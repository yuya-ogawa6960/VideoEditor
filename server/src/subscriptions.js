// =====================================================================
// アプリ内課金(自動更新サブスクリプション)の確認と、毎月のポイント。
//
// - アプリは購入・起動のたびに、StoreKit 2 の「いま有効な購入」(Transaction.currentEntitlements)の
//   jwsRepresentation を POST /v1/subscription/sync で送る。サーバーは Apple の署名を確かめ(appTransaction.js)、
//   購入(originalTransactionId)をこのアカウントに結びつける。ほかのアカウントに結びついた購入は使えない
// - 月が替わって更新されると transactionId が新しくなる。新しい transactionId ごとに 1 回だけ、プランの毎月のポイントを付ける
// - ポイントは繰り越さない: 前の月にプランで付けた分(sub_points)の残りは、次の付与のときに消してから付け直す。
//   無料でもらったポイント(登録・毎日・広告)は消さない。使うときはプランの分から先に減らす(index.js の reserve)
// - App Store のサーバー通知(POST /v1/appstore/notifications。App Store Connect に URL を登録する)で、
//   アプリを開いていなくても更新・返金・取り消しを反映する
// - 解約して期限が切れたら、プランで付けたポイントの残りを消す(EXPIRED の通知、または期限から PLAN_POINTS_GRACE_MS 過ぎたとき)
// - TestFlight・App Review の購入(Sandbox)は更新が早回しなので、毎月のポイントは同じアカウントに実時間で 30 日に 1 回だけ付ける
// =====================================================================

import { verifyAppleJWS } from "./appTransaction.js";

/** 商品 ID → プランと毎月のポイント(App Store Connect の商品 ID と同じにする) */
export const PRODUCTS = {
  "com.yuyaogawa6960.videomania.standard.month": { plan: "standard", monthlyPoints: 1500 },
  "com.yuyaogawa6960.videomania.pro.month": { plan: "pro", monthlyPoints: 5000 },
};
const PLAN_RANK = { free: 0, standard: 1, pro: 2 };
const MAX_TRANSACTIONS = 10;
const DAY_MS = 86400 * 1000;
/** 期限が過ぎてもプランのポイントを残す日数(請求の猶予期間中に消さないため。期限切れの通知が来ればその場で消す) */
const PLAN_POINTS_GRACE_MS = 28 * DAY_MS;
/** Sandbox(TestFlight・App Review)の購入で毎月のポイントを付ける間隔(実時間) */
const SANDBOX_GRANT_INTERVAL_MS = 30 * DAY_MS;

function nowISO() {
  return new Date().toISOString();
}

let columnsEnsured = false;

/** 既存の DB に sub_points(プランで付けたポイントの残り)と、課金の表を足す(あれば失敗するので無視。isolate ごとに 1 回) */
export async function ensureSubscriptionTables(env) {
  if (columnsEnsured) return;
  columnsEnsured = true;
  try {
    await env.DB.prepare("ALTER TABLE users ADD COLUMN sub_points INTEGER NOT NULL DEFAULT 0").run();
  } catch (_) {}
  await env.DB.batch([
    env.DB.prepare(
      "CREATE TABLE IF NOT EXISTS subscriptions (original_transaction_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, product_id TEXT NOT NULL, plan TEXT NOT NULL, expires_at INTEGER NOT NULL, environment TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL)"
    ),
    env.DB.prepare("CREATE INDEX IF NOT EXISTS subscriptions_user ON subscriptions (user_id)"),
    env.DB.prepare(
      "CREATE TABLE IF NOT EXISTS subscription_grants (transaction_id TEXT PRIMARY KEY, amount INTEGER NOT NULL, created_at TEXT NOT NULL)"
    ),
    env.DB.prepare("CREATE TABLE IF NOT EXISTS sandbox_grants (user_id TEXT PRIMARY KEY, granted_at INTEGER NOT NULL)"),
  ]);
}

/**
 * 購入の記録(JWSTransaction)を確かめて、使える形にして返す。通らなければ null。
 * このアプリの、知っている商品の、自動更新サブスクリプションで、家族共有ではないものだけ
 */
export async function verifyTransaction(jws, env, options = {}) {
  const payload = await verifyAppleJWS(jws, options);
  if (!payload || payload.bundleId !== env.APPLE_AUDIENCE) return null;
  const product = PRODUCTS[payload.productId];
  if (!product) return null;
  if (payload.type && payload.type !== "Auto-Renewable Subscription") return null;
  if (payload.inAppOwnershipType && payload.inAppOwnershipType !== "PURCHASED") return null;
  if (payload.environment !== "Production" && payload.environment !== "Sandbox") return null;
  const transactionID = String(payload.transactionId || "");
  const originalID = String(payload.originalTransactionId || "");
  const expires = Number(payload.expiresDate);
  if (!transactionID || !originalID || !Number.isFinite(expires)) return null;
  return {
    transactionID,
    originalID,
    productID: payload.productId,
    plan: product.plan,
    monthlyPoints: product.monthlyPoints,
    expires,
    environment: payload.environment,
    revoked: payload.revocationDate != null,
  };
}

/** いま有効なプラン(一番上のもの)と期限。無ければ free */
export async function subscriptionState(env, userID, now = Date.now()) {
  await ensureSubscriptionTables(env);
  const rows = (await env.DB.prepare(
    "SELECT plan, expires_at FROM subscriptions WHERE user_id = ? AND revoked = 0 AND expires_at > ?"
  ).bind(userID, now).all()).results || [];
  let best = { plan: "free", expiresAt: null };
  for (const row of rows) {
    if ((PLAN_RANK[row.plan] || 0) > PLAN_RANK[best.plan]) best = { plan: row.plan, expiresAt: row.expires_at };
  }
  return best;
}

/**
 * 確かめた購入を 1 件反映する(結びつけ・期限・取り消し・毎月のポイント)。
 * userID が null(サーバー通知)のときは、前に結びついたアカウントに反映する。
 * 返り値: { ok, reason?, granted }
 */
export async function applyTransaction(env, userID, tx, now = Date.now()) {
  await ensureSubscriptionTables(env);
  const existing = await env.DB.prepare("SELECT user_id FROM subscriptions WHERE original_transaction_id = ?")
    .bind(tx.originalID).first();
  if (existing && userID && existing.user_id !== userID) return { ok: false, reason: "owned_by_other", granted: 0 };
  const owner = existing ? existing.user_id : userID;
  if (!owner) return { ok: false, reason: "unknown_owner", granted: 0 };
  const sandbox = tx.environment === "Sandbox";

  await env.DB.prepare(
    `INSERT INTO subscriptions (original_transaction_id, user_id, product_id, plan, expires_at, environment, revoked, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(original_transaction_id) DO UPDATE SET product_id = excluded.product_id, plan = excluded.plan,
       expires_at = MAX(subscriptions.expires_at, excluded.expires_at), environment = excluded.environment,
       revoked = excluded.revoked, updated_at = excluded.updated_at`
  ).bind(tx.originalID, owner, tx.productID, tx.plan, tx.expires, tx.environment, tx.revoked ? 1 : 0, nowISO()).run();

  if (tx.revoked) {
    // 返金・取り消し: プランで付けたポイントの残りを消す(使った分は戻さない)
    await clearPlanPoints(env, owner, "subscription_revoked");
    return { ok: true, granted: 0, owner };
  }
  if (tx.expires <= now) return { ok: true, granted: 0, owner };

  // Sandbox(TestFlight の早回しの更新)は、同じアカウントに実時間で SANDBOX_GRANT_INTERVAL_MS に 1 回だけ付ける
  // (本番のサーバーと同じポイントで本物の AI を使えるため。App Review が毎月のポイントを確かめられるよう、0 にはしない)
  if (sandbox) {
    const last = await env.DB.prepare("SELECT granted_at FROM sandbox_grants WHERE user_id = ?").bind(owner).first();
    if (last && now - Number(last.granted_at) < SANDBOX_GRANT_INTERVAL_MS) return { ok: true, granted: 0, owner };
  }

  // この期間(transactionId)の毎月のポイントは 1 回だけ。前の期間の残りは繰り越さない
  const inserted = await env.DB.prepare(
    "INSERT OR IGNORE INTO subscription_grants (transaction_id, amount, created_at) VALUES (?, ?, ?)"
  ).bind(tx.transactionID, tx.monthlyPoints, nowISO()).run();
  if (!inserted.meta || inserted.meta.changes === 0) return { ok: true, granted: 0, owner };
  await clearPlanPoints(env, owner, "subscription_reset");
  await env.DB.prepare("UPDATE users SET points = points + ?, sub_points = ? WHERE id = ?")
    .bind(tx.monthlyPoints, tx.monthlyPoints, owner).run();
  await ledger(env, owner, tx.monthlyPoints, "subscription:" + tx.plan);
  if (sandbox) {
    await env.DB.prepare(
      "INSERT INTO sandbox_grants (user_id, granted_at) VALUES (?, ?) ON CONFLICT(user_id) DO UPDATE SET granted_at = excluded.granted_at"
    ).bind(owner, now).run();
  }
  return { ok: true, granted: tx.monthlyPoints, owner };
}

/**
 * 有効なプラン(期限から graceMs 以内のものを含む)が無いのに、プランで付けたポイントが残っていれば消す。
 * ポイントを使う前(index.js の reserve)と /v1/me で呼ぶ。消したら true
 */
export async function expirePlanPoints(env, userID, now = Date.now(), graceMs = PLAN_POINTS_GRACE_MS) {
  await ensureSubscriptionTables(env);
  const row = await env.DB.prepare("SELECT sub_points FROM users WHERE id = ?").bind(userID).first();
  if (!row || !(row.sub_points > 0)) return false;
  const active = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM subscriptions WHERE user_id = ? AND revoked = 0 AND expires_at > ?"
  ).bind(userID, now - graceMs).first();
  if (active && active.n > 0) return false;
  await clearPlanPoints(env, userID, "subscription_expired");
  return true;
}

async function clearPlanPoints(env, userID, reason) {
  const row = await env.DB.prepare("SELECT points, sub_points FROM users WHERE id = ?").bind(userID).first();
  if (!row) return;
  const remove = Math.min(Math.max(row.sub_points || 0, 0), Math.max(row.points || 0, 0));
  await env.DB.prepare("UPDATE users SET points = points - ?, sub_points = 0 WHERE id = ?").bind(remove, userID).run();
  if (remove > 0) await ledger(env, userID, -remove, reason);
}

async function ledger(env, userID, delta, reason) {
  await env.DB.prepare("INSERT INTO ledger (user_id, delta, reason, created_at) VALUES (?, ?, ?, ?)")
    .bind(userID, delta, reason, nowISO()).run();
}

/** POST /v1/subscription/sync の中身。{ transactions: [jws...] } → { plan, expiresAt, granted, rejected } */
export async function syncSubscriptions(body, userID, env, options = {}) {
  const list = Array.isArray(body && body.transactions) ? body.transactions.slice(0, MAX_TRANSACTIONS) : [];
  let granted = 0;
  const rejected = [];
  for (const jws of list) {
    const tx = typeof jws === "string" ? await verifyTransaction(jws, env, options) : null;
    if (!tx) {
      rejected.push("invalid");
      continue;
    }
    const result = await applyTransaction(env, userID, tx, options.nowMs);
    if (!result.ok) rejected.push(result.reason);
    granted += result.granted;
  }
  return { ...(await subscriptionState(env, userID, options.nowMs)), granted, rejected };
}

/**
 * App Store のサーバー通知(V2)。signedPayload を確かめ、中の購入の記録を反映する。
 * 知らないアカウントの購入(アプリでまだ一度も送られていない)は、次にアプリが送ったときに反映される
 */
export async function handleNotification(body, env, options = {}) {
  const payload = await verifyAppleJWS(body && body.signedPayload, options);
  if (!payload || !payload.data || payload.data.bundleId !== env.APPLE_AUDIENCE) return { ok: false };
  const signed = payload.data.signedTransactionInfo;
  if (typeof signed !== "string") return { ok: true, applied: false };
  const tx = await verifyTransaction(signed, env, options);
  if (!tx) return { ok: true, applied: false };
  if (payload.notificationType === "REFUND" || payload.notificationType === "REVOKE") tx.revoked = true;
  const result = await applyTransaction(env, null, tx, options.nowMs);
  // 解約して期限が切れた: プランで付けたポイントの残りを消す(ほかに有効なプランがあれば残す)
  if (result.ok && result.owner && payload.notificationType === "EXPIRED") {
    await expirePlanPoints(env, result.owner, options.nowMs ?? Date.now(), 0);
  }
  return { ok: true, applied: result.ok };
}

/** アカウント削除のとき: 結びつきを外す(同じ購入を作り直したアカウントで使えるように)。
 *  付与済みの期間(subscription_grants)は残すので、同じ月のポイントがもう一度付くことはない */
export async function forgetSubscriptions(env, userID) {
  await ensureSubscriptionTables(env);
  await env.DB.prepare("DELETE FROM subscriptions WHERE user_id = ?").bind(userID).run();
}

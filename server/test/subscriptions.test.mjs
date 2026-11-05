// アプリ内課金(src/subscriptions.js)のテスト。D1 の代わりに Node の SQLite(node:sqlite)を使い、
// 購入の記録は test/fixtures の証明書で署名する(Apple のルートの代わりに fixtures の root.pem を信頼する)。
//   - 正しい購入 → プランが有効になり、毎月のポイントが 1 回だけ付く
//   - ほかのアカウントに結びついた購入・偽の署名・知らない商品・家族共有 → 使えない
//   - 更新(新しい transactionId)→ 前の月のプランの残りを消してから付け直す(無料のポイントは残る)
//   - 返金(サーバー通知の REFUND)→ プランが外れ、プランの残りが消える
//   実行: cd server && node --test test/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { certificate, privateKey, makeJWS } from "./helpers.mjs";
import { syncSubscriptions, handleNotification, subscriptionState } from "../src/subscriptions.js";

const BUNDLE_ID = "com.yuyaogawa6960.videomania";
const STANDARD = "com.yuyaogawa6960.videomania.plan.standard.monthly";
const PRO = "com.yuyaogawa6960.videomania.plan.pro.monthly";
const ROOT = certificate("root.pem");
const SIGNED = Date.UTC(2026, 5, 1); // fixtures の 3 枚とも有効な日時
const NOW = SIGNED + 1000;
const DAY = 86400 * 1000;
const options = { fetchRoot: async () => ROOT, nowMs: NOW };

/** D1 と同じ呼び方(prepare → bind → run / first / all、batch)をする SQLite */
function d1() {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(new URL("../schema.sql", import.meta.url), "utf8"));
  const statement = (sql, args = []) => ({
    bind: (...values) => statement(sql, values),
    run: async () => ({ meta: { changes: Number(db.prepare(sql).run(...args).changes) } }),
    first: async () => db.prepare(sql).get(...args) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...args) }),
  });
  return {
    raw: db,
    prepare: (sql) => statement(sql),
    batch: async (list) => Promise.all(list.map((s) => s.run())),
  };
}

function setup(users = { "apple:a": 30, "apple:b": 0 }) {
  const DB = d1();
  for (const [id, points] of Object.entries(users)) {
    DB.raw.prepare("INSERT INTO users (id, points, created_at) VALUES (?, ?, ?)").run(id, points, "2026-06-01");
  }
  return { DB, APPLE_AUDIENCE: BUNDLE_ID };
}

function points(env, id) {
  return env.DB.raw.prepare("SELECT points FROM users WHERE id = ?").get(id).points;
}

function transaction(extra = {}, signer = {}) {
  return makeJWS({
    x5c: signer.x5c || [certificate("leaf.pem"), certificate("inter.pem"), ROOT],
    key: signer.key || privateKey("leaf.key"),
    payload: {
      bundleId: BUNDLE_ID, productId: STANDARD, type: "Auto-Renewable Subscription", inAppOwnershipType: "PURCHASED",
      environment: "Production", transactionId: "1000", originalTransactionId: "1000",
      purchaseDate: SIGNED, signedDate: SIGNED, expiresDate: NOW + 30 * DAY, ...extra,
    },
  });
}

test("正しい購入でプランが有効になり、毎月のポイントは 1 回だけ付く", async () => {
  const env = setup();
  const first = await syncSubscriptions({ transactions: [transaction()] }, "apple:a", env, options);
  assert.equal(first.plan, "standard");
  assert.equal(first.granted, 1500);
  assert.equal(points(env, "apple:a"), 1530);
  const again = await syncSubscriptions({ transactions: [transaction()] }, "apple:a", env, options);
  assert.equal(again.granted, 0);
  assert.equal(points(env, "apple:a"), 1530);
});

test("ほかのアカウントに結びついた購入は使えない", async () => {
  const env = setup();
  await syncSubscriptions({ transactions: [transaction()] }, "apple:a", env, options);
  const other = await syncSubscriptions({ transactions: [transaction()] }, "apple:b", env, options);
  assert.equal(other.plan, "free");
  assert.deepEqual(other.rejected, ["owned_by_other"]);
  assert.equal(points(env, "apple:b"), 0);
});

test("偽の署名・知らない商品・家族共有・別のアプリ・期限切れは使えない", async () => {
  const env = setup();
  const forged = transaction({}, {
    x5c: [certificate("forged-leaf.pem"), certificate("forged-inter.pem"), certificate("forged-root.pem")],
    key: privateKey("forged-leaf.key"),
  });
  const list = [
    forged,
    transaction({ productId: "com.example.other", originalTransactionId: "2" }),
    transaction({ inAppOwnershipType: "FAMILY_SHARED", originalTransactionId: "3" }),
    transaction({ bundleId: "com.example.app", originalTransactionId: "4" }),
  ];
  const result = await syncSubscriptions({ transactions: list }, "apple:a", env, options);
  assert.equal(result.plan, "free");
  assert.equal(result.rejected.length, 4);
  const expired = await syncSubscriptions({ transactions: [transaction({ expiresDate: NOW - 1 })] }, "apple:a", env, options);
  assert.equal(expired.plan, "free");
  assert.equal(expired.granted, 0);
  assert.equal(points(env, "apple:a"), 30);
});

test("更新されると前の月のプランの残りは消え、無料のポイントは残る", async () => {
  const env = setup();
  await syncSubscriptions({ transactions: [transaction()] }, "apple:a", env, options);
  // 1000pt 使う(プランの分から先に減る)
  env.DB.raw.prepare("UPDATE users SET points = points - 1000, sub_points = MAX(sub_points - 1000, 0) WHERE id = ?").run("apple:a");
  assert.equal(points(env, "apple:a"), 530); // 無料 30 + プランの残り 500
  const renewed = await syncSubscriptions({ transactions: [transaction({ transactionId: "1001", expiresDate: NOW + 60 * DAY })] }, "apple:a", env, options);
  assert.equal(renewed.granted, 1500);
  assert.equal(points(env, "apple:a"), 1530); // 残り 500 は消えて、新しい 1500 + 無料 30
});

test("Pro に上げるとその場で Pro のポイントに置き換わる", async () => {
  const env = setup();
  await syncSubscriptions({ transactions: [transaction()] }, "apple:a", env, options);
  const upgraded = await syncSubscriptions({ transactions: [transaction({ productId: PRO, transactionId: "1002" })] }, "apple:a", env, options);
  assert.equal(upgraded.plan, "pro");
  assert.equal(points(env, "apple:a"), 5030);
});

test("返金の通知でプランが外れ、プランの残りが消える", async () => {
  const env = setup();
  await syncSubscriptions({ transactions: [transaction()] }, "apple:a", env, options);
  const signedPayload = makeJWS({
    x5c: [certificate("leaf.pem"), certificate("inter.pem"), ROOT],
    key: privateKey("leaf.key"),
    payload: { notificationType: "REFUND", signedDate: SIGNED, data: { bundleId: BUNDLE_ID, environment: "Production", signedTransactionInfo: transaction() } },
  });
  const result = await handleNotification({ signedPayload }, env, options);
  assert.equal(result.applied, true);
  assert.equal((await subscriptionState(env, "apple:a", NOW)).plan, "free");
  assert.equal(points(env, "apple:a"), 30);
});

test("偽の通知は受け付けない", async () => {
  const env = setup();
  const signedPayload = makeJWS({
    x5c: [certificate("forged-leaf.pem"), certificate("forged-inter.pem"), certificate("forged-root.pem")],
    key: privateKey("forged-leaf.key"),
    payload: { notificationType: "DID_RENEW", data: { bundleId: BUNDLE_ID, signedTransactionInfo: transaction() } },
  });
  assert.equal((await handleNotification({ signedPayload }, env, options)).ok, false);
});

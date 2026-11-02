// /v1/ads/claim(src/index.js)を通したテスト。Apple の証明の確認を厳しくしても、ポイントを受け取れる人は変わらない:
//   - 正しい Sandbox の証明 → サインインしているどのアカウントでも付与(1 日の上限まで)
//   - 証明なし(App Store 版)→ 付与せず pending: true(AdMob の SSV を待つ)
//   - 偽の連鎖(forge.mjs)・Production の証明 → 付与せず pending: true
//   - 証明が無くても x-vm-test-build: 1 + TEST_AD_USERS のアカウントなら付与(古い端末向け。今まで通り)
// Apple のルート証明書の取得(fetch)だけをテスト用のルートに差し替え、D1 は下の fakeDB で代わりにする。
//   実行: cd server && node --test test/*.test.mjs
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { certificate, privateKey, makeJWS } from "./helpers.mjs";

const APPLE_ROOT_URL = "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer";
const BUNDLE_ID = "com.yuyaogawa6960.videomania";
const SESSION_SECRET = "test-session-secret";
const USER = "apple:someone"; // TEST_AD_USERS に入っていないアカウント
const TESTER = "apple:tester"; // TEST_AD_USERS のアカウント

const ROOT = certificate("root.pem");
const FORGED_ROOT = certificate("forged-root.pem");
const RECEIPT_CREATION_DATE = Date.UTC(2026, 5, 1); // fixtures の 3 枚とも有効な日時

/** 正しい連鎖で署名した、このアプリの AppTransaction */
function proof(extra = {}) {
  return makeJWS({
    x5c: [certificate("leaf.pem"), certificate("inter.pem"), ROOT],
    payload: { bundleId: BUNDLE_ID, receiptType: "Sandbox", receiptCreationDate: RECEIPT_CREATION_DATE, ...extra },
    key: privateKey("leaf.key"),
  });
}

/** forge.mjs と同じ偽の連鎖で署名したもの(日時は証明書の期間内に固定) */
function forgedProof() {
  return makeJWS({
    x5c: [certificate("forged-leaf.pem"), certificate("forged-inter.pem"), FORGED_ROOT],
    payload: { bundleId: BUNDLE_ID, receiptType: "Sandbox", appAppleId: 0, receiptCreationDate: Date.UTC(2027, 0, 1) },
    key: privateKey("forged-leaf.key"),
  });
}

// apple.com の代わりに返すルート(テストごとに変える)。それ以外の URL には出ない
let appleRoot = ROOT;
let rootRequests = 0;
let realFetch;
before(() => {
  realFetch = globalThis.fetch;
  globalThis.fetch = async (input) => {
    const url = typeof input === "string" ? input : input.url;
    if (url !== APPLE_ROOT_URL) throw new Error("テストでは外に出ない: " + url);
    rootRequests++;
    return new Response(appleRoot);
  };
});
after(() => {
  globalThis.fetch = realFetch;
});

/** テスト用の D1 もどき(/v1/ads/claim が使う SQL だけ。知らない SQL は失敗にする) */
function fakeDB(userIDs) {
  const db = { users: new Map(userIDs.map((id) => [id, { id, points: 0, last_daily: null }])), adRewards: [], ledger: [] };
  const exec = (sql, args) => {
    const s = sql.replace(/\s+/g, " ").trim();
    if (s === "SELECT id, points, last_daily FROM users WHERE id = ?") return { row: db.users.get(args[0]) ?? null };
    if (s === "SELECT id FROM users WHERE id = ?") return { row: db.users.has(args[0]) ? { id: args[0] } : null };
    if (s === "SELECT points FROM users WHERE id = ?") return { row: db.users.has(args[0]) ? { points: db.users.get(args[0]).points } : null };
    if (s === "SELECT COUNT(*) AS n FROM ad_rewards WHERE user_id = ? AND day = ?") {
      return { row: { n: db.adRewards.filter((r) => r.user_id === args[0] && r.day === args[1]).length } };
    }
    if (s.startsWith("INSERT OR IGNORE INTO ad_rewards ")) {
      if (db.adRewards.some((r) => r.transaction_id === args[0])) return { changes: 0 };
      db.adRewards.push({ transaction_id: args[0], user_id: args[1], amount: args[2], day: args[3], source: args[4] });
      return { changes: 1 };
    }
    if (s === "UPDATE users SET points = points + ? WHERE id = ?") {
      const user = db.users.get(args[1]);
      if (user) user.points += args[0];
      return { changes: user ? 1 : 0 };
    }
    if (s.startsWith("INSERT INTO ledger ")) {
      db.ledger.push({ user_id: args[0], delta: args[1], reason: args[2] });
      return { changes: 1 };
    }
    throw new Error("fakeDB: 未対応の SQL: " + s);
  };
  const statement = (sql, args = []) => ({
    bind: (...values) => statement(sql, values),
    first: async () => exec(sql, args).row ?? null,
    run: async () => ({ meta: { changes: exec(sql, args).changes ?? 0 } }),
  });
  db.prepare = (sql) => statement(sql);
  return db;
}

function makeEnv(db) {
  return { DB: db, SESSION_SECRET, APPLE_AUDIENCE: BUNDLE_ID, ALLOW_CLIENT_AD_CLAIM: "0", TEST_AD_USERS: TESTER };
}

/** index.js と同じ形のセッショントークン(vm1.<中身>.<HMAC-SHA256>) */
async function sessionToken(userID) {
  const body = Buffer.from(JSON.stringify({ sub: userID, exp: Math.floor(Date.now() / 1000) + 3600 })).toString("base64url");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(SESSION_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return "vm1." + body + "." + Buffer.from(signature).toString("base64url");
}

/** POST /v1/ads/claim を Worker の fetch に渡し、応答の JSON を返す */
async function claim(env, userID, { appTransaction, testBuildHeader = false } = {}) {
  const headers = { "content-type": "application/json", authorization: "Bearer " + (await sessionToken(userID)) };
  if (testBuildHeader) headers["x-vm-test-build"] = "1";
  const body = JSON.stringify(appTransaction === undefined ? {} : { appTransaction });
  const response = await worker.fetch(new Request("https://videomania.test/v1/ads/claim", { method: "POST", headers, body }), env);
  assert.equal(response.status, 200);
  return response.json();
}

test("正しい Sandbox の証明は、TEST_AD_USERS に無いアカウントでも付与する(1 日の上限まで)", async () => {
  appleRoot = ROOT;
  const requestsBefore = rootRequests;
  const db = fakeDB([USER]);
  const env = makeEnv(db);
  const first = await claim(env, USER, { appTransaction: proof() });
  assert.equal(first.granted, true);
  assert.equal(first.pending, false);
  assert.equal(first.points, first.adRewardPoints);
  for (let i = 2; i <= first.adRewardLimit; i++) {
    const body = await claim(env, USER, { appTransaction: proof() });
    assert.equal(body.granted, true);
    assert.equal(body.points, first.adRewardPoints * i);
  }
  // 上限の後は付与しない(pending ではない)
  const over = await claim(env, USER, { appTransaction: proof() });
  assert.equal(over.granted, false);
  assert.equal(over.pending, false);
  assert.equal(over.points, first.adRewardPoints * first.adRewardLimit);
  assert.equal(db.users.get(USER).points, first.adRewardPoints * first.adRewardLimit);
  assert.ok(db.adRewards.every((r) => r.source === "client"));
  assert.ok(rootRequests > requestsBefore, "Apple のルートは apple.com の URL から取っている");
});

test("証明なし(App Store 版)は付与せず pending: true", async () => {
  const db = fakeDB([USER]);
  const body = await claim(makeEnv(db), USER);
  assert.equal(body.granted, false);
  assert.equal(body.pending, true);
  assert.equal(db.users.get(USER).points, 0);
});

test("偽の連鎖(forge.mjs)の証明は、そのルートを信頼させても付与せず pending: true", async () => {
  appleRoot = FORGED_ROOT;
  try {
    const db = fakeDB([USER]);
    const body = await claim(makeEnv(db), USER, { appTransaction: forgedProof() });
    assert.equal(body.granted, false);
    assert.equal(body.pending, true);
    assert.equal(db.users.get(USER).points, 0);
    assert.equal(db.adRewards.length, 0);
  } finally {
    appleRoot = ROOT;
  }
});

test("本番(Production)・別のアプリの証明は付与せず pending: true", async () => {
  appleRoot = ROOT;
  for (const extra of [{ receiptType: "Production" }, { receiptType: "Xcode" }, { bundleId: "com.example.other" }]) {
    const db = fakeDB([USER]);
    const body = await claim(makeEnv(db), USER, { appTransaction: proof(extra) });
    assert.equal(body.granted, false, JSON.stringify(extra));
    assert.equal(body.pending, true, JSON.stringify(extra));
    assert.equal(db.users.get(USER).points, 0);
  }
});

test("証明が無くても、x-vm-test-build: 1 で TEST_AD_USERS のアカウントなら付与する(今まで通り)", async () => {
  const db = fakeDB([TESTER, USER]);
  const env = makeEnv(db);
  const tester = await claim(env, TESTER, { testBuildHeader: true });
  assert.equal(tester.granted, true);
  assert.equal(tester.pending, false);
  // TEST_AD_USERS に無いアカウントはヘッダだけでは付与しない
  const other = await claim(env, USER, { testBuildHeader: true });
  assert.equal(other.granted, false);
  assert.equal(other.pending, true);
});

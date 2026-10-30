// POST /v1/ads/claim の守り(テスト版の証明 + TEST_AD_USERS + 1 日の回数 + 断った回の記録)
//   実行: cd server && node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import { adClaim, ingestEvents, ALLOWED_EVENT_NAMES, AD_CLAIM_ATTEMPTS_PER_DAY, POINTS } from "../src/index.js";
import { fakeDB } from "./fakeDB.mjs";

const USER = "apple:tester";
const sandbox = { bundleId: "com.example.app", environment: "Sandbox" };
const production = { bundleId: "com.example.app", environment: "Production" };

function makeEnv(db, extra = {}) {
  return { DB: db, APPLE_AUDIENCE: "com.example.app", ALLOW_CLIENT_AD_CLAIM: "0", TEST_AD_USERS: USER, ...extra };
}

function makeRequest({ header = false, body = {} } = {}) {
  const headers = { "content-type": "application/json" };
  if (header) headers["x-vm-test-build"] = "1";
  return new Request("https://example.test/v1/ads/claim", { method: "POST", headers, body: JSON.stringify(body) });
}

/** verifyAppTransaction の代わり: 文字列ごとに返す payload を決める */
function verifier(map) {
  return async (jws, { bundleID }) => {
    const payload = map[jws] || null;
    if (payload && bundleID && payload.bundleId !== bundleID) return null;
    return payload;
  };
}

async function claim(db, env, req, verify) {
  const res = await adClaim(req, { id: USER, points: db.users[USER]?.points ?? 0 }, env, { verifyAppTransaction: verify });
  return { status: res.status, body: await res.json() };
}

test("本番のアプリ(ヘッダも証明も無し)は pending。付与も記録もしない", async () => {
  const db = fakeDB({ users: { [USER]: 0 } });
  const r = await claim(db, makeEnv(db), makeRequest(), verifier({}));
  assert.equal(r.status, 200);
  assert.equal(r.body.granted, false);
  assert.equal(r.body.pending, true);
  assert.equal(db.users[USER].points, 0);
  assert.equal(db.events.length, 0);
});

test("ヘッダだけ(証明なし)では付与しない。TEST_AD_USERS でも同じ。記録に残る", async () => {
  const db = fakeDB({ users: { [USER]: 0 } });
  const r = await claim(db, makeEnv(db), makeRequest({ header: true }), verifier({}));
  assert.equal(r.status, 403);
  assert.equal(r.body.error.code, "test_proof_required");
  assert.equal(db.users[USER].points, 0);
  assert.deepEqual(db.events.map((e) => [e.install_id, e.name, e.params.reason]), [["server", "ad_claim_rejected", "no_proof"]]);
  assert.equal(db.events[0].params.header, "1");
  assert.ok(!JSON.stringify(db.events[0].params).includes(USER), "生のアカウント ID は記録に入れない");
});

test("検証に通らない AppTransaction は付与しない(bad_proof)", async () => {
  const db = fakeDB({ users: { [USER]: 0 } });
  const r = await claim(db, makeEnv(db), makeRequest({ header: true, body: { appTransaction: "forged" } }), verifier({}));
  assert.equal(r.status, 403);
  assert.equal(r.body.error.code, "test_proof_invalid");
  assert.equal(db.events[0].params.reason, "bad_proof");
});

test("本番(Production)の AppTransaction は付与しない(not_sandbox)", async () => {
  const db = fakeDB({ users: { [USER]: 0 } });
  const r = await claim(db, makeEnv(db), makeRequest({ body: { appTransaction: "prod" } }), verifier({ prod: production }));
  assert.equal(r.status, 403);
  assert.equal(r.body.error.code, "not_test_build");
  assert.equal(db.events[0].params.reason, "not_sandbox");
  assert.equal(db.events[0].params.environment, "Production");
});

test("Sandbox の証明があっても TEST_AD_USERS 以外は付与しない(not_test_user)", async () => {
  const db = fakeDB({ users: { [USER]: 0 } });
  const env = makeEnv(db, { TEST_AD_USERS: "apple:someone-else" });
  const r = await claim(db, env, makeRequest({ header: true, body: { appTransaction: "sb" } }), verifier({ sb: sandbox }));
  assert.equal(r.status, 403);
  assert.equal(r.body.error.code, "not_test_user");
  assert.equal(db.users[USER].points, 0);
  assert.equal(db.events[0].params.reason, "not_test_user");
});

test("別アプリの bundleId の AppTransaction は付与しない", async () => {
  const db = fakeDB({ users: { [USER]: 0 } });
  const r = await claim(db, makeEnv(db), makeRequest({ body: { appTransaction: "other" } }),
                        verifier({ other: { bundleId: "com.other.app", environment: "Sandbox" } }));
  assert.equal(r.status, 403);
  assert.equal(r.body.error.code, "test_proof_invalid");
});

test("Sandbox の証明 + TEST_AD_USERS のときだけ付与する(1 日の上限まで)。上限後は daily_limit を記録", async () => {
  const db = fakeDB({ users: { [USER]: 0 } });
  const env = makeEnv(db);
  for (let i = 0; i < POINTS.adRewardDailyLimit; i++) {
    const r = await claim(db, env, makeRequest({ header: true, body: { appTransaction: "sb" } }), verifier({ sb: sandbox }));
    assert.equal(r.status, 200);
    assert.equal(r.body.granted, true);
    assert.equal(r.body.pending, false);
  }
  assert.equal(db.users[USER].points, POINTS.adReward * POINTS.adRewardDailyLimit);
  assert.ok(db.adRewards.every((r) => r.source === "client"));
  const r = await claim(db, env, makeRequest({ header: true, body: { appTransaction: "sb" } }), verifier({ sb: sandbox }));
  assert.equal(r.status, 200);
  assert.equal(r.body.granted, false);
  assert.equal(db.users[USER].points, POINTS.adReward * POINTS.adRewardDailyLimit);
  assert.deepEqual(db.events.map((e) => e.params.reason), ["daily_limit"]);
});

test("ALLOW_CLIENT_AD_CLAIM=1 は TEST_AD_USERS の条件だけ省く。証明なしは今までのように通さない", async () => {
  const db = fakeDB({ users: { [USER]: 0 } });
  const env = makeEnv(db, { ALLOW_CLIENT_AD_CLAIM: "1", TEST_AD_USERS: "" });
  let r = await claim(db, env, makeRequest(), verifier({}));
  assert.equal(r.status, 403);
  assert.equal(r.body.error.code, "test_proof_required");
  r = await claim(db, env, makeRequest({ body: { appTransaction: "sb" } }), verifier({ sb: sandbox }));
  assert.equal(r.status, 200);
  assert.equal(r.body.granted, true);
});

test("1 アカウント 1 日の呼び出し回数を超えると 429。超えた回も記録に残る", async () => {
  const db = fakeDB({ users: { [USER]: 0 } });
  const env = makeEnv(db);
  for (let i = 0; i < AD_CLAIM_ATTEMPTS_PER_DAY; i++) {
    const r = await claim(db, env, makeRequest({ header: true, body: { appTransaction: "forged" } }), verifier({}));
    assert.equal(r.status, 403);
  }
  const r = await claim(db, env, makeRequest({ header: true, body: { appTransaction: "forged" } }), verifier({}));
  assert.equal(r.status, 429);
  assert.equal(r.body.error.code, "rate_limited");
  const last = db.events[db.events.length - 1];
  assert.equal(last.params.reason, "rate_limited");
  assert.equal(last.params.attempts, String(AD_CLAIM_ATTEMPTS_PER_DAY + 1));
  // 回数の上限は本番のアプリにもかかる(pending の応答も数える)
  const r2 = await claim(db, env, makeRequest(), verifier({}));
  assert.equal(r2.status, 429);
});

test("ad_claim_rejected は許可された名前だが、アプリからの /v1/events では受け付けない", async () => {
  assert.ok(ALLOWED_EVENT_NAMES.has("ad_claim_rejected"));
  const db = fakeDB();
  const req = new Request("https://example.test/v1/events", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ install: "0123456789abcdef", events: [{ name: "ad_claim_rejected" }, { name: "app_open" }] }),
  });
  const res = await ingestEvents(req, { DB: db });
  assert.equal((await res.json()).accepted, 1);
  assert.deepEqual(db.events.map((e) => e.name), ["app_open"]);
});

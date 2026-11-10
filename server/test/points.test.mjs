// ポイントの精算(src/index.js)のテスト。D1 の代わりに Node の SQLite(node:sqlite)、OpenAI・Apple の代わりに fetch の差し替えを使う。
//   - 無料プランの試用(50pt): trialID で 1 回だけ返せる(プランの分はプランの分に戻る)・ほかの人の試用は返せない・時間切れ
//   - クラウド文字起こし: 秒で数えて端数を持ち越す(6 秒 × 10 本 = 10pt)・OpenAI に渡す項目はサーバーで作り直す
//   - チャット: 許可した項目だけを渡す(n=1・max_tokens の上限)・すべてのロールの文を確かめる・失敗で返すときはプランの分に戻す
//   - はじめてのボーナス: アカウントを削除して作り直しても 2 回目は付かない(同じ日の毎日ボーナスも)
//   - /v1/me: 期限が近いセッションは新しいトークンを返す・リワード広告の ID・期限切れのプランのポイントを消す
//   - 使い方の統計: TikTok・カメラのイベントを受け付ける
//   実行: cd server && node --test test/*.test.mjs
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { generateKeyPairSync, sign } from "node:crypto";
import worker from "../src/index.js";

const SESSION_SECRET = "test-session-secret";
const BUNDLE_ID = "com.yuyaogawa6960.videomania";
const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

function d1() {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(new URL("../schema.sql", import.meta.url), "utf8"));
  const statement = (sql, args = []) => ({
    bind: (...values) => statement(sql, values),
    run: async () => ({ meta: { changes: Number(db.prepare(sql).run(...args).changes) } }),
    first: async () => db.prepare(sql).get(...args) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...args) }),
  });
  return { raw: db, prepare: (sql) => statement(sql), batch: async (list) => Promise.all(list.map((s) => s.run())) };
}

function setup({ points = 100, subPoints = 0, activePlan = subPoints > 0 } = {}) {
  const DB = d1();
  DB.raw.prepare("INSERT INTO users (id, points, sub_points, created_at) VALUES (?, ?, ?, ?)").run("apple:a", points, subPoints, "2026-06-01");
  DB.raw.prepare("INSERT INTO users (id, points, created_at) VALUES (?, ?, ?)").run("apple:b", 100, "2026-06-01");
  if (activePlan) addPlan(DB, Date.now() + 86400000);
  return { DB, SESSION_SECRET, APPLE_AUDIENCE: BUNDLE_ID, OPENAI_API_KEY: "sk-test" };
}

function addPlan(DB, expiresAt) {
  DB.raw.prepare(
    "INSERT INTO subscriptions (original_transaction_id, user_id, product_id, plan, expires_at, environment, revoked, updated_at) VALUES (?, ?, ?, ?, ?, ?, 0, ?)"
  ).run("t1", "apple:a", "com.yuyaogawa6960.videomania.standard.month", "standard", expiresAt, "Production", "2026-06-01");
}

/** index.js と同じ形のセッショントークン(vm1.<中身>.<HMAC-SHA256>) */
async function sessionToken(userID, seconds = 3600) {
  const body = Buffer.from(JSON.stringify({ sub: userID, exp: Math.floor(Date.now() / 1000) + seconds })).toString("base64url");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(SESSION_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return "vm1." + body + "." + Buffer.from(signature).toString("base64url");
}

async function call(env, method, path, { body, user = "apple:a", token } = {}) {
  const headers = { authorization: "Bearer " + (token || (await sessionToken(user))) };
  let payload;
  if (body instanceof FormData) {
    payload = body;
  } else if (body !== undefined) {
    headers["content-type"] = "application/json";
    payload = JSON.stringify(body);
  }
  const response = await worker.fetch(new Request("https://videomania.test" + path, { method, headers, body: payload }), env);
  const text = await response.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch (_) {}
  return { status: response.status, body: json, headers: response.headers };
}

function row(env, id = "apple:a") {
  return { ...env.DB.raw.prepare("SELECT points, sub_points, transcribe_carry FROM users WHERE id = ?").get(id) };
}

// ---------------------------------------------------------------------
// 試用の返金
// ---------------------------------------------------------------------

test("試用は trialID を返し、1 回だけ返せる(プランの分はプランの分に戻る)", async () => {
  const env = setup({ points: 100, subPoints: 30 });
  const spent = await call(env, "POST", "/v1/points/feature", { body: { feature: "ai.fillerCut" } });
  assert.equal(spent.status, 200);
  assert.equal(spent.body.points, 50);
  assert.equal(typeof spent.body.trialID, "string");
  assert.deepEqual({ points: row(env).points, sub: row(env).sub_points }, { points: 50, sub: 0 });

  // ほかの人は返せない
  const other = await call(env, "POST", "/v1/points/feature/refund", { body: { trialID: spent.body.trialID }, user: "apple:b" });
  assert.equal(other.status, 404);

  const back = await call(env, "POST", "/v1/points/feature/refund", { body: { trialID: spent.body.trialID } });
  assert.equal(back.status, 200);
  assert.equal(back.body.refunded, 50);
  assert.deepEqual({ points: row(env).points, sub: row(env).sub_points }, { points: 100, sub: 30 });

  const again = await call(env, "POST", "/v1/points/feature/refund", { body: { trialID: spent.body.trialID } });
  assert.equal(again.body.refunded, 0);
  assert.equal(row(env).points, 100);
});

test("試用を返せるのは決まった時間のうちだけ", async () => {
  const env = setup();
  const spent = await call(env, "POST", "/v1/points/feature", { body: { feature: "motion.bgRemoval" } });
  env.DB.raw.prepare("UPDATE feature_trials SET created_at = ? WHERE id = ?").run(new Date(Date.now() - 7 * 3600 * 1000).toISOString(), spent.body.trialID);
  const late = await call(env, "POST", "/v1/points/feature/refund", { body: { trialID: spent.body.trialID } });
  assert.equal(late.status, 409);
  assert.equal(row(env).points, 50);
});

// ---------------------------------------------------------------------
// クラウド文字起こし
// ---------------------------------------------------------------------

/** moov → mvhd(version 0)に長さを書いた m4a のような中身 */
function fakeM4A(seconds, padding = 2000) {
  const timescale = 1000;
  const mvhd = Buffer.alloc(8 + 100);
  mvhd.writeUInt32BE(mvhd.length, 0);
  mvhd.write("mvhd", 4, "latin1");
  mvhd.writeUInt32BE(timescale, 8 + 12);
  mvhd.writeUInt32BE(Math.round(seconds * timescale), 8 + 16);
  const moov = Buffer.concat([Buffer.alloc(8), mvhd]);
  moov.writeUInt32BE(moov.length, 0);
  moov.write("moov", 4, "latin1");
  const ftyp = Buffer.alloc(16);
  ftyp.writeUInt32BE(16, 0);
  ftyp.write("ftypM4A ", 4, "latin1");
  const mdat = Buffer.alloc(8 + padding);
  mdat.writeUInt32BE(mdat.length, 0);
  mdat.write("mdat", 4, "latin1");
  return Buffer.concat([ftyp, mdat, moov]);
}

function transcribeForm(seconds, extra = {}) {
  const form = new FormData();
  form.append("model", "whisper-1");
  form.append("language", "ja");
  form.append("response_format", "text");
  form.append("timestamp_granularities[]", "word");
  form.append("n", "5");
  for (const [k, v] of Object.entries(extra)) form.append(k, v);
  form.append("file", new File([fakeM4A(seconds)], "audio.m4a", { type: "audio/m4a" }));
  return form;
}

/** OpenAI の文字起こしの代わり。返す duration は音声の長さどおり。送られた本文を sent に残す */
function mockTranscriptions(sent, { duration } = {}) {
  globalThis.fetch = async (url, init) => {
    assert.match(String(url), /\/v1\/audio\/transcriptions$/);
    const form = init.body;
    sent.push(form);
    const file = form.get("file");
    const bytes = new Uint8Array(await file.arrayBuffer());
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    // fakeM4A の mvhd の位置から長さを読む
    const seconds = duration ?? view.getUint32(bytes.length - 100 + 16) / 1000;
    return new Response(JSON.stringify({ text: "こんにちは", duration: seconds }), { status: 200, headers: { "content-type": "application/json" } });
  };
}

test("文字起こしは秒で数え、6 秒 × 10 本でも 1 分ぶん(10pt)だけ引く", async () => {
  const env = setup({ points: 100 });
  const sent = [];
  mockTranscriptions(sent);
  for (let i = 0; i < 10; i++) {
    const result = await call(env, "POST", "/v1/audio/transcriptions", { body: transcribeForm(6) });
    assert.equal(result.status, 200);
  }
  assert.equal(row(env).points, 90);
  assert.equal(row(env).transcribe_carry, 0);
});

test("4 秒 × 10 本(40 秒)は 6pt で、余りの 4 秒は次に持ち越す", async () => {
  const env = setup({ points: 100 });
  const sent = [];
  mockTranscriptions(sent);
  for (let i = 0; i < 10; i++) await call(env, "POST", "/v1/audio/transcriptions", { body: transcribeForm(4) });
  assert.equal(row(env).points, 94);
  assert.equal(row(env).transcribe_carry, 4);
});

test("OpenAI に渡す文字起こしの項目はサーバーで決める(whisper-1 は verbose_json、知らない項目は捨てる)", async () => {
  const env = setup({ points: 100 });
  const sent = [];
  mockTranscriptions(sent);
  await call(env, "POST", "/v1/audio/transcriptions", { body: transcribeForm(30, { temperature: "0" }) });
  const form = sent[0];
  assert.equal(form.get("response_format"), "verbose_json");
  assert.equal(form.get("model"), "whisper-1");
  assert.equal(form.get("language"), "ja");
  assert.equal(form.get("n"), null);
  assert.deepEqual(form.getAll("timestamp_granularities[]"), ["word"]);
  assert.equal(row(env).points, 95);
});

test("長さが返らないモデルでも、音声ファイルに書かれた長さで精算する", async () => {
  const env = setup({ points: 100 });
  globalThis.fetch = async () => new Response(JSON.stringify({ text: "hello" }), { status: 200 });
  const form = new FormData();
  form.append("model", "gpt-4o-transcribe");
  form.append("file", new File([fakeM4A(120)], "audio.m4a", { type: "audio/m4a" }));
  const result = await call(env, "POST", "/v1/audio/transcriptions", { body: form });
  assert.equal(result.status, 200);
  assert.equal(row(env).points, 80); // 2 分 = 20pt(ファイルの大きさだけなら 1pt になっていた)
});

test("ポイントが足りなければ 402 で、OpenAI には送らない", async () => {
  const env = setup({ points: 5 });
  let called = false;
  globalThis.fetch = async () => {
    called = true;
    return new Response("{}", { status: 200 });
  };
  const result = await call(env, "POST", "/v1/audio/transcriptions", { body: transcribeForm(120) });
  assert.equal(result.status, 402);
  assert.equal(called, false);
  assert.equal(row(env).points, 5);
});

// ---------------------------------------------------------------------
// チャット
// ---------------------------------------------------------------------

test("チャットは許可した項目だけを渡し、すべてのロールの文を確かめる", async () => {
  const env = setup({ points: 100 });
  let moderated = null;
  let payload = null;
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    if (String(url).endsWith("/v1/moderations")) {
      moderated = body.input;
      return new Response(JSON.stringify({ results: [{ flagged: false }] }), { status: 200 });
    }
    payload = body;
    return new Response(JSON.stringify({ choices: [{ message: { content: "{}" } }] }), { status: 200 });
  };
  const result = await call(env, "POST", "/v1/chat/completions", {
    body: {
      model: "gpt-4o", n: 128, max_tokens: "abc", tools: [{ type: "function" }], logprobs: true,
      temperature: 0.2, response_format: { type: "json_object" },
      messages: [{ role: "system", content: "SYSTEM-TEXT" }, { role: "user", content: [{ type: "text", text: "USER-TEXT" }] }],
    },
  });
  assert.equal(result.status, 200);
  assert.deepEqual(Object.keys(payload).sort(), ["max_tokens", "messages", "model", "n", "response_format", "stream", "temperature"]);
  assert.equal(payload.model, "gpt-4o-mini");
  assert.equal(payload.n, 1);
  assert.equal(payload.max_tokens, 4000);
  assert.deepEqual(payload.messages, [{ role: "system", content: "SYSTEM-TEXT" }, { role: "user", content: "USER-TEXT" }]);
  assert.ok(moderated.join("\n").includes("SYSTEM-TEXT"));
  assert.ok(moderated.join("\n").includes("USER-TEXT"));
  assert.equal(row(env).points, 80);
});

test("画像や知らないロールは受け付けず、ポイントも引かない", async () => {
  const env = setup({ points: 100 });
  globalThis.fetch = async () => new Response(JSON.stringify({ results: [] }), { status: 200 });
  for (const messages of [
    [{ role: "user", content: [{ type: "image_url", image_url: { url: "https://example.com/a.png" } }] }],
    [{ role: "tool", content: "x" }],
    [],
    [{ role: "user", content: "x".repeat(60001) }],
  ]) {
    const result = await call(env, "POST", "/v1/chat/completions", { body: { messages } });
    assert.equal(result.status, 400);
  }
  assert.equal(row(env).points, 100);
});

test("AI の失敗で返すポイントは、引いたときと同じくプランの分に戻る", async () => {
  const env = setup({ points: 100, subPoints: 50 });
  globalThis.fetch = async (url) => {
    if (String(url).endsWith("/v1/moderations")) return new Response(JSON.stringify({ results: [{ flagged: false }] }), { status: 200 });
    return new Response(JSON.stringify({ error: { message: "boom" } }), { status: 500 });
  };
  const result = await call(env, "POST", "/v1/chat/completions", { body: { messages: [{ role: "user", content: "hi" }] } });
  assert.equal(result.status, 500);
  assert.deepEqual({ points: row(env).points, sub: row(env).sub_points }, { points: 100, sub: 50 });
});

// ---------------------------------------------------------------------
// プランのポイントの期限切れ
// ---------------------------------------------------------------------

test("期限が切れて猶予も過ぎたプランのポイントは、使う前に消える(無料のポイントは残る)", async () => {
  const env = setup({ points: 130, subPoints: 100, activePlan: false });
  addPlan(env.DB, Date.now() - 29 * 86400000);
  globalThis.fetch = async () => new Response(JSON.stringify({ results: [{ flagged: false }] }), { status: 200 });
  const result = await call(env, "POST", "/v1/points/feature", { body: { feature: "ai.editCheck" } });
  assert.equal(result.status, 402); // 残り 30pt だけ
  assert.deepEqual({ points: row(env).points, sub: row(env).sub_points }, { points: 30, sub: 0 });
});

test("請求の猶予期間のうち(期限から 28 日以内)はプランのポイントを残す", async () => {
  const env = setup({ points: 130, subPoints: 100, activePlan: false });
  addPlan(env.DB, Date.now() - 3 * 86400000);
  const me = await call(env, "GET", "/v1/me");
  assert.equal(me.body.points, 130);
});

// ---------------------------------------------------------------------
// /v1/me
// ---------------------------------------------------------------------

test("/v1/me は期限が近いセッションに新しいトークンを返し、リワード広告の ID を返す", async () => {
  const env = setup();
  const near = await call(env, "GET", "/v1/me", { token: await sessionToken("apple:a", 3 * 86400) });
  assert.equal(near.status, 200);
  assert.match(near.body.token, /^vm1\./);
  assert.match(near.body.rewardID, /^[0-9a-f]{32}$/);
  assert.notEqual(near.body.rewardID, near.body.id);
  const mapped = env.DB.raw.prepare("SELECT user_id FROM reward_ids WHERE reward_id = ?").get(near.body.rewardID);
  assert.equal(mapped.user_id, "apple:a");
  // 新しいトークンでも使える
  const renewed = await call(env, "GET", "/v1/me", { token: near.body.token });
  assert.equal(renewed.status, 200);
  assert.equal(renewed.body.token, undefined);
  const far = await call(env, "GET", "/v1/me", { token: await sessionToken("apple:a", 20 * 86400) });
  assert.equal(far.body.token, undefined);
});

// ---------------------------------------------------------------------
// はじめてのボーナス
// ---------------------------------------------------------------------

const appleKeys = generateKeyPairSync("rsa", { modulusLength: 2048 });
const appleJWK = { ...appleKeys.publicKey.export({ format: "jwk" }), kid: "test-kid", alg: "RS256", use: "sig" };

function appleIdentityToken(sub) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const input = encode({ alg: "RS256", kid: "test-kid" }) + "." +
    encode({ iss: "https://appleid.apple.com", aud: BUNDLE_ID, sub, exp: Math.floor(Date.now() / 1000) + 600 });
  return input + "." + sign("sha256", Buffer.from(input), appleKeys.privateKey).toString("base64url");
}

async function signIn(env, sub) {
  globalThis.fetch = async (url) => {
    assert.equal(String(url), "https://appleid.apple.com/auth/keys");
    return new Response(JSON.stringify({ keys: [appleJWK] }), { status: 200 });
  };
  const response = await worker.fetch(new Request("https://videomania.test/v1/auth/apple", {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ identityToken: appleIdentityToken(sub) }),
  }), env);
  globalThis.fetch = realFetch;
  return { status: response.status, body: await response.json() };
}

test("アカウントを削除して作り直しても、はじめてのボーナスと同じ日の毎日ボーナスはもう一度付かない", async () => {
  const env = { DB: d1(), SESSION_SECRET, APPLE_AUDIENCE: BUNDLE_ID };
  const first = await signIn(env, "001");
  assert.equal(first.status, 200);
  assert.equal(first.body.points, 100);
  assert.equal(first.body.signupBonus, 100);
  const daily = await call(env, "POST", "/v1/points/daily", { body: {}, token: first.body.token });
  assert.equal(daily.body.points, 110);

  const deleted = await call(env, "DELETE", "/v1/me", { token: first.body.token });
  assert.equal(deleted.body.deleted, true);
  assert.equal(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM users").get().n, 0);
  // 残るのは元に戻せない印だけ(Apple の ID そのものは残さない)
  const marks = env.DB.raw.prepare("SELECT sub_hash FROM signup_grants").all();
  assert.equal(marks.length, 1);
  assert.ok(!marks[0].sub_hash.includes("001"));

  const again = await signIn(env, "001");
  assert.equal(again.status, 200);
  assert.equal(again.body.points, 0);
  assert.equal(again.body.signupBonus, 0);
  assert.equal(again.body.dailyAvailable, false);

  // ほかの人は今までどおり
  const other = await signIn(env, "002");
  assert.equal(other.body.points, 100);
});

// ---------------------------------------------------------------------
// 使い方の統計
// ---------------------------------------------------------------------

test("TikTok への投稿とカメラの「使う」を統計に残す", async () => {
  const env = setup();
  const response = await worker.fetch(new Request("https://videomania.test/v1/events", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({
      install: "0123abcd-0000-4000-8000-000000000000",
      events: [{ name: "tiktok_share_start" }, { name: "tiktok_share_done" }, { name: "camera_record_use" }, { name: "unknown_event" }],
    }),
  }), env);
  assert.equal((await response.json()).accepted, 3);
});

// /v1/points/feature(src/index.js)のテスト。無料プランで有料の機能を 1 回 50pt で使う:
//   - 決まった機能なら 50pt 引いて残高を返す(プランのポイントから先に減る)
//   - 足りなければ 402 insufficient_points で、残高は変わらない
//   - 知らない機能は 400 unknown_feature
// D1 の代わりに Node の SQLite(node:sqlite)を使う。
//   実行: cd server && node --test test/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";

const SESSION_SECRET = "test-session-secret";

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

function setup(points, subPoints = 0) {
  const DB = d1();
  DB.raw.prepare("INSERT INTO users (id, points, sub_points, created_at) VALUES (?, ?, ?, ?)").run("apple:a", points, subPoints, "2026-06-01");
  return { DB, SESSION_SECRET };
}

/** index.js と同じ形のセッショントークン(vm1.<中身>.<HMAC-SHA256>) */
async function sessionToken(userID) {
  const body = Buffer.from(JSON.stringify({ sub: userID, exp: Math.floor(Date.now() / 1000) + 3600 })).toString("base64url");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(SESSION_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return "vm1." + body + "." + Buffer.from(signature).toString("base64url");
}

async function spend(env, feature) {
  const headers = { "content-type": "application/json", authorization: "Bearer " + (await sessionToken("apple:a")) };
  const response = await worker.fetch(new Request("https://videomania.test/v1/points/feature", {
    method: "POST", headers, body: JSON.stringify({ feature }),
  }), env);
  return { status: response.status, body: await response.json() };
}

function row(env) {
  return env.DB.raw.prepare("SELECT points, sub_points FROM users WHERE id = ?").get("apple:a");
}

test("決まった機能は 50pt 引いて残高を返す(プランのポイントから先に減る)", async () => {
  const env = setup(100, 30);
  const result = await spend(env, "ai.fillerCut");
  assert.equal(result.status, 200);
  assert.equal(result.body.points, 50);
  assert.equal(result.body.spent, 50);
  assert.deepEqual({ ...row(env) }, { points: 50, sub_points: 0 });
  const ledger = env.DB.raw.prepare("SELECT delta, reason FROM ledger WHERE user_id = ?").all("apple:a");
  assert.deepEqual(ledger.map((l) => ({ ...l })), [{ delta: -50, reason: "feature:ai.fillerCut" }]);
});

test("足りなければ 402 で、残高は変わらない", async () => {
  const env = setup(49);
  const result = await spend(env, "motion.bgRemoval");
  assert.equal(result.status, 402);
  assert.equal(result.body.error.code, "insufficient_points");
  assert.equal(row(env).points, 49);
});

test("知らない機能・プランだけの機能は 400", async () => {
  const env = setup(100);
  for (const feature of ["edit.multicam", "color.lut", "", "ai.fillerCut "]) {
    const result = await spend(env, feature);
    assert.equal(result.status, 400);
    assert.equal(result.body.error.code, "unknown_feature");
  }
  assert.equal(row(env).points, 100);
});

// =====================================================================
// Video Mania のポイント・AI 中継サーバー(Cloudflare Workers + D1)
//
// - アプリは「Apple でサインイン」のトークンを送ってログインし、このサーバーが発行する
//   セッショントークン(30 日)を以後の Authorization: Bearer に使う
// - AI(OpenAI)はこのサーバーが代わりに呼ぶ。キーはサーバーにだけ置く(OPENAI_API_KEY)
// - 使う前に必要なポイントを確保し、実際に使った量で精算する。失敗したら戻す
// - パスは OpenAI と同じ(/v1/audio/transcriptions, /v1/chat/completions)にして、
//   アプリ側は宛先とトークンを差し替えるだけで使えるようにしている
// =====================================================================

const POINTS = {
  signup: 100,            // はじめてのサインイン
  daily: 20,              // 毎日ボーナス(日本時間で 1 日 1 回)
  transcribePerMinute: 5, // クラウド文字起こし 1 分
  chat: 2,                // 字幕の整え・翻訳・台本など 1 回
};

const OPENAI = "https://api.openai.com";
const ALLOWED_TRANSCRIBE_MODELS = ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-transcribe-diarize"];
const CHAT_MODEL = "gpt-4o-mini";
const MAX_CHAT_TOKENS = 4000;
const SESSION_DAYS = 30;

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      const path = url.pathname;
      if (request.method === "GET" && path === "/") return json({ ok: true, service: "videomania-api" });
      if (request.method === "POST" && path === "/v1/auth/apple") return await signInWithApple(request, env);

      // ここから先はログインが必要
      const user = await authenticate(request, env);
      if (!user) return error(401, "ログインの期限が切れました。アプリの設定から、もう一度サインインしてください。", "unauthorized");

      if (request.method === "GET" && path === "/v1/me") return await me(user, env);
      if (request.method === "POST" && path === "/v1/points/daily") return await daily(user, env);
      if (request.method === "POST" && path === "/v1/audio/transcriptions") return await transcribe(request, user, env);
      if (request.method === "POST" && path === "/v1/chat/completions") return await chat(request, user, env);
      return error(404, "見つかりません", "not_found");
    } catch (e) {
      return error(500, "サーバーでエラーが起きました: " + (e && e.message ? e.message : String(e)), "server_error");
    }
  },
};

// ---------------------------------------------------------------------
// 応答
// ---------------------------------------------------------------------

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

/** OpenAI と同じ形のエラー({ error: { message, code } })。アプリの既存のエラー表示がそのまま使える */
function error(status, message, code) {
  return json({ error: { message, code, type: "videomania" } }, status);
}

function nowISO() {
  return new Date().toISOString();
}

function todayJST() {
  const jst = new Date(Date.now() + 9 * 3600 * 1000);
  return jst.toISOString().slice(0, 10);
}

// ---------------------------------------------------------------------
// base64url / HMAC セッショントークン
// ---------------------------------------------------------------------

function b64urlEncode(bytes) {
  let s = "";
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  for (let i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(str) {
  const pad = str.length % 4 === 0 ? "" : "=".repeat(4 - (str.length % 4));
  const s = atob(str.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

async function hmacKey(secret) {
  return crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}

async function issueSession(userID, env) {
  const payload = { sub: userID, exp: Math.floor(Date.now() / 1000) + SESSION_DAYS * 86400 };
  const body = b64urlEncode(new TextEncoder().encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(env.SESSION_SECRET), new TextEncoder().encode(body));
  return "vm1." + body + "." + b64urlEncode(sig);
}

async function authenticate(request, env) {
  const header = request.headers.get("authorization") || "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== "vm1") return null;
  let signature;
  try {
    signature = b64urlDecode(parts[2]);
  } catch (_) {
    return null;
  }
  const ok = await crypto.subtle.verify(
    "HMAC",
    await hmacKey(env.SESSION_SECRET),
    signature,
    new TextEncoder().encode(parts[1])
  );
  if (!ok) return null;
  let payload;
  try {
    payload = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
  } catch (_) {
    return null;
  }
  if (!payload.sub || !payload.exp || payload.exp < Date.now() / 1000) return null;
  const row = await env.DB.prepare("SELECT id, points, last_daily FROM users WHERE id = ?").bind(payload.sub).first();
  return row || null;
}

// ---------------------------------------------------------------------
// Apple でサインイン(identityToken の署名・発行元・宛先・期限を確かめる)
// ---------------------------------------------------------------------

let appleKeysCache = null;
let appleKeysFetchedAt = 0;

async function appleKeys() {
  if (appleKeysCache && Date.now() - appleKeysFetchedAt < 3600 * 1000) return appleKeysCache;
  const res = await fetch("https://appleid.apple.com/auth/keys");
  if (!res.ok) throw new Error("Apple の公開鍵を取得できませんでした");
  appleKeysCache = (await res.json()).keys || [];
  appleKeysFetchedAt = Date.now();
  return appleKeysCache;
}

async function verifyAppleToken(idToken, audience) {
  const parts = (idToken || "").split(".");
  if (parts.length !== 3) return null;
  let header, payload;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
    payload = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
  } catch (_) {
    return null;
  }
  const jwk = (await appleKeys()).find((k) => k.kid === header.kid);
  if (!jwk || header.alg !== "RS256") return null;
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    b64urlDecode(parts[2]),
    new TextEncoder().encode(parts[0] + "." + parts[1])
  );
  if (!ok) return null;
  if (payload.iss !== "https://appleid.apple.com") return null;
  if (payload.aud !== audience) return null;
  if (!payload.exp || payload.exp < Date.now() / 1000) return null;
  if (!payload.sub) return null;
  return payload;
}

async function signInWithApple(request, env) {
  const body = await request.json().catch(() => ({}));
  const claims = await verifyAppleToken(body.identityToken, env.APPLE_AUDIENCE);
  if (!claims) return error(401, "Apple でのサインインを確認できませんでした。もう一度お試しください。", "invalid_apple_token");

  const userID = "apple:" + claims.sub;
  let user = await env.DB.prepare("SELECT id, points, last_daily FROM users WHERE id = ?").bind(userID).first();
  let isNew = false;
  if (!user) {
    isNew = true;
    await env.DB.batch([
      env.DB.prepare("INSERT INTO users (id, points, created_at) VALUES (?, ?, ?)").bind(userID, POINTS.signup, nowISO()),
      env.DB.prepare("INSERT INTO ledger (user_id, delta, reason, created_at) VALUES (?, ?, ?, ?)").bind(
        userID,
        POINTS.signup,
        "signup",
        nowISO()
      ),
    ]);
    user = { id: userID, points: POINTS.signup, last_daily: null };
  }
  const token = await issueSession(userID, env);
  return json({ token, points: user.points, isNew, dailyAvailable: user.last_daily !== todayJST() });
}

// ---------------------------------------------------------------------
// ポイント
// ---------------------------------------------------------------------

async function me(user, env) {
  return json({ points: user.points, dailyAvailable: user.last_daily !== todayJST(), prices: POINTS });
}

async function daily(user, env) {
  const today = todayJST();
  const result = await env.DB.prepare(
    "UPDATE users SET points = points + ?, last_daily = ? WHERE id = ? AND (last_daily IS NULL OR last_daily <> ?)"
  )
    .bind(POINTS.daily, today, user.id, today)
    .run();
  if (!result.meta || result.meta.changes === 0) {
    return error(409, "今日のボーナスは受け取り済みです。また明日どうぞ。", "already_claimed");
  }
  await addLedger(env, user.id, POINTS.daily, "daily");
  const row = await env.DB.prepare("SELECT points FROM users WHERE id = ?").bind(user.id).first();
  return json({ points: row.points, added: POINTS.daily });
}

async function addLedger(env, userID, delta, reason) {
  await env.DB.prepare("INSERT INTO ledger (user_id, delta, reason, created_at) VALUES (?, ?, ?, ?)")
    .bind(userID, delta, reason, nowISO())
    .run();
}

/** 足りていれば amount を引いて true(同時に使われても残高がマイナスにならない) */
async function reserve(env, userID, amount, reason) {
  const result = await env.DB.prepare("UPDATE users SET points = points - ? WHERE id = ? AND points >= ?")
    .bind(amount, userID, amount)
    .run();
  if (!result.meta || result.meta.changes === 0) return false;
  await addLedger(env, userID, -amount, reason);
  return true;
}

async function refund(env, userID, amount, reason) {
  if (amount <= 0) return;
  await env.DB.prepare("UPDATE users SET points = points + ? WHERE id = ?").bind(amount, userID).run();
  await addLedger(env, userID, amount, reason);
}

/** 追加で引く(残高が足りない分は 0 で止める) */
async function chargeExtra(env, userID, amount, reason) {
  if (amount <= 0) return;
  await env.DB.prepare("UPDATE users SET points = MAX(points - ?, 0) WHERE id = ?").bind(amount, userID).run();
  await addLedger(env, userID, -amount, reason);
}

async function balance(env, userID) {
  const row = await env.DB.prepare("SELECT points FROM users WHERE id = ?").bind(userID).first();
  return row ? row.points : 0;
}

/** サーバーの OpenAI キーが使えないとき(利用者のログインの問題ではないので 401 にしない) */
function upstreamAuthError() {
  return error(502, "AI のサービスの設定に問題があります(サーバー側)。ポイントは戻しました。時間をおいてお試しください。", "upstream_auth");
}

function insufficient(need, have) {
  return error(
    402,
    `ポイントが足りません(必要: ${need} ポイント、残り: ${have} ポイント)。毎日ボーナスを受け取るか、自分の OpenAI キーを使ってください。`,
    "insufficient_points"
  );
}

// ---------------------------------------------------------------------
// AI 中継
// ---------------------------------------------------------------------

async function transcribe(request, user, env) {
  const contentType = request.headers.get("content-type") || "";
  if (!contentType.includes("multipart/form-data")) return error(400, "形式が正しくありません", "bad_request");
  const bodyBytes = await request.arrayBuffer();
  if (bodyBytes.byteLength > 26 * 1024 * 1024) return error(413, "音声が大きすぎます(25MB まで)", "too_large");

  // 使う前の見積もり: アプリが伝える秒数と、ファイルの大きさ(256kbps として)の大きいほう
  const claimed = Math.max(0, Number(request.headers.get("x-vm-seconds") || 0));
  const fromBytes = bodyBytes.byteLength / 32000;
  const estimateSeconds = Math.max(claimed, fromBytes, 1);
  const estimate = Math.max(1, Math.ceil(estimateSeconds / 60)) * POINTS.transcribePerMinute;
  if (!(await reserve(env, user.id, estimate, "transcribe:reserve"))) {
    return insufficient(estimate, await balance(env, user.id));
  }

  // モデルを確かめる(許可したものだけ)
  const form = await new Request("https://local/", { method: "POST", headers: { "content-type": contentType }, body: bodyBytes })
    .formData()
    .catch(() => null);
  const model = form ? String(form.get("model") || "") : "";
  if (!ALLOWED_TRANSCRIBE_MODELS.includes(model)) {
    await refund(env, user.id, estimate, "transcribe:refund");
    return error(400, "このモデルは使えません: " + model, "bad_model");
  }

  let upstream;
  try {
    upstream = await fetch(OPENAI + "/v1/audio/transcriptions", {
      method: "POST",
      headers: { authorization: "Bearer " + env.OPENAI_API_KEY, "content-type": contentType },
      body: bodyBytes,
    });
  } catch (e) {
    await refund(env, user.id, estimate, "transcribe:refund");
    return error(502, "文字起こしのサービスにつながりませんでした", "upstream_unreachable");
  }
  const text = await upstream.text();
  if (!upstream.ok) {
    await refund(env, user.id, estimate, "transcribe:refund");
    if (upstream.status === 401 || upstream.status === 403) return upstreamAuthError();
    return new Response(text, { status: upstream.status, headers: { "content-type": upstream.headers.get("content-type") || "application/json" } });
  }

  // 実際の長さ(verbose_json の duration)で精算する
  let actual = estimate;
  try {
    const parsed = JSON.parse(text);
    if (typeof parsed.duration === "number" && parsed.duration > 0) {
      actual = Math.max(1, Math.ceil(parsed.duration / 60)) * POINTS.transcribePerMinute;
    }
  } catch (_) {}
  if (actual < estimate) await refund(env, user.id, estimate - actual, "transcribe:settle");
  if (actual > estimate) await chargeExtra(env, user.id, actual - estimate, "transcribe:settle");

  return new Response(text, {
    status: 200,
    headers: { "content-type": "application/json; charset=utf-8", "x-vm-points": String(await balance(env, user.id)) },
  });
}

async function chat(request, user, env) {
  const body = await request.json().catch(() => null);
  if (!body || !Array.isArray(body.messages)) return error(400, "形式が正しくありません", "bad_request");
  // モデルと長さはサーバーで決める(高いモデルを使われないように)
  body.model = CHAT_MODEL;
  const asked = Number(body.max_tokens || body.max_completion_tokens || MAX_CHAT_TOKENS);
  delete body.max_completion_tokens;
  body.max_tokens = Math.min(Math.max(1, asked), MAX_CHAT_TOKENS);
  body.stream = false;

  if (!(await reserve(env, user.id, POINTS.chat, "chat"))) {
    return insufficient(POINTS.chat, await balance(env, user.id));
  }
  let upstream;
  try {
    upstream = await fetch(OPENAI + "/v1/chat/completions", {
      method: "POST",
      headers: { authorization: "Bearer " + env.OPENAI_API_KEY, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (e) {
    await refund(env, user.id, POINTS.chat, "chat:refund");
    return error(502, "AI のサービスにつながりませんでした", "upstream_unreachable");
  }
  const text = await upstream.text();
  if (!upstream.ok) {
    await refund(env, user.id, POINTS.chat, "chat:refund");
    if (upstream.status === 401 || upstream.status === 403) return upstreamAuthError();
  }
  return new Response(text, {
    status: upstream.status,
    headers: { "content-type": "application/json; charset=utf-8", "x-vm-points": String(await balance(env, user.id)) },
  });
}

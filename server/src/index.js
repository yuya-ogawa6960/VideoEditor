// =====================================================================
// Video Mania のポイント・AI 中継サーバー(Cloudflare Workers + D1)
//
// - アプリは「Apple でサインイン」のトークンを送ってログインし、このサーバーが発行する
//   セッショントークン(30 日)を以後の Authorization: Bearer に使う
// - AI(OpenAI)はこのサーバーが代わりに呼ぶ。キーはサーバーにだけ置く(OPENAI_API_KEY)
// - 使う前に必要なポイントを確保し、実際に使った量で精算する。失敗したら戻す
// - パスは OpenAI と同じ(/v1/audio/transcriptions, /v1/chat/completions, /v1/audio/speech)にして、
//   アプリ側は宛先とトークンを差し替えるだけで使えるようにしている
// =====================================================================

const POINTS = {
  signup: 100,            // はじめてのサインイン
  daily: 20,              // 毎日ボーナス(日本時間で 1 日 1 回)
  transcribePerMinute: 5, // クラウド文字起こし 1 分
  chat: 2,                // 字幕の整え・翻訳・台本など 1 回
  speechPerThousandChars: 3, // クラウドの声(読み上げ)1000 文字あたり
  adReward: 10,           // リワード広告 1 回
  adRewardDailyLimit: 5,  // リワード広告の 1 日の上限(日本時間)
};
const SPEECH_MODEL = "gpt-4o-mini-tts";
const SPEECH_VOICES = ["alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer", "verse"];
const MAX_SPEECH_CHARS = 4000;

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
      if (request.method === "GET" && path === "/privacy") return html(PRIVACY_HTML);
      if (request.method === "POST" && path === "/v1/events") return await ingestEvents(request, env);
      if (request.method === "GET" && path === "/stats") return await stats(url, env);
      if (request.method === "GET" && path === "/support") return html(SUPPORT_HTML);
      if (request.method === "POST" && path === "/v1/auth/apple") return await signInWithApple(request, env);
      // AdMob のサーバー側検証(ログイン不要。署名で確かめる)
      if (request.method === "GET" && path === "/v1/ads/ssv") return await admobSSV(url, env);

      // ここから先はログインが必要
      const user = await authenticate(request, env);
      if (!user) return error(401, "ログインの期限が切れました。アプリの設定から、もう一度サインインしてください。", "unauthorized");

      if (request.method === "GET" && path === "/v1/me") return await me(user, env);
      if (request.method === "DELETE" && path === "/v1/me") return await deleteAccount(user, env);
      if (request.method === "POST" && path === "/v1/points/daily") return await daily(user, env);
      if (request.method === "POST" && path === "/v1/audio/transcriptions") return await transcribe(request, user, env);
      if (request.method === "POST" && path === "/v1/chat/completions") return await chat(request, user, env);
      if (request.method === "POST" && path === "/v1/audio/speech") return await speech(request, user, env);
      if (request.method === "POST" && path === "/v1/ads/claim") return await adClaim(request, user, env);
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
  return json({
    id: user.id,
    points: user.points,
    dailyAvailable: user.last_daily !== todayJST(),
    prices: POINTS,
    ...(await adState(env, user.id)),
  });
}

// ---------------------------------------------------------------------
// リワード広告
// ---------------------------------------------------------------------

async function adState(env, userID) {
  const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM ad_rewards WHERE user_id = ? AND day = ?")
    .bind(userID, todayJST())
    .first();
  return { adRewardsToday: row ? row.n : 0, adRewardLimit: POINTS.adRewardDailyLimit, adRewardPoints: POINTS.adReward };
}

/** 1 回分を付与(同じ transaction_id は 1 回だけ・1 日の上限まで)。付与したら true */
async function grantAdReward(env, userID, transactionID, source) {
  const exists = await env.DB.prepare("SELECT id FROM users WHERE id = ?").bind(userID).first();
  if (!exists) return false;
  const state = await adState(env, userID);
  if (state.adRewardsToday >= POINTS.adRewardDailyLimit) return false;
  const inserted = await env.DB.prepare(
    "INSERT OR IGNORE INTO ad_rewards (transaction_id, user_id, amount, day, source, created_at) VALUES (?, ?, ?, ?, ?, ?)"
  )
    .bind(transactionID, userID, POINTS.adReward, todayJST(), source, nowISO())
    .run();
  if (!inserted.meta || inserted.meta.changes === 0) return false;
  await env.DB.prepare("UPDATE users SET points = points + ? WHERE id = ?").bind(POINTS.adReward, userID).run();
  await addLedger(env, userID, POINTS.adReward, "ad:" + source);
  return true;
}

/** アプリが「最後まで見た」と伝える。テスト期間(ALLOW_CLIENT_AD_CLAIM=1)だけここで付与し、本番は SSV を待つ */
async function adClaim(request, user, env) {
  // TestFlight のテスト広告は SSV が来ないので、その場合だけアプリの申告で足す(1 日の上限あり)
  const clientGrant = env.ALLOW_CLIENT_AD_CLAIM === "1" || request.headers.get("x-vm-test-build") === "1";
  let granted = false;
  if (clientGrant) {
    granted = await grantAdReward(env, user.id, "client:" + crypto.randomUUID(), "client");
  }
  return json({
    points: await balance(env, user.id),
    granted,
    pending: !clientGrant,
    ...(await adState(env, user.id)),
  });
}

// ---------------------------------------------------------------------
// 使い方の統計(匿名)
// ---------------------------------------------------------------------

const MAX_EVENTS_PER_POST = 100;
const ALLOWED_EVENT_NAMES = new Set([
  "app_open", "app_close", "project_create", "project_open", "panel", "sheet", "analysis",
  "export_start", "export_done", "export_failed", "export_cancelled",
]);

async function ingestEvents(request, env) {
  const body = await request.json().catch(() => null);
  if (!body || typeof body.install !== "string" || !Array.isArray(body.events)) return error(400, "形式が正しくありません", "bad_request");
  const install = body.install.slice(0, 64);
  if (!/^[0-9a-f-]{8,64}$/.test(install)) return error(400, "形式が正しくありません", "bad_request");
  const events = body.events.slice(0, MAX_EVENTS_PER_POST);
  const meta = {
    app: String(body.app || "").slice(0, 32),
    build: String(body.build || "").slice(0, 16),
    os: String(body.os || "").slice(0, 32),
    device: String(body.device || "").slice(0, 32),
    locale: String(body.locale || "").slice(0, 16),
  };
  const now = nowISO();
  const statements = [];
  for (const e of events) {
    if (!e || typeof e.name !== "string" || !ALLOWED_EVENT_NAMES.has(e.name)) continue;
    const params = {};
    if (e.params && typeof e.params === "object") {
      for (const [k, v] of Object.entries(e.params).slice(0, 12)) {
        params[String(k).slice(0, 32)] = String(v).slice(0, 80);
      }
    }
    statements.push(
      env.DB.prepare(
        "INSERT INTO events (install_id, name, params, app_version, os_version, device, locale, client_time, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
      ).bind(install, e.name, JSON.stringify(params), meta.app + " (" + meta.build + ")", meta.os, meta.device, meta.locale,
             String(e.t || "").slice(0, 32), now)
    );
  }
  if (statements.length) await env.DB.batch(statements);
  return json({ accepted: statements.length });
}

/** 集計ページ(?token=STATS_TOKEN)。GitHub の secret STATS_TOKEN を設定すると開ける */
async function stats(url, env) {
  const token = url.searchParams.get("token") || "";
  if (!env.STATS_TOKEN || token !== env.STATS_TOKEN) return error(403, "token が必要です", "forbidden");
  const days = Math.min(90, Math.max(1, Number(url.searchParams.get("days") || 30)));
  const since = new Date(Date.now() - days * 86400 * 1000).toISOString();

  const q = async (sql, ...binds) => (await env.DB.prepare(sql).bind(...binds).all()).results || [];
  const daily = await q(
    "SELECT substr(created_at, 1, 10) AS day, COUNT(DISTINCT install_id) AS installs, COUNT(*) AS events FROM events WHERE created_at >= ? GROUP BY day ORDER BY day DESC",
    since
  );
  const totals = await q("SELECT COUNT(DISTINCT install_id) AS installs, COUNT(*) AS events FROM events WHERE created_at >= ?", since);
  const names = await q(
    "SELECT name, COUNT(*) AS n, COUNT(DISTINCT install_id) AS installs FROM events WHERE created_at >= ? GROUP BY name ORDER BY n DESC",
    since
  );
  const panels = await q(
    "SELECT json_extract(params, '$.name') AS name, COUNT(*) AS n, COUNT(DISTINCT install_id) AS installs FROM events WHERE created_at >= ? AND name IN ('panel','sheet','analysis') GROUP BY name ORDER BY n DESC LIMIT 60",
    since
  );
  const exportsRows = await q(
    "SELECT name, json_extract(params, '$.length') AS length, COUNT(*) AS n FROM events WHERE created_at >= ? AND name IN ('export_done','export_failed','export_cancelled') GROUP BY name, length ORDER BY name, n DESC",
    since
  );
  const failed = await q(
    "SELECT json_extract(params, '$.kind') AS kind, COUNT(*) AS n FROM events WHERE created_at >= ? AND name = 'export_failed' GROUP BY kind ORDER BY n DESC",
    since
  );
  const versions = await q(
    "SELECT app_version, os_version, COUNT(DISTINCT install_id) AS installs FROM events WHERE created_at >= ? GROUP BY app_version, os_version ORDER BY installs DESC LIMIT 20",
    since
  );
  const esc = (v) => String(v == null ? "" : v).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const table = (rows, cols) =>
    rows.length
      ? "<table><tr>" + cols.map((c) => "<th>" + esc(c) + "</th>").join("") + "</tr>" +
        rows.map((r) => "<tr>" + cols.map((c) => "<td>" + esc(r[c]) + "</td>").join("") + "</tr>").join("") + "</table>"
      : "<p>(なし)</p>";
  const t = totals[0] || { installs: 0, events: 0 };
  const page = `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>Video Mania 利用状況</title>${PAGE_STYLE}
<style>table{border-collapse:collapse;margin:8px 0 20px;font-size:14px}th,td{border:1px solid #8884;padding:4px 10px;text-align:left}th{background:#8882}</style></head><body>
<h1>Video Mania 利用状況(直近 ${days} 日)</h1>
<p>期間: <a href="?token=${esc(token)}&days=7">7 日</a> / <a href="?token=${esc(token)}&days=30">30 日</a> / <a href="?token=${esc(token)}&days=90">90 日</a></p>
<p>利用端末 <b>${t.installs}</b> 台・出来事 <b>${t.events}</b> 件</p>
<h2>日ごとの利用端末</h2>${table(daily, ["day", "installs", "events"])}
<h2>出来事の種類</h2>${table(names, ["name", "n", "installs"])}
<h2>よく使われる機能(パネル・画面・AI)</h2>${table(panels, ["name", "n", "installs"])}
<h2>書き出し(長さ別)</h2>${table(exportsRows, ["name", "length", "n"])}
<h2>書き出しの失敗の種類</h2>${table(failed, ["kind", "n"])}
<h2>バージョン・OS</h2>${table(versions, ["app_version", "os_version", "installs"])}
</body></html>`;
  return html(page);
}

/** アカウントの削除(ポイント・台帳・広告の記録をすべて消す) */
async function deleteAccount(user, env) {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM ad_rewards WHERE user_id = ?").bind(user.id),
    env.DB.prepare("DELETE FROM ledger WHERE user_id = ?").bind(user.id),
    env.DB.prepare("DELETE FROM users WHERE id = ?").bind(user.id),
  ]);
  return json({ deleted: true });
}

function html(body) {
  return new Response(body, { status: 200, headers: { "content-type": "text/html; charset=utf-8" } });
}

const PAGE_STYLE = `<meta name="viewport" content="width=device-width, initial-scale=1"><style>body{font-family:-apple-system,system-ui,sans-serif;max-width:720px;margin:0 auto;padding:24px 16px;line-height:1.7;color:#222;background:#fff}h1{font-size:1.5em}h2{font-size:1.15em;margin-top:1.6em}@media (prefers-color-scheme: dark){body{color:#eee;background:#111}a{color:#8cf}}</style>`;

const PRIVACY_HTML = `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>Video Mania プライバシーポリシー</title>${PAGE_STYLE}</head><body>
<h1>Video Mania プライバシーポリシー</h1>
<p>最終更新日: 2026年10月22日</p>
<h2>1. 動画・写真</h2>
<p>編集する動画・写真・プロジェクトは、お使いの iPhone の中だけで処理・保存されます。開発者のサーバーに送られることはありません。</p>
<h2>2. クラウド AI を使う場合</h2>
<p>「クラウド AI」を選んだときだけ、文字起こしのための音声、字幕の整え・翻訳・台本作成のための文章、読み上げのための文章が OpenAI, L.L.C. に送られます(ポイントを使う場合は開発者のサーバーを経由し、内容は保存しません)。端末内 AI(Apple 音声認識・Apple Intelligence・Whisper)を選んだ場合は送信されません。</p>
<h2>3. アカウントとポイント</h2>
<p>Apple でサインインすると、Apple が発行する利用者ごとの識別子と、ポイントの残高・増減の記録を開発者のサーバー(Cloudflare)に保存します。氏名やメールアドレスは受け取りません。アプリの「文字起こしの方式」画面の「アカウントを削除」から、いつでも削除できます。</p>
<h2>4. 使い方の統計</h2>
<p>どの機能がどれだけ使われているかを、端末ごとのランダムな ID(アプリを削除すると変わります)で開発者のサーバーに送り、改善に役立てます。動画・文章・氏名は送りません。アプリの「文字起こしの方式」画面の「プライバシー」でいつでもオフにできます。</p>
<h2>5. 広告</h2>
<p>アプリは Google AdMob の広告を表示します。AdMob は広告の配信・測定のために、端末の広告識別子(許可した場合)やおおよその位置などを利用することがあります。詳しくは <a href="https://policies.google.com/technologies/ads?hl=ja">Google のポリシー</a>をご覧ください。トラッキングは iPhone の設定でいつでも許可を取り消せます。</p>
<h2>6. Google フォトからの取り込み</h2>
<p>「Google フォト」から追加する機能では、Google でログインし、Google フォト Picker API を使います。アプリが受け取るのは、あなたが Google フォトの選択画面で選んだ写真・動画(とそのファイル名・種類などの情報)だけです。ライブラリ全体やアルバム、ほかの写真・動画を見ることはありません。</p>
<p>選んだ写真・動画は Google から直接お使いの iPhone にダウンロードされ、編集のためだけに使われます。開発者のサーバーや第三者に送ることはなく、広告や AI の学習にも使いません(ただし、取り込んだ動画であなた自身が「クラウド AI」の文字起こしなどを選んだときは、その音声だけが 2. のとおり送られます)。Google のログインの情報(トークン)はお使いの iPhone の中(キーチェーン)にだけ保存され、開発者のサーバーには送られません。</p>
<p>アプリの「ログアウト」で接続をやめられます。Google 側の許可は、Google アカウント →「セキュリティ」→「サードパーティ製のアプリとサービスへのアクセス」(<a href="https://myaccount.google.com/connections">myaccount.google.com/connections</a>)から Video Mania を選んで、いつでも取り消せます。</p>
<p>Video Mania が Google API から受け取った情報の使用および他のアプリへの転送は、限定的な使用(Limited Use)の要件を含む <a href="https://developers.google.com/terms/api-services-user-data-policy">Google API サービスのユーザーデータに関するポリシー</a>に準拠します。</p>
<h2>7. 第三者への提供</h2>
<p>上記のほか、法令に基づく場合を除き、個人情報を第三者に提供しません。</p>
<h2>8. お問い合わせ</h2>
<p><a href="/support">サポートページ</a>をご覧ください。</p>
<hr>
<h1>Privacy Policy (English)</h1>
<p>Your videos, photos and projects are processed and stored only on your iPhone. When you choose Cloud AI, audio (for transcription) and text (for caption cleanup, translation, scripts and speech) are sent to OpenAI; with points, requests pass through our server without being stored. If you sign in with Apple, we store an Apple-issued user identifier and your points history on our server (Cloudflare); we never receive your name or email. You can delete your account in the app at any time. The app shows Google AdMob ads, which may use your advertising identifier (if you allow tracking) and approximate location. Anonymous usage statistics (which features are used, keyed by a random per-install ID) are sent to our server to improve the app; you can turn this off in the app. We do not share personal data with third parties except as required by law.</p>
<h2>Google Photos</h2>
<p>When you add media from Google Photos, you sign in with Google and the app uses the Google Photos Picker API. The app only receives the photos and videos you select in the Google Photos picker (and their file name and type); it cannot see the rest of your library or your albums. The selected items are downloaded directly from Google to your iPhone and used only for editing there. They are never sent to our server or to any third party, and are not used for advertising or AI training (the only exception: if you yourself choose a Cloud AI feature such as cloud transcription for an imported video, only its audio is sent as described above). Your Google sign-in tokens are stored only on your iPhone (in the Keychain) and are never sent to our server. You can disconnect with "Log out" in the app, and revoke access at any time in your Google Account under Security &rarr; Third-party apps &amp; services (<a href="https://myaccount.google.com/connections">myaccount.google.com/connections</a>).</p>
<p>Video Mania's use and transfer to any other app of information received from Google APIs will adhere to <a href="https://developers.google.com/terms/api-services-user-data-policy#additional_requirements_for_specific_api_scopes">Google API Services User Data Policy</a>, including the Limited Use requirements.</p>
</body></html>`;

const SUPPORT_HTML = `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>Video Mania サポート</title>${PAGE_STYLE}</head><body>
<h1>Video Mania サポート</h1>
<h2>よくある質問</h2>
<p><b>書き出しが途中で止まる</b><br>iPhone の空き容量を確認し、書き出し中はアプリを開いたままにするか、iOS 26 以降ではロック画面の表示を止めずにお待ちください。</p>
<p><b>字幕が作れない</b><br>「設定」→「Video Mania」で「音声認識」を許可してください。BGM だけの動画では字幕は作られません。</p>
<p><b>ポイントについて</b><br>はじめてのサインインで 100 ポイント、毎日 20 ポイント、広告を見て 1 日 5 回まで 10 ポイントずつもらえます。</p>
<p><b>アカウントの削除</b><br>アプリの「文字起こしの方式」画面の「アカウントを削除」から行えます。</p>
<h2>お問い合わせ</h2>
<p>アプリ内の TestFlight / App Store のフィードバック、または App Store のアプリページの「デベロッパの Web サイト」からご連絡ください。</p>
<p><a href="/privacy">プライバシーポリシー</a></p>
</body></html>`;

/** AdMob のサーバー側検証のコールバック。署名(ECDSA P-256 / SHA-256)を Google の公開鍵で確かめてから付与 */
async function admobSSV(url, env) {
  const query = url.search.startsWith("?") ? url.search.slice(1) : url.search;
  const at = query.indexOf("&signature=");
  // AdMob の画面で URL を登録したときの確認(パラメータなし)には 200 を返す
  if (at < 0) return json({ ok: true });
  const message = query.slice(0, at);
  const params = url.searchParams;
  const signature = params.get("signature") || "";
  const keyID = params.get("key_id") || "";
  const verified = await verifyAdMobSignature(message, signature, keyID).catch(() => false);
  if (!verified) return error(403, "署名が正しくありません", "bad_signature");

  const userID = params.get("user_id") || "";
  const transactionID = params.get("transaction_id") || "";
  if (!userID || !transactionID) return json({ ok: true, granted: false });
  const granted = await grantAdReward(env, userID, "ssv:" + transactionID, "ssv");
  return json({ ok: true, granted });
}

async function verifyAdMobSignature(message, signatureB64url, keyID) {
  const response = await fetch("https://www.gstatic.com/admob/reward/verifier-keys.json", { cf: { cacheTtl: 3600 } });
  const body = await response.json();
  const entry = (body.keys || []).find((k) => String(k.keyId) === String(keyID));
  if (!entry) return false;
  const spki = b64urlDecode(entry.base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""));
  const key = await crypto.subtle.importKey("spki", spki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const raw = derToRawSignature(b64urlDecode(signatureB64url));
  if (!raw) return false;
  return crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, new TextEncoder().encode(message));
}

/** DER(SEQUENCE { INTEGER r, INTEGER s })→ WebCrypto の r||s(各 32 バイト) */
function derToRawSignature(der) {
  if (der.length < 8 || der[0] !== 0x30) return null;
  let i = 2;
  if (der[1] & 0x80) i = 2 + (der[1] & 0x7f);
  const readInt = () => {
    if (der[i] !== 0x02) return null;
    const len = der[i + 1];
    let bytes = der.slice(i + 2, i + 2 + len);
    i += 2 + len;
    while (bytes.length > 32 && bytes[0] === 0) bytes = bytes.slice(1);
    if (bytes.length > 32) return null;
    const out = new Uint8Array(32);
    out.set(bytes, 32 - bytes.length);
    return out;
  };
  const r = readInt();
  const s = readInt();
  if (!r || !s) return null;
  const raw = new Uint8Array(64);
  raw.set(r, 0);
  raw.set(s, 32);
  return raw;
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

// クラウドの声(読み上げ)。本文: { input, voice, speed?, instructions? }。音声(mp3)をそのまま返す
async function speech(request, user, env) {
  const body = await request.json().catch(() => null);
  if (!body || typeof body.input !== "string") return error(400, "形式が正しくありません", "bad_request");
  const input = body.input.trim();
  if (!input) return error(400, "読み上げる文章が空です", "bad_request");
  if (input.length > MAX_SPEECH_CHARS) return error(413, "文章が長すぎます(" + MAX_SPEECH_CHARS + " 文字まで)", "too_large");
  const voice = SPEECH_VOICES.includes(body.voice) ? body.voice : "alloy";
  const speed = Math.min(4, Math.max(0.25, Number(body.speed || 1)));
  const payload = { model: SPEECH_MODEL, input, voice, speed, response_format: "mp3" };
  if (typeof body.instructions === "string" && body.instructions.trim()) payload.instructions = body.instructions.trim().slice(0, 400);

  const cost = Math.max(1, Math.ceil(input.length / 1000)) * POINTS.speechPerThousandChars;
  if (!(await reserve(env, user.id, cost, "speech"))) {
    return insufficient(cost, await balance(env, user.id));
  }
  let upstream;
  try {
    upstream = await fetch(OPENAI + "/v1/audio/speech", {
      method: "POST",
      headers: { authorization: "Bearer " + env.OPENAI_API_KEY, "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    await refund(env, user.id, cost, "speech:refund");
    return error(502, "読み上げのサービスにつながりませんでした", "upstream_unreachable");
  }
  if (!upstream.ok) {
    await refund(env, user.id, cost, "speech:refund");
    if (upstream.status === 401 || upstream.status === 403) return upstreamAuthError();
    const text = await upstream.text();
    return new Response(text, { status: upstream.status, headers: { "content-type": upstream.headers.get("content-type") || "application/json" } });
  }
  const audio = await upstream.arrayBuffer();
  return new Response(audio, {
    status: 200,
    headers: { "content-type": "audio/mpeg", "x-vm-points": String(await balance(env, user.id)) },
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

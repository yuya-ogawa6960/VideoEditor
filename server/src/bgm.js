// =====================================================================
// BGM の配信(ログイン不要)。曲は R2 のバケット videomania-bgm(バインディング BGM)に置く:
//   catalog.json      … 曲の一覧(アプリが最初に読む)。tools/bgm/make_catalog.py が作る
//   files/<id>.mp3    … 曲そのもの。アプリは試聴でストリーミング再生し、「ダウンロード」で端末に保存する
// 試聴(AVPlayer)は Range で少しずつ読むので、206 Partial Content に対応する。
// バケットがまだ無い(BGM が未設定)ときは、GitHub のリリース(bgm-v1)に置いた同じファイルを取ってきて返す
// (リポジトリは公開。catalog.json と <id>_1.mp3 をリリースの添付ファイルにする)。どちらも無ければ 404 / 503。
// =====================================================================

const FILE_PREFIX = "/v1/bgm/files/";
const FILE_NAME = /^[A-Za-z0-9._-]{1,120}\.(mp3|m4a)$/;
const GITHUB_RELEASE = "https://github.com/yuya-ogawa6960/VideoEditor/releases/download/bgm-v1/";

export function isBGMPath(path) {
  return path === "/v1/bgm/catalog" || path.startsWith(FILE_PREFIX);
}

export async function serveBGM(request, env, path) {
  const headers = new Headers({ "access-control-allow-origin": "*" });
  let key;
  if (path === "/v1/bgm/catalog") {
    key = "catalog.json";
    // 一覧は曲を足したらすぐ届くように短め
    headers.set("cache-control", "public, max-age=300");
  } else {
    const name = path.slice(FILE_PREFIX.length);
    if (!FILE_NAME.test(name)) return text(404, "見つかりません", headers);
    key = "files/" + name;
    // 曲のファイルは中身を変えない(作り直したら別の名前にする)
    headers.set("cache-control", "public, max-age=31536000, immutable");
  }

  if (!env.BGM) return await fromGitHub(request, key, headers);

  if (request.method === "HEAD") {
    const head = await env.BGM.head(key);
    if (!head) return text(404, "見つかりません", headers);
    head.writeHttpMetadata(headers);
    headers.set("etag", head.httpEtag);
    headers.set("accept-ranges", "bytes");
    headers.set("content-length", String(head.size));
    return new Response(null, { status: 200, headers });
  }

  const object = await env.BGM.get(key, { range: request.headers, onlyIf: request.headers });
  if (!object) return text(404, "見つかりません", headers);
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("accept-ranges", "bytes");
  // onlyIf(If-None-Match など)に当たったときは本文が無い
  if (!("body" in object) || !object.body) return new Response(null, { status: 304, headers });

  const range = object.range;
  if (range && request.headers.has("range")) {
    let start, length;
    if ("suffix" in range && range.suffix !== undefined) {
      length = Math.min(range.suffix, object.size);
      start = object.size - length;
    } else {
      start = range.offset ?? 0;
      length = range.length ?? object.size - start;
    }
    headers.set("content-range", `bytes ${start}-${start + length - 1}/${object.size}`);
    headers.set("content-length", String(length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("content-length", String(object.size));
  return new Response(object.body, { status: 200, headers });
}

/** R2 が無いとき: GitHub のリリースの添付ファイルを、Range を付けたまま取ってきて返す */
async function fromGitHub(request, key, headers) {
  const name = key.startsWith("files/") ? key.slice("files/".length) : key;
  const forward = new Headers();
  for (const h of ["range", "if-none-match", "if-modified-since"]) {
    if (request.headers.has(h)) forward.set(h, request.headers.get(h));
  }
  let upstream;
  try {
    upstream = await fetch(GITHUB_RELEASE + name, { method: request.method, headers: forward, redirect: "follow" });
  } catch {
    return text(503, "BGM はまだ準備中です", headers);
  }
  if (upstream.status === 404) return text(404, "見つかりません", headers);
  if (![200, 206, 304].includes(upstream.status)) return text(503, "BGM はまだ準備中です", headers);
  for (const h of ["content-length", "content-range", "etag", "last-modified"]) {
    if (upstream.headers.has(h)) headers.set(h, upstream.headers.get(h));
  }
  headers.set("content-type", name.endsWith(".json") ? "application/json; charset=utf-8" : "audio/mpeg");
  headers.set("accept-ranges", "bytes");
  return new Response(request.method === "HEAD" || upstream.status === 304 ? null : upstream.body,
    { status: upstream.status, headers });
}

function text(status, message, headers) {
  headers.set("content-type", "text/plain; charset=utf-8");
  headers.set("cache-control", "no-store");
  return new Response(message, { status, headers });
}

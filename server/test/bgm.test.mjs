// BGM の配信(src/bgm.js)のテスト。R2 は下の fakeBucket で代わりにする(Range と If-None-Match の扱いだけ再現)。
//   実行: cd server && node --test test/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const SONG = new Uint8Array(1000).map((_, i) => i % 256);

function fakeBucket(objects) {
  const meta = (key, size) => ({
    size,
    httpEtag: `"${key}"`,
    writeHttpMetadata(h) { h.set("content-type", key.endsWith(".json") ? "application/json" : "audio/mpeg"); },
  });
  return {
    async head(key) { return objects[key] ? meta(key, objects[key].length) : null; },
    async get(key, { range, onlyIf } = {}) {
      const data = objects[key];
      if (!data) return null;
      const m = meta(key, data.length);
      if (onlyIf && onlyIf.get("if-none-match") === m.httpEtag) return m; // 本文なし
      const r = range && range.get("range");
      if (r) {
        const [, a, b] = /bytes=(\d*)-(\d*)/.exec(r);
        if (a === "") {
          const suffix = Number(b);
          return { ...m, range: { suffix }, body: new Blob([data.slice(data.length - suffix)]).stream() };
        }
        const offset = Number(a);
        const end = b === "" ? data.length - 1 : Number(b);
        return { ...m, range: { offset, length: end - offset + 1 }, body: new Blob([data.slice(offset, end + 1)]).stream() };
      }
      return { ...m, body: new Blob([data]).stream() };
    },
  };
}

const env = () => ({ BGM: fakeBucket({ "catalog.json": new TextEncoder().encode('{"tracks":[]}'), "files/a_1.mp3": SONG }) });
const call = (path, init = {}, e = env()) => worker.fetch(new Request("https://x.dev" + path, init), e);

test("曲の一覧はログインなしで読める", async () => {
  const res = await call("/v1/bgm/catalog");
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { tracks: [] });
  assert.match(res.headers.get("cache-control"), /max-age=300/);
});

test("曲は全体でも Range でも取れる", async () => {
  const all = await call("/v1/bgm/files/a_1.mp3");
  assert.equal(all.status, 200);
  assert.equal((await all.arrayBuffer()).byteLength, 1000);
  assert.equal(all.headers.get("accept-ranges"), "bytes");

  const part = await call("/v1/bgm/files/a_1.mp3", { headers: { range: "bytes=100-199" } });
  assert.equal(part.status, 206);
  assert.equal(part.headers.get("content-range"), "bytes 100-199/1000");
  assert.deepEqual(new Uint8Array(await part.arrayBuffer()), SONG.slice(100, 200));

  const tail = await call("/v1/bgm/files/a_1.mp3", { headers: { range: "bytes=-10" } });
  assert.equal(tail.status, 206);
  assert.equal(tail.headers.get("content-range"), "bytes 990-999/1000");
});

test("HEAD・304・見つからない・変な名前・バケットなし", async () => {
  const head = await call("/v1/bgm/files/a_1.mp3", { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get("content-length"), "1000");

  const cached = await call("/v1/bgm/files/a_1.mp3", { headers: { "if-none-match": '"files/a_1.mp3"' } });
  assert.equal(cached.status, 304);

  assert.equal((await call("/v1/bgm/files/none.mp3")).status, 404);
  assert.equal((await call("/v1/bgm/files/..%2Fcatalog.json")).status, 404);
  assert.equal((await call("/v1/bgm/files/a_1.exe")).status, 404);
});

test("R2 が無いときは GitHub のリリースから Range ごと取ってくる", async () => {
  const realFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (url, init) => {
    seen.push({ url: String(url), range: init.headers.get("range") });
    if (String(url).endsWith("/none.mp3")) return new Response("Not Found", { status: 404 });
    if (init.headers.get("range")) {
      return new Response(SONG.slice(0, 10), { status: 206, headers: { "content-range": "bytes 0-9/1000", "content-length": "10" } });
    }
    return new Response(SONG, { status: 200, headers: { "content-length": "1000" } });
  };
  try {
    const part = await call("/v1/bgm/files/a_1.mp3", { headers: { range: "bytes=0-9" } }, {});
    assert.equal(part.status, 206);
    assert.equal(part.headers.get("content-range"), "bytes 0-9/1000");
    assert.equal(part.headers.get("content-type"), "audio/mpeg");
    assert.equal(seen[0].url, "https://github.com/yuya-ogawa6960/VideoEditor/releases/download/bgm-v1/a_1.mp3");
    assert.equal(seen[0].range, "bytes=0-9");

    const catalog = await call("/v1/bgm/catalog", {}, {});
    assert.equal(catalog.status, 200);
    assert.match(seen[1].url, /bgm-v1\/catalog\.json$/);
    assert.match(catalog.headers.get("content-type"), /application\/json/);

    assert.equal((await call("/v1/bgm/files/none.mp3", {}, {})).status, 404);
    globalThis.fetch = async () => { throw new Error("offline"); };
    assert.equal((await call("/v1/bgm/catalog", {}, {})).status, 503);
  } finally {
    globalThis.fetch = realFetch;
  }
});

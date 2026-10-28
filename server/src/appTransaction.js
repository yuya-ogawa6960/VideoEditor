// =====================================================================
// Apple の AppTransaction(StoreKit 2 の署名付き JWS)をサーバーで確かめる。
// アプリは TestFlight・App Review・Xcode の「サンドボックス」で動いているときだけ、
// この JWS を /v1/ads/claim の本文(appTransaction)で送る。サーバーは次を確かめる:
//   1) JWS の x5c の証明書の連鎖が、Apple のルート証明書(apple.com から取得)につながる
//   2) 一番下の証明書の鍵で JWS の署名が正しい
//   3) 中身の bundleId がこのアプリで、environment が Sandbox / Xcode
// 通れば「本当にテスト版で動いている」とみなし、テスト広告のポイントをアプリの申告で足せる。
// 本番の App Store 版の JWS は environment が Production なので通らない(本番は AdMob の SSV で足す)。
// =====================================================================

const APPLE_ROOT_URL = "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer";

/** JWS を確かめて、通れば中身(payload)を返す。通らなければ null */
export async function verifyAppTransaction(jws, { bundleID, fetchRoot = fetchAppleRoot } = {}) {
  try {
    const parts = String(jws || "").split(".");
    if (parts.length !== 3) return null;
    const header = JSON.parse(utf8(b64urlToBytes(parts[0])));
    if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length < 2) return null;
    const chain = header.x5c.map((c) => b64ToBytes(c));

    // 連鎖の確認: 一番上が Apple のルートと同じバイト列で、上から順に下の証明書を署名している
    const root = await fetchRoot();
    if (!root || !sameBytes(chain[chain.length - 1], root)) return null;
    for (let i = chain.length - 1; i > 0; i--) {
      if (!(await certificateSigned(chain[i - 1], chain[i]))) return null;
    }

    // JWS 本体の署名(一番下の証明書の鍵、ES256)
    const leaf = parseCertificate(chain[0]);
    const key = await crypto.subtle.importKey("spki", leaf.spki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const signature = b64urlToBytes(parts[2]);
    if (signature.length !== 64) return null;
    const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature,
                                          new TextEncoder().encode(parts[0] + "." + parts[1]));
    if (!ok) return null;

    const payload = JSON.parse(utf8(b64urlToBytes(parts[1])));
    if (bundleID && payload.bundleId !== bundleID) return null;
    return payload;
  } catch {
    return null;
  }
}

/** テスト版(TestFlight・App Review・Xcode)で動いているか */
export function isSandbox(payload) {
  return !!payload && (payload.environment === "Sandbox" || payload.environment === "Xcode");
}

async function fetchAppleRoot() {
  const response = await fetch(APPLE_ROOT_URL, { cf: { cacheTtl: 86400, cacheEverything: true } });
  if (!response.ok) return null;
  return new Uint8Array(await response.arrayBuffer());
}

// ---------------------------------------------------------------------
// X.509(DER)の最小限の読み取り
// ---------------------------------------------------------------------

/** DER の 1 要素(tag、ヘッダの位置、中身の範囲) */
function readTLV(bytes, offset) {
  const tag = bytes[offset];
  let length = bytes[offset + 1];
  let headerLength = 2;
  if (length & 0x80) {
    const n = length & 0x7f;
    length = 0;
    for (let i = 0; i < n; i++) length = (length << 8) | bytes[offset + 2 + i];
    headerLength = 2 + n;
  }
  const start = offset + headerLength;
  return { tag, headerStart: offset, start, end: start + length };
}

/** SEQUENCE の子要素を順に返す */
function children(bytes, tlv) {
  const out = [];
  let offset = tlv.start;
  while (offset < tlv.end) {
    const child = readTLV(bytes, offset);
    out.push(child);
    offset = child.end;
  }
  return out;
}

/** 要素をヘッダごと切り出す(DER のまま) */
function slice(bytes, tlv) {
  return bytes.slice(tlv.headerStart, tlv.end);
}

const OID = {
  ecdsaSHA256: "2a8648ce3d040302",
  ecdsaSHA384: "2a8648ce3d040303",
  rsaSHA256: "2a864886f70d01010b",
  rsaSHA384: "2a864886f70d01010c",
  p384: "2b81040022",
};

function hex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** 証明書から、署名の対象(tbs)・署名アルゴリズム・署名・公開鍵(SPKI)を取り出す */
export function parseCertificate(der) {
  const cert = readTLV(der, 0);
  const [tbs, sigAlg, sigValue] = children(der, cert);
  const algOID = hex(slice(der, children(der, sigAlg)[0]).slice(2));
  // BIT STRING の最初の 1 バイトは未使用ビット数
  const signature = der.slice(sigValue.start + 1, sigValue.end);
  const tbsChildren = children(der, tbs);
  // [0] version があれば 7 番目、無ければ 6 番目が subjectPublicKeyInfo
  const spkiTLV = tbsChildren[tbsChildren[0].tag === 0xa0 ? 6 : 5];
  const spkiAlg = children(der, children(der, spkiTLV)[0]);
  const curveOID = spkiAlg.length > 1 ? hex(slice(der, spkiAlg[1]).slice(2)) : "";
  return { tbs: slice(der, tbs), algOID, signature, spki: slice(der, spkiTLV), curveOID };
}

/** child(証明書)が issuer(証明書)の鍵で署名されているか */
async function certificateSigned(childDer, issuerDer) {
  const child = parseCertificate(childDer);
  const issuer = parseCertificate(issuerDer);
  let key, params, signature;
  if (child.algOID === OID.ecdsaSHA256 || child.algOID === OID.ecdsaSHA384) {
    const curve = issuer.curveOID === OID.p384 ? "P-384" : "P-256";
    key = await crypto.subtle.importKey("spki", issuer.spki, { name: "ECDSA", namedCurve: curve }, false, ["verify"]);
    params = { name: "ECDSA", hash: child.algOID === OID.ecdsaSHA384 ? "SHA-384" : "SHA-256" };
    signature = derToRaw(child.signature, curve === "P-384" ? 48 : 32);
    if (!signature) return false;
  } else if (child.algOID === OID.rsaSHA256 || child.algOID === OID.rsaSHA384) {
    const hash = child.algOID === OID.rsaSHA384 ? "SHA-384" : "SHA-256";
    key = await crypto.subtle.importKey("spki", issuer.spki, { name: "RSASSA-PKCS1-v1_5", hash }, false, ["verify"]);
    params = { name: "RSASSA-PKCS1-v1_5" };
    signature = child.signature;
  } else {
    return false;
  }
  return crypto.subtle.verify(params, key, signature, child.tbs);
}

/** DER(SEQUENCE { INTEGER r, INTEGER s })→ r||s(各 size バイト) */
function derToRaw(der, size) {
  if (der.length < 8 || der[0] !== 0x30) return null;
  let i = 2;
  if (der[1] & 0x80) i = 2 + (der[1] & 0x7f);
  const readInt = () => {
    if (der[i] !== 0x02) return null;
    const len = der[i + 1];
    let bytes = der.slice(i + 2, i + 2 + len);
    i += 2 + len;
    while (bytes.length > size && bytes[0] === 0) bytes = bytes.slice(1);
    if (bytes.length > size) return null;
    const out = new Uint8Array(size);
    out.set(bytes, size - bytes.length);
    return out;
  };
  const r = readInt();
  const s = readInt();
  if (!r || !s) return null;
  const raw = new Uint8Array(size * 2);
  raw.set(r, 0);
  raw.set(s, size);
  return raw;
}

// ---------------------------------------------------------------------
// 文字列・バイト列
// ---------------------------------------------------------------------

function b64ToBytes(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64urlToBytes(s) {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  return b64ToBytes(b64);
}

function utf8(bytes) {
  return new TextDecoder().decode(bytes);
}

function sameBytes(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

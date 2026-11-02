// =====================================================================
// Apple の AppTransaction(StoreKit 2 の署名付き JWS)をサーバーで確かめる。
// アプリは TestFlight・App Review・Xcode の「サンドボックス」で動いているときだけ、
// この JWS を /v1/ads/claim の本文(appTransaction)で送る。サーバーは次を確かめる
// (証明書の確認は Apple 公式の app-store-server-library の SignedDataVerifier にそろえ、追加のライブラリなしで行う。
//  OCSP の問い合わせだけはしない):
//   1) JWS の x5c の証明書がちょうど 3 枚(App Store の署名用 → Apple の中間 CA → Apple のルート)
//   2) 連鎖が Apple のルート証明書(apple.com から取得)につながる。上から順に下の証明書を署名し、発行者の名前も一致する
//   3) 一番下が App Store の署名用の証明書(OID 1.2.840.113635.100.6.11.1)、
//      中間が Apple の中間 CA(OID 1.2.840.113635.100.6.2.1、basicConstraints が cA=TRUE)。
//      Apple のルートにつながる証明書(開発用・配布用・Apple Pay など)は、有料の Apple Developer なら
//      誰でも自分の鍵で発行してもらえるので、「つながる」だけでは App Store が署名したことにならない
//   4) 3 枚とも、JWS が作られた時点(receiptCreationDate → signedDate → 今)で有効期間内(前後 60 秒の余裕)
//   5) 一番下の証明書の鍵で JWS の署名が正しい(ES256)
//   6) 中身の bundleId がこのアプリで、receiptType(署名した環境)が Sandbox
// 通れば「本当にテスト版で動いている」とみなし、テスト広告のポイントをアプリの申告で足せる。
// 本番の App Store 版の JWS は receiptType が Production なので通らない(本番は AdMob の SSV で足す)。
// Xcode の StoreKit テストの JWS は Xcode の証明書で署名され、Apple のルートにつながらないので通らない。
// =====================================================================

const APPLE_ROOT_URL = "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer";
// 証明書の有効期間を見るときの前後の余裕(Apple のライブラリと同じ 60 秒)
const MAX_SKEW_MS = 60 * 1000;
// JWS の形(base64url の 3 つの部分)
const JWS_PATTERN = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;

/**
 * JWS を確かめて、通れば中身(payload)を返す。通らなければ null。
 * fetchRoot(信頼するルート証明書の DER を返す)と now(日時の入っていない JWS で使う「今」)はテストで差し替える用。
 * 本番(index.js)は渡さないので、常に apple.com の Apple Root CA - G3 と今の時刻で確かめる
 */
export async function verifyAppTransaction(jws, { bundleID, fetchRoot = fetchAppleRoot, now = new Date() } = {}) {
  try {
    const text = String(jws || "");
    if (!JWS_PATTERN.test(text)) return null;
    const parts = text.split(".");
    const header = JSON.parse(utf8(b64urlToBytes(parts[0])));
    const payload = JSON.parse(utf8(b64urlToBytes(parts[1])));
    if (!isObject(header) || !isObject(payload)) return null;

    // 1) 証明書はちょうど 3 枚(一番下・中間・ルート)
    if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length !== 3) return null;
    if (!header.x5c.every((c) => typeof c === "string")) return null;
    const chain = header.x5c.map((c) => b64ToBytes(c));
    const [leaf, intermediate, root] = chain.map((der) => parseCertificate(der));

    // 2) 連鎖: 一番上が Apple のルートと同じバイト列で、上から順に下の証明書を発行している(名前と署名)
    const trustedRoot = await fetchRoot();
    if (!trustedRoot || !sameBytes(chain[2], trustedRoot)) return null;
    if (!(await issuedBy(intermediate, root)) || !(await issuedBy(leaf, intermediate))) return null;

    // 3) Apple の印(拡張の OID)。一番下は App Store の署名用、中間は Apple の中間 CA で、CA の証明書
    if (!leaf.extensions.has(OID.appStoreReceiptSigning)) return null;
    if (!intermediate.extensions.has(OID.appleIntermediateCA) || !isCA(intermediate)) return null;

    // 4) 有効期間。Apple のライブラリと同じく、JWS が作られた時点で見る
    const at = signedAt(payload, now);
    if (![leaf, intermediate, root].every((cert) => validAt(cert, at))) return null;

    // 5) JWS 本体の署名(一番下の証明書の鍵、ES256)
    const key = await crypto.subtle.importKey("spki", leaf.spki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const signature = b64urlToBytes(parts[2]);
    if (signature.length !== 64) return null;
    const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature,
                                          new TextEncoder().encode(parts[0] + "." + parts[1]));
    if (!ok) return null;

    // 6) このアプリの、サンドボックス(TestFlight・App Review)の JWS か
    if (!bundleID || payload.bundleId !== bundleID) return null;
    if (!isSandbox(payload)) return null;
    return payload;
  } catch {
    return null;
  }
}

/** テスト版(TestFlight・App Review のサンドボックス)の AppTransaction か。
 *  署名した環境は receiptType にある(Apple の JWSAppTransactionDecodedPayload。environment という項目は無い。
 *  前は environment を見ていたため、本物の証明は一度も通っていなかった)。
 *  Xcode の StoreKit テスト(receiptType が Xcode)の JWS は Apple のルートにつながらないので含めない */
export function isSandbox(payload) {
  return !!payload && payload.receiptType === "Sandbox";
}

async function fetchAppleRoot() {
  const response = await fetch(APPLE_ROOT_URL, { cf: { cacheTtl: 86400, cacheEverything: true } });
  if (!response.ok) return null;
  return new Uint8Array(await response.arrayBuffer());
}

/** 有効期間を見る時刻(ミリ秒)。receiptCreationDate → signedDate → now の順。日時が数でなければ NaN(通さない) */
function signedAt(payload, now) {
  for (const key of ["receiptCreationDate", "signedDate"]) {
    if (payload[key] === undefined) continue;
    return typeof payload[key] === "number" ? payload[key] : NaN;
  }
  return now instanceof Date ? now.getTime() : Number(now);
}

/** at(ミリ秒)が証明書の有効期間(notBefore 〜 notAfter、前後 60 秒の余裕)に入っているか */
function validAt(cert, at) {
  if (!Number.isFinite(at) || !cert.notBefore || !cert.notAfter) return false;
  return cert.notBefore.getTime() - MAX_SKEW_MS <= at && at <= cert.notAfter.getTime() + MAX_SKEW_MS;
}

/** child(証明書)が issuer(証明書)から発行されたか: 発行者の名前が issuer の名前と同じで、issuer の鍵で署名されている */
async function issuedBy(child, issuer) {
  return sameBytes(child.issuer, issuer.subject) && (await certificateSigned(child, issuer));
}

/** CA の証明書か: basicConstraints が cA=TRUE で、keyUsage があれば keyCertSign を含む(Node の X509Certificate.ca と同じ判定) */
function isCA(cert) {
  const constraints = cert.extensions.get(OID.basicConstraints);
  if (!constraints) return false;
  // SEQUENCE { cA BOOLEAN DEFAULT FALSE, pathLenConstraint INTEGER OPTIONAL }。FALSE は省かれる
  const seq = readTLV(constraints, 0);
  if (seq.tag !== 0x30) return false;
  const [first] = children(constraints, seq);
  if (!first || first.tag !== 0x01 || first.end - first.start !== 1 || constraints[first.start] === 0) return false;
  const usage = cert.extensions.get(OID.keyUsage);
  if (usage) {
    // BIT STRING。先頭の 1 バイトは未使用ビット数で、keyCertSign は 5 番目のビット(0x04)
    const bits = readTLV(usage, 0);
    if (bits.tag !== 0x03 || bits.end - bits.start < 2 || !(usage[bits.start + 1] & 0x04)) return false;
  }
  return true;
}

// ---------------------------------------------------------------------
// X.509(DER)の最小限の読み取り
// ---------------------------------------------------------------------

/** DER の 1 要素(tag、ヘッダの位置、中身の範囲)。limit(親の終わり)からはみ出すものは読めない扱い */
function readTLV(bytes, offset, limit = bytes.length) {
  if (offset + 2 > limit) throw new Error("DER が途中で終わっています");
  const tag = bytes[offset];
  let length = bytes[offset + 1];
  let headerLength = 2;
  if (length & 0x80) {
    const n = length & 0x7f;
    if (n === 0 || n > 4 || offset + 2 + n > limit) throw new Error("DER の長さが読めません");
    length = 0;
    for (let i = 0; i < n; i++) length = length * 256 + bytes[offset + 2 + i];
    headerLength = 2 + n;
  }
  const start = offset + headerLength;
  const end = start + length;
  if (end > limit) throw new Error("DER が途中で終わっています");
  return { tag, headerStart: offset, start, end };
}

/** SEQUENCE の子要素を順に返す */
function children(bytes, tlv) {
  const out = [];
  let offset = tlv.start;
  while (offset < tlv.end) {
    const child = readTLV(bytes, offset, tlv.end);
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
  basicConstraints: "551d13", // 2.5.29.19
  keyUsage: "551d0f",         // 2.5.29.15
  // Apple の印(Apple のライブラリが確かめるもの)
  appStoreReceiptSigning: "2a864886f76364060b01", // 1.2.840.113635.100.6.11.1(App Store の署名用の証明書)
  appleIntermediateCA: "2a864886f76364060201",    // 1.2.840.113635.100.6.2.1(Apple の中間 CA)
};

function hex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** 証明書から、署名の対象(tbs)・署名アルゴリズム・署名・公開鍵(SPKI)・発行者と主体の名前・有効期間・拡張を取り出す */
export function parseCertificate(der) {
  const cert = readTLV(der, 0);
  if (cert.tag !== 0x30 || cert.end !== der.length) throw new Error("証明書の形が違います");
  const [tbs, sigAlg, sigValue] = children(der, cert);
  if (!tbs || !sigAlg || !sigValue || sigValue.tag !== 0x03) throw new Error("証明書の形が違います");
  const algOID = hex(slice(der, children(der, sigAlg)[0]).slice(2));
  // BIT STRING の最初の 1 バイトは未使用ビット数(署名では 0)
  if (sigValue.end - sigValue.start < 2 || der[sigValue.start] !== 0) throw new Error("署名の形が違います");
  const signature = der.slice(sigValue.start + 1, sigValue.end);
  const tbsChildren = children(der, tbs);
  // [0] version があれば 1 つずれる。serialNumber の後は signature・issuer・validity・subject・subjectPublicKeyInfo
  const first = tbsChildren[0].tag === 0xa0 ? 1 : 0;
  const [tbsSigAlg, issuer, validity, subject, spkiTLV] = tbsChildren.slice(first + 1, first + 6);
  if (![tbsSigAlg, issuer, validity, subject, spkiTLV].every((t) => t && t.tag === 0x30)) throw new Error("証明書の形が違います");
  // 外側と tbs の中の署名アルゴリズムは同じはず(RFC 5280)
  if (!sameBytes(slice(der, tbsSigAlg), slice(der, sigAlg))) throw new Error("署名アルゴリズムが一致しません");
  const spkiAlg = children(der, children(der, spkiTLV)[0]);
  const curveOID = spkiAlg.length > 1 ? hex(slice(der, spkiAlg[1]).slice(2)) : "";
  const [notBefore, notAfter] = children(der, validity);
  return {
    tbs: slice(der, tbs), algOID, signature, spki: slice(der, spkiTLV), curveOID,
    issuer: slice(der, issuer), subject: slice(der, subject),
    notBefore: readTime(der, notBefore), notAfter: readTime(der, notAfter),
    extensions: readExtensions(der, tbsChildren.slice(first + 6)),
  };
}

/** UTCTime(YYMMDDHHMMSSZ)/ GeneralizedTime(YYYYMMDDHHMMSSZ)→ Date。読めなければ null */
function readTime(der, tlv) {
  const text = utf8(der.slice(tlv.start, tlv.end));
  let m, date = null;
  if (tlv.tag === 0x17 && (m = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text))) {
    // RFC 5280: 50 以上は 19xx 年、50 未満は 20xx 年
    const yy = Number(m[1]);
    date = new Date(Date.UTC(yy >= 50 ? 1900 + yy : 2000 + yy, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])));
  } else if (tlv.tag === 0x18 && (m = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text))) {
    date = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])));
  }
  return date && Number.isFinite(date.getTime()) ? date : null;
}

/** 拡張([3] の中の SEQUENCE OF Extension)を、OID(hex)→ 中身(extnValue の中の DER)の Map にする。
 *  同じ拡張が 2 つあるもの(RFC 5280 で禁止)は読めない扱い */
function readExtensions(der, rest) {
  const extensions = new Map();
  const wrapper = rest.find((t) => t.tag === 0xa3);
  if (!wrapper) return extensions;
  const [list] = children(der, wrapper);
  if (!list || list.tag !== 0x30) throw new Error("拡張の形が違います");
  for (const ext of children(der, list)) {
    // SEQUENCE { extnID OBJECT IDENTIFIER, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
    const items = ext.tag === 0x30 ? children(der, ext) : [];
    const id = items[0];
    const value = items[items.length - 1];
    if (items.length < 2 || items.length > 3 || id.tag !== 0x06 || value.tag !== 0x04) throw new Error("拡張の形が違います");
    const oid = hex(der.slice(id.start, id.end));
    if (extensions.has(oid)) throw new Error("同じ拡張が 2 つあります");
    extensions.set(oid, der.slice(value.start, value.end));
  }
  return extensions;
}

/** child(証明書)が issuer(証明書)の鍵で署名されているか(どちらも parseCertificate の結果) */
async function certificateSigned(child, issuer) {
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

/** DER(SEQUENCE { INTEGER r, INTEGER s })→ r||s(各 size バイト)。DER として正しくない形(長さの食い違い・余分な 0 など)は null */
function derToRaw(der, size) {
  // P-256・P-384 の署名は 128 バイト未満なので、長さは 1 バイトの形だけ
  if (der.length < 8 || der[0] !== 0x30 || der[1] !== der.length - 2) return null;
  let i = 2;
  const readInt = () => {
    if (der[i] !== 0x02) return null;
    const len = der[i + 1];
    if (!(len >= 1) || len > size + 1 || i + 2 + len > der.length) return null;
    let bytes = der.slice(i + 2, i + 2 + len);
    i += 2 + len;
    // 負の数と、要らない先頭の 0 は DER ではない(先頭の 0 は次のバイトの最上位ビットが 1 のときだけ)
    if (bytes[0] & 0x80) return null;
    if (bytes.length > 1 && bytes[0] === 0) {
      if (!(bytes[1] & 0x80)) return null;
      bytes = bytes.slice(1);
    }
    if (bytes.length > size) return null;
    const out = new Uint8Array(size);
    out.set(bytes, size - bytes.length);
    return out;
  };
  const r = readInt();
  const s = readInt();
  if (!r || !s || i !== der.length) return null;
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

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

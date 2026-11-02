// AppTransaction(JWS)の確認(src/appTransaction.js)のテスト
//   実行: cd server && node --test test/*.test.mjs
// 証明書は test/fixtures/ の、openssl で作ったテスト専用の連鎖(作り方は fixtures/make-fixtures.sh)。
// 本物と同じく ルート(P-384)→ 中間(P-384、OID 1.2.840.113635.100.6.2.1・CA)→ 一番下(P-256、OID 1.2.840.113635.100.6.11.1)。
// 本番は Apple Root CA - G3 だけを信頼するので、ここでは fetchRoot でテスト用のルートを渡す。
import { test } from "node:test";
import assert from "node:assert/strict";
import { X509Certificate } from "node:crypto";
import { verifyAppTransaction, isSandbox, parseCertificate } from "../src/appTransaction.js";
import { fixture, certificate, privateKey, makeJWS } from "./helpers.mjs";

const BUNDLE_ID = "com.yuyaogawa6960.videomania";
const ROOT = certificate("root.pem");
const INTER = certificate("inter.pem");
const LEAF = certificate("leaf.pem");
const LEAF_KEY = privateKey("leaf.key");

// Apple の印(拡張の OID の中身を hex にしたもの)
const RECEIPT_SIGNING_OID = "2a864886f76364060b01"; // 1.2.840.113635.100.6.11.1
const APPLE_INTERMEDIATE_OID = "2a864886f76364060201"; // 1.2.840.113635.100.6.2.1

// fixtures の日付(make-fixtures.sh と同じ)
const LEAF_NOT_BEFORE = Date.UTC(2026, 0, 1);
const LEAF_NOT_AFTER = Date.UTC(2028, 0, 1);
const INSIDE = Date.UTC(2026, 5, 1); // 3 枚とも有効期間の中
const EXPIRED = Date.UTC(2030, 0, 1); // 一番下の期限切れの後

/** このアプリの、サンドボックスの AppTransaction の中身 */
const sandbox = (extra = {}) => ({ bundleId: BUNDLE_ID, receiptType: "Sandbox", receiptCreationDate: INSIDE, ...extra });

/** 一番下の鍵で署名した JWS(x5c は既定で正しい形の 3 枚) */
const signed = (payload = sandbox(), x5c = [LEAF, INTER, ROOT]) => makeJWS({ x5c, payload, key: LEAF_KEY });

/** テスト用のルートを信頼して確かめる */
const verify = (jws, { root = ROOT, bundleID = BUNDLE_ID, now } = {}) =>
  verifyAppTransaction(jws, { bundleID, fetchRoot: async () => root, now });

test("fixtures の証明書を読める(有効期間・発行者の名前・Apple の OID)", () => {
  const leaf = parseCertificate(LEAF);
  const inter = parseCertificate(INTER);
  const root = parseCertificate(ROOT);
  assert.equal(leaf.notBefore.toISOString(), "2026-01-01T00:00:00.000Z");
  assert.equal(leaf.notAfter.toISOString(), "2028-01-01T00:00:00.000Z");
  assert.equal(inter.notAfter.toISOString(), "2040-01-01T00:00:00.000Z");
  // 2050 年以降は GeneralizedTime
  assert.equal(root.notAfter.toISOString(), "2055-01-01T00:00:00.000Z");
  assert.deepEqual(leaf.issuer, inter.subject);
  assert.deepEqual(inter.issuer, root.subject);
  assert.ok(leaf.extensions.has(RECEIPT_SIGNING_OID));
  assert.ok(inter.extensions.has(APPLE_INTERMEDIATE_OID));
  assert.ok(!inter.extensions.has(RECEIPT_SIGNING_OID));
});

test("正しい連鎖(一番下 6.11.1、中間 6.2.1 + CA)で署名された、このアプリの Sandbox の JWS は通る", async () => {
  const payload = await verify(signed());
  assert.ok(payload, "payload が返る");
  assert.equal(payload.bundleId, BUNDLE_ID);
  assert.equal(payload.receiptType, "Sandbox");
  assert.equal(isSandbox(payload), true);
});

test("isSandbox は Sandbox だけ(Xcode・Production は含めない)", () => {
  assert.equal(isSandbox({ receiptType: "Sandbox" }), true);
  assert.equal(isSandbox({ receiptType: "Xcode" }), false);
  assert.equal(isSandbox({ receiptType: "Production" }), false);
  assert.equal(isSandbox({}), false);
  assert.equal(isSandbox(null), false);
});

test("一番下に App Store の署名用の OID(1.2.840.113635.100.6.11.1)が無ければ通さない", async () => {
  const developerCert = certificate("leaf-no-receipt-oid.pem");
  assert.equal(parseCertificate(developerCert).extensions.has(RECEIPT_SIGNING_OID), false);
  assert.equal(await verify(signed(sandbox(), [developerCert, INTER, ROOT])), null);
});

test("中間に Apple の中間 CA の OID(1.2.840.113635.100.6.2.1)が無ければ通さない", async () => {
  assert.equal(await verify(signed(sandbox(), [LEAF, certificate("inter-no-wwdr-oid.pem"), ROOT])), null);
});

test("中間が CA でなければ通さない(basicConstraints が CA:FALSE、keyUsage に keyCertSign が無い)", async () => {
  // Apple のライブラリ(Node の X509Certificate.ca)でも CA ではない
  assert.equal(new X509Certificate(fixture("inter.pem")).ca, true);
  assert.equal(new X509Certificate(fixture("inter-not-ca.pem")).ca, false);
  assert.equal(new X509Certificate(fixture("inter-no-certsign.pem")).ca, false);
  assert.equal(await verify(signed(sandbox(), [LEAF, certificate("inter-not-ca.pem"), ROOT])), null);
  assert.equal(await verify(signed(sandbox(), [LEAF, certificate("inter-no-certsign.pem"), ROOT])), null);
});

test("x5c がちょうど 3 枚でなければ通さない(前の確認では通っていた 2 枚・4 枚の連鎖も)", async () => {
  // 2 枚: 中間を「ルート」として信頼させても通さない
  assert.equal(await verify(signed(sandbox(), [LEAF, INTER]), { root: INTER }), null);
  // 4 枚: ルートを 2 回並べたもの
  assert.equal(await verify(signed(sandbox(), [LEAF, INTER, ROOT, ROOT])), null);
  assert.equal(await verify(signed(sandbox(), [ROOT])), null);
  assert.equal(await verify(signed(sandbox(), [])), null);
});

test("発行者の名前が中間の名前と違えば、署名が正しくても通さない", async () => {
  // inter-renamed.pem は inter.pem と同じ鍵で名前だけ違う(一番下の署名は正しい)
  assert.equal(await verify(signed(sandbox(), [LEAF, certificate("inter-renamed.pem"), ROOT])), null);
});

test("有効期間は JWS が作られた時点(receiptCreationDate)で、前後 60 秒の余裕まで見る", async () => {
  const at = (ms) => verify(signed(sandbox({ receiptCreationDate: ms })));
  assert.ok(await at(LEAF_NOT_AFTER + 30_000), "期限の 30 秒後は余裕の中");
  assert.equal(await at(LEAF_NOT_AFTER + 90_000), null, "期限の 90 秒後は期限切れ");
  assert.ok(await at(LEAF_NOT_BEFORE - 30_000), "始まりの 30 秒前は余裕の中");
  assert.equal(await at(LEAF_NOT_BEFORE - 90_000), null, "始まりの 90 秒前はまだ有効でない");
  assert.equal(await at(EXPIRED), null);
});

test("日時は receiptCreationDate → signedDate → now の順に使う。数でない日時は通さない", async () => {
  const base = { bundleId: BUNDLE_ID, receiptType: "Sandbox" };
  // receiptCreationDate があればそれで見る
  assert.ok(await verify(signed({ ...base, receiptCreationDate: INSIDE, signedDate: EXPIRED })));
  assert.equal(await verify(signed({ ...base, receiptCreationDate: EXPIRED, signedDate: INSIDE })), null);
  // 無ければ signedDate
  assert.ok(await verify(signed({ ...base, signedDate: INSIDE }), { now: new Date(EXPIRED) }));
  assert.equal(await verify(signed({ ...base, signedDate: EXPIRED }), { now: new Date(INSIDE) }), null);
  // どちらも無ければ now(本番は今の時刻。テストでは差し替える)
  assert.ok(await verify(signed(base), { now: new Date(INSIDE) }));
  assert.equal(await verify(signed(base), { now: new Date(EXPIRED) }), null);
  // 数でない日時
  assert.equal(await verify(signed({ ...base, receiptCreationDate: String(INSIDE) })), null);
  assert.equal(await verify(signed({ ...base, receiptCreationDate: null }), { now: new Date(INSIDE) }), null);
});

test("中間の有効期間も見る(中間が期限切れなら、一番下が有効でも通さない)", async () => {
  const shortInter = certificate("inter-short.pem"); // 2026-03-01 に期限切れ
  assert.ok(await verify(signed(sandbox({ receiptCreationDate: Date.UTC(2026, 1, 1) }), [LEAF, shortInter, ROOT])));
  assert.equal(await verify(signed(sandbox({ receiptCreationDate: Date.UTC(2026, 5, 1) }), [LEAF, shortInter, ROOT])), null);
});

test("本番(Production)・Xcode の JWS は、署名が正しくても通さない", async () => {
  assert.equal(await verify(signed(sandbox({ receiptType: "Production" }))), null);
  assert.equal(await verify(signed(sandbox({ receiptType: "Xcode" }))), null);
  assert.equal(await verify(signed(sandbox({ receiptType: undefined }))), null);
});

test("別のアプリ(bundleId が違う)の JWS は通さない。bundleID を渡さないときも通さない", async () => {
  assert.equal(await verify(signed(sandbox({ bundleId: "com.example.other" }))), null);
  assert.equal(await verify(signed(), { bundleID: "" }), null);
  assert.equal(await verifyAppTransaction(signed(), { fetchRoot: async () => ROOT }), null);
});

test("信頼するルートと違う連鎖・ルートが取れないときは通さない", async () => {
  assert.equal(await verify(signed(), { root: certificate("forged-root.pem") }), null);
  assert.equal(await verify(signed(), { root: null }), null);
});

test("署名・中身の書き換え、ES256 以外、形の違う JWS は通さない", async () => {
  const [header, payload, signature] = signed().split(".");
  // 署名を 1 ビット変える
  const flipped = Buffer.from(signature, "base64url");
  flipped[10] ^= 1;
  assert.equal(await verify(`${header}.${payload}.${flipped.toString("base64url")}`), null);
  // 中身を書き換える(署名はそのまま)
  const tampered = Buffer.from(JSON.stringify(sandbox({ appAppleId: 1 }))).toString("base64url");
  assert.equal(await verify(`${header}.${tampered}.${signature}`), null);
  // alg が ES256 でない
  assert.equal(await verify(makeJWS({ x5c: [LEAF, INTER, ROOT], payload: sandbox(), key: LEAF_KEY, alg: "ES384" })), null);
  // x5c に文字列でないものが入っている
  const numbers = Buffer.from(JSON.stringify({ alg: "ES256", x5c: [1, 2, 3] })).toString("base64url");
  assert.equal(await verify(`${numbers}.${payload}.${signature}`), null);
  // 形が違う
  for (const bad of [undefined, null, "", "a.b", "a.b.c.d", `${header}.${payload}`, `${header}.${payload}.${signature}=`]) {
    assert.equal(await verify(bad), null);
  }
});

test("PR #2 の確認で作った偽の連鎖(forge.mjs)は通さない", async () => {
  const leaf = certificate("forged-leaf.pem");
  const inter = certificate("forged-inter.pem");
  const root = certificate("forged-root.pem");
  // 連鎖としては正しい(ルートの代わりにつながり、中間は CA)。違うのは Apple の OID が無いことだけ
  const [leafX509, interX509, rootX509] = ["forged-leaf.pem", "forged-inter.pem", "forged-root.pem"].map((n) => new X509Certificate(fixture(n)));
  assert.ok(leafX509.checkIssued(interX509) && leafX509.verify(interX509.publicKey));
  assert.ok(interX509.checkIssued(rootX509) && interX509.verify(rootX509.publicKey));
  assert.equal(interX509.ca, true);
  assert.equal(parseCertificate(leaf).extensions.has(RECEIPT_SIGNING_OID), false);
  assert.equal(parseCertificate(inter).extensions.has(APPLE_INTERMEDIATE_OID), false);
  // forge.mjs と同じ JWS(このアプリの bundleId、Sandbox)
  const jws = makeJWS({
    x5c: [leaf, inter, root],
    payload: { bundleId: BUNDLE_ID, receiptType: "Sandbox", appAppleId: 0 },
    key: privateKey("forged-leaf.key"),
  });
  assert.equal(await verify(jws, { root, now: new Date(Date.UTC(2027, 0, 1)) }), null);
});

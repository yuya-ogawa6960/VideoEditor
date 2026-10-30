// AppTransaction(JWS)の検証の守り: 形が違う・連鎖が無い・期限切れの証明書は通さない
import { test } from "node:test";
import assert from "node:assert/strict";
import { verifyAppTransaction, isSandbox, parseCertificate } from "../src/appTransaction.js";

// テスト用に openssl で作った自己署名の証明書(P-256 / SHA-256。2026-10-30 〜 2036-10-27)。鍵は捨てている
const TEST_CERT_B64 = "MIIBczCCARmgAwIBAgIUAe9J+vbGMoDgGdusLBO/0iPRsSswCgYIKoZIzj0EAwIwDzENMAsGA1UEAwwEdGVzdDAeFw0yNjEwMzAxMTI0MDNaFw0zNjEwMjcxMTI0MDNaMA8xDTALBgNVBAMMBHRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAT/BsqH1hUeIBOCennNNu/xaPD5+BeeYIthrL8SPDLhI2svCnfgJ+i8IEMR9WbL/c4WIr+J6WNp7HZw/az0k33Fo1MwUTAdBgNVHQ4EFgQUM+y+FFGwOZ7t6B8L0ZrD5i8qZ9owHwYDVR0jBBgwFoAUM+y+FFGwOZ7t6B8L0ZrD5i8qZ9owDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEA/u+dwcV0xa7/yBeUw8wDrC1e2mRdB/VVNMqT543PqkkCIBnrSgKPJ3V9uiwOAdIouWtg1IwgCzjmv3Agp2sCC5Wt";
const der = Uint8Array.from(Buffer.from(TEST_CERT_B64, "base64"));

test("parseCertificate は有効期間(notBefore / notAfter)を読める", () => {
  const cert = parseCertificate(der);
  assert.ok(cert.notBefore instanceof Date && cert.notAfter instanceof Date);
  assert.equal(cert.notBefore.toISOString(), "2026-10-30T11:24:03.000Z");
  assert.equal(cert.notAfter.toISOString(), "2036-10-27T11:24:03.000Z");
  assert.ok(cert.notBefore < cert.notAfter);
});

test("isSandbox は Sandbox / Xcode だけ", () => {
  assert.equal(isSandbox({ environment: "Sandbox" }), true);
  assert.equal(isSandbox({ environment: "Xcode" }), true);
  assert.equal(isSandbox({ environment: "Production" }), false);
  assert.equal(isSandbox(null), false);
});

test("JWS の形が違う・x5c が無い・Apple のルートにつながらないものは null", async () => {
  const noRoot = { fetchRoot: async () => null };
  assert.equal(await verifyAppTransaction("", noRoot), null);
  assert.equal(await verifyAppTransaction("a.b", noRoot), null);
  const b64url = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  assert.equal(await verifyAppTransaction(b64url({ alg: "ES256" }) + "." + b64url({}) + ".sig", noRoot), null);
  // x5c が 1 枚だけ(連鎖になっていない)
  assert.equal(await verifyAppTransaction(b64url({ alg: "ES256", x5c: [TEST_CERT_B64] }) + "." + b64url({}) + ".sig", noRoot), null);
  // 連鎖の一番上が「ルート」として渡したものと違う
  const wrongRoot = { fetchRoot: async () => new Uint8Array([1, 2, 3]) };
  assert.equal(await verifyAppTransaction(b64url({ alg: "ES256", x5c: [TEST_CERT_B64, TEST_CERT_B64] }) + "." + b64url({}) + ".sig", wrongRoot), null);
});

// 上の証明書の鍵で署名した JWS(bundleId = com.example.app, environment = Sandbox)。連鎖は同じ証明書 2 枚で、ルート = この証明書
const SIGNED_JWS = "eyJhbGciOiJFUzI1NiIsIng1YyI6WyJNSUlCY3pDQ0FSbWdBd0lCQWdJVUFlOUordmJHTW9EZ0dkdXNMQk8vMGlQUnNTc3dDZ1lJS29aSXpqMEVBd0l3RHpFTk1Bc0dBMVVFQXd3RWRHVnpkREFlRncweU5qRXdNekF4TVRJME1ETmFGdzB6TmpFd01qY3hNVEkwTUROYU1BOHhEVEFMQmdOVkJBTU1CSFJsYzNRd1dUQVRCZ2NxaGtqT1BRSUJCZ2dxaGtqT1BRTUJCd05DQUFUL0JzcUgxaFVlSUJPQ2Vubk5OdS94YVBENStCZWVZSXRockw4U1BETGhJMnN2Q25mZ0oraThJRU1SOVdiTC9jNFdJcitKNldOcDdIWncvYXowazMzRm8xTXdVVEFkQmdOVkhRNEVGZ1FVTSt5K0ZGR3dPWjd0NkI4TDBackQ1aThxWjlvd0h3WURWUjBqQkJnd0ZvQVVNK3krRkZHd09aN3Q2QjhMMFpyRDVpOHFaOW93RHdZRFZSMFRBUUgvQkFVd0F3RUIvekFLQmdncWhrak9QUVFEQWdOSUFEQkZBaUVBL3UrZHdjVjB4YTcveUJlVXc4d0RyQzFlMm1SZEIvVlZOTXFUNTQzUHFra0NJQm5yU2dLUEozVjl1aXdPQWRJb3VXdGcxSXdnQ3pqbXYzQWdwMnNDQzVXdCIsIk1JSUJjekNDQVJtZ0F3SUJBZ0lVQWU5Sit2YkdNb0RnR2R1c0xCTy8waVBSc1Nzd0NnWUlLb1pJemowRUF3SXdEekVOTUFzR0ExVUVBd3dFZEdWemREQWVGdzB5TmpFd016QXhNVEkwTUROYUZ3MHpOakV3TWpjeE1USTBNRE5hTUE4eERUQUxCZ05WQkFNTUJIUmxjM1F3V1RBVEJnY3Foa2pPUFFJQkJnZ3Foa2pPUFFNQkJ3TkNBQVQvQnNxSDFoVWVJQk9DZW5uTk51L3hhUEQ1K0JlZVlJdGhyTDhTUERMaEkyc3ZDbmZnSitpOElFTVI5V2JML2M0V0lyK0o2V05wN0hady9hejBrMzNGbzFNd1VUQWRCZ05WSFE0RUZnUVVNK3krRkZHd09aN3Q2QjhMMFpyRDVpOHFaOW93SHdZRFZSMGpCQmd3Rm9BVU0reStGRkd3T1o3dDZCOEwwWnJENWk4cVo5b3dEd1lEVlIwVEFRSC9CQVV3QXdFQi96QUtCZ2dxaGtqT1BRUURBZ05JQURCRkFpRUEvdStkd2NWMHhhNy95QmVVdzh3RHJDMWUybVJkQi9WVk5NcVQ1NDNQcWtrQ0lCbnJTZ0tQSjNWOXVpd09BZElvdVd0ZzFJd2dDemptdjNBZ3Ayc0NDNVd0Il19.eyJidW5kbGVJZCI6ImNvbS5leGFtcGxlLmFwcCIsImVudmlyb25tZW50IjoiU2FuZGJveCIsImFwcEFwcGxlSWQiOjB9.UXcBZEKh9q24mTKyBXj8W6JJHiZkaGbfxcz9ZcBnl9v4LBVslpAlGvqi2LUyyxKmR3B2insfmo7GR8TwaTsnjg";

test("署名も連鎖も正しい JWS は、証明書の有効期間の中だけ通る(期限切れ・期限前は null)", async () => {
  const root = async () => der;
  const inside = await verifyAppTransaction(SIGNED_JWS, { fetchRoot: root, bundleID: "com.example.app", now: new Date("2030-01-01T00:00:00Z") });
  assert.ok(inside, "期間の中では payload が返る");
  assert.equal(inside.environment, "Sandbox");
  assert.equal(isSandbox(inside), true);
  // bundleId が違うアプリ向けなら null
  assert.equal(await verifyAppTransaction(SIGNED_JWS, { fetchRoot: root, bundleID: "com.other.app", now: new Date("2030-01-01T00:00:00Z") }), null);
  // 期間の外では null(署名は正しいまま)
  assert.equal(await verifyAppTransaction(SIGNED_JWS, { fetchRoot: root, now: new Date("2040-01-01T00:00:00Z") }), null);
  assert.equal(await verifyAppTransaction(SIGNED_JWS, { fetchRoot: root, now: new Date("2020-01-01T00:00:00Z") }), null);
  // 署名を 1 ビット変えると null
  const parts = SIGNED_JWS.split(".");
  const sig = Buffer.from(parts[2], "base64url"); sig[10] ^= 1;
  assert.equal(await verifyAppTransaction(parts[0] + "." + parts[1] + "." + sig.toString("base64url"), { fetchRoot: root, now: new Date("2030-01-01T00:00:00Z") }), null);
  // 中身(payload)を書き換えても null
  const tampered = Buffer.from(JSON.stringify({ bundleId: "com.example.app", environment: "Sandbox", appAppleId: 1 })).toString("base64url");
  assert.equal(await verifyAppTransaction(parts[0] + "." + tampered + "." + parts[2], { fetchRoot: root, now: new Date("2030-01-01T00:00:00Z") }), null);
});

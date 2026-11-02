// テストの共通部分: test/fixtures の証明書・鍵を読み、AppTransaction と同じ形の JWS を作る
import { readFileSync } from "node:fs";
import { createPrivateKey, sign } from "node:crypto";

/** fixtures のファイルを文字列で読む */
export function fixture(name) {
  return readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");
}

/** fixtures の PEM の証明書 → DER(Uint8Array) */
export function certificate(name) {
  const body = fixture(name).replace(/-----(BEGIN|END) CERTIFICATE-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(Buffer.from(body, "base64"));
}

/** fixtures の PEM の秘密鍵 */
export function privateKey(name) {
  return createPrivateKey(fixture(name));
}

/** x5c(DER の配列)と中身(payload)で、key で署名した JWS を作る(StoreKit の jwsRepresentation と同じ形) */
export function makeJWS({ x5c, payload, key, alg = "ES256" }) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const input = encode({ alg, x5c: x5c.map((der) => Buffer.from(der).toString("base64")) }) + "." + encode(payload);
  const signature = sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" });
  return input + "." + signature.toString("base64url");
}

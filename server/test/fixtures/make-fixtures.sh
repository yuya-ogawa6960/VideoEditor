#!/usr/bin/env bash
# server/test の AppTransaction のテストで使う証明書を作り直す(OpenSSL 3.4 以降。-not_before / -not_after を使う)
#   実行: bash server/test/fixtures/make-fixtures.sh
#
# 本物の App Store の JWS と同じ形の、テスト専用の使い捨ての連鎖を作る。日付は固定(テストは日時を自分で渡す)
#   root.pem                 ルート(Apple Root CA - G3 の代わり)。P-384、2020-01-01 〜 2055-01-01
#   inter.pem                中間(Apple の中間 CA の代わり)。P-384、OID 1.2.840.113635.100.6.2.1・CA:TRUE、2020-01-01 〜 2040-01-01
#   inter-no-wwdr-oid.pem    ↑と同じ鍵・同じ名前で、OID 1.2.840.113635.100.6.2.1 が無いもの
#   inter-not-ca.pem         ↑と同じ鍵・同じ名前で、basicConstraints が CA:FALSE のもの
#   inter-no-certsign.pem    ↑と同じ鍵・同じ名前で、keyUsage に keyCertSign が無いもの
#   inter-short.pem          ↑と同じ鍵・同じ名前で、2026-03-01 に期限が切れるもの
#   inter-renamed.pem        ↑と同じ鍵で、名前(CN)だけ違うもの(発行者の名前の一致を確かめる用)
#   leaf.pem                 App Store の署名用(OID 1.2.840.113635.100.6.11.1)。P-256、2026-01-01 〜 2028-01-01
#   leaf-no-receipt-oid.pem  同じ鍵で OID 1.2.840.113635.100.6.11.1 が無いもの(開発者がもらえる証明書の代わり)
#   leaf.key                 上の 2 つの秘密鍵。テストの中で JWS を署名するため残す
#                            (テスト専用。本番は Apple Root CA - G3 だけを信頼するので、この連鎖は通らない)
# 中間はどれも同じ鍵なので、leaf.pem の署名はどの中間の鍵でも正しい(中間の中身の違いだけを確かめられる)。
# ルート・中間の秘密鍵は残さない(足すときは全部作り直す)。
#
# forged-*.pem / forged-leaf.key は、PR #2 の確認で作った偽の連鎖(forge.mjs)をそのまま置いたもので、ここでは作らない。
# 「Apple のルートにつながるが、Apple の OID が無い」中間・一番下(Swift Package の署名用の形)で、
# OID を確かめる前の appTransaction.js はこれを通していた。
set -euo pipefail
cd "$(dirname "$0")"
# Windows の Git Bash で -subj の「/C=JP/...」がパスに書き換えられないように(ファイルはすべて相対パスで渡す)
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

work=".make-fixtures.tmp"
rm -rf "$work"
mkdir "$work"
trap 'rm -rf "$work"' EXIT

cat > "$work/ext.cnf" <<'EOF'
[req]
distinguished_name = dn
[dn]

[root]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash

[inter]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
1.2.840.113635.100.6.2.1 = ASN1:NULL

[inter_no_wwdr_oid]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid

[inter_not_ca]
basicConstraints = critical, CA:FALSE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
1.2.840.113635.100.6.2.1 = ASN1:NULL

[inter_no_certsign]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, digitalSignature
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
1.2.840.113635.100.6.2.1 = ASN1:NULL

[leaf]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
1.2.840.113635.100.6.11.1 = ASN1:NULL

[leaf_no_receipt_oid]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF

ROOT_SUBJECT="/C=JP/O=Video Mania Test/CN=Test Root CA - G3"
INTER_SUBJECT="/C=JP/O=Video Mania Test/OU=G6/CN=Test Intermediate CA"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$work/root.key"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$work/inter.key"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out leaf.key

# ルート(自己署名)
openssl req -new -x509 -config "$work/ext.cnf" -extensions root -key "$work/root.key" -subj "$ROOT_SUBJECT" \
  -sha384 -set_serial 1 -not_before 20200101000000Z -not_after 20550101000000Z -out root.pem

# issue <CSR> <発行者の証明書> <発行者の鍵> <ext.cnf の節> <シリアル> <notBefore> <notAfter> <出力>
issue() {
  openssl x509 -req -in "$1" -CA "$2" -CAkey "$3" -extfile "$work/ext.cnf" -extensions "$4" \
    -set_serial "$5" -sha384 -not_before "$6" -not_after "$7" -out "$8"
}

# 中間(同じ鍵・同じ名前で、中身だけ違うもの)
openssl req -new -config "$work/ext.cnf" -key "$work/inter.key" -subj "$INTER_SUBJECT" -out "$work/inter.csr"
issue "$work/inter.csr" root.pem "$work/root.key" inter             2 20200101000000Z 20400101000000Z inter.pem
issue "$work/inter.csr" root.pem "$work/root.key" inter_no_wwdr_oid 3 20200101000000Z 20400101000000Z inter-no-wwdr-oid.pem
issue "$work/inter.csr" root.pem "$work/root.key" inter_not_ca      4 20200101000000Z 20400101000000Z inter-not-ca.pem
issue "$work/inter.csr" root.pem "$work/root.key" inter_no_certsign 5 20200101000000Z 20400101000000Z inter-no-certsign.pem
issue "$work/inter.csr" root.pem "$work/root.key" inter             6 20200101000000Z 20260301000000Z inter-short.pem
openssl req -new -config "$work/ext.cnf" -key "$work/inter.key" -subj "/C=JP/O=Video Mania Test/OU=G6/CN=Another Intermediate CA" -out "$work/renamed.csr"
issue "$work/renamed.csr" root.pem "$work/root.key" inter           7 20200101000000Z 20400101000000Z inter-renamed.pem

# 一番下(App Store の署名用と、OID の無いもの。同じ鍵)
openssl req -new -config "$work/ext.cnf" -key leaf.key -subj "/C=JP/O=Video Mania Test/CN=Test App Store Receipt Signing" -out "$work/leaf.csr"
issue "$work/leaf.csr" inter.pem "$work/inter.key" leaf 8 20260101000000Z 20280101000000Z leaf.pem
openssl req -new -config "$work/ext.cnf" -key leaf.key -subj "/C=JP/O=Video Mania Test/CN=Test Developer Certificate" -out "$work/dev.csr"
issue "$work/dev.csr" inter.pem "$work/inter.key" leaf_no_receipt_oid 9 20260101000000Z 20280101000000Z leaf-no-receipt-oid.pem

echo "作り直しました: $(pwd)"

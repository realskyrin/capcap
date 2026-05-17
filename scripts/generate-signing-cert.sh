#!/usr/bin/env bash
#
# Generate a self-signed code-signing certificate for capcap.
#
# Why this exists:
#   macOS TCC (Screen Recording / Accessibility grants) keys permissions to an
#   app's code-signing identity. CI's ad-hoc signature has no stable identity,
#   so TCC falls back to the binary's cdhash — which changes every build, so
#   users must re-authorize on every update.
#
#   Signing every build with ONE reusable self-signed certificate gives the app
#   a stable Designated Requirement, so TCC keeps the grants across updates.
#   (This is NOT a Developer ID cert — Gatekeeper still shows an "unidentified
#   developer" prompt on first launch. That part is unavoidable without a paid
#   Apple Developer account.)
#
# Run this ONCE, then store the outputs as GitHub Secrets (see bottom). Keep the
# .p12 safe and reuse it forever — regenerating it forces users to re-authorize
# one more time.
#
# Usage:
#   scripts/generate-signing-cert.sh [output_dir]
# Env:
#   CERT_PASSWORD   password protecting the .p12 (default: capcap)
#   CERT_NAME       certificate common name (default: capcap Self-Signed)
#   CERT_DAYS       validity in days (default: 3650 — ~10 years)
#
set -euo pipefail

OUT_DIR="${1:-$HOME/Desktop}"
CERT_NAME="${CERT_NAME:-capcap Self-Signed}"
CERT_PASSWORD="${CERT_PASSWORD:-capcap}"
CERT_DAYS="${CERT_DAYS:-3650}"

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# OpenSSL config: a code-signing leaf cert needs the codeSigning extended key
# usage, or `codesign` refuses to use it as an identity.
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = $CERT_NAME

[v3]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

echo "==> generating RSA key + self-signed cert ($CERT_DAYS days)"
openssl req -x509 -newkey rsa:2048 -sha256 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days "$CERT_DAYS" -nodes -config "$WORK/cert.cnf" >/dev/null 2>&1

P12="$OUT_DIR/capcap-signing.p12"
echo "==> bundling into $P12"
# -legacy: macOS `security import` chokes on OpenSSL 3's default PKCS#12 cipher.
openssl pkcs12 -export -legacy \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CERT_NAME" -out "$P12" \
    -passout "pass:$CERT_PASSWORD"

B64="$OUT_DIR/capcap-signing.p12.base64"
base64 -i "$P12" -o "$B64"

echo ""
echo "✅ done"
echo "   certificate : $P12"
echo "   base64      : $B64"
echo ""
echo "Configure these GitHub repo secrets (Settings → Secrets → Actions):"
echo "   MACOS_CERTIFICATE      = contents of $B64"
echo "   MACOS_CERTIFICATE_PWD  = $CERT_PASSWORD"
echo "   MACOS_SIGNING_IDENTITY = $CERT_NAME"
echo "   KEYCHAIN_PASSWORD      = (any throwaway string)"
echo ""
echo "Keep $P12 backed up — reuse it for every release forever."

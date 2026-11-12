#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: create-signing-cert.sh OUTPUT_DIR" >&2
  exit 2
fi

out="$1"
cert_name="Idasen Self-Signed"

if [[ -n "${OPENSSL:-}" ]]; then
  openssl_bin="$OPENSSL"
else
  openssl_bin="$(brew --prefix openssl)/bin/openssl"
fi
if [[ ! -x "$openssl_bin" ]] || "$openssl_bin" version | grep -q LibreSSL; then
  echo "error: Homebrew OpenSSL is required (brew install openssl). /usr/bin/openssl is LibreSSL and cannot write a PKCS#12 that macOS can import." >&2
  exit 1
fi

if [[ -e "$out" ]] && [[ -n "$(ls -A "$out")" ]]; then
  echo "error: $out already exists and is not empty" >&2
  exit 1
fi
mkdir -p "$out"
chmod 700 "$out"
out="$(cd "$out" && pwd)"
umask 077

"$openssl_bin" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$out/key.pem" -out "$out/cert.pem" -subj "/CN=$cert_name" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

"$openssl_bin" rand -hex 16 | tr -d '\n' > "$out/p12-password.txt"
"$openssl_bin" pkcs12 -export -legacy -inkey "$out/key.pem" -in "$out/cert.pem" \
  -name "$cert_name" -out "$out/idasen.p12" -passout "file:$out/p12-password.txt"

"$openssl_bin" x509 -in "$out/cert.pem" -noout -fingerprint -sha1 \
  | sed 's/.*=//; s/://g' > "$out/signing-cert.sha1"

cat <<MSG
Created in $out:
  key.pem, cert.pem, idasen.p12, p12-password.txt, signing-cert.sha1
Certificate SHA-1: $(cat "$out/signing-cert.sha1")

Nothing was uploaded or committed. Next steps:

1. Store key.pem, idasen.p12 and p12-password.txt in a password manager. Losing the key means one
   more Bluetooth prompt for every user when switching to a new certificate. It is valid for 10 years.

2. Set the repository secrets (from the repository checkout):
     base64 -i "$out/idasen.p12" | gh secret set SIGNING_CERT_P12
     gh secret set SIGNING_CERT_PASSWORD < "$out/p12-password.txt"

3. Commit the certificate hash:
     cp "$out/signing-cert.sha1" .github/signing-cert.sha1
     git add .github/signing-cert.sha1
MSG

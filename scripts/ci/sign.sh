#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<USAGE
usage: sign.sh [--adhoc] [--identity NAME] [--entitlements FILE] Idasen.app

Signs Contents/Helpers/idasen first, then the app, without --deep and without the hardened runtime.
Certificate mode reads SIGNING_CERT_P12 (base64 .p12) and SIGNING_CERT_PASSWORD from the environment
and imports them into a temporary keychain that is deleted on exit.
--adhoc signs with "-" instead and needs neither.
USAGE
  exit 2
}

CLI_IDENTIFIER="io.github.michalpodeszwa.idasen.cli"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
identity="Idasen Self-Signed"
entitlements="$repo_root/App/Resources/Idasen.entitlements"
adhoc=false
app=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --adhoc) adhoc=true ;;
    --identity) identity="${2:?--identity needs a value}"; shift ;;
    --entitlements) entitlements="${2:?--entitlements needs a value}"; shift ;;
    -h | --help) usage ;;
    -*) echo "error: unknown option $1" >&2; usage ;;
    *) [[ -z "$app" ]] || usage; app="$1" ;;
  esac
  shift
done

[[ -n "$app" ]] || usage
cli="$app/Contents/Helpers/idasen"
[[ -d "$app" ]] || { echo "error: $app is not a directory" >&2; exit 1; }
[[ -f "$cli" ]] || { echo "error: $cli not found" >&2; exit 1; }
[[ -f "$entitlements" ]] || { echo "error: entitlements file $entitlements not found" >&2; exit 1; }

keychain_args=()
if $adhoc; then
  sign_identity="-"
else
  : "${SIGNING_CERT_P12:?SIGNING_CERT_P12 (base64 .p12) is not set; pass --adhoc to sign ad-hoc}"
  : "${SIGNING_CERT_PASSWORD:?SIGNING_CERT_PASSWORD is not set}"
  sign_identity="$identity"

  work="$(mktemp -d)"
  keychain="$work/signing.keychain-db"

  cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -rf "$work"
  }
  trap cleanup EXIT

  keychain_password="$(openssl rand -hex 16)"
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  printf '%s' "$SIGNING_CERT_P12" | base64 -d > "$work/cert.p12"
  security import "$work/cert.p12" -k "$keychain" -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
  rm -f "$work/cert.p12"

  if ! security find-identity -p codesigning "$keychain" | grep -qF "\"$identity\""; then
    echo "error: the .p12 does not contain a certificate with a private key named '$identity'" >&2
    exit 1
  fi
  keychain_args=(--keychain "$keychain")
fi

codesign --force ${keychain_args[@]+"${keychain_args[@]}"} -s "$sign_identity" --timestamp=none \
  -i "$CLI_IDENTIFIER" "$cli"
codesign --force ${keychain_args[@]+"${keychain_args[@]}"} -s "$sign_identity" --timestamp=none \
  --entitlements "$entitlements" "$app"

echo "signed $app ($($adhoc && echo ad-hoc || echo "$identity"))"

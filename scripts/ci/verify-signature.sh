#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<USAGE
usage: verify-signature.sh [--adhoc] Idasen.app [CERT_SHA1]

Strict-verifies the app and its CLI, checks their signing identifiers, then checks that both
designated requirements are 'identifier "<id>" and certificate leaf = H"<sha1>"'.
CERT_SHA1 defaults to the contents of .github/signing-cert.sha1.
--adhoc skips the certificate check and only runs the strict verification and the identifier check.
USAGE
  exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sha_file="$repo_root/.github/signing-cert.sha1"
adhoc=false
args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --adhoc) adhoc=true ;;
    -h | --help) usage ;;
    -*) echo "error: unknown option $1" >&2; usage ;;
    *) args+=("$1") ;;
  esac
  shift
done

((${#args[@]} >= 1 && ${#args[@]} <= 2)) || usage
app="${args[0]}"
cli="$app/Contents/Helpers/idasen"
[[ -d "$app" ]] || { echo "error: $app is not a directory" >&2; exit 1; }
[[ -f "$cli" ]] || { echo "error: $cli not found" >&2; exit 1; }

APP_IDENTIFIER="io.github.michalpodeszwa.idasen"
CLI_IDENTIFIER="io.github.michalpodeszwa.idasen.cli"

codesign --verify --strict --deep --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$cli"

status=0
for entry in "$app:$APP_IDENTIFIER" "$cli:$CLI_IDENTIFIER"; do
  target="${entry%:*}"
  want="${entry##*:}"
  have="$(codesign -d --verbose=2 "$target" 2>&1 | sed -n 's/^Identifier=//p')"
  if [[ "$have" != "$want" ]]; then
    echo "error: $target has signing identifier '$have', expected '$want'" >&2
    status=1
  fi
done
((status == 0)) || exit 1

if $adhoc; then
  echo "strict verification passed (ad-hoc, certificate not checked)"
  exit 0
fi

if ((${#args[@]} == 2)); then
  expected="${args[1]}"
elif [[ -f "$sha_file" ]]; then
  expected="$(cat "$sha_file")"
else
  cat >&2 <<MSG
error: $sha_file does not exist, so there is no certificate identity to verify against.
Create the release certificate once with scripts/create-signing-cert.sh <output-dir>, copy the
<output-dir>/signing-cert.sha1 it writes to .github/signing-cert.sha1, and commit it.
MSG
  exit 1
fi

expected="$(printf '%s' "$expected" | tr -d '[:space:]:' | tr '[:upper:]' '[:lower:]')"
if ! [[ "$expected" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: '$expected' is not a SHA-1 (40 hex characters)" >&2
  exit 1
fi

for entry in "$app:$APP_IDENTIFIER" "$cli:$CLI_IDENTIFIER"; do
  target="${entry%:*}"
  want="${entry##*:}"
  requirement="$(codesign -d -r- "$target" 2>&1 | grep '^designated' || true)"
  if [[ "$(printf '%s' "$requirement" | tr '[:upper:]' '[:lower:]')" == *"identifier \"$want\" and certificate leaf = h\"$expected\""* ]]; then
    echo "ok: $target is pinned to $want and certificate $expected"
  else
    echo "error: $target designated requirement is not 'identifier \"$want\" and certificate leaf = H\"$expected\"':" >&2
    echo "${requirement:-no designated requirement found}" >&2
    status=1
  fi
done
exit "$status"

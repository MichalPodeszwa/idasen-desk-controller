#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: package.sh Idasen.app VERSION OUTPUT_DIR" >&2
  exit 2
fi

app="$1"
version="$2"
out="$3"

[[ -d "$app" ]] || { echo "error: $app is not a directory" >&2; exit 1; }
[[ "$version" =~ ^[0-9A-Za-z.-]+$ ]] || { echo "error: invalid version '$version'" >&2; exit 1; }

mkdir -p "$out"
zip_name="Idasen-${version}-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$zip_name"
(cd "$out" && shasum -a 256 "$zip_name" > SHA256SUMS.txt)

echo "$out/$zip_name"
echo "$out/SHA256SUMS.txt"

#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: version-from-tag.sh vMAJOR.MINOR.PATCH[-prerelease]" >&2
  exit 2
fi

tag="$1"
num='0|[1-9][0-9]*'
ident='[0-9A-Za-z-]+'
re="^v(${num})\.(${num})\.(${num})(-${ident}(\.${ident})*)?$"

if ! [[ "$tag" =~ $re ]]; then
  echo "error: '$tag' is not a valid release tag (expected vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-suffix)" >&2
  exit 1
fi

version="${tag#v}"
marketing="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
prerelease=false
if [[ -n "${BASH_REMATCH[4]}" ]]; then
  prerelease=true
fi

echo "version=$version"
echo "marketing_version=$marketing"
echo "prerelease=$prerelease"

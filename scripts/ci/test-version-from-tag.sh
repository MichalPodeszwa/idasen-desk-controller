#!/usr/bin/env bash
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/version-from-tag.sh"
failures=0

expect_ok() {
  local tag="$1" expected="$2" actual
  if ! actual="$("$script" "$tag" 2>/dev/null)"; then
    echo "FAIL: '$tag' was rejected"
    failures=$((failures + 1))
  elif [[ "$actual" != "$expected" ]]; then
    echo "FAIL: '$tag' gave:"$'\n'"$actual"$'\n'"expected:"$'\n'"$expected"
    failures=$((failures + 1))
  fi
}

expect_reject() {
  local tag="$1"
  if "$script" "$tag" >/dev/null 2>&1; then
    echo "FAIL: '$tag' was accepted"
    failures=$((failures + 1))
  fi
}

expect_ok v1.2.3 $'version=1.2.3\nmarketing_version=1.2.3\nprerelease=false'
expect_ok v0.0.1 $'version=0.0.1\nmarketing_version=0.0.1\nprerelease=false'
expect_ok v10.20.30 $'version=10.20.30\nmarketing_version=10.20.30\nprerelease=false'
expect_ok v1.0.0-beta.1 $'version=1.0.0-beta.1\nmarketing_version=1.0.0\nprerelease=true'
expect_ok v2.1.0-rc1 $'version=2.1.0-rc1\nmarketing_version=2.1.0\nprerelease=true'
expect_ok v0.0.0-dryrun.7 $'version=0.0.0-dryrun.7\nmarketing_version=0.0.0\nprerelease=true'

for bad in "" v 1.2.3 v1 v1.2 v1.2.3.4 v01.2.3 v1.02.3 v1.2.03 v1.2.3- v1.2.3-beta. v1.2.3-be_ta \
  v1.2.3+build v1.2.3-beta+1 V1.2.3 vx.y.z "v1.2.3 " " v1.2.3" "v1.2.3-beta 1" release-1 refs/tags/v1.2.3; do
  expect_reject "$bad"
done

if "$script" >/dev/null 2>&1; then
  echo "FAIL: no argument was accepted"
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  echo "$failures failure(s)"
  exit 1
fi
echo "version-from-tag: all tests passed"

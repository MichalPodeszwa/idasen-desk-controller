#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/../.."

failures=0

check() {
  local description=$1 haystack=$2 needle=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok   $description"
  else
    echo "FAIL $description: expected to find '$needle' in:" >&2
    echo "$haystack" >&2
    failures=$((failures + 1))
  fi
}

check_absent() {
  local description=$1 haystack=$2 needle=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "FAIL $description: did not expect '$needle' in:" >&2
    echo "$haystack" >&2
    failures=$((failures + 1))
  else
    echo "ok   $description"
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

out=$(HOME="$work" scripts/hw-log.sh --dry-run)
check "default output is on the Desktop" "$out" "output: $work/Desktop/idasen-hw-logs/idasen-"
check "streams at debug level" "$out" "log stream --level debug"
check "covers the release bundle ID" "$out" 'subsystem == "io.github.michalpodeszwa.idasen"'
check "covers the debug bundle ID" "$out" 'subsystem == "io.github.michalpodeszwa.idasen.debug"'
[ ! -e "$work/Desktop" ] && echo "ok   dry run creates nothing" || { echo "FAIL dry run created files" >&2; failures=$((failures + 1)); }

out=$(scripts/hw-log.sh --dry-run "$work/session.log")
check "explicit file path" "$out" "output: $work/session.log"

mkdir "$work/logs"
out=$(scripts/hw-log.sh --dry-run "$work/logs")
check "directory path gets a timestamped file" "$out" "output: $work/logs/idasen-"

out=$(scripts/hw-log.sh --dry-run --since 30m)
check "since uses log show with info and debug" "$out" "log show --last 30m --info --debug"

out=$(scripts/hw-log.sh --dry-run --bundle-id io.github.michalpodeszwa.idasen.debug)
check "single bundle ID" "$out" 'subsystem == "io.github.michalpodeszwa.idasen.debug"'
check_absent "single bundle ID excludes the release ID" "$out" 'subsystem == "io.github.michalpodeszwa.idasen"'

check "marks are part of the predicate" "$out" 'eventMessage BEGINSWITH "[idasen-mark]"'

RC=0
scripts/hw-log.sh --bogus >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ] && echo "ok   unknown option exits 2" || { echo "FAIL unknown option exit $RC" >&2; failures=$((failures + 1)); }

[ "$failures" -eq 0 ] || exit 1
echo "hw-log: all checks passed"

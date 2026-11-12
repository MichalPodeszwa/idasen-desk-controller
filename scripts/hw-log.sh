#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE_IDS=(io.github.michalpodeszwa.idasen io.github.michalpodeszwa.idasen.debug)
DEFAULT_DIR="$HOME/Desktop/idasen-hw-logs"
MARK_PREFIX="[idasen-mark]"

usage() {
  cat <<USAGE
usage: hw-log.sh [--since DURATION] [--bundle-id ID] [--dry-run] [PATH]
       hw-log.sh --mark TEXT

Collects the Idasen app's diagnostic log (subsystem = bundle ID, categories
ble, controller, ipc, app) into a timestamped file.

  (default)        stream live until Ctrl-C. Start it BEFORE the test session:
                   debug-level lines (every reading, every tick) are not kept
                   by macOS, so they can only be captured live.
  --since 30m      instead collect what macOS still has from the last 30m
                   (also 2h, 1d). Lossy: debug-level lines are missing.
  --bundle-id ID   only this bundle ID. Default: both the release app
                   (${BUNDLE_IDS[0]}) and the debug build (${BUNDLE_IDS[1]}).
  --dry-run        print the command and the output file, run nothing.
  --mark TEXT      write a "[idasen-mark] TEXT" line into the running capture, so
                   the log can be split per test step. Run it from another terminal.
  PATH             output file, or a directory to put the timestamped file in.
                   Default: $DEFAULT_DIR/idasen-<timestamp>.log
USAGE
}

since=""
dry_run=0
mark=""
mark_set=0
output=""
ids=()
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since=${2:?--since needs a duration such as 30m}; shift 2 ;;
    --bundle-id) ids+=("${2:?--bundle-id needs a value}"); shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --mark) mark=${2:?--mark needs a text}; mark_set=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "hw-log: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) [ -z "$output" ] || { echo "hw-log: more than one PATH" >&2; exit 2; }; output=$1; shift ;;
  esac
done
[ ${#ids[@]} -gt 0 ] || ids=("${BUNDLE_IDS[@]}")

if [ "$mark_set" = 1 ]; then
  logger "$MARK_PREFIX $mark"
  echo "hw-log: marked '$mark'"
  exit 0
fi

predicate=""
for id in "${ids[@]}"; do
  predicate+="${predicate:+ OR }subsystem == \"$id\""
done
predicate+=" OR (process == \"logger\" AND eventMessage BEGINSWITH \"$MARK_PREFIX\")"

stamp=$(date +%Y%m%d-%H%M%S)
if [ -z "$output" ]; then
  output="$DEFAULT_DIR/idasen-$stamp.log"
elif [ -d "$output" ] || [[ "$output" == */ ]]; then
  output="${output%/}/idasen-$stamp.log"
fi

if [ -n "$since" ]; then
  command=(log show --last "$since" --info --debug --style compact --predicate "$predicate")
else
  command=(log stream --level debug --style compact --predicate "$predicate")
fi

if [ "$dry_run" = 1 ]; then
  echo "output: $output"
  echo "predicate: $predicate"
  printf 'command:'
  printf ' %q' "${command[@]}"
  echo
  exit 0
fi

mkdir -p "$(dirname "$output")"
{
  echo "# idasen hw-log $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "# host: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
  echo "# predicate: $predicate"
  printf '# command:'
  printf ' %q' "${command[@]}"
  echo
} >"$output"

echo "hw-log: writing to $output"

child=""
finish() {
  [ -z "$child" ] || kill "$child" 2>/dev/null || true
  wait 2>/dev/null || true
  lines=$(grep -c '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ' "$output" || true)
  echo
  echo "hw-log: $lines log lines in $output"
}
trap finish EXIT
trap 'exit 0' INT
trap 'exit 143' TERM

if [ -n "$since" ]; then
  "${command[@]}" >>"$output" 2>&1
else
  "${command[@]}" >>"$output" 2>&1 &
  child=$!
  for _ in $(seq 1 50); do
    grep -q '^Filtering the log data' "$output" && break
    sleep 0.1
  done
  echo "hw-log: streaming, ready for marks. Press Ctrl-C when the session is over"
  wait "$child"
fi

#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

command -v jq >/dev/null || { echo "e2e: jq is required" >&2; exit 2; }

if [ "${E2E_SKIP_BUILD:-0}" != 1 ]; then
  make build >/dev/null
fi

APP=$(make -s app-path)
APP_BINARY="$APP/Contents/MacOS/Idasen"
CLI="$APP/Contents/Helpers/idasen"
[ -x "$APP_BINARY" ] || { echo "e2e: no app at $APP" >&2; exit 2; }
[ -x "$CLI" ] || { echo "e2e: no CLI at $CLI" >&2; exit 2; }

bundle_id=$(defaults read "$APP/Contents/Info" CFBundleIdentifier) \
  || { echo "e2e: cannot read the bundle identifier of $APP" >&2; exit 2; }
case "$bundle_id" in
  *.debug) ;;
  *) echo "e2e: refusing to run a non-debug build ($bundle_id)" >&2; exit 2 ;;
esac

SUPPORT_DIR=$(mktemp -d /tmp/idasen-e2e.XXXXXX)
export IDASEN_SUPPORT_DIR="$SUPPORT_DIR"
SOCKET="$SUPPORT_DIR/control.sock"
LOG="$SUPPORT_DIR/app.log"

[ "${#SOCKET}" -lt 104 ] || { echo "e2e: socket path too long: $SOCKET" >&2; exit 2; }

APP_PID=""
SECOND_PID=""
BACKGROUND_PIDS=()
failures=0

cleanup() {
  local status=$?
  local pid
  for pid in ${BACKGROUND_PIDS[@]+"${BACKGROUND_PIDS[@]}"} $SECOND_PID $APP_PID; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  if [ "$status" -eq 0 ] && [ "$failures" -eq 0 ]; then
    rm -rf "$SUPPORT_DIR"
  else
    echo "e2e: failed (exit $status). Logs and state kept in $SUPPORT_DIR" >&2
    tail -n 20 "$LOG" 2>/dev/null | sed 's/^/e2e: app.log: /' >&2 || true
  fi
}
trap cleanup EXIT
trap 'echo "FAIL unexpected error at line $LINENO: $BASH_COMMAND" >&2; failures=$((failures + 1))' ERR

idasen() {
  "$CLI" --no-launch "$@"
}

OUT=""
RC=0
capture() {
  RC=0
  OUT=$("$@" 2>&1) || RC=$?
}

pass() {
  echo "ok   $1"
}

fail() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
  exit 1
}

expect_rc() {
  local description=$1 expected=$2
  shift 2
  capture "$@"
  [ "$RC" -eq "$expected" ] || fail "$description: exit $RC, expected $expected ($OUT)"
  pass "$description"
}

expect_equal() {
  [ "$2" = "$3" ] || fail "$1: got '$2', expected '$3'"
  pass "$1"
}

expect_near() {
  local description=$1 value=$2 expected=$3 tolerance=$4
  awk -v v="$value" -v e="$expected" -v t="$tolerance" \
    'BEGIN { d = v - e; if (d < 0) d = -d; exit !(d <= t) }' \
    || fail "$description: got '$value', expected $expected ± $tolerance"
  pass "$description"
}

wait_until() {
  local description=$1 timeout=$2
  shift 2
  local deadline=$((SECONDS + timeout))
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "$description: timed out after ${timeout}s"
    sleep 0.1
  done
  pass "$description"
}

is_moving() {
  [ "$(idasen status --json | jq -r .moving)" = true ]
}

is_stopped() {
  [ "$(idasen status --json | jq -r .moving)" = false ]
}

is_dead() {
  ! kill -0 "$1" 2>/dev/null
}

socket_exists() {
  [ -S "$SOCKET" ]
}

socket_gone() {
  [ ! -e "$SOCKET" ]
}

capture "$CLI" --no-launch status
[ "$RC" -eq 3 ] || fail "isolation: CLI with the temp support dir should find no app (exit $RC: $OUT)"
case "$OUT" in
  *"$SOCKET"*) ;;
  *) fail "isolation: CLI does not use the temp socket $SOCKET ($OUT)" ;;
esac
pass "isolation: CLI resolves to the temp socket and nothing listens there"

"$APP_BINARY" --simulate >"$LOG" 2>&1 &
APP_PID=$!
wait_until "app creates the socket" 15 socket_exists

capture idasen --version
[ "$RC" -eq 0 ] && pass "idasen --version ($OUT)" || fail "idasen --version"

capture idasen height
[ "$RC" -eq 0 ] || fail "height: exit $RC ($OUT)"
expect_equal "height right after launch" "$OUT" "72.0"

capture idasen status --json
[ "$RC" -eq 0 ] || fail "status --json: exit $RC ($OUT)"
expect_equal "status state" "$(jq -r .state <<<"$OUT")" connected
expect_equal "status moving" "$(jq -r .moving <<<"$OUT")" false
expect_equal "status range" "$(jq -r '"\(.minCm)-\(.maxCm)"' <<<"$OUT")" "62-127"
expect_rc "status (human)" 0 idasen status

capture idasen move 100
[ "$RC" -eq 0 ] || fail "move 100: exit $RC ($OUT)"
expect_near "move 100 prints the settled height" "$OUT" 100 0.5
is_stopped || fail "move 100 left the desk moving"
pass "move 100 left the desk stopped"

expect_rc "up 2 --no-wait" 0 idasen up 2 --no-wait
wait_until "desk is moving after up 2 --no-wait" 5 is_moving
expect_rc "stop" 0 idasen stop
wait_until "desk stopped after stop" 5 is_stopped
capture idasen height
expect_near "height after up 2 + stop is above 100" "$OUT" 101 1.5

capture idasen positions --json
expect_equal "no positions at first" "$OUT" "[]"
expect_rc "positions save Sit" 0 idasen positions save Sit --height 72
expect_rc "positions save Stand" 0 idasen positions save Stand --height 110
capture idasen positions --json
expect_equal "positions list order" "$(jq -r 'map(.name) | join(",")' <<<"$OUT")" "Sit,Stand"
expect_equal "position height" "$(jq -r '.[1].heightCm' <<<"$OUT")" 110
expect_equal "positions file version" \
  "$(jq -r .version "$SUPPORT_DIR/positions.json")" 1
expect_rc "positions rename" 0 idasen positions rename Sit Sitting
capture idasen positions --json
expect_equal "renamed position" "$(jq -r '.[0].name' <<<"$OUT")" Sitting
capture idasen move stand
[ "$RC" -eq 0 ] || fail "move stand (case-insensitive): exit $RC ($OUT)"
expect_near "move to a named position" "$OUT" 110 0.5
expect_rc "positions remove" 0 idasen positions remove Stand
capture idasen positions --json
expect_equal "removed position is gone" "$(jq -r 'map(.name) | join(",")' <<<"$OUT")" Sitting

expect_rc "positions save with diacritics" 0 idasen positions save "Żółte biurko" --height 95
capture idasen positions --json
expect_equal "slug in positions --json" "$(jq -r '.[] | select(.name == "Żółte biurko") | .slug' <<<"$OUT")" zolte-biurko
capture idasen positions
case "$OUT" in
  *"Żółte biurko  zolte-biurko  95.0 cm"*) pass "slug in human positions output" ;;
  *) fail "slug in human positions output ($OUT)" ;;
esac
expect_rc "save with a colliding slug" 9 idasen positions save "ZOLTE biurko!"
capture idasen move zolte-biurko
[ "$RC" -eq 0 ] || fail "move by slug: exit $RC ($OUT)"
expect_near "move by slug" "$OUT" 95 0.5
capture idasen move ZOLTE-BIURKO
[ "$RC" -eq 0 ] || fail "move by upper-case slug: exit $RC ($OUT)"
expect_rc "unknown slug prefix" 6 idasen move zolte
expect_rc "remove by slug" 0 idasen positions remove zolte-biurko
capture idasen positions --json
expect_equal "slug-removed position is gone" "$(jq -r 'map(.name) | join(",")' <<<"$OUT")" Sitting

expect_rc "unknown position" 6 idasen move Nowhere
expect_rc "out of range" 5 idasen move 200
expect_rc "numeric position name" 9 idasen positions save 123
expect_rc "rename to a numeric name" 9 idasen positions rename Sitting 1e3
expect_rc "remove unknown position" 6 idasen positions remove Nowhere
expect_rc "usage error" 2 idasen up -3

expect_rc "move 90 --no-wait" 0 idasen move 90 --no-wait
WATCH_OUT="$SUPPORT_DIR/watch.out"
"$CLI" --no-launch watch --json >"$WATCH_OUT" 2>&1 &
watch_pid=$!
BACKGROUND_PIDS+=("$watch_pid")
sleep 2
kill -TERM "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
jq -e . "$WATCH_OUT" >/dev/null || fail "watch --json is not valid JSON lines"
moving_events=$(jq -s '[.[] | select(.event == "height" and .state == "moving" and .speedCmS != 0)] | length' "$WATCH_OUT")
[ "$moving_events" -ge 3 ] || fail "watch --json: only $moving_events moving height events in 2 s"
pass "watch --json during a move shows moving events ($moving_events)"
heights=$(jq -s '[.[] | select(.event == "height") | .heightCm] | (.[0] != .[-1])' "$WATCH_OUT")
expect_equal "watch --json heights change during the move" "$heights" true
expect_rc "stop after watch" 0 idasen stop
wait_until "desk stopped after watch test" 5 is_stopped

"$CLI" --no-launch move 125 >"$SUPPORT_DIR/sigint.out" 2>&1 &
move_pid=$!
BACKGROUND_PIDS+=("$move_pid")
wait_until "blocking move is running" 5 is_moving
sleep 1
kill -INT "$move_pid" || fail "could not signal the waiting move"
RC=0
wait "$move_pid" || RC=$?
expect_equal "Ctrl-C on a waiting move exits 130" "$RC" 130
wait_until "desk stopped after Ctrl-C" 5 is_stopped
capture idasen height
awk -v h="$OUT" 'BEGIN { exit !(h < 124) }' || fail "desk reached the target despite Ctrl-C ($OUT)"
pass "desk did not continue to the target after Ctrl-C ($OUT)"

"$APP_BINARY" --simulate >"$SUPPORT_DIR/second.log" 2>&1 &
SECOND_PID=$!
socket_inode=$(stat -f %i "$SOCKET")
wait_until "second instance exits" 15 is_dead "$SECOND_PID"
RC=0
wait "$SECOND_PID" || RC=$?
expect_equal "second instance exit code" "$RC" 0
SECOND_PID=""
expect_rc "first instance still answers" 0 idasen status
socket_exists || fail "second instance removed the first instance's socket"
expect_equal "second instance left the socket alone" "$(stat -f %i "$SOCKET")" "$socket_inode"

kill -TERM "$APP_PID"
wait_until "app quits on SIGTERM" 15 is_dead "$APP_PID"
APP_PID=""
socket_gone || fail "socket file still exists after quit"
pass "socket removed after quit"
expect_rc "CLI without the app exits 3" 3 idasen status

echo "e2e: all checks passed"

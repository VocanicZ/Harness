#!/usr/bin/env bash
# test_usage_text.sh — #1131 / PRD #475: the usage text and docs/reference.md describe the real behaviour on both
# session backends (tmux, headless) and both OSes (Linux, Windows): attach, supervise/web --install, uninstall --force-engine.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"; pin_host_home "$TMP/hh"; mkdir -p "$HARNESS_HOME"
U="$(bash "$ROOT/bin/harness" help 2>&1)"
DOC="$ROOT/docs/reference.md"
has(){ grep -qF -- "$2" <<<"$1"; }
row(){ grep -F -- "$1" "$DOC" | head -1; }

echo "=== usage: attach ==="
A="$(grep -A1 '^  attach ' <<<"$U")"
assert_no "attach is no longer 'tmux-attach to a session'" has "$U" "tmux-attach to a session"
assert_ok "attach usage names the tmux detach key" has "$A" "Ctrl-b d"
assert_ok "attach usage says typed lines are sent to the lane" has "$A" "typed line is sent to the lane"
assert_ok "attach usage says Ctrl-C detaches" has "$A" "Ctrl-C detaches"

echo "=== usage: supervise / web --install on Windows ==="
assert_ok "supervise --install names the Windows Task Scheduler task" has "$(grep -A2 '^  supervise ' <<<"$U")" "Task Scheduler task"
assert_ok "web --install names the Windows Task Scheduler task" has "$(grep -A3 '^  web ' <<<"$U")" "Task Scheduler task"

echo "=== usage: uninstall --force-engine on Windows ==="
assert_ok "uninstall usage says --force-engine is refused on Windows while another fleet uses the engine" \
  has "$(grep '^  uninstall ' <<<"$U")" "on Windows it is refused while another fleet uses the engine"

echo "=== attach.sh header ==="
H="$(sed -n 1,8p "$ROOT/scripts/attach.sh")"
assert_ok "attach.sh header names Ctrl-C detach and headless send" bash -c 'grep -qF "Ctrl-C detaches" <<<"$1" && grep -qF "typed line is sent" <<<"$1"' _ "$H"
assert_ok "attach.sh header keeps the tmux detach key" has "$H" "Ctrl-b d"

echo "=== uninstall.sh header ==="
assert_ok "uninstall.sh header says Windows refuses --force-engine while another fleet uses the engine" \
  has "$(sed -n 1,8p "$ROOT/scripts/uninstall.sh")" "On Windows it is REFUSED"

echo "=== docs/reference.md ==="
R="$(row '| `attach <unit> [issue]`')"
assert_no "reference attach row is no longer 'tmux-attach to a running session'" has "$R" "tmux-attach to a running session"
assert_ok "reference attach row: tmux detach key" has "$R" "Ctrl-b d"
assert_ok "reference attach row: typed lines go to the lane" has "$R" "each line you type is sent to the lane"
assert_ok "reference attach row: Ctrl-C detaches" has "$R" "Ctrl-C"
assert_ok "reference supervise row names the Windows task" has "$(row '| `supervise [--once]')" "Task Scheduler task"
assert_ok "reference web row names the Windows task" has "$(row '| `web` |')" "Task Scheduler task"
UR="$(row '| `uninstall [--force] [--force-engine]`')"
assert_ok "reference has an uninstall row" test -n "$UR"
assert_ok "reference uninstall row: refused on Windows while another fleet uses the engine" has "$UR" "on Windows it is refused while another fleet still uses the engine"

echo "=== unwritable stdout (#1268): ONE short stderr line naming stdout, a non-zero status ==="
P="$TMP/proj"; mkdir -p "$P/.harness"; echo "REPO=o/r" > "$P/.harness/config"
for c in "status" "update --help" "uninstall --help" "doctor"; do
  ( cd "$P" && env -u STATE_DIR -u ENGINE_DIR bash "$ROOT/bin/harness" $c >/dev/full 2>"$TMP/full.err" ); rc=$?
  assert_ok "harness $c > /dev/full: a non-zero status" test "$rc" -ne 0
  assert_ok "harness $c > /dev/full: exactly one stderr line" test "$(wc -l < "$TMP/full.err")" -eq 1
  assert_ok "harness $c > /dev/full: the line names stdout" grep -qF "stdout" "$TMP/full.err"
  assert_no "harness $c > /dev/full: no script path or 'line N:' in it" grep -qE '\.sh|line [0-9]+:' "$TMP/full.err"
  out="$(cd "$P" && env -u STATE_DIR -u ENGINE_DIR bash "$ROOT/bin/harness" $c 2>&1 >/dev/null </dev/null | head -c 300)"
  assert_no "harness $c to /dev/null: still no stderr noise" test -n "$out"
done
finish

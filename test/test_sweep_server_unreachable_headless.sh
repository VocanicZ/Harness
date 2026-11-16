#!/usr/bin/env bash
# test_sweep_server_unreachable_headless.sh — #1168: the headless twin of test_sweep_server_unreachable.sh. A headless lane is files
# under the fleet's own dir, so there is no server to lose: sess_server_reachable is always true, and gc_orphan_goals /
# stats_sweep_ended sweep a session no lane runs exactly as before, whatever TMUX_TMPDIR points at. No tmux.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
log(){ :; }
export HARNESS_SESSION_BACKEND=headless HARNESS_HEADLESS_DIR="$RUN_DIR/headless"
EVENTS="$RUN_DIR/events"; SWEPT="$RUN_DIR/swept"; : > "$EVENTS"; : > "$SWEPT"
harness_event(){ echo "$1" >> "$EVENTS"; }
sess_sweep(){ echo "$1" >> "$SWEPT"; }
churn_check(){ :; }
_stats_cli_usage(){ :; }

mk(){ local s="$1"
  echo ISSUE:7 > "$RUN_DIR/$s.goal"; echo /w > "$RUN_DIR/$s.wd"; : > "$RUN_DIR/$s.loop"; : > "$RUN_DIR/$s.loop.lock"
  printf '{"session":"uuid-%s","repo":"o/r","issue":"7","kind":"impl"}\n' "$s" > "$RUN_DIR/$s.stats"; }
echo "== headless backend: the probe is true and the sweeps still run =="
export TMUX_TMPDIR="$RUN_DIR/no-such-dir"
assert_ok "the headless probe is always true" sess_server_reachable
mk hzfk-dead; echo /w > "$RUN_DIR/hzfk-wdonly.wd"
gc_orphan_goals
for e in goal wd loop loop.lock stats; do assert_no "headless: a session no lane runs has its .$e swept" test -e "$RUN_DIR/hzfk-dead.$e"; done
assert_no "headless: the .wd-only orphan is swept" test -e "$RUN_DIR/hzfk-wdonly.wd"
assert_eq "$(cat "$EVENTS")" "session_end" "headless: session_end emitted"
assert_eq "$(cat "$SWEPT")" "uuid-hzfk-dead" "headless: sess_sweep ran"
finish

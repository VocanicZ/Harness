#!/usr/bin/env bash
# test_sweep_server_unreachable.sh — #1168: the orphan sweeps never read "the tmux server is unreachable" as
# "no session is live". A claude lane runs under bwrap with an EMPTY tmpfs over the fleet's tmux socket dir, yet
# sees the fleet's run/ read-write; gc_orphan_goals / stats_sweep_ended there deleted every lane's .goal/.wd/
# .loop/.loop.lock and consumed every .stats (no session_end, no sess_sweep), so finished lanes were never reaped.
#   1. server reachable: a missing session is still swept (.goal/.wd/.loop/.loop.lock, the #610 .wd-only case),
#      a live session's files are kept, an ended session's .stats is consumed (session_end + sess_sweep)
#   2. server UNREACHABLE (private empty TMUX_TMPDIR): nothing is deleted or consumed, no session_end, no sess_sweep
#   3. the headless backend still sweeps as before (its probe is always true)
# Real tmux, two private short TMUX_TMPDIRs: L holds the "fleet's" server, H is the empty sandbox view.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
log(){ :; }
command -v tmux >/dev/null || { echo "  skip: tmux not installed"; exit 0; }
export HARNESS_SESSION_BACKEND=tmux
tmux_short_dir; L="$TMUX_SHORT_DIR"; LIVE_SOCK_DIR="$L"
tmux_short_dir; H="$TMUX_SHORT_DIR"        # the empty "sandbox" view: a private dir no server ever ran in
trap 'TMUX_TMPDIR="$L" tmux kill-server 2>/dev/null; tmp_cleanup' EXIT
at(){ export TMUX_TMPDIR="$1"; }
EVENTS="$RUN_DIR/events"; SWEPT="$RUN_DIR/swept"; : > "$EVENTS"; : > "$SWEPT"
harness_event(){ echo "$1" >> "$EVENTS"; }
sess_sweep(){ echo "$1" >> "$SWEPT"; }
churn_check(){ :; }
_stats_cli_usage(){ :; }

mk(){ local s="$1"   # one lane's whole file set
  echo ISSUE:7 > "$RUN_DIR/$s.goal"; echo /w > "$RUN_DIR/$s.wd"; : > "$RUN_DIR/$s.loop"; : > "$RUN_DIR/$s.loop.lock"
  printf '{"session":"uuid-%s","repo":"o/r","issue":"7","kind":"impl"}\n' "$s" > "$RUN_DIR/$s.stats"; }
files(){ ls "$RUN_DIR" | grep -E '^hzfk-' | sort | xargs; }
all_of(){ local s="$1" e; for e in goal wd loop loop.lock stats; do printf '%s ' "hzfk-$s.$e"; done; }

at "$L"; tmux new-session -d -s hzfk-live 'sleep 600'
assert_ok "the fleet's server is up on L" tmux has-session -t hzfk-live

echo "== server reachable: behaviour unchanged =="
mk hzfk-live; mk hzfk-dead; echo /w > "$RUN_DIR/hzfk-wdonly.wd"
at "$L"; gc_orphan_goals
assert_ok "a live session's .goal is kept" test -e "$RUN_DIR/hzfk-live.goal"
for e in goal wd loop loop.lock; do assert_no "a session missing from the reachable server has its .$e swept" test -e "$RUN_DIR/hzfk-dead.$e"; done
assert_no "the #610 .wd-only orphan is still swept" test -e "$RUN_DIR/hzfk-wdonly.wd"
assert_no "an ended session's .stats is consumed" test -e "$RUN_DIR/hzfk-dead.stats"
assert_ok "a live session's .stats stays" test -e "$RUN_DIR/hzfk-live.stats"
assert_eq "$(cat "$EVENTS")" "session_end" "session_end emitted for the ended session only"
assert_eq "$(cat "$SWEPT")" "uuid-hzfk-dead" "sess_sweep ran for the ended session only"

echo "== server UNREACHABLE: nothing is judged =="
rm -f "$RUN_DIR"/hzfk-*; : > "$EVENTS"; : > "$SWEPT"
mk hzfk-live; mk hzfk-dead; echo /w > "$RUN_DIR/hzfk-wdonly.wd"
before="$(ls "$RUN_DIR" | sort | xargs)"
at "$H"; assert_no "the server is unreachable from H (the live one is on L)" tmux has-session -t hzfk-live
assert_no "sess_server_reachable is false there" sess_server_reachable
gc_orphan_goals
assert_eq "$(ls "$RUN_DIR" | sort | xargs)" "$before" "gc_orphan_goals deleted and consumed nothing (.goal .wd .loop .loop.lock .stats)"
stats_sweep_ended
assert_eq "$(ls "$RUN_DIR" | sort | xargs)" "$before" "stats_sweep_ended consumed no .stats"
assert_eq "$(cat "$EVENTS")" "" "no session_end emitted"
assert_eq "$(cat "$SWEPT")" "" "no sess_sweep / proc_sweep_session call"
at "$L"; assert_ok "the live session is still up on its own server" tmux has-session -t hzfk-live
assert_ok "sess_server_reachable is true again once the server is reachable" sess_server_reachable
finish

#!/usr/bin/env bash
# test_watchdog.sh — #115: the stalled-session watchdog. A transient Anthropic API error
# (529 Overloaded / 5xx / overloaded / rate limit) aborts a driven turn abnormally: ralph-loop's
# Stop hook never fires, so the interactive `claude` TUI parks at its idle `❯` prompt forever. The
# session stays LIVE (tmux has-session true) yet makes no forward progress, and the `iteration`
# counter is frozen at 1 — so none of the five reaper paths (all keyed on liveness or
# goal-satisfaction) ever touch it. The watchdog detects that alive-but-idle state and recovers it:
# nudge first, then kill after HARNESS_STALL_RETRIES consecutive stalled polls so the existing
# reap → re-dispatch path frees the slot. A busy or healthy-idle session is NEVER disturbed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/helpers.sh"
make_env

# ── A: session_stalled — classify a real captured pane ───────────────────────
# Uses REAL tmux: spin up three live panes whose content mimics the three states, capture each with
# `tmux capture-pane -p`, and assert the detector fires ONLY for the error-then-idle pane. This is
# the no-false-positive guarantee at the detector level (busy mid-turn / healthy idle untouched).
PFX="wdtest-$$"
S_STALL="$PFX-stalled"; S_BUSY="$PFX-busy"; S_OK="$PFX-ok"
# `command tmux`: later sections redefine tmux() as a recording stub, so the EXIT trap must reach
# the REAL binary to actually reap these live panes (else they leak on the host).
cleanup(){ for s in "$S_STALL" "$S_BUSY" "$S_OK"; do command tmux kill-session -t "$s" 2>/dev/null || true; done; }
trap cleanup EXIT

# Stalled: the documented wedge — a satisfied-looking promise, then a 529 error line, then the idle
# `❯` prompt with NO active "(esc to interrupt)" spinner. This is the state that must be recovered.
tmux new-session -d -s "$S_STALL" "bash -c \"printf '%s\n' '  <promise>ISSUE 23 DONE</promise>' '  API Error: 529 Overloaded. This is a server-side issue, usually temporary.' '' '❯' '  bypass permissions on (shift+tab to cycle)'; exec sleep 600\""
# Busy: an active turn mid-tool-use — the TUI shows "(esc to interrupt)". Must NOT be stalled.
tmux new-session -d -s "$S_BUSY"  "bash -c \"printf '%s\n' 'Editing file… (esc to interrupt)'; exec sleep 600\""
# Healthy idle: parked at `❯` briefly between ralph turns, but with NO transient-error marker. Must
# NOT be stalled (the error marker is what separates a wedge from an ordinary idle prompt).
tmux new-session -d -s "$S_OK"    "bash -c \"printf '%s\n' '  Done.' '❯' '  bypass permissions on (shift+tab to cycle)'; exec sleep 600\""
sleep 0.4

assert_ok "session_stalled detects the error-then-idle wedge" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_stalled \"\$(tmux capture-pane -p -t '$S_STALL')\""
assert_no "session_stalled leaves a busy mid-turn session alone" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_stalled \"\$(tmux capture-pane -p -t '$S_BUSY')\""
assert_no "session_stalled leaves a healthy idle-no-error session alone" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_stalled \"\$(tmux capture-pane -p -t '$S_OK')\""

# ── B: watchdog_session escalation — nudge first, then kill after K stalled polls ────────────────
# Deterministic: stub the pane capture to a fixed stalled pane and record nudges/kills, so the
# counting + escalation are tested without timing flake. K = HARNESS_STALL_RETRIES.
make_env
HARNESS_STALL_RETRIES=3
SESS="hz-bug-acme_widget-5-fix"
NUDGED="$RUN_DIR/nudged"; KILLED="$RUN_DIR/killed"; : > "$NUDGED"; : > "$KILLED"
session_live(){ ! grep -qx "$1" "$KILLED" 2>/dev/null; }     # live until the watchdog kills it
tmux(){ case "$1" in
  capture-pane) printf '%s\n' '  API Error: 529 Overloaded.' '❯' ;;   # always the stalled pane
  kill-session) echo "$3" >> "$KILLED" ;;
  send-keys)    : ;;                                                  # the real nudge path; see _watchdog_nudge stub
esac; return 0; }
_watchdog_nudge(){ echo "$1" >> "$NUDGED"; }                  # record that a nudge was issued

watchdog_session "$SESS"   # poll 1
assert_eq "$(wc -l < "$NUDGED")" "1" "poll 1: stalled session is nudged"
assert_eq "$(wc -l < "$KILLED")" "0" "poll 1: not killed yet"
assert_eq "$(cat "$RUN_DIR/$SESS.stall" 2>/dev/null)" "1" "poll 1: stall counter = 1"
watchdog_session "$SESS"   # poll 2
assert_eq "$(wc -l < "$NUDGED")" "2" "poll 2: nudged again"
assert_eq "$(wc -l < "$KILLED")" "0" "poll 2: still not killed"
watchdog_session "$SESS"   # poll 3 → K reached → kill
assert_eq "$(cat "$KILLED")" "$SESS" "poll 3: killed after K consecutive stalled polls"
assert_no "stall counter file cleared on kill" test -f "$RUN_DIR/$SESS.stall"

# ── C: watchdog_session never disturbs a busy / healthy session, and resets on recovery ──────────
make_env
HARNESS_STALL_RETRIES=3
SESS="hz-main-i9"
NUDGED="$RUN_DIR/nudged2"; KILLED="$RUN_DIR/killed2"; : > "$NUDGED"; : > "$KILLED"
PANE="$RUN_DIR/pane"; printf '%s\n' 'Working… (esc to interrupt)' > "$PANE"   # busy
session_live(){ ! grep -qx "$1" "$KILLED" 2>/dev/null; }
tmux(){ case "$1" in
  capture-pane) cat "$PANE" ;;
  kill-session) echo "$3" >> "$KILLED" ;;
  send-keys)    : ;;
esac; return 0; }
_watchdog_nudge(){ echo "$1" >> "$NUDGED"; }

watchdog_session "$SESS"; watchdog_session "$SESS"; watchdog_session "$SESS"; watchdog_session "$SESS"
assert_eq "$(wc -l < "$NUDGED")" "0" "busy session never nudged"
assert_eq "$(wc -l < "$KILLED")" "0" "busy session never killed"
assert_no "busy session leaves no stall counter" test -f "$RUN_DIR/$SESS.stall"

# recovery resets the counter: a session stalled for K-1 polls that then resumes (goes busy) must
# have its stall count cleared, so a LATER unrelated stall starts counting from zero again.
printf '%s\n' '  API Error: 529 Overloaded.' '❯' > "$PANE"   # stalled
watchdog_session "$SESS"; watchdog_session "$SESS"           # count → 2 (K-1)
assert_eq "$(cat "$RUN_DIR/$SESS.stall" 2>/dev/null)" "2" "two consecutive stalls counted"
printf '%s\n' 'Resumed… (esc to interrupt)' > "$PANE"        # nudge worked → busy again
watchdog_session "$SESS"
assert_no "stall counter cleared once the session recovers (busy)" test -f "$RUN_DIR/$SESS.stall"

# ── D: both lanes invoke the watchdog over their live sessions ───────────────────────────────────
# Pool: drive_unit must run the watchdog over the unit's team sessions every poll.
make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; CAP=2; POLL=0
WORKTREES_DIR="$RUN_DIR/wtD"; mkdir -p "$WORKTREES_DIR"
WD_SEEN="$RUN_DIR/wd_seen"; : > "$WD_SEEN"
reap_done_sessions(){ :; }; reap_team(){ :; }
count_team_sessions(){ echo 1; }
team_sessions(){ printf '%s\n' "hz-main-i7"; }
tmux(){ :; }; git(){ :; }
watchdog_session(){ echo "$1" >> "$WD_SEEN"; }
dispatch_actions(){ :; }
TICK="$RUN_DIR/tickD"; echo 0 > "$TICK"
unit_complete(){ local n; n=$(( $(cat "$TICK")+1 )); echo "$n" > "$TICK"; [[ "$n" -ge 2 ]]; }
drive_unit main
assert_ok "drive_unit (pool) runs the watchdog over its team sessions" grep -qx "hz-main-i7" "$WD_SEEN"

# Lane: drive_bug must run the watchdog while it HOLDS a live bug session (its inner loop is the only
# per-poll point during the wedge — bug_step's reap_lane never sees an in-flight wedged session).
source "$HERE/../scripts/priority-worker.sh"   # bring in drive_bug
make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"
WD_SEEN2="$RUN_DIR/wd_seen2"; : > "$WD_SEEN2"
_bug_ref_repo(){ echo "acme/widget"; }; _bug_ref_num(){ echo 5; }
bug_phase(){ echo fix; }; bug_checkout(){ echo "$RUN_DIR/co"; }
spawn_bug(){ return 0; }
remove_worktree(){ :; }; bug_worktree(){ echo x; }; triage_worktree(){ echo y; }
is_paused(){ return 1; }
LTICK="$RUN_DIR/ltick"; echo 0 > "$LTICK"
session_live(){ local n; n=$(( $(cat "$LTICK")+1 )); echo "$n" > "$LTICK"; [[ "$n" -le 1 ]]; }  # live for one poll
bug_goal_done(){ return 1; }
watchdog_session(){ echo "$1" >> "$WD_SEEN2"; }
PRIORITY_POLL=0
drive_bug "acme/widget#5"
assert_ok "drive_bug (lane) runs the watchdog over its in-flight bug session" \
  grep -qx "$(sess_bug acme/widget 5 fix)" "$WD_SEEN2"

# ── E: #120 quota park — detected, recovered, and NEVER killed ───────────────────────────────────
# Two shapes: blocked on the interactive limit menu (no `❯` at all), and a limit-aborted turn parked
# at idle `❯`. Both must be recovered without ever escalating to a kill — the account is out of
# quota, not wedged, and killing K lanes would throw away their in-flight context.
# Pane fixtures are written by these two helpers rather than held in files: every make_env below
# recreates RUN_DIR, so a fixture PATH captured before one would silently read back empty.
pane_menu(){ printf '%s\n' '   What do you want to do?' '   ❯ 1. Stop and wait for limit to reset' \
              '     2. Add funds to continue with usage credits' '   Enter to confirm · Esc to cancel' > "$1"; }
pane_limit(){ printf '%s\n' "  ⎿  You've hit your session limit · resets 12:10am (UTC)" '❯' \
              '  bypass permissions on (shift+tab to cycle)' > "$1"; }
# Credit exhaustion is the same class and must park, not stall: it names neither "limit" nor "reset",
# so it used to fall through to #115 and get nudged ×K then KILLED — and each re-dispatch reprovisions
# a worktree only to die instantly again, looping for as long as the account is dry.
pane_credits(){ printf '%s\n' "  ⎿  You're out of usage credits. Run /usage-credits to keep using" \
              '     Fable 5 or /model to switch models.' '❯' \
              '  bypass permissions on (shift+tab to cycle)' > "$1"; }
make_env
PANE_MENU="$RUN_DIR/pane_menu"; PANE_LIM="$RUN_DIR/pane_lim"; PANE_CRED="$RUN_DIR/pane_cred"
pane_menu "$PANE_MENU"; pane_limit "$PANE_LIM"; pane_credits "$PANE_CRED"

assert_ok "session_limit_menu detects the blocking usage-limit menu" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_limit_menu \"\$(cat '$PANE_MENU')\""
assert_ok "session_limit_idle detects a limit-aborted turn parked at idle ❯" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_limit_idle \"\$(cat '$PANE_LIM')\""
# A lane mid-way through a long shell command shows "to run in background" INSTEAD of the spinner,
# and its own tool output can carry an error marker (a 500 in a log tail). That is a BUSY session.
PANE_BG="$RUN_DIR/pane_bg"
printf '%s\n' '  ⎿  $ tools/run_tests.sh > base.log 2>&1; tail -30 base.log (32s)' \
              '     HTTP 500 from the fixture server — expected, see base.log' \
              '     (ctrl+b ctrl+b (twice) to run in background)' \
              '❯' > "$PANE_BG"
assert_no "session_stalled leaves a lane running a long shell command alone (background hint)" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_stalled \"\$(cat '$PANE_BG')\""
assert_no "session_limit_idle leaves a lane running a long shell command alone" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_limit_idle \"\$(cat '$PANE_BG')\""
assert_ok "session_limit_idle detects a turn aborted by credit exhaustion (parks, never kills)" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_limit_idle \"\$(cat '$PANE_CRED')\""
assert_no "session_limit_idle leaves a busy mid-turn session alone" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_limit_idle 'Working… (esc to interrupt)'"
assert_no "session_limit_idle leaves a healthy idle-no-limit session alone" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_limit_idle \"\$(printf '%s\n' '  Done.' '❯')\""
assert_no "session_limit_menu ignores an ordinary pane" \
  bash -c "source '$HERE/../scripts/lib.sh'; session_limit_menu \"\$(cat '$PANE_LIM')\""

source "$HERE/../scripts/lib.sh"   # section D stubbed watchdog_session — restore the real one
make_env
HARNESS_STALL_RETRIES=3; HARNESS_LIMIT_NUDGE_EVERY=5
SESS="hz-main-i120"
PICKED="$RUN_DIR/picked"; LNUDGED="$RUN_DIR/lnudged"; KILLED="$RUN_DIR/killed3"
: > "$PICKED"; : > "$LNUDGED"; : > "$KILLED"
PANE="$RUN_DIR/paneE"; pane_menu "$PANE"
session_live(){ ! grep -qx "$1" "$KILLED" 2>/dev/null; }
tmux(){ case "$1" in
  capture-pane) cat "$PANE" ;;
  kill-session) echo "$3" >> "$KILLED" ;;
  send-keys)    : ;;
esac; return 0; }
_watchdog_limit_pick(){ echo "$1" >> "$PICKED"; }
_watchdog_limit_nudge(){ echo "$1" >> "$LNUDGED"; }
_watchdog_nudge(){ echo "STALL-NUDGE" >> "$LNUDGED"; }   # must never fire on a quota park

# menu shape: answered every poll, never counted, never killed
watchdog_session "$SESS"; watchdog_session "$SESS"; watchdog_session "$SESS"; watchdog_session "$SESS"
assert_eq "$(wc -l < "$PICKED")" "4" "menu-blocked session gets Enter on every poll"
assert_eq "$(wc -l < "$KILLED")" "0" "menu-blocked session is never killed"
assert_no "menu-blocked session accrues no stall counter" test -f "$RUN_DIR/$SESS.stall"

# idle shape: nudged on poll 1, then backed off to every Nth — and killed on NO poll, ever. Ten
# polls is well past HARNESS_STALL_RETRIES=3, which is exactly the escalation that must not happen.
make_env
HARNESS_STALL_RETRIES=3; HARNESS_LIMIT_NUDGE_EVERY=5
PICKED="$RUN_DIR/picked2"; LNUDGED="$RUN_DIR/lnudged2"; KILLED="$RUN_DIR/killed4"
: > "$PICKED"; : > "$LNUDGED"; : > "$KILLED"
PANE="$RUN_DIR/paneE2"; pane_limit "$PANE"
session_live(){ ! grep -qx "$1" "$KILLED" 2>/dev/null; }
tmux(){ case "$1" in
  capture-pane) cat "$PANE" ;;
  kill-session) echo "$3" >> "$KILLED" ;;
  send-keys)    : ;;
esac; return 0; }
_watchdog_limit_pick(){ echo "$1" >> "$PICKED"; }
_watchdog_limit_nudge(){ echo "$1" >> "$LNUDGED"; }
_watchdog_nudge(){ echo "STALL-NUDGE" >> "$LNUDGED"; }

for _ in 1 2 3 4 5 6 7 8 9 10; do watchdog_session "$SESS"; done
assert_eq "$(wc -l < "$KILLED")" "0" "quota-parked session is NEVER killed, even past HARNESS_STALL_RETRIES"
assert_eq "$(wc -l < "$LNUDGED")" "3" "nudged on poll 1 then every 5th (1, 5, 10) — backed off"
assert_no "quota park never reaches the #115 stall path" grep -qx "STALL-NUDGE" "$LNUDGED"
assert_eq "$(cat "$RUN_DIR/$SESS.limit" 2>/dev/null)" "10" "limit poll counter tracks consecutive parks"

# recovery: the nudge lands, the session goes busy → the limit counter is cleared, so a LATER quota
# park starts its backoff from poll 1 again (and gets an immediate nudge rather than a silent wait).
printf '%s\n' 'Resumed… (esc to interrupt)' > "$PANE"
watchdog_session "$SESS"
assert_no "limit counter cleared once the session recovers (busy)" test -f "$RUN_DIR/$SESS.limit"

finish

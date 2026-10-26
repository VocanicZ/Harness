#!/usr/bin/env bash
# test_turn.sh — #207: a lane stuck in ONE long turn never sees a nudge. Mid-turn, text typed into the
# pane only QUEUES in the input box, so a lane polling a long job for hours (one turn, never ending)
# sat with three watchdog nudges queued for 7+ h while its status read RUNNING. The watchdog now
# interrupts such a turn — Escape, wait for `Interrupted`, Enter so the queued text is submitted —
# once it has run HARNESS_TURN_MAX with input queued, or as soon as one of Harness's own nudges is
# still queued a poll later. A long turn with an EMPTY input box is a legitimately long tool call
# and is never touched.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env

NUDGE='Please continue — the transient API error has cleared; resume the in-flight task.'
# pane_turn <file> <spinner timer> [queued line …] — a mid-turn Claude Code pane: a long-polling Bash
# call, the spinner with its turn timer, and the input box holding whatever was typed during the turn.
pane_turn(){ local f=$1 timer=$2; shift 2
  { printf '%s\n' '⏺ Bash(timeout 590 bash -c "until grep -q done replay.log; do sleep 30; done")' \
                  '  ⎿  Running… (32s)' \
                  "✻ Polling the bench replay… ($timer · ↓ 12.3k tokens · esc to interrupt)" '' \
                  '────────────────────────────────────────'
    if (( $# )); then printf '❯ %s\n' "$1"; shift; printf '  %s\n' "$@"; else printf '❯ \n'; fi
    printf '%s\n' '────────────────────────────────────────' '  ⏵⏵ bypass permissions on (shift+tab to cycle)'
  } > "$f"; }

# ── A: reading the pane ─────────────────────────────────────────────────────────────────────────
P="$RUN_DIR/pA"
pane_turn "$P" '5h 0m 3s' "$NUDGE"
assert_eq "$(turn_secs "$(cat "$P")")" "18003" "turn_secs reads the spinner's 5h 0m 3s timer"
pane_turn "$P" '21h 3m'
assert_eq "$(turn_secs "$(cat "$P")")" "75780" "turn_secs reads a timer that dropped its seconds (21h 3m)"
assert_eq "$(turn_secs "$(printf '%s\n' '  ⎿  Running… (32s)' '❯ ')")" "0" \
  "a tool line's own (32s) is not a turn timer"
assert_eq "$(turn_secs "$(printf '%s\n' '✻ Worked for 5h 2m' '❯ ')")" "0" "a finished turn has no timer"
pane_turn "$P" '5h 0m 3s' 'first queued line' 'its continuation'
assert_eq "$(turn_queued "$(cat "$P")")" "$(printf '%s\n' 'first queued line' 'its continuation')" \
  "turn_queued reads the input box, continuation lines included, footer excluded"
pane_turn "$P" '5h 0m 3s'
assert_eq "$(turn_queued "$(cat "$P")")" "" "turn_queued: an empty input box queues nothing"
assert_eq "$(turn_queued "$(printf '%s\n' '❯ typed' '  ⏵⏵ bypass permissions on (shift+tab to cycle)')")" "typed" \
  "turn_queued: with no bottom rule only the ❯ line counts (the next line may be the footer)"

# ── B: watchdog_session — stub tmux; the Escape stub prints `Interrupted` like the real TUI ─────────
KEYS="$RUN_DIR/keys"; EVENTS="$RUN_DIR/events"; KILLED="$RUN_DIR/killed"
PANE="$RUN_DIR/pane"; INTERRUPTS=1
SESS="hz-rtdd-i508"
reset_rec(){ : > "$KEYS"; : > "$EVENTS"; : > "$KILLED"; rm -f "$RUN_DIR/$SESS".*; }
session_live(){ ! grep -qx "$1" "$KILLED" 2>/dev/null; }
tmux(){ case "$1" in
  capture-pane) cat "$PANE" ;;
  kill-session) echo "$3" >> "$KILLED" ;;
  send-keys)    [[ $4 == -l ]] && { echo "TEXT" >> "$KEYS"; return 0; }
                echo "$4" >> "$KEYS"
                [[ $4 == Escape ]] && (( INTERRUPTS )) && echo '  ⎿  Interrupted · What should Claude do instead?' >> "$PANE" ;;
esac; return 0; }
stats_sess_event(){ echo "$2 ${*:3}" >> "$EVENTS"; }
keys(){ tr '\n' ' ' < "$KEYS" | sed 's/ $//'; }
HARNESS_TURN_MAX=14400 HARNESS_INTERRUPT_WAIT=1

# Acceptance 1: a 5 h turn with queued text → Escape, then Enter, and the event is logged.
reset_rec; pane_turn "$PANE" '5h 0m 3s' "$NUDGE"
watchdog_session "$SESS"
assert_eq "$(keys)" "Escape Enter" "5 h turn + queued text: Escape, then Enter"
assert_eq "$(cat "$EVENTS")" "turn_interrupted turn_s=18003 queued_nudges=1" \
  "turn_interrupted is logged with the turn length and the queued nudges"
assert_eq "$(wc -l < "$KILLED")" "0" "the interrupted lane is never killed"

# Acceptance 2: a 5 h turn with an EMPTY input box is a legitimately long tool call → no action.
reset_rec; pane_turn "$PANE" '5h 0m 3s'
watchdog_session "$SESS"; watchdog_session "$SESS"; watchdog_session "$SESS"
assert_eq "$(keys)" "" "5 h turn + empty input box: nothing is sent"
assert_eq "$(cat "$EVENTS")" "" "5 h turn + empty input box: no event"

# Acceptance 3: a 30 min turn with queued text → no action until HARNESS_TURN_MAX.
reset_rec; pane_turn "$PANE" '30m 12s' 'also check the flaky test'
watchdog_session "$SESS"; watchdog_session "$SESS"; watchdog_session "$SESS"
assert_eq "$(keys)" "" "30 min turn + queued text: no action before HARNESS_TURN_MAX"
pane_turn "$PANE" '4h 0m 0s' 'also check the flaky test'
watchdog_session "$SESS"
assert_eq "$(keys)" "Escape Enter" "the same queued text at HARNESS_TURN_MAX (4 h): interrupted"

# One of Harness's own nudges still queued a poll later is interrupted without waiting 4 h.
reset_rec; pane_turn "$PANE" '30m 12s' "$NUDGE"
watchdog_session "$SESS"
assert_eq "$(keys)" "" "a Harness nudge queued for the first time: give the turn one poll to end"
watchdog_session "$SESS"
assert_eq "$(keys)" "Escape Enter" "the same nudge still queued a poll later: interrupted"
assert_no "the queued-nudge state is forgotten after the interrupt" test -f "$RUN_DIR/$SESS.turnq"
reset_rec; pane_turn "$PANE" '30m 12s' "$NUDGE"; watchdog_session "$SESS"
pane_turn "$PANE" '30m 40s'; watchdog_session "$SESS"
assert_no "the nudge delivered on its own (box empty): the state is cleared" test -f "$RUN_DIR/$SESS.turnq"

# A turn that never reports `Interrupted` gets no Enter (it would only queue again) and no event.
reset_rec; INTERRUPTS=0; HARNESS_INTERRUPT_WAIT=0
pane_turn "$PANE" '5h 0m 3s' "$NUDGE"
echo '  ⎿  Interrupted · What should Claude do instead?' >> "$PANE"   # an OLD one, already on screen
watchdog_session "$SESS"
assert_eq "$(keys)" "Escape" "no new Interrupted: Escape only, Enter withheld"
assert_eq "$(cat "$EVENTS")" "" "no new Interrupted: no turn_interrupted event"

finish

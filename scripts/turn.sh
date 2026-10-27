#!/usr/bin/env bash
# turn.sh — #207: a lane stuck in ONE long turn never sees a nudge. While Claude Code is mid-turn,
# text typed into the pane (the #115 watchdog's continue, the supervisor's nudge, an operator's) is
# only QUEUED in the input box; it is delivered when the turn ends. A lane that polls a long job with
# repeated `timeout 590 bash -c "until grep …"` calls never ends its turn, so nudges pile up unseen
# while the status reads RUNNING (seen: one turn of 21 h, three nudges queued for 7+ h). Neither
# existing check sees it: the pane is mid-turn (never "stalled"), and the spinner's turn timer changes
# every second (never "frozen"). The fix is the operator's: Escape to interrupt the turn, wait for
# it to end, then Enter so the queued text is submitted.
#
# Pure pane-text helpers plus the interrupt itself, sourced by lib.sh (the per-fleet watchdog) and by
# supervise.sh (the host supervisor, which also watches non-Harness panes with no lib.sh loaded).
# Both source scripts/cli/dispatch.sh too; the helpers resolve the CLI when they are called.
: "${HARNESS_TURN_MAX:=14400}"        # #207: seconds one turn may run with input queued before it is interrupted (4 h)
: "${HARNESS_INTERRUPT_WAIT:=10}"     # #207: seconds to wait for the turn to end after Escape before giving up this poll
# The opening words of every nudge Harness types into a pane (_watchdog_nudge, _watchdog_limit_nudge,
# supervise's SUP_NUDGE_MSG / SUP_EXTRA_MSG). One of OUR nudges still queued a poll later is proof the
# turn is not ending on its own, so it is interrupted without waiting for HARNESS_TURN_MAX.
HARNESS_NUDGE_RE='^Please continue —|^harness supervise:'

# Every CLI fact — where the input prompt is, how long the turn has run, what an interrupt prints —
# comes from the CLI adapter (scripts/cli/, #188): the fleet's own CLI, or the one a caller names
# with `cli_with <cli> turn_…` (the supervisor, reading another fleet's pane).

# turn_secs <pane> — how long the active turn has run, in seconds (the CLI's turn timer); 0 when no
# turn is running; EMPTY when the CLI draws no turn timer (cli_turn_secs).
turn_secs(){ cli_turn_secs "$1"; }

# turn_queued <pane> — the text waiting in the input box (the last prompt line's text plus its
# continuation lines up to the box's bottom rule), blank lines dropped; empty when the box is empty.
# Without a bottom rule only the prompt line counts: what follows could be the footer, not more input.
turn_queued(){ local n first
  n=$(cli_pane_prompt_line "$1"); (( n > 0 )) || return 0
  first=$(cli_prompt_text "$(printf '%s\n' "$1" | sed -n "${n}p")")
  { printf '%s\n' "$first"
    printf '%s\n' "$1" | awk -v n="$n" '
      NR > n { if ($0 ~ /^(─|━)/) { closed = 1; exit } more = more $0 "\n" }
      END { if (closed) printf "%s", more }'
  } | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$'; }

# turn_should_interrupt <pane> <state file> — true iff the lane's turn must be interrupted: it has run
# HARNESS_TURN_MAX with input queued, or one of Harness's own nudges is still queued a poll after it
# was first seen there. The state file remembers that queued nudge between polls; it is removed the
# moment nothing is queued or no turn is running. A long turn with an EMPTY input box is a
# legitimately long tool call and is never touched.
# A CLI with no turn timer cannot reach HARNESS_TURN_MAX: its running turn is read off cli_pane_busy,
# and only the queued-nudge rule applies.
turn_should_interrupt(){ local pane=$1 f=$2 q secs h
  q=$(turn_queued "$pane"); secs=$(turn_secs "$pane")
  if [[ -z $secs ]]; then cli_pane_busy "$pane" && secs=-1 || secs=0; fi
  if [[ -z $q ]] || (( secs == 0 )); then rm -f "$f"; return 1; fi
  (( secs >= HARNESS_TURN_MAX )) && return 0
  grep -qE "$HARNESS_NUDGE_RE" <<<"$q" || { rm -f "$f"; return 1; }
  h=$(md5sum <<<"$q" | cut -c1-12)
  [[ -f $f && $(cat "$f" 2>/dev/null) == "$h" ]] && return 0
  mkdir -p "$(dirname "$f")"; echo "$h" >"$f"; return 1; }

# turn_queued_nudges <pane> — how many of Harness's nudges sit in the input box (for the stats event).
turn_queued_nudges(){ turn_queued "$1" | grep -cE "$HARNESS_NUDGE_RE"; }

# turn_interrupt <tmux target> [runner …] — Escape, wait (up to HARNESS_INTERRUPT_WAIT s) for the
# turn to end, then Enter so the queued text is submitted. The turn has ended once a NEW line matching
# cli_interrupted_re shows (claude's `Interrupted`); a CLI that prints none ends it when the pane is no
# longer busy. The runner (e.g. supervise's sup_act) wraps the two key presses. False when the turn
# never ended: Enter is then NOT sent (it would only queue behind a turn still running) and the next
# poll tries again.
turn_interrupt(){ local t=$1 re before i; shift
  re=$(cli_interrupted_re)
  [[ -n $re ]] && before=$(tmux capture-pane -p -t "$t" 2>/dev/null | grep -cE -- "$re")
  "$@" tmux send-keys -t "$t" Escape
  for (( i = 0; i <= HARNESS_INTERRUPT_WAIT * 2; i++ )); do
    if _turn_ended "$t" "$re" "${before:-0}"; then "$@" tmux send-keys -t "$t" Enter; return 0; fi
    (( i < HARNESS_INTERRUPT_WAIT * 2 )) && sleep 0.5
  done
  return 1; }
_turn_ended(){ local pane; pane=$(tmux capture-pane -p -t "$1" 2>/dev/null)
  if [[ -n $2 ]]; then (( $(grep -cE -- "$2" <<<"$pane") > $3 )); else ! cli_pane_busy "$pane"; fi; }

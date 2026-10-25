#!/usr/bin/env bash
# turn.sh — #207: a lane stuck in ONE long turn never sees a nudge. While Claude Code is mid-turn,
# text typed into the pane (the #115 watchdog's continue, the supervisor's nudge, an operator's) is
# only QUEUED in the input box; it is delivered when the turn ends. A lane that polls a long job with
# repeated `timeout 590 bash -c "until grep …"` calls never ends its turn, so nudges pile up unseen
# while the status reads RUNNING (seen: one turn of 21 h, three nudges queued for 7+ h). Neither
# existing check sees it: the pane is mid-turn (never "stalled"), and the spinner's turn timer changes
# every second (never "frozen"). The fix is the operator's: Escape to interrupt the turn, wait for
# `Interrupted`, then Enter so the queued text is submitted.
#
# Pure pane-text helpers plus the interrupt itself, sourced by lib.sh (the per-fleet watchdog) and by
# supervise.sh (the host supervisor, which also watches non-Harness panes with no lib.sh loaded).
: "${HARNESS_TURN_MAX:=14400}"        # #207: seconds one turn may run with input queued before it is interrupted (4 h)
: "${HARNESS_INTERRUPT_WAIT:=10}"     # #207: seconds to wait for `Interrupted` after Escape before giving up this poll
# The opening words of every nudge Harness types into a pane (_watchdog_nudge, _watchdog_limit_nudge,
# supervise's SUP_NUDGE_MSG / SUP_EXTRA_MSG). One of OUR nudges still queued a poll later is proof the
# turn is not ending on its own, so it is interrupted without waiting for HARNESS_TURN_MAX.
HARNESS_NUDGE_RE='^Please continue —|^harness supervise:'

# _turn_prompt_line <pane> — line number of the LAST idle input prompt (`❯` at column 0), 0 if none.
_turn_prompt_line(){ printf '%s\n' "$1" | awk '/^❯/{n=NR} END{print n+0}'; }

# turn_secs <pane> — how long the active turn has run, in seconds, from the spinner's timer above
# the input box: "✻ Running… (21h 3m 12s · ↓ 4.2k tokens · esc to interrupt)". 0 when no turn is
# running. The " ·" after the timer is what separates the spinner from a tool line's own "(32s)".
turn_secs(){ local n
  n=$(_turn_prompt_line "$1")
  printf '%s\n' "$1" | awk -v n="$n" 'n == 0 || NR < n' | grep -oE '\(([0-9]+[dhms] ?)+ ·' | tail -1 |
    awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\(?[0-9]+[dhms]$/) { v = $i; gsub(/[^0-9]/, "", v); u = substr($i, length($i))
           s += v * (u == "d" ? 86400 : u == "h" ? 3600 : u == "m" ? 60 : 1) } }
         END { print s + 0 }'; }

# turn_queued <pane> — the text waiting in the input box (`❯ <text>` plus its continuation lines up
# to the box's bottom rule), blank lines dropped; empty when the box is empty. Without a bottom rule
# only the `❯` line counts: what follows could be the footer, not more input.
turn_queued(){ printf '%s\n' "$1" | awk '
  /^❯/ { n = NR } { l[NR] = $0 }
  END { if (!n) exit
        t = l[n]; sub(/^❯ ?/, "", t); out = t
        for (i = n + 1; i <= NR; i++) { if (l[i] ~ /^(─|━)/) { closed = 1; break } more = more "\n" l[i] }
        if (closed) out = out more
        print out }' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$'; }

# turn_should_interrupt <pane> <state file> — true iff the lane's turn must be interrupted: it has run
# HARNESS_TURN_MAX with input queued, or one of Harness's own nudges is still queued a poll after it
# was first seen there. The state file remembers that queued nudge between polls; it is removed the
# moment nothing is queued or no turn is running. A long turn with an EMPTY input box is a
# legitimately long tool call and is never touched.
turn_should_interrupt(){ local pane=$1 f=$2 q secs h
  q=$(turn_queued "$pane"); secs=$(turn_secs "$pane")
  if [[ -z $q ]] || (( secs == 0 )); then rm -f "$f"; return 1; fi
  (( secs >= HARNESS_TURN_MAX )) && return 0
  grep -qE "$HARNESS_NUDGE_RE" <<<"$q" || { rm -f "$f"; return 1; }
  h=$(md5sum <<<"$q" | cut -c1-12)
  [[ -f $f && $(cat "$f" 2>/dev/null) == "$h" ]] && return 0
  mkdir -p "$(dirname "$f")"; echo "$h" >"$f"; return 1; }

# turn_queued_nudges <pane> — how many of Harness's nudges sit in the input box (for the stats event).
turn_queued_nudges(){ turn_queued "$1" | grep -cE "$HARNESS_NUDGE_RE"; }

# turn_interrupt <tmux target> [runner …] — Escape, wait (up to HARNESS_INTERRUPT_WAIT s) for a NEW
# `Interrupted` line, then Enter so the queued text is submitted. The runner (e.g. supervise's
# sup_act) wraps the two key presses. False when the turn never reported `Interrupted`: Enter is then
# NOT sent (it would only queue behind a turn still running) and the next poll tries again.
turn_interrupt(){ local t=$1 before i; shift
  before=$(tmux capture-pane -p -t "$t" 2>/dev/null | grep -c 'Interrupted')
  "$@" tmux send-keys -t "$t" Escape
  for (( i = 0; i <= HARNESS_INTERRUPT_WAIT * 2; i++ )); do
    if (( $(tmux capture-pane -p -t "$t" 2>/dev/null | grep -c 'Interrupted') > before )); then
      "$@" tmux send-keys -t "$t" Enter; return 0
    fi
    (( i < HARNESS_INTERRUPT_WAIT * 2 )) && sleep 0.5
  done
  return 1; }

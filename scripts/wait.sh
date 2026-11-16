#!/usr/bin/env bash
# wait.sh — #1066: engine-owned waits. Sourced by lib.sh (after usage.sh); defines functions only.
#
# #1042 told lanes (a prompt rule) to wait in the background. A rule a model must follow is not a guarantee, and 72% of
# three days' spend ($1110 of $1547) went to wait/poll wake-ups. So the ENGINE waits:
#
#   job      A lane starts a long job detached (`waitlib.py run`, scripts/waitlib.py) and ends its turn. The spec it wrote
#            ($RUN_DIR/<session>.wait, $HARNESS_WAIT_FILE in the lane) names a condition (a pid exits, a file appears, a
#            regex in a log, the winsma queue) and a deadline. wait_tend, from the worker's lane tend (every
#            HARNESS_TEND_TICK / POLL), resumes the lane's session ONCE when the condition holds or the deadline passes: a
#            message through the CLI adapter's resume path (the headless inbox, or the pane), `wait done: <condition>,
#            rc=<n>, log tail: …`. No model call is made between the end of the turn and that message.
#   limit    The usage limit takes the same path for EVERY CLI. Only Claude Code continues by itself after a reset
#            (interactive, at most 3 times, never for a reset over 24h away); codex, copilot, hermes, openclaw, opencode
#            and agy stop, and their headless modes exit non-zero. So a lane the limit froze is PARKED (wait_limit_park,
#            from the watchdog) instead of nudged every few polls, and resumed once the usage hold of its account has
#            cleared and its reset time has passed, staggered so a reset does not wake every lane in the same second.
#   winsma   #1034's park (a lane gave its pool slot up for the winsma lock queue) is the same spec with `resume=redispatch`:
#            the lane's session is gone, so waking it is removing the waiting label and letting the pool relaunch the
#            issue (winsma_wake_tick, lib.sh).
#
# Knobs: HARNESS_WAIT_STAGGER_S (30) seconds between two limit resumes; HARNESS_LIMIT_PARK_MIN (30) minutes a limit park
# without a known reset time waits before its lane is tried again; HARNESS_WAIT_JITTER_S (60) the per-lane spread added to
# a limit park's reset time; HARNESS_WINSMA_WAKE_S (60) the throttle of the winsma queue question.
WAITLIB_PY="${WAITLIB_PY:-$ENGINE_DIR/scripts/waitlib.py}"

# wait_file <sess> — where a lane's wait spec lives (the lane's HARNESS_WAIT_FILE).
wait_file(){ printf '%s' "$RUN_DIR/$1.wait"; }
# wait_standing <sess> — the lane has a wait spec (or a resume message not yet delivered): it ended its turn on purpose, so no goal
# loop re-feeds it, no supervisor nudges it and the watchdog does not count its idle prompt.
wait_standing(){ [[ -s "$RUN_DIR/$1.wait" || -s "$RUN_DIR/$1.wait.msg" ]]; }
# wait_env — add the wait file to SESSION_ENV for the session launch_agent is starting ($1).
wait_env(){ SESSION_ENV+=(-e "HARNESS_WAIT_FILE=$(wait_file "$1")"); }
# wait_forget <sess> — drop an inject wait of a session that is gone (a redispatch spec outlives its lane on purpose).
wait_forget(){ local f="$RUN_DIR/$1.wait"
  [[ -f "$f" && "$(python3 "$WAITLIB_PY" show --file "$f" --field resume 2>/dev/null)" == redispatch ]] || rm -f "$f"
  rm -f "$f.msg" "$RUN_DIR/$1.wait.asked"; }
# wait_spec_field <file> <field> — one field of a spec ('' when none).
wait_spec_field(){ python3 "$WAITLIB_PY" show --file "$1" --field "$2" 2>/dev/null; }

# usage_held_for <account> — the account's usage hold stands; with no account known, any hold does.
usage_held_for(){ [[ -n "${1:-}" ]] || { usage_held; return; }
  [[ -f "$(_usage_hold_dir)/$(_usage_key "$1").hold" ]]; }

# wait_stagger_ok — one limit resume per HARNESS_WAIT_STAGGER_S seconds across the fleet's workers: the first caller after the
# window takes the slot (the stamp, under a lock), the rest try again next tick.
wait_stagger_ok(){ local gap="${HARNESS_WAIT_STAGGER_S:-30}" f="$RUN_DIR/wait-stagger.stamp" now t lockfd ok=1
  [[ "$gap" =~ ^[0-9]+$ ]] || gap=30
  (( gap > 0 )) || return 0
  lock_try "$RUN_DIR/wait-stagger.lock" lockfd || return 1
  now="$(date +%s)"; t="$(cat "$f" 2>/dev/null)"
  if [[ "$t" =~ ^[0-9]+$ ]] && (( now - t < gap )); then ok=0; else echo "$now" > "$f"; fi
  lock_release "$lockfd"; (( ok == 0 )) && return 1; return 0; }

# _wait_limit_reset <sess> <pane> — the epoch the usage limit resets at: the headless lane runner's reading (every adapter
# parses its CLI's message), else nothing (a pane's "resets 3pm (UTC)" is wall-clock words the park does not guess at).
_wait_limit_reset(){ local r
  [[ "$(sess_backend)" == headless && -s "$(headless_lane_dir "$1")/state.json" ]] || return 0
  r="$(python3 "$HEADLESS_LANE_PY" state --lane "$(headless_lane_dir "$1")" --field limit_resets_at 2>/dev/null)"
  r="${r%%.*}"; [[ "$r" =~ ^[0-9]+$ ]] || return 0
  (( r > $(date +%s) && r < $(date +%s) + 8 * 86400 )) && echo "$r"; return 0; }

# wait_limit_park <sess> <pane> — a lane the usage limit froze is parked, not nudged. rc 0 = parked (now or already), 1 = the spec
# could not be written (the caller falls back to the nudge). The spec carries the earliest time it may be tried again: the
# reset time (plus the lane's own jitter, so lanes spread out) or HARNESS_LIMIT_PARK_MIN from now.
wait_limit_park(){ local sess="$1" pane="$2" f nb reset acct jit mins now what
  f="$(wait_file "$sess")"
  wait_standing "$sess" && return 0    # parked already (or waiting on a job: that wake comes first), or its resume message is on its way
  now="$(date +%s)"; reset="$(_wait_limit_reset "$sess" "$pane")"; acct="$(session_account "$sess" 2>/dev/null)"
  jit="${HARNESS_WAIT_JITTER_S:-60}"; [[ "$jit" =~ ^[1-9][0-9]*$ ]] || jit=0
  (( jit > 0 )) && jit=$(( $(printf '%s' "$sess" | cksum | cut -d' ' -f1) % jit )) || jit=0
  mins="${HARNESS_LIMIT_PARK_MIN:-30}"; [[ "$mins" =~ ^[0-9]+$ ]] || mins=30
  if [[ -n "$reset" ]]; then nb=$(( reset + jit )); what="usage limit (resets $(limit_reset "$pane"))"
  else nb=$(( now + mins * 60 + jit )); what="usage limit (reset time unknown; tried again in ${mins}m)"; fi
  python3 "$WAITLIB_PY" set --file "$f" --limit --until "$nb" --account "$acct" --what "$what" >/dev/null 2>&1 || return 1
  return 0; }

# wait_limit_ready <sess> <spec> — a limit park may be resumed: the lane's account holds no usage hold, the reset time has
# passed, and the stagger gives it a slot.
wait_limit_ready(){ local sess="$1" f="$2" nb acct
  IFS=$'\t' read -r nb acct < <(python3 "$WAITLIB_PY" fields --file "$f" not_before account 2>/dev/null) || return 1
  nb="${nb%%.*}"; [[ "$nb" =~ ^[0-9]+$ ]] || nb=0
  (( $(date +%s) >= nb )) || return 1
  usage_held_for "$acct" && return 1
  wait_stagger_ok; }

# wait_winsma_turn <issue> — ask the winsma host whether #<issue>'s ticket is next and the lock free. rc 0 = next (or no Windows host
# is configured: nothing to wait for), 1 = still waiting, 2 = the host could not be asked. $WAIT_WINSMA_OUT holds its last line.
wait_winsma_turn(){ local out rc
  if [[ -n "${HARNESS_WINDOWS_HOST:-}" ]]; then
    # Into a file, not a $(…) pipe: where timeout cannot signal the whole process group (Git Bash), a child the killed bash left
    # behind holds the pipe open and the substitution would wait for it, past the timeout (#1109).
    local of; of="$(mktemp "${RUN_DIR:-${TMPDIR:-/tmp}}/winsma-turn.XXXXXX")" || of=/dev/null
    timeout "${WS_WAKE_TIMEOUT:-20}" bash "$ENGINE_DIR/test/smoke/winsma/winsma.sh" turn "$1" >"$of" 2>&1 </dev/null; rc=$?
    out="$(cat "$of" 2>/dev/null)"; [[ "$of" == /dev/null ]] || rm -f "$of"
  else out="no Windows host is configured"; rc=0; fi
  WAIT_WINSMA_OUT="${out##*$'\n'}"
  case "$rc" in 0) return 0;; 1) return 1;; *) return 2;; esac; }

# _wait_deliver <sess> — send the lane the resume message waiting in <sess>.wait.msg, once. The message is kept on disk until
# the send succeeded, so a failed send is retried next tick and a delivered one is never sent again.
_wait_deliver(){ local sess="$1" mf="$RUN_DIR/$1.wait.msg" msg
  [[ -s "$mf" ]] || return 0
  msg="$(cat "$mf")"
  cli_send "$sess" "$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)" "$msg" || return 1
  rm -f "$mf"; return 0; }

# _wait_foreign <sess> <spec> — #1084: the spec in a live lane's wait file names an issue or repo that is not the lane's (a test
# wrote its fixture park there). Prints "#<issue> <slug>" of the spec and returns 0 when so. The lane's identity is its .stats
# (issue, prd, repo): a park's issue is the lane's issue, or its PRD for a review lane. A spec with no issue/slug, or a lane whose
# .stats cannot be read, is never foreign.
_wait_foreign(){ python3 - "$RUN_DIR/$1.stats" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    lane = json.load(open(sys.argv[1])); spec = json.load(open(sys.argv[2]))
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(lane, dict) or not isinstance(spec, dict):
    sys.exit(1)
def s(v): return "" if v is None else str(v).strip()
issue, slug = s(spec.get("issue")), s(spec.get("slug"))
mine = {x for x in (s(lane.get("issue")), s(lane.get("prd"))) if x}
repo = s(lane.get("repo"))
bad = (issue and mine and issue not in mine) or (slug and repo and slug != repo)
if not bad:
    sys.exit(1)
print(f"#{issue or '-'} {slug or '-'}")
PY
}

# wait_tend <sess> — one tick for one live lane: resume it, once, when its wait is over. A busy lane is left alone (it did not end its
# turn yet; the wait is judged when it does). rc 0 always.
wait_tend(){ local sess="$1" f mf pane cond resume msg rc asked reason issue foreign
  f="$(wait_file "$sess")"; mf="$f.msg"
  [[ -s "$f" || -s "$mf" ]] || return 0
  session_live "$sess" || return 0
  pane="$(sess_capture "$sess" 2>/dev/null)" || return 0
  # a lane that is working has not ended its turn: nothing to resume it with, nothing to wait for yet
  if ! cli_pane_prompt "$pane" || session_active_turn "$pane" || { declare -F lane_subagent_running >/dev/null && lane_subagent_running "$pane"; }; then return 0; fi
  if [[ -s "$mf" ]]; then _wait_deliver "$sess" || log "wait: $sess — could not deliver the resume message, retrying next tick (#1066)"; return 0; fi
  IFS=$'\t' read -r cond resume issue < <(python3 "$WAITLIB_PY" fields --file "$f" cond resume issue 2>/dev/null) || return 0
  if foreign="$(_wait_foreign "$sess" "$f")"; then   # #1084: not this lane's spec — drop it, resume the lane
    rm -f "$f"
    printf '%s' "Your wait spec was replaced by a foreign one (${foreign}) and has been removed. Check whether your job is still running and re-arm your wait (harness-wait run / set) if it is; otherwise carry on." > "$mf"
    log "wait: $sess — foreign wait spec (issue/slug ${foreign}) in this lane's file; removed, lane resumed (#1084)"
    stats_sess_event "$sess" wait_done cond=foreign
    _wait_deliver "$sess" || log "wait: $sess — could not deliver the resume message, retrying next tick (#1066)"
    return 0
  fi
  [[ "$resume" == redispatch ]] && return 0   # winsma_wake_tick's: the session is gone
  if [[ "$cond" == limit ]] && ! session_limit_idle "$pane"; then
    log "wait: $sess — no longer at the usage limit; park dropped (#1066)"; rm -f "$f"; return 0; fi
  msg="$(python3 "$WAITLIB_PY" fire --file "$f" 2>/dev/null)"; rc=$?
  if (( rc == 1 )); then                      # pending by its own clock: the engine judges the external conditions
    case "$cond" in
      limit)  wait_limit_ready "$sess" "$f" || return 0; reason="usage limit cleared";;
      winsma) asked="$RUN_DIR/$sess.wait.asked"
              if [[ -f "$asked" ]] && (( $(date +%s) - $(stat -c %Y "$asked" 2>/dev/null || echo 0) < ${HARNESS_WINSMA_WAKE_S:-60} )); then return 0; fi
              : > "$asked"
              wait_winsma_turn "$issue" || return 0; reason="${WAIT_WINSMA_OUT:-first in the winsma queue}";;
      *)      return 0;;
    esac
    msg="$(python3 "$WAITLIB_PY" fire --file "$f" --satisfied "$reason" 2>/dev/null)"; rc=$?
  fi
  (( rc == 0 )) || return 0                  # none left (another worker took it) or still pending
  printf '%s' "$msg" > "$mf"
  log "wait: $sess — ${msg:0:200} (#1066)"
  stats_sess_event "$sess" wait_done cond="$cond"
  _wait_deliver "$sess" || log "wait: $sess — could not deliver the resume message, retrying next tick (#1066)"
  return 0; }

# wait_sweep — chores: an inject wait whose session is gone is void (a redispatch spec waits for winsma_wake_tick).
wait_sweep(){ local f s
  shopt -s nullglob
  for f in "$RUN_DIR"/*.wait "$RUN_DIR"/*.wait.msg; do
    s="$(basename "$f")"; s="${s%.wait.msg}"; s="${s%.wait}"
    session_live "$s" || wait_forget "$s"
  done
  shopt -u nullglob; return 0; }

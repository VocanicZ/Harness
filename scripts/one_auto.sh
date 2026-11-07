#!/usr/bin/env bash
# one_auto.sh — #392 (PRD #362): HARNESS_ONE_AUTO=1 starts ONE headless harness-one lane by itself while
# an account's #194 usage hold is on. Sourced by lib.sh (after usage.sh); defines functions only. The
# spawn half (one_auto_spawn) needs drive.sh's prepare_impl, so only the pool worker (worker_chores) calls one_auto_tick.
#
#   trigger   the pool worker's chores call one_auto_tick every tick while usage is HELD; it does nothing unless this
#             fleet set HARNESS_ONE_AUTO=1. No operator step, no human gate.
#   one lane  per ACCOUNT, host-wide: usage is per account, so the lane record
#             $HARNESS_HOME/one-auto/<account>.lane (taken under <account>.lock) is shared by every fleet
#             on the host. The fleet that owns it refreshes it each poll (one_auto_tend); a record nobody
#             refreshed for _oa_stale seconds is a dead fleet's and is free again.
#   turns     each opted-in, held fleet unit with a claimable issue keeps <account>.want/<fleet-unit>
#             fresh; a free lane goes to the first such entry after the one served last
#             (<account>.last), so fleets on one account take turns.
#   gate      the #365 rule, no human: start the issue only if `harness one gate` APPROVEs
#             (now% + p80% + reserve <= HARNESS_ONE_STOP_PCT in every window). A DENY STOPS the chain
#             for the account until the held window resets (<account>.stopped), logging the forecast.
#   execution #366: prepare_impl claims + renders impl.md (resume.md for an agent-paused issue); the
#             lane is an ordinary impl session of the fleet (hz-<unit>-i<n>), so the reapers, watchdog
#             and goal check tend it like any lane. Its task ends with the per-phase re-check
#             (`harness one phase`); a CHECKPOINT is pause --force's message — the issue is left
#             agent-paused, its branch pushed, a handoff comment posted. one_auto_tend then ends the lane.
#   chaining  #367: the lane's issue closed (the goal check) → the next poll picks the next claimable
#             issue with a fresh forecast. An issue still OPEN once its lane is gone stops the chain.
#   hand-back the hold clears → the pool worker stops calling one_auto_tick: no new issue starts. The live
#             lane finishes (or checkpoints) as a normal session of the fleet — its issue stays
#             agent-working, so the pool never races it for the claim.
# Every start and stop is a stats event (one_auto_start / one_auto_stop / one_auto_done); `harness
# status` and the web dashboard read the lane and stop records (one_auto_report, web_data.one_auto).

one_auto_dir(){ echo "${HARNESS_ONE_AUTO_DIR:-$HARNESS_HOME/one-auto}"; }
_oa_file(){ echo "$(one_auto_dir)/$(_usage_key "$1").$2"; }   # <account> <lane|stopped|last|lock|want>
_oa_stale(){ local s=$(( 3 * ${POLL:-300} )); (( s < 900 )) && s=900; echo "$s"; }
_oa_fresh(){ local m; m="$(stat -c %Y "$1" 2>/dev/null)" || return 1; (( $(date +%s) - m < $(_oa_stale) )); }
_oa_me(){ _usage_key "$STATE_DIR:${UNIT:-}"; }   # this fleet unit's key in the turn order
# _oa_say <key> <message> — log once per distinct key in this process (a held fleet polls every POLL).
_oa_say(){ [[ "${_OA_SAID:-}" == "$1" ]] && return 0; _OA_SAID="$1"; log "one-auto: $2"; }

# one_auto_account — the held account this fleet's lane runs for: its first usage hold's account.
one_auto_account(){ local hf acct rest
  for hf in "$(_usage_hold_dir)"/*.hold; do
    [[ -f "$hf" ]] || continue
    IFS=$'\t' read -r acct rest < "$hf"; [[ -n "$acct" ]] && { echo "$acct"; return 0; }
  done
  return 1; }

# _oa_hold_reset <account> — when the held window resets (epoch), from this fleet's hold record.
_oa_hold_reset(){ local acct win pct reset
  IFS=$'\t' read -r acct win pct reset < "$(_usage_hold_dir)/$(_usage_key "$1").hold" 2>/dev/null
  echo "${reset:-0}"; }

# one_auto_lane_live <account> — a lane record some fleet still refreshes.
one_auto_lane_live(){ local f; f="$(_oa_file "$1" lane)"; [[ -f "$f" ]] && _oa_fresh "$f"; }

# one_auto_stopped <account> — the chain stopped for this account and its window has not reset yet.
one_auto_stopped(){ local f until rest; f="$(_oa_file "$1" stopped)"; [[ -f "$f" ]] || return 1
  IFS=$'\t' read -r until rest < "$f"; (( ${until:-0} > $(date +%s) )); }

# _oa_stop <account> <reason> <detail> [issue] — stop the account's chain until its window resets.
_oa_stop(){ local acct="$1" until; until="$(_oa_hold_reset "$acct")"
  (( until > $(date +%s) )) || until=$(( $(date +%s) + 3600 ))   # no reset known: an hour
  printf '%s\t%s\t%s\t%s\t%s\n' "$until" "$2" "$3" "${SLUG:-}" "${4:-}" > "$(_oa_file "$acct" stopped)"
  log "one-auto: $acct lane stops — $2: $3"
  harness_event one_auto_stop account="$acct" reason="$2" issue="${4:-}" detail="$3"; }

# _oa_my_turn <account> — is this fleet unit the next fresh want after the one served last?
_oa_my_turn(){ local d last f k first="" pick=""; d="$(_oa_file "$1" want)"
  last="$(cat "$(_oa_file "$1" last)" 2>/dev/null)"
  for f in "$d"/*; do
    [[ -f "$f" ]] && _oa_fresh "$f" || continue
    k="${f##*/}"; [[ -z "$first" ]] && first="$k"
    [[ -z "$pick" && "$k" > "$last" ]] && pick="$k"
  done
  [[ "${pick:-$first}" == "$(_oa_me)" ]]; }

# _oa_summary <gate json file> — the forecast arithmetic, one `acct window: now + p80 + reserve = need`
# per window, and the reasons for a DENY.
_oa_summary(){ python3 - "$1" <<'PY' 2>/dev/null
import json, sys
try:
    g = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("no forecast"); sys.exit()
ws = []
for w in g.get("windows") or []:
    name = f"{w.get('account', '')} {w.get('window', '')}".strip()
    ws.append(f"{name}: now {w['now']:g}%" + (f" + p80 {w['p80']:g}% + reserve {g['reserve']:g}% = {w['need']:g}%"
              if w.get("need") is not None else " + p80 n/a") + f" vs stop {g['stop']:g}%")
fc = g.get("forecast") or {}
p80 = (fc.get("total") or {}).get("p80")
out = "; ".join(ws) or "no usage window"
if p80 is not None:
    out = f"p80 ${p80:g} — " + out
if g.get("reasons"):
    out += " — " + "; ".join(g["reasons"])
print(out)
PY
}

# _one_auto_note <issue> — appended to the lane's rendered task: the #366 per-phase re-check, for a lane
# no human watches. The checkpoint itself is the message `harness one phase` prints.
_one_auto_note(){ local h; h="$(printf '%q --state-dir %q one' "$ENGINE_DIR/bin/harness" "$STATE_DIR")"
  cat <<NOTE

HARNESS ONE (AUTO) — this lane was started by HARNESS_ONE_AUTO while the account's usage is HELD
near its limit; it is the only lane running on it. The budget is tight, so:
BEFORE EACH PHASE — explore, test, impl, gate, ship, in that order — run:
  $h phase $1 <phase> --unit $UNIT
  Exit 0 (FITS): go on with that phase.
  Exit 1 (CHECKPOINT): do not start the phase. It prints a message beginning "HARNESS CHECKPOINT",
  the one \`harness pause --force\` sends a fleet lane: follow it exactly — commit + push the branch,
  the handoff comment, the $HARNESS_LABEL_WORKING → $HARNESS_LABEL_PAUSED swap — then exit. The engine
  ends this lane; the pool resumes the issue after the usage window resets.
Merged and closed: output the completion promise as usual; the engine picks the next issue itself.
NOTE
}

# one_auto_spawn <issue> — the lane: prepare_impl (the claim, the worktree, impl.md or resume.md), the
# per-phase note, then an ordinary impl session. rc 1 when it could not be set up or launched.
one_auto_spawn(){ local issue="$1" wd; MAXITER="$IMPL_MAXITER"; GOAL="ISSUE:$issue"; STAT_PRD=""
  wd="$WORKTREES_DIR/$UNIT-i$issue"
  prepare_impl "$issue" "ISSUE $issue DONE" && [[ -s "$wd/.harness-task.md" ]] || return 1
  _one_auto_note "$issue" >> "$wd/.harness-task.md"
  STAT_PRD="$(prepared_parent_prd "$issue")"   # #618: off the view prepare_impl made
  launch_claude "$(sess_impl "$UNIT" "$issue")" "$wd"; }

# one_auto_tick — the pool worker's chores while usage is HELD, every tick: start the account's lane on this fleet's
# next claimable issue when the lane is free, the chain is not stopped, it is this fleet's turn and the
# gate APPROVEs. Never blocks the poll on failure.
one_auto_tick(){ local acct next want lockfd claimfd gj rc sum sess
  [[ "${HARNESS_ONE_AUTO:-0}" == 1 ]] || return 0
  acct="$(one_auto_account)" || return 0
  mkdir -p "$(_oa_file "$acct" want)" 2>/dev/null || return 0
  if one_auto_stopped "$acct"; then _oa_say "stopped:$acct" "$acct lane stopped until its window resets"; return 0; fi
  want="$(_oa_file "$acct" want)/$(_oa_me)"
  # #446: never the issue a live lane still owns (busy_issues_for, as dispatch skips it, #416): its
  # worktree add fails, and the same busy issue came back every poll — the chain never moved on.
  next="$(python3 "$ISSUELIB" next "$REPO" --exclude "$(busy_issues_for "$UNIT")" 2>/dev/null)" || return 0
  if [[ -z "$next" ]]; then
    rm -f "$want"; _oa_say "none:$acct" "no claimable issue on $SLUG for the $acct lane"; return 0; fi
  touch "$want"
  lock_acquire "$(_oa_file "$acct" lock)" lockfd
  if one_auto_lane_live "$acct" || one_auto_stopped "$acct" || ! _oa_my_turn "$acct"; then
    lock_release "$lockfd"; return 0; fi
  gj="$(mktemp)"
  bash "$ENGINE_DIR/scripts/one.sh" gate "$next" -R "$SLUG" --unit "$UNIT" --json > "$gj" 2>/dev/null; rc=$?
  sum="$(_oa_summary "$gj")"; rm -f "$gj"
  if (( rc != 0 )); then
    _oa_stop "$acct" deny "$SLUG#$next does not fit under HARNESS_ONE_STOP_PCT=$HARNESS_ONE_STOP_PCT% ($sum)" "$next"
    lock_release "$lockfd"; return 0; fi
  sess="$(sess_impl "$UNIT" "$next")"
  # #561: the pool's impl-<n> lane claim, written before the worktree exists and held until the session is up, so
  # reap_team (is_claimed) keeps off the spawn window and the pool cap counts the lane. A claim a pool worker
  # holds already means the issue is not ours to start.
  mkdir -p "$CLAIMS_DIR"; lock_acquire "$POOL_LOCK" claimfd
  if is_claimed "impl-$next"; then lock_release "$claimfd"; lock_release "$lockfd"; return 0; fi
  lane_claim_write "impl-$next" one-auto "IMPL:$next" "$sess"
  lock_release "$claimfd"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$STATE_DIR" "$UNIT" "$SLUG" "$next" "$sess" "$acct" "$(date +%s)" "$sum" \
    > "$(_oa_file "$acct" lane)"
  _oa_me > "$(_oa_file "$acct" last)"
  lock_release "$lockfd"
  _OA_SAID=""
  one_auto_spawn "$next"; rc=$?
  rm -f "$CLAIMS_DIR/impl-$next.claim"   # #561: the session is up (adopt_lanes takes it over) or the spawn failed (the reapers clean up)
  if (( rc != 0 )); then
    rm -f "$(_oa_file "$acct" lane)"
    log "one-auto: could not start $SLUG#$next — the reapers release its claim"; return 0; fi
  log "one-auto: $acct lane started on $SLUG#$next ($sum)"
  harness_event one_auto_start account="$acct" issue="$next" session="$sess" forecast="$sum"; }

# one_auto_tend — every poll, held or not: the lane records THIS fleet unit owns. A live lane whose issue
# went agent-paused has checkpointed — end it (its relaunch after the reset resumes it). A live one is
# refreshed. A lane that is gone frees the record: its issue closed → done, the chain goes on; still
# open → the chain stops for the account.
one_auto_tend(){ local f fsd funit fslug issue sess acct rest st
  shopt -s nullglob
  for f in "$(one_auto_dir)"/*.lane; do
    IFS=$'\t' read -r fsd funit fslug issue sess acct rest < "$f" || continue
    [[ "$fsd" == "$STATE_DIR" && "$funit" == "${UNIT:-}" ]] || continue
    if session_live "$sess"; then
      st="$(gh issue view "$issue" -R "$fslug" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null)" \
        || { touch "$f"; continue; }
      if [[ ",$st," != *",$HARNESS_LABEL_PAUSED,"* ]]; then touch "$f"; continue; fi
      log "one-auto: $fslug#$issue checkpointed ($HARNESS_LABEL_PAUSED) — ending lane $sess"
      cli_kill "$sess" "$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)" >/dev/null 2>&1 || true
      stats_sess_event "$sess" paused reason=one_auto_checkpoint
    fi
    st="$(gh issue view "$issue" -R "$fslug" --json state -q .state 2>/dev/null)" || { touch "$f"; continue; }
    rm -f "$f"
    if [[ "$st" == CLOSED ]]; then
      log "one-auto: $acct lane finished $fslug#$issue — closed; the next poll picks the next issue"
      harness_event one_auto_done account="$acct" issue="$issue"
    else
      SLUG="$fslug" _oa_stop "$acct" open_after_run "$fslug#$issue is still open after its run (checkpointed or failed)" "$issue"
    fi
  done
  shopt -u nullglob; }

# one_auto_report — `harness status`: every auto lane and chain stop on the host.
one_auto_report(){ local f fsd funit fslug issue sess acct started sum until reason detail slug n
  shopt -s nullglob
  for f in "$(one_auto_dir)"/*.lane; do
    IFS=$'\t' read -r fsd funit fslug issue sess acct started sum < "$f" || continue
    _oa_fresh "$f" || continue
    printf '  one-auto: %s lane on %s#%s (%s, since %s) — %s\n' "$acct" "$fslug" "$issue" "$sess" \
      "$(date -d "@$started" '+%a %H:%M' 2>/dev/null || echo "$started")" "${sum:-no forecast}"
  done
  for f in "$(one_auto_dir)"/*.stopped; do
    IFS=$'\t' read -r until reason detail slug n < "$f" || continue
    (( ${until:-0} > $(date +%s) )) || continue
    printf '  one-auto: %s lane STOPPED (%s) until %s — %s\n' "$(basename "$f" .stopped)" "$reason" \
      "$(date -d "@$until" '+%a %H:%M' 2>/dev/null || echo "$until")" "$detail"
  done
  shopt -u nullglob
  [[ "${HARNESS_ONE_AUTO:-0}" == 1 ]] && echo "  one-auto: on (HARNESS_ONE_AUTO=1) — a usage hold starts one harness-one lane per account"
  return 0; }

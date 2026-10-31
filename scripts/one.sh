#!/usr/bin/env bash
# one.sh — `harness one`: the /harness-one budget gate (#365) and execution (#366), PRD #362. One
# issue at a time, worked in the invoking session, while the fleet itself claims nothing.
#
#   harness one check
#       the precondition: the fleet is PAUSED (is_paused) or its claims are usage-HELD (usage_held,
#       #194). Anything else — a RUNNING, un-held fleet, or a stopped one a `harness start` would
#       bring back un-paused — is refused: its pool would race this session for the claim.
#   harness one gate <issue> [-R owner/repo] [--unit U] [--json]
#       the precondition, then the issue's forecast (forecast.py, #363/#364) against the freshest
#       usage reading of every window (cli_limit_usage), and the recommendation (one.py):
#       APPROVE iff now% + p80% + HARNESS_ONE_RESERVE_PCT <= HARNESS_ONE_STOP_PCT, else DENY.
#       It only recommends — the human decides (skill/harness-one), and nothing is claimed here.
#
#   harness one start <issue> [-R owner/repo] [--unit U]                                   (#366)
#       on the human's approval: the precondition again, immediately before the claim, then the claim
#       and setup exactly as dispatch does it (prepare_impl: agent-working, the issue's worktree on
#       issue/<n>, impl.md — resume.md for an agent-paused issue) plus a lease standing in for the
#       lane session the reapers look for (one_lease_live). The invoking session works the task file.
#   harness one phase <issue> <explore|test|impl|gate|ship> [-R …] [--unit U] [--json]      (#366)
#       before each phase: fresh usage vs the forecast LEFT (one.py phase). FITS → go on. CHECKPOINT
#       → the very HARNESS CHECKPOINT `pause --force` sends a lane (_checkpoint_msg), for this session.
#   harness one release <issue> [-R …] [--unit U] [--force]                                 (#366)
#       after the checkpoint or the merge: drop the worktree, local branch and lease, so the pool
#       resumes the issue as its own. Refuses to drop work that is not pushed, without --force.
#
# Exit status: check 0 pass / 1 refused; gate 0 APPROVE / 1 DENY / 2 bad args or no forecast / 3 refused;
# start 0 claimed / 2 bad args / 3 refused / 4 not claimable / 5 setup failed; phase 0 FITS /
# 1 CHECKPOINT / 2 bad args or not started; release 0 released / 2 bad args / 4 unpushed work.
# Sourced by test/test_one.sh; runs one_main only when executed directly.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# one_check — print why harness-one may run here (rc 0), or why not (stderr, rc 1).
one_check(){ local hf acct win pct reset
  if is_paused; then echo "harness one: the fleet is PAUSED — its pool claims nothing"; return 0; fi
  if usage_held; then
    for hf in "$(_usage_hold_dir)"/*.hold; do
      IFS=$'\t' read -r acct win pct reset < "$hf"
      echo "harness one: claims are usage-HELD (${acct:-?} ${win:-?} window at ${pct:-?}%) — the pool claims nothing until it resets"
      return 0
    done
  fi
  cat >&2 <<EOF
harness one: refused — the fleet is not PAUSED and no account is usage-HELD, so its pool would
  race this session for the claim. Pause it first: harness pause (drain) or harness pause --force.
EOF
  return 1; }

# _one_reading_age <account> <now> — seconds since <account>'s usage was last read, '' = unknown:
# its status-line drop (<usage-dir>/<account>.json, the claude adapter), else the newest usage
# cache another adapter writes (<usage-dir>/<cli>.tsv).
_one_reading_age(){ local f d newest=""
  d="$(_usage_dir)"; f="$d/$(_usage_key "$1").json"
  if [[ -f "$f" ]]; then newest="$(stat -c %Y "$f" 2>/dev/null)"
  else
    for f in "$d"/*.tsv; do
      [[ -f "$f" ]] || continue
      local m; m="$(stat -c %Y "$f" 2>/dev/null)" || continue
      (( m > ${newest:-0} )) && newest="$m"
    done
  fi
  [[ -n "$newest" ]] && echo $(( $2 - newest )) || echo ""; }

# one_readings — the usage readings TSV one.py reads: `<account>\t<window>\t<pct>\t<resets_at>\t<age>`.
# Prints nothing when usage is unavailable (the gate then DENIES: it cannot show the work fits).
one_readings(){ local out acct win pct reset now; now="$(date +%s)"
  out="$(cli_limit_usage 2>/dev/null)" || return 0
  while IFS=$'\t' read -r acct win pct reset; do
    [[ -n "$acct" && -n "$pct" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$acct" "$win" "$pct" "${reset:-0}" "$(_one_reading_age "$acct" "$now")"
  done <<< "$out"; }

# one_gate <issue> [forecast args…] [--json] — precondition, forecast, readings, recommendation.
one_gate(){ local issue="${1:-}" json="" a fc rd rc; shift || true
  [[ "$issue" =~ ^[0-9]+$ ]] || { echo "usage: harness one gate <issue> [-R owner/repo] [--unit U] [--json]" >&2; return 2; }
  local -a fargs=()
  for a in "$@"; do if [[ "$a" == --json ]]; then json=--json; else fargs+=("$a"); fi; done
  one_check >&2 || return 3
  fc="$(mktemp)"; rd="$(mktemp)"
  python3 "$ENGINE_DIR/scripts/forecast.py" "$issue" ${fargs[@]+"${fargs[@]}"} --json > "$fc"; rc=$?
  # rc 1 = no past lanes on the host: its JSON still prints, and the gate DENIES on it.
  if (( rc != 0 && rc != 1 )); then rm -f "$fc" "$rd"; return 2; fi
  one_readings > "$rd"
  python3 "$ENGINE_DIR/scripts/one.py" gate --forecast "$fc" --readings "$rd" \
    --stop "$HARNESS_ONE_STOP_PCT" --reserve "$HARNESS_ONE_RESERVE_PCT" \
    --stale-min "$HARNESS_ONE_STALE_MIN" --stale-pad "$HARNESS_ONE_STALE_PAD_PCT" $json; rc=$?
  rm -f "$fc" "$rd"; return $rc; }

# _one_target [-R owner/repo] [--unit U] [other args ignored] — set UNIT REPO SLUG PROJECT DESC
# CHECKOUT, the dynamic-scope vars drive.sh's helpers read, as drive_unit sets them. The caller
# declares them local. No -R/--unit: the project's only unit. rc 2 when none or several match.
_one_target(){ local want="" unit="" u
  while (( $# )); do
    case "$1" in -R) want="${2:-}"; shift;; --unit) unit="${2:-}"; shift;; esac
    shift || true
  done
  if [[ -z "$unit" ]]; then
    for u in $(all_units); do
      [[ -z "$want" || "${want,,}" == "$(unit_slug "$u" | tr '[:upper:]' '[:lower:]')" ]] || continue
      [[ -n "$unit" ]] && { echo "harness one: more than one unit${want:+ on $want} — name it with --unit" >&2; return 2; }
      unit="$u"
    done
  fi
  REPO=""; [[ -n "$unit" ]] && REPO="$(unit_repo "$unit")"
  [[ -n "$REPO" && "$REPO" != - ]] || { echo "harness one: no unit${want:+ for $want}${unit:+ named $unit}" >&2; return 2; }
  UNIT="$unit"; SLUG="$(unit_slug "$unit")"; PROJECT="$unit"; DESC="$(unit_desc "$unit")"; CHECKOUT="$(unit_checkout "$unit")"; }

# _one_state <issue> — `<OPEN|CLOSED> <label,label,…>` of $SLUG#<issue>; rc 1 when gh cannot read it.
_one_state(){ gh issue view "$1" -R "$SLUG" --json state,labels -q '.state + " " + ([.labels[].name] | join(","))' 2>/dev/null; }
_one_has(){ [[ ",${1#* }," == *",$2,"* ]]; }   # <_one_state line> <label>

# _one_cmd — this project's `harness one`, runnable from any directory (the worktree included).
_one_cmd(){ printf '%q --state-dir %q one' "$ENGINE_DIR/bin/harness" "$STATE_DIR"; }

# _one_note <issue> — the section `harness one start` appends to the rendered task: the per-phase
# re-check, and what to do on a checkpoint or once merged. The checkpoint itself is the message
# one_phase prints, word for word what a pool lane is sent.
_one_note(){ local h; h="$(_one_cmd)"
  cat <<NOTE

HARNESS ONE — you are working this issue in an interactive /harness-one session, not a fleet lane:
nothing relaunches you, and the fleet stays paused or usage-held while you work.
BEFORE EACH PHASE — explore, test, impl, gate, ship, in that order — run:
  $h phase $1 <phase> --unit $UNIT
  Exit 0 (FITS): go on with that phase.
  Exit 1 (CHECKPOINT): do not start the phase. It prints a message beginning "HARNESS CHECKPOINT",
  the one `harness pause --force` sends a fleet lane: follow it exactly — commit + push the branch,
  the handoff comment, the $HARNESS_LABEL_WORKING → $HARNESS_LABEL_PAUSED swap — then, instead of
  exiting, run the release below and stop.
WHEN DONE — merged and closed, or checkpointed — run:
  $h release $1 --unit $UNIT
NOTE
}

# one_start <issue> [-R owner/repo] [--unit U] — claim + set up an approved issue for this session.
one_start(){ local issue="${1:-}" st wd lease; shift || true
  [[ "$issue" =~ ^[0-9]+$ ]] || { echo "usage: harness one start <issue> [-R owner/repo] [--unit U]" >&2; return 2; }
  local UNIT REPO SLUG PROJECT DESC CHECKOUT IMPL_TMPL="" PROMISE=""
  _one_target "$@" || return 2
  one_check >&2 || return 3   # re-checked immediately before the claim: a resumed pool would race it
  st="$(_one_state "$issue")" || { echo "harness one: cannot read $SLUG#$issue" >&2; return 2; }
  [[ "$st" == "OPEN "* ]] || { echo "harness one: $SLUG#$issue is not open" >&2; return 4; }
  if _one_has "$st" "$HARNESS_LABEL_WORKING"; then
    echo "harness one: $SLUG#$issue is already $HARNESS_LABEL_WORKING — another lane has it" >&2; return 4; fi
  [[ -n "${_HARNESS_DRIVE_SOURCED:-}" ]] || source "$ENGINE_DIR/scripts/drive.sh"
  lease="$(one_lease_file "$UNIT" "$issue")"; mkdir -p "$(dirname "$lease")"
  printf '%s\t%s\t%s\n' "$UNIT" "$SLUG" "$issue" > "$lease"   # before the claim: no window for a reaper
  wd="$WORKTREES_DIR/$UNIT-i$issue"
  if ! prepare_impl "$issue" "ISSUE $issue DONE" || [[ ! -s "$wd/.harness-task.md" ]]; then
    rm -f "$lease"; unlock_issue "$SLUG" "$issue"
    echo "harness one: could not set up $SLUG#$issue's worktree — claim released" >&2; return 5; fi
  _one_note "$issue" >> "$wd/.harness-task.md"
  harness_event one_claim kind=impl issue="$issue" template="$IMPL_TMPL"
  echo "harness one: claimed $SLUG#$issue ($HARNESS_LABEL_WORKING) — rendered $IMPL_TMPL"
  echo "  worktree: $wd"
  echo "  task:     $wd/.harness-task.md   (work it in this session; it ends with the per-phase re-check)"; }

# one_phase <issue> <phase> [-R owner/repo] [--unit U] [forecast args…] [--json] — the re-check
# before <phase>: CHECKPOINT (rc 1) prints the checkpoint instruction for this session to follow.
one_phase(){ local issue="${1:-}" phase="${2:-}" json="" skip="" a fc rd rc lease
  shift 2 2>/dev/null || shift $#
  [[ "$issue" =~ ^[0-9]+$ && "$phase" =~ ^(explore|test|impl|gate|ship)$ ]] \
    || { echo "usage: harness one phase <issue> <explore|test|impl|gate|ship> [-R owner/repo] [--unit U] [--json]" >&2; return 2; }
  local -a targs=() fargs=()
  for a in "$@"; do
    if [[ -n "$skip" ]]; then targs+=("$a"); skip=""
    elif [[ "$a" == -R || "$a" == --unit ]]; then targs+=("$a"); skip=1
    elif [[ "$a" == --json ]]; then json=--json
    else fargs+=("$a"); fi
  done
  local UNIT REPO SLUG PROJECT DESC CHECKOUT
  _one_target ${targs[@]+"${targs[@]}"} || return 2
  lease="$(one_lease_file "$UNIT" "$issue")"
  [[ -f "$lease" ]] || { echo "harness one: $SLUG#$issue was not claimed by harness one start" >&2; return 2; }
  touch "$lease"   # the session is alive: hold the reapers off for another HARNESS_ONE_LEASE_MIN
  fc="$(mktemp)"; rd="$(mktemp)"
  python3 "$ENGINE_DIR/scripts/forecast.py" "$issue" -R "$SLUG" --unit "$UNIT" ${fargs[@]+"${fargs[@]}"} --json > "$fc"; rc=$?
  if (( rc != 0 && rc != 1 )); then rm -f "$fc" "$rd"; return 2; fi
  one_readings > "$rd"
  python3 "$ENGINE_DIR/scripts/one.py" phase --phase "$phase" --forecast "$fc" --readings "$rd" \
    --stop "$HARNESS_ONE_STOP_PCT" --reserve "$HARNESS_ONE_RESERVE_PCT" \
    --stale-min "$HARNESS_ONE_STALE_MIN" --stale-pad "$HARNESS_ONE_STALE_PAD_PCT" $json; rc=$?
  rm -f "$fc" "$rd"
  (( rc == 1 )) || return $rc
  harness_event one_checkpoint kind=impl issue="$issue" phase="$phase"
  [[ -n "$json" ]] && return 1
  # The instruction pause --force (and the #194 usage checkpoint) sends a live lane: same text, same labels.
  echo
  _checkpoint_msg "$issue" "$SLUG" "issue/$issue" "$HARNESS_LABEL_WORKING" "$HARNESS_LABEL_PAUSED" \
    "harness one: the forecast left from $phase no longer fits under HARNESS_ONE_STOP_PCT=$HARNESS_ONE_STOP_PCT%"
  echo
  echo "Once checkpointed — instead of exiting — run: $(_one_cmd) release $issue --unit $UNIT"
  return 1; }

# _one_unpushed <wd> — work in <wd> that only this host has: uncommitted changes (the rendered task
# and the CLI's own state aside) or commits on no origin branch.
_one_unpushed(){ [[ -d "$1" ]] || return 1
  [[ -n "$(git -C "$1" status --porcelain 2>/dev/null | grep -vE '^.. (\.harness-task\.md|\.claude/)')" ]] && return 0
  [[ -n "$(git -C "$1" rev-list HEAD --not --remotes=origin 2>/dev/null | head -1)" ]]; }

# one_release <issue> [-R owner/repo] [--unit U] [--force] — give the issue back to the pool: no
# worktree, local branch, lease or lock of this session's is left for a lane to trip over.
one_release(){ local issue="${1:-}" force="" a st wd; shift || true
  [[ "$issue" =~ ^[0-9]+$ ]] || { echo "usage: harness one release <issue> [-R owner/repo] [--unit U] [--force]" >&2; return 2; }
  for a in "$@"; do [[ "$a" == --force ]] && force=1; done
  local UNIT REPO SLUG PROJECT DESC CHECKOUT
  _one_target "$@" || return 2
  wd="$WORKTREES_DIR/$UNIT-i$issue"; st="$(_one_state "$issue")" || st=""
  if [[ "$st" != CLOSED* && -z "$force" ]] && _one_unpushed "$wd"; then
    echo "harness one: $wd has work that is not pushed — push it (the checkpoint does), or release --force to drop it" >&2
    return 4; fi
  remove_worktree "$CHECKOUT" "$wd" "issue/$issue"
  rm -f "$(one_lease_file "$UNIT" "$issue")"
  harness_event one_release kind=impl issue="$issue"
  if [[ "$st" == CLOSED* ]]; then echo "harness one: released $SLUG#$issue — closed"; return 0; fi
  if [[ -n "$st" ]] && _one_has "$st" "$HARNESS_LABEL_WORKING" && ! _one_has "$st" "$HARNESS_LABEL_PAUSED"; then
    # Never checkpointed: the lock is the last state this session owns — free it, as a reap would.
    unlock_issue "$SLUG" "$issue"
    echo "harness one: released $SLUG#$issue — not checkpointed; $HARNESS_LABEL_WORKING cleared, the pool re-dispatches it"
    return 0; fi
  echo "harness one: released $SLUG#$issue — the pool resumes it (resume.md) once the fleet resumes or the usage hold lifts"; }

one_main(){ local cmd="${1:-}"; shift || true
  case "$cmd" in
    check)   one_check;;
    gate)    one_gate "$@";;
    start)   one_start "$@";;
    phase)   one_phase "$@";;
    release) one_release "$@";;
    *) echo "usage: harness one check | gate <issue> | start <issue> | phase <issue> <phase> | release <issue>   [-R owner/repo] [--unit U]" >&2; return 2;;
  esac; }

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && one_main "$@"

#!/usr/bin/env bash
# priority-worker.sh — the priority bug lane (#26, #27). A single resident worker (cap 1) that
# claims one bug-lane issue at a time, drives it through its current phase, and releases it,
# polling at the fast HARNESS_PRIORITY_POLL cadence. Same pause/stop semantics as pool-worker.sh:
# pause drains (rc 3), stop kills the pid. drive_bug runs the two-phase triage→fix flow (#27):
# an untriaged `bug` triages (refine + flip label), a `bug-triaged` fixes (TDD → PR → close).
set -uo pipefail
_PW_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${_HARNESS_LIB_SOURCED:-}" ]]   && { source "$_PW_HERE/lib.sh";   _HARNESS_LIB_SOURCED=1; }
[[ -z "${_HARNESS_DRIVE_SOURCED:-}" ]] && { source "$_PW_HERE/drive.sh"; _HARNESS_DRIVE_SOURCED=1; }

# bug_goal_done <n> <phase> — has this phase's session delivered its outcome? triage: the issue
# is closed (invalid/dup/wontfix) OR the label flipped to bug-triaged (now a fix). fix: the issue
# is closed (its PR merged). Reads GitHub via the lib.sh seams (_bug_state/_bug_labels).
bug_goal_done(){ local n="$1" phase="$2"
  [[ "$(_bug_state "$n")" == CLOSED ]] && return 0
  [[ "$phase" == triage && "$(bug_phase "$n")" == fix ]]; }

# drive_bug <ref> — take one claimed bug through its current phase (#27). <ref> is a repo-qualified
# "<repo>#<num>" token (#37): the repo is CARRIED from the claim, not re-scanned, so colliding
# issue numbers across repos route to the right one. Pick the phase (triage|fix), spawn the matching
# session, then HOLD until that session ends (mirrors the pool's drive_unit: the claim stays held for
# the whole session so the cap-1 lane never moves on / double-dispatches). The two phases run as two
# DISTINCT sessions across two claim cycles: triage flips bug → bug-triaged, a later cycle fixes the
# bug-triaged issue. Sourced (overridable) so tests assert the lane lifecycle without touching GitHub.
drive_bug(){ local ref="$1" n phase sess SLUG PROJECT DESC CHECKOUT REPO
  REPO="$(_bug_ref_repo "$ref")"; n="$(_bug_ref_num "$ref")"
  [[ -n "$REPO" ]] || { log "priority: cannot resolve repo for bug $ref"; return 1; }
  SLUG="$(_with_owner "$REPO")"; PROJECT="${SLUG##*/}"; DESC="$PROJECT"; CHECKOUT="$(bug_checkout "$REPO")"
  phase="$(bug_phase "$n")"; sess="$(sess_bug "$SLUG" "$n" "$phase")"
  log "priority: bug #$n → $phase session ($sess)"
  spawn_bug "$n" "$phase" || { log "priority: spawn failed for bug #$n"; return 1; }
  # Hold the claim while the phase session is live; reap once its goal is satisfied. A pause
  # leaves the live session running (drained) — same contract as the pool.
  while session_live "$sess"; do
    is_paused && { log "priority: paused — leaving bug #$n $phase session live"; break; }
    if bug_goal_done "$n" "$phase"; then
      tmux kill-session -t "$sess" 2>/dev/null || true; rm -f "$RUN_DIR/$sess.goal"; break
    fi
    sleep "$PRIORITY_POLL"
  done
  # Reap the fix worktree + local branch once its session has ended (#34) — the pool gets this via
  # reap_team/finalize_unit; the cap-1 lane had no equivalent, so it leaked a worktree + dead branch
  # on every fix and a crashed fix wedged the next attempt. Skip while paused: a drained fix session
  # is still live and owns its worktree. (triage has no worktree.)
  if [[ "$phase" == fix ]] && ! is_paused; then
    remove_worktree "$CHECKOUT" "$(bug_worktree "$SLUG" "$n")" "issue/$n"
    log "priority: reaped bug #$n fix worktree + branch"
  fi; }

# One claim cycle. rc 3 paused (drained, no claim), rc 0 claimed+drove+released a bug,
# rc 1 idle (no claimable bug). The lane holds at most one bug at a time (cap 1): it
# releases before returning, so it is structurally serial — a second bug always waits.
bug_tick(){ local wid="$1" ref
  if is_paused; then return 3; fi
  ref="$(claim_next_bug "$wid")"
  if [[ -z "$ref" ]]; then return 1; fi
  log "priority $wid claimed bug $ref"; drive_bug "$ref"; release_bug_claim "$ref"; log "priority $wid released bug $ref"; return 0; }

# One poll cycle. Resident: idle (rc 1) logs a banner ONCE per idle streak (deduped via
# _IDLE_LOGGED) and keeps polling; real work (rc 0) clears the dedup so a later idle streak
# re-announces. The lane only ever terminates on stop (kill); pause keeps it drained (rc 3).
bug_step(){ local wid="$1"; bug_tick "$wid"; local rc=$?
  case "$rc" in
    0) _IDLE_LOGGED=0 ;;
    1) [[ "${_IDLE_LOGGED:-0}" == 1 ]] || { log "no bugs — idle, watching"; _IDLE_LOGGED=1; }
       sleep "$PRIORITY_POLL" ;;
    *) sleep "$PRIORITY_POLL" ;;
  esac
  return "$rc"; }
main(){ local wid="${1:-P1}"; UNIT="priority-$wid"; _IDLE_LOGGED=0
  log "priority lane $wid up — cap 1 poll ${PRIORITY_POLL}s"
  while true; do bug_step "$wid"; done; }
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"

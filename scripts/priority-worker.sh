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

# reap_lane — the lane's per-poll self-heal (#42), the cap-1 analog of the pool's reap_team
# (drive.sh). A bug-lane session that DIES after spawn_bug stamps agent-working (drive.sh:206) but
# before the issue closes leaves the bug stuck under agent-working: bug_lane_candidates excludes
# agent-working, so the lane idles "watching" an OPEN bug forever — needing a manual `harness start
# --recover`. So at the TOP of every poll, for each OPEN bug-lane issue still under agent-working
# whose sess_bug session is NOT live, strip agent-working and reap any worktree+branch a crashed fix
# orphaned (triage has none — remove_worktree is idempotent on a missing worktree), so the next poll
# re-claims it cleanly. bug_session_live (shared with #43's recover skip) protects a genuinely live
# session, so this never double-dispatches in-flight work. Runs every poll regardless of pause: a
# paused-but-live session is still live (drained, not killed) → skipped; a checkpointed one carries
# agent-paused, not agent-working → not a candidate. Repo/slug/checkout/worktree are derived exactly
# as drive_bug derives them, so create (spawn_bug) and reap can never disagree on the path.
reap_lane(){ local repo slug n
  for repo in $(_bug_repos); do
    [[ -n "$repo" ]] || continue
    slug="$(_with_owner "$repo")"
    while read -r n; do
      [[ -n "$n" ]] || continue
      bug_session_live "$slug" "$n" && continue   # live session — never sweep (no double-dispatch, #43)
      log "priority: reaping stale agent-working on bug $repo#$n (no live session) — re-claimable next poll"
      gh issue edit "$n" -R "$slug" --remove-label "$HARNESS_LABEL_WORKING" 2>/dev/null || true
      remove_worktree "$(bug_checkout "$repo")" "$(bug_worktree "$slug" "$n")" "issue/$n"
    done < <(_repo_working_bugs "$repo")
  done; }

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
bug_step(){ local wid="$1"
  # PRD-B slice 3 (#72): gate the WHOLE poll on a fresh host snapshot when HARNESS_USE_POLLER is set.
  # A stale/missing snapshot HOLDS — reap_lane is skipped too (its self-heal does gh writes), no
  # claim, no gh — the gate relaunches the poller and we log a deduped banner. Flag OFF: snapshot_gate
  # returns 0 and the poll is byte-for-byte today's (reap_lane + bug_tick).
  if ! snapshot_gate; then
    [[ "${_IDLE_LOGGED:-0}" == 1 ]] || { log "snapshot stale — holding, restarting poller"; _IDLE_LOGGED=1; }
    sleep "$PRIORITY_POLL"; return 4
  fi
  reap_lane; bug_tick "$wid"; local rc=$?
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

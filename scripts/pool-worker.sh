#!/usr/bin/env bash
# pool-worker.sh — a pool worker (#468, PRD #464 §2). A worker claims ONE lane — one issue or one PRD
# action — runs it, reaps it, releases it and claims the next. POOL is the most lanes that run at once, so
# POOL=3 with 3 ready issues runs 3 lanes, not 1 worker driving the unit while 2 sit idle.
#
# The worker is STEP-based: worker_step runs once per tick (every POLL, or at once after a claim). It never
# blocks inside a lane, so the fleet-wide chores always run:
#   1 preamble   roots_check, gc_orphan_goals, gh_rate_wait, snapshot_gate, usage_watch
#   2 chores     worker_chores — one winner per tick (chores.lock): the reapers and watchdog for OWNERLESS
#                lanes, adoption of ownerless live lanes, every slotless dispatch action, completion
#   3 own lanes  worker_tend — one tend step per lane this worker holds a claim on; an ended lane is reaped
#                and its claim released
#   4 claim      worker_tick — when it owns no lane, is not paused or held and live lanes + claims < POOL,
#                claim_lane takes the first slot-taking item under pool.lock; the lane is spawned AFTER the
#                lock is released (the claim covers the window)
# Claims, adoption and the lane keys are described beside lane_claim_key in lib.sh.
#
_PW_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -uo pipefail
[[ -z "${_HARNESS_LIB_SOURCED:-}" ]]   && { source "$_PW_HERE/lib.sh";   _HARNESS_LIB_SOURCED=1; }
[[ -z "${_HARNESS_DRIVE_SOURCED:-}" ]] && { source "$_PW_HERE/drive.sh"; _HARNESS_DRIVE_SOURCED=1; }

# ── the step-based loop ──────────────────────────────────────────────────────────────────────────────────
# fleet_ctx — the dynamic-scope variables drive.sh's helpers read, for the fleet's one unit. A caller
# declares them `local` first: the worker's own UNIT (worker-<wid>) is what its log lines carry.
fleet_ctx(){ UNIT="$(fleet_unit)"; REPO="$(unit_repo "$UNIT")"; SLUG="$(unit_slug "$UNIT")"; PROJECT="$UNIT"
  DESC="$(unit_desc "$UNIT")"; CHECKOUT="$(unit_checkout "$UNIT")"; }

# lane_release <claim-key> <wid> — drop a claim once its lane is reaped.
lane_release(){ rm -f "$CLAIMS_DIR/$1.claim"; harness_event lane_release lane="$1" worker="$2" repo="$SLUG"; }

# claim_lane <wid> — under pool.lock, take the first slot-taking dispatch item and write its claim; print
# `ACTION<TAB>PAYLOAD<TAB>PROMISE` (nothing when there is none). Claims only while live lanes + live
# claims < POOL. busy_prds / busy_issues add the held claims to the live sessions, and allow_orch is 1 only
# with no lane live, all read inside the lock — so two workers never take the same item, however close.
claim_lane(){ local wid="$1" lockfd live allow busy owned actions rc errf action payload promise key tok sess wid_claim
  local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx
  lock_acquire "$POOL_LOCK" lockfd
  live="$(pool_lane_count)"
  if (( live < POOL )); then
    allow=0; (( live == 0 )) && allow=1
    busy="$(_csv_union "$(busy_prds_for "$UNIT")" "$(claimed_prds)")"
    owned="$(_csv_union "$(busy_issues_for "$UNIT")" "$(claimed_issues)")"
    errf="$RUN_DIR/$UNIT.dispatch.err"
    actions="$(dispatch_actions "$REPO" 1 "$allow" "$busy" "$owned" 2>"$errf")"; rc=$?
    [[ -s "$errf" ]] && cat "$errf" >&2
    (( rc == 3 )) && harness_event hold reason="$(hold_reason "$(cat "$errf" 2>/dev/null)")" secs="$POLL"
    while IFS=$'\t' read -r action payload promise; do
      case "$action" in IMPL|BUG|PLAN|PRD|DECOMPOSE|REVIEW) ;; *) action=""; continue;; esac
      key="$(lane_claim_key "$action" "$payload")"; tok="$action:$payload"
      case "$action" in
        IMPL)              sess="$(sess_impl "$UNIT" "$payload")";;
        PLAN|PRD)          sess="$(sess_orch "$UNIT" 0)";;
        BUG)               tok="$SLUG#$payload"; sess="-"
                           is_bug_claimed "$tok" && { action=""; continue; };;   # the priority lane holds it
        *)                 sess="$(sess_orch "$UNIT" "$payload")";;
      esac
      [[ "$action" == BUG ]] && wid_claim="pool-$wid" || wid_claim="$wid"
      lane_claim_write "$key" "$wid_claim" "$tok" "$sess"
      break
    done <<< "$actions"
  fi
  lock_release "$lockfd"
  [[ -n "${action:-}" ]] && printf '%s\t%s\t%s\n' "$action" "$payload" "$promise"
  return 0; }

# start_lane <wid> <action> <payload> <promise> — spawn the lane claim_lane just claimed, outside pool.lock.
# A spawn that fails drops the claim; whatever it left (a worktree) has no session, so the chores reap it.
start_lane(){ local wid="$1" action="$2" payload="$3" promise="$4" key sess rc=0 pid phase kind=orch tok f
  local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx
  key="$(lane_claim_key "$action" "$payload")"; f="$CLAIMS_DIR/$key.claim"; tok="$(awk '{print $3; exit}' "$f" 2>/dev/null)"
  case "$action" in
    IMPL) kind=impl; sess="$(sess_impl "$UNIT" "$payload")"
          log "worker $wid claimed issue #$payload"
          spawn_impl "$payload" "$promise" || rc=$?;;
    BUG)  kind=bug; phase="$(bug_phase "$payload")"; sess="$(sess_bug "$SLUG" "$payload" "$phase")"
          log "worker $wid claimed bug #$payload → $phase session ($sess)"
          spawn_bug "$payload" "$phase" || rc=$?;;
    PLAN|PRD) sess="$(sess_orch "$UNIT" 0)"
          log "worker $wid claimed $action"
          spawn_orch "$action" "$payload" "$promise" || rc=$?;;
    *)    sess="$(sess_orch "$UNIT" "$payload")"
          log "worker $wid claimed $action #$payload"
          spawn_orch "$action" "$payload" "$promise" || rc=$?;;
  esac
  harness_event lane_claim kind="$kind" action="$action" payload="$payload" worker="$wid" repo="$SLUG"
  if (( rc != 0 )); then
    log "worker $wid: could not start $action $payload — claim dropped"; lane_release "$key" "$wid"; return 1; fi
  pid="$(sess_pane_pid "$sess")"
  [[ -f "$f" ]] && lane_claim_write "$key" "$(awk '{print $1; exit}' "$f")" "$tok" "$sess" "${pid:--}"
  return 0; }

# worker_tick [wid] — the claim step (4). rc 0 = claimed + spawned a lane, 1 = nothing to claim (or this
# worker has a lane), 2 = the repo is COMPLETE, 3 = paused / usage held / default branch red, 5 = the GitHub
# budget is low.
worker_tick(){ local wid="$1" act pl pr
  local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx
  if is_paused; then return 3; fi   # pause: no new claim — running lanes are still tended (worker_tend)
  if usage_held; then return 3; fi   # #194: an account is near its usage limit — claim nothing until it resets
  if gh_budget_low; then return 5; fi   # #183: the GitHub token is near its budget — claim nothing, poll at half rate
  [[ -z "$(worker_claims "$wid" | head -n1)" ]] || return 1   # one lane per worker (adoption can add more)
  # #50: a red default branch holds NEW dispatch; the next tick re-checks, so the fleet resumes by itself.
  if ! ci_gate_ok "$SLUG"; then harness_event hold reason=other cause=ci_red secs="$POLL"; return 3; fi
  IFS=$'\t' read -r act pl pr < <(claim_lane "$wid")
  if [[ -z "$act" ]]; then all_complete && return 2; return 1; fi
  start_lane "$wid" "$act" "$pl" "$pr"; return 0; }

# tend_lane_done <claim-file> — one tend step for the lane a claim names: the goal check and watchdog of a
# live session (a driven goal loop advances from the watchdog, so it runs through a pause too), and the
# reap once the session is gone. rc 0 = the lane ended and was reaped, 1 = it lives on.
tend_lane_done(){ local f="$1" key tok sess n prd slug
  key="$(basename "$f" .claim)"; tok="$(awk '{print $3; exit}' "$f" 2>/dev/null)"
  case "$key" in
    impl-*) n="${key#impl-}"; sess="$(sess_impl "$UNIT" "$n")"
            if session_live "$sess"; then check_session_goal "$sess"; watchdog_session "$sess"; fi
            reap_impl_lane "$n";;
    orch-*) prd="${key#orch-}"; sess="$(sess_orch "$UNIT" "$prd")"
            if session_live "$sess"; then check_session_goal "$sess"; watchdog_session "$sess"; fi
            if (( prd == 0 )); then ! session_live "$sess"; else reap_orch_lane "$prd"; fi;;
    bug-*)  slug="$(_with_owner "$(_bug_ref_repo "$tok")")"; n="$(_bug_ref_num "$tok")"
            bug_lane_tend "$slug" "$n"
            bug_session_live "$slug" "$n" && return 1
            bug_lane_reap_worktrees "$slug" "$n"; log "pool: reaped bug $tok session — worktrees released";;
    *)      return 1;;
  esac; }

# worker_tend <wid> — step 3: one tend step for every lane this worker holds a claim on. An ended lane is
# reaped and its claim released. rc 0 = at least one lane ended.
worker_tend(){ local wid="$1" f key ended=1
  local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx
  while read -r f; do
    [[ -n "$f" ]] || continue
    if tend_lane_done "$f"; then key="$(basename "$f" .claim)"; lane_release "$key" "$wid"; ended=0; fi
  done < <(worker_claims "$wid")
  return "$ended"; }

# adopt_lanes <wid> — a live session of the unit's (`-i<N>`, `-p<N>`, `-p0`) that no live worker holds a
# claim on is adopted: this worker writes the claim and tends the lane from then on. Derived from sessions,
# not claim files, so it survives `start --recover`'s clear_stale_claims and picks up what a worker roll
# (#467) or a killed worker left running. A dead lane is not adopted: reap_team / reap_orch reap it.
adopt_lanes(){ local wid="$1" s key goal tok lockfd
  while read -r s; do
    [[ -n "$s" ]] || continue
    key="$(session_lane_key "$s")"; [[ -n "$key" ]] || continue
    is_claimed "$key" && continue
    session_live "$s" || continue
    lock_acquire "$POOL_LOCK" lockfd
    if ! is_claimed "$key"; then
      goal="$(cat "$RUN_DIR/$s.goal" 2>/dev/null)"
      case "$key" in
        impl-*) tok="IMPL:${key#impl-}";;
        *)      tok="${goal:-ORCH}"; [[ "$tok" == *:* ]] || tok="$tok:-";;
      esac
      lane_claim_write "$key" "$wid" "$tok" "$s" "$(sess_pane_pid "$s")"
      log "worker $wid adopted lane $key ($s) — no live worker held it"
      harness_event lane_adopt lane="$key" worker="$wid" repo="$SLUG"
    fi
    lock_release "$lockfd"
  done < <(team_sessions "$UNIT"); }

# reap_ownerless_pool_bugs — tend the pool-taken bugs whose worker is gone (or whose claim predates the
# step loop): the owner's half of tend_lane_done, run by the chores winner. The teardown re-checks the
# claim under pool.lock, so a claim the priority lane has since taken over is never touched.
reap_ownerless_pool_bugs(){ local f tok n slug pid nf lockfd
  while IFS=$'\t' read -r f tok; do
    nf="$(awk '{print NF; exit}' "$f" 2>/dev/null)"; pid="$(awk '{print $2; exit}' "$f" 2>/dev/null)"
    (( ${nf:-0} >= 5 )) && [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && continue   # its worker tends it
    slug="$(_with_owner "$(_bug_ref_repo "$tok")")"; n="$(_bug_ref_num "$tok")"
    bug_lane_tend "$slug" "$n"
    bug_session_live "$slug" "$n" && continue
    lock_acquire "$POOL_LOCK" lockfd
    if [[ "$(awk '{print $1; exit}' "$f" 2>/dev/null)" == pool-* ]] && [[ "$(awk '{print $2; exit}' "$f" 2>/dev/null)" == "$pid" ]]; then
      bug_lane_reap_worktrees "$slug" "$n"
      rm -f "$f"; log "pool: reaped bug $tok session — worktrees + claim released"
    fi
    lock_release "$lockfd"
  done < <(pool_bug_claims); }

# sweep_stale_lane_claims — an impl/orch claim whose worker is dead says nothing: adoption reads sessions.
sweep_stale_lane_claims(){ local f k lockfd; shopt -s nullglob
  lock_acquire "$POOL_LOCK" lockfd
  for f in "$CLAIMS_DIR"/impl-*.claim "$CLAIMS_DIR"/orch-*.claim; do
    k="$(basename "$f" .claim)"; is_claimed "$k" || rm -f "$f"
  done
  lock_release "$lockfd"; shopt -u nullglob; }

# chores_slotless — every dispatch action that takes no slot (LABEL_READY, CLOSE_PRD), this tick. On a
# COMPLETE repo: archive PLAN.md once (archive_plan is idempotent) and nothing else — never finalize_unit's
# kill-all, and no lane holding a claim is touched. A new PRD or ready issue makes the repo incomplete again.
chores_slotless(){ local live allow busy owned actions rc errf action payload promise
  if unit_complete "$UNIT"; then archive_plan; return 0; fi
  live="$(pool_lane_count)"; allow=0; (( live == 0 )) && allow=1
  busy="$(_csv_union "$(busy_prds_for "$UNIT")" "$(claimed_prds)")"
  owned="$(_csv_union "$(busy_issues_for "$UNIT")" "$(claimed_issues)")"
  errf="$RUN_DIR/$UNIT.dispatch.err"
  actions="$(dispatch_actions "$REPO" 99 "$allow" "$busy" "$owned" 2>"$errf")"; rc=$?
  [[ -s "$errf" ]] && cat "$errf" >&2
  (( rc == 3 )) && harness_event hold reason="$(hold_reason "$(cat "$errf" 2>/dev/null)")" secs="$POLL"
  (( live == 0 )) && [[ -z "$actions" ]] && dispatch_stalled_banner "$REPO" "$UNIT"
  while IFS=$'\t' read -r action payload promise; do
    case "$action" in
      CLOSE_PRD)   close_prd "$payload";;
      LABEL_READY) label_ready "$payload";;
    esac
  done <<< "$actions"; }

# worker_chores <wid> — step 2. One winner per tick takes chores.lock; a worker that does not win skips it.
# The reapers and the watchdog see OWNERLESS lanes only (an owner tends its own, so none runs twice).
worker_chores(){ local wid="$1" lockfd
  local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx
  lock_try "$RUN_DIR/chores.lock" lockfd || return 0
  reap_done_sessions; reap_team; reap_orch; watchdog_team; reap_finished_inject "$UNIT"
  one_auto_tend; reap_ownerless_pool_bugs
  retry_pending_unlocks; sweep_orphan_locks "$UNIT"   # #179: a lock a failed reap or a dead host left behind
  sweep_stale_lane_claims
  adopt_lanes "$wid"
  chores_slotless
  lock_release "$lockfd"
  # After the lock, both: each can start a job that outlives the tick (a release run, a harness-one lane)
  # and must not inherit chores.lock, or the chores would stop for as long as it lives.
  release_tick     # #283: a throttled patch release for queued bug fixes (Harness repo only)
  usage_held && one_auto_tick   # #392: a usage hold starts one gated harness-one lane per account
  return 0; }

# worker_hold_tick — gh-free work while a GitHub rate limit holds the worker (gh_rate_wait's callback):
# the watchdog over this worker's own lanes, and over the ownerless ones when it holds chores.lock.
worker_hold_tick(){ local f sess lockfd
  local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx
  while read -r f; do
    sess="$(awk '{print $4; exit}' "$f" 2>/dev/null)"; [[ -n "$sess" && "$sess" != - ]] && watchdog_session "$sess"
  done < <(worker_claims "${_WORKER_ID:-}")
  lock_try "$RUN_DIR/chores.lock" lockfd || return 0
  watchdog_team; lock_release "$lockfd"; }

# One tick. rc is the claim step's (worker_tick): 0 a lane was claimed (the next tick comes at once), 1 idle,
# 2 the repo is COMPLETE — logged ONCE per idle streak (_IDLE_LOGGED), the worker stays resident (#24),
# 3 paused / held, 4 the host snapshot is stale, 5 the GitHub budget is low. Workers only end on stop (kill)
# or once their roots are deleted (#419).
worker_step(){ local wid="$1" rc
  _WORKER_ID="$wid"
  roots_check       # #419 FIRST: its STATE_DIR / HARNESS_HOME deleted → exit 0, before any mkdir -p hides it
  gc_orphan_goals   # sweep .goal files whose session self-exited / has no reaper (Ralph + inject leaks)
  gh_rate_wait worker_hold_tick   # #183: rate-limited — sleep until the reset, tending lanes (gh-free) meanwhile
  # PRD-B slice 3 (#72): with the host poller on (the default since #182), gate the tick on a fresh host
  # snapshot. Stale/missing/unknown-schema HOLDS it (no chores, no claim, no gh fallback); the gate relaunches
  # the poller and a deduped banner says so. Flag OFF: snapshot_gate returns 0.
  if ! snapshot_gate; then
    [[ "${_IDLE_LOGGED:-0}" == 1 ]] || { log "snapshot stale — holding, restarting poller"; _IDLE_LOGGED=1; }
    sleep "$POLL"; return 4
  fi
  usage_watch   # #194: read usage before claiming, so a crossing checkpoints + holds before this claim
  worker_chores "$wid"
  worker_tend "$wid"
  worker_tick "$wid"; rc=$?
  case "$rc" in
    0) _IDLE_LOGGED=0 ;;
    2) [[ "${_IDLE_LOGGED:-0}" == 1 ]] || { log "all COMPLETE — idle, watching"; _IDLE_LOGGED=1; }
       sleep "$POLL" ;;
    5) sleep "$(( POLL * 2 ))" ;;
    *) sleep "$POLL" ;;
  esac
  return "$rc"; }

main(){ local wid="${1:?usage: pool-worker.sh <worker-id>}"; UNIT="worker-$wid"; _IDLE_LOGGED=0
  log "pool worker $wid up — one lane at a time, at most $POOL at once, poll ${POLL}s"
  roots_watch   # #419: the resident loop ends by itself once the roots it serves are deleted
  seed_if_needed "$(fleet_unit)"   # once, at worker start
  while true; do worker_step "$wid"; done; }
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"

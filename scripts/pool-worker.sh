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
# A worker that owns a live lane ticks every HARNESS_TEND_TICK (15s) instead (#594): the SHORT tick runs only
# step 3, with the goal check gated on an idle pane, and a reap hands straight to a full step so the next
# claim happens at once. Steps 1, 2 and 4 stay on POLL.
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
    # #596: an issue / PRD whose last launch failed is held back (like a busy one) until its backoff runs out
    busy="$(_csv_union "$(busy_prds_for "$UNIT")" "$(claimed_prds)" "$(backoff_keys orch)")"
    owned="$(_csv_union "$(busy_issues_for "$UNIT")" "$(claimed_issues)" "$(backoff_keys impl)" "$(closed_live_keys)")"   # #730
    errf="$RUN_DIR/$UNIT.dispatch.err"
    actions="$(dispatch_actions "$REPO" 1 "$allow" "$busy" "$owned" 2>"$errf")"; rc=$?
    [[ -s "$errf" ]] && cat "$errf" >&2
    (( rc == 3 )) && harness_event hold reason="$(hold_reason "$(cat "$errf" 2>/dev/null)")" secs="$POLL"
    while IFS=$'\t' read -r action payload promise; do
      case "$action" in IMPL|BUG|PLAN|PRD|DECOMPOSE|REVIEW) ;; *) action=""; continue;; esac
      key="$(lane_claim_key "$action" "$payload")"; tok="$action:$payload"
      [[ "$action" != BUG ]] && launch_backoff_active "$key" && { action=""; continue; }   # #596 (orch-0 has no number to exclude)
      case "$action" in
        IMPL)              sess="$(sess_impl "$UNIT" "$payload")";;
        PLAN|PRD)          sess="$(sess_orch "$UNIT" 0)";;
        BUG)               tok="$SLUG#$payload"; sess="-"
                           is_bug_claimed "$tok" && { action=""; continue; }   # the priority lane holds it
                           bug_session_live "$SLUG" "$payload" && { action=""; continue; };;   # #540: in flight, not yet adopted
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
start_lane(){ local wid="$1" action="$2" payload="$3" promise="$4" key sess rc=0 pid phase kind=orch tok f lockfd
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
  if (( rc == 3 )) && [[ "$action" == IMPL ]]; then   # #745: a closed issue was skipped (#730) — not a failed spawn
    log "worker $wid: #$payload is closed — claim dropped, claiming again"; lane_release "$key" "$wid"; return 7; fi
  harness_event lane_claim kind="$kind" action="$action" payload="$payload" worker="$wid" repo="$SLUG"
  if (( rc != 0 )); then
    log "worker $wid: could not start $action $payload — claim dropped"; lane_release "$key" "$wid"; return 1; fi
  pid="$(sess_pane_pid "$sess")"
  # #684: this rewrite replaces the claim file another worker's claim_lane reads (under pool.lock) to learn the issue is taken.
  # A Windows rename over a file is not atomic — a reader in that gap sees no claim and takes the same issue — so the
  # rewrite holds pool.lock too, which is what every reader of a claim for claiming purposes already holds.
  lock_acquire "$POOL_LOCK" lockfd
  [[ -f "$f" ]] && lane_claim_write "$key" "$(awk '{print $1; exit}' "$f")" "$tok" "$sess" "${pid:--}"
  lock_release "$lockfd"
  return 0; }

# worker_tick [wid] — the claim step (4). rc 0 = claimed + spawned a lane, 1 = nothing to claim (or this
# worker has a lane), 2 = the repo is COMPLETE, 3 = paused / usage held / default branch red, 5 = the GitHub
# budget is low, 6 = no usable checkout, or the lane failed to spawn (#539: the claim was dropped — worker_step
# sleeps POLL, so a persistent failure never re-claims back to back). rc 7 = the claimed issue was already closed
# (#730/#745): skipped and marked, no spawn failed — worker_step claims again at once, not after POLL.
worker_tick(){ local wid="$1" act pl pr rc
  local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx
  if is_paused; then return 3; fi   # pause: no new claim — running lanes are still tended (worker_tend)
  if usage_held; then return 3; fi   # #194: an account is near its usage limit — claim nothing until it resets
  if gh_budget_low; then return 5; fi   # #183: the GitHub token is near its budget — claim nothing, poll at half rate
  [[ -z "$(worker_claims "$wid" | head -n1)" ]] || return 1   # one lane per worker (adoption can add more)
  ensure_checkout || return 6   # #539: no clone → no worktree can be added; clone it or hold (deduped log), never spin
  # #50: a red default branch holds NEW dispatch; the next tick re-checks, so the fleet resumes by itself.
  if ! ci_gate_ok "$SLUG"; then harness_event hold reason=other cause=ci_red secs="$POLL"; return 3; fi
  IFS=$'\t' read -r act pl pr < <(claim_lane "$wid")
  if [[ -z "$act" ]]; then all_complete && return 2; return 1; fi
  start_lane "$wid" "$act" "$pl" "$pr"; rc=$?
  (( rc == 7 )) && return 7   # #745: a closed issue skipped — the marker keeps it out of the next claim
  (( rc == 0 )) || return 6   # #539: a failed spawn is not "a lane was claimed"
  return 0; }

# tend_lane_done <claim-file> — one tend step for the lane a claim names: the goal check and watchdog of a
# live session (a driven goal loop advances from the watchdog, so it runs through a pause too), and the
# reap once the session is gone. rc 0 = the lane ended and was reaped, 1 = it lives on.
tend_lane_done(){ local f="$1" key tok sess n prd slug
  key="$(basename "$f" .claim)"; tok="$(awk '{print $3; exit}' "$f" 2>/dev/null)"
  case "$key" in
    impl-*) n="${key#impl-}"; sess="$(sess_impl "$UNIT" "$n")"
            if session_live "$sess"; then tend_goal "$sess"; tend_watchdog "$sess"; fi
            reap_impl_lane "$n";;
    orch-*) prd="${key#orch-}"; sess="$(sess_orch "$UNIT" "$prd")"
            if session_live "$sess"; then tend_goal "$sess"; tend_watchdog "$sess"; fi
            if (( prd == 0 )); then session_live "$sess" && return 1; launch_gone_check "$sess" orch; return 0   # #596
            else reap_orch_lane "$prd"; fi;;
    bug-*)  (( ${TEND_FAST:-0} )) && return 1   # #594: a bug lane has no goal; the full step tends it
            slug="$(_with_owner "$(_bug_ref_repo "$tok")")"; n="$(_bug_ref_num "$tok")"
            bug_lane_tend "$slug" "$n"
            bug_session_live "$slug" "$n" && return 1
            bug_lane_reap_worktrees "$slug" "$n"; log "pool: reaped bug $tok session — worktrees released";;
    *)      return 1;;
  esac; }

# --- #594: the short tick ---------------------------------------------------------------------------------
# lane_pane_active <sess> — the lane is working: a turn is running (cli_pane_busy), or a sub-agent it started
# still runs. A review lane sits at its prompt while its sub-agent works.
# The footer's `← 1 agent` is NOT that signal (#668): Claude Code draws it on every pane, a fresh one with nothing
# typed included (idle.txt), and with one sub-agent running or none it reads the same. A running sub-agent shows
# as `✻ Waiting for N background agent(s) to finish` right above the input box, and as `◯ <type> <task>` rows
# under the footer (idle-subagent-running.txt). Only the live bottom of the pane counts: a finished agent's
# `Waiting for…` line stays in the scrollback (idle-subagent-done.txt).
lane_subagent_running(){ awk '
    /^(─)+$/ { rule[++r]=NR }                                  # the input box top and bottom rules
    { line[NR]=$0 }
    /^ +⏵⏵ / { foot=NR }                                     # the footer (bypass-permissions line)
    END { if (foot) for (i=foot+1;i<=NR;i++) if (line[i] ~ /^ +◯ /) exit 0     # a sub-agent row under the footer
          if (r>=2) { for (i=rule[r-1]-1;i>0;i--) if (line[i] ~ /[^ ]/) break
                      if (i>0 && line[i] ~ /Waiting for [0-9]+ background agents? to finish/) exit 0 }
          exit 1 }' <<<"$1"; }
lane_pane_active(){ local pane; pane="$(sess_capture "$1" 2>/dev/null)" || return 1
  cli_pane_busy "$pane" || lane_subagent_running "$pane"; }
# lane_has_gh <sess> — a `gh` process runs under the lane's pane (it is mid-filing: issue create, edit…).
lane_has_gh(){ local pid; pid="$(sess_pane_pid "$1" 2>/dev/null)"; [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  proc_tree_has_comm "$pid" gh; }   # scripts/portable.sh: the process-table walk, Windows-safe (#653)
# lane_goal_gate <sess> — may the short tick check this lane's goal? Only while its pane is idle, so gh is not
# hit every 15s while the agent works. A DECOMPOSE lane counts as done once the PRD has ANY child
# (issuelib `check`), so an idle pane between two `gh issue create` calls must not end it: it waits for its
# completion promise (cli_done), or HARNESS_TEND_IDLE_TICKS consecutive idle ticks with no gh running.
# #721: while the goal stays pending the checks back off (below); idleticks holds `<n> <last> <gap>`.
lane_goal_gate(){ local s="$1" idlef="$RUN_DIR/$1.idleticks" goal n=0 last=0 gap=0 maxgap ok=0
  if lane_pane_active "$s"; then rm -f "$idlef"; return 1; fi
  [[ -f "$idlef" ]] && { read -r n last gap < "$idlef" || true; }   # idle ticks so far, the tick of the last check, the gap after it
  [[ "$n" =~ ^[0-9]+$ ]] || n=0; [[ "$last" =~ ^[0-9]+$ ]] || last=0; [[ "$gap" =~ ^[0-9]+$ ]] || gap=0
  n=$(( n + 1 ))
  goal="$(cat "$RUN_DIR/$s.goal" 2>/dev/null)"
  if [[ "${goal%%:*}" == DECOMPOSE ]]; then
    if cli_done "$(cat "$RUN_DIR/$s.wd" 2>/dev/null)"; then ok=1
    elif (( n >= HARNESS_TEND_IDLE_TICKS )) && ! lane_has_gh "$s"; then ok=1; fi
  else ok=1; fi
  # #721: the first check after the pane goes idle is on the first eligible tick (goal_satisfied within 30s, PRD
  # #587). A check that finds the goal still pending backs the next one off — 1 tick, 2, 4… doubling up to POLL —
  # so a lane parked at idle (self-park grace, auto-merge waiting, a usage menu) is not a gh call every 15s. A busy
  # pane drops idleticks above, which resets the backoff.
  if (( ok )) && (( last == 0 || n - last >= gap )); then
    maxgap=1; (( HARNESS_TEND_TICK > 0 )) && maxgap=$(( (POLL + HARNESS_TEND_TICK - 1) / HARNESS_TEND_TICK )); (( maxgap >= 1 )) || maxgap=1
    gap=$(( gap == 0 ? 1 : gap * 2 )); (( gap <= maxgap )) || gap="$maxgap"
    echo "$n $n $gap" > "$idlef"; return 0
  fi
  echo "$n $last $gap" > "$idlef"; return 1; }
# tend_goal / tend_watchdog <sess> — the goal check and watchdog of tend_lane_done. On the short tick
# (TEND_FAST=1) the goal check is gated and the watchdog is skipped: its stall counter counts POLLs.
tend_goal(){ if (( ${TEND_FAST:-0} )); then lane_goal_gate "$1" && check_session_goal "$1" live; else check_session_goal "$1"; fi; }
tend_watchdog(){ (( ${TEND_FAST:-0} )) || watchdog_session "$1"; }

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
# adopt_impl_flaw <issue> — #643: why a live impl session's lane is not worth adopting; empty when it is sound: its
# worktree is a git worktree whose top level is that dir, on issue/<N>, with the task file in it. A claimless launcher
# whose worktree was reaped under it leaves a session in an empty (or missing) dir that would hold a slot forever.
adopt_impl_flaw(){ local n="$1" wd="$WORKTREES_DIR/$UNIT-i$1" top br
  [[ -d "$wd" ]] || { echo "no worktree/task file"; return 0; }
  top="$(git -C "$wd" rev-parse --show-toplevel 2>/dev/null)"
  [[ -n "$top" && "$top" -ef "$wd" ]] || { echo "no worktree/task file"; return 0; }
  [[ -f "$wd/.harness-task.md" ]] || { echo "no worktree/task file"; return 0; }
  br="$(git -C "$wd" symbolic-ref --short -q HEAD 2>/dev/null)"
  [[ "$br" == "issue/$n" ]] || echo "worktree is on '${br:-detached HEAD}', not issue/$n"; return 0; }
adopt_lanes(){ local wid="$1" s key goal tok lockfd flaw
  while read -r s; do
    [[ -n "$s" ]] || continue
    key="$(session_lane_key "$s")"; [[ -n "$key" ]] || continue
    is_claimed "$key" && continue
    session_live "$s" || continue
    if [[ "$key" == impl-* ]] && flaw="$(adopt_impl_flaw "${key#impl-}")" && [[ -n "$flaw" ]]; then
      log "adopt: $s has $flaw — killed for re-dispatch (#643)"
      harness_event lane_adopt_rejected lane="$key" session="$s" reason="$flaw" repo="$SLUG"
      cli_kill "$s" "$(cat "$RUN_DIR/$s.wd" 2>/dev/null)" || true
      continue
    fi
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

# adopt_bug_sessions <wid> — #540: the bug twin of adopt_lanes. A live triage/fix session of the fleet repo
# with NO claim file (its pool worker was killed and `start --recover`'s clear_stale_claims dropped the claim) is
# adopted: this worker writes a `pool-<wid>` bug claim, so worker_tend watchdogs it and reaps its worktrees and
# claim once it ends, and it counts toward POOL. A claim file of any kind is left alone: a live priority-lane
# claim is never taken over, and a pool claim whose worker died is reap_ownerless_pool_bugs's.
adopt_bug_sessions(){ local wid="$1" n key sess ph lockfd
  while read -r n; do
    [[ -n "$n" ]] || continue
    key="$(_bug_claim_key "$SLUG#$n")"
    [[ -f "$CLAIMS_DIR/$key.claim" ]] && continue
    lock_acquire "$POOL_LOCK" lockfd
    if [[ ! -f "$CLAIMS_DIR/$key.claim" ]]; then
      sess=""; for ph in fix triage; do session_live "$(sess_bug "$SLUG" "$n" "$ph")" && { sess="$(sess_bug "$SLUG" "$n" "$ph")"; break; }; done
      if [[ -n "$sess" ]]; then
        lane_claim_write "$key" "pool-$wid" "$SLUG#$n" "$sess" "$(sess_pane_pid "$sess")"
        log "worker $wid adopted bug lane $key ($sess) — no claim held it"
        harness_event lane_adopt lane="$key" worker="$wid" repo="$SLUG"
      fi
    fi
    lock_release "$lockfd"
  done < <(fleet_bug_numbers); }

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

# sweep_stale_lane_claims — a claim whose worker is dead says nothing: adoption reads sessions. That covers an
# impl-/orch- lane claim and a leftover <unit>.claim from the retired unit-claim loop (a rolled old worker
# wrote it; nothing reads it now). bug-*.claim is NOT swept here: reap_ownerless_pool_bugs tears its worktrees down first.
sweep_stale_lane_claims(){ local f k lockfd pid; shopt -s nullglob
  lock_acquire "$POOL_LOCK" lockfd
  for f in "$CLAIMS_DIR"/*.claim; do
    k="$(basename "$f" .claim)"; [[ "$k" == bug-* ]] && continue
    if ! is_claimed "$k"; then rm -f "$f"; continue; fi
    # #643: a LIVE legacy unit claim is a worker of the retired unit-claim loop that no pid file names: fleet_roll stops it
    # on the next roll, but until then an operator should see the mixed-engine fleet. Once per pid.
    case "$k" in impl-*|orch-*) continue;; esac
    pid="$(awk '{print $2; exit}' "$f" 2>/dev/null)"; [[ -f "$RUN_DIR/legacy-warned.$pid" ]] && continue
    : > "$RUN_DIR/legacy-warned.$pid"
    log "WARN legacy worker pid $pid holds unit claim $k.claim — a worker of the retired unit-claim loop is alive: a mixed-engine fleet. \`harness update\` (fleet_roll) stops it (#643)"
  done
  lock_release "$lockfd"; shopt -u nullglob; }

# chores_slotless — every slotless action that takes no slot (LABEL_READY, CLOSE_PRD, FILE_CHILD), this tick. On a
# COMPLETE repo: archive PLAN.md once (archive_plan is idempotent) and nothing else — never a kill-all sweep,
# and no lane holding a claim is touched. A new PRD or ready issue makes the repo incomplete again.
chores_slotless(){ local live allow busy owned actions rc errf action payload promise
  if unit_complete "$UNIT"; then archive_plan; return 0; fi
  live="$(pool_lane_count)"; allow=0; (( live == 0 )) && allow=1
  busy="$(_csv_union "$(busy_prds_for "$UNIT")" "$(claimed_prds)")"
  owned="$(_csv_union "$(busy_issues_for "$UNIT")" "$(claimed_issues)")"
  errf="$RUN_DIR/$UNIT.dispatch.err"
  # #527: slotless_actions, not dispatch_actions — dispatch returns early on a DECOMPOSE and never reaches these.
  actions="$(slotless_actions "$REPO" "$busy" 2>"$errf")"; rc=$?
  [[ -s "$errf" ]] && cat "$errf" >&2
  (( rc == 3 )) && harness_event hold reason="$(hold_reason "$(cat "$errf" 2>/dev/null)")" secs="$POLL"
  # the banner says "nothing dispatchable": only so when the claim path has nothing either (the chores' own set is slotless only)
  (( live == 0 )) && (( rc == 0 )) && [[ -z "$actions" ]] \
    && [[ -z "$(dispatch_actions "$REPO" 99 "$allow" "$busy" "$owned" 2>/dev/null)" ]] && dispatch_stalled_banner "$REPO" "$UNIT"
  while IFS=$'\t' read -r action payload promise; do
    case "$action" in
      CLOSE_PRD)   close_prd "$payload";;
      LABEL_READY) label_ready "$payload";;
      FILE_CHILD)  file_child "$payload";;   # #614
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
  adopt_lanes "$wid"; adopt_bug_sessions "$wid"
  chores_slotless
  lock_release "$lockfd"
  # After the lock, both: each can start a job that outlives the tick (a release run, a harness-one lane)
  # and must not inherit chores.lock, or the chores would stop for as long as it lives.
  release_tick     # #283: a throttled patch release for queued bug fixes (Harness repo only)
  usage_held && one_auto_tick   # #392: a usage hold starts one gated harness-one lane per account
  prebuild_tick    # #644: while a lane runs, the next claimable issue's worktree is built ahead; one nobody can claim any more is dropped
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

# worker_owns_lane <wid> — this worker holds a claim (a lane it tends).
worker_owns_lane(){ [[ -n "$(worker_claims "$1" | head -n1)" ]]; }
# worker_short_due <wid> — #594: tick short while this worker owns a lane and the last FULL step is under POLL
# old. _LAST_FULL starts unset and a reap clears it, so the first step and the step after a reap are full.
worker_short_due(){ local now; (( HARNESS_TEND_TICK > 0 && HARNESS_TEND_TICK < POLL )) || return 1
  [[ "${_LAST_FULL:-0}" =~ ^[0-9]+$ ]] && (( ${_LAST_FULL:-0} > 0 )) || return 1
  now="$(date +%s)"; (( now - _LAST_FULL < POLL )) || return 1
  worker_owns_lane "$1"; }
# worker_short_step <wid> — the short tick: only the lane's tend step. A reap ends the short run: the next step is
# full and at once (no sleep), so the next claim — or a slotless CLOSE_PRD — happens immediately. rc 0 = reaped.
worker_short_step(){ local wid="$1" UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx
  roots_check
  if TEND_FAST=1 worker_tend "$wid"; then _LAST_FULL=0; return 0; fi
  sleep "$HARNESS_TEND_TICK"; return 1; }

# One tick. rc is the claim step's (worker_tick): 0 a lane was claimed (the next tick comes at once), 1 idle,
# 2 the repo is COMPLETE — logged ONCE per idle streak (_IDLE_LOGGED), the worker stays resident (#24),
# 3 paused / held, 4 the host snapshot is stale, 5 the GitHub budget is low, 6 no checkout / a lane failed to
# spawn (#539 — sleeps POLL like idle, so the same item is not re-claimed at once), 7 a closed issue was skipped
# (#745 — no sleep: the next step claims again at once). Workers only end on stop (kill)
# or once their roots are deleted (#419).
# tend_knobs — #782: HARNESS_TEND_TICK / HARNESS_TEND_IDLE_TICKS feed bash arithmetic, so a value that is not a
# non-negative integer (abc, 15s, -5, empty) is replaced in place by its default (15 / 3) with a warning naming the
# knob and value. In place -> the warning comes once per process; a valid value (0 included) is left as it is.
tend_knobs(){ local k def v n
  for k in "HARNESS_TEND_TICK 15" "HARNESS_TEND_IDLE_TICKS 3"; do set -- $k; k="$1"; def="$2"; v="${!k-}"
    # #800: IDLE_TICKS above 86400 (or over 6 significant digits) wrapped in $((10#v)) and turned the idle guard off; TEND_TICK keeps its #799 overflow meaning
    if [[ "$v" =~ ^[0-9]+$ ]]; then n="${v#"${v%%[!0]*}"}"
      if [[ "$k" == HARNESS_TEND_TICK ]]; then printf -v "$k" %s "$((10#$v))"; continue; fi
      (( ${#n} <= 6 )) && (( 10#${n:-0} <= 86400 )) && { printf -v "$k" %s "$((10#${n:-0}))"; continue; }; fi
    log "WARN $k='$v' is not a non-negative integer — using the default $def" >&2; printf -v "$k" %s "$def"; done; }
worker_step(){ local wid="$1" rc reaped=1
  _WORKER_ID="$wid"
  tend_knobs
  worker_short_due "$wid" && { worker_short_step "$wid"; return $?; }   # #594: own a live lane → tend it on the short tick
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
  _LAST_FULL="$(date +%s)"
  worker_chores "$wid"
  worker_tend "$wid" && reaped=0   # #883: a reap here ran after this step's chores, so a slotless chore it unblocked needs another step
  worker_tick "$wid"; rc=$?
  case "$rc" in
    0) _IDLE_LOGGED=0 ;;
    2) [[ "${_IDLE_LOGGED:-0}" == 1 ]] || { log "all COMPLETE — idle, watching"; _IDLE_LOGGED=1; }
       sleep "$POLL" ;;
    5) sleep "$(( POLL * 2 ))" ;;
    6) sleep "$POLL" ;;
    7) ;;   # #745: a closed issue skipped, not a failed spawn — claim again at once
    *) if worker_owns_lane "$wid"; then
         (( HARNESS_TEND_TICK > 0 && HARNESS_TEND_TICK < POLL )) && sleep "$HARNESS_TEND_TICK" || sleep "$POLL"   # #594; #799: 0 / overflow = POLL, never sleep 0
       elif (( reaped == 0 )); then :   # #883: no lane left after a reap in the full step → the next step is full and at once (CLOSE_PRD etc.); it sleeps POLL itself if it reaps nothing
       else sleep "$POLL"; fi ;;
  esac
  return "$rc"; }

main(){ local wid="${1:?usage: pool-worker.sh <worker-id>}"; UNIT="worker-$wid"; _IDLE_LOGGED=0
  declare -F tmux_env_sanitize >/dev/null && tmux_env_sanitize   # #596: a stale inherited TMUX breaks every tmux call
  log "pool worker $wid up — one lane at a time, at most $POOL at once, poll ${POLL}s"
  roots_watch   # #419: the resident loop ends by itself once the roots it serves are deleted
  seed_if_needed "$(fleet_unit)"   # once, at worker start
  while true; do worker_step "$wid"; done; }
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"

#!/usr/bin/env bash
# drive.sh — the lane helpers (spawn_*, reap_*, close_prd, label_ready, archive_plan) the step-based
# pool worker (pool-worker.sh) and `harness one` call. Sourced after lib.sh (by them and tests).
# Relies on bash dynamic scoping: the caller (pool-worker.sh fleet_ctx, one.sh) sets
# UNIT/REPO/SLUG/PROJECT/DESC/CHECKOUT as locals, and the helpers below read them.
_HARNESS_DRIVE_SOURCED=1
source "$(dirname "${BASH_SOURCE[0]}")/autorelease.sh"   # #283: the fleet cuts its own Harness releases

# Committed plan-completion artifacts (mirrors issuelib.py PLAN_MARKER_PATH). These live in the
# unit's repo — NOT the gitignored .harness runtime clone — so the marker survives a fresh checkout.
PLAN_MARKER_PATH="docs/harness/plan-complete.json"
PLAN_ARCHIVE_DIR="docs/harness/archive"

default_branch(){ gh repo view "$SLUG" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main; }

# archive_plan — on unit completion, archive a live PLAN.md (never delete) and write a committed,
# spec-keyed completion marker, so the auto-PLAN gate (issuelib.py) neither stays blocked by the
# leftover doc nor silently re-fires against the same spec. Idempotent: a no-op once PLAN.md is
# already archived. git mv/commit/push are best-effort (fall back to plain mv; never abort the caller).
archive_plan(){
  if [[ -f "$CHECKOUT/PLAN.md" ]]; then
    local ts archived spec_hash
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    archived="$PLAN_ARCHIVE_DIR/PLAN-$ts.md"
    mkdir -p "$CHECKOUT/$PLAN_ARCHIVE_DIR" "$CHECKOUT/$(dirname "$PLAN_MARKER_PATH")"
    git -C "$CHECKOUT" mv PLAN.md "$archived" 2>/dev/null || mv "$CHECKOUT/PLAN.md" "$CHECKOUT/$archived"
    spec_hash="$(python3 "$ISSUELIB" spec-hash 2>/dev/null)"
    cat > "$CHECKOUT/$PLAN_MARKER_PATH" <<EOF
{
  "spec": "$HARNESS_SPEC",
  "spec_hash": "$spec_hash",
  "archived": "$archived",
  "completed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "unit": "$UNIT"
}
EOF
    git -C "$CHECKOUT" add -A 2>/dev/null || true
    git -C "$CHECKOUT" commit -q -m "chore(harness): archive PLAN.md + plan-complete marker for $UNIT" 2>/dev/null || true
    git -C "$CHECKOUT" push -q 2>/dev/null || true
    log "finalize: archived PLAN.md → $archived; wrote $PLAN_MARKER_PATH (spec_hash=${spec_hash:0:12})"
  fi
}

# check_session_goal <sess> — one live session's goal check: a satisfied goal ends the session, a
# self-parked issue is nudged (#417), a recovered one clears its state. Split out of reap_done_sessions
# (#468) so the worker that owns a lane runs it on that lane alone.
check_session_goal(){ local s="$1" goal res
  goal="$(cat "$RUN_DIR/$s.goal" 2>/dev/null)"; [[ -z "$goal" ]] && return 0
  res="$(python3 "$ISSUELIB" check "$REPO" "$goal" 2>/dev/null)"
  case "$res" in
    DONE)
      log "session $s goal '$goal' satisfied → advancing"
      stats_sess_event "$s" goal_satisfied
      cli_kill "$s" "$(cat "$RUN_DIR/$s.wd" 2>/dev/null)" || true
      rm -f "$RUN_DIR/$s.goal" "$RUN_DIR/$s.selfpark";;
    PAUSED)  selfpark_tend "$s" "${goal#ISSUE:}";;
    PENDING) rm -f "$RUN_DIR/$s.selfpark";;   # #417: back on agent-working — a later park starts afresh
  esac   # no answer (a transient gh failure): keep whatever state there is
}
# reap_done_sessions — the goal check over every session of the unit no worker owns (#468: an owner runs
# it on its own lane, so a lane is never checked twice).
reap_done_sessions(){
  local s
  while read -r s; do
    [[ -z "$s" ]] && continue
    session_owned "$s" && continue
    check_session_goal "$s"
  done < <(team_sessions "$UNIT")
}

# --- #417: the self-parked impl lane -----------------------------------------------------------------
# An impl lane on an autonomous fleet may swap its issue to agent-paused only when a HARNESS CHECKPOINT
# told it to (checkpoint_mark records every one sent). One that does so on its own — to wait for a
# human decision — would idle at its prompt and hold its slot forever: the reap never fires (paused is
# not done), the stall watchdog sees a healthy idle prompt, and every nudge it answers resets the
# supervisor's escalation. selfpark_tend <sess> <issue>, for a lane whose issue `check` reads PAUSED:
#   first sight      → ONE targeted nudge; $RUN_DIR/<sess>.selfpark keeps its epoch.
#   still PAUSED past HARNESS_SELFPARK_GRACE_MIN → mechanical checkpoint (push + harness-handoff) and
#                       kill; reap_team then unlocks the issue and dispatch resumes it from resume.md.
# Recovery (check reads PENDING) clears the state in reap_done_sessions. Work that cannot be pushed
# is never killed: logged as an ERROR and retried next poll.
SELFPARK_NUDGE='AUTONOMOUS fleet: you may not wait on a human. The `%s` label belongs to the HARNESS CHECKPOINT protocol only, and no checkpoint was sent to you. Pick the option you recommended, document it in an issue comment as an operator decision, remove `%s`, re-add `%s` (gh issue edit %s -R %s --remove-label %s --add-label %s), and continue the task.'
selfpark_tend(){ local sess="$1" issue="$2" f="$RUN_DIR/$1.selfpark" t now wd
  [[ "${HARNESS_AUTONOMOUS:-true}" == true ]] || return 0
  [[ "$issue" =~ ^[0-9]+$ ]] || return 0
  [[ -f "$RUN_DIR/$sess.checkpoint" ]] && return 0   # a checkpoint was requested: it is meant to sit there
  wd="$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)"; now="$(date +%s)"
  t="$(cat "$f" 2>/dev/null)"
  if ! [[ "$t" =~ ^[0-9]+$ ]]; then
    log "self-park: $sess labelled #$issue $HARNESS_LABEL_PAUSED with no checkpoint sent — nudging it to decide and continue (#417)"
    stats_sess_event "$sess" nudge reason=self_park
    # shellcheck disable=SC2059
    cli_send "$sess" "$wd" "$(printf "$SELFPARK_NUDGE" "$HARNESS_LABEL_PAUSED" "$HARNESS_LABEL_PAUSED" "$HARNESS_LABEL_WORKING" \
      "$issue" "$SLUG" "$HARNESS_LABEL_PAUSED" "$HARNESS_LABEL_WORKING")"
    echo "$now" > "$f"; return 0
  fi
  (( now - t >= ${HARNESS_SELFPARK_GRACE_MIN:-30} * 60 )) || return 0
  mechanical_checkpoint "$sess" "$(sess_capture "$sess")" "self-park" \
    "Session \`$sess\` labelled this issue \`$HARNESS_LABEL_PAUSED\` to wait for a decision although no HARNESS CHECKPOINT was sent to it, and was still parked ${HARNESS_SELFPARK_GRACE_MIN:-30} min after a nudge to decide and continue. The fleet is autonomous, so Harness checkpointed it and ended the session; the issue is resumed from this branch. The next lane decides any open question itself (taking the recommended option) and documents it as an operator decision." \
    || { log "self-park: ERROR could not checkpoint $sess — not killing it, retrying next poll (#417)"; return 0; }
  log "self-park: $sess still parked ${HARNESS_SELFPARK_GRACE_MIN:-30}m after its nudge — checkpointed, killing for reap → resume (#417)"
  stats_sess_event "$sess" watchdog_kill reason=self_park
  cli_kill "$sess" "$wd" || true
  rm -f "$f"; }

# reap_impl_lane <issue> — reap one impl lane whose session is gone: its worktree goes, and the issue is
# freed (still open) or its local branch dropped (closed — the PR squash-merged). A live session, or a
# fresh /harness-one lease, keeps the lane. rc 0 = reaped, 1 = the lane lives on.
reap_impl_lane(){ local issue="$1" wd="$WORKTREES_DIR/$UNIT-i$1" sess; sess="$(sess_impl "$UNIT" "$issue")"
  session_live "$sess" && return 1
  rm -f "$RUN_DIR/$sess.checkpoint" "$RUN_DIR/$sess.selfpark"   # #417: they lived as long as the session
  one_lease_live "$UNIT" "$issue" && return 1   # #366: a /harness-one session is working it
  rm -f "$(one_lease_file "$UNIT" "$issue")" "$(one_start_file "$UNIT" "$issue")"
  log "reaping issue #$issue worktree"
  harness_event reap kind=impl issue="$issue" reason=session_gone
  remove_worktree "$CHECKOUT" "$wd"
  local state
  # #179: the worktree is gone, so this reap never comes round again — a gh failure here must not
  # strand the lock. Unreadable state ⇒ queue the unlock (harmless on a closed issue).
  state="$(gh issue view "$issue" -R "$SLUG" --json state,labels 2>/dev/null)" || { unlock_issue "$SLUG" "$issue"; return 0; }
  # fully autonomous: free a still-open issue's stale agent-working for retry, even if a
  # prior session left it agent-blocked (no human will ever clear that label for us). An
  # agent-blocked one is parked as well (#271), so it is retried only once something changes it.
  if echo "$state" | grep -q '"state":"OPEN"'; then
    unlock_issue "$SLUG" "$issue" || true
    grep -qiF "\"name\":\"$HARNESS_LABEL_BLOCKED\"" <<<"$state" && park_issue "$SLUG" "$issue"
  else
    # issue closed ⇒ its PR squash-merged; drop the now-orphaned local feature branch.
    # (the remote branch is auto-deleted on merge by delete_branch_on_merge + --delete-branch.)
    harness_event merged kind=impl issue="$issue"
    # #283: a merged bug fix in the Harness repo is queued for the next throttled patch release.
    grep -qiE "\"name\":\"($HARNESS_LABEL_BUG|$HARNESS_LABEL_BUG_TRIAGED)\"" <<<"$state" && release_on_bug_merge "$issue"
    git -C "$CHECKOUT" branch -D "issue/$issue" 2>/dev/null || true
  fi
  return 0
}
# reap_team — reap_impl_lane over every impl worktree of the unit no worker owns (#468).
reap_team(){
  stats_sweep_ended   # #185: before any worktree goes — its ralph state carries the iteration count
  shopt -s nullglob
  for wd in "$WORKTREES_DIR/$UNIT"-i*; do
    local issue="${wd##*-i}"
    is_claimed "impl-$issue" && continue
    # #528: the owner removes the worktree before it releases its claim. If it finished this lane after the
    # glob listed it, the claim is gone AND so is the worktree: already reaped, once — not for us to redo.
    [[ -d "$wd" ]] || continue
    reap_impl_lane "$issue"
  done
  shopt -u nullglob
}

# busy_prds_for <unit> — comma-separated PRD numbers with a LIVE orch session, for dispatch's
# --busy-prds gate. p0 is the unit-level PLAN/PRD session and carries no PRD, so it is excluded.
busy_prds_for(){
  team_sessions "$1" | sed -n "s/^$HARNESS_SESS_PREFIX-$1-p\([0-9][0-9]*\)$/\1/p" \
    | grep -v '^0$' | paste -sd, - ; }

# reap_orch — sibling of reap_team for the per-PRD DECOMPOSE/REVIEW worktrees. Orch sessions hold
# no issue label and push no branch, so teardown is just: drop the worktree and its throwaway
# branch once the session is gone.
reap_orch_lane(){ local prd="$1" wd; wd="$(orch_worktree "$SLUG" "$prd")"
  session_live "$(sess_orch "$UNIT" "$prd")" && return 1
  log "reaping orch worktree for PRD #$prd"
  harness_event reap kind=orch prd="$prd" reason=session_gone
  remove_worktree "$CHECKOUT" "$wd" "agent/orch-$prd"
  return 0
}
reap_orch(){
  shopt -s nullglob
  local wd prd san; san="$(printf '%s' "$SLUG" | tr '/' '_')"
  for wd in "$WORKTREES_DIR/orch-$san"-p*; do
    prd="${wd##*-p}"
    is_claimed "orch-$prd" && continue   # #468: its owner reaps it
    [[ -d "$wd" ]] || continue           # #528: ...and already did, between the glob and the claim check
    reap_orch_lane "$prd"
  done
  shopt -u nullglob
}

# close_prd <prd> — the engine's own PRD close (the CLOSE_PRD dispatch action). REVIEW only SIGNS
# OFF (applies the reviewed label); the mechanical close lives here so it never depends on the
# review agent's own `gh issue close` succeeding — a shared-token rate limit could drop that call
# and strand a reviewed PRD open forever ("PRD won't close"). This is a single idempotent gh call,
# re-emitted by dispatch every poll until the PRD is closed; no Ralph session, no worktree, no goal.
close_prd(){
  local prd="$1"
  log "engine closing reviewed PRD #$prd"
  if gh issue close "$prd" -R "$SLUG" --comment "All acceptance criteria met and reviewed — closing." 2>/dev/null; then
    harness_event prd_closed kind=orch prd="$prd"
    release_on_prd_close "$prd"   # #283: once per reviewed PRD close, and only in the Harness repo
  else
    log "close of PRD #$prd failed (will retry next poll)"
  fi
}

# label_ready <issue> — the LABEL_READY dispatch action (#287). An open issue that names an open PRD
# as its parent but carries no label at all (a lane filed a follow-up bare) is in no lane's queue,
# and used to let that PRD sign off and close over it. One idempotent gh call, re-emitted every poll
# until the label lands; the issue then joins the PRD's children and holds its review until closed.
label_ready(){
  local n="$1"
  log "labelling stray child #$n $HARNESS_LABEL_READY (names an open PRD as parent, had no label)"
  gh issue edit "$n" -R "$SLUG" --add-label "$HARNESS_LABEL_READY" >/dev/null 2>&1 \
    || log "label of #$n failed (will retry next poll)"
}

spawn_orch(){   # <ACTION> <PAYLOAD> <PROMISE>
  local action="$1" payload="$2"; PROMISE="$3"; MAXITER="$ORCH_MAXITER"
  local tmpl wd prd=0 base ground=""; STAT_PRD=""
  case "$action" in
    PLAN)      tmpl=plan.md;;
    PRD)       tmpl=prd.md;;
    DECOMPOSE) tmpl=decompose.md; prd="$payload";;
    REVIEW)    tmpl=review.md;    prd="$payload";;
    *) log "bad orch action $action"; return 1;; esac
  # PRD-qualified goal so reap_done_sessions advances the right session when several PRDs are in
  # flight; the unit-level PLAN/PRD actions keep the bare goal.
  GOAL="$action"; (( prd > 0 )) && GOAL="$action:$prd"
  ensure_safe "$CHECKOUT"
  win_repo_config "$CHECKOUT"   # #488
  base="$(default_branch)"
  git -C "$CHECKOUT" fetch -q origin "$base" 2>/dev/null || true
  if (( prd > 0 )); then
    # DECOMPOSE/REVIEW: own worktree per PRD. Two of these can be live at once, and in the shared
    # $CHECKOUT they would clobber each other's .harness-task.md and yank each other's working tree
    # via `git reset --hard` — the same corruption #5/#109 fixed for bug-triage. Read-only + gh
    # only, so `agent/orch-<prd>` is a throwaway branch that is never pushed.
    wd="$(orch_worktree "$SLUG" "$prd")"
    remove_worktree "$CHECKOUT" "$wd"   # defensive pre-add reap of a crashed-orch leftover
    if ! git -C "$CHECKOUT" worktree add -B "agent/orch-$prd" "$wd" "origin/$base" 2>/dev/null; then
      git -C "$CHECKOUT" worktree add -B "agent/orch-$prd" "$wd" 2>/dev/null || { log "worktree add failed orch PRD #$prd"; return 1; }
    fi
    ensure_safe "$wd"
    win_repo_config "$wd"   # #488: per-repo longpaths + LF on Windows (never --global)
    run_worktree_hook "$wd"
  else
    # PLAN/PRD: unit-level, gated on zero PRDs existing, so they cannot race each other or a
    # DECOMPOSE/REVIEW. PLAN also needs a real branch to commit and push PLAN.md.
    wd="$CHECKOUT"
    git -C "$CHECKOUT" checkout -q "$base" 2>/dev/null || git -C "$CHECKOUT" checkout -q -B "$base" "origin/$base" 2>/dev/null || true
    git -C "$CHECKOUT" reset -q --hard "origin/$base" 2>/dev/null || true
  fi
  # Round is computed HERE, not in the prompt: a Claude session cannot call a lib.sh function,
  # and letting it count its own comments makes the cap something it can miscount past.
  local saround="" gdir="$STATE_DIR/gauntlet/$UNIT/p$prd" rsub="" csub=""
  if [[ "$action" == REVIEW ]]; then ground="$(gauntlet_round "$payload")"; saround="$(security_audit_round "$payload")"
    # How this CLI starts each sub-agent review.md asks for (#314): the critic works in the round's
    # evidence dir, its brief a sibling of that dir so the critic never sees it among A/ and B/.
    mkdir -p "$STATE_DIR/review/$UNIT/p$prd"
    rsub="$(cli_subagent "$wd" "$wd" "$STATE_DIR/review/$UNIT/p$prd/subagent.md")"
    csub="$(cli_subagent "$wd" "$gdir/r$ground" "$gdir/r$ground-critic.md")"; fi
  render "$PROMPTS_DIR/$tmpl" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" OWNER="$HARNESS_OWNER" \
    SPEC="$HARNESS_SPEC" PRD="$payload" ISSUE="" BRANCH="" PROMISE="$PROMISE" \
    LABEL_READY="$HARNESS_LABEL_READY" LABEL_PRD="$HARNESS_LABEL_PRD" LABEL_REVIEWED="$HARNESS_LABEL_REVIEWED" LABEL_HITL="$HARNESS_LABEL_HITL" \
    GAUNTLET_DIR="$gdir" GAUNTLET_ROUNDS="$HARNESS_GAUNTLET_ROUNDS" \
    GAUNTLET_ROUND="$ground" REVIEW_SUBAGENT="$rsub" CRITIC_SUBAGENT="$csub" \
    SECURITY_AUDIT="$HARNESS_SECURITY_AUDIT" SECURITY_AUDIT_ROUNDS="$HARNESS_SECURITY_AUDIT_ROUNDS" \
    SECURITY_AUDIT_ROUND="$saround" SECURITY_AUDIT_DIR="$STATE_DIR/security-audit/$UNIT/p$prd" \
    SECURITY_AUDIT_SKILL="$ENGINE_DIR/vendor/security-audit/SKILL.md" \
    SWARM="$HARNESS_SWARM" SWARM_SUITE="$(swarm_suite_cmd)" > "$wd/.harness-task.md"
  launch_claude "$(sess_orch "$UNIT" "$prd")" "$wd"
}

# prepare_impl <ISSUE> <PROMISE> — claim the issue (agent-working), set up its worktree on
# issue/<n> and render impl.md — resume.md for a force-paused issue or one whose branch is already
# pushed — into <worktree>/.harness-task.md. Everything spawn_impl does short of the launch, so
# `harness one start` (#366) sets an issue up exactly the way dispatch does. Sets PROMISE and
# IMPL_TMPL (the template rendered).
prepare_impl(){   # <ISSUE> <PROMISE>
  local issue="$1"; PROMISE="$2"
  local wd="$WORKTREES_DIR/$UNIT-i$issue" branch="issue/$issue" base; base="$(default_branch)"
  git -C "$CHECKOUT" fetch -q origin "$base" 2>/dev/null || true
  if ! git -C "$CHECKOUT" worktree add -B "$branch" "$wd" "origin/$base" 2>/dev/null; then
    git -C "$CHECKOUT" worktree add -B "$branch" "$wd" 2>/dev/null || { log "worktree add failed #$issue"; return 1; }
  fi
  ensure_safe "$wd"
  win_repo_config "$wd"   # #488
  run_worktree_hook "$wd"
  # Stamp agent-working only AFTER the worktree is in place (#416, as spawn_bug since #34). A failed
  # add returns above WITHOUT a stamp — and never removes one: it can mean a live lane still owns the
  # issue's worktree, and that lane may have re-taken the lock.
  gh issue edit "$issue" -R "$SLUG" --add-label "$HARNESS_LABEL_WORKING" 2>/dev/null || true
  # Resume detection: a force-paused issue (agent-paused label) OR an existing remote branch
  # means a prior agent checkpointed WIP to GitHub — continue it instead of starting fresh.
  local tmpl="impl.md" labels handoff=""
  labels="$(gh issue view "$issue" -R "$SLUG" --json labels -q '[.labels[].name]' 2>/dev/null || echo '')"
  # #471: the branch may sit ONLY in a submodule (issue/<unit>-<n>) — a lane that died after pushing just that.
  if [[ "$labels" == *"$HARNESS_LABEL_PAUSED"* ]] || git -C "$CHECKOUT" ls-remote --heads origin "$branch" 2>/dev/null | grep -q . \
       || submodule_branch_pushed "$wd" "issue/$(fleet_unit)-$issue"; then
    tmpl="resume.md"; handoff="$(resume_handoff "$issue")"; log "resuming paused issue #$issue from origin/$branch"
  fi
  IMPL_TMPL="$tmpl"
  mkdir -p "$STATE_DIR/subagent/$UNIT-i$issue"   # where an impl.md sub-agent's brief goes (cli_subagent)
  render "$PROMPTS_DIR/$tmpl" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" OWNER="$HARNESS_OWNER" \
    SPEC="$HARNESS_SPEC" PRD="" UNIT="$(fleet_unit)" ISSUE="$issue" BRANCH="$branch" PROMISE="$PROMISE" \
    LABEL_READY="$HARNESS_LABEL_READY" LABEL_PRD="$HARNESS_LABEL_PRD" LABEL_REVIEWED="$HARNESS_LABEL_REVIEWED" LABEL_HITL="$HARNESS_LABEL_HITL" \
    LABEL_WORKING="$HARNESS_LABEL_WORKING" LABEL_PAUSED="$HARNESS_LABEL_PAUSED" HANDOFF="$handoff" \
    SUBAGENT="$(cli_subagent "$wd" "$wd" "$STATE_DIR/subagent/$UNIT-i$issue/NAME.md")" \
    SWARM="$HARNESS_SWARM" SWARM_SUITE="$(swarm_suite_cmd)" > "$wd/.harness-task.md"
  return 0   # as before the split: a failed render write never stopped the launch
}

spawn_impl(){   # <ISSUE> <PROMISE>
  local issue="$1"; MAXITER="$IMPL_MAXITER"; GOAL="ISSUE:$issue"; STAT_PRD=""
  prepare_impl "$issue" "$2" || return 1
  STAT_PRD="$(issue_parent_prd "$issue")"   # #185: attribute the session to its PRD for `stats --prd`
  launch_claude "$(sess_impl "$UNIT" "$issue")" "$WORKTREES_DIR/$UNIT-i$issue"
}

# spawn_bug <issue> <phase> — launch ONE priority-lane session for a bug (#27). The phase
# (from bug_phase) picks the template AND a distinct session, so triage and fix are always
# two separate sessions with fresh context:
#   triage → bug-triage.md, in its OWN triage worktree (#5/#109 — was the shared CHECKOUT, which a
#            concurrent orch render+reset could clobber): refine the issue body + acceptance and flip
#            the label IN PLACE — read-only, no commits, no PR, no code (the branch is throwaway).
#   fix    → bug-fix.md, in a fresh issue worktree on issue/<n> (exactly like spawn_impl): TDD →
#            PR → auto-merge → close.
# Both phases stamp agent-working synchronously before returning so the lane never re-dispatches
# the same bug while its session is in flight (bug_lane_issues excludes agent-working).
spawn_bug(){
  local issue="$1" phase="$2" tmpl wd base handoff=""
  PROMISE="BUG $issue $phase DONE"; MAXITER="$IMPL_MAXITER"; GOAL="BUG:$issue:$phase"; STAT_PRD=""
  if [[ "$phase" == fix ]]; then
    # Repo-qualify the worktree dir (#37): issue numbers are per-repo, so two repos can each have
    # a bug #N — a bare bug-i$issue path would collide and block the second fix. The branch lives
    # in the repo's own checkout, so issue/$issue alone is already unambiguous there.
    tmpl="bug-fix.md"; wd="$(bug_worktree "$SLUG" "$issue")"; base="$(default_branch)"
    # Defensively reap a leftover worktree from a crashed/unclean fix (#34): without this the
    # `worktree add` below fails (rc 128, 'issue/N' already used by worktree) and the bug stays
    # stuck under agent-working forever. Remove + prune so a fresh attempt always starts clean.
    remove_worktree "$CHECKOUT" "$wd"
    # The triage is over once the bug is a fix. Its worktree is the triage lane's to reap, but a
    # triage that ran under a different lane (#214: the pool) can hand over before that reap runs.
    session_live "$(sess_bug "$SLUG" "$issue" triage)" \
      || remove_worktree "$CHECKOUT" "$(triage_worktree "$SLUG" "$issue")" "agent/bug-triage-$issue"
    git -C "$CHECKOUT" fetch -q origin "$base" 2>/dev/null || true
    if ! git -C "$CHECKOUT" worktree add -B "issue/$issue" "$wd" "origin/$base" 2>/dev/null; then
      git -C "$CHECKOUT" worktree add -B "issue/$issue" "$wd" 2>/dev/null || { log "worktree add failed bug #$issue"; return 1; }
    fi
    ensure_safe "$wd"
    win_repo_config "$wd"   # #488: per-repo longpaths + LF on Windows (never --global)
    run_worktree_hook "$wd"
    # Resume detection (mirrors spawn_impl, #36): a force-paused fix flips to agent-paused and
    # pushes its issue/<n> branch. Either signal means a prior agent checkpointed WIP to GitHub —
    # continue it from resume.md instead of restarting the fix cold from bug-fix.md.
    local labels
    labels="$(gh issue view "$issue" -R "$SLUG" --json labels -q '[.labels[].name]' 2>/dev/null || echo '')"
    if [[ "$labels" == *"$HARNESS_LABEL_PAUSED"* ]] || git -C "$CHECKOUT" ls-remote --heads origin "issue/$issue" 2>/dev/null | grep -q . \
         || submodule_branch_pushed "$wd" "issue/$(fleet_unit)-$issue"; then   # #471: submodule-only branch
      tmpl="resume.md"; handoff="$(resume_handoff "$issue")"; log "resuming paused bug #$issue from origin/issue/$issue"
    fi
  else
    # Triage gets its OWN worktree too (#5/#109): it used to run in the shared $CHECKOUT, where a
    # concurrent spawn_orch `render > $CHECKOUT/.harness-task.md` (brief clobber) + `git reset --hard
    # origin/<base>` (working-tree yank) corrupted the in-flight triage. Isolate it exactly like the
    # fix phase / spawn_impl. A DISTINCT triage-<slug>-i<n> path + agent/bug-triage-<n> branch keep it
    # off the fix worktree. (Triage stays read-only — no commits, no PR — the branch is throwaway.)
    tmpl="bug-triage.md"; wd="$(triage_worktree "$SLUG" "$issue")"; base="$(default_branch)"
    remove_worktree "$CHECKOUT" "$wd"   # defensive pre-add reap of a crashed-triage leftover (#34)
    git -C "$CHECKOUT" fetch -q origin "$base" 2>/dev/null || true
    if ! git -C "$CHECKOUT" worktree add -B "agent/bug-triage-$issue" "$wd" "origin/$base" 2>/dev/null; then
      git -C "$CHECKOUT" worktree add -B "agent/bug-triage-$issue" "$wd" 2>/dev/null || { log "worktree add failed triage #$issue"; return 1; }
    fi
    ensure_safe "$wd"
    win_repo_config "$wd"   # #488: per-repo longpaths + LF on Windows (never --global)
    run_worktree_hook "$wd"
  fi
  # Stamp agent-working only AFTER the worktree is in place (#34): a failed `worktree add` returns
  # above WITHOUT stamping, so a spawn failure never leaves an open bug under agent-working with no
  # live session (which would hide it from bug_lane_issues forever). BOTH phases now create a worktree
  # before reaching here, so the stamp is always after worktree setup. Both phases still stamp BEFORE
  # launch, so the lane never re-dispatches the same bug while its session is in flight.
  gh issue edit "$issue" -R "$SLUG" --add-label "$HARNESS_LABEL_WORKING" 2>/dev/null || true
  render "$PROMPTS_DIR/$tmpl" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" OWNER="$HARNESS_OWNER" \
    SPEC="$HARNESS_SPEC" PRD="" UNIT="$(fleet_unit)" ISSUE="$issue" BRANCH="issue/$issue" PROMISE="$PROMISE" \
    LABEL_READY="$HARNESS_LABEL_READY" LABEL_WORKING="$HARNESS_LABEL_WORKING" LABEL_PAUSED="$HARNESS_LABEL_PAUSED" \
    LABEL_BUG="$HARNESS_LABEL_BUG" LABEL_BUG_TRIAGED="$HARNESS_LABEL_BUG_TRIAGED" HANDOFF="$handoff" \
    SWARM="$HARNESS_SWARM" SWARM_SUITE="$(swarm_suite_cmd)" > "$wd/.harness-task.md"
  launch_claude "$(sess_bug "$SLUG" "$issue" "$phase")" "$wd"
}

# bug_goal_done <n> <phase> — has this phase's session delivered its outcome? triage: the issue
# is closed (invalid/dup/wontfix) OR the label flipped to bug-triaged (now a fix). fix: the issue
# is closed (its PR merged). Shared by the priority lane (drive_bug) and the pool (#214, bug_lane_tend). Reads GitHub via the lib.sh seams (_bug_state/_bug_labels).
bug_goal_done(){ local n="$1" phase="$2"
  [[ "$(_bug_state "$n")" == CLOSED ]] && return 0
  [[ "$phase" == triage && "$(bug_phase "$n")" == fix ]]; }

# bug_lane_tend <slug> <n> — one pool-taken bug's live sessions (#214): watchdogged, and ended once the
# phase goal is met. Shared by the step-based worker (#468).
bug_lane_tend(){ local slug="$1" n="$2" phase sess SLUG="$1"
  for phase in triage fix; do
    sess="$(sess_bug "$slug" "$n" "$phase")"
    session_live "$sess" || continue
    watchdog_session "$sess"
    if bug_goal_done "$n" "$phase"; then
      log "pool: bug #$n $phase goal met — ending $sess"
      [[ "$phase" == fix ]] && release_on_bug_merge "$n"   # #283: a triage close is a dismissal, not a merge
      cli_kill "$sess" "$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)" || true; rm -f "$RUN_DIR/$sess.goal"
    fi
  done; }
# bug_lane_reap_worktrees <slug> <n> — drop a pool-taken bug's fix and triage worktrees once its sessions are gone.
bug_lane_reap_worktrees(){ local slug="$1" n="$2"
  stats_sweep_ended   # #185: session_end before the worktree (and its ralph iteration count) goes
  remove_worktree "$(bug_checkout "$slug")" "$(bug_worktree "$slug" "$n")" "issue/$n"
  remove_worktree "$(bug_checkout "$slug")" "$(triage_worktree "$slug" "$n")" "agent/bug-triage-$n"; }

# dispatch_stalled_banner <repo> <unit> — say WHY a unit is sitting still, once per distinct state.
#
# Deduped on the status line itself, so a genuinely stuck unit announces once and then stays quiet
# until something about it changes — and a transient `gh` HOLD (dispatch_actions prints nothing and
# exits 3 on a rate limit) does not spam the log either, because the status read behind it holds the
# same way and yields the same empty key. The status line already carries the diagnosis: `open=N`
# with `unblocked=0` is the blocked-child case, `complete=N` with `open=0` is a PRD still to close.
dispatch_stalled_banner(){ local st
  st="$(python3 "$ISSUELIB" status "$1" 2>/dev/null)" || return 0
  [[ -z "$st" || "${_STALL_LOGGED:-}" == "$st" ]] && return 0
  _STALL_LOGGED="$st"
  log "$2: nothing dispatchable and nothing in flight — holding. $st"
  log "  a ready child that no lane can claim (unclosed dep, agent-blocked on a non-autonomous fleet, or parked agent-blocked and unchanged on an autonomous one) keeps the unit incomplete by design; close or unblock it to let the unit finish."; }

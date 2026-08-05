#!/usr/bin/env bash
# drive.sh — drive_unit(unit): take one unit from wherever it is to COMPLETE.
# Sourced after lib.sh (by pool-worker.sh and tests).
# Relies on bash dynamic scoping: drive_unit sets UNIT/REPO/SLUG/PROJECT/DESC/CHECKOUT as
# locals, and the helpers below read them.
_HARNESS_DRIVE_SOURCED=1

# Committed plan-completion artifacts (mirrors issuelib.py PLAN_MARKER_PATH). These live in the
# unit's repo — NOT the gitignored .harness runtime clone — so the marker survives a fresh checkout.
PLAN_MARKER_PATH="docs/harness/plan-complete.json"
PLAN_ARCHIVE_DIR="docs/harness/archive"

default_branch(){ gh repo view "$SLUG" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main; }

# archive_plan — on unit completion, archive a live PLAN.md (never delete) and write a committed,
# spec-keyed completion marker, so the auto-PLAN gate (issuelib.py) neither stays blocked by the
# leftover doc nor silently re-fires against the same spec. Idempotent: a no-op once PLAN.md is
# already archived. git mv/commit/push are best-effort (fall back to plain mv; never abort finalize).
# (It deliberately does NOT touch targets.tsv — see the note at the end of the function.)
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
  # NOTE: do NOT drop the completed unit's targets.tsv row in multi-topology. targets.tsv is the
  # dependency registry: downstream units resolve their deps through it (deps_complete →
  # unit_complete resolves the repo by unit id). Deleting a completed unit's row makes any dependent
  # unit's deps unresolvable (unit_repo → "-"), so deps_complete fails forever and the whole
  # downstream DAG freezes after that unit completes. Completion is already recomputed live each poll
  # (claimable_units skips complete units via unit_complete), so a finished unit is never re-driven
  # even with its row intact — the row can and must persist.
}

reap_done_sessions(){
  local s goal
  while read -r s; do
    [[ -z "$s" ]] && continue
    goal="$(cat "$RUN_DIR/$s.goal" 2>/dev/null)"; [[ -z "$goal" ]] && continue
    if [[ "$(python3 "$ISSUELIB" check "$REPO" "$goal" 2>/dev/null)" == DONE ]]; then
      log "session $s goal '$goal' satisfied → advancing"
      tmux kill-session -t "$s" 2>/dev/null || true
      rm -f "$RUN_DIR/$s.goal"
    fi
  done < <(team_sessions "$UNIT")
}

reap_team(){
  shopt -s nullglob
  for wd in "$WORKTREES_DIR/$UNIT"-i*; do
    local issue="${wd##*-i}" sess; sess="$(sess_impl "$UNIT" "$issue")"
    session_live "$sess" && continue
    log "reaping issue #$issue worktree"
    git -C "$CHECKOUT" worktree remove --force "$wd" 2>/dev/null || rm -rf "$wd"
    local state
    state="$(gh issue view "$issue" -R "$SLUG" --json state,labels 2>/dev/null)" || continue
    # fully autonomous: free a still-open issue's stale agent-working for retry, even if a
    # prior session left it agent-blocked (no human will ever clear that label for us).
    if echo "$state" | grep -q '"state":"OPEN"'; then
      gh issue edit "$issue" -R "$SLUG" --remove-label "$HARNESS_LABEL_WORKING" 2>/dev/null || true
    else
      # issue closed ⇒ its PR squash-merged; drop the now-orphaned local feature branch.
      # (the remote branch is auto-deleted on merge by delete_branch_on_merge + --delete-branch.)
      git -C "$CHECKOUT" branch -D "issue/$issue" 2>/dev/null || true
    fi
  done
  shopt -u nullglob
}

# finalize_unit — the unit just reached COMPLETE. reap_done_sessions/reap_team only run at the
# TOP of the poll loop, so the session AND worktree that DELIVER completion are never swept by
# them — the loop exits first, orphaning the last tmux session + worktree (this is exactly how a
# finished review session gets left behind). This final, unconditional sweep tears the whole team
# down: kill every session still up for the unit, drop its goal file, remove each per-issue
# worktree and its local branch, then prune. (Remote branches are auto-deleted on squash-merge.)
finalize_unit(){
  local s wd issue
  archive_plan   # archive PLAN.md + write the spec-keyed completion marker (idempotent no-op if none)
  while read -r s; do
    [[ -z "$s" ]] && continue
    tmux kill-session -t "$s" 2>/dev/null && log "finalize: reaped leftover session $s"
    rm -f "$RUN_DIR/$s.goal"
  done < <(team_sessions "$UNIT")
  shopt -s nullglob
  for wd in "$WORKTREES_DIR/$UNIT"-i*; do
    issue="${wd##*-i}"
    git -C "$CHECKOUT" worktree remove --force "$wd" 2>/dev/null || rm -rf "$wd"
    git -C "$CHECKOUT" branch -D "issue/$issue" 2>/dev/null || true
    log "finalize: removed worktree + local branch for #$issue"
  done
  git -C "$CHECKOUT" worktree prune 2>/dev/null || true
  shopt -u nullglob
}

ensure_checkout(){  # clone unit repo into $CHECKOUT for multi topology if absent; no-op for single
  [[ "$HARNESS_TOPOLOGY" == multi ]] || return 0
  git -C "$CHECKOUT" rev-parse --git-dir >/dev/null 2>&1 && return 0
  log "cloning $SLUG into $CHECKOUT"
  git clone "https://github.com/$SLUG.git" "$CHECKOUT" || { log "clone failed for $SLUG"; return 1; }
  ensure_safe "$CHECKOUT"
}

# close_prd <prd> — the engine's own PRD close (the CLOSE_PRD dispatch action). REVIEW only SIGNS
# OFF (applies the reviewed label); the mechanical close lives here so it never depends on the
# review agent's own `gh issue close` succeeding — a shared-token rate limit could drop that call
# and strand a reviewed PRD open forever ("PRD won't close"). This is a single idempotent gh call,
# re-emitted by dispatch every poll until the PRD is closed; no Ralph session, no worktree, no goal.
close_prd(){
  local prd="$1"
  log "engine closing reviewed PRD #$prd"
  gh issue close "$prd" -R "$SLUG" --comment "All acceptance criteria met and reviewed — closing." 2>/dev/null || \
    log "close of PRD #$prd failed (will retry next poll)"
}

spawn_orch(){   # <ACTION> <PAYLOAD> <PROMISE>
  local action="$1" payload="$2"; PROMISE="$3"; MAXITER="$ORCH_MAXITER"; GOAL="$action"
  ensure_checkout || return 1
  ensure_safe "$CHECKOUT"
  local base; base="$(default_branch)"
  git -C "$CHECKOUT" fetch -q origin "$base" 2>/dev/null || true
  git -C "$CHECKOUT" checkout -q "$base" 2>/dev/null || git -C "$CHECKOUT" checkout -q -B "$base" "origin/$base" 2>/dev/null || true
  git -C "$CHECKOUT" reset -q --hard "origin/$base" 2>/dev/null || true
  local tmpl; case "$action" in
    PLAN)     tmpl=plan.md;;
    PRD)      tmpl=prd.md;;
    DECOMPOSE) tmpl=decompose.md;;
    REVIEW)   tmpl=review.md;;
    *) log "bad orch action $action"; return 1;; esac
  render "$PROMPTS_DIR/$tmpl" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" OWNER="$HARNESS_OWNER" \
    SPEC="$HARNESS_SPEC" PRD="$payload" ISSUE="" BRANCH="" PROMISE="$PROMISE" \
    LABEL_READY="$HARNESS_LABEL_READY" LABEL_PRD="$HARNESS_LABEL_PRD" LABEL_REVIEWED="$HARNESS_LABEL_REVIEWED" > "$CHECKOUT/.harness-task.md"
  launch_claude "$(sess_orch "$UNIT")" "$CHECKOUT"
}

spawn_impl(){   # <ISSUE> <PROMISE>
  local issue="$1"; PROMISE="$2"; MAXITER="$IMPL_MAXITER"; GOAL="ISSUE:$issue"
  local wd="$WORKTREES_DIR/$UNIT-i$issue" branch="issue/$issue" base; base="$(default_branch)"
  ensure_checkout || { log "checkout unavailable for #$issue"; return 1; }
  gh issue edit "$issue" -R "$SLUG" --add-label "$HARNESS_LABEL_WORKING" 2>/dev/null || true
  git -C "$CHECKOUT" fetch -q origin "$base" 2>/dev/null || true
  if ! git -C "$CHECKOUT" worktree add -B "$branch" "$wd" "origin/$base" 2>/dev/null; then
    git -C "$CHECKOUT" worktree add -B "$branch" "$wd" 2>/dev/null || { log "worktree add failed #$issue"; return 1; }
  fi
  ensure_safe "$wd"
  run_worktree_hook "$wd"
  # Resume detection: a force-paused issue (agent-paused label) OR an existing remote branch
  # means a prior agent checkpointed WIP to GitHub — continue it instead of starting fresh.
  local tmpl="impl.md" labels
  labels="$(gh issue view "$issue" -R "$SLUG" --json labels -q '[.labels[].name]' 2>/dev/null || echo '')"
  if [[ "$labels" == *"$HARNESS_LABEL_PAUSED"* ]] || git -C "$CHECKOUT" ls-remote --heads origin "$branch" 2>/dev/null | grep -q .; then
    tmpl="resume.md"; log "resuming paused issue #$issue from origin/$branch"
  fi
  render "$PROMPTS_DIR/$tmpl" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" OWNER="$HARNESS_OWNER" \
    SPEC="$HARNESS_SPEC" PRD="" ISSUE="$issue" BRANCH="$branch" PROMISE="$PROMISE" \
    LABEL_READY="$HARNESS_LABEL_READY" LABEL_PRD="$HARNESS_LABEL_PRD" LABEL_REVIEWED="$HARNESS_LABEL_REVIEWED" \
    LABEL_WORKING="$HARNESS_LABEL_WORKING" LABEL_PAUSED="$HARNESS_LABEL_PAUSED" > "$wd/.harness-task.md"
  launch_claude "$(sess_impl "$UNIT" "$issue")" "$wd"
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
  local issue="$1" phase="$2" tmpl wd base
  PROMISE="BUG $issue $phase DONE"; MAXITER="$IMPL_MAXITER"; GOAL="BUG:$issue:$phase"
  ensure_checkout || { log "checkout unavailable for bug #$issue"; return 1; }
  if [[ "$phase" == fix ]]; then
    # Repo-qualify the worktree dir (#37): issue numbers are per-repo, so two repos can each have
    # a bug #N — a bare bug-i$issue path would collide and block the second fix. The branch lives
    # in the repo's own checkout, so issue/$issue alone is already unambiguous there.
    tmpl="bug-fix.md"; wd="$(bug_worktree "$SLUG" "$issue")"; base="$(default_branch)"
    # Defensively reap a leftover worktree from a crashed/unclean fix (#34): without this the
    # `worktree add` below fails (rc 128, 'issue/N' already used by worktree) and the bug stays
    # stuck under agent-working forever. Remove + prune so a fresh attempt always starts clean.
    remove_worktree "$CHECKOUT" "$wd"
    git -C "$CHECKOUT" fetch -q origin "$base" 2>/dev/null || true
    if ! git -C "$CHECKOUT" worktree add -B "issue/$issue" "$wd" "origin/$base" 2>/dev/null; then
      git -C "$CHECKOUT" worktree add -B "issue/$issue" "$wd" 2>/dev/null || { log "worktree add failed bug #$issue"; return 1; }
    fi
    ensure_safe "$wd"
    run_worktree_hook "$wd"
    # Resume detection (mirrors spawn_impl, #36): a force-paused fix flips to agent-paused and
    # pushes its issue/<n> branch. Either signal means a prior agent checkpointed WIP to GitHub —
    # continue it from resume.md instead of restarting the fix cold from bug-fix.md.
    local labels
    labels="$(gh issue view "$issue" -R "$SLUG" --json labels -q '[.labels[].name]' 2>/dev/null || echo '')"
    if [[ "$labels" == *"$HARNESS_LABEL_PAUSED"* ]] || git -C "$CHECKOUT" ls-remote --heads origin "issue/$issue" 2>/dev/null | grep -q .; then
      tmpl="resume.md"; log "resuming paused bug #$issue from origin/issue/$issue"
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
    run_worktree_hook "$wd"
  fi
  # Stamp agent-working only AFTER the worktree is in place (#34): a failed `worktree add` returns
  # above WITHOUT stamping, so a spawn failure never leaves an open bug under agent-working with no
  # live session (which would hide it from bug_lane_issues forever). BOTH phases now create a worktree
  # before reaching here, so the stamp is always after worktree setup. Both phases still stamp BEFORE
  # launch, so the lane never re-dispatches the same bug while its session is in flight.
  gh issue edit "$issue" -R "$SLUG" --add-label "$HARNESS_LABEL_WORKING" 2>/dev/null || true
  render "$PROMPTS_DIR/$tmpl" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" OWNER="$HARNESS_OWNER" \
    SPEC="$HARNESS_SPEC" PRD="" ISSUE="$issue" BRANCH="issue/$issue" PROMISE="$PROMISE" \
    LABEL_READY="$HARNESS_LABEL_READY" LABEL_WORKING="$HARNESS_LABEL_WORKING" LABEL_PAUSED="$HARNESS_LABEL_PAUSED" \
    LABEL_BUG="$HARNESS_LABEL_BUG" LABEL_BUG_TRIAGED="$HARNESS_LABEL_BUG_TRIAGED" > "$wd/.harness-task.md"
  launch_claude "$(sess_bug "$SLUG" "$issue" "$phase")" "$wd"
}

# drive_unit <unit> — poll loop; returns 0 when the unit reaches COMPLETE.
drive_unit(){
  local UNIT="$1" REPO SLUG PROJECT DESC CHECKOUT drained=0
  REPO="$(unit_repo "$UNIT")"; [[ -n "$REPO" ]] || { log "unknown unit: $UNIT"; return 1; }
  SLUG="$(unit_slug "$UNIT")"; PROJECT="$UNIT"; DESC="$(unit_desc "$UNIT")"; CHECKOUT="$(unit_checkout "$UNIT")"
  log "drive $SLUG — mode $HARNESS_MODE cap $CAP poll ${POLL}s"
  while ! unit_complete "$UNIT"; do
    reap_done_sessions; reap_team; watchdog_team; reap_finished_inject "$UNIT"   # #115 watchdog + reap a finished injector parked at idle ❯
    if is_paused; then log "$UNIT paused — draining (no new dispatch); live sessions keep running"; drained=1; break; fi
    local active free allow_orch action payload promise
    active="$(count_team_sessions "$UNIT")"; free=$(( CAP - active ))
    if (( free > 0 )); then
      allow_orch=0; (( active == 0 )) && allow_orch=1
      while IFS=$'\t' read -r action payload promise; do
        [[ -z "$action" ]] && continue
        case "$action" in
          IMPL)      spawn_impl "$payload" "$promise";;
          CLOSE_PRD) close_prd "$payload";;        # engine-side close — no session, returns at once
          *)         spawn_orch "$action" "$payload" "$promise";;
        esac
        sleep 2
      done < <(dispatch_actions "$REPO" "$free" "$allow_orch")
    fi
    sleep "$POLL"
  done
  # The loop exits on genuine completion OR a pause-drain `break`; track which directly via
  # `drained` rather than re-querying unit_complete here — that re-query is a GitHub round-trip,
  # and a transient error would wrongly skip the sweep and re-orphan the very session this
  # teardown exists to reap. Only tear the team down on real completion; a paused unit must keep
  # its live sessions running to drain.
  if (( drained )); then log "$UNIT drained (paused) — live sessions left running"; else finalize_unit; log "$UNIT COMPLETE"; fi
}

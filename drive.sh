#!/usr/bin/env bash
# drive.sh — drive_unit(unit): take one unit from wherever it is to COMPLETE.
# Sourced after lib.sh (by pool-worker.sh and tests).
# Relies on bash dynamic scoping: drive_unit sets UNIT/REPO/SLUG/PROJECT/DESC/CHECKOUT as
# locals, and the helpers below read them.
_HARNESS_DRIVE_SOURCED=1

default_branch(){ gh repo view "$SLUG" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main; }

reap_done_sessions(){
  local s goal
  while read -r s; do
    [[ -z "$s" ]] && continue
    goal="$(cat "$RUN_DIR/$s.goal" 2>/dev/null)"; [[ -z "$goal" ]] && continue
    if [[ "$(python3 "$HARNESS_DIR/issuelib.py" check "$REPO" "$goal" 2>/dev/null)" == DONE ]]; then
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
    fi
  done
  shopt -u nullglob
}

ensure_checkout(){  # clone unit repo into $CHECKOUT for multi topology if absent; no-op for single
  [[ "$HARNESS_TOPOLOGY" == multi ]] || return 0
  git -C "$CHECKOUT" rev-parse --git-dir >/dev/null 2>&1 && return 0
  log "cloning $SLUG into $CHECKOUT"
  git clone "https://github.com/$SLUG.git" "$CHECKOUT" || { log "clone failed for $SLUG"; return 1; }
  ensure_safe "$CHECKOUT"
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

# drive_unit <unit> — poll loop; returns 0 when the unit reaches COMPLETE.
drive_unit(){
  local UNIT="$1" REPO SLUG PROJECT DESC CHECKOUT
  REPO="$(unit_repo "$UNIT")"; [[ -n "$REPO" ]] || { log "unknown unit: $UNIT"; return 1; }
  SLUG="$(unit_slug "$UNIT")"; PROJECT="$UNIT"; DESC="$(unit_desc "$UNIT")"; CHECKOUT="$(unit_checkout "$UNIT")"
  log "drive $SLUG — mode $HARNESS_MODE cap $CAP poll ${POLL}s"
  while ! unit_complete "$UNIT"; do
    reap_done_sessions; reap_team
    if is_paused; then log "$UNIT paused — draining (no new dispatch); live sessions keep running"; break; fi
    local active free allow_orch action payload promise
    active="$(count_team_sessions "$UNIT")"; free=$(( CAP - active ))
    if (( free > 0 )); then
      allow_orch=0; (( active == 0 )) && allow_orch=1
      while IFS=$'\t' read -r action payload promise; do
        [[ -z "$action" ]] && continue
        if [[ "$action" == IMPL ]]; then spawn_impl "$payload" "$promise"; else spawn_orch "$action" "$payload" "$promise"; fi
        sleep 2
      done < <(dispatch_actions "$REPO" "$free" "$allow_orch")
    fi
    sleep "$POLL"
  done
  log "$UNIT COMPLETE"
}

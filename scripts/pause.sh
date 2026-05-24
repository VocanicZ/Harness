#!/usr/bin/env bash
# pause.sh [--force] — pause the fleet.
#   (soft)   stop claiming/dispatching new work; workers idle; live sessions finish naturally.
#   --force  tell each live agent to checkpoint to GitHub (commit+push+/handoff comment+label),
#            then idle. Resumable from ANY machine. (implemented in a later step)
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Build the one-line checkpoint instruction sent to a live agent. Single-quoted printf
# format keeps the literal backticks/markers from being command-substituted by THIS shell.
# An empty <branch> (a read-only triage session, #36) emits a no-push variant that still runs
# /handoff and flips agent-working → agent-paused, so the lane is never left orphaned.
_checkpoint_msg(){  # <issue> <slug> <branch> <working-label> <paused-label>
  if [[ -n "$3" ]]; then
    printf 'HARNESS CHECKPOINT — pause requested. Stop now. Commit ALL work in progress and push your branch to origin. Then run the /handoff skill and post the handoff as a GitHub issue comment: gh issue comment %s -R %s --body-file <file>, whose FIRST line is exactly `<!-- harness-handoff issue=%s branch=%s -->`. Then swap labels: gh issue edit %s -R %s --remove-label %s --add-label %s. Do NOT merge or close the issue. Then output your completion promise and exit.' \
      "$1" "$2" "$1" "$3" "$1" "$2" "$4" "$5"
  else
    printf 'HARNESS CHECKPOINT — pause requested. Stop now. You have no code branch to push (read-only phase). Run the /handoff skill and post the handoff as a GitHub issue comment: gh issue comment %s -R %s --body-file <file>, whose FIRST line is exactly `<!-- harness-handoff issue=%s -->`. Then swap labels: gh issue edit %s -R %s --remove-label %s --add-label %s. Do NOT merge or close the issue. Then output your completion promise and exit.' \
      "$1" "$2" "$1" "$1" "$2" "$4" "$5"
  fi
}

# Parse a live session name into "<issue> <slug> <branch>" for the checkpoint, setting the
# globals _CP_ISSUE/_CP_SLUG/_CP_BRANCH. Two shapes (#36): impl sessions hz-<unit>-i<issue>
# (branch issue/<issue>), and priority-lane sessions hz-bug-<slug-sanitised>-<n>-(triage|fix) —
# the fix carries branch issue/<n>, triage has none (read-only). Returns 1 for an unrecognised
# session.
#
# The lane session carries the REPO (#44), but only sanitised (/ -> _), which can't be reversed
# unambiguously (owner_repo). So the real owner/repo is recovered from the live bug claim's stored
# token (third field), keyed by the same sanitised slug+number the session embeds. This is the
# routing fix: a colliding issue #N in another repo no longer mis-resolves via the lossy bug_repo
# rescan. A legacy bare session (hz-bug-<n>-(triage|fix)) still falls back to bug_repo.
_checkpoint_target(){  # <session>
  local sess="$1" issue unit phase
  local bug_re="^${HARNESS_SESS_PREFIX}-bug-(.+)-([0-9]+)-(triage|fix)$"
  local bug_bare_re="^${HARNESS_SESS_PREFIX}-bug-([0-9]+)-(triage|fix)$"
  if [[ "$sess" =~ $bug_re ]]; then
    local san="${BASH_REMATCH[1]}"; issue="${BASH_REMATCH[2]}"; phase="${BASH_REMATCH[3]}"
    local tok; tok="$(awk '{print $3; exit}' "$CLAIMS_DIR/bug-${san}-${issue}.claim" 2>/dev/null)"
    if [[ -n "$tok" ]]; then _CP_SLUG="$(_with_owner "$(_bug_ref_repo "$tok")")"
    else _CP_SLUG="$(_with_owner "$(bug_repo "$issue")")"; fi
    _CP_ISSUE="$issue"
    [[ "$phase" == fix ]] && _CP_BRANCH="issue/$issue" || _CP_BRANCH=""
    return 0
  fi
  if [[ "$sess" =~ $bug_bare_re ]]; then
    issue="${BASH_REMATCH[1]}"; phase="${BASH_REMATCH[2]}"
    _CP_ISSUE="$issue"; _CP_SLUG="$(_with_owner "$(bug_repo "$issue")")"
    [[ "$phase" == fix ]] && _CP_BRANCH="issue/$issue" || _CP_BRANCH=""
    return 0
  fi
  if [[ "$sess" =~ ^${HARNESS_SESS_PREFIX}-.*-i[0-9]+$ ]]; then
    issue="${sess##*-i}"
    unit="${sess#"$HARNESS_SESS_PREFIX"-}"; unit="${unit%-i$issue}"
    _CP_ISSUE="$issue"; _CP_SLUG="$(unit_slug "$unit")"; _CP_BRANCH="issue/$issue"
    return 0
  fi
  return 1
}

force_pause(){
  command -v tmux >/dev/null || die "tmux not found"
  command -v gh   >/dev/null || die "gh not found"
  local sessions sess issue slug branch msg
  # Match BOTH impl sessions (hz-<unit>-i<issue>) and priority-lane sessions
  # (hz-bug-<slug-sanitised>-<n>-triage|fix, or a legacy bare hz-bug-<n>-...) — a forced pause must
  # reach the bug lane too (#36), and the lane session now carries the repo (#44).
  sessions="$(tmux ls -F '#S' 2>/dev/null \
    | grep -E "^$HARNESS_SESS_PREFIX-(.*-i[0-9]+|bug-.+-(triage|fix))$" || true)"
  if [[ -z "$sessions" ]]; then
    echo "No live impl/lane sessions — nothing to checkpoint. Marking paused."
    touch "$PAUSE_FLAG"; return 0
  fi
  # 1) inject the checkpoint instruction into every live impl/lane session
  local -a pending=()
  while read -r sess; do
    [[ -z "$sess" ]] && continue
    _checkpoint_target "$sess" || { echo "  skip unrecognised session: $sess"; continue; }
    issue="$_CP_ISSUE"; slug="$_CP_SLUG"; branch="$_CP_BRANCH"
    msg="$(_checkpoint_msg "$issue" "$slug" "$branch" "$HARNESS_LABEL_WORKING" "$HARNESS_LABEL_PAUSED")"
    tmux send-keys -t "$sess" -l "$msg" 2>/dev/null || true
    tmux send-keys -t "$sess" Enter 2>/dev/null || true
    pending+=("$sess:$issue:$slug")
    echo "  checkpoint requested: $sess (issue #$issue on $slug)"
  done <<< "$sessions"
  # 2) poll GitHub for the paused label = proof the agent committed+pushed+labeled
  local deadline=$(( $(date +%s) + HARNESS_PAUSE_GRACE )) item u i sl labels
  while (( ${#pending[@]} > 0 )) && (( $(date +%s) < deadline )); do
    local -a still=()
    for item in "${pending[@]}"; do
      IFS=: read -r u i sl <<< "$item"
      labels="$(gh issue view "$i" -R "$sl" --json labels -q '[.labels[].name]' 2>/dev/null || echo '')"
      if [[ "$labels" == *"$HARNESS_LABEL_PAUSED"* ]]; then
        echo "  confirmed paused: $sl#$i"
      else
        still+=("$item")
      fi
    done
    pending=( ${still[@]+"${still[@]}"} )
    (( ${#pending[@]} > 0 )) && sleep 3
  done
  # 3) mark the machine paused (workers idle). NEVER kill — stragglers keep running.
  touch "$PAUSE_FLAG"
  if (( ${#pending[@]} > 0 )); then
    echo "FLEET: PAUSED — WARNING: ${#pending[@]} session(s) did not confirm within ${HARNESS_PAUSE_GRACE}s; left running (NOT killed):"
    for item in "${pending[@]}"; do IFS=: read -r u i sl <<< "$item"; echo "    pending: $sl#$i"; done
    echo "  (they will get the agent-paused label when they finish checkpointing; resume picks them up)"
  else
    echo "FLEET: PAUSED — all in-flight agents checkpointed to GitHub. Resume anywhere: harness/resume.sh"
  fi
}

FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1

if (( FORCE )); then
  force_pause   # defined below (Task 4)
else
  touch "$PAUSE_FLAG"
  echo "FLEET: PAUSED (draining) — workers stop claiming; live sessions finish. Resume: harness/resume.sh"
fi

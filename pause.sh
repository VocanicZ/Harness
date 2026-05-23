#!/usr/bin/env bash
# pause.sh [--force] — pause the fleet.
#   (soft)   stop claiming/dispatching new work; workers idle; live sessions finish naturally.
#   --force  tell each live agent to checkpoint to GitHub (commit+push+/handoff comment+label),
#            then idle. Resumable from ANY machine. (implemented in a later step)
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Build the one-line checkpoint instruction sent to a live agent. Single-quoted printf
# format keeps the literal backticks/markers from being command-substituted by THIS shell.
_checkpoint_msg(){  # <issue> <slug> <branch> <working-label> <paused-label>
  printf 'HARNESS CHECKPOINT — pause requested. Stop now. Commit ALL work in progress and push your branch to origin. Then run the /handoff skill and post the handoff as a GitHub issue comment: gh issue comment %s -R %s --body-file <file>, whose FIRST line is exactly `<!-- harness-handoff issue=%s branch=%s -->`. Then swap labels: gh issue edit %s -R %s --remove-label %s --add-label %s. Do NOT merge or close the issue. Then output your completion promise and exit.' \
    "$1" "$2" "$1" "$3" "$1" "$2" "$4" "$5"
}

force_pause(){
  command -v tmux >/dev/null || die "tmux not found"
  command -v gh   >/dev/null || die "gh not found"
  local sessions sess unit issue slug branch msg
  sessions="$(tmux ls -F '#S' 2>/dev/null | grep -E "^$HARNESS_SESS_PREFIX-.*-i[0-9]+$" || true)"
  if [[ -z "$sessions" ]]; then
    echo "No live impl sessions — nothing to checkpoint. Marking paused."
    touch "$PAUSE_FLAG"; return 0
  fi
  # 1) inject the checkpoint instruction into every live impl session
  local -a pending=()
  while read -r sess; do
    [[ -z "$sess" ]] && continue
    issue="${sess##*-i}"                       # hz-<unit>-i<issue> -> <issue>
    unit="${sess#"$HARNESS_SESS_PREFIX"-}"; unit="${unit%-i$issue}"   # -> <unit>
    slug="$(unit_slug "$unit")"; branch="issue/$issue"
    msg="$(_checkpoint_msg "$issue" "$slug" "$branch" "$HARNESS_LABEL_WORKING" "$HARNESS_LABEL_PAUSED")"
    tmux send-keys -t "$sess" -l "$msg" 2>/dev/null || true
    tmux send-keys -t "$sess" Enter 2>/dev/null || true
    pending+=("$unit:$issue:$slug")
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

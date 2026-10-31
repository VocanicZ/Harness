#!/usr/bin/env bash
# pause.sh [--force] — pause the fleet.
#   (soft)   stop claiming/dispatching new work; workers idle; live sessions finish naturally.
#   --force  tell each live agent to checkpoint to GitHub (commit+push+/handoff comment+label),
#            then idle. Resumable from ANY machine. A headless lane is ended once its checkpoint turn
#            is over (#350); a tmux one is never killed.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# _checkpoint_msg / _checkpoint_target / checkpoint_sessions live in lib.sh + usage.sh: the #194
# usage checkpoint sends the very same instruction to the very same sessions.

force_pause(){
  local b; for b in $(sess_bins); do command -v "$b" >/dev/null || die "$b not found"; done
  command -v gh   >/dev/null || die "gh not found"
  local sessions sess issue slug branch msg mark
  # Match BOTH impl sessions (hz-<unit>-i<issue>) and priority-lane sessions
  # (hz-bug-<slug-sanitised>-<n>-triage|fix, or a legacy bare hz-bug-<n>-...) — a forced pause must
  # reach the bug lane too (#36), and the lane session now carries the repo (#44).
  sessions="$(checkpoint_sessions)"
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
    mark="$(sess_turns "$sess")"   # #350: a backend that counts turns (headless) is waited on for this one
    cli_send "$sess" "$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)" "$msg"
    pending+=("$sess:$issue:$slug:$mark")
    echo "  checkpoint requested: $sess (issue #$issue on $slug)"
  done <<< "$sessions"
  # 2) poll GitHub for the paused label = proof the agent committed+pushed+labeled. A session whose
  #    backend counts its turns (a headless lane, #350) is waited on too, through the lane's state, until
  #    its checkpoint turn has ended — then it is ended: it has nothing left to do, and the resume
  #    relaunches it in its worktree, carrying on the same claude session (launch_agent, sess_resume_id).
  local deadline=$(( $(date +%s) + HARNESS_PAUSE_GRACE )) item u i sl m labels
  while (( ${#pending[@]} > 0 )) && (( $(date +%s) < deadline )); do
    local -a still=()
    for item in "${pending[@]}"; do
      IFS=: read -r u i sl m <<< "$item"
      labels="$(gh issue view "$i" -R "$sl" --json labels -q '[.labels[].name]' 2>/dev/null || echo '')"
      if [[ "$labels" == *"$HARNESS_LABEL_PAUSED"* ]]; then
        if [[ -n "$m" ]]; then
          sess_turn_ended "$u" "$m" || { still+=("$item"); continue; }
          cli_kill "$u" "$(cat "$RUN_DIR/$u.wd" 2>/dev/null)" >/dev/null 2>&1 || true
          echo "  lane ended after its checkpoint: $u"
        fi
        echo "  confirmed paused: $sl#$i"
        stats_sess_event "$u" paused
      else
        still+=("$item")
      fi
    done
    pending=( ${still[@]+"${still[@]}"} )
    (( ${#pending[@]} > 0 )) && sleep 3
  done
  # 3) mark the machine paused (workers idle). A straggler is NEVER killed — it keeps running.
  touch "$PAUSE_FLAG"
  if (( ${#pending[@]} > 0 )); then
    echo "FLEET: PAUSED — WARNING: ${#pending[@]} session(s) did not confirm within ${HARNESS_PAUSE_GRACE}s; left running (NOT killed):"
    for item in "${pending[@]}"; do IFS=: read -r u i sl m <<< "$item"; echo "    pending: $sl#$i"; done
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

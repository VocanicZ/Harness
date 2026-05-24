#!/usr/bin/env bash
# start.sh [--recover] — launch the Harness worker-pool delivery fleet.
# A fixed pool of HARNESS_POOL workers each claim, drive, and release units, plus a single
# resident priority bug lane (cap 1, fast poll) that claims bug-lane issues one at a time.
# Re-runnable: pool.sh / priority.sh skip workers already alive.
#
#   --recover   crash / new-machine recovery sweep BEFORE launch:
#               (1) drop stale pidfiles whose process is gone (post-reboot PIDs lie);
#               (2) clear stale claim files whose worker pid is dead;
#               (3) free GitHub issues stuck under HARNESS_LABEL_WORKING whose session
#                   died with the host — reap_team only walks LOCAL worktrees, so a
#                   crashed/migrated box leaves orphaned issues invisible to dispatch.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
rm -f "$PAUSE_FLAG"   # starting un-pauses this machine's pool

command -v tmux   >/dev/null || die "tmux not found — install tmux first"
command -v claude >/dev/null || die "claude not found on PATH — install Claude Code first"
command -v gh     >/dev/null || die "gh not found — install the GitHub CLI first"

# crash / migration recovery: GitHub is the source of truth, but two bits of local state
# lie after an unclean stop — stale pidfiles and orphaned HARNESS_LABEL_WORKING labels.
# Clear both so dispatch resumes cleanly.
recover(){
  echo "── recovery sweep (crash / new-machine) ──"
  shopt -s nullglob
  for pf in "$RUN_DIR"/*.pid; do
    if kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
      echo "  live pid in $(basename "$pf") — left as is"
    else
      rm -f "$pf"; echo "  cleared stale pidfile $(basename "$pf")"
    fi
  done
  shopt -u nullglob
  echo "  clearing stale claims (dead-pid worker claims):"
  # Acquire pool lock around clear_stale_claims to avoid racing a live claim_next.
  # --recover is normally run before workers start, but the lock is cheap insurance.
  local lockfd
  exec {lockfd}>"$POOL_LOCK"
  flock "$lockfd"
  clear_stale_claims
  flock -u "$lockfd"
  exec {lockfd}>&-

  # The priority lane reaps its fix worktrees in drive_bug, but an unclean host exit kills the lane
  # mid-fix and orphans a bug-<slug>-i<n> worktree on disk. Left in place it makes the next
  # spawn_bug fix collide on `worktree add` (rc 128) and wedge the lane. Sweep dead-session ones now
  # (the agent-working-label sweep below then frees the issue so the lane re-claims it cleanly). #34
  echo "  sweeping orphaned bug-fix worktrees:"
  sweep_orphan_bug_worktrees

  # Free issues stuck under HARNESS_LABEL_WORKING whose owning session died with the host. Skips any
  # issue with a live impl OR bug-lane session, so --recover is safe to run even while the fleet is up
  # — it won't double-dispatch live pool work, nor strip a live bug's label and let the lane rip out
  # the worktree the agent is still editing (#43). Same liveness predicate as the lane's reap (#42).
  echo "  freeing orphaned $HARNESS_LABEL_WORKING (dead-session issues):"
  local freed; freed="$(recover_orphan_working)"
  echo "── recovery done ($freed issue(s) freed) ──"
}

# arg parse: peel off --recover, leave remaining args in $@
DO_RECOVER=0; args=()
for a in "$@"; do
  case "$a" in --recover) DO_RECOVER=1;; *) args+=("$a");; esac
done
set -- ${args[@]+"${args[@]}"}

(( DO_RECOVER )) && recover

echo "Starting Harness delivery fleet — pool of $POOL workers (cap=$CAP) + 1 priority bug lane:"
# Guard against double-start: flock a start-lock so two concurrent `harness start`
# don't double-spawn worker slots (pool.sh checks individual worker pids, but this
# prevents two concurrent start.sh calls from both racing into pool.sh).
START_LOCK="$RUN_DIR/start.lock"
exec 9>"$START_LOCK"
if ! flock -n 9; then
  echo "  (another start is in progress — skipping)"
  exec 9>&-
  exit 0
fi
bash "$ENGINE_DIR/pool.sh"
bash "$ENGINE_DIR/priority.sh"
exec 9>&-

echo
echo "Monitor:  harness/status.sh          Watch a unit: harness/attach.sh <unit> [issue]"
echo "Stop all: harness/stop.sh"

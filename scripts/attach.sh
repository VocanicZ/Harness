#!/usr/bin/env bash
# attach.sh <unit> [issue]  — attach to a unit's live claude session to watch it work.
# No issue -> the orchestration session.  Detach with Ctrl-b d.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

UNIT="${1:-}"; ISSUE="${2:-}"
if [[ -z "$UNIT" ]]; then
  echo "live sessions:"
  tmux ls -F '  #S' 2>/dev/null | grep -E "^  ${HARNESS_SESS_PREFIX}-" || echo "  (none)"
  echo "usage: attach.sh <unit> [issue]"
  exit 0
fi
if [[ -n "$ISSUE" ]]; then
  sess="$(sess_impl "$UNIT" "$ISSUE")"
elif session_live "$UNIT"; then
  # <unit> may name a live session outright (`harness attach hz-main-p41`) — the escape hatch the
  # several-orch-sessions error below points operators at.
  sess="$UNIT"
else
  # Several orch sessions can be live at once (one per PRD). Attach directly when there is exactly
  # one; otherwise list them and let the operator name the session.
  mapfile -t _orch < <(team_sessions "$UNIT" | grep -E -- "-p[0-9]+$" || true)
  if (( ${#_orch[@]} == 1 )); then
    sess="${_orch[0]}"
  elif (( ${#_orch[@]} > 1 )); then
    echo "several orch sessions are live for $UNIT:"; printf '  %s\n' "${_orch[@]}"
    die "name one explicitly: harness attach <session>"
  else
    sess="$(sess_orch "$UNIT")"
  fi
fi
session_live "$sess" || {
  echo "no live session '$sess'"
  tmux ls -F '  #S' 2>/dev/null | grep -E "^  ${HARNESS_SESS_PREFIX}-${UNIT}" || true
  exit 1
}
exec tmux attach -t "$sess"

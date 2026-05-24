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
else
  sess="$(sess_orch "$UNIT")"
fi
session_live "$sess" || {
  echo "no live session '$sess'"
  tmux ls -F '  #S' 2>/dev/null | grep -E "^  ${HARNESS_SESS_PREFIX}-${UNIT}" || true
  exit 1
}
exec tmux attach -t "$sess"

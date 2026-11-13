#!/usr/bin/env bash
# attach.sh <unit> [issue]  — attach to a unit's live claude session to watch it work.
# No issue -> the orchestration session.  Detach with Ctrl-b d.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

UNIT="${1:-}"; ISSUE="${2:-}"
ATTACH_USAGE="usage: attach.sh <unit> [issue]   (harness attach <unit> [issue] | harness attach <session>)"
# #1121: -h/--help print the usage; any other dash-led argument is a usage error (exit 2), never a unit
# name; the issue is a number.
case "$UNIT" in -h|--help) echo "$ATTACH_USAGE"; exit 0;; esac
case "$ISSUE" in -h|--help) echo "$ATTACH_USAGE"; exit 0;; esac
if [[ "$UNIT" == -* ]]; then
  echo "harness attach: unknown option '$UNIT'" >&2; echo "$ATTACH_USAGE" >&2; exit 2
fi
if [[ -n "$ISSUE" && ! "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "harness attach: issue must be a number, got '$ISSUE'" >&2; echo "$ATTACH_USAGE" >&2; exit 2
fi
if [[ -z "$UNIT" ]]; then
  echo "live sessions:"
  sess_list | sed 's/^/  /' | grep -E "^  ${HARNESS_SESS_PREFIX}-" || echo "  (none)"
  echo "$ATTACH_USAGE"
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
    { echo "several orch sessions are live for $UNIT:"; printf '  %s\n' "${_orch[@]}"; } >&2
    die "name one explicitly: harness attach <session>"
  else
    sess="$(sess_orch "$UNIT")"
  fi
fi
session_live "$sess" || {
  # An error: stderr, so `harness attach xx >/dev/null` still shows it and `2>/dev/null` hides it (#1123).
  { echo "no live session '$sess'"
    sess_list | sed 's/^/  /' | grep -E "^  ${HARNESS_SESS_PREFIX}-${UNIT}" || true; } >&2
  exit 1
}
sess_attach "$sess"

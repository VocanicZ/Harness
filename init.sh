#!/usr/bin/env bash
set -uo pipefail
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONFIG="$HARNESS_DIR/config"
ni="${HARNESS_INIT_NONINTERACTIVE:-0}"; [[ -t 0 ]] || ni=1
ask(){ local var="$1" prompt="$2" def="$3" val
  if [[ "$ni" == 1 ]]; then val="${!var:-$def}"; else read -rp "$prompt [$def]: " val; val="${val:-$def}"; fi
  printf -v "$var" '%s' "$val"; }
ask HARNESS_MODE       "Mode (issue-only|prd|planned)"   "${HARNESS_MODE:-issue-only}"
ask HARNESS_TOPOLOGY   "Topology (single|multi)"          "${HARNESS_TOPOLOGY:-single}"
ask HARNESS_OWNER      "GitHub owner/org"                 "${HARNESS_OWNER:-}"
[[ "$HARNESS_TOPOLOGY" == single ]] && ask HARNESS_REPO "Target repo (owner/repo)" "${HARNESS_REPO:-}"
[[ "$HARNESS_MODE" == planned ]] && ask HARNESS_SPEC "Spec path (planned mode)" "${HARNESS_SPEC:-}"
ask HARNESS_AUTONOMOUS "Fully autonomous? (true|false)"   "${HARNESS_AUTONOMOUS:-true}"
ask HARNESS_POOL       "Pool workers"                     "${HARNESS_POOL:-3}"
ask HARNESS_CAP        "Sessions per unit"                "${HARNESS_CAP:-3}"
ask HARNESS_POLL       "Poll interval (s)"                "${HARNESS_POLL:-60}"
ask HARNESS_LABEL_READY "Dispatchable label"              "${HARNESS_LABEL_READY:-ready-for-agent}"
ask HARNESS_LABEL_PRD   "PRD label"                       "${HARNESS_LABEL_PRD:-prd}"
ask HARNESS_AUTHOR_ALLOWLIST "Author allowlist (comma-sep logins; empty=self-only; *=any)" "${HARNESS_AUTHOR_ALLOWLIST:-}"
# Default the 4 label vars not prompted for, so they're written with real values (not empty)
# in non-interactive mode where lib.sh is NOT sourced.
: "${HARNESS_LABEL_WORKING:=agent-working}"
: "${HARNESS_LABEL_BLOCKED:=agent-blocked}"
: "${HARNESS_LABEL_REVIEWED:=reviewed}"
: "${HARNESS_LABEL_COORD:=coordination}"
: "${HARNESS_LABEL_PAUSED:=agent-paused}"
{
  echo "# Harness per-project config — written by 'harness init'."
  echo "# Lines use := so a pre-set environment variable overrides this file."
  for v in HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC HARNESS_AUTONOMOUS \
           HARNESS_POOL HARNESS_CAP HARNESS_POLL HARNESS_LABEL_READY HARNESS_LABEL_PRD \
           HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD \
           HARNESS_LABEL_PAUSED HARNESS_AUTHOR_ALLOWLIST; do
    printf ': "${%s:=%s}"\n' "$v" "${!v:-}"
  done
} > "$CONFIG"
echo "wrote $CONFIG"
if [[ "$ni" != 1 ]]; then
  source "$HARNESS_DIR/lib.sh"
  if [[ "$HARNESS_TOPOLOGY" == single ]]; then seed_if_needed main
  else [[ -f "$TARGETS_TSV" ]] || printf '# id\trepo\tdeps(comma|-)\tdesc\n' > "$TARGETS_TSV"; echo "edit $TARGETS_TSV to list your repos + deps"; fi
fi

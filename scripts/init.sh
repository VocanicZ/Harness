#!/usr/bin/env bash
# init.sh — create a project's per-project STATE only: ./.harness/{config,run/claims,worktrees}.
# NO engine code is placed in the project (#55, PRD #52): the engine is one shared host install and
# `harness` runs it off PATH. STATE_DIR is the project's .harness/; bin/harness sets it to
# $PWD/.harness for `init`. Honors a pre-set STATE_DIR and the legacy HARNESS_DIR (direct invocation
# / vendored layout). ENGINE_DIR (the engine root — the parent of this file's scripts/ dir when run
# directly, #60) is only used to source lib.sh.
set -uo pipefail
ENGINE_DIR="${ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-${HARNESS_DIR:-$PWD/.harness}}"
mkdir -p "$STATE_DIR/run/claims" "$STATE_DIR/worktrees"
CONFIG="$STATE_DIR/config"
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
ask HARNESS_POLL          "Poll interval (s)"             "${HARNESS_POLL:-300}"
ask HARNESS_PRIORITY_POLL "Priority-lane poll interval (s)" "${HARNESS_PRIORITY_POLL:-60}"
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
: "${HARNESS_LABEL_BUG:=bug}"
: "${HARNESS_LABEL_BUG_TRIAGED:=bug-triaged}"
{
  echo "# Harness per-project config — written by 'harness init'."
  echo "# Lines use := so a pre-set environment variable overrides this file."
  for v in HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC HARNESS_AUTONOMOUS \
           HARNESS_POOL HARNESS_CAP HARNESS_POLL HARNESS_PRIORITY_POLL HARNESS_LABEL_READY HARNESS_LABEL_PRD \
           HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD \
           HARNESS_LABEL_PAUSED HARNESS_LABEL_BUG HARNESS_LABEL_BUG_TRIAGED HARNESS_AUTHOR_ALLOWLIST; do
    printf ': "${%s:=%s}"\n' "$v" "${!v:-}"
  done
  # Host-poller opt-in (PRD-B, #74). Empty = today's direct-gh polling (default OFF); set to 1 to
  # have this fleet read shared host snapshots instead. Staged-rollout flag — flip per fleet, then
  # `harness stop && harness start --recover`. See README "Host poller".
  printf ': "${%s:=%s}"\n' HARNESS_USE_POLLER "${HARNESS_USE_POLLER:-}"
} > "$CONFIG"
echo "wrote $CONFIG"
if [[ "$ni" != 1 ]]; then
  source "$ENGINE_DIR/scripts/lib.sh"
  if [[ "$HARNESS_TOPOLOGY" == single ]]; then seed_if_needed main
  else [[ -f "$TARGETS_TSV" ]] || printf '# id\trepo\tdeps(comma|-)\tdesc\n' > "$TARGETS_TSV"; echo "edit $TARGETS_TSV to list your repos + deps"; fi
fi

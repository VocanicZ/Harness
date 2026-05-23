#!/usr/bin/env bash
# setup.sh — config-driven bring-up: verify prerequisites, then seed the configured labels
# on every unit (single = HARNESS_REPO; multi = each targets.tsv row). Idempotent. Does NOT start.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "── Harness setup (mode=$HARNESS_MODE topology=$HARNESS_TOPOLOGY) ──"
command -v tmux   >/dev/null || die "tmux not found — install tmux"
command -v claude >/dev/null || die "claude not found — install Claude Code CLI"
command -v gh     >/dev/null || die "gh not found — install the GitHub CLI"
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"

if [[ "$HARNESS_TOPOLOGY" == single && -z "$HARNESS_REPO" ]]; then
  die "HARNESS_REPO is empty — run 'harness init' first"
fi

n=0
for u in $(all_units); do
  echo "  seeding labels for unit '$u' ($(unit_slug "$u"))"
  seed_if_needed "$u"
  n=$((n+1))
done
echo "── setup done: verified prereqs + seeded $n unit(s). Start the fleet: harness/start.sh ──"

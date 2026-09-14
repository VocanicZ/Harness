#!/usr/bin/env bash
# setup.sh — config-driven bring-up: verify prerequisites, then seed the configured labels
# on every unit (single = HARNESS_REPO; multi = each targets.tsv row). Idempotent. Does NOT start.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "── Harness setup (mode=$HARNESS_MODE topology=$HARNESS_TOPOLOGY cli=${HARNESS_CLI:-claude}) ──"
command -v tmux   >/dev/null || die "tmux not found — install tmux"
if [[ "${HARNESS_CLI:-claude}" == "agy" ]]; then
  command -v agy >/dev/null || die "agy not found — install Antigravity CLI (agy)"
else
  command -v claude >/dev/null || die "claude not found — install Claude Code CLI"
fi
command -v gh     >/dev/null || die "gh not found — install the GitHub CLI"
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"
# rtdd is the lane test loop (prompts/impl.md step 2), not a hard prerequisite — a lane without it
# falls back to two full-suite runs, which is correct but slow. WARN, never die. This check is also
# the backstop for the one upgrade `harness update` cannot fix itself: git replaces update.sh by
# rename, so the update that BRINGS the rtdd install still runs the OLD update.sh, and a host stays
# without rtdd until something says so. This is that something.
command -v rtdd >/dev/null || {
  echo "  ! rtdd not found — lanes will fall back to full-suite runs (slow but correct)."
  echo "    Install it with:  npx -y github:VocanicZ/rtdd     (or: harness update)"
}

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

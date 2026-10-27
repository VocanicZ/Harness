#!/usr/bin/env bash
# setup.sh — config-driven bring-up: verify prerequisites, then seed the configured labels
# on every unit (single = HARNESS_REPO; multi = each targets.tsv row). Idempotent. Does NOT start.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "── Harness setup (mode=$HARNESS_MODE topology=$HARNESS_TOPOLOGY cli=$(cli_name)) ──"
command -v tmux   >/dev/null || die "tmux not found — install tmux"
# #188/#253: the agent CLI's binary and the plugins its lanes need — checked, and what is missing
# installed (cli_prereqs --install). Anything still missing after that is fatal: a lane without its
# goal-loop plugin runs one turn and stops.
prereqs="$(cli_prereqs 2>&1)" || prereqs="$(cli_prereqs --install 2>&1)" || {
  sed 's/^/  /' <<<"$prereqs" >&2
  die "$(cli_name) prerequisites still missing after install — fix the MISSING line(s) above and re-run harness setup"; }
sed 's/^/  /' <<<"$prereqs"
command -v gh     >/dev/null || die "gh not found — install the GitHub CLI"
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"
# rtdd is the lane test loop (prompts/_rtdd.md), not a hard prerequisite — a lane without it runs
# the full suite instead of rtdd's rounds, which is correct but slow. WARN, never die. This check is
# also the backstop for the one upgrade `harness update` cannot fix itself: git replaces update.sh by
# rename, so the update that BRINGS the rtdd install still runs the OLD update.sh, and a host stays
# without rtdd until something says so. This is that something.
if command -v rtdd >/dev/null; then
  rtdd_skill_install   # #187: the lane prompts defer the details to the user-level skill
else
  echo "  ! rtdd not found — lanes will run the full suite instead of rtdd's rounds (slow but correct)."
  echo "    Install it with:  npx -y github:VocanicZ/rtdd     (or: harness update)"
fi

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

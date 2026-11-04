#!/usr/bin/env bash
# setup.sh — config-driven bring-up: verify prerequisites, then seed the configured labels
# on the fleet's repo (HARNESS_REPO). Idempotent. Does NOT start.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "── Harness setup (mode=$HARNESS_MODE cli=$(cli_name)) ──"
for b in $(sess_bins); do command -v "$b" >/dev/null || die "$b not found — install $b"; done
# #188/#253: the agent CLI's binary and the plugins its lanes need — checked, and what is missing
# installed (cli_prereqs --install). Anything still missing after that is fatal: a lane without its
# goal-loop plugin runs one turn and stops.
prereqs="$(cli_prereqs 2>&1)" || prereqs="$(cli_prereqs --install 2>&1)" || {
  sed 's/^/  /' <<<"$prereqs" >&2
  die "$(cli_name) prerequisites still missing after install — fix the MISSING line(s) above and re-run harness setup"; }
sed 's/^/  /' <<<"$prereqs"
skills_heal   # #439: the engine's skills linked into every installed CLI's user-skills dir
command -v gh     >/dev/null || die "gh not found — install the GitHub CLI"
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"
# rtdd is the lane test loop (prompts/_rtdd.md), not a hard prerequisite — a lane without it runs
# the closest tests by hand instead of rtdd's rounds (#449: never the full suite). WARN, never die. This check is
# also the backstop for the one upgrade `harness update` cannot fix itself: git replaces update.sh by
# rename, so the update that BRINGS the rtdd install still runs the OLD update.sh, and a host stays
# without rtdd until something says so. This is that something.
if rtdd_exe >/dev/null; then
  rtdd_skill_install   # #187: the lane prompts defer the details to the user-level skill
else
  echo "  ! rtdd not found — lanes will run the closest tests by hand instead of rtdd's rounds (#449: never the full suite)."
  echo "    Install it with:  npx -y github:VocanicZ/rtdd     (or: harness update)"
fi

if [[ -z "$HARNESS_REPO" ]]; then
  die "HARNESS_REPO is empty — run 'harness init' first"
fi

n=0
for u in $(all_units); do
  echo "  seeding labels for unit '$u' ($(unit_slug "$u"))"
  seed_if_needed "$u"
  n=$((n+1))
done
echo "── setup done: verified prereqs + seeded $n unit(s). Start the fleet: harness/start.sh ──"

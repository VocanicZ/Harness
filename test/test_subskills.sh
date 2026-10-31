#!/usr/bin/env bash
# test_subskills.sh — the per-command thin skills exist, are well-formed, and deploy.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SK="$HERE/../skill"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }

# name -> harness subcommand it must reference
declare -A CMD=(
  [harness-init]=init [harness-start]=start [harness-stop]=stop
  [harness-pause]=pause [harness-resume]=resume [harness-status]=status
  [harness-plan]=plan [harness-prd]=prd [harness-issue]=issue
  [harness-uninstall]=uninstall [harness-one]=one
)
for name in "${!CMD[@]}"; do
  f="$SK/$name/SKILL.md"
  assert "$name SKILL.md exists"          "[[ -f '$f' ]]"
  assert "$name has name: $name"          "head -5 '$f' | grep -qx 'name: $name'"
  assert "$name has description"          "head -8 '$f' | grep -q '^description:'"
  assert "$name runs harness ${CMD[$name]}" "grep -q 'harness ${CMD[$name]}' '$f'"
done

# The three injection skills additionally grill→confirm→run (the human safety gate) and
# document the multi-topology --unit form plus the retired-fleet --recover fallback.
for name in harness-plan harness-prd harness-issue; do
  f="$SK/$name/SKILL.md"
  assert "$name grills before mutating"       "grep -qi 'grill' '$f'"
  assert "$name requires confirmation"        "grep -qi 'confirm' '$f'"
  assert "$name documents the --unit form"    "grep -q -- '--unit' '$f'"
  assert "$name documents --recover fallback" "grep -q -- '--recover' '$f'"
done

# deploy uses the REAL install.sh function (install once, user scope) — not a local cp simulation —
# so this test and `harness install` can never drift apart (#57, PRD #52).
export HARNESS_INSTALL_NOMAIN=1
source "$HERE/../install.sh"
TMP="$(mktemp -d)"; USK="$TMP/.claude/skills"
HARNESS_SKILL_SRC="$SK" HARNESS_USER_SKILLS="$USK" install_harness_skills >/dev/null
assert "deploy keeps umbrella /harness" "[[ -f '$USK/harness/SKILL.md' ]]"
for name in "${!CMD[@]}"; do
  assert "deploy lands /$name" "[[ -f '$USK/$name/SKILL.md' ]]"
done
# #181: harness-arc ships in the repo and deploys WHOLE — its REFERENCE.md and scripts/ beside SKILL.md.
# #230: its status-page.py is gone; §5 links the `harness web` fleet page instead.
# Its old watch.py is folded into `harness supervise`, so it is not shipped and §4 points there.
A="$SK/harness-arc"
assert "harness-arc has name: harness-arc"        "head -5 '$A/SKILL.md' | grep -qx 'name: harness-arc'"
assert "harness-arc §4: the supervisor watches"   "grep -q '^## 4. Watch — the supervisor watches; read its log or alarms' '$A/SKILL.md'"
assert "harness-arc points at supervise --alarms" "grep -q 'harness supervise --alarms' '$A/SKILL.md'"
assert "REFERENCE.md tables the supervisor rules"  "grep -q '^## Supervisor rules, and the failure each was written for' '$A/REFERENCE.md'"
assert "harness-arc ships no watch.py"            "! ls '$A'/scripts/watch.py* 2>/dev/null | grep -q ."
assert "deploy lands harness-arc REFERENCE.md"    "[[ -f '$USK/harness-arc/REFERENCE.md' ]]"
assert "deploy lands an executable preflight.sh"  "[[ -x '$USK/harness-arc/scripts/preflight.sh' ]]"
assert "deploy carries no status-page.py (#230)"  "[[ ! -e '$USK/harness-arc/scripts/status-page.py' ]]"
AGY="$TMP/agy-skills"; mkdir -p "$TMP/home/.gemini"
HOME="$TMP/home" HARNESS_SKILL_SRC="$SK" HARNESS_USER_SKILLS="$USK" HARNESS_AGY_USER_SKILLS="$AGY" install_harness_skills >/dev/null
assert "agy deploy lands harness-arc whole"      "[[ -x '$AGY/harness-arc/scripts/preflight.sh' && -f '$AGY/harness-arc/REFERENCE.md' ]]"
assert "agy deploy carries no status-page.py"     "[[ ! -e '$AGY/harness-arc/scripts/status-page.py' ]]"
assert "preflight.sh still parses"                "bash -n '$A/scripts/preflight.sh'"
rm -rf "$TMP"
echo "── subskills ok"

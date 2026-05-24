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
rm -rf "$TMP"
echo "── subskills ok"

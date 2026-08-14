#!/usr/bin/env bash
# test_readme_docs.sh — the three live-injection shortcuts are documented in README's
# CLI command table AND the per-command shortcut table (PRD #80 required three places;
# the umbrella skill section was the third — see test_subskills.sh). Guards #81.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README="$HERE/../README.md"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }

assert "README exists" "[[ -f '$README' ]]"

# 1. CLI command table — a row per injection subcommand (matched as a command-cell,
#    i.e. opening `| \`<cmd>` so it can't be satisfied by the shortcut table's /harness-* rows).
for cmd in plan prd issue; do
  assert "command table lists \`$cmd\`" "grep -qE '^\| \`$cmd ' '$README'"
done

# 2. Per-command shortcut table — a row per shortcut skill, mapped to its harness subcommand.
for alt in plan prd issue; do
  assert "shortcut table lists /harness-$alt" \
    "grep -qE '^\| \`/harness-$alt\`' '$README'"
  assert "/harness-$alt row maps to \`harness $alt\`" \
    "grep -E '^\| \`/harness-$alt\`' '$README' | grep -q 'harness $alt'"
done

# 3. The shortcut rows describe the human safety gate (grill + crystallized brief / confirm)
#    and the documented flags: --unit (multi-topology) and --recover (retired-fleet fallback).
#    Capture into a var first — piping `grep -q` under `pipefail` would SIGPIPE the upstream grep.
#    (Unquoted RHS + single-quoted pattern keeps the literal backticks out of command substitution.)
INJ_ROWS=$(grep -E '^\| `/harness-(plan|prd|issue)`' "$README")
assert "shortcut rows mention the grill/confirm safety gate" \
  "grep -qiE 'grill|crystallized|confirm' <<<\"\$INJ_ROWS\""
assert "shortcut rows document --unit"    "grep -q -- '--unit' <<<\"\$INJ_ROWS\""
assert "shortcut rows document --recover" "grep -q -- '--recover' <<<\"\$INJ_ROWS\""

# 4. Gauntlet review — config row, its own section, and the honest blindness caveat.
assert "config table lists HARNESS_GAUNTLET_ROUNDS" \
  "grep -qE '^\| \`HARNESS_GAUNTLET_ROUNDS\`' '$README'"
assert "README has a Gauntlet review section" \
  "grep -qE '^### Gauntlet review' '$README'"
assert "README documents the ## Quality bar opt-in" \
  "grep -q '## Quality bar' '$README'"
assert "README is honest that blindness is not a sandbox" \
  "grep -qi 'not a sandbox' '$README'"

# 5. Multi-PRD in `prd` mode — a unit may hold several PRDs, they run in parallel unless a PRD
#    declares `## Blocked by`, children are attributed by `## Parent` (with the `Part of #N`
#    fallback), unparented issues go first without gating a review, and COMPLETE needs every PRD.
assert "README has a multi-PRD section" \
  "grep -qiE '^#+ .*(several|multiple|multi-)PRD|^#+ .*PRDs' '$README'"
assert "README says a unit may hold several PRDs" \
  "grep -qiE 'unit may hold (several|multiple) PRD' '$README'"
assert "README documents PRDs running in parallel" \
  "grep -qi 'parallel' '$README'"
assert "README documents lowest PRD number first with spill" \
  "grep -qiE 'lowest PRD number first' '$README'"
assert "README documents \`## Blocked by\` sequencing between PRDs" \
  "grep -q '## Blocked by' '$README'"
assert "README documents \`## Parent\` attribution" \
  "grep -q '## Parent' '$README'"
assert "README documents the legacy \`Part of #N\` fallback" \
  "grep -q 'Part of #' '$README'"
assert "README documents unparented issues dispatching first" \
  "grep -qiE 'no parent|unparented' '$README'"
assert "README documents COMPLETE needs every PRD closed" \
  "grep -qiE 'only when every PRD is closed' '$README'"

# 6. Fleet prefixes — the config row explains uniqueness-per-host, and a section explains the
#    registry, the refusal, and the doctor escape hatch.
assert "config table row for HARNESS_SESS_PREFIX mentions per-host uniqueness" \
  "grep -E '^\| \`HARNESS_SESS_PREFIX\`' '$README' | grep -qi 'uniqu\|per fleet\|per project'"
assert "README has a Fleet prefixes section" "grep -qiE '^#+ .*[Ff]leet prefix' '$README'"
assert "README documents the fleets registry path" "grep -q '~/.harness/fleets' '$README'"
assert "README documents HARNESS_PREFIX_COLLISION" \
  "grep -qE '^\| \`HARNESS_PREFIX_COLLISION\`' '$README'"
assert "README documents the doctor escape hatch for stale entries" \
  "grep -qi 'doctor --fix' '$README'"

echo "── readme docs ok"

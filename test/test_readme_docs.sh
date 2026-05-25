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

echo "── readme docs ok"

#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../skill/SKILL.md"
README="$HERE/../README.md"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert "skill file exists"        "[[ -f '$S' ]]"
assert "has name frontmatter"     "head -5 '$S' | grep -q '^name:'"
assert "has description"          "head -8 '$S' | grep -q '^description:'"
assert "documents start"          "grep -q 'harness start' '$S'"
assert "documents stop"           "grep -q 'harness stop' '$S'"
assert "documents status"         "grep -q 'harness status' '$S'"
assert "documents pause"  "grep -q 'harness pause' '$S'"
assert "documents resume" "grep -q 'harness resume' '$S'"
assert "documents update" "grep -q 'harness update' '$S'"
assert "documents setup"  "grep -qi 'setup' '$S'"

# #343: harness is one host install run off PATH — the per-project .harness/bin/harness is gone.
assert "no stale .harness/bin/harness paths (#343)" "! grep -q '\.harness/bin/harness' '$S'"

# #343: `/harness <idea>` — from an idea to a running fleet in one conversation.
IDEA="$(awk '/^## On `\/harness <idea>`/{f=1;next} f&&/^## /{exit} f' "$S")"
assert "has an \`/harness <idea>\` section (#343)" "[[ -n \"\$IDEA\" ]]"
assert "description mentions the idea flow (#343)" "head -8 '$S' | grep '^description:' | grep -q '/harness <idea>'"
assert "plain /harness keeps today's behaviour (#343)" \
  "grep -qiE 'plain \`/harness\`.*(no text|today|unchanged)|no text.*plain \`/harness\`' '$S'"
assert "idea flow: installs harness when not on PATH via npx (#343)" \
  "grep -q 'npx -y github:VocanicZ/Harness' <<<\"\$IDEA\" && grep -qi 'not on PATH' <<<\"\$IDEA\""
assert "idea flow: curl fallback install line (#343)" \
  "grep -q 'curl -fsSL https://raw.githubusercontent.com/VocanicZ/Harness/main/install.sh | bash' <<<\"\$IDEA\""
assert "idea flow: relays the installer's questions (#343)" "grep -qi 'relay' <<<\"\$IDEA\""
assert "idea flow: no config -> harness init in prd mode (#343)" \
  "grep -q 'harness init' <<<\"\$IDEA\" && grep -qE 'HARNESS_MODE=prd|\`prd\` mode' <<<\"\$IDEA\""
assert "idea flow: asks the user to run \`! harness init\` for a terminal (#343)" \
  "grep -q '! harness init' <<<\"\$IDEA\""
assert "idea flow: grills goal, scope and acceptance criteria (#343)" \
  "grep -qi 'grill' <<<\"\$IDEA\" && grep -qi 'goal' <<<\"\$IDEA\" && grep -qi 'scope' <<<\"\$IDEA\" && grep -qi 'acceptance criteria' <<<\"\$IDEA\""
assert "idea flow: files ONE prd-labelled issue in the to-prd structure (#343)" \
  "grep -qi 'one \`prd\`-labelled issue' <<<\"\$IDEA\" && grep -q 'to-prd' <<<\"\$IDEA\" && grep -q '## Acceptance criteria' <<<\"\$IDEA\""
assert "idea flow: not running -> harness setup + harness start (#343)" \
  "grep -q 'harness setup' <<<\"\$IDEA\" && grep -q 'harness start' <<<\"\$IDEA\""
assert "idea flow: live fleet -> /harness-prd, not filed by hand (#343)" \
  "grep -qiE 'running.*\`/harness-prd\`' <<<\"\$IDEA\" && grep -qi 'by hand' <<<\"\$IDEA\""
assert "idea flow: tells the user where to watch (#343)" \
  "grep -q 'harness status --watch' <<<\"\$IDEA\" && grep -q 'harness web' <<<\"\$IDEA\""
# Every outward step is a confirmation point: install, init, filing the PRD, start.
n_confirm="$(grep -c '\*\*Confirm' <<<"$IDEA")"
assert "idea flow: marks its confirmation points (install, init, PRD, start) (#343)" "(( n_confirm >= 4 ))"

# #343: README Quick start shows `/harness <idea>` as the one step.
QS="$(awk '/^## Quick start/{f=1;next} f&&/^## /{exit} f' "$README")"
assert "README Quick start shows \`/harness <idea>\` (#343)" "grep -qE '^> \`?/harness <' <<<\"\$QS\""
echo "── skill ok"

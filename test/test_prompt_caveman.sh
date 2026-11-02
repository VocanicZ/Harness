#!/usr/bin/env bash
# test_prompt_caveman.sh — #377: every session prompt invokes caveman at session start, scoped.
# A session prompt is any prompts/<name>.md not starting with `_`; a `_part.md` is a partial
# ({{> _part.md}}) that renders only inside a session prompt, so it inherits that prompt's caveman.
# The prompts are enumerated, not listed: a new prompt without caveman fails here.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"

TESTS_RUN=0; TESTS_FAIL=0
assert(){ TESTS_RUN=$((TESTS_RUN+1))
  if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }

P="$HERE/../prompts"
mapfile -t SESSION < <(cd "$P" && ls [!_]*.md)
assert "found the session prompts" "[[ \${#SESSION[@]} -ge 9 ]]"

# Carve-outs every session prompt must carry, as rendered (grep -F, case-insensitive).
CARVE=(
  "agent-to-agent comments"          # caveman's scope: the session's own output + handoffs/findings/notes
  "handoffs, review findings, checkpoint notes"
  "human-facing artifacts stay plain prose"
  "PRD and issue bodies"
  "PR titles and descriptions"
  "docs, README"
  "commit messages"
  "exact strings are never compressed"
  "code, commands, errors"
  "label names"
  "issue and PR refs"
)

for p in "${SESSION[@]}"; do
  out="$(render "$P/$p")"
  inv="$(cli_skill caveman) skill"
  assert "$p: renders the caveman skill invocation ($inv)" "grep -qF -- \"\$inv\" <<<\"\$out\""
  assert "$p: no unrendered {{skill:caveman}} / {{> _caveman.md}}" \
    "! grep -qE '\{\{skill:caveman\}\}|\{\{> *_caveman' <<<\"\$out\""
  # At session start: before the first GOAL / Steps / RECOVER instruction.
  first_task="$(grep -nE '^(GOAL|Steps:|A previous agent)' <<<"$out" | head -1 | cut -d: -f1)"
  inv_line="$(grep -nF -- "$inv" <<<"$out" | head -1 | cut -d: -f1)"
  assert "$p: caveman is invoked before the task begins" \
    "[[ -n \"\$inv_line\" && -n \"\$first_task\" && \$inv_line -lt \$first_task ]]"
  assert "$p: caveman invoked once" "[[ \$(grep -cF -- \"\$inv\" <<<\"\$out\") -eq 1 ]]"
  for c in "${CARVE[@]}"; do
    assert "$p: carries carve-out '$c'" "grep -qiF -- \"\$c\" <<<\"\$out\""
  done
done

# Every CLI that renders the prompts checks caveman as a prompt skill (#315's prompt-skills-installed),
# and renders it its own way in every session prompt.
for cli in $(cli_list); do
  ( cli_load "$cli" || exit 1
    assert "$cli: cli_prompt_skills lists caveman" "cli_prompt_skills | grep -qx caveman"
    h="$(mktemp -d)"
    out="$(HOME="$h" HARNESS_USER_SKILLS="$h/skills" cli_prereqs 2>&1)"
    assert "$cli: harness setup checks the caveman skill" "grep -qE '^(MISSING|ok) +$cli skill caveman ' <<<\"\$out\""
    inv="$(cli_skill caveman) skill"
    for p in "${SESSION[@]}"; do
      assert "$cli: $p renders caveman as $cli invokes a skill" "render \"$P/$p\" | grep -qF -- \"\$inv\""
    done
    rm -rf "$h"
    exit $TESTS_FAIL ) || TESTS_FAIL=$((TESTS_FAIL+1))
done

echo "$TESTS_RUN run (top level), $TESTS_FAIL failed"
[[ $TESTS_FAIL -eq 0 ]]

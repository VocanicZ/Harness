#!/usr/bin/env bash
# test_prompt_caveman.sh — #377/#617: every session prompt carries the caveman rules inline (no skill invocation), scoped.
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

# Carve-outs plus the inlined rules: the rules ride in the prompt itself (#617), so a lane spends no turn
# invoking the skill, and `caveman` is no longer a skill the prompts name.
INLINE=("drop articles" "fragments are fine" "arrows for" "Technical terms stay exact")
for p in "${SESSION[@]}"; do
  out="$(render "$P/$p")"
  assert "$p: no caveman skill invocation" "! grep -qi 'caveman skill' <<<\"\$out\""
  assert "$p: no unrendered {{skill:caveman}} / {{> _caveman.md}}" \
    "! grep -qE '\{\{skill:caveman\}\}|\{\{> *_caveman' <<<\"\$out\""
  # At session start: before the first GOAL / Steps / RECOVER instruction.
  first_task="$(grep -nE '^(GOAL|Steps:|A previous agent)' <<<"$out" | head -1 | cut -d: -f1)"
  inv_line="$(grep -nF -- "OUTPUT STYLE" <<<"$out" | head -1 | cut -d: -f1)"
  assert "$p: the caveman rules come before the task begins" \
    "[[ -n \"\$inv_line\" && -n \"\$first_task\" && \$inv_line -lt \$first_task ]]"
  assert "$p: the caveman rules appear once" "[[ \$(grep -cF -- 'OUTPUT STYLE' <<<\"\$out\") -eq 1 ]]"
  for c in "${INLINE[@]}" "${CARVE[@]}"; do
    assert "$p: carries '$c'" "grep -qiF -- \"\$c\" <<<\"\$out\""
  done
done

assert "no prompt names the caveman skill" "! grep -rqF '{{skill:caveman}}' \"$P\""
# No CLI treats caveman as a prompt skill any more: nothing to check or install for it.
for cli in $(cli_list); do
  ( cli_load "$cli" || exit 1
    assert "$cli: cli_prompt_skills no longer lists caveman" "! cli_prompt_skills | grep -qx caveman"
    exit $TESTS_FAIL ) || TESTS_FAIL=$((TESTS_FAIL+1))
done

echo "$TESTS_RUN run (top level), $TESTS_FAIL failed"
[[ $TESTS_FAIL -eq 0 ]]

#!/usr/bin/env bash
# test_prompt_scope_grouping.sh — #1143: the PRD review groups findings by rtdd scope (one issue per overlapping test
# set, a `## Scope` section on every filed issue, one checkbox per finding, a big finding stands alone), and the
# implementer sizes the work after reading the issue (big = 2+ disjoint scope groups, >8 files, >6 checkboxes: one
# sub-agent per scope group holding only its own scope). Prompts are grepped as rendered text (newlines folded).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
flat(){ tr '\n' ' ' | tr -s ' '; }

RV="$(render "$P/review.md" PROJECT=w DESC=d SLUG=acme/widget PRD=7 PROMISE="REVIEW DONE" LABEL_READY=ready-for-agent \
  LABEL_REVIEWED=prd-reviewed | flat)"
IM="$(render "$P/impl.md" ISSUE=5 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused \
  LABEL_READY=ready-for-agent PROMISE="ISSUE 5 DONE" | flat)"

echo "-- review.md: group by rtdd scope"
assert_ok "one issue per finding is gone" bash -c '! grep -qF "File one issue per finding" <<<"$1"' _ "$RV"
assert_ok "names the grouping rule" grep -qF 'GROUPING FINDINGS INTO ISSUES' <<<"$RV"
assert_ok "runs rtdd explain per source file" grep -qF 'run `rtdd explain <file>` to get the tests that cover them' <<<"$RV"
assert_ok "overlapping test sets share one issue" \
  grep -qF 'Findings whose test sets largely overlap go into ONE issue' <<<"$RV"
assert_ok "small separate test sets stay separate" grep -qF 'with small, separate test sets stay separate small issues' <<<"$RV"
assert_ok "applies to phase 1, 2b, phase 2 and phase 3" \
  grep -qF 'phase 1 criteria gaps, step 2b I/O findings, phase 2 security findings and the phase 3 gauntlet gap' <<<"$RV"

echo "-- review.md: big-finding exception"
assert_ok "a big finding is always its own issue" grep -qF 'A BIG finding is always its own issue' <<<"$RV"
assert_ok "big = own design, several subsystems, or more than one lane" \
  grep -qF 'needs its own design, spans several subsystems, or is more than one lane' <<<"$RV"

echo "-- review.md: ## Scope on every filed issue"
assert_ok "every issue gets a Scope section" grep -qF 'EVERY issue you file gets a `## Scope` section' <<<"$RV"
assert_ok "scope lists files to read and tests to run from rtdd" \
  grep -qF 'lists the files to read and the test files to run, both taken from rtdd' <<<"$RV"
assert_ok "2b points at the Scope section" grep -qF 'a `## Scope` section on each issue' <<<"$RV"
assert_ok "phase 2 issues carry a Scope section" grep -qF 'Each issue has a `## Scope` section' <<<"$RV"
assert_ok "phase 3 gap carries a Scope section" grep -qF 'It carries a `## Scope` section' <<<"$RV"
assert_ok "step 3 gaps carry a Scope section" grep -qF 'one checkbox per gap and a `## Scope` section' <<<"$RV"

echo "-- review.md: one checkbox per finding, still filed before sign-off"
assert_ok "one checkbox per finding" grep -qF 'one checkbox per finding' <<<"$RV"
assert_ok "checkbox gives command or repro, expected vs actual" \
  grep -qF 'the exact command or repro, plus expected vs actual' <<<"$RV"
assert_ok "never sign off over an unfiled finding (#600)" \
  grep -qF 'never sign off in step 6 over an unfiled finding (#600)' <<<"$RV"
assert_ok "PRD comment maps each finding to its issue" grep -qF 'The PRD comment maps each finding to its issue' <<<"$RV"
assert_ok "the #600 sign-off rule from step 2b still holds" \
  grep -qF 'never sign off in step 6 over a finding you did not file' <<<"$RV"

echo "-- review.md: worked example, 10 findings -> 4 issues"
assert_ok "10 findings become 4 issues" grep -qF '10 findings become 4 issues' <<<"$RV"
assert_ok "three in one subsystem with shared tests" grep -qF 'Three findings sit in one subsystem with shared tests' <<<"$RV"
assert_ok "four in a.py" grep -qF 'Four are in `a.py`' <<<"$RV"
assert_ok "two in c.py and d.py sharing tests" grep -qF 'Two are in `c.py` and `d.py` and share tests' <<<"$RV"
assert_ok "one big, alone" grep -qF 'One is big' <<<"$RV"

echo "-- impl.md: size the work after reading the issue"
assert_ok "old vague wording is gone" bash -c '! grep -qF "sizeable / multi-subtask" <<<"$1"' _ "$IM"
assert_ok "reads ## Scope first, starts from those files only" \
  grep -qF "Read its \`## Scope\` first and start from those files only" <<<"$IM"
assert_ok "big when 2+ scope groups with disjoint files" \
  grep -qF 'two or more scope groups with disjoint files' <<<"$IM"
assert_ok "big when more than 8 files in scope" grep -qF 'more than 8 files in scope' <<<"$IM"
assert_ok "big when more than 6 checkboxes" grep -qF 'more than 6 checkboxes' <<<"$IM"
assert_ok "otherwise small" grep -qF 'Otherwise SMALL' <<<"$IM"
assert_ok "small: do the work directly" grep -qF 'SMALL: do the work yourself, directly' <<<"$IM"
assert_ok "big: one sub-agent per scope group" grep -qF 'start ONE sub-agent per scope group' <<<"$IM"
assert_ok "each brief holds only its own files, tests and checkboxes" \
  grep -qF "its brief holding only its own files, tests and checkboxes" <<<"$IM"
assert_ok "lane does not read those files itself" grep -qF 'Do NOT read those files yourself' <<<"$IM"
assert_ok "integrates, runs rtdd rounds once, one PR" \
  grep -qF 'run the rtdd rounds ONCE and open ONE PR' <<<"$IM"
assert_ok "still points at the subagent-task-tree skill" grep -qF 'subagent-task-tree' <<<"$IM"
finish

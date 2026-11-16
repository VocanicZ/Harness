#!/usr/bin/env bash
# test_prompt_scope_grouping.sh — #1143, reshaped by #1183: the PRD review files AT MOST ONE issue per round (every finding a
# checkbox in it, a `## Scope` section from rtdd, the findings fed through scripts/review_findings.py, non-blocking findings
# below the tier direct limits kept as notes), and the
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

echo "-- review.md: one issue per review round (#1183)"
assert_ok "one issue per finding is gone" bash -c '! grep -qF "File one issue per finding" <<<"$1"' _ "$RV"
assert_ok "the old grouping rules are gone" bash -c '! grep -qF "GROUPING FINDINGS INTO ISSUES" <<<"$1" && ! grep -qF "Findings whose test sets largely overlap" <<<"$1" && ! grep -qF "10 findings become 4 issues" <<<"$1"' _ "$RV"
assert_ok "names the one-issue rule" grep -qF 'ONE ISSUE PER REVIEW ROUND' <<<"$RV"
assert_ok "a pass files AT MOST ONE issue" grep -qF 'a pass files AT MOST ONE `ready-for-agent` issue, however many findings it holds' <<<"$RV"
assert_ok "gives the cost reason" grep -qF 'costs about $0.31 and 2.4 minutes' <<<"$RV"
assert_ok "applies to phase 1, 2b, phase 2 and phase 3" \
  grep -qF 'phase 1 criteria gaps, step 2b I/O findings, phase 2 security findings and the phase 3 gauntlet gap' <<<"$RV"
assert_ok "no gh issue create by hand" grep -qF 'You never run `gh issue create` for a finding yourself' <<<"$RV"

echo "-- review.md: findings go through the helper"
assert_ok "one findings file for the whole pass" grep -qF 'Make ONE findings file' <<<"$RV"
assert_ok "findings carry a severity, blocking or non-blocking" grep -qF '`blocking` = the PRD must not be signed off over it' <<<"$RV"
assert_ok "a finding with no severity is blocking" grep -qF 'A finding with no `severity` counts as blocking' <<<"$RV"
assert_ok "runs rtdd explain per source file for files and tests" \
  grep -qF 'run `rtdd explain <file>` to get the tests that cover them' <<<"$RV"
assert_ok "the helper files it, with the rendered placeholder left for drive.sh" grep -qF '{{REVIEW_FINDINGS}} file --prd 7 -R acme/widget --label ready-for-agent --input "$F"' <<<"$RV"
assert_ok "files exactly what it returns" grep -qF 'File exactly what it returns' <<<"$RV"
assert_ok "a null issue is on purpose, notes go in the PRD comment" \
  grep -qF '`issue` is null: nothing was filed, on purpose' <<<"$RV"
assert_ok "below the tier direct limits non-blocking findings are notes" \
  grep -qF 'fit the tier'"'"'s `direct`' <<<"$RV"
assert_ok "above the limits they are in the issue" grep -qF 'Non-blocking findings ABOVE those limits are in the issue instead' <<<"$RV"
assert_ok "files once, at the end of the pass" grep -qF 'FILE ONCE, at the end of the pass' <<<"$RV"
assert_ok "step 2b only collects" grep -qF 'step 2b only collects' <<<"$RV"
assert_ok "sign-off files whatever is still unfiled first" grep -qF 'if the findings file holds anything not yet filed, file the pass with' <<<"$RV"

echo "-- review.md: ## Scope and the trailer on the one issue"
assert_ok "body holds a Scope section, the union of files and tests" \
  grep -qF 'a `## Scope` section (the union of the files and tests)' <<<"$RV"
assert_ok "2b points at the one Scope" grep -qF 'one `## Scope`' <<<"$RV"
assert_ok "phase 2 findings are blocking checkboxes in the one issue" grep -qF 'is a `blocking` finding' <<<"$RV"
assert_ok "phase 3 gap is one blocking finding" grep -qF 'ONE `blocking` finding' <<<"$RV"
assert_ok "step 3 gaps are blocking and filed through the helper" grep -qF 'an unmet criterion is `blocking`' <<<"$RV"
assert_ok "the security marker still comes first" grep -qF -- '--body "<!-- harness-security-audit round=' <<<"$RV"
assert_ok "the gauntlet marker still comes first" grep -qF -- '--body "<!-- harness-gauntlet round=' <<<"$RV"

echo "-- review.md: blocking findings stay mandatory (#600)"
assert_ok "checkbox gives command or repro, expected vs actual" \
  grep -qF 'one `- [ ]` per finding with its repro and expected vs actual' <<<"$RV"
assert_ok "never sign off over an unfiled blocking finding (#600)" \
  grep -qF 'Never sign off over an unfiled blocking finding (#600)' <<<"$RV"
assert_ok "PRD comment maps each finding to the issue and the notes" grep -qF 'the PRD comment maps each finding to it' <<<"$RV"
assert_ok "the #600 sign-off rule from step 2b still holds" \
  grep -qF 'never sign off in step 6 over a finding you did not file' <<<"$RV"
assert_ok "a big finding is a checkbox, not its own issue" grep -qF 'is a checkbox like the rest, not an issue of its own' <<<"$RV"

echo "-- review.md: the rendered placeholder runs the real helper (drive.sh passes it)"
assert_ok "drive.sh renders REVIEW_FINDINGS for the review prompt" grep -qF 'REVIEW_FINDINGS="$(review_findings_cmd)"' "$HERE/../scripts/drive.sh"
RVC="$(review_findings_cmd)"
RR="$(render "$P/review.md" PROJECT=w DESC=d SLUG=acme/widget PRD=7 PROMISE=x LABEL_READY=ready-for-agent REVIEW_FINDINGS="$RVC" | flat)"
assert_ok "the rendered prompt names the helper's path, no placeholder left" bash -c '[[ "$1" == *"scripts/review_findings.py file --prd 7 -R acme/widget"* && "$1" != *"{{REVIEW_FINDINGS}}"* ]]' _ "$RR"
printf '%s' '[{"severity":"blocking","title":"a","files":["x/a.py"]},{"severity":"non-blocking","title":"b"},{"title":"c"},{"severity":"blocking","title":"d"},{"severity":"non-blocking","title":"e"}]' > "$T/f.json"
out="$(eval "$RVC plan --prd 7 --input \"\$T/f.json\"")"
assert_eq "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["counts"]["blocking"], d["counts"]["in_issue"], d["counts"]["in_notes"], d["issue"].count("- [ ] "))' "$out")" "3 3 2 3" \
  "5 findings through the rendered command: one issue with the 3 blocking checkboxes, 2 notes"

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

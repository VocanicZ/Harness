#!/usr/bin/env bash
# test_prompt_review_probe.sh — #600 (PRD #587): the PRD review acts on what it finds. review.md judges against the
# original brief/spec when the repo holds one, files a follow-up issue for EVERY user-visible I/O finding whatever its
# severity, and has the probe sub-agent always run a fixed robustness checklist (CLI list below; an interface-appropriate
# one otherwise). Prompts are grepped as rendered text (newlines folded) — their bodies carry backticks.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
flat(){ tr '\n' ' ' | tr -s ' '; }
pos_of(){ local pre="${2%%"$1"*}"; [[ "$2" == *"$1"* ]] && echo "${#pre}" || echo 999999999; }

R="$(render "$P/review.md" PROJECT=w DESC=d SLUG=acme/widget PRD=7 PROMISE="REVIEW DONE" LABEL_READY=ready-for-agent \
  LABEL_REVIEWED=prd-reviewed | flat)"

echo "-- judge against the original brief"
assert_ok "finds the original brief or spec when one exists" grep -qF 'JUDGE AGAINST THE ORIGINAL BRIEF' <<<"$R"
assert_ok "names brief.md and HARNESS_SPEC" grep -qF '`brief.md`, `HARNESS_SPEC`' <<<"$R"
assert_ok "judges against the brief as well as the PRD" grep -qF 'AS WELL AS against the PRD' <<<"$R"
assert_ok "the brief wins a disagreement" grep -qF 'the brief wins' <<<"$R"

echo "-- every user-visible I/O finding becomes an issue"
assert_ok "rule present" grep -qF 'FILE EVERY USER-VISIBLE I/O FINDING' <<<"$R"
assert_ok "whatever its weight: an I/O defect is blocking" grep -qF 'is `blocking` whatever its weight' <<<"$R"
assert_ok "before sign-off" grep -qF 'BEFORE sign-off' <<<"$R"
assert_ok "'consistent with the PRD' is no excuse" grep -qF '"consistent with the PRD"' <<<"$R"
assert_ok "the filed issue carries the Blocked by + Parent trailer" \
  grep -qF '`## Blocked by` + `## Parent` trailer written by' <<<"$R"
assert_ok "never sign off over an unfiled finding" grep -qF 'never sign off in step 6 over a finding you did not file' <<<"$R"

echo "-- the probe runs a fixed robustness checklist"
assert_ok "the probe ALWAYS runs it" grep -qF 'it ALWAYS runs a fixed robustness checklist' <<<"$R"
assert_ok "CLI: dash-leading positional and option values" \
  grep -qF 'a value starting with a dash, both positional and as an option value' <<<"$R"
assert_ok "CLI: output piped into head -1" grep -qF 'output piped into `head -1`' <<<"$R"
assert_ok "CLI: UTF-8 BOM" grep -qF 'a UTF-8 BOM at the start of the input' <<<"$R"
assert_ok "CLI: CRLF and lone CR" grep -qF 'CRLF and lone-CR line endings' <<<"$R"
assert_ok "CLI: form feed and U+2028 in a field" grep -qF 'a form feed (U+000C) and U+2028 inside a field' <<<"$R"
assert_ok "other interfaces get an interface-appropriate checklist" \
  grep -qF 'write the equivalent checklist for THAT interface' <<<"$R"
assert_ok "CLI: a dash-led value where a number or text is expected" grep -qF 'including where a number or free text is expected' <<<"$R"
assert_ok "CLI: empty option value" grep -qF 'an empty option value' <<<"$R"
assert_ok "CLI: 5000-digit number" grep -qF 'a number of 5000 digits' <<<"$R"
assert_ok "CLI: stdout that cannot be written" grep -qF 'stdout that cannot be written' <<<"$R"

echo "-- #1239: the reviewer runs the probe itself unless the project is big AND the suite slow"
assert_ok "the reviewer runs it itself" grep -qF 'So you run it YOURSELF, in this session, after the suite' <<<"$R"
assert_ok "sub-agent only when both hold" grep -qF 'Use a sub-agent only when BOTH hold' <<<"$R"
assert_ok "size bar is 3000 source lines" grep -qF 'over 3000 lines' <<<"$R"
assert_ok "slow-suite bar is 2 minutes" grep -qF 'takes over 2 minutes' <<<"$R"
inline="$(pos_of 'So you run it YOURSELF' "$R")"; probe="$(pos_of 'THE PROBE: it ALWAYS' "$R")"
assert_ok "the who-runs-it rule (@$inline) comes before the checklist (@$probe)" test "$inline" -lt "$probe"

assert_ok "the reviewer's own pass includes the spec-literal check" grep -qF 'go through the original request sentence by sentence' <<<"$R"
assert_ok "a rule with no passing check is a finding" grep -qF 'a rule you cannot trace to a passing check is a finding' <<<"$R"

echo "-- #1239: the implementer lane runs the same checklist before it commits"
I="$(render "$P/impl.md" ISSUE=5 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused \
  LABEL_READY=ready-for-agent PROMISE="ISSUE 5 DONE" | flat)"
assert_ok "impl has the robustness pass" grep -qF 'ROBUSTNESS PASS' <<<"$I"
assert_ok "impl runs the review's probe checklist" grep -qF "run the PRD review's probe yourself, once" <<<"$I"
assert_ok "impl checklist has the 5000-digit number and /dev/full" grep -qF 'a 5000-digit number, stdout that cannot be written' <<<"$I"
assert_ok "impl fixes defects in the same lane with a test" grep -qF 'Fix every defect it shows in THIS lane and add a test for it' <<<"$I"
assert_ok "impl pass is only for a user-visible interface" grep -qF 'only when your change alters something a user feeds in or sees come out' <<<"$I"
assert_ok "impl: a dash-led value where a number is expected is that value, not an unknown option" grep -qF 'never the parser'"'"'s unknown-option error' <<<"$I"
assert_ok "impl checks every concrete rule of the request has a test" grep -qF 'every concrete rule in it (sort order, numeric against text' <<<"$I"
assert_ok "impl checklist has the closed pipe" grep -qF 'output piped into `head -1`' <<<"$I"
a="$(pos_of 'ROBUSTNESS PASS' "$I")"; b="$(pos_of 'Never delete, skip, or weaken a test' "$I")"
assert_ok "the pass (@$a) comes before the never-weaken rule and the commit (@$b)" test "$a" -lt "$b"
finish

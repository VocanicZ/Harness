#!/usr/bin/env bash
# test_prompt_gate_bug.sh — #1211: 26 `release gate failed at …` issues since 2026-10-29, each fixed for its own symptom only. The prompts a gate
# bug goes through now close its class: bug-triage.md writes the rule into the refined acceptance, bug-fix.md makes the fix put the failing check in
# the guard set (or say why a lane-level run could not catch it), and _rtdd.md has every lane paste the `guard set: …` result line into its PR body.
# Prompts are grepped as rendered text (newlines folded) — their bodies carry backticks.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
flat(){ tr '\n' ' ' | tr -s ' '; }
args=(ISSUE=5 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused LABEL_BUG_TRIAGED=bug-triaged LABEL_BUG=bug PROMISE="BUG 5 fix DONE")

echo "-- bug-fix.md, rendered"
R="$(render "$P/bug-fix.md" "${args[@]}" | flat)"
assert_ok "names the gate-bug rule" grep -qF 'GATE BUGS' <<<"$R"
assert_ok "keyed on the title prefix" grep -qF 'titled `release gate failed at …`' <<<"$R"
assert_ok "(a) the failing assertion or its static check goes in the guard set" \
  grep -qF 'put the failing assertion, or the static check that would have caught it, in the guard set' <<<"$R"
assert_ok "(b) or the PR body says why a lane-level run could not have caught it" \
  grep -qF 'say in the PR body why a lane-level run could not have caught it' <<<"$R"
assert_ok "a fix that only removes the symptom is not done" grep -qF 'A fix that only removes the symptom is not done' <<<"$R"
assert_ok "the guard-set result line goes in the PR body" grep -qF 'Copy its last line (`guard set: N files, Ns, green|RED`) into your PR body' <<<"$R"

echo "-- bug-triage.md, rendered"
R="$(render "$P/bug-triage.md" "${args[@]}" | flat)"
assert_ok "triage writes the rule into the refined acceptance" \
  grep -qF 'A title starting `release gate failed at` adds: the fix puts the failing assertion' <<<"$R"
assert_ok "...naming the guard set and the PR-body alternative" \
  grep -qF 'in the guard set (`test/guards.sh`, `# rtdd: always`), or its PR body says why a lane-level run could not have caught it' <<<"$R"

echo "-- _rtdd.md, in every lane prompt that includes it"
for p in impl bug-fix resume; do
  R="$(render "$P/$p.md" "${args[@]}" LABEL_READY=ready-for-agent | flat)"
  assert_ok "$p.md: the lane copies the guard set's result line into its PR body" \
    grep -qF 'Copy its last line (`guard set: N files, Ns, green|RED`) into your PR body' <<<"$R"
done
assert_ok "test/guards.sh really prints that line" grep -qF 'echo "guard set: ${#files[@]} files,' "$HERE/guards.sh"
finish

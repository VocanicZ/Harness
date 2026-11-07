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

R="$(render "$P/review.md" PROJECT=w DESC=d SLUG=acme/widget PRD=7 PROMISE="REVIEW DONE" LABEL_READY=ready-for-agent \
  LABEL_REVIEWED=prd-reviewed | flat)"

echo "-- judge against the original brief"
assert_ok "finds the original brief or spec when one exists" grep -qF 'JUDGE AGAINST THE ORIGINAL BRIEF' <<<"$R"
assert_ok "names brief.md and HARNESS_SPEC" grep -qF '`brief.md`, `HARNESS_SPEC`' <<<"$R"
assert_ok "judges against the brief as well as the PRD" grep -qF 'AS WELL AS against the PRD' <<<"$R"
assert_ok "the brief wins a disagreement" grep -qF 'the brief wins' <<<"$R"

echo "-- every user-visible I/O finding becomes an issue"
assert_ok "rule present" grep -qF 'FILE EVERY USER-VISIBLE I/O FINDING' <<<"$R"
assert_ok "whatever its severity" grep -qF 'whatever its severity' <<<"$R"
assert_ok "before sign-off" grep -qF 'BEFORE sign-off' <<<"$R"
assert_ok "'consistent with the PRD' is no excuse" grep -qF '"consistent with the PRD"' <<<"$R"
assert_ok "filed issues carry the Blocked by + Parent trailer" \
  grep -qF 'with the `## Blocked by` + `## Parent` trailer from FILING A GAP ISSUE above' <<<"$R"
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
finish

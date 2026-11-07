#!/usr/bin/env bash
# test_prompt_known_gap.sh — #599 (PRD #587): the implementer treats a known gap as a failed gate. In bench
# run-20261106 an implementer wrote "Known gap: …" only in chat, merged and promised anyway. impl.md, as rendered,
# says: fix the gap, or file it under the _followup.md rules and link it in the PR body; never promise over an
# unfixed, unfiled gap. Prompts are grepped as rendered text (newlines folded) — their bodies carry backticks.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
flat(){ tr '\n' ' ' | tr -s ' '; }

echo "-- impl.md known-gap gate, rendered"
R="$(render "$P/impl.md" ISSUE=5 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused \
  LABEL_READY=ready-for-agent PROMISE="ISSUE 5 DONE" | flat)"
assert_ok "names the KNOWN-GAP GATE" grep -qF 'KNOWN-GAP GATE' <<<"$R"
assert_ok "a known gap against the criteria or the brief is a failed gate" \
  grep -qF "a known gap against this issue's acceptance criteria or the brief is a FAILED gate" <<<"$R"
assert_ok "a gap written only in chat is still a failed gate" \
  grep -qF 'even if only written in your chat output' <<<"$R"
assert_ok "fix it" grep -qF 'Either FIX it on this branch' <<<"$R"
assert_ok "or file it under the _followup.md rules" grep -qF 'FILE it as a follow-up under the FILING A FOLLOW-UP rules' <<<"$R"
assert_ok "and link it in the PR body" grep -qF 'LINK that issue in the PR body' <<<"$R"
assert_ok "never merge or promise over an unfixed, unfiled gap" \
  grep -qF 'Never merge, and never output the promise, over a gap that is neither fixed nor filed' <<<"$R"
assert_ok "the rule sits in the promise paragraph, before the exact promise line" \
  grep -qF 'neither fixed nor filed. When it holds, output exactly: <promise>ISSUE 5 DONE</promise>' <<<"$R"
assert_ok "the follow-up rules it points to are still included" grep -qF 'FILING A FOLLOW-UP' <<<"$R"
finish

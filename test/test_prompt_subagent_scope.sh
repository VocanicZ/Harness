#!/usr/bin/env bash
# test_prompt_subagent_scope.sh — #1252: lanes and their sub-agents grew context without bound (0 compactions, up to 804k), every call
# re-reading it from cache. The impl, resume, bug-fix and review prompts, as rendered, carry the SUB-AGENT SCOPE rule
# (the second half of prompts/_long_waits.md, one line: the rendered prompts have a line budget, test_rtdd.sh): the engine's context budget, one bounded task per sub-agent, no whole-repo reads, a short summary
# back, a merge sub-agent resolves only the files it is given.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
flat(){ tr '\n' ' ' | tr -s ' '; }
RULES=(
  'SUB-AGENT SCOPE (#1252)'
  'The engine sets a context budget (`HARNESS_LANE_CONTEXT_MAX`, default 200k)'
  'compacts a lane and each of its sub-agents when it reaches it'
  'A sub-agent is ONE bounded task'
  'It never reads the whole repo'
  'It hands back a SUMMARY of at most 30 lines'
  'A merge or conflict-resolution sub-agent resolves ONLY the files it is given'
  'goes to a FRESH sub-agent with a new brief'
)
echo "-- the partial"
w="$(flat <"$P/_long_waits.md")"
for r in "${RULES[@]}"; do assert_ok "partial: $r" grep -qF -- "$r" <<<"$w"; done
echo "-- every lane prompt, as rendered"
for p in impl.md resume.md bug-fix.md review.md; do
  out="$(render "$P/$p" ISSUE=5 PRD=4 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused | flat)"
  for r in "${RULES[@]}"; do assert_ok "$p: $r" grep -qF -- "$r" <<<"$out"; done
  assert_ok "$p: the LONG WAITS rule is intact"      grep -qF 'LONG WAITS (#1042, #1066) — never wait inside your session' <<<"$out"
done
finish

#!/usr/bin/env bash
# test_prompt_selfpark.sh — #417: the lane prompts reserve agent-paused for a received HARNESS
# CHECKPOINT. An impl lane once copied the CHECKPOINT PROTOCOL's label swap to wait for a human
# decision on an autonomous fleet and held its slot for hours. impl.md, resume.md and bug-fix.md, as
# rendered, forbid that; resume.md also tells the lane to settle a handoff's open decision itself.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
for p in impl.md resume.md bug-fix.md; do
  out="$(render "$P/$p" ISSUE=5 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused \
    | tr '\n' ' ' | tr -s ' ')"
  assert_ok "$p: agent-paused is only for a received HARNESS CHECKPOINT" \
    grep -qF '`agent-paused` is ONLY for a received HARNESS CHECKPOINT' <<<"$out"
  assert_ok "$p: never applied without one, never to wait for a decision" \
    grep -qF 'never apply it without one, and never to wait for a decision' <<<"$out"
  assert_ok "$p: decide, document as an operator decision, continue" \
    grep -qF 'document it as an operator decision in an issue comment, and continue' <<<"$out"
done
out="$(render "$P/resume.md" ISSUE=5 SLUG=acme/widget BRANCH=issue/5 LABEL_PAUSED=agent-paused | tr '\n' ' ' | tr -s ' ')"
assert_ok "resume.md: an autonomous lane resolves the handoff's open decision itself" \
  grep -qF 'If the handoff above ends on an open question or decision, resolve it yourself' <<<"$out"
assert_ok "resume.md: the rule sits in the AUTONOMOUS block" \
  grep -qE 'configured AUTONOMOUS: never park the work, drive it to closed\. `agent-paused` is ONLY' <<<"$out"
finish

#!/usr/bin/env bash
# test_prompt_fast_ship.sh — #618 (PRD #587): cut the serial waits in the review and implementer prompts.
#   review.md starts the review sub-agent BEFORE the suite run (it used to start after ~80 s of serial checks).
#   impl.md skips the rebase and the re-gate when nothing merged to the default branch since the branch's base, and
#   prints the promise as soon as the direct `gh pr merge` exits 0 (no --auto, sleep and re-poll sequence).
# Prompts are grepped as rendered text (newlines folded) — their bodies carry backticks.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENGINE_DIR="$(cd "$HERE/.." && pwd)"   # a lane exports ENGINE_DIR = the installed release; this tests THIS tree
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
flat(){ tr '\n' ' ' | tr -s ' '; }
# pos <needle> <haystack> — byte offset of the first match, or 999999999 when absent.
pos(){ local pre="${2%%"$1"*}"; [[ "$2" == *"$1"* ]] && echo "${#pre}" || echo 999999999; }

echo "-- review.md: the sub-agent starts before the suite"
R="$(render "$P/review.md" PROJECT=w DESC=d SLUG=acme/widget PRD=7 PROMISE="REVIEW DONE" LABEL_READY=ready-for-agent \
  LABEL_REVIEWED=prd-reviewed SWARM=auto SWARM_SUITE=SUITECMD REVIEW_SUBAGENT=SUBAGENTSTART | flat)"
a="$(pos SUBAGENTSTART "$R")"; b="$(pos SUITECMD "$R")"
assert_ok "the sub-agent start (@$a) comes before the suite command (@$b)" test "$a" -lt "$b"
assert_ok "says to start it first" grep -qF 'START THE REVIEW SUB-AGENT FIRST, before any suite run' <<<"$R"
assert_ok "says the two overlap" grep -qF 'it works while the suite runs' <<<"$R"
assert_ok "says not to wait for it before the suite" grep -qF 'Do not wait for it to finish before the next step' <<<"$R"
assert_ok "exit 3 covers a small suite" grep -qF 'a SMALL suite the helper sends back' <<<"$R"
assert_ok "the probe checklist is still there" grep -qF 'it ALWAYS runs a fixed robustness checklist' <<<"$R"

echo "-- impl.md: no new commits on the default branch → no rebase, no re-gate"
I="$(render "$P/impl.md" ISSUE=5 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused \
  LABEL_READY=ready-for-agent PROMISE="ISSUE 5 DONE" | flat)"
assert_ok "step 5 only fetches first" grep -qF 'RE-VERIFY AGAINST THE CURRENT BASE — immediately before merging, every time: git fetch origin NOTHING MERGED SINCE YOUR BASE' <<<"$I"
assert_ok "the check is an empty rev-list of HEAD..origin/<default>" grep -qF 'git rev-list HEAD..origin/<default-branch>' <<<"$I"
assert_ok "an empty answer skips the rebase and the re-gate" grep -qF 'SKIP THE REBASE AND THE RE-GATE' <<<"$I"
assert_ok "no re-push, no second rtdd run" grep -qF 'Do not rebase, push again, or re-run `rtdd which` or its rounds in step 6b' <<<"$I"
assert_ok "the rebase is still run when other lanes merged" grep -qF 'Run `git rebase origin/<default-branch>`' <<<"$I"
assert_ok "and still re-verifies after a rebase that moved anything" grep -qF 'If the rebase moved anything: re-run the build' <<<"$I"
assert_ok "gate 6b treats the step 2 run as the gate when the rebase was skipped" \
  grep -qF 'When step 5 skipped the rebase, the step 2 run on this same HEAD IS this gate' <<<"$I"
assert_ok "gate 6a (the repo's CI entrypoint) is untouched" grep -qF 'If one exists it IS the gate' <<<"$I"

echo "-- impl.md: the promise prints once gh pr merge exits 0"
assert_ok "ONE direct squash merge" grep -qF '7. Get the PR MERGED with ONE direct squash merge, once the step 6 gate is green: gh pr merge --squash --delete-branch' <<<"$I"
assert_ok "exit 0 means merged: promise at once" grep -qF 'Exit 0 means MERGED: print the promise at once' <<<"$I"
assert_ok "no polling, no sleeping" grep -qF 'no polling, sleeping or re-reading the PR' <<<"$I"
assert_ok "the engine's merged check confirms it" grep -qF "the engine's \`merged\` check confirms the issue closed" <<<"$I"
direct="$(pos 'gh pr merge --squash --delete-branch' "$I")"; auto="$(pos 'gh pr merge --auto' "$I")"
assert_ok "--auto is only the fallback, after the direct merge (@$direct < @$auto)" test "$direct" -lt "$auto"
assert_ok "--auto is for a merge that failed" grep -qF 'If it exits non-zero' <<<"$I"
assert_ok "the promise paragraph keys on gh pr merge exiting 0" grep -qF '(`gh pr merge` exited 0; or truly auto-merging' <<<"$I"
assert_ok "known-gap gate survives" grep -qF 'KNOWN-GAP GATE' <<<"$I"
assert_ok "the gate still precedes any merge" test "$(pos 'scripts/ci-local.sh' "$I")" -lt "$direct"

echo "-- bug-fix.md and resume.md keep their own merge flow"
for t in bug-fix resume; do
  X="$(render "$P/$t.md" ISSUE=5 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused \
    LABEL_READY=ready-for-agent PROMISE="X DONE" | flat)"
  assert_ok "$t.md still tries auto-merge first" grep -qF 'FIRST try to enable auto-merge' <<<"$X"
done
finish

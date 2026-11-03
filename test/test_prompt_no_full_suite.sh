#!/usr/bin/env bash
# test_prompt_no_full_suite.sh — #449: lanes test with rtdd Rounds 1 and 2 only; the full suite runs
# ONCE, at PRD review, never once per issue. #204/#218/#246 each brought a per-lane full suite back
# (baseline + final + gate, 15–22 min each on swarm), so pin the rule on every lane prompt — raw AND
# as scripts/drive.sh renders it — and pin review.md's single suite run so it cannot drift away too.
# Prompts are grepped from files: their bodies carry backticks.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
PR="$HERE/../prompts"
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT

# Every way a prompt has told a lane to run the full suite.
FORBIDDEN=('FULL-SUITE BAR' 'Round 3' '{{SWARM_SUITE}}' 'swarm-suite' 'hz-baseline' '<baseline|final>'
           'full suite IS the gate' 'otherwise the FULL suite')
no_full_suite(){ # <label> <file>
  local pat
  for pat in "${FORBIDDEN[@]}"; do
    assert_no "$1: no '$pat'" grep -qiF -- "$pat" "$2"
  done
}
rtdd_gate(){ # <label> <file>: step 6b gates on rtdd Rounds 1+2, re-selected on the rebased HEAD
  assert_ok "$1: gate without a CI entrypoint is rtdd Rounds 1+2" \
    grep -qi 'otherwise the gate is rtdd Rounds 1+2' "$2"
  assert_ok "$1: gate re-selects with rtdd which on the rebased HEAD" \
    grep -q 'rtdd which --base origin/<default-branch>` on this rebased HEAD' "$2"
  assert_ok "$1: gate includes the lane's own new tests" grep -qi "own new tests" "$2"
  assert_ok "$1: the local CI entrypoint is still the gate when present" grep -q 'scripts/ci-local.sh' "$2"
  assert_ok "$1: gate never the full suite" grep -qi 'never the full suite' "$2"
}

echo "-- raw lane prompts"
for p in impl bug-fix resume _rtdd _followup; do
  no_full_suite "$p.md" "$PR/$p.md"
done
for p in impl bug-fix resume; do rtdd_gate "$p.md" "$PR/$p.md"; done

echo "-- the rtdd fallback (missing / old / erroring / both rounds empty)"
R="$PR/_rtdd.md"
assert_ok "_rtdd.md: fallback covers both rounds EMPTY" grep -q 'both rounds EMPTY' "$R"
assert_ok "_rtdd.md: fallback runs the closest test files by hand" grep -qi 'closest test files by hand' "$R"
assert_ok "_rtdd.md: fallback notes it in an issue comment" grep -qi 'note it in an issue comment' "$R"
assert_ok "_rtdd.md: files one rtdd bug when rtdd misbehaved" grep -qi 'file ONE rtdd bug' "$R"
assert_ok "_rtdd.md: fallback never runs the full suite" grep -qi 'never the full suite' "$R"
assert_ok "_rtdd.md: never blocks" grep -q 'Never block' "$R"
assert_ok "_rtdd.md: keeps the pre-existing-red check on the base" grep -q 'git worktree add' "$R"

echo "-- review.md keeps the one full-suite run"
V="$PR/review.md"
assert_ok "review.md runs the suite through {{SWARM_SUITE}}" grep -qF '{{SWARM_SUITE}} "$PWD" {{SLUG}}-prd{{PRD}}-review' "$V"
assert_ok "review.md: exit 3 → run the suite locally" grep -q '`3` not run on swarm' "$V"
assert_ok "review.md says it is the ONLY full-suite run" grep -q 'the ONLY full-suite run in the pipeline' "$V"

echo "-- lane prompts as scripts/drive.sh renders them"
(
  source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; make_env
  HARNESS_SWARM=auto
  launch_claude(){ :; }; ensure_checkout(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }
  remove_worktree(){ :; }; default_branch(){ echo main; }; session_live(){ return 1; }
  issue_parent_prd(){ :; }; resume_handoff(){ :; }
  PAUSED=""; gh(){ [[ "$*" == *"--json labels"* && -n "$PAUSED" ]] && { echo "[\"$HARNESS_LABEL_PAUSED\"]"; return 0; }; return 1; }
  git(){ local a; case "$*" in *"worktree add"*) for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && mkdir -p "$a"; done;; esac; return 0; }
  UNIT=main; SLUG=acme/widget; PROJECT=w; DESC=d; CHECKOUT="$T/checkout"; mkdir -p "$CHECKOUT"
  spawn_impl 7 "ISSUE 7 DONE"
  assert_eq "$IMPL_TMPL" impl.md "fresh issue renders impl.md"
  F="$WORKTREES_DIR/main-i7/.harness-task.md"; cp "$F" "$T/impl.txt"
  no_full_suite "rendered impl" "$T/impl.txt"; rtdd_gate "rendered impl" "$T/impl.txt"
  spawn_bug 8 fix
  cp "$(bug_worktree acme/widget 8)/.harness-task.md" "$T/bug-fix.txt"
  no_full_suite "rendered bug-fix" "$T/bug-fix.txt"; rtdd_gate "rendered bug-fix" "$T/bug-fix.txt"
  PAUSED=1; prepare_impl 9 "ISSUE 9 DONE"
  assert_eq "$IMPL_TMPL" resume.md "paused issue renders resume.md"
  cp "$WORKTREES_DIR/main-i9/.harness-task.md" "$T/resume.txt"
  no_full_suite "rendered resume" "$T/resume.txt"; rtdd_gate "rendered resume" "$T/resume.txt"
  PAUSED=""; spawn_orch REVIEW 41 "REVIEW DONE"
  V="$(orch_worktree acme/widget 41)/.harness-task.md"
  assert_ok "rendered review runs swarm-suite.sh" grep -q 'swarm-suite.sh' "$V"
  assert_no "rendered review: no unrendered {{SWARM token" grep -q '{{SWARM' "$V"
  finish
) || TESTS_FAIL=$((TESTS_FAIL+1))
finish

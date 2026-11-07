#!/usr/bin/env bash
# test_prompt_decompose.sh — #598 (PRD #587): a small task stays small. decompose.md files ONE issue unless
# splitting pays (POOL-aware, overriding the vendored to-issues skill), never files a final sweep issue and
# adds no implementation primitive of its own; prd.md states behaviour, not primitives the brief never named.
# Prompts are grepped as rendered text (newlines folded) — their bodies carry backticks.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
flat(){ tr '\n' ' ' | tr -s ' '; }

echo "-- decompose.md, rendered with POOL"
D1="$(render "$P/decompose.md" PROJECT=w DESC=d SLUG=acme/widget PRD=41 POOL=1 LABEL_READY=ready-for-agent | flat)"
D4="$(render "$P/decompose.md" PROJECT=w DESC=d SLUG=acme/widget PRD=41 POOL=4 LABEL_READY=ready-for-agent | flat)"
assert_ok "POOL renders into the prompt" grep -qF 'at most 4 lanes' <<<"$D4"
assert_ok "POOL=1 renders too" grep -qF 'at most 1 lanes' <<<"$D1"
assert_no "no unrendered {{POOL}}" grep -qF '{{POOL}}' <<<"$D4"
assert_ok "split only when it pays" grep -qF 'split only when it pays' <<<"$D4"
assert_ok "POOL=1: one issue" grep -qF 'POOL is 1: file ONE issue' <<<"$D4"
assert_ok "POOL=1: unless more than ~15 acceptance criteria or unrelated subsystems" \
  grep -qF 'more than ~15 PRD acceptance criteria, or unrelated subsystems' <<<"$D4"
assert_ok "POOL>1: split only when the graph is 2 wide at the top" \
  grep -qF 'split only when the dependency graph is at least 2 wide at its top' <<<"$D4"
assert_ok "otherwise one issue" grep -qF 'file ONE issue.' <<<"$D4"
assert_ok "overrides the skill's many-thin-slices line explicitly" \
  grep -qF 'OVERRIDES the skill'"'"'s "Prefer many thin slices over few thick ones"' <<<"$D4"
assert_ok "never a final sweep / README / acceptance-check issue" \
  grep -qF 'NEVER file a final sweep, README, docs or acceptance-check issue' <<<"$D4"
assert_ok "docs go into the slices" grep -qF 'Put the docs for a change into the slice that makes the change' <<<"$D4"
assert_ok "decompose adds no implementation primitive of its own" \
  grep -qF 'Do NOT add implementation primitives the PRD does not name' <<<"$D4"
assert_ok "a PRD's own Task sections are not merged" grep -qF 'the SLICING RULE does not merge them' <<<"$D4"
assert_ok "the Task 1 rule is kept" grep -qF 'FIRST child, titled `[AFK] Task 1' <<<"$D4"

echo "-- prd.md"
R="$(render "$P/prd.md" PROJECT=w DESC=d SLUG=acme/widget SPEC=s | flat)"
assert_ok "prd.md: behaviour, not primitives" grep -qF 'BEHAVIOUR, NOT PRIMITIVES' <<<"$R"
assert_ok "prd.md: no primitive the brief does not require" \
  grep -qF 'Do NOT prescribe an implementation primitive the brief does not require' <<<"$R"
assert_ok "prd.md: names the kinds (splitting function, encoding, library)" \
  grep -qF 'a string-splitting function, an encoding, a library' <<<"$R"
assert_ok "prd.md: a primitive is named only where the brief names it" \
  grep -qF 'Name a primitive only where the brief itself names it' <<<"$R"

echo "-- scripts/drive.sh passes POOL to the decompose render"
(
  source "$HERE/../scripts/drive.sh"; make_env
  launch_claude(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }; remove_worktree(){ :; }
  default_branch(){ echo main; }; win_repo_config(){ :; }
  git(){ local a; case "$*" in *"worktree add"*) for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && mkdir -p "$a"; done;; esac; return 0; }
  PROMPTS_DIR="$P"   # render THIS tree's prompts, never an installed engine's
  UNIT=main; SLUG=acme/widget; PROJECT=w; DESC=d; CHECKOUT="$T/checkout"; mkdir -p "$CHECKOUT"
  POOL=3; spawn_orch DECOMPOSE 41 "DECOMPOSE DONE"
  F="$(orch_worktree acme/widget 41)/.harness-task.md"
  assert_ok "rendered decompose carries the pool bound" grep -q 'at most 3 lanes' "$F"
  assert_no "rendered decompose: no unrendered {{POOL}}" grep -q '{{POOL}}' "$F"
  finish
) || TESTS_FAIL=$((TESTS_FAIL+1))
finish

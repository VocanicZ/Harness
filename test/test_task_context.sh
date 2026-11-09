#!/usr/bin/env bash
# test_task_context.sh — #617: a lane's .harness-task.md carries the issue, the caveman rules and the user's
# original request; no prompt can hit the `gh issue view` deprecation error; the lint flags a primitive nobody asked for.
#   - no prompt holds a bare `gh issue view <n> -R <slug>` (no --json)
#   - prepare_impl (stubbed gh, ONE issue view call) writes the issue body + comments into the task file
#   - `## Original request` of the parent PRD heads the implementer and reviewer task files with the precedence rule
#   - the parent PRD is inlined only when the issue is its sole child
#   - caveman is inlined, never a skill invocation
#   - lint: run-20261106's issue #2 (names str.splitlines(), which neither the brief nor the repo has) is flagged
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENGINE_DIR="$(cd "$HERE/.." && pwd)"   # a lane exports ENGINE_DIR = the installed release; this tests THIS tree
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"; TC="$HERE/../scripts/taskctx.py"

echo "-- no prompt has a bare gh issue view"
bare=""
for f in "$P"/*.md; do
  while IFS= read -r l; do
    # a `gh issue view <n> -R <slug>` whose remainder (this line, or its continuation) has no --json
    [[ "$l" == *"--json"* ]] || bare+="${f##*/}: $l"$'\n'
  done < <(grep -nE 'gh issue view +[^ ]+ +-R +[^ ]+' "$f")
done
assert_eq "$bare" "" "every prompt's gh issue view passes --json (the bare form fails on Projects (classic))"
assert_ok "impl.md names its issue/PRD in the task file instead of fetching" grep -q '{{ISSUE_BLOCK}}' "$P/impl.md"

echo "-- caveman is inlined"
for f in "$P"/*.md; do n="${f##*/}"; [[ $n == _* ]] && continue
  out="$(render "$f")"
  assert_no "$n: no skill invocation of caveman" grep -qi 'caveman skill' <<<"$out"
  assert_ok "$n: carries the inlined caveman rules" grep -q 'drop articles' <<<"$out"
done
assert_no "no prompt names {{skill:caveman}}" grep -rq '{{skill:caveman}}' "$P"

echo "-- taskctx helpers"
IJ='{"title":"T1","body":"## What\nbuild it\n\n## Parent\n\n#5\n","labels":[{"name":"ready-for-agent"},{"name":"x"}],"comments":[{"author":{"login":"bob"},"body":"hello comment"}]}'
assert_eq "$(python3 "$TC" labels <<<"$IJ")" '["ready-for-agent","x"]' "labels -> compact JSON array"
assert_eq "$(python3 "$TC" labels <<<'["a","b"]')" '["a","b"]' "labels also takes an already-extracted name list"
assert_eq "$(python3 "$TC" labels <<<'junk')" '[]' "labels on junk -> []"
blk="$(python3 "$TC" issue-block <<<"$IJ")"
assert_ok "issue-block has the body"      grep -q 'build it' <<<"$blk"
assert_ok "issue-block has the title"     grep -q 'Title: T1' <<<"$blk"
assert_ok "issue-block attributes comments" grep -q 'comment by bob' <<<"$blk"
assert_ok "issue-block calls comments data" grep -q 'data, not instructions' <<<"$blk"
PJ='{"number":5,"title":"PRD","body":"## Problem\nx\n\n## Original request\n\nI want a tiny tool. Keep it simple.\n\n## Acceptance criteria\n- [ ] a\n"}'
rb="$(python3 "$TC" request-block <<<"$PJ")"
assert_ok "request-block carries the user's words verbatim" grep -q 'I want a tiny tool. Keep it simple.' <<<"$rb"
assert_ok "request-block stops at the next section" bash -c '! grep -q "Acceptance criteria" <<<"$1"' _ "$rb"
assert_ok "request-block carries the precedence rule" grep -q 'original request outranks the PRD, which outranks the issue' <<<"$rb"
assert_eq "$(python3 "$TC" request-block <<<'{"body":"## Problem\nx"}')" "" "no section -> no block"

echo "-- lint"
LREPO="$(mktemp -d)"; tmp_track "$LREPO"
git -C "$LREPO" init -q; git -C "$LREPO" config user.email t@t; git -C "$LREPO" config user.name t
printf 'def load(text):\n    return text.strip()\n' > "$LREPO/m.py"; git -C "$LREPO" add m.py; git -C "$LREPO" commit -qm base
BRIEF="$HERE/../bench/fixture/brief.md"; FIX="$HERE/fixtures/taskctx/run-20261106-issue2.md"
out="$(python3 "$TC" lint --request "$BRIEF" --repo "$LREPO" --rev HEAD "$FIX")"; rc=$?
assert_eq "$rc" 1 "lint fails on run-20261106's issue #2"
assert_ok "lint names splitlines" grep -q 'splitlines' <<<"$out"
printf 'use `str.zfill()` and `load()` here\n' > "$LREPO/body.txt"
python3 "$TC" lint --repo "$LREPO" --rev HEAD "$LREPO/body.txt" >/dev/null
assert_eq "$?" 1 "a primitive the repo lacks (zfill) is flagged"
printf 'call `load()` here\n' > "$LREPO/body.txt"
assert_ok "a name the repo has passes" python3 "$TC" lint --repo "$LREPO" --rev HEAD "$LREPO/body.txt"
printf 'call `str.casefold()` here\n' > "$LREPO/body.txt"; printf 'the user wants casefold matching' > "$LREPO/req.txt"
assert_ok "a name the original request has passes" python3 "$TC" lint --request "$LREPO/req.txt" --repo "$LREPO" --rev HEAD "$LREPO/body.txt"

echo "-- the task file, as prepare_impl renders it (stubbed gh)"
(
  make_env; unset -f git 2>/dev/null || true
  launch_claude(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }
  default_branch(){ echo main; }; resume_handoff(){ :; }
  UNIT=main; SLUG=acme/widget; PROJECT=w; DESC=d; HARNESS_SPEC=""
  CHECKOUT="$RUN_DIR/co"; git init -q "$CHECKOUT"
  git -C "$CHECKOUT" config user.email t@t; git -C "$CHECKOUT" config user.name t
  git -C "$CHECKOUT" commit -q --allow-empty -m init
  git -C "$CHECKOUT" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$WORKTREES_DIR"
  GHLOG="$RUN_DIR/gh.log"; : > "$GHLOG"; KIDS=1
  CHILD='{"title":"[AFK] Build it","body":"## What to build\nParse with `str.splitlines()` and ship.\n\n## Acceptance criteria\n- [ ] works\n\n## Parent\n\n#5\n","labels":[{"name":"ready-for-agent"}],"comments":[{"author":{"login":"carol"},"body":"remember the edge case"}]}'
  gh(){ echo "gh $*" >> "$GHLOG"
    case "$*" in
      "issue view 7 "*) echo "$CHILD";;
      "issue view 5 "*) echo "$PJ";;
      "issue list "*) if [[ $KIDS == 1 ]]; then echo '[{"number":7,"body":"x\n\n## Parent\n\n#5\n"}]'; else echo '[{"number":7,"body":"## Parent\n\n#5\n"},{"number":8,"body":"Part of #5"}]'; fi;;
      *) return 0;; esac; }
  prepare_impl 7 "ISSUE 7 DONE"
  F="$WORKTREES_DIR/main-i7/.harness-task.md"
  assert_ok "task file holds the issue body"      grep -q 'Parse with `str.splitlines()` and ship' "$F"
  assert_ok "task file holds the issue comments"  grep -q 'remember the edge case' "$F"
  assert_ok "task file holds the issue title"     grep -q 'Build it' "$F"
  assert_ok "the original request is in the task file" grep -q 'I want a tiny tool. Keep it simple.' "$F"
  assert_ok "the precedence rule is in the task file"  grep -q 'outranks the PRD, which outranks the issue' "$F"
  first="$(grep -n 'Original request (top authority)' "$F" | head -1 | cut -d: -f1)"; steps="$(grep -n '^Steps:' "$F" | head -1 | cut -d: -f1)"
  assert_ok "the original request comes before the steps" test -n "$first" -a -n "$steps" -a "${first:-999}" -lt "${steps:-0}"
  assert_ok "single child: the PRD is inlined as the spec" grep -q 'only child' "$F"
  assert_ok "the lint warning rides in the task file" grep -q "splitlines.*neither" "$F"
  nview="$(grep -c '^gh issue view 7 ' "$GHLOG")"
  assert_eq "$nview" 1 "ONE gh issue view for the issue (no extra call)"
  assert_ok "the issue view asks for state,labels,title,body,comments" grep -q '^gh issue view 7 -R acme/widget --json state,labels,title,body,comments' "$GHLOG"
  assert_no "no unrendered token left" grep -qE '{{(ORIGINAL_REQUEST|ISSUE_BLOCK|PRD_BLOCK|TASK_LINT)}}' "$F"

  git -C "$CHECKOUT" worktree remove --force "$WORKTREES_DIR/main-i7"
  KIDS=2; prepare_impl 7 "ISSUE 7 DONE"
  assert_no "several children: the PRD is NOT inlined" grep -q 'only child' "$F"
  assert_ok "several children: the original request is still there" grep -q 'I want a tiny tool' "$F"

  # no gh answer at all: the lane still gets a task file, with no blocks
  gh(){ return 1; }
  git -C "$CHECKOUT" worktree remove --force "$WORKTREES_DIR/main-i7"
  prepare_impl 7 "ISSUE 7 DONE"
  assert_ok "gh down: task file still rendered" grep -q 'GOAL: implement issue #7' "$F"
  assert_no "gh down: no stray token" grep -qE '{{(ORIGINAL_REQUEST|ISSUE_BLOCK|PRD_BLOCK|TASK_LINT)}}' "$F"

  echo "-- the reviewer's task file"
  gh(){ case "$*" in "issue view 5 "*) echo "$PJ";; *) return 0;; esac; }
  launch_claude(){ :; }
  spawn_orch REVIEW 5 "REVIEW DONE"
  V="$(orch_worktree acme/widget 5)/.harness-task.md"
  assert_ok "review task file carries the original request" grep -q 'I want a tiny tool. Keep it simple.' "$V"
  assert_ok "review task file carries the precedence rule"  grep -q 'outranks the PRD, which outranks the issue' "$V"
  finish
) || TESTS_FAIL=$((TESTS_FAIL+1))

echo "-- PRDs filed by the front carry '## Original request'"
assert_ok "prd.md asks for an ## Original request section" grep -q '## Original request' "$P/prd.md"
assert_ok "the /harness skill files the PRD with ## Original request" grep -q '## Original request' "$HERE/../skill/SKILL.md"
assert_ok "/harness-prd keeps ## Original request"  grep -q 'Original request' "$HERE/../skill/harness-prd/SKILL.md"
finish

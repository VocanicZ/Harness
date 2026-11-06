#!/usr/bin/env bash
# test_windows_prompts.sh — #494 (PRD #475, Solution 8): with HARNESS_WINDOWS_HOST set, a lane whose diff touches Windows-relevant
# code also runs its rtdd Rounds 1+2 on that host, and the PRD review's single full suite runs there too, both through the winsma
# lock / isolation / guard helpers. Unset, the prompts are exactly what they were.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
ROOT="$HERE/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
REL="$ROOT/scripts/windows-relevant.sh"

echo "-- windows-relevant.sh: the path list"
for p in scripts/portable.sh scripts/portable.py install.sh update.sh scripts/uninstall.sh scripts/doctor.sh \
         scripts/session/headless.sh scripts/cli/claude_headless.py scripts/cli/codex.sh scripts/cli/opencode.sh scripts/cli/dispatch.sh \
         scripts/supervise.sh scripts/web.sh scripts/attach.sh test/smoke/winsma/suite.sh test/smoke/winsma/lock.sh; do
  assert_ok "relevant: $p" bash "$REL" "$p"
done
for p in scripts/drive.sh scripts/lib.sh prompts/impl.md docs/reference.md test/test_winsma.sh scripts/session/tmux.sh \
         scripts/web_data.py scripts/supervise_rules.py README.md test/smoke/fleet_smoke.sh scripts/portable_x/a.sh; do
  assert_no "not relevant: $p" bash "$REL" "$p"
done
assert_eq "$(printf 'docs/a.md\nscripts/web.sh\nREADME.md\n' | bash "$REL")" "scripts/web.sh" "stdin: only the matching path is printed"
assert_ok "stdin: one match among many is enough" bash -c "printf 'docs/a.md\ninstall.sh\n' | bash '$REL'"
assert_no "stdin: no match" bash -c "printf 'docs/a.md\nREADME.md\n' | bash '$REL'"
assert_no "no paths at all" bash -c "bash '$REL' </dev/null"

echo "-- rendered lane prompts and review"
(
  source "$ROOT/scripts/lib.sh"; source "$ROOT/scripts/drive.sh"; make_env
  launch_claude(){ :; }; ensure_checkout(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }
  remove_worktree(){ :; }; default_branch(){ echo main; }; session_live(){ return 1; }
  issue_parent_prd(){ :; }; resume_handoff(){ :; }
  PAUSED=""; gh(){ [[ "$*" == *"--json labels"* && -n "$PAUSED" ]] && { echo "[\"$HARNESS_LABEL_PAUSED\"]"; return 0; }; return 1; }
  git(){ local a; case "$*" in *"worktree add"*) for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && mkdir -p "$a"; done;; esac; return 0; }
  UNIT=main; SLUG=acme/widget; PROJECT=w; DESC=d; CHECKOUT="$T/checkout"; mkdir -p "$CHECKOUT"
  render_all(){ # <suffix>: impl, bug-fix, resume and review as drive.sh renders them
    spawn_impl 7 "ISSUE 7 DONE"; cp "$WORKTREES_DIR/main-i7/.harness-task.md" "$T/impl.$1"
    spawn_bug 8 fix; cp "$(bug_worktree acme/widget 8)/.harness-task.md" "$T/bug-fix.$1"
    PAUSED=1; prepare_impl 9 "ISSUE 9 DONE"; cp "$WORKTREES_DIR/main-i9/.harness-task.md" "$T/resume.$1"
    PAUSED=""; spawn_orch REVIEW 41 "REVIEW DONE"; cp "$(orch_worktree acme/widget 41)/.harness-task.md" "$T/review.$1"
    rm -rf "$WORKTREES_DIR"/* "$(dirname "$(bug_worktree acme/widget 8)")"/* 2>/dev/null; }

  HARNESS_WINDOWS_HOST=""; render_all off
  for f in impl bug-fix resume review; do
    assert_no "unset: $f has no Windows step" grep -qE 'WINDOWS HOST|windows-relevant|winsma' "$T/$f.off"
    assert_no "unset: $f has no unrendered {{WINDOWS" grep -q '{{WINDOWS' "$T/$f.off"
  done

  HARNESS_WINDOWS_HOST=winsma; render_all on
  for f in impl bug-fix resume; do
    assert_ok "set: $f names the host"                 grep -q 'HARNESS_WINDOWS_HOST=winsma' "$T/$f.on"
    assert_ok "set: $f asks windows-relevant.sh about the diff" grep -qE 'git diff --name-only origin/<default-branch>\.\.\.HEAD \| bash \S*/scripts/windows-relevant\.sh' "$T/$f.on"
    assert_ok "set: $f runs rtdd Rounds 1+2 there, not the full suite" grep -q 'rtdd Rounds 1+2 (never the full suite' "$T/$f.on"
    assert_ok "set: $f goes through winsma.sh run in its issue's folder" grep -qE 'winsma\.sh run [0-9]+ suite' "$T/$f.on"
    assert_ok "set: $f states the winsma rules"        grep -q 'Verification on winsma' "$T/$f.on"
    assert_ok "set: $f commits a -windows- log"        grep -q 'test/smoke/logs/rtdd-windows-' "$T/$f.on"
    assert_ok "set: $f never raw ssh"                  grep -q 'never raw ssh' "$T/$f.on"
    assert_no "set: $f has no unrendered token"        grep -qE '{{(WINDOWS|WINSMA|ISSUE)' "$T/$f.on"
    assert_no "set: $f does not run the full suite on the Windows host" grep -q 'HX_STRICT' "$T/$f.on"
  done
  assert_ok "set: impl uses its own issue number" grep -q 'winsma.sh run 7 suite' "$T/impl.on"
  assert_ok "set: bug-fix uses its own issue number" grep -q 'winsma.sh run 8 suite' "$T/bug-fix.on"
  assert_ok "set: resume uses its own issue number" grep -q 'winsma.sh run 9 suite' "$T/resume.on"
  assert_ok "set: the engine's helper path is in the prompt" grep -qF "$ENGINE_DIR/scripts/windows-relevant.sh" "$T/impl.on"

  assert_ok "set: review runs the full suite on the Windows host" grep -q 'Run that same single full suite on the Windows' "$T/review.on"
  assert_ok "set: review goes through winsma.sh run in the suite isolation" grep -qE 'winsma\.sh run 41 suite "export HX_BRANCH=<default-branch> HX_STRICT=1; \$\(cat \S*/suite\.sh\)"' "$T/review.on"
  assert_ok "set: review's bar is no Windows failure Linux lacks" grep -q 'no Windows failure that Linux does not also have at the same commit' "$T/review.on"
  assert_ok "set: review requires every Windows skip to name an n/a row" grep -q 'every Windows skip names an `n/a` row' "$T/review.on"
  assert_ok "set: review applies the guard and the winsma rules" grep -q 'before/after guard' "$T/review.on"
  assert_ok "set: review still runs the Linux suite" grep -q 'swarm-suite.sh' "$T/review.on"
  assert_no "set: review has no unrendered token" grep -qE '{{(WINDOWS|WINSMA)' "$T/review.on"
  assert_no "set: review does not tell the lanes' rtdd step" grep -q 'rtdd-windows-' "$T/review.on"
  for f in impl bug-fix resume; do assert_no "set: $f has no full-suite Windows run" grep -q 'Run that same single full suite' "$T/$f.on"; done

  # Unset, only the Windows paragraph differs: cutting it out of the set render gives the unset render back, byte for byte.
  cut_block(){ # <file> <line count>: drop the count lines that start at the "WINDOWS HOST" line
    awk -v n="$2" '/^   WINDOWS HOST/ && !d { d=n } d>0 { d--; next } { print }' "$1"; }
  n_rtdd="$(windows_block _windows_rtdd.md ISSUE=7 | wc -l)"; n_suite="$(windows_block _windows_suite.md PRD=41 | wc -l)"
  for f in impl bug-fix resume; do
    cut_block "$T/$f.on" "$n_rtdd" > "$T/$f.cut"
    # the ISSUE-specific winsma line differs per prompt but the line COUNT is the same, so the cut is exact
    assert_ok "$f: the Windows paragraph is the only difference" cmp -s "$T/$f.cut" "$T/$f.off"
  done
  cut_block "$T/review.on" "$n_suite" > "$T/review.cut"
  assert_ok "review: the Windows paragraph is the only difference" cmp -s "$T/review.cut" "$T/review.off"
  finish
) || TESTS_FAIL=$((TESTS_FAIL+1))
finish

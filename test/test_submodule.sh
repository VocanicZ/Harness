#!/usr/bin/env bash
# test_submodule.sh — submodule lane plumbing (#470, PRD #464 §3): a fresh lane worktree has its
# submodules initialised before HARNESS_WORKTREE_HOOK runs, a submodule's base branch resolves from
# .gitmodules or from the remote branch holding the gitlink, and scripts/gitlink-guard.sh refuses a
# main-repo merge whose changed gitlink is unmerged or not a descendant of the current one. Real git
# on local fixture repos — nothing is stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"
export RUN_DIR="$(mktemp -d)"
TMP="$(mktemp -d)"; tmp_track "$TMP" 2>/dev/null || true
trap 'rm -rf "$TMP"' EXIT
# modern git refuses file:// submodule transport; fixtures are local
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
GUARD="$ROOT/scripts/gitlink-guard.sh"
rc=0

q(){ git "$@" >/dev/null 2>&1; }
# mk_fixture <dir> — <dir>/sub.git (default branch main, plus rebuild), <dir>/main (a clone whose
# submodule `engine` is pinned at the tip of main). Echoes nothing; sets C_MAIN (the pinned sha).
mk_fixture(){ local d="$1"
  mkdir -p "$d"; git init -q --bare -b main "$d/sub.git"
  git clone -q "$d/sub.git" "$d/subwork" 2>/dev/null
  ( cd "$d/subwork" && git checkout -q -b main 2>/dev/null; echo 1 > f; git add f; q commit -m c1; q push origin main )
  git init -q -b main "$d/main"
  ( cd "$d/main" && echo hi > README; git add README; q commit -m init \
      && git submodule add -q "$d/sub.git" engine 2>/dev/null && q commit -m "add engine" )
  git init -q --bare -b main "$d/main.git"; ( cd "$d/main" && q remote add origin "$d/main.git" && q push origin main )
}
# sub_commit <dir> <branch> <msg> — a new commit on <branch> in the submodule remote; echoes its sha.
sub_commit(){ ( cd "$1/subwork" && q fetch origin
    if git rev-parse -q --verify "origin/$2" >/dev/null; then q checkout -B "$2" "origin/$2"; else q checkout -B "$2"; fi
    echo "$3" >> f; git add f; q commit -m "$3"; q push origin "$2"; git rev-parse HEAD ); }
# bump <dir> <sha> — point main's gitlink at <sha> (committed on the current branch of <dir>/main).
bump(){ ( cd "$1/main/engine" && q fetch origin && q checkout "$2" ) && ( cd "$1/main" && git add engine && q commit -m "bump" ); }

source "$ROOT/scripts/lib.sh"

# ── group 1: a fresh lane worktree has its submodules initialised BEFORE the hook ────────────
(
  D="$TMP/g1"; mk_fixture "$D"
  PIN="$(git -C "$D/main/engine" rev-parse HEAD)"
  q -C "$D/main" worktree add -b issue/1 "$D/wt" HEAD
  assert_no "precondition: worktree add leaves the submodule empty" test -e "$D/wt/engine/f"
  printf '#!/usr/bin/env bash\nif [[ -e engine/f ]]; then echo present > "$1/hook.sawsub"; fi\n' > "$D/hook.sh"; chmod +x "$D/hook.sh"
  PROJECT_ROOT="$D/main"; HARNESS_WORKTREE_HOOK="$D/hook.sh"
  run_worktree_hook "$D/wt" >/dev/null 2>&1
  assert_ok "submodule is checked out in the lane worktree" test -e "$D/wt/engine/f"
  assert_eq "$(git -C "$D/wt/engine" rev-parse HEAD)" "$PIN" "submodule sits at the gitlink commit"
  assert_ok "the hook already saw the checked-out submodule" test -e "$D/wt/hook.sawsub"
  # an unset hook still inits submodules
  q -C "$D/main" worktree add -b issue/2 "$D/wt2" HEAD
  HARNESS_WORKTREE_HOOK=""; run_worktree_hook "$D/wt2" >/dev/null 2>&1
  assert_ok "no hook configured: submodules still initialised" test -e "$D/wt2/engine/f"
  finish
) || rc=1

# ── group 2: a repo with no submodules is untouched ──────────────────────────────────────────
(
  D="$TMP/g2"; mkdir -p "$D"; git init -q -b main "$D/r"; ( cd "$D/r" && echo x > a && git add a && q commit -m i )
  q -C "$D/r" worktree add -b issue/1 "$D/wt" HEAD
  PROJECT_ROOT="$D/r"; HARNESS_WORKTREE_HOOK=""
  git(){ [[ "${*}" == *submodule* ]] && echo "SUBMODULE-CALL" >> "$D/calls"; command git "$@"; }
  run_worktree_hook "$D/wt" >/dev/null 2>&1; rc2=$?
  assert_eq "$rc2" "0" "no .gitmodules: run_worktree_hook succeeds"
  assert_no "no .gitmodules: git submodule is never invoked" test -e "$D/calls"
  finish
) || rc=1

# ── group 3: base-branch resolver ────────────────────────────────────────────────────────────
(
  D="$TMP/g3"; mk_fixture "$D"
  REB="$(sub_commit "$D" rebuild "r1")"          # rebuild branches off the same history, ahead of main
  R="$D/main"
  q -C "$R" submodule update --init
  # (a) explicit `branch =` wins, even over the containing-branch rule
  git config -f "$R/.gitmodules" submodule.engine.branch x
  assert_eq "$(submodule_base_branch "$R" engine)" "x" "branch = x in .gitmodules -> x"
  git config -f "$R/.gitmodules" --unset submodule.engine.branch
  # (b) unset + gitlink on BOTH main and rebuild (it is main's tip, which rebuild descends) -> default main
  assert_eq "$(submodule_base_branch "$R" engine)" "main" "unset, gitlink on main and rebuild -> main (default)"
  # (c) unset + gitlink only on rebuild -> rebuild
  bump "$D" "$REB"
  assert_eq "$(submodule_base_branch "$R" engine)" "rebuild" "unset, gitlink only on rebuild -> rebuild"
  # (d) a path that is no submodule is an error
  assert_no "unknown path fails" submodule_base_branch "$R" nope
  finish
) || rc=1

# ── group 4: gitlink guard ───────────────────────────────────────────────────────────────────
guard(){ bash "$GUARD" --repo "$1" --base "${2:-origin/main}" --head "${3:-HEAD}"; }
(
  D="$TMP/g4"; mk_fixture "$D"
  R="$D/main"; q -C "$R" submodule update --init
  CUR="$(git -C "$R" rev-parse HEAD:engine)"

  # no gitlink change -> passes untouched
  q -C "$R" checkout -b lane/plain; echo y >> "$R/README"; git -C "$R" add README; q -C "$R" commit -m doc
  assert_ok "no gitlink change passes" guard "$R"

  # merged descendant -> allowed
  q -C "$R" checkout main; q -C "$R" checkout -b lane/ok
  MERGED="$(sub_commit "$D" main "m2")"; bump "$D" "$MERGED"
  assert_ok "merged descendant of the current gitlink is allowed" guard "$R"

  # unmerged commit (only on a feature branch of the submodule remote) -> refused
  q -C "$R" checkout main; q -C "$R" checkout -b lane/unmerged
  UNM="$(sub_commit "$D" feature "u1")"; bump "$D" "$UNM"
  assert_no "gitlink to an unmerged commit is refused" guard "$R"
  OUT="$(guard "$R" 2>&1)"; assert_ok "refusal names the submodule path" grep -q engine <<<"$OUT"

  # non-descendant: a commit on main that does NOT descend from the current gitlink
  # (current gitlink is moved up first so an older merged commit is an ancestor, not a descendant)
  q -C "$R" checkout main; q -C "$R" reset -q --hard origin/main
  bump "$D" "$MERGED"; q -C "$R" push origin main
  q -C "$R" checkout -b lane/backwards
  bump "$D" "$CUR"   # CUR is merged on origin/main but is an ANCESTOR of the current gitlink
  assert_no "merged but non-descendant (older) gitlink is refused" guard "$R"
  finish
) || rc=1

# ── group 5: a repo with no submodules passes the guard ─────────────────────────────────────
(
  D="$TMP/g5"; mkdir -p "$D"; git init -q -b main "$D/r"; ( cd "$D/r" && echo x > a && git add a && q commit -m i )
  git init -q --bare -b main "$D/r.git"; q -C "$D/r" remote add origin "$D/r.git"; q -C "$D/r" push origin main
  ( cd "$D/r" && q checkout -b lane && echo y >> a && git add a && q commit -m c )
  assert_ok "no-submodule repo passes the guard" guard "$D/r"
  finish
) || rc=1

# ── group 6: the lane merge path runs the guard (gh shim) ────────────────────────────────────
(
  D="$TMP/g6"; mk_fixture "$D"
  R="$D/main"; q -C "$R" submodule update --init
  q -C "$R" checkout -b lane/bad
  UNM="$(sub_commit "$D" feature "u1")"; bump "$D" "$UNM"
  mkdir -p "$D/bin"; printf '#!/usr/bin/env bash\necho "$@" >> "%s/real-gh.calls"\n' "$D" > "$D/bin/gh"; chmod +x "$D/bin/gh"
  SHIM="$ROOT/scripts/lane-bin/gh"
  assert_ok "lane-bin/gh shim exists and is executable" test -x "$SHIM"
  ( cd "$R" && PATH="$ROOT/scripts/lane-bin:$D/bin:$PATH" HARNESS_GUARD_BASE=origin/main gh pr merge --squash 5 ) >/dev/null 2>&1; rcm=$?
  assert_ok 'shim refuses gh pr merge over a bad gitlink' test "$rcm" -ne 0
  assert_no "real gh is not reached on refusal" test -e "$D/real-gh.calls"
  ( cd "$R" && PATH="$ROOT/scripts/lane-bin:$D/bin:$PATH" gh issue list ) >/dev/null 2>&1
  assert_ok "other gh commands pass straight through" grep -q "issue list" "$D/real-gh.calls"
  q -C "$R" reset -q --hard origin/main
  ( cd "$R" && PATH="$ROOT/scripts/lane-bin:$D/bin:$PATH" HARNESS_GUARD_BASE=origin/main gh pr merge --squash 5 ) >/dev/null 2>&1
  assert_ok "clean merge reaches real gh" grep -q "pr merge --squash 5" "$D/real-gh.calls"
  finish
) || rc=1

# ── group 7: a lane in a submodule repo gets the guarded gh first on PATH; any other lane's env is unchanged
(
  GOAL=""; SLUG="acme/widget"; STATS_PY=/nonexistent
  D="$TMP/g7"; mkdir -p "$D/with" "$D/without"; : > "$D/with/.gitmodules"
  session_env sess-1; plain="${SESSION_ENV[*]}"
  session_env sess-1; lane_guard_env "$D/without"
  assert_eq "${SESSION_ENV[*]}" "$plain" "no .gitmodules: the lane env is exactly session_env's"
  session_env sess-1; lane_guard_env "$D/with"
  assert_ok "with .gitmodules: scripts/lane-bin is first on the lane PATH" \
    grep -qF -- "PATH=$ROOT/scripts/lane-bin:" <<<"${SESSION_ENV[*]}"
  assert_ok "launch_agent applies it" grep -q 'lane_guard_env "\$wd"' "$ROOT/scripts/lib.sh"
  finish
) || rc=1

exit $rc

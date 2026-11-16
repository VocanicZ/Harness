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
  # #1179: two lane-bin copies (the worktree's and the engine's) ahead of the real gh used to exec each other forever
  CP="$D/copies"; mkdir -p "$CP/a/scripts" "$CP/b/scripts"; cp -r "$ROOT/scripts/lane-bin" "$CP/a/scripts/"; cp -r "$ROOT/scripts/lane-bin" "$CP/b/scripts/"
  cp "$ROOT/scripts/gitlink-guard.sh" "$CP/a/scripts/"; cp "$ROOT/scripts/gitlink-guard.sh" "$CP/b/scripts/"; ln -s "$CP/a/scripts/lane-bin" "$CP/alias"
  rm -f "$D/real-gh.calls"
  ( cd "$R" && PATH="$CP/a/scripts/lane-bin:$CP/b/scripts/lane-bin:$D/bin:$PATH" timeout 10 gh issue list ) >/dev/null 2>&1
  assert_eq "$?" 0 "two lane-bin copies: gh finishes under timeout"
  assert_ok "…and reaches the real gh" grep -q "issue list" "$D/real-gh.calls"
  ( cd "$R" && PATH="$CP/a/scripts/lane-bin:$CP/alias:$D/bin:$PATH" timeout 10 gh issue view 3 ) >/dev/null 2>&1
  assert_eq "$?" 0 "a lane-bin dir and its symlink: gh finishes under timeout"
  assert_ok "…and reaches the real gh" grep -q "issue view 3" "$D/real-gh.calls"
  assert_eq "$(cd "$R" && PATH="$CP/a/scripts/lane-bin:$CP/b/scripts/lane-bin" /bin/bash "$CP/a/scripts/lane-bin/gh" issue list 2>&1; echo rc=$?)" "gh: command not found
rc=127" "only lane-bin dirs on PATH: gh: command not found, 127"
  finish
) || rc=1

# ── group 7: every lane gets scripts/lane-bin first on PATH (#642); only a submodule repo's gh runs the guard (#470)
(
  GOAL=""; SLUG="acme/widget"; STATS_PY=/nonexistent
  D="$TMP/g7"; mkdir -p "$D/with" "$D/without"; : > "$D/with/.gitmodules"
  session_env sess-1; lane_guard_env "$D/without"
  assert_ok "no .gitmodules: scripts/lane-bin is on the lane PATH too (#642: the git trailer wrapper)" \
    grep -qF -- "PATH=$ROOT/scripts/lane-bin:" <<<"${SESSION_ENV[*]}"
  session_env sess-1; lane_guard_env "$D/with"
  assert_ok "with .gitmodules: scripts/lane-bin is first on the lane PATH" \
    grep -qF -- "PATH=$ROOT/scripts/lane-bin:" <<<"${SESSION_ENV[*]}"
  assert_ok "launch_agent applies it" grep -q 'lane_guard_env "\$wd"' "$ROOT/scripts/lib.sh"
  # On Windows ENGINE_DIR is C:/x (export_native_paths) and a drive colon splits a colon-separated PATH: the entry is the MSYS
  # form (#605). A fake cygpath (-u: /posix<path>) stands in for Git for Windows' on Linux.
  mkdir -p "$D/fakebin"; printf '#!/usr/bin/env bash\n[[ $1 == -u ]] && echo "/posix$2"\n' > "$D/fakebin/cygpath"; chmod +x "$D/fakebin/cygpath"
  session_env sess-1; ( PATH="$D/fakebin:$PATH" HARNESS_PLATFORM=windows; lane_guard_env "$D/without"; printf '%s\n' "${SESSION_ENV[@]}" ) > "$D/winenv"
  assert_ok "windows: the lane PATH entry for lane-bin is the engine dir in MSYS form (a C:/x entry splits at its colon)" \
    grep -qxF "PATH=/posix$ENGINE_DIR/scripts/lane-bin:$D/fakebin:$PATH" "$D/winenv"
  finish
) || rc=1

# ── group 8: submodule issue end to end — submodule merges first, then the gitlink bump (#471) ──
(
  D="$TMP/g8"; mk_fixture "$D"
  R="$D/main"; q -C "$R" submodule update --init
  q -C "$R" checkout -b issue/7
  # lane step 1: work in the submodule on issue/<unit>-<n> (never issue/<n>) and push it
  BR="issue/main-7"; BRSHA="$(sub_commit "$D" "$BR" "lane work")"
  # step 2: squash-merge into the submodule base — the SHA changes
  BASE="$(submodule_base_branch "$R" engine)"
  assert_eq "$BASE" "main" "the resolver names the submodule's base branch"
  ( cd "$D/subwork" && q fetch origin && q checkout -B "$BASE" "origin/$BASE" && q merge --squash "origin/$BR" && q commit -m "squash lane" && q push origin "$BASE" )
  MERGED="$(git -C "$D/subwork" rev-parse HEAD)"
  assert_ok "precondition: a squash merge changed the SHA" test "$MERGED" != "$BRSHA"
  # a bump to the pre-merge branch commit is refused by the guard …
  bump "$D" "$BRSHA"
  assert_no "gitlink at the pre-merge branch commit is refused" guard "$R"
  # … step 3: point the gitlink at the MERGED commit on origin/<base>, step 4: the bump merges
  q -C "$R" reset -q --hard origin/main
  git -C "$R/engine" fetch -q origin; bump "$D" "$(git -C "$R/engine" rev-parse "origin/$BASE")"
  assert_eq "$(git -C "$R" rev-parse HEAD:engine)" "$MERGED" "the bump pins the merged commit on origin/<base>"
  assert_ok "the bump to the merged commit passes the guard" guard "$R"
  finish
) || rc=1

# ── group 9: resume detection looks in every submodule (#471) ────────────────────────────────
(
  D="$TMP/g9"; mk_fixture "$D"
  R="$D/main"; q -C "$R" submodule update --init
  q -C "$R" worktree add -b issue/3 "$D/wt" HEAD; q -C "$D/wt" submodule update --init
  assert_no "no branch anywhere: not pushed" submodule_branch_pushed "$D/wt" "issue/main-3"
  sub_commit "$D" "issue/main-3" "wip" >/dev/null
  assert_ok "branch only in the submodule: found" submodule_branch_pushed "$D/wt" "issue/main-3"
  assert_no "another branch name does not match" submodule_branch_pushed "$D/wt" "issue/3"
  assert_no "a repo without .gitmodules never matches" submodule_branch_pushed "$TMP" "issue/main-3"

  # prepare_impl takes the resume path when issue/<unit>-<n> exists only in the submodule
  source "$ROOT/scripts/drive.sh"
  RENDERED="$D/rendered"; : > "$RENDERED"
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_WORKTREE_HOOK=""
  UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget; HARNESS_SPEC=""; CHECKOUT="$R"; WORKTREES_DIR="$D/wts"; mkdir -p "$WORKTREES_DIR"
  PROJECT_ROOT="$R"; STATE_DIR="$D/state"
  render(){ echo "$1" >> "$RENDERED"; }; ensure_checkout(){ :; }; ensure_safe(){ :; }; default_branch(){ echo main; }
  resume_handoff(){ :; }; cli_subagent(){ :; }; swarm_suite_cmd(){ :; }
  gh(){ case "$1 $2" in "issue view") echo '[]';; esac; return 0; }
  sub_commit "$D" "issue/main-5" "wip" >/dev/null           # #5: the branch is ONLY in the submodule
  prepare_impl 5 "ISSUE 5 DONE" >/dev/null 2>&1
  assert_ok "submodule-only branch: resume.md is rendered" grep -q 'resume.md' "$RENDERED"
  : > "$RENDERED"
  prepare_impl 6 "ISSUE 6 DONE" >/dev/null 2>&1               # #6: no branch anywhere
  assert_ok "no branch anywhere: impl.md is rendered" grep -q 'impl.md' "$RENDERED"
  assert_no "no branch anywhere: not resume.md" grep -q 'resume.md' "$RENDERED"
  finish
) || rc=1

# ── group 10: the prompts tell writers and lanes about submodule code (#471) ─────────────────
(
  P="$ROOT/prompts"
  for f in decompose bug-triage inject; do
    assert_ok "$f.md asks for a ## Code location section naming the submodule path" \
      grep -q '## Code location' "$P/$f.md"
  done
  assert_ok "decompose.md: issues stay in the main repo" grep -q "never in the submodule's own repo" "$P/decompose.md"
  for f in impl bug-fix resume; do
    R="$(source "$ROOT/scripts/lib.sh"; render "$P/$f.md" ISSUE=42 UNIT=orge SLUG=acme/widget BRANCH=issue/42 LABEL_PAUSED=p)"
    assert_ok "$f: submodule branch is issue/<unit>-<n>, rendered" grep -qF 'issue/orge-42' <<<"$R"
    assert_ok "$f: rtdd which runs inside the submodule too" grep -qF 'run `rtdd which` inside the submodule as well as here' <<<"$R"
    assert_ok "$f: merge into the submodule base branch first" grep -qF "BASE branch" <<<"$R"
    assert_ok "$f: gitlink points at the MERGED commit on origin/<base>" grep -qF 'MERGED commit on the submodule' <<<"$R"
    assert_ok "$f: lanes never claim issues from a submodule repo" grep -qF "lanes never claim issues from a submodule's own repo" <<<"$R"
  done
  assert_ok "_rtdd.md points at the submodule rule" grep -q 'inside the submodule too' "$P/_rtdd.md"
  assert_ok "resume.md checks a submodule-only branch" grep -q 'ONLY in a submodule' "$P/resume.md"
  finish
) || rc=1

# ── group 11: lane worktree submodules borrow the main checkout's objects (#1207) ─────────────
# A plain `submodule update --init --recursive` in a linked worktree clones every submodule in full
# (a 1 GB pack per lane). file:// URLs, so a local-clone hardlink cannot mask a full copy.
(
  D="$TMP/g11"; mkdir -p "$D"; BLOB=3000000
  F="file://$D"
  # mk11 <name> — bare remote <name>.git with a big blob, work clone <name>w; pushes main.
  mk11(){ git init -q --bare -b main "$D/$1.git"; git clone -q "$F/$1.git" "$D/$1w" 2>/dev/null
    ( cd "$D/$1w" && git checkout -q -b main 2>/dev/null; head -c $BLOB /dev/urandom > big; git add big; q commit -m c1; q push origin main ); }
  mk11 nest; mk11 sub; mk11 other
  ( cd "$D/subw" && git submodule add -q "$F/nest.git" nest 2>/dev/null && q commit -m "add nest" && q push origin main )
  git init -q -b main "$D/main"
  ( cd "$D/main" && echo hi > README; git add README; q commit -m init \
      && git submodule add -q "$F/sub.git" engine 2>/dev/null && git submodule add -q "$F/other.git" other 2>/dev/null \
      && q commit -m "add submodules" && git submodule update --init --recursive -q 2>/dev/null )
  M="$D/main"; MG="$(git -C "$M" rev-parse --path-format=absolute --git-common-dir)"
  kb(){ du -sk "$1" | cut -f1; }
  FULLKB=$((BLOB / 1024))

  # (a) every level borrows from its OWN main-side counterpart
  q -C "$M" worktree add -b issue/11 "$D/wt1" HEAD
  submodule_init "$D/wt1"; assert_eq "$?" 0 "borrowing init: returns 0"
  W1G="$(git -C "$D/wt1" rev-parse --path-format=absolute --git-common-dir)"
  for pair in "engine:modules/engine" "other:modules/other" "engine/nest:modules/engine/modules/nest"; do
    p="${pair%%:*}"; want="${pair#*:}"
    git -C "$D/wt1/$p" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { assert_ok "$p is checked out" false; continue; }
    od="$(git -C "$D/wt1/$p" rev-parse --path-format=absolute --git-path objects)"
    assert_ok "$p: objects/info/alternates exists" test -f "$od/info/alternates"
    assert_eq "$(sed 's#\\#/#g' "$od/info/alternates" 2>/dev/null | head -1 | sed -E 's#^.*/\.git/(modules/.*)$#\1#')" "$want/objects" \
      "$p: alternates names its own main-side objects"
    assert_ok "$p: lane objects dir is not a copy (<< blob size)" test "$(kb "$od")" -lt $((FULLKB / 4))
    assert_eq "$(git -C "$D/wt1/$p" rev-parse HEAD)" "$(git -C "$M/$p" rev-parse HEAD)" "$p: sits at the gitlink commit"
    assert_ok "$p: object store is consistent" git -C "$D/wt1/$p" fsck --connectivity-only
  done
  assert_ok "the nested file is checked out" test -s "$D/wt1/engine/nest/big"

  # (b) main-side module dir absent for one submodule -> that one is a plain clone, the other still borrows
  git init -q -b main "$D/main2"
  ( cd "$D/main2" && echo hi > README; git add README; q commit -m init \
      && git submodule add -q "$F/sub.git" engine 2>/dev/null && git submodule add -q "$F/other.git" other 2>/dev/null \
      && q commit -m "add submodules" && git submodule update --init --recursive -q -- engine 2>/dev/null \
      && git submodule deinit -f -q other 2>/dev/null; rm -rf .git/modules/other )
  assert_no "precondition: main2 never initialised other" test -d "$D/main2/.git/modules/other"
  q -C "$D/main2" worktree add -b issue/12 "$D/wt2" HEAD
  submodule_init "$D/wt2"; assert_eq "$?" 0 "missing reference: returns 0"
  assert_ok "missing reference: other is checked out at all" test -s "$D/wt2/other/big"
  assert_eq "$(git -C "$D/wt2/other" rev-parse HEAD)" "$(git -C "$D/main2" rev-parse HEAD:other)" "missing reference: other at the gitlink"
  assert_no "missing reference: other has no alternates" test -f "$D/wt2/other/.git" -a -f "$(git -C "$D/wt2/other" rev-parse --path-format=absolute --git-path objects/info/alternates)"
  assert_ok "missing reference: engine still borrows" test -f "$(git -C "$D/wt2/engine" rev-parse --path-format=absolute --git-path objects/info/alternates)"
  assert_ok "missing reference: nested submodule of engine still borrows" test -f "$(git -C "$D/wt2/engine/nest" rev-parse --path-format=absolute --git-path objects/info/alternates)"

  # (c) main checkout's submodule sits at an OLDER commit than the lane's gitlink: missing objects come from the remote
  ( cd "$D/otherw" && echo 2 > f2 && git add f2 && q commit -m c2 && q push origin main )
  NEW="$(git -C "$D/otherw" rev-parse HEAD)"
  ( cd "$M" && git update-index --cacheinfo "160000,$NEW,other" && q commit -m "bump other" )
  assert_ok "precondition: main's other is behind the gitlink" test "$(git -C "$M/other" rev-parse HEAD)" != "$NEW"
  q -C "$M" worktree add -b issue/13 "$D/wt3" HEAD
  submodule_init "$D/wt3"; assert_eq "$?" 0 "stale reference: returns 0"
  assert_eq "$(git -C "$D/wt3/other" rev-parse HEAD)" "$NEW" "stale reference: other at the lane's gitlink"
  assert_ok "stale reference: the new file is checked out" test -f "$D/wt3/other/f2"
  assert_ok "stale reference: still borrows" test -f "$(git -C "$D/wt3/other" rev-parse --path-format=absolute --git-path objects/info/alternates)"

  # (d) a real failure (unreachable remote) still returns non-zero, and the other submodules are still done
  q -C "$M" worktree add -b issue/14 "$D/wt4" HEAD
  mv "$D/sub.git" "$D/sub.git.off"
  submodule_init "$D/wt4" >/dev/null 2>&1; rc4=$?; mv "$D/sub.git.off" "$D/sub.git"
  assert_ok "init failure: returns non-zero" test "$rc4" -ne 0
  assert_ok "init failure: the other submodule is still checked out" test -s "$D/wt4/other/big"
  assert_no "init failure: the failed one is not" test -s "$D/wt4/engine/big"
  finish
) || rc=1

exit $rc

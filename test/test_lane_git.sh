#!/usr/bin/env bash
# test_lane_git.sh — #642: every lane commit credits the Harness GitHub identity. scripts/lane-bin/git is the
# `git` a lane gets first on PATH; `git commit` through it carries the Harness `Co-authored-by` trailer
# (HARNESS_COAUTHOR, empty = off), every other subcommand is passed through untouched, an amend or a message
# that already ends with the trailer does not get it twice, and a Claude trailer sits beside it. lane_guard_env puts
# lane-bin on EVERY lane's PATH (not only a submodule repo's) and hands HARNESS_COAUTHOR on to the lane.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
TRAILER='Co-authored-by: Harness <353635118+vocanicz-harness[bot]@users.noreply.github.com>'
CLAUDE='Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>'
LB="$ROOT/scripts/lane-bin"
T="$(mktemp -d)"; tmp_track "$T"
git init -q -b main "$T/r"; git -C "$T/r" config user.email t@t; git -C "$T/r" config user.name t
echo 1 > "$T/r/a"; git -C "$T/r" add a
# lg ... — the wrapped git: lane-bin first on PATH, the real git behind it
lg(){ PATH="$LB:$PATH" git "$@"; }
body(){ git -C "${2:-$T/r}" log -1 --format=%B | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }
count(){ body | grep -cxF -- "$TRAILER"; }

echo "== the commit gets the trailer =="
assert_ok "wrapper exists and is executable" test -x "$LB/git"
( cd "$T/r" && lg commit -q -m "x" ); assert_eq "$(body | tail -1)" "$TRAILER" "git commit -m: the message ends with the Harness trailer"
assert_eq "$(body | head -1)" x "…the subject is untouched"
echo 2 >> "$T/r/a"; git -C "$T/r" add a
( cd "$T/r" && lg -C "$T/r" commit -q -m "c" ); assert_eq "$(count)" 1 "git -C <dir> commit: trailer"
echo 3 >> "$T/r/a"; git -C "$T/r" add a
( cd "$T/r" && lg -c a.b=v commit -q -m "k" ); assert_eq "$(count)" 1 "git -c k=v commit: trailer"
echo 4 >> "$T/r/a"; git -C "$T/r" add a
( cd "$T/r" && lg -c a.b=v -C "$T/r" --no-pager commit -q -m "kc" ); assert_eq "$(count)" 1 "-c, -C and a flag option before commit: trailer"
( cd "$T" && lg -C r commit -q --allow-empty -m "e" ); assert_eq "$(count)" 1 "git commit --allow-empty: trailer"

echo "== no duplicate =="
( cd "$T/r" && lg commit -q --allow-empty --amend --no-edit && lg commit -q --allow-empty --amend --no-edit && lg commit -q --allow-empty --amend -m "again" )
assert_eq "$(count)" 1 "repeated --amend: the trailer once"
( cd "$T/r" && lg commit -q --allow-empty -m "$(printf 'm\n\n%s' "$TRAILER")" )
assert_eq "$(count)" 1 "a message that already ends with the trailer: once"

echo "== beside the Claude trailer =="
( cd "$T/r" && lg commit -q --allow-empty -m "$(printf 'feat: y\n\n%s' "$CLAUDE")" )
assert_ok "both trailers on the commit" test "$(body | grep -cxF -e "$TRAILER" -e "$CLAUDE")" = 2
( cd "$T/r" && lg commit -q --allow-empty --amend --no-edit )
assert_eq "$(count)" 1 "amend over both trailers: Harness once"
assert_eq "$(body | grep -cxF -- "$CLAUDE")" 1 "…Claude once"

echo "== opt-out and override =="
( cd "$T/r" && HARNESS_COAUTHOR= lg commit -q --allow-empty -m "off" ); assert_eq "$(count)" 0 "HARNESS_COAUTHOR= (empty): no trailer"
assert_eq "$(body)" off "…the message is exactly what was given"
( cd "$T/r" && HARNESS_COAUTHOR='Co-authored-by: Other <o@o>' lg commit -q --allow-empty -m "o" )
assert_eq "$(body | tail -1)" 'Co-authored-by: Other <o@o>' "HARNESS_COAUTHOR=<trailer>: that trailer"

echo "== everything else passes through byte for byte =="
echo 5 >> "$T/r/a"
for args in "status -s" "log --oneline" "diff" "rev-parse HEAD" "-C $T/r status --porcelain" "--version"; do
  want="$(cd "$T/r" && git $args 2>&1; echo "rc=$?")"; got="$(cd "$T/r" && lg $args 2>&1; echo "rc=$?")"
  assert_eq "$got" "$want" "git $args"
done
tree="$(git -C "$T/r" write-tree)"; head="$(git -C "$T/r" rev-parse HEAD)"
c1="$(cd "$T/r" && git commit-tree "$tree" -p "$head" -m "ct")"; c2="$(cd "$T/r" && lg commit-tree "$tree" -p "$head" -m "ct")"
assert_eq "$(git -C "$T/r" log -1 --format=%B "$c2")" "$(git -C "$T/r" log -1 --format=%B "$c1")" "git commit-tree: no trailer added"
assert_no "git commit-tree message has no Harness trailer" git -C "$T/r" log -1 --format=%B "$c2" | grep -qF "$TRAILER"
( cd "$T/r" && lg commit-tree "$tree" -p "$head" -m ct ) >/dev/null
( cd "$T/r" && lg commit --dry-run -q ) >/dev/null 2>&1; assert_eq "$(git -C "$T/r" rev-parse HEAD)" "$head" "git commit --dry-run: no commit made"

echo "== a missing real git =="
assert_eq "$(PATH="$LB" /bin/bash "$LB/git" status 2>&1; echo rc=$?)" "git: command not found
rc=127" "no real git on PATH: 127"

echo "== two lane-bin copies on PATH do not loop (#1179) =="
# the worktree's lane-bin and the installed engine's lane-bin are both on a lane PATH; each wrapper used to take the other for "the real
# git" and the two exec'd each other forever. A wrapper skips every candidate that is itself a lane-bin wrapper. Each call is under timeout.
CP="$T/copies"; mkdir -p "$CP/a/scripts" "$CP/b/scripts"; cp -r "$LB" "$CP/a/scripts/"; cp -r "$LB" "$CP/b/scripts/"
ln -s "$CP/a/scripts/lane-bin" "$CP/alias"
RGD="$(dirname "$(PATH="$LB:$PATH" real_git)")"
TWO="$CP/a/scripts/lane-bin:$CP/b/scripts/lane-bin:$RGD"
out="$(PATH="$TWO" timeout 10 git --version 2>&1)"; assert_eq "$?" 0 "two copies: git --version finishes"
assert_ok "…and prints the version" grep -q '^git version' <<<"$out"
assert_ok "two copies: git status finishes" bash -c 'cd "$1" && PATH="$2" timeout 10 git status -s' _ "$T/r" "$TWO"
echo 6 >> "$T/r/a"; git -C "$T/r" add a
( cd "$T/r" && PATH="$TWO" timeout 10 git commit -q -m "two" ); assert_eq "$?" 0 "two copies: git commit finishes"
assert_eq "$(count)" 1 "…and the commit carries the Harness trailer once"
( cd "$T/r" && PATH="$CP/a/scripts/lane-bin:$CP/alias:$RGD" timeout 10 git --version ) >/dev/null 2>&1
assert_eq "$?" 0 "a symlink to the lane-bin dir ahead of the real git: no loop"
( cd "$T/r" && PATH="$CP/alias:$CP/a/scripts/lane-bin:$RGD" timeout 10 git --version ) >/dev/null 2>&1
assert_eq "$?" 0 "…the symlink first, the dir second: no loop"
assert_eq "$(PATH="$CP/a/scripts/lane-bin:$CP/b/scripts/lane-bin" /bin/bash "$CP/a/scripts/lane-bin/git" status 2>&1; echo rc=$?)" "git: command not found
rc=127" "only lane-bin dirs on PATH: git: command not found, 127"
assert_eq "$(PATH="$CP/a/scripts/lane-bin:$CP/alias" /bin/bash "$CP/a/scripts/lane-bin/git" status 2>&1; echo rc=$?)" "git: command not found
rc=127" "a lane-bin dir and its symlink only: 127"

echo "== the lane environment =="
GOAL=""; SLUG="acme/widget"; STATS_PY=/nonexistent
mkdir -p "$T/with" "$T/without"; : > "$T/with/.gitmodules"
for d in with without; do
  session_env s-1; lane_guard_env "$T/$d"
  assert_ok "$d .gitmodules: lane-bin first on the lane PATH" grep -qF -- "PATH=$LB:" <<<"${SESSION_ENV[*]}"
  assert_ok "$d .gitmodules: HARNESS_COAUTHOR is the Harness trailer" \
    grep -qxF -- "HARNESS_COAUTHOR=$TRAILER" <<<"$(printf '%s\n' "${SESSION_ENV[@]}")"
done
HARNESS_COAUTHOR= session_env s-1; HARNESS_COAUTHOR= lane_guard_env "$T/without"
assert_ok "an empty HARNESS_COAUTHOR reaches the lane as empty" grep -qxF -- "HARNESS_COAUTHOR=" <<<"$(printf '%s\n' "${SESSION_ENV[@]}")"
CFGD="$(mktemp -d)"; tmp_track "$CFGD"; printf '%s\n' 'HARNESS_COAUTHOR=' > "$CFGD/config"
assert_eq "$(unset HARNESS_COAUTHOR; STATE_DIR="$CFGD" bash -c 'source "$1/scripts/lib.sh"; printf "[%s]" "$HARNESS_COAUTHOR"' _ "$ROOT" 2>/dev/null)" "[]" ".harness/config HARNESS_COAUTHOR= turns it off"
assert_eq "$(unset HARNESS_COAUTHOR; bash -c 'source "$1/scripts/lib.sh"; printf "%s" "$HARNESS_COAUTHOR"' _ "$ROOT" 2>/dev/null)" "$TRAILER" "unset: the default trailer"

echo "== a wrapper in front of lane-bin does not loop (#1177) =="
# test_drive.sh's winfake/git and test_tier.sh's $GBIN/git exec "the real git" while lane-bin is first on the lane PATH. A bare
# `command -v git` there is lane-bin/git itself, which picks the first git on PATH that is not its own dir: the wrapper, and the two
# exec each other forever. real_git (helpers.sh) skips every scripts/lane-bin.
RG="$(PATH="$LB:$PATH" real_git)"
assert_ok "real_git is an executable git" test -x "$RG"
assert_no "real_git is not a scripts/lane-bin/git, lane-bin first on PATH" test "$(cd "$(dirname "$RG")" && pwd)" = "$LB"
assert_eq "$(cd "$(dirname "$RG")" && pwd | grep -c 'scripts/lane-bin$')" 0 "real_git: its dir is no scripts/lane-bin"
mkdir -p "$T/wf"; printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$RG" > "$T/wf/git"; chmod +x "$T/wf/git"
out="$(PATH="$T/wf:$LB:$PATH" timeout 10 git --version 2>&1)"; rc=$?
assert_eq "$rc" 0 "wrapper -> real_git -> git --version finishes (not 124)"
assert_ok "…and prints the version" grep -q '^git version' <<<"$out"
# the old resolution is the loop: lane-bin first on PATH, `command -v git` is lane-bin/git, and the wrapper in front of it cycles
BAD="$(PATH="$LB:$PATH" command -v git)"
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$BAD" > "$T/wf/git"
PATH="$T/wf:$LB:$PATH" timeout 3 git --version >/dev/null 2>&1; assert_eq "$?" 124 "(control) command -v git behind a wrapper loops: timeout 124"

echo "== gh in a repo without .gitmodules is unchanged =="
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\necho "$@" >> "%s/real-gh.calls"\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"
( cd "$T/r" && PATH="$LB:$T/bin:$PATH" gh pr merge --squash 5 ) >/dev/null 2>&1
assert_ok "gh pr merge reaches the real gh, no guard run" grep -q "pr merge --squash 5" "$T/real-gh.calls"
finish

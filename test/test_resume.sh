#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"; make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme
RENDERED="$RUN_DIR/rendered"; : > "$RENDERED"
# stubs: record which template render() was asked for; no real tmux/git/gh
render(){ echo "$1" >> "$RENDERED"; : ; }
launch_claude(){ :; }
ensure_checkout(){ return 0; }
default_branch(){ echo main; }
gh(){ case "$1 $2" in "issue view") echo '{"labels":[{"name":"agent-paused"}]}';; *) : ;; esac; return 0; }
git(){ case "$*" in *"ls-remote"*) echo "abc123	refs/heads/issue/5";; *) : ;; esac; return 0; }
export -f gh git
# spawn_impl writes the rendered task into $wd/.harness-task.md, so $wd must exist.
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR/main-i5" "$WORKTREES_DIR/main-i6"
# drive_unit sets the dynamic-scope vars; call spawn_impl directly inside that scope:
UNIT=main REPO=acme/widget SLUG=acme/widget PROJECT=main DESC=widget CHECKOUT="$PROJECT_ROOT"
spawn_impl 5 "ISSUE 5 DONE"
assert_ok "resume issue rendered resume.md" bash -c "grep -q 'resume.md' '$RENDERED'"
assert_no "resume issue did NOT render impl.md" bash -c "grep -q 'impl.md' '$RENDERED'"
# a fresh (non-paused, no remote branch) issue renders impl.md
: > "$RENDERED"
gh(){ case "$1 $2" in "issue view") echo '{"labels":[{"name":"ready-for-agent"}]}';; *) : ;; esac; return 0; }
git(){ case "$*" in *"ls-remote"*) echo "";; *) : ;; esac; return 0; }
export -f gh git
spawn_impl 6 "ISSUE 6 DONE"
assert_ok "fresh issue rendered impl.md" bash -c "grep -q 'impl.md' '$RENDERED'"
# an issue with NO paused label but an EXISTING remote branch also resumes (ls-remote arm)
: > "$RENDERED"
mkdir -p "$WORKTREES_DIR/main-i7"
gh(){ case "$1 $2" in "issue view") echo '{"labels":[{"name":"ready-for-agent"}]}';; *) : ;; esac; return 0; }
git(){ case "$*" in *"ls-remote"*) echo "abc123	refs/heads/issue/7";; *) : ;; esac; return 0; }
export -f gh git
spawn_impl 7 "ISSUE 7 DONE"
assert_ok "remote-branch issue rendered resume.md" bash -c "grep -q 'resume.md' '$RENDERED'"
assert_no "remote-branch issue did NOT render impl.md" bash -c "grep -q 'impl.md' '$RENDERED'"
finish

#!/usr/bin/env bash
# test_version.sh — PRD #274 / #277: every install knows its version. A release archive's VERSION
# (tag, then commit) is what `harness --version` prints; a git checkout with none prints a dev build.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"   # outside any project: no .harness/config here or in any parent
hv(){ env -u STATE_DIR -u ENGINE_DIR bash "$1/bin/harness" "${@:2}"; }

# A release-shaped engine: the real entrypoint plus a VERSION file, and no .git.
REL="$T/rel"; mkdir -p "$REL/bin"; cp "$HERE/../bin/harness" "$REL/bin/"
printf 'v0.1.0\n0123456789abcdef0123456789abcdef01234567\n' > "$REL/VERSION"
out="$(hv "$REL" --version)"; rc=$?
assert_eq "$rc" 0 "--version exits 0"
assert_eq "$out" "harness v0.1.0 (0123456)" "--version prints the tag and the short commit"
assert_eq "$(hv "$REL" version)" "$out" "'harness version' is the same command"

# A git checkout with no VERSION: git describe, marked as a dev build, never a failure.
DEV="$T/dev"; mkdir -p "$DEV/bin"; cp "$HERE/../bin/harness" "$DEV/bin/"
gc "$DEV" init -q; gc "$DEV" add -A; gc "$DEV" commit -qm init; gc "$DEV" tag -a v0.1.0 -m v0.1.0
printf 'x\n' > "$DEV/extra"; gc "$DEV" add -A; gc "$DEV" commit -qm more
out="$(hv "$DEV" --version)"; rc=$?
assert_eq "$rc" 0 "a dev checkout's --version exits 0"
assert_ok "a dev checkout prints git describe, marked dev" \
  grep -qE '^harness v0\.1\.0-1-g[0-9a-f]+ \(dev checkout\)$' <<<"$out"

# Neither VERSION nor .git: still a line, still exit 0.
BARE="$T/bare"; mkdir -p "$BARE/bin"; cp "$HERE/../bin/harness" "$BARE/bin/"
out="$(hv "$BARE" --version)"; rc=$?
assert_eq "$rc" 0 "an engine with no VERSION and no .git still exits 0"
assert_eq "$out" "harness unknown (no VERSION file)" "and says why it cannot name a version"

# An engine dir with no VERSION that merely sits INSIDE someone else's git repo (a dotfiles $HOME,
# a vendored copy) is not a dev checkout of Harness: it must not report that repo's describe.
HOST="$T/host"; mkdir -p "$HOST/eng/bin"; cp "$HERE/../bin/harness" "$HOST/eng/bin/"
gc "$HOST" init -q; printf 'y\n' > "$HOST/f"; gc "$HOST" add f; gc "$HOST" commit -qm host
out="$(hv "$HOST/eng" --version)"; rc=$?
assert_eq "$rc" 0 "an engine nested in an unrelated git repo exits 0"
assert_eq "$out" "harness unknown (no VERSION file)" "and does not borrow that repo's describe"

assert_ok "harness help lists --version" grep -qF -- '--version' <<<"$(hv "$REL" help)"
assert_ok "VERSION is never committed" grep -qx '/VERSION' "$HERE/../.gitignore"
finish

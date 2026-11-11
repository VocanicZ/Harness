#!/usr/bin/env bash
# rtdd: always
# test_tmux_short_dir_real.sh — #1077: a REAL tmux server starts on the dir tmux_short_dir makes, under a TMPDIR of 150+ bytes, where the
# same server on a dir under that TMPDIR fails with "error connecting to … (File name too long)". The path-length, hygiene and lint
# assertions need no tmux and are in test_tmux_short_dir.sh (its headless twin, test/tmux_twins.tsv). Kills only its own private server.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
command -v tmux >/dev/null 2>&1 || { echo "  skip: tmux not installed"; exit 0; }
ROOT="$(mktemp -d)"; tmp_track "$ROOT"
deep="$ROOT"; while (( ${#deep} < 150 )); do deep="$deep/$(printf 'x%.0s' {1..40})"; done
mkdir -p "$deep"
# the old way: a TMUX_TMPDIR under that TMPDIR — proves the probe below would have caught the bug
old="$deep/tmux-claude"; mkdir -p "$old"
assert_no "(control) a TMUX_TMPDIR under that TMPDIR is too long for tmux" bash -c 'env -u TMUX TMUX_TMPDIR="$1" tmux new-session -d -s hxctl "sleep 5" 2>/dev/null' _ "$old"
env -u TMUX TMUX_TMPDIR="$old" tmux kill-server 2>/dev/null
out="$(env -u TMUX_TMPDIR TMPDIR="$deep" bash -c '
  source "$1/helpers.sh"; tmux_short_dir || exit 1
  echo "$TMUX_TMPDIR"
  tmux new-session -d -s hx1077 "sleep 30" && tmux has-session -t hx1077 && echo started
  tmux -L "lm$$" new-session -d -s hx1077b "sleep 30" && tmux -L "lm$$" has-session -t hx1077b && echo started-L
  tmux -L "lm$$" kill-server 2>/dev/null; tmux kill-server 2>/dev/null' _ "$HERE")"
assert_eq "$(sed -n 2p <<<"$out")" "started" "a real tmux server starts on the helper's dir (no more File name too long)"
assert_eq "$(sed -n 3p <<<"$out")" "started-L" "…and one on a -L lm<pid> socket in it"
assert_no "…and nothing is left of the dir" test -e "$(sed -n 1p <<<"$out")"
finish

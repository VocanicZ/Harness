#!/usr/bin/env bash
# rtdd: always
# test_tmux_short_dir.sh — #1077: a tmux socket path is a fixed-size kernel field (AF_UNIX sun_path: 108 bytes with the NUL), but
# the tests derived TMUX_TMPDIR from `mktemp -d`, which inherits the whole depth of $TMPDIR. The release gate (#1060) runs run.sh
# under TMPDIR=$tmp/gate-tmp, run.sh nests each test under it, and the socket path
#   $TMUX_TMPDIR/tmux-$UID/<socket>
# came to 110-126 bytes: tmux said "error connecting to … (File name too long)" and every supervisor-frozen cell went red.
# The fix is ONE helper, tmux_short_dir (test/helpers.sh): a private, tracked dir directly under /tmp, whatever $TMPDIR is.
#   1. dynamic — under a TMPDIR of 150+ bytes the helper's socket path is short (no tmux needed; the real server that starts on it
#      is test_tmux_short_dir_real.sh, whose headless twin is this file)
#   2. the helper keeps #649 (private, existing, never /tmp itself, TMUX dropped) and temp hygiene (#294: nothing left in /tmp)
#   3. static  — no test that starts a real tmux server derives its TMUX_TMPDIR from mktemp / $RUN_DIR / $T / $ROOT; the lint has
#      its own good and bad fixtures, and runs over every test/test_*.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
export HARNESS_SESSION_BACKEND=headless   # the twin of test_tmux_short_dir_real.sh (test/tmux_twins.tsv): no tmux anywhere in this file
ROOT="$(mktemp -d)"; tmp_track "$ROOT"
UIDN="$(id -u)"

echo "== the helper exists =="
assert_ok "helpers.sh defines tmux_short_dir" declare -F tmux_short_dir

echo "== dynamic: a TMPDIR of 150+ bytes does not lengthen the socket path =="
deep="$ROOT"; while (( ${#deep} < 150 )); do deep="$deep/$(printf 'x%.0s' {1..40})"; done
mkdir -p "$deep"
# probe — what tmux_short_dir leaves in a child shell whose TMPDIR is $deep; prints dir, then whether TMUX/TMUX_PANE survived
probe(){ env -u TMUX_TMPDIR TMUX=/nonexistent/sock,1,0 TMUX_PANE=%3 TMPDIR="$deep" bash -c '
  source "$1/helpers.sh"; tmux_short_dir || exit 1
  echo "$TMUX_TMPDIR"; echo "${TMUX-unset}/${TMUX_PANE-unset}"
 ' _ "$HERE"; }
out="$(probe)"; dir="$(sed -n 1p <<<"$out")"; envs="$(sed -n 2p <<<"$out")"
assert_ok "the helper returned a directory name" test -n "$dir"
assert_ok "…it is a short path (< 100 with /tmux-$UIDN/default)" test $(( ${#dir} + ${#UIDN} + 15 )) -lt 100
assert_ok "…and with the longest -L name the suite uses (lm<pid>)" test $(( ${#dir} + ${#UIDN} + 8 + ${#BASHPID} + 4 )) -lt 100
assert_no "…it is not under the 150-byte TMPDIR" test "${dir#"$deep"}" != "$dir"
assert_no "…it is not /tmp itself (#649)" test "${dir%/}" = /tmp
assert_eq "$envs" "unset/unset" "…and TMUX and TMUX_PANE are dropped (#649)"
assert_no "…the dir is gone after the shell exits (#294)" test -e "$dir"

echo "== hygiene: the dir is removed when the test's own EXIT trap runs tmp_cleanup =="
out="$(env -u TMUX_TMPDIR TMPDIR="$deep" bash -c '
  source "$1/helpers.sh"; trap "tmp_cleanup" EXIT; tmux_short_dir; echo "$TMUX_TMPDIR"' _ "$HERE")"
assert_no "an EXIT trap with tmp_cleanup removes it" test -e "$out"

# ── static: a real-tmux test never builds TMUX_TMPDIR from a temp-derived path (#1077) ─────────────────────
# "starts a real server" = a non-comment line with `new-session` that is not a stub body, a grep, a printf'd probe or an assert text.
# "derived" = TMUX_TMPDIR= assigned from $(mktemp…), $RUN_DIR, $T, $ROOT or $TMPDIR. The pattern is built from parts: spelled out,
# the lint would match this file.
ns=new; ns="$ns-session"
NS_RE="(^|[;&|({'\"[:space:]])${ns}([^A-Za-z0-9_-]|\$)"
NS_SKIP='grep|assert_|printf|echo|tmux\(\)|== '"${ns}"
DERIVED_RE='(^|[^A-Za-z0-9_])TMUX_TMPDIR=("|)(\$\(mktemp|\$\{?(RUN_DIR|TMPDIR|T|ROOT)([^A-Za-z0-9_]|$))'
tmux_dir_offenders(){ local f code
  for f in "$@"; do
    code="$(grep -v '^[[:space:]]*#' "$f")"
    grep -E "$NS_RE" <<<"$code" | grep -vE "$NS_SKIP" >/dev/null || continue   # no real server started
    grep -E "$DERIVED_RE" <<<"$code" >/dev/null && echo "${f##*/}"
  done | LC_ALL=C sort; }
LINT="$ROOT/lint"; mkdir -p "$LINT"
printf 'export TMUX_TMPDIR="$T/tmux"\ntmux %s -d -s x\n' "$ns"                          > "$LINT/test_dir_bad_T.sh"
printf 'export TMUX_TMPDIR="$(mktemp -d)"\ntmux %s -d -s x\n' "$ns"                    > "$LINT/test_dir_bad_mktemp.sh"
printf 'TMUX_TMPDIR="$RUN_DIR/tmux-$cli"; tmux %s -d -s x\n' "$ns"                      > "$LINT/test_dir_bad_run_dir.sh"
printf 'export TMUX_TMPDIR=$ROOT/tmux\nenv tmux %s -d -s x\n' "$ns"                    > "$LINT/test_dir_bad_root.sh"
printf 'tmux_short_dir\ntmux %s -d -s x\n' "$ns"                                         > "$LINT/test_dir_good_helper.sh"
printf 'export TMUX_TMPDIR="$HOSTSOCK"\ntmux %s -d -s x\n' "$ns"                       > "$LINT/test_dir_good_other.sh"
printf 'export TMUX_TMPDIR="$T/tmux"\nassert_ok "tmux %s sets -e" grep -q x y\n' "$ns"  > "$LINT/test_dir_good_assert.sh"
printf 'export TMUX_TMPDIR="$T/tmux"\ntmux(){ case "$1" in %s) echo 1;; esac; }\n' "$ns" > "$LINT/test_dir_good_stub.sh"
printf '# export TMUX_TMPDIR="$T/tmux"\ntmux %s -d -s x\n' "$ns"                         > "$LINT/test_dir_good_comment.sh"
assert_eq "$(tmux_dir_offenders "$LINT"/test_dir_bad_* | tr '\n' ' ')" \
  "test_dir_bad_T.sh test_dir_bad_mktemp.sh test_dir_bad_root.sh test_dir_bad_run_dir.sh " "the lint catches a planted \$T / mktemp / \$RUN_DIR / \$ROOT dir"
assert_eq "$(tmux_dir_offenders "$LINT"/test_dir_good_*)" "" "...and passes the helper, another dir, an assert text, a stub and a comment"
assert_eq "$(tmux_dir_offenders "$HERE"/test_*.sh | tr '\n' ' ')" "" "no test that starts a real tmux server takes its TMUX_TMPDIR from a temp-derived path"
finish

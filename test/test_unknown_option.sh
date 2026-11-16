#!/usr/bin/env bash
# test_unknown_option.sh — #1134: one wording for an unknown option across the harness subcommands that reject one:
#   harness <cmd>: unknown option '<arg>'   then the usage, on stderr, exit 2, nothing on stdout.
# Only subcommands that are safe to run with a bogus option are run (none starts a fleet, a poller or a server).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
CLI="$HERE/../bin/harness"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/proj/.harness"
: >"$T/proj/.harness/config"
export HOME="$T/home" HARNESS_HOME="$T/hh"
unset STATE_DIR TMUX

# run_x CMD ARG — run `harness CMD ARG` in the temp project; sets OUT (stdout), ERR (stderr), RC.
run_x(){ local cmd="$1" arg="$2"
  OUT="$(cd "$T/proj" && "$CLI" --state-dir="$T/proj/.harness" "$cmd" "$arg" 2>"$T/err" </dev/null)"; RC=$?
  ERR="$(cat "$T/err")"; }

echo "== every subcommand that rejects an option words it the same way (#1134) =="
for c in supervise web poll release doctor; do
  run_x "$c" -x
  assert_eq "$RC" 2 "$c -x: exit 2"
  assert_eq "$OUT" "" "$c -x: nothing on stdout"
  assert_eq "$(sed -n 1p <<<"$ERR")" "harness $c: unknown option '-x'" "$c -x: first stderr line"
  assert_ok "$c -x: usage on stderr" grep -q "^usage: harness $c" <<<"$ERR"
done

echo "== a long option and a dash-less stray =="
run_x supervise --bogus
assert_eq "$(sed -n 1p <<<"$ERR")" "harness supervise: unknown option '--bogus'" "supervise --bogus"
run_x release --bogus
assert_eq "$(sed -n 1p <<<"$ERR")" "harness release: unknown option '--bogus'" "release --bogus"
run_x web stray
assert_eq "$(sed -n 1p <<<"$ERR")" "harness web: unknown argument 'stray'" "web stray is an argument, not an option"
assert_eq "$RC" 2 "web stray: exit 2"
run_x poll stray
assert_eq "$(sed -n 1p <<<"$ERR")" "harness poll: unknown argument 'stray'" "poll stray is an argument, not an option"

echo "== a control character never reaches the terminal raw =="
for c in supervise web poll release; do
  run_x "$c" $'-a\fb'
  assert_eq "$(sed -n 1p <<<"$ERR")" "harness $c: unknown option '-a?b'" "$c: control char shown as ?"
done

finish

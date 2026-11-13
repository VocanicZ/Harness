#!/usr/bin/env bash
# test_attach_args.sh — #1121 / PRD #475: `harness attach` checks its arguments before it looks for a session.
# A dash-led unit used to become a session name (`no live session 'pz--x-p0'`, exit 1); a non-numeric issue
# became part of one (`pz-main-i-x`). Now --help/-h print the usage (exit 0), any other dash-led unit is a
# usage error (exit 2), and an issue that is not a number is a usage error naming the value.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
make_env
export HARNESS_SESS_PREFIX=aa
trap 'tmp_cleanup' EXIT
ATTACH="$ROOT/scripts/attach.sh"

# attach_run <args…> — sets OUT (stdout), ERR (stderr) and RC.
attach_run(){ OUT="$(bash "$ATTACH" "$@" 2>"$RUN_DIR/err")"; RC=$?; ERR="$(cat "$RUN_DIR/err")"; }
has(){ [[ "$1" == *"$2"* ]]; }

echo "== --help and -h print the usage and exit 0 =="
for a in --help -h; do
  attach_run "$a"
  assert_eq "$RC" 0 "attach $a exits 0"
  assert_ok "attach $a prints the usage on stdout" has "$OUT" "usage: attach.sh <unit> [issue]"
  assert_eq "$ERR" "" "attach $a prints nothing on stderr"
done
attach_run main --help
assert_eq "$RC" 0 "attach main --help exits 0"

echo "== any other dash-led unit is a usage error, exit 2 =="
for a in -x - --flag; do
  attach_run "$a"
  assert_eq "$RC" 2 "attach $a exits 2"
  assert_ok "attach $a names the argument on stderr" has "$ERR" "'$a'"
  assert_ok "attach $a shows the usage on stderr" has "$ERR" "usage: attach.sh"
  assert_eq "$OUT" "" "attach $a prints nothing on stdout"
  assert_no "attach $a does not look for a session" has "$OUT$ERR" "no live session"
done
attach_run -x 5
assert_eq "$RC" 2 "attach -x 5 (dash-led unit, with an issue) exits 2"

echo "== a non-numeric issue is a usage error naming the value =="
for a in -x abc 1x 1.5; do
  attach_run main "$a"
  assert_eq "$RC" 2 "attach main $a exits 2"
  assert_ok "attach main $a names the value" has "$ERR" "'$a'"
  assert_no "attach main $a does not look for a session" has "$OUT$ERR" "no live session"
done

echo "== a numeric issue still reaches the session lookup =="
attach_run main 12
assert_eq "$RC" 1 "attach main 12 exits 1 (no such session)"
assert_ok "attach main 12 names the session on stderr" has "$ERR" "no live session 'aa-main-i12'"

echo "== no argument still lists live sessions, exit 0 =="
attach_run
assert_eq "$RC" 0 "attach with no argument exits 0"
assert_ok "attach with no argument lists sessions" has "$OUT" "live sessions:"
finish

#!/usr/bin/env bash
# test_attach_usage.sh — #1122: `harness attach` with no unit (or an empty one) names the command the user
# typed (`harness attach <unit> [issue]`, not the internal attach.sh), prints it to stderr, and exits 2.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
make_env
trap tmp_cleanup EXIT

for args in "" "''"; do
  label="no unit"; [[ -n "$args" ]] && label="an empty unit"
  echo "== attach with $label =="
  if [[ -n "$args" ]]; then set -- ""; else set --; fi
  out="$(bash "$ROOT/scripts/attach.sh" "$@" 2>"$RUN_DIR/err" </dev/null)"; rc=$?
  err="$(cat "$RUN_DIR/err")"
  assert_eq "$rc" 2 "exits 2"
  assert_ok "usage names the typed command on stderr" grep -qF "usage: harness attach <unit> [issue]" <<<"$err"
  assert_no "…and never the internal script name" grep -qF "attach.sh" <<<"$out$err"
  assert_no "…and nothing usage-like on stdout" grep -qF "usage:" <<<"$out"
done
finish

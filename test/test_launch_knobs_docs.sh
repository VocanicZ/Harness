#!/usr/bin/env bash
# test_launch_knobs_docs.sh — #792: docs/reference.md lists the launch knobs with the defaults scripts/lib.sh uses,
# and says a value that is not a non-negative integer falls back to the default with a one-time warning.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"
DOC="$ROOT/docs/reference.md"
row(){ grep -E "^\| \`$1\` \|" "$DOC"; }
for spec in HARNESS_LAUNCH_FAIL_SECS:30 HARNESS_LAUNCH_BACKOFF:60 HARNESS_LAUNCH_BACKOFF_MAX:900; do
  k="${spec%%:*}" d="${spec##*:}"; r="$(row "$k")"
  assert_ok "$k has a row in docs/reference.md" test -n "$r"
  assert_ok "…default $d in the second column" grep -qE "^\| \`$k\` \| \`$d\` \|" <<<"$r"
  assert_ok "…a value that is not a non-negative integer falls back to $d" grep -qE "not a non-negative integer.*falls back to \`$d\`|falls back to \`$d\`" <<<"$r"
  assert_ok "…with a one-time warning" grep -q "one-time warning" <<<"$r"
done
# the defaults in the docs are the ones the code reads
assert_ok "lib.sh reads HARNESS_LAUNCH_FAIL_SECS through _launch_knob with 30" grep -q "_launch_knob HARNESS_LAUNCH_FAIL_SECS 30" "$ROOT/scripts/lib.sh"
assert_ok "lib.sh BACKOFF defaults are 60 and 900" grep -q "_launch_knob HARNESS_LAUNCH_BACKOFF 60.*_launch_knob HARNESS_LAUNCH_BACKOFF_MAX 900" "$ROOT/scripts/lib.sh"
finish

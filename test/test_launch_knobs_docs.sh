#!/usr/bin/env bash
# test_launch_knobs_docs.sh — #786 (PRD #587): docs/reference.md's config table lists HARNESS_LAUNCH_BACKOFF,
# HARNESS_LAUNCH_BACKOFF_MAX and HARNESS_LAUNCH_FAIL_SECS, each with the default scripts/lib.sh uses.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
ROOT="$HERE/.."
config="$(sed -n '/^## Configuration/,/^### /p' "$ROOT/docs/reference.md" | grep '^| `HARNESS_')"
for pair in HARNESS_LAUNCH_BACKOFF:60 HARNESS_LAUNCH_BACKOFF_MAX:900 HARNESS_LAUNCH_FAIL_SECS:30; do
  v="${pair%%:*}"; d="${pair##*:}"
  row="$(grep -F "| \`$v\` |" <<<"$config")"
  assert_ok "$v has a row in the config table" test -n "$row"
  assert_eq "$(cut -d'|' -f3 <<<"$row" | tr -d ' ')" "\`$d\`" "$v row shows default $d"
  # the default in the table is the one lib.sh falls back to
  assert_ok "scripts/lib.sh falls back to $d for $v" grep -qE "$v(:-| )$d\b|$v:-$d\}" "$ROOT/scripts/lib.sh"
done
for v in HARNESS_LAUNCH_BACKOFF HARNESS_LAUNCH_BACKOFF_MAX; do
  assert_ok "$v row says what a non-integer value does" grep -qE "^\| \`$v\` \|.*not a non-negative integer.*falls back" <<<"$config"
done
finish

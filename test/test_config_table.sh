#!/usr/bin/env bash
# rtdd: always
# test_config_table.sh — #1059: the config table (docs/reference.md "## Configuration") has a row for every HARNESS_* setting
# the adapters (scripts/cli/*.sh) read. The same check test_cli_readme.sh makes, alone: that file waits on every CLI's matrix
# cells (minutes), so a lane's rtdd rounds never ran it and the gate was first to see a new setting with no row (#682 #687 #692
# #698 #778 #814 #657). This one takes a second and is in the always-run guard set (test/guards.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
ROOT="$HERE/.."

assert_eq "$(config_table_gaps "$ROOT")" "" "the config table has a row for every HARNESS_* setting the adapters read"
for v in $CONFIG_TABLE_INTERNAL; do
  assert_ok "$v, left out of the config table, is still read by an adapter" grep -qw "$v" <<<"$(config_table_read_vars "$ROOT")"
done

# The check bites: a fixture tree whose adapter reads a new setting with no row is a gap; the row closes it; an internal one is exempt.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/cli" "$T/docs"
printf '%s\n' '## Configuration' '| Variable | Default | Meaning |' '| `HARNESS_OLD` | x | an old setting |' '### Next' > "$T/docs/reference.md"
printf '%s\n' 'echo "$HARNESS_OLD"' > "$T/scripts/cli/a.sh"
assert_eq "$(config_table_gaps "$T")" "" "fixture: every setting read has a row"
printf '%s\n' 'echo "$HARNESS_OLD $HARNESS_BRAND_NEW"' > "$T/scripts/cli/a.sh"
assert_eq "$(config_table_gaps "$T")" "HARNESS_BRAND_NEW" "fixture: a new HARNESS_* read with no row is a gap"
printf '%s\n' '## Configuration' '| `HARNESS_OLD` | x | y |' '| `HARNESS_BRAND_NEW` | x | y |' '### Next' > "$T/docs/reference.md"
assert_eq "$(config_table_gaps "$T")" "" "fixture: the row closes the gap"
printf '%s\n' 'echo "$HARNESS_SESSION"' > "$T/scripts/cli/a.sh"
assert_eq "$(config_table_gaps "$T")" "" "fixture: an engine-internal variable needs no row"
finish

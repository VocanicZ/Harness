#!/usr/bin/env bash
# rtdd: always
# test_static_scripts_lints.sh — #1211: two repo-wide scans of scripts/, alone. A script that reads HARNESS_CLI outside the adapter
# dispatcher broke the release gate (#657), and one that mentions HARNESS_CAP / $CAP outside the migration code did too (#778): both
# scans lived in slow files (test_cli_readme.sh waits on every CLI's matrix cells, minutes; test_cap_removed.sh runs `harness init`),
# which a lane's rtdd rounds never select for a change that only ADDS a script. The input is the repo tree and a run is milliseconds,
# so this file is in the always-run guard set (test/guards.sh). The behavioural parts stay in those two files.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
ROOT="$HERE/.."

# #188 / PRD #189: HARNESS_CLI is read only by the adapter dispatcher.
hits="$(cd "$ROOT" && grep -l 'HARNESS_CLI' scripts/*.sh scripts/cli/*.sh)"
assert_eq "$hits" "scripts/cli/dispatch.sh" "only the dispatcher reads HARNESS_CLI"
assert_eq "$(cd "$ROOT" && grep -l 'HARNESS_CLI' scripts/*.py)" "" "no python script reads HARNESS_CLI"

# #469 (PRD #464 §2): CAP is gone; no HARNESS_CAP / lane-CAP reference is left in scripts/ except the migration code.
left="$(cd "$ROOT/scripts" && grep -rnE 'HARNESS_CAP|\$CAP\b|\$\{CAP\b|\bCAP=|cap=\$|\bcap \$' . \
        | grep -vE '^\./(fleet-migrate\.sh|fleet_migrate\.py):' )"
assert_eq "$left" "" "scripts/ outside fleet-migrate.sh / fleet_migrate.py mentions neither HARNESS_CAP nor \$CAP"
finish

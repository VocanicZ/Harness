#!/usr/bin/env bash
# Cadence defaults (#24): the resident pool polls slowly by default (HARNESS_POLL=300),
# while a fast priority lane polls every HARNESS_PRIORITY_POLL=60s. Both come from lib.sh
# defaults, are mirrored into POLL/PRIORITY_POLL, and are overridable by env/.harness/config.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
export RUN_DIR="$(mktemp -d)"   # keep lib.sh's mkdir out of the repo
rc=0

( unset HARNESS_POLL HARNESS_PRIORITY_POLL; source "$HERE/../lib.sh"
  assert_eq "$HARNESS_POLL"          "300" "HARNESS_POLL defaults to 300 (slow resident cadence)"
  assert_eq "$POLL"                  "300" "POLL mirrors HARNESS_POLL"
  assert_eq "$HARNESS_PRIORITY_POLL" "60"  "HARNESS_PRIORITY_POLL defaults to 60 (fast priority lane)"
  assert_eq "$PRIORITY_POLL"         "60"  "PRIORITY_POLL mirrors HARNESS_PRIORITY_POLL"
  finish ) || rc=1

( HARNESS_POLL=7 HARNESS_PRIORITY_POLL=3; source "$HERE/../lib.sh"
  assert_eq "$POLL"          "7" "HARNESS_POLL is overridable (env/.harness/config wins via :=)"
  assert_eq "$PRIORITY_POLL" "3" "HARNESS_PRIORITY_POLL is overridable (env/.harness/config wins via :=)"
  finish ) || rc=1

exit $rc

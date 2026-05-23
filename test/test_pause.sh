#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/helpers.sh"; make_env
assert_no "not paused initially" is_paused
touch "$PAUSE_FLAG"
assert_ok "paused after flag created" is_paused
rm -f "$PAUSE_FLAG"
assert_no "not paused after flag removed" is_paused
# config default present
assert_eq "$HARNESS_LABEL_PAUSED" "agent-paused" "default paused label"
finish

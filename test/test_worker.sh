#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/../drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../pool-worker.sh"   # defines worker_tick; main() guarded out
source "$HERE/helpers.sh"; make_env
HARNESS_TOPOLOGY=multi
write_targets <<'EOF'
a	acme/a	-	root
b	acme/b	a	needs a
EOF
seed_if_needed(){ :; }            # no real gh
drive_unit(){ set_complete $(cat "$COMPLETE_SET") "$1"; }  # "driving" marks it complete
set_complete
worker_tick W1; assert_eq "$?" "0" "claimed a + drove -> rc 0"
assert_ok "a now complete" unit_complete a
worker_tick W1; assert_eq "$?" "0" "claimed b + drove -> rc 0"
worker_tick W1; assert_eq "$?" "2" "all complete -> rc 2 (retire)"
finish

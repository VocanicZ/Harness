#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../scripts/pool-worker.sh"   # defines worker_tick; main() guarded out
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
worker_tick W1; assert_eq "$?" "2" "all complete -> rc 2 (resident: idle, not retire)"

# --- resident pool (#24): worker_step idles on all_complete instead of retiring ----
# worker_step wraps worker_tick: rc 0 does work, rc 2 (all_complete) logs an idle banner
# ONCE per idle streak (deduped across polls) and keeps polling — it must NOT exit.
POLL=0
IDLELOG="$RUN_DIR/idle.log"; : > "$IDLELOG"
worker_step W1 >>"$IDLELOG" 2>&1; assert_eq "$?" "2" "worker_step: all_complete -> rc 2 (no exit/retire)"
worker_step W1 >>"$IDLELOG" 2>&1
worker_step W1 >>"$IDLELOG" 2>&1; assert_eq "$?" "2" "worker_step: still resident after 3 polls"
assert_eq "$(grep -c 'idle, watching' "$IDLELOG")" "1" "worker_step: idle banner logged exactly once (deduped)"

# inject new claimable work -> claimed on the NEXT poll with no restart; dedup resets
write_targets <<'EOF'
a	acme/a	-	root
b	acme/b	a	needs a
c	acme/c	-	injected
EOF
worker_step W1 >>"$IDLELOG" 2>&1; assert_eq "$?" "0" "worker_step: injected unit claimed+driven -> rc 0 (no restart)"
assert_ok "injected unit c now complete" unit_complete c
: > "$IDLELOG"
worker_step W1 >>"$IDLELOG" 2>&1; assert_eq "$?" "2" "worker_step: all complete again -> rc 2"
assert_eq "$(grep -c 'idle, watching' "$IDLELOG")" "1" "worker_step: idle banner re-logged after work (dedup reset)"

finish

#!/usr/bin/env bash
# test_doctor.sh — lock-diagnostic primitives (lib) + harness doctor report/--fix behaviour.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../scripts/lib.sh
source ./helpers.sh
_DOCTOR_SOURCED=1 source ../scripts/doctor.sh   # bring in doctor_* fns without running main
make_env

# ── lock_holders: finds a process holding the file open, empty when none ───────────────────────
LF="$(mktemp)"
assert_eq "$(lock_holders "$LF")" "" "lock_holders: no holder → empty"
# Hold the fd in THIS shell (synchronously) rather than racing a backgrounded subshell: the prior
# background-holder design was inherently flaky under load (the OS might not schedule the child to
# open fd 9 before the scan, even with a poll). Opening fd 9 here means our OWN pid ($$) holds the
# lock the instant lock_holders runs — deterministic, zero scheduling race.
exec 9>"$LF"
assert_ok "lock_holders: reports the holding pid" \
  grep -qE "(^|[^0-9])$$"'\b' <<<"$(lock_holders "$LF")"
exec 9>&-                             # release before the lock_free test reuses fd 9

# ── lock_free: true when acquirable, false when held; never leaves a holder behind ─────────────
LF2="$(mktemp)"
assert_ok "lock_free: free file is acquirable" lock_free "$LF2"
( exec 9>"$LF2"; flock 9; sleep 5 ) &   # hold an EXCLUSIVE flock
HOLDER2=$!; sleep 0.2
assert_no "lock_free: held lock is not acquirable" lock_free "$LF2"
kill "$HOLDER2" 2>/dev/null; wait "$HOLDER2" 2>/dev/null
assert_ok "lock_free: leaves no holder behind (re-acquirable after probing)" lock_free "$LF2"

# ── tracked_worker_pid: true iff pid is in one of THIS project's RUN_DIR/*.pid ─────────────────
echo "$$" > "$RUN_DIR/worker-1.pid"
assert_ok "tracked_worker_pid: recorded pid is tracked"        tracked_worker_pid "$$"
assert_no "tracked_worker_pid: unrecorded pid is not tracked"  tracked_worker_pid 999999
rm -f "$RUN_DIR/worker-1.pid"

# ── doctor_pidfiles: detects a stale pidfile; --fix removes it ─────────────────────────────────
echo "999999" > "$RUN_DIR/worker-1.pid"          # dead pid → stale
DOCTOR_FIX=0; out_rc=0; doctor_pidfiles >/dev/null || out_rc=$?
assert_eq "$out_rc" "1" "doctor_pidfiles: reports 1 stale pidfile"
assert_ok "doctor_pidfiles: report mode leaves the file in place" test -f "$RUN_DIR/worker-1.pid"
DOCTOR_FIX=1; doctor_pidfiles >/dev/null || true
assert_no "doctor_pidfiles --fix: stale pidfile removed" test -f "$RUN_DIR/worker-1.pid"
DOCTOR_FIX=0

# ── doctor_main: healthy env exits 0; a stale pidfile exits 1; --fix returns to clean ──────────
rm -f "$RUN_DIR"/*.pid "$RUN_DIR"/*.lock
rc=0; DOCTOR_FIX=0; doctor_main >/dev/null || rc=$?
assert_eq "$rc" "0" "doctor_main: clean env is healthy (exit 0)"
echo "999999" > "$RUN_DIR/worker-2.pid"           # dead pid → unhealthy
rc=0; DOCTOR_FIX=0; doctor_main >/dev/null || rc=$?
assert_eq "$rc" "1" "doctor_main: stale pidfile makes it unhealthy (exit 1)"
rc=0; doctor_main --fix >/dev/null || rc=$?
assert_eq "$rc" "0" "doctor_main --fix: clears the problem (exit 0)"
assert_no "doctor_main --fix actually removed the stale pidfile" test -f "$RUN_DIR/worker-2.pid"

finish

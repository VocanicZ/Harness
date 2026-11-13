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
lock_acquire "$LF" LFH                # portable.sh: a flock on Linux, an owned mkdir lock on Windows (Git Bash has no flock)
assert_ok "lock_holders: reports the holding pid" \
  grep -qE "(^|[^0-9])$$"'\b' <<<"$(lock_holders "$LF")"
lock_release "$LFH"

# ── lock_free: true when acquirable, false when held; never leaves a holder behind ─────────────
LF2="$(mktemp)"
assert_ok "lock_free: free file is acquirable" lock_free "$LF2"
( lock_acquire "$LF2" LF2H; sleep 5 ) &   # hold the lock (an exclusive flock on Linux)
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
# A real Windows host also runs the Windows checks: it has no tmux (headless is the one backend there) and the poller state
# pin_host_home made under HARNESS_HOME would read as a leftover install. The lock/pidfile health below is what this asks.
if real_windows_host; then export "$SESS_CONFIG_VAR=headless"; rm -rf "$HARNESS_HOME/poller"; fi
rc=0; DOCTOR_FIX=0; doctor_main >/dev/null || rc=$?
assert_eq "$rc" "0" "doctor_main: clean env is healthy (exit 0)"
echo "999999" > "$RUN_DIR/worker-2.pid"           # dead pid → unhealthy
rc=0; DOCTOR_FIX=0; doctor_main >/dev/null || rc=$?
assert_eq "$rc" "1" "doctor_main: stale pidfile makes it unhealthy (exit 1)"
rc=0; doctor_main --fix >/dev/null || rc=$?
assert_eq "$rc" "0" "doctor_main --fix: clears the problem (exit 0)"
assert_no "doctor_main --fix actually removed the stale pidfile" test -f "$RUN_DIR/worker-2.pid"

echo "== doctor reports and --fix prunes stale fleet-registry entries =="
export HARNESS_HOME="$(mktemp -d)"; export HARNESS_FLEETS_DIR="$HARNESS_HOME/fleets"
tmux(){ return 1; }; export -f tmux
# A dead fleet: no sessions, no live pids. Its reservation would otherwise sit there forever.
DEAD_RD="$(mktemp -d)"; echo 999999 > "$DEAD_RD/worker-1.pid"
( STATE_DIR=/p/dead/.harness RUN_DIR="$DEAD_RD" HARNESS_SESS_PREFIX=dead fleet_register )
# DOCTOR_FIX is a global mutated (and left at 1) by the `doctor_main --fix` calls above — reset it
# so this report-only call is actually report-only, not an accidental immediate prune.
DOCTOR_FIX=0
OUT="$(doctor_fleets)"; PROBLEMS=$?
# IN-PROCESS via `contains` — `bash -c "… <<<\"\$OUT\""` would match against an empty string.
contains(){ grep -qE -- "$1" <<<"$2"; }
assert_ok "doctor reports the stale entry" contains '[Ss][Tt][Aa][Ll][Ee]' "$OUT"
assert_ok "doctor names the dead fleet"    contains "$(native_path /p/dead)" "$OUT"   # the registry keeps the native form (P:/dead) on Windows
# Round-1 fix review: doctor_fleets' message must name the owning PROJECT (dirname of the registered
# STATE_DIR), the same value status.sh's sibling row and check_prefix_collision's refusal print for
# this same entry — never the raw STATE_DIR with its trailing /.harness leaking through.
assert_no "doctor's stale-entry message does not leak the .harness suffix" contains '\.harness' "$OUT"
assert_ok "doctor counts it as a problem"   test "$PROBLEMS" -gt 0
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "1" "report-only leaves the entry in place"
DOCTOR_FIX=1 doctor_fleets >/dev/null
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json 2>/dev/null | wc -l)" "0" "--fix prunes the stale entry"

# A LIVE fleet must never be pruned or flagged.
sleep 300 & LP=$!; LIVE_RD="$(mktemp -d)"; echo "$LP" > "$LIVE_RD/worker-1.pid"
( STATE_DIR=/p/live/.harness RUN_DIR="$LIVE_RD" HARNESS_SESS_PREFIX=live fleet_register )
DOCTOR_FIX=1 doctor_fleets >/dev/null
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "1" "--fix never prunes a live fleet"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null

# A POLLER-registered fleet has NO run_dir — poller_register writes {slug,cadence,prefix,project}
# and nothing more — so there are no pidfiles for fleet_stale to check and, with no live session, it
# would call a live fleet stale. Worse, fleet_deregister only deletes from $HARNESS_FLEETS_DIR, so
# --fix would print `→ pruned`, leave the record exactly where it was, and report the same problem
# every run thereafter. An absent run_dir is not evidence of death; doctor must leave it alone.
rm -f "$HARNESS_FLEETS_DIR"/*.json     # isolate the count: only the poller record is in play
export POLLER_REGISTRY_DIR="$HARNESS_HOME/poller/registry"; mkdir -p "$POLLER_REGISTRY_DIR"
poller_register acme/widget 60 pollr /p/pollr/.harness
OUT="$(DOCTOR_FIX=0 doctor_fleets)"; PROBLEMS=$?
assert_no "doctor does not call a run_dir-less poller entry stale" contains "$(native_path /p/pollr)" "$OUT"
assert_eq "$PROBLEMS" "0" "and counts no problem for it"
DOCTOR_FIX=1 doctor_fleets >/dev/null
assert_eq "$(ls "$POLLER_REGISTRY_DIR"/*.json 2>/dev/null | wc -l)" "1" \
  "--fix never claims to prune a poller entry it cannot remove"
rm -f "$POLLER_REGISTRY_DIR"/*.json
unset -f tmux

echo "== doctor_main's summary wording covers a stale fleet-registry entry, not just locks/pidfiles =="
# Round-1 fix review item 4: doctor_main's "healthy"/"problem(s) found" strings must not contradict
# doctor_fleets' own finding when a stale registry entry is the ONLY problem present.
rm -f "$RUN_DIR"/*.pid "$RUN_DIR"/*.lock
export HARNESS_HOME="$(mktemp -d)"; export HARNESS_FLEETS_DIR="$HARNESS_HOME/fleets"
tmux(){ return 1; }; export -f tmux
DEAD2_RD="$(mktemp -d)"; echo 999999 > "$DEAD2_RD/worker-1.pid"
( STATE_DIR=/p/dead2/.harness RUN_DIR="$DEAD2_RD" HARNESS_SESS_PREFIX=dead2 fleet_register )
DOCTOR_FIX=0
SUMMARY="$(doctor_main)"; rc=$?
assert_eq "$rc" "1" "doctor_main: a stale fleet-registry entry alone makes it unhealthy (exit 1)"
# Look only at the tail (the "$total problem(s) found" verdict line, AFTER the divider) — the
# "fleet registry:" section header appears unconditionally above it, so grepping the whole $SUMMARY
# would pass even against the pre-fix wording that never mentioned the registry in the verdict itself.
TAIL="$(sed -n '/^────/,$p' <<<"$SUMMARY")"
assert_ok "doctor_main's verdict line (not just the section header) mentions the fleet registry" \
  contains 'registry' "$TAIL"
DOCTOR_FIX=1 doctor_main >/dev/null   # clean up: prune it
unset -f tmux

echo "== #1144: doctor warns when the tmux server's global env holds the Claude Code session's variables =="
# A server created from inside a Claude Code session carries CLAUDECODE / CLAUDE_CODE_CHILD_SESSION into every lane: no
# transcript, no usage in session_end. Silent on a clean server and when no server runs; --fix unsets them.
# A `tmux` function models the server's global environment (a file: one NAME=value per line); no real tmux.
export HARNESS_SESSION_BACKEND=tmux
rm -rf "$HARNESS_HOME"; export HARNESS_HOME="$(mktemp -d)"; export HARNESS_FLEETS_DIR="$HARNESS_HOME/fleets"; rm -f "$RUN_DIR"/*.pid
GENV="$(mktemp)"; rm -f "$GENV"   # absent = no server running
tmux(){ case "$1 $2" in
  "show-environment -g") [[ -f $GENV ]] && cat "$GENV" || return 1 ;;
  "set-environment -g") [[ -f $GENV && $3 == -u ]] && { grep -v "^$4=" "$GENV" > "$GENV.n"; mv "$GENV.n" "$GENV"; } ;;
  *) return 1 ;; esac; }
DOCTOR_FIX=0
OUT="$(doctor_main 2>&1)"; rc=$?
assert_eq "$rc" 0 "no tmux server running: doctor is healthy"
assert_no "…and silent about the tmux server environment" contains 'set-environment' "$OUT"
printf 'SOME_GLOBAL=keep\n-REMOVED_ONE\n' > "$GENV"
OUT="$(doctor_main 2>&1)"; rc=$?
assert_eq "$rc" 0 "a clean server: doctor is healthy"
assert_no "…and silent" contains 'set-environment' "$OUT"
printf 'CLAUDECODE=1\nCLAUDE_CODE_CHILD_SESSION=1\nCLAUDE_CODE_SESSION_ID=x\n' >> "$GENV"
OUT="$(doctor_main 2>&1)"; rc=$?
assert_eq "$rc" 1 "a leaked server: doctor reports a problem"
assert_ok "…names CLAUDECODE" contains 'CLAUDECODE' "$OUT"
assert_ok "…names CLAUDE_CODE_CHILD_SESSION" contains 'CLAUDE_CODE_CHILD_SESSION' "$OUT"
assert_ok "…names CLAUDE_CODE_SESSION_ID" contains 'CLAUDE_CODE_SESSION_ID' "$OUT"
assert_ok "…and the fix" contains 'tmux set-environment -g -u' "$OUT"
assert_eq "$(grep -cE '^(CLAUDECODE|CLAUDE_CODE_)' "$GENV")" 3 "report mode leaves the server alone"
OUT="$(doctor_main --fix 2>&1)"; rc=$?
assert_eq "$rc" 0 "doctor --fix: done (exit 0)"
assert_eq "$(grep -cE '^(CLAUDECODE|CLAUDE_CODE_)' "$GENV")" 0 "…the variables are gone from the server's global env"
assert_eq "$(grep -c '^SOME_GLOBAL=keep$' "$GENV")" 1 "…and nothing else"
DOCTOR_FIX=0; OUT="$(doctor_main 2>&1)"; rc=$?
assert_eq "$rc" 0 "after --fix: healthy again"
unset -f tmux; rm -f "$GENV"

finish

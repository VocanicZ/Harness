#!/usr/bin/env bash
# test_fleet_registry.sh — the host-wide fleet registry under $HARNESS_HOME/fleets: one file per
# LIVE fleet, keyed on STATE_DIR, feeding the start-time prefix-collision guard. Deliberately
# separate from the poller registry, whose files are poller.sh's GitHub WORK LIST — registering
# there unconditionally would enroll every fleet into shared-token polling it never opted into.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pin the host root BEFORE sourcing lib.sh so HARNESS_FLEETS_DIR derives into a throwaway and we
# never touch a real ~/.harness (a stray fixture entry there aborts a real `harness start`).
# Drop any INHERITED HARNESS_FLEETS_DIR first. run.sh now pins one per test (and a live fleet exports
# its own), and lib.sh:99 prefers an inherited value over the HARNESS_HOME set here BY DESIGN — so
# without this unset the derivation asserted below is never exercised. The mktemp'd HARNESS_HOME
# below keeps this throwaway either way; only the derivation-under-test changes.
unset HARNESS_FLEETS_DIR
export HARNESS_HOME="$(mktemp -d)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"

echo "== the registry dir is separate from the poller's =="
# Checked BEFORE make_env: make_env re-pins HARNESS_HOME to its own throwaway (helpers.sh:55) for
# STATE_DIR/RUN_DIR isolation, but does not re-derive HARNESS_FLEETS_DIR (it was already resolved at
# lib.sh source time from the HARNESS_HOME pinned above) — so this is the point that actually proves
# the derivation. Values are interpolated by THIS (already-sourced) shell, not looked up inside the
# bash -c child: POLLER_REGISTRY_DIR is never exported, so a child process would see it as empty and
# the "NOT the poller registry" check would pass for the wrong reason (non-empty vs empty).
assert_ok "HARNESS_FLEETS_DIR is under HARNESS_HOME" bash -c "[[ '$HARNESS_FLEETS_DIR' == '$HARNESS_HOME/fleets' ]]"
assert_no "it is NOT the poller registry"            bash -c "[[ '$HARNESS_FLEETS_DIR' == '$POLLER_REGISTRY_DIR' ]]"

make_env

echo "== register / read back / deregister =="
rm -rf "$HARNESS_FLEETS_DIR"
( STATE_DIR=/proj/a RUN_DIR=/proj/a/run HARNESS_SESS_PREFIX=alpha fleet_register )
( STATE_DIR=/proj/b RUN_DIR=/proj/b/run HARNESS_SESS_PREFIX=beta  fleet_register )
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json 2>/dev/null | wc -l)" "2" "one file per fleet"

# entries EXCLUDE the caller's own fleet (self must never trip the guard).
OUT="$(fleet_registry_entries /proj/a)"
assert_eq "$(printf '%s\n' "$OUT" | grep -c .)" "1" "self-project excluded from entries"
# fleet_registry_entries is called IN-PROCESS (lib.sh is sourced here); its output is then handed to
# the bash -c child as a plain positional arg ($1), never re-invoked or re-looked-up inside the
# child — a bash -c subshell never sourced lib.sh, so calling the function there would be "command
# not found" (127), and referencing $OUT there would be empty (never exported). Same discipline as
# test_prefix_guard.sh's prefixes_collide check.
assert_ok "the other fleet's prefix is reported"  bash -c 'grep -q "^beta	/proj/b	/proj/b/run" <<<"$1"' _ "$OUT"
assert_no "our own prefix is not reported"        bash -c 'grep -q "^alpha" <<<"$1"' _ "$OUT"

# re-registering the same project overwrites in place (idempotent, not additive).
( STATE_DIR=/proj/a RUN_DIR=/proj/a/run HARNESS_SESS_PREFIX=alpha2 fleet_register )
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "2" "re-register is idempotent"
assert_ok "re-register updates the prefix" bash -c 'grep -q "^alpha2	" <<<"$1"' _ "$(fleet_registry_entries /proj/b)"

# deregister removes ONLY the calling project's entry, matched on the JSON field not the filename.
fleet_deregister /proj/a
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "1" "deregister removes only its own entry"
assert_ok "the sibling survives" bash -c 'grep -q "^beta	" <<<"$1"' _ "$(fleet_registry_entries /proj/a)"

echo "== best-effort: the registry is an aid, never a gate =="
# No registry dir at all -> no entries, no error (the single-fleet no-op).
rm -rf "$HARNESS_FLEETS_DIR"
assert_eq "$(fleet_registry_entries /proj/a | grep -c . || true)" "0" "absent registry yields no entries"
assert_ok "absent registry is not an error" fleet_registry_entries /proj/a
# An UNWRITABLE host root must warn and still return 0 — a fleet must always be startable.
RO="$(mktemp -d)"; chmod 500 "$RO"
( HARNESS_FLEETS_DIR="$RO/fleets" STATE_DIR=/proj/c RUN_DIR=/proj/c/run HARNESS_SESS_PREFIX=gamma fleet_register ) 2>/dev/null
assert_eq "$?" "0" "unwritable registry still returns 0"
# fleet_register itself is under test here, so it must run where it's actually defined: a nested `(
# … )` subshell of THIS process (which inherits functions, unlike a `bash -c` child). Wrapping the
# whole pipeline in bash -c, as opposed to only the final grep, would hit the same 127 pitfall as
# above.
_ro_warns(){ ( HARNESS_FLEETS_DIR="$RO/fleets" STATE_DIR=/proj/c RUN_DIR=/proj/c/run HARNESS_SESS_PREFIX=gamma fleet_register ) 2>&1 >/dev/null | grep -qi 'warning'; }
assert_ok "unwritable registry warns on stderr" _ro_warns
chmod 700 "$RO"

echo "== a malformed entry never breaks the reader =="
mkdir -p "$HARNESS_FLEETS_DIR"; echo 'not json' > "$HARNESS_FLEETS_DIR/junk.json"
( STATE_DIR=/proj/d RUN_DIR=/proj/d/run HARNESS_SESS_PREFIX=delta fleet_register )
assert_ok "malformed entries are skipped, valid ones still read" \
  bash -c 'grep -q "^delta	" <<<"$1"' _ "$(fleet_registry_entries /proj/z)"

echo "== start.sh registers UNCONDITIONALLY (static: it can't run in this harness) =="
START="$HERE/../scripts/start.sh"
assert_ok "start.sh calls fleet_register" grep -q '^fleet_register' "$START"
# It must NOT sit inside the HARNESS_USE_POLLER block — that flag is off by default, which is exactly
# why the old guard read an empty registry and never fired.
reg_ln="$(grep -n '^fleet_register' "$START" | head -1 | cut -d: -f1)"
poll_ln="$(grep -n 'if \[\[ -n "\${HARNESS_USE_POLLER:-}" \]\]' "$START" | head -1 | cut -d: -f1)"
guard_ln="$(grep -n '^check_prefix_collision' "$START" | head -1 | cut -d: -f1)"
assert_ok "found the fleet_register line"        test -n "$reg_ln"
assert_ok "found the HARNESS_USE_POLLER block"   test -n "$poll_ln"
assert_ok "found the check_prefix_collision line" test -n "$guard_ln"
assert_ok "registration precedes the poller block (not nested inside it)" test "$reg_ln" -lt "$poll_ln"
assert_ok "registration happens AFTER the collision guard passes"          test "$guard_ln" -lt "$reg_ln"

echo "== stop.sh deregisters unconditionally (behavioural) =="
SRUN="$(mktemp -d)"
tmux(){ case "$1" in ls) return 0;; *) return 0;; esac; }
export -f tmux
rm -rf "$HARNESS_FLEETS_DIR"
( STATE_DIR="$SRUN" RUN_DIR="$SRUN" HARNESS_SESS_PREFIX=zeta fleet_register )
( STATE_DIR=/other/proj RUN_DIR=/other/proj/run HARNESS_SESS_PREFIX=other fleet_register )
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "2" "two fleets registered before stop"
HARNESS_SESS_PREFIX=zeta RUN_DIR="$SRUN" STATE_DIR="$SRUN" bash "$HERE/../scripts/stop.sh" >/dev/null 2>&1
unset -f tmux
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "1" "stop removed exactly one entry"
# IN-PROCESS. `bash -c "… <<<\"\$(fleet_registry_entries …)\""` would run fleet_registry_entries in a
# child that never sourced lib.sh — a 127 matched against an empty string, not a test of anything.
contains(){ grep -qE -- "$1" <<<"$2"; }
assert_ok "the sibling fleet's entry survives stop" contains '^other	' "$(fleet_registry_entries /nobody)"

finish

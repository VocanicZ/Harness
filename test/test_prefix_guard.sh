#!/usr/bin/env bash
# test_prefix_guard.sh — PRD-B slice 4 (#73): prefix-collision guard at `harness start`
# (consuming slice 2's registry, which records each fleet's HARNESS_SESS_PREFIX) + the
# full-session-grammar tightening of stop.sh / status.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Point the host-poller registry at a private temp root BEFORE sourcing lib.sh so the
# derived POLLER_REGISTRY_DIR lands there and we never touch a real ~/.harness.
export HARNESS_HOME="$(mktemp -d)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env

echo "== prefixes_collide: the collision predicate =="
# equal prefixes collide
assert_ok "equal prefixes collide"                          prefixes_collide hz hz
# dash-prefix overlap: one prefix's session space (`P-…`) swallows the other's sessions
assert_ok "dash-prefix overlap collides (hz vs hz-bug)"     prefixes_collide hz hz-bug
assert_ok "dash-prefix overlap collides (reverse)"          prefixes_collide hz-bug hz
# hz / hzli / boto coexist: the trailing-dash grammar means hzli-… is NOT inside hz-…'s space
assert_no "hz vs hzli do NOT collide"                       prefixes_collide hz hzli
assert_no "hzli vs hz do NOT collide"                       prefixes_collide hzli hz
assert_no "hz vs boto do NOT collide"                       prefixes_collide hz boto
assert_no "hzli vs boto do NOT collide"                     prefixes_collide hzli boto

echo "== start-time guard reads slice-2's registry (poller_register records the prefix) =="
REG="$HARNESS_HOME/poller/registry"
reset_reg(){ rm -rf "$REG"; mkdir -p "$REG"; }

# A sibling fleet (different project) registered with a COLLIDING prefix -> refuse (default).
reset_reg
poller_register acme/widget 60 hz /other/project
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "colliding prefix REFUSED at start (default refuse)"

# Same collision but HARNESS_PREFIX_COLLISION=warn -> proceed (rc 0).
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=warn check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "warn mode proceeds despite collision"

# hz / hzli / boto coexist end-to-end: a sibling registered as hzli does NOT block our hz fleet.
reset_reg
poller_register acme/widget 60 hzli /other/project
poller_register acme/other  60 boto /third/project
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "hz coexists with sibling hzli + boto (no refusal)"

# Our OWN registry entry must never trip the guard (self-exclusion on STATE_DIR).
reset_reg
poller_register acme/widget 60 hz /our/project
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "own registry entry does not self-collide"

# No registry at all (single fleet, poller never used) -> no behavior change.
rm -rf "$REG"
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "empty/absent registry never refuses (single-fleet no-op)"

echo "== full session grammar: stop/status match ONLY the fleet's own sessions =="
HARNESS_SESS_PREFIX=hz
# every real session form this fleet creates matches
assert_ok "orch session matches"               is_fleet_session hz-main
assert_ok "impl session matches"               is_fleet_session hz-main-i5
assert_ok "inject session matches"             is_fleet_session hz-inject-main
assert_ok "bug fix session matches"            is_fleet_session hz-bug-acme_widget-5-fix
assert_ok "bug triage session matches"         is_fleet_session hz-bug-acme_widget-5-triage
# a SIBLING fleet's sessions (different prefix) are NOT matched -> untouched by stop/status
assert_no "sibling hzli impl untouched"        is_fleet_session hzli-main-i5
assert_no "sibling boto orch untouched"        is_fleet_session boto-x
# stray, structurally-invalid <prefix>- sessions are NOT matched (defense-in-depth)
assert_no "multi-segment non-grammar untouched" is_fleet_session hz-foo-bar-baz
assert_no "bug without a phase not matched"     is_fleet_session hz-bug-acme_widget-5

echo "== stop.sh kills ONLY full-grammar sessions; a sibling fleet survives =="
SRUN="$(mktemp -d)"; export CALLS="$(mktemp)"
tmux(){ echo "tmux $*" >> "$CALLS"
  case "$1" in
    ls) printf 'hz-main-i1\nhz-bug-acme_widget-5-fix\nhzli-main-i1\nboto-x\nhz-foo-bar-baz\n';;
    *) return 0;;
  esac; }
export -f tmux
HARNESS_SESS_PREFIX=hz RUN_DIR="$SRUN" STATE_DIR="$SRUN" bash "$HERE/../scripts/stop.sh" >/dev/null 2>&1
unset -f tmux
assert_ok "stop kills our impl session"    bash -c "grep -q 'kill-session -t hz-main-i1' '$CALLS'"
assert_ok "stop kills our bug session"     bash -c "grep -q 'kill-session -t hz-bug-acme_widget-5-fix' '$CALLS'"
assert_no "stop leaves sibling hzli alone" bash -c "grep -q 'kill-session -t hzli-main-i1' '$CALLS'"
assert_no "stop leaves sibling boto alone" bash -c "grep -q 'kill-session -t boto-x' '$CALLS'"
assert_no "stop leaves stray non-grammar"  bash -c "grep -q 'kill-session -t hz-foo-bar-baz' '$CALLS'"

finish

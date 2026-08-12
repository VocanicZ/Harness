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
# The guard now reads live worker processes too. Silence that source for the registry block —
# otherwise these assertions would depend on whatever fleets happen to be running on the host, and
# on a developer machine with a live `hz` fleet the coexistence cases would refuse. The next block
# exercises it directly.
running_fleet_prefixes(){ :; }

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

# No registry AND no running fleet (a genuinely single fleet) -> no behavior change.
rm -rf "$REG"
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "empty registry + no running fleet never refuses (single-fleet no-op)"

echo "== the guard no longer depends on the poller being enabled =="
# THE BUG. HARNESS_USE_POLLER is UNSET by default, so the registry is always empty, so this guard
# was a no-op for the ordinary configuration. Three fleets came up on the default `hz` prefix on one
# host and two of them reaped each other's sessions and worktrees for hours. Every case below runs
# with NO registry at all — discovery comes from the live worker processes alone.
rm -rf "$REG"

# A sibling fleet is RUNNING with a colliding prefix -> refuse, with the poller never involved.
running_fleet_prefixes(){ printf 'hz\t/other/project\n'; }
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "running colliding fleet REFUSED with an empty registry"

# The message must name the offender, or the operator cannot act on it.
msg="$( ( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>&1 )"
assert_ok "refusal names the colliding prefix and project" grep -q '/other/project' <<<"$msg"
assert_ok "refusal names the remedy"                       grep -q 'HARNESS_SESS_PREFIX' <<<"$msg"

# warn mode still downgrades to a warning.
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=warn check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "warn mode proceeds despite a running collision"

# The real host layout that broke: hz (ours) + hz (sibling) + hzli (innocent bystander).
running_fleet_prefixes(){ printf 'hzli\t/third/project\nhz\t/other/project\n'; }
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "a colliding fleet is caught even behind a non-colliding one"

# ...and hzli alone must NOT block us, or every multi-project host becomes unstartable.
running_fleet_prefixes(){ printf 'hzli\t/third/project\nboto\t/fourth/project\n'; }
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "running hzli + boto fleets do not block an hz fleet"

# Our OWN workers must never trip the guard. `harness start --recover` is the documented top-up
# path and runs with this fleet's workers already live; self-refusal would make it unusable.
running_fleet_prefixes(){ :; }   # real impl excludes self by STATE_DIR before printing
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "our own running workers do not self-collide"

# Both sources feed one decision: a collision found in EITHER must refuse.
reset_reg
poller_register acme/widget 60 hz /registry/project
running_fleet_prefixes(){ :; }
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "union: registry-only collision still refuses"
reset_reg
running_fleet_prefixes(){ printf 'hz\t/process/project\n'; }
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "union: process-only collision refuses"

echo "== running_fleet_prefixes against the real process table =="
# The seam above is stubbed everywhere else, so exercise the genuine implementation once. It must
# not crash, must emit well-formed `<prefix>\tab<state-dir>` rows, and must never report the
# caller's own state dir.
unset -f running_fleet_prefixes
source "$HERE/../scripts/lib.sh"          # restore the real one
real_out="$(running_fleet_prefixes /definitely/not/a/real/state/dir 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "running_fleet_prefixes exits 0 on a real host"
bad="$(awk -F'\t' 'NF!=2 || $1=="" || $2==""' <<<"${real_out}" | grep -c . || true)"
assert_eq "$bad" "0" "every emitted row is <prefix>TAB<state-dir>"
assert_no "never reports the state dir it was asked to exclude" \
  grep -q '/definitely/not/a/real/state/dir' <<<"$real_out"
# Whatever it found, feeding it back through the predicate must not explode.
assert_ok "its output drives prefixes_collide without error" \
  bash -c 'while IFS=$'"'"'\t'"'"' read -r p _; do [[ -n "$p" ]] && prefixes_collide zzz "$p"; done <<<"'"$real_out"'"; true'

echo "== full session grammar: stop/status match ONLY the fleet's own sessions =="
HARNESS_SESS_PREFIX=hz
# every real session form this fleet creates matches
assert_ok "orch session matches"               is_fleet_session hz-main
assert_ok "impl session matches"               is_fleet_session hz-main-i5
assert_ok "inject session matches"             is_fleet_session hz-inject-main
assert_ok "bug fix session matches"            is_fleet_session hz-bug-acme_widget-5-fix
assert_ok "bug triage session matches"         is_fleet_session hz-bug-acme_widget-5-triage
# a dashed-unit orch session IS ours and MUST match (regression for the dash-leak bug)
assert_ok "dashed-unit orch session matches"   is_fleet_session "$(HARNESS_SESS_PREFIX=hz sess_orch web-api)"
# a SIBLING fleet's sessions (different prefix) are NOT matched -> untouched by stop/status
assert_no "sibling hzli impl untouched"        is_fleet_session hzli-main-i5
assert_no "sibling boto orch untouched"        is_fleet_session boto-x
# any non-empty session under OUR prefix is ours (dashed unit id or otherwise) -> matched
assert_ok "dashed-unit multi-segment matches"  is_fleet_session hz-foo-bar-baz
assert_ok "any session under our prefix matches" is_fleet_session hz-bug-acme_widget-5

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
assert_ok "stop kills our dashed-unit orch" bash -c "grep -q 'kill-session -t hz-foo-bar-baz' '$CALLS'"

finish

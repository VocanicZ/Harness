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

echo "== the guard: tmux enforces, the registry reserves and attributes =="
# make_env (above) pins HARNESS_HOME *and* HARNESS_FLEETS_DIR to its own throwaway root, so the two
# stay in step and no re-pin is needed here. See helpers.sh / test_hermetic.sh's fleet-decoy block.
REG="$HARNESS_HOME/poller/registry"
FREG="$HARNESS_HOME/fleets"
reset_reg(){ rm -rf "$REG" "$FREG"; mkdir -p "$REG" "$FREG"; }
OURS="/home/u/Harness/.harness"; THEIRS="/home/u/Bonsai/.harness"
no_tmux(){ tmux(){ return 1; }; export -f tmux; }
their_sessions(){ tmux(){ printf '%s\t%s\n' "hz-main-i1" "/home/u/Bonsai/.harness/worktrees/main-i1"; }; export -f tmux; }
our_sessions(){ tmux(){ printf '%s\t%s\n' "hz-main-i1" "/home/u/Harness/.harness/worktrees/main-i1"; }; export -f tmux; }

# 1. A sibling's LIVE sessions in our prefix space -> refuse, even with an EMPTY registry. This is
#    the case the old guard could never see: it read only the poller registry, which is written
#    behind HARNESS_USE_POLLER (off by default), so it always passed.
reset_reg; their_sessions
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "live sibling sessions REFUSE the start with no registry at all"

# 2. The refusal names the owner, our project, the live count, and a concrete retry line.
# PROJECT_ROOT must be overridden alongside STATE_DIR. The `yours:` line and the retry suggestion are
# both derived from PROJECT_ROOT (_prefix_collision_report: `derive_prefix "$PROJECT_ROOT"`), and
# leaving it at make_env's temp dir made the message read `yours: /tmp/tmp.XXXX` with a retry naming a
# temp-derived prefix — so an UNANCHORED `contains '/home/u/Harness'` passed purely off the trailing
# `…/config` line, and deleting the `yours:` line or the whole retry suggestion left this suite green.
MSG="$( ( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" PROJECT_ROOT=/home/u/Harness check_prefix_collision ) 2>&1 >/dev/null )"
# IN-PROCESS via `contains`. Under `bash -c "… <<<\"\$MSG\""` the expansion happens in a child where
# MSG is unset, so every one of these would match against an empty string.
contains(){ grep -qE -- "$1" <<<"$2"; }
assert_ok "message names the owning project"  contains '^ +owner: +/home/u/Bonsai$' "$MSG"
# Anchored on the `yours:` FIELD, not on the string anywhere in the message.
assert_ok "message names our project"         contains '^ +yours: +/home/u/Harness$' "$MSG"
assert_ok "message reports the live count"    contains '1 live tmux session' "$MSG"
# The retry must be a runnable command carrying a CONCRETE alternative prefix (derive_prefix of our
# project root = `harness`), not just the bare variable name.
assert_ok "message offers a retry command"    contains 'HARNESS_SESS_PREFIX=harness harness start' "$MSG"
assert_ok "message points at the config file" contains "$OURS/config" "$MSG"

# 3. warn mode still downgrades to a stderr warning and proceeds.
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=warn check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "warn mode proceeds despite a real collision"

# 4. The SAME sessions, owned by US -> proceed. This is `harness start --recover` against a live
#    fleet, which is a documented, supported re-run.
our_sessions
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "our own live sessions never refuse (the --recover path)"

# 5. RESERVATION: a registered sibling with NO live sessions still refuses, so two idle fleets can't
#    race into one namespace. Its run_dir holds a live pid, so it is not stale.
reset_reg; no_tmux
LIVE_RD="$(mktemp -d)"; sleep 300 & LIVE_PID=$!; echo "$LIVE_PID" > "$LIVE_RD/worker-1.pid"
( STATE_DIR="$THEIRS" RUN_DIR="$LIVE_RD" HARNESS_SESS_PREFIX=hz fleet_register )
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "a registered, live-but-idle sibling reserves its prefix"

# 5a. A registry-only refusal must not render as `prefix: hz — 0 live tmux session(s)`, which reads
#     as the guard contradicting itself (it just refused, on zero evidence?). Say what is actually
#     true: the prefix is RESERVED, the sibling simply hasn't spawned a session yet.
RMSG="$( ( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" PROJECT_ROOT=/home/u/Harness check_prefix_collision ) 2>&1 >/dev/null )"
rcontains(){ grep -qE -- "$1" <<<"$2"; }
assert_no "registry-only refusal never says '0 live tmux session'" rcontains '0 live tmux session' "$RMSG"
assert_ok "registry-only refusal says the prefix is reserved"      rcontains 'registered, no live sessions yet' "$RMSG"

# 5b. warn mode downgrades a REGISTRY-ONLY collision too (no live tmux session at all — the stage-2
#     path's own `return $?`), not just the tmux-path collision case 3 already covers.
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=warn check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "warn mode proceeds despite a registry reservation"

# 6. STALENESS: no live sessions AND no live pids -> the entry is pruned and the start proceeds. A
#    fleet killed with -9 never deregisters; its reservation must not block a restart forever.
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "a crashed sibling's stale reservation does not refuse"
assert_eq "$(ls "$FREG"/*.json 2>/dev/null | wc -l)" "0" "and the stale entry is pruned"

# 7. A poller-registry-only sibling (older engine) is still seen — fleet_registry_entries reads both.
reset_reg; no_tmux
POLL_RD="$(mktemp -d)"; sleep 300 & POLL_PID=$!; echo "$POLL_PID" > "$POLL_RD/priority.pid"
poller_register acme/widget 60 hz "$THEIRS"
python3 - "$REG" "$POLL_RD" <<'PY'
import json, os, sys
d, rd = sys.argv[1], sys.argv[2]
for n in os.listdir(d):
    p = os.path.join(d, n); rec = json.load(open(p)); rec["run_dir"] = rd
    json.dump(rec, open(p, "w"))
PY
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "a poller-registry-only sibling still refuses"
kill "$POLL_PID" 2>/dev/null; wait "$POLL_PID" 2>/dev/null

# 8. Non-colliding neighbours coexist: hz / hzli / boto, the live three-fleet arrangement.
reset_reg; no_tmux
( STATE_DIR=/p/one RUN_DIR=/p/one/run HARNESS_SESS_PREFIX=hzli fleet_register )
( STATE_DIR=/p/two RUN_DIR=/p/two/run HARNESS_SESS_PREFIX=boto fleet_register )
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "hz coexists with sibling hzli + boto"

# 9. Our OWN registry entry never trips the guard (self-exclusion on STATE_DIR).
reset_reg; no_tmux
( STATE_DIR="$OURS" RUN_DIR=/p/us/run HARNESS_SESS_PREFIX=hz fleet_register )
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "our own registry entry does not self-collide"

# 10. No registry and no tmux server -> the single-fleet no-op, unchanged behaviour.
rm -rf "$REG" "$FREG"
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "absent registry + no tmux never refuses"
unset -f tmux

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

echo "== derive_prefix: a distinct default prefix per project =="
assert_eq "$(derive_prefix /home/u/Harness)"     "harness"    "basename, lowercased"
assert_eq "$(derive_prefix /home/u/bonsai-api)"  "bonsaiapi"  "dashes stripped (they are the grammar separator)"
assert_eq "$(derive_prefix /home/u/my.app)"      "myapp"      "dots stripped (illegal in tmux session names)"
assert_eq "$(derive_prefix /home/u/Web_API_2)"   "web_api_2"  "underscores and digits kept"
assert_eq "$(derive_prefix /home/u/a_very_long_project_name)" "a_very_lon" "truncated to 10 chars"
# A name that sanitises to nothing falls back to hz<4 hex of the path digest: non-empty, tmux-safe,
# deterministic across runs, and distinct per path.
NA1="$(derive_prefix /home/u/中文)"; NA2="$(derive_prefix /home/u/中文)"; NB="$(derive_prefix /srv/中文)"
assert_ok "non-ascii name falls back to hz<hex>" bash -c "[[ '$NA1' =~ ^hz[0-9a-f]{4}$ ]]"
assert_eq "$NA1" "$NA2" "fallback is deterministic for the same path"
assert_no "different paths get different fallbacks" bash -c "[[ '$NA1' == '$NB' ]]"
# The result is always usable as a tmux session-name segment.
assert_ok "result never contains a dash" bash -c "[[ ! '$(derive_prefix /home/u/bonsai-api)' == *-* ]]"
# Run this IN-PROCESS, not under `bash -c`: the helper rig's assert_* run their argv directly, so
# lib.sh's functions are in scope. A `bash -c '! prefixes_collide …'` subshell never sourced lib.sh,
# so both functions would be "command not found" (127) and the leading `!` would negate that into a
# pass — an assertion that stays green even if the functions are deleted.
assert_no "derived prefixes of two sibling projects do not collide" \
  prefixes_collide "$(derive_prefix /home/u/Harness)" "$(derive_prefix /home/u/Bonsai)"

echo "== colliding_sessions: tmux is the enforcement signal, session_path the attribution =="
# tmux stub emitting `<name>\t<path>` — the format colliding_sessions requests. Sessions are created
# in a worktree under the OWNING project's STATE_DIR (lib.sh:850), so the path names the owner.
OURS="/home/u/Harness/.harness"; THEIRS="/home/u/Bonsai/.harness"
# Match a pattern against captured output IN-PROCESS. Never wrap these checks in `bash -c "… <<<\"\$OUT\""`:
# the escaped expansion happens in a child that never sourced lib.sh and never had $OUT exported, so the
# pattern is matched against an empty string (and any lib.sh function called there is a 127). `contains`
# keeps the here-string out of argv so assert_ok/assert_no can run it directly.
contains(){ grep -qE -- "$1" <<<"$2"; }
tmux(){ printf '%s\t%s\n' \
  "hz-main-i1"        "$THEIRS/worktrees/main-i1" \
  "hz-bug-a_b-5-fix"  "$THEIRS/worktrees/bug-a_b-5" \
  "hzli-main-i1"      "/home/u/Other/.harness/worktrees/main-i1" \
  "boto-x"            "/home/u/Third/.harness/worktrees/x"; }
export -f tmux

# Our prefix is hz and the live hz-* sessions belong to ANOTHER project -> both reported as theirs.
OUT="$(HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" colliding_sessions)"
assert_eq "$(grep -c 'theirs$' <<<"$OUT")" "2" "both hz-* sessions attributed to the sibling"
assert_no "hzli is not in our prefix space" contains 'hzli' "$OUT"
assert_no "boto is not in our prefix space" contains 'boto' "$OUT"

# Same sessions, but they are OURS (paths under our STATE_DIR) -> mine, not theirs. This is the
# `harness start --recover` path: a documented re-run against a live fleet, which must proceed.
OUT="$(HARNESS_SESS_PREFIX=hz STATE_DIR="$THEIRS" colliding_sessions)"
assert_eq "$(grep -c 'mine$' <<<"$OUT")"   "2" "sessions under our own STATE_DIR are ours"
assert_eq "$(grep -c 'theirs$' <<<"$OUT")" "0" "and none are attributed to a sibling"

# A prefix that owns a superset of the namespace still collides (hz- swallows hz-bug-…).
OUT="$(HARNESS_SESS_PREFIX=hz-bug STATE_DIR="$OURS" colliding_sessions)"
assert_ok "hz-bug sees the overlapping hz-* sessions" contains 'theirs$' "$OUT"

# A non-colliding prefix sees nothing at all — the single-fleet no-op.
OUT="$(HARNESS_SESS_PREFIX=widget STATE_DIR="$OURS" colliding_sessions)"
assert_eq "$(grep -c . <<<"$OUT" || true)" "0" "a distinct prefix sees no collisions"
unset -f tmux

# No tmux server at all (nothing running) must be a clean empty result, not an error. Call it
# IN-PROCESS — under `bash -c` the subshell never sourced lib.sh, so colliding_sessions would be
# "command not found" and the assertion would test nothing about this function.
tmux(){ return 1; }; export -f tmux
HARNESS_SESS_PREFIX=hz colliding_sessions >/dev/null
assert_eq "$?" "0" "no tmux server is a clean empty result, not an error"
unset -f tmux

echo "== fleet_owner_of: session path -> owning project dir =="
assert_eq "$(fleet_owner_of /home/u/Bonsai/.harness/worktrees/main-i1)" "/home/u/Bonsai" "cuts at /worktrees/"
assert_eq "$(fleet_owner_of /home/u/Bonsai/.harness/worktrees/bug-a_b-5/nested)" "/home/u/Bonsai" "nested path still resolves"
assert_eq "$(fleet_owner_of /some/unrecognised/path)" "/some/unrecognised/path" "unrecognised path falls back to itself"

echo "== fleet_stale: a crashed fleet's reservation must not block a restart forever =="
STALE_RD="$(mktemp -d)"
tmux(){ printf '%s\t%s\n' "alpha-main-i1" "/p/alpha/.harness/worktrees/main-i1"; }; export -f tmux
assert_no "a fleet with live sessions is NOT stale" fleet_stale alpha "$STALE_RD"
assert_ok "a fleet with neither sessions nor pids IS stale" fleet_stale beta "$STALE_RD"
sleep 300 & SP=$!; echo "$SP" > "$STALE_RD/worker-1.pid"
assert_no "a fleet with a live pid is NOT stale" fleet_stale beta "$STALE_RD"
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
assert_ok "a dead pidfile does not keep a fleet alive" fleet_stale beta "$STALE_RD"
unset -f tmux

finish

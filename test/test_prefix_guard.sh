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

echo "== the guard: tmux enforces, live workers detect, the registry reserves and attributes =="
# make_env (above) pins HARNESS_HOME *and* HARNESS_FLEETS_DIR to its own throwaway root, so the two
# stay in step and no re-pin is needed here. See helpers.sh / test_hermetic.sh's fleet-decoy block.
REG="$HARNESS_HOME/poller/registry"
FREG="$HARNESS_HOME/fleets"
reset_reg(){ rm -rf "$REG" "$FREG"; mkdir -p "$REG" "$FREG"; }
OURS="/home/u/Harness/.harness"; THEIRS="/home/u/Bonsai/.harness"
no_tmux(){ tmux(){ return 1; }; export -f tmux; }
their_sessions(){ tmux(){ printf '%s\t%s\n' "hz-main-i1" "/home/u/Bonsai/.harness/worktrees/main-i1"; }; export -f tmux; }
our_sessions(){ tmux(){ printf '%s\t%s\n' "hz-main-i1" "/home/u/Harness/.harness/worktrees/main-i1"; }; export -f tmux; }
# The guard reads live worker PROCESSES too. Silence that source for this block — otherwise these
# assertions would depend on whatever fleets happen to be running on the host, and on a developer
# machine with a live `hz` fleet the coexistence cases would refuse. The next block exercises it
# directly, and the one after that runs the real implementation against this host.
running_fleet_prefixes(){ :; }

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

# 4a. The refusal names the owner's REPO when that owner is known only to the POLLER registry.
#     fleet_slugs_of reads fleet_registry_entries, whose poller rows carry an EMPTY INTERIOR run_dir
#     field; read on tab, bash collapses the run and hands fleet_slugs_of the slug list as $rd, so the
#     message renders `(repo )` — losing the one field that tells the operator WHICH repo just
#     blocked them. This is the tmux path, so the owner comes from the session and only the slugs
#     come from the registry.
reset_reg; their_sessions
poller_register acme/widget 60 hz "$THEIRS"
SMSG="$( ( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" PROJECT_ROOT=/home/u/Harness check_prefix_collision ) 2>&1 >/dev/null )"
assert_ok "tmux-path refusal names a poller-known owner's repo" \
  contains '^ +owner: +/home/u/Bonsai \(repo acme/widget\)$' "$SMSG"

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

# 5b. warn mode downgrades a REGISTRY-ONLY collision too (no live tmux session at all — the
#     sessionless path's own `return $?`), not just the tmux-path collision case 3 already covers.
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=warn check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "warn mode proceeds despite a registry reservation"

# 6. STALENESS: no live sessions AND no live pids -> the entry is pruned and the start proceeds. A
#    fleet killed with -9 never deregisters; its reservation must not block a restart forever.
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "a crashed sibling's stale reservation does not refuse"
assert_eq "$(ls "$FREG"/*.json 2>/dev/null | wc -l)" "0" "and the stale entry is pruned"

# 7. A poller-registry-only sibling (older engine) is still seen — fleet_registry_entries reads both.
#    poller_register writes NO run_dir: the record is {slug,cadence,prefix,project} and nothing else.
#    That is the shape production actually emits, so every case below uses it unaltered. A row with
#    no run_dir carries no liveness evidence in EITHER direction, and check_prefix_collision must
#    therefore not read it as dead — see the `-n "$rd"` guard there.
reset_reg; no_tmux
poller_register acme/widget 60 hz "$THEIRS"
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "a poller-registry-only sibling still refuses"

# 7a. warn mode downgrades a poller-registry collision as well (#167's case, on the merged guard).
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=warn check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "warn mode proceeds despite a poller-registry collision"

# 7b. Non-colliding poller-registry siblings coexist: hz / hzli / boto through the OLD source.
reset_reg; no_tmux
poller_register acme/widget 60 hzli "$THEIRS"
poller_register acme/other  60 boto /third/project/.harness
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "hz coexists with poller-registered hzli + boto"

# 7c. Our OWN poller entry never trips the guard either (self-exclusion on STATE_DIR).
reset_reg; no_tmux
poller_register acme/widget 60 hz "$OURS"
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "our own poller entry does not self-collide"

# 7d. The other liveness path for a poller-only record: the sibling has a LIVE `hz-` session. It must
#     refuse too — here the tmux stage catches it first, which is the stronger signal (it can also
#     name the owner). Together with case 7 this pins a poller-only fleet as refused whether or not
#     it has spawned a session, which is the whole point of a source that carries no run_dir.
reset_reg; their_sessions
poller_register acme/widget 60 hz "$THEIRS"
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "a poller-only sibling with a live session refuses"

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

# 10. No registry, no tmux server and no running worker -> the single-fleet no-op, unchanged.
rm -rf "$REG" "$FREG"
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "absent registry + no tmux + no worker never refuses"
unset -f tmux

echo "== the guard no longer depends on the poller being enabled =="
# THE BUG (#167). HARNESS_USE_POLLER is UNSET by default, so the poller registry is always empty, so
# the original guard was a no-op for the ordinary configuration. Three fleets came up on the default
# `hz` prefix on one host and two of them reaped each other's sessions and worktrees for hours. Every
# case below runs with NO registry at all and NO tmux server — discovery comes from the live worker
# PROCESSES alone. The tmux source is silenced here for the same reason the process source is
# silenced above: otherwise these assertions would read whatever is live on the host.
reset_reg; no_tmux
rm -rf "$REG" "$FREG"
# The stubs emit a STATE_DIR (`…/.harness`), which is what the real running_fleet_prefixes reads out
# of /proc/<pid>/environ — the refusal names its parent, the project dir.
running_fleet_prefixes(){ printf 'hz\t/other/project/.harness\n'; }
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project/.harness HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "running colliding fleet REFUSED with an empty registry"

# The message must name the offender, or the operator cannot act on it.
msg="$( ( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project/.harness HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>&1 )"
assert_ok "refusal names the colliding prefix and project" contains '/other/project' "$msg"
assert_ok "refusal names the remedy"                       contains 'HARNESS_SESS_PREFIX' "$msg"
# ...and it must say a WORKER is up, not that a fleet is "registered" (nothing is registered here)
# and not `0 live tmux session(s)`, which reads as the guard refusing on no evidence at all.
assert_ok "process-source refusal names the live worker" contains 'live worker process, no sessions yet' "$msg"
assert_no "process-source refusal never claims a registration" contains 'registered, no live sessions yet' "$msg"
assert_no "process-source refusal never says '0 live tmux session'" contains '0 live tmux session' "$msg"

# warn mode still downgrades to a warning.
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project/.harness HARNESS_PREFIX_COLLISION=warn check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "warn mode proceeds despite a running collision"

# The real host layout that broke: hz (ours) + hz (sibling) + hzli (innocent bystander).
running_fleet_prefixes(){ printf 'hzli\t/third/project/.harness\nhz\t/other/project/.harness\n'; }
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project/.harness HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "a colliding fleet is caught even behind a non-colliding one"

# ...and hzli alone must NOT block us, or every multi-project host becomes unstartable.
running_fleet_prefixes(){ printf 'hzli\t/third/project/.harness\nboto\t/fourth/project/.harness\n'; }
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project/.harness HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "running hzli + boto fleets do not block an hz fleet"

# Our OWN workers must never trip the guard. `harness start --recover` is the documented top-up
# path and runs with this fleet's workers already live; self-refusal would make it unusable.
running_fleet_prefixes(){ :; }   # real impl excludes self by STATE_DIR before printing
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project/.harness HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "our own running workers do not self-collide"

# All three sources feed one decision: a collision found in ANY must refuse. (The tmux source has
# its own cases 1-4 above; here the other two are isolated from each other.)
reset_reg
poller_register acme/widget 60 hz /registry/project/.harness
running_fleet_prefixes(){ :; }
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project/.harness HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "union: registry-only collision still refuses"
reset_reg
# A process row carries NO run_dir — it cannot, a process is not a registration. If the staleness
# prune were applied to it (no run_dir, no tmux sessions => "stale") this would silently pass by
# pruning a LIVE fleet. That is why the row carries its source and fleet_stale is gated on it.
running_fleet_prefixes(){ printf 'hz\t/process/project/.harness\n'; }
( HARNESS_SESS_PREFIX=hz STATE_DIR=/our/project/.harness HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "union: process-only collision refuses (never stale-pruned for lacking a run_dir)"
unset -f tmux

echo "== running_fleet_prefixes against the real process table =="
# The seam above is stubbed everywhere else, so exercise the genuine implementation once. It must
# not crash, must emit well-formed `<prefix>\tab<state-dir>` rows, and must never report the
# caller's own state dir. Stubs are what let #167's first draft pass while finding zero of the three
# fleets actually running on the box.
unset -f running_fleet_prefixes
source "$HERE/../scripts/lib.sh"          # restore the real one
real_out="$(running_fleet_prefixes /definitely/not/a/real/state/dir 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "running_fleet_prefixes exits 0 on a real host"
bad="$(awk -F'\t' 'NF!=2 || $1=="" || $2==""' <<<"${real_out}" | grep -c . || true)"
assert_eq "$bad" "0" "every emitted row is <prefix>TAB<state-dir>"
assert_no "never reports the state dir it was asked to exclude" \
  grep -q '/definitely/not/a/real/state/dir' <<<"$real_out"
# Whatever it found, feeding it back through the predicate must agree that a prefix nothing uses
# collides with nothing. IN-PROCESS: under `bash -c` the child never sourced lib.sh, prefixes_collide
# would be a 127, and a trailing `true` would make the assertion a permanent pass.
drives_predicate(){ local p _
  while IFS=$'\t' read -r p _; do
    [[ -n "$p" ]] || continue
    prefixes_collide zzz "$p" && return 1
  done <<<"$1"
  return 0; }
assert_ok "its output drives prefixes_collide without error" drives_predicate "$real_out"

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

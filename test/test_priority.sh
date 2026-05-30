#!/usr/bin/env bash
# test_priority.sh — the priority bug lane (#26): issue-level bug claims, single-agent
# serialization, stale-claim recovery, and resident pause/stop semantics.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"; make_env

# ── bug-claim lifecycle: claim records the worker id; is/release reflect it ────
# Bug identity is repo-qualified end-to-end (#37): the GitHub-backed seam emits "<repo>#<num>"
# tokens and claim files key on a sanitised repo+num, so everything below carries the repo.
_bug_numbers(){ printf 'acme/widget#6\nacme/widget#7\n'; }
assert_eq "$(claimable_bugs | tr '\n' ' ')" "acme/widget#6 acme/widget#7 " "both bugs claimable when unclaimed"
got="$(claim_next_bug P1)"; assert_eq "$got" "acme/widget#6" "claim_next_bug returns first claimable bug token"
assert_eq "$(awk '{print $1}' "$CLAIMS_DIR/bug-acme_widget-6.claim")" "P1" "claim records worker id (repo-qualified key)"
assert_eq "$(awk '{print $3}' "$CLAIMS_DIR/bug-acme_widget-6.claim")" "acme/widget#6" "claim stores the full repo-qualified token (#44 — lane_bug/checkpoint read it)"
assert_ok  "claimed bug is is_bug_claimed"          is_bug_claimed acme/widget#6
assert_eq "$(claimable_bugs | tr '\n' ' ')" "acme/widget#7 " "claimed bug excluded -> only the other waits"
release_bug_claim acme/widget#6
assert_ok "release removes the bug-claim file" bash -c "[[ ! -f '$CLAIMS_DIR/bug-acme_widget-6.claim' ]]"
assert_eq "$(claimable_bugs | tr '\n' ' ')" "acme/widget#6 acme/widget#7 " "released bug is claimable again"

# ── single-agent serialization: two simultaneous claimers get DIFFERENT bugs ──
( claim_next_bug A > "$RUN_DIR/ba.out" ) &
( claim_next_bug B > "$RUN_DIR/bb.out" ) &
wait
ra="$(cat "$RUN_DIR/ba.out")"; rb="$(cat "$RUN_DIR/bb.out")"
assert_ok "both claimers got a bug"     bash -c "[[ -n '$ra' && -n '$rb' ]]"
assert_ok "claimers got DIFFERENT bugs" bash -c "[[ '$ra' != '$rb' ]]"
rm -f "$CLAIMS_DIR"/bug-*.claim

# ── stale-claim recovery: clear_stale_claims frees a dead-pid bug claim, keeps a live one ──
printf 'P1 %s\n' "$$"     > "$CLAIMS_DIR/bug-acme_widget-6.claim"   # this shell -> live
printf 'P1 %s\n' "999999" > "$CLAIMS_DIR/bug-acme_widget-7.claim"   # dead pid -> stale
assert_ok "live-pid bug claim is claimed"    is_bug_claimed acme/widget#6
assert_no "dead-pid bug claim is not claimed" is_bug_claimed acme/widget#7
clear_stale_claims >/dev/null
assert_ok "stale bug claim swept by clear_stale_claims" bash -c "[[ ! -f '$CLAIMS_DIR/bug-acme_widget-7.claim' ]]"
assert_ok "live bug claim kept"                         bash -c "[[ -f '$CLAIMS_DIR/bug-acme_widget-6.claim' ]]"
rm -f "$CLAIMS_DIR"/bug-*.claim

# ── resident worker loop: bug_tick claims→drives→releases; pause idles; idle dedups ──
source "$HERE/../scripts/drive.sh" 2>/dev/null || true
source "$HERE/../scripts/priority-worker.sh"   # defines bug_tick/bug_step/drive_bug; main() guarded out
PRIORITY_POLL=0
DROVE="$RUN_DIR/drove"; : > "$DROVE"
drive_bug(){ echo "$1" >> "$DROVE"; }     # record which bug token was driven (no real session)

# work: one claimable bug -> claim, drive, release, rc 0; claim released after the tick
_bug_numbers(){ printf 'acme/widget#6\n'; }
bug_tick P1; assert_eq "$?" "0" "bug_tick claimed+drove a bug -> rc 0"
assert_eq "$(cat "$DROVE")" "acme/widget#6" "drive_bug ran for the claimed bug token"
assert_ok "bug released after tick (serial: lane holds at most one)" bash -c "[[ ! -f '$CLAIMS_DIR/bug-acme_widget-6.claim' ]]"

# idle: no claimable bugs -> rc 1, drives nothing
: > "$DROVE"; _bug_numbers(){ :; }
bug_tick P1; assert_eq "$?" "1" "bug_tick with no bugs -> rc 1 (idle)"
assert_eq "$(cat "$DROVE")" "" "idle tick drove nothing"

# pause: bug_tick returns 3 and never claims, even with a bug available
_bug_numbers(){ printf 'acme/widget#6\n'; }; : > "$DROVE"
touch "$PAUSE_FLAG"
bug_tick P1; assert_eq "$?" "3" "bug_tick returns 3 when paused"
assert_eq "$(cat "$DROVE")" "" "bug_tick drove nothing while paused"
assert_ok "no bug claimed while paused" bash -c "[[ -z \"\$(ls '$CLAIMS_DIR'/bug-*.claim 2>/dev/null)\" ]]"
rm -f "$PAUSE_FLAG"

# bug_step: idle banner logged ONCE per idle streak (deduped across polls), keeps polling
_bug_numbers(){ :; }; _IDLE_LOGGED=0
ILOG="$RUN_DIR/idle.log"; : > "$ILOG"
bug_step P1 >>"$ILOG" 2>&1; assert_eq "$?" "1" "bug_step: idle -> rc 1 (resident, no exit)"
bug_step P1 >>"$ILOG" 2>&1
bug_step P1 >>"$ILOG" 2>&1; assert_eq "$?" "1" "bug_step: still resident after 3 idle polls"
assert_eq "$(grep -c 'idle' "$ILOG")" "1" "bug_step: idle banner logged exactly once (deduped)"
# real work resets the dedup so a later idle streak re-announces
_bug_numbers(){ printf 'acme/widget#6\n'; }
bug_step P1 >>"$ILOG" 2>&1; assert_eq "$?" "0" "bug_step: bug claimed+driven -> rc 0"
: > "$ILOG"; _bug_numbers(){ :; }
bug_step P1 >>"$ILOG" 2>&1; assert_eq "$?" "1" "bug_step: idle again -> rc 1"
assert_eq "$(grep -c 'idle' "$ILOG")" "1" "bug_step: idle banner re-logged after work (dedup reset)"

# ── #37 cross-repo collision: two repos each with bug #5 are INDEPENDENT ──────
# Bug identity carries the repo, so claiming repo A's #5 neither blocks nor mis-routes repo B's #5.
rm -f "$CLAIMS_DIR"/bug-*.claim
_bug_numbers(){ printf 'acme/a#5\nacme/b#5\n'; }
assert_eq "$(claimable_bugs | tr '\n' ' ')" "acme/a#5 acme/b#5 " "both repos' #5 are claimable (distinct identity)"
ta="$(claim_next_bug P1)"; assert_eq "$ta" "acme/a#5" "claim picks repo A's #5"
assert_ok "repo A #5 claimed"                            is_bug_claimed acme/a#5
assert_no "repo B #5 NOT claimed by claiming repo A's #5" is_bug_claimed acme/b#5
assert_eq "$(claimable_bugs | tr '\n' ' ')" "acme/b#5 " "repo B's #5 still waits (not blocked by A's)"
tb="$(claim_next_bug P2)"; assert_eq "$tb" "acme/b#5" "claim then picks repo B's #5 independently"
release_bug_claim acme/a#5; release_bug_claim acme/b#5
rm -f "$CLAIMS_DIR"/bug-*.claim

# ── #37 drive_bug resolves SLUG/REPO from the CARRIED repo (not a rescan) ─────
assert_eq "$(_bug_ref_repo acme/b#5)" "acme/b" "_bug_ref_repo extracts the carried repo"
assert_eq "$(_bug_ref_num  acme/b#5)" "5"      "_bug_ref_num extracts the number"
source "$HERE/../scripts/priority-worker.sh"      # restore the real drive_bug (was stubbed above)
ROUTE="$RUN_DIR/route"; : > "$ROUTE"
HARNESS_TOPOLOGY=multi
bug_phase(){ echo triage; }                                   # avoid gh
spawn_bug(){ echo "SLUG=$SLUG REPO=$REPO n=$1 phase=$2" >> "$ROUTE"; }
session_live(){ return 1; }                                   # no live session -> returns at once
drive_bug acme/b#5 >/dev/null 2>&1
assert_ok "drive_bug routes to the carried repo acme/b (not a colliding repo)" grep -q 'SLUG=acme/b ' "$ROUTE"
assert_ok "drive_bug carries the right number"                                 grep -q ' n=5 ' "$ROUTE"

# ── #37 fix-pending-first holds ACROSS repos (global re-sort of candidates) ───
# _bug_numbers tags each repo's candidates with their phase (via _repo_bugs) and globally
# re-sorts, so a bug-triaged in ANY repo drains before a fresh bug in ANY repo. Same-phase
# candidates keep their cross-repo input order (stable).
source "$HERE/../scripts/lib.sh"                                       # restore the real _bug_numbers (overridden above)
_bug_repos(){ printf 'acme/a\nacme/b\n'; }
_repo_bugs(){ case "$1" in
  acme/a) printf '5\ttriage\n';;                               # fresh bug, earlier repo
  acme/b) printf '7\tfix\n8\ttriage\n';;                       # pending fix + fresh, later repo
esac; }
assert_eq "$(_bug_numbers | tr '\n' ' ')" "acme/b#7 acme/a#5 acme/b#8 " \
  "fix-pending (acme/b#7) drains before any fresh bug across repos; same-phase keeps input order"
# bug_repo back-compat (bare ref): matches the number field of _repo_bugs' "<num>\t<phase>" output
assert_eq "$(bug_repo 5)" "acme/a" "bug_repo(bare): resolves the repo listing #5"
assert_eq "$(bug_repo 8)" "acme/b" "bug_repo(bare): resolves the repo listing #8 (number field, not the phase line)"

# ── #49 bare-repo owner-qualification: token, claim, session, worktree, lane_phase ALL agree ─────
# #44 owner-qualified the session/worktree (SLUG=_with_owner REPO) but left _bug_numbers' token —
# and so the claim key — on the RAW _bug_repos string. On a BARE repo (multi col-2 `widget`, or
# single HARNESS_REPO=widget) with HARNESS_OWNER set, the claim landed at bug-widget-9 while the
# session was hz-bug-acme_widget-9-fix: _checkpoint_target's lookup missed and lane_phase's grep
# never matched. Owner-qualifying the token at construction makes every deriver share ONE slug.
source "$HERE/../scripts/lib.sh"                                       # restore the real _bug_numbers
HARNESS_TOPOLOGY=multi; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz
WORKTREES_DIR="$RUN_DIR/wt"                                    # hermetic worktree base for the path check
_bug_repos(){ echo widget; }                                  # BARE repo (no owner) — the regression trigger
_repo_bugs(){ printf '9\tfix\n'; }
assert_eq "$(_bug_numbers | tr '\n' ' ')" "acme/widget#9 " "_bug_numbers owner-qualifies a bare repo's token"
tok="$(_bug_numbers | head -n1)"
assert_eq "$(_bug_claim_key "$tok")" "bug-acme_widget-9" "claim key derives from the owner-qualified slug"
# the slug drive_bug computes (SLUG=_with_owner of the carried repo) feeds session + worktree
slug="$(_with_owner "$(_bug_ref_repo "$tok")")"
assert_eq "$slug" "acme/widget" "drive_bug's SLUG (=_with_owner carried repo) is owner-qualified"
assert_eq "$(sess_bug "$slug" 9 fix)" "hz-bug-acme_widget-9-fix" "session embeds the owner-qualified slug"
assert_eq "$(bug_worktree "$slug" 9)" "$RUN_DIR/wt/bug-acme_widget-i9" "worktree path uses the owner-qualified slug"
# _checkpoint_target parses san+num from the session and looks up bug-<san>-<n>.claim: it must equal
# the key claim_next_bug actually wrote (token-derived). Agreement = no fallback to the bug_repo rescan.
san="$(printf '%s' "$(sess_bug "$slug" 9 fix)" | sed -E "s/^hz-bug-(.+)-9-fix$/\1/")"
assert_eq "bug-${san}-9" "$(_bug_claim_key "$tok")" "checkpoint's session-derived lookup == the written claim key"
# lane_phase resolves the live session via the token's grep key (no permanent '?')
tmux(){ [[ "$1" == ls ]] && echo "hz-bug-acme_widget-9-fix"; }
assert_eq "$(lane_phase "$tok")" "fix" "lane_phase resolves the owner-qualified session (no '?' phase)"
unset -f tmux
# existing owner-qualified configs are unaffected: a repo that already carries an owner is a no-op
_bug_repos(){ echo acme/widget; }
assert_eq "$(_bug_numbers | tr '\n' ' ')" "acme/widget#9 " "_bug_numbers leaves an already-qualified repo unchanged"

# ── priority.sh launches EXACTLY ONE resident lane; pid tracked under run/; idempotent ──
# Hermetic: empty HARNESS_REPO means the lane finds no bug repos and just idles (no gh).
LRUN="$(mktemp -d)"
HARNESS_PRIORITY_POLL=3600 HARNESS_TOPOLOGY=single HARNESS_REPO="" RUN_DIR="$LRUN" \
  bash "$HERE/../scripts/priority.sh" >/dev/null 2>&1
assert_ok "priority.sh wrote run/priority.pid" bash -c "[[ -f '$LRUN/priority.pid' ]]"
lpid="$(cat "$LRUN/priority.pid")"
assert_ok "lane process is alive" bash -c "kill -0 '$lpid' 2>/dev/null"
# re-run: must NOT spawn a second lane — same pid, still exactly one pidfile
HARNESS_PRIORITY_POLL=3600 HARNESS_TOPOLOGY=single HARNESS_REPO="" RUN_DIR="$LRUN" \
  bash "$HERE/../scripts/priority.sh" >/dev/null 2>&1
assert_eq "$(cat "$LRUN/priority.pid")" "$lpid" "re-run kept the same lane (idempotent, no double-spawn)"
assert_eq "$(ls "$LRUN"/priority*.pid | wc -l | tr -d ' ')" "1" "exactly one lane pidfile"
kill "$lpid" 2>/dev/null; rm -rf "$LRUN"

# ── start.sh wires the lane in alongside the pool ──
assert_ok "start.sh invokes priority.sh" bash -c "grep -q 'priority.sh' '$HERE/../scripts/start.sh'"

# ── stop.sh tears the lane down (its pidfile is generic run/*.pid) ──
SRUN="$(mktemp -d)"
( exec sleep 600 ) & lane=$!     # stand-in lane process
printf '%s\n' "$lane" > "$SRUN/priority.pid"
RUN_DIR="$SRUN" bash "$HERE/../scripts/stop.sh" >/dev/null 2>&1
assert_no "stop.sh killed the lane process"  bash -c "kill -0 '$lane' 2>/dev/null"
assert_ok "stop.sh removed the lane pidfile" bash -c "[[ ! -f '$SRUN/priority.pid' ]]"
rm -rf "$SRUN"

# ── #42 lane self-heal: reap_lane clears a crashed bug's stale agent-working ──────────
# A bug-lane session that dies after spawn_bug stamps agent-working but BEFORE the issue closes
# leaves the bug stuck under agent-working: bug_lane_candidates excludes agent-working, so the
# cap-1 lane idles "watching" an OPEN bug forever (needing a manual `harness start --recover`).
# reap_lane — run at the TOP of every poll, the lane's analog of the pool's reap_team — frees the
# stale label + reaps any orphaned fix worktree so the next poll re-claims the bug. A genuinely
# LIVE session is never swept (no double-dispatch), gated by bug_session_live: the SAME liveness
# predicate start --recover uses (#43), so the two reconciliation paths can never disagree.
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/../scripts/priority-worker.sh"
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"   # isolate from the live fleet's worktrees

# bug_session_live <slug> <n>: live when EITHER phase's sess_bug session is up; dead only when
# neither is. The session name MUST be built the SAME way production (spawn_bug) builds it — the
# 3-arg repo-qualified sess_bug "<slug>" <n> <phase> (#44) — else the guard can never match the
# real session and a future sess_bug arity change silently re-breaks both reap paths (#48).
LIVE="$RUN_DIR/live_sessions"; : > "$LIVE"
SLUG="$(_with_owner "$HARNESS_REPO")"                     # exactly the slug reap_lane derives
session_live(){ grep -qxF "$1" "$LIVE"; }                # a session is "live" iff listed in $LIVE
printf '%s\n' "$(sess_bug "$SLUG" 9 fix)"    > "$LIVE"; assert_ok "bug_session_live: true when fix session live"     bug_session_live "$SLUG" 9
printf '%s\n' "$(sess_bug "$SLUG" 9 triage)" > "$LIVE"; assert_ok "bug_session_live: true when triage session live"  bug_session_live "$SLUG" 9
: > "$LIVE";                                            assert_no "bug_session_live: false when neither session live" bug_session_live "$SLUG" 9

# reap_lane records its GitHub + worktree effects through stubs (no real gh/git).
GHLOG="$RUN_DIR/reap_gh"; WTLOG="$RUN_DIR/reap_wt"
gh(){ echo "$*" >> "$GHLOG"; }                           # record every gh call
remove_worktree(){ echo "$2|$3" >> "$WTLOG"; }           # record worktree path + branch reaped
_repo_working_bugs(){ echo 9; }                          # repo's one OPEN agent-working bug is #9

# DEAD session: reap_lane frees the stale agent-working AND reaps the orphaned worktrees. The crash
# could have been in EITHER phase, so it reaps both the fix (bug-…|issue/<n>) and the triage
# (triage-…|agent/bug-triage-<n>) worktree+branch (#109) — idempotent on whichever never existed.
: > "$GHLOG"; : > "$WTLOG"; : > "$LIVE"                   # no live session for #9
reap_lane
assert_ok "reap_lane removed stale agent-working for the dead-session bug" \
  grep -q "issue edit 9 -R acme/widget --remove-label agent-working" "$GHLOG"
assert_ok "reap_lane reaped the orphaned fix worktree + issue branch" \
  grep -qxF "$WORKTREES_DIR/bug-acme_widget-i9|issue/9" "$WTLOG"
assert_ok "reap_lane reaped the orphaned triage worktree + branch (#109)" \
  grep -qxF "$WORKTREES_DIR/triage-acme_widget-i9|agent/bug-triage-9" "$WTLOG"

# LIVE session: reap_lane leaves the bug entirely untouched (no double-dispatch). The live session
# is the REAL one production creates — sess_bug "$SLUG" 9 fix — so this exercises reap_lane's guard
# end-to-end against the production session name, not a 2-arg stand-in production never makes (#48).
: > "$GHLOG"; : > "$WTLOG"; printf '%s\n' "$(sess_bug "$SLUG" 9 fix)" > "$LIVE"   # #9 fix session is live
reap_lane
assert_eq "$(cat "$GHLOG")" "" "reap_lane did NOT touch a live-session bug's labels"
assert_eq "$(cat "$WTLOG")" "" "reap_lane did NOT reap a live-session bug's worktree"

# wiring: bug_step runs reap_lane at the top of EVERY poll (per-poll self-heal, like the pool)
REAPED="$RUN_DIR/reaped"; : > "$REAPED"
reap_lane(){ echo tick >> "$REAPED"; }                   # stub the now-tested reap to count calls
_bug_numbers(){ :; }; PRIORITY_POLL=0; _IDLE_LOGGED=0
bug_step P1 >/dev/null 2>&1
assert_eq "$(grep -c tick "$REAPED")" "1" "bug_step ran reap_lane once (per-poll self-heal)"

# ───────────────────── PRD-B slice 3 (#72): bug-lane snapshot dispatch gate ─────────────────────
# The lane gates exactly like the pool. A stale/missing snapshot HOLDS the whole poll — NO reap_lane
# (its self-heal does gh writes), no claim, no gh — relaunches the poller, and logs a deduped banner;
# a fresh snapshot serves reap_lane + the claim from the snapshot. Flag OFF = today's path (every
# assertion above ran with it unset). Restore the real lane fns (some were stubbed above), then point
# the host-root SEAMS at a temp dir.
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/../scripts/priority-worker.sh"
P3="$(mktemp -d)"
HARNESS_HOME="$P3/host"; HARNESS_POLLER_DIR="$P3/host/poller"; HARNESS_SNAPSHOTS_DIR="$P3/host/snapshots"
POLLER_REGISTRY_DIR="$HARNESS_POLLER_DIR/registry"; POLLER_PID="$HARNESS_POLLER_DIR/poller.pid"; POLLER_LOCK="$HARNESS_POLLER_DIR/poller.lock"
mkdir -p "$HARNESS_SNAPSHOTS_DIR" "$POLLER_REGISTRY_DIR"
export HARNESS_HOME HARNESS_POLLER_DIR HARNESS_SNAPSHOTS_DIR HARNESS_POLLER_CMD="sleep 30"
HARNESS_USE_POLLER=1; HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme
poller_register acme/widget 60 hz "$P3/proj"
p3_snap(){ cat > "$HARNESS_SNAPSHOTS_DIR/acme__widget.json" <<JSON
{"schema_version":1,"generated_at":$1,"slug":"acme/widget","issues":[],"has_plan":false,"plan_marker":null,"self_login":"me"}
JSON
}
NOW="$(date +%s)"
P3REAP="$P3/reap.log"; P3CLAIM="$P3/claim.log"; P3GH="$P3/gh.log"
reap_lane(){ echo called >> "$P3REAP"; }
claim_next_bug(){ echo called >> "$P3CLAIM"; echo ""; }
gh(){ echo "$*" >> "$P3GH"; }
PRIORITY_POLL=0; _IDLE_LOGGED=0
: > "$P3REAP"; : > "$P3CLAIM"; : > "$P3GH"
P3HOLD="$P3/hold.log"; : > "$P3HOLD"
p3_snap "$((NOW-100000))"                                 # stale
bug_step P1 >>"$P3HOLD" 2>&1; assert_eq "$?" "4" "bug_step: stale snapshot HOLDS the poll (rc 4)"
assert_eq "$(cat "$P3REAP")"  "" "bug_step: held tick did NOT run reap_lane (no gh self-heal on hold)"
assert_eq "$(cat "$P3CLAIM")" "" "bug_step: held tick made NO bug claim"
assert_eq "$(cat "$P3GH")"    "" "bug_step: held tick made NO gh read"
bug_step P1 >>"$P3HOLD" 2>&1; bug_step P1 >>"$P3HOLD" 2>&1
assert_eq "$(grep -c 'snapshot stale' "$P3HOLD")" "1" "bug_step: hold banner logged once (deduped)"

# fresh: reap_lane + the claim both run (served from the snapshot)
: > "$P3REAP"; : > "$P3CLAIM"; _IDLE_LOGGED=0; p3_snap "$NOW"
bug_step P1 >/dev/null 2>&1
assert_eq "$(cat "$P3REAP")" "called" "bug_step: fresh tick runs reap_lane"
assert_ok "bug_step: fresh tick consults the bug claim" bash -c "[[ -s '$P3CLAIM' ]]"
[[ -f "$POLLER_PID" ]] && kill "$(cat "$POLLER_PID")" 2>/dev/null
rm -rf "$P3"

# ── start.sh registers this project's repos + ensures a poller, gated on the flag ──
assert_ok "start.sh registers the project's repos behind the flag" bash -c "grep -q 'poller_register_project' '$HERE/../scripts/start.sh'"
assert_ok "start.sh ensures a poller behind the flag"              bash -c "grep -q 'ensure_poller'           '$HERE/../scripts/start.sh'"
assert_ok "start.sh gates the poller wiring on HARNESS_USE_POLLER" bash -c "grep -q 'HARNESS_USE_POLLER'       '$HERE/../scripts/start.sh'"

# poller_register_project: registers every slug this project serves, keyed on STATE_DIR (the refcount)
RP="$(mktemp -d)"
HARNESS_POLLER_DIR="$RP/poller"; POLLER_REGISTRY_DIR="$RP/poller/registry"; mkdir -p "$POLLER_REGISTRY_DIR"
HARNESS_TOPOLOGY=single; HARNESS_REPO=acme/widget; HARNESS_OWNER=acme; STATE_DIR="$RP/state"; HARNESS_PRIORITY_POLL=60; HARNESS_SESS_PREFIX=hz
poller_register_project
assert_eq "$(poller_registry_slugs)" "acme/widget" "poller_register_project (single) registers HARNESS_REPO"
assert_ok "registry file is keyed on STATE_DIR" bash -c "ls '$POLLER_REGISTRY_DIR'/acme__widget__*.json >/dev/null 2>&1"
HARNESS_TOPOLOGY=multi; TARGETS_TSV="$(mktemp)"
printf 'a\tacme/a\t-\troot\nb\tacme/b\ta\tneeds a\n' > "$TARGETS_TSV"
rm -f "$POLLER_REGISTRY_DIR"/*.json
poller_register_project
assert_eq "$(poller_registry_slugs | tr '\n' ' ')" "acme/a acme/b " "poller_register_project (multi) registers every targets row"
rm -rf "$RP"

# ── stop.sh deregisters ONLY this project (refcount); a shared slug stays; the poller is never killed ──
SD="$(mktemp -d)"
HARNESS_POLLER_DIR="$SD/poller"; HARNESS_HOME="$SD"; POLLER_REGISTRY_DIR="$SD/poller/registry"; mkdir -p "$POLLER_REGISTRY_DIR" "$SD/poller"
poller_register acme/widget 60 hz   "$SD/projA"
poller_register acme/widget 60 hzli "$SD/projB"
( exec sleep 60 ) & SDPOLL=$!; echo "$SDPOLL" > "$SD/poller/poller.pid"   # live poller stop must NEVER touch
HARNESS_USE_POLLER=1 STATE_DIR="$SD/projA" HARNESS_POLLER_DIR="$SD/poller" HARNESS_HOME="$SD" RUN_DIR="$(mktemp -d)" \
  bash "$HERE/../scripts/stop.sh" >/dev/null 2>&1
assert_eq "$(poller_registry_slugs)" "acme/widget" "stop(projA): slug stays (projB still references it)"
assert_ok "stop did NOT kill the poller (not in RUN_DIR, not a tmux session)" kill -0 "$SDPOLL"
HARNESS_USE_POLLER=1 STATE_DIR="$SD/projB" HARNESS_POLLER_DIR="$SD/poller" HARNESS_HOME="$SD" RUN_DIR="$(mktemp -d)" \
  bash "$HERE/../scripts/stop.sh" >/dev/null 2>&1
assert_eq "$(poller_registry_slugs)" "" "stop(projB): last ref dropped -> slug gone (refcount 0)"
# flag OFF: stop never touches the registry (regression — today's stop is registry-blind). The flag
# is EXPORTED (lib.sh), so a child stop.sh would inherit our =1 — clear it explicitly to prove off.
poller_register acme/widget 60 hz "$SD/projC"
HARNESS_USE_POLLER= STATE_DIR="$SD/projC" HARNESS_POLLER_DIR="$SD/poller" HARNESS_HOME="$SD" RUN_DIR="$(mktemp -d)" \
  bash "$HERE/../scripts/stop.sh" >/dev/null 2>&1
assert_eq "$(poller_registry_slugs)" "acme/widget" "stop with the flag OFF leaves the registry untouched"
kill "$SDPOLL" 2>/dev/null; rm -rf "$SD"

finish

#!/usr/bin/env bash
# test_priority.sh — the priority bug lane (#26): issue-level bug claims, single-agent
# serialization, stale-claim recovery, and resident pause/stop semantics.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/helpers.sh"; make_env

# ── bug-claim lifecycle: claim records the worker id; is/release reflect it ────
# Bug identity is repo-qualified end-to-end (#37): the GitHub-backed seam emits "<repo>#<num>"
# tokens and claim files key on a sanitised repo+num, so everything below carries the repo.
_bug_numbers(){ printf 'acme/widget#6\nacme/widget#7\n'; }
assert_eq "$(claimable_bugs | tr '\n' ' ')" "acme/widget#6 acme/widget#7 " "both bugs claimable when unclaimed"
got="$(claim_next_bug P1)"; assert_eq "$got" "acme/widget#6" "claim_next_bug returns first claimable bug token"
assert_eq "$(awk '{print $1}' "$CLAIMS_DIR/bug-acme_widget-6.claim")" "P1" "claim records worker id (repo-qualified key)"
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
source "$HERE/../drive.sh" 2>/dev/null || true
source "$HERE/../priority-worker.sh"   # defines bug_tick/bug_step/drive_bug; main() guarded out
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
source "$HERE/../priority-worker.sh"      # restore the real drive_bug (was stubbed above)
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
source "$HERE/../lib.sh"                                       # restore the real _bug_numbers (overridden above)
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

# ── priority.sh launches EXACTLY ONE resident lane; pid tracked under run/; idempotent ──
# Hermetic: empty HARNESS_REPO means the lane finds no bug repos and just idles (no gh).
LRUN="$(mktemp -d)"
HARNESS_PRIORITY_POLL=3600 HARNESS_TOPOLOGY=single HARNESS_REPO="" RUN_DIR="$LRUN" \
  bash "$HERE/../priority.sh" >/dev/null 2>&1
assert_ok "priority.sh wrote run/priority.pid" bash -c "[[ -f '$LRUN/priority.pid' ]]"
lpid="$(cat "$LRUN/priority.pid")"
assert_ok "lane process is alive" bash -c "kill -0 '$lpid' 2>/dev/null"
# re-run: must NOT spawn a second lane — same pid, still exactly one pidfile
HARNESS_PRIORITY_POLL=3600 HARNESS_TOPOLOGY=single HARNESS_REPO="" RUN_DIR="$LRUN" \
  bash "$HERE/../priority.sh" >/dev/null 2>&1
assert_eq "$(cat "$LRUN/priority.pid")" "$lpid" "re-run kept the same lane (idempotent, no double-spawn)"
assert_eq "$(ls "$LRUN"/priority*.pid | wc -l | tr -d ' ')" "1" "exactly one lane pidfile"
kill "$lpid" 2>/dev/null; rm -rf "$LRUN"

# ── start.sh wires the lane in alongside the pool ──
assert_ok "start.sh invokes priority.sh" bash -c "grep -q 'priority.sh' '$HERE/../start.sh'"

# ── stop.sh tears the lane down (its pidfile is generic run/*.pid) ──
SRUN="$(mktemp -d)"
( exec sleep 600 ) & lane=$!     # stand-in lane process
printf '%s\n' "$lane" > "$SRUN/priority.pid"
RUN_DIR="$SRUN" bash "$HERE/../stop.sh" >/dev/null 2>&1
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
source "$HERE/../lib.sh"; source "$HERE/../drive.sh"; source "$HERE/../priority-worker.sh"
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"   # isolate from the live fleet's worktrees

# bug_session_live: live when EITHER phase's sess_bug session is up; dead only when neither is.
LIVE="$RUN_DIR/live_sessions"; : > "$LIVE"
session_live(){ grep -qxF "$1" "$LIVE"; }                # a session is "live" iff listed in $LIVE
printf '%s\n' "$(sess_bug 9 fix)"    > "$LIVE"; assert_ok "bug_session_live: true when fix session live"     bug_session_live 9
printf '%s\n' "$(sess_bug 9 triage)" > "$LIVE"; assert_ok "bug_session_live: true when triage session live"  bug_session_live 9
: > "$LIVE";                                    assert_no "bug_session_live: false when neither session live" bug_session_live 9

# reap_lane records its GitHub + worktree effects through stubs (no real gh/git).
GHLOG="$RUN_DIR/reap_gh"; WTLOG="$RUN_DIR/reap_wt"
gh(){ echo "$*" >> "$GHLOG"; }                           # record every gh call
remove_worktree(){ echo "$2|$3" >> "$WTLOG"; }           # record worktree path + branch reaped
_repo_working_bugs(){ echo 9; }                          # repo's one OPEN agent-working bug is #9

# DEAD session: reap_lane frees the stale agent-working AND reaps the orphaned fix worktree+branch
: > "$GHLOG"; : > "$WTLOG"; : > "$LIVE"                   # no live session for #9
reap_lane
assert_ok "reap_lane removed stale agent-working for the dead-session bug" \
  grep -q "issue edit 9 -R acme/widget --remove-label agent-working" "$GHLOG"
assert_eq "$(cat "$WTLOG")" "$WORKTREES_DIR/bug-acme_widget-i9|issue/9" \
  "reap_lane reaped the orphaned fix worktree + issue branch"

# LIVE session: reap_lane leaves the bug entirely untouched (no double-dispatch)
: > "$GHLOG"; : > "$WTLOG"; printf '%s\n' "$(sess_bug 9 fix)" > "$LIVE"   # #9 fix session is live
reap_lane
assert_eq "$(cat "$GHLOG")" "" "reap_lane did NOT touch a live-session bug's labels"
assert_eq "$(cat "$WTLOG")" "" "reap_lane did NOT reap a live-session bug's worktree"

# wiring: bug_step runs reap_lane at the top of EVERY poll (per-poll self-heal, like the pool)
REAPED="$RUN_DIR/reaped"; : > "$REAPED"
reap_lane(){ echo tick >> "$REAPED"; }                   # stub the now-tested reap to count calls
_bug_numbers(){ :; }; PRIORITY_POLL=0; _IDLE_LOGGED=0
bug_step P1 >/dev/null 2>&1
assert_eq "$(grep -c tick "$REAPED")" "1" "bug_step ran reap_lane once (per-poll self-heal)"

finish

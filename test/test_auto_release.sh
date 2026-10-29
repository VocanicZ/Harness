#!/usr/bin/env bash
# test_auto_release.sh — PRD #274 / #283: the fleet cuts Harness releases itself — once per reviewed
# PRD close in the Harness repo, at most one patch release per hour for bug fixes, and a red release
# gate files one bug issue instead of looping.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
make_env
export HARNESS_RELEASE_REPO=acme/harness HARNESS_AUTORELEASE_DIR="$RUN_DIR/autorelease"
# #331: these checkouts carry no vX.Y.Z tag; the bootstrap release is test_auto_release_bootstrap.sh's.
mkdir -p "$HARNESS_AUTORELEASE_DIR"; : > "$HARNESS_AUTORELEASE_DIR/bootstrap"
RLOG="$RUN_DIR/release.log"; GH_LOG="$RUN_DIR/gh.log"; EV="$RUN_DIR/events"; : > "$RLOG"; : > "$GH_LOG"; : > "$EV"
# Stub release command: logs the reason it was run for (and the --ref to $REFS), exits $STUB_RC
# (4 = the gate failed).
REFS="$RUN_DIR/refs"; : > "$REFS"
printf '#!/usr/bin/env bash\necho "$HARNESS_RELEASE_REASON" >> %q\necho "$2" >> %q\nexit "${STUB_RC:-0}"\n' "$RLOG" "$REFS" > "$RUN_DIR/release"
chmod +x "$RUN_DIR/release"; export HARNESS_RELEASE_CMD="$RUN_DIR/release"
gh(){ echo "$*" >> "$GH_LOG"
  case "$1 $2" in
    "issue list")   cat "$RUN_DIR/open-bugs" 2>/dev/null || echo '[]';;
    "issue create") echo '[{"number":99}]' > "$RUN_DIR/open-bugs"; echo "https://github.com/acme/harness/issues/99";;
  esac; return 0; }
harness_event(){ echo "$*" >> "$EV"; }
release_kick(){ release_run "$@"; }               # a background job in production; synchronous here
release_head(){ cat "$RUN_DIR/head"; }; echo aaaaaaa1 > "$RUN_DIR/head"
CHECKOUT="$RUN_DIR"

# ── a reviewed PRD close in the Harness repo: exactly one release ──
SLUG=acme/harness
close_prd 274; close_prd 274   # dispatch re-emits CLOSE_PRD every poll until the board sees it closed
assert_eq "$(grep -c . "$RLOG")" 1 "a reviewed PRD close triggers exactly one harness release"
assert_ok "for that PRD" grep -qx 'prd:274' "$RLOG"
: > "$RLOG"; SLUG=acme/widget; close_prd 12
assert_eq "$(grep -c . "$RLOG")" 0 "a PRD close in another target repo triggers no release"

# ── bug merges: at most one patch release per hour, covering every fix ──
SLUG=acme/harness; : > "$RLOG"; t0=1800000000
HARNESS_NOW=$t0          release_on_bug_merge 31; HARNESS_NOW=$t0          release_tick
HARNESS_NOW=$((t0+600))  release_on_bug_merge 32; HARNESS_NOW=$((t0+600))  release_tick
HARNESS_NOW=$((t0+900))  release_on_bug_merge 32   # a second reap of the same fix queues nothing new
HARNESS_NOW=$((t0+3000)) release_on_bug_merge 33; HARNESS_NOW=$((t0+3599)) release_tick
assert_eq "$(grep -c . "$RLOG")" 0 "no patch release inside the hour"
HARNESS_NOW=$((t0+3600)) release_tick; HARNESS_NOW=$((t0+3700)) release_tick
assert_eq "$(grep -c . "$RLOG")" 1 "three bug merges within an hour → exactly one patch release"
assert_ok "and it covers all three" grep -qx 'bug:31,32,33' "$RLOG"
: > "$RLOG"; SLUG=acme/widget; HARNESS_NOW=$t0 release_on_bug_merge 5; HARNESS_NOW=$((t0+7200)) release_tick
assert_eq "$(grep -c . "$RLOG")" 0 "a bug fix in another repo never triggers a Harness release"
assert_no "...nor is queued for one" grep -qP '\t5$' "$HARNESS_AUTORELEASE_DIR/pending"

# ── a red gate: one bug issue, no retry loop on the same commit ──
SLUG=acme/harness; : > "$RLOG"; : > "$GH_LOG"; echo bbbbbbb2 > "$RUN_DIR/head"
STUB_RC=4 release_run prd:275
STUB_RC=4 release_run prd:275          # the next poll, same commit
assert_eq "$(grep -c . "$RLOG")" 1 "a red gate is not retried on the same commit"
assert_eq "$(grep -c '^issue create' "$GH_LOG")" 1 "a red gate files one bug issue"
assert_eq "$(grep -c '^issue list' "$GH_LOG")" 1 "the next poll on that commit asks GitHub nothing"
assert_ok "labelled bug" grep -qE '^issue create .*--label bug' "$GH_LOG"
assert_ok "the gate failure is an event" grep -q '^release_gate_failed ' "$EV"
echo ccccccc3 > "$RUN_DIR/head"; STUB_RC=0 release_run prd:275
assert_eq "$(grep -c . "$RLOG")" 2 "a new commit (the fix) is released"
assert_ok "the release is an event" grep -q '^release_published ' "$EV"

# ── a failed close is no close: nothing is released until the close lands ──
SLUG=acme/harness; : > "$RLOG"
gh(){ [[ "$1 $2" == "issue close" ]] && return 1; return 0; }
close_prd 276
assert_eq "$(grep -c . "$RLOG")" 0 "a PRD close that failed triggers no release"
gh(){ return 0; }; close_prd 276
assert_ok "the retried close that lands releases" grep -qx 'prd:276' "$RLOG"

# ── a red gate while a bug for it is already open: no duplicate ──
: > "$GH_LOG"; echo '[{"number":77}]' > "$RUN_DIR/open-bugs"; echo ddddddd4 > "$RUN_DIR/head"
gh(){ echo "$*" >> "$GH_LOG"
  case "$1 $2" in "issue list") cat "$RUN_DIR/open-bugs";; "issue create") echo "https://github.com/acme/harness/issues/100";; esac; return 0; }
STUB_RC=4 release_run prd:277
assert_eq "$(grep -c '^issue create' "$GH_LOG")" 0 "an open bug for the same commit is not filed twice"
assert_eq "$(cat "$HARNESS_AUTORELEASE_DIR/gate-failed-ddddddd4")" 77 "the open bug is recorded for that commit"

# ── a release that errored (rc 3: network, gh) waits out the throttle, then retries ──
: > "$RLOG"; rm -f "$HARNESS_AUTORELEASE_DIR/pending"; echo eeeeeee5 > "$RUN_DIR/head"
HARNESS_NOW=$t0 release_on_bug_merge 34
HARNESS_NOW=$((t0+3600)) STUB_RC=3 release_tick
HARNESS_NOW=$((t0+3700)) release_tick
assert_eq "$(grep -c . "$RLOG")" 1 "an errored release is not retried every poll"
HARNESS_NOW=$((t0+7200)) release_tick
assert_eq "$(grep -c . "$RLOG")" 2 "it is retried once the throttle has passed"
assert_eq "$(grep -c . "$HARNESS_AUTORELEASE_DIR/pending")" 0 "and the released fix leaves the queue"

# ── #326: a PRD close while a release job is running is queued and released after it, not dropped ──
: > "$RLOG"; : > "$REFS"; rm -f "$HARNESS_AUTORELEASE_DIR/pending" "$HARNESS_AUTORELEASE_DIR/retry-after"
echo 1111111a > "$RUN_DIR/head"
# The running job resolves its head, then PRD #279's last child merges and the PRD closes mid-run.
release_head(){ cat "$RUN_DIR/head"; [[ -f "$HARNESS_AUTORELEASE_DIR/prd-279" ]] && return 0
  close_prd 279 >/dev/null 2>&1; echo 2222222b > "$RUN_DIR/head"; }
release_run bug:35
release_head(){ cat "$RUN_DIR/head"; }
assert_eq "$(cat "$RLOG")" "bug:35" "a PRD close while a release runs starts no second job"
assert_ok "the close is queued, not dropped" grep -qP '\tprd:279$' "$HARNESS_AUTORELEASE_DIR/pending"
release_tick
assert_eq "$(tail -1 "$RLOG")" "prd:279" "the next tick releases the PRD after that job finished"
assert_eq "$(tail -1 "$REFS")" 2222222b "on a commit at or after the close"
release_tick; close_prd 279 >/dev/null 2>&1; release_tick
assert_eq "$(grep -c . "$RLOG")" 2 "re-emitted CLOSE_PRD polls for that PRD release nothing more"
assert_eq "$(grep -c . "$HARNESS_AUTORELEASE_DIR/pending")" 0 "and the released PRD leaves the queue"

# ── #326: a PRD-close release that errored (rc 3) is retried after retry-after, no bug queued ──
: > "$RLOG"; echo 3333333c > "$RUN_DIR/head"
HARNESS_NOW=$t0 STUB_RC=3 close_prd 280 >/dev/null 2>&1
HARNESS_NOW=$((t0+600)) release_tick
assert_eq "$(grep -c . "$RLOG")" 1 "an errored PRD release is not retried before retry-after"
HARNESS_NOW=$((t0+3600)) release_tick
assert_eq "$(cat "$RLOG")" "prd:280
prd:280" "it is retried by release_tick once retry-after has passed, with an empty bug queue"
HARNESS_NOW=$((t0+7200)) release_tick; HARNESS_NOW=$((t0+7200)) close_prd 280 >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 2 "once released, neither the tick nor a re-emitted close releases it again"

# ── the triggers are wired where fixes merge and where the lanes poll ──
MERGED="$RUN_DIR/merged"; : > "$MERGED"
release_on_bug_merge(){ echo "$SLUG#$1" >> "$MERGED"; }
# reap_team: a closed impl issue that is a bug fix is queued; a closed feature issue is not.
UNIT=main; SLUG=acme/harness; WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR/main-i41" "$WORKTREES_DIR/main-i42"
echo '{"labels":[{"name":"bug-triaged"}],"state":"CLOSED"}'     > "$RUN_DIR/state-41"
echo '{"labels":[{"name":"ready-for-agent"}],"state":"CLOSED"}' > "$RUN_DIR/state-42"
gh(){ [[ "$1 $2" == "issue view" ]] && cat "$RUN_DIR/state-$3"; return 0; }
session_live(){ return 1; }; remove_worktree(){ rm -rf "$2"; }; stats_sweep_ended(){ :; }
reap_team >/dev/null 2>&1
assert_eq "$(cat "$MERGED")" "acme/harness#41" "reap_team queues a merged bug fix, not a merged feature"
# reap_pool_bugs: a fix-phase goal met is a merge; a triage-phase close is a dismissal.
: > "$MERGED"; LIVE=""
pool_bug_claims(){ printf 'f\tacme/harness#51\nf\tacme/harness#52\n'; }
session_live(){ [[ " $LIVE " == *" $1 "* ]]; }
LIVE="$(sess_bug acme/harness 51 fix) $(sess_bug acme/harness 52 triage)"
watchdog_session(){ :; }; bug_goal_done(){ return 0; }; cli_kill(){ :; }; bug_session_live(){ return 0; }
reap_pool_bugs >/dev/null 2>&1
assert_eq "$(cat "$MERGED")" "acme/harness#51" "reap_pool_bugs queues a fixed bug, not a triaged-closed one"
# drive_bug (the priority lane): the same rule.
source "$HERE/../scripts/priority-worker.sh"
: > "$MERGED"; spawn_bug(){ :; }; is_paused(){ return 1; }; usage_watch(){ :; }; session_live(){ return 0; }
bug_phase(){ echo fix; };    drive_bug acme/harness#61 >/dev/null 2>&1
bug_phase(){ echo triage; }; drive_bug acme/harness#62 >/dev/null 2>&1
assert_eq "$(cat "$MERGED")" "acme/harness#61" "drive_bug queues a fixed bug, not a triaged-closed one"
# the priority lane ticks the Harness repo's queue (it outlives a completed unit), never another's.
TICKED="$RUN_DIR/ticked"; : > "$TICKED"
release_tick(){ echo "$SLUG $CHECKOUT" >> "$TICKED"; }
HARNESS_TOPOLOGY=multi; CHECKOUTS_DIR="$RUN_DIR/co"; _bug_repos(){ printf 'acme/widget\nacme/harness\n'; }
gc_orphan_goals(){ :; }; snapshot_gate(){ return 0; }; gh_rate_wait(){ :; }; reap_lane(){ :; }
retry_pending_unlocks(){ :; }; bug_tick(){ return 0; }
bug_step P1 >/dev/null 2>&1
assert_eq "$(cat "$TICKED")" "acme/harness $RUN_DIR/co/harness" "bug_step ticks the Harness repo's release queue only"
# drive_unit ticks once per poll, with the unit's own repo.
: > "$TICKED"; HARNESS_TOPOLOGY=single; HARNESS_REPO=acme/harness; CAP=1; POLL=0
reap_done_sessions(){ :; }; reap_team(){ :; }; count_team_sessions(){ echo 0; }; team_sessions(){ :; }
reap_pool_bugs(){ :; }; tmux(){ :; }; dispatch_actions(){ :; }; finalize_unit(){ :; }
N=0; unit_complete(){ (( N++ >= 2 )); }
drive_unit main >/dev/null 2>&1
assert_eq "$(cut -d' ' -f1 "$TICKED" | sort -u)" "acme/harness" "drive_unit ticks the release queue with its repo"
assert_eq "$(grep -c . "$TICKED")" 2 "once per poll"

# ── release_kick: one background job at a time, stopped only by its PID ──
source "$HERE/../scripts/autorelease.sh"           # the real release_kick (the top stubbed it)
release_head(){ cat "$RUN_DIR/head"; }; echo fffffff6 > "$RUN_DIR/head"; : > "$RLOG"
sleep 300 & HOLD=$!; echo "$HOLD" > "$HARNESS_AUTORELEASE_DIR/release.pid"
release_kick prd:278
[[ "$(cat "$HARNESS_AUTORELEASE_DIR/release.pid")" == "$HOLD" ]] || wait "$(cat "$HARNESS_AUTORELEASE_DIR/release.pid")"
assert_eq "$(grep -c . "$RLOG")" 0 "a kick while a release job is live starts no second one"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
release_kick prd:278; wait "$(cat "$HARNESS_AUTORELEASE_DIR/release.pid")" 2>/dev/null
assert_ok "a kick runs the release in the background" grep -qx 'prd:278' "$RLOG"
assert_ok "and logs it" grep -q 'released fffffff (prd:278)' "$HARNESS_AUTORELEASE_DIR/release.log"

# ── #329: a failed fetch releases no stale origin head, and the queued PRD close stays queued ──
source "$HERE/../scripts/autorelease.sh"           # the real release_head
release_kick(){ release_run "$@"; }; default_branch(){ echo main; }
gc(){ git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }
O="$RUN_DIR/rh-origin.git"; W="$RUN_DIR/rh-work"; CHECKOUT="$RUN_DIR/rh-checkout"
git init -q --bare -b main "$O"; git clone -q "$O" "$W" 2>/dev/null
gc "$W" commit -q --allow-empty -m a; git -C "$W" push -q origin main 2>/dev/null
git clone -q "$O" "$CHECKOUT" 2>/dev/null
gc "$W" commit -q --allow-empty -m 'the PRD last child'; git -C "$W" push -q origin main 2>/dev/null
FRESH="$(git -C "$W" rev-parse HEAD)"
git -C "$CHECKOUT" remote set-url origin "$RUN_DIR/unreachable.git"
: > "$RLOG"; : > "$REFS"; rm -f "$HARNESS_AUTORELEASE_DIR/pending" "$HARNESS_AUTORELEASE_DIR/retry-after"
SLUG=acme/harness; release_on_prd_close 281 >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 0 "a failed fetch runs no release on the stale origin head"
assert_ok "the PRD close stays queued" grep -qP '\tprd:281$' "$HARNESS_AUTORELEASE_DIR/pending"
git -C "$CHECKOUT" remote set-url origin "$O"
release_tick >/dev/null 2>&1; release_tick >/dev/null 2>&1
assert_eq "$(cat "$RLOG")" "prd:281" "once the fetch succeeds, one release covers it"
assert_eq "$(cat "$REFS")" "$FRESH" "at the fetched head, after the PRD's last merge"
assert_eq "$(grep -c . "$HARNESS_AUTORELEASE_DIR/pending")" 0 "and the released PRD leaves the queue"
finish

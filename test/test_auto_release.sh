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
    "issue list")   cat "$RUN_DIR/open-bugs" 2>/dev/null;;   # TSV: number<TAB>title, what --jq prints (#1056)
    "issue create") printf '99\trelease gate failed at %s\n' bbbbbbb > "$RUN_DIR/open-bugs"; echo "https://github.com/acme/harness/issues/99";;
    "issue view")   [[ -e "$RUN_DIR/gh-down" ]] && return 1; cat "$RUN_DIR/state-$3" 2>/dev/null || echo CLOSED;;  # #1029
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
# #1029: the red gate's entries stay queued, and while its bug is open no new head is gated.
D="$HARNESS_AUTORELEASE_DIR"; rm -f "$D/pending" "$D/retry-after"; printf '%s\tprd:275\n' "$t0" > "$D/pending"
echo 99 > "$RUN_DIR/state-99"; echo OPEN > "$RUN_DIR/state-99"; : > "$GH_LOG"
echo ccccccc3 > "$RUN_DIR/head"; HARNESS_NOW=$t0 release_tick >> "$RUN_DIR/tick.log" 2>&1
assert_eq "$(grep -c . "$RLOG")" 1 "an unrelated merge while the gate bug is open runs no release (prd entry)"
assert_ok "the prd entry stays queued" grep -qP '\tprd:275$' "$D/pending"
assert_ok "the hold is logged" grep -q 'gate bug #99 (red gate at bbbbbbb) still open' "$RUN_DIR/tick.log"
printf '%s\t41\n' "$t0" >> "$D/pending"; sed -i '/prd:275/d' "$D/pending"
HARNESS_NOW=$((t0+7200)) release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 1 "...nor a throttled bug entry past the throttle"
assert_ok "the bug entry stays queued" grep -qP '\t41$' "$D/pending"
printf '%s\tprd:275\n' "$t0" >> "$D/pending"
echo CLOSED > "$RUN_DIR/state-99"; : > "$GH_LOG"
HARNESS_NOW=$((t0+7200)) release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 2 "once the gate bug is closed the next tick releases the current head"
assert_eq "$(tail -1 "$REFS")" ccccccc3 "at the new head"
assert_ok "the release is an event" grep -q '^release_published ' "$EV"
assert_eq "$(grep -c . "$D/pending")" 0 "and clears the queued prd and bug entries it covered"
: > "$GH_LOG"; printf '%s\tprd:275\n' "$t0" > "$D/pending"; echo dddddd0 > "$RUN_DIR/head"
HARNESS_NOW=$((t0+7200)) release_tick >/dev/null 2>&1
assert_eq "$(grep -c '^issue view' "$GH_LOG")" 0 "a marker whose bug is known closed costs no later gh call"
assert_eq "$(grep -c . "$RLOG")" 3 "and does not hold later releases"
echo bbbbbbb2 > "$RUN_DIR/head"; : > "$GH_LOG"
release_run prd:275
assert_eq "$(grep -c . "$RLOG")" 3 "a commit with a gate-failed marker is never re-gated, even once its bug closed"
rm -f "$D/pending"

# #1029: a gh error while checking the gate bug holds the release; an unfiled marker holds it and is re-filed
echo eeeeee9 > "$RUN_DIR/head"; STUB_RC=4 release_run prd:290; echo fffff10 > "$RUN_DIR/head"
n_rl="$(grep -c . "$RLOG")"; printf '%s\tprd:290\n' "$t0" > "$D/pending"; : > "$RUN_DIR/tick.log"
echo OPEN > "$RUN_DIR/state-99"; : > "$RUN_DIR/gh-down"
HARNESS_NOW=$((t0+7200)) release_tick >> "$RUN_DIR/tick.log" 2>&1; rm -f "$RUN_DIR/gh-down"
assert_eq "$(grep -c . "$RLOG")" "$n_rl" "a gh error checking the gate bug holds the release"
assert_ok "prd stays queued" grep -qP '\tprd:290$' "$D/pending"
: > "$D/gate-failed-eeeeee9"; rm -f "$RUN_DIR/open-bugs"; : > "$GH_LOG"; echo CLOSED > "$RUN_DIR/state-99"
echo OPEN > "$RUN_DIR/state-99"
HARNESS_NOW=$((t0+7200)) release_tick >> "$RUN_DIR/tick.log" 2>&1
assert_eq "$(grep -c . "$RLOG")" "$n_rl" "an unfiled marker holds the release"
assert_ok "and the tick retries filing its bug" grep -q '^issue create' "$GH_LOG"
assert_eq "$(cat "$D/gate-failed-eeeeee9")" 99 "recorded for the stranded sha"
echo CLOSED > "$RUN_DIR/state-99"
HARNESS_NOW=$((t0+7200)) release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" "$((n_rl+1))" "and releases once that bug is closed"
rm -f "$D/pending" "$D/retry-after"

# ── a failed close is no close: nothing is released until the close lands ──
SLUG=acme/harness; : > "$RLOG"
gh(){ [[ "$1 $2" == "issue close" ]] && return 1; return 0; }
close_prd 276
assert_eq "$(grep -c . "$RLOG")" 0 "a PRD close that failed triggers no release"
gh(){ return 0; }; close_prd 276
assert_ok "the retried close that lands releases" grep -qx 'prd:276' "$RLOG"

# ── a red gate while a bug for it is already open: no duplicate ──
: > "$GH_LOG"; printf '77\trelease gate failed at ddddddd\n' > "$RUN_DIR/open-bugs"; echo ddddddd4 > "$RUN_DIR/head"
gh(){ echo "$*" >> "$GH_LOG"
  case "$1 $2" in "issue list") cat "$RUN_DIR/open-bugs";; "issue create") echo "https://github.com/acme/harness/issues/100";;
    "issue view") cat "$RUN_DIR/state-$3" 2>/dev/null || echo CLOSED;; esac; return 0; }
STUB_RC=4 release_run prd:277
assert_eq "$(grep -c '^issue create' "$GH_LOG")" 0 "an open bug for the same commit is not filed twice"
assert_eq "$(cat "$HARNESS_AUTORELEASE_DIR/gate-failed-ddddddd4")" 77 "the open bug is recorded for that commit"

# ── #1056: a later head failing the same test files files no new issue, whatever label the bug carries ──
# The bug lane swaps `bug` for `bug-triaged`, and the title holds the short sha, so neither a label
# filter nor a title search finds the open gate bug for a new head. The FAILED: set is the key.
D="$HARNESS_AUTORELEASE_DIR"; gate_log(){ local sha="$1"; shift   # a gate log: a failing suite, then run.sh's FAILED: lines
  printf '== test_x.sh ==\n  FAIL: x\n== run.sh: 1/3 test files passed ==\n' > "$D/gate-$sha.log"
  for f in "$@"; do echo "FAILED: $f"; done >> "$D/gate-$sha.log"; }
gh(){ echo "$*" >> "$GH_LOG"
  case "$1 $2" in
    "issue list") cat "$RUN_DIR/open-bugs" 2>/dev/null;;
    "issue create") echo "https://github.com/acme/harness/issues/101";;
    "issue comment") :;;
    "issue view") case "$*" in *"--json body"*) cat "$RUN_DIR/body-$3" 2>/dev/null;;
                               *"--json comments"*) cat "$RUN_DIR/comments-$3" 2>/dev/null;;
                               *) [[ -e "$RUN_DIR/gh-down" ]] && return 1; cat "$RUN_DIR/state-$3" 2>/dev/null || echo CLOSED;; esac;;
  esac; return 0; }
# #77 is open and triaged (the bug label is gone), filed for an earlier head, listing two failing files
printf '77\trelease gate failed at 1a1a1a1\n' > "$RUN_DIR/open-bugs"
printf '```\nFAILED: test_a.sh\nFAILED: test_b.sh\n```\n' > "$RUN_DIR/body-77"; echo OPEN > "$RUN_DIR/state-77"
LAST=2b2b2b2c; gate_log "$LAST" test_b.sh test_a.sh; echo "$LAST" > "$RUN_DIR/head"; : > "$GH_LOG"
STUB_RC=4 release_run prd:1056
assert_eq "$(grep -c '^issue create' "$GH_LOG")" 0 "gate 2 at a new sha with the same FAILED set files no new issue"
assert_eq "$(cat "$D/gate-failed-$LAST")" 77 "its marker points at the open triaged bug"
assert_ok "the new sha is commented on that bug" grep -qE "^issue comment 77 .*$LAST" "$GH_LOG"
# a different FAILED set is a different defect: filed as its own bug
LAST=3c3c3c3d; gate_log "$LAST" test_a.sh test_z.sh; echo "$LAST" > "$RUN_DIR/head"; : > "$GH_LOG"
STUB_RC=4 release_run prd:1056
assert_eq "$(grep -c '^issue create' "$GH_LOG")" 1 "a gate failing a different file set files its own bug"
assert_eq "$(cat "$D/gate-failed-$LAST")" 101 "recorded for that sha"
# a log with no FAILED: lines has no set to match: only the same commit's title dedupes
LAST=4d4d4d4e; printf 'run.sh blew up\n' > "$D/gate-$LAST.log"; echo "$LAST" > "$RUN_DIR/head"; : > "$GH_LOG"
STUB_RC=4 release_run prd:1056
assert_eq "$(grep -c '^issue create' "$GH_LOG")" 1 "an empty FAILED set is never matched against an open bug"
# GitHub may hand the body back with CRLF line ends: still the same set
printf '77\trelease gate failed at 1a1a1a1\n' > "$RUN_DIR/open-bugs"; printf 'FAILED: test_a.sh\r\nFAILED: test_b.sh\r\n' > "$RUN_DIR/body-77"
LAST=7a7a7a7b; gate_log "$LAST" test_a.sh test_b.sh; echo "$LAST" > "$RUN_DIR/head"; : > "$GH_LOG"
STUB_RC=4 release_run prd:1056
assert_eq "$(grep -c '^issue create' "$GH_LOG")" 0 "a CRLF body lists the same set"
rm -f "$D"/gate-failed-2b2b2b2c "$D"/gate-failed-3c3c3c3d "$D"/gate-failed-4d4d4d4e "$D"/gate-failed-7a7a7a7b "$RUN_DIR/open-bugs"

# ── #1056: a gate bug closed as a duplicate keeps the hold while its canonical is open ──
# #692 closed as a dup of #687 (still open) and the next gate ran, failing the same test (#698).
printf '80\n' > "$D/gate-failed-5e5e5e5f"; rm -f "$D/gate-resolved-5e5e5e5f"
echo CLOSED > "$RUN_DIR/state-80"; printf 'Closing: Duplicate of #77.\n' > "$RUN_DIR/comments-80"; echo OPEN > "$RUN_DIR/state-77"
: > "$RUN_DIR/tick.log"; : > "$GH_LOG"
release_gate_held prd:1056 >> "$RUN_DIR/tick.log" 2>&1; rc=$?
assert_eq "$rc" 0 "a gate bug closed as a duplicate of an open one still holds the release"
assert_eq "$(head -n1 "$D/gate-failed-5e5e5e5f")" 77 "the marker is repointed to the canonical"
assert_no "and the sha is not recorded as resolved" test -e "$D/gate-resolved-5e5e5e5f"
assert_ok "the hold is logged on the canonical" grep -q 'gate bug #77 .*still open' "$RUN_DIR/tick.log"
echo CLOSED > "$RUN_DIR/state-77"; : > "$RUN_DIR/comments-77"
release_gate_held prd:1056; rc=$?
assert_eq "$rc" 1 "once the canonical closes too the hold lifts"
assert_ok "and the sha is resolved" test -e "$D/gate-resolved-5e5e5e5f"
# a gh error reading the closing comments keeps the hold rather than guessing
printf '81\n' > "$D/gate-failed-6f6f6f60"; echo CLOSED > "$RUN_DIR/state-81"
gh(){ case "$*" in *"--json comments"*) return 1;; "issue view"*) cat "$RUN_DIR/state-$3" 2>/dev/null || echo CLOSED;; esac; return 0; }
release_gate_held prd:1056 >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "unreadable closing comments hold the release"
# closed with no canonical named is a plain close: resolved
gh(){ case "$*" in *"--json comments"*) echo "fixed in #123";; "issue view"*) cat "$RUN_DIR/state-$3" 2>/dev/null || echo CLOSED;; esac; return 0; }
release_gate_held prd:1056; rc=$?
assert_eq "$rc" 1 "a gate bug closed without naming a canonical is resolved as before"
rm -f "$D"/gate-failed-5e5e5e5f "$D"/gate-resolved-5e5e5e5f "$D"/gate-failed-6f6f6f60 "$D"/gate-resolved-6f6f6f60 "$RUN_DIR"/{state,body,comments}-{77,80,81}
gh(){ echo "$*" >> "$GH_LOG"
  case "$1 $2" in
    "issue list")   cat "$RUN_DIR/open-bugs" 2>/dev/null;;
    "issue create") printf '99\trelease gate failed at bbbbbbb\n' > "$RUN_DIR/open-bugs"; echo "https://github.com/acme/harness/issues/99";;
    "issue view")   [[ -e "$RUN_DIR/gh-down" ]] && return 1; cat "$RUN_DIR/state-$3" 2>/dev/null || echo CLOSED;;
  esac; return 0; }

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
touch -d "2 minutes ago" "$WORKTREES_DIR/main-i41" "$WORKTREES_DIR/main-i42"   # #643: past the launch grace
echo '{"labels":[{"name":"bug-triaged"}],"state":"CLOSED"}'     > "$RUN_DIR/state-41"
echo '{"labels":[{"name":"ready-for-agent"}],"state":"CLOSED"}' > "$RUN_DIR/state-42"
gh(){ [[ "$1 $2" == "issue view" ]] && cat "$RUN_DIR/state-$3"; return 0; }
session_live(){ return 1; }; remove_worktree(){ rm -rf "$2"; }; stats_sweep_ended(){ :; }
reap_team >/dev/null 2>&1
assert_eq "$(cat "$MERGED")" "acme/harness#41" "reap_team queues a merged bug fix, not a merged feature"
# bug_lane_tend (the pool worker's tend of a pool-taken bug): a fix-phase goal met is a merge; a
# triage-phase close is a dismissal.
: > "$MERGED"; LIVE=""
session_live(){ [[ " $LIVE " == *" $1 "* ]]; }
LIVE="$(sess_bug acme/harness 51 fix) $(sess_bug acme/harness 52 triage)"
watchdog_session(){ :; }; bug_goal_done(){ return 0; }; cli_kill(){ :; }
bug_lane_tend acme/harness 51 >/dev/null 2>&1; bug_lane_tend acme/harness 52 >/dev/null 2>&1
assert_eq "$(cat "$MERGED")" "acme/harness#51" "bug_lane_tend queues a fixed bug, not a triaged-closed one"
# drive_bug (the priority lane): the same rule.
source "$HERE/../scripts/priority-worker.sh"
: > "$MERGED"; spawn_bug(){ :; }; is_paused(){ return 1; }; usage_watch(){ :; }; session_live(){ return 0; }
bug_phase(){ echo fix; };    drive_bug acme/harness#61 >/dev/null 2>&1
bug_phase(){ echo triage; }; drive_bug acme/harness#62 >/dev/null 2>&1
assert_eq "$(cat "$MERGED")" "acme/harness#61" "drive_bug queues a fixed bug, not a triaged-closed one"
# the priority lane ticks the Harness repo's queue (it outlives a completed unit), never another's.
TICKED="$RUN_DIR/ticked"; : > "$TICKED"
release_tick(){ echo "$SLUG $CHECKOUT" >> "$TICKED"; }
_bug_repos(){ printf 'acme/widget\nacme/harness\n'; }
gc_orphan_goals(){ :; }; snapshot_gate(){ return 0; }; gh_rate_wait(){ :; }; reap_lane(){ :; }
retry_pending_unlocks(){ :; }; bug_tick(){ return 0; }
bug_step P1 >/dev/null 2>&1
assert_eq "$(cat "$TICKED")" "acme/harness $(fleet_checkout)" "bug_step ticks the Harness repo's release queue only"
# the pool worker's chores tick once per pass, with the fleet's own repo.
: > "$TICKED"; HARNESS_REPO=acme/harness; POOL=1; POLL=0
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1; source "$HERE/../scripts/pool-worker.sh"
reap_done_sessions(){ :; }; reap_team(){ :; }; reap_orch(){ :; }; watchdog_team(){ :; }; reap_finished_inject(){ :; }
one_auto_tend(){ :; }; reap_ownerless_pool_bugs(){ :; }; sweep_orphan_locks(){ :; }; sweep_stale_lane_claims(){ :; }
adopt_lanes(){ :; }; chores_slotless(){ :; }; usage_held(){ return 1; }; tmux(){ :; }
worker_chores W1 >/dev/null 2>&1; worker_chores W1 >/dev/null 2>&1
assert_eq "$(cut -d' ' -f1 "$TICKED" | sort -u)" "acme/harness" "worker_chores ticks the release queue with its repo"
assert_eq "$(grep -c . "$TICKED")" 2 "once per pass"

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
# ── #1068: an engine roll kills release_run mid-gate; release.sh survives and the NEXT tick records its result ──
# The stub blocks until $GO exists, then exits $STUB_RC. release_run runs in a background subshell that is SIGKILLed once
# the stub started — what the roll did to the worker's job — and the gate then finishes with nobody left to act on its rc.
release_head(){ cat "$RUN_DIR/head"; }
gh(){ echo "$*" >> "$GH_LOG"
  case "$1 $2" in
    "issue list")   cat "$RUN_DIR/open-bugs" 2>/dev/null;;
    "issue create") printf '99\trelease gate failed at x\n' > "$RUN_DIR/open-bugs"; echo "https://github.com/acme/harness/issues/99";;
    "issue view")   cat "$RUN_DIR/state-$3" 2>/dev/null || echo OPEN;;
  esac; return 0; }
orphan_run(){ local rc="$1" head="$2" reason="$3" i rp
  GO="$RUN_DIR/go-$head"; STARTED="$RUN_DIR/started-$head"; rm -f "$GO" "$STARTED"; echo "$head" > "$RUN_DIR/head"
  printf '#!/usr/bin/env bash\n: > %q\nuntil [[ -e %q ]]; do sleep 0.1; done\nexit %q\n' "$STARTED" "$GO" "$rc" > "$RUN_DIR/release-blocking"
  chmod +x "$RUN_DIR/release-blocking"
  ( HARNESS_RELEASE_CMD="$RUN_DIR/release-blocking" release_run "$reason" >/dev/null 2>&1 ) & rp=$!
  for i in $(seq 1 100); do [[ -e "$STARTED" ]] && break; sleep 0.1; done
  kill -9 "$rp" 2>/dev/null; wait "$rp" 2>/dev/null; : > "$GO"
  for i in $(seq 1 100); do [[ -f "$HARNESS_AUTORELEASE_DIR/result-$head" ]] && break; sleep 0.1; done; }
SLUG=acme/harness; D="$HARNESS_AUTORELEASE_DIR"; TICK="$RUN_DIR/tick.out"
rm -f "$D"/pending "$D"/retry-after "$D"/gate-* "$D"/result-* "$D"/inflight-*; : > "$RLOG"; : > "$GH_LOG"; : > "$EV"; rm -f "$RUN_DIR/open-bugs"
t1=1800100000
printf '%s\t77\n%s\tprd:78\n' "$t1" "$t1" > "$D/pending"
orphan_run 0 c0ffee01 prd:78
assert_eq "$(cat "$D/result-c0ffee01" 2>/dev/null)" 0 "the orphaned job's rc survives its release_run in result-<sha>"
assert_eq "$(grep -c . "$D/pending")" 2 "nothing recorded it yet: the covered entries are still queued"
printf '%s\t79\n' "$t1" >> "$D/pending"          # queued after release_run resolved the head: not covered
HARNESS_NOW=$((t1+10)) release_tick > "$TICK" 2>&1
assert_eq "$(cat "$D/pending")" "$(printf '%s\t79' "$t1")" "rc 0: the next tick clears what the release covered, and only that"
assert_ok "and logs the release" grep -q 'auto-release: released c0ffee0 (prd:78)' "$TICK"
assert_ok "and the release is an event" grep -q '^release_published reason=prd:78 sha=c0ffee01' "$EV"
assert_no "the result is consumed" test -e "$D/result-c0ffee01"
assert_no "and so is the in-flight record" test -e "$D/inflight-c0ffee01"
HARNESS_NOW=$((t1+20)) release_tick > "$TICK" 2>&1
assert_eq "$(grep -c '^release_published' "$EV")" 1 "a second tick records nothing twice"

: > "$GH_LOG"; : > "$EV"; : > "$RLOG"; printf '%s\tprd:80\n' "$t1" > "$D/pending"
orphan_run 4 c0ffee04 prd:80
assert_no "no marker before a tick runs" test -e "$D/gate-failed-c0ffee04"
HARNESS_NOW=$((t1+30)) release_tick > "$TICK" 2>&1
assert_ok "rc 4: the next tick writes the gate-failed marker" test -e "$D/gate-failed-c0ffee04"
assert_eq "$(grep -c '^issue create' "$GH_LOG")" 1 "and files the bug"
assert_eq "$(head -n1 "$D/gate-failed-c0ffee04")" 99 "which the marker records, so the hold (#1029) engages"
assert_ok "the red gate is an event" grep -q '^release_gate_failed reason=prd:80 sha=c0ffee04 issue=99' "$EV"
assert_eq "$(grep -c . "$D/pending")" 1 "the entry stays queued behind the hold"
assert_eq "$(grep -c . "$RLOG")" 0 "and nothing was released"

: > "$GH_LOG"; : > "$EV"; rm -f "$D"/gate-*; printf '%s\tprd:81\n' "$t1" > "$D/pending"
HARNESS_NOW=$t1 orphan_run 1 c0ffee05 prd:81
HARNESS_NOW=$((t1+40)) release_tick > "$TICK" 2>&1
assert_eq "$(cat "$D/retry-after")" $((t1+3600)) "other rc: the next tick sets retry-after from the job's start"
assert_eq "$(grep -c . "$D/pending")" 1 "and the entry stays queued"
assert_no "no gate-failed marker for it" test -e "$D/gate-failed-c0ffee05"
finish

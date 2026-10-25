#!/usr/bin/env bash
# test_stats.sh — #185: the host-wide event log, from the bash side. launch_agent records the session
# context and a `launch` event; once the tmux session is gone stats_sweep_ended writes its
# `session_end` with the token usage of the recorded transcript fixture (main + subagents); the
# reapers, the watchdog and the claim path emit their lifecycle events; and a broken event log never
# fails or blocks the caller — the write error is swallowed and logged ONCE. (The report and roll-up
# logic is unit-tested in test_stats.py.)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/helpers.sh"
make_env
EVENTS="$HARNESS_HOME/events.jsonl"
FIXTURE_SID=11111111-2222-3333-4444-555555555555
export HARNESS_CLAUDE_CONFIG_DIRS="$HERE/fixtures/stats/claude"
# jq-free field read: ev <n-th line, 1-based> <python expression over e>
ev(){ python3 -c 'import json,sys; e=[json.loads(l) for l in open(sys.argv[1])][int(sys.argv[2])-1]; print(eval(sys.argv[3]))' "$EVENTS" "$1" "$2"; }
nev(){ [[ -f "$EVENTS" ]] && wc -l < "$EVENTS" | tr -d ' ' || echo 0; }

echo "=== launch → session_end on the recorded transcript fixture ==="
LIVE="$RUN_DIR/live"; : > "$LIVE"
tmux(){ case "$1" in has-session) grep -qxF "$3" "$LIVE";; new-session) echo "$4" >> "$LIVE";; *) return 0;; esac; }
sleep(){ :; }
uuidgen(){ echo "$FIXTURE_SID"; }
WT="$RUN_DIR/wt-main-i7"; mkdir -p "$WT/.claude"; echo task > "$WT/.harness-task.md"
printf '{"model": "sonnet"}\n' > "$WT/.claude/settings.local.json"   # what a worktree hook routes
UNIT=main SLUG=acme/widget GOAL="ISSUE:7" STAT_PRD=5 CLAUDE_FLAGS="--dangerously-skip-permissions --effort high" \
  launch_agent hz-main-i7 "$WT" >/dev/null
assert_ok "launch records the session context" test -f "$RUN_DIR/hz-main-i7.stats"
assert_eq "$(nev)" 1 "one launch event"
assert_eq "$(ev 1 "e['event'],e['session'],e['kind'],e['issue'],e['prd'],e['repo'],e['unit']")" \
  "('launch', '$FIXTURE_SID', 'impl', 7, 5, 'acme/widget', 'main')" "launch carries session/kind/issue/prd/repo/unit"
assert_eq "$(ev 1 "e['model'],e['effort'],e['ralph_iter'],e['prefix']")" "('sonnet', 'high', 1, 'hz')" \
  "launch model from the worktree hook, effort from the flags"
stats_sweep_ended
assert_eq "$(nev)" 1 "a LIVE session gets no session_end"
: > "$LIVE"   # the session exits
UNIT=worker-1 stats_sweep_ended
assert_eq "$(nev)" 2 "session_end written once the session is gone"
assert_eq "$(ev 2 "e['event'],e['issue'],e['unit']")" "('session_end', 7, 'main')" "session_end keeps the session's own attribution"
assert_eq "$(ev 2 "sorted((m,u['input'],u['output'],u['cache_create'],u['cache_read']) for m,u in e['usage'].items())")" \
  "[('claude-opus-5-5', 15, 150, 1000, 30000), ('claude-sonnet-5-5', 3, 10, 300, 1000)]" \
  "session_end usage = main transcript + subagents, each streamed message counted once"
assert_no "the context file is consumed" test -e "$RUN_DIR/hz-main-i7.stats"
stats_sweep_ended
assert_eq "$(nev)" 2 "a second sweep never re-emits"

echo "=== #186: every lane session gets the rtdd event env, for claude AND agy ==="
NEWSESS="$RUN_DIR/new-session.args"
tmux(){ case "$1" in has-session) return 1;; new-session) printf '%s\n' "$@" > "$NEWSESS";; *) return 0;; esac; }
for cli in claude agy; do
  : > "$EVENTS"
  HARNESS_CLI=$cli UNIT=main SLUG=acme/widget GOAL="ISSUE:7" STAT_PRD=5 launch_agent "hz-$cli-i7" "$WT" >/dev/null
  for kv in "RTDD_EVENT_LOG=$HARNESS_HOME/rtdd-events.jsonl" "HARNESS_SESSION=$FIXTURE_SID" HARNESS_PREFIX=hz \
            HARNESS_REPO=acme/widget HARNESS_KIND=impl HARNESS_ISSUE=7 HARNESS_PRD=5; do
    assert_ok "$cli: tmux new-session sets -e $kv" grep -qxF -- "$kv" "$NEWSESS"
  done
  assert_eq "$(grep -cx -- -e "$NEWSESS")" 7 "$cli: exactly the rtdd env, nothing else"
  assert_eq "$(ev 1 "e['session']")" "$FIXTURE_SID" "$cli: the launch event's session is the HARNESS_SESSION rtdd joins on"
  rm -f "$RUN_DIR/hz-$cli-i7.stats"
done
GOAL="REVIEW:5" STAT_PRD="" HARNESS_RTDD_EVENTS_FILE="$RUN_DIR/r.jsonl" session_env u-1
assert_eq "${SESSION_ENV[*]}" "-e RTDD_EVENT_LOG=$RUN_DIR/r.jsonl -e HARNESS_SESSION=u-1 -e HARNESS_PREFIX=hz -e HARNESS_KIND=review -e HARNESS_PRD=5" \
  "session_env: a review session has no issue, its PRD from the GOAL; the log path honours its override"
tmux(){ case "$1" in has-session) grep -qxF "$3" "$LIVE";; new-session) echo "$4" >> "$LIVE";; *) return 0;; esac; }

echo "=== #186: start.sh records a missing rtdd as an rtdd_missing event ==="
FAKE_BIN="$RUN_DIR/fakebin"; mkdir -p "$FAKE_BIN"
for b in tmux claude gh; do printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/$b"; chmod +x "$FAKE_BIN/$b"; done
SYS_PATH=/usr/bin:/bin
if PATH=$SYS_PATH command -v rtdd >/dev/null; then   # rtdd installed system-wide: mirror the system bins minus it
  SYS_PATH="$RUN_DIR/sysbin"; mkdir -p "$SYS_PATH"
  for f in /bin/* /usr/bin/*; do [[ "${f##*/}" == rtdd ]] || ln -sf "$f" "$SYS_PATH/" 2>/dev/null; done
fi
mkdir -p "$STATE_DIR/run"; : > "$EVENTS"
# a held start.lock makes start.sh exit 0 right after its prerequisite checks: nothing is launched
flock "$STATE_DIR/run/start.lock" sleep 30 & HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$STATE_DIR/run/start.lock" true || break; command sleep 0.1; done
out="$(PATH="$FAKE_BIN:$SYS_PATH" bash "$HERE/../scripts/start.sh" 2>&1)"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
assert_ok "start.sh still only warns" grep -q 'rtdd not found' <<<"$out"
assert_eq "$(ev 1 "e['event'],e['prefix']")" "('rtdd_missing', 'hz')" "start.sh emits rtdd_missing"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/rtdd"; chmod +x "$FAKE_BIN/rtdd"; : > "$EVENTS"
flock "$STATE_DIR/run/start.lock" sleep 30 & HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$STATE_DIR/run/start.lock" true || break; command sleep 0.1; done
PATH="$FAKE_BIN:$SYS_PATH" bash "$HERE/../scripts/start.sh" >/dev/null 2>&1
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
assert_eq "$(nev)" 0 "rtdd on PATH: no rtdd_missing event"

echo "=== watchdog / reaper / claim events ==="
: > "$EVENTS"
printf '{"session":"s-9","issue":9,"kind":"impl","repo":"acme/widget"}' > "$RUN_DIR/hz-main-i9.stats"
echo hz-main-i9 >> "$LIVE"
capture=""
tmux(){ case "$1" in has-session) grep -qxF "$3" "$LIVE";; capture-pane) printf '%s' "$capture";; *) return 0;; esac; }
capture=$'API Error: 529 Overloaded\n❯ '
HARNESS_STALL_RETRIES=2 watchdog_session hz-main-i9 >/dev/null
HARNESS_STALL_RETRIES=2 watchdog_session hz-main-i9 >/dev/null
assert_eq "$(ev 1 "e['event'],e['reason'],e['session'],e['issue']")" "('nudge', 'transient_api_error', 's-9', 9)" "nudge event"
assert_eq "$(ev 2 "e['event'],e['session']")" "('watchdog_kill', 's-9')" "watchdog_kill event"
: > "$EVENTS"; rm -f "$RUN_DIR/hz-main-i9.limit"
capture=$'You\'ve hit your session limit · resets 3pm (UTC)\n❯ '
watchdog_session hz-main-i9 >/dev/null
assert_eq "$(ev 1 "e['event'],e['reset']")" "('rate_limited', '3pm (UTC)')" "rate_limited event names the reset"
assert_eq "$(ev 2 "e['event'],e['reason']")" "('nudge', 'rate_limit')" "the limit nudge is a nudge event too"
: > "$EVENTS"
capture=$'1. Stop and wait for limit to reset\n2. Add funds'
watchdog_session hz-main-i9 >/dev/null
assert_eq "$(ev 1 "e['event']")" "rate_limited" "the limit menu is a rate_limited event"
assert_eq "$(limit_reset 'no reset named')" "" "limit_reset: empty when the pane names none"

: > "$EVENTS"
write_targets <<<$'u1\tacme/widget\t-\tw'
claim_out="$(claim_next W1)"
assert_eq "$claim_out" "u1" "claim_next still returns only the unit on stdout"
release_claim u1
assert_eq "$(ev 1 "e['event'],e['unit'],e['worker']")" "('claim', 'u1', 'W1')" "claim event"
assert_eq "$(ev 2 "e['event'],e['unit']")" "('release', 'u1')" "release event"

: > "$EVENTS"
UNIT=main; SLUG=acme/widget; REPO=acme/widget; CHECKOUT="$RUN_DIR/co"
mkdir -p "$WORKTREES_DIR/main-i12"
remove_worktree(){ :; }
gh(){ case "$1 $2" in "issue view") echo '{"state":"CLOSED","labels":[]}';; "issue close") return 0;; *) return 0;; esac; }
git(){ :; }
reap_team >/dev/null
assert_eq "$(ev 1 "e['event'],e['kind'],e['issue'],e['repo']")" "('reap', 'impl', 12, 'acme/widget')" "reap event"
assert_eq "$(ev 2 "e['event'],e['issue']")" "('merged', 12)" "a closed issue's reap is a merged event"
: > "$EVENTS"
close_prd 5 >/dev/null
assert_eq "$(ev 1 "e['event'],e['prd']")" "('prd_closed', 5)" "prd_closed event"
: > "$EVENTS"
echo hz-main-i12 >> "$LIVE"; echo "ISSUE:12" > "$RUN_DIR/hz-main-i12.goal"
printf '{"session":"s-12","issue":12}' > "$RUN_DIR/hz-main-i12.stats"
python3(){ if [[ "$1" == "$ISSUELIB" ]]; then echo DONE; else command python3 "$@"; fi; }
team_sessions(){ echo hz-main-i12; }
reap_done_sessions >/dev/null
unset -f python3 team_sessions
assert_eq "$(ev 1 "e['event'],e['session']")" "('goal_satisfied', 's-12')" "goal_satisfied event"
assert_eq "$(hold_reason 'gh: API rate limit exceeded (HTTP 403)')" rate_limit "hold_reason: rate limit"
assert_eq "$(hold_reason 'dial tcp: i/o timeout')" network "hold_reason: network"
assert_eq "$(hold_reason 'boom')" other "hold_reason: other"
unset -f gh git remove_worktree

: > "$EVENTS"
SAN="acme_widget"; mkdir -p "$WORKTREES_DIR/orch-$SAN-p5"
remove_worktree(){ :; }
reap_orch >/dev/null
assert_eq "$(ev 1 "e['event'],e['kind'],e['prd']")" "('reap', 'orch', 5)" "reap_orch emits a reap event"
unset -f remove_worktree

echo "=== doctor --fix: clearing an orphaned start.lock is an unlock event ==="
_DOCTOR_SOURCED=1 source "$HERE/../scripts/doctor.sh"
: > "$EVENTS"; : > "$RUN_DIR/start.lock"; rm -f "$RUN_DIR/pool.lock"
lock_free(){ return 1; }
lock_holders(){ printf '4242\tsleep 300\n'; }
proc_state_dir(){ :; }
tracked_worker_pid(){ return 1; }
kill(){ [[ "$1" == 4242 ]]; }
DOCTOR_FIX=1 doctor_locks >/dev/null
assert_eq "$(ev 1 "e['event'],e['lock'],e['pid']")" "('unlock', 'start.lock', 4242)" "unlock event names the lock + pid"
kill(){ return 1; }
: > "$EVENTS"
DOCTOR_FIX=1 doctor_locks >/dev/null
assert_eq "$(nev)" 0 "a failed kill clears nothing, so no unlock event"
unset -f kill lock_free lock_holders proc_state_dir tracked_worker_pid

echo "=== spawn_impl attributes the session to its ## Parent PRD ==="
gh(){ [[ "$*" == *"--json body"* ]] && printf 'Work.\n\n## Parent\n#41\n'; return 0; }
assert_eq "$(issue_parent_prd 23)" 41 "issue_parent_prd reads ## Parent"
gh(){ return 1; }
assert_eq "$(issue_parent_prd 23)" "" "issue_parent_prd: empty when gh fails"
unset -f gh

echo "=== a broken event log never fails or blocks the caller ==="
: > "$HARNESS_HOME/blocker"
ERR="$RUN_DIR/err"
( HARNESS_HOME="$HARNESS_HOME/blocker"   # a FILE: events.jsonl beneath it cannot be created
  harness_event claim unit=x; r1=$?
  harness_event release unit=x; r2=$?
  echo "$r1$r2" > "$RUN_DIR/rcs" ) 2>"$ERR" >/dev/null
assert_eq "$(cat "$RUN_DIR/rcs")" "00" "harness_event returns 0 on a write failure"
assert_eq "$(grep -c 'event log write failed' "$ERR")" 1 "the failure is logged exactly once"

echo "=== harness stats CLI ==="
out="$(HARNESS_HOME="$HARNESS_HOME" bash "$HERE/../bin/harness" stats --since 2000-01-01 --json)"
assert_ok "harness stats --json parses" python3 -c 'import json,sys; json.loads(sys.argv[1])' "$out"
assert_ok "harness help lists stats" grep -q '^  stats ' <(bash "$HERE/../bin/harness" help)
finish

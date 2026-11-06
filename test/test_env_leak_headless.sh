#!/usr/bin/env bash
# test_env_leak_headless.sh — #493 / PRD #475 task 6: the headless twin of test_tmux_env_leak.sh (#547).
# On tmux the spawn that CREATES the server must not leak its fleet's env (STATE_DIR / HARNESS_* /
# RTDD_EVENT_LOG) into the server's global env, so a LATER session of another fleet never sees them, while the
# lane still gets its own via -e pairs. The headless equivalent, on HARNESS_SESSION_BACKEND=headless (a lane is
# a detached runner process driving the fake claude of test/fixtures/cli/claude/stream-json/, no tmux): a lane
# launched from fleet A's env carries A's values and its own -e pairs; a lane launched later from fleet B's env
# (A's vars unset) must carry NONE of A's values — in its runner's environ (read from /proc where there is one)
# or in its CLI turn's environment (which the fake's turn-hook records, so this works without /proc, on
# Git Bash) — and B's own pairs must be there. No tmux anywhere. Only pids this test started are signalled.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
unset HARNESS_SESSION
export RUN_DIR HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
export HARNESS_CLAUDE_BIN="python3 $FAKE" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
export HARNESS_STALL_RETRIES=3 HARNESS_LIMIT_NUDGE_EVERY=1 HARNESS_INTERRUPT_WAIT=10 HARNESS_HEADLESS_STOP_WAIT=10
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"
LOG="$RUN_DIR/harness.log"; log(){ printf '%s\n' "$*" >> "$LOG"; }

# Only the processes this test started: each lane's runner (its pid file) and each fake claude (calls.jsonl).
our_pids(){ local d; shopt -s nullglob
  for d in "$HARNESS_HOME"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$RUN_DIR"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
  done; shopt -u nullglob; }
cleanup(){ local p; for p in $(our_pids); do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
lane_state(){ python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$(headless_lane_dir "$1")" --field "$2" 2>/dev/null; }
turn_ended(){ [[ "$(lane_state "$1" turn)" == "$2" && "$(lane_state "$1" state)" == idle ]]; }
# lane <name> — a worktree and a fake-claude dir whose turn-hook records the environment its turn runs in.
lane(){ local name="$1"
  WD="$RUN_DIR/wd-$name"; mkdir -p "$WD"; echo "the task" > "$WD/.harness-task.md"
  export FAKE_CLAUDE_DIR="$RUN_DIR/fake-$name"; mkdir -p "$FAKE_CLAUDE_DIR"
  echo normal > "$FAKE_CLAUDE_DIR/plan"
  cat > "$FAKE_CLAUDE_DIR/turn-hook" <<EOF
#!/usr/bin/env bash
env | sort > "$FAKE_CLAUDE_DIR/turn.env.tmp" && mv "$FAKE_CLAUDE_DIR/turn.env.tmp" "$FAKE_CLAUDE_DIR/turn.env"
EOF
  chmod +x "$FAKE_CLAUDE_DIR/turn-hook"; }
# have_proc — the host has a /proc to read a runner's environ from (Linux, MSYS for its own processes).
have_proc(){ [[ -r /proc/self/environ ]]; }
# runner_env <sess> — the runner process's exec-time environment, one NAME=value per line (empty without /proc).
runner_env(){ local pid; pid="$(sess_pane_pid "$1")"; [[ -n $pid ]] && have_proc && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null; return 0; }
# turn_env <name> — the environment the lane's CLI turn ran in, as the fake recorded it.
turn_env(){ cat "$RUN_DIR/fake-$1/turn.env" 2>/dev/null; }
env_has(){ grep -qxF -- "$2" <<<"$1"; }          # env_has <dump> <NAME=value>
env_key(){ grep -c -- "^$2=" <<<"$1"; }          # env_key <dump> <NAME> — how many NAME= lines
# env_leak <dump> — every line of <dump> holding a value only fleet A set.
assert_ne(){ [[ "$1" != "$2" ]]; }
env_leak(){ grep -E 'fleetA|fleeta|acme/a([^a-z]|$)' <<<"$1"; return 0; }

LEAK_KEYS=(STATE_DIR HARNESS_REPO HARNESS_CHECKOUT HARNESS_GUARD_BASE HARNESS_SNAPSHOT_FILE)
A_STATE=/fake/fleetA/.harness; A_RTDD=/fake/fleetA/rtdd-events.jsonl
cd "$RUN_DIR" || exit 1

echo "== fleet A's lane carries A's env and its own -e pairs =="
lane ia
SA=fleeta-main-i1
(
  export STATE_DIR="$A_STATE" HARNESS_REPO=acme/a HARNESS_SESS_PREFIX=fleeta SLUG=acme/a HARNESS_RTDD_EVENTS_FILE="$A_RTDD"
  export HARNESS_CHECKOUT=/fake/fleetA/co HARNESS_GUARD_BASE=/fake/fleetA/base HARNESS_SNAPSHOT_FILE=/fake/fleetA/snap
  GOAL=ISSUE:1 MAXITER=10 PROMISE="ISSUE 1 DONE" launch_agent "$SA" "$WD" >/dev/null 2>&1
); rc=$?
assert_eq "$rc" 0 "launch_agent starts fleet A's lane"
assert_ok "the lane is live" sess_live "$SA"
assert_ok "its turn runs" wait_until 20 turn_ended "$SA" 1
UA="$(cat "$(headless_lane_dir "$SA")/session")"
EA="$(turn_env ia)"; RA="$(runner_env "$SA")"
assert_ok "the turn recorded its environment" test -n "$EA"
assert_ok "the turn has its own HARNESS_SESSION (-e)" env_has "$EA" "HARNESS_SESSION=$UA"
assert_ok "…its HARNESS_PREFIX (-e)" env_has "$EA" "HARNESS_PREFIX=fleeta"
assert_ok "…its HARNESS_REPO (-e)" env_has "$EA" "HARNESS_REPO=acme/a"
assert_ok "…its RTDD_EVENT_LOG (-e)" env_has "$EA" "RTDD_EVENT_LOG=$A_RTDD"
assert_ok "…and the STATE_DIR of the client that started it" env_has "$EA" "STATE_DIR=$A_STATE"
if have_proc; then
  assert_ok "the runner's environ has HARNESS_SESSION" env_has "$RA" "HARNESS_SESSION=$UA"
  assert_ok "…its RTDD_EVENT_LOG" env_has "$RA" "RTDD_EVENT_LOG=$A_RTDD"
  assert_ok "…its STATE_DIR" env_has "$RA" "STATE_DIR=$A_STATE"
else echo "  n/a: no /proc: the runner's environ is not read (the turn's recorded environment stands in)"; fi

echo "== a lane launched later from fleet B's env, while A's runner is still up, sees none of A's =="
lane ib
SB=fleetb-main-i2
(
  # A different client: A's variables are not in it (the analogue of `env -u … tmux new-session`).
  unset "${LEAK_KEYS[@]}"
  export HARNESS_SESS_PREFIX=fleetb SLUG=acme/b HARNESS_RTDD_EVENTS_FILE="$RUN_DIR/fleetB-rtdd-events.jsonl"
  GOAL=ISSUE:2 MAXITER=10 PROMISE="ISSUE 2 DONE" launch_agent "$SB" "$WD" >/dev/null 2>&1
); rc=$?
assert_eq "$rc" 0 "launch_agent starts fleet B's lane"
assert_ok "fixture: fleet A's lane is still live" sess_live "$SA"
assert_ok "fleet B's lane is live" sess_live "$SB"
assert_ok "its turn runs" wait_until 20 turn_ended "$SB" 1
UB="$(cat "$(headless_lane_dir "$SB")/session")"
EB="$(turn_env ib)"; RB="$(runner_env "$SB")"
assert_ok "the turn recorded its environment" test -n "$EB"
assert_ok "the two lanes have different sessions" assert_ne "$UA" "$UB"
assert_eq "$(env_leak "$EB")" "" "the turn's environment holds no value of fleet A's"
for k in "${LEAK_KEYS[@]}"; do
  [[ $k == HARNESS_REPO ]] && continue   # B has its own (below)
  assert_eq "$(env_key "$EB" "$k")" 0 "…and no $k at all"
done
assert_ok "…its own HARNESS_SESSION is there" env_has "$EB" "HARNESS_SESSION=$UB"
assert_ok "…its own HARNESS_PREFIX" env_has "$EB" "HARNESS_PREFIX=fleetb"
assert_ok "…its own HARNESS_REPO, not A's" env_has "$EB" "HARNESS_REPO=acme/b"
assert_ok "…its own RTDD_EVENT_LOG, not A's" env_has "$EB" "RTDD_EVENT_LOG=$RUN_DIR/fleetB-rtdd-events.jsonl"
if have_proc; then
  assert_eq "$(env_leak "$RB")" "" "the runner's environ holds no value of fleet A's"
  assert_eq "$(env_key "$RB" STATE_DIR)" 0 "…no STATE_DIR"
  assert_eq "$(env_key "$RB" HARNESS_CHECKOUT)" 0 "…no HARNESS_CHECKOUT"
  assert_ok "…its own HARNESS_SESSION" env_has "$RB" "HARNESS_SESSION=$UB"
  assert_ok "…its own HARNESS_REPO" env_has "$RB" "HARNESS_REPO=acme/b"
fi

echo "== fleet A's lane is untouched by B's launch =="
EA2="$(turn_env ia)"
assert_eq "$EA2" "$EA" "A's recorded turn environment is unchanged"
if have_proc; then assert_eq "$(runner_env "$SA")" "$RA" "A's runner environ is unchanged"; fi
assert_eq "$(env_leak "$(turn_env ib)")" "" "…and B's still holds nothing of A's"

echo "== a third lane, from a client with no fleet vars at all, sees none of A's or B's =="
lane ic
SC=fleetc-main-i3
(
  unset "${LEAK_KEYS[@]}"
  export HARNESS_SESS_PREFIX=fleetc SLUG="" HARNESS_RTDD_EVENTS_FILE="$RUN_DIR/fleetC-rtdd-events.jsonl"
  GOAL=ISSUE:3 MAXITER=10 PROMISE="ISSUE 3 DONE" launch_agent "$SC" "$WD" >/dev/null 2>&1
); rc=$?
assert_eq "$rc" 0 "launch_agent starts the third lane"
assert_ok "its turn runs" wait_until 20 turn_ended "$SC" 1
EC="$(turn_env ic)"
assert_ok "the turn recorded its environment" test -n "$EC"
assert_eq "$(env_leak "$EC")" "" "its environment holds no value of fleet A's"
assert_eq "$(env_key "$EC" HARNESS_REPO)" 0 "…and no HARNESS_REPO (no repo was set for it)"
assert_eq "$(env_key "$EC" STATE_DIR)" 0 "…and no STATE_DIR"
assert_eq "$(grep -c 'fleetB\|fleetb\|acme/b' <<<"$EC")" 0 "…and nothing of fleet B's"

echo "== launching a lane leaves the caller's scope alone (#558) =="
# A temporary (`VAR=x f`) or `local` value must not come back as an exported global.
lane id
R="$RUN_DIR/scope.out"
(
  export HARNESS_SESS_PREFIX=fleetd HARNESS_SCOPE_PROBE=global STATE_DIR=/global/state
  f(){ GOAL=ISSUE:4 PROMISE="ISSUE 4 DONE" MAXITER=10 launch_agent fleetd-main-i4 "$WD" >/dev/null 2>&1; }
  HARNESS_SCOPE_PROBE=temp f; echo "launch=$?"
  echo "temp=$HARNESS_SCOPE_PROBE"
  echo "child=$(bash -c 'echo "$HARNESS_SCOPE_PROBE"')"
  g(){ local STATE_DIR=/local/state; launch_agent fleetd-main-i5 "$WD" >/dev/null 2>&1; }
  lane ie; g; echo "local=$STATE_DIR"
) > "$R" 2>/dev/null
assert_eq "$(grep '^launch=' "$R")" "launch=0" "the launch under a temporary value succeeds"
assert_eq "$(grep '^temp=' "$R")" "temp=global" "a temporary HARNESS_SCOPE_PROBE=temp does not outlive the call"
assert_eq "$(grep '^child=' "$R")" "child=global" "…and a child process sees the earlier value"
assert_eq "$(grep '^local=' "$R")" "local=/global/state" "a caller's local STATE_DIR does not change the global one"

finish

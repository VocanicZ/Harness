#!/usr/bin/env bash
# test_cache_ttl.sh — #615 (PRD #587): claude lanes write their prompt cache with the 5-minute TTL (1.25x the
# input price; Claude Code's default 1h TTL is 2x): FORCE_PROMPT_CACHING_5M=1 reaches the lane's environment on
# both session backends. HARNESS_CACHE_TTL=5m|1h picks it (default 5m; 1h leaves the CLI's default); a CLI
# other than claude gets nothing. The bench side (the writes by TTL, the turn gaps) is test_bench_run.py's.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
unset HARNESS_CACHE_TTL FORCE_PROMPT_CACHING_5M
VAR=FORCE_PROMPT_CACHING_5M=1
has(){ grep -qxF -- "$VAR" <<<"$1"; }
pairs(){ printf '%s\n' "${SESSION_ENV[@]}"; }

echo "== session_env: the TTL setting decides =="
HARNESS_CLI=claude; session_env u-1
assert_ok "default: the 5m TTL is in the lane's environment" has "$(pairs)"
assert_eq "$(pairs | grep -cx -- "$VAR")" 1 "…once"
assert_eq "$(pairs | grep -B1 -x -- "$VAR" | head -1)" "-e" "…as an -e NAME=value pair"
HARNESS_CACHE_TTL=5m session_env u-1;  assert_ok "HARNESS_CACHE_TTL=5m: set" has "$(pairs)"
HARNESS_CACHE_TTL=1h session_env u-1;  assert_no "HARNESS_CACHE_TTL=1h: not set (the CLI's own 1h default)" has "$(pairs)"
HARNESS_CACHE_TTL=bogus session_env u-1; assert_ok "an unknown value is the 5m default" has "$(pairs)"
HARNESS_CACHE_TTL= session_env u-1;    assert_ok "an empty value is the 5m default" has "$(pairs)"
echo "== an unrecognised value warns once, case and spaces are ignored (#808) =="
HARNESS_CACHE_TTL=1H session_env u-1 2>"$RUN_DIR/w1"; assert_no "1H: read as 1h (no 5m pair)" has "$(pairs)"
assert_eq "$(cat "$RUN_DIR/w1")" "" "1H: no warning"
HARNESS_CACHE_TTL=" 1h " session_env u-1 2>"$RUN_DIR/w2"; assert_no " 1h : read as 1h" has "$(pairs)"
assert_eq "$(cat "$RUN_DIR/w2")" "" " 1h : no warning"
HARNESS_CACHE_TTL=5M session_env u-1 2>"$RUN_DIR/w3"; assert_ok "5M: read as 5m" has "$(pairs)"
assert_eq "$(cat "$RUN_DIR/w3")" "" "5M: no warning"
HARNESS_CACHE_TTL= session_env u-1 2>"$RUN_DIR/w4"; assert_eq "$(cat "$RUN_DIR/w4")" "" "empty: no warning"
for bad in 60m abc 0; do
  HARNESS_CACHE_TTL=$bad session_env u-1 2>"$RUN_DIR/wb"; assert_ok "$bad: 5m" has "$(pairs)"
  assert_ok "$bad: warned, naming the value" grep -qF "WARN HARNESS_CACHE_TTL='$bad' is not 5m or 1h" "$RUN_DIR/wb"
  HARNESS_CACHE_TTL=$bad session_env u-1 2>"$RUN_DIR/wb2"; assert_eq "$(cat "$RUN_DIR/wb2")" "" "$bad: the second launch does not warn again"
done
for cli in agy codex; do
  [[ -f "$ROOT/scripts/cli/$cli.sh" ]] || continue
  HARNESS_CLI=$cli session_env u-1; assert_no "$cli lane: no claude cache variable" has "$(pairs)"
done
HARNESS_CLI=claude
assert_eq "$(HARNESS_CACHE_TTL=1h claude_cache_ttl)" 1h "claude_cache_ttl: 1h"
assert_eq "$(claude_cache_ttl)" 5m "claude_cache_ttl: 5m by default"

echo "== tmux: new-session carries the pair =="
NEWSESS="$RUN_DIR/new-session.args"
tmux(){ case "$1" in has-session) return 1;; new-session) printf '%s\n' "$@" > "$NEWSESS";; *) return 0;; esac; }
sleep(){ :; }
export HARNESS_TMP_ROOT="$RUN_DIR/tmproot"
WT="$RUN_DIR/wt-main-i7"; mkdir -p "$WT"; echo task > "$WT/.harness-task.md"
UNIT=main SLUG=acme/widget GOAL="ISSUE:7" STAT_PRD=5 launch_agent hz-a-i7 "$WT" >/dev/null 2>&1
assert_ok "launch_agent: tmux new-session gets -e $VAR" grep -qxF -- "$VAR" "$NEWSESS"
HARNESS_CACHE_TTL=1h UNIT=main SLUG=acme/widget GOAL="ISSUE:7" STAT_PRD=5 launch_agent hz-b-i7 "$WT" >/dev/null 2>&1
assert_no "HARNESS_CACHE_TTL=1h: new-session has no such pair" grep -qF FORCE_PROMPT_CACHING_5M "$NEWSESS"
unset -f tmux sleep

echo "== headless: the lane's CLI turn runs with it =="
export RUN_DIR HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
export HARNESS_CLAUDE_BIN="python3 $(native_path "$FAKE")" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
export HARNESS_STALL_RETRIES=3 HARNESS_LIMIT_NUDGE_EVERY=1 HARNESS_INTERRUPT_WAIT=10 HARNESS_HEADLESS_STOP_WAIT=10
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"
LOG="$RUN_DIR/harness.log"; log(){ printf '%s\n' "$*" >> "$LOG"; }
our_pids(){ local d; shopt -s nullglob
  for d in "$HARNESS_HOME"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$RUN_DIR"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
  done; shopt -u nullglob; }
cleanup(){ local p; for p in $(our_pids); do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
turn_ran(){ [[ -s "$RUN_DIR/fake-$1/turn.env" ]]; }
lane(){ local name="$1" WDX="$RUN_DIR/wd-$1"
  mkdir -p "$WDX"; echo "the task" > "$WDX/.harness-task.md"
  export FAKE_CLAUDE_DIR="$RUN_DIR/fake-$name"; mkdir -p "$FAKE_CLAUDE_DIR"; echo normal > "$FAKE_CLAUDE_DIR/plan"
  cat > "$FAKE_CLAUDE_DIR/turn-hook" <<HOOK
#!/usr/bin/env bash
env | sort > "$FAKE_CLAUDE_DIR/turn.env.tmp" && mv "$FAKE_CLAUDE_DIR/turn.env.tmp" "$FAKE_CLAUDE_DIR/turn.env"
HOOK
  chmod +x "$FAKE_CLAUDE_DIR/turn-hook"; }
cd "$RUN_DIR" || exit 1
for ttl in 5m 1h; do
  lane "t$ttl"
  ( export HARNESS_CACHE_TTL=$ttl HARNESS_SESS_PREFIX=hz SLUG=acme/widget
    GOAL=ISSUE:3 MAXITER=10 PROMISE="ISSUE 3 DONE" launch_agent "hz-$ttl-i3" "$RUN_DIR/wd-t$ttl" >/dev/null 2>&1 )
  assert_ok "$ttl: the headless lane runs a turn" wait_until 20 turn_ran "t$ttl"
  if [[ $ttl == 5m ]]; then assert_ok "5m: the turn's environment has $VAR" grep -qxF -- "$VAR" "$RUN_DIR/fake-t$ttl/turn.env"
  else assert_no "1h: the turn's environment has no FORCE_PROMPT_CACHING_5M" grep -qF FORCE_PROMPT_CACHING_5M "$RUN_DIR/fake-t$ttl/turn.env"; fi
done
finish

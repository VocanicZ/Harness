#!/usr/bin/env bash
# test_context_max.sh — #1252: claude lanes (and the sub-agents inside them) get a context budget. HARNESS_LANE_CONTEXT_MAX
# (default 200k; a count, or k / m suffix; off|none|0 = none) reaches the lane's environment as CLAUDE_CODE_AUTO_COMPACT_WINDOW=<tokens>
# on both session backends, raised to Claude Code's 100k minimum, an unknown value = the default with a one-time warning.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
unset HARNESS_LANE_CONTEXT_MAX CLAUDE_CODE_AUTO_COMPACT_WINDOW
NAME=CLAUDE_CODE_AUTO_COMPACT_WINDOW
pairs(){ printf '%s\n' "${SESSION_ENV[@]}"; }
val(){ pairs | grep "^$NAME=" | tr '\n' ' ' | sed 's/ $//'; }

echo "== session_env: the setting decides =="
HARNESS_CLI=claude; session_env u-1
assert_eq "$(val)" "$NAME=200000" "default: 200k"
assert_eq "$(pairs | grep -B1 "^$NAME=" | head -1)" "-e" "…as an -e NAME=value pair"
echo "== an unrecognised value warns once, naming it (before the table: a marker per value) =="
for bad in bogus -5 1.5m; do
  HARNESS_LANE_CONTEXT_MAX=$bad session_env u-1 2>"$RUN_DIR/w1"
  assert_ok "$bad: warned, naming the value" grep -qF "WARN HARNESS_LANE_CONTEXT_MAX='$bad' is not a token count" "$RUN_DIR/w1"
  HARNESS_LANE_CONTEXT_MAX=$bad session_env u-1 2>"$RUN_DIR/w2"; assert_eq "$(cat "$RUN_DIR/w2")" "" "$bad: the second launch does not warn again"
done
for ok in "" 250k " 1M " off 50k; do
  HARNESS_LANE_CONTEXT_MAX=$ok session_env u-1 2>"$RUN_DIR/w3"; assert_eq "$(cat "$RUN_DIR/w3")" "" "'$ok': no warning"
done

# rows: setting|expected value ("" = no pair)
while IFS='|' read -r in want; do
  HARNESS_LANE_CONTEXT_MAX="$in" session_env u-1 2>/dev/null
  assert_eq "$(val)" "${want:+$NAME=$want}" "'$in' -> ${want:-no pair}"
done <<'ROWS'
|200000
200000|200000
150000|150000
250k|250000
 300K |300000
1m|1000000
1M|1000000
0120k|120000
50k|100000
99999|100000
1|100000
off|
OFF|
none|
0|
0k|
bogus|200000
-5|200000
1.5m|200000
200 k|200000
12345678901|200000
ROWS
for cli in agy codex; do
  [[ -f "$ROOT/scripts/cli/$cli.sh" ]] || continue
  HARNESS_CLI=$cli session_env u-1; assert_eq "$(val)" "" "$cli lane: no claude compaction variable"
done
HARNESS_CLI=claude
assert_eq "$(claude_context_max)" 200000 "claude_context_max: 200000 by default"
assert_eq "$(HARNESS_LANE_CONTEXT_MAX=400k claude_context_max)" 400000 "claude_context_max: 400k"
assert_eq "$(HARNESS_LANE_CONTEXT_MAX=off claude_context_max)" "" "claude_context_max: off prints nothing"

echo "== an operator's own CLAUDE_CODE_AUTO_COMPACT_WINDOW does not leak in: the knob decides (portable.sh strips CLAUDE_CODE_*) =="
assert_ok "claude_session_env_name matches it" claude_session_env_name "$NAME"
( export CLAUDE_CODE_AUTO_COMPACT_WINDOW=777k; HARNESS_LANE_CONTEXT_MAX=300k session_env u-1; assert_eq "$(val)" "$NAME=300000" "the lane's pair is the knob's" )

echo "== tmux: new-session carries the pair =="
NEWSESS="$RUN_DIR/new-session.args"
tmux(){ case "$1" in has-session) return 1;; new-session) printf '%s\n' "$@" > "$NEWSESS";; *) return 0;; esac; }
sleep(){ :; }
export HARNESS_TMP_ROOT="$RUN_DIR/tmproot"
WT="$RUN_DIR/wt-main-i7"; mkdir -p "$WT"; echo task > "$WT/.harness-task.md"
UNIT=main SLUG=acme/widget GOAL="ISSUE:7" STAT_PRD=5 launch_agent hz-a-i7 "$WT" >/dev/null 2>&1
assert_ok "default: tmux new-session gets -e $NAME=200000" grep -qxF -- "$NAME=200000" "$NEWSESS"
HARNESS_LANE_CONTEXT_MAX=off UNIT=main SLUG=acme/widget GOAL="ISSUE:7" STAT_PRD=5 launch_agent hz-b-i7 "$WT" >/dev/null 2>&1
assert_no "off: new-session has no such pair" grep -qF "$NAME" "$NEWSESS"
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
for cap in 250k off; do
  lane "t$cap"
  ( export HARNESS_LANE_CONTEXT_MAX=$cap HARNESS_SESS_PREFIX=hz SLUG=acme/widget CLAUDE_CODE_AUTO_COMPACT_WINDOW=777k
    GOAL=ISSUE:3 MAXITER=10 PROMISE="ISSUE 3 DONE" launch_agent "hz-$cap-i3" "$RUN_DIR/wd-t$cap" >/dev/null 2>&1 )
  assert_ok "$cap: the headless lane runs a turn" wait_until 20 turn_ran "t$cap"
  if [[ $cap == 250k ]]; then assert_ok "250k: the turn's environment has $NAME=250000" grep -qxF -- "$NAME=250000" "$RUN_DIR/fake-t$cap/turn.env"
  else assert_no "off: the turn's environment has no $NAME (not even the operator's)" grep -qF "$NAME" "$RUN_DIR/fake-t$cap/turn.env"; fi
done
finish

#!/usr/bin/env bash
# test_supervise_headless.sh — #351 / PRD #344: `harness supervise` handles headless lanes
# (HARNESS_SESSION_BACKEND=headless) with the rules it applies to tmux panes, on real lane runners
# (scripts/cli/claude_headless.py) driving the fake claude from test/fixtures/cli/claude/stream-json/:
# a frozen idle lane is nudged (through its inbox), a turn that ran between two passes is activity
# (the drawn screen shows no reply text: the lane's activity mark does), an endless turn with a nudge
# queued is interrupted and the nudge delivered, a limit-parked lane is left alone, a lane past the
# kill threshold is checkpointed to GitHub and then killed, and a whole headless fleet is supervised —
# dead workers, orphan locks, frozen lanes, the arc rules' screen capture — with no tmux at all.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
_DOCTOR_SOURCED=1 source "$ROOT/scripts/doctor.sh"
make_env
T="$RUN_DIR/sup-t"; mkdir -p "$T/bin"
# tmux is never needed: a stub first on PATH records any call (and fails, as a host without it would).
printf '#!/bin/sh\necho "$@" >> %q\nexit 127\n' "$T/tmux.calls" > "$T/bin/tmux"; chmod +x "$T/bin/tmux"
printf '#!/bin/sh\necho "$@" >> %q\n' "$T/gh.calls" > "$T/bin/gh"; chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export RUN_DIR HARNESS_SESS_PREFIX=hst HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
export HARNESS_TOPOLOGY=multi TARGETS_TSV="$T/targets.tsv"; printf 'u\towner/repo\t-\tdesc\n' > "$TARGETS_TSV"
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
export HARNESS_CLAUDE_BIN="python3 $FAKE" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
export HARNESS_SUPERVISE_CONF="$T/none.conf" HARNESS_SUPERVISE_STATE="$T/sup" HARNESS_SUPERVISE_LOG="$T/sup.log"
source "$ROOT/scripts/supervise.sh"
LOG=$SUP_LOG; SUP_DRY=0
SEV="$T/events"; stats_sess_event(){ echo "$1 $2 ${*:3}" >> "$SEV"; }   # the fleet's stats log, recorded

# Only the processes this test started: each lane's runner (its pid file) and each fake claude
# (calls.jsonl / pids). Never a pattern kill: the host runs other lanes.
our_pids(){ local d; shopt -s nullglob
  for d in "$HARNESS_HOME"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$RUN_DIR"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
    [[ -f "$d/pids" ]] && tr ' ' '\n' < "$d/pids"
  done; shopt -u nullglob; }
cleanup(){ local p; for p in $(our_pids) ${LIVE:-}; do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
alive(){ kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
# lane <session> <plan…> — a worktree, a fake-claude dir replaying <plan>, and the lane launched on it.
lane(){ local s="$1"; shift
  WD="$RUN_DIR/wd-$s"; mkdir -p "$WD"; echo "the task" > "$WD/.harness-task.md"
  export FAKE_CLAUDE_DIR="$RUN_DIR/fake-$s"; mkdir -p "$FAKE_CLAUDE_DIR"
  printf '%s\n' "$@" > "$FAKE_CLAUDE_DIR/plan"
  [[ ${HOLD:-} ]] && touch "$FAKE_CLAUDE_DIR/hold"
  GOAL=ISSUE:${s##*-i} launch_agent "$s" "$WD" >/dev/null; }
prompt(){ python3 -c 'import json,sys; l=open(sys.argv[1]).read().splitlines(); n=int(sys.argv[2]); print(json.loads(l[n-1])["prompt"] if len(l) >= n else "")' \
  "$RUN_DIR/fake-$1/calls.jsonl" "$2" 2>/dev/null; }
state(){ python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$(headless_lane_dir "$1")" --field "$2"; }
idle_at(){ [[ "$(state "$1" turn)" == "$2" ]] && [[ "$(state "$1" state)" != busy ]] && ! cli_pane_busy "$(sess_capture "$1")"; }
# pass <session> [nudge min] [kill min] — one frozen-session pass over a lane, as sup_check_fleet runs it.
pass(){ sup_watch_pane "$1" "$SUP_STATE/panes/$1" "${2:-0}" "${3:-0}" "$SUP_NUDGE_MSG" claude sup_checkpoint_and_kill; }
quiet(){ "$@" 2>/dev/null; }
typed(){ grep -c "headless type $1: harness supervise:" "$LOG"; }

echo "== a frozen idle lane is nudged, through its inbox =="
S=hst-u-i1; lane "$S" normal normal
assert_ok "the lane's first turn ends, idle" wait_until 15 idle_at "$S" 1
: > "$LOG"; rm -rf "$SUP_STATE"
pass "$S"; pass "$S"                                     # baseline, then quiet (NUDGE_MIN 0)
assert_eq "$(typed "$S")" 1 "the quiet lane is nudged once"
assert_ok "…clearing its input line first" grep -q "ACT headless clear $S" "$LOG"
assert_ok "…then submitting it" grep -q "ACT headless enter $S" "$LOG"
assert_ok "the nudge is the lane's next turn" wait_until 15 idle_at "$S" 2
assert_ok "…its prompt the supervisor's nudge" grep -qF "harness supervise: no activity for a while" <<<"$(prompt "$S" 2)"
pass "$S"
assert_eq "$(typed "$S")" 1 "no second nudge inside RENUDGE_S"

echo "== a turn that ran between two passes is activity, though the drawn screen is unchanged =="
rm -f "$SUP_STATE/panes/$S"; : > "$LOG"
pass "$S"                                                # baseline: idle after turn 2
before="$(sess_capture "$S")"
cli_send "$S" "$WD" "more work"
assert_ok "a third turn runs and ends" wait_until 15 idle_at "$S" 3
assert_eq "$(sess_capture "$S")" "$before" "the lane's screen reads exactly as before the turn"
assert_ok "a headless lane has an activity mark" test -n "$(sess_activity "$S")"
pass "$S"
assert_eq "$(typed "$S")" 0 "…so the lane is not quiet and is not nudged"
read -r _ _ _ t0 nudged _ < "$SUP_STATE/panes/$S"
assert_ok "…its quiet clock restarted" test "$(( $(date +%s) - t0 ))" -le 5
assert_eq "$(HARNESS_SESSION_BACKEND=tmux sess_activity "$S")" "" "a tmux pane has no mark beyond its screen"
sess_kill "$S"

echo "== a limit-parked lane is NOT nudged =="
S=hst-u-i2; lane "$S" limit
assert_ok "the lane's turn hits the usage limit" wait_until 15 idle_at "$S" 1
assert_eq "$(state "$S" state)" limit "…its state reads limit"
: > "$LOG"
pass "$S"; sleep 1; pass "$S"
assert_eq "$(typed "$S")" 0 "a limit-parked lane is left alone"
assert_no "…nothing at all is done to it" grep -q "$S" "$LOG"
sess_kill "$S"

echo "== an endless turn with a nudge queued behind it is interrupted =="
S=hst-u-i3; lane "$S" hang normal
assert_ok "the lane's turn hangs" wait_until 15 test -s "$FAKE_CLAUDE_DIR/pids"
fpid=; gpid=; read -r fpid gpid < "$FAKE_CLAUDE_DIR/pids"
sess_type "$S" "$SUP_NUDGE_MSG"; sess_enter "$S"         # a nudge typed mid-turn waits in the inbox
assert_ok "the nudge waits in the lane's input box" grep -qF "❯ harness supervise: no activity" <<<"$(sess_capture "$S")"
HARNESS_TURN_MAX=1; sleep 2; : > "$LOG"; : > "$SEV"
SUP_DRY=1 pass "$S"
assert_ok "dry run: the endless turn would be interrupted" grep -q "DRY headless interrupt $S" "$LOG"
assert_ok "…its process still running" alive "$fpid"
rm -rf "$SUP_STATE/turn"; : > "$LOG"; HARNESS_INTERRUPT_WAIT=10
# The nudge's own turn is held, as a real `claude -p` turn takes seconds: turn_interrupt reads the
# `Interrupted` line while the next turn runs (the TUI's scrollback keeps it the same way).
touch "$FAKE_CLAUDE_DIR/hold"
pass "$S"
assert_ok "the turn is logged as endless with input queued" grep -q "turn: $S has run one turn for [0-9]*s with input queued" "$LOG"
assert_ok "…and interrupted" grep -q "ACT headless interrupt $S" "$LOG"
assert_no "…which it reports (Interrupted)" grep -q "did not report Interrupted" "$LOG"
assert_ok "…its process tree ended" wait_until 10 bash -c "! kill -0 $fpid 2>/dev/null && ! kill -0 $gpid 2>/dev/null"
assert_ok "a turn_interrupted event is recorded for stats" grep -q "^$S turn_interrupted turn_s=[0-9]* queued_nudges=1" "$SEV"
rm -f "$FAKE_CLAUDE_DIR/hold"
assert_ok "the queued nudge is delivered as the next turn" wait_until 15 idle_at "$S" 2
assert_ok "…its prompt the nudge" grep -qF "harness supervise: no activity for a while" <<<"$(prompt "$S" 2)"
HARNESS_TURN_MAX=14400
sess_kill "$S"

echo "== a lane past the kill threshold is checkpointed, then killed =="
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
git init -q --bare "$T/remote.git"
S=hst-u-i4; WD="$RUN_DIR/wd-$S"
git clone -q "$T/remote.git" "$WD" 2>/dev/null; gc "$WD" config user.email t@t; gc "$WD" config user.name t
echo base > "$WD/a.txt"; gc "$WD" add -A; gc "$WD" commit -qm base; gc "$WD" push -q origin HEAD:main; gc "$WD" checkout -qb issue/4
lane "$S" normal
echo "work in progress" > "$WD/b.txt"
assert_ok "the lane's turn ends, idle" wait_until 15 idle_at "$S" 1
rpid="$(sess_pane_pid "$S")"
: > "$LOG"; : > "$SEV"; : > "$T/gh.calls"; rm -rf "$SUP_STATE"
SUP_DRY=1 pass "$S" 0 1; SUP_DRY=1 pass "$S" 0 1        # baseline, then the nudge (not delivered: dry)
assert_ok "the quiet lane is nudged first (dry: never delivered)" grep -q "DRY headless type $S: harness supervise:" "$LOG"
pass "$S" 0 1
assert_ok "nothing is killed before KILL_MIN" sess_live "$S"
read -r a b c t0 rest < "$SUP_STATE/panes/$S"; echo "$a $b $c $(( t0 - 7200 )) $rest" > "$SUP_STATE/panes/$S"
pass "$S" 0 1                                            # the nudge ignored, quiet past KILL_MIN
assert_ok "its WIP is pushed to origin/issue/4" bash -c "git -C '$T/remote.git' show issue/4:b.txt | grep -q 'work in progress'"
assert_no "…never .harness-task.md" quiet git -C "$T/remote.git" cat-file -e issue/4:.harness-task.md
assert_ok "a handoff comment is posted" grep -q "issue comment 4 -R owner/repo --body <!-- harness-handoff issue=4 branch=issue/4 -->" "$T/gh.calls"
assert_ok "…carrying the lane's last screen" grep -q "❯" "$T/gh.calls"
assert_no "the lane is killed" sess_live "$S"
assert_no "…its runner gone" alive "$rpid"
assert_eq "$(state "$S" state)" ended "…its state reads ended"
cn="$(grep -n "ACT gh issue comment 4" "$LOG" | cut -d: -f1)"; kn="$(grep -n "ACT headless stop =$S" "$LOG" | cut -d: -f1)"
assert_ok "checkpointed BEFORE it was killed (comment line $cn, stop line $kn)" test "${cn:-99}" -lt "${kn:-0}"
assert_ok "a watchdog_kill event is recorded" grep -q "^$S watchdog_kill reason=frozen" "$SEV"
assert_no "the killed lane's state is forgotten" test -f "$SUP_STATE/panes/$S"

echo "== a whole headless fleet: workers, orphan locks, frozen lanes, arc rules — no tmux =="
F="$T/fleets/proj"; mkdir -p "$F/.harness/run"
printf ': "${HARNESS_SESS_PREFIX:=fx}"\n: "${HARNESS_POOL:=1}"\n: "${HARNESS_REPO:=owner/fx}"\n: "${HARNESS_SESSION_BACKEND:=headless}"\n' > "$F/.harness/config"
cat > "$T/bin/gh" <<EOF
#!/bin/sh
echo "\$@" >> $T/gh.calls
case "\$1 \$2" in
  "issue list") printf '5\n6\n' ;;
  "api repos/owner/fx/issues/5/timeline"|"api repos/owner/fx/issues/6/timeline") echo 2020-01-01T00:00:00Z ;;
esac
EOF
cat > "$T/rules-stub" <<EOF
import sys
open("$T/rules.stdin", "w").write(sys.stdin.read())
EOF
SUP_RULES="$T/rules-stub"
printf '#!/bin/sh\necho "$@" >> %s/harness.calls\n' "$T" > "$T/harness-stub"; chmod +x "$T/harness-stub"; SUP_HARNESS="$T/harness-stub"
sleep 600 & LIVE=$!; echo "$LIVE" > "$F/.harness/run/worker-1.pid"
S=fx-main-i6; lane "$S" normal
assert_ok "the fleet's lane is idle" wait_until 15 idle_at "$S" 1
: > "$LOG"; : > "$T/gh.calls"; rm -rf "$SUP_STATE"
# The environment names tmux: the fleet's own config is what makes its lanes headless.
HARNESS_SESSION_BACKEND=tmux SUP_DRY=0 NUDGE_MIN=0 sup_check_fleet "$F/.harness"
HARNESS_SESSION_BACKEND=tmux SUP_DRY=0 NUDGE_MIN=0 sup_check_fleet "$F/.harness"
assert_ok "an orphan lock (no lane for it) is cleared" grep -q "issue edit 5 -R owner/fx --remove-label agent-working" "$T/gh.calls"
assert_no "a lock held by a live headless lane is kept" grep -q "issue edit 6" "$T/gh.calls"
assert_eq "$(typed "$S")" 1 "the fleet's frozen lane is nudged"
assert_ok "…and the nudge reaches it" wait_until 15 idle_at "$S" 2
assert_ok "the arc rules are handed the headless lane" grep -qx "$(printf '%s\towner/fx\t6\timpl' "$S")" "$T/rules.stdin"
cap="$(HARNESS_SESSION_BACKEND=headless python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import supervise_rules; print(supervise_rules.capture(sys.argv[2]))' "$ROOT/scripts" "$S")"
assert_ok "the arc rules read the lane's screen (its drawn state)" grep -q "^❯" <<<"$cap"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
SUP_DRY=0 NUDGE_MIN=0 sup_check_fleet "$F/.harness"
assert_ok "a dead worker → harness start for the headless fleet" grep -q -- "--state-dir $F/.harness start" "$T/harness.calls"
sess_kill "$S"

echo "== the supervisor's own preflight needs no tmux =="
U="$T/unit"; mkdir -p "$T/tools"
for b in claude gh rtdd python3 git; do ln -sf "$(command -v "$b" 2>/dev/null || echo /bin/true)" "$T/tools/$b"; done
ln -sf "$(command -v bash)" "$T/tools/bash"
printf '#!/bin/sh\n' > "$T/tools/systemctl"; chmod +x "$T/tools/systemctl"; cp "$T/tools/systemctl" "$T/tools/loginctl"
out="$(PATH="$T/tools:/usr/bin:/bin" SUP_UNIT_DIR="$U" SUP_SYSTEMCTL="$T/tools/systemctl" SUP_LOGINCTL="$T/tools/loginctl" sup_install 2>&1)"
assert_no "--install warns about nothing missing" grep -qi "warning" <<<"$out"
assert_ok "…and writes the unit" test -f "$U/harness-supervise.service"
assert_ok "the unit's PATH reaches every session backend's binaries the host has (python3)" \
  grep -q "^Environment=PATH=.*$(dirname "$(command -v python3)")" "$U/harness-supervise.service"
out="$(DOCTOR_FIX=0 doctor_main 2>&1)"
assert_ok "harness doctor reports the headless backend" grep -qF "session backend: headless" <<<"$out"
assert_eq "$(cat "$T/tmux.calls" 2>/dev/null)" "" "no tmux ran anywhere in this test"

echo "== docs =="
assert_ok "docs/reference.md says the supervisor handles headless lanes" \
  grep -qi "harness supervise" <<<"$(sed -n '/^### Headless lanes/,/^##/p' "$ROOT/docs/reference.md")"
finish

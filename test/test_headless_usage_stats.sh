#!/usr/bin/env bash
# test_headless_usage_stats.sh — #352 / PRD #344: usage checkpoints, stats and the status views on the
# headless backend. A busy headless claude lane is checkpointed by the usage watch when a (stubbed)
# usage window crosses the threshold — the checkpoint waits behind the running turn — and, once its
# checkpoint turn has swapped the labels, parked: the lane is ended, claims stay held. Below the
# threshold it is left alone. The ended lane's session lands in `harness stats` with the model it ran
# and the tokens its turns' stream-json `result` events report (no claude transcript), and session_end
# is emitted only once its runner has exited. The claude adapter reads a headless lane's usage windows
# off its rate_limit_event readings (no status line). `harness status`, fleetview and `harness web` list
# a live headless lane with its state.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"; source "$ROOT/scripts/drive.sh"
make_env
export RUN_DIR PAUSE_FLAG HARNESS_SESS_PREFIX=hus HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
export HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl" HARNESS_CLAUDE_CONFIG_DIRS="$RUN_DIR/no-claude-config"
export HARNESS_USAGE_CHECKPOINT_PCT=90 HARNESS_USAGE_STATUSLINE=0
FIX="$HERE/fixtures/cli/claude/stream-json"
export HARNESS_CLAUDE_BIN="python3 $FIX/fake-claude" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions --model haiku"
LOG="$RUN_DIR/harness.log"; log(){ printf '%s\n' "$*" >> "$LOG"; }

# A fake gh over files in $FAKE_GH_DIR (labels-<n>, comments-<n>.json): `issue view|edit|comment` and
# `api user`, -q through jq as gh's does.
export FAKE_GH_DIR="$RUN_DIR/gh"; mkdir -p "$FAKE_GH_DIR" "$RUN_DIR/bin"
cat > "$RUN_DIR/bin/gh" <<'EOF'
#!/usr/bin/env python3
import json, os, subprocess, sys
d = os.environ["FAKE_GH_DIR"]; a = sys.argv[1:]
def opt(name, default=None):
    return a[a.index(name) + 1] if name in a else default
def labels(n):
    try: return [l.strip() for l in open(os.path.join(d, f"labels-{n}")) if l.strip()]
    except OSError: return []
def comments(n):
    try: return json.load(open(os.path.join(d, f"comments-{n}.json")))
    except (OSError, ValueError): return []
def out(obj):
    q = opt("-q") or opt("--jq")
    if q: sys.stdout.write(subprocess.run(["jq", "-r", q], input=json.dumps(obj), capture_output=True, text=True).stdout)
    else: print(json.dumps(obj))
cmd = " ".join(a[:2])
if cmd == "api user": out({"login": "fleet-bot"})
elif cmd == "issue view":
    n = a[2]; out({"number": int(n), "state": "OPEN", "body": "", "labels": [{"name": l} for l in labels(n)], "comments": comments(n)})
elif cmd == "issue edit":
    n = a[2]; ls = labels(n)
    for i, w in enumerate(a):
        if w == "--remove-label": ls = [l for l in ls if l not in a[i + 1].split(",")]
        if w == "--add-label": ls += [l for l in a[i + 1].split(",") if l not in ls]
    open(os.path.join(d, f"labels-{n}"), "w").write("".join(l + "\n" for l in ls))
elif cmd == "issue comment":
    n = a[2]; body = opt("--body")
    if body is None: body = open(opt("--body-file")).read()
    json.dump(comments(n) + [{"author": {"login": "fleet-bot"}, "body": body}], open(os.path.join(d, f"comments-{n}.json"), "w"))
EOF
chmod +x "$RUN_DIR/bin/gh"; export PATH="$RUN_DIR/bin:$PATH"
gh_labels(){ paste -sd, "$FAKE_GH_DIR/labels-$1" 2>/dev/null; }

# Only the processes this test started: each lane's runner and each fake claude. Never a pattern kill.
our_pids(){ local d; shopt -s nullglob
  for d in "$HARNESS_HOME"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$RUN_DIR"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
  done; shopt -u nullglob; }
cleanup(){ local p; for p in $(our_pids); do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
alive(){ kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
lane_field(){ python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$(headless_lane_dir "$1")" --field "$2" 2>/dev/null; }
pane_has(){ sess_capture "$1" 2>/dev/null | grep -qF "$2"; }
turn_idle(){ [[ "$(lane_field "$1" turn)" == "$2" && "$(lane_field "$1" state)" == idle ]]; }
calls(){ python3 -c 'import json,sys; [print(json.dumps(json.loads(l)[sys.argv[2]])) for l in open(sys.argv[1])]' \
  "$FAKE_CLAUDE_DIR/calls.jsonl" "$1" 2>/dev/null; }
# fake_claude <name> <plan…> — the fake claude's dir for a lane, replaying <plan> (one fixture per turn),
# whose checkpoint turn makes the agent's gh calls (the handoff comment and the label swap).
fake_claude(){ export FAKE_CLAUDE_DIR="$RUN_DIR/fake-$1"; shift; mkdir -p "$FAKE_CLAUDE_DIR"
  printf '%s\n' "$@" > "$FAKE_CLAUDE_DIR/plan"
  cat > "$FAKE_CLAUDE_DIR/turn-hook" <<'EOF'
#!/usr/bin/env bash
p="$(cat)"; [[ $p == "HARNESS CHECKPOINT"* ]] || exit 0
f="$(mktemp)"; { grep -o '<!-- harness-handoff [^>]*-->' <<<"$p" | head -1; echo "Handoff: usage."; } > "$f"
eval "$(grep -o 'gh issue comment [0-9]* -R [^ ]*' <<<"$p" | head -1) --body-file $f"
eval "$(grep -o 'gh issue edit [0-9]* -R [^ ]* --remove-label [^ ]* --add-label [^ .]*' <<<"$p" | head -1)"
rm -f "$f"
EOF
  chmod +x "$FAKE_CLAUDE_DIR/turn-hook"; }
# usage_stub <account> <pct> — HARNESS_USAGE_CMD reporting one open five-hour window. A lane's account is
# its config dir's name, "default" with none (the status line's rule): this test's lanes run on "default".
usage_stub(){ export HARNESS_USAGE_CMD="printf '$1\tfive_hour\t$2\t%s\n' $(( $(date +%s) + 3600 ))"; }
session_ends(){ grep -c '"event": *"session_end"' "$HARNESS_EVENTS_FILE" 2>/dev/null || true; }
# The dispatch context spawn_impl runs in (drive_unit's dynamic scope), its git and checkout stubbed.
UNIT=main REPO=acme/widget SLUG=acme/widget PROJECT=main DESC=widget CHECKOUT="$PROJECT_ROOT"
ensure_checkout(){ return 0; }; default_branch(){ echo main; }
git(){ return 0; }

echo "== a busy headless lane under the usage threshold is left alone =="
S="$(sess_impl main 9)"; WD="$WORKTREES_DIR/main-i9"; mkdir -p "$WD"
printf 'agent-working\n' > "$FAKE_GH_DIR/labels-9"
fake_claude i9 "tool-use working on it" "normal checkpointed <promise>ISSUE 9 DONE</promise>" "normal"
touch "$FAKE_CLAUDE_DIR/hold"   # the lane is mid-turn on the issue when the usage watch looks
spawn_impl 9 "ISSUE 9 DONE" >/dev/null 2>&1
assert_ok "the headless impl lane is live" sess_live "$S"
uuid="$(sed -n 's/^session_id: //p' "$WD/.claude/ralph-loop.local.md")"
assert_ok "…its first turn running" wait_until 10 test "$(lane_field "$S" state)" = busy
usage_stub default 42; usage_watch
assert_no "below the threshold: no hold" usage_held
assert_no "…no checkpoint queued for the lane" pane_has "$S" "HARNESS CHECKPOINT"
assert_eq "$(lane_field "$S" queued)" 0 "…nothing waits on its inbox"
assert_no "…no park pending" test -f "$RUN_DIR/$S.usagepark"
assert_eq "$(lane_field "$S" state)" busy "…its turn runs on"
usage_stub other 97; usage_watch
assert_ok "another account over the threshold holds claims" usage_held
assert_no "…but the lane runs on its own account: no checkpoint for it" test -f "$RUN_DIR/$S.usagepark"
assert_eq "$(lane_field "$S" queued)" 0 "…nothing queued on it"
rm -rf "$RUN_DIR/usage-holds"

echo "== over the threshold: the checkpoint waits behind the running turn, then the lane parks =="
usage_stub default 95; usage_watch
assert_ok "the account's claims are held" usage_held
assert_eq "$(session_account "$S")" default "the lane's account is the one its runner recorded"
assert_ok "the checkpoint was requested" grep -qF "usage: checkpoint requested: $S (acme/widget#9)" "$LOG"
assert_ok "…and waits behind the running turn" wait_until 10 pane_has "$S" "❯ HARNESS CHECKPOINT"
assert_ok "…a park is pending for the lane" test -f "$RUN_DIR/$S.usagepark"
assert_eq "$(session_ends)" 0 "no session_end while the lane is live"
usage_watch
assert_ok "still mid-turn: the lane is not parked yet" sess_live "$S"
rpid="$(sess_pane_pid "$S")"
rm -f "$FAKE_CLAUDE_DIR/hold"
assert_ok "the checkpoint turn runs and ends" wait_until 15 turn_idle "$S" 2
assert_ok "…it was the checkpoint, on the same claude session" grep -qF "\"--resume\", \"$uuid\"" <<<"$(calls argv | sed -n 2p)"
assert_ok "…whose prompt names the usage limit" grep -qF 'HARNESS CHECKPOINT \u2014 usage limit near (five_hour window at 95%)' <<<"$(calls prompt | sed -n 2p)"
assert_eq "$(gh_labels 9)" "agent-paused" "the checkpoint landed: agent-working → agent-paused"
assert_ok "…with the handoff comment" grep -qF '<!-- harness-handoff issue=9 branch=issue/9 -->' "$FAKE_GH_DIR/comments-9.json"
usage_watch
assert_ok "the next usage pass parks the lane" grep -qF "usage: lane parked after its checkpoint: $S (acme/widget#9)" "$LOG"
assert_no "…it is no longer live" sess_live "$S"
assert_ok "…its runner has exited" wait_until 10 bash -c "! kill -0 $rpid 2>/dev/null"
assert_no "…the park is done with" test -f "$RUN_DIR/$S.usagepark"
assert_ok "claims stay held while the window is over" usage_held
assert_eq "$(sess_resume_id "$S" "$WD")" "$uuid" "the parked lane leaves its claude session for the resume"
assert_ok "a paused event was logged for the session" grep -qE '"event": *"paused".*"reason": *"usage_limit"' "$HARNESS_EVENTS_FILE"

echo "== stats: the ended session's model and tokens, from its turns' stream-json results =="
stats_sweep_ended
assert_eq "$(session_ends)" 1 "session_end is emitted once the runner has exited"
stats_sweep_ended
assert_eq "$(session_ends)" 1 "…exactly once"
want="$(python3 - "$FIX/tool-use.jsonl" "$FIX/normal.jsonl" <<'PY'
import json, sys
tot = {}
for f in sys.argv[1:]:
    for l in open(f):
        r = json.loads(l)
        for m, u in (r.get("modelUsage") or {}).items() if r.get("type") == "result" else ():
            t = tot.setdefault(m, {"input": 0, "output": 0, "cache_create": 0, "cache_read": 0})
            for s, d in (("inputTokens", "input"), ("outputTokens", "output"),
                         ("cacheCreationInputTokens", "cache_create"), ("cacheReadInputTokens", "cache_read")):
                t[d] += u[s]
print(json.dumps(tot, sort_keys=True))
PY
)"
got="$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["event"] == "session_end": print(json.dumps(e.get("usage"), sort_keys=True))' "$HARNESS_EVENTS_FILE")"
assert_eq "$got" "$want" "session_end's usage is the sum of the fixture turns' modelUsage"
assert_ok "…a model the fixtures ran" grep -qF '"claude-haiku-5-5"' <<<"$got"
rep="$(python3 "$ROOT/scripts/stats.py" report --issue 9 --json --events "$HARNESS_EVENTS_FILE")"
assert_eq "$(jq -r '.sessions[0].model' <<<"$rep")" haiku "harness stats shows the session's model"
assert_eq "$(jq -c '.sessions[0].usage' <<<"$rep" | jq -S -c .)" "$(jq -S -c . <<<"$want")" "…and its token counts"
assert_eq "$(jq -r '.sessions[0].session' <<<"$rep")" "$uuid" "…under its claude session id"

echo "== the claude adapter reads a headless lane's usage windows off its rate_limit_event readings =="
unset HARNESS_USAGE_CMD; rm -rf "$RUN_DIR/usage-holds"
future=$(( $(date +%s) + 7200 )); past=$(( $(date +%s) - 60 ))
lane_state(){ mkdir -p "$HARNESS_HOME/lanes/$1"; printf '%s' "$2" > "$HARNESS_HOME/lanes/$1/state.json"; }
rm -rf "$HARNESS_HOME/lanes"
lane_state hus-old "{\"state\":\"ended\",\"account\":\"work\",\"rate_limit_at\":100,\"rate_limit\":{\"unifiedWindows\":{\"seven_day\":{\"utilization\":0.5,\"resetsAt\":$future}}}}"
lane_state hus-new "{\"state\":\"busy\",\"account\":\"work\",\"rate_limit_at\":200,\"rate_limit\":{\"status\":\"allowed_warning\",\"unifiedWindows\":{\"five_hour\":{\"utilization\":0.02,\"resetsAt\":$past},\"seven_day\":{\"utilization\":0.94,\"resetsAt\":$future}}}}"
lane_state hus-junk 'not json'
# A sibling fleet's lane on the same host: its account is not this fleet's to hold claims for.
lane_state sib-x "{\"state\":\"busy\",\"account\":\"theirs\",\"rate_limit_at\":300,\"rate_limit\":{\"unifiedWindows\":{\"seven_day\":{\"utilization\":0.99,\"resetsAt\":$future}}}}"
assert_eq "$(cli_limit_usage)" "$(printf 'work\tseven_day\t94\t%s' "$future")" \
  "the newest reading per account window of this fleet's lanes, a reset window skipped"
mkdir -p "$(_usage_dir)"; printf '{"account":"work","at":300,"rate_limits":{"seven_day":{"used_percentage":96.5,"resets_at":%s}}}' "$future" > "$(_usage_dir)/work.json"
assert_eq "$(cli_limit_usage)" "$(printf 'work\tseven_day\t96.5\t%s' "$future")" "…a newer status-line drop wins over it"
rm -rf "$(_usage_dir)"
usage_watch
assert_ok "the usage watch holds claims on a headless lane's reading" usage_held
assert_ok "…naming the window" grep -qF "usage: work seven_day window at 94% (>= 90%)" "$LOG"
rm -rf "$HARNESS_HOME/lanes" "$RUN_DIR/usage-holds"
assert_no "no lane and no drop: usage unavailable" cli_limit_usage
mkdir -p "$(_usage_dir)"; printf '{"account":"work","rate_limits":{"seven_day":{"used_percentage":50,"resets_at":%s}}}' "$past" > "$(_usage_dir)/work.json"
assert_eq "$(cli_limit_usage; echo "rc=$?")" "rc=0" "a drop whose every window has reset: available, no open window (as before)"
rm -rf "$(_usage_dir)"

echo "== the lane runner records the account and when its rate-limit reading changed =="
L="$RUN_DIR/lane-acct"; export FAKE_CLAUDE_DIR="$RUN_DIR/fake-acct"; mkdir -p "$FAKE_CLAUDE_DIR"; echo tool-use > "$FAKE_CLAUDE_DIR/plan"
CLAUDE_CONFIG_DIR=/x/accounts/team/ HARNESS_LANE_DIR="$L" python3 "$ROOT/scripts/cli/claude_headless.py" run \
  --cwd "$RUN_DIR" --bin "python3 $FIX/fake-claude" --session-id 11111111-2222-3333-4444-555555555555 --message hi \
  >/dev/null 2>&1 & lpid=$!
wait_until 15 test "$(python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$L" --field turn 2>/dev/null)" = 1
wait_until 15 test "$(python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$L" --field state 2>/dev/null)" = idle
st="$(cat "$L/state.json")"
python3 "$ROOT/scripts/cli/claude_headless.py" stop --lane "$L" >/dev/null 2>&1; wait "$lpid" 2>/dev/null
assert_eq "$(jq -r .account <<<"$st")" team "the account is the lane's config dir, as the status line names it"
assert_ok "rate_limit_at is stamped with the reading" jq -e '.rate_limit_at > 0 and .rate_limit.unifiedWindows.seven_day.utilization == 0.94' >/dev/null <<<"$st"

echo "== harness status, fleetview and harness web list a live headless lane with its state =="
S="$(sess_impl main 11)"; WD="$WORKTREES_DIR/main-i11"; mkdir -p "$WD"
printf 'ready-for-agent\n' > "$FAKE_GH_DIR/labels-11"
fake_claude i11 "normal working"; touch "$FAKE_CLAUDE_DIR/hold"
spawn_impl 11 "ISSUE 11 DONE" >/dev/null 2>&1
assert_ok "the lane is busy" wait_until 10 test "$(lane_field "$S" state)" = busy
assert_eq "$(sess_state "$S")" busy "sess_state reads the lane's state"
source "$ROOT/scripts/status.sh"
assert_ok "harness status's session row shows the lane's state" grep -qE "⟳ $S +ralph-iter=1  headless: busy" <<<"$(session_row "$S" "$WD")"
assert_eq "$(HARNESS_SESSION_BACKEND=tmux sess_state "$S")" "" "a tmux session has no state of its own"
assert_no "…so its row shows none" grep -qF "tmux:" <<<"$(HARNESS_SESSION_BACKEND=tmux session_row "$S" "$WD")"
views="$(cd "$ROOT/scripts" && HARNESS_SESSION_BACKEND=tmux python3 -c '
import json, fleetview, web_data
print(json.dumps([fleetview.host_sessions(), fleetview.session_states(), fleetview.session_models(),
                  web_data.live_sessions("hus", 0, run_dir=None, cfg={})]))')"
assert_ok "fleetview lists the lane (whatever backend the viewer runs on)" jq -e --arg s "$S" '.[0] | has($s)' >/dev/null <<<"$views"
assert_eq "$(jq -r --arg s "$S" '.[1][$s]' <<<"$views")" busy "…with its state"
assert_eq "$(jq -r --arg s "$S" '.[2][$s]' <<<"$views")" haiku "…and the model on its runner's flags"
assert_eq "$(jq -r '.[3][0].state + " " + .[3][0].issue' <<<"$views")" "busy #11" "harness web's session row carries the lane and its state"
rm -f "$FAKE_CLAUDE_DIR/hold"; wait_until 15 turn_idle "$S" 1
assert_eq "$(sess_state "$S")" idle "the state follows the lane"
sess_kill "$S" >/dev/null
assert_eq "$(sess_state "$S")" "" "an ended lane has no state"

echo "== docs =="
sec="$(sed -n '/^### Headless lanes/,/^### /p' "$ROOT/docs/reference.md")"
assert_ok "docs/reference.md § Headless lanes covers usage, stats and the views" grep -qF "**Usage, stats and status.**" <<<"$sec"
finish

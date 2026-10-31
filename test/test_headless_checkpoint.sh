#!/usr/bin/env bash
# test_headless_checkpoint.sh — #350 / PRD #344: checkpoint and resume for headless lanes. A headless
# claude lane mid-issue is checkpointed by `harness pause --force` (the fake claude's checkpoint turn
# makes the agent's gh calls against a fake gh), the pause waits on the lane's state for that turn and
# then ends the lane; `harness resume` clears the pause and the re-dispatch relaunches the lane in its
# worktree with the resume prompt, carrying on the SAME claude session. A lane whose runner died with
# the box is found by the crash-recovery sweep, its agent-working lock freed, and relaunched the same
# way. Orch sessions and tmux lanes start fresh, as before.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"; source "$ROOT/scripts/drive.sh"
make_env
export RUN_DIR PAUSE_FLAG HARNESS_SESS_PREFIX=hlc HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
export HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme HARNESS_PAUSE_GRACE=30
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
export HARNESS_CLAUDE_BIN="python3 $FAKE" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
LOG="$RUN_DIR/harness.log"; log(){ printf '%s\n' "$*" >> "$LOG"; }

# A fake gh over files in $FAKE_GH_DIR: labels-<n> (one label per line), comments-<n>.json. Enough of
# `issue view|edit|comment|list`, `repo view` and `api user` for pause, prepare_impl and recover; -q runs
# through jq, as gh's does.
export FAKE_GH_DIR="$RUN_DIR/gh"; mkdir -p "$FAKE_GH_DIR" "$RUN_DIR/bin"
cat > "$RUN_DIR/bin/gh" <<'EOF'
#!/usr/bin/env python3
import glob, json, os, subprocess, sys
d = os.environ["FAKE_GH_DIR"]; a = sys.argv[1:]
open(os.path.join(d, "calls"), "a").write("gh " + " ".join(a) + "\n")
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
    if q:
        sys.stdout.write(subprocess.run(["jq", "-r", q], input=json.dumps(obj), capture_output=True, text=True).stdout)
    else:
        print(json.dumps(obj))
cmd = " ".join(a[:2])
if cmd == "api user": out({"login": "fleet-bot"})
elif cmd == "repo view": print("{}")
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
    cs = comments(n) + [{"author": {"login": "fleet-bot"}, "body": body}]
    json.dump(cs, open(os.path.join(d, f"comments-{n}.json"), "w"))
elif cmd == "issue list":
    want = opt("--label"); issues = []
    for f in sorted(glob.glob(os.path.join(d, "labels-*"))):
        n = f.rsplit("-", 1)[1]
        if want is None or want in labels(n):
            issues.append({"number": int(n), "labels": [{"name": l} for l in labels(n)]})
    out(issues)
EOF
chmod +x "$RUN_DIR/bin/gh"; export PATH="$RUN_DIR/bin:$PATH"
gh_labels(){ paste -sd, "$FAKE_GH_DIR/labels-$1" 2>/dev/null; }

# Only the processes this test started: each lane's runner and each fake claude. Never a pattern kill.
our_pids(){ local d; shopt -s nullglob
  for d in "$HARNESS_HOME"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$RUN_DIR"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
    [[ -f "$d/pids" ]] && tr ' ' '\n' < "$d/pids"
  done; shopt -u nullglob; }
cleanup(){ local p; for p in $(our_pids) ${worker:-}; do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
alive(){ kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
calls(){ python3 -c 'import json,sys; [print(json.dumps(json.loads(l)[sys.argv[2]])) for l in open(sys.argv[1])]' \
  "$FAKE_CLAUDE_DIR/calls.jsonl" "$1" 2>/dev/null; }
lane_field(){ python3 "$ROOT/scripts/cli/claude_headless.py" state --lane "$(headless_lane_dir "$1")" --field "$2" 2>/dev/null; }
pane_has(){ sess_capture "$1" 2>/dev/null | grep -qF "$2"; }
turn_idle(){ [[ "$(lane_field "$1" turn)" == "$2" && "$(lane_field "$1" state)" == idle ]]; }
# fake_claude <name> <plan…> — the fake claude's dir for a lane, replaying <plan> (one fixture per turn).
fake_claude(){ export FAKE_CLAUDE_DIR="$RUN_DIR/fake-$1"; shift; mkdir -p "$FAKE_CLAUDE_DIR"
  printf '%s\n' "$@" > "$FAKE_CLAUDE_DIR/plan"
  # The agent's side of a checkpoint: the handoff comment and the label swap the message asks for.
  cat > "$FAKE_CLAUDE_DIR/turn-hook" <<'EOF'
#!/usr/bin/env bash
p="$(cat)"; [[ $p == "HARNESS CHECKPOINT"* ]] || exit 0
f="$(mktemp)"; { grep -o '<!-- harness-handoff [^>]*-->' <<<"$p" | head -1; echo "Handoff: half the tests written."; } > "$f"
eval "$(grep -o 'gh issue comment [0-9]* -R [^ ]*' <<<"$p" | head -1) --body-file $f"
eval "$(grep -o 'gh issue edit [0-9]* -R [^ ]* --remove-label [^ ]* --add-label [^ .]*' <<<"$p" | head -1)"
rm -f "$f"
EOF
  chmod +x "$FAKE_CLAUDE_DIR/turn-hook"; }
# The dispatch context spawn_impl runs in (drive_unit's dynamic scope), its git and checkout stubbed: the
# worktree is already there, as the reaper re-adds it at the same path.
UNIT=main REPO=acme/widget SLUG=acme/widget PROJECT=main DESC=widget CHECKOUT="$PROJECT_ROOT"
ensure_checkout(){ return 0; }; default_branch(){ echo main; }
git(){ case "$*" in *ls-remote*) echo "abc123	refs/heads/issue/${LS_REMOTE:-none}";; esac; return 0; }

echo "== pause --force checkpoints a headless lane mid-issue, waits on its state, ends it =="
S="$(sess_impl main 9)"; WD="$WORKTREES_DIR/main-i9"; mkdir -p "$WD"
printf 'agent-working\n' > "$FAKE_GH_DIR/labels-9"
fake_claude i9 "normal working on it" "normal checkpointed <promise>ISSUE 9 DONE</promise>" "normal resumed" "normal"
touch "$FAKE_CLAUDE_DIR/hold"   # the lane is mid-turn on the issue when the pause comes
LS_REMOTE=none spawn_impl 9 "ISSUE 9 DONE" >/dev/null 2>&1
assert_ok "the headless impl lane is live" sess_live "$S"
uuid="$(sed -n 's/^session_id: //p' "$WD/.claude/ralph-loop.local.md")"
rpid="$(sess_pane_pid "$S")"
assert_ok "…its bootstrap turn running" wait_until 10 test "$(lane_field "$S" state)" = busy
bash "$ROOT/scripts/pause.sh" --force > "$RUN_DIR/pause.out" 2>&1 & ppid=$!
assert_ok "the checkpoint waits behind the running turn" wait_until 10 pane_has "$S" "❯ HARNESS CHECKPOINT"
assert_ok "…and the pause waits on it" alive "$ppid"
rm -f "$FAKE_CLAUDE_DIR/hold"
wait "$ppid"; rc=$?; out="$(cat "$RUN_DIR/pause.out")"
assert_eq "$rc" 0 "pause --force exits 0"
assert_ok "it asked the lane to checkpoint" grep -qF "checkpoint requested: $S (issue #9 on acme/widget)" <<<"$out"
assert_ok "…confirmed the checkpoint" grep -qF "confirmed paused: acme/widget#9" <<<"$out"
assert_ok "…and ended the lane after it" grep -qF "lane ended after its checkpoint: $S" <<<"$out"
assert_ok "…every agent checkpointed" grep -qF "all in-flight agents checkpointed" <<<"$out"
assert_ok "the checkpoint was the lane's next turn" grep -qF '"HARNESS CHECKPOINT' <<<"$(calls prompt | sed -n 2p)"
assert_ok "…resuming the same claude session" grep -qF "\"--resume\", \"$uuid\"" <<<"$(calls argv | sed -n 2p)"
assert_eq "$(gh_labels 9)" "agent-paused" "the checkpoint landed: agent-working → agent-paused"
assert_ok "…with the handoff comment" grep -qF '<!-- harness-handoff issue=9 branch=issue/9 -->' "$FAKE_GH_DIR/comments-9.json"
assert_no "the lane has ended" sess_live "$S"
assert_eq "$(lane_field "$S" state)" ended "…its state reads ended"
assert_no "…and its runner is gone" alive "$rpid"
assert_ok "the fleet is paused" test -f "$PAUSE_FLAG"
assert_eq "$(sess_resume_id "$S" "$WD")" "$uuid" "the ended lane leaves its claude session to resume"
assert_eq "$(sess_resume_id "$S" "$RUN_DIR/elsewhere")" "" "…only in its own worktree"

echo "== harness resume relaunches it with the resume prompt, carrying on the same claude session =="
sleep 600 & worker=$!; echo "$worker" > "$RUN_DIR/worker-1.pid"   # a live pool here: resume does not start one
out="$(bash "$ROOT/scripts/resume.sh" 2>&1)"
assert_ok "resume clears the pause" grep -qF "RESUMED" <<<"$out"
assert_no "…the pause flag is gone" test -f "$PAUSE_FLAG"
{ kill "$worker"; wait "$worker"; } 2>/dev/null; worker=""
: > "$LOG"
LS_REMOTE=9 spawn_impl 9 "ISSUE 9 DONE" >/dev/null 2>&1   # the worker's re-dispatch of the agent-paused issue
assert_ok "the issue is resumed from its checkpoint" grep -qF "resuming paused issue #9" "$LOG"
assert_ok "…its task is the resume prompt" grep -qF "You are RESUMING a previously force-paused implementation of issue #9" "$WD/.harness-task.md"
assert_ok "…carrying the handoff" grep -qF "Handoff: half the tests written." "$WD/.harness-task.md"
assert_ok "the lane is live again" sess_live "$S"
assert_ok "…carrying on the claude session" grep -qF "session $S carries on agent session $uuid" "$LOG"
assert_ok "its first turn ends" wait_until 15 turn_idle "$S" 1
assert_eq "$(calls prompt | sed -n 3p)" "\"$HARNESS_BOOTSTRAP_PROMPT\"" "the resumed lane's first turn is the bootstrap (the resume prompt)"
assert_ok "…resuming the same claude session id" grep -qF "\"--resume\", \"$uuid\"" <<<"$(calls argv | sed -n 3p)"
assert_no "…not a new one" grep -qF -- '"--session-id"' <<<"$(calls argv | sed -n 3p)"
assert_eq "$(sed -n 's/^session_id: //p' "$WD/.claude/ralph-loop.local.md")" "$uuid" "the goal loop's state names that session"
assert_eq "$(claude_last_reply "$WD" "$uuid")" "$uuid:1"$'\n'"resumed" "…so the driven goal loop reads the resumed lane's reply"
sess_kill "$S" >/dev/null; : > "$FAKE_GH_DIR/labels-9"   # its work merges: the issue is done with

echo "== a lane whose runner died with the box: the crash-recovery sweep frees it, the relaunch resumes it =="
S="$(sess_impl main 12)"; WD="$WORKTREES_DIR/main-i12"; mkdir -p "$WD"
printf 'ready-for-agent\n' > "$FAKE_GH_DIR/labels-12"
fake_claude i12 hang "normal back"
LS_REMOTE=none spawn_impl 12 "ISSUE 12 DONE" >/dev/null 2>&1
uuid="$(sed -n 's/^session_id: //p' "$WD/.claude/ralph-loop.local.md")"
assert_ok "the lane's turn runs" wait_until 10 test -s "$FAKE_CLAUDE_DIR/pids"
assert_eq "$(gh_labels 12)" "ready-for-agent,agent-working" "the issue is claimed"
fpid=; gpid=; read -r fpid gpid < "$FAKE_CLAUDE_DIR/pids"
rpid="$(sess_pane_pid "$S")"
{ kill -KILL "$rpid" "$fpid" "$gpid"; wait "$rpid"; } 2>/dev/null   # the box goes down: runner and turn alike
assert_no "the lane is not live" sess_live "$S"
assert_eq "$(lane_field "$S" state)" busy "…its state still reads the turn it died in"
freed="$(recover_orphan_working 2>"$RUN_DIR/recover.err")"
assert_eq "$freed" 1 "the crash-recovery sweep frees the orphaned issue"
assert_ok "…naming it" grep -qF "freed acme/widget#12" "$RUN_DIR/recover.err"
assert_eq "$(gh_labels 12)" "ready-for-agent" "…its agent-working lock is not stranded"
: > "$LOG"
LS_REMOTE=none spawn_impl 12 "ISSUE 12 DONE" >/dev/null 2>&1   # the pool re-claims it
assert_ok "the relaunched lane is live" sess_live "$S"
assert_ok "…in its worktree" test "$(cat "$RUN_DIR/$S.wd")" = "$WD"
assert_ok "…carrying on the dead lane's claude session" grep -qF "session $S carries on agent session $uuid" "$LOG"
assert_ok "its first turn ends" wait_until 15 turn_idle "$S" 1
assert_ok "…resuming that session id" grep -qF "\"--resume\", \"$uuid\"" <<<"$(calls argv | sed -n 2p)"
assert_eq "$(claude_last_reply "$WD" "$uuid")" "$uuid:1"$'\n'"back" "…and the goal loop reads its reply"
sess_kill "$S" >/dev/null

echo "== orch sessions and tmux lanes start fresh =="
S="$(sess_orch main 3)"; WD="$RUN_DIR/orch-p3"; mkdir -p "$WD"; echo task > "$WD/.harness-task.md"
fake_claude p3 normal normal
GOAL=PRD:3 launch_agent "$S" "$WD" >/dev/null
old="$(sed -n 's/^session_id: //p' "$WD/.claude/ralph-loop.local.md")"
wait_until 15 turn_idle "$S" 1; sess_kill "$S" >/dev/null
assert_eq "$(sess_resume_id "$S" "$WD")" "$old" "an ended orch lane has a session behind it"
GOAL=PRD:3 launch_agent "$S" "$WD" >/dev/null
new="$(sed -n 's/^session_id: //p' "$WD/.claude/ralph-loop.local.md")"
assert_no "…but its relaunch is a new session" test "$new" = "$old"
assert_ok "…started fresh" wait_until 15 bash -c "grep -qF '\"--session-id\", \"$new\"' <<<\"\$(python3 -c 'import json,sys; [print(json.dumps(json.loads(l)[\"argv\"])) for l in open(sys.argv[1])]' '$FAKE_CLAUDE_DIR/calls.jsonl')\""
sess_kill "$S" >/dev/null
assert_eq "$(HARNESS_SESSION_BACKEND=tmux sess_resume_id "$(sess_impl main 9)" "$WORKTREES_DIR/main-i9")" "" "a tmux lane keeps no session to resume"
assert_eq "$(HARNESS_SESSION_BACKEND=tmux sess_turns "$(sess_impl main 9)")" "" "…nor counts its turns"
assert_no "…so pause never waits on one's state" env HARNESS_SESSION_BACKEND=tmux bash -c "source '$ROOT/scripts/session/dispatch.sh'; sess_turn_ended x 0"

echo "== docs =="
sec="$(sed -n '/^### Headless lanes/,/^### /p' "$ROOT/docs/reference.md")"
assert_ok "docs/reference.md § Headless lanes covers checkpoint and resume" grep -qF "**Checkpoint and resume.**" <<<"$sec"
finish

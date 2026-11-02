#!/usr/bin/env bash
# test_lane_model.sh — #374: a claude lane runs the model its launch event names.
#
# hardcore-gacha-2's implementer lanes logged `model=sonnet` (their worktree hook's
# .claude/settings.local.json pin) while every transcript turn was Opus. Claude Code reads a linked git
# worktree's local settings together with its MAIN checkout's .claude/settings.local.json, and the main
# checkout's wins: the same hook pinned `opus` there for the orchestration sessions, so every worktree
# lane ran Opus whatever its own file said. Only `--model` on the launch line beats both (verified
# against claude 2.1.316 on the host: worktree local=sonnet + main local=opus → Opus; + `--model
# sonnet` → Sonnet; the main checkout's tracked settings.json does not leak).
#
# The fixture lane: a main checkout pinned to opus, a linked worktree pinned to sonnet, launched through
# launch_agent, then the launch line it typed run against a fake claude that picks its model the way
# the real one does and records it as its transcript's model. The launch event and the transcript must
# agree, and both must be the worktree's pin.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/scripts/lib.sh"
source "$HERE/helpers.sh"
make_env

# A fake claude: --model on argv, else the main checkout's .claude/settings.local.json when cwd is a
# linked worktree, else cwd's .claude/settings.local.json, else its settings.json, else `default`.
# It writes the model it ran as one transcript turn to $FAKE_TRANSCRIPT.
FAKE="$RUN_DIR/fake-claude"
cat > "$FAKE" <<'PY'
import json, os, subprocess, sys
def pin(path):
    try:
        return (json.load(open(path)) or {}).get("model") or ""
    except (OSError, ValueError):
        return ""
model = ""
args = sys.argv[1:]
for i, a in enumerate(args):
    if a == "--model" and i + 1 < len(args):
        model = args[i + 1]
    elif a.startswith("--model="):
        model = a.split("=", 1)[1]
if not model:
    git = lambda *a: subprocess.run(["git", *a], capture_output=True, text=True).stdout.strip()
    common, own = git("rev-parse", "--path-format=absolute", "--git-common-dir"), git("rev-parse", "--path-format=absolute", "--git-dir")
    if common and common != own:
        model = pin(os.path.join(os.path.dirname(common), ".claude", "settings.local.json"))
model = model or pin(".claude/settings.local.json") or pin(".claude/settings.json") or "default"
with open(os.environ["FAKE_TRANSCRIPT"], "a") as f:
    f.write(json.dumps({"type": "assistant", "message": {"model": model}}) + "\n")
PY
export HARNESS_CLAUDE_BIN="python3 $FAKE" FAKE_TRANSCRIPT="$RUN_DIR/transcript.jsonl"
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"
unset HARNESS_CLAUDE_FLAGS CLAUDE_FLAGS
HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions --effort high"

MAIN="$CHECKOUTS_DIR/game"
git init -q "$MAIN"; git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$MAIN/.claude"; printf '{\n  "model": "opus"\n}\n' > "$MAIN/.claude/settings.local.json"   # the orch checkout's pin

SENT="$RUN_DIR/sent"
tmux(){ case "$1" in has-session) return 1 ;; send-keys) shift; [[ "$1" == -t ]] && shift 2; echo "${*% Enter}" >> "$SENT" ;; esac; return 0; }
sleep(){ :; }
# lane <name> — a fresh linked worktree of $MAIN at $WORKTREES_DIR/<name>.
lane(){ local wd="$WORKTREES_DIR/$1"; git -C "$MAIN" worktree add -q -b "b-$1" "$wd" 2>/dev/null; mkdir -p "$wd/.claude"; echo task > "$wd/.harness-task.md"; echo "$wd"; }
# run_lane <sess> <wd> — launch_agent it, then run the line it typed in <wd>: the fake's transcript model.
# The line stays in $SENT (sent_line reads it back: run_lane runs in a command substitution).
run_lane(){ : > "$SENT"; : > "$FAKE_TRANSCRIPT"
  ( launch_agent "$1" "$2" ) >/dev/null 2>&1
  local line; line="$(grep -m1 -F 'exec ' "$SENT")"
  ( cd "$2" && eval "${line#exec }" ) >/dev/null 2>&1
  python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["message"]["model"])' "$FAKE_TRANSCRIPT" 2>/dev/null; }
sent_line(){ grep -m1 -F 'exec ' "$SENT"; }
event_model(){ python3 -c 'import json,sys
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print([e for e in ev if e.get("event") == "launch" and e.get("tmux") == sys.argv[2]][-1].get("model", ""))' "$HARNESS_EVENTS_FILE" "$1"; }

echo "=== 1: a worktree's settings.local.json pin is the model the lane runs ==="
WT="$(lane neuro-i848)"
printf '{\n  "model": "sonnet"\n}\n' > "$WT/.claude/settings.local.json"   # the old hg2/bangwa hook's pin
ran="$(run_lane hz-lm-pin "$WT")"
assert_eq "$(event_model hz-lm-pin)" "sonnet" "the launch event names the worktree's pin"
assert_eq "$ran" "sonnet" "the lane's transcript turn runs the worktree's pin, not the main checkout's opus"
assert_eq "$ran" "$(event_model hz-lm-pin)" "the launch event and the transcript agree"
assert_ok "the pin reaches the launch line as --model" grep -qE -- '--model sonnet( |$)' <<<"$(sent_line)"
assert_eq "$(grep -oE -- '--model' <<<"$(sent_line)" | wc -l)" "1" "--model is given once"

echo "=== 2: .harness-lane wins over the settings.local.json pin ==="
WT2="$(lane neuro-i849)"
printf '{"model": "sonnet"}' > "$WT2/.claude/settings.local.json"
printf 'model=haiku\n' > "$WT2/.harness-lane"
ran="$(run_lane hz-lm-lane "$WT2")"
assert_eq "$ran" "haiku" "the lane's .harness-lane model runs"
assert_eq "$(event_model hz-lm-lane)" "haiku" "…and the launch event names it"

echo "=== 3: the worktree's pin replaces a --model in the configured flags ==="
WT3="$(lane neuro-i850)"
printf '{"model": "sonnet"}' > "$WT3/.claude/settings.local.json"
ran="$(HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions --model opus --effort high" run_lane hz-lm-flags "$WT3")"
assert_eq "$ran" "sonnet" "a lane's own pin beats the fleet-wide --model"
assert_eq "$(grep -oE -- '--model' <<<"$(sent_line)" | wc -l)" "1" "--model is given once"

echo "=== 4: no pin in the worktree — the event names what the main checkout's pin runs ==="
WT4="$(lane neuro-i851)"
ran="$(run_lane hz-lm-none "$WT4")"
assert_eq "$ran" "opus" "fixture: an unpinned worktree runs the main checkout's local pin"
assert_eq "$(event_model hz-lm-none)" "opus" "the launch event names it too"
assert_no "no --model is added when nothing pins one" grep -qF -- '--model' <<<"$(sent_line)"

echo "=== 5: a headless lane carries the pin in its flags too ==="
argv="$(cli_with claude claude_headless "$WT" uuid-1 "" "")"
assert_ok "the headless runner's flags carry --model sonnet" grep -qE -- '^--flags=.*--model sonnet' <<<"$argv"
unset -f tmux sleep

finish

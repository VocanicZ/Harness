#!/usr/bin/env bash
# openclaw-loop.sh — the program an `openclaw` lane's pane runs (#264): a one-line prompt that runs
# each message it reads as one headless `openclaw agent exec` turn in the worktree. OpenClaw's TUI
# works in its own agent workspace, not the pane's cwd; `agent exec --cwd` is its coding-automation
# entry point (docs/cli-capabilities.md § `openclaw`). Not an adapter: dispatch.sh skips *-loop.sh.
#
#   openclaw-loop.sh --bin <command line> --cwd <wd> --run <id> [--config <lane config>]
#                    [--model <m>] [--thinking <e>] [--timeout <s>] [<first message>]
#
# The first message (the bootstrap) is one turn; then each line typed at the `harness-openclaw ❯`
# prompt (cli_send: a goal-loop re-prompt, a nudge, a checkpoint) is the next. A line typed while a
# turn runs waits in the terminal until that turn ends. Each turn's message goes to `agent exec` in a
# file (--message-file), never in argv. Each turn's JSON envelope is appended, one line, to
# <wd>/.harness-openclaw/runs/<id>.jsonl: the session's transcript (cli_transcripts), its usage
# (cli_usage) and the reply the Harness-driven goal loop reads (cli_last_reply). The screen is
# redrawn at each turn's start and end, so it shows the busy line or the last reply and its error
# (an `agent exec` failure, e.g. OpenClaw's `⚠️ …` rate-limit copy) above the prompt, never both.
set -uo pipefail
bin=openclaw wd= run= config= model= thinking= timeout=14400
while (( $# )); do
  case "$1" in
    --bin) bin="$2"; shift 2;;
    --cwd) wd="$2"; shift 2;;
    --run) run="$2"; shift 2;;
    --config) config="$2"; shift 2;;
    --model) model="$2"; shift 2;;
    --thinking) thinking="$2"; shift 2;;
    --timeout) timeout="$2"; shift 2;;
    --) shift; break;;
    *) break;;
  esac
done
[[ -n $wd && -n $run ]] || { echo "usage: openclaw-loop.sh --bin <cmd> --cwd <wd> --run <id> [--model m] [--thinking e] [msg]" >&2; exit 2; }
st="$wd/.harness-openclaw"; runs="$st/runs/$run.jsonl"
mkdir -p "$st/runs" || exit 1
read -ra cmd <<<"$bin"

# The pane's hangup (tmux kill-session) reaches this loop, not the turn: `agent exec` and the CLI
# backend it starts (claude-cli runs `claude`, which runs the turn's commands) outlive it. So a hangup
# or TERM stops the running turn's whole process tree first.
tree(){ ps -e -o pid=,ppid= | awk -v r="$1" '{ up[$1] = $2 } END { s[r] = 1
  do { n = 0; for (k in up) if (!(k in s) && (up[k] in s)) { s[k] = 1; n++ } } while (n)
  for (k in s) print k }'; }
stop_turn(){ local p; p="$(cat "$st/running" 2>/dev/null)"; [[ $p =~ ^[0-9]+$ ]] || return 0
  kill $(tree "$p") 2>/dev/null; rm -f "$st/running"; }
trap 'stop_turn; exit 129' HUP
trap 'stop_turn; exit 143' TERM

# turn <message> — one `agent exec` turn. While it runs, <state>/running holds its pid.
turn(){ local pid rc
  printf '\e[H\e[2J\e[3J'
  printf 'harness-openclaw: busy · %s · started %s\n' "${model:-default model}" "$(date +%H:%M:%S)"
  printf '%s\n' "$1" > "$st/message"
  "${cmd[@]}" agent exec ${config:+--config "$config"} --cwd "$wd" --state-dir "$st" ${model:+--model "$model"} ${thinking:+--thinking "$thinking"} \
    --timeout "$timeout" --message-file "$st/message" --json </dev/null >"$st/last.json" 2>"$st/last.err" &
  pid=$!; echo "$pid" > "$st/running"
  wait "$pid"; rc=$?
  python3 - "$st/last.json" "$st/last.err" "$runs" "$rc" "$1" > "$st/last.txt" <<'PY'
import json, re, sys, time
out, err, runs, rc, msg = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
try:
    env = json.loads(open(out).read())
    if not isinstance(env, dict):
        raise ValueError(env)
except Exception:
    tail = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in open(err, errors="replace").read().splitlines() if l.strip()]
    env = {"ok": False, "status": "error",
           "error": {"message": tail[-1] if tail else f"openclaw agent exec exited {rc} with no JSON envelope", "kind": "harness"}}
env["harness"] = {"exit": rc, "ended": int(time.time()), "message": msg.splitlines()[0][:200] if msg else ""}
with open(runs, "a") as f:
    f.write(json.dumps(env, separators=(",", ":")) + "\n")
final = (env.get("final") or "").rstrip()
if final:
    print(final)
e = env.get("error") or {}
if not env.get("ok") and (e.get("message") or env.get("status") != "ok"):
    print(f"harness-openclaw: error: {(e.get('message') or env.get('status') or 'failed').splitlines()[0]}")
PY
  rm -f "$st/running"
  printf '\e[H\e[2J\e[3J'
  tail -n 15 "$st/last.txt"; }

msg="${1:-}"
while :; do
  [[ -n ${msg//[[:space:]]/} ]] && turn "$msg"
  printf 'harness-openclaw ❯ '
  IFS= read -r msg || { echo; exit 0; }
done

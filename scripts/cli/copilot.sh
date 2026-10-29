# copilot.sh — the GitHub Copilot CLI adapter (#259). Facts: docs/cli-capabilities.md § `copilot`;
# panes: test/fixtures/cli/copilot/. Loaded by dispatch.sh; defines copilot_<fn> for the cli_* interface.

: "${HARNESS_COPILOT_BIN:=copilot}"
: "${HARNESS_COPILOT_FLAGS:=--yolo --no-ask-user --no-auto-update}"
export HARNESS_COPILOT_BIN HARNESS_COPILOT_FLAGS

_copilot_home(){ echo "${COPILOT_HOME:-$HOME/.copilot}"; }

copilot_bin(){ echo "${HARNESS_COPILOT_BIN:-copilot}"; }
# _copilot_flags <flags> <model> <effort> — the configured flags with --model and --effort (alias
# --reasoning-effort) replaced by the lane's own when it names one, so the line never carries either
# twice. Copilot spells both `--flag=<value>`.
_copilot_flags(){ local f=" $1 "
  [[ -n "$2" ]] && f="$(sed -E 's/ --model[= ][^ ]+//g' <<<"$f") --model=$2"
  [[ -n "$3" ]] && f="$(sed -E 's/ --(reasoning-)?effort[= ][^ ]+//g' <<<"$f") --effort=$3"
  f="$(tr -s ' ' <<<"$f")"; f="${f# }"; echo "${f% }"; }
# The caller sets the session id (--session-id=<uuid> creates the session under that id). -i runs the
# bootstrap as the first prompt of an interactive session. --yolo allows every tool, path and URL;
# --no-ask-user takes away the tool that stops a turn on a question; --no-auto-update keeps a lane
# from swapping the CLI under a running fleet. COPILOT_HOME rides the line only when the operator set
# it: the pane's shell does not inherit this process's environment.
copilot_launch(){ local wd="$1" uuid="$2" model="$3" effort="$4" home=""
  [[ -n "${COPILOT_HOME:-}" ]] && home="COPILOT_HOME=$(printf '%q' "$COPILOT_HOME") "
  echo "${home}exec $(copilot_bin) ${uuid:+--session-id=$uuid }$(_copilot_flags "${HARNESS_COPILOT_FLAGS:-}" "$model" "$effort") -i \"$HARNESS_BOOTSTRAP_PROMPT\""; }
# --model, and --effort or its alias --reasoning-effort.
copilot_model_effort(){ printf '%s\t%s\n' "$(_cli_line_opt "$1" '--model[= ]')" "$(_cli_line_opt "$1" '--(reasoning-)?effort[= ]')"; }

# --- panes (test/fixtures/cli/copilot/*.txt) ----------------------------------------------------
# The input box is `❯` at column 0 between two rules, drawn even while a turn runs (busy.txt). Copilot
# echoes each submitted prompt one column in (` ❯ …`), so the echo never matches. The trust dialog's
# and the model picker's `❯` are inside their boxes (trust.txt), and copilot_dialog_re names them.
copilot_idle_re(){ echo '^❯( |$)'; }
copilot_dialog_re(){ echo 'Do you trust the files in this folder\?|Rate limit hit\. Switch to the auto model\?|enter to select · esc to cancel'; }
# A turn shows `<pulse> <label> · <bytes> esc esc interrupt` on the footer row (busy.txt, busy-start.txt;
# the label is `Working`, the intent, or `Waiting for background shells`), and `esc again to interrupt`
# after one Escape. The idle footer reads `← open sidebar · …` instead (idle.txt).
copilot_busy_re(){ echo 'esc (esc|again to) interrupt'; }
# The account's limits end the turn with an error cell (`✗ <message>`, the way the CLI draws a
# session.error: model-error.txt). Strings from the 1.0.105 runtime (README.md, limit.txt).
copilot_limit_re(){ echo "You've hit (your|the) (session )?rate limit|You've reached your weekly rate limit|You've run out of your included AI credits|You've reached the spending limit for this session|You've reached your additional usage limit"; }
# A rate limit on a chosen model raises a menu instead: switch to the auto model, or stay. Enter (the
# watchdog's pick) takes its first choice, `Switch to auto for this request`: the turn goes on.
copilot_limit_menu_re(){ echo 'Rate limit hit\. Switch to the auto model\?'; }
# What reaches the pane once Copilot's own retries give up (transient.txt, from the 1.0.105 runtime).
copilot_transient_re(){ echo 'Failed to get response from the AI model|No response was returned\. Send your message again to retry'; }
copilot_loop(){ echo driven; }
# Two Escapes end a turn with `● Operation cancelled by user` (interrupted.txt). Text typed while a
# turn runs is delivered into that turn, never queued in the input box (steer.txt), so #207's
# interrupt never has a queued nudge to free.
copilot_interrupted_re(){ echo 'Operation cancelled by user'; }

# --- workspace trust: trustedFolders in config.json ---------------------------------------------
# config.json is JSON behind `//` comment lines, rewritten by the CLI itself (trust dialog's "remember
# this folder", its own first-launch keys). Edited under the lock file the CLI keeps beside it; the
# comment header is kept, every other key is re-serialized unchanged.
copilot_trust(){
  local dir="$1" cfg lockfd; cfg="$(_copilot_home)/config.json"
  mkdir -p "$(dirname "$cfg")"
  exec {lockfd}>"$cfg.trusted-folders.lock"; flock "$lockfd"
  CFG="$cfg" DIR="$dir" python3 - <<'PY'
import json, os, tempfile
cfg, d = os.environ["CFG"], os.environ["DIR"]
try:
    lines = open(cfg).read().splitlines()
except FileNotFoundError:
    lines = ["// User settings belong in settings.json.", "// This file is managed automatically."]
head = [l for l in lines if l.lstrip().startswith("//")]
body = "\n".join(l for l in lines if not l.lstrip().startswith("//")).strip()
try:
    data = json.loads(body) if body else {}
except ValueError:
    raise SystemExit(f"copilot_trust: {cfg} is not valid JSON; left unchanged")
folders = data.setdefault("trustedFolders", [])
if d in folders:
    raise SystemExit(0)
folders.append(d)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(cfg)), prefix=".config.json.harness.")
try:
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(head + [json.dumps(data, indent=2)]) + "\n")
    os.replace(tmp, cfg)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
PY
  flock -u "$lockfd"; exec {lockfd}>&-; }
copilot_trusted(){ CFG="$(_copilot_home)/config.json" DIR="$1" python3 -c 'import json, os, sys
body = "\n".join(l for l in open(os.environ["CFG"]) if not l.lstrip().startswith("//"))
sys.exit(0 if os.environ["DIR"] in (json.loads(body).get("trustedFolders") or []) else 1)' 2>/dev/null; }

# --- permission bypass ----------------------------------------------------------------------------
# --yolo is the session's policy, and sub-agents run under it: seen on the host (bypass-subagent.jsonl:
# a sub-agent ran a shell command with no prompt). Nothing is written per worktree; the check is that
# the flag reaches the launch line.
copilot_bypass(){ :; }
copilot_bypassed(){ grep -qE -- '(^| )(--yolo|--allow-all)( |$)' <<<"$(copilot_launch "$1" "" "" "")"; }

# Personal skills are read from $COPILOT_HOME/skills (or ~/.agents/skills), never ~/.claude/skills.
copilot_user_skills_dir(){ echo "${HARNESS_COPILOT_USER_SKILLS:-$(_copilot_home)/skills}"; }

# --- transcripts + usage --------------------------------------------------------------------------
# One JSONL of session events per session, sub-agents' included: session-state/<id>/events.jsonl.
copilot_transcripts(){ local f; [[ -n "$2" ]] || return 0; f="$(_copilot_home)/session-state/$2/events.jsonl"
  [[ -f "$f" ]] && echo "$f"; return 0; }
# Each model call writes a session.usage_record {usage: {model, inputTokens, outputTokens,
# cacheReadTokens, cacheWriteTokens}} (transcript.jsonl). inputTokens counts the cache reads and
# writes too (session.shutdown's tokenDetails split them out): they are taken back out of it.
copilot_usage(){ (( $# )) || return 0; python3 - "$@" <<'PY'
import json, sys
tot = {}
for path in sys.argv[1:]:
    with open(path) as f:
        for line in f:
            if '"session.usage_record"' not in line:
                continue
            try:
                d = json.loads(line)
                if d.get("type") != "session.usage_record":
                    continue
                u = d["data"]["usage"]
                cr, cw = int(u.get("cacheReadTokens") or 0), int(u.get("cacheWriteTokens") or 0)
                t = tot.setdefault(u.get("model") or "?", [0, 0, 0, 0])
                t[0] += int(u.get("inputTokens") or 0) - cr - cw
                t[1] += int(u.get("outputTokens") or 0)
                t[2] += cr
                t[3] += cw
            except (ValueError, TypeError, KeyError, AttributeError):
                continue
for m, t in sorted(tot.items()):
    print(m, *t, sep="\t")
PY
}
# Usage windows (#194): every model.model_call_success carries the account's quotaSnapshots {<quota>:
# {entitlementRequests, isUnlimitedEntitlement, remainingPercentage, resetDate}} (usage-windows.jsonl).
# The newest session on the host has the latest reading. `completions` is the editors' code-completion
# quota, which the CLI never spends; an unlimited quota or one with no entitlement is no window.
copilot_limit_usage(){ H="$(_copilot_home)" python3 - <<'PY'
import glob, json, os, sys, time
from datetime import datetime
h, now = os.environ["H"], time.time()
files = sorted(glob.glob(os.path.join(h, "session-state", "*", "events.jsonl")), key=os.path.getmtime, reverse=True)
for f in files[:20]:
    q = None
    try:
        with open(f) as fh:
            for line in fh:
                if '"quotaSnapshots"' not in line:
                    continue
                d = json.loads(line)
                if d.get("type") == "model.model_call_success" and (d.get("data") or {}).get("quotaSnapshots"):
                    q = d["data"]["quotaSnapshots"]
    except (OSError, ValueError):
        continue
    if not q:
        continue
    out = []
    for name, s in sorted(q.items()):
        try:
            if name == "completions" or s.get("isUnlimitedEntitlement") or not s.get("entitlementRequests"):
                continue
            reset = int(datetime.fromisoformat(s["resetDate"].replace("Z", "+00:00")).timestamp())
            if reset <= now:
                continue
            out.append(f"copilot\t{name}\t{round(100 - float(s['remainingPercentage']), 1)}\t{reset}")
        except (TypeError, ValueError, KeyError, AttributeError):
            continue
    print("\n".join(out))
    sys.exit(0 if out else 1)
sys.exit(1)
PY
}

# --- the Harness-driven goal loop (lib.sh goal_loop_tick) -----------------------------------------
# copilot_last_reply <wd> <session id> — the id of the last prompt the session was given, then the
# text the agent answered it with: the last non-empty assistant.message since that user.message (a
# promise the agent only announced mid-run is no answer). rc 1 while that
# prompt's turn is still running: no assistant.turn_end after it yet, or a turn_start after the last
# turn_end (a turn is one model call; a prompt runs several, transcript.jsonl). A sub-agent writes its
# own prompt, turns and replies into the same file, each event tagged with its agentId
# (bypass-subagent.jsonl): those are not the session's.
copilot_last_reply(){ local f; f="$(copilot_transcripts "$1" "$2")"; [[ -n "$f" ]] || return 1
  python3 - "$f" <<'PY'
import json, sys
pid, reply, ended = None, [], False
for line in open(sys.argv[1]):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    t, x = d.get("type"), d.get("data") or {}
    if d.get("agentId"):
        continue
    if t == "user.message":
        pid, reply, ended = d.get("id") or x.get("messageId"), [], False
    elif pid is None:
        continue
    elif t == "assistant.message" and x.get("content"):
        reply = [x["content"]]
    elif t == "assistant.turn_start":
        ended = False
    elif t in ("assistant.turn_end", "abort"):
        ended = True
if pid is None or not ended:
    sys.exit(1)
print(pid)
print("\n".join(reply))
PY
}

# --- prerequisites ------------------------------------------------------------------------------
# The binary only: the goal loop is Harness's own (cli_loop driven), so nothing is installed into
# Copilot. It signs in with COPILOT_GITHUB_TOKEN / GH_TOKEN / GITHUB_TOKEN, a stored `copilot login`,
# or the GitHub CLI's own login.
copilot_prereqs(){ local bin; bin="$(copilot_bin)"
  _cli_bin_ensure copilot "$bin" "${1:-}" 'npm install -g @github/copilot' || return 1
  echo "ok      copilot binary ($bin)"; }

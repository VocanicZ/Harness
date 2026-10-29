# openclaw.sh — the OpenClaw adapter (#264). Facts: docs/cli-capabilities.md § `openclaw`; panes:
# test/fixtures/cli/openclaw/. Loaded by dispatch.sh; defines openclaw_<fn> for the cli_* interface.
#
# OpenClaw's TUI works in its agent workspace, not the shell's cwd; its headless `agent exec --cwd`
# is the entry point built for coding automation. So a lane's pane runs Harness's own one-line
# prompt, openclaw-loop.sh, which runs each message it reads as one `agent exec` turn in the
# worktree. Its idle and busy lines are Harness's own; cli_send types the next message at it, which
# is how the Harness-driven goal loop (cli_loop driven), a nudge or a checkpoint reaches the agent.
# A lane's run state lives in <wd>/.harness-openclaw (kept out of the lane's commits): the
# `--state-dir` each turn runs on, the lane config, and the envelope of every turn.

: "${HARNESS_OPENCLAW_BIN:=openclaw}"
: "${HARNESS_OPENCLAW_TIMEOUT:=14400}"
export HARNESS_OPENCLAW_BIN HARNESS_OPENCLAW_TIMEOUT

openclaw_bin(){ echo "${HARNESS_OPENCLAW_BIN:-openclaw}"; }
_openclaw_dir(){ echo "$1/.harness-openclaw"; }
# The operator's config, which every lane config includes (OpenClaw's own default path).
_openclaw_op_config(){ echo "${HARNESS_OPENCLAW_CONFIG:-${OPENCLAW_CONFIG_PATH:-${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/openclaw.json}}"; }
_openclaw_cfg(){ echo "$(_openclaw_dir "$1")/openclaw.json"; }
# _openclaw_runs <wd> <session id> — the session's transcript: one `agent exec` envelope per turn.
_openclaw_runs(){ echo "$(_openclaw_dir "$1")/runs/$2.jsonl"; }

# _openclaw_config <wd> — (re)write the lane config: the operator's config ($include; its model,
# auth and plugins) with, over it (sibling keys override an include):
# - tools.exec.mode full, so no exec in the lane waits on an approval whatever the operator's own
#   policy is (bypass.txt; an operator config that sets tools.exec.security or .ask is refused beside
#   it, `mode cannot be combined with security or ask`: set the operator's policy as `mode`);
# - skills.load.extraDirs: the user skills Harness installs (HARNESS_USER_SKILLS, ~/.claude/skills)
#   and ~/.agents/skills, which OpenClaw reads only on its default state dir (skill.txt), after the
#   operator's own extra dirs when its config is plain JSON. OpenClaw reads a dir with a SKILL.md of
#   its own as that one skill, so such a dir's skills are listed one by one.
_openclaw_config(){ local d; d="$(_openclaw_dir "$1")"
  mkdir -p "$d/runs" 2>/dev/null || return 1
  git_exclude "$1" "/.harness-openclaw/" 2>/dev/null
  OP="$(_openclaw_op_config)" CFG="$(_openclaw_cfg "$1")" SKILLS="${HARNESS_USER_SKILLS:-$HOME/.claude/skills}" \
    AGENTS="${HARNESS_OPENCLAW_AGENTS_SKILLS:-$HOME/.agents/skills}" python3 -c 'import json, os
op, cfg = os.environ["OP"], os.environ["CFG"]
c, dirs = {}, []
if os.path.isfile(op):
    c["$include"] = op
    try:
        dirs = list(json.load(open(op))["skills"]["load"]["extraDirs"])
    except Exception:
        pass
for x in (os.environ["SKILLS"], os.environ["AGENTS"]):
    if not os.path.isdir(x):
        continue
    if os.path.isfile(os.path.join(x, "SKILL.md")):
        sub = sorted(os.path.join(x, n) for n in os.listdir(x) if os.path.isfile(os.path.join(x, n, "SKILL.md")))
    else:
        sub = [x]
    dirs += [y for y in sub if y not in dirs]
c["tools"] = {"exec": {"mode": "full"}}
if dirs:
    c["skills"] = {"load": {"extraDirs": dirs}}
tmp = cfg + ".tmp"
json.dump(c, open(tmp, "w"), indent=2)
os.replace(tmp, cfg)'; }

# The pane runs the loop (exec: the pane ends with it). OPENCLAW_INCLUDE_ROOTS lets the lane config,
# outside the operator's config dir, include it. The bootstrap is the first message; the task stays
# in its file. An empty model or effort is the operator config's default.
openclaw_launch(){ _openclaw_config "$1"; _openclaw_line "$@"; }
_openclaw_line(){ local wd="$1" uuid="$2" model="$3" effort="$4" op; op="$(_openclaw_op_config)"
  printf 'exec env OPENCLAW_INCLUDE_ROOTS=%q bash %q --bin %q --cwd %q --run %s --config %q%s%s --timeout %s "%s"\n' \
    "$(dirname "$op")" "$CLI_DIR/openclaw-loop.sh" "$(openclaw_bin)" "$wd" "$uuid" "$(_openclaw_cfg "$wd")" \
    "${model:+ --model $model}" "${effort:+ --thinking $effort}" "${HARNESS_OPENCLAW_TIMEOUT:-14400}" "$HARNESS_BOOTSTRAP_PROMPT"; }

# The loop's --model and --thinking (the effort).
openclaw_model_effort(){ printf '%s\t%s\n' "$(_cli_line_opt "$1" '--model[= ]')" "$(_cli_line_opt "$1" '--thinking[= ]')"; }

# The session id is the launch's own (the loop's --run): each `agent exec` turn is its own OpenClaw
# session, and the lane's transcript gathers them under this id. openclaw_session_id keeps the
# dispatch default (echo <uuid>).

# --- panes (test/fixtures/cli/openclaw/*.txt) ---------------------------------------------------
# openclaw-loop.sh redraws the screen at each turn's start (the busy line) and end (the reply, its
# error line, the prompt), so the two never share a pane. What is typed at the prompt follows it.
openclaw_idle_re(){ echo '^harness-openclaw ❯ ?'; }
openclaw_busy_re(){ echo '^harness-openclaw: busy · '; }
# A failed turn's error is printed as `harness-openclaw: error: <envelope error.message>`. A provider's
# 429 ends the turn with its own message when it names a usage limit (limit.txt: `⚠️ You have reached
# your usage limit for this period.; Retry-After: 7200 seconds`), else with OpenClaw's copy once its
# retries give up (limit-short-break.txt: `⚠️ The AI service needs a short break.`); a billing failure
# with OpenClaw's billing copy (its assistant-request-failure-copy).
openclaw_limit_re(){ echo '^harness-openclaw: error: ⚠️ (The AI service needs a short break|The AI service reported a billing problem|.*([Uu]sage limit|[Qq]uota))'; }
# A provider's 5xx once OpenClaw's retries give up (transient.txt: a 503, `The AI service is
# temporarily overloaded.`), and OpenClaw's overloaded / server-error copy.
openclaw_transient_re(){ echo '^harness-openclaw: error: (⚠️ )?(The AI service is (temporarily overloaded|busy|having trouble)|Selected model is at capacity|Rate-limit recovery stopped)'; }
openclaw_loop(){ echo driven; }

# --- workspace trust: none (agent exec has no trust gate; --cwd scopes its file tools) ----------
openclaw_trust(){ :; }
openclaw_trusted(){ :; }

# --- permission bypass: the lane config's tools.exec.mode full, which the launch runs on ------------
openclaw_bypass(){ _openclaw_config "$1"; }
openclaw_bypassed(){ local cfg; cfg="$(_openclaw_cfg "$1")"
  grep -qF -- "--config $(printf '%q' "$cfg")" <<<"$(_openclaw_line "$1" x "" "")" &&
    python3 -c 'import json, sys
sys.exit(0 if json.load(open(sys.argv[1]))["tools"]["exec"]["mode"] == "full" else 1)' "$cfg" 2>/dev/null; }

# OpenClaw loads a skill through its skill tool, by name (skill.txt); the lane's skill dirs are in
# its config (_openclaw_config).
openclaw_skill(){ echo "$1"; }

# --- sub-agents: a fresh `agent exec` session (#314) ----------------------------------------------
# sessions_spawn fails in an `agent exec` turn (bypass-subagent.txt), so a prompt's sub-agent is its
# own `agent exec` run instead: the lane config, a cwd of <dir>, a new empty --state-dir (the lane's
# is held by its running turn), the brief from a file. A fresh session that sees none of the lane's
# context; its reply is the command's stdout (subagent-critic.txt).
openclaw_subagent(){ local wd="$1" dir="$2" brief="$3"
  printf 'this CLI cannot spawn sub-agents (sessions_spawn fails in an `agent exec` turn), so run it as its own fresh OpenClaw session: write its whole brief to `%s`, then run `%s`. Its answer is that command'"'"'s output.\n' \
    "$brief" "$(_openclaw_subagent_cmd "$wd" "$dir" "$brief")"; }
_openclaw_subagent_cmd(){ printf 'env OPENCLAW_INCLUDE_ROOTS=%q %s agent exec --config %q --cwd %q --state-dir "$(mktemp -d)" --timeout %s --message-file %q' \
    "$(dirname "$(_openclaw_op_config)")" "$(openclaw_bin)" "$(_openclaw_cfg "$1")" "$2" "${HARNESS_OPENCLAW_SUBAGENT_TIMEOUT:-3600}" "$3"; }

# --- transcripts + usage --------------------------------------------------------------------------
openclaw_transcripts(){ local f; [[ -n "${2:-}" ]] || return 0
  f="$(_openclaw_runs "$1" "$2")"; [[ -s $f ]] && echo "$f"; return 0; }
# Each envelope's usage: input, output, cacheRead, cacheWrite (transcript.jsonl); its model is
# <provider>/<model>, as --model names it.
openclaw_usage(){ (( $# )) || return 0; python3 - "$@" <<'PY'
import json, sys
tot = {}
for path in sys.argv[1:]:
    try:
        lines = open(path).read().splitlines()
    except OSError:
        continue
    for line in lines:
        try:
            d = json.loads(line)
            u = d.get("usage")
            if not isinstance(u, dict):
                continue
            m = "/".join(x for x in (d.get("provider"), d.get("model")) if x) or "?"
            a = tot.setdefault(m, [0, 0, 0, 0])
            for i, k in enumerate(("input", "output", "cacheRead", "cacheWrite")):
                a[i] += int(u.get(k) or 0)
        except (ValueError, TypeError, AttributeError):
            continue
for m, t in sorted(tot.items()):
    print(m, *t, sep="\t")
PY
}
# Usage windows (#194, #304): `openclaw status --usage --json` fetches every provider the operator's
# config holds auth for (the auth each lane config includes): usage.providers[] {provider, windows:
# [{label, groupLabel?, usedPercent, resetAt? (ms)}], error?} (usage-windows.json); with none, an empty
# providers list (usage-none.json). A fetch per poll per worker would hit the providers' own rate
# limits, so the answer is cached HARNESS_OPENCLAW_USAGE_TTL seconds in the usage dir.
openclaw_limit_usage(){ _cli_usage_cached openclaw "${HARNESS_OPENCLAW_USAGE_TTL:-120}" _openclaw_limit_usage_fetch; }
_openclaw_limit_usage_fetch(){ local -a cmd; read -ra cmd <<<"$(openclaw_bin)"
  timeout 90 "${cmd[@]}" status --usage --json 2>/dev/null | python3 -c 'import json, sys, time
now = time.time()
for p in (json.load(sys.stdin).get("usage") or {}).get("providers") or []:
    # One malformed window skips that row only; an unknown reset is 0.
    for w in p.get("windows") or []:
        try:
            reset = int(w.get("resetAt") or 0) // 1000
            if 0 < reset <= now:
                continue
            win = " ".join(x for x in (w.get("groupLabel"), w["label"]) if x)
            print(p.get("provider") or "openclaw", win, round(float(w["usedPercent"]), 1), reset, sep="\t")
        except (AttributeError, TypeError, ValueError, KeyError):
            continue'; }

# --- the Harness-driven goal loop (lib.sh goal_loop_tick) -----------------------------------------
# openclaw_last_reply <wd> <session id> — the last turn's id (its line in the transcript, and its own
# OpenClaw session id), then its reply: the envelope's final text, or for a failed turn its error.
# rc 1 while a turn runs (the loop's `running` pid is alive), before the first turn ends, and for a
# turn a limit or a transient error ended: those are the watchdog's (session_limit_idle,
# session_stalled), which nudge it on.
openclaw_last_reply(){ local f run; [[ -n "${2:-}" ]] || return 1
  f="$(_openclaw_runs "$1" "$2")"; [[ -s $f ]] || return 1
  run="$(cat "$(_openclaw_dir "$1")/running" 2>/dev/null)"
  [[ -n $run ]] && kill -0 "$run" 2>/dev/null && return 1
  RUNS="$f" LIMIT="$(openclaw_limit_re)" TRANSIENT="$(openclaw_transient_re)" python3 - <<'PY'
import json, os, re, sys
lines = [l for l in open(os.environ["RUNS"]).read().splitlines() if l.strip()]
try:
    d = json.loads(lines[-1])
except ValueError:
    sys.exit(1)
err = ((d.get("error") or {}).get("message") or "").splitlines()
line = "harness-openclaw: error: " + (err[0] if err else "")
if err and any(re.search(os.environ[k], line) for k in ("LIMIT", "TRANSIENT")):
    sys.exit(1)
print(f"{len(lines)}:{d.get('sessionId') or ''}")
print(d.get("final") or (err[0] if err else ""))
PY
}

# openclaw_kill <sess> <wd> — the pane, and the turn it was running: the loop stops the turn's
# process tree on the pane's hangup; should the loop itself be gone, the tree read before the pane
# is killed (`agent exec`, the claude-cli backend's `claude`, the turn's commands) is stopped here.
openclaw_kill(){ local rc run pids=; run="$(cat "$(_openclaw_dir "${2:-/nonexistent}")/running" 2>/dev/null)"
  [[ $run =~ ^[0-9]+$ ]] && pids="$(_openclaw_tree "$run")"
  tmux kill-session -t "$1" 2>/dev/null; rc=$?
  [[ -n $pids ]] && kill $pids 2>/dev/null
  return "$rc"; }
_openclaw_tree(){ ps -e -o pid=,ppid= | awk -v r="$1" '{ up[$1] = $2 } END { s[r] = 1
  do { n = 0; for (k in up) if (!(k in s) && (up[k] in s)) { s[k] = 1; n++ } } while (n)
  for (k in s) print k }'; }

# --- prerequisites ------------------------------------------------------------------------------
# The binary only: the goal loop is Harness's own (cli_loop driven), each lane's config is written at
# launch, and OpenClaw signs in with the operator's own stored or external CLI credentials. --install
# installs it from npm when there is no binary at all (OpenClaw needs node >= 24.22.1).
openclaw_prereqs(){ local bin; bin="$(openclaw_bin)"
  if ! command -v "$(_cli_exe "$bin")" >/dev/null && [[ "${1:-}" == --install ]] && command -v npm >/dev/null; then
    npm install -g openclaw@latest --allow-scripts=openclaw >/dev/null 2>&1; hash -r; fi
  if command -v "$(_cli_exe "$bin")" >/dev/null; then echo "ok      openclaw binary ($bin)"
  else echo "MISSING openclaw binary ($bin): npm install -g openclaw@latest --allow-scripts=openclaw"; return 1; fi; }

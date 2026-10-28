# codex.sh — the OpenAI Codex CLI adapter (#257). Facts: docs/cli-capabilities.md § `codex`; panes:
# test/fixtures/cli/codex/. Loaded by dispatch.sh; defines codex_<fn> for the cli_* interface.

: "${HARNESS_CODEX_BIN:=codex}"
: "${HARNESS_CODEX_FLAGS:=--no-alt-screen --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -c model_reasoning_effort=high}"
export HARNESS_CODEX_BIN HARNESS_CODEX_FLAGS

_codex_home(){ echo "${CODEX_HOME:-$HOME/.codex}"; }

codex_bin(){ echo "${HARNESS_CODEX_BIN:-codex}"; }
# _codex_flags <flags> <model> <effort> — the configured flags with the model (-m/--model) and the
# effort (Codex has no effort flag: the config override -c model_reasoning_effort=<e>) replaced by
# the lane's own when it names one, so the line never carries either twice.
_codex_flags(){ local f=" $1 "
  [[ -n "$2" ]] && f="$(sed -E 's/ (-m|--model)[= ][^ ]+//g' <<<"$f") -m $2"
  [[ -n "$3" ]] && f="$(sed -E 's/ -c model_reasoning_effort=[^ ]+//g' <<<"$f") -c model_reasoning_effort=$3"
  f="$(tr -s ' ' <<<"$f")"; f="${f# }"; echo "${f% }"; }
# The prompt is positional. --no-alt-screen keeps the scrollback capture-pane reads; the bypass flag
# covers approvals and the sandbox; --dangerously-bypass-hook-trust lets Harness's own Stop hook (the
# harness-ralph plugin, codex_prereqs) run without a /hooks review. No caller-set session id:
# codex_session_id discovers it.
codex_launch(){ local wd="$1" uuid="$2" model="$3" effort="$4"
  echo "exec $(codex_bin) $(_codex_flags "${HARNESS_CODEX_FLAGS:-}" "$model" "$effort") \"$HARNESS_BOOTSTRAP_PROMPT\""; }

# codex_session_id <wd> — Codex names its thread itself (a UUIDv7) and writes it into the rollout's
# first line, session_meta {id, cwd, timestamp} (transcript.jsonl). The id is that of the newest
# rollout started in <wd> at or after this launch (write_state's started_at), so a relaunch in the
# same worktree never reads the previous session's. Sub-agent threads (a parent_thread_id) are not it.
codex_session_id(){ WD="$1" H="$(_codex_home)" python3 - 2>/dev/null <<'PY'
import glob, json, os, re
from datetime import datetime
wd, h = os.environ["WD"], os.environ["H"]
def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
try:
    m = re.search(r'^started_at: "([^"]+)"', open(os.path.join(wd, ".claude", "ralph-loop.local.md")).read(), re.M)
    launched = ts(m.group(1))
except Exception:
    launched = None
# rollout-<YYYY-MM-DDThh-mm-ss>-<id>.jsonl: the name sorts by start time.
for f in sorted(glob.glob(os.path.join(h, "sessions", "*", "*", "*", "rollout-*.jsonl")), key=os.path.basename, reverse=True):
    try:
        with open(f) as fh:
            meta = json.loads(fh.readline())
        p = meta["payload"]
        if meta.get("type") != "session_meta" or p.get("cwd") != wd or p.get("parent_thread_id"):
            continue
        if launched is not None and ts(p["timestamp"]) < launched:
            break
        print(p["id"])
        break
    except Exception:
        continue
PY
  return 0; }

# --- panes (test/fixtures/cli/codex/*.txt) ------------------------------------------------------
# The composer is `› ` at column 0 (`»` at ultra effort). Codex echoes each submitted prompt the same
# way into the scrollback above it, so cli_pane_prompt_line reads the LAST match. The trust dialog's
# `› 1. Yes, continue` is at column 0 too (trust.txt): codex_dialog_re tells it apart.
codex_idle_re(){ echo '^[›»]( |$)'; }
codex_dialog_re(){ echo 'Do you trust the contents of this directory|Press enter to continue'; }
# A turn shows the status row `• Working (12s • esc to interrupt)` above the composer (busy.txt,
# busy-start.txt); its header varies, its suffix does not. Codex's own retries (`Reconnecting... 2/5`)
# are that same row.
codex_busy_re(){ echo ' to interrupt\)'; }
codex_limit_re(){ echo "You've hit your usage limit|Usage limit reached"; }
# What reaches the pane once Codex's own retries give up (transient.txt, from the 0.154.0 binary).
codex_transient_re(){ echo 'stream disconnected before completion|exceeded retry limit|rate limit exceeded'; }
# The status row's timer: "(12s •", "(1m 05s •", "(1h 02m 03s •".
codex_turn_secs(){ local n
  n=$(cli_pane_prompt_line "$1")
  printf '%s\n' "$1" | awk -v n="$n" 'n == 0 || NR < n' | grep -oE '\(([0-9]+[hms] ?)+ • esc to interrupt' | tail -1 |
    awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\(?[0-9]+[hms]$/) { v = $i; gsub(/[^0-9]/, "", v); u = substr($i, length($i))
           s += v * (u == "h" ? 3600 : u == "m" ? 60 : 1) } }
         END { print s + 0 }'; }
# Escape ends the turn with "■ Conversation interrupted - tell the model what to do differently."
codex_interrupted_re(){ echo 'Conversation interrupted'; }
codex_bg_re(){ echo "$(_cli_default_bg_re)|\\([0-9]+s • esc"; }

# --- workspace trust: [projects."<dir>"] trust_level = "trusted" in config.toml -----------------
# Also turns off the startup update check, whose "Update available!" modal would wait on a key. A
# key written after a table header belongs to that table, so the top-level one goes above the first
# header. The file is edited as text, never re-serialized: every other line of it is kept as is.
codex_trust(){
  local dir="$1" cfg lockfd; cfg="$(_codex_home)/config.toml"
  mkdir -p "$(dirname "$cfg")"
  exec {lockfd}>"$cfg.harness-trust.lock"; flock "$lockfd"
  CFG="$cfg" DIR="$dir" python3 - <<'PY'
import json, os, re, tempfile, tomllib
cfg, d = os.environ["CFG"], os.environ["DIR"]
try:
    text = open(cfg).read()
except FileNotFoundError:
    text = ""
try:
    data = tomllib.loads(text)
except tomllib.TOMLDecodeError:
    raise SystemExit(f"codex_trust: {cfg} is not valid TOML; left unchanged")
lines = text.splitlines()
if "check_for_update_on_startup" not in data:
    first = next((i for i, l in enumerate(lines) if re.match(r"\s*\[", l)), len(lines))
    lines[first:first] = ["check_for_update_on_startup = false"] + ([""] if first < len(lines) else [])
if ((data.get("projects") or {}).get(d) or {}).get("trust_level") != "trusted":
    header = f"[projects.{json.dumps(d)}]"
    at = next((i for i, l in enumerate(lines) if l.strip() == header), None)
    if at is None:
        lines += ([""] if lines and lines[-1].strip() else []) + [header, 'trust_level = "trusted"']
    else:
        end = next((i for i in range(at + 1, len(lines)) if re.match(r"\s*\[", lines[i])), len(lines))
        body = [l for l in lines[at + 1:end] if not re.match(r"\s*trust_level\s*=", l)]
        lines[at:end] = [header, 'trust_level = "trusted"'] + body
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(cfg)), prefix=".config.toml.harness.")
try:
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, cfg)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
PY
  flock -u "$lockfd"; exec {lockfd}>&-; }
codex_trusted(){ CFG="$(_codex_home)/config.toml" DIR="$1" python3 -c 'import os, sys, tomllib
d = tomllib.load(open(os.environ["CFG"], "rb"))
sys.exit(0 if ((d.get("projects") or {}).get(os.environ["DIR"]) or {}).get("trust_level") == "trusted" else 1)' 2>/dev/null; }

# --- permission bypass ----------------------------------------------------------------------------
# --dangerously-bypass-approvals-and-sandbox is the whole session's policy, and sub-agents inherit
# the parent turn's sandbox and approval settings (cli-capabilities § codex). Nothing is written per
# worktree; the check is that the flag reaches the launch line.
codex_bypass(){ :; }
codex_bypassed(){ grep -qE -- '(^| )--dangerously-bypass-approvals-and-sandbox( |$)' <<<"$(codex_launch "$1" "" "" "")"; }

# Codex invokes a skill as `$<name>` and reads user skills from ~/.agents/skills.
codex_skill(){ echo "\$$1"; }
codex_user_skills_dir(){ echo "${HARNESS_CODEX_USER_SKILLS:-$HOME/.agents/skills}"; }

# --- transcripts + usage --------------------------------------------------------------------------
# The session's rollout, $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl, then each of its
# sub-agents' rollouts: their session_meta carries the parent's session_id under their own id
# (bypass-subagent.jsonl). Rollouts 7+ days old are compressed to .jsonl.zst, which this does not read.
codex_transcripts(){ [[ -n "$2" ]] || return 0
  SID="$2" H="$(_codex_home)" python3 - 2>/dev/null <<'PY'
import glob, json, os
sid, h = os.environ["SID"], os.environ["H"]
files = sorted(glob.glob(os.path.join(h, "sessions", "*", "*", "*", "rollout-*.jsonl")))
own = [f for f in files if f.endswith(f"-{sid}.jsonl")]
if own:
    print(own[0])
    for f in files:
        if f in own:
            continue
        try:
            with open(f) as fh:
                p = json.loads(fh.readline()).get("payload") or {}
        except (OSError, ValueError):
            continue
        if p.get("session_id") == sid and p.get("id") != sid:
            print(f)
PY
  return 0; }
# Each response's usage is an event_msg token_count's info.last_token_usage; its model is that of the
# turn_context before it. input_tokens counts the cached ones too: they are reported as cache reads.
codex_usage(){ (( $# )) || return 0; python3 - "$@" <<'PY'
import json, sys
tot = {}
for path in sys.argv[1:]:
    model = "?"
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
                p = d.get("payload") or {}
                if d.get("type") == "turn_context":
                    model = p.get("model") or model
                elif d.get("type") == "event_msg" and p.get("type") == "token_count":
                    u = (p.get("info") or {}).get("last_token_usage")
                    if not u:
                        continue
                    t = tot.setdefault(model, [0, 0, 0, 0])
                    cached = int(u.get("cached_input_tokens") or 0)
                    t[0] += int(u.get("input_tokens") or 0) - cached
                    t[1] += int(u.get("output_tokens") or 0)
                    t[2] += cached
                    t[3] += int(u.get("cache_write_input_tokens") or 0)
            except (ValueError, TypeError, AttributeError):
                continue
for m, t in sorted(tot.items()):
    print(m, *t, sep="\t")
PY
}
# Usage windows (#194): every token_count also carries the account's rate_limits {primary,
# secondary}: {used_percent, window_minutes, resets_at}. The newest rollout on the host has the
# latest reading. A window whose reset has passed has reset, and is skipped.
codex_limit_usage(){ H="$(_codex_home)" python3 - <<'PY'
import glob, json, os, sys, time
h, now = os.environ["H"], time.time()
def win(mins):
    return f"{mins // 1440}d" if mins % 1440 == 0 else f"{mins // 60}h" if mins % 60 == 0 else f"{mins}m"
files = sorted(glob.glob(os.path.join(h, "sessions", "*", "*", "*", "rollout-*.jsonl")), key=os.path.getmtime, reverse=True)
for f in files[:20]:
    rl = None
    try:
        with open(f) as fh:
            for line in fh:
                if '"token_count"' not in line:
                    continue
                p = json.loads(line).get("payload") or {}
                if p.get("type") == "token_count" and p.get("rate_limits"):
                    rl = p["rate_limits"]
    except (OSError, ValueError):
        continue
    if not rl:
        continue
    out = []
    for key in ("primary", "secondary"):
        w = rl.get(key)
        try:
            if not w or w.get("used_percent") is None or int(w.get("resets_at") or 0) <= now:
                continue
            out.append(f"{rl.get('limit_id') or 'codex'}\t{win(int(w['window_minutes']))}\t{w['used_percent']}\t{int(w['resets_at'])}")
        except (TypeError, ValueError, KeyError, AttributeError):
            continue
    print("\n".join(out))
    sys.exit(0 if out else 1)
sys.exit(1)
PY
}

# --- prerequisites ------------------------------------------------------------------------------
# The binary, plus the harness-ralph plugin (plugins/codex): Codex's Stop hook that IS the goal loop.
# Without it a lane runs one turn and stops. It installs from Harness's own local marketplace
# (plugins/codex/.agents/plugins/marketplace.json, named `harness`); Codex copies the plugin into its
# cache, so a changed hook reaches lanes only once the plugin's version is bumped and re-added.
# HARNESS_ENGINE_PLUGINS names another engine's plugins/ (install.sh: the placed engine's, which
# outlives the checkout install.sh ran from).
codex_prereqs(){ local bin mkt="${HARNESS_ENGINE_PLUGINS:-$CLI_DIR/../../plugins}/codex"
  bin="$(codex_bin)"
  if command -v "$(_cli_exe "$bin")" >/dev/null; then echo "ok      codex binary ($bin)"
  else echo "MISSING codex binary ($bin): curl -fsSL https://chatgpt.com/codex/install.sh | sh"; return 1; fi
  # grep reads the whole listing (no -q): stopping at the match would kill codex with SIGPIPE, and
  # pipefail would read that as the plugin missing.
  if _cli_run "$bin" plugin list 2>/dev/null | grep -E '^harness-ralph@harness +installed, enabled' >/dev/null; then
    echo "ok      codex plugin harness-ralph"
  elif [[ "${1:-}" == --install ]] && { _cli_run "$bin" plugin marketplace add "$mkt" >/dev/null 2>&1; _cli_run "$bin" plugin add harness-ralph@harness >/dev/null 2>&1; }; then
    echo "ok      codex plugin harness-ralph (installed)"
  else
    echo "MISSING codex marketplace harness: $bin plugin marketplace add $mkt"
    echo "MISSING codex plugin harness-ralph: $bin plugin add harness-ralph@harness"; return 1; fi; }
# The harness-ralph plugin and its marketplace are Harness's own: uninstall takes them back out.
codex_uninstall(){ local bin; bin="$(codex_bin)"
  command -v "$(_cli_exe "$bin")" >/dev/null 2>&1 || return 0
  _cli_run "$bin" plugin remove harness-ralph@harness >/dev/null 2>&1; _cli_run "$bin" plugin marketplace remove harness >/dev/null 2>&1; return 0; }

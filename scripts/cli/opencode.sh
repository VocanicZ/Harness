# opencode.sh — the OpenCode 1.x adapter (#261). Facts: docs/cli-capabilities.md § `opencode`; panes:
# test/fixtures/cli/opencode/. Loaded by dispatch.sh; defines opencode_<fn> for the cli_* interface.

: "${HARNESS_OPENCODE_BIN:=opencode}"
: "${HARNESS_OPENCODE_FLAGS:=--auto}"
export HARNESS_OPENCODE_BIN HARNESS_OPENCODE_FLAGS

# One SQLite database holds every session, message and part (`opencode db path`); OpenCode puts it
# under XDG_DATA_HOME.
_opencode_db(){ echo "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"; }

opencode_bin(){ echo "${HARNESS_OPENCODE_BIN:-opencode}"; }
# _opencode_flags <flags> <model> — the configured flags with the model (-m/--model <provider>/<model>)
# replaced by the lane's own when it names one, so the line never carries it twice.
_opencode_flags(){ local f=" $1 "
  [[ -n "$2" ]] && f="$(sed -E 's/ (-m|--model)[= ][^ ]+//g' <<<"$f") -m $2"
  f="$(tr -s ' ' <<<"$f")"; f="${f# }"; echo "${f% }"; }
# The TUI submits --prompt as the session's first message. --auto approves every permission ask, the
# sub-agents' too. The v1 TUI has no effort flag and no caller-set session id: the effort is the build
# agent's variant in the lane's config, the id is discovered (opencode_session_id). The lane's config
# is inline (OPENCODE_CONFIG_CONTENT, merged above the project's own opencode.json, so nothing is
# written into the worktree for a lane to commit): the goal-loop plugin (opencode-ralph.js, loaded from
# the engine by path, the goal-loop script it runs in OPENCODE_HARNESS_LOOP), `permission.question =
# deny` so the agent never stops on a question no one will answer, and `agent.build.variant` when the
# lane names an effort. OPENCODE_DISABLE_AUTOUPDATE keeps a lane from swapping the CLI under a running
# fleet. All of it rides the line, which the pane's shell runs: it does not inherit this process's
# environment.
opencode_launch(){ local wd="$1" uuid="$2" model="$3" effort="$4"
  echo "OPENCODE_CONFIG_CONTENT=$(_opencode_sq "$(_opencode_config "$effort")") OPENCODE_HARNESS_LOOP=$(_opencode_sq "${GOAL_LOOP_PY:-}")" \
    "OPENCODE_DISABLE_AUTOUPDATE=1 exec $(opencode_bin) $(_opencode_flags "${HARNESS_OPENCODE_FLAGS:-}" "$model") --prompt \"$HARNESS_BOOTSTRAP_PROMPT\""; }
# The model -m/--model names; the effort is the build agent's variant in the line's inline config.
opencode_model_effort(){ local effort
  effort="$(_opencode_line_config "$1" | python3 -c 'import json, sys; print(((json.load(sys.stdin).get("agent") or {}).get("build") or {}).get("variant") or "")' 2>/dev/null)"
  printf '%s\t%s\n' "$(_cli_line_opt "$1" '(-m|--model)[= ]')" "$effort"; }
# _opencode_config <effort> — the lane's inline config, one line of JSON.
_opencode_config(){ PLUGIN="$CLI_DIR/opencode-ralph.js" EFFORT="$1" python3 -c 'import json, os, pathlib
c = {"plugin": [pathlib.Path(os.environ["PLUGIN"]).resolve().as_uri()], "permission": {"question": "deny"}}
if os.environ["EFFORT"]:
    c["agent"] = {"build": {"variant": os.environ["EFFORT"]}}
print(json.dumps(c, separators=(",", ":")))'; }
# _opencode_sq <s> — <s> single-quoted for the pane's shell.
_opencode_sq(){ local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
# _opencode_line_config <line> — the inline config a launch line carries, as JSON ('' = none).
_opencode_line_config(){ LINE="$1" python3 -c 'import os, shlex
for w in shlex.split(os.environ["LINE"]):
    if w.startswith("OPENCODE_CONFIG_CONTENT="):
        print(w.split("=", 1)[1])' 2>/dev/null; }

# opencode_session_id <wd> — OpenCode names its session itself (`ses_…`). The id is that of the newest
# top-level session (no parent: sub-agents are child sessions) whose directory is <wd> (or the path it
# resolves to: OpenCode records its cwd), created at or
# after this launch (write_state's started_at), so a relaunch in the same worktree never reads the
# previous session's.
opencode_session_id(){ WD="$1" DB="$(_opencode_db)" python3 - 2>/dev/null <<'PY'
import os, re, sqlite3
from datetime import datetime
wd, db = os.environ["WD"], os.environ["DB"]
dirs = sorted({wd, os.path.realpath(wd)})
try:
    m = re.search(r'^started_at: "([^"]+)"', open(os.path.join(wd, ".claude", "ralph-loop.local.md")).read(), re.M)
    launched = int(datetime.fromisoformat(m.group(1).replace("Z", "+00:00")).timestamp() * 1000)
except Exception:
    launched = 0
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
r = c.execute(f"SELECT id FROM session WHERE directory IN ({','.join('?' * len(dirs))}) AND parent_id IS NULL"
              " AND time_created >= ? ORDER BY time_created DESC LIMIT 1", (*dirs, launched)).fetchone()
r and print(r[0])
PY
  return 0; }

# --- panes (test/fixtures/cli/opencode/*.txt) ---------------------------------------------------
# The input box is a `┃` bar ending in the agent line `┃  Build auto · <model> <provider>` (idle.txt;
# `auto` is --auto), drawn even while a turn runs. Each prompt, tool call and error is echoed behind
# the same bar in the scrollback; none of them starts with a capitalised word and ` · `. The match
# runs to the end of the line, so cli_prompt_text reads nothing typed: text typed into the box sits
# on the bar's lines above it, and a nudge typed while a turn runs is queued as its own message
# (`QUEUED`, steer.txt), never left in the box.
opencode_idle_re(){ echo '^ *┃  [A-Z][A-Za-z]*( auto)? · .*$'; }
# A permission ask replaces the input box with its panel (busy-permission.txt: a session without
# --auto): the turn waits on it, and nothing may be typed into it.
opencode_dialog_re(){ echo '^ *┃  △ Permission required|^ *┃ +Allow once +Allow always +Reject'; }
# A turn shows `esc interrupt` in the footer, `esc again to interrupt` after one Escape (busy.txt,
# busy-start.txt). While OpenCode retries a failed call the footer is the retry status instead,
# `<message> [retrying in 10s attempt #4]` (busy-retrying.txt, busy-limit-retrying.txt), and a
# narrow pane can wrap the hint one letter per line, so the retry suffix counts on its own. The
# permission panel is a turn waiting (busy-permission.txt). The idle footer has none of them. Each is
# anchored where OpenCode draws it (the footer's spinner, the panel's bar), so the same words in a
# tool's output or a prompt above are not a running turn; so are the limit and error lines below,
# drawn behind the bar.
opencode_busy_re(){ echo '^ +(■|⬝)+ +esc (again to )?interrupt|attempt #[0-9]+\]|^ *┃  △ Permission required'; }
# OpenCode retries a limit 5 times, its own text in the retry status (`<limitName> usage limit
# reached. It will reset in …`, `Free usage exceeded, subscribe to Go`: busy-limit-retrying.txt),
# then draws the provider's message at the prompt (limit.txt: OpenAI's insufficient_quota). An
# insufficient_quota stream error it words itself: `Quota exceeded. Check your plan and billing
# details.` (strings of the 1.19.5 binary).
opencode_limit_re(){ echo '^ *┃  (([A-Za-z0-9-]+ )?[Uu]sage limit reached|Free usage (exceeded|limit)|Quota exceeded|You exceeded your current quota)|FreeUsageLimitError|GoUsageLimitError'; }
# What reaches the prompt once OpenCode's own retries give up (transient.txt: a 503 after 5
# retries); `Too Many Requests` and `Provider is overloaded` are its own wording of a 429 / 529.
opencode_transient_re(){ echo '^ *┃  (Service Unavailable|Internal Server Error|Bad Gateway|Gateway Timeout|Too Many Requests|Provider is overloaded)'; }
# No turn timer while a turn runs: the duration shows only once it has ended (`▣  Build · <model> ·
# 1m 1s`, idle.txt). opencode_turn_secs keeps the dispatch default ('' = unavailable). Escape twice
# ends the turn with that line reading `· interrupted` (interrupted.txt).
opencode_interrupted_re(){ echo '▣ .* · interrupted *$'; }
# The footer's context count (`19.3K (10%)`, busy.txt) grows while a turn streams.
opencode_bg_re(){ echo "$(_cli_default_bg_re)|[0-9.]+K \\([0-9]+%"; }

# --- workspace trust: none (OpenCode loads project config and plugins without asking) ------------
opencode_trust(){ :; }
opencode_trusted(){ :; }

# --- permission bypass ----------------------------------------------------------------------------
# --auto answers every permission ask the session raises, a sub-agent's (child session's) too
# (bypass-subagent.txt). The question tool is denied in the lane's inline config. The check is that
# both reach the launch line.
opencode_bypass(){ :; }
opencode_bypassed(){ local line; line="$(opencode_launch "$1" "" "" "")"
  grep -qE -- '(^| )(--auto|--yolo|--dangerously-skip-permissions)( |$)' <<<"$line" &&
    _opencode_line_config "$line" | python3 -c 'import json, sys
sys.exit(0 if (json.load(sys.stdin).get("permission") or {}).get("question") == "deny" else 1)' 2>/dev/null; }

# OpenCode loads a skill through its skill tool, by name.
opencode_skill(){ echo "$1"; }

# --- transcripts + usage --------------------------------------------------------------------------
# Every session lives in the one database: a transcript is `<db>#<session id>`, the session's own
# then each of its sub-agents' (child sessions).
opencode_transcripts(){ [[ -n "$2" ]] || return 0
  SID="$2" DB="$(_opencode_db)" python3 - 2>/dev/null <<'PY'
import os, sqlite3
sid, db = os.environ["SID"], os.environ["DB"]
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
if c.execute("SELECT 1 FROM session WHERE id = ?", (sid,)).fetchone():
    todo = [sid]
    while todo:
        s = todo.pop(0)
        print(f"{db}#{s}")
        todo += [r[0] for r in c.execute("SELECT id FROM session WHERE parent_id = ? ORDER BY time_created", (s,))]
PY
  return 0; }
# Each assistant message's data carries providerID, modelID and tokens {input, output, reasoning,
# cache {read, write}} (transcript.db). Reasoning tokens are output tokens.
opencode_usage(){ (( $# )) || return 0; python3 - "$@" <<'PY'
import json, sqlite3, sys
tot = {}
for t in sys.argv[1:]:
    db, _, sid = t.rpartition("#")
    try:
        c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = c.execute("SELECT data FROM message WHERE session_id = ?", (sid,)).fetchall()
    except sqlite3.Error:
        continue
    for (data,) in rows:
        try:
            d = json.loads(data)
            if d.get("role") != "assistant" or not d.get("tokens"):
                continue
            k, cache = d["tokens"], d["tokens"].get("cache") or {}
            m = tot.setdefault(f"{d.get('providerID') or '?'}/{d.get('modelID') or '?'}", [0, 0, 0, 0])
            m[0] += int(k.get("input") or 0)
            m[1] += int(k.get("output") or 0) + int(k.get("reasoning") or 0)
            m[2] += int(cache.get("read") or 0)
            m[3] += int(cache.get("write") or 0)
        except (ValueError, TypeError, AttributeError):
            continue
for m, t in sorted(tot.items()):
    print(m, *t, sep="\t")
PY
}

# --- prerequisites ------------------------------------------------------------------------------
# The binary, and it must be OpenCode 1: OpenCode 2 installs a binary with the same name and other
# flags. --install installs v1 from npm when there is no binary at all (never over an OpenCode 2).
# The goal-loop plugin is per worktree (opencode_launch), so nothing is installed into OpenCode.
opencode_prereqs(){ local bin v; bin="$(opencode_bin)"
  _cli_bin_ensure opencode "$bin" "${1:-}" 'npm install -g opencode-ai@1' \
    'npm install -g --allow-scripts=opencode-ai opencode-ai@1 || npm install -g opencode-ai@1' || return 1
  v="$(_cli_run "$bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -z $v ]]; then echo "MISSING opencode binary ($bin) reports no version: npm install -g opencode-ai@1"; return 1; fi
  if [[ ${v%%.*} != 1 ]]; then
    echo "MISSING opencode binary ($bin) is $v: OpenCode 2 is not supported: install opencode-ai@1"; return 1; fi
  echo "ok      opencode binary ($bin, $v)"; }

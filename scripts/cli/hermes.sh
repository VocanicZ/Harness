# hermes.sh — the Hermes Agent adapter (#263). Facts: docs/cli-capabilities.md § `hermes`; panes:
# test/fixtures/cli/hermes/. Loaded by dispatch.sh; defines hermes_<fn> for the cli_* interface.
#
# Hermes runs each chat as a client of a gateway daemon of its home (HERMES_HOME): the gateway runs
# the turn, and two lanes sharing a home share a gateway, its state.db and its config. So each lane
# gets its own home, <wd>/.harness-hermes, seeded from the operator's (HARNESS_HERMES_HOME, default
# ~/.hermes): the runtime Hermes installed there (installs/, tools/: a home without them re-installs
# it) and its skills are linked, its stored login (auth.json, .env) copied, and its config.yaml
# copied with the lane's own settings written into it (_hermes_seed).

: "${HARNESS_HERMES_BIN:=hermes}"
export HARNESS_HERMES_BIN

hermes_bin(){ echo "${HARNESS_HERMES_BIN:-hermes}"; }
_hermes_op_home(){ echo "${HARNESS_HERMES_HOME:-$HOME/.hermes}"; }
_hermes_home(){ echo "$1/.harness-hermes"; }
_hermes_db(){ echo "$(_hermes_home "$1")/state.db"; }
_hermes_json(){ python3 -c 'import json, sys; print(json.dumps(sys.argv[1:] if len(sys.argv) > 2 else sys.argv[1]))' "$@"; }

# _hermes_seed <wd> [model] [effort] — (re)write the lane's home from the operator's. Its config.yaml
# is the operator's with: approvals off (the session and every delegate_task child: no one is there
# to answer one); the clarify toolset off (a question no one answers holds the turn for
# agent.clarify_timeout); no update checks (a lane must not swap the CLI under a running fleet); the
# user skills Harness installs (HARNESS_USER_SKILLS, ~/.claude/skills) as an external skills dir; the
# lane's model and effort when it names them (Hermes refuses -m and --reasoning beside
# `-c <title> --create-if-missing`); and the worktrees cli_trust trusted (harness.trusted). The home
# is in the worktree, kept out of the lane's commits by its own .gitignore and info/exclude.
_hermes_seed(){ local wd="$1" model="${2:-}" effort="${3:-}" home op d skills sets=()
  home="$(_hermes_home "$wd")"; op="$(_hermes_op_home)"; skills="${HARNESS_USER_SKILLS:-$HOME/.claude/skills}"
  mkdir -p "$home" || return 1
  printf '*\n' > "$home/.gitignore"
  git_exclude "$wd" ".harness-hermes/"
  for d in installs tools skills; do
    [[ -e "$op/$d" && ! -L "$home/$d" ]] && { rm -rf "${home:?}/$d"; ln -s "$op/$d" "$home/$d"; }; done
  for d in auth.json .env SOUL.md; do [[ -f "$op/$d" ]] && cp -p "$op/$d" "$home/$d"; done
  : > "$home/harness.settings"
  [[ -n $model ]] && { sets+=("model.default=$(_hermes_json "$model")"); echo "model.default=$model" >> "$home/harness.settings"; }
  [[ -n $effort ]] && { sets+=("agent.reasoning_effort=$(_hermes_json "$effort")"); echo "agent.reasoning_effort=$effort" >> "$home/harness.settings"; }
  [[ -d $skills ]] && sets+=("skills.external_dirs=[$(_hermes_json "$skills")]")
  [[ -s "$home/harness.trusted" ]] && sets+=("$(_hermes_trust_set "$home")")
  if [[ -f "$op/config.yaml" ]]; then cp "$op/config.yaml" "$home/config.yaml"; else : > "$home/config.yaml"; fi
  _hermes_yaml_set "$home/config.yaml" approvals.mode=off updates.check=false 'agent.disabled_toolsets=["clarify"]' "${sets[@]}"; }
_hermes_trust_set(){ local -a dirs; mapfile -t dirs < "$1/harness.trusted"
  echo "skills.trusted_project_dirs=$( (( ${#dirs[@]} == 1 )) && echo "[$(_hermes_json "${dirs[0]}")]" || _hermes_json "${dirs[@]}")"; }
# _hermes_yaml_set <config.yaml> <block>.<key>=<yaml value>… — set keys of top-level blocks in place,
# every other line (and its comments) kept as it was. A key's old value — its line and the
# deeper-indented or list lines under it — is replaced; a missing block or key is added.
_hermes_yaml_set(){ python3 - "$@" <<'PY'
import os, re, sys, tempfile
path, sets = sys.argv[1], sys.argv[2:]
lines = open(path).read().splitlines()
for s in sets:
    k, v = s.split("=", 1)
    block, key = k.split(".", 1)
    b = re.escape(block)
    head = next((i for i, l in enumerate(lines) if re.match(rf"{b}:\s*(#.*)?$", l)), None)
    if head is None:
        head = next((i for i, l in enumerate(lines) if re.match(rf"{b}:", l)), None)
        if head is None:
            lines += ["", f"{block}:"]
            head = len(lines) - 1
        else:
            lines[head] = f"{block}:"
    end = next((j for j in range(head + 1, len(lines)) if re.match(r"[^\s#]", lines[j])), len(lines))
    at = next((j for j in range(head + 1, end) if re.match(rf"  {re.escape(key)}:", lines[j])), None)
    new = f"  {key}: {v}"
    if at is None:
        lines.insert(head + 1, new)
        continue
    nxt = at + 1
    while nxt < end and re.match(r"   |  - ", lines[nxt]):
        nxt += 1
    lines[at:nxt] = [new]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".config.yaml.")
with os.fdopen(fd, "w") as f:
    f.write("\n".join(lines) + "\n")
os.replace(tmp, path)
PY
}

# The lane's home rides the line, which the pane's shell runs: it does not inherit this process's
# environment. `-c <uuid> --create-if-missing` creates the session titled <uuid>: Hermes takes no
# caller-set id. --yolo skips approvals for the session; --accept-hooks approves the config's shell
# hooks, which would otherwise ask on a TTY. On a TTY -q submits the bootstrap as the first turn and
# the session stays open. Model and effort are in the lane's config (_hermes_seed).
hermes_launch(){ _hermes_seed "$1" "$3" "$4"; _hermes_line "$1" "$2"; }
_hermes_line(){ echo "exec env HERMES_HOME=$(printf '%q' "$(_hermes_home "$1")") $(hermes_bin) chat ${2:+-c $2 --create-if-missing }--yolo --accept-hooks -q \"$HARNESS_BOOTSTRAP_PROMPT\""; }
hermes_lane_settings(){ cat "$(_hermes_home "$1")/harness.settings" 2>/dev/null; return 0; }

# An Enter that reaches the composer in the same burst as the text is read as a newline in it, not
# a submit (the text stays in the box): the Enter waits half a second.
hermes_send(){ tmux send-keys -t "$1" -l "$3" 2>/dev/null || true; sleep 0.5; tmux send-keys -t "$1" Enter 2>/dev/null || true; }
# hermes_kill <sess> <wd> — the pane, then the lane's gateway. The TUI leaving interrupts its turn
# (a pane killed mid-command: `Operation interrupted`), but the gateway daemon outlives it: `gateway
# stop -y` ends it, interrupting anything it still runs. In the other order the TUI, still up, starts
# a new gateway for its home.
hermes_kill(){ local home rc; home="$(_hermes_home "${2:-}")"
  tmux kill-session -t "$1" 2>/dev/null; rc=$?
  [[ -n "${2:-}" && -d "$home" ]] && HERMES_HOME="$home" _cli_run "$(hermes_bin)" gateway stop -y >/dev/null 2>&1 </dev/null
  return "$rc"; }

# hermes_session_id <wd> <uuid> — the top-level session titled <uuid> in the lane's state.db.
hermes_session_id(){ [[ -n "${2:-}" ]] || return 0
  _hermes_sql "$(_hermes_db "$1")" "SELECT id FROM sessions WHERE title = ? AND parent_session_id IS NULL ORDER BY started_at DESC LIMIT 1" "$2"
  return 0; }
# _hermes_sql <db> <query> [args…] — the first column of each row; nothing when the db is absent.
_hermes_sql(){ python3 - "$@" 2>/dev/null <<'PY'
import sqlite3, sys
db, q, args = sys.argv[1], sys.argv[2], sys.argv[3:]
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
for r in c.execute(q, args):
    print(r[0])
PY
}

# --- panes (test/fixtures/cli/hermes/*.txt) -----------------------------------------------------
# The composer is `❯ ` at column 0 under its top rule, and Hermes echoes every submitted prompt the
# same way into the scrollback (idle.txt). Idle, the top rule is dashes then the session title
# (`───── <uuid> ─`); busy, it starts `── <spinner> <activity> · <turn time>` (busy.txt) and the
# composer reads `☤ ❯ type to redirect this turn` instead. So the prompt is that title rule: no
# echo matches it, and the match runs to its end, so cli_prompt_text reads nothing typed (a nudge
# typed while a turn runs redirects it, steer.txt: nothing is ever queued in the box).
hermes_idle_re(){ echo '^─{3,} [^─].* ─$'; }
# busy_input_mode interrupt / steer / queue each word the busy composer's placeholder their own way.
hermes_busy_re(){ echo '^☤ ❯ |^── [^ ─]+ |type to (redirect|steer) this turn|type to queue a message for after this turn'; }
# Once its retries give up Hermes prints its verdict at column 0 (the pane wraps everything else):
# limit.txt (a 429 that names its reset) and the credit and Nous-quota wordings of turn_recovery.py /
# turn_api_call.py.
hermes_limit_re(){ echo '^Limit resets at |^❌ Billing or credits exhausted|^❌ Provider reported usage/credit exhaustion|^Your Nous account has hit its rate limit'; }
# transient.txt: a 503 after every retry (`❌ API failed after 3 retries — HTTP 503 …`); a 429 with
# no reset is the provider's per-minute throttle, as transient as a 503.
hermes_transient_re(){ echo '^❌ API failed after [0-9]+ retries|^❌ Rate limited after [0-9]+ (attempt|retries)'; }
hermes_loop(){ echo driven; }
# hermes_turn_secs <pane> — the turn time on the busy top rule (busy.txt: `· 23s`; Hermes writes it
# `Ns`, `Nm`, `Nh`, `Nh Mm`, `N.Nd`), or the status bar's `⏱` when a long activity truncated the
# rule (busy-retrying.txt); 0 when no turn runs.
hermes_turn_secs(){ printf '%s\n' "$1" | python3 -c 'import re, sys
pane = sys.stdin.read().splitlines()
dur = r"(\d+(?:\.\d+)?d|\d+h(?: \d+m)?|\d+m(?: \d+s)?|\d+s)"
def secs(t):
    n = 0
    for v, u in re.findall(r"(\d+(?:\.\d+)?)([dhms])", t):
        n += float(v) * {"d": 86400, "h": 3600, "m": 60, "s": 1}[u]
    return int(n)
rules = [l for l in pane if re.match(r"── [^ ─]+ ", l)]
if not rules:
    print(0); sys.exit()
m = re.search(r" · " + dur + r"(?= ·| ─|$)", rules[-1])
if not m:
    m = next((re.search("⏱ " + dur, l) for l in reversed(pane) if re.search("⏱ " + dur, l)), None)
print(secs(m.group(1)) if m else 1)'; }

# --- workspace trust: no gate on running. A worktree's own skills (.hermes/skills, .agents/skills)
# load only from a root in skills.trusted_project_dirs (skill.txt) — the lane config's, kept across
# relaunches in harness.trusted.
hermes_trust(){ local home; home="$(_hermes_home "$1")"; mkdir -p "$home"
  grep -qxF -- "$1" "$home/harness.trusted" 2>/dev/null || echo "$1" >> "$home/harness.trusted"
  [[ -f "$home/config.yaml" ]] || _hermes_seed "$1"
  _hermes_yaml_set "$home/config.yaml" "$(_hermes_trust_set "$home")"; }
hermes_trusted(){ grep -E '^  trusted_project_dirs: ' "$(_hermes_home "$1")/config.yaml" 2>/dev/null | grep -qF -- "$(_hermes_json "$1")"; }

# --- permission bypass: --yolo on the line, approvals.mode off in the lane's config ----------------
# A delegate_task child runs with the lane's config: its `rm -r` ran with no approval check at all,
# where a lane without them had it flagged and judged by smart approval (bypass-subagent.txt).
hermes_bypass(){ :; }
hermes_bypassed(){ grep -qE -- '(^| )--yolo( |$)' <<<"$(_hermes_line "$1" "")" &&
  sed -n '/^approvals:/,/^[^[:space:]#]/p' "$(_hermes_home "$1")/config.yaml" 2>/dev/null | grep -qx '  mode: off'; }

# Hermes loads a skill through its skill tool, by name: `/<name>` is a slash command, and Hermes's
# own `/handoff` shadows the skill (handoff.txt). The lane's skills include HARNESS_USER_SKILLS
# (_hermes_seed: skill.txt ran one from there by name).
hermes_skill(){ echo "$1"; }

# --- transcripts + usage --------------------------------------------------------------------------
# A transcript is `<state.db>#<session id>`: the session's own, then each delegate_task child's
# (parent_session_id).
hermes_transcripts(){ [[ -n "${2:-}" ]] || return 0
  SID="$2" DB="$(_hermes_db "$1")" python3 - 2>/dev/null <<'PY'
import os, sqlite3
sid, db = os.environ["SID"], os.environ["DB"]
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
if c.execute("SELECT 1 FROM sessions WHERE id = ?", (sid,)).fetchone():
    todo = [sid]
    while todo:
        s = todo.pop(0)
        print(f"{db}#{s}")
        todo += [r[0] for r in c.execute("SELECT id FROM sessions WHERE parent_session_id = ? ORDER BY started_at", (s,))]
PY
  return 0; }
# session_model_usage holds a row per model (and task: title_generation, …) a session called; its
# input_tokens excludes the cache reads and writes, its output_tokens includes the reasoning tokens.
hermes_usage(){ (( $# )) || return 0; python3 - "$@" <<'PY'
import sqlite3, sys
tot = {}
for t in sys.argv[1:]:
    db, _, sid = t.rpartition("#")
    try:
        c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = c.execute("SELECT model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens"
                         " FROM session_model_usage WHERE session_id = ?", (sid,)).fetchall()
    except sqlite3.Error:
        continue
    for m, *n in rows:
        a = tot.setdefault(m or "?", [0, 0, 0, 0])
        for i in range(4):
            a[i] += int(n[i] or 0)
for m, t in sorted(tot.items()):
    print(m, *t, sep="\t")
PY
}

# --- the Harness-driven goal loop (lib.sh goal_loop_tick) -----------------------------------------
# hermes_last_reply <wd> <session id> — the id of the session's last user message (a prompt, a
# redirect, or the message Hermes injects when a background delegation or process ends), then the
# reply that ended its turn: the last assistant message, which must have finished (`stop`). rc 1
# while the turn runs (the gateway holds a turn lease on the session), while a delegate_task child
# dispatched to the background still runs (Hermes resumes the session when it ends), and for a turn
# that failed (`failed_turn`: transient.txt, limit.txt) or was interrupted (an empty message):
# those are the watchdog's.
hermes_last_reply(){ [[ -n "${2:-}" ]] || return 1
  SID="$2" DB="$(_hermes_db "$1")" python3 - 2>/dev/null <<'PY'
import os, sqlite3, sys, time
sid, db = os.environ["SID"], os.environ["DB"]
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True
try:
    if c.execute("SELECT 1 FROM session_turn_leases WHERE conversation_id = ? AND expires_at > ?", (sid, time.time())).fetchone():
        sys.exit(1)
    for (pid,) in c.execute("SELECT owner_pid FROM async_delegations WHERE parent_session_id = ? AND completed_at IS NULL", (sid,)):
        if alive(pid):
            sys.exit(1)
except sqlite3.OperationalError:
    pass
rows = c.execute("SELECT id, role, content, finish_reason, display_kind FROM messages WHERE session_id = ? AND active = 1"
                 " ORDER BY id", (sid,)).fetchall()
users = [r for r in rows if r[1] == "user"]
if not users:
    sys.exit(1)
pid = users[-1][0]
said = [r for r in rows if r[0] > pid and r[1] == "assistant"]
if not said or said[-1][3] != "stop" or said[-1][4] == "failed_turn" or not (said[-1][2] or "").strip():
    sys.exit(1)
print(pid)
print(said[-1][2])
PY
}

# --- prerequisites ------------------------------------------------------------------------------
# The binary only: the goal loop is Harness's own (cli_loop driven), and each lane's home is seeded
# at launch. Hermes signs in with the operator's stored login in its home (`hermes auth`; on this
# host the GitHub CLI's, for the Copilot provider). --install runs Hermes's installer when there is
# no binary at all.
hermes_prereqs(){ local bin; bin="$(hermes_bin)"
  if ! command -v "$(_cli_exe "$bin")" >/dev/null && [[ "${1:-}" == --install ]] && command -v curl >/dev/null; then
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup >/dev/null 2>&1; hash -r; fi
  if command -v "$(_cli_exe "$bin")" >/dev/null; then echo "ok      hermes binary ($bin)"
  else echo "MISSING hermes binary ($bin): curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"; return 1; fi; }

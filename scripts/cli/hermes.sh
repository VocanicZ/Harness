# hermes.sh — the Hermes Agent adapter (#263). Facts: docs/cli-capabilities.md § `hermes`; panes:
# test/fixtures/cli/hermes/. Loaded by dispatch.sh; defines hermes_<fn> for the cli_* interface.
#
# Hermes runs each chat as a client of one host gateway, which serves every profile (its
# gateway_state.json: served_profiles) and runs every session's turns. A turn's commands start from
# the gateway's environment — that of whichever client started it, so another lane's — with only the
# client variables Hermes allowlists (PATH, the toolchain names, and the profile's
# terminal.client_env_passthrough) taken from the session's own client, every other one of those
# names unset (agent/session_client_env.py; env-passthrough.txt). So each lane gets its own home: a
# Hermes profile of the operator's (HARNESS_HERMES_HOME, default ~/.hermes),
# <op>/profiles/harness<hash of the worktree>, with its own state.db and config, which passes the
# lane's variables on (_hermes_seed). A profile runs on the runtime its root installed; a
# home anywhere else re-installs it, and one that links the root's tools/ in makes Hermes repoint
# the host's `hermes` launcher at that home's path (gone with the worktree). Nothing is written
# into the worktree. The profile is seeded from the operator's home (_hermes_seed) and removed once
# its worktree is gone (_hermes_gc).

: "${HARNESS_HERMES_BIN:=hermes}"
export HARNESS_HERMES_BIN

hermes_bin(){ echo "${HARNESS_HERMES_BIN:-hermes}"; }
_hermes_op_home(){ echo "${HARNESS_HERMES_HOME:-$HOME/.hermes}"; }
# _hermes_home <wd> — the lane's profile (a profile name is lowercase letters and digits).
_hermes_home(){ echo "$(_hermes_op_home)/profiles/harness$(printf '%s' "$1" | sha1sum | cut -c1-12)"; }
_hermes_db(){ echo "$(_hermes_home "$1")/state.db"; }
_hermes_json(){ python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"; }
_hermes_jlist(){ python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@"; }

# _hermes_seed <wd> [model] [effort] — (re)write the lane's profile from the operator's home: its
# stored login (auth.json; not .env, whose messaging-bot tokens would put every lane's gateway on
# the operator's bots) and persona, and its config.yaml with: approvals off (the session and every
# delegate_task child: no one is there to answer one); the clarify toolset off as well as the
# operator's (a question no one answers holds the turn for agent.clarify_timeout); no update checks
# (a lane must not swap the CLI under a running fleet); the operator's skills and the user skills
# Harness installs (HARNESS_USER_SKILLS, ~/.claude/skills) as external, read-only skill dirs; the
# lane's model and effort when it names them (Hermes refuses -m and --reasoning beside
# `-c <title> --create-if-missing`); the worktrees cli_trust trusted (harness.trusted); and every
# lane variable (LANE_ENV_NAMES: RTDD_EVENT_LOG, HARNESS_SESSION, …) in terminal.client_env_passthrough,
# beside the operator's, so the lane's commands get its own values, not the gateway's (#313).
_hermes_seed(){ local wd="$1" model="${2:-}" effort="${3:-}" home op d skills sets=() ext=()
  home="$(_hermes_home "$wd")"; op="$(_hermes_op_home)"; skills="${HARNESS_USER_SKILLS:-$HOME/.claude/skills}"
  mkdir -p "$home" 2>/dev/null || return 1
  _hermes_gc "$home"
  printf '%s\n' "$wd" > "$home/harness.wd"
  for d in auth.json SOUL.md; do [[ -f "$op/$d" ]] && cp -p "$op/$d" "$home/$d"; done
  : > "$home/harness.settings"
  [[ -n $model ]] && { sets+=("model.default=$(_hermes_json "$model")"); echo "model.default=$model" >> "$home/harness.settings"; }
  [[ -n $effort ]] && { sets+=("agent.reasoning_effort=$(_hermes_json "$effort")"); echo "agent.reasoning_effort=$effort" >> "$home/harness.settings"; }
  for d in "$op/skills" "$skills"; do [[ -d $d ]] && ext+=("$d"); done
  (( ${#ext[@]} )) && sets+=("skills.external_dirs+=$(_hermes_jlist "${ext[@]}")")
  [[ -s "$home/harness.trusted" ]] && sets+=("$(_hermes_trust_set "$home")")
  (( ${#LANE_ENV_NAMES[@]} )) && sets+=("terminal.client_env_passthrough+=$(_hermes_jlist "${LANE_ENV_NAMES[@]}")")
  if [[ -f "$op/config.yaml" ]]; then cp "$op/config.yaml" "$home/config.yaml"; else : > "$home/config.yaml"; fi
  _hermes_yaml_set "$home/config.yaml" approvals.mode=off updates.check=false 'agent.disabled_toolsets+=["clarify"]' "${sets[@]}"; }
_hermes_trust_set(){ local -a dirs; mapfile -t dirs < "$1/harness.trusted"; echo "skills.trusted_project_dirs+=$(_hermes_jlist "${dirs[@]}")"; }
# _hermes_gc <keep> — remove every other lane profile whose worktree (harness.wd) is gone and whose
# gateway is not running.
_hermes_gc(){ local p wd pid
  for p in "$(_hermes_op_home)"/profiles/harness*/; do p="${p%/}"; [[ -d $p && $p != "$1" ]] || continue
    wd="$(cat "$p/harness.wd" 2>/dev/null)"; [[ -n $wd && ! -d $wd ]] || continue
    pid="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pid"])' "$p/gateway.pid" 2>/dev/null)"
    [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && continue
    rm -rf "${p:?}"; done; }
# _hermes_yaml_set <config.yaml> <block>.<key>=<yaml value>|<block>.<key>+=<json list>… — set the
# keys of top-level blocks in place, every other line (and its comments) kept as it was; `+=`
# appends the list's items to the key's own list (block or flow style), once each. A key's old
# value — its line and the lines under it indented deeper than the key (blank lines between them
# included) — is replaced; a missing block or key is added, at the block's own indent. A block
# written as a flow mapping (`approvals: {mode: manual, timeout: 60}`) is unfolded into lines first.
_hermes_yaml_set(){ python3 - "$@" <<'PY'
import json, os, re, sys, tempfile
path, sets = sys.argv[1], sys.argv[2:]
lines = open(path).read().splitlines()
def ind(l):
    return len(l) - len(l.lstrip(" "))
def scalar(t):
    t = t.strip()
    return t[1:-1] if len(t) > 1 and t[0] == t[-1] and t[0] in "'\"" else t
for s in sets:
    k, v = s.split("=", 1)
    add = k.endswith("+")
    block, key = k.rstrip("+").split(".", 1)
    b = re.escape(block)
    head = next((i for i, l in enumerate(lines) if re.match(rf"{b}:\s*(#.*)?$", l)), None)
    if head is None:
        head = next((i for i, l in enumerate(lines) if re.match(rf"{b}:", l)), None)
        if head is None:
            lines += ["", f"{block}:"]
            head = len(lines) - 1
        else:
            m = re.match(rf"{b}:\s*\{{([^{{}}\[\]]*)\}}\s*(#.*)?$", lines[head])
            pairs = [p.split(":", 1) for p in m.group(1).split(",") if ":" in p] if m else []
            lines[head:head + 1] = [f"{block}:"] + [f"  {a.strip()}: {c.strip()}" for a, c in pairs]
    end = next((j for j in range(head + 1, len(lines)) if re.match(r"[^\s#]", lines[j])), len(lines))
    body = [l for l in lines[head + 1:end] if l.strip() and not l.lstrip().startswith("#")]
    pad = " " * (ind(body[0]) if body else 2)
    at = next((j for j in range(head + 1, end) if re.match(rf"{pad}{re.escape(key)}:", lines[j])), None)
    old, nxt = [], (at + 1 if at is not None else None)
    if at is not None:
        while nxt < end and (not lines[nxt].strip() or ind(lines[nxt]) > len(pad)
                             or (ind(lines[nxt]) == len(pad) and lines[nxt].lstrip().startswith("- "))):
            nxt += 1
        while nxt > at + 1 and not lines[nxt - 1].strip():
            nxt -= 1
        if add:
            inline = lines[at].split(":", 1)[1].split(" #")[0].strip()
            if inline.startswith("[") and inline.endswith("]"):
                old = [scalar(x) for x in inline[1:-1].split(",") if x.strip()]
            old += [scalar(l.lstrip()[2:]) for l in lines[at + 1:nxt] if l.lstrip().startswith("- ")]
    if add:
        items = old + [x for x in json.loads(v) if x not in old]
        v = json.dumps(items)
    new = f"{pad}{key}: {v}"
    if at is None:
        lines.insert(head + 1, new)
    else:
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
# The line names neither: model.default and agent.reasoning_effort in the lane profile's config.yaml
# (_hermes_seed: the lane's own, else the operator's), a `model: <name>` scalar read as the model.
hermes_model_effort(){ python3 - "$(_hermes_home "$2")/config.yaml" 2>/dev/null <<'PY' || printf '\t\n'
import re, sys
want = {("model", "default"): "", ("agent", "reasoning_effort"): ""}
block = None
for l in open(sys.argv[1]).read().splitlines():
    if not l.strip() or l.lstrip().startswith("#"):
        continue
    m = re.match(r"([^\s#][^:]*):\s*(.*?)\s*(#.*)?$", l)
    if m:
        block = m.group(1)
        if block == "model" and m.group(2) and not m.group(2).startswith("{"):
            want[("model", "default")] = m.group(2)
        continue
    m = re.match(r"\s+([^:\s]+):\s*(.*?)\s*(#.*)?$", l)
    if m and (block, m.group(1)) in want:
        want[(block, m.group(1))] = m.group(2)
print("\t".join(v.strip("'\"") for v in want.values()))
PY
}

# An Enter that reaches the composer in the same burst as the text is read as a newline in it, not
# a submit (the text stays in the box): the Enter waits half a second.
hermes_send(){ sess_type "$1" "$3" || true; sleep 0.5; sess_enter "$1" || true; }
# hermes_kill <sess> <wd> — the pane, then the lane's gateway. The TUI leaving interrupts its turn
# (a pane killed mid-command: `Operation interrupted`), but the gateway daemon outlives it: `gateway
# stop -y` ends it, interrupting anything it still runs. In the other order the TUI, still up, starts
# a new gateway for its home.
hermes_kill(){ local home rc; home="$(_hermes_home "${2:-}")"
  sess_kill "$1"; rc=$?
  [[ -n "${2:-}" && -d "$home" ]] && HERMES_HOME="$home" timeout 60 $(hermes_bin) gateway stop -y >/dev/null 2>&1 </dev/null
  return "$rc"; }

# hermes_session_id <wd> <uuid> — the session titled <uuid> in the lane's state.db: the first of its
# compression chain. Hermes compresses a long session by ending it (`end_reason` compression) and
# going on in a child session, which the title may move to; delegate_task children are no part of
# the chain (source subagent).
hermes_session_id(){ [[ -n "${2:-}" ]] || return 0
  SID="$2" DB="$(_hermes_db "$1")" python3 - 2>/dev/null <<'PY'
import os, sqlite3
c = sqlite3.connect(f"file:{os.environ['DB']}?mode=ro", uri=True)
r = c.execute("SELECT id, parent_session_id FROM sessions WHERE title = ? ORDER BY started_at DESC LIMIT 1", (os.environ["SID"],)).fetchone()
while r and r[1]:
    up = c.execute("SELECT id, parent_session_id FROM sessions WHERE id = ? AND end_reason = 'compression'", (r[1],)).fetchone()
    if not up:
        break
    r = up
r and print(r[0])
PY
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
# Usage windows (#194, #304): `hermes usage --json` fetches the configured provider's account limits
# (openai-codex, anthropic OAuth, openrouter): {provider, windows: [{label, used_percent, resets_at}]}
# (usage-windows.json); a provider with no usage endpoint (copilot) exits 1 (usage-none.txt). It runs
# in the newest lane's profile — the provider and login every lane runs on (_hermes_seed) — or the
# operator's home before any lane has one. A fetch per poll per worker would hit the provider's own
# rate limit, so the answer is cached HARNESS_HERMES_USAGE_TTL seconds in the usage dir.
hermes_limit_usage(){ _cli_usage_cached hermes "${HARNESS_HERMES_USAGE_TTL:-120}" _hermes_limit_usage_fetch; }
_hermes_usage_home(){ local p
  p="$(ls -td "$(_hermes_op_home)"/profiles/harness*/ 2>/dev/null | head -1)"
  p="${p%/}"; echo "${p:-$(_hermes_op_home)}"; }
_hermes_limit_usage_fetch(){ local -a cmd; read -ra cmd <<<"$(hermes_bin)"
  HERMES_HOME="$(_hermes_usage_home)" timeout 90 "${cmd[@]}" usage --json 2>/dev/null | python3 -c 'import json, sys, time
from datetime import datetime
d, now = json.load(sys.stdin), time.time()
acct = d.get("provider") or "hermes"
for w in d.get("windows") or []:
    # One malformed window (no percent, a bad reset) skips that row only; an unknown reset is 0.
    try:
        pct, reset = w.get("used_percent"), w.get("resets_at")
        if pct is None:
            continue
        reset = int(datetime.fromisoformat(reset.replace("Z", "+00:00")).timestamp()) if reset else 0
        if 0 < reset <= now:
            continue
        print(acct, w["label"], round(float(pct), 1), reset, sep="\t")
    except (AttributeError, TypeError, ValueError, KeyError):
        continue'; }

# --- the Harness-driven goal loop (lib.sh goal_loop_tick) -----------------------------------------
# hermes_last_reply <wd> <session id> — the id of the last user message (a prompt, a redirect, or the
# message Hermes injects when a background delegation or process ends) in the newest session of the
# session's compression chain, then the reply that ended its turn: the last assistant message, which
# must have finished (`stop`). rc 1 while the turn runs (the gateway holds a turn lease on the
# chain), while a delegate_task child dispatched to the background still runs or its result is not
# yet delivered (Hermes resumes the session with it), and for a turn
# that failed (`failed_turn`: transient.txt, limit.txt) or was interrupted (an empty message):
# those are the watchdog's.
hermes_last_reply(){ [[ -n "${2:-}" ]] || return 1
  SID="$2" DB="$(_hermes_db "$1")" python3 - 2>/dev/null <<'PY'
import os, sqlite3, sys, time
sid, db = os.environ["SID"], os.environ["DB"]
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
chain = [sid]
while True:
    nxt = c.execute("SELECT s.id FROM sessions p JOIN sessions s ON s.parent_session_id = p.id WHERE p.id = ?"
                    " AND p.end_reason = 'compression' AND COALESCE(s.source, '') NOT IN ('subagent', 'tool')"
                    " ORDER BY s.started_at DESC LIMIT 1", (chain[-1],)).fetchone()
    if not nxt or nxt[0] in chain:
        break
    chain.append(nxt[0])
marks = ",".join("?" * len(chain))
def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True
try:
    if c.execute(f"SELECT 1 FROM session_turn_leases WHERE conversation_id IN ({marks}) AND expires_at > ?", (*chain, time.time())).fetchone():
        sys.exit(1)
    for (pid,) in c.execute(f"SELECT owner_pid FROM async_delegations WHERE parent_session_id IN ({marks})"
                            " AND (completed_at IS NULL OR delivery_state != 'delivered')", chain):
        if alive(pid):
            sys.exit(1)
except sqlite3.OperationalError:
    pass
rows = c.execute("SELECT id, role, content, finish_reason, display_kind FROM messages WHERE session_id = ? AND active = 1"
                 " ORDER BY id", (chain[-1],)).fetchall()
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
  _cli_bin_ensure hermes "$bin" "${1:-}" 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash' \
    'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup' || return 1
  echo "ok      hermes binary ($bin)"; }

# agy.sh — the Google Antigravity CLI adapter (#188). Facts: docs/cli-capabilities.md § `agy`; panes:
# test/fixtures/cli/agy/. Loaded by dispatch.sh; defines agy_<fn> for the cli_* interface.

: "${HARNESS_AGY_BIN:=agy}"
: "${HARNESS_AGY_FLAGS:=--dangerously-skip-permissions --effort high}"
export HARNESS_AGY_BIN HARNESS_AGY_FLAGS

_agy_home(){ echo "${HARNESS_AGY_HOME:-$HOME/.gemini/antigravity-cli}"; }
# HARNESS_AGY_TRUST_FILE is a test seam (helpers.sh pins it).
_agy_settings(){ echo "${HARNESS_AGY_TRUST_FILE:-$(_agy_home)/settings.json}"; }

agy_bin(){ echo "${HARNESS_AGY_BIN:-${AGY_BIN:-agy}}"; }
_agy_flags(){ echo "${HARNESS_AGY_FLAGS:-${AGY_FLAGS:-}}"; }
# No positional prompt: the bootstrap rides -i (interactive with an initial prompt). No caller-set
# session id either; agy_session_id discovers it after launch.
agy_launch(){ local wd="$1" uuid="$2" model="$3" effort="$4"
  echo "exec $(agy_bin) $(_cli_flags "$(_agy_flags)" "$model" "$effort") -i \"$HARNESS_BOOTSTRAP_PROMPT\""; }
# --- the headless lane (#486, PRD #475): agy_headless.py runs one `agy -p=` print-mode turn at a time ------
# agy_headless <wd> <uuid> <model> <effort> [resume] — the runner's command, one argv word per line: the headless
# session backend starts it in place of the pane's shell + launch line. Each turn carries the configured flags (the
# lane's model and effort replacing theirs) and the message on stdin as a stream-json user line. agy names its own
# conversations: <uuid> is only the lane's, and a 5th argument (#350) says <uuid> is an existing agy conversation the
# lane carries on: its first turn continues it with --conversation.
agy_headless(){ local wd="$1" uuid="$2" model="$3" effort="$4"
  printf '%s\n' python3 "$CLI_DIR/agy_headless.py" run --cwd "$wd" --bin "$(agy_bin)" --session-id "$uuid" \
    ${5:+--resume} "--flags=$(_cli_flags "$(_agy_flags)" "$model" "$effort")" --message "$HARNESS_BOOTSTRAP_PROMPT"; }
# The headless backend draws a lane in the shapes headless_core.py pane documents, whatever the CLI, so on it the pane
# regexes below are those (_cli_headless_pane_re) and not the TUI's.
_agy_headless(){ declare -F sess_backend >/dev/null && [[ "$(sess_backend)" == headless ]]; }
# A pane's goal loop is the harness-ralph Stop hook. A headless lane is looped by Harness as well (the driven loop,
# lib.sh goal_loop_tick): every print-mode turn that ends without the promise is re-prompted from the lane's own last
# reply (the core's state.json, _cli_headless_last_reply). Where the hook runs inside `agy -p` too it holds the turn
# open until the promise and the driven loop finds the loop already over (cli_done), as claude's does.
agy_loop(){ _agy_headless && echo driven || echo hook; }
agy_last_reply(){ _cli_headless_last_reply "$@"; }

# agy records the conversation it last ran in each workspace in cache/last_conversations.json. Right
# after a relaunch in the same worktree that is still the previous session's, so the id counts only
# when its conversation started at or after this launch: write_state's `started_at`, against the
# `created_at` of the conversation's first transcript step (its db's mtime when there is no
# transcript). With no launch time recorded, the mapped id stands.
agy_session_id(){ WD="$1" H="$(_agy_home)" python3 - 2>/dev/null <<'PY'
import json, os, re
from datetime import datetime, timezone
wd, h = os.environ["WD"], os.environ["H"]
# keys compared as paths, not strings: on Windows agy writes C:\\x or C:/x for what a bash caller names C:/x (#606)
norm = lambda p: os.path.normcase(os.path.normpath(p))
sid = {norm(k): v for k, v in json.load(open(os.path.join(h, "cache", "last_conversations.json"))).items()}.get(norm(wd), "")
def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
try:
    m = re.search(r'^started_at: "([^"]+)"', open(os.path.join(wd, ".claude", "ralph-loop.local.md")).read(), re.M)
    launched = ts(m.group(1))
except Exception:
    launched = None
if sid and launched is not None:
    try:
        with open(os.path.join(h, "brain", sid, ".system_generated", "logs", "transcript.jsonl")) as f:
            start = ts(json.loads(f.readline())["created_at"])
    except Exception:
        try:
            start = os.stat(os.path.join(h, "conversations", sid + ".db")).st_mtime
        except OSError:
            start = None
    if start is None or start < launched:
        sid = ""
print(sid)
PY
  return 0; }

# --- panes (test/fixtures/cli/agy/*.txt) --------------------------------------------------------
# The input box line is `>` at column 0 (idle.txt; older builds drew it boxed, `│ > `). The trust
# dialog's `> Yes, I trust this folder` is at column 0 too (trust.txt), so it is told apart by
# agy_dialog_re, never by this regex. So is a tool-permission prompt's `> 1. Yes, run command`
# (permission.txt: agy without --dangerously-skip-permissions).
agy_idle_re(){ _agy_headless && { _cli_headless_pane_re idle; return; }; echo '^(│ *)?>( |$)'; }
agy_dialog_re(){ _agy_headless && return 0; echo 'I trust this folder|enter Confirm|Requesting permission for:'; }
# A turn shows a braille spinner with "Loading..." then "Generating..." (busy.txt,
# busy-generating.txt); the binary also carries "Working..." and the "(%s · esc to cancel)" hint.
# While agy retries an unavailable model the spinner says so instead (transient-retrying.txt).
agy_busy_re(){ _agy_headless && { _cli_headless_pane_re busy; return; }; echo '(Loading|Generating|Working)\.\.\.|esc to cancel|, retrying in [0-9]+s'; }
# Quota/credit strings from the agy 1.4.8 binary (README of the fixtures). agy retries 5xx and
# per-minute 429 itself; what reaches the pane is its give-up line.
agy_limit_re(){ _agy_headless && { _cli_headless_pane_re limit; return; }; echo 'exhausted your quota|Quota exhausted|AI credits balance is too low'; }
# `Model unavailable (attempt N/10), retrying in Ns` is agy's in-progress status while it retries
# (transient-retrying.txt), not a give-up: only the terminal error stalls a session.
agy_transient_re(){ _agy_headless && { _cli_headless_pane_re transient; return; }; echo 'Agent execution terminated due to error'; }
# No turn timer and no interrupt line in agy's panes (busy*.txt): on a pane agy_turn_secs and
# agy_interrupted_re keep the dispatch defaults ('' = unavailable). turn.sh then reads a running
# turn off agy_busy_re and an interrupt as the busy line going away. A headless lane's drawn screen has both
# (headless_core.py pane), which is what lets the stuck-turn interrupt (#207) and the supervisor's frozen-session
# rule see how long a turn has run.
agy_turn_secs(){ _agy_headless && _cli_headless_turn_secs "$@"; return 0; }
agy_interrupted_re(){ _agy_headless && _cli_headless_pane_re interrupted; return 0; }
# The footer opens with the context's token count ("10.2k ▁▁▁▆▆…", 10.1k idle → 10.2k busy): it moves
# while a turn streams, so the supervisor reads it as activity.
agy_bg_re(){ echo "$(_cli_default_bg_re)|^[0-9.]+k "; }

# --- workspace trust: "trustedWorkspaces" in settings.json (cli-capabilities Findings 1) --------
agy_trust(){
  local dir="$1" tf; tf="$(_agy_settings)"
  [[ -d "$(dirname "$tf")" ]] || return 0      # no agy on this host: nothing to pre-accept
  local lockfd; lock_acquire "$tf.harness-trust.lock" lockfd
  TF="$tf" DIR="$dir" python3 - <<'PY'
import json, os, tempfile
tf, d = os.environ["TF"], os.environ["DIR"]
try:
    with open(tf) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, ValueError):
    data = {}
tw = data.get("trustedWorkspaces")
if not isinstance(tw, list):
    tw = data["trustedWorkspaces"] = []
if d not in tw:
    tw.append(d)
dirn = os.path.dirname(os.path.abspath(tf)) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".settings.json.harness.")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, tf)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
PY
  lock_release "$lockfd"; }
agy_trusted(){ TF="$(_agy_settings)" DIR="$1" python3 -c 'import json,os,sys
sys.exit(0 if os.environ["DIR"] in (json.load(open(os.environ["TF"])).get("trustedWorkspaces") or []) else 1)' 2>/dev/null; }

# --- permission bypass ----------------------------------------------------------------------------
# --dangerously-skip-permissions is agy's always-proceed mode, and sub-agents inherit it: seen on the
# host (bypass-subagent.jsonl: a sub-agent ran a shell command with no prompt, where the same agy
# without the flag asked first, permission.txt). Nothing is written per worktree; the check is that
# the flag reaches the launch line.
agy_bypass(){ :; }
agy_bypassed(){ grep -qE -- '(^| )--dangerously-skip-permissions( |$)' <<<"$(agy_launch "$1" "" "" "")"; }

# rtdd's own `skill install` covers ~/.claude only; agy reads its user skills from here.
agy_user_skills_dir(){ echo "${HARNESS_AGY_USER_SKILLS:-$HOME/.gemini/config/skills}"; }

# --- transcripts + usage --------------------------------------------------------------------------
# Token counts live in conversations/<id>.db (protobuf rows, decoded by agy_usage.py).
agy_transcripts(){ local f; [[ -n "$2" ]] || return 0; f="$(_agy_home)/conversations/$2.db"
  [[ -f "$f" ]] && echo "$f"; return 0; }
agy_usage(){ (( $# )) && python3 "$CLI_DIR/agy_usage.py" "$@"; }
# Usage windows (#194): `agy -p /usage --output-format json` runs no turn and reports each model
# group's 5h and weekly buckets as remaining_fraction (cli-capabilities Findings 3). Every worker
# polls usage, so the answer is cached HARNESS_AGY_USAGE_TTL seconds in the usage dir.
agy_limit_usage(){ _cli_usage_cached agy "${HARNESS_AGY_USAGE_TTL:-120}" _agy_limit_usage_fetch; }
_agy_limit_usage_fetch(){ local -a cmd
  read -ra cmd <<<"$(agy_bin)"   # a command line (#272): timeout runs its words, not a function
  # (MSYS2_ARG_CONV_EXCL: Git Bash rewrites a lone "/usage" argument into C:/Program Files/Git/usage for a native agy, #606)
  MSYS2_ARG_CONV_EXCL='*' timeout 90 "${cmd[@]}" -p "/usage" --output-format json 2>/dev/null | python3 -c 'import json,sys
from datetime import datetime
for g in json.load(sys.stdin)["command"]["data"]["groups"]:
    for b in g.get("buckets") or []:
        rf = b.get("remaining_fraction")
        if rf is None:
            continue
        # One malformed bucket (a non-string reset_time, a non-number fraction) skips that row only.
        try:
            reset = b.get("reset_time") or ""
            try:
                reset = int(datetime.fromisoformat(reset.replace("Z", "+00:00")).timestamp())
            except ValueError:
                reset = 0
            acct, win = g.get("name") or "agy", b.get("window") or b.get("id")
            print(f"{acct}\t{win}\t{round((1 - rf) * 100, 1)}\t{reset}")
        except (AttributeError, TypeError):
            continue'; }

# --- prerequisites ------------------------------------------------------------------------------
# The binary, plus the harness-ralph plugin (plugins/ralph-loop): agy's Stop hook that IS the goal
# loop. Without it a lane runs one turn and stops.
# HARNESS_ENGINE_PLUGINS names another engine's plugins/ (install.sh: the placed engine's, which
# outlives the checkout install.sh ran from).
agy_prereqs(){ local bin plugin_dir="${HARNESS_ENGINE_PLUGINS:-$CLI_DIR/../../plugins}/ralph-loop"
  bin="$(agy_bin)"
  _cli_bin_ensure agy "$bin" "${1:-}" 'curl -fsSL https://antigravity.google/cli/install.sh | bash' || return 1
  echo "ok      agy binary ($bin)"
  if _cli_run "$bin" plugin list 2>/dev/null | grep -q 'harness-ralph'; then echo "ok      agy plugin harness-ralph"
  elif [[ "${1:-}" == --install ]] && _cli_run "$bin" plugin install "$plugin_dir" >/dev/null 2>&1; then
    echo "ok      agy plugin harness-ralph (installed)"
  else echo "MISSING agy plugin harness-ralph: $bin plugin install $plugin_dir"; return 1; fi; }
# The harness-ralph plugin is Harness's own: uninstall takes it back out of agy.
agy_uninstall(){ local bin; bin="$(agy_bin)"
  command -v "$(_cli_exe "$bin")" >/dev/null 2>&1 && _cli_run "$bin" plugin uninstall harness-ralph >/dev/null 2>&1; return 0; }

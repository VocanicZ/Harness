# agy.sh — the Google Antigravity CLI adapter (#188). Facts: docs/cli-capabilities.md § `agy`; panes:
# test/fixtures/cli/agy/. Loaded by dispatch.sh; defines agy_<fn> for the cli_* interface.

_agy_home(){ echo "${HARNESS_AGY_HOME:-$HOME/.gemini/antigravity-cli}"; }
# HARNESS_AGY_TRUST_FILE is a test seam (helpers.sh pins it).
_agy_settings(){ echo "${HARNESS_AGY_TRUST_FILE:-$(_agy_home)/settings.json}"; }

agy_bin(){ echo "${HARNESS_AGY_BIN:-${AGY_BIN:-agy}}"; }
_agy_flags(){ echo "${HARNESS_AGY_FLAGS:-${AGY_FLAGS:-}}"; }
# No positional prompt: the bootstrap rides -i (interactive with an initial prompt). No caller-set
# session id either; agy_session_id discovers it after launch.
agy_launch(){ local wd="$1" uuid="$2" model="$3" effort="$4"
  echo "exec $(agy_bin) $(_cli_flags "$(_agy_flags)" "$model" "$effort") -i \"$HARNESS_BOOTSTRAP_PROMPT\""; }
# agy records the conversation it last ran in each workspace in cache/last_conversations.json.
agy_session_id(){ WD="$1" F="$(_agy_home)/cache/last_conversations.json" python3 -c 'import json,os
print(json.load(open(os.environ["F"])).get(os.environ["WD"], ""))' 2>/dev/null; return 0; }

# --- panes (test/fixtures/cli/agy/*.txt) --------------------------------------------------------
# The input box line is `>` at column 0 (idle.txt; older builds drew it boxed, `│ > `). The trust
# dialog's `> Yes, I trust this folder` is at column 0 too (trust.txt), so it is told apart by
# agy_dialog_re, never by this regex.
agy_idle_re(){ echo '^(│ *)?>( |$)'; }
agy_dialog_re(){ echo 'I trust this folder|enter Confirm'; }
# A turn shows a braille spinner with "Loading..." then "Generating..." (busy.txt,
# busy-generating.txt); the binary also carries "Working..." and the "(%s · esc to cancel)" hint.
agy_busy_re(){ echo '(Loading|Generating|Working)\.\.\.|esc to cancel'; }
# Quota/credit strings from the agy 1.4.8 binary (README of the fixtures). agy retries 5xx and
# per-minute 429 itself; what reaches the pane is its give-up line.
agy_limit_re(){ echo 'exhausted your quota|Quota exhausted|AI credits balance is too low'; }
agy_transient_re(){ echo 'Model unavailable \(attempt|Agent execution terminated due to error'; }

# --- workspace trust: "trustedWorkspaces" in settings.json (cli-capabilities Findings 1) --------
agy_trust(){
  local dir="$1" tf; tf="$(_agy_settings)"
  [[ -d "$(dirname "$tf")" ]] || return 0      # no agy on this host: nothing to pre-accept
  local lockfd; exec {lockfd}>"$tf.harness-trust.lock"; flock "$lockfd"
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
  flock -u "$lockfd"; exec {lockfd}>&-; }
agy_trusted(){ TF="$(_agy_settings)" DIR="$1" python3 -c 'import json,os,sys
sys.exit(0 if os.environ["DIR"] in (json.load(open(os.environ["TF"])).get("trustedWorkspaces") or []) else 1)' 2>/dev/null; }

# --- permission bypass ----------------------------------------------------------------------------
# --dangerously-skip-permissions is agy's always-proceed mode, and sub-agents inherit it (changelog
# 1.1.22 and 1.1.26 fixed sub-agents prompting under it). Nothing is written per worktree; the
# check is that the flag reaches the launch line.
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
agy_limit_usage(){ local c out now; c="$(_usage_dir)/agy.tsv"; now="$(date +%s)"
  if [[ -f "$c" ]] && (( now - $(stat -c %Y "$c") < ${HARNESS_AGY_USAGE_TTL:-120} )); then
    [[ -s "$c" ]] && { cat "$c"; return 0; }; return 1; fi
  mkdir -p "$(dirname "$c")"
  out="$(timeout 90 "$(agy_bin)" -p "/usage" --output-format json 2>/dev/null | python3 -c 'import json,sys
from datetime import datetime
for g in json.load(sys.stdin)["command"]["data"]["groups"]:
    for b in g.get("buckets") or []:
        rf = b.get("remaining_fraction")
        if rf is None:
            continue
        reset = b.get("reset_time") or ""
        try:
            reset = int(datetime.fromisoformat(reset.replace("Z", "+00:00")).timestamp())
        except ValueError:
            reset = 0
        acct, win = g.get("name") or "agy", b.get("window") or b.get("id")
        print(f"{acct}\t{win}\t{round((1 - rf) * 100, 1)}\t{reset}")' 2>/dev/null)"
  printf '%s' "${out:+$out$'\n'}" > "$c"
  [[ -n "$out" ]] && echo "$out"; }

# --- prerequisites ------------------------------------------------------------------------------
# The binary, plus the harness-ralph plugin (plugins/ralph-loop): agy's Stop hook that IS the goal
# loop. Without it a lane runs one turn and stops.
agy_prereqs(){ local bin plugin_dir="$CLI_DIR/../../plugins/ralph-loop"
  bin="$(agy_bin)"
  if command -v "$bin" >/dev/null; then echo "ok      agy binary ($bin)"
  else echo "MISSING agy binary ($bin): curl -fsSL https://antigravity.google/cli/install.sh | bash"; return 1; fi
  if "$bin" plugin list 2>/dev/null | grep -q 'harness-ralph'; then echo "ok      agy plugin harness-ralph"
  elif [[ "${1:-}" == --install ]] && "$bin" plugin install "$plugin_dir" >/dev/null 2>&1; then
    echo "ok      agy plugin harness-ralph (installed)"
  else echo "MISSING agy plugin harness-ralph: $bin plugin install $plugin_dir"; return 1; fi; }

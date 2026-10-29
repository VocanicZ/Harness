# claude.sh — the Claude Code adapter (#188). Facts: docs/cli-capabilities.md § `claude`; panes:
# test/fixtures/cli/claude/. Loaded by dispatch.sh; defines claude_<fn> for the cli_* interface.

: "${HARNESS_CLAUDE_BIN:=claude}"
: "${HARNESS_CLAUDE_FLAGS:=--dangerously-skip-permissions --effort high}"
export HARNESS_CLAUDE_BIN HARNESS_CLAUDE_FLAGS

claude_bin(){ echo "${CLAUDE_BIN:-${HARNESS_CLAUDE_BIN:-claude}}"; }
# The prompt is positional; the session id is ours to set, so the transcript is found by it (#185).
claude_launch(){ local wd="$1" uuid="$2" model="$3" effort="$4"
  echo "exec $(claude_bin) --session-id $uuid $(_cli_flags "${CLAUDE_FLAGS-${HARNESS_CLAUDE_FLAGS:-}}" "$model" "$effort") \"$HARNESS_BOOTSTRAP_PROMPT\""; }
# A worktree hook may pin the lane's model in settings.local.json instead of the flags.
claude_lane_settings(){ local f="$1/.claude/settings.local.json"
  [[ -f "$f" ]] && F="$f" python3 -c 'import json,os
m = (json.load(open(os.environ["F"])) or {}).get("model")
m and print(f"model={m}")' 2>/dev/null; return 0; }
# A --model/--effort on the line wins; otherwise the model the worktree's .claude/settings.local.json
# (a worktree hook's pin) or settings.json names.
claude_model_effort(){ local model effort f
  model="$(_cli_line_opt "$1" '--model[= ]')"; effort="$(_cli_line_opt "$1" '--effort[= ]')"
  for f in settings.local.json settings.json; do
    [[ -z "$model" && -n "${2:-}" && -f "$2/.claude/$f" ]] || continue
    model="$(F="$2/.claude/$f" python3 -c 'import json, os; print((json.load(open(os.environ["F"])) or {}).get("model") or "")' 2>/dev/null)"
  done
  printf '%s\t%s\n' "$model" "$effort"; }

# --- panes (test/fixtures/cli/claude/*.txt) ---------------------------------------------------
# The input prompt is `❯` at column 0; the trust dialog's `❯ No, exit` is indented, so `^` skips it.
claude_idle_re(){ echo '^❯'; }
# An active turn. The spinner line is "✻ <Verb>… (14s · ↓ 288 tokens)"; Harness's own status line
# (ensure_usage_statusline) HIDES the older "(esc to interrupt)" hint (busy-spinner.txt), so the
# spinner's "… (<timer> ·" shape is what proves a turn on a Harness worktree. While a long shell
# command runs the TUI shows "(ctrl+b ctrl+b (twice) to run in background)" (busy.txt).
claude_busy_re(){ echo 'esc to interrupt|to run in background|… \(([0-9]+[dhms] ?)+ ·'; }
# Credit exhaustion is the same class as a limit park (see lib.sh #120).
claude_limit_re(){ echo 'hit your [a-z]+ limit|usage limit reached|limit reached · resets|approaching (your )?usage limit|out of usage credits|out of credits'; }
claude_limit_menu_re(){ echo 'Stop and wait for limit to reset'; }
claude_transient_re(){ echo 'API Error|[Oo]verloaded|overloaded_error|rate.?limit|(^|[^0-9])(429|500|502|503|529)([^0-9]|$)'; }
claude_dialog_re(){ echo 'Yes, I trust this folder|Enter to confirm · Esc to cancel'; }
# The footer's background-agent / shell timers and token counters; one moving means work is in
# flight even though the screen above the prompt is still (supervise.sh).
claude_bg_re(){ echo "$(_cli_default_bg_re)|↓ [0-9.]+k tokens"; }

# --- the running turn (#207, turn.sh) ---------------------------------------------------------
# The spinner's timer above the input box: "✻ Running… (21h 3m 12s · ↓ 4.2k tokens · esc to
# interrupt)". The " ·" after the timer is what separates the spinner from a tool line's own "(32s)".
claude_turn_secs(){ local n
  n=$(cli_pane_prompt_line "$1")
  printf '%s\n' "$1" | awk -v n="$n" 'n == 0 || NR < n' | grep -oE '\(([0-9]+[dhms] ?)+ ·' | tail -1 |
    awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\(?[0-9]+[dhms]$/) { v = $i; gsub(/[^0-9]/, "", v); u = substr($i, length($i))
           s += v * (u == "d" ? 86400 : u == "h" ? 3600 : u == "m" ? 60 : 1) } }
         END { print s + 0 }'; }
# Escape ends the turn with "⎿  Interrupted · What should Claude do instead?".
claude_interrupted_re(){ echo 'Interrupted'; }

# --- workspace trust (#67) ----------------------------------------------------------------------
# Claude Code reads workspace trust from $CLAUDE_CONFIG_DIR/.claude.json when that var is set, else
# ~/.claude.json. Writing only ~/.claude.json silently stopped working once the claude-acc account
# switcher was installed: ~/.bashrc exports CLAUDE_CONFIG_DIR=~/.claude-switch/accounts/<acct> in
# EVERY interactive bash, including the one `tmux new-session` opens for the lane, so the pane reads
# the per-account config while the pre-accept landed in ~/.claude.json — and #67's forever-block came
# back on every new worktree. We cannot resolve the account here: it is chosen AFTER we run, by the
# pane's .bashrc, and the pool worker carries no CLAUDE_CONFIG_DIR of its own (nor can we cache a
# decision — `claude-acc default` may be flipped between spawn and launch). So seed every config the
# pane could possibly read; an entry in a config the pane never opens is inert.
# HARNESS_CLAUDE_CONFIG is a test seam: an explicit config is authoritative and stays single-file.
_claude_trust_configs(){ local acct
  if [[ -n "${HARNESS_CLAUDE_CONFIG:-}" ]]; then echo "$HARNESS_CLAUDE_CONFIG"; return 0; fi
  echo "$HOME/.claude.json"                                       # no switcher, or switcher not active yet
  [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && echo "$CLAUDE_CONFIG_DIR/.claude.json"   # a worker that DID inherit one
  for acct in "$HOME"/.claude-switch/accounts/*/; do              # every claude-acc account the pane may pick
    [[ -d "$acct" ]] && echo "$acct.claude.json"                  # unmatched glob stays literal — skip it
  done; return 0; }
# _claude_trust_config <cfg> <dir> — merge the trust flag for <dir> into one config file. Atomic +
# flocked: several agents launch near-simultaneously.
_claude_trust_config(){
  local dir="$2" cfg="$1" lockfd
  exec {lockfd}>"$cfg.harness-trust.lock"; flock "$lockfd"
  CFG="$cfg" DIR="$dir" python3 - <<'PY'
import json, os, tempfile
cfg, d = os.environ["CFG"], os.environ["DIR"]
try:
    with open(cfg) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, ValueError):
    data = {}
projects = data.get("projects")
if not isinstance(projects, dict):
    projects = data["projects"] = {}
entry = projects.get(d)
if not isinstance(entry, dict):
    entry = projects[d] = {}
entry["hasTrustDialogAccepted"] = True
dirn = os.path.dirname(os.path.abspath(cfg)) or "."
os.makedirs(dirn, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".claude.json.harness.")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, cfg)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
PY
  flock -u "$lockfd"; exec {lockfd}>&-
}
claude_trust(){ local cfg
  while read -r cfg; do _claude_trust_config "$cfg" "$1"; done < <(_claude_trust_configs); }
claude_trusted(){ local cfg
  while read -r cfg; do
    CFG="$cfg" DIR="$1" python3 -c 'import json,os,sys
p = (json.load(open(os.environ["CFG"])).get("projects") or {}).get(os.environ["DIR"]) or {}
sys.exit(0 if p.get("hasTrustDialogAccepted") is True else 1)' 2>/dev/null || return 1
  done < <(_claude_trust_configs); }

# --- permission bypass ----------------------------------------------------------------------------
# --dangerously-skip-permissions only sets the MAIN session's mode; Task/sub-agents
# (subagent-driven-development) were seen NOT to inherit it and fall back to "default" (ask) mode,
# wedging an autonomous run FOREVER on the first mutating-command prompt (no human to answer). So
# permissions.defaultMode goes into <dir>/.claude/settings.local.json, read by the session + its
# sub-agents (cwd-scoped) and git-ignored by convention; it is also added to the worktree's
# info/exclude so `git add -A` can never commit it on installs lacking that global ignore. No flock:
# each session owns a unique <dir>, so there's no shared-file race.
claude_bypass(){
  local dir="$1" f="$1/.claude/settings.local.json"
  mkdir -p "$dir/.claude"
  F="$f" python3 - <<'PY'
import json, os, tempfile
f = os.environ["F"]
try:
    with open(f) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, ValueError):
    data = {}
perms = data.get("permissions")
if not isinstance(perms, dict):
    perms = data["permissions"] = {}
perms["defaultMode"] = "bypassPermissions"
d = os.path.dirname(f) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.harness.")
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, f)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
PY
  # --git-path is relative to <dir> in a plain repo; this shell's cwd is not <dir>.
  local excl; excl="$(cd "$dir" && git rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  [[ -n "$excl" && "$excl" != /* ]] && excl="$dir/$excl"
  [[ -n "$excl" ]] || return 0
  mkdir -p "$(dirname "$excl")"
  grep -qxF '.claude/settings.local.json' "$excl" 2>/dev/null || echo '.claude/settings.local.json' >> "$excl"
}
claude_bypassed(){ F="$1/.claude/settings.local.json" python3 -c 'import json,os,sys
d = json.load(open(os.environ["F"]))
sys.exit(0 if (d.get("permissions") or {}).get("defaultMode") == "bypassPermissions" else 1)' 2>/dev/null; }

# --- transcripts + usage (#185) -----------------------------------------------------------------
# $CLAUDE_CONFIG_DIR/projects/<slug>/<session>.jsonl plus its sub-agents' transcripts; stats.py owns
# the search (every account's config dir) and the fold (dedupe a streamed message by its id).
claude_transcripts(){ [[ -n "$2" ]] && python3 "$CLI_DIR/../stats.py" transcripts "$2"; }
claude_usage(){ (( $# )) && python3 "$CLI_DIR/../stats.py" usage "$@"; }
# Usage windows (#194): Claude Code hands its status line the documented
# `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`; scripts/usage-statusline.sh (wired
# into each worktree by claude_usage_setup) drops that into $USAGE_DIR/<account>.json. A window
# whose resets_at has passed has reset, so it is skipped rather than reported stale. No drop at all =
# usage unavailable (rc 1).
claude_limit_usage(){
  compgen -G "$(_usage_dir)/*.json" >/dev/null || return 1
  USAGE_DIR="$(_usage_dir)" python3 - <<'PY'
import glob, json, os, time
now = time.time()
for f in sorted(glob.glob(os.path.join(os.environ["USAGE_DIR"], "*.json"))):
    try:
        with open(f) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        continue
    acct = d.get("account") or "default"
    for win, w in sorted((d.get("rate_limits") or {}).items()):
        if not isinstance(w, dict) or w.get("used_percentage") is None:
            continue
        reset = int(w.get("resets_at") or 0)
        if reset and reset <= now:
            continue
        print(f"{acct}\t{win}\t{w['used_percentage']}\t{reset}")
PY
}
# usage_statusline_install <dir> — point a claude worktree's status line at usage-statusline.sh,
# only when no statusLine is set there already.
usage_statusline_install(){ local dir="$1"
  mkdir -p "$dir/.claude" "$(_usage_dir)"
  F="$dir/.claude/settings.local.json" CMD="bash '$ENGINE_DIR/scripts/usage-statusline.sh' '$(_usage_dir)'" python3 - <<'PY'
import json, os, tempfile
f = os.environ["F"]
try:
    with open(f) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, ValueError):
    data = {}
if "statusLine" not in data:
    data["statusLine"] = {"type": "command", "command": os.environ["CMD"]}
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), prefix=".settings.harness.")
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, f)
PY
}
claude_usage_setup(){ usage_statusline_install "$1"; }

# --- prerequisites ------------------------------------------------------------------------------
# The binary, plus the plugins every lane needs: ralph-loop (the goal loop's Stop hook) and
# superpowers (the skills the prompts name). --install installs what is missing.
# HARNESS_MARKETPLACE / HARNESS_MARKETPLACE_NAME name the marketplace they come from (install.sh).
claude_prereqs(){ local bin rc=0 p f mk="${HARNESS_MARKETPLACE_NAME:-claude-plugins-official}"
  bin="$(claude_bin)"
  if command -v "$(_cli_exe "$bin")" >/dev/null; then echo "ok      claude binary ($bin)"
  else echo "MISSING claude binary ($bin): curl -fsSL https://claude.ai/install.sh | bash"; return 1; fi
  [[ "${1:-}" == --install ]] &&
    _cli_run "$bin" plugin marketplace add "${HARNESS_MARKETPLACE:-anthropics/claude-plugins-official}" >/dev/null 2>&1
  for p in ralph-loop superpowers; do
    f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
    if [[ -f "$f" ]] && P="$p" F="$f" python3 -c 'import json,os,sys
d = json.load(open(os.environ["F"])).get("plugins", {})
sys.exit(0 if any(k.split("@")[0] == os.environ["P"] for k in d) else 1)' 2>/dev/null; then
      echo "ok      claude plugin $p"
    elif [[ "${1:-}" == --install ]] && _cli_run "$bin" plugin install "$p@$mk" --scope user >/dev/null 2>&1; then
      echo "ok      claude plugin $p (installed)"
    else echo "MISSING claude plugin $p: $bin plugin install $p@$mk"; rc=1; fi
  done
  # ralph-loop's Stop hook must be executable, or the goal loop never re-feeds the task.
  [[ "${1:-}" == --install ]] && find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" \
    -path '*/ralph-loop/*/hooks/*.sh' -exec chmod +x {} \; 2>/dev/null
  return $rc; }

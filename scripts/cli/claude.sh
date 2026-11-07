# claude.sh — the Claude Code adapter (#188). Facts: docs/cli-capabilities.md § `claude`; panes:
# test/fixtures/cli/claude/. Loaded by dispatch.sh; defines claude_<fn> for the cli_* interface.

: "${HARNESS_CLAUDE_BIN:=claude}"
: "${HARNESS_CLAUDE_FLAGS:=--dangerously-skip-permissions --effort high}"
export HARNESS_CLAUDE_BIN HARNESS_CLAUDE_FLAGS

claude_bin(){ echo "${CLAUDE_BIN:-${HARNESS_CLAUDE_BIN:-claude}}"; }
# _claude_settings_model <file> — the model a Claude Code settings file names (empty: none, or no file).
_claude_settings_model(){ [[ -f "$1" ]] || return 0
  F="$1" python3 -c 'import json, os; print((json.load(open(os.environ["F"])) or {}).get("model") or "")' 2>/dev/null; return 0; }
# _claude_main_local <wd> — a linked git worktree's MAIN checkout's .claude/settings.local.json (empty when
# <wd> is no linked worktree). Claude Code reads it for every worktree of that repository, and it wins
# over the worktree's own settings.local.json (#374, claude 2.1.316) — the tracked settings.json does not.
_claude_main_local(){ local common own
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  own="$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 0
  [[ -n "$common" && "$common" != "$own" ]] && echo "${common%/.git}/.claude/settings.local.json"; return 0; }
# _claude_lane_model <wd> <model> — the model a lane launches with: its own (.harness-lane), else the pin a
# worktree hook wrote into <wd>/.claude/settings.local.json. That pin alone silently loses to the main
# checkout's own settings.local.json in a linked worktree (#374: hg2's Sonnet implementer lanes ran Opus,
# the orchestration checkout's pin), so it goes on the launch line as --model, which beats every settings file.
_claude_lane_model(){ [[ -n "$2" ]] && { echo "$2"; return 0; }
  _claude_settings_model "$1/.claude/settings.local.json"; }
# claude_pinned_model <wd> — the worktree hook's settings.local.json pin: launch_agent ranks it with
# .harness-lane, above the role's model (#375), so a hook's pin still wins over a role default.
claude_pinned_model(){ _claude_settings_model "$1/.claude/settings.local.json"; }
# claude_role_default <role> <model|effort> — #375: Opus manages (plan, PRD, decompose, review, triage,
# inject), Sonnet implements, both at high effort. Aliases, never full ids: a new Opus or Sonnet arrives
# with the CLI update.
claude_role_default(){ case "$1:$2" in manager:model) echo opus;; implementer:model) echo sonnet;; *:effort) echo high;; esac; }
# --- the lean lane (#595) -------------------------------------------------------------------------
# A lane does not need the operator's user-scope Claude config (186 skills, plugins, MCP servers, hooks:
# ~13k tokens of fixed context, re-cached with the 1h TTL in every session; cache writes were 53% of the
# bench run's cost). It launches with the project and local setting sources only; what it uses comes from
# the engine: its skills as symlinks in the worktree's .claude/skills (claude_lean_setup) and the goal
# loop's Stop hook (the ralph-loop plugin) through --plugin-dir. Measured (12 local `claude -p` runs): first
# turn cache write 32.5k -> 3.85k with `--setting-sources project,local --strict-mcp-config`.
# NOT --disable-slash-commands (it removes the Skill tool and bloats the Workflow tool's description) and
# NOT --tools <list> (a custom tool set misses the shared global prompt cache). The tools no lane used in
# 10 sessions are --disallowedTools instead (total context 20.9k -> 9.7k); AskUserQuestion only for an
# autonomous fleet, where no human answers. Flags that take a list use the `=` form: a space-separated
# variadic option would swallow the positional bootstrap prompt.
# HARNESS_CLAUDE_LEAN=0 turns it off. Lean is also off when the configured flags name --setting-sources
# (the operator chose), or when the ralph-loop plugin cannot be found (without its hook the pane's goal loop
# breaks silently, so the full user config, which has the plugin, is the safe launch).
CLAUDE_LEAN_TOOLS="Workflow,ScheduleWakeup,ReportFindings,ListAgents"
# _claude_plugin_dir <plugin> — the install dir of a user-scope Claude Code plugin: the first of the config
# dirs a lane may run under (CLAUDE_CONFIG_DIR, HARNESS_CLAUDE_CONFIG_DIRS, ~/.claude, every claude-acc
# account) whose installed_plugins.json names it. Empty: not installed.
_claude_plugin_dir(){ local d
  { [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && echo "$CLAUDE_CONFIG_DIR"
    tr ':' '\n' <<<"${HARNESS_CLAUDE_CONFIG_DIRS:-}"
    echo "$HOME/.claude"; for d in "$HOME"/.claude-switch/accounts/*/; do [[ -d $d ]] && echo "${d%/}"; done; } |
  while IFS= read -r d; do
    [[ -n $d && -f "$d/plugins/installed_plugins.json" ]] || continue
    P="$1" F="$d/plugins/installed_plugins.json" python3 -c 'import json, os, sys
for k, v in (json.load(open(os.environ["F"])).get("plugins") or {}).items():
    if k.split("@")[0] != os.environ["P"]:
        continue
    for e in sorted(v if isinstance(v, list) else [], key=lambda e: e.get("scope") != "user"):
        p = e.get("installPath") or ""
        if os.path.isdir(p):
            print(p); sys.exit(0)
sys.exit(1)' 2>/dev/null && return 0
  done; return 0; }
# claude_lean_flags — the lean launch flags, one line; empty when the lane launches with the full user
# config (see above).
claude_lean_flags(){ local rl tools="$CLAUDE_LEAN_TOOLS"
  [[ "${HARNESS_CLAUDE_LEAN:-1}" == 0 ]] && return 0
  [[ " ${CLAUDE_FLAGS-${HARNESS_CLAUDE_FLAGS:-}} " == *" --setting-sources"* ]] && return 0
  rl="$(_claude_plugin_dir ralph-loop)"
  [[ -n "$rl" && "$rl" != *[[:space:]]* ]] || return 0
  [[ "${HARNESS_AUTONOMOUS:-true}" == true ]] && tools="$tools,AskUserQuestion"
  echo "--setting-sources project,local --strict-mcp-config --plugin-dir=$rl --disallowedTools=$tools"; }
# claude_lean_setup <wd> — put the skills the prompts name where a lean lane finds them: a symlink each in
# <wd>/.claude/skills, from the engine's skill/<name> (Harness's own, vendored ones) or, for a skill that is
# not the engine's (rtdd: its own, versioned with its binary), from the operator's user skills dir. A skill
# the project itself ships there is left alone. Each link is git-excluded in the worktree, so `git add -A`
# never commits it. Nothing is made when the lane launches full (claude_lean_flags empty).
claude_lean_setup(){ local wd="$1" n src dst
  [[ -n "$(claude_lean_flags)" ]] || return 0
  for n in $(cli_prompt_skills); do
    src="$(cli_engine_skill_root)/$n"; [[ -f "$src/SKILL.md" ]] || src="$(claude_user_skills_dir)/$n"
    [[ -f "$src/SKILL.md" ]] || continue
    dst="$wd/.claude/skills/$n"
    if [[ -L $dst ]]; then rm -f "$dst"; elif [[ -e $dst ]]; then continue; fi
    mkdir -p "$wd/.claude/skills" && ln -s "$src" "$dst" || continue
    git_exclude "$wd" ".claude/skills/$n"
  done; return 0; }
# --- the prompt-cache TTL (#615) ------------------------------------------------------------------
# Claude Code writes its prompt cache with the 1h TTL (2x the input price); the 5m TTL is 1.25x. Cache
# writes were the largest share of the bench run's cost, and a lane re-reads its cache every turn, so a
# lane launches with the 5m TTL: FORCE_PROMPT_CACHING_5M=1 in its environment (a local test switched
# every write to 5m with it). The cost is a gap over 5 minutes between turns (a long suite, a wait),
# after which the cache is written again; bench/run.py records the gap distribution next to the write split.
# HARNESS_CACHE_TTL=5m|1h picks it (default 5m); 1h leaves the CLI's own default. Anything else is 5m.
claude_cache_ttl(){ case "${HARNESS_CACHE_TTL:-5m}" in 1h) echo 1h;; *) echo 5m;; esac; }
# claude_lane_env — the `NAME=value` lines a lane's environment gets from this adapter (session_env, lib.sh).
claude_lane_env(){ [[ "$(claude_cache_ttl)" == 5m ]] && echo "FORCE_PROMPT_CACHING_5M=1"; return 0; }
# The prompt is positional; the session id is ours to set, so the transcript is found by it (#185).
claude_launch(){ local wd="$1" uuid="$2" model effort="$4" lean; model="$(_claude_lane_model "$wd" "$3")"; lean="$(claude_lean_flags)"
  echo "exec $(claude_bin) --session-id $uuid $(_cli_flags "${CLAUDE_FLAGS-${HARNESS_CLAUDE_FLAGS:-}}" "$model" "$effort")${lean:+ $lean} \"$HARNESS_BOOTSTRAP_PROMPT\""; }
# --- the headless lane (#349): claude is the one CLI with a headless lane runner -----------------
# claude_headless <wd> <uuid> <model> <effort> [resume] — the runner's command, one argv word per line: the
# headless session backend starts it in place of the pane's shell + launch line. Each turn is one
# `claude -p` with the configured flags (the lane's model/effort replacing theirs); the bootstrap is
# the first turn; the session id is ours, as on a pane. A 5th argument (#350) says <uuid> is an existing
# session the lane carries on: the first turn resumes it.
claude_headless(){ local wd="$1" uuid="$2" model effort="$4" lean; model="$(_claude_lane_model "$wd" "$3")"; lean="$(claude_lean_flags)"
  printf '%s\n' python3 "$CLI_DIR/claude_headless.py" run --cwd "$wd" --bin "$(claude_bin)" --session-id "$uuid" \
    ${5:+--resume} "--flags=$(_cli_flags "${CLAUDE_FLAGS-${HARNESS_CLAUDE_FLAGS:-}}" "$model" "$effort")${lean:+ $lean}" --message "$HARNESS_BOOTSTRAP_PROMPT"; }
# A pane's goal loop is ralph-loop's Stop hook. A headless lane is looped by Harness as well (the driven
# loop, lib.sh goal_loop_tick): every `claude -p` turn that ends without the promise is re-prompted from
# the lane's own last reply. Where ralph-loop's hook runs inside `claude -p` too, it holds the turn open
# until the promise and the driven loop finds the loop already over (cli_done).
claude_loop(){ [[ "$(sess_backend)" == headless ]] && echo driven || echo hook; }
# claude_last_reply <wd> <session id> — the headless lane's last turn: `<session>:<turn>`, then its reply
# (_cli_headless_last_reply in dispatch.sh: the core's state.json is every CLI's).
claude_last_reply(){ _cli_headless_last_reply "$@"; }
# A worktree hook may pin the lane's model in settings.local.json instead of the flags.
claude_lane_settings(){ local f="$1/.claude/settings.local.json"
  [[ -f "$f" ]] && F="$f" python3 -c 'import json,os
m = (json.load(open(os.environ["F"])) or {}).get("model")
m and print(f"model={m}")' 2>/dev/null; return 0; }
# A --model/--effort on the line wins; otherwise the model Claude Code takes from the settings files, in
# its order: a linked worktree's main checkout's .claude/settings.local.json (#374), then the worktree's
# own settings.local.json (a worktree hook's pin — claude_launch puts that on the line), then settings.json.
claude_model_effort(){ local model effort f
  model="$(_cli_line_opt "$1" '--model[= ]')"; effort="$(_cli_line_opt "$1" '--effort[= ]')"
  if [[ -z "$model" && -n "${2:-}" ]]; then
    for f in "$(_claude_main_local "$2")" "$2/.claude/settings.local.json" "$2/.claude/settings.json"; do
      [[ -n "$f" ]] && model="$(_claude_settings_model "$f")"
      [[ -n "$model" ]] && break
    done
  fi
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
claude_turn_secs(){ _cli_headless_turn_secs "$@"; }
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
  lock_acquire "$cfg.harness-trust.lock" lockfd
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
  lock_release "$lockfd"
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
# Claude Code reads user skills from ~/.claude/skills (#439): Harness links its skills there.
claude_user_skills_dir(){ echo "${HARNESS_USER_SKILLS:-$HOME/.claude/skills}"; }
claude_transcripts(){ [[ -n "$2" ]] && python3 "$CLI_DIR/../stats.py" transcripts "$2"; }
claude_usage(){ (( $# )) && python3 "$CLI_DIR/../stats.py" usage "$@"; }
# Usage windows (#194): Claude Code hands its status line the documented
# `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`; scripts/usage-statusline.sh (wired
# into each worktree by claude_usage_setup) drops that into $USAGE_DIR/<account>.json. A headless lane
# (#352) runs no status line: `claude -p` reports the same windows as rate_limit_event
# `unifiedWindows` (utilization 0–1, resetsAt), which its runner keeps in the lane's state.json with the
# account it runs on — read from this fleet's own lanes (`<prefix>-…`), as the drops are this fleet's: a
# sibling fleet's account must not hold this fleet's claims. For each account window the newest reading
# of either source wins. A window whose resets_at has passed has reset, so it is skipped rather than
# reported stale. No drop and no lane reading at all = usage unavailable (rc 1).
claude_limit_usage(){
  USAGE_DIR="$(_usage_dir)" LANES="$(declare -F _hl_root >/dev/null && _hl_root)" PREFIX="${HARNESS_SESS_PREFIX:-}" python3 - <<'PY'
import glob, json, os, sys, time
now, best, seen = time.time(), {}, False
def load(f):
    try:
        with open(f, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}
def take(acct, win, pct, reset, at):   # pct: the reading as printed
    try:
        reset, at = int(reset or 0), float(at or 0)
    except (TypeError, ValueError):
        return
    if reset and reset <= now:
        return
    if (acct, win) not in best or at >= best[(acct, win)][2]:
        best[(acct, win)] = (pct, reset, at)
for f in sorted(glob.glob(os.path.join(os.environ["USAGE_DIR"], "*.json"))):
    seen = True
    d = load(f)
    for win, w in sorted((d.get("rate_limits") or {}).items()):
        if isinstance(w, dict) and w.get("used_percentage") is not None:
            take(d.get("account") or "default", win, w["used_percentage"], w.get("resets_at"), d.get("at") or os.path.getmtime(f))
pfx = os.environ["PREFIX"] + "-" if os.environ["PREFIX"] else ""
for f in sorted(glob.glob(os.path.join(os.environ["LANES"], pfx + "*", "state.json"))) if os.environ["LANES"] else ():
    st = load(f)
    info = st.get("rate_limit") if isinstance(st.get("rate_limit"), dict) else {}
    seen = seen or bool(info.get("unifiedWindows"))
    for win, w in sorted((info.get("unifiedWindows") or {}).items()):
        if isinstance(w, dict) and isinstance(w.get("utilization"), (int, float)):
            pct = round(w["utilization"] * 100, 1)
            take(st.get("account") or "default", win, int(pct) if pct == int(pct) else pct, w.get("resetsAt"),
                 st.get("rate_limit_at") or st.get("updated"))
if not seen:
    sys.exit(1)
for (acct, win), (pct, reset, _) in sorted(best.items()):
    print(f"{acct}\t{win}\t{pct}\t{reset}")
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
  _cli_bin_ensure claude "$bin" "${1:-}" 'curl -fsSL https://claude.ai/install.sh | bash' || return 1
  echo "ok      claude binary ($bin)"
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

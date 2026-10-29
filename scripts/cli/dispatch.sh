# dispatch.sh — the CLI adapter seam (#188, PRD #189). The ONE file that reads HARNESS_CLI: every
# caller (lib.sh, usage.sh, supervise.sh, setup.sh, start.sh, status.sh, init.sh) calls the cli_*
# interface below instead of branching on the CLI name. Sourced; defines functions only.
#
# Each adapter scripts/cli/<cli>.sh defines <cli>_<fn> for the interface functions its CLI needs;
# a function it leaves out falls back to _cli_default_<fn> here. The CLI is resolved at CALL time,
# so `HARNESS_CLI=agy cli_trust "$wd"` (a test, or the supervisor reading another fleet's pane)
# reaches the agy adapter without re-sourcing anything. docs/plans/2026-10-24-multi-cli.md lists
# the contract of each function; docs/cli-capabilities.md is where every CLI fact comes from.
: "${HARNESS_CLI:=claude}"
export HARNESS_CLI
CLI_CONFIG_VAR=HARNESS_CLI    # the config key naming the fleet's CLI (init.sh writes it)
CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# cli_list — every CLI with an adapter, one per line. A *-loop.sh is a program an adapter's pane runs
# (openclaw-loop.sh), not an adapter.
cli_list(){ local f; for f in "$CLI_DIR"/*.sh; do f="${f##*/}"; [[ $f == dispatch.sh || $f == *-loop.sh ]] || echo "${f%.sh}"; done; }
# cli_load <cli> — make <cli> the fleet's CLI for every later cli_* call in this shell.
cli_load(){ [[ -n "$1" && -f "$CLI_DIR/$1.sh" ]] || { echo "unknown agent CLI: ${1:-<empty>} (have: $(cli_list | xargs))" >&2; return 1; }
  HARNESS_CLI="$1"; }
# cli_name — the CLI this fleet drives.
cli_name(){ echo "${HARNESS_CLI:-claude}"; }
# cli_with <cli> <fn> [args…] — run one interface function for a CLI other than the fleet's own.
cli_with(){ [[ -f "$CLI_DIR/$1.sh" ]] || return 1; HARNESS_CLI="$1" "${@:2}"; }

_cli_call(){ local fn="$1" cli="${HARNESS_CLI:-claude}"; shift
  if declare -F "${cli}_$fn" >/dev/null; then "${cli}_$fn" "$@"
  elif [[ -f "$CLI_DIR/$cli.sh" ]] && declare -F "_cli_default_$fn" >/dev/null; then "_cli_default_$fn" "$@"
  else echo "agent CLI '$cli' has no adapter (have: $(cli_list | xargs))" >&2; return 1; fi; }

# --- defaults: an adapter overrides only what its CLI needs -----------------------------------
_cli_default_lane_settings(){ :; }
# The model and effort the line's --model/--effort name (`--model x` or `--model=x`).
_cli_default_model_effort(){ printf '%s\t%s\n' "$(_cli_line_opt "$1" '--model[= ]')" "$(_cli_line_opt "$1" '--effort[= ]')"; }
_cli_default_first_input(){ :; }
_cli_default_send(){ tmux send-keys -t "$1" -l "$3" 2>/dev/null || true; tmux send-keys -t "$1" Enter 2>/dev/null || true; }
_cli_default_kill(){ tmux kill-session -t "$1" 2>/dev/null; }
_cli_default_session_id(){ echo "$2"; }
_cli_default_limit_menu_re(){ :; }
_cli_default_dialog_re(){ :; }
_cli_default_loop(){ echo hook; }
# The goal loop's state file: written by write_state, removed by the loop's Stop hook (ralph-loop
# on claude, harness-ralph on agy) the moment the loop ends — promise, max-iter, or error.
_cli_default_done(){ [[ ! -f "$1/.claude/ralph-loop.local.md" ]]; }
# A hook-looped CLI never needs it: its own Stop hook reads the reply.
_cli_default_last_reply(){ return 1; }
_cli_default_trust(){ :; }
_cli_default_trusted(){ :; }
_cli_default_skill(){ echo "/$1"; }
_cli_default_user_skills_dir(){ :; }
_cli_default_transcripts(){ :; }
_cli_default_usage(){ :; }
_cli_default_limit_usage(){ return 1; }
_cli_default_usage_setup(){ :; }
_cli_default_turn_secs(){ :; }
_cli_default_interrupted_re(){ :; }
# Elapsed-time shapes ("1h 2m 3s", "4m 5s") in the footer: a background job's running timer.
_cli_default_bg_re(){ echo '[0-9]+h [0-9]+m [0-9]+s|[0-9]+m [0-9]+s'; }
_cli_default_runnable(){ command -v "$(cli_exe)" >/dev/null 2>&1 && _cli_run "$(cli_bin)" --version >/dev/null 2>&1; }
_cli_default_uninstall(){ :; }

# --- the interface ------------------------------------------------------------------------------
cli_bin(){ _cli_call bin "$@"; }                       # the command line that runs the CLI (HARNESS_<CLI>_BIN)
cli_exe(){ _cli_exe "$(cli_bin)"; }                    # its executable: what to look for on PATH, or match a pane against
cli_launch(){ _cli_call launch "$@"; }                 # <wd> <uuid> <model> <effort> → the line typed into the pane
cli_lane_settings(){ _cli_call lane_settings "$@"; }   # <wd> → per-lane settings written outside the launch line
cli_model_effort(){ _cli_call model_effort "$@"; }     # <launch line> <wd> → <model>\t<effort> the launch runs with ('' = the CLI's default)
cli_first_input(){ _cli_call first_input "$@"; }       # <effort> → lines typed once the prompt first shows
cli_send(){ _cli_call send "$@"; }                     # <sess> <wd> <text> → deliver a line to the running agent
cli_kill(){ _cli_call kill "$@"; }                     # <sess> <wd> → end the session
cli_session_id(){ _cli_call session_id "$@"; }         # <wd> <uuid> → the CLI's own id for this launch
cli_idle_re(){ _cli_call idle_re; }                    # ERE: the line that is the input prompt
cli_busy_re(){ _cli_call busy_re; }                    # ERE: a turn is running
cli_limit_re(){ _cli_call limit_re; }                  # ERE: a usage/quota limit ended the turn
cli_limit_menu_re(){ _cli_call limit_menu_re; }        # ERE: a blocking limit menu owns the pane ('' = none)
cli_transient_re(){ _cli_call transient_re; }          # ERE: a transient API error ended the turn
cli_dialog_re(){ _cli_call dialog_re; }                # ERE: a dialog/menu owns the pane, never a prompt ('' = none)
cli_loop(){ _cli_call loop; }                          # hook | driven
cli_done(){ _cli_call done "$@"; }                     # <wd> → 0 once the goal loop has ended
cli_last_reply(){ _cli_call last_reply "$@"; }         # <wd> <session id> → last prompt's id, then the reply; rc 1 = turn not over (driven loop)
cli_trust(){ _cli_call trust "$@"; }                   # <dir> → pre-accept the workspace-trust gate
cli_trusted(){ _cli_call trusted "$@"; }               # <dir> → 0 iff pre-accepted
cli_bypass(){ _cli_call bypass "$@"; }                 # <dir> → main session AND sub-agents skip approvals
cli_bypassed(){ _cli_call bypassed "$@"; }             # <dir> → 0 iff that holds
cli_skill(){ _cli_call skill "$@"; }                   # <name> → how a prompt invokes a skill
cli_user_skills_dir(){ _cli_call user_skills_dir; }    # where Harness must copy a user skill itself ('' = none)
cli_transcripts(){ _cli_call transcripts "$@"; }       # <wd> <session id> → transcript paths ('' = unavailable)
cli_usage(){ _cli_call usage "$@"; }                   # <transcript>… → <model>\t<in>\t<out>\t<cache_read>\t<cache_write>
cli_usage_setup(){ _cli_call usage_setup "$@"; }       # <wd> → wire the worktree so cli_limit_usage can see it
# cli_prereqs [--install] → one line per prerequisite; rc 1 = one missing. The adapter's own (binary,
# plugins), then the skills the prompts name through cli_skill (#303), for every CLI alike.
cli_prereqs(){ local rc=0; _cli_call prereqs "$@" || rc=1; _cli_skill_prereq handoff "$@" || rc=1; return $rc; }
cli_runnable(){ _cli_call runnable; }                  # 0 iff the installed binary actually runs
cli_uninstall(){ _cli_call uninstall; }                # remove what Harness installed into the CLI (best-effort)
cli_turn_secs(){ _cli_call turn_secs "$@"; }           # <pane> → seconds the running turn has taken; 0 = no turn; '' = no turn timer
cli_interrupted_re(){ _cli_call interrupted_re; }      # ERE: the line an interrupted turn prints ('' = none: wait for not-busy)
cli_bg_re(){ _cli_call bg_re; }                        # ERE: footer timers/counters that move while work runs
# cli_limit_usage — `<account>\t<window>\t<pct used>\t<resets_at>` lines; rc 1 = unavailable.
# HARNESS_USAGE_CMD overrides the adapter for ANY CLI (an operator's own source, and the test stub).
cli_limit_usage(){
  if [[ -n "${HARNESS_USAGE_CMD:-}" ]]; then bash -c "$HARNESS_USAGE_CMD"; return; fi
  _cli_call limit_usage; }
# _cli_usage_cached <name> <ttl> <fn> — the usage lines <fn> prints, cached <ttl> seconds in the usage
# dir as <name>.tsv (an empty cache = none: rc 1). For a CLI whose usage source is a command that
# fetches from the provider: every worker polls usage, so one fetch serves them all.
_cli_usage_cached(){ local c out now tmp; c="$(_usage_dir)/$1.tsv"; now="$(date +%s)"
  if [[ -f "$c" ]] && (( now - $(stat -c %Y "$c") < $2 )); then
    [[ -s "$c" ]] && { cat "$c"; return 0; }; return 1; fi
  mkdir -p "$(dirname "$c")"
  out="$("$3" 2>/dev/null)"
  # Every worker reads this cache: write a temp file beside it and rename, so no reader sees it half
  # written.
  tmp="$(mktemp "$c.XXXXXX")" || return 1
  printf '%s' "${out:+$out$'\n'}" > "$tmp" && mv -f "$tmp" "$c" || rm -f "$tmp"
  [[ -n "$out" ]] && echo "$out"; }

# --- the skills the prompts name (#303) -------------------------------------------------------
# cli_skills_dir — where this CLI loads user skills from: its own dir (cli_user_skills_dir), else
# ~/.claude/skills (HARNESS_USER_SKILLS), which claude and opencode read and which a hermes or openclaw
# lane gets as an external skill dir (_hermes_seed, _openclaw_config).
cli_skills_dir(){ local d; d="$(cli_user_skills_dir)"; echo "${d:-${HARNESS_USER_SKILLS:-$HOME/.claude/skills}}"; }
# A skill Harness ships carries this line (skill/handoff/SKILL.md). A same-named skill without it is
# the operator's own: Harness never overwrites or removes it.
CLI_SKILL_MARK='<!-- harness-skill:'
# cli_skill_place <src dir> <dst dir> — copy one skill dir, unless <dst> holds the operator's own.
cli_skill_place(){ [[ -f "$2/SKILL.md" ]] && ! grep -qF "$CLI_SKILL_MARK" "$2/SKILL.md" && return 0
  mkdir -p "$2" && cp -R "$1/." "$2/"; }
# _cli_skill_prereq <name> [--install] — the skill is where this CLI loads skills from; --install copies
# the engine's own skill/<name> there.
_cli_skill_prereq(){ local dst src; dst="$(cli_skills_dir)/$1"; src="$(cd "$CLI_DIR/../.." && pwd)/skill/$1"
  if [[ -f "$dst/SKILL.md" ]]; then echo "ok      $(cli_name) skill $1 ($dst)"
  elif [[ "${2:-}" == --install && -f "$src/SKILL.md" ]] && cli_skill_place "$src" "$dst"; then
    echo "ok      $(cli_name) skill $1 ($dst, installed)"
  else echo "MISSING $(cli_name) skill $1 ($dst): mkdir -p $dst && cp -R $src/. $dst/"; return 1; fi; }

# --- the command line (#272) -------------------------------------------------------------------
# HARNESS_<CLI>_BIN is a command line, not one executable: hosts pin the account with
# `env CLAUDE_CONFIG_DIR=… claude`. The launch line runs it whole; anything that needs the executable
# (a PATH check, a pane's command, the unit's PATH) takes _cli_exe of it. Words split on whitespace,
# so a value with a space in it is not supported.
# _cli_exe <command line> — its first word that is not `env`, an env option, or a NAME=value.
_cli_exe(){ local w env= skip=; local -a ws; read -ra ws <<<"$1"
  for w in "${ws[@]}"; do
    if [[ -n $skip ]]; then skip=; continue; fi
    case "$w" in
      env|*/env) env=1;;
      [A-Za-z_]*=*) [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "$w"; return; };;
      -u|-C|-S|--unset|--chdir|--split-string) [[ -n $env ]] || { echo "$w"; return; }; skip=1;;
      -*) [[ -n $env ]] || { echo "$w"; return; };;
      *) echo "$w"; return;;
    esac
  done; }
# _cli_run <command line> [args…] — run it, its words split (an `env` prefix applies its env).
_cli_run(){ local -a ws; read -ra ws <<<"$1"; shift; "${ws[@]}" "$@"; }

# --- pane helpers over the regexes (an empty regex matches nothing) ---------------------------
_cli_re_hits(){ [[ -n "$1" ]] && printf '%s\n' "$2" | grep -qE -- "$1"; }
# cli_pane_busy <pane> — a turn is running.
cli_pane_busy(){ _cli_re_hits "$(cli_busy_re)" "$1"; }
# cli_pane_prompt <pane> — the pane shows the input prompt and no dialog owns it.
cli_pane_prompt(){ _cli_re_hits "$(cli_idle_re)" "$1" && ! cli_pane_dialog "$1"; }
# cli_pane_prompt_line <pane> — line number of the LAST input-prompt line, 0 if none. The last one:
# a CLI that echoes each submitted prompt at the prompt's own column (agy) leaves earlier matches
# in the scrollback above the live input box.
cli_pane_prompt_line(){ local re; re="$(cli_idle_re)"; [[ -n "$re" ]] || { echo 0; return; }
  printf '%s\n' "$1" | grep -nE -- "$re" | tail -1 | cut -d: -f1 | grep . || echo 0; }
# cli_prompt_text <line> — a prompt line with the prompt itself stripped: the text typed into it.
cli_prompt_text(){ local re; re="$(cli_idle_re)"
  if [[ -n "$re" && $1 =~ $re ]]; then printf '%s\n' "${1#"${BASH_REMATCH[0]}"}"; else printf '%s\n' "$1"; fi; }
# cli_pane_dialog <pane> — a dialog owns the pane. Only its foot is read: a dialog is drawn at the
# bottom, and the same words higher up are scrollback (an agent quoting them), not a dialog.
cli_pane_dialog(){ _cli_re_hits "$(cli_dialog_re)" "$(printf '%s\n' "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | tail -n 15)"; }

# _cli_flags <flags> <model> <effort> — the configured flags with --model/--effort replaced by the
# lane's own when it names one, so a launch line never carries the flag twice.
_cli_flags(){ local f=" $1 "
  [[ -n "$2" ]] && f="$(sed -E 's/ --model[= ][^ ]+//g' <<<"$f") --model $2"
  [[ -n "$3" ]] && f="$(sed -E 's/ --effort[= ][^ ]+//g' <<<"$f") --effort $3"
  f="$(tr -s ' ' <<<"$f")"; f="${f# }"; echo "${f% }"; }
# _cli_line_opt <line> <ERE: an option and its separator> — the value the LAST such option in a launch
# line gives (up to the next space, quotes dropped); empty when the line names none. `(-m|--model)[= ]`
# reads `-m x`, `--model x` and `--model=x`; `-c model_reasoning_effort=` reads codex's config override.
_cli_line_opt(){ local v; v="$(grep -oE -- "(^| )($2)[^ ]+" <<<"$1" | tail -1)"; v="${v# }"
  v="$(sed -E "s/^($2)//" <<<"$v")"; v="${v//\"/}"; printf '%s' "${v//\'/}"; }

for _cli_f in "$CLI_DIR"/*.sh; do [[ "${_cli_f##*/}" == dispatch.sh || "${_cli_f##*/}" == *-loop.sh ]] || source "$_cli_f"; done
unset _cli_f

#!/usr/bin/env bash
# supervise.sh — #180: `harness supervise`, the HOST-level supervisor. Nothing else watches the
# fleets from outside: a pool worker that dies cannot restart itself, and a session frozen at its
# prompt holds its lock forever. One supervisor covers every fleet on the host; on each pass, for
# every fleet that is not PAUSED and still has worker pid files (a fleet stopped on purpose has
# none and is skipped entirely):
#   1. dead pool/priority worker (pid file present, process gone)            -> `harness start`
#   2. orphan lock: open issue labelled agent-working, no live <prefix>-* session for it, label
#      older than LOCK_GRACE                                                  -> remove label + comment
#      (a backstop to the in-engine reap, #179)
#   3. frozen session: no ACTIVITY for NUDGE_MIN -> nudge (at most once per RENUDGE_S); the nudge
#      ignored and still no activity at KILL_MIN -> checkpoint the work to GitHub, then kill (the
#      pool reaps and re-dispatches). Activity = the pane text above the input prompt changed, a
#      background-agent/shell timer in the footer moved, or the pane's process tree used more than
#      CPU_ACTIVE_S CPU seconds since the last pass, or the session's own activity mark moved (a headless
#      lane: its turn count or event log, #351 — its drawn screen shows no reply text, so a turn that
#      ran between two passes leaves it unchanged). Only an idle input prompt is ever typed into —
#      never a dialog or menu — and panes showing a usage/credit/rate-limit message are left alone.
#      Checked before activity: a pane in ONE turn for HARNESS_TURN_MAX with input queued in its box,
#      or with a Harness nudge still queued a pass later, is never "quiet" (its spinner timer ticks),
#      yet nothing typed into it lands -> Escape, wait for `Interrupted`, Enter (#207; rule 4 too).
#      A headless lane (the headless session backend, #351) gets every one of these rules: its
#      screen is its state.json drawn in the claude TUI's shapes (spinner + turn timer, limit and
#      interrupt lines, queued inbox messages in the input box), its CPU is its runner's process tree,
#      and a nudge, an interrupt and a kill go to its inbox / interrupt / stop files. No tmux needed.
#   4. non-Harness agent panes (EXTRA_RE, host config): the same activity test, nudge only, never
#      killed — nothing re-dispatches them.
#   5. host offline: hold every action; on reconnect re-arm every pane so quiet ones are nudged at once.
#   6. arc stall rules (#181, the old harness-arc watch.py), each strike-counted over 2+ passes with
#      the counts on disk ($HARNESS_HOME/supervise/rules/<prefix>.json) so a restart resets nothing:
#      auto-fixed: wedged session (STOP_HOOK_BLOCK_CAP in its pane) -> checkpoint + kill; zombie
#      session (its issue closed) -> kill, checkpointing first if it holds unpushed work; unlocked
#      work (live session, no agent-working label) -> re-label. Alarm only (a human decides):
#      review loop, no frontier, decompose stalled, unfiled plan tasks, missing ## Parent,
#      wayfinder leak, deep context. Alarms go to the log; `--alarms` lists the ones still firing.
#   7. auto-update (#477): a published release is installed by the host, not by an operator. Each pass
#      checks the latest release at most once per HARNESS_AUTO_UPDATE_EVERY (600 s) and, when it is
#      newer than the installed one, runs `harness update` from the stable engine link, then rolls the
#      workers of EVERY fleet onto it (scripts/roll.sh: only worker/priority processes not already on
#      the new release, each under the fleet's pool.lock, never one holding a bug claim, never a lane
#      session; `harness start` relaunches them). HARNESS_AUTO_UPDATE_HEALTH_S (120 s) after the roll a
#      dead worker or priority pid -> `harness update --rollback`, roll again onto the old release,
#      the bad tag is never retried, and one `bug` is filed on the engine's own repo. The phase of an
#      update lives in $HARNESS_HOME/supervise/auto-update.json, so the supervisor the update restarts
#      (`supervise.sh --install` in update.sh) resumes the roll and the health check. Off with
#      HARNESS_AUTO_UPDATE=0; never on a HARNESS_REF pin, a git-checkout engine, or an engine that is not
#      a release of this host; never a downgrade or a re-install of the installed release.
# Every action is logged to $HARNESS_HOME/supervise.log.
#
# usage: harness supervise [--once] [--dry-run] | --alarms | --install | --uninstall
#   --alarms     list every arc alarm still firing, per fleet
#   --install    write + enable a systemd user unit (Restart=always, linger) running this loop;
#                `harness update` re-runs it so the unit follows the engine. On Windows: a Task
#                Scheduler task Harness\harness-supervise[-<hash>] (per HARNESS_HOME, logon-only) instead (#356, #489)
#   --uninstall  stop, disable and remove that unit
#   --once       one pass, actions echoed too        --dry-run  log what it would do, do nothing
#
# Host config: $HARNESS_HOME/supervise.conf (bash assignments) sets any knob below, e.g.
#   EXTRA_RE='^hg2(-loops)?$'
set -uo pipefail
SUP_ENGINE_DIR="${ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HARNESS_HOME="${HARNESS_HOME:-$HOME/.harness}"
HARNESS_FLEETS_DIR="${HARNESS_FLEETS_DIR:-$HARNESS_HOME/fleets}"
SUP_CONF="${HARNESS_SUPERVISE_CONF:-$HARNESS_HOME/supervise.conf}"
[[ -f "$SUP_CONF" ]] && source "$SUP_CONF"
: "${INTERVAL:=300}" "${LOCK_GRACE:=1200}" "${NUDGE_MIN:=45}" "${KILL_MIN:=120}"
: "${RENUDGE_S:=10800}" "${CPU_ACTIVE_S:=10}" "${EXTRA_RE:=}" "${EXTRA_MIN:=60}"
: "${ONLINE_URL:=https://api.anthropic.com}" "${UNPARENTED_OK:=}"
: "${HARNESS_AUTO_UPDATE:=1}" "${HARNESS_AUTO_UPDATE_EVERY:=600}" "${HARNESS_AUTO_UPDATE_HEALTH_S:=120}"
SUP_STATE="${HARNESS_SUPERVISE_STATE:-$HARNESS_HOME/supervise}"
SUP_LOG="${HARNESS_SUPERVISE_LOG:-$HARNESS_HOME/supervise.log}"
source "$SUP_ENGINE_DIR/scripts/turn.sh"   # #207: stuck-turn detection + interrupt (after supervise.conf, which may set HARNESS_TURN_MAX)
source "$SUP_ENGINE_DIR/scripts/session/dispatch.sh"   # #346: every pane it reads, types into or kills (sess_*)
source "$SUP_ENGINE_DIR/scripts/cli/dispatch.sh"   # #188: each CLI's pane regexes (cli_with <cli> …)
[[ -f "$SUP_ENGINE_DIR/scripts/roll.sh" ]] && source "$SUP_ENGINE_DIR/scripts/roll.sh"   # #477: fleet_roll, shared with `harness update`
# The unit and every restart go through the STABLE engine path bin/harness exported (#281), so a
# release flip takes effect on restart without rewriting the unit. Taken only when it resolves to
# this engine: a link inherited from some other engine's environment never redirects the unit.
SUP_LINK="${HARNESS_ENGINE_LINK:-$SUP_ENGINE_DIR}"
[[ "$(realpath -m "$SUP_LINK" 2>/dev/null)" == "$(realpath -m "$SUP_ENGINE_DIR" 2>/dev/null)" ]] || SUP_LINK="$SUP_ENGINE_DIR"
SUP_HARNESS="${HARNESS_SUPERVISE_HARNESS:-$SUP_LINK/bin/harness}"
SUP_RULES="${HARNESS_SUPERVISE_RULES:-$SUP_ENGINE_DIR/scripts/supervise_rules.py}"
# Fleets the registry does not know (an engine that predates it) are found by this glob too.
SUP_FLEET_GLOB="${HARNESS_SUPERVISE_GLOB:-$HOME/*/.harness}"
# On Windows the "unit" is a Task Scheduler launcher script under $HARNESS_HOME/tasks (#356, portable.sh).
if is_windows; then SUP_UNIT_DIR="${HARNESS_SUPERVISE_UNIT_DIR:-$HARNESS_HOME/tasks}"
else SUP_UNIT_DIR="${HARNESS_SUPERVISE_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"; fi
SUP_UNIT=harness-supervise.service
SUP_SYSTEMCTL="${HARNESS_SUPERVISE_SYSTEMCTL:-systemctl}"
SUP_LOGINCTL="${HARNESS_SUPERVISE_LOGINCTL:-loginctl}"
# Usage / credit / rate-limit messages: such a pane is parked by the account, not frozen (#120). A
# CLI-neutral net, widened per pane by its adapter's own limit strings (sup_limit_re). A bare "usage
# limit" counts only as the end of a phrase or before reached/exceeded/hit/for: Codex's idle pane
# can carry "You have 1 usage limit reset available" (fixtures/cli/codex/idle.txt), which is no park.
SUP_LIMIT_RE='limit reached|usage limit([^ a-z]|$| (reached|exceeded|hit|for))|resets (at|in)|rate.limit|out of (extra )?usage|out of (usage )?credits|hit your [a-z]+ limit'
SUP_NUDGE_MSG="harness supervise: no activity for a while. If your goal is met, finish it now (push, PR, labels); if you are waiting on background work, check it and report; otherwise continue the task."
SUP_EXTRA_MSG="harness supervise: no activity for a while. If an API/network error or a broken wake-up cut you off, resume your task now; if you are waiting on background work, check it, report, and keep your wake-ups going."
SUP_DRY=0 SUP_ONCE=0

sup_log(){ mkdir -p "$(dirname "$SUP_LOG")"; echo "$(date '+%F %T') $*" >>"$SUP_LOG"; (( SUP_ONCE )) && echo "$*"; return 0; }
# A session action logs as the backend's own command line (sess_describe: `tmux send-keys -t … Enter`).
sup_act(){ if (( SUP_DRY )); then sup_log "DRY $(sess_describe "$@")"; else sup_log "ACT $(sess_describe "$@")"; "$@" >>"$SUP_LOG" 2>&1; fi; }
sup_alive(){ [[ -f $1 ]] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }

# --- how each agent CLI's pane reads: the CLI adapters (scripts/cli/, #188) ----------------------
# sup_cli <cli> — <cli> when it has an adapter, else the default CLI (cli_name): every pane
# function below reads the pane through that adapter. Membership is tested on cli_list's whole
# output, never by piping it into `grep -q`: under pipefail the writer's SIGPIPE after an early
# match would read as "no adapter" and send the pane through the wrong CLI's adapter (#339).
sup_cli(){ if [[ $'\n'"$(cli_list)"$'\n' == *$'\n'"$1"$'\n'* ]]; then echo "$1"; else cli_name; fi; }
# sup_prompt_re <cli> — a line that IS the idle input prompt. Everything above the LAST such line
# is the "screen" (sup_prompt_line); a pane with no such line is a dialog or menu and is never typed
# into. HARNESS_SUPERVISE_PROMPT_RE overrides it for every CLI.
sup_prompt_re(){
  [[ -n "${HARNESS_SUPERVISE_PROMPT_RE:-}" ]] && { echo "$HARNESS_SUPERVISE_PROMPT_RE"; return; }
  cli_with "$(sup_cli "$1")" cli_idle_re; }
# sup_prompt_line <cli> <pane> — line number of the last idle-prompt line, 0 if none.
sup_prompt_line(){ printf '%s\n' "$2" | grep -nE -- "$(sup_prompt_re "$1")" | tail -1 | cut -d: -f1 | grep . || echo 0; }
# sup_dialog <cli> <pane> — a dialog owns the pane (agy's trust dialog shows a `>` line at column 0).
sup_dialog(){ cli_with "$(sup_cli "$1")" cli_pane_dialog "$2"; }
# sup_bg_re <cli> — the footer's background-agent / shell timers and token counters; one moving
# means work is in flight even though the screen above the prompt is still. '' = the CLI has none.
sup_bg_re(){ cli_with "$(sup_cli "$1")" cli_bg_re; }
# sup_limit_re <cli> — the CLI-neutral SUP_LIMIT_RE plus the CLI's own limit and limit-menu strings.
sup_limit_re(){ local c re x; c=$(sup_cli "$1"); re=$SUP_LIMIT_RE
  for x in "$(cli_with "$c" cli_limit_re)" "$(cli_with "$c" cli_limit_menu_re)"; do [[ -n $x ]] && re="$re|$x"; done
  echo "$re"; }
# sup_agent_cmds — pane_current_command values that are agent CLIs (for the EXTRA_RE panes).
sup_agent_cmds(){ local c; for c in $(cli_list); do basename "$(cli_with "$c" cli_exe)"; done | paste -sd'|'; }
# sup_cmd_cli <pane command> — the CLI whose binary that is (EXTRA_RE panes); the command itself if none.
sup_cmd_cli(){ local c; for c in $(cli_list); do
    [[ $(basename "$(cli_with "$c" cli_exe)") == "$1" ]] && { echo "$c"; return; }; done; echo "$1"; }
# sup_agent_bins — every agent CLI's binary, the default CLI's first (the unit's PATH must reach
# whichever a fleet runs, and the default one wins a directory-order tie).
sup_agent_bins(){ local c; cli_exe; for c in $(cli_list); do cli_with "$c" cli_exe; done; }

# sup_tree_cpu <pid> — total CPU seconds used by a process and all its descendants.
sup_tree_cpu(){ ps -eo pid=,ppid=,cputimes= 2>/dev/null | awk -v root="$1" '
  { par[$1]=$2; cpu[$1]=$3 } END { s[root]=1; do { ch=0; for (i in par) if (!(i in s) && (par[i] in s)) { s[i]=1; ch=1 } } while (ch)
  for (i in s) t+=cpu[i]; print t+0 }'; }

# sup_watch_pane <tmux target> <state file> <nudge min> <kill min, 0 = never> <nudge text> <cli> [kill fn]
# State file: "<screen hash> <footer hash> <tree cpu> <quiet since> <nudged 0|1> <last nudge>".
# supervise_rules.pane_activity reads this format for `harness web` (#225): change both together.
sup_watch_pane(){
  local t=$1 f=$2 nudge_min=$3 kill_min=$4 msg=$5 cli=$6 killfn=${7:-}
  local pane n bgre body bg cpu now old= oldbg= oldcpu=0 t0 nudged=0 lastn=0 idle
  pane=$(sess_capture "$t") || return 0
  cli=$(sup_cli "$cli")
  # #207: one endless turn with input queued behind it. The spinner's timer changes every second, so
  # the activity test below would call it busy forever — it is checked first, through the pane's CLI.
  if cli_with "$cli" turn_should_interrupt "$pane" "$SUP_STATE/turn/${f##*/}"; then
    cli_with "$cli" sup_turn_interrupt "$t" "$pane" "$SUP_STATE/turn/${f##*/}"; return 0
  fi
  now=$(date +%s); t0=$now; n=$(sup_prompt_line "$cli" "$pane"); bgre=$(sup_bg_re "$cli")
  (( n > 0 )) || n=$(( $(wc -l <<<"$pane") + 1 ))                  # no prompt: it is all screen
  body=$({ awk -v n="$n" 'NR < n' <<<"$pane"; sess_activity "$t"; } | md5sum | cut -c1-12)   # '' from a pane: same hash as ever
  bg=$(awk -v n="$n" 'NR >= n' <<<"$pane" | { [[ -n $bgre ]] && grep -oE -- "$bgre"; } | md5sum | cut -c1-12)
  cpu=$(sup_tree_cpu "$(sess_pane_pid "$t")")
  mkdir -p "$(dirname "$f")"
  [[ -f $f ]] && read -r old oldbg oldcpu t0 nudged lastn <"$f"
  if [[ $body != "$old" || $bg != "$oldbg" ]] || (( cpu - oldcpu > CPU_ACTIVE_S )); then
    echo "$body $bg $cpu $now 0 $lastn" >"$f"; return 0           # active: reset the quiet clock
  fi
  echo "$body $bg $cpu $t0 $nudged $lastn" >"$f"                   # quiet: keep the CPU baseline current
  idle=$(( (now - t0) / 60 ))
  (( $(sup_prompt_line "$cli" "$pane") > 0 )) || return 0           # dialog/menu, not an idle prompt
  sup_dialog "$cli" "$pane" && return 0
  grep -qiE "$(sup_limit_re "$cli")" <<<"$(tail -40 <<<"$pane")" && return 0 # parked at a usage limit
  if (( kill_min > 0 && nudged == 1 && idle >= kill_min )) && [[ -n $killfn ]]; then
    "$killfn" "${t%%:*}" "$idle" "$pane" && rm -f "$f"
  elif (( idle >= nudge_min && nudged == 0 && now - lastn >= RENUDGE_S )); then
    sup_act sess_clear_line "$t"
    sup_act sess_type "$t" "$msg"
    (( SUP_DRY )) || sleep 0.5   # an Enter in the same burst as the text is a newline to hermes (cli_send)
    sup_act sess_enter "$t"
    echo "$body $bg $cpu $t0 1 $now" >"$f"
  fi
  return 0
}

# sup_turn_interrupt <tmux target> <pane text> <turn state file> — #207: Escape the endless turn, wait
# for it to end (turn_interrupt), then Enter so the queued nudges are delivered. A fleet session
# (lib.sh loaded) also gets a turn_interrupted event for `harness stats`.
sup_turn_interrupt(){ local t=$1 pane=$2 tf=$3 secs
  secs=$(turn_secs "$pane")
  sup_log "turn: $t has run one turn for ${secs}s with input queued behind it — Escape, then Enter"
  if (( SUP_DRY )); then sup_act sess_interrupt "$t"; sup_act sess_enter "$t"; return 0; fi
  turn_interrupt "$t" sup_act || { sup_log "turn: $t did not report Interrupted after Escape — retrying next pass"; return 0; }
  rm -f "$tf"
  declare -F stats_sess_event >/dev/null &&
    stats_sess_event "${t%%:*}" turn_interrupted turn_s="$secs" queued_nudges="$(turn_queued_nudges "$pane")" >/dev/null 2>&1
  return 0; }

# sup_checkpoint_and_kill <session> <idle min> <pane text> [why] [stats reason] — never lose a frozen
# (or wedged, or zombie) session's work:
# commit + push its branch (never .claude/ or .harness-task.md, never a force-push; a diverged
# remote gets <branch>-checkpoint-<ts> instead), post a harness-handoff comment with the last screen
# (spawn_impl resumes from origin/issue/N + that handoff), THEN kill. If the work cannot be pushed
# anywhere, do NOT kill — log an ERROR for a human. Runs inside sup_check_fleet (lib.sh sourced for
# that fleet), so the session is parsed by the same _checkpoint_target `pause --force` uses.
sup_checkpoint_and_kill(){
  local s=$1 idle=$2 pane=$3 why=${4:-} reason=${5:-frozen} wd branch= sha= pushed= num= slug= body cpb ex=(':!.claude' ':!.harness-task.md')
  why=${why:-"Session \`$s\` showed no activity for ${idle} min (no screen change, no background timer, no CPU in its process tree) and did not react to a nudge, so it was restarted."}
  _CP_ISSUE= _CP_SLUG= _CP_BRANCH=
  if _checkpoint_target "$s"; then num=$_CP_ISSUE slug=$_CP_SLUG
  elif [[ $s =~ ^${HARNESS_SESS_PREFIX}-(.+)-p([0-9]+)$ ]]; then          # orch (decompose/review)
    num=${BASH_REMATCH[2]}; slug=$(unit_slug "${BASH_REMATCH[1]}")
  fi
  wd=$(cat "$RUN_DIR/$s.wd" 2>/dev/null)
  if [[ -n $_CP_BRANCH && -n $wd && -d $wd ]]; then                     # a session with code to keep
    branch=$(git -C "$wd" symbolic-ref --short -q HEAD)
    if [[ -z $branch || $branch == main || $branch == master ]]; then
      sup_log "ERROR $s: $wd is not on a feature branch (${branch:-detached}) — NOT killing; needs a human"; return 1
    fi
    if [[ -n $(git -C "$wd" status --porcelain -- . "${ex[@]}") ]]; then
      sup_act git -C "$wd" add -A -- . "${ex[@]}"
      sup_act git -C "$wd" reset -q -- .claude .harness-task.md        # even if the agent staged them
      sup_act git -C "$wd" commit -q --no-verify -m "wip: harness supervise checkpoint of frozen session $s (#$num)" \
        || { sup_log "ERROR $s: could not commit the WIP in $wd — NOT killing; needs a human"; return 1; }
    fi
    sha=$(git -C "$wd" rev-parse --short HEAD)
    cpb="$branch-checkpoint-$(date +%Y%m%d%H%M)"
    if sup_act git -C "$wd" push -q origin "HEAD:refs/heads/$branch"; then pushed=$branch
    elif sup_act git -C "$wd" push -q origin "HEAD:refs/heads/$cpb"; then
      pushed="$cpb (origin/$branch had diverged; merge it by hand)"
    else
      sup_log "ERROR $s: could not push $branch from $wd — NOT killing; needs a human"; return 1
    fi
  fi
  body="<!-- harness-handoff issue=$num${branch:+ branch=$branch} -->
## Checkpoint by harness supervise
$why
${pushed:+All work in progress was committed and pushed to \`$pushed\` @ \`$sha\`. }This was a mechanical checkpoint, not the agent's own handoff. Rebuild context from the branch's commits and diff against the base.

Last screen:
\`\`\`
$(tail -30 <<<"$pane" | cut -c1-200)
\`\`\`"
  [[ -n $slug && -n $num ]] && sup_act gh issue comment "$num" -R "$slug" --body "$body"
  sup_act sess_kill "=$s"
  (( SUP_DRY )) || stats_sess_event "$s" watchdog_kill reason="$reason" >/dev/null 2>&1
  return 0
}

# sup_kill_zombie <session> — rule 6: a session still alive after its issue closed holds a worktree
# and can still push. Nothing of its own to keep -> just kill it; uncommitted or unpushed work ->
# checkpoint it to GitHub first, exactly like a frozen session.
sup_kill_zombie(){ local s=$1 wd
  wd=$(cat "$RUN_DIR/$s.wd" 2>/dev/null)
  if [[ -n $wd && -d $wd ]] && [[ -n $(git -C "$wd" status --porcelain -- . ':!.claude' ':!.harness-task.md' 2>/dev/null) \
       || -n $(git -C "$wd" rev-list -n1 HEAD --not --remotes 2>/dev/null) ]]; then
    sup_checkpoint_and_kill "$s" 0 "$(sess_capture "$s")" \
      "Session \`$s\` was still alive after its issue closed, holding a worktree that could still push, so it was stopped." zombie
    return
  fi
  sup_act sess_kill "=$s"
  (( SUP_DRY )) || stats_sess_event "$s" watchdog_kill reason=zombie >/dev/null 2>&1
  return 0
}

# sup_session_rows <sessions> — `<session>\t<slug>\t<issue>\t<kind>` per live session, the input
# supervise_rules.py reads. Parsed by the same _checkpoint_target `pause --force` uses.
sup_session_rows(){ local s kind
  for s in $1; do
    _CP_ISSUE= _CP_SLUG= _CP_BRANCH=
    if _checkpoint_target "$s"; then
      [[ $s == "$HARNESS_SESS_PREFIX"-bug-* ]] && kind=bug || kind=impl
      printf '%s\t%s\t%s\t%s\n' "$s" "$_CP_SLUG" "$_CP_ISSUE" "$kind"
    elif [[ $s =~ ^${HARNESS_SESS_PREFIX}-(.+)-p([0-9]+)$ ]]; then
      printf '%s\t%s\t%s\torch\n' "$s" "$(unit_slug "${BASH_REMATCH[1]}")" "${BASH_REMATCH[2]}"
    else
      printf '%s\t\t\tother\n' "$s"
    fi
  done; }

# sup_arc_rules <sessions> — rule 6, inside sup_check_fleet. supervise_rules.py judges (and keeps
# the strike + round counters on disk); this acts on its FIX lines and logs its ALARM/RESOLVED ones.
# Reads come from the host poller's snapshots when every one is fresh, so a pass costs no gh calls.
sup_arc_rules(){ local sessions=$1 slugs sl line s slug num counters fresh=1
  slugs=$(snapshot_slugs); [[ -n $slugs ]] || return 0
  for sl in $slugs; do ensure_snapshot_fresh "$sl" || fresh=0; done
  if (( fresh )) && poller_enabled; then
    export HARNESS_SNAPSHOT_DIR="$HARNESS_SNAPSHOTS_DIR"
    export HARNESS_SNAPSHOT_FILE="$(poller_snapshot_path "$(head -n1 <<<"$slugs")")"
  fi
  counters="$SUP_STATE/rules/$HARNESS_SESS_PREFIX.json"
  if (( SUP_DRY )); then                                   # a preview must not advance the strikes
    mkdir -p "$SUP_STATE/rules"; cp "$counters" "$counters.dry" 2>/dev/null || rm -f "$counters.dry"
    counters="$counters.dry"
  fi
  while read -r line; do
    case $line in
      "FIX wedged "*) s=${line#FIX wedged }
        sup_checkpoint_and_kill "$s" 0 "$(sess_capture "$s")" \
          "Session \`$s\` hit the stop-hook block cap (\`STOP_HOOK_BLOCK_CAP\`): its loop will not resume and it held its issue lock, so it was restarted." wedged ;;
      "FIX zombie "*) sup_kill_zombie "${line#FIX zombie }" ;;
      "FIX unlocked "*) read -r _ _ slug num <<<"$line"
        sup_act gh issue edit "$num" -R "$slug" --add-label "$HARNESS_LABEL_WORKING" ;;
      ALARM\ *|RESOLVED\ *) sup_log "$line [fleet $HARNESS_SESS_PREFIX]" ;;
    esac
  done < <(sup_session_rows "$sessions" | UNPARENTED_OK="$UNPARENTED_OK" python3 "$SUP_RULES" --counters "$counters" --repo-dir "$PROJECT_ROOT" \
             --reconciled "$STATE_DIR/reconciled-plans" $slugs 2>>"$SUP_LOG")
  rm -f "$SUP_STATE/rules/$HARNESS_SESS_PREFIX.json.dry"
}

# sup_clean_env — drop any inherited fleet config before sourcing lib.sh for ANOTHER fleet. Config
# lines are `: "${VAR:=…}"`, so an inherited HARNESS_PREFIX/… (a `harness supervise --once` run from
# inside a fleet session) would beat the fleet's own file. Path seams (*_DIR/_HOME/_FILE/CONFIG*)
# and the supervisor's own knobs are kept.
sup_clean_env(){ local v
  for v in $(compgen -v HARNESS_); do
    case $v in *_DIR|*_DIRS|*_HOME|*_FILE|*CONFIG*|HARNESS_SUPERVISE_*) ;; *) unset "$v" ;; esac
  done
  unset STATE_DIR RUN_DIR CLAIMS_DIR POOL_LOCK PAUSE_FLAG; }

# sup_check_fleet <state dir> — rules 1-3 and 6 for one fleet, in a subshell with that fleet's lib.sh.
sup_check_fleet(){ local sd=$1
  ( sup_clean_env; export STATE_DIR="$sd" ENGINE_DIR="$SUP_ENGINE_DIR"
    source "$SUP_ENGINE_DIR/scripts/lib.sh" >/dev/null 2>&1 || exit 0
    is_paused && exit 0
    shopt -s nullglob; local pids=("$RUN_DIR"/worker-*.pid); shopt -u nullglob
    (( ${#pids[@]} )) || exit 0                                     # stopped on purpose
    local prefix=$HARNESS_SESS_PREFIX lw=$HARNESS_LABEL_WORKING

    # 1. dead workers
    local dead=0 pf n
    for pf in "${pids[@]}"; do
      n=${pf##*worker-}; n=${n%.pid}
      [[ $n =~ ^[0-9]+$ ]] && (( n <= POOL )) && ! sup_alive "$pf" && dead=1
    done
    [[ -f $RUN_DIR/priority.pid ]] && ! sup_alive "$RUN_DIR/priority.pid" && dead=1
    (( dead )) && sup_act env -C "$PROJECT_ROOT" "$SUP_HARNESS" --state-dir "$STATE_DIR" start

    # 2. orphan agent-working locks
    local sessions repo nums num since age
    sessions=$(sess_list | grep "^$prefix-")
    for repo in $(snapshot_slugs); do
      if ! nums=$(gh issue list -R "$repo" --label "$lw" --state open --json number --jq '.[].number' 2>&1); then
        sup_log "WARN $repo: gh unreachable (${nums:0:120})"; continue
      fi
      for num in $nums; do
        grep -qE -- "-[ip]?$num(-|\$)" <<<"$sessions" && continue
        since=$(gh api "repos/$repo/issues/$num/timeline" --paginate \
          --jq "[.[]|select(.event==\"labeled\" and .label.name==\"$lw\")|.created_at]|last // empty" 2>/dev/null | tail -1)
        [[ -n $since ]] || continue
        age=$(( $(date +%s) - $(date -d "$since" +%s) ))
        (( age >= LOCK_GRACE )) || continue
        sup_act gh issue edit "$num" -R "$repo" --remove-label "$lw"
        sup_act gh issue comment "$num" -R "$repo" --body "harness supervise: cleared stale \`$lw\` (no live \`$prefix-*\` session for this issue; locked since $since). The pool will re-dispatch it."
      done
    done

    # 3. frozen sessions
    local s f
    for s in $sessions; do
      sup_watch_pane "$s" "$SUP_STATE/panes/$s" "$NUDGE_MIN" "$KILL_MIN" "$SUP_NUDGE_MSG" "$(cli_name)" sup_checkpoint_and_kill
    done
    for f in "$SUP_STATE"/{panes,turn}/"$prefix"-*; do               # forget panes of ended sessions
      [[ -e $f ]] && ! sess_live "=${f##*/}" && rm -f "$f"
    done

    # 6. arc stall rules (sessions killed by rule 3 above are gone from tmux, so re-list)
    sup_arc_rules "$(sess_list | grep "^$prefix-")"
    exit 0 )
}

# sup_check_extra — rule 4: non-Harness agent panes whose session matches EXTRA_RE. Nudge only.
sup_check_extra(){ local t cmd
  [[ -n $EXTRA_RE ]] || return 0
  while read -r t cmd; do
    sup_watch_pane "$t" "$SUP_STATE/panes/x_$(tr ':.' '__' <<<"$t")" "$EXTRA_MIN" 0 "$SUP_EXTRA_MSG" "$(sup_cmd_cli "$cmd")"
  done < <(sess_panes \
           | awk -v re="$EXTRA_RE" -v cmds="^($(sup_agent_cmds))\$" '$2 ~ cmds { split($1,a,":"); if (a[1] ~ re) print }')
}

# sup_net_gate — rule 5: while the host is offline a nudge only hits the same dead network (and burns
# the RENUDGE_S throttle), so hold every action; when it returns, re-arm every pane so the quiet ones
# are nudged on the very next pass instead of hours later.
sup_net_gate(){ local f a b c
  mkdir -p "$SUP_STATE/panes"
  if ! curl -s -m 15 -o /dev/null "$ONLINE_URL"; then
    [[ -f $SUP_STATE/offline ]] || { sup_log "WARN network down ($ONLINE_URL unreachable): holding all actions"; touch "$SUP_STATE/offline"; }
    return 1
  fi
  [[ -f $SUP_STATE/offline ]] || return 0
  sup_log "network back: re-arming every pane for an immediate nudge"; rm -f "$SUP_STATE/offline"
  for f in "$SUP_STATE"/panes/*; do [[ -f $f ]] && read -r a b c _ <"$f" && echo "$a $b $c 0 0 0" >"$f"; done
  return 0
}

# sup_fleets — every fleet's STATE_DIR on this host, once each: the host fleet registry (written by
# `harness start`) plus SUP_FLEET_GLOB for fleets the registry does not know.
sup_fleets(){ local d
  { python3 - "$HARNESS_FLEETS_DIR" <<'PY' 2>/dev/null
import json, os, sys
d = sys.argv[1]
for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
    if name.endswith(".json"):
        try:
            print(json.load(open(os.path.join(d, name))).get("project") or "")
        except (OSError, ValueError):
            pass
PY
    for d in $SUP_FLEET_GLOB; do echo "$d"; done
  } | while read -r d; do [[ -n $d && -f $d/config ]] && realpath "$d"; done | awk '!seen[$0]++'
}

sup_pass(){ local sd
  sup_net_gate || return 0
  sup_auto_update
  while read -r sd; do sup_check_fleet "$sd"; done < <(sup_fleets)
  sup_check_extra
}

# --- auto-update (#477) -----------------------------------------------------------------------------
SUP_AU_STATE="$SUP_STATE/auto-update.json" SUP_AU_SKIP="$SUP_STATE/auto-update.skip"
SUP_AU_CHECKED="$SUP_STATE/auto-update.checked" SUP_AU_BUGS="$SUP_STATE/auto-update.bugs"
SUP_AU_TERM=0
# sup_event <event> [k=v …] — a host event (events.jsonl); never fails the pass, never written by a dry run.
sup_event(){ (( SUP_DRY )) && return 0
  HARNESS_HOME="$HARNESS_HOME" timeout 10 python3 "$SUP_ENGINE_DIR/scripts/stats.py" emit "$@" -c "prefix=supervise" >/dev/null 2>&1 \
    || sup_log "WARN auto-update: event $1 not written"; return 0; }
# sup_au_get <key> / sup_au_put k=v … — the update's phase, kept on disk so the NEXT supervisor process
# (the unit restarts this one in the middle of `harness update`) picks the roll and health check up.
sup_au_get(){ python3 - "$SUP_AU_STATE" "$1" <<'PY' 2>/dev/null
import json, sys
try: v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
except (OSError, ValueError): v = ""
print(v)
PY
}
sup_au_put(){ (( SUP_DRY )) && return 0; mkdir -p "$SUP_STATE"
  python3 - "$SUP_AU_STATE" "$@" <<'PY'
import json, os, sys
p = sys.argv[1]
try: d = json.load(open(p))
except (OSError, ValueError): d = {}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    d[k] = int(v) if v.lstrip("-").isdigit() and k in ("roll_done", "flipped_at", "rolled_at") else v
tmp = p + ".tmp"
with open(tmp, "w") as f: json.dump(d, f)
os.replace(tmp, p)
PY
}
sup_au_clear(){ (( SUP_DRY )) || rm -f "$SUP_AU_STATE"; }
# sup_rel <fn> [args] — install.sh's release functions (rel_latest_tag, semver_cmp, engine_current,
# engine_version), in a subshell: the file defines far more than a supervisor wants in its namespace.
sup_rel(){ ( export HARNESS_HOME; HARNESS_INSTALL_NOMAIN=1 source "$SUP_ENGINE_DIR/install.sh" || exit 3; "$@" ); }
# sup_au_enabled — this supervisor is a release engine of THIS host and the operator left it on.
sup_au_enabled(){ [[ ${HARNESS_AUTO_UPDATE:-1} != 0 && -z ${HARNESS_REF:-} && -L $HARNESS_HOME/engine ]] || return 1
  [[ "$(realpath -m "$SUP_ENGINE_DIR" 2>/dev/null)" == "$(realpath -m "$HARNESS_HOME/releases" 2>/dev/null)"/* ]]; }
# sup_au_harness <args> — `harness <args>` through the stable engine link, in the clean env bin/harness
# expects. TERM is held while it runs: `harness update` restarts THIS unit, and the supervisor must
# survive that long enough to start the roll (the state file covers a hard kill).
sup_au_harness(){ local rc
  trap 'SUP_AU_TERM=1' TERM
  env -u STATE_DIR -u ENGINE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF HARNESS_HOME="$HARNESS_HOME" \
    bash "$HARNESS_HOME/engine/bin/harness" "$@" >>"$SUP_LOG" 2>&1 </dev/null 8>&-; rc=$?
  trap - TERM; return $rc; }

# sup_au_roll — roll the workers of every registered fleet onto the engine the link names now. Sets
# SUP_AU_DEFERRED (workers left for a later pass: a bug claim) and SUP_AU_DEAD.
sup_au_roll(){ local sd want res k d x name
  SUP_AU_DEFERRED=0 SUP_AU_DEAD=0
  want="$(realpath -m "$HARNESS_HOME/engine")"
  while read -r sd; do
    res="$(mktemp)"
    ( exec 8>&-                                   # the auto-update lock fd: a relaunched worker must never inherit it
      sup_clean_env; export STATE_DIR="$sd"
      ROLL_RESULT="$res" ROLL_LOG=sup_log fleet_roll "$sd" "$want" "$HARNESS_HOME/engine/bin/harness" "$SUP_DRY" )
    read -r k d x <"$res"; rm -f "$res"
    SUP_AU_DEFERRED=$((SUP_AU_DEFERRED + ${d:-0})); SUP_AU_DEAD=$((SUP_AU_DEAD + ${x:-0}))
    name="$(basename "$(dirname "$sd")")"
    (( ${k:-0} + ${d:-0} > 0 )) && sup_event workers_rolled fleet="$name" killed="${k:-0}" deferred="${d:-0}" -c "project=$(dirname "$sd")"
  done < <(sup_fleets)
}
# sup_au_dead_pids — every worker / priority pid file whose process is gone, over every fleet.
sup_au_dead_pids(){ local sd pf
  shopt -s nullglob
  while read -r sd; do
    for pf in "$sd"/run/worker-*.pid "$sd"/run/priority.pid; do [[ -f $pf ]] && ! sup_alive "$pf" && echo "$pf"; done
  done < <(sup_fleets)
  shopt -u nullglob; }
# sup_au_file_bug <bad tag> <good tag> <dead pid files> — one bug on the engine's own repo, never two for a tag.
sup_au_file_bug(){ local bad=$1 good=$2 dead=$3 repo="${HARNESS_RELEASE_REPO:-VocanicZ/Harness}"
  grep -qxF "$bad" "$SUP_AU_BUGS" 2>/dev/null && return 0
  if sup_act gh issue create -R "$repo" --label bug \
       --title "Release $bad: fleet workers died after the auto-update — rolled back to $good" \
       --body "harness supervise installed release \`$bad\` and rolled every fleet's workers onto it, and $HARNESS_AUTO_UPDATE_HEALTH_S s later these worker pids were dead:

$(sed 's/^/- /' <<<"$dead")

It ran \`harness update --rollback\` (the engine is on \`$good\` again), rolled the workers back, and will never retry \`$bad\`; the next release is installed automatically. Fix forward. Supervise log: \`$SUP_LOG\`." >>"$SUP_LOG" 2>&1; then
    (( SUP_DRY )) || echo "$bad" >>"$SUP_AU_BUGS"
  else sup_log "ERROR auto-update: could not file the bug for $bad on $repo"; fi
}
# sup_au_rollback <bad tag> <previous tag> <dead pid files>
sup_au_rollback(){ local bad=$1 prev=$2 dead=$3 cur
  sup_log "ERROR auto-update: $bad is unhealthy — dead: $(tr '\n' ' ' <<<"$dead")— rolling back to $prev"
  mkdir -p "$SUP_STATE"; grep -qxF "$bad" "$SUP_AU_SKIP" 2>/dev/null || echo "$bad" >>"$SUP_AU_SKIP"   # first: a crash below never retries it
  sup_au_put phase=rollback
  sup_au_harness update --rollback || sup_log "ERROR auto-update: harness update --rollback failed"
  cur="$(sup_rel engine_current)"
  sup_au_put tag="$cur" prev="$bad" phase=rolling roll_done=0 health=ok rolled_at="$(date +%s)"
  sup_event engine_rolled_back from="$bad" to="${cur:-unknown}" reason="workers dead $HARNESS_AUTO_UPDATE_HEALTH_S s after the update: $(tr '\n' ' ' <<<"$dead")"
  sup_au_roll
  (( SUP_AU_DEFERRED )) || sup_au_put roll_done=1
  sup_au_file_bug "$bad" "${cur:-$prev}" "$dead"
}
# sup_au_progress — an update that is under way (state on disk): finish the roll, then the health
# check. rc 0: handled (the pass does no new release check); rc 1: nothing under way.
sup_au_progress(){ local phase tag prev cur now rolled dead
  phase="$(sup_au_get phase)"; [[ -n $phase && $phase != done ]] || return 1
  tag="$(sup_au_get tag)"; prev="$(sup_au_get prev)"; cur="$(sup_rel engine_current)"; now=$(date +%s)
  if [[ $phase == installing ]]; then
    if [[ $cur != "$tag" ]]; then sup_log "WARN auto-update: the update to $tag did not complete (engine is $cur) — trying again next cycle"; sup_au_clear; return 0; fi
    sup_au_put phase=rolling; sup_event engine_updated from="$prev" to="$tag"; phase=rolling
  fi
  if [[ $cur != "$tag" ]]; then sup_log "auto-update: the engine moved to $cur by hand — dropping the $tag roll"; sup_au_clear; return 1; fi
  if [[ "$(sup_au_get roll_done)" != 1 ]]; then
    sup_au_roll
    rolled="$(sup_au_get rolled_at)"; [[ -n $rolled ]] || sup_au_put rolled_at="$now"
    (( SUP_AU_DEFERRED )) || sup_au_put roll_done=1
  fi
  rolled="$(sup_au_get rolled_at)"
  if [[ "$(sup_au_get health)" == pending && -n $rolled ]] && (( now - rolled >= HARNESS_AUTO_UPDATE_HEALTH_S )) && (( ! SUP_DRY )); then
    dead="$(sup_au_dead_pids)"
    if [[ -z $dead ]]; then sup_au_put health=ok; sup_log "auto-update: $tag is healthy on every fleet"
    else sup_au_rollback "$tag" "$prev" "$dead"; return 0; fi
  fi
  [[ "$(sup_au_get roll_done)" == 1 && "$(sup_au_get health)" == ok ]] && sup_au_put phase=done
  return 0
}
# sup_au_check — look for a newer release (at most every HARNESS_AUTO_UPDATE_EVERY s) and install it.
sup_au_check(){ local now last tag rc cur order
  now=$(date +%s); last=$(cat "$SUP_AU_CHECKED" 2>/dev/null); last=${last:-0}
  (( now - last >= HARNESS_AUTO_UPDATE_EVERY )) || return 0
  (( SUP_DRY )) || { mkdir -p "$SUP_STATE"; echo "$now" >"$SUP_AU_CHECKED"; }
  tag="$(sup_rel rel_latest_tag 2>&1)"; rc=$?
  if (( rc == 2 )); then sup_log "WARN auto-update: the release query named no release — trying again next cycle"; return 0
  elif (( rc != 0 )); then sup_log "WARN auto-update: could not resolve the latest release (${tag:0:160}) — trying again next cycle"; return 0; fi
  cur="$(sup_rel engine_version)"
  if ! order="$(sup_rel semver_cmp "$tag" "$cur")"; then
    sup_log "WARN auto-update: cannot tell whether release \"$tag\" is newer than $cur (not [v]MAJOR.MINOR.PATCH) — skipped"; return 0
  fi
  (( order > 0 )) || return 0
  grep -qxF "$tag" "$SUP_AU_SKIP" 2>/dev/null && return 0              # rolled back once: never again
  if (( SUP_DRY )); then
    sup_log "DRY auto-update: would update $cur -> $tag (harness update), then roll the workers of every fleet"
    return 0
  fi
  sup_log "ACT auto-update: $cur -> $tag"
  sup_au_put tag="$tag" prev="$cur" phase=installing flipped_at="$now" rolled_at= roll_done=0 health=pending
  sup_au_harness update || { sup_log "WARN auto-update: harness update to $tag failed — trying again next cycle"; }
  sup_au_progress
}
# sup_auto_update — rule 7. One at a time (a manual --once beside the unit), on a fd the update's own
# children never inherit.
sup_auto_update(){ local lk
  sup_au_enabled || return 0
  mkdir -p "$SUP_STATE"; lock_try "$SUP_STATE/auto-update.lock" lk 8 || return 0
  sup_au_progress || sup_au_check
  lock_release "$lk"
}

# --- systemd user unit ------------------------------------------------------------------------
# sup_unit_path — the unit's PATH: the directories holding every tool a pass (and the `harness
# start` it may run) needs. systemd hands a user unit a bare PATH, and a missing `rtdd` there
# silently downgrades every relaunched lane to the full test suite.
# Every session backend's binaries, found or not: the unit's fleets may run any backend (#351), and one
# a host lacks (tmux, on a headless-only host) is simply left out — never required.
sup_unit_path(){ local b p sb out=()
  for b in $(sup_agent_bins) gh rtdd $(for sb in $(sess_backend_list); do ( export "$SESS_CONFIG_VAR=$sb"; sess_bins ); done) git python3 curl; do
    if [[ $b == rtdd ]]; then p=$(rtdd_exe 2>/dev/null) || continue; else p=$(command -v "$b" 2>/dev/null) || continue; fi   # rtdd.exe on Windows (#495)
    [[ $p == /* ]] && out+=("$(dirname "$p")")
  done
  out+=("$HOME/.local/bin" /usr/local/bin /usr/bin /bin)
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++' | paste -sd: -
}
# KillMode=process: the workers a pass restarts (`harness start`), and a tmux server it may bring
# up, are children of this unit. systemd's default control-group kill would take every one of them
# down with the supervisor on each restart — and `harness update` restarts it.
sup_install(){ local b unit="$SUP_UNIT_DIR/$SUP_UNIT"
  for b in "$(cli_exe)" gh rtdd; do
    if [[ $b == rtdd ]]; then rtdd_exe >/dev/null 2>&1 && continue; else command -v "$b" >/dev/null 2>&1 && continue; fi
    echo "WARNING: '$b' is not on PATH, so the supervisor's unit cannot find it$([[ $b == rtdd ]] && echo ' — relaunched lanes silently fall back to full test suites')" >&2
  done
  if is_windows; then   # #356: a scheduled task, never systemctl; same PATH, same restart delay
    win_task_install "$SUP_UNIT_DIR" "${SUP_UNIT%.service}" 60 "PATH=$(sup_unit_path)" "HARNESS_HOME=$HARNESS_HOME" \
      -- "$SUP_HARNESS" supervise || return 1
    echo "  supervisor running: schtasks /Query /TN $(win_task_name "${SUP_UNIT%.service}")   log: $SUP_LOG"
    return 0
  fi
  mkdir -p "$SUP_UNIT_DIR" || { echo "ERROR: cannot create $SUP_UNIT_DIR" >&2; return 1; }
  cat >"$unit" <<EOF
[Unit]
Description=Harness supervise: keeps every fleet on this host unstuck (dead workers, orphan locks, frozen sessions)
After=network-online.target

[Service]
ExecStart=$SUP_HARNESS supervise
Restart=always
RestartSec=60
KillMode=process
Nice=10
Environment=PATH=$(sup_unit_path)
Environment=HARNESS_HOME=$HARNESS_HOME

[Install]
WantedBy=default.target
EOF
  echo "  wrote $unit"
  "$SUP_SYSTEMCTL" --user daemon-reload || echo "WARNING: systemctl --user daemon-reload failed" >&2
  "$SUP_SYSTEMCTL" --user enable "$SUP_UNIT" || echo "WARNING: could not enable $SUP_UNIT" >&2
  "$SUP_SYSTEMCTL" --user restart "$SUP_UNIT" || echo "WARNING: could not (re)start $SUP_UNIT" >&2
  # linger keeps the user manager (and so this unit) running with no login session open.
  "$SUP_LOGINCTL" enable-linger "$(id -un)" 2>/dev/null \
    || echo "WARNING: loginctl enable-linger failed — the supervisor stops when you log out" >&2
  [[ -f $SUP_UNIT_DIR/harness-manager.service ]] && echo "NOTE: the prototype harness-manager.service is installed too; both would act. Retire it: systemctl --user disable --now harness-manager.service"
  echo "  supervisor running: systemctl --user status $SUP_UNIT   log: $SUP_LOG"
}
sup_uninstall(){ local unit="$SUP_UNIT_DIR/$SUP_UNIT"
  if is_windows; then
    [[ -f $(win_task_file "$SUP_UNIT_DIR" "${SUP_UNIT%.service}") ]] || { echo "  $SUP_UNIT not installed"; return 0; }
    win_task_uninstall "$SUP_UNIT_DIR" "${SUP_UNIT%.service}"
    echo "  removed scheduled task $(win_task_name "${SUP_UNIT%.service}")"; return 0
  fi
  [[ -f $unit ]] || { echo "  $SUP_UNIT not installed"; return 0; }
  "$SUP_SYSTEMCTL" --user disable --now "$SUP_UNIT" 2>/dev/null || true
  rm -f "$unit"; "$SUP_SYSTEMCTL" --user daemon-reload 2>/dev/null || true
  echo "  removed $unit"
}
# sup_installed — the unit is installed AND runs THIS engine. update/uninstall act only then, so a
# second engine checkout (a dev clone, a test sandbox) never rewrites or removes the host's unit.
sup_installed(){
  if is_windows; then
    grep -qxF "# ExecStart=$SUP_HARNESS supervise" "$(win_task_file "$SUP_UNIT_DIR" "${SUP_UNIT%.service}")" 2>/dev/null && return 0
    win_task_pinned "$SUP_UNIT_DIR" "${SUP_UNIT%.service}" supervise; return; fi   # pinned to one release by an older install: ours, to re-point
  grep -qxF "ExecStart=$SUP_HARNESS supervise" "$SUP_UNIT_DIR/$SUP_UNIT" 2>/dev/null; }

[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0   # sourced (tests, update.sh): define functions only
for a; do case $a in
  --dry-run) SUP_DRY=1 ;; --once) SUP_ONCE=1 ;;
  --install) sup_install; exit ;; --uninstall) sup_uninstall; exit ;;
  --alarms) python3 "$SUP_RULES" alarms "$SUP_STATE/rules"; exit ;;
  -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "harness supervise: unknown option $a" >&2; exit 2 ;;
esac; done
mkdir -p "$SUP_STATE/panes"
while :; do
  sup_pass
  (( SUP_AU_TERM )) && { sup_log "stopping: TERM arrived while an update restarted this unit"; exit 0; }
  (( SUP_ONCE )) && break
  sleep "$INTERVAL"
done

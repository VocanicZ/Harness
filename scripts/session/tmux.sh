# tmux.sh — the tmux session backend (#346): every session a lane runs in is a detached tmux session
# on the host's default server, named by the fleet's session grammar (sess_impl / sess_orch / …). The
# ONE engine file that runs `tmux`; the contract of each function is in scripts/session/dispatch.sh.
# Sourced by dispatch.sh; defines functions only.
tmux_sess_bins(){ echo tmux; }
tmux_sess_list(){ tmux ls -F '#S' 2>/dev/null; }
tmux_sess_list_paths(){ tmux ls -F '#{session_name}'$'\t''#{session_path}' 2>/dev/null; }
tmux_sess_panes(){ tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}' 2>/dev/null; }
tmux_sess_live(){ tmux has-session -t "$1" 2>/dev/null; }
# Typing and kill leave their stderr to the caller, as `tmux send-keys` / `kill-session` did before the
# seam: an adapter silences it, supervise logs it.
# <name> <dir> [-e K=V …] [command…] — the -e pairs are the session's environment (session_env).
# #547: tmux copies the CREATING client's whole environment into the server's global environment, where every
# later session — another fleet's lane, the operator's shell — inherits it. This call is the only one that can
# create the server, and its client is a pool worker with one fleet's STATE_DIR / HARNESS_* / RTDD_EVENT_LOG
# exported. So run the real tmux through `env -u` for those: the caller's shell is never touched (#558: unsetting
# and restoring them here promoted a caller's temporary `HARNESS_CLI=agy f` or `local STATE_DIR` to an exported
# global). A `tmux` FUNCTION stub (a test) is called directly, so it runs in THIS shell and keeps its side
# effects. The lane gets its own values from the -e pairs. TMUX_TMPDIR, TMUX, PATH and HOME stay.
tmux_sess_start(){ local v unset_args=()
  if declare -F tmux >/dev/null; then tmux new-session -d -s "$1" -c "$2" "${@:3}"; return $?; fi
  for v in STATE_DIR RTDD_EVENT_LOG $(compgen -e HARNESS_); do unset_args+=(-u "$v"); done
  env "${unset_args[@]}" tmux new-session -d -s "$1" -c "$2" "${@:3}"; }
tmux_sess_send_line(){ tmux send-keys -t "$1" "$2" Enter; }
tmux_sess_type(){ tmux send-keys -t "$1" -l "$2"; }
tmux_sess_enter(){ tmux send-keys -t "$1" Enter; }
tmux_sess_clear_line(){ tmux send-keys -t "$1" C-u; }
tmux_sess_interrupt(){ tmux send-keys -t "$1" Escape; }
tmux_sess_capture(){ tmux capture-pane -p ${2:+-S "-$2"} -t "$1" 2>/dev/null; }
tmux_sess_pane_pid(){ tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null; }
# kill-session SIGHUPs only the pane's own process group: a detached background job (setsid — a test
# server, `tail -F`, a watcher) outlived the lane forever, re-parented to init (#418). So read the
# session's HARNESS_SESSION and its panes' process trees FIRST (after the kill the tree is re-parented
# and unreachable by ppid), kill the session, then sweep both (proc_sweep_session) — never the tmux
# server. The result is kill-session's: false when there was none.
tmux_sess_kill(){ local u pids rc srv
  u="$(tmux show-environment -t "$1" HARNESS_SESSION 2>/dev/null)"
  [[ $u == HARNESS_SESSION=?* ]] && u="${u#HARNESS_SESSION=}" || u=""
  pids="$(tmux list-panes -s -t "$1" -F '#{pane_pid}' 2>/dev/null | grep -E '^[0-9]+$')"
  [[ -n $pids ]] && pids="$pids $(proc_descendants $pids)"
  srv="$(_tmux_server_pid)"
  tmux kill-session -t "$1"; rc=$?
  [[ -n $u || -n $pids ]] && SWEEP_KEEP="$srv" proc_sweep_session "$u" $pids
  return $rc; }
# A lane that ended on its own (no kill): what still carries its HARNESS_SESSION (stats_sweep_ended).
tmux_sess_sweep(){ [[ -n ${1:-} ]] || return 0; SWEEP_KEEP="$(_tmux_server_pid)" proc_sweep_session "$1"; }
# The server's own pid: started by a lane's descendant, it would carry that lane's HARNESS_SESSION.
_tmux_server_pid(){ tmux ls -F '#{pid}' 2>/dev/null | head -n1; }
# Everything a pane does is on its screen: no mark beyond what sess_capture shows.
tmux_sess_activity(){ return 0; }
tmux_sess_turns(){ return 0; }
# A pane has no state beyond its screen (the views read the supervisor's activity instead).
tmux_sess_state(){ return 0; }
tmux_sess_turn_ended(){ return 1; }
# A pane keeps no record of the claude session it ran: a relaunched tmux lane starts a new one.
tmux_sess_resume_id(){ return 0; }
tmux_sess_attach(){ exec tmux attach -t "$1"; }
tmux_sess_attach_hint(){ echo "tmux attach -t $1"; }
# tmux_sess_describe <fn> <target> [args…] — the tmux command line <fn> runs (sess_describe).
tmux_sess_describe(){ local fn="$1" t="$2"; shift 2
  case $fn in
    send_line)  echo "tmux send-keys -t $t $* Enter" ;;
    type)       echo "tmux send-keys -t $t -l $*" ;;
    enter)      echo "tmux send-keys -t $t Enter" ;;
    clear_line) echo "tmux send-keys -t $t C-u" ;;
    interrupt)  echo "tmux send-keys -t $t Escape" ;;
    kill)       echo "tmux kill-session -t $t" ;;
    *)          echo "sess_$fn $t $*" ;;
  esac; }

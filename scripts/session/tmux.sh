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
tmux_sess_start(){ tmux new-session -d -s "$1" -c "$2" "${@:3}"; }
tmux_sess_send_line(){ tmux send-keys -t "$1" "$2" Enter; }
tmux_sess_type(){ tmux send-keys -t "$1" -l "$2"; }
tmux_sess_enter(){ tmux send-keys -t "$1" Enter; }
tmux_sess_clear_line(){ tmux send-keys -t "$1" C-u; }
tmux_sess_interrupt(){ tmux send-keys -t "$1" Escape; }
tmux_sess_capture(){ tmux capture-pane -p ${2:+-S "-$2"} -t "$1" 2>/dev/null; }
tmux_sess_pane_pid(){ tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null; }
tmux_sess_kill(){ tmux kill-session -t "$1"; }
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

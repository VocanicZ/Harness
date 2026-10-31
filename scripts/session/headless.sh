# headless.sh — the headless session backend (#346, #349, PRD #344): a lane runs as a detached
# background process — the CLI's headless lane runner (scripts/cli/claude_headless.py for claude, the
# only CLI with one) — and no terminal multiplexer. The groundwork native Windows needs.
#
# Each lane has a directory, $HARNESS_HOME/lanes/<session name>/ (HARNESS_HEADLESS_DIR overrides the
# root): host-wide like the tmux server, so a sibling fleet's lanes are seen as its tmux sessions were.
#   pid, started  the runner's process id (sess_pane_pid) and its start time + command line as `ps`
#                 prints them: a pid is the lane's only while they match, never a later process that
#                 reused the number. The
#                 runner leads its own process session.
#   dir, created  the lane's start directory and start time (sess_list_paths)
#   runner.log    the runner's own stdout/stderr
#   typed         text sess_type has typed and sess_enter has not yet submitted
#   inbox.jsonl, events.jsonl, stderr.log, state.json, stop, interrupt — the runner's lane files: the
#                 protocol claude_headless.py documents, the one this backend reads and writes.
# A lane is live while its runner's process is alive and its state is not `ended`. Its screen
# (sess_capture) is the runner's state drawn in the claude TUI's shapes (claude_headless.py pane),
# which is how the watchdog, the goal loop and turn.sh read a headless lane unchanged.
# The contract of each function is in scripts/session/dispatch.sh. Sourced by dispatch.sh; defines
# functions only.
HEADLESS_LANE_PY="$SESS_DIR/../cli/claude_headless.py"   # the lane protocol's reader/writer
: "${HARNESS_HEADLESS_STOP_WAIT:=15}"   # seconds sess_kill waits for a runner to end its turn and exit

# _hl_root — where every lane's directory lives.
_hl_root(){ echo "${HARNESS_HEADLESS_DIR:-${HARNESS_HOME:-$HOME/.harness}/lanes}"; }
# _hl_name <target> — the session name a target names: `=<name>` and `<name>:<window>.<pane>` too.
_hl_name(){ local t="${1#=}"; echo "${t%%:*}"; }
# headless_lane_dir <target> — the lane directory of the session <target> names.
headless_lane_dir(){ echo "$(_hl_root)/$(_hl_name "$1")"; }
_hl_pid(){ local p; p="$(cat "$(headless_lane_dir "$1")/pid" 2>/dev/null)"; [[ $p =~ ^[0-9]+$ ]] && echo "$p"; }
# A zombie is not alive: a runner that exited but whose parent has not reaped it yet.
_hl_alive(){ kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }
# _hl_ident <pid> — what tells this process from a later one given the same number: its start time and
# command line.
_hl_ident(){ printf '%s|%s' "$(ps -o lstart= -p "$1" 2>/dev/null)" "$(ps -o args= -p "$1" 2>/dev/null)"; }
# _hl_runner <target> — the lane's runner pid, while that process is the one this backend started.
_hl_runner(){ local pid lane; lane="$(headless_lane_dir "$1")"; pid="$(_hl_pid "$1")" || return 1
  _hl_alive "$pid" && [[ -s "$lane/started" && "$(_hl_ident "$pid")" == "$(cat "$lane/started")" ]] && echo "$pid"; }
# _hl_reap_turn <lane dir> — end a claude turn a runner left behind (one SIGKILLed or OOM-killed
# mid-turn: each turn leads its own process group, so it outlives its runner), named by state.json's
# claude_pid and only while that process still runs this lane's session.
_hl_reap_turn(){ local lane="$1" cpid sid
  cpid="$(python3 "$HEADLESS_LANE_PY" state --lane "$lane" --field claude_pid 2>/dev/null)"
  sid="$(python3 "$HEADLESS_LANE_PY" state --lane "$lane" --field session_id 2>/dev/null)"
  [[ $cpid =~ ^[0-9]+$ && -n $sid ]] && _hl_alive "$cpid" || return 0
  [[ "$(ps -o args= -p "$cpid" 2>/dev/null)" == *"$sid"* ]] || return 0
  kill -KILL -- "-$cpid" 2>/dev/null; kill -KILL "$cpid" 2>/dev/null; return 0; }
_hl_state(){ python3 "$HEADLESS_LANE_PY" state --lane "$(headless_lane_dir "$1")" --field state 2>/dev/null; }
_hl_names(){ local d; shopt -s nullglob; for d in "$(_hl_root)"/*/; do d="${d%/}"; echo "${d##*/}"; done; shopt -u nullglob; }
# _hl_send <target> <text> — one message onto the lane's inbox.
_hl_send(){ headless_sess_live "$1" || return 1
  printf '%s' "$2" | python3 "$HEADLESS_LANE_PY" send --lane "$(headless_lane_dir "$1")" -; }

headless_sess_bins(){ echo python3; }
headless_sess_list(){ local n; while read -r n; do [[ -n $n ]] && headless_sess_live "$n" && echo "$n"; done < <(_hl_names); return 0; }
headless_sess_list_paths(){ local n
  while read -r n; do [[ -n $n ]] && printf '%s\t%s\n' "$n" "$(cat "$(headless_lane_dir "$n")/dir" 2>/dev/null)"; done < <(headless_sess_list); }
headless_sess_panes(){ local n; while read -r n; do [[ -n $n ]] && echo "$n:0.0 headless"; done < <(headless_sess_list); }
headless_sess_live(){ _hl_runner "$1" >/dev/null && [[ "$(_hl_state "$1")" != ended ]]; }
# <name> <dir> [-e K=V …] <command…> — a lane needs its runner's command: there is no shell to type a
# launch line into. The command runs in <dir> with the -e pairs and HARNESS_LANE_DIR in its
# environment, detached (setsid where the host has it, so the worker that started it can exit), and
# the start succeeds once the runner has written its first state.
headless_sess_start(){ local name="$1" dir="$2" lane pid i; shift 2; local -a envs=()
  while [[ "${1:-}" == -e ]]; do envs+=("$2"); shift 2; done
  (( $# )) || { echo "session backend 'headless' needs the lane runner's command to start $name (the CLI's cli_headless)" >&2; return 1; }
  headless_sess_live "$name" && { echo "headless lane $name is already live" >&2; return 1; }
  lane="$(headless_lane_dir "$name")"
  # A fresh launch is a fresh lane: a runner reads its session id and inbox position back from an old
  # state.json, which would resume the previous launch's claude session.
  [[ -d $lane ]] && _hl_reap_turn "$lane"   # a dead runner's turn must not keep editing the worktree
  rm -rf "$lane"; mkdir -p "$lane" || return 1
  printf '%s\n' "$dir" > "$lane/dir"; date +%s > "$lane/created"
  command -v setsid >/dev/null 2>&1 && set -- setsid "$@"
  ( cd "$dir" 2>/dev/null || exit 1
    exec env "${envs[@]}" HARNESS_LANE_DIR="$lane" nohup "$@" </dev/null >>"$lane/runner.log" 2>&1 ) &
  pid=$!; echo "$pid" > "$lane/pid"
  for (( i = 0; i < 100; i++ )); do
    # Its identity once it runs the runner (the state file is the runner's), not the shell it forked as.
    [[ -s "$lane/state.json" ]] && _hl_alive "$pid" && { _hl_ident "$pid" > "$lane/started"; return 0; }
    _hl_alive "$pid" || break
    sleep 0.1
  done
  echo "headless lane $name did not start: $(tail -n 3 "$lane/runner.log" 2>/dev/null | tr '\n' ' ')" >&2
  _hl_alive "$pid" && kill -KILL "$pid" 2>/dev/null
  return 1; }
headless_sess_send_line(){ _hl_send "$1" "$2"; }
headless_sess_type(){ headless_sess_live "$1" || return 1; printf '%s' "$2" >> "$(headless_lane_dir "$1")/typed"; }
# Enter submits what is typed as one message; on an empty input line it does nothing, as on a prompt.
headless_sess_enter(){ local f text; headless_sess_live "$1" || return 1
  f="$(headless_lane_dir "$1")/typed"; [[ -s $f ]] || { rm -f "$f"; return 0; }
  text="$(cat "$f")"; rm -f "$f"; _hl_send "$1" "$text"; }
headless_sess_clear_line(){ headless_sess_live "$1" || return 1; rm -f "$(headless_lane_dir "$1")/typed"; }
headless_sess_interrupt(){ headless_sess_live "$1" || return 1
  python3 "$HEADLESS_LANE_PY" interrupt --lane "$(headless_lane_dir "$1")"; }
headless_sess_capture(){ headless_sess_live "$1" || return 1
  python3 "$HEADLESS_LANE_PY" pane --lane "$(headless_lane_dir "$1")" 2>/dev/null; }
headless_sess_pane_pid(){ headless_sess_live "$1" || return 1; _hl_runner "$1"; }
# A stop request plus SIGTERM: the runner ends its turn's whole process tree and exits. One that has
# not after HARNESS_HEADLESS_STOP_WAIT seconds is killed with its process group, and so is the claude
# turn it may have left (its own process group) — that one even when the runner was already gone.
headless_sess_kill(){ local lane pid i
  lane="$(headless_lane_dir "$1")"
  headless_sess_live "$1" || { [[ -d $lane ]] && _hl_reap_turn "$lane"; return 1; }
  pid="$(_hl_runner "$1")"
  : > "$lane/stop"; kill -TERM "$pid" 2>/dev/null
  for (( i = 0; i < HARNESS_HEADLESS_STOP_WAIT * 10; i++ )); do _hl_alive "$pid" || break; sleep 0.1; done
  if [[ "$(_hl_runner "$1")" == "$pid" ]]; then kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; fi
  _hl_reap_turn "$lane"; return 0; }
headless_sess_turns(){ headless_sess_live "$1" || return 0
  python3 "$HEADLESS_LANE_PY" state --lane "$(headless_lane_dir "$1")" --field turn 2>/dev/null; }
headless_sess_turn_ended(){ headless_sess_live "$1" || return 0
  LANE_STATE="$(headless_lane_dir "$1")/state.json" MARK="$2" python3 -c '
import json, os, sys
st = json.load(open(os.environ["LANE_STATE"], encoding="utf-8"))
mark = int(os.environ["MARK"] or 0)
try:   # a message on the inbox no turn has taken yet (the runner may not have read it)
    waiting = os.path.getsize(os.path.join(os.path.dirname(os.environ["LANE_STATE"]), "inbox.jsonl")) > int(st.get("inbox_offset") or 0)
except OSError:
    waiting = False
sys.exit(0 if int(st.get("turn") or 0) > mark and st.get("state") != "busy" and not st.get("queued") and not waiting else 1)' 2>/dev/null; }
# The lane directory outlives its runner (a stop, a pause's end, a crash), and its state.json names the
# claude session it ran: the one to resume when the same lane is launched again in the same worktree —
# once that session exists (session_started), never while the lane is still live.
headless_sess_resume_id(){ local lane="$(headless_lane_dir "$1")"
  [[ -s $lane/state.json ]] && ! headless_sess_live "$1" || return 0
  LANE_STATE="$lane/state.json" WD="$2" python3 -c '
import json, os
try:
    st = json.load(open(os.environ["LANE_STATE"], encoding="utf-8"))
except (OSError, ValueError):
    st = {}
sid = st.get("session_id") if isinstance(st, dict) else None
if isinstance(sid, str) and sid and st.get("session_started") and st.get("cwd") == os.environ["WD"]:
    print(sid)' 2>/dev/null; return 0; }
# Watching a lane is reading it: its events and replies as they land (claude_headless.py watch).
headless_sess_attach(){ headless_sess_live "$1" || { echo "no live headless lane $1" >&2; return 1; }
  echo "watching headless lane $1 (read-only; Ctrl-C to stop) — $(headless_lane_dir "$1")/events.jsonl"
  exec python3 "$HEADLESS_LANE_PY" watch --lane "$(headless_lane_dir "$1")"; }
headless_sess_attach_hint(){ echo "harness attach $1"; }
# headless_sess_describe <fn> <target> [args…] — what <fn> does to a lane (sess_describe).
headless_sess_describe(){ local fn="$1" t="$2"; shift 2
  case $fn in
    send_line)  echo "headless send $t: $*" ;;
    type)       echo "headless type $t: $*" ;;
    enter)      echo "headless enter $t" ;;
    clear_line) echo "headless clear $t" ;;
    interrupt)  echo "headless interrupt $t" ;;
    kill)       echo "headless stop $t" ;;
    *)          echo "sess_$fn $t $*" ;;
  esac; }

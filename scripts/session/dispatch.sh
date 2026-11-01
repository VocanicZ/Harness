# dispatch.sh — the session-backend seam (#346, PRD #344). The ONE file that reads
# HARNESS_SESSION_BACKEND: every lane-lifecycle operation the engine performs on an agent session —
# start it, list the fleet's sessions, ask whether one is live, type into it, read its screen,
# interrupt, kill, its process id, attach — goes through the sess_* interface below, beside the CLI
# adapter seam (scripts/cli/dispatch.sh). Sourced; defines functions only.
#
# Each backend scripts/session/<backend>.sh defines <backend>_sess_<fn> for every interface function.
# The backend is resolved at CALL time, so `HARNESS_SESSION_BACKEND=headless sess_list` (a test, or
# the supervisor reading another fleet) reaches that backend without re-sourcing anything. Only
# scripts/session/tmux.sh runs `tmux`; test_session_backend.sh guards that.
#
# A <target> is whatever the caller names a session by: a session name, `=<name>` (an exact match),
# or `<name>:<window>.<pane>` (sess_panes' targets).
: "${HARNESS_SESSION_BACKEND:=tmux}"
export HARNESS_SESSION_BACKEND
SESS_CONFIG_VAR=HARNESS_SESSION_BACKEND   # the config key naming the fleet's session backend
SESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# #355: the process and locking primitives every backend, adapter and lib.sh caller goes through.
source "$SESS_DIR/../portable.sh"

# sess_backend_list — every session backend this engine ships, one per line.
sess_backend_list(){ local f; for f in "$SESS_DIR"/*.sh; do f="${f##*/}"; [[ $f == dispatch.sh ]] || echo "${f%.sh}"; done; }
# sess_backend — the backend this fleet's sessions run on.
sess_backend(){ echo "${HARNESS_SESSION_BACKEND:-tmux}"; }
# sess_backend_check [backend] — true when <backend> (default: the configured one) is a backend this
# engine ships; otherwise says so, naming the valid ones, and is false.
sess_backend_check(){ local b="${1-$(sess_backend)}"
  [[ -n "$b" && $b != */* && -f "$SESS_DIR/$b.sh" && $b != dispatch ]] && return 0
  echo "unknown $SESS_CONFIG_VAR: ${b:-<empty>} (valid: $(sess_backend_list | xargs))" >&2; return 1; }
# sess_platform_check [backend] — true when <backend> (default: the configured one) runs on this host.
# Native Windows has no tmux, so only `headless` does there (#356, ADR 0001 §1); every backend does
# elsewhere. Otherwise says why, naming the fix, and is false.
sess_platform_check(){ local b="${1-$(sess_backend)}"
  is_windows || return 0
  [[ $b == headless ]] && return 0
  echo "session backend '$b' cannot run on native Windows (no tmux) — set $SESS_CONFIG_VAR=headless" >&2; return 1; }

_sess_call(){ local fn="$1" b; shift; b="$(sess_backend)"
  sess_backend_check "$b" || return 1
  "${b}_sess_$fn" "$@"; }

# --- the interface ----------------------------------------------------------------------------
# sess_bins — the binaries the backend needs on PATH (prerequisite checks, a systemd unit's PATH).
sess_bins(){ _sess_call bins "$@"; }
# sess_list — the name of every live session on the host, one per line; nothing when there is none.
sess_list(){ _sess_call list "$@"; }
# sess_list_paths — `<name>\t<start directory>` per live session (the prefix guard's attribution).
sess_list_paths(){ _sess_call list_paths "$@"; }
# sess_panes — `<target> <current command>` per pane on the host, the target addressable by every
# function below.
sess_panes(){ _sess_call panes "$@"; }
# sess_live <target> — true while the session is up.
sess_live(){ _sess_call live "$@"; }
# sess_start <name> <dir> [command…] — start a detached session named <name> in <dir>; with no
# command, the backend's shell. False when it could not be started.
sess_start(){ _sess_call start "$@"; }
# sess_send_line <target> <line> — type <line> into the session and press Enter (the launch line).
sess_send_line(){ _sess_call send_line "$@"; }
# sess_type <target> <text> — type <text> literally, no Enter.
sess_type(){ _sess_call type "$@"; }
# sess_enter <target> — press Enter (submit what is typed, or a menu's default choice).
sess_enter(){ _sess_call enter "$@"; }
# sess_clear_line <target> — clear whatever is typed in the session's input line.
sess_clear_line(){ _sess_call clear_line "$@"; }
# sess_interrupt <target> — interrupt the running turn (Escape).
sess_interrupt(){ _sess_call interrupt "$@"; }
# sess_capture <target> [lines] — the session's current screen; with <lines>, that many lines of
# scrollback above it too. False when the session is not live.
sess_capture(){ _sess_call capture "$@"; }
# sess_pane_pid <target> — the process id the session's pane runs; empty when it is not live.
sess_pane_pid(){ _sess_call pane_pid "$@"; }
# sess_activity <target> — a mark that changes whenever the session works in a way its screen does not
# show: a headless lane draws no reply text, so a turn that ran and ended between two looks leaves the
# same screen behind (#351: the supervisor's frozen-session test). Empty when the screen is the whole
# story (a pane prints everything it does) or the session is not live.
sess_activity(){ _sess_call activity "$@"; }
# sess_state <target> — the session's own state word where the backend keeps one (a headless lane's
# idle | busy | limit | transient, #352: status and the views show it); empty for a pane or a dead one.
sess_state(){ _sess_call state "$@"; }
# sess_kill <target> — end the session; false when there was none.
sess_kill(){ _sess_call kill "$@"; }
# sess_turns <target> — how many turns the session has started, a mark for sess_turn_ended; empty when
# the backend cannot count them (a pane's turns are only screen text).
sess_turns(){ _sess_call turns "$@"; }
# sess_turn_ended <target> <turns> — true once the session has ended every turn it started after <turns>
# (sess_turns), at least one, and has no message waiting for another — or is no longer live. False when
# the backend cannot tell (#350: `pause --force` waits on it for a lane's checkpoint turn).
sess_turn_ended(){ _sess_call turn_ended "$@"; }
# sess_resume_id <name> <dir> — the agent CLI's session id an earlier, ended run of session <name> in
# <dir> left behind to carry on (#350: a checkpointed or crashed lane relaunched by `harness resume` or
# the crash-recovery sweep); empty when there is none, the session is live, or the backend keeps none.
sess_resume_id(){ _sess_call resume_id "$@"; }
# sess_attach <target> — put this terminal on the session (replaces the calling shell).
sess_attach(){ _sess_call attach "$@"; }
# sess_attach_hint <name> — the command an operator runs to watch <name>.
sess_attach_hint(){ _sess_call attach_hint "$@"; }
# sess_describe <command> [args…] — <command> as the backend runs it, for a dry-run or action log:
# a sess_* call reads as the backend's own command line, anything else as itself.
sess_describe(){ local b; b="$(sess_backend)"
  if [[ $1 == sess_* ]] && declare -F "${b}_sess_describe" >/dev/null; then "${b}_sess_describe" "${1#sess_}" "${@:2}"
  else echo "$*"; fi; }

for _sess_f in "$SESS_DIR"/*.sh; do [[ ${_sess_f##*/} == dispatch.sh ]] || source "$_sess_f"; done
unset _sess_f

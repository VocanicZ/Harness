"""session_backend.py — the session-backend seam for the Python views (#346, PRD #344).

The Python half of scripts/session/dispatch.sh: fleetview, `harness web` and supervise_rules read the
fleet's sessions through the argv this module builds and never name a multiplexer themselves. Each
function returns the command a caller runs through its own runner (fleetview.run_cmd,
supervise_rules.sh), so a test that fakes the runner fakes the backend too; None means the backend has
no such probe, which a caller reads as "no session". The backend is the one HARNESS_SESSION_BACKEND
names (lib.sh exports it; tmux when unset). On the headless backend every probe is one bash call into
scripts/session/headless.sh (headless_lane_rows: name, created, runner pid, state per live lane, #352),
so a lane is live here exactly when the engine's sess_live says so; its screen is captured too (#351).
"""
import os
import sys

BACKENDS = ("tmux", "headless")


HEADLESS_LANE_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cli", "claude_headless.py")


def backend():
    """The configured session backend; tmux when unset."""
    return os.environ.get("HARNESS_SESSION_BACKEND") or "tmux"


def _tmux():
    return backend() == "tmux"


SESSION_DISPATCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "session", "dispatch.sh")


def _lane_rows_argv(fields):
    """Prints the given 1-based columns of headless_lane_rows (name, created, runner pid, state)."""
    return ["bash", "-c", 'source "$1" && HARNESS_SESSION_BACKEND=headless headless_lane_rows | cut -f"$2"',
            "_", SESSION_DISPATCH, fields]


def list_created_argv(b=None):
    """Prints `<session name>\\t<created epoch>` per live session of backend <b> (default: the configured
    one). The host-wide views (fleetview, `harness web`) ask every backend: fleets on one host may differ."""
    b = b or backend()
    if b == "tmux":
        return ["tmux", "ls", "-F", "#{session_name}\t#{session_created}"]
    return _lane_rows_argv("1,2") if b == "headless" else None


def pane_pids_argv(b=None):
    """Prints `<session name>\\t<pane pid>` per pane. A headless lane's is its runner, whose argv carries
    the lane's claude flags (`--flags=… --model X`)."""
    b = b or backend()
    if b == "tmux":
        return ["tmux", "list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}"]
    return _lane_rows_argv("1,3") if b == "headless" else None


def states_argv(b=None):
    """Prints `<session name>\\t<state>` per live session whose backend keeps a state of its own: a
    headless lane's idle | busy | limit | transient (#352). None for tmux: a pane has only its screen."""
    return _lane_rows_argv("1,4") if (b or backend()) == "headless" else None


def headless_lane_dir(session):
    """A headless lane's directory (scripts/session/headless.sh headless_lane_dir)."""
    root = os.environ.get("HARNESS_HEADLESS_DIR") or os.path.join(
        os.environ.get("HARNESS_HOME") or os.path.join(os.path.expanduser("~"), ".harness"), "lanes")
    name = session[1:] if session.startswith("=") else session
    return os.path.join(root, name.split(":", 1)[0])


def capture_argv(session, lines=40):
    """Prints the session's screen plus `lines` lines of scrollback above it. A headless lane's screen
    is its state drawn in the claude TUI's shapes (claude_headless.py pane, #351: supervise's arc rules)."""
    if _tmux():
        return ["tmux", "capture-pane", "-p", "-S", f"-{lines}", "-t", session]
    if backend() == "headless":
        return [sys.executable or "python3", HEADLESS_LANE_PY, "pane", "--lane", headless_lane_dir(session)]
    return None


def attach_hint(name):
    """The command an operator runs to watch session `name`."""
    if _tmux():
        return f"tmux attach -t {name}"
    return f"harness attach {name}" if backend() == "headless" else "harness status"

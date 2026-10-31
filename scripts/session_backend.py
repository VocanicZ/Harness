"""session_backend.py — the session-backend seam for the Python views (#346, PRD #344).

The Python half of scripts/session/dispatch.sh: fleetview, `harness web` and supervise_rules read the
fleet's sessions through the argv this module builds and never name a multiplexer themselves. Each
function returns the command a caller runs through its own runner (fleetview.run_cmd,
supervise_rules.sh), so a test that fakes the runner fakes the backend too; None means the backend has
no such probe, which a caller reads as "no session". The backend is the one HARNESS_SESSION_BACKEND
names (lib.sh exports it; tmux when unset). The headless backend has a screen to capture (#351); its
other probes are tmux-only today.
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


def list_created_argv():
    """Prints `<session name>\\t<created epoch>` per live session."""
    return ["tmux", "ls", "-F", "#{session_name}\t#{session_created}"] if _tmux() else None


def pane_pids_argv():
    """Prints `<session name>\\t<pane pid>` per pane."""
    return ["tmux", "list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}"] if _tmux() else None


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
    return f"tmux attach -t {name}" if _tmux() else "harness status"

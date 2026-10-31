"""session_backend.py — the session-backend seam for the Python views (#346, PRD #344).

The Python half of scripts/session/dispatch.sh: fleetview, `harness web` and supervise_rules read the
fleet's sessions through the argv this module builds and never name a multiplexer themselves. Each
function returns the command a caller runs through its own runner (fleetview.run_cmd,
supervise_rules.sh), so a test that fakes the runner fakes the backend too; None means the backend has
no such probe, which a caller reads as "no session". The backend is the one HARNESS_SESSION_BACKEND
names (lib.sh exports it; tmux when unset); only the tmux backend has sessions today.
"""
import os

BACKENDS = ("tmux", "headless")


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


def capture_argv(session, lines=40):
    """Prints the session's screen plus `lines` lines of scrollback above it."""
    return ["tmux", "capture-pane", "-p", "-S", f"-{lines}", "-t", session] if _tmux() else None


def attach_hint(name):
    """The command an operator runs to watch session `name`."""
    return f"tmux attach -t {name}" if _tmux() else "harness status"

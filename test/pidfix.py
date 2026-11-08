"""pidfix.py — pids a Python test records for the engine to probe (#607).

The engine records MSYS pids, and on native Windows portable.pid_alive turns one into a Windows pid through MSYS's
/proc/<pid>/winpid. A native Python test that writes os.getpid() (or a child's Popen.pid) into a pid file is therefore
writing a pid MSYS does not know: the fleet reads DEAD for it. live_pid() registers the pid in a fake /proc tree
(HARNESS_PROC_ROOT, the seam portable.sh and portable.py already have) that maps it to itself, so the real
OpenProcess/GetExitCodeProcess probe runs against the real process. Everywhere else it returns the pid unchanged.
A pid never registered (dead_pid()) stays unknown to MSYS, which is what a dead one is.
"""
import os, sys, tempfile

_ROOT = None


def live_pid(pid=None):
    """The pid to record in a pid / claim file for a process that is alive: <pid> (default: this process)."""
    global _ROOT
    pid = os.getpid() if pid is None else pid
    if sys.platform != "win32":
        return pid
    if _ROOT is None:
        _ROOT = tempfile.mkdtemp(prefix="hx-proc-")
        os.environ["HARNESS_PROC_ROOT"] = _ROOT
    d = os.path.join(_ROOT, str(pid))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "winpid"), "w") as fh:
        fh.write(f"{pid}\n")
    return pid

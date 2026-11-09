"""hlproc.py — what the headless lane runner tests (test_*_headless.py, test_headless_core.py) share to start a runner and
to ask about, and end, a process on both Linux and native Windows (#606).

A Windows venv's python.exe is a launcher: it starts the base interpreter as a CHILD and waits for it, so the pid
subprocess.Popen reports is the launcher's while the runner's own os.getpid() (the `runner_pid` in state.json) is the
child's. A test that waits for `runner_pid == proc.pid` then never sees its runner's first state, and a proc.kill() ends
the launcher but not the runner. RUNNER_PY is the interpreter a test starts a runner with: on Windows the base
interpreter itself (no launcher in between), elsewhere sys.executable. The runners and fakes need only the standard
library, so a venv's site-packages is nothing they miss."""
import os, signal, subprocess, sys

WINDOWS = os.name == "nt"
RUNNER_PY = (getattr(sys, "_base_executable", None) or sys.executable) if WINDOWS else sys.executable


def alive(pid):
    """The process exists and is not a zombie. os.kill(pid, 0) is no probe on Windows (it would end the process)."""
    if WINDOWS:
        import ctypes
        k32 = ctypes.windll.kernel32
        k32.OpenProcess.restype = ctypes.c_void_p
        h = k32.OpenProcess(0x1000, False, int(pid))   # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        try:
            code = ctypes.c_ulong()
            return bool(k32.GetExitCodeProcess(ctypes.c_void_p(h), ctypes.byref(code))) and code.value == 259   # STILL_ACTIVE
        finally:
            k32.CloseHandle(ctypes.c_void_p(h))
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    try:   # reaped-later zombies count as gone
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[-1].split()[0] != "Z"
    except OSError:
        return False


def gone(pid):
    return not alive(pid)


def kill_tree(pid):
    """End <pid> and what it started: SIGKILL on POSIX, `taskkill /T /F` on Windows. Never raises."""
    if WINDOWS:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True)
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass


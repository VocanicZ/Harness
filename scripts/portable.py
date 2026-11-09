"""portable.py — the Python side of the engine's portable process and locking primitives (#355).

The twin of scripts/portable.sh (docs/adr/0001-native-windows-runtime.md). Native Windows CPython has
no `fcntl`, and there `os.kill(pid, 0)` sends CTRL_C_EVENT instead of probing — and the pid the engine
recorded is an MSYS pid, not a Windows one. So:

    pid_alive(pid)       is this engine-recorded (MSYS) pid a live process?
    lock_nb(fh)          take an exclusive lock on an open file without blocking (BlockingIOError if held)
    unlock(fh)           release it

POSIX keeps what the engine did before: `os.kill(pid, 0)` and `fcntl.flock`. Windows uses
`OpenProcess` + `GetExitCodeProcess` (ctypes, stdlib) on the winpid MSYS records beside the pid
(/proc/<pid>/winpid, read through Git's bash: a native process cannot see MSYS's /proc), and
`msvcrt.locking` on byte 0. HARNESS_PLATFORM=windows forces the Windows paths (the suite runs them on
Linux with fakes), HARNESS_PROC_ROOT points the /proc reads at a fake tree, and HARNESS_BASH names the
bash that reads MSYS's /proc (default: the first `bash` on PATH)."""
import os, re, shutil, subprocess, sys

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
STILL_ACTIVE = 259
ERROR_ACCESS_DENIED = 5


def is_windows():
    forced = os.environ.get("HARNESS_PLATFORM")
    if forced in ("windows", "posix"):
        return forced == "windows"
    return sys.platform == "win32"


def _path_program(name):
    """The first thing on PATH a shell would run as `name`, as (path, is_script): a PATHEXT match (gh.exe, gh.cmd) or, as Git
    Bash does, an extensionless file that starts with a bash/sh shebang. None when nothing is."""
    if os.path.dirname(name):
        return None
    exts = [e for e in os.environ.get("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";") if e]
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if not d:
            continue
        for e in exts:
            f = os.path.join(d, name + e)
            if os.path.isfile(f):
                return f, False
        f = os.path.join(d, name)
        if os.path.isfile(f):
            try:
                with open(f, "rb") as fh:
                    head = fh.read(64)
            except OSError:
                continue
            if re.match(rb"#!\s*(/usr/bin/env\s+)?(\S*/)?(ba)?sh\b", head):
                return f, True
    return None


def resolve_argv(argv):
    """argv with its program resolved through PATH on native Windows, as a shell would (#607, #686). CreateProcess searches
    System32 before PATH (so a bare `bash` is WSL's, not Git's) and appends only `.exe`, so a `gh.cmd` shim is never found, and
    an extensionless bash script (a fake `gh` a test or a wrapper puts first on PATH) is never started: the REAL gh.exe further
    down PATH answered instead. This walks PATH and PATHEXT in order and runs a bash/sh shebang script through Git's bash, as
    Git Bash itself would (a .cmd shim is no way round it: cmd.exe splits an argument at its `&`). Elsewhere, and for a program
    it cannot find, argv is returned as it was."""
    if sys.platform != "win32" or not argv:
        return argv
    found = _path_program(argv[0])
    if not found:
        return argv
    exe, is_script = found
    return [bash_exe(), exe, *argv[1:]] if is_script else [exe, *argv[1:]]


def bash_exe():
    """The bash the engine's Python runs scripts with (#609): HARNESS_BASH, else the first `bash` on PATH. Never the bare name
    "bash": CreateProcess looks in System32 before PATH, and there `bash` is WSL's launcher (a Linux userland, no Harness)."""
    return os.environ.get("HARNESS_BASH") or shutil.which("bash") or "bash"


def winpid_of(pid):
    """The Windows pid behind an MSYS pid, or None when MSYS no longer knows it."""
    root = os.environ.get("HARNESS_PROC_ROOT")
    if root or not is_windows():
        try:
            with open(os.path.join(root or "/proc", str(pid), "winpid")) as fh:
                return int(fh.read().strip())
        except (OSError, ValueError):
            return None
    bash = bash_exe()
    try:
        out = subprocess.run([bash, "-c", 'cat "/proc/$1/winpid"', "_", str(pid)],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        return int(out) if out else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


class _Kernel32:
    """The three kernel32 calls pid_alive needs, behind plain methods (a test passes a fake)."""
    def __init__(self):
        import ctypes
        self.ct = ctypes
        self.k = ctypes.WinDLL("kernel32", use_last_error=True)

    def open(self, winpid):
        """(handle, 0) or (None, GetLastError())."""
        h = self.k.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(winpid))
        return (h, 0) if h else (None, self.ct.get_last_error())

    def exit_code(self, h):
        code = self.ct.c_ulong(0)
        return code.value if self.k.GetExitCodeProcess(h, self.ct.byref(code)) else None

    def close(self, h):
        self.k.CloseHandle(h)


def win_process_alive(winpid, kernel32=None):
    """OpenProcess + GetExitCodeProcess: alive iff the process still reports STILL_ACTIVE. A process
    we may not open (ERROR_ACCESS_DENIED) exists, as os.kill's PermissionError does on POSIX."""
    k = kernel32 or _Kernel32()
    h, err = k.open(winpid)
    if h is None:
        return err == ERROR_ACCESS_DENIED
    try:
        return k.exit_code(h) == STILL_ACTIVE
    finally:
        k.close(h)


def pid_alive(pid, kernel32=None):
    """True iff <pid> (as the engine records it: an MSYS pid on Windows) is a live process."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if is_windows():
        w = winpid_of(pid)
        return w is not None and win_process_alive(w, kernel32)
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True          # alive, just not ours
    except OSError:
        return False
    return True


def lock_nb(fh, msvcrt_mod=None):
    """Exclusive, non-blocking lock on open file <fh>; BlockingIOError when another holder has it."""
    if is_windows():
        m = msvcrt_mod or __import__("msvcrt")
        pos = fh.tell()
        fh.seek(0)
        try:
            m.locking(fh.fileno(), m.LK_NBLCK, 1)
        except OSError as e:
            raise BlockingIOError(*e.args) from e
        finally:
            fh.seek(pos)
        return
    import fcntl
    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)


def unlock(fh, msvcrt_mod=None):
    """Release lock_nb's lock (POSIX: closing the file would too; Windows wants it explicit)."""
    if is_windows():
        m = msvcrt_mod or __import__("msvcrt")
        pos = fh.tell()
        fh.seek(0)
        try:
            m.locking(fh.fileno(), m.LK_UNLCK, 1)
        except OSError:
            pass
        finally:
            fh.seek(pos)
        return
    import fcntl
    fcntl.flock(fh, fcntl.LOCK_UN)

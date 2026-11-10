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


def _script_kind(f):
    """"sh" for a file starting with a bash/sh shebang, "py" for a python one (the interpreter may be named by a Windows path, or
    through /usr/bin/env), else None."""
    try:
        with open(f, "rb") as fh:
            head = fh.read(256)
    except OSError:
        return None
    if not head.startswith(b"#!"):
        return None
    line = head[2:].split(b"\n", 1)[0].decode("latin-1").strip()
    if ".exe" in line.lower():           # a Windows interpreter path may hold spaces: it ends at its .exe
        line = line[:line.lower().index(".exe") + 4]
    words = line.split() if ".exe" not in line.lower() else [line]
    if words and re.split(r"[/\\]", words[0])[-1] == "env" and len(words) > 1:
        words = words[1:]
    prog = re.split(r"[/\\]", words[0])[-1].lower() if words else ""
    prog = prog[:-4] if prog.endswith(".exe") else prog
    if prog in ("sh", "bash"):
        return "sh"
    return "py" if re.fullmatch(r"python[0-9.]*", prog) else None


def _path_program(name):
    """The first thing on PATH a shell would run as `name`, as (path, script kind): a PATHEXT match (gh.exe, gh.cmd) or, as Git
    Bash does, an extensionless file with a bash/sh/python shebang. A name with a directory is looked at as it stands."""
    if os.path.dirname(name):
        return (name, _script_kind(name)) if os.path.isfile(name) and _script_kind(name) else None
    exts = [e for e in os.environ.get("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";") if e]
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if not d:
            continue
        for e in exts:
            f = os.path.join(d, name + e)
            if os.path.isfile(f):
                return f, None
        f = os.path.join(d, name)
        if os.path.isfile(f) and _script_kind(f):
            return f, _script_kind(f)
    return None


def resolve_argv(argv):
    """argv with its program resolved through PATH on native Windows, as a shell would (#607, #686). CreateProcess searches
    System32 before PATH (so a bare `bash` is WSL's, not Git's) and appends only `.exe`, so a `gh.cmd` shim is never found, and
    a script (a fake `gh` a test or a wrapper puts first on PATH, or names by path) is never started: the REAL gh.exe further
    down PATH answered instead. This walks PATH and PATHEXT in order and runs a bash/sh script under Git's bash and a python
    one under this interpreter, as Git Bash itself would by the shebang (a .cmd shim is no way round it: cmd.exe splits an
    argument at its `&`). Elsewhere, and for a program it cannot find, argv is returned as it was."""
    if sys.platform != "win32" or not argv:
        return argv
    found = _path_program(argv[0])
    if not found:
        return argv
    exe, kind = found
    return [{"sh": bash_exe, "py": lambda: sys.executable}[kind](), exe, *argv[1:]] if kind else [exe, *argv[1:]]


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


# ------------------------------------------------------------------------------------------ paths ---
# One directory has two spellings in one Windows run (#605): `C:/x` (a Windows environment variable,
# export_native_paths) and `/c/x` (bash's `pwd`, `realpath`, `mktemp`, and every path a bash-written config
# or table holds). Native CPython opens only the first; bash compares and sources only the second.
#
#     native_path(p)   the form this Python opens: C:/x   (`cygpath -m`); unchanged on POSIX
#     posix_path(p)    the form bash holds:        /c/x   (`cygpath -u`); unchanged on POSIX
#
# A path read out of a file or an argument bash wrote goes through native_path before open(); a path
# Python writes where bash will read it goes through posix_path (os.path.abspath answers C:\x, which a
# bash `source`d config turns into C:x). Mirrors portable.sh native_path / posix_path.
_DRIVE_MSYS = re.compile(r"^/([A-Za-z])(?:/(.*))?$")
_DRIVE_WIN = re.compile(r"^([A-Za-z]):(?:[\\/](.*))?$")


def _cygpath(flag, p):
    exe = os.environ.get("HARNESS_CYGPATH") or shutil.which("cygpath")
    if not exe:
        return None
    try:
        out = subprocess.run([exe, flag, p], capture_output=True, text=True, timeout=10).stdout.strip()
        return out or None
    except (OSError, subprocess.SubprocessError):
        return None


def native_path(p):
    """C:/x for /c/x (and for C:\\x); the drive-less MSYS roots (/tmp, /usr) need cygpath, which asks the mount table."""
    p = os.fspath(p)
    if not is_windows() or not p:
        return p
    m = _DRIVE_MSYS.match(p)
    if m:
        return "%s:/%s" % (m.group(1).upper(), m.group(2) or "")
    if _DRIVE_WIN.match(p):
        return p.replace("\\", "/")
    if p.startswith("/"):
        return _cygpath("-m", p) or p
    return p.replace("\\", "/")


def posix_path(p):
    """/c/x for C:/x and C:\\x; unchanged when it is already MSYS form (or relative)."""
    p = os.fspath(p)
    if not is_windows() or not p:
        return p
    m = _DRIVE_WIN.match(p)
    if m:
        rest = (m.group(2) or "").replace("\\", "/")
        return "/%s/%s" % (m.group(1).lower(), rest) if rest else "/" + m.group(1).lower()
    return p.replace("\\", "/")

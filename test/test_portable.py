#!/usr/bin/env python3
"""test_portable.py — #355: scripts/portable.py, on both branches.

The Windows branch is forced on Linux with HARNESS_PLATFORM=windows: pid_alive reads the winpid from a
fake /proc (HARNESS_PROC_ROOT) and asks a fake kernel32 (OpenProcess / GetExitCodeProcess); lock_nb /
unlock drive a fake msvcrt. Its callers — stats.append_event, fleetview.pid_alive, web_data.claim_alive
— are checked to go through it (no fcntl, no os.kill(pid, 0) on the Windows branch)."""
import importlib.util, os, subprocess, sys, tempfile, types
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.normpath(os.path.join(HERE, "..", "scripts"))
sys.path.insert(0, SCRIPTS)
import portable  # noqa: E402

fails = 0
def check(ok, msg):
    global fails
    print(("  ok: " if ok else "  FAIL: ") + msg)
    fails += 0 if ok else 1


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, name + ".py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


class FakeKernel32:
    """winpid -> exit code (259 = STILL_ACTIVE); a winpid in `denied` cannot be opened (access denied)."""
    def __init__(self, procs, denied=()):
        self.procs, self.denied, self.closed = procs, set(denied), []

    def open(self, winpid):
        if winpid in self.denied:
            return None, portable.ERROR_ACCESS_DENIED
        return (("h", winpid), 0) if winpid in self.procs else (None, 87)   # ERROR_INVALID_PARAMETER

    def exit_code(self, h):
        return self.procs[h[1]]

    def close(self, h):
        self.closed.append(h)


class FakeMsvcrt:
    LK_NBLCK, LK_UNLCK = 2, 0
    held = {}   # path -> owner fd, shared like an OS lock table

    def __init__(self):
        self.calls = []

    def locking(self, fd, mode, nbytes):
        path = os.readlink(f"/proc/self/fd/{fd}")
        self.calls.append((mode, nbytes, os.lseek(fd, 0, os.SEEK_CUR)))
        if mode == self.LK_NBLCK:
            if path in self.held and self.held[path] != fd:
                raise PermissionError(13, "Permission denied")   # what msvcrt raises when locked
            self.held[path] = fd
        elif mode == self.LK_UNLCK:
            self.held.pop(path, None)


def env(**kw):
    """Context: set/unset environment variables for a block."""
    class _E:
        def __enter__(self):
            self.old = {k: os.environ.get(k) for k in kw}
            for k, v in kw.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v
        def __exit__(self, *a):
            for k, v in self.old.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v
    return _E()


def main():
    tmp = tempfile.mkdtemp()
    # ---- platform switch
    with env(HARNESS_PLATFORM="windows"):
        check(portable.is_windows(), "HARNESS_PLATFORM=windows forces the Windows branch")
    with env(HARNESS_PLATFORM="posix"):
        check(not portable.is_windows(), "HARNESS_PLATFORM=posix forces the POSIX branch")
    with env(HARNESS_PLATFORM=None):
        check(portable.is_windows() == (sys.platform == "win32"), "default follows sys.platform")

    # ---- pid_alive, POSIX
    with env(HARNESS_PLATFORM="posix"):
        check(portable.pid_alive(os.getpid()), "[posix] pid_alive: this process is alive")
        p = subprocess.Popen(["true"]); p.wait()
        check(not portable.pid_alive(p.pid), "[posix] pid_alive: a reaped child is not")
        check(not portable.pid_alive("x"), "[posix] pid_alive: garbage is not")
        check(not portable.pid_alive(0), "[posix] pid_alive: pid 0 is not (os.kill(0, 0) would signal the group)")
        check(portable.pid_alive(1), "[posix] pid_alive: a live process we may not signal is alive (EPERM)")

    # ---- pid_alive, Windows: MSYS pid -> /proc/<pid>/winpid -> OpenProcess/GetExitCodeProcess
    proc = os.path.join(tmp, "proc")
    for msys, win in ((100, 5000), (101, 5001), (102, 5002), (103, 5003)):
        os.makedirs(os.path.join(proc, str(msys)))
        with open(os.path.join(proc, str(msys), "winpid"), "w") as fh:
            fh.write(f"{win}\n")
    k = FakeKernel32({5000: portable.STILL_ACTIVE, 5001: 0}, denied={5003})
    real_kill = os.kill
    def no_kill(*a):
        raise AssertionError("os.kill called on the Windows branch")
    os.kill = no_kill
    try:
        with env(HARNESS_PLATFORM="windows", HARNESS_PROC_ROOT=proc):
            check(portable.winpid_of(100) == 5000, "[windows] winpid_of reads /proc/<pid>/winpid")
            check(portable.pid_alive(100, k), "[windows] a STILL_ACTIVE process is alive")
            check(not portable.pid_alive(101, k), "[windows] a process with an exit code is not")
            check(not portable.pid_alive(102, k), "[windows] a winpid OpenProcess cannot find is not")
            check(portable.pid_alive(103, k), "[windows] an access-denied process exists (alive)")
            check(not portable.pid_alive(104, k), "[windows] an MSYS pid with no winpid is not")
            check(not portable.pid_alive("x", k), "[windows] garbage is not")
            check(k.closed == [("h", 5000), ("h", 5001)], f"[windows] every opened handle is closed ({k.closed})")
    finally:
        os.kill = real_kill
    # winpid through Git's bash when there is no HARNESS_PROC_ROOT (a native process cannot see MSYS /proc)
    fakebash = os.path.join(tmp, "fakebash")
    with open(fakebash, "w") as fh:
        fh.write("#!/bin/sh\n# argv: -c <script> _ <pid>\n[ \"$4\" = 42 ] && echo 777\n")
    os.chmod(fakebash, 0o755)
    with env(HARNESS_PLATFORM="windows", HARNESS_PROC_ROOT=None, HARNESS_BASH=fakebash):
        check(portable.winpid_of(42) == 777, "[windows] winpid_of asks bash for /proc/<pid>/winpid")
        check(portable.winpid_of(43) is None, "[windows] … and gets None for a pid MSYS does not know")

    # ---- lock_nb / unlock
    path = os.path.join(tmp, "events.jsonl")
    with env(HARNESS_PLATFORM="posix"):
        a, b = open(path, "a"), open(path, "a")
        portable.lock_nb(a)
        try:
            portable.lock_nb(b); got = False
        except BlockingIOError:
            got = True
        check(got, "[posix] lock_nb on a held file raises BlockingIOError")
        portable.unlock(a); portable.lock_nb(b)
        check(True, "[posix] after unlock another handle takes it")
        portable.unlock(b); a.close(); b.close()
    m = FakeMsvcrt()
    with env(HARNESS_PLATFORM="windows"):
        a, b = open(path, "a"), open(path, "a")
        a.write("x"); a.flush()
        portable.lock_nb(a, m)
        check(m.calls[-1] == (m.LK_NBLCK, 1, 0), f"[windows] lock_nb locks byte 0 with LK_NBLCK ({m.calls[-1]})")
        check(a.tell() == 1, "[windows] lock_nb leaves the file position where it was")
        try:
            portable.lock_nb(b, m); got = False
        except BlockingIOError:
            got = True
        check(got, "[windows] lock_nb on a held file raises BlockingIOError (msvcrt's error translated)")
        portable.unlock(a, m)
        check(m.calls[-1][0] == m.LK_UNLCK, "[windows] unlock uses LK_UNLCK")
        portable.lock_nb(b, m); portable.unlock(b, m)
        check(True, "[windows] after unlock another handle takes it")
        a.close(); b.close()

    # ---- callers go through portable
    stats = load("stats")
    check(not hasattr(stats, "fcntl"), "stats.py does not import fcntl (native Windows has none)")
    ev = os.path.join(tmp, "ev.jsonl")
    fake = FakeMsvcrt()
    real_nb, real_un = portable.lock_nb, portable.unlock
    stats.portable.lock_nb = lambda fh: real_nb(fh, fake)
    stats.portable.unlock = lambda fh: real_un(fh, fake)
    try:
        with env(HARNESS_PLATFORM="windows"):
            check(stats.append_event({"event": "t"}, ev), "[windows] stats.append_event appends under msvcrt locking")
            check([c[0] for c in fake.calls] == [fake.LK_NBLCK, fake.LK_UNLCK], f"[windows] … lock then unlock ({fake.calls})")
            # a held lock: the append gives up after LOCK_WAIT_S and returns False
            other = open(ev, "a"); real_nb(other, fake)
            stats.LOCK_WAIT_S = 0.2
            check(stats.append_event({"event": "u"}, ev) is False, "[windows] a held lock makes the append give up (False)")
            real_un(other, fake); other.close()
    finally:
        stats.portable.lock_nb, stats.portable.unlock = real_nb, real_un
    with open(ev) as fh:
        check(fh.read().count("\n") == 1, "only the unlocked append landed")
    with env(HARNESS_PLATFORM="posix"):
        check(stats.append_event({"event": "p"}, ev), "[posix] stats.append_event appends under flock")

    fv = load("fleetview")
    pf = os.path.join(tmp, "w.pid")
    with open(pf, "w") as fh:
        fh.write(f"{os.getpid()}\n")
    seen = []
    real = portable.pid_alive
    fv.portable.pid_alive = lambda pid: seen.append(pid) or True
    try:
        check(fv.pid_alive(pf) and seen == [os.getpid()], "fleetview.pid_alive reads the pid file and asks portable.pid_alive")
    finally:
        fv.portable.pid_alive = real
    check(not fv.pid_alive(os.path.join(tmp, "missing.pid")), "fleetview.pid_alive: no pid file is not alive")

    wd = load("web_data")
    claim = os.path.join(tmp, "claim")
    with open(claim, "w") as fh:
        fh.write(f"pool-1 {os.getpid()} 123\n")
    seen = []
    wd.portable.pid_alive = lambda pid: seen.append(pid) or True
    try:
        check(wd.claim_alive(claim) and seen == [str(os.getpid())], "web_data.claim_alive asks portable.pid_alive")
    finally:
        wd.portable.pid_alive = real

    print(f"── {'FAILED' if fails else 'passed'} ({fails} failure(s))")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

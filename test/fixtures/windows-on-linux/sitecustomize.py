"""An msvcrt for a Linux host forced onto the Windows code paths (HARNESS_PLATFORM=windows): the one stdlib module
scripts/portable.py's lock_nb/unlock import there. `locking(fd, mode, nbytes)` is flock on that descriptor, so a
second holder fails with PermissionError, as msvcrt's does. test/test_cli_matrix.sh puts this directory on
PYTHONPATH for its headless-* rows when HARNESS_MATRIX_HEADLESS_PLATFORM=windows and the host is not Windows.

It is a sitecustomize, not an msvcrt.py on the path, because the stdlib's subprocess decides it is on Windows when
`import msvcrt` works: it is imported first, then the module is registered for the code that asks for it later."""
import fcntl, subprocess, sys, types   # noqa: F401  (subprocess first: see above)

LK_UNLCK, LK_LOCK, LK_NBLCK = 0, 1, 2


def locking(fd, mode, nbytes):
    if mode == LK_UNLCK:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if mode == LK_NBLCK else 0))
    except BlockingIOError as e:
        raise PermissionError(13, "Permission denied") from e


_m = types.ModuleType("msvcrt")
_m.LK_UNLCK, _m.LK_LOCK, _m.LK_NBLCK, _m.locking = LK_UNLCK, LK_LOCK, LK_NBLCK, locking
sys.modules["msvcrt"] = _m

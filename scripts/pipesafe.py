"""pipesafe.py — one shared way for a CLI to end quietly when its reader closes stdout early (#713).

`cmd | head -1`, `cmd | true`: the reader exits, the next write or the flush at interpreter exit raises
BrokenPipeError, and python prints "Exception ignored on flushing sys.stdout" and exits 120. `run(main)`
is the entrypoint wrapper — `sys.exit(pipesafe.run(main))` — that flushes inside the guard, and on a
closed pipe points stdout at devnull (so the exit-time flush cannot raise again) and exits cleanly.
stats.py's `_print_report` (#671) does the same for its one print. A `SystemExit` out of `main` (argparse's
`--help`, #783) is caught so its output is flushed inside the guard too, and its status is returned.

A closed pipe is not a failure of the command: the status is the one `main` returned (0 when the pipe
broke before `main` finished). A closed standard output (`>&-`, sys.stdout None, #806) is the same: output is dropped,
no traceback, the status `main` returned. Stdlib only.
"""
import os, sys


def quiet_stdout():
    """Point stdout at devnull so nothing buffered raises BrokenPipeError again at interpreter exit."""
    try:
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    except (OSError, ValueError, AttributeError):
        pass


def run(main, *args):
    """main(*args)'s exit status; a reader that closed stdout early ends the command quietly instead."""
    try:
        rc = main(*args)
    except BrokenPipeError:
        quiet_stdout()
        return 0
    except SystemExit as e:   # #783: argparse prints --help / a usage error, then exits inside parse_args
        rc = e.code
    flush()
    return rc


def flush():
    """sys.stdout.flush() that ends quietly on a closed pipe, and on a closed stdout (`>&-`: sys.stdout is None, #806)."""
    if sys.stdout is None:
        return
    try:
        sys.stdout.flush()
    except BrokenPipeError:
        quiet_stdout()

"""pipesafe.py — one shared way for a CLI to end quietly when its reader closes stdout early (#713).

`cmd | head -1`, `cmd | true`: the reader exits, the next write or the flush at interpreter exit raises
BrokenPipeError, and python prints "Exception ignored on flushing sys.stdout" and exits 120. `run(main)`
is the entrypoint wrapper — `sys.exit(pipesafe.run(main))` — that flushes inside the guard, and on a
closed pipe points stdout at devnull (so the exit-time flush cannot raise again) and exits cleanly.
stats.py's `_print_report` (#671) does the same for its one print. A `SystemExit` out of `main` (argparse's
`--help`, #783) is caught so its output is flushed inside the guard too, and its status is returned.

A closed pipe is not a failure of the command: the status is the one `main` returned (0 when the pipe
broke before `main` finished). Any other stdout write error (a full disk, ENOSPC; EIO) is a failure (#882): one line on
stderr, `harness <cmd>: cannot write output: No space left on device`, status 1, no traceback and no "Exception ignored".
A closed standard output (`>&-`, sys.stdout None, #806) is the same: output is dropped,
no traceback, the status `main` returned, and --help is dropped too (#837). Stdlib only.
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
    if sys.stdout is None:   # #837: `>&-`; argparse would print --help on stderr, so drop output like the rest
        sys.stdout = open(os.devnull, "w")
    try:
        rc = main(*args)
    except BrokenPipeError:
        quiet_stdout()
        return 0
    except OSError as e:
        if e.filename is not None or e.errno is None:   # a failed open()/stat of a named path is main's, not stdout's
            raise
        return write_failed(e)
    except SystemExit as e:   # #783: argparse prints --help / a usage error, then exits inside parse_args
        rc = e.code
    try:
        flush()
    except OSError as e:
        return write_failed(e)
    return rc


def prog():
    """`harness tier` for scripts/tier.py, `harness bench` for bench/run.py: the name an error line starts with."""
    path = os.path.abspath(sys.argv[0]) if sys.argv and sys.argv[0] else "harness"
    name = os.path.splitext(os.path.basename(path))[0]
    if name == "run":
        name = os.path.basename(os.path.dirname(path))
    return "harness " + name


def write_failed(e):
    """A stdout write error other than EPIPE (ENOSPC, EIO): one stderr line naming it, status 1. Stdout then points
    at devnull so the buffered rest cannot raise again at interpreter exit."""
    quiet_stdout()
    try:
        sys.stderr.write(f"{prog()}: cannot write output: {e.strerror or e}\n")
        sys.stderr.flush()
    except (OSError, ValueError):
        pass
    return 1


def flush():
    """sys.stdout.flush() that ends quietly on a closed pipe, and on a closed stdout (`>&-`: sys.stdout is None, #806)."""
    if sys.stdout is None:
        return
    try:
        sys.stdout.flush()
    except BrokenPipeError:
        quiet_stdout()

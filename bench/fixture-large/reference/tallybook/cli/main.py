"""`tallybook`: reads the global options, finds the command, runs it and turns the outcome into output and an exit
status (0 done, 1 refused by the program's rules, 2 the command line itself is wrong). Nothing but a clean message
ever reaches the user: no traceback."""
import os
import sys

from .. import __version__
from ..errors import TallybookError
from ..dates import parse_date
from . import accounts, calc, db, imports, planning, reports, txs
from .args import HelpRequested, UsageError, is_long_option, parse, split_long
from .common import DEFAULT_DB, Context, Output

MODULES = (db, accounts, txs, imports, planning, reports, calc)

GLOBAL_HELP = """\
options:
  --db FILE     the book file (default: $TALLYBOOK_DB, else ./tallybook.db)
  --today DATE  the date to use as today, YYYY-MM-DD (default: the real date)
  --version     print the version and stop
  -h, --help    print this help and stop
"""


def registry():
    """{path tuple: Command} for every command of this build."""
    commands = {}
    for module in MODULES:
        for command in module.commands():
            commands[command.path] = command
    return commands


# ---------------------------------------------------------------- help

def _listing(commands, prefix):
    rows = [(" ".join(path[len(prefix):]), c.summary) for path, c in commands.items() if path[:len(prefix)] == prefix]
    width = max(len(name) for name, _ in rows)
    return "".join(("  %s  %s\n" % (name.ljust(width), summary)).rstrip() + "\n" for name, summary in rows)


def help_text(commands, path):
    if path in commands:
        command = commands[path]
        return "usage: %s\n\n%s\n" % (command.usage(), command.summary)
    words = " ".join(("tallybook",) + path)
    if not path:
        head = "usage: tallybook [--db FILE] [--today DATE] COMMAND [ARGS]\n"
        return head + "\ncommands:\n" + _listing(commands, path) + "\n" + GLOBAL_HELP
    return "usage: %s COMMAND [ARGS]\n\ncommands:\n%s" % (words, _listing(commands, path))


# ---------------------------------------------------------------- the global options and the command words

def read_globals(argv):
    """Leading global options, left to right. Returns (options, rest, early) where `early` is output that ends the
    run at once (--help, --version)."""
    found = {}
    i = 0
    while i < len(argv):
        token = argv[i]
        if token in ("-h", "--help"):
            raise HelpRequested(())
        if token == "--":
            i += 1
            break
        if not is_long_option(token):
            break
        i += 1
        name, inline = split_long(token)
        if name == "help":
            raise HelpRequested(())
        if name == "version":
            if inline is not None:
                raise UsageError("option --version takes no value")
            return found, [], "tallybook %s\n" % __version__
        if name not in ("db", "today"):
            raise UsageError("unknown option '--%s'" % name)
        if name in found:
            raise UsageError("option --%s given twice" % name)
        if inline is not None:
            found[name] = inline
        elif i < len(argv):
            found[name] = argv[i]
            i += 1
        else:
            raise UsageError("option --%s needs a value" % name)
        if name == "today":
            parse_date(found["today"])
    return found, argv[i:], None


def resolve(commands, words):
    """Walk the command words down to a leaf. Returns (Command, remaining arguments)."""
    path = ()
    while True:
        if not words:
            raise UsageError("missing command" if not path else "missing subcommand of '%s'" % " ".join(path))
        word = words[0]
        if word in ("-h", "--help"):
            raise HelpRequested(path)
        candidate = path + (word,)
        if candidate in commands:
            return commands[candidate], words[1:]
        if any(p[:len(candidate)] == candidate for p in commands):
            path, words = candidate, words[1:]
            continue
        if word.startswith("--") and len(word) > 2:
            raise UsageError("unknown option '%s'" % word)
        raise UsageError("unknown command '%s'" % " ".join(candidate))


# ---------------------------------------------------------------- one run

def execute(argv):
    """Run `argv` (without the program name). Returns (stdout text, stderr text, exit status); a run that fails
    produces no stdout."""
    commands = registry()
    ctx = None
    try:
        found, rest, early = read_globals(argv)
        if early is not None:
            return early, "", 0
        command, tail = resolve(commands, rest)
        ctx = Context(found.get("db") or os.environ.get("TALLYBOOK_DB") or DEFAULT_DB, found.get("today"))
        result = command.handler(ctx, parse(command, tail))
        if result is None:
            result = Output()
        elif isinstance(result, str):
            result = Output(result)
        return result.text, "", result.status
    except HelpRequested as exc:
        return help_text(commands, exc.path), "", 0
    except UsageError as exc:
        return "", "tallybook: %s\nTry 'tallybook --help'.\n" % exc, 2
    except TallybookError as exc:
        return "", "tallybook: %s\n" % exc, 1
    except OverflowError:
        return "", "tallybook: a date or number is outside what the calendar can hold\n", 1
    except KeyboardInterrupt:
        return "", "tallybook: interrupted\n", 1
    except Exception as exc:  # a bug or a surprise from outside; still no traceback
        return "", "tallybook: unexpected %s: %s\n" % (type(exc).__name__, exc), 1
    finally:
        if ctx is not None:
            ctx.close()


def _write(stream, text):
    """UTF-8 bytes with plain \\n line ends when the stream has a binary side (the real stdout and stderr)."""
    raw = getattr(stream, "buffer", None)
    if raw is None:
        stream.write(text)
        stream.flush()
        return
    if text:
        raw.write(text.encode("utf-8", "replace"))
    raw.flush()


def _reader_went_away():
    """Point stdout at the null device so that the final flush at exit has nothing left to complain about."""
    try:
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    except (OSError, ValueError):
        pass


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    out, err, status = execute(args)
    try:
        _write(sys.stdout, out)
    except BrokenPipeError:
        _reader_went_away()
        return 0
    try:
        _write(sys.stderr, err)
    except (BrokenPipeError, OSError):
        pass
    return status


if __name__ == "__main__":
    raise SystemExit(main())

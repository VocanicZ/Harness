"""A small, strict reader for command lines.

Every command is described once by a `Command` (its words, its positional arguments, its options and a handler).
The reader turns the arguments after the command words into a `Parsed` value, or raises `UsageError`, which the
caller reports as a usage mistake (exit status 2). Rules, in short:

* `--name`, `--name=value`: a long option. An option that takes a value takes the next argument as it is, whatever
  it looks like (`--note -5` is fine). `--` ends the options.
* `-h`/`--help` and the short names a command declares (`-p`) are the only one-dash options; every other argument
  that begins with a single dash (`-5`, `-`, `-x y`) is an ordinary value.
* Options and positional arguments may be mixed; a value option that is not marked `repeat` may be given once.
"""
from dataclasses import dataclass, field
from typing import Callable, List, Optional


class UsageError(Exception):
    """The command line itself is wrong: an unknown command or option, a missing or surplus argument."""


class HelpRequested(Exception):
    def __init__(self, path):
        super().__init__("help")
        self.path = path


@dataclass(frozen=True)
class Opt:
    name: str                       # long name without the dashes
    metavar: Optional[str] = None   # None: a flag that takes no value
    short: Optional[str] = None     # a one-dash alias, e.g. "p"
    repeat: bool = False
    required: bool = False


@dataclass(frozen=True)
class Arg:
    name: str
    kind: str = "one"               # one | opt | many (zero or more) | some (one or more)


@dataclass
class Command:
    path: tuple
    summary: str
    handler: Callable
    args: List[Arg] = field(default_factory=list)
    opts: List[Opt] = field(default_factory=list)

    def usage(self):
        parts = ["tallybook"] + list(self.path)
        for a in self.args:
            parts.append({"one": a.name, "opt": "[%s]" % a.name, "many": "[%s...]" % a.name,
                          "some": "%s..." % a.name}[a.kind])
        for o in self.opts:
            text = "--" + o.name + (" " + o.metavar if o.metavar else "")
            parts.append(text if o.required else "[%s]" % text)
        return " ".join(parts)


@dataclass
class Parsed:
    args: dict
    opts: dict

    def opt(self, name, default=None):
        value = self.opts.get(name)
        return default if value is None else value

    def flag(self, name):
        return bool(self.opts.get(name))

    def many(self, name):
        return list(self.opts.get(name) or [])


def split_long(token):
    """'--name=value' -> ('name', 'value'); '--name' -> ('name', None)."""
    name, eq, value = token[2:].partition("=")
    return name, (value if eq else None)


def is_long_option(token):
    return token.startswith("--") and len(token) > 2


def parse(command, argv):
    by_long = {o.name: o for o in command.opts}
    by_short = {o.short: o for o in command.opts if o.short}
    positional, given = [], {}
    only_values = False
    i = 0
    while i < len(argv):
        token = argv[i]
        i += 1
        if only_values:
            positional.append(token)
            continue
        if token == "--":
            only_values = True
            continue
        if token in ("-h", "--help"):
            raise HelpRequested(command.path)
        if is_long_option(token):
            name, inline = split_long(token)
            opt = by_long.get(name)
            if opt is None:
                raise UsageError("unknown option '--%s'" % name)
            if opt.metavar is None:
                if inline is not None:
                    raise UsageError("option --%s takes no value" % name)
                value = True
            elif inline is not None:
                value = inline
            elif i < len(argv):
                value = argv[i]
                i += 1
            else:
                raise UsageError("option --%s needs a value (%s)" % (name, opt.metavar))
        elif len(token) == 2 and token[0] == "-" and token[1] in by_short:
            opt = by_short[token[1]]
            if i >= len(argv):
                raise UsageError("option -%s needs a value (%s)" % (opt.short, opt.metavar))
            value = argv[i]
            i += 1
        else:
            positional.append(token)
            continue
        if opt.repeat:
            given.setdefault(opt.name, []).append(value)
        elif opt.name in given:
            raise UsageError("option --%s given twice" % opt.name)
        else:
            given[opt.name] = value
    for opt in command.opts:
        if opt.required and opt.name not in given:
            raise UsageError(("missing option --%s %s" % (opt.name, opt.metavar or "")).rstrip())
    return Parsed(_bind(command, positional), given)


def _bind(command, values):
    bound = {}
    at = 0
    for arg in command.args:
        if arg.kind in ("many", "some"):
            rest = values[at:]
            if arg.kind == "some" and not rest:
                raise UsageError("missing %s" % arg.name)
            bound[arg.name] = rest
            at = len(values)
        elif at < len(values):
            bound[arg.name] = values[at]
            at += 1
        elif arg.kind == "one":
            raise UsageError("missing %s" % arg.name)
        else:
            bound[arg.name] = None
    if at < len(values):
        raise UsageError("unexpected argument '%s'" % values[at])
    return bound

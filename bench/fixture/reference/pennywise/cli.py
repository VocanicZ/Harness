import argparse
import csv
import errno
import json
import os
import sys

from . import ledger


def _date(text):
    try:
        return ledger.parse_date(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc))


def _read(path):
    """The ledger text. Bytes are decoded as UTF-8; a byte order mark is dropped (UnicodeDecodeError on bad bytes)."""
    if path == "-":
        stream = getattr(sys.stdin, "buffer", None)
        data = stream.read() if stream is not None else sys.stdin.read()
    else:
        with open(path, "rb") as fh:
            data = fh.read()
    return data.decode("utf-8-sig") if isinstance(data, bytes) else data


def _money(value):
    return ledger.money(value)


def _sorted(entries):
    return sorted(entries, key=lambda e: e.date)  # stable: same-day entries keep file order


def _emit_json(obj):
    print(json.dumps(obj))


def _cmd_balance(args, entries):
    total = _money(ledger.balance(entries))
    if args.json:
        _emit_json({"balance": total})
    else:
        print(total)


def _cmd_summary(args, entries):
    group = ledger.by_month if args.by == "month" else ledger.by_category
    totals = {k: _money(v) for k, v in group(entries).items()}
    if args.json:
        _emit_json(totals)
    else:
        for name, total in totals.items():
            print("%s  %s" % (name, total))


def _cmd_list(args, entries):
    shown = _sorted(ledger.filter_entries(entries, args.category, args.since, args.until))
    if args.json:
        _emit_json([{"date": e.date.isoformat(), "category": e.category,
                     "amount": _money(e.amount), "note": e.note} for e in shown])
    else:
        for e in shown:
            print(ledger.format_entry(e))


def _cmd_export(args, entries):
    out = csv.writer(sys.stdout, lineterminator="\n")
    out.writerow(["date", "category", "amount", "note"])
    for e in _sorted(entries):
        out.writerow([e.date.isoformat(), e.category, _money(e.amount), e.note])


def _cmd_add(args):
    try:
        entry = ledger.make_entry(args.date, args.category, args.amount, args.note)
    except ValueError as exc:
        print("pennywise: %s" % exc, file=sys.stderr)
        return 1
    try:
        try:
            with open(args.file, "rb") as fh:
                existing = fh.read()
        except FileNotFoundError:
            existing = b""
        with open(args.file, "ab") as fh:
            if existing and not existing.endswith((b"\n", b"\r")):
                fh.write(b"\n")
            fh.write((ledger.format_entry(entry) + "\n").encode("utf-8"))
    except OSError as exc:
        print("pennywise: %s" % exc, file=sys.stderr)
        return 2
    print(ledger.format_entry(entry))
    return 0


def _parser():
    p = argparse.ArgumentParser(prog="pennywise")
    sub = p.add_subparsers(dest="command", required=True)

    def reader(name, handler, **extra):
        s = sub.add_parser(name)
        s.add_argument("file")
        s.set_defaults(handler=handler)
        return s

    s = reader("balance", _cmd_balance)
    s.add_argument("--json", action="store_true")
    s = reader("summary", _cmd_summary)
    s.add_argument("--by", choices=["category", "month"], default="category")
    s.add_argument("--json", action="store_true")
    s = reader("list", _cmd_list)
    s.add_argument("--category")
    s.add_argument("--since", type=_date)
    s.add_argument("--until", type=_date)
    s.add_argument("--json", action="store_true")
    s = reader("export", _cmd_export)
    s.add_argument("--format", choices=["csv"], default="csv")

    s = sub.add_parser("add")
    s.add_argument("file")
    s.add_argument("date")
    s.add_argument("category")
    s.add_argument("amount")
    s.add_argument("note", nargs="?", default="")
    s.set_defaults(handler=None)
    return p


def _add_args(argv):
    """`add`'s arguments are all positional: FILE DATE CATEGORY AMOUNT [NOTE], each taken as typed, so a
    dash-led amount (`-5`, `-abc`) or note (`-refund`) is an argument and not an option. A leading `--` is
    dropped; `-h` / `--help` before it still reaches argparse. None leaves the line to argparse."""
    rest = list(argv[1:])
    if "--" in rest:
        rest.remove("--")
    elif "-h" in rest or "--help" in rest:
        return None
    ns = argparse.Namespace(command="add")
    if not 4 <= len(rest) <= 5:
        return None
    ns.file, ns.date, ns.category, ns.amount = rest[:4]
    ns.note = rest[4] if len(rest) == 5 else ""
    return ns


def main(argv=None):
    """Run the CLI; its exit status. A reader that went away (`pennywise list | head -1`) ends the output
    quietly with status 0: no traceback, nothing on standard error."""
    try:
        try:
            status = _main(sys.argv[1:] if argv is None else list(argv))
            if sys.stdout is not None:
                sys.stdout.flush()
            return status
        except OSError as exc:   # a write to a pipe nobody reads is EINVAL on Windows, EPIPE elsewhere
            if os.name == "nt" and exc.errno == errno.EINVAL:
                raise BrokenPipeError(errno.EPIPE, "Broken pipe") from exc
            raise
    except BrokenPipeError:
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())   # the exit-time flush must not fail too
        except (OSError, ValueError, AttributeError):
            pass
        return 0


def _main(argv):
    args = (_add_args(argv) if argv[:1] == ["add"] else None) or _parser().parse_args(argv)
    if args.command == "add":
        return _cmd_add(args)
    try:
        text = _read(args.file)
    except (OSError, UnicodeDecodeError) as exc:
        print("pennywise: cannot read %s: %s" % (args.file, exc), file=sys.stderr)
        return 2
    try:
        entries = ledger.parse(text)
    except ledger.ParseError as exc:
        print("pennywise: %s" % exc, file=sys.stderr)
        return 1
    args.handler(args, entries)
    return 0

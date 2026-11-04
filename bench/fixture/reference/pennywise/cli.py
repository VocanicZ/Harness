import argparse
import csv
import json
import sys

from . import ledger


def _date(text):
    try:
        return ledger.parse_date(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc))


def _read(path):
    if path == "-":
        return sys.stdin.read()
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _money(value):
    return "%.2f" % value


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
            with open(args.file, encoding="utf-8") as fh:
                existing = fh.read()
        except FileNotFoundError:
            existing = ""
        with open(args.file, "a", encoding="utf-8", newline="") as fh:
            if existing and not existing.endswith("\n"):
                fh.write("\n")
            fh.write(ledger.format_entry(entry) + "\n")
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


def main(argv=None):
    args = _parser().parse_args(argv)
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

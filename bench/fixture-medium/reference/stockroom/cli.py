"""The `stockroom` command. The command line is checked first (exit 2), then files are read, then the request runs."""
import os
import sys

from . import fulfil, money, pricing, render
from .catalog import norm_sku, parse_catalog
from .dates import parse_date
from .errors import DataError, ParseError, Refused, UsageError
from .movements import (format_movement, history, new_movement, parse_movements, stock_levels)
from .orders import norm_order, parse_orders
from .textio import append_line, read_file

PROG = "stockroom"
# command -> (positional arguments min, max, options that take no value, options that take one, files it reads)
COMMANDS = {
    "stock": (0, 0, ("--json",), (), "cm"),
    "low": (0, 0, ("--json",), (), "cm"),
    "history": (1, 1, ("--json",), (), "cm"),
    "receive": (3, 4, (), (), "cm"),
    "ship": (3, 4, (), (), "cm"),
    "quote": (1, 1, ("--json",), (), "co"),
    "fulfil": (2, 2, (), (), "cmo"),
    "invoice": (1, 1, ("--json",), (), "cmo"),
    "report": (0, 0, (), ("--format",), "cmo"),
}
FILES = {"c": "catalog.txt", "m": "movements.txt", "o": "orders.txt"}


def parse_args(argv):
    """(command, positionals, options): UsageError for anything wrong with the command line. `--dir DIR` goes anywhere."""
    if not argv:
        raise UsageError("no command")
    args = list(argv)
    opts, rest, i = {}, [], 0
    command = None
    while i < len(args):
        a = args[i]
        if a == "--dir":
            if i + 1 >= len(args):
                raise UsageError("--dir needs a folder")
            opts["--dir"] = args[i + 1]
            i += 2
            continue
        rest.append(a)
        i += 1
    if not rest:
        raise UsageError("no command")
    command, rest = rest[0], rest[1:]
    if command not in COMMANDS:
        raise UsageError("unknown command %r" % command)
    low, high, flags, valued, _ = COMMANDS[command]
    positional, i = [], 0
    while i < len(rest):
        a = rest[i]
        if a in flags:
            opts[a] = True
        elif a in valued:
            if i + 1 >= len(rest):
                raise UsageError("%s needs a value" % a)
            opts[a] = rest[i + 1]
            i += 1
        elif a.startswith("-") and len(a) > 1 and command not in ("receive", "ship", "fulfil"):
            raise UsageError("unknown option %r" % a)
        else:
            positional.append(a)
        i += 1
    if not low <= len(positional) <= high:
        raise UsageError("%s takes %s argument(s)" % (command, low if low == high else "%d to %d" % (low, high)))
    if opts.get("--format", "text") not in ("text", "csv", "json"):
        raise UsageError("--format is text, csv or json")
    if command in ("receive", "ship", "fulfil"):
        try:
            opts["date"] = parse_date(positional[0] if command != "fulfil" else positional[1])
        except ValueError as exc:
            raise UsageError(str(exc))
    return command, positional, opts


def load(folder, wanted):
    """{'c': catalog, 'm': movements, 'o': orders} for the files named in `wanted`, each parsed and labelled with its file."""
    if not os.path.isdir(folder):
        raise DataError("cannot read %s: not a folder" % folder)
    out = {}
    for key in "cmo":
        if key not in wanted:
            continue
        text = read_file(os.path.join(folder, FILES[key]), required=(key == "c"))
        try:
            if key == "c":
                out[key] = parse_catalog(text)
            elif key == "m":
                out[key] = parse_movements(text, out["c"])
            else:
                out[key] = parse_orders(text, out["c"])
        except ParseError as exc:
            raise exc.in_file(FILES[key])
    return out


def find_order(orders, text):
    oid = norm_order(text)
    for o in orders:
        if o.id == oid:
            return o
    raise Refused("no such order %r" % text)


def out(lines):
    for line in lines:
        print(line)


def run(command, positional, opts, data, folder):
    as_json = opts.get("--json")
    catalog = data["c"]
    if command in ("stock", "low"):
        levels = stock_levels(catalog, data["m"])
        rows = (render.stock_rows if command == "stock" else render.low_rows)(catalog, levels)
        if as_json:
            print(render.dump(rows))
        else:
            out((render.stock_text if command == "stock" else render.low_text)(rows))
    elif command == "history":
        sku = norm_sku(positional[0])
        if sku is None or sku not in catalog:
            raise Refused("unknown SKU %r" % positional[0])
        rows = render.history_rows(history(data["m"], sku))
        if as_json:
            print(render.dump(rows))
        else:
            out(render.history_text(rows))
    elif command in ("receive", "ship"):
        note = positional[3] if len(positional) == 4 else ""
        m = new_movement(data["m"], catalog, opts["date"], positional[1], positional[2], note,
                         1 if command == "receive" else -1)
        line = format_movement(m)
        append_line(os.path.join(folder, FILES["m"]), line)
        print(line)
    elif command == "quote":
        q = pricing.price(find_order(data["o"], positional[0]), catalog)
        print(render.dump(render.quote_obj(q))) if as_json else out(render.quote_text(q))
    elif command == "fulfil":
        order = find_order(data["o"], positional[0])
        shipments, new = fulfil.plan(order, data["m"], opts["date"])
        for m in new:
            append_line(os.path.join(folder, FILES["m"]), format_movement(m))
        state = fulfil.status(order, list(data["m"]) + new)
        out(render.fulfil_text(shipments, state))
    elif command == "invoice":
        order = find_order(data["o"], positional[0])
        sent = fulfil.shipped_so_far(order, data["m"])
        if not any(sent):
            raise Refused("nothing has shipped on %s yet" % order.id)
        q = pricing.price(order, catalog, sent)
        print(render.dump(render.quote_obj(q))) if as_json else out(render.quote_text(q, "invoice "))
    elif command == "report":
        rows = report_rows(data["o"], catalog, data["m"])
        fmt = opts.get("--format", "text")
        if fmt == "json":
            print(render.dump(rows))
        else:
            out(render.report_csv(rows) if fmt == "csv" else render.report_text(rows))


def report_rows(orders, catalog, moves):
    rows = []
    for o in sorted(orders, key=lambda o: (o.date, int(o.id[3:]), o.id)):
        sent = fulfil.shipped_so_far(o, moves)
        invoiced = pricing.price(o, catalog, sent).total if any(sent) else 0
        rows.append({"order": o.id, "date": o.date.isoformat(), "customer": o.customer,
                     "status": fulfil.status(o, moves), "ordered": sum(q for _, q in o.lines), "shipped": sum(sent),
                     "quoted": money.fmt(pricing.price(o, catalog).total), "invoiced": money.fmt(invoiced)})
    return rows


def main(argv=None):
    """Run the CLI; its exit status. A reader that went away ends the output quietly with status 0."""
    try:
        status = _main(sys.argv[1:] if argv is None else list(argv))
        if sys.stdout is not None:
            sys.stdout.flush()
        return status
    except BrokenPipeError:
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        except (OSError, ValueError, AttributeError):
            pass
        return 0


def _main(argv):
    try:
        command, positional, opts = parse_args(argv)
        folder = opts.get("--dir", ".")
        data = load(folder, COMMANDS[command][4])
    except UsageError as exc:
        print("%s: %s" % (PROG, exc), file=sys.stderr)
        return 2
    except DataError as exc:
        print("%s: %s" % (PROG, exc), file=sys.stderr)
        return 2
    except ParseError as exc:
        print("%s: %s" % (PROG, exc), file=sys.stderr)
        return 1
    try:
        run(command, positional, opts, data, folder)
    except Refused as exc:
        print("%s: %s" % (PROG, exc), file=sys.stderr)
        return 1
    except DataError as exc:
        print("%s: %s" % (PROG, exc), file=sys.stderr)
        return 2
    return 0

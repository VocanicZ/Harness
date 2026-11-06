"""Transactions, searching, and getting the book out: tx add | list | show | delete, query, export, journal."""
from ..errors import ParseError
from ..export import transaction_to_dict, transactions_to_csv, transactions_to_json
from ..journal import format_journal, format_transaction, parse_journal
from .args import Arg, Command, Opt
from .common import (CliError, build_transaction, counts_text, json_text, label, optional_date, optional_number,
                     read_text, tx_listing, whole_number)

TEMPLATE_OPTS = [Opt("narration", "TEXT"), Opt("flag", "FLAG"), Opt("tag", "TAG", repeat=True),
                 Opt("posting", "POSTING", short="p", repeat=True)]
PAGING_OPTS = [Opt("limit", "N"), Opt("offset", "N"), Opt("json")]


def tx_add(ctx, args):
    day = optional_date(args.opt("date"), ctx.today())
    tx = build_transaction(day, args.args["PAYEE"], args.opt("narration"), args.opt("flag"), args.many("tag"),
                           args.many("posting"))
    stored = ctx.store().add_transaction(tx)
    if args.flag("json"):
        return json_text(transaction_to_dict(stored))
    return "added transaction %d\n" % stored.id


def _select(ctx, args, query):
    store = ctx.store()
    limit = optional_number(args.opt("limit"), "limit")
    offset = whole_number(args.opt("offset", "0"), "offset")
    return store, store.transactions(query, limit=limit, offset=offset)


def tx_list(ctx, args):
    _, found = _select(ctx, args, args.opt("query"))
    return tx_listing(found, args.flag("json"))


def query(ctx, args):
    if args.flag("count"):
        return "%d\n" % ctx.store().count_transactions(args.args["QUERY"])
    _, found = _select(ctx, args, args.args["QUERY"])
    return tx_listing(found, args.flag("json"))


def tx_show(ctx, args):
    tx = ctx.store().get_transaction(whole_number(args.args["ID"], "transaction id", 1))
    if args.flag("json"):
        return json_text(transaction_to_dict(tx))
    return "; id %d\n%s" % (tx.id, format_transaction(tx))


def tx_delete(ctx, args):
    tx = ctx.store().delete_transaction(whole_number(args.args["ID"], "transaction id", 1))
    return "deleted transaction %d\n" % tx.id


def export(ctx, args):
    kind = args.opt("format", "csv")
    text_query = args.opt("query")
    if kind == "journal":
        if text_query is not None:
            raise CliError("--query cannot be used with --format journal")
        return format_journal(ctx.store().journal())
    if kind not in ("csv", "json"):
        raise CliError("unknown export format '%s': expected csv, json or journal" % kind)
    found = ctx.store().transactions(text_query)
    return transactions_to_csv(found) if kind == "csv" else transactions_to_json(found)


def journal_export(ctx, args):
    return format_journal(ctx.store().journal())


def journal_import(ctx, args):
    path = args.args["FILE"]
    store = ctx.store()
    text = read_text(path, "journal")
    try:
        journal = parse_journal(text)
    except ParseError as exc:
        raise CliError("%s: %s" % (label(path), exc))
    store.load_journal(journal)
    return "imported %s\n" % counts_text(journal)


def commands():
    return [
        Command(("tx", "add"), "add a transaction", tx_add, args=[Arg("PAYEE")],
                opts=[Opt("date", "DATE")] + TEMPLATE_OPTS + [Opt("json")]),
        Command(("tx", "list"), "list transactions, optionally only those matching a query", tx_list,
                opts=[Opt("query", "QUERY")] + PAGING_OPTS),
        Command(("tx", "show"), "show one transaction", tx_show, args=[Arg("ID")], opts=[Opt("json")]),
        Command(("tx", "delete"), "delete a transaction", tx_delete, args=[Arg("ID")]),
        Command(("query",), "list the transactions matching a query", query, args=[Arg("QUERY")],
                opts=PAGING_OPTS + [Opt("count")]),
        Command(("export",), "write transactions as csv or json, or the whole book as a journal", export,
                opts=[Opt("format", "FORMAT"), Opt("query", "QUERY")]),
        Command(("journal", "export"), "write the whole book as journal text", journal_export),
        Command(("journal", "import"), "load a journal file into the book (all or nothing)", journal_import,
                args=[Arg("FILE")]),
    ]

"""The five reports: report trial-balance | balance-sheet | income-statement | cashflow | register.

`build_report` is shared with `calc report`, which runs the same reports over a journal file instead of a book."""
from .. import reports as lib
from ..dates import Period
from .args import Arg, Command, Opt, UsageError
from .common import json_text, month_of, optional_date

KINDS = ("trial-balance", "balance-sheet", "income-statement", "cashflow", "register")

OPTIONS = {
    "trial-balance": ["as-of"],
    "balance-sheet": ["as-of", "convert"],
    "income-statement": ["period", "convert"],
    "cashflow": ["period"],
    "register": ["period", "rollup"],
}
ALL_OPTS = {
    "as-of": Opt("as-of", "DATE"), "period": Opt("period", "PERIOD"), "convert": Opt("convert", "CUR"),
    "rollup": Opt("rollup"),
}


def build_report(ledger, kind, account, args, today):
    """The report dict for `kind` from the options in `args`; `today` is a date."""
    if kind == "trial-balance":
        return lib.trial_balance(ledger, optional_date(args.opt("as-of")))
    if kind == "balance-sheet":
        return lib.balance_sheet(ledger, optional_date(args.opt("as-of"), today), convert_to=args.opt("convert"),
                                 today=today)
    if kind == "income-statement":
        return lib.income_statement(ledger, _period(args, today), convert_to=args.opt("convert"))
    if kind == "cashflow":
        return lib.cashflow(ledger, _period(args, today))
    if kind == "register":
        text = args.opt("period")
        return lib.register(ledger, account, Period.parse(text) if text is not None else None,
                            rollup=args.flag("rollup"))
    raise UsageError("unknown report '%s': expected %s" % (kind, ", ".join(KINDS)))


def _period(args, today):
    text = args.opt("period")
    return Period.parse(text) if text is not None else month_of(today)


def show(report, as_json):
    return json_text(report) if as_json else lib.render_text(report)


def make_handler(kind):
    def handler(ctx, args):
        ledger = ctx.store().ledger()
        report = build_report(ledger, kind, args.args.get("ACCOUNT"), args, ctx.today())
        return show(report, args.flag("json"))
    return handler


def commands():
    titles = {"trial-balance": "debits and credits of every account", "balance-sheet": "assets, liabilities and equity",
              "income-statement": "income and expenses over a period", "cashflow": "money in and out over a period",
              "register": "the postings of one account with a running balance"}
    out = []
    for kind in KINDS:
        args = [Arg("ACCOUNT")] if kind == "register" else []
        opts = [ALL_OPTS[name] for name in OPTIONS[kind]] + [Opt("json")]
        out.append(Command(("report", kind), titles[kind], make_handler(kind), args=args, opts=opts))
    return out

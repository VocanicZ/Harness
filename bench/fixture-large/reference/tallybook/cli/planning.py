"""Rates, budgets and recurring transactions: rate set | list | remove, budget add | list | remove | status,
recurring add | list | remove | materialize."""
from ..budgets import Budget, budget_status
from ..dates import Period
from ..export import money_to_dict, transaction_to_dict
from ..money import Money
from ..recurring import Recurring
from .args import Arg, Command, Opt
from .common import build_transaction, json_text, month_of, optional_date, optional_number, table
from .txs import TEMPLATE_OPTS


# ---------------------------------------------------------------- rates

def rate_set(ctx, args):
    on = optional_date(args.opt("on"), ctx.today())
    src, dst, text = args.args["FROM"], args.args["TO"], args.args["RATE"]
    ctx.store().set_rate(src, dst, text, on)
    return "set 1 %s = %s %s on %s\n" % (src, text, dst, on.isoformat())


def rate_list(ctx, args):
    rows = ctx.store().rate_rows()
    if args.flag("json"):
        return json_text([{"from": s, "to": d, "date": on.isoformat(), "rate": text} for s, d, on, text in rows])
    if not rows:
        return ""
    return table(["From", "To", "Date", "Rate"], [[s, d, on.isoformat(), text] for s, d, on, text in rows], "lllr")


def rate_remove(ctx, args):
    on = optional_date(args.opt("on"), ctx.today())
    src, dst = args.args["FROM"], args.args["TO"]
    ctx.store().remove_rate(src, dst, on)
    return "removed rate %s -> %s on %s\n" % (src, dst, on.isoformat())


# ---------------------------------------------------------------- budgets

def budget_add(ctx, args):
    kind = args.opt("per", "month")
    start = optional_date(args.opt("start"), ctx.today())
    budget = Budget(args.args["PATTERN"], kind, Money.parse(args.args["AMOUNT"]), start)
    ctx.store().add_budget(budget)
    return "added budget %s %s per %s\n" % (budget.pattern, budget.amount, budget.period_kind)


def budget_list(ctx, args):
    budgets = ctx.store().budgets()
    if args.flag("json"):
        return json_text([{"pattern": b.pattern, "period_kind": b.period_kind, "amount": money_to_dict(b.amount),
                           "start": b.start.isoformat()} for b in budgets])
    if not budgets:
        return ""
    rows = [[b.pattern, b.period_kind, str(b.amount), b.start.isoformat()] for b in budgets]
    return table(["Pattern", "Per", "Amount", "Start"], rows, "llrl")


def budget_remove(ctx, args):
    kind = args.opt("per", "month")
    ctx.store().remove_budget(args.args["PATTERN"], kind)
    return "removed budget %s per %s\n" % (args.args["PATTERN"], kind)


def budget_listing(lines, as_json):
    """Budget lines as a table (Pattern Per Budget Actual Remaining Percent Over) or the JSON array."""
    if as_json:
        return json_text([line.to_dict() for line in lines])
    if not lines:
        return ""
    rows = [[ln.pattern, ln.period_kind, str(ln.budget), str(ln.actual), str(ln.remaining), "%s%%" % ln.percent,
             "over" if ln.over else ""] for ln in lines]
    return table(["Pattern", "Per", "Budget", "Actual", "Remaining", "Percent", "Over"], rows, "llrrrrl")


def budget_status_cmd(ctx, args):
    store = ctx.store()
    text = args.opt("period")
    period = Period.parse(text) if text is not None else month_of(ctx.today())
    return budget_listing(budget_status(store.budgets(), store.ledger(), period), args.flag("json"))


# ---------------------------------------------------------------- recurring

def recurring_add(ctx, args):
    start = optional_date(args.opt("start"), ctx.today())
    template = build_transaction(start, args.args["PAYEE"], args.opt("narration"), args.opt("flag"),
                                 args.many("tag"), args.many("posting"))
    rec = Recurring(args.args["NAME"], args.args["SCHEDULE"], template, start,
                    end=optional_date(args.opt("end")), count=optional_number(args.opt("count"), "count", 1))
    ctx.store().add_recurring(rec)
    return "added recurring %s\n" % rec.name


def _recurring_dict(store, rec):
    template = transaction_to_dict(rec.template)
    through = store.materialized_through(rec.name)
    return {
        "name": rec.name,
        "schedule": str(rec.schedule),
        "start": rec.start.isoformat(),
        "end": rec.end.isoformat() if rec.end else None,
        "count": rec.count,
        "materialized_through": through.isoformat() if through else None,
        "template": {k: template[k] for k in ("payee", "narration", "flag", "tags", "postings")},
    }


def recurring_list(ctx, args):
    store = ctx.store()
    items = store.recurring()
    if args.flag("json"):
        return json_text([_recurring_dict(store, r) for r in items])
    if not items:
        return ""
    rows = []
    for r in items:
        d = _recurring_dict(store, r)
        rows.append([d["name"], d["schedule"], d["start"], d["end"], d["count"], d["materialized_through"],
                     r.template.payee])
    return table(["Name", "Schedule", "Start", "End", "Count", "Through", "Payee"], rows, "lllllll")


def recurring_remove(ctx, args):
    ctx.store().remove_recurring(args.args["NAME"])
    return "removed recurring %s\n" % args.args["NAME"]


def recurring_materialize(ctx, args):
    store = ctx.store()
    upto = optional_date(args.opt("upto"))
    made = store.materialize(upto=upto) if upto is not None else store.materialize(today=ctx.today())
    if args.flag("json"):
        return json_text([transaction_to_dict(tx) for tx in made])
    return "created %d transactions\n" % len(made)


def commands():
    return [
        Command(("rate", "set"), "record an exchange rate (1 FROM = RATE TO)", rate_set,
                args=[Arg("FROM"), Arg("TO"), Arg("RATE")], opts=[Opt("on", "DATE")]),
        Command(("rate", "list"), "list the exchange rates", rate_list, opts=[Opt("json")]),
        Command(("rate", "remove"), "remove the rate set on a day", rate_remove,
                args=[Arg("FROM"), Arg("TO")], opts=[Opt("on", "DATE")]),
        Command(("budget", "add"), "add a budget for the accounts a pattern selects", budget_add,
                args=[Arg("PATTERN"), Arg("AMOUNT")], opts=[Opt("per", "KIND"), Opt("start", "DATE")]),
        Command(("budget", "list"), "list the budgets", budget_list, opts=[Opt("json")]),
        Command(("budget", "remove"), "remove a budget", budget_remove, args=[Arg("PATTERN")],
                opts=[Opt("per", "KIND")]),
        Command(("budget", "status"), "compare spending with the budgets over a period", budget_status_cmd,
                opts=[Opt("period", "PERIOD"), Opt("json")]),
        Command(("recurring", "add"), "add a recurring transaction", recurring_add,
                args=[Arg("NAME"), Arg("SCHEDULE"), Arg("PAYEE")],
                opts=[Opt("start", "DATE"), Opt("end", "DATE"), Opt("count", "N")] + TEMPLATE_OPTS),
        Command(("recurring", "list"), "list the recurring transactions", recurring_list, opts=[Opt("json")]),
        Command(("recurring", "remove"), "remove a recurring transaction", recurring_remove, args=[Arg("NAME")]),
        Command(("recurring", "materialize"), "create the transactions that are due", recurring_materialize,
                opts=[Opt("upto", "DATE"), Opt("json")]),
    ]

"""`tallybook calc ...`: the library without a book. Money, dates, schedules, queries, journals, reports and CSV
imports worked out from the arguments and from plain files, so that they can be tried (and tested) without a
database. The book file and `--db` play no part; every output is fully determined by the arguments and files.
"""
import re
from datetime import date

from ..accounts import account_type, parent_path, path_matches, valid_path
from ..budgets import Budget, budget_status
from ..csvimport import import_csv as read_statement
from ..dates import Period, add_months, parse_date, periods
from ..errors import ParseError
from ..journal import Journal, format_journal, parse_journal
from ..model import Transaction
from ..money import Money
from ..currency import RateTable
from ..rules import parse_rules
from ..query import parse_query, select
from ..recurring import Recurring, occurrences, parse_schedule
from .args import Arg, Command, Opt, UsageError
from .common import (CliError, counts_text, label, optional_date, optional_number, read_text, tx_listing,
                     whole_number)
from .planning import budget_listing
from .reports import ALL_OPTS, KINDS, build_report, show

MAX_SPAN_DAYS = 40000       # the longest stretch `calc schedule` will list occurrences over
MAX_PERIODS = 5000          # the most periods `calc date periods` will list
RATE_DAY = date(2000, 1, 1)
WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
_RATIO = re.compile(r"(-?[0-9]{1,18})(?:/(-?[0-9]{1,18}))?")


# ---------------------------------------------------------------- money

def money_parse(ctx, args):
    money = Money.parse(args.args["MONEY"])
    return "%d %s\n" % (money.minor, money.currency)


def money_format(ctx, args):
    return "%s\n" % Money(whole_number(args.args["MINOR"], "minor units", -10 ** 18), args.args["CURRENCY"])


def money_add(ctx, args):
    return "%s\n" % (Money.parse(args.args["A"]) + Money.parse(args.args["B"]))


def money_sub(ctx, args):
    return "%s\n" % (Money.parse(args.args["A"]) - Money.parse(args.args["B"]))


def money_scale(ctx, args):
    money = Money.parse(args.args["MONEY"])
    m = _RATIO.fullmatch(args.args["RATIO"])
    if m is None:
        raise CliError("invalid ratio '%s': expected N or N/D, whole numbers" % args.args["RATIO"])
    return "%s\n" % money.scale(int(m.group(1)), int(m.group(2) or 1))


def money_allocate(ctx, args):
    money = Money.parse(args.args["MONEY"])
    weights = [whole_number(w, "weight") for w in args.args["WEIGHT"]]
    return "".join("%s\n" % part for part in money.allocate(weights))


def money_convert(ctx, args):
    money = Money.parse(args.args["MONEY"])
    rates = RateTable()
    rates.set(money.currency, args.args["TO"], args.args["RATE"], RATE_DAY)
    return "%s\n" % rates.convert(money, args.args["TO"], RATE_DAY)


# ---------------------------------------------------------------- dates and schedules

def date_parse(ctx, args):
    day = parse_date(args.args["DATE"])
    return "%s %s\n" % (day.isoformat(), WEEKDAYS[day.weekday()])


def date_add_months(ctx, args):
    day = parse_date(args.args["DATE"])
    return "%s\n" % add_months(day, whole_number(args.args["N"], "number of months", -10 ** 18)).isoformat()


def date_period(ctx, args):
    period = Period.parse(args.args["PERIOD"])
    return ("start: %s\nend: %s\ndays: %d\nlabel: %s\nnext: %s\n"
            % (period.start.isoformat(), period.end.isoformat(), period.days, period.label, period.next().label))


def date_periods(ctx, args):
    found = periods(parse_date(args.args["START"]), parse_date(args.args["END"]), args.args["STEP"])
    if len(found) > MAX_PERIODS:
        raise CliError("too many periods (%d): at most %d are listed" % (len(found), MAX_PERIODS))
    return "".join(p.label + "\n" for p in found)


def schedule(ctx, args):
    parsed = parse_schedule(args.args["SCHEDULE"])
    first, last = parse_date(args.opt("from")), parse_date(args.opt("to"))
    start = optional_date(args.opt("start"), first)
    if (last - min(first, start)).days > MAX_SPAN_DAYS:
        raise CliError("the range is too long: at most %d days from the first date to --to" % MAX_SPAN_DAYS)
    series = Recurring("calc", parsed, Transaction(date=first, payee="calc"), start,
                       end=optional_date(args.opt("end")), count=optional_number(args.opt("count"), "count", 1))
    return "".join(d.isoformat() + "\n" for d in occurrences(series, first, last))


# ---------------------------------------------------------------- journals, queries, reports, statements

def load_journal(path):
    text = read_text(path, "journal")
    try:
        return parse_journal(text)
    except ParseError as exc:
        raise CliError("%s: %s" % (label(path), exc))


def journal_check(ctx, args):
    journal = load_journal(args.args["FILE"])
    journal.to_ledger()
    return "ok: %s\n" % counts_text(journal)


def journal_format(ctx, args):
    return format_journal(load_journal(args.args["FILE"]))


def query(ctx, args):
    ledger = load_journal(args.opt("journal")).to_ledger()
    found = select(ledger.transactions(), parse_query(args.args["QUERY"], ledger.chart))
    return tx_listing(found, args.flag("json"))


def report(ctx, args):
    kind, account = args.args["KIND"], args.args["ACCOUNT"]
    if kind not in KINDS:
        raise UsageError("unknown report '%s': expected %s" % (kind, ", ".join(KINDS)))
    if kind == "register" and account is None:
        raise UsageError("report register needs an ACCOUNT")
    ledger = load_journal(args.opt("journal")).to_ledger()
    return show(build_report(ledger, kind, account, args, ctx.today()), args.flag("json"))


def rate(ctx, args):
    ledger = load_journal(args.opt("journal")).to_ledger()
    found = ledger.rates.rate(args.args["FROM"], args.args["TO"], parse_date(args.opt("on")))
    return "%d/%d\n" % (found.numerator, found.denominator)


def budget(ctx, args):
    ledger = load_journal(args.opt("journal")).to_ledger()
    period = Period.parse(args.opt("period"))
    spec = Budget(args.args["PATTERN"], args.opt("per", "month"), Money.parse(args.args["AMOUNT"]),
                  optional_date(args.opt("start"), period.start))
    return budget_listing(budget_status([spec], ledger, period), args.flag("json"))


def rules(ctx, args):
    ruleset = parse_rules(read_text(args.args["FILE"], "rules"))
    fields = {}
    if args.opt("payee") is not None:
        fields["payee"] = args.opt("payee")
    if args.opt("narration") is not None:
        fields["narration"] = args.opt("narration")
    if args.opt("amount") is not None:
        fields["amount"] = Money.parse(args.opt("amount"))
    if args.opt("date") is not None:
        fields["date"] = parse_date(args.opt("date"))
    rule = ruleset.match(fields)
    if rule is None:
        return "no match\n"
    actions = rule.actions
    lines = ["rule: %d" % rule.line]
    for key in ("account", "payee", "narration", "flag"):
        if key in actions:
            lines.append("%s: %s" % (key, actions[key]))
    if "tags" in actions:
        lines.append("tags: %s" % ",".join(actions["tags"]))
    return "".join(line.rstrip() + "\n" for line in lines)


def account_check(ctx, args):
    path = args.args["PATH"]
    if not valid_path(path):
        raise CliError("invalid account path '%s'" % path)
    return "path: %s\ntype: %s\nparent: %s\n" % (path, account_type(path), parent_path(path) or "none")


def account_match(ctx, args):
    return "%s\n" % ("yes" if path_matches(args.args["PATTERN"], args.args["PATH"]) else "no")


def csv_import(ctx, args):
    profile = read_text(args.args["PROFILE"], "profile")
    statement = read_text(args.args["CSV"], "statement")
    rules_path = args.opt("rules")
    result = read_statement(statement, profile, read_text(rules_path, "rules") if rules_path is not None else None)
    if result.errors:
        detail = "\n".join("row %d: %s" % (row, message) for row, message in result.errors)
        raise CliError("%d rows could not be read\n%s" % (len(result.errors), detail))
    return format_journal(Journal(transactions=result.transactions))


def commands():
    def calc(*words):
        return ("calc",) + words

    return [
        Command(calc("money", "parse"), "read 'AMOUNT CUR' and print its minor units", money_parse, args=[Arg("MONEY")]),
        Command(calc("money", "format"), "write minor units as an amount", money_format,
                args=[Arg("MINOR"), Arg("CURRENCY")]),
        Command(calc("money", "add"), "add two amounts", money_add, args=[Arg("A"), Arg("B")]),
        Command(calc("money", "sub"), "subtract two amounts", money_sub, args=[Arg("A"), Arg("B")]),
        Command(calc("money", "scale"), "multiply an amount by a ratio N or N/D", money_scale,
                args=[Arg("MONEY"), Arg("RATIO")]),
        Command(calc("money", "allocate"), "split an amount by weights, largest remainder", money_allocate,
                args=[Arg("MONEY"), Arg("WEIGHT", "some")]),
        Command(calc("money", "convert"), "convert an amount at one rate", money_convert,
                args=[Arg("MONEY"), Arg("TO"), Arg("RATE")]),
        Command(calc("date", "parse"), "check a date and name its weekday", date_parse, args=[Arg("DATE")]),
        Command(calc("date", "add-months"), "move a date by months", date_add_months, args=[Arg("DATE"), Arg("N")]),
        Command(calc("date", "period"), "describe a month, quarter, year or range", date_period,
                args=[Arg("PERIOD")]),
        Command(calc("date", "periods"), "list whole periods covering two dates", date_periods,
                args=[Arg("START"), Arg("END"), Arg("STEP")]),
        Command(calc("schedule"), "list the dates a recurring schedule produces", schedule, args=[Arg("SCHEDULE")],
                opts=[Opt("from", "DATE", required=True), Opt("to", "DATE", required=True), Opt("start", "DATE"),
                      Opt("end", "DATE"), Opt("count", "N")]),
        Command(calc("query"), "list the transactions of a journal file matching a query", query,
                args=[Arg("QUERY")], opts=[Opt("journal", "FILE", required=True), Opt("json")]),
        Command(calc("journal", "check"), "read a journal file and check its book-keeping", journal_check,
                args=[Arg("FILE")]),
        Command(calc("journal", "format"), "write a journal file in canonical form", journal_format,
                args=[Arg("FILE")]),
        Command(calc("report"), "run a report over a journal file", report, args=[Arg("KIND"), Arg("ACCOUNT", "opt")],
                opts=[Opt("journal", "FILE", required=True), ALL_OPTS["as-of"], ALL_OPTS["period"],
                      ALL_OPTS["convert"], ALL_OPTS["rollup"], Opt("json")]),
        Command(calc("rate"), "look up the rate between two currencies in a journal file", rate,
                args=[Arg("FROM"), Arg("TO")], opts=[Opt("journal", "FILE", required=True),
                                                      Opt("on", "DATE", required=True)]),
        Command(calc("budget"), "measure one budget against a journal file over a period", budget,
                args=[Arg("PATTERN"), Arg("AMOUNT")],
                opts=[Opt("journal", "FILE", required=True), Opt("period", "PERIOD", required=True),
                      Opt("per", "KIND"), Opt("start", "DATE"), Opt("json")]),
        Command(calc("rules"), "show which rule of a rules file wins for a payee, narration, amount and date", rules,
                args=[Arg("FILE")], opts=[Opt("payee", "TEXT"), Opt("narration", "TEXT"), Opt("amount", "MONEY"),
                                          Opt("date", "DATE")]),
        Command(calc("account", "check"), "check an account path and name its type and parent", account_check,
                args=[Arg("PATH")]),
        Command(calc("account", "match"), "say whether an account pattern matches a path", account_match,
                args=[Arg("PATTERN"), Arg("PATH")]),
        Command(calc("csv"), "show what importing a statement would produce, as journal text", csv_import,
                args=[Arg("PROFILE"), Arg("CSV")], opts=[Opt("rules", "FILE")]),
    ]

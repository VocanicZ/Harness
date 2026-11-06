"""Reports: trial balance, balance sheet, income statement, cash flow and account register. Each report is a
plain JSON-able dict (money as {"amount", "currency"}, dates as YYYY-MM-DD text) and `render_text` draws any of
them as fixed-width text."""
from itertools import groupby

from .currency import RateTable, currency as _currency
from .errors import ValidationError
from .dates import periods
from .export import money_to_dict, render_table, to_csv
from .money import Money, round_div

_TYPES = {"Assets": "asset", "Liabilities": "liability", "Equity": "equity", "Income": "income", "Expenses": "expense"}


class ReportError(ValidationError):
    """A report that cannot be built or drawn: an unknown account, a missing rate date, an unknown report."""


# ---------------------------------------------------------------- shared helpers

def account_type(path):
    return _TYPES.get(path.split(":")[0])


def _iso(d):
    return None if d is None else d.isoformat()


def _entries(ledger):
    """Every posting that has an amount as (tx, posting), in (date, id, posting order) order."""
    items = []
    for n, (tx, posting) in enumerate(ledger.postings()):
        if posting.amount is not None:
            items.append(((tx.date, tx.id if tx.id is not None else 0, n), tx, posting))
    items.sort(key=lambda item: item[0])
    return [(tx, posting) for _, tx, posting in items]


def _sums(entries, start=None, end=None):
    """{(account, currency): minor} over postings dated within start..end (None = unbounded)."""
    sums = {}
    for tx, p in entries:
        if (start is not None and tx.date < start) or (end is not None and tx.date > end):
            continue
        key = (p.account, p.amount.currency)
        sums[key] = sums.get(key, 0) + p.amount.minor
    return sums


def _money_list(totals):
    """[{"amount", "currency"}] sorted by currency from {currency: minor}."""
    return [money_to_dict(Money(totals[c], c)) for c in sorted(totals)]


def _add(totals, currency, minor):
    totals[currency] = totals.get(currency, 0) + minor


def _converter(ledger, convert_to, on, what):
    """None when no conversion is asked for, else f(minor, currency) -> minor in `convert_to`."""
    if convert_to is None:
        return None
    _currency(convert_to)
    if on is None:
        raise ReportError("%s cannot convert to %s without a date" % (what, convert_to))
    rates = getattr(ledger, "rates", None)
    if rates is None:
        rates = RateTable()

    def convert(minor, code):
        if code == convert_to:
            return minor
        return rates.convert(Money(minor, code), convert_to, on).minor
    return convert


def _tenths(part, whole):
    """part / whole as a percentage in tenths of a percent, rounded with round_div."""
    if whole == 0:
        return 0
    if whole < 0:
        part, whole = -part, -whole
    return round_div(part * 1000, whole)


def _percent_text(tenths):
    sign = "-" if tenths < 0 else ""
    whole, frac = divmod(abs(tenths), 10)
    return "%s%d.%d" % (sign, whole, frac)


# ---------------------------------------------------------------- trial balance

def trial_balance(ledger, as_of):
    """Every account with a non-zero balance on `as_of` (None: all postings), debit or credit side."""
    sums = _sums(_entries(ledger), end=as_of)
    rows, totals = [], {}
    for (account, cur), minor in sorted(sums.items()):
        if minor == 0:
            continue
        side = "debit" if minor > 0 else "credit"
        money = money_to_dict(Money(abs(minor), cur))
        rows.append({"account": account, "type": account_type(account),
                     "debit": money if side == "debit" else None,
                     "credit": money if side == "credit" else None})
        t = totals.setdefault(cur, {"debit": 0, "credit": 0})
        t[side] += abs(minor)
    return {
        "report": "trial_balance",
        "as_of": _iso(as_of),
        "accounts": rows,
        "totals": [{"currency": c,
                    "debit": money_to_dict(Money(totals[c]["debit"], c)),
                    "credit": money_to_dict(Money(totals[c]["credit"], c)),
                    "balanced": totals[c]["debit"] == totals[c]["credit"]} for c in sorted(totals)],
    }


# ---------------------------------------------------------------- balance sheet

def _section(sums, kind, sign, convert, convert_to):
    """Lines and per-currency totals for the accounts of one type; sign flips credit-side accounts positive."""
    lines, totals = [], {}
    for (account, cur), minor in sorted(sums.items()):
        if minor == 0 or account_type(account) != kind:
            continue
        amount = sign * minor
        line = {"account": account}
        if convert is None:
            line["balance"] = money_to_dict(Money(amount, cur))
            _add(totals, cur, amount)
        else:
            converted = convert(amount, cur)
            line["balance"] = money_to_dict(Money(converted, convert_to))
            line["original"] = money_to_dict(Money(amount, cur))
            _add(totals, convert_to, converted)
        lines.append(line)
    return lines, totals


def balance_sheet(ledger, as_of, convert_to=None, today=None):
    """Assets, liabilities and equity on `as_of` (None: all postings). Equity includes `retained_earnings`, the
    income less the expenses of everything up to `as_of`, so the sheet balances. `today` has no effect."""
    convert = _converter(ledger, convert_to, as_of, "a balance sheet")
    sums = _sums(_entries(ledger), end=as_of)
    assets, asset_totals = _section(sums, "asset", 1, convert, convert_to)
    liabilities, liability_totals = _section(sums, "liability", -1, convert, convert_to)
    equity, equity_totals = _section(sums, "equity", -1, convert, convert_to)

    earned = {}
    for (account, cur), minor in sums.items():
        if account_type(account) in ("income", "expense"):
            _add(earned, cur, -minor)
    retained = {c: v for c, v in earned.items() if v != 0}
    if convert is not None and retained:
        retained = {convert_to: sum(convert(v, c) for c, v in retained.items())}
    for cur, v in retained.items():
        _add(equity_totals, cur, v)

    if convert is not None:
        for totals in (asset_totals, liability_totals, equity_totals):
            totals.setdefault(convert_to, 0)
    balanced = all(asset_totals.get(c, 0) == liability_totals.get(c, 0) + equity_totals.get(c, 0)
                   for c in set(asset_totals) | set(liability_totals) | set(equity_totals))
    return {
        "report": "balance_sheet",
        "as_of": _iso(as_of),
        "currency": convert_to,
        "assets": {"accounts": assets, "total": _money_list(asset_totals)},
        "liabilities": {"accounts": liabilities, "total": _money_list(liability_totals)},
        "equity": {"accounts": equity, "retained_earnings": _money_list(retained), "total": _money_list(equity_totals)},
        "balanced": balanced,
    }


# ---------------------------------------------------------------- income statement

def _statement_section(sums, kind, sign, convert, convert_to):
    rows, totals = [], {}
    for (account, cur), minor in sorted(sums.items()):
        if minor == 0 or account_type(account) != kind:
            continue
        amount = sign * minor
        if convert is None:
            rows.append((account, cur, amount, None))
            _add(totals, cur, amount)
        else:
            converted = convert(amount, cur)
            rows.append((account, convert_to, converted, Money(amount, cur)))
            _add(totals, convert_to, converted)
    lines = []
    for account, cur, amount, original in rows:
        line = {"account": account, "amount": money_to_dict(Money(amount, cur)),
                "percent": _percent_text(_tenths(amount, totals[cur]))}
        if original is not None:
            line["original"] = money_to_dict(original)
        lines.append(line)
    return lines, totals


def income_statement(ledger, period, convert_to=None):
    """Income and expenses of `period`. Each line carries its share of its section total (same currency) as
    `percent`, text with one decimal. `net` is income less expenses per currency."""
    convert = _converter(ledger, convert_to, period.end, "an income statement")
    sums = _sums(_entries(ledger), period.start, period.end)
    income, income_totals = _statement_section(sums, "income", -1, convert, convert_to)
    expenses, expense_totals = _statement_section(sums, "expense", 1, convert, convert_to)
    if convert is not None:
        income_totals.setdefault(convert_to, 0)
        expense_totals.setdefault(convert_to, 0)
    net = {c: income_totals.get(c, 0) - expense_totals.get(c, 0) for c in set(income_totals) | set(expense_totals)}
    return {
        "report": "income_statement",
        "start": period.start.isoformat(),
        "end": period.end.isoformat(),
        "currency": convert_to,
        "income": {"accounts": income, "total": _money_list(income_totals)},
        "expenses": {"accounts": expenses, "total": _money_list(expense_totals)},
        "net": _money_list(net),
    }


# ---------------------------------------------------------------- cash flow

def cashflow(ledger, period):
    """Money in and out of the asset accounts during `period`, by the account on the other side of each
    transaction. Transfers between asset accounts cancel out."""
    entries = _entries(ledger)
    asset_entries = [(tx, p) for tx, p in entries if account_type(p.account) == "asset"]
    currencies = sorted({p.amount.currency for tx, p in asset_entries if tx.date <= period.end})
    opening = {c: 0 for c in currencies}
    net = {c: 0 for c in currencies}
    for tx, p in asset_entries:
        if tx.date < period.start:
            opening[p.amount.currency] += p.amount.minor
        elif tx.date <= period.end:
            net[p.amount.currency] += p.amount.minor

    flows = {}
    in_period = [(tx, p) for tx, p in entries if period.contains(tx.date)]
    for _, group in groupby(in_period, key=lambda e: id(e[0])):
        postings = [p for _, p in group]
        moved = {}
        for p in postings:
            if account_type(p.account) == "asset":
                _add(moved, p.amount.currency, p.amount.minor)
        for p in postings:
            cur = p.amount.currency
            if account_type(p.account) != "asset" and moved.get(cur, 0) != 0:
                key = (p.account, cur)
                flows[key] = flows.get(key, 0) - p.amount.minor

    inflows, outflows, total_in, total_out = [], [], {c: 0 for c in currencies}, {c: 0 for c in currencies}
    for (account, cur), minor in sorted(flows.items()):
        if minor > 0:
            inflows.append({"account": account, "amount": money_to_dict(Money(minor, cur))})
            _add(total_in, cur, minor)
        elif minor < 0:
            outflows.append({"account": account, "amount": money_to_dict(Money(-minor, cur))})
            _add(total_out, cur, -minor)
    closing = {c: opening[c] + net[c] for c in currencies}
    return {
        "report": "cashflow",
        "start": period.start.isoformat(),
        "end": period.end.isoformat(),
        "opening": _money_list(opening),
        "inflows": inflows,
        "outflows": outflows,
        "total_in": _money_list(total_in),
        "total_out": _money_list(total_out),
        "net": _money_list(net),
        "closing": _money_list(closing),
    }


# ---------------------------------------------------------------- register

def register(ledger, account, period=None, rollup=False):
    """The postings of one account (with rollup=True also of everything below it), each with the running balance
    of its currency; `opening` is the balance before the period and `closing` the one after its last row."""
    if not ledger.chart.exists(account):
        raise ReportError("unknown account '%s'" % (account,))

    def selected(path):
        return path == account or (rollup and path.startswith(account + ":"))

    start = period.start if period is not None else None
    end = period.end if period is not None else None
    chosen = [(tx, p) for tx, p in _entries(ledger) if selected(p.account) and (end is None or tx.date <= end)]
    running = {}
    for tx, p in chosen:
        running.setdefault(p.amount.currency, 0)
        if start is not None and tx.date < start:
            running[p.amount.currency] += p.amount.minor
    opening = dict(running)
    rows = []
    for tx, p in chosen:
        if start is not None and tx.date < start:
            continue
        cur = p.amount.currency
        running[cur] += p.amount.minor
        rows.append({
            "date": tx.date.isoformat(),
            "id": tx.id,
            "payee": tx.payee,
            "narration": tx.narration,
            "account": p.account,
            "amount": money_to_dict(p.amount),
            "balance": money_to_dict(Money(running[cur], cur)),
        })
    return {
        "report": "register",
        "account": account,
        "rollup": bool(rollup),
        "start": _iso(start),
        "end": _iso(end),
        "opening": _money_list(opening),
        "rows": rows,
        "closing": _money_list(running),
    }


# ---------------------------------------------------------------- net worth

NET_WORTH_STEPS = ("week", "month", "quarter", "year")


def net_worth(ledger, period, step="month"):
    """Assets, liabilities and their difference at the end of each whole calendar week, month, quarter or year
    that is touched by `period` (the first and last are not trimmed to the period)."""
    if step not in NET_WORTH_STEPS:
        raise ReportError("unknown step '%s': expected week, month, quarter or year" % (step,))
    entries = _entries(ledger)
    points = []
    for span in periods(period.start, period.end, step):
        sums = _sums(entries, end=span.end)
        assets, liabilities = {}, {}
        for (account, cur), minor in sums.items():
            kind = account_type(account)
            if kind == "asset":
                _add(assets, cur, minor)
                _add(liabilities, cur, 0)
            elif kind == "liability":
                _add(liabilities, cur, -minor)
                _add(assets, cur, 0)
        net = {c: assets[c] - liabilities[c] for c in assets}
        points.append({"date": span.end.isoformat(), "assets": _money_list(assets),
                       "liabilities": _money_list(liabilities), "net": _money_list(net)})
    return {"report": "net_worth", "start": period.start.isoformat(), "end": period.end.isoformat(),
            "step": step, "points": points}


# ---------------------------------------------------------------- CSV

def _amount(money):
    return "" if money is None else money["amount"]


def _currency_of(money):
    return "" if money is None else money["currency"]


def _csv_trial_balance(r):
    rows = [[a["account"], a["type"], _currency_of(a["debit"] or a["credit"]), _amount(a["debit"]), _amount(a["credit"])]
            for a in r["accounts"]]
    return ["account", "type", "currency", "debit", "credit"], rows


def _csv_balance_sheet(r):
    rows = []
    for name in ("assets", "liabilities", "equity"):
        rows += [[name, a["account"], a["balance"]["currency"], a["balance"]["amount"]] for a in r[name]["accounts"]]
    rows += [["equity", "Retained earnings", m["currency"], m["amount"]] for m in r["equity"]["retained_earnings"]]
    return ["section", "account", "currency", "balance"], rows


def _csv_income_statement(r):
    rows = []
    for name in ("income", "expenses"):
        rows += [[name, a["account"], a["amount"]["currency"], a["amount"]["amount"], a["percent"]]
                 for a in r[name]["accounts"]]
    return ["section", "account", "currency", "amount", "percent"], rows


def _csv_cashflow(r):
    rows = [["opening", "", m["currency"], m["amount"]] for m in r["opening"]]
    rows += [["in", a["account"], a["amount"]["currency"], a["amount"]["amount"]] for a in r["inflows"]]
    rows += [["out", a["account"], a["amount"]["currency"], a["amount"]["amount"]] for a in r["outflows"]]
    rows += [["closing", "", m["currency"], m["amount"]] for m in r["closing"]]
    return ["section", "account", "currency", "amount"], rows


def _csv_register(r):
    rows = [[x["date"], "" if x["id"] is None else x["id"], x["payee"], x["narration"], x["account"],
             x["amount"]["currency"], x["amount"]["amount"], x["balance"]["amount"]] for x in r["rows"]]
    return ["date", "id", "payee", "narration", "account", "currency", "amount", "balance"], rows


def _csv_net_worth(r):
    rows = []
    for point in r["points"]:
        for assets, liabilities, net in zip(point["assets"], point["liabilities"], point["net"]):
            rows.append([point["date"], assets["currency"], assets["amount"], liabilities["amount"], net["amount"]])
    return ["date", "currency", "assets", "liabilities", "net"], rows


def report_to_csv(report):
    """The table part of a report as CSV (export.to_csv rules): headers per report, one record per line item, no
    totals. Money cells are the amount text with the currency in its own column."""
    kind = report.get("report") if isinstance(report, dict) else None
    builder = _CSV.get(kind)
    if builder is None:
        raise ReportError("cannot export %r as CSV: not a report" % (kind,))
    headers, rows = builder(report)
    return to_csv(headers, rows)


# ---------------------------------------------------------------- text

def _m(money):
    return "%s %s" % (money["amount"], money["currency"])


def _title(text, currency):
    return text + (" (in %s)" % currency if currency else "")


def _span(report):
    return "%s to %s" % (report["start"], report["end"])


def _text_trial_balance(r):
    rows = [[a["account"], a["type"], _m(a["debit"]) if a["debit"] else "", _m(a["credit"]) if a["credit"] else ""]
            for a in r["accounts"]]
    rows += [["Total", "", _m(t["debit"]), _m(t["credit"])] for t in r["totals"]]
    title = "Trial balance" + (" as of %s" % r["as_of"] if r["as_of"] else "")
    return title + "\n\n" + render_table(["Account", "Type", "Debit", "Credit"], rows, "llrr")


def _blocks(blocks, width=2):
    """Rows of the given blocks one after the other, an empty row between two blocks that have rows."""
    rows = []
    for block in blocks:
        if block and rows:
            rows.append([""] * width)
        rows += [list(r) for r in block]
    return rows


def _text_balance_sheet(r):
    def block(name, section, extra=()):
        rows = [[name, ""]]
        rows += [["  " + a["account"], _m(a["balance"])] for a in section["accounts"]]
        rows += [["  Retained earnings", _m(m)] for m in extra]
        rows += [["Total " + name.lower(), _m(m)] for m in section["total"]]
        return rows
    rows = _blocks([block("Assets", r["assets"]), block("Liabilities", r["liabilities"]),
                    block("Equity", r["equity"], r["equity"]["retained_earnings"])])
    title = _title("Balance sheet" + (" as of %s" % r["as_of"] if r["as_of"] else ""), r["currency"])
    return title + "\n\n" + render_table(["Account", "Balance"], rows, "lr")


def _text_income_statement(r):
    def block(name, section, total_label):
        rows = [[name, "", ""]]
        rows += [["  " + a["account"], _m(a["amount"]), a["percent"] + "%"] for a in section["accounts"]]
        rows += [[total_label, _m(m), ""] for m in section["total"]]
        return rows
    rows = _blocks([block("Income", r["income"], "Total income"), block("Expenses", r["expenses"], "Total expenses"),
                    [["Net income", _m(m), ""] for m in r["net"]]], 3)
    title = _title("Income statement " + _span(r), r["currency"])
    return title + "\n\n" + render_table(["Account", "Amount", "Percent"], rows, "lrr")


def _text_cashflow(r):
    rows = _blocks([
        [["Opening balance", _m(m)] for m in r["opening"]],
        [["Money in", ""]] + [["  " + a["account"], _m(a["amount"])] for a in r["inflows"]]
        + [["Total money in", _m(m)] for m in r["total_in"]],
        [["Money out", ""]] + [["  " + a["account"], _m(a["amount"])] for a in r["outflows"]]
        + [["Total money out", _m(m)] for m in r["total_out"]],
        [["Net change", _m(m)] for m in r["net"]] + [["Closing balance", _m(m)] for m in r["closing"]],
    ])
    return "Cash flow " + _span(r) + "\n\n" + render_table(["Account", "Amount"], rows, "lr")


def _text_register(r):
    title = "Register " + r["account"] + (" (with sub-accounts)" if r["rollup"] else "")
    if r["start"] is not None:
        title += " " + _span(r)
    rows = [["", "", "Opening balance", "", "", _m(m)] for m in r["opening"]]
    rows += [[x["date"], "" if x["id"] is None else x["id"], x["payee"], x["account"], _m(x["amount"]), _m(x["balance"])]
             for x in r["rows"]]
    rows += [["", "", "Closing balance", "", "", _m(m)] for m in r["closing"]]
    return title + "\n\n" + render_table(["Date", "Id", "Payee", "Account", "Amount", "Balance"], rows, "llllrr")


def _text_net_worth(r):
    rows = []
    for point in r["points"]:
        if not point["net"]:
            rows.append([point["date"], "", "", ""])
        for assets, liabilities, net in zip(point["assets"], point["liabilities"], point["net"]):
            rows.append([point["date"], _m(assets), _m(liabilities), _m(net)])
    title = "Net worth %s (by %s)" % (_span(r), r["step"])
    return title + "\n\n" + render_table(["Date", "Assets", "Liabilities", "Net"], rows, "lrrr")


_RENDERERS = {
    "net_worth": _text_net_worth,
    "trial_balance": _text_trial_balance,
    "balance_sheet": _text_balance_sheet,
    "income_statement": _text_income_statement,
    "cashflow": _text_cashflow,
    "register": _text_register,
}


def render_text(report):
    """Fixed-width text for any report dict this module builds."""
    kind = report.get("report") if isinstance(report, dict) else None
    if kind not in _RENDERERS:
        raise ReportError("cannot render %r: not a report" % (kind,))
    return _RENDERERS[kind](report)


_CSV = {
    "trial_balance": _csv_trial_balance,
    "balance_sheet": _csv_balance_sheet,
    "income_statement": _csv_income_statement,
    "cashflow": _csv_cashflow,
    "register": _csv_register,
    "net_worth": _csv_net_worth,
}

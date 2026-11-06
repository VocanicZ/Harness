"""The resources of the API: one function per path and verb, each taking the request and an open Store and
returning a Reply. Input is checked here (shapes, types, the text of dates and amounts); the rules of the book are
the library's, and the errors it raises are turned into answers by the router."""
import re
from dataclasses import dataclass

from .. import __version__, reports
from ..budgets import Budget, budget_status as _budget_status
from ..dates import Period, parse_date
from ..errors import NotFoundError, ValidationError
from ..export import money_to_dict, posting_to_dict, transaction_to_dict, transactions_to_csv
from ..journal import format_journal
from ..model import Posting, Transaction
from ..money import Money
from ..recurring import Recurring

MAX_NUMBER = 2 ** 63 - 1
_WHOLE = re.compile(r"[0-9]+")
_TRUE = ("true", "yes", "1")
_FALSE = ("false", "no", "0")
TEXT = "text/plain; charset=utf-8"
CSV = "text/csv; charset=utf-8"


@dataclass
class Reply:
    """An answer: `data` is sent as JSON, or `text` as it is with its content type."""
    status: int = 200
    data: object = None
    text: str = None
    content_type: str = None


# ---------------------------------------------------------------- reading what was sent

def _need(req, name):
    value = req.params.get(name)
    if value is None:
        raise ValidationError("the parameter %s is required" % name)
    return value


def _flag(req, name, default):
    text = req.params.get(name)
    if text is None:
        return default
    if text.lower() in _TRUE:
        return True
    if text.lower() in _FALSE:
        return False
    raise ValidationError("the parameter %s must be true or false, got '%s'" % (name, text))


def _whole(text, name):
    if not _WHOLE.fullmatch(text) or int(text) > MAX_NUMBER:
        raise ValidationError("%s must be a whole number of at least 0, got '%s'" % (name, text))
    return int(text)


def _date(value, name):
    if not isinstance(value, str):
        raise ValidationError("%s must be a date written YYYY-MM-DD" % name)
    return parse_date(value)


def _param_date(req, name, required=False):
    text = _need(req, name) if required else req.params.get(name)
    return None if text is None else parse_date(text)


def _fields(data, required, optional, what):
    """`data` must be a JSON object holding every required name and no name beyond the optional ones."""
    if not isinstance(data, dict):
        raise ValidationError("%s must be a JSON object" % what)
    unknown = sorted(set(data) - set(required) - set(optional))
    if unknown:
        raise ValidationError("unknown field%s in %s: %s" % ("s" if len(unknown) > 1 else "", what, ", ".join(unknown)))
    for name in required:
        if name not in data:
            raise ValidationError("%s is required in %s" % (name, what))
    return data


def _body(req, required=(), optional=()):
    """The JSON object sent (an empty body is an empty object), checked by `_fields`."""
    return _fields({} if req.json is None else req.json, required, optional, "the body")


def _text(data, name, default=None):
    """A text field; a missing or null optional one is `default`."""
    value = data.get(name)
    if value is None and default is not None:
        return default
    if not isinstance(value, str):
        raise ValidationError("%s must be text" % name)
    return value


def _maybe_text(data, name):
    return None if data.get(name) is None else _text(data, name)


def _maybe_date(data, name):
    return None if data.get(name) is None else _date(data[name], name)


def _money(value, name):
    """Money as the object {"amount": "12.50", "currency": "USD"} or as the text "12.50 USD"."""
    if isinstance(value, str):
        return Money.parse(value)
    if isinstance(value, dict) and set(value) == {"amount", "currency"} and \
            isinstance(value["amount"], str) and isinstance(value["currency"], str):
        return Money.of(value["amount"], value["currency"])
    raise ValidationError('%s must be an amount such as "12.50 USD" or {"amount": "12.50", "currency": "USD"}' % name)


def _posting(value, number):
    value = _fields(value, ("account",), ("amount", "note"), "posting %d" % number)
    amount = value.get("amount")
    return Posting(_text(value, "account"), None if amount is None else _money(amount, "the amount of posting %d" % number),
                   _text(value, "note", ""))


def _transaction(data, day):
    """A Transaction from the JSON fields payee, narration, flag, tags and postings (and `day`)."""
    tags = data.get("tags")
    if tags is None:
        tags = []
    if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
        raise ValidationError("tags must be a list of text")
    postings = data["postings"]
    if not isinstance(postings, list):
        raise ValidationError("postings must be a list")
    return Transaction(date=day, payee=_text(data, "payee"), narration=_text(data, "narration", ""),
                       postings=[_posting(p, n) for n, p in enumerate(postings, 1)], tags=tuple(tags),
                       flag=_text(data, "flag", "*"))


# ---------------------------------------------------------------- the JSON shapes

def account_json(a):
    return {"path": a.path, "type": a.type, "currency": a.currency, "opened": _iso(a.opened),
            "closed": _iso(a.closed), "note": a.note}


def _iso(day):
    return None if day is None else day.isoformat()


def rate_json(row):
    src, dst, on, text = row
    return {"src": src, "dst": dst, "date": on.isoformat(), "rate": text}


def budget_json(b):
    return {"pattern": b.pattern, "period_kind": b.period_kind, "amount": money_to_dict(b.amount),
            "start": b.start.isoformat()}


def recurring_json(r):
    t = r.template
    return {"name": r.name, "schedule": str(r.schedule), "start": r.start.isoformat(), "end": _iso(r.end),
            "count": r.count,
            "template": {"payee": t.payee, "narration": t.narration, "flag": t.flag, "tags": sorted(t.tags),
                         "postings": [posting_to_dict(p) for p in t.postings]}}


# ---------------------------------------------------------------- health, accounts

def health(req, store):
    return Reply(data={"status": "ok", "version": __version__, "schema_version": store.version})


def list_accounts(req, store):
    accounts = store.accounts(type=req.params.get("type"), under=req.params.get("under"),
                              currency=req.params.get("currency"), include_closed=_flag(req, "include_closed", True))
    return Reply(data=[account_json(a) for a in accounts])


def create_account(req, store):
    data = _body(req, ("path",), ("type", "currency", "opened", "note"))
    account = store.add_account(_text(data, "path"), type=_maybe_text(data, "type"),
                                currency=_maybe_text(data, "currency"), opened=_maybe_date(data, "opened"),
                                note=_text(data, "note", ""))
    return Reply(201, account_json(account))


def get_account(req, store):
    return Reply(data=account_json(store.get_account(req.args["path"])))


def close_account(req, store):
    data = _body(req, (), ("on",))
    on = _maybe_date(data, "on") or req.today
    return Reply(data=account_json(store.close_account(req.args["path"], on)))


# ---------------------------------------------------------------- transactions

def list_transactions(req, store):
    query = req.params.get("q")
    limit = req.params.get("limit")
    limit = None if limit is None else _whole(limit, "limit")
    offset = _whole(req.params.get("offset", "0"), "offset")
    items = store.transactions(query, limit=limit, offset=offset)
    return Reply(data={"items": [transaction_to_dict(t) for t in items], "total": store.count_transactions(query),
                       "limit": limit, "offset": offset})


def create_transaction(req, store):
    data = _body(req, ("date", "payee", "postings"), ("narration", "flag", "tags"))
    stored = store.add_transaction(_transaction(data, _date(data["date"], "date")))
    return Reply(201, transaction_to_dict(stored))


def _tx_id(text):
    if not _WHOLE.fullmatch(text) or int(text) > MAX_NUMBER:
        raise NotFoundError("no such transaction: %s" % text)
    return int(text)


def get_transaction(req, store):
    return Reply(data=transaction_to_dict(store.get_transaction(_tx_id(req.args["id"]))))


def delete_transaction(req, store):
    return Reply(data=transaction_to_dict(store.delete_transaction(_tx_id(req.args["id"]))))


# ---------------------------------------------------------------- rates

def list_rates(req, store):
    return Reply(data=[rate_json(row) for row in store.rate_rows()])


def put_rate(req, store):
    data = _body(req, ("src", "dst", "rate", "date"))
    src, dst, rate = _text(data, "src"), _text(data, "dst"), _text(data, "rate")
    store.set_rate(src, dst, rate, _date(data["date"], "date"))
    return Reply(data={"src": src, "dst": dst, "date": data["date"], "rate": rate})


def delete_rate(req, store):
    src, dst, on = _need(req, "src"), _need(req, "dst"), _param_date(req, "date", required=True)
    found = [row for row in store.rate_rows() if row[:3] == (src, dst, on)]
    store.remove_rate(src, dst, on)
    return Reply(data=rate_json(found[0]))


# ---------------------------------------------------------------- budgets

def list_budgets(req, store):
    return Reply(data=[budget_json(b) for b in store.budgets()])


def create_budget(req, store):
    data = _body(req, ("pattern", "period_kind", "amount", "start"))
    budget = Budget(data["pattern"], data["period_kind"], _money(data["amount"], "amount"), _date(data["start"], "start"))
    return Reply(201, budget_json(store.add_budget(budget)))


def delete_budget(req, store):
    pattern, kind = _need(req, "pattern"), _need(req, "period_kind")
    found = [b for b in store.budgets() if (b.pattern, b.period_kind) == (pattern, kind)]
    store.remove_budget(pattern, kind)
    return Reply(data=budget_json(found[0]))


def budget_status(req, store):
    period = Period.parse(_need(req, "period"))
    lines = _budget_status(store.budgets(), store.ledger(), period)
    return Reply(data=[line.to_dict() for line in lines])


# ---------------------------------------------------------------- recurring

def list_recurring(req, store):
    return Reply(data=[recurring_json(r) for r in store.recurring()])


def create_recurring(req, store):
    data = _body(req, ("name", "schedule", "start", "template"), ("end", "count"))
    start = _date(data["start"], "start")
    template = _fields(data["template"], ("payee", "postings"), ("narration", "flag", "tags"), "template")
    rec = Recurring(data["name"], data["schedule"], _transaction(template, start), start,
                    _maybe_date(data, "end"), data.get("count"))
    return Reply(201, recurring_json(store.add_recurring(rec)))


def delete_recurring(req, store):
    name = _need(req, "name")
    found = [r for r in store.recurring() if r.name == name]
    store.remove_recurring(name)
    return Reply(data=recurring_json(found[0]))


def materialize(req, store):
    data = _body(req, (), ("upto",))
    made = store.materialize(upto=_maybe_date(data, "upto"), today=req.today)
    return Reply(data={"added": [transaction_to_dict(t) for t in made]})


# ---------------------------------------------------------------- reports

def _format(req):
    name = req.params.get("format", "json")
    if name not in ("json", "text"):
        raise ValidationError("format must be json or text, got '%s'" % name)
    return name


def _answer(name, report):
    """The report as JSON, or drawn as text for `format=text`."""
    if name == "json":
        return Reply(data=report)
    return Reply(text=reports.render_text(report), content_type=TEXT)


def report_trial_balance(req, store):
    name = _format(req)
    return _answer(name, reports.trial_balance(store.ledger(), _param_date(req, "as_of")))


def report_balance_sheet(req, store):
    name = _format(req)
    report = reports.balance_sheet(store.ledger(), _param_date(req, "as_of"), req.params.get("convert_to"), req.today)
    return _answer(name, report)


def report_income_statement(req, store):
    name = _format(req)
    period = Period.parse(_need(req, "period"))
    return _answer(name, reports.income_statement(store.ledger(), period, req.params.get("convert_to")))


def report_cashflow(req, store):
    name = _format(req)
    return _answer(name, reports.cashflow(store.ledger(), Period.parse(_need(req, "period"))))


def report_register(req, store):
    name = _format(req)
    account = _need(req, "account")
    text = req.params.get("period")
    period = None if text is None else Period.parse(text)
    return _answer(name, reports.register(store.ledger(), account, period, _flag(req, "rollup", False)))


# ---------------------------------------------------------------- import, rules, export, lock

def import_csv(req, store):
    if req.media_type == "application/json":
        data = _body(req, ("csv", "profile"), ("apply_rules",))
        text, profile, apply_rules = _text(data, "csv"), _text(data, "profile"), data.get("apply_rules")
        if apply_rules is None:
            apply_rules = True
        if not isinstance(apply_rules, bool):
            raise ValidationError("apply_rules must be true or false")
    else:
        text, profile, apply_rules = req.text(), _need(req, "profile"), _flag(req, "apply_rules", True)
    outcome = store.import_csv(text, profile, apply_rules=apply_rules)
    if outcome.errors:
        raise ValidationError("import failed: " + "; ".join("row %d: %s" % (row, why) for row, why in outcome.errors))
    return Reply(data={"added": [transaction_to_dict(t) for t in outcome.added],
                       "duplicates": [transaction_to_dict(t) for t in outcome.duplicates]})


def get_rules(req, store):
    return Reply(data={"rules": store.rules_text()})


def put_rules(req, store):
    data = _body(req, ("rules",))
    store.set_rules(_text(data, "rules"))
    return Reply(data={"rules": store.rules_text()})


def export(req, store):
    name = req.params.get("format", "json")
    if name not in ("json", "csv", "journal"):
        raise ValidationError("format must be json, csv or journal, got '%s'" % name)
    if name == "journal":
        return Reply(text=format_journal(store.journal()), content_type=TEXT)
    txs = store.transactions()
    if name == "csv":
        return Reply(text=transactions_to_csv(txs), content_type=CSV)
    return Reply(data=[transaction_to_dict(t) for t in txs])


def get_lock(req, store):
    return Reply(data={"lock_date": _iso(store.lock_date())})


def put_lock(req, store):
    data = _body(req, ("lock_date",))
    store.set_lock(_maybe_date(data, "lock_date"))
    return Reply(data={"lock_date": _iso(store.lock_date())})

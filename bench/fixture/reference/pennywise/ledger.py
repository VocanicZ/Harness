import datetime
import re
from collections import namedtuple
from decimal import Decimal

Entry = namedtuple("Entry", "date category amount note")

_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_AMOUNT = re.compile(r"^[+-]?\d+(\.\d{1,2})?$")


class ParseError(ValueError):
    def __init__(self, line, problem):
        super().__init__("line %d: %s" % (line, problem))
        self.line = line
        self.problem = problem


def parse_date(text):
    if not _DATE.match(text):
        raise ValueError("bad date %r (want YYYY-MM-DD)" % text)
    try:
        return datetime.date(int(text[:4]), int(text[5:7]), int(text[8:]))
    except ValueError:
        raise ValueError("no such date %r" % text) from None


def parse_amount(text):
    if not _AMOUNT.match(text):
        raise ValueError("bad amount %r (want at most two decimals)" % text)
    return Decimal(text)


def make_entry(date, category, amount, note=""):
    """Validate the raw text fields of one entry and build it; ValueError on a mistake."""
    return Entry(parse_date(date), category.lower(), parse_amount(amount), note.strip())


def parse(text):
    entries = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split(None, 3)
        if len(fields) < 3:
            raise ParseError(number, "want DATE CATEGORY AMOUNT [NOTE]")
        try:
            entries.append(make_entry(*fields))
        except ValueError as exc:
            raise ParseError(number, str(exc)) from None
    return entries


def balance(entries):
    return sum((e.amount for e in entries), Decimal("0.00"))


def _totals(entries, key):
    totals = {}
    for e in entries:
        totals[key(e)] = totals.get(key(e), Decimal("0.00")) + e.amount
    return dict(sorted(totals.items()))


def by_category(entries):
    return _totals(entries, lambda e: e.category)


def by_month(entries):
    return _totals(entries, lambda e: e.date.strftime("%Y-%m"))


def filter_entries(entries, category=None, since=None, until=None):
    out = []
    for e in entries:
        if category is not None and e.category != category.lower():
            continue
        if since is not None and e.date < since:
            continue
        if until is not None and e.date > until:
            continue
        out.append(e)
    return out


def format_entry(e):
    line = "%s %s %.2f" % (e.date.isoformat(), e.category, e.amount)
    return line + " " + e.note if e.note else line

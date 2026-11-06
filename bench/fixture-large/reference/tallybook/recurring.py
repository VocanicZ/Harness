"""Recurring transactions: a schedule written in plain words, a template, and the dated copies it produces."""
import re
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Optional

from .dates import DateError, add_months, last_day, parse_date
from .errors import ValidationError
from .model import Transaction

RECURRING_TAG = "recurring"
WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
_UNITS = {"day": "days", "days": "days", "week": "weeks", "weeks": "weeks",
          "month": "months", "months": "months", "year": "years", "years": "years"}
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
_MM_DD = re.compile(r"([0-9]{2})-([0-9]{2})")
_NUMBER = re.compile(r"[0-9]+")
_FORMS = ("daily", "weekly on <mon..sun>", "monthly on <1..31|last>", "yearly on <MM-DD>",
          "every <N> <days|weeks|months|years> from <YYYY-MM-DD>")


class RecurringError(ValidationError):
    """A schedule that does not read, or a recurring item that cannot exist."""


@dataclass(frozen=True)
class Schedule:
    """kind is daily, weekly, monthly, yearly or every. Used fields: weekly `weekday` (0 = Monday); monthly `day`
    (1..31, or 0 for the last day); yearly `month` and `day`; every `step` (a count), `unit` and `anchor`."""
    kind: str
    weekday: Optional[int] = None
    day: Optional[int] = None
    month: Optional[int] = None
    step: Optional[int] = None
    unit: Optional[str] = None
    anchor: Optional[date] = None

    def __str__(self):
        if self.kind == "daily":
            return "daily"
        if self.kind == "weekly":
            return "weekly on %s" % WEEKDAYS[self.weekday]
        if self.kind == "monthly":
            return "monthly on %s" % ("last" if self.day == 0 else self.day)
        if self.kind == "yearly":
            return "yearly on %02d-%02d" % (self.month, self.day)
        unit = self.unit[:-1] if self.step == 1 else self.unit
        return "every %d %s from %s" % (self.step, unit, self.anchor.isoformat())

    # ---- generation

    def dates_from(self, first):
        """Every date of the schedule on or after `first`, in order, without end."""
        try:
            if self.kind == "daily":
                return _count_days(first, 1)
            if self.kind == "weekly":
                return _count_days(first + timedelta(days=(self.weekday - first.weekday()) % 7), 7)
            if self.kind == "monthly":
                return _monthly(self.day, first)
            if self.kind == "yearly":
                return _yearly(self.month, self.day, first)
            return _every(self, first)
        except OverflowError:
            return iter(())

    def between(self, start, end):
        """The schedule's own dates within start..end inclusive (no recurring limits applied)."""
        out = []
        for d in self.dates_from(start):
            if d > end:
                break
            out.append(d)
        return out


def _count_days(first, step):
    d = first
    while True:
        yield d
        try:
            d = d + timedelta(days=step)
        except OverflowError:
            return


def _month_days(year, month, day):
    last = last_day(year, month)
    return last if day == 0 else min(day, last)


def _monthly(day, first):
    year, month = first.year, first.month
    while year <= 9999:
        d = date(year, month, _month_days(year, month, day))
        if d >= first:
            yield d
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)


def _yearly(month, day, first):
    year = first.year
    while year <= 9999:
        d = date(year, month, min(day, last_day(year, month)))
        if d >= first:
            yield d
        year += 1


def _every(schedule, first):
    anchor, step = schedule.anchor, schedule.step
    if schedule.unit in ("days", "weeks"):
        stride = step * (7 if schedule.unit == "weeks" else 1)
        skip = max(0, (first - anchor).days // stride)
        d = anchor + timedelta(days=skip * stride)
        while True:
            if d >= first:
                yield d
            try:
                d = d + timedelta(days=stride)
            except OverflowError:
                return
    months = step * (12 if schedule.unit == "years" else 1)
    gap = (first.year - anchor.year) * 12 + first.month - anchor.month
    k = max(0, gap // months - 1)
    while True:
        try:
            d = add_months(anchor, k * months)
        except DateError:
            return
        if d >= first:
            yield d
        k += 1


# ---------------------------------------------------------------- parsing

def _whole(text, what, low, high):
    if not _NUMBER.fullmatch(text):
        raise RecurringError("invalid schedule: %s '%s' is not a number" % (what, text))
    n = int(text)
    if not low <= n <= high:
        raise RecurringError("invalid schedule: %s %d is outside %d to %d" % (what, n, low, high))
    return n


def parse_schedule(text):
    """Parse the words described in the brief. Case and extra blanks do not matter; anything else is a
    RecurringError whose message names the forms that are allowed."""
    if not isinstance(text, str):
        raise RecurringError("a schedule is text such as 'monthly on 5'")
    words = text.lower().split()
    bad = RecurringError("invalid schedule '%s': expected one of %s" % (text.strip(), "; ".join(_FORMS)))
    if not words:
        raise bad
    head = words[0]
    if head == "daily" and len(words) == 1:
        return Schedule("daily")
    if head == "weekly" and len(words) == 3 and words[1] == "on":
        if words[2] not in WEEKDAYS:
            raise RecurringError("invalid schedule: '%s' is not a weekday (mon, tue, wed, thu, fri, sat, sun)" % words[2])
        return Schedule("weekly", weekday=WEEKDAYS.index(words[2]))
    if head == "monthly" and len(words) == 3 and words[1] == "on":
        if words[2] == "last":
            return Schedule("monthly", day=0)
        return Schedule("monthly", day=_whole(words[2], "day of month", 1, 31))
    if head == "yearly" and len(words) == 3 and words[1] == "on":
        m = _MM_DD.fullmatch(words[2])
        if m is None:
            raise RecurringError("invalid schedule: '%s' is not MM-DD" % words[2])
        month, day = int(m.group(1)), int(m.group(2))
        if not 1 <= month <= 12 or not 1 <= day <= last_day(2024, month):
            raise RecurringError("invalid schedule: %s is not a day of the year" % words[2])
        return Schedule("yearly", month=month, day=day)
    if head == "every" and len(words) == 5 and words[3] == "from":
        step = _whole(words[1], "interval", 1, 10**9)
        if words[2] not in _UNITS:
            raise RecurringError("invalid schedule: '%s' is not days, weeks, months or years" % words[2])
        try:
            anchor = parse_date(words[4])
        except DateError as exc:
            raise RecurringError("invalid schedule: %s" % exc.message)
        return Schedule("every", step=step, unit=_UNITS[words[2]], anchor=anchor)
    raise bad


# ---------------------------------------------------------------- recurring items

class Recurring:
    """name `[A-Za-z0-9][A-Za-z0-9_-]*`; schedule a Schedule or its text; template a Transaction (its own date
    is ignored); start the first day the series may produce; end the last (inclusive) or None; count the most
    occurrences the series ever has, counted from `start`, or None."""

    def __init__(self, name, schedule, template, start, end=None, count=None):
        if not isinstance(name, str) or not _NAME.fullmatch(name):
            raise RecurringError("invalid recurring name %r: letters, digits, '-' and '_', not starting with - or _" % (name,))
        if isinstance(schedule, str):
            schedule = parse_schedule(schedule)
        if not isinstance(schedule, Schedule):
            raise RecurringError("a recurring item needs a schedule")
        if not isinstance(template, Transaction):
            raise RecurringError("a recurring item needs a transaction as its template")
        if not isinstance(start, date):
            raise RecurringError("a recurring item needs a start date")
        if end is not None and (not isinstance(end, date) or end < start):
            raise RecurringError("the end of '%s' must be a date on or after its start" % name)
        if count is not None and (not isinstance(count, int) or isinstance(count, bool) or count < 1):
            raise RecurringError("the count of '%s' must be a whole number of at least 1" % name)
        self.name, self.schedule, self.template = name, schedule, template
        self.start, self.end, self.count = start, end, count

    def __eq__(self, other):
        if not isinstance(other, Recurring):
            return NotImplemented
        return (self.name, self.schedule, self.template, self.start, self.end, self.count) == \
            (other.name, other.schedule, other.template, other.start, other.end, other.count)

    __hash__ = None

    def __repr__(self):
        return "Recurring(%r, %r, start=%s)" % (self.name, str(self.schedule), self.start.isoformat())


def occurrences(rec, start, end):
    """The dates of the series that fall within start..end inclusive, ascending. The series itself runs from
    rec.start to rec.end and stops after rec.count dates; those limits apply from the series' first date, not from
    the window."""
    if end < start:
        return []
    out = []
    for number, d in enumerate(rec.schedule.dates_from(rec.start), 1):
        if rec.count is not None and number > rec.count:
            break
        if d > end or (rec.end is not None and d > rec.end):
            break
        if d >= start:
            out.append(d)
    return out


def next_occurrence(rec, after):
    """The first date of the series strictly after `after`, or None when the series has ended."""
    for number, d in enumerate(rec.schedule.dates_from(rec.start), 1):
        if (rec.count is not None and number > rec.count) or (rec.end is not None and d > rec.end):
            return None
        if d > after:
            return d
    return None


_WEEKDAY_NAMES = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
_MONTH_NAMES = ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                "November", "December")


def ordinal(n):
    """1 -> 1st, 2 -> 2nd, 3 -> 3rd, 4 -> 4th, 11 -> 11th, 21 -> 21st, 112 -> 112th."""
    if 10 <= n % 100 <= 20:
        return "%dth" % n
    return "%d%s" % (n, {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th"))


def describe(schedule):
    """A schedule in words for a person: 'every Monday', 'on the 5th of every month', 'every 2 weeks from ...'."""
    if schedule.kind == "daily":
        return "every day"
    if schedule.kind == "weekly":
        return "every " + _WEEKDAY_NAMES[schedule.weekday]
    if schedule.kind == "monthly":
        which = "the last day" if schedule.day == 0 else "the " + ordinal(schedule.day)
        return "on %s of every month" % which
    if schedule.kind == "yearly":
        return "every year on %d %s" % (schedule.day, _MONTH_NAMES[schedule.month - 1])
    unit = schedule.unit[:-1]
    every = "every " + unit if schedule.step == 1 else "every %d %s" % (schedule.step, schedule.unit)
    return "%s from %s" % (every, schedule.anchor.isoformat())


def instantiate(rec, on):
    """One dated copy of the template: payee, narration, flag and postings as in the template, the tag `recurring`
    added to the template's tags (sorted, no repeats), no id."""
    t = rec.template
    return Transaction(
        date=on,
        payee=t.payee,
        narration=t.narration,
        postings=list(t.postings),
        tags=tuple(sorted(set(t.tags) | {RECURRING_TAG})),
        flag=t.flag,
        id=None,
    )


def expand(recs, start, end):
    """Dated copies for every occurrence of every item within start..end, ordered by (date, name, position in
    `recs`)."""
    keyed = []
    for position, rec in enumerate(recs):
        for d in occurrences(rec, start, end):
            keyed.append((d, rec.name, position, rec))
    keyed.sort(key=lambda k: k[:3])
    return [instantiate(rec, d) for d, _, _, rec in keyed]

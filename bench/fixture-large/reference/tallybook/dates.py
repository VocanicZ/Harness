"""Calendar helpers: strict dates, month arithmetic, and periods such as a month, a quarter or a range."""
import calendar
import re
from dataclasses import dataclass
from datetime import date, timedelta

from .errors import ParseError


class DateError(ParseError):
    """Text that is not a date or period, or a date calculation that leaves the calendar."""


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


_DATE_RE = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})")
_YEAR_RE = re.compile(r"([0-9]{4})")
_MONTH_RE = re.compile(r"([0-9]{4})-([0-9]{2})")
_QUARTER_RE = re.compile(r"([0-9]{4})-Q([1-4])")


def parse_date(text):
    """Strictly YYYY-MM-DD: four, two and two ASCII digits, and a day that exists."""
    if not isinstance(text, str):
        raise DateError("invalid date %r: expected text YYYY-MM-DD" % (text,))
    m = _DATE_RE.fullmatch(text)
    if m is None:
        raise DateError("invalid date '%s': expected YYYY-MM-DD" % text)
    try:
        return date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError as exc:
        raise DateError("invalid date '%s': %s" % (text, exc))


def format_date(d):
    if not isinstance(d, date):
        raise DateError("cannot format %r as a date" % (d,))
    return d.isoformat()


def last_day(year, month):
    """The number of the last day of that month (28 to 31)."""
    if not _is_int(year) or not 1 <= year <= 9999:
        raise DateError("invalid year %r: expected 1 to 9999" % (year,))
    if not _is_int(month) or not 1 <= month <= 12:
        raise DateError("invalid month %r: expected 1 to 12" % (month,))
    return calendar.monthrange(year, month)[1]


def add_months(d, n):
    """Move `n` months (negative goes back); a day past the end of the target month is clamped to its last day."""
    if not isinstance(d, date):
        raise DateError("add_months needs a date, got %r" % (d,))
    if not _is_int(n):
        raise DateError("add_months needs a whole number of months, got %r" % (n,))
    year, month0 = divmod(d.year * 12 + d.month - 1 + n, 12)
    if not 1 <= year <= 9999:
        raise DateError("%s plus %d months is outside the calendar" % (d.isoformat(), n))
    return date(year, month0 + 1, min(d.day, last_day(year, month0 + 1)))


def _month_end(d):
    return d.replace(day=last_day(d.year, d.month))


@dataclass(frozen=True)
class Period:
    """A run of whole days, both ends included."""
    start: date
    end: date

    def __post_init__(self):
        if not isinstance(self.start, date) or not isinstance(self.end, date):
            raise DateError("a period needs two dates, got %r and %r" % (self.start, self.end))
        if self.end < self.start:
            raise DateError("empty period: %s is before %s" % (self.end.isoformat(), self.start.isoformat()))

    @classmethod
    def parse(cls, text):
        """'2024' a year, '2024-03' a month, '2024-Q1' a quarter, '2024-03-01..2024-03-31' any range."""
        if not isinstance(text, str):
            raise DateError("invalid period %r" % (text,))
        try:
            if ".." in text:
                first, _, second = text.partition("..")
                return cls(parse_date(first), parse_date(second))
            m = _YEAR_RE.fullmatch(text)
            if m:
                year = int(m.group(1))
                return cls(date(year, 1, 1), date(year, 12, 31))
            m = _MONTH_RE.fullmatch(text)
            if m:
                year, month = int(m.group(1)), int(m.group(2))
                return cls(date(year, month, 1), date(year, month, last_day(year, month)))
            m = _QUARTER_RE.fullmatch(text)
            if m:
                year, quarter = int(m.group(1)), int(m.group(2))
                first_month = quarter * 3 - 2
                return cls(date(year, first_month, 1), date(year, first_month + 2, last_day(year, first_month + 2)))
        except (DateError, ValueError) as exc:
            raise DateError("invalid period '%s': %s" % (text, exc))
        raise DateError("invalid period '%s': expected 2024, 2024-03, 2024-Q1 or 2024-03-01..2024-03-31" % text)

    def _kind(self):
        s, e = self.start, self.end
        if s.day != 1 or e != _month_end(e) or s.year != e.year:
            return "range"
        if s.month == 1 and e.month == 12:
            return "year"
        if s.month == e.month:
            return "month"
        if s.month % 3 == 1 and e.month == s.month + 2:
            return "quarter"
        return "range"

    @property
    def label(self):
        kind = self._kind()
        if kind == "year":
            return "%04d" % self.start.year
        if kind == "month":
            return "%04d-%02d" % (self.start.year, self.start.month)
        if kind == "quarter":
            return "%04d-Q%d" % (self.start.year, (self.start.month - 1) // 3 + 1)
        return "%s..%s" % (self.start.isoformat(), self.end.isoformat())

    def __str__(self):
        return self.label

    @property
    def days(self):
        return (self.end - self.start).days + 1

    def contains(self, d):
        if not isinstance(d, date):
            raise DateError("contains needs a date, got %r" % (d,))
        return self.start <= d <= self.end

    def next(self):
        """The following month, quarter or year if this is one; otherwise the next run of the same number of days."""
        kind = self._kind()
        if kind == "range":
            try:
                start = self.end + timedelta(days=1)
                return Period(start, start + timedelta(days=self.days - 1))
            except OverflowError:
                raise DateError("the period after %s is outside the calendar" % self.label)
        step = {"month": 1, "quarter": 3, "year": 12}[kind]
        start = add_months(self.start, step)
        return Period(start, _month_end(add_months(start, step - 1)))


def _containing(d, step):
    if step == "week":
        start = d - timedelta(days=d.weekday())
        return Period(start, start + timedelta(days=6))
    if step == "month":
        return Period(d.replace(day=1), _month_end(d))
    if step == "quarter":
        first = d.replace(month=(d.month - 1) // 3 * 3 + 1, day=1)
        return Period(first, _month_end(add_months(first, 2)))
    return Period(date(d.year, 1, 1), date(d.year, 12, 31))


def periods(start, end, step):
    """Whole calendar periods ('week' Monday to Sunday, 'month', 'quarter', 'year') from the one holding
    `start` to the one holding `end`; the first and last are not trimmed to the dates given."""
    if step not in ("week", "month", "quarter", "year"):
        raise DateError("unknown period step '%s': expected week, month, quarter or year" % (step,))
    if not isinstance(start, date) or not isinstance(end, date):
        raise DateError("periods needs two dates, got %r and %r" % (start, end))
    if end < start:
        raise DateError("empty range: %s is before %s" % (end.isoformat(), start.isoformat()))
    try:
        current = _containing(start, step)
        out = [current]
        while current.end < end:
            current = (Period(current.end + timedelta(days=1), current.end + timedelta(days=7))
                       if step == "week" else current.next())
            out.append(current)
        return out
    except OverflowError:
        raise DateError("periods from %s to %s run outside the calendar" % (start.isoformat(), end.isoformat()))

"""Budgets: an allowance per month, quarter or year for the expense accounts a pattern selects, compared with
what was actually spent in any period you ask about."""
import re
from dataclasses import dataclass
from datetime import date, timedelta
from fractions import Fraction
from decimal import Decimal

from .dates import add_months, last_day
from .errors import ValidationError
from .export import money_to_dict
from .money import Money, round_div

PERIOD_KINDS = ("month", "quarter", "year")
_SEGMENT = re.compile(r"[A-Z][A-Za-z0-9_-]*")


class BudgetError(ValidationError):
    """A budget that cannot exist: unknown kind, bad pattern, an allowance that is not positive."""


def _split_pattern(pattern):
    if not isinstance(pattern, str) or not pattern:
        raise BudgetError("a budget needs an account pattern such as Expenses:Food")
    segments = pattern.split(":")
    for seg in segments:
        if seg != "*" and not _SEGMENT.fullmatch(seg):
            raise BudgetError("invalid budget pattern '%s': segments are account names or *" % pattern)
    return segments


def pattern_matches(pattern, account):
    """True when `account` is what the pattern names or lies below it; `*` stands for any one segment."""
    want = _split_pattern(pattern)
    have = account.split(":")
    if len(have) < len(want):
        return False
    return all(w == "*" or w == h for w, h in zip(want, have))


@dataclass(frozen=True)
class Budget:
    pattern: str
    period_kind: str
    amount: Money
    start: date

    def __post_init__(self):
        _split_pattern(self.pattern)
        if self.period_kind not in PERIOD_KINDS:
            raise BudgetError("invalid budget period '%s': expected month, quarter or year" % (self.period_kind,))
        if not isinstance(self.amount, Money) or self.amount.minor <= 0:
            raise BudgetError("a budget amount must be a positive sum of money, got %s" % (self.amount,))
        if not isinstance(self.start, date):
            raise BudgetError("a budget needs a start date, got %r" % (self.start,))


@dataclass(frozen=True)
class BudgetLine:
    """One budget measured over one period. `accounts` is a tuple of (account, Money) for every matching expense
    account with spending in the budget's currency, sorted by account. `percent` is a Decimal with one place."""
    pattern: str
    period_kind: str
    budget: Money
    actual: Money
    remaining: Money
    percent: Decimal
    over: bool
    accounts: tuple

    def to_dict(self):
        return {
            "pattern": self.pattern,
            "period_kind": self.period_kind,
            "budget": money_to_dict(self.budget),
            "actual": money_to_dict(self.actual),
            "remaining": money_to_dict(self.remaining),
            "percent": str(self.percent),
            "over": self.over,
            "accounts": [{"account": a, "amount": money_to_dict(m)} for a, m in self.accounts],
        }


def calendar_period(kind, on):
    """(first day, last day) of the calendar month, quarter or year that holds `on`."""
    if kind == "month":
        first = on.replace(day=1)
        months = 1
    elif kind == "quarter":
        first = date(on.year, (on.month - 1) // 3 * 3 + 1, 1)
        months = 3
    else:
        first = date(on.year, 1, 1)
        months = 12
    end = add_months(first, months - 1)
    return first, end.replace(day=last_day(end.year, end.month))


def allowance(budget, period):
    """The budget's amount for `period`: each calendar unit of its kind, from the unit that holds `start`, counts
    for the share of its days that fall inside the period; the shares are added and rounded once."""
    first_unit_start, _ = calendar_period(budget.period_kind, budget.start)
    lo = max(period.start, first_unit_start)
    if lo > period.end:
        return None
    share = Fraction(0)
    unit_start, unit_end = calendar_period(budget.period_kind, lo)
    while unit_start <= period.end:
        days = (unit_end - unit_start).days + 1
        overlap = (min(unit_end, period.end) - max(unit_start, period.start)).days + 1
        share += Fraction(overlap, days)
        unit_start, unit_end = calendar_period(budget.period_kind, unit_end + timedelta(days=1))
    return Money(round_div(budget.amount.minor * share.numerator, share.denominator), budget.amount.currency)


def _percent(actual, budget):
    if budget.minor == 0:
        return Decimal("0.0") if actual.minor == 0 else Decimal("100.0")
    tenths = round_div(actual.minor * 1000, budget.minor)
    return Decimal(tenths).scaleb(-1).quantize(Decimal("0.1"))


def _spend_by_account(ledger, budget, period):
    totals = {}
    for tx, posting in ledger.postings():
        if posting.amount is None or not period.contains(tx.date):
            continue
        if posting.amount.currency != budget.amount.currency:
            continue
        if posting.account.split(":")[0] != "Expenses" or not pattern_matches(budget.pattern, posting.account):
            continue
        totals[posting.account] = totals.get(posting.account, 0) + posting.amount.minor
    currency = budget.amount.currency
    return [(a, Money(v, currency)) for a, v in sorted(totals.items()) if v != 0]


def budget_status(budgets, ledger, period):
    """One BudgetLine for each budget that is in force during some part of `period`, sorted by (pattern, kind
    month < quarter < year, start); equal budgets keep their given order."""
    lines = []
    for budget in sorted(budgets, key=lambda b: (b.pattern, PERIOD_KINDS.index(b.period_kind), b.start)):
        allowed = allowance(budget, period)
        if allowed is None:
            continue
        accounts = _spend_by_account(ledger, budget, period)
        actual = Money(sum(m.minor for _, m in accounts), budget.amount.currency)
        lines.append(BudgetLine(
            pattern=budget.pattern,
            period_kind=budget.period_kind,
            budget=allowed,
            actual=actual,
            remaining=allowed - actual,
            percent=_percent(actual, allowed),
            over=actual.minor > allowed.minor,
            accounts=tuple(accounts),
        ))
    return lines

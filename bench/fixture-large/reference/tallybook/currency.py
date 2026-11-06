"""The currency table and dated exchange rates.

Rates are kept as exact fractions. Nothing here reads the clock: every lookup says which day it is for.
"""
import re
from dataclasses import dataclass
from datetime import date, datetime
from fractions import Fraction
from typing import Dict, List, Tuple

from .errors import ValidationError


class CurrencyError(ValidationError):
    """An unknown currency, a bad rate, or a rate that is not there."""


@dataclass(frozen=True)
class Currency:
    code: str
    exponent: int
    name: str
    symbol: str


CURRENCIES = {c.code: c for c in (
    Currency("USD", 2, "US Dollar", "$"),
    Currency("EUR", 2, "Euro", "€"),
    Currency("GBP", 2, "British Pound", "£"),
    Currency("JPY", 0, "Japanese Yen", "¥"),
    Currency("CHF", 2, "Swiss Franc", "CHF"),
    Currency("CAD", 2, "Canadian Dollar", "CA$"),
    Currency("AUD", 2, "Australian Dollar", "A$"),
    Currency("KWD", 3, "Kuwaiti Dinar", "KD"),
    Currency("SEK", 2, "Swedish Krona", "kr"),
    Currency("INR", 2, "Indian Rupee", "₹"),
    Currency("NZD", 2, "New Zealand Dollar", "NZ$"),
    Currency("NOK", 2, "Norwegian Krone", "kr"),
    Currency("KRW", 0, "South Korean Won", "₩"),
    Currency("BHD", 3, "Bahraini Dinar", "BD"),
    Currency("CNY", 2, "Chinese Yuan", "CN¥"),
    Currency("MXN", 2, "Mexican Peso", "MX$"),
)}

MAX_RATE_DECIMALS = 8
_RATE_RE = re.compile(r"[0-9]+(?:\.([0-9]+))?")


def currency(code):
    """The Currency for an upper-case code; anything else is a CurrencyError naming it."""
    if not isinstance(code, str) or code not in CURRENCIES:
        raise CurrencyError("unknown currency '%s'" % (code,), code=code)
    return CURRENCIES[code]


def _check_day(on):
    if not isinstance(on, date) or isinstance(on, datetime):
        raise CurrencyError("a rate date must be a datetime.date, got %r" % (on,))
    return on


class RateTable:
    """Exchange rates by (src, dst) and the day they were set."""

    def __init__(self):
        self._rates = {}  # type: Dict[Tuple[str, str], Dict[date, Fraction]]

    def set(self, src, dst, rate_text, on):
        """Record that 1 `src` was worth `rate_text` `dst` from day `on`. Setting the same day again replaces it."""
        currency(src)
        currency(dst)
        _check_day(on)
        if src == dst:
            raise CurrencyError("cannot set a rate from %s to itself" % src)
        if not isinstance(rate_text, str):
            raise CurrencyError("a rate must be given as text, got %r" % (rate_text,))
        m = _RATE_RE.fullmatch(rate_text)
        if m is None:
            raise CurrencyError("invalid rate '%s': expected a positive decimal such as 0.9215" % rate_text)
        if m.group(1) is not None and len(m.group(1)) > MAX_RATE_DECIMALS:
            raise CurrencyError("invalid rate '%s': at most %d decimals" % (rate_text, MAX_RATE_DECIMALS))
        value = Fraction(rate_text)
        if value <= 0:
            raise CurrencyError("invalid rate '%s': a rate must be greater than zero" % rate_text)
        self._rates.setdefault((src, dst), {})[on] = value

    def remove(self, src, dst, on):
        """Delete exactly the rate set for src -> dst on that day."""
        currency(src)
        currency(dst)
        _check_day(on)
        days = self._rates.get((src, dst), {})
        if on not in days:
            raise CurrencyError("no rate %s -> %s set on %s" % (src, dst, on.isoformat()))
        del days[on]
        if not days:
            del self._rates[(src, dst)]

    def _latest(self, src, dst, on):
        days = [d for d in self._rates.get((src, dst), ()) if d <= on]
        if not days:
            return None
        return self._rates[(src, dst)][max(days)]

    def rate(self, src, dst, on):
        """How many `dst` one `src` buys on day `on`, as an exact Fraction.

        The latest direct rate dated on or before `on` wins; failing that the inverse of the latest
        opposite-direction rate. There is no going through a third currency."""
        currency(src)
        currency(dst)
        _check_day(on)
        if src == dst:
            return Fraction(1)
        direct = self._latest(src, dst, on)
        if direct is not None:
            return direct
        opposite = self._latest(dst, src, on)
        if opposite is not None:
            return 1 / opposite
        raise CurrencyError("no rate %s -> %s on %s" % (src, dst, on.isoformat()))

    def convert(self, money, dst, on):
        """`money` in currency `dst` at the rate of day `on`, rounded to dst's minor unit with round_div."""
        from .money import Money, round_div
        if not isinstance(money, Money):
            raise CurrencyError("convert needs a Money, got %r" % (money,))
        if money.currency == dst:
            currency(dst)
            return money
        r = self.rate(money.currency, dst, on)
        shift = currency(dst).exponent - currency(money.currency).exponent
        num = money.minor * r.numerator * (10 ** shift if shift > 0 else 1)
        den = r.denominator * (10 ** -shift if shift < 0 else 1)
        return Money(round_div(num, den), dst)

    def entries(self):
        """Every stored rate as (src, dst, day, Fraction), sorted."""
        out = []  # type: List[tuple]
        for (src, dst), days in self._rates.items():
            for day, value in days.items():
                out.append((src, dst, day, value))
        return sorted(out)

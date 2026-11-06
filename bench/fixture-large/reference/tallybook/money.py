"""Money: whole minor units of one currency, with strict parsing, exact arithmetic and fair allocation."""
import re
from dataclasses import dataclass
from typing import List

from . import _phase
from .currency import currency as _currency
from .errors import ValidationError


class MoneyError(ValidationError):
    """Bad amount text, mixed currencies, or an impossible division."""


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def round_div(n, d):
    """The integer nearest n / d for d > 0. A tie goes away from zero (original rules) or to the even neighbour."""
    if not _is_int(n) or not _is_int(d):
        raise MoneyError("round_div needs two integers, got %r and %r" % (n, d))
    if d <= 0:
        raise MoneyError("cannot divide by %d: the divisor must be positive" % d)
    q, r = divmod(abs(n), d)
    if 2 * r > d or (2 * r == d and (_phase.PRE or q % 2 == 1)):
        q += 1
    return -q if n < 0 else q


_AMOUNT_RE = re.compile(r"([+-]?)([0-9]+)(?:\.([0-9]+))?")


def parse_amount(text, currency):
    """Amount text such as '-12.50' to minor units. At most as many decimals as the currency has."""
    exponent = _currency(currency).exponent
    if not isinstance(text, str):
        raise MoneyError("invalid amount %r for %s: amounts are text" % (text, currency))
    m = _AMOUNT_RE.fullmatch(text)
    if m is None:
        raise MoneyError("invalid amount '%s' for %s: expected digits, optionally signed, with an optional "
                         "decimal part" % (text, currency))
    sign, whole, frac = m.group(1), m.group(2), m.group(3) or ""
    if len(frac) > exponent:
        raise MoneyError("invalid amount '%s' for %s: at most %d decimal places" % (text, currency, exponent))
    minor = int(whole + frac.ljust(exponent, "0"))
    return -minor if sign == "-" else minor


def format_minor(minor, currency):
    """Minor units as amount text with exactly the currency's decimals: -5 USD is '-0.05', 7 JPY is '7'."""
    exponent = _currency(currency).exponent
    if not _is_int(minor):
        raise MoneyError("minor units must be an integer, got %r" % (minor,))
    sign = "-" if minor < 0 else ""
    digits = str(abs(minor))
    if exponent == 0:
        return sign + digits
    digits = digits.rjust(exponent + 1, "0")
    return "%s%s.%s" % (sign, digits[:-exponent], digits[-exponent:])


@dataclass(frozen=True)
class Money:
    minor: int
    currency: str

    def __post_init__(self):
        if not _is_int(self.minor):
            raise MoneyError("minor units must be an integer, got %r" % (self.minor,))
        _currency(self.currency)

    # construction
    @classmethod
    def parse(cls, text):
        """'12.50 USD': an amount, exactly one space, a currency code."""
        if not isinstance(text, str):
            raise MoneyError("invalid money %r: expected text such as '12.50 USD'" % (text,))
        parts = text.split(" ")
        if len(parts) != 2 or not all(parts):
            raise MoneyError("invalid money '%s': expected an amount, one space and a currency code" % text)
        amount, code = parts
        return cls(parse_amount(amount, code), code)

    @classmethod
    def of(cls, amount_text, currency):
        return cls(parse_amount(amount_text, currency), currency)

    @classmethod
    def zero(cls, currency):
        return cls(0, currency)

    # inspection
    @property
    def exponent(self):
        return _currency(self.currency).exponent

    def is_zero(self):
        return self.minor == 0

    def sign(self):
        return (self.minor > 0) - (self.minor < 0)

    def amount_str(self):
        return format_minor(self.minor, self.currency)

    def __str__(self):
        return "%s %s" % (self.amount_str(), self.currency)

    def __repr__(self):
        return "Money(%d, %r)" % (self.minor, self.currency)

    # arithmetic
    def _same(self, other, verb):
        if self.currency != other.currency:
            raise MoneyError("cannot %s %s and %s: different currencies" % (verb, self.currency, other.currency))

    def __add__(self, other):
        if not isinstance(other, Money):
            return NotImplemented
        self._same(other, "add")
        return Money(self.minor + other.minor, self.currency)

    def __sub__(self, other):
        if not isinstance(other, Money):
            return NotImplemented
        self._same(other, "subtract")
        return Money(self.minor - other.minor, self.currency)

    def __neg__(self):
        return Money(-self.minor, self.currency)

    def __abs__(self):
        return Money(abs(self.minor), self.currency)

    def __mul__(self, factor):
        if not _is_int(factor):
            return NotImplemented
        return Money(self.minor * factor, self.currency)

    __rmul__ = __mul__

    def scale(self, num, den=1):
        """This amount times the ratio num/den, rounded to a whole minor unit with round_div."""
        if not _is_int(num) or not _is_int(den):
            raise MoneyError("scale needs integers, got %r and %r" % (num, den))
        if den == 0:
            raise MoneyError("cannot scale by %d/0" % num)
        if den < 0:
            num, den = -num, -den
        return Money(round_div(self.minor * num, den), self.currency)

    # comparison (equality across currencies is simply False)
    def _order(self, other, op):
        if not isinstance(other, Money):
            return NotImplemented
        self._same(other, "compare")
        return op(self.minor, other.minor)

    def __lt__(self, other):
        return self._order(other, lambda a, b: a < b)

    def __le__(self, other):
        return self._order(other, lambda a, b: a <= b)

    def __gt__(self, other):
        return self._order(other, lambda a, b: a > b)

    def __ge__(self, other):
        return self._order(other, lambda a, b: a >= b)

    # sharing out
    def allocate(self, weights):
        """Split into len(weights) parts proportional to the weights, summing exactly to this amount.

        Largest remainder: every part gets its whole share, then the leftover minor units go one each to the
        parts with the biggest fractional remainders, the earlier part winning a tie. A negative amount is
        split as its absolute value and negated. A zero weight always gets zero."""
        if not isinstance(weights, (list, tuple)) or not all(_is_int(w) and w >= 0 for w in weights):
            raise MoneyError("weights must be a list of non-negative integers, got %r" % (weights,))
        total_weight = sum(weights)
        if total_weight <= 0:
            raise MoneyError("weights must have a positive sum, got %r" % (list(weights),))
        amount = abs(self.minor)
        shares = [amount * w // total_weight for w in weights]
        remainders = [amount * w % total_weight for w in weights]
        leftover = amount - sum(shares)
        by_remainder = sorted(range(len(weights)), key=lambda i: (-remainders[i], i))
        for i in by_remainder[:leftover]:
            shares[i] += 1
        sign = -1 if self.minor < 0 else 1
        return [Money(sign * s, self.currency) for s in shares]  # type: List[Money]

"""Money as whole pennies. Every rounding of a half goes up."""
import re
from decimal import Decimal

AMOUNT = re.compile(r"[0-9]+(\.[0-9]{1,2})?")


def parse_pennies(text):
    """'12.5' -> 1250. None when the text is not a non-negative amount with at most two decimals."""
    if not AMOUNT.fullmatch(text):
        return None
    whole, _, frac = text.partition(".")
    return int(whole) * 100 + int((frac + "00")[:2])


def fmt(pennies):
    """1250 -> '12.50'; -150 -> '-1.50'."""
    sign = "-" if pennies < 0 else ""
    pennies = abs(pennies)
    return "%s%d.%02d" % (sign, pennies // 100, pennies % 100)


def to_decimal(pennies):
    return Decimal(pennies).scaleb(-2).quantize(Decimal("0.01"))


def percent(pennies, rate):
    """`rate` per cent of a non-negative number of pennies, halves rounded up."""
    return (pennies * rate + 50) // 100

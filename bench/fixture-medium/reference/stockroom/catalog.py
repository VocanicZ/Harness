"""catalog.txt: what is sold."""
import re
from collections import namedtuple
from decimal import Decimal

from . import money
from .errors import ParseError
from .textio import numbered

SKU = re.compile(r"[A-Za-z]{2,4}-[0-9]{3}")
TAX_RATES = {"standard": 20, "reduced": 5, "zero": 0}

Product = namedtuple("Product", "sku name price reorder tax")


def norm_sku(text):
    """The upper-case SKU, or None when the text is not shaped like one."""
    return text.upper() if SKU.fullmatch(text) else None


def parse_catalog(text):
    """dict of SKU -> Product, in file order. ParseError names the line of the first mistake."""
    out = {}
    for number, line in numbered(text):
        fields = [f.strip() for f in line.split("|")]
        if len(fields) not in (4, 5):
            raise ParseError("expected 4 or 5 fields separated by '|', found %d" % len(fields), number)
        sku = norm_sku(fields[0])
        if sku is None:
            raise ParseError("bad SKU %r (want letters, a dash and three digits)" % fields[0], number)
        if sku in out:
            raise ParseError("duplicate SKU %s" % sku, number)
        if not fields[1]:
            raise ParseError("empty name", number)
        pennies = money.parse_pennies(fields[2])
        if pennies is None or pennies < 1:
            raise ParseError("bad price %r (at least 0.01, at most two decimals)" % fields[2], number)
        if not re.fullmatch(r"[0-9]+", fields[3]):
            raise ParseError("bad reorder level %r (a whole number)" % fields[3], number)
        tax = fields[4].lower() if len(fields) == 5 else "standard"
        if tax not in TAX_RATES:
            raise ParseError("bad tax class %r (standard, reduced or zero)" % fields[4], number)
        out[sku] = Product(sku, fields[1], money.to_decimal(pennies), int(fields[3]), tax)
    return out


def pennies_of(product):
    """A product's unit price in whole pennies."""
    return int(product.price * 100)


def tax_rate(product):
    return TAX_RATES[product.tax]

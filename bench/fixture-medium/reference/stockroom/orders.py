"""orders.txt: what customers ordered."""
import re
from collections import namedtuple

from .catalog import norm_sku
from .dates import parse_date
from .errors import ParseError
from .textio import numbered, split_ws

Order = namedtuple("Order", "id date customer lines")
ORDER_ID = re.compile(r"[Ss][Oo]-[0-9]+")


def norm_order(text):
    """The upper-case order number, or None when the text is not shaped like one."""
    return text.upper() if ORDER_ID.fullmatch(text) else None


def parse_orders(text, catalog):
    """The orders in file order; `.lines` is a list of (sku, quantity). ParseError names the line of a mistake."""
    out, seen = [], set()
    for number, line in numbered(text):
        parts = split_ws(line, 4)
        if len(parts) != 4:
            raise ParseError("expected ORDER DATE CUSTOMER LINES", number)
        oid = norm_order(parts[0])
        if oid is None:
            raise ParseError("bad order number %r (SO- and digits)" % parts[0], number)
        if oid in seen:
            raise ParseError("duplicate order %s" % oid, number)
        try:
            date = parse_date(parts[1])
        except ValueError as exc:
            raise ParseError(str(exc), number)
        if re.search(r"[ \t]", parts[3]):
            raise ParseError("order lines must be comma separated with no spaces", number)
        lines, used = [], set()
        for piece in parts[3].split(","):
            sku_text, star, qty_text = piece.partition("*")
            sku = norm_sku(sku_text)
            if not star or sku is None or sku not in catalog:
                raise ParseError("bad order line %r (want SKU*QUANTITY with a known SKU)" % piece, number)
            if not re.fullmatch(r"[0-9]+", qty_text) or int(qty_text) < 1:
                raise ParseError("bad quantity %r (a whole number of one or more)" % qty_text, number)
            if sku in used:
                raise ParseError("%s appears twice in the order" % sku, number)
            used.add(sku)
            lines.append((sku, int(qty_text)))
        seen.add(oid)
        out.append(Order(oid, date, parts[2], lines))
    return out

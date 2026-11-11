"""movements.txt: what came in and went out, and the stock they leave."""
import re
from collections import namedtuple

from .catalog import norm_sku
from .dates import parse_date
from .errors import ParseError, Refused
from .textio import numbered, split_ws

Movement = namedtuple("Movement", "date sku quantity note")
QUANTITY = re.compile(r"[+-]?[0-9]+")


def parse_movements(text, catalog):
    """The movements, in file order. ParseError for a bad line, or for the line that takes a stock below zero."""
    out = []
    for number, line in numbered(text):
        parts = split_ws(line, 4)
        if len(parts) < 3:
            raise ParseError("expected DATE SKU QUANTITY [NOTE]", number)
        try:
            date = parse_date(parts[0])
        except ValueError as exc:
            raise ParseError(str(exc), number)
        sku = norm_sku(parts[1])
        if sku is None or sku not in catalog:
            raise ParseError("unknown SKU %r" % parts[1], number)
        if not QUANTITY.fullmatch(parts[2]) or int(parts[2]) == 0:
            raise ParseError("bad quantity %r (a whole number, not zero)" % parts[2], number)
        note = parts[3].strip() if len(parts) == 4 else ""
        out.append((number, Movement(date, sku, int(parts[2]), note)))
    check_stock(out)
    return [m for _, m in out]


def in_order(numbered_moves):
    """Movements in the order they count: by date, the file order within a day."""
    return sorted(numbered_moves, key=lambda nm: nm[1].date)


def check_stock(numbered_moves):
    """ParseError at the line whose movement takes some stock below zero."""
    level = {}
    for number, m in in_order(numbered_moves):
        level[m.sku] = level.get(m.sku, 0) + m.quantity
        if level[m.sku] < 0:
            raise ParseError("stock of %s would go below zero" % m.sku, number)


def sorted_moves(moves):
    return [m for _, m in in_order(list(enumerate(moves)))]


def stock_levels(catalog, moves):
    """dict of SKU -> quantity on the shelf, for every product in the catalogue."""
    level = {sku: 0 for sku in catalog}
    for m in moves:
        level[m.sku] = level.get(m.sku, 0) + m.quantity
    return level


def history(moves, sku):
    """[(Movement, balance after)] for one SKU, in the order they count."""
    balance, out = 0, []
    for m in sorted_moves(moves):
        if m.sku == sku:
            balance += m.quantity
            out.append((m, balance))
    return out


def available_on(moves, sku, date):
    """The most of `sku` that can leave on `date` without any later movement taking the stock below zero: the lowest
    balance from `date` on (after everything dated on or before `date`, and after each later movement)."""
    balance, low = 0, None
    for m in sorted_moves(moves):
        if m.sku != sku:
            continue
        if m.date > date and low is None:
            low = balance
        balance += m.quantity
        if m.date > date:
            low = min(low, balance)
    return max(0, balance if low is None else low)


def format_movement(m):
    return "%s %s %+d%s" % (m.date.isoformat(), m.sku, m.quantity, " " + m.note if m.note else "")


def new_movement(moves, catalog, date, sku_text, quantity_text, note, sign):
    """The Movement `receive` (sign +1) or `ship` (-1) would add, checked against the rules: Refused when it breaks one."""
    sku = norm_sku(sku_text)
    if sku is None or sku not in catalog:
        raise Refused("unknown SKU %r" % sku_text)
    if not re.fullmatch(r"[0-9]+", quantity_text) or int(quantity_text) < 1:
        raise Refused("bad quantity %r (a whole number of one or more)" % quantity_text)
    if "\n" in note or "\r" in note:
        raise Refused("a note may not contain a line break")
    m = Movement(date, sku, sign * int(quantity_text), note.strip())
    try:
        check_stock([(i, x) for i, x in enumerate(list(moves) + [m])])
    except ParseError:
        raise Refused("stock of %s would go below zero" % sku)
    return m

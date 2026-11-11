"""Pricing an order: volume discount, order discount shared out by largest remainder, tax per line."""
from collections import namedtuple

from . import money
from .catalog import pennies_of, tax_rate

QuoteLine = namedtuple("QuoteLine", "sku quantity unit gross discount net")
Quote = namedtuple("Quote", "order lines subtotal order_discount tax total")

ORDER_DISCOUNT_FROM = 50000   # pennies: a subtotal of 500.00 or more
ORDER_DISCOUNT_PCT = 3


def volume_pct(quantity):
    return 10 if quantity >= 50 else 5 if quantity >= 10 else 0


def share_out(total, weights):
    """Split `total` pennies over `weights` in proportion: each share rounded down, the leftover pennies one each to
    the biggest fractional parts (the earlier line first on a tie)."""
    weight_sum = sum(weights)
    if not weights or weight_sum == 0:
        return [0] * len(weights)
    shares = [total * w // weight_sum for w in weights]
    remainders = [total * w % weight_sum for w in weights]
    order = sorted(range(len(weights)), key=lambda i: (-remainders[i], i))
    for i in order[:total - sum(shares)]:
        shares[i] += 1
    return shares


def price_lines(order, catalog, quantities):
    """Whole-penny figures for `order`'s lines at `quantities` (a list parallel to order.lines; zero skips a line)."""
    rows = []
    for (sku, _), qty in zip(order.lines, quantities):
        if qty <= 0:
            continue
        product = catalog[sku]
        unit = pennies_of(product)
        gross = unit * qty
        discount = money.percent(gross, volume_pct(qty))
        rows.append((product, qty, unit, gross, -discount, gross - discount))
    subtotal = sum(r[5] for r in rows)
    order_discount = money.percent(subtotal, ORDER_DISCOUNT_PCT) if subtotal >= ORDER_DISCOUNT_FROM else 0
    shares = share_out(order_discount, [r[5] for r in rows])
    tax = sum(money.percent(r[5] - s, tax_rate(r[0])) for r, s in zip(rows, shares))
    return rows, subtotal, -order_discount, tax


def price(order, catalog, quantities=None):
    """A Quote (pennies as ints inside; see price_order for the Decimal form)."""
    quantities = [q for _, q in order.lines] if quantities is None else quantities
    rows, subtotal, order_discount, tax = price_lines(order, catalog, quantities)
    lines = [QuoteLine(r[0].sku, r[1], r[2], r[3], r[4], r[5]) for r in rows]
    return Quote(order, lines, subtotal, order_discount, tax, subtotal + order_discount + tax)


def price_order(order, catalog):
    """The Quote of the whole order with every amount a two-decimal Decimal."""
    q = price(order, catalog)
    d = money.to_decimal
    lines = [QuoteLine(l.sku, l.quantity, d(l.unit), d(l.gross), d(l.discount), d(l.net)) for l in q.lines]
    return Quote(order, lines, d(q.subtotal), d(q.order_discount), d(q.tax), d(q.total))

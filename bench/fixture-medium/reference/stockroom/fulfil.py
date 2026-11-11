"""Shipping an order from the shelves, and what has shipped so far."""
from collections import namedtuple

from .movements import Movement, available_on
from .errors import Refused

Shipment = namedtuple("Shipment", "sku shipped owed")


def ship_note(order):
    return "order %s" % order.id


def shipped_so_far(order, moves):
    """[units shipped on each order line], from the movements whose note is exactly `order SO-n`; capped at the
    quantity ordered."""
    note = ship_note(order)
    sent = {}
    for m in moves:
        if m.note == note and m.quantity < 0:
            sent[m.sku] = sent.get(m.sku, 0) - m.quantity
    return [min(qty, sent.get(sku, 0)) for sku, qty in order.lines]


def status(order, moves):
    """open (nothing shipped), partial or complete (nothing owed on any line)."""
    sent = shipped_so_far(order, moves)
    if all(s >= q for s, (_, q) in zip(sent, order.lines)):
        return "complete"
    return "open" if not any(sent) else "partial"


def plan(order, moves, date):
    """([Shipment per order line], [Movement to add]) for shipping what the shelves cover on `date`."""
    if date < order.date:
        raise Refused("cannot ship %s on %s: it was ordered on %s" % (order.id, date.isoformat(), order.date.isoformat()))
    sent = shipped_so_far(order, moves)
    shipments, new = [], []
    work = list(moves)
    for (sku, qty), done in zip(order.lines, sent):
        owed = qty - done
        n = min(owed, available_on(work, sku, date))
        if n > 0:
            m = Movement(date, sku, -n, ship_note(order))
            new.append(m)
            work.append(m)
        shipments.append(Shipment(sku, n, owed - n))
    return shipments, new

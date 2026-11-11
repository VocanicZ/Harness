"""Everything the commands print, as text, JSON or CSV."""
import csv
import io
import json

from . import money


def dump(obj):
    return json.dumps(obj)


def stock_rows(catalog, levels):
    rows = []
    for sku in sorted(catalog):
        p, n = catalog[sku], levels[sku]
        status = "out" if n == 0 else "low" if n <= p.reorder else "ok"
        rows.append({"sku": sku, "name": p.name, "onhand": n, "status": status})
    return rows


def stock_text(rows):
    return ["%s %d %s %s" % (r["sku"], r["onhand"], r["status"], r["name"]) for r in rows]


def low_rows(catalog, levels):
    rows = []
    for sku in sorted(catalog):
        p, n = catalog[sku], levels[sku]
        if n <= p.reorder:
            rows.append({"sku": sku, "onhand": n, "reorder": p.reorder, "buy": max(1, 2 * p.reorder - n)})
    return rows


def low_text(rows):
    return ["%s %d %d %d" % (r["sku"], r["onhand"], r["reorder"], r["buy"]) for r in rows]


def history_rows(pairs):
    return [{"date": m.date.isoformat(), "delta": "%+d" % m.quantity, "balance": b, "note": m.note} for m, b in pairs]


def history_text(rows):
    return ["%s %s %d%s" % (r["date"], r["delta"], r["balance"], " " + r["note"] if r["note"] else "") for r in rows]


def quote_obj(q, prefix=""):
    o = q.order
    return {"order": o.id, "date": o.date.isoformat(), "customer": o.customer,
            "lines": [{"sku": l.sku, "quantity": l.quantity, "unit": money.fmt(l.unit), "gross": money.fmt(l.gross),
                       "discount": money.fmt(l.discount), "net": money.fmt(l.net)} for l in q.lines],
            "subtotal": money.fmt(q.subtotal), "order_discount": money.fmt(q.order_discount),
            "tax": money.fmt(q.tax), "total": money.fmt(q.total)}


def quote_text(q, prefix=""):
    o = q.order
    out = ["%s%s %s %s" % (prefix, o.id, o.date.isoformat(), o.customer)]
    for l in q.lines:
        out.append("%s %d %s %s %s %s" % (l.sku, l.quantity, money.fmt(l.unit), money.fmt(l.gross),
                                          money.fmt(l.discount), money.fmt(l.net)))
    out += ["subtotal %s" % money.fmt(q.subtotal), "order discount %s" % money.fmt(q.order_discount),
            "tax %s" % money.fmt(q.tax), "total %s" % money.fmt(q.total)]
    return out


def fulfil_text(shipments, status):
    return ["%s shipped %d backordered %d" % (s.sku, s.shipped, s.owed) for s in shipments] + ["status " + status]


REPORT_KEYS = ("order", "date", "customer", "status", "ordered", "shipped", "quoted", "invoiced")


def report_text(rows):
    return ["%s %s %s %s %d/%d %s %s" % (r["order"], r["date"], r["customer"], r["status"], r["shipped"], r["ordered"],
                                         r["quoted"], r["invoiced"]) for r in rows]


def report_csv(rows):
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(REPORT_KEYS)
    for r in rows:
        w.writerow([r[k] for k in REPORT_KEYS])
    return buf.getvalue().rstrip("\n").split("\n")

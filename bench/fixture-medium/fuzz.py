#!/usr/bin/env python3
"""fuzz.py — differential fuzz of an arm's `stockroom` against the reference implementation (PRD #345, #621).

The medium fixture's own tests are hand-written; this feeds the arm and the reference (bench/fixture-medium/reference/)
the SAME work folders and command lines and counts where they disagree. Same interface as bench/fuzz.py (which delegates
here for `--fixture medium`):

    bench/fixture-medium/fuzz.py --self                  # the reference against itself: must report 0 divergences
    bench/fixture-medium/fuzz.py --cmd '["stockroom"]'   # an arm's command line (JSON argv); default $STOCKROOM_CMD
    bench/fixture-medium/fuzz.py --cases 200 --cap 60    # the first 200 cases / a shorter time cap (defaults 1000 / 600 s)

Prints one JSON object (exit 0; 2 for bad arguments or a generator that no longer matches its frozen hash):

    {"fuzz_cases": N, "fuzz_divergences": N, "fuzz_classes": N, "fuzz_class_counts": {"<feature> x <difference>": N, ...},
     "fuzz_examples": [up to 10], "fuzz_seed": 621, "fuzz_hash": "..."}

A case is a work folder (catalog.txt, movements.txt, orders.txt as bytes, any of them absent; in the current folder or in a
sub-folder named by `--dir`) and ONE OR A SHORT SEQUENCE of command lines run in it one after the other, so what `receive`,
`ship` and `fulfil` add is seen by the commands after them. The reference runs as `python -m stockroom`. Each case gets its own
fresh folder for both implementations. The cases cover every command and option of the brief with good and bad dates, SKUs,
quantities and order numbers; each kind of mistake the brief lists in the three files (with the line it must name); LF and CRLF,
a byte order mark, no final newline, blank and comment lines, tabs, non-ASCII text, invalid UTF-8, missing files and `--dir` to
a missing folder; prices and quantities that put a half penny into the volume discount, the order discount and the tax; the
500.00 threshold; the order discount shared out with ties; the three tax classes; `fulfil` with a shortfall, earlier shipments
by note, later movements that limit what can go, a date before the order; `invoice` for what shipped; `report` as text, csv and
json; every way the command line can be wrong; the order the brief fixes (command line, then files, then request); and a
closed output pipe.

What is compared, per command: the exit status; standard output (exactly for text; JSON as data, keys in any order; CSV as
rows, whatever its line ending; not at all for exit 2, where the brief says nothing about it); whether standard error is
empty; for a mistake in a file whose line the case pins (one mistake in the whole case) that standard error names the file and
the line; and, after each command, the lines of movements.txt (absent, or its non-empty lines, so a missing one is not
created), that movements.txt is byte for byte as it was when the command failed, and that catalog.txt and orders.txt are byte
for byte what they were. With a
closed output pipe (`stockroom stock | head -1`) only the exit status (0) and "standard error stays empty" are compared.

Left open by the brief and therefore never generated or compared: the wording of any message, column padding, the type of
`delta` in `history --json` (-3 or "-3"), what exit 2 prints, line
terminators other than LF and CRLF (a lone CR, a form feed, U+2028, ...: not a line end here, and not put in a file), whitespace
other than spaces and tabs, a leading zero or a sign on a price or a reorder level, `12.` or `.5` as a price, year 0000, an empty
fifth catalogue field, an empty or space-padded note passed to `receive` / `ship`, leading whitespace on a movement or order
line, two kinds of mistake in one file or one case where the line named matters (which is reported first), a data file that
cannot be read next to one with a mistake (which is reported first), `--dir` given twice or followed by an option, `--format=csv`,
`--help`, two orders with the same number written differently and on the same date in a `report`, and pipes closed
under a command that writes a file.

PROVENANCE (#621): this is a BLIND generator. It was written from this fixture's brief (bench/fixture-medium/brief.md) and its
reference implementation (bench/fixture-medium/reference/) only, before any arm had run on this fixture: no arm's output, bug or
divergence shaped it, and it reads none. A change to it is a different measurement (see FROZEN_HASH) and must keep that
property: write it from the brief and the reference, never from what an arm got wrong.

The generator is FROZEN: its own splitmix64 PRNG (no `random` module, so Python's version cannot change it), SEED and the
SHA-256 of the case list (FROZEN_HASH). Change it and this refuses to run until SEED / FROZEN_HASH are updated on purpose; that
is a different measurement, so re-grade the runs you compare. Stdlib only.
"""
import argparse
import csv
import datetime
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE_DIR = os.path.join(HERE, "reference")

PROVENANCE = ("blind: written from the brief and the reference implementation only, committed (#621) before any arm "
              "had run on this fixture; no arm output informed it")
SEED = 621
CASES = 1000
CAP_S = 600
RUN_TIMEOUT = 20            # one command of a case
CASE_S = 90                 # all the commands of one case, then the rest count as timed out
WORKERS = 4
CHUNK = 16
MAX_EXAMPLES = 10
FROZEN_HASH = "dadc646bc2e0c241c8dde733be0f4c09da016eba2e7319c0e5d24dcf3537a0f1"

M64 = 0xFFFFFFFFFFFFFFFF
CATALOG, MOVEMENTS, ORDERS = "catalog.txt", "movements.txt", "orders.txt"
BOX = "box"                 # the folder a case names with --dir


class Rng:
    """splitmix64: the same stream on every Python."""

    def __init__(self, seed):
        self.x = seed & M64
        self.quirky = False             # a case writes its files in odd ways (tabs, CRLF, ...) only when this is set

    def next(self):
        self.x = (self.x + 0x9E3779B97F4A7C15) & M64
        z = self.x
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        return z ^ (z >> 31)

    def below(self, n):
        return self.next() % n

    def pct(self, p):
        return self.below(100) < p

    def span(self, lo, hi):
        return lo + self.below(hi - lo + 1)

    def pick(self, seq):
        return seq[self.below(len(seq))]

    def shuffle(self, seq):
        seq = list(seq)
        for i in range(len(seq) - 1, 0, -1):
            j = self.below(i + 1)
            seq[i], seq[j] = seq[j], seq[i]
        return seq

    def sample(self, seq, n):
        return self.shuffle(seq)[:n]


def case_hash(cases):
    blob = json.dumps(cases, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(blob.encode("ascii")).hexdigest()


# --- the tables the cases are made from -------------------------------------------------------
PREFIXES = ["AB", "CD", "EF", "GH", "IJ", "KL", "MN", "OP", "QRS", "TUV", "WXYZ", "AX", "ZZ", "GN", "TO", "BOX"]
DIGITS = ["100", "205", "310", "001", "999", "123", "456", "750", "010", "500", "777"]
NAMES = ["Garden gnome", "Seed packet, mix", "Gift voucher", "Café lamp", "日本 tea", "Ünï box", "Watering can",
         "Bird feeder #2", "Ceramic pot (large)", "Two  spaces", "Plant label \"oak\"", "Rake & hoe", "O'Brien mug",
         "Tea-towel", "A", "Name with 'quotes'", "100% cotton", "Soil 20L", "Gnome — deluxe", "Trowel: steel"]
# pennies; many of them put a half penny into a 5 % or 10 % discount, a 3 % discount or a 5 % tax
PRICES = [1, 5, 10, 13, 15, 25, 50, 55, 99, 101, 105, 133, 150, 199, 250, 333, 999, 1000, 1050, 1250, 1999, 2500, 4999,
          5000, 9999, 12345, 25000, 50000, 99999]
HALF_PRICES = [1, 5, 13, 15, 25, 35, 45, 55, 65, 75, 85, 95, 101, 105, 115, 125, 135, 145, 333, 1001, 1005, 2605]
TAXES = ["standard", "standard", "standard", "reduced", "reduced", "zero"]
REORDERS = [0, 0, 1, 2, 3, 5, 5, 10, 20, 40]
QTYS = [1, 2, 3, 4, 5, 9, 10, 11, 12, 19, 20, 24, 25, 49, 50, 51, 60, 99, 100, 101, 250, 1000]
HALF_QTYS = [10, 11, 19, 20, 50, 51, 55, 60, 150]
EDGE_QTYS = [9, 10, 11, 49, 50, 51]
FQTYS = [1, 2, 3, 5, 8, 10, 12, 20, 50]
IN_QTYS = [1, 2, 3, 5, 8, 10, 12, 20, 25, 40, 60, 100]
NOTES = ["", "", "", "", "first delivery", "restock", "damaged", "returned", "# not a comment", "a|b", "two  spaces",
         "Zoë's delivery", "日本 order", "order", "order SO", "x", "shipped by van"]
ORDER_IDS = ["SO-1001", "SO-1002", "SO-1003", "SO-7", "SO-007", "SO-10", "SO-9", "SO-100", "SO-2", "SO-12", "SO-00042"]
CUSTOMERS = ["acme", "Bea", "Zoë", "日本", "O'Brien", "a,b", "say\"hi\"", "#x", "Mr.Smith", "x", "ACME", "Q"]
COMMENTS = ["# a comment", "#", "  # indented comment", "\t# tab comment", "# AB-100 | bad | -1 | x", "# 2024-02-30 ZZ-1 0",
            "#no space", "# Café — ünï 日本", "# SO-1 2024-01-01 a ZZ-9*0"]
WS_SEPS = [" "] * 6 + ["  ", "\t", " \t ", "   "]
CAT_SEPS = [" | "] * 4 + ["|", " |", "| ", "  |  ", "\t|\t"]
BAD_DATES = ["2024-02-30", "2023-02-29", "2024-13-01", "2024-00-10", "2024-03-00", "2024-3-1", "2024-03-1", "24-03-01",
             "2024/03/01", "20240301", "2024-04-31", "2024-06-31", "2024-02-31", "2100-02-29", "2024-1-01", "March 1",
             "2024-03-01x", "tomorrow", "2024-W10-1", "01-03-2024"]
EDGE_DATES = ["2024-02-29", "2024-12-31", "2023-12-31", "2025-01-01", "2024-03-01", "2024-01-01", "2000-02-29",
              "2024-02-28", "2024-04-30", "2024-01-31"]
BAD_QTYS = ["0", "+0", "-0", "1.5", "abc", "5x", "--3", "+-3", "++5", "1,000", "-5", "-1", "+5", "-", "+", "x5", "0.5", "1/2"]
BAD_SKUS = ["QQ-999", "AB-1000", "AB100", "abc", "A-100", "ABCDE-100", "AB-10", "AB_100", "-AB-100", "AB-", "1B-100", "AB-1A0"]
REFUSED_NOTES = ["line1\nline2", "a\r\nb", "x\ny z", "\nlead"]
ARG_NOTES = ["first delivery", "order SO-1001", "with # hash", "two  spaces", "日本 note", "a|b", "--json", "-x", "-", "--dir2",
             "restock", "# note", "Zoë", "delivery 3 of 4", "a\tb"]


def D(n):
    return datetime.date(2024, 1, 1) + datetime.timedelta(days=n)


def iso(d):
    return d.isoformat()


PLAIN_NAMES = ["Garden gnome", "Seed packet, mix", "Gift voucher", "Watering can", "Ceramic pot (large)", "Rake & hoe", "Tea-towel",
               "A", "Soil 20L", "Trowel: steel"]
PLAIN_CUSTOMERS = ["acme", "Bea", "Mr.Smith", "x", "ACME", "Q"]
PLAIN_NOTES = ["", "", "", "", "first delivery", "restock", "damaged", "returned", "shipped by van"]


def name_of(r):
    return r.pick(NAMES if r.quirky else PLAIN_NAMES)


def customer_of(r):
    return r.pick(CUSTOMERS if r.quirky else PLAIN_CUSTOMERS)


def note_of(r):
    return r.pick(NOTES if r.quirky else PLAIN_NOTES)


def variant(r, s):
    """The same SKU or order number in another case (in a quirky case)."""
    return r.pick([s, s, s.lower(), s.capitalize(), s.swapcase()]) if r.quirky else s


def money_text(r, p):
    whole, frac = divmod(p, 100)
    if not r.quirky:
        return "%d.%02d" % (whole, frac)
    if frac == 0:
        return r.pick(["%d" % whole, "%d.00" % whole, "%d.0" % whole])
    if frac % 10 == 0:
        return r.pick(["%d.%d" % (whole, frac // 10), "%d.%02d" % (whole, frac)])
    return "%d.%02d" % (whole, frac)


def tax_text(r, prod):
    if prod["omit_tax"]:
        return None
    return r.pick([prod["tax"], prod["tax"], prod["tax"].title(), prod["tax"].upper()]) if r.quirky else prod["tax"]


def make_products(r, n, prices=None, taxes=None):
    seen, out = set(), []
    while len(out) < n:
        sku = r.pick(PREFIXES) + "-" + r.pick(DIGITS)
        if sku in seen:
            continue
        seen.add(sku)
        pennies = r.pick(prices) if prices else (r.pick(PRICES) if r.pct(70) else r.span(1, 30000))
        tax = r.pick(taxes) if taxes else r.pick(TAXES)
        out.append({"sku": sku, "name": name_of(r), "p": pennies, "reorder": r.pick(REORDERS), "tax": tax,
                    "omit_tax": tax == "standard" and r.pct(40)})
    return out


# --- rendering the three files -----------------------------------------------------------------
def gap(r, mixed):
    return r.pick(WS_SEPS) if mixed else " "


def product_line(r, p):
    sep = r.pick(CAT_SEPS) if r.quirky and r.pct(40) else " | "
    f = [variant(r, p["sku"]), p["name"], money_text(r, p["p"]), str(p["reorder"])]
    t = tax_text(r, p)
    if t is not None:
        f.append(t)
    line = sep.join(f)
    if r.quirky and r.pct(25):
        line = r.pick(["  ", "\t", " "]) + line + r.pick(["", " ", "\t", "  "])
    return line


def move_line(r, m):
    q = m["qty"]
    qt = ("%+d" % q) if (q < 0 or r.pct(50)) else str(q)
    parts = [iso(m["date"]), variant(r, m["sku"]), qt] + ([m["note"]] if m["note"] else [])
    line, mixed = parts[0], r.quirky and r.pct(40)
    for part in parts[1:]:
        line += gap(r, mixed) + part
    if m["note"] and r.quirky:
        line += r.pick(["", "", "", " ", "\t", "  "])
    return line


def order_line(r, o):
    pieces = ",".join("%s*%d" % (variant(r, s), q) for s, q in o["lines"])
    mixed = r.quirky and r.pct(40)
    return o["id_text"] + gap(r, mixed) + iso(o["date"]) + gap(r, mixed) + o["customer"] + gap(r, mixed) + pieces


def style(r, plain=False):
    if plain:
        return {"eol": "lf", "bom": False, "final": True, "blank": 0, "comment": 0}
    if not r.quirky:
        return {"eol": "lf", "bom": False, "final": True, "blank": 0, "comment": 0}
    return {"eol": r.pick(["lf"] * 4 + ["crlf"] * 3 + ["mixed"]), "bom": r.pct(15), "final": r.pct(65),
            "blank": r.pick([0, 15, 40]), "comment": r.pick([0, 15, 40])}


def assemble(r, lines, st):
    """The bytes of a file from its data lines: comment and blank lines in between, the line ends, a byte order mark."""
    out = []
    for line in lines:
        while r.pct(st["blank"]):
            out.append(r.pick(["", "", "  ", "\t"]))
        while r.pct(st["comment"]):
            out.append(r.pick(COMMENTS))
        out.append(line)
    if r.pct(st["blank"]):
        out.append(r.pick(["", "  "]))
    if r.pct(st["comment"]):
        out.append(r.pick(COMMENTS))
    text = ""
    for i, line in enumerate(out):
        text += line
        last = i == len(out) - 1
        if last and not st["final"]:
            break
        text += "\r\n" if st["eol"] == "crlf" or (st["eol"] == "mixed" and r.pct(50)) else "\n"
    data = text.encode("utf-8")
    return (b"\xef\xbb\xbf" + data) if st["bom"] else data


def file_set(r, world, plain=False, which="cmo", moves_absent=0, orders_absent=0, cat_lines=None, mov_lines=None,
             ord_lines=None):
    """{name: hex} for the files a case writes; a name left out is a file that is not there."""
    files = {}
    if "c" in which:
        lines = cat_lines if cat_lines is not None else [product_line(r, p) for p in world["products"]]
        files[CATALOG] = assemble(r, lines, style(r, plain)).hex()
    if "m" in which and not r.pct(moves_absent):
        lines = mov_lines if mov_lines is not None else [move_line(r, m) for m in world["moves"]]
        files[MOVEMENTS] = assemble(r, lines, style(r, plain)).hex()
    if "o" in which and not r.pct(orders_absent):
        lines = ord_lines if ord_lines is not None else [order_line(r, o) for o in world["orders"]]
        files[ORDERS] = assemble(r, lines, style(r, plain)).hex()
    return files


# --- the shelves and the orders ----------------------------------------------------------------
def timeline(r, p, count, start, spread):
    """Movements of one product that never take it below zero, dated start.. onwards, one day after another or the same day."""
    bal, d, out = 0, start, []
    for _ in range(count):
        d += r.below(spread)
        if bal == 0 or r.pct(45):
            q = r.pick(IN_QTYS)
        else:
            q = -bal if r.pct(25) else -r.span(1, bal)
        bal += q
        out.append({"date": D(d), "sku": p["sku"], "qty": q, "note": note_of(r)})
    if r.pct(55):                       # end on, just under or just over the reorder level, or on zero
        target = max(0, p["reorder"] + r.pick([-1, 0, 0, 1, 2])) if r.pct(80) else 0
        if target != bal:
            d += r.below(spread)
            out.append({"date": D(d), "sku": p["sku"], "qty": target - bal, "note": note_of(r)})
    return out


def order_note(r, oid):
    """The note of a shipment of order `oid`: mostly exactly what `fulfil` writes, sometimes something that is not."""
    n = int(oid[3:]) if oid[3:].isdigit() else 0
    if r.pct(65):
        return "order %s" % oid
    return r.pick(["order %s" % oid.lower(), "order %s again" % oid, "Order %s" % oid, "order  %s" % oid, "order %s." % oid,
                   "order SO-%d" % (n * 10 + 5), "for order %s" % oid, "order %s" % oid, "order %s" % oid])


def make_orders(r, prods, n, first=30, spread=60, qtys=None):
    orders = []
    ids = r.sample(ORDER_IDS, n)
    for oid in ids:
        picked = r.sample(prods, r.span(1, min(len(prods), 4)))
        lines = [(p["sku"], r.pick(qtys or FQTYS)) for p in picked]
        orders.append({"id": oid, "id_text": variant(r, oid), "date": D(first + r.below(spread)),
                       "customer": customer_of(r), "lines": lines})
    for o in orders:                    # two orders with one number are never on one day (a report's order is fixed by date, then number)
        for q in orders:
            if q is not o and int(q["id"][3:]) == int(o["id"][3:]) and q["date"] == o["date"]:
                q["date"] = q["date"] + datetime.timedelta(days=1)
    return orders


def merge_by_date(r, moves, shuffle_days=True):
    """File order: by date (each product's own order kept), and often the days themselves in another order, which does not
    change what the movements mean."""
    moves = sorted(moves, key=lambda m: m["date"])
    if shuffle_days and r.pct(35):
        days, order = {}, []
        for m in moves:
            days.setdefault(m["date"], []).append(m)
            if m["date"] not in order:
                order.append(m["date"])
        moves = [m for d in r.shuffle(order) for m in days[d]]
    return moves


def ledger(r, nprod=None, norders=None, moves=True):
    prods = make_products(r, nprod or r.span(2, 5))
    orders = make_orders(r, prods, r.span(1, 3) if norders is None else norders)
    mv = []
    if moves:
        for p in prods:
            mv += timeline(r, p, r.span(0, 6), r.below(20), 25)
        for m in mv:
            if m["qty"] < 0 and r.pct(35):
                cands = [o for o in orders if any(s == m["sku"] for s, _ in o["lines"])]
                if cands:
                    m["note"] = order_note(r, r.pick(cands)["id"])
            elif m["qty"] > 0 and r.pct(8) and orders:
                m["note"] = "order %s" % r.pick(orders)["id"]
        mv = merge_by_date(r, mv)
    return {"products": prods, "orders": orders, "moves": mv}


def order_of(r, lines, oid=None, date=40):
    oid = oid or r.pick(ORDER_IDS)
    return {"id": oid, "id_text": variant(r, oid), "date": D(date), "customer": customer_of(r),
            "lines": [(p["sku"], q) for p, q in lines]}


def pricing_lines(r, kind, tags):
    """[(product, quantity)] of one order, chosen so that the rounding the brief names is reached."""
    if kind == "plain":
        prods = make_products(r, r.span(1, 5))
        return [(p, r.pick(QTYS)) for p in prods]
    if kind == "volume":
        prods = make_products(r, r.span(1, 3), HALF_PRICES if r.pct(60) else None)
        tags.append("pricing:volume-edge")
        return [(p, r.pick(EDGE_QTYS) if r.pct(80) else r.pick(HALF_QTYS)) for p in prods]
    if kind == "half":
        prods = make_products(r, r.span(1, 4), HALF_PRICES)
        tags.append("pricing:half-penny")
        return [(p, r.pick(HALF_QTYS + QTYS)) for p in prods]
    if kind == "threshold":
        tags.append("pricing:threshold")
        total = r.pick([49999, 50000, 50000, 50001] if r.pct(55) else
                       [49900, 49998, 50002, 50050, 50049, 100000, 99999, 25000, 49950, 50100, 500000, 50050, 60050, 100050, 50150])
        lines, left = [], total
        for _ in range(r.span(0, 2)):
            q, price = r.span(1, 9), r.span(100, 30000)
            if q * price < left - 1:
                lines.append((q, price))
                left -= q * price
        lines.append((1, left))
        prods = make_products(r, len(lines), [price for _, price in lines])
        return [(p, q) for p, (q, _) in zip(prods, lines)]
    if kind == "tie":
        tags.append("pricing:tie")
        n = r.span(3, 8)
        q = r.pick([1, 2, 3, 4, 5, 7])
        least = -(-50000 // (n * q))                 # n equal lines of q at this price come to 500.00 or more
        price = least + r.below(least // 2 + 1) if r.pct(85) else max(1, r.span(6000, 60000) // q)
        prods = make_products(r, n, [price], ["standard", "standard", "standard", "reduced", "zero"])
        lines = [(p, q) for p in prods]
        if r.pct(40):                    # one odd line among the equal ones
            at = r.below(n)
            lines[at] = (prods[at], r.span(1, 9))
        return lines
    if kind == "taxes":
        tags.append("pricing:three-tax-classes")
        price = r.pick(HALF_PRICES + PRICES)
        prods = make_products(r, 3, [price], ["standard", "reduced", "zero"])
        for p, t in zip(prods, ["standard", "reduced", "zero"]):
            p["tax"], p["omit_tax"] = t, False
        q = r.pick(QTYS)
        return [(p, q if r.pct(60) else r.pick(QTYS)) for p in prods]
    if kind == "many":
        tags.append("pricing:many-lines")
        prods = make_products(r, r.span(6, 9), HALF_PRICES + PRICES)
        return [(p, r.pick(QTYS)) for p in prods]
    if kind == "big":
        tags.append("pricing:big-numbers")
        prods = make_products(r, r.span(1, 3), [99999, 5000000, 9999999, 123456, 7])
        return [(p, r.pick([100000, 99999, 12345, 1000000, 500])) for p in prods]
    prods = make_products(r, 1, HALF_PRICES + PRICES)
    return [(prods[0], r.pick(QTYS))]


PRICING_KINDS = ["plain", "volume", "half", "half", "threshold", "threshold", "threshold", "threshold", "threshold", "threshold", "tie", "tie",
                 "tie", "tie", "taxes", "many", "big"]


def pricing_world(r, tags):
    kind = r.pick(PRICING_KINDS)
    lines = pricing_lines(r, kind, tags)
    prods = [p for p, _ in lines]
    for e in make_products(r, r.span(0, 2)):
        if all(e["sku"] != p["sku"] for p in prods):
            prods.append(e)
    r2 = r.shuffle(prods)
    order = order_of(r, lines)
    others = []
    if r.pct(40):
        others = make_orders(r, r2, r.span(1, 2))
        others = [o for o in others if o["id"] != order["id"]]
    orders = others[:]
    orders.insert(r.below(len(orders) + 1), order)
    return {"products": r2, "orders": orders, "moves": []}, order, kind


def shipping(r, world, order, kinds=("partial", "all", "none")):
    """Movements that stock the order's products and ship part of the order the way `fulfil` writes it."""
    moves, d = [], order["date"] - datetime.timedelta(days=r.span(5, 25))
    for sku, q in order["lines"]:
        have = r.pick([q, q + 5, q + 40, max(1, q // 2), q + 1])
        moves.append({"date": d, "sku": sku, "qty": have, "note": note_of(r)})
        how = r.pick(kinds)
        sent = q if how == "all" else (r.span(1, max(1, q - 1)) if how == "partial" else 0)
        sent = min(sent, have)
        if sent > 0:
            moves.append({"date": order["date"] + datetime.timedelta(days=r.below(8)), "sku": sku, "qty": -sent,
                          "note": "order %s" % order["id"] if r.pct(90) else order_note(r, order["id"])})
    return merge_by_date(r, moves)


# --- command lines -----------------------------------------------------------------------------
def sku_arg(r, world, bad=8):
    if r.pct(bad):
        return r.pick(BAD_SKUS)
    return variant(r, r.pick(world["products"])["sku"])


def date_arg(r, bad=6, near=None):
    if r.pct(bad):
        return r.pick(BAD_DATES)
    if near is not None and r.pct(70):
        return iso(D(near + r.span(-3, 12)))
    return r.pick(EDGE_DATES) if r.pct(20) else iso(D(r.span(0, 120)))


def order_arg(r, world, bad=8):
    if r.pct(bad) or not world["orders"]:
        return r.pick(["SO-9999", "so-404", "SO-1", "xyz", "SO-", "SO-007x", "1001", "SO-00001"])
    return variant(r, r.pick(world["orders"])["id"])


def place_dir(r, argv, tags):
    """argv with `--dir box` first, after the command or last."""
    at = r.pick([0, min(1, len(argv)), len(argv)])
    tags.append("argv:dir-option")
    return argv[:at] + ["--dir", BOX] + argv[at:]


def read_cmd(r, world, shelves_only=False):
    k = r.below(9 if not shelves_only else 4)
    j = ["--json"] if r.pct(40) else []
    if k == 0:
        return ["stock"] + j
    if k == 1:
        return ["low"] + j
    if k == 2:
        return ["history", sku_arg(r, world, 4)] + j
    if k == 3:
        return ["history"] + j + [sku_arg(r, world, 4)]
    if k in (4, 5):
        return [r.pick(["quote", "invoice"]), order_arg(r, world, 5)] + j
    return ["report"] + r.pick([[], [], ["--format", "text"], ["--format", "csv"], ["--format", "json"]])


def balances(world):
    out = {}
    for m in world["moves"]:
        out[m["sku"]] = out.get(m["sku"], 0) + m["qty"]
    return out


def move_args(r, world, cmd, near=None):
    note = r.pick(ARG_NOTES) if r.pct(45) else None
    sku = sku_arg(r, world, 5)
    bal = balances(world).get(sku.upper(), 0)
    if r.pct(8):
        qty = r.pick(BAD_QTYS)
    elif cmd == "ship" and bal > 0 and r.pct(70):
        qty = str(r.pick([1, 1, 2, max(1, bal // 2), bal, bal, bal + 1]))
    else:
        qty = str(r.pick([1, 1, 2, 3, 5, 8, 10, 20, 40, 100, 500]))
    argv = [cmd, date_arg(r, 5, near), sku, qty]
    if note is not None:
        argv.append(note)
    elif r.pct(4):
        argv.append(r.pick(REFUSED_NOTES))
    return argv


def new_case(kind, files, steps, sub=None, closed=False, locate=None, tags=None):
    return {"kind": kind, "files": files, "sub": sub, "steps": steps, "closed_stdout": closed, "locate": locate,
            "tags": sorted(set(tags or []))}


def wrap_steps(r, steps, tags, dir_pct=10):
    """(steps, sub): some cases keep the files in a folder named by --dir, on each command."""
    if r.pct(dir_pct):
        return [place_dir(r, s, tags) for s in steps], BOX
    return steps, None


# --- the scenarios -----------------------------------------------------------------------------
def sc_shelves(r):
    tags = []
    w = ledger(r, norders=0)
    files = file_set(r, w, moves_absent=8)
    steps = [read_cmd(r, w, shelves_only=True) for _ in range(r.span(1, 3))]
    steps, sub = wrap_steps(r, steps, tags)
    return new_case("shelves", files, steps, sub, tags=tags)


def sc_stock_edges(r):
    """Levels exactly on, just above and just under the reorder level, on zero, with reorder 0."""
    tags = ["shelves:status-edges"]
    prods = make_products(r, r.span(3, 6))
    moves = []
    for i, p in enumerate(prods):
        want = r.pick([0, p["reorder"], p["reorder"] + 1, max(0, p["reorder"] - 1), p["reorder"] * 2, 7])
        if want:
            moves.append({"date": D(i), "sku": p["sku"], "qty": want, "note": note_of(r)})
        if r.pct(30) and want > 1:
            moves.append({"date": D(i + 30), "sku": p["sku"], "qty": -r.span(1, want), "note": ""})
    w = {"products": prods, "orders": [], "moves": merge_by_date(r, moves)}
    files = file_set(r, w, moves_absent=4)
    steps = [["stock"] + (["--json"] if r.pct(40) else []), ["low"] + (["--json"] if r.pct(40) else [])]
    return new_case("shelves", files, steps, tags=tags)


def sc_history(r):
    tags = ["shelves:history"]
    w = ledger(r, norders=0)
    files = file_set(r, w, moves_absent=5)
    steps = [["history", sku_arg(r, w, 6)] + (["--json"] if r.pct(45) else []) for _ in range(r.span(1, 3))]
    steps, sub = wrap_steps(r, steps, tags)
    return new_case("shelves", files, steps, sub, tags=tags)


def sc_receive_ship(r):
    tags = ["movements:receive-ship"]
    w = ledger(r, r.span(1, 4), norders=0)
    files = file_set(r, w, moves_absent=12)
    steps = []
    for _ in range(r.span(1, 4)):
        cmd = r.pick(["receive", "ship", "ship"])
        last = max([(m["date"] - D(0)).days for m in w["moves"]] + [0])
        steps.append(move_args(r, w, cmd, near=last + r.span(-8, 20)))
        if r.pct(55):
            steps.append(r.pick([["history", sku_arg(r, w, 0)], ["stock"], ["low"], ["history", sku_arg(r, w, 0), "--json"]]))
    steps = steps[:6]
    steps, sub = wrap_steps(r, steps, tags, 12)
    return new_case("receive_ship", files, steps, sub, tags=tags)


def sc_stock_rule(r):
    """Shipments and receipts dated before, between and after what is on file: the rule is in date order, not file order."""
    tags = ["movements:date-order-rule"]
    prods = make_products(r, 2)
    a = prods[0]["sku"]
    base = r.span(10, 30)
    moves = [{"date": D(base), "sku": a, "qty": 10, "note": "in"},
             {"date": D(base + 10), "sku": a, "qty": -r.pick([4, 6, 10]), "note": "out"}]
    if r.pct(50):
        moves.append({"date": D(base + 10), "sku": a, "qty": r.pick([3, 5]), "note": "same day in"})
    w = {"products": prods, "orders": [], "moves": merge_by_date(r, moves, False)}
    files = file_set(r, w, plain=r.pct(50))
    steps = []
    for _ in range(r.span(2, 4)):
        cmd = r.pick(["receive", "ship", "ship"])
        d = r.pick([base - 1, base, base + 1, base + 5, base + 10, base + 11, base + 30])
        q = r.pick([1, 2, 3, 4, 5, 6, 7, 10, 11, 12])
        steps.append([cmd, iso(D(d)), r.pick([a, a.lower()]), str(q)] + ([r.pick(ARG_NOTES)] if r.pct(30) else []))
        if r.pct(40):
            steps.append(["history", a])
    steps, sub = wrap_steps(r, steps[:6], tags, 8)
    return new_case("receive_ship", files, steps, sub, tags=tags)


def sc_quote(r):
    tags = []
    w, order, kind = pricing_world(r, tags)
    files = file_set(r, w, which="co", orders_absent=0)
    if r.pct(50):
        files.update(file_set(r, {"moves": [], "products": [], "orders": []}, which="m"))
    steps = []
    for _ in range(r.span(1, 2)):
        o = order if r.pct(75) else r.pick(w["orders"])
        steps.append(["quote", variant(r, o["id"])] + (["--json"] if r.pct(45) else []))
    steps, sub = wrap_steps(r, steps, tags, 6)
    return new_case("quote", files, steps, sub, tags=tags)


def later_sales(r, moves, order, when, tags):
    """A sale after `when` that leaves a few units of a product of the order: what can ship now is what the shelves still have then."""
    for sku, _ in order["lines"]:
        if r.pct(50):
            mine = [m for m in moves if m["sku"] == sku]
            left = sum(m["qty"] for m in mine)
            if left >= 2:
                last = max([m["date"] for m in mine] + [D(when)])
                dip = last + datetime.timedelta(days=r.span(1, 9))
                moves.append({"date": dip, "sku": sku, "qty": r.span(0, min(3, left - 1)) - left,
                              "note": r.pick(["later sale", "", "order SO-9999"])})
                if r.pct(60):                # and the shelves fill up again: the dip is what limits the shipment, not the end
                    moves.append({"date": dip + datetime.timedelta(days=r.span(1, 9)), "sku": sku, "qty": r.span(1, 40),
                                  "note": "restock"})
                tags.append("fulfil:later-movements")


def sc_fulfil(r):
    tags = ["fulfil:order"]
    w = ledger(r, r.span(2, 4), r.span(1, 3))
    o = r.pick(w["orders"])
    od = (o["date"] - D(0)).days
    last = max([(m["date"] - D(0)).days for m in w["moves"]] + [od])
    when = r.pick([od, od + 1, od + 3, od + 10, od + 40, last, last + 1, od - 1, od + 2, max(0, last - 5), od + 20])
    if r.pct(60):
        later_sales(r, w["moves"], o, when, tags)
        w["moves"] = merge_by_date(r, w["moves"])
    files = file_set(r, w, moves_absent=3)
    if when < od:
        tags.append("fulfil:before-order-date")
    if any(m["note"].startswith("order") and m["qty"] < 0 for m in w["moves"]):
        tags.append("fulfil:earlier-shipments")
    if any((m["date"] - D(0)).days > when for m in w["moves"]):
        tags.append("fulfil:later-movements")
    script = r.below(8)
    f = lambda oo, d: ["fulfil", variant(r, oo["id"]), iso(D(d))]
    if script == 0:
        steps = [f(o, when), ["invoice", o["id"]], ["report"]]
    elif script == 1:
        steps = [f(o, when), f(o, when), ["report", "--format", "csv"]]
    elif script == 2:
        steps = [["invoice", o["id"]], f(o, when), ["invoice", o["id"], "--json"]]
    elif script == 3:
        o2 = r.pick(w["orders"])
        steps = [f(o, when), f(o2, when + r.below(5)), ["stock"], ["report", "--format", "json"]]
        tags.append("fulfil:two-orders-one-stock")
    elif script == 4:
        s = r.pick(o["lines"])
        steps = [f(o, when), ["receive", iso(D(when + 1)), s[0], str(r.span(1, 60)), "restock"], f(o, when + 2), ["report"]]
    elif script == 5:
        s = r.pick(o["lines"])
        steps = [["ship", iso(D(when)), s[0], str(r.span(1, 5)), "order %s" % o["id"]], ["invoice", o["id"]], f(o, when),
                 ["invoice", o["id"]]]
        tags.append("fulfil:shipped-by-hand")
    elif script == 6:
        steps = [f(o, when), ["history", r.pick(o["lines"])[0]], f(o, when + r.span(0, 9)), ["quote", o["id"]]]
    else:
        steps = [f(o, when), f(o, when + r.span(1, 30)), ["invoice", o["id"]]]
    steps, sub = wrap_steps(r, steps, tags, 6)
    return new_case("fulfil", files, steps, sub, tags=tags)


def sc_fulfil_shortfall(r):
    """One order, stock and earlier shipments chosen so that it ships short, in full, over-shipped or not at all."""
    tags = ["fulfil:shortfall"]
    prods = make_products(r, r.span(2, 4), HALF_PRICES + PRICES)
    lines = [(p, r.pick(FQTYS)) for p in prods[:r.span(1, len(prods))]]
    order = order_of(r, lines, date=r.span(20, 50))
    od = (order["date"] - D(0)).days
    moves = shipping(r, None, order, ("partial", "all", "none", "none"))
    for p in prods:
        if r.pct(40):
            moves.append({"date": D(od + r.span(1, 20)), "sku": p["sku"], "qty": -1, "note": r.pick(["gift", "sample", ""])})
            moves.append({"date": D(od - 20), "sku": p["sku"], "qty": 200, "note": "bulk in"})
    moves = [m for m in merge_by_date(r, moves, False)]
    when = od + r.pick([0, 0, 1, 5, 12, 30])
    later_sales(r, moves, order, when, tags)
    w = {"products": prods, "orders": [order], "moves": merge_by_date(r, moves, False)}
    files = file_set(r, w)
    steps = [["fulfil", order["id"], iso(D(when))], ["invoice", order["id"]], ["report"]]
    if r.pct(40):
        steps.insert(1, ["fulfil", order["id"], iso(D(when + 3))])
    return new_case("fulfil", files, steps, tags=tags)


def sc_invoice_report(r):
    tags = ["orders:invoice-report"]
    w = ledger(r, r.span(2, 5), r.span(2, 4))
    keep = []
    for o in w["orders"]:
        keep += shipping(r, w, o, ("partial", "all", "none"))
    w["moves"] = merge_by_date(r, keep)
    # several orders can stock one product; the file stays valid because each shipment is covered by its own receipt
    files = file_set(r, w)
    steps = []
    for o in r.sample(w["orders"], r.span(1, len(w["orders"]))):
        steps.append([r.pick(["invoice", "invoice", "quote"]), variant(r, o["id"])] + (["--json"] if r.pct(45) else []))
    steps.append(["report"] + r.pick([[], ["--format", "text"], ["--format", "csv"], ["--format", "json"]]))
    if r.pct(40):
        steps.append(["report"] + r.pick([[], ["--format", "csv"], ["--format", "json"]]))
    if r.pct(25):
        steps.append(["invoice", order_arg(r, w, 100)])
    steps, sub = wrap_steps(r, steps, tags, 6)
    return new_case("invoice_report", files, steps, sub, tags=tags)


def sc_report_order(r):
    """Many orders, other dates than the file order, SO-9 against SO-10, every status, an empty orders file."""
    tags = ["orders:report-order"]
    prods = make_products(r, 3, HALF_PRICES + PRICES)
    ids = r.sample(["SO-9", "SO-10", "SO-100", "SO-2", "SO-1001", "SO-12", "SO-7", "SO-30"], r.span(3, 6))
    orders, moves = [], []
    for oid in ids:
        lines = [(p, r.pick(FQTYS)) for p in r.sample(prods, r.span(1, 3))]
        o = order_of(r, lines, oid, date=r.pick([10, 10, 11, 12, 20, 25, 25]))
        orders.append(o)
        moves += shipping(r, None, o, ("partial", "all", "none", "none"))
    w = {"products": prods, "orders": orders, "moves": merge_by_date(r, moves)}
    files = file_set(r, w)
    if r.pct(8):
        files[ORDERS] = assemble(r, [], style(r)).hex()
        tags.append("orders:empty-file")
    steps = [["report", "--format", f] if f else ["report"] for f in r.sample(["", "csv", "json", "text"], r.span(1, 3))]
    return new_case("invoice_report", files, steps, tags=tags)


# --- mistakes in the three files ---------------------------------------------------------------
def bad_catalog_line(r, prods):
    """(kind, line) for one mistake of the catalogue."""
    sep = " | "
    fresh = "NP-" + r.pick(["001", "002", "003", "004"])      # a SKU no product has: the mistake is the only fault on its line
    good = lambda: [fresh, "A name", "2.50", "3", "standard"]
    kind = r.pick(["fields-few", "fields-many", "sku", "duplicate", "name", "price", "reorder", "tax", "name-with-pipe", "single-word"])
    f = good()
    if kind == "fields-few":
        return kind, sep.join(f[:r.pick([1, 2, 3])]) if r.pct(70) else "AB-777 | Nameless | 2.00"
    if kind == "fields-many":
        return kind, sep.join(f + [r.pick(["extra", "", "1"])])
    if kind == "sku":
        f[0] = r.pick(["A-100", "ABCDE-100", "AB100", "AB-10", "AB-1000", "AB_100", "A1-100", "AB-1A0", "-100", "AB-", "ab 100",
                       "AB - 100", "1234", "AB-100x"])
        return kind, sep.join(f)
    if kind == "duplicate":                 # the caller repeats a product that is really there
        return kind, sep.join(f)
    if kind == "name":
        f[1] = ""
        return kind, sep.join(f[:r.pick([4, 5])])
    if kind == "price":
        f[2] = r.pick(["12.505", "1,000.00", "-3", "abc", "0", "0.00", "0.0", "0.001", "", "$5", "1.2.3", "5 EUR", "12.345"])
        return kind, sep.join(f)
    if kind == "reorder":
        f[3] = r.pick(["-1", "2.5", "abc", "", "five", "1,0", "3x", "0.0"])
        return kind, sep.join(f)
    if kind == "tax":
        f[4] = r.pick(["standrd", "reduced1", "20%", "luxury", "high", "std", "0", "zero rated", "none"])
        return kind, sep.join(f)
    if kind == "name-with-pipe":
        return kind, "AB-888 | Nuts | bolts | 1.00 | 5 | zero"
    return kind, r.pick(["gizmo", "AB-100", "just some words here"])


def bad_movement_line(r, w):
    sku = r.pick(w["products"])["sku"]
    d = iso(D(r.span(0, 60)))
    kind = r.pick(["fields", "date", "sku", "quantity", "quantity", "date-only"])
    if kind == "fields":
        return kind, r.pick(["%s %s" % (d, sku), "%s %s" % (sku, "+5"), "%s" % d, "%s %s" % (sku, d)])
    if kind == "date":
        return kind, "%s %s +5 note" % (r.pick(BAD_DATES), sku)
    if kind == "sku":
        return kind, "%s %s +5" % (d, r.pick(BAD_SKUS))
    if kind == "quantity":
        return kind, "%s %s %s" % (d, sku, r.pick(["0", "+0", "-0", "1.5", "abc", "5x", "--3", "+-3", "1,000", "0.5", "x5"]))
    return kind, "%s" % d


def sc_mistake_catalog(r):
    kind_tags = []
    w = ledger(r)
    kind, line = bad_catalog_line(r, w["products"])
    lines = [product_line(r, p) for p in w["products"]]
    if kind == "duplicate":                # it has to come after the product it repeats, which is the first one
        line = "%s | A name | 2.50 | 3 | standard" % r.pick([w["products"][0]["sku"], w["products"][0]["sku"].lower()])
        lines.insert(r.span(1, len(lines)), line)
    else:
        lines.insert(r.below(len(lines) + 1), line)
    kind_tags += ["mistake:catalog-" + kind, "mistake:data-file"]
    files = file_set(r, w, cat_lines=lines)
    cmd = read_cmd(r, w) if r.pct(75) else [r.pick(["stock", "low"])]
    steps = [cmd]
    if cmd[0] in ("history", "quote", "invoice") and r.pct(50):
        steps.append(["stock"])
    steps, sub = wrap_steps(r, steps, kind_tags, 6)
    return new_case("mistake", files, steps, sub, locate=CATALOG, tags=kind_tags)


def sc_mistake_movements(r):
    w = ledger(r)
    mv_lines = [move_line(r, m) for m in w["moves"]]
    tags = []
    pick = r.below(8)
    if pick < 4:
        kind, line = bad_movement_line(r, w)
        mv_lines.insert(r.below(len(mv_lines) + 1), line)
        tags.append("mistake:movements-" + kind)
    else:
        # the stock rule, broken in one place: the line that takes a product below zero is the one named
        free = [p for p in w["products"] if all(m["sku"] != p["sku"] for m in w["moves"])]
        kind = ["over", "early", "same-day", "over"][pick - 4]
        total = {}
        for m in w["moves"]:
            total[m["sku"]] = total.get(m["sku"], 0) + m["qty"]
        if kind == "same-day" and free:
            sku, day = free[0]["sku"], iso(D(r.span(0, 60)))
            at = r.below(len(mv_lines) + 1)
            mv_lines[at:at] = ["%s %s -%d" % (day, sku, r.span(1, 3)), "%s %s +%d" % (day, sku, r.span(3, 9))]
        elif kind == "early" and w["moves"]:
            m0 = min(w["moves"], key=lambda m: m["date"])
            sku = m0["sku"]
            mv_lines.insert(r.below(len(mv_lines) + 1), "%s %s -1" % (iso(m0["date"] - datetime.timedelta(days=r.span(1, 5))), sku))
        else:
            kind = "over"
            sku = r.pick(w["products"])["sku"]
            last = max([m["date"] for m in w["moves"]] + [D(10)])
            mv_lines.append("%s %s -%d" % (iso(last + datetime.timedelta(days=r.below(4))), sku, total.get(sku, 0) + r.span(1, 4)))
        tags.append("mistake:movements-stock-" + kind)
    tags.append("mistake:data-file")
    files = file_set(r, w, mov_lines=mv_lines)
    steps = [read_cmd(r, w) if r.pct(60) else [r.pick(["stock", "low"])]]
    steps, sub = wrap_steps(r, steps, tags, 5)
    return new_case("mistake", files, steps, sub, locate=MOVEMENTS, tags=tags)


def bad_order_line(r, w):
    p = r.pick(w["products"])["sku"]
    o = r.pick(w["orders"])
    d = iso(D(r.span(0, 60)))
    kind = r.pick(["fields", "id", "id", "duplicate", "date", "lines-space", "lines-empty", "lines-unknown", "lines-shape",
                   "quantity", "quantity", "twice", "customer"])
    if kind == "fields":
        return kind, r.pick(["SO-50 %s acme" % d, "SO-50 %s" % d, "SO-50"])
    if kind == "id":
        return kind, "%s %s acme %s*1" % (r.pick(["SO7", "SO-", "S0-7", "SX-7", "SO-7a", "ORDER-1", "so_7", "7", "SO--7"]), d, p)
    if kind == "duplicate":
        return kind, "%s %s acme %s*1" % (r.pick([o["id"], o["id"].lower(), o["id"].title()]), d, p)
    if kind == "date":
        return kind, "SO-60 %s acme %s*1" % (r.pick(BAD_DATES), p)
    if kind == "lines-space":
        return kind, r.pick(["SO-60 %s acme %s*1, %s*2" % (d, p, p), "SO-60 %s acme %s*1 ,%s*2" % (d, p, p),
                             "SO-60 %s acme %s *1" % (d, p)])
    if kind == "lines-empty":
        return kind, "SO-60 %s acme %s" % (d, r.pick(["%s*1,,%s*2" % (p, p), "%s*1," % p, ",%s*1" % p, ","]))
    if kind == "lines-unknown":
        return kind, "SO-60 %s acme %s*1" % (d, r.pick(BAD_SKUS))
    if kind == "lines-shape":
        return kind, "SO-60 %s acme %s" % (d, r.pick([p, p + ":2", p + "x2", "*2", p + "**2", "2*" + p]))
    if kind == "quantity":
        return kind, "SO-60 %s acme %s*%s" % (d, p, r.pick(["0", "-3", "+3", "abc", "1.5", "", "2x", "0.5", "00"]))
    if kind == "twice":
        return kind, "SO-60 %s acme %s*1,%s*2" % (d, p, r.pick([p, p.lower()]))
    return kind, "SO-60 %s John Smith %s*1" % (d, p)


def sc_mistake_orders(r):
    w = ledger(r, norders=r.span(1, 3))
    lines = [order_line(r, o) for o in w["orders"]]
    kind, line = bad_order_line(r, w)
    at = r.below(len(lines) + 1)
    if kind == "duplicate":
        at = r.span(1, len(lines))
        line = "%s %s acme %s*1" % (r.pick([w["orders"][0]["id"], w["orders"][0]["id"].lower()]), iso(D(r.span(0, 60))),
                                     w["products"][0]["sku"])
    lines.insert(at, line)
    tags = ["mistake:orders-" + kind, "mistake:data-file"]
    files = file_set(r, w, ord_lines=lines)
    cmd = r.pick([["quote", w["orders"][0]["id"]], ["report"], ["invoice", w["orders"][0]["id"]],
                  ["fulfil", w["orders"][0]["id"], iso(D(70))]])
    steps = [cmd]
    steps, sub = wrap_steps(r, steps, tags, 5)
    return new_case("mistake", files, steps, sub, locate=ORDERS, tags=tags)


def sc_elsewhere(r):
    """A mistake in a file the command does not read is not its business; in one it does read, it is."""
    w = ledger(r, norders=r.span(1, 2))
    which = r.pick([MOVEMENTS, ORDERS, ORDERS, MOVEMENTS])
    mv = [move_line(r, m) for m in w["moves"]]
    od = [order_line(r, o) for o in w["orders"]]
    if which == ORDERS:
        od.insert(r.below(len(od) + 1), r.pick(["garbage here", "SO-1 2024-02-30 x AB-100*1", "SO-77 2024-03-03 acme QQ-999*1",
                                                 "SO-5 2024-03-03 acme"]))
    else:
        mv.insert(r.below(len(mv) + 1), r.pick(["garbage", "2024-02-30 AB-100 +1", "2024-03-03 QQ-999 +1", "2024-03-03 AB-100 0"]))
    files = file_set(r, w, mov_lines=mv, ord_lines=od)
    o = w["orders"][0]["id"]
    cmd = r.pick([["stock"], ["low"], ["history", w["products"][0]["sku"]], ["quote", o], ["quote", o, "--json"],
                  ["receive", iso(D(90)), w["products"][0]["sku"], "1", "n"], ["ship", iso(D(90)), w["products"][0]["sku"], "1"],
                  ["fulfil", o, iso(D(90))], ["invoice", o], ["report"], ["stock", "--json"]])
    tags = ["mistake:elsewhere-" + which[:-4], "command-reads-other-files"]
    return new_case("mistake", files, [cmd], tags=tags)


# --- file shapes, unreadable files, a closed pipe -------------------------------------------------
def sc_format(r):
    """Good files in every shape the brief allows."""
    r.quirky = True
    w = ledger(r, r.span(2, 4), r.span(1, 3))
    tags = ["format:shapes"]
    files = {}
    for name, key in ((CATALOG, "c"), (MOVEMENTS, "m"), (ORDERS, "o")):
        st = style(r)
        st["blank"], st["comment"] = r.pick([10, 30, 60]), r.pick([10, 30, 60])
        if name == CATALOG:
            lines = [product_line(r, p) for p in w["products"]]
        elif name == MOVEMENTS:
            lines = [move_line(r, m) for m in w["moves"]]
        else:
            lines = [order_line(r, o) for o in w["orders"]]
        files[name] = assemble(r, lines, st).hex()
    steps = [["stock"], ["history", w["products"][0]["sku"]], ["quote", w["orders"][0]["id"]]]
    if r.pct(40):
        steps.append(["report"])
    o = w["orders"][0]
    if r.pct(40):
        steps = [["fulfil", o["id"], iso(D(90))], ["stock"], ["invoice", o["id"]]]
    elif r.pct(40):
        steps = [["receive", iso(D(100)), w["products"][0]["sku"], "4", "later"], ["ship", iso(D(101)), w["products"][0]["sku"], "1"],
                 ["history", w["products"][0]["sku"]]]
    return new_case("format", files, steps, tags=tags)


def sc_edges_of_files(r):
    """Empty files, only comments, no products, one very long line."""
    tags = ["format:empty"]
    r.quirky = r.pct(50)
    w = ledger(r, 2, 1)
    which = r.below(5)
    files = file_set(r, w)
    if which == 0:
        files[CATALOG] = b"".hex()
        files.pop(MOVEMENTS, None)
        files.pop(ORDERS, None)
        tags.append("catalog:empty")
    elif which == 1:
        files[CATALOG] = assemble(r, [], dict(style(r), comment=100)).hex()
        files[MOVEMENTS] = b"".hex()
        files[ORDERS] = b"# none\n".hex()
    elif which == 2:
        files[MOVEMENTS] = b"# nothing yet\n\n   \n".hex()
    elif which == 3:
        files[MOVEMENTS] = b"".hex()
        files[ORDERS] = b"\n\n".hex()
    else:
        files[MOVEMENTS] = b"\xef\xbb\xbf".hex()
        files[ORDERS] = b"\xef\xbb\xbf# only a comment".hex()
    steps = [["stock"], ["stock", "--json"], ["low"], ["low", "--json"], ["report"], ["report", "--format", "csv"],
             ["report", "--format", "json"]]
    steps = r.sample(steps, 3)
    if which != 0 and r.pct(40):
        steps += [["receive", iso(D(5)), w["products"][0]["sku"], "2", "first"], ["history", w["products"][0]["sku"]]]
    if which == 0 and r.pct(40):
        steps.append(["history", w["products"][0]["sku"]])
    return new_case("format", files, steps, tags=tags)


BAD_BYTES = [b"\xff", b"\xc3\x28", b"\xe2\x82", b"\xed\xa0\x80", b"\x80", b"\xfe\xff", b"\xf0\x28\x8c\x28", b"\xc0\xaf"]


def sc_unreadable(r):
    tags = []
    w = ledger(r, norders=r.span(1, 2))
    files = file_set(r, w)
    which = r.below(7)
    steps = None
    if which == 0:
        files.pop(CATALOG)
        tags.append("catalog:missing")
    elif which == 1:
        files[CATALOG] = (bytes.fromhex(files[CATALOG]) + b"# " + r.pick(BAD_BYTES) + b"\n").hex()
        tags.append("catalog:invalid-utf8")
    elif which == 2:
        files[MOVEMENTS] = (bytes.fromhex(files[MOVEMENTS]) + b"# " + r.pick(BAD_BYTES) + b"\n").hex() if MOVEMENTS in files \
            else (b"\xff\xfe").hex()
        tags.append("movements:invalid-utf8")
    elif which == 3:
        files[ORDERS] = (bytes.fromhex(files[ORDERS]) + r.pick(BAD_BYTES)).hex()
        tags.append("orders:invalid-utf8")
    elif which == 4:
        files[CATALOG] = ("\n".join(product_line(r, p) for p in w["products"])).encode("utf-16")
        files[CATALOG] = files[CATALOG].hex()
        tags.append("catalog:utf-16")
    elif which == 5:
        tags.append("argv:dir-missing")
        steps = [["--dir", "nowhere"] + read_cmd(r, w)]
        if r.pct(50):
            steps = [read_cmd(r, w) + ["--dir", r.pick(["nowhere", "no/such/folder", "box2"])]]
    else:
        files.pop(MOVEMENTS, None)
        files.pop(ORDERS, None)
        tags.append("movements:missing")
        steps = [r.pick([["stock"], ["low"], ["report"], ["quote", w["orders"][0]["id"]], ["invoice", w["orders"][0]["id"]],
                         ["fulfil", w["orders"][0]["id"], iso(D(90))], ["history", w["products"][0]["sku"]],
                         ["receive", iso(D(3)), w["products"][0]["sku"], "5"], ["ship", iso(D(3)), w["products"][0]["sku"], "1"]]),
                 ["stock"]]
    if which != 6:
        tags.append("file:unreadable")
    if steps is None:
        steps = [read_cmd(r, w) for _ in range(r.span(1, 2))]
        if r.pct(40):
            steps = [r.pick([["stock"], ["low"], ["quote", w["orders"][0]["id"]], ["report"], ["history", w["products"][0]["sku"]],
                             ["ship", iso(D(3)), w["products"][0]["sku"], "1"], ["fulfil", w["orders"][0]["id"], iso(D(90))],
                             ["invoice", w["orders"][0]["id"]]])]
    return new_case("unreadable", files, steps, tags=tags)


def sc_closed_pipe(r):
    tags = ["output:closed-pipe"]
    w = ledger(r, r.span(2, 5), r.span(1, 3))
    files = file_set(r, w)
    j = ["--json"] if r.pct(40) else []
    cmd = r.pick([["stock"] + j, ["low"] + j, ["history", w["products"][0]["sku"]] + j, ["quote", w["orders"][0]["id"]] + j,
                  ["report"] + r.pick([[], ["--format", "csv"], ["--format", "json"]]), ["stock"], ["report"]])
    return new_case("closed_pipe", files, [cmd], closed=True, tags=tags)


# --- the command line --------------------------------------------------------------------------
def usage_templates(r, w):
    s, o, d = w["products"][0]["sku"], w["orders"][0]["id"], iso(D(70))
    return [
        [], ["--dir"], ["--dir", "x"], ["bogus"], ["bogus", "--json"], ["bogus", "extra"], ["stock", "extra"], ["stock", "--bogus"],
        ["stock", "-x"], ["stock", "--jso"], ["stock", "--format", "csv"], ["stock", "--json", "--bogus"], ["stock", "--dir"],
        ["low", "x"], ["low", "--bogus"], ["low", "--verbose", "--json"], ["history"], ["history", s, "x"], ["history", "--json"],
        ["history", s, "--bogus"], ["history", "-" + s], ["history", "-x"], ["receive"], ["receive", d], ["receive", d, s],
        ["receive", d, s, "5", "note", "extra"], ["ship"], ["ship", d], ["ship", d, s], ["ship", d, s, "1", "note", "extra"],
        ["quote"], ["quote", o, o], ["quote", o, "--bogus"], ["quote", "--json"], ["quote", "-" + o], ["fulfil"], ["fulfil", o],
        ["fulfil", o, d, "x"], ["fulfil", o, d, "--json"], ["fulfil", o, "--json"], ["invoice"], ["invoice", o, o],
        ["invoice", o, "--format", "csv"], ["invoice", o, "--bogus"], ["report", "x"], ["report", "--json"], ["report", "--format"],
        ["report", "--format", "xml"], ["report", "--format", "yaml", "--json"], ["report", "--forma", "csv"], ["report", "-f", "csv"],
        ["receive", "2024-02-30", s, "5"], ["ship", "2023-02-29", s, "1"], ["receive", "24-01-01", s, "5"],
        ["ship", "tomorrow", s, "1"], ["receive", "2024-1-5", s, "5", "note"], ["fulfil", o, "2024-13-01"], ["fulfil", o, "20240101"],
        ["fulfil", o, "2024-02-30"], ["receive", "", s, "5"], ["ship", "-2024-01-01", s, "1"], ["fulfil", o, "-2024-01-01"],
        ["receive", "2024-02-30", s], ["ship", "2024-02-30", s, "1", "a", "b"], ["fulfil", "2024-02-30", o],
    ]


def sc_usage(r):
    """Several command lines that are wrong, one after the other (none of them changes anything), on good or broken files."""
    w = ledger(r, 2, 1)
    tags = ["argv:usage"]
    templates = usage_templates(r, w)
    steps = [list(x) for x in r.sample(templates, r.span(2, 4))]
    files = file_set(r, w)
    sub = None
    if r.pct(35):                        # the command line is checked first: files that cannot be read do not change a 2 to a 1
        how = r.below(5)
        if how == 0:
            files.pop(CATALOG)
            tags.append("catalog:missing")
        elif how == 1:
            files[CATALOG] = ("this is not a catalogue\n").encode().hex()
            tags.append("catalog:bad-line")
        elif how == 2:
            files[MOVEMENTS] = b"2024-02-30 nonsense\n".hex()
            tags.append("movements:bad-line")
        elif how == 3:
            files[CATALOG] = b"\xff\xfe".hex()
            tags.append("catalog:invalid-utf8")
        else:
            steps = [x + ["--dir", "nowhere"] if r.pct(50) else ["--dir", "nowhere"] + x for x in steps]
            tags.append("argv:dir-missing")
    return new_case("usage", files, steps, sub, tags=tags)


def sc_checks_order(r):
    """The command line, then the files, then the request: a request that is refused only matters if the files read."""
    w = ledger(r, 2, 1)
    tags = ["order-of-checks"]
    s, o = w["products"][0]["sku"], w["orders"][0]["id"]
    files = file_set(r, w)
    how = r.below(6)
    cmds = [["history", "QQ-999"], ["quote", "SO-9999"], ["ship", iso(D(60)), "QQ-999", "1"], ["ship", iso(D(60)), s, "abc"],
            ["fulfil", "SO-9999", iso(D(60))], ["invoice", "SO-9999"], ["receive", iso(D(60)), s, "-1", "x"]]
    argv = r.pick(cmds)
    if how == 0:
        files.pop(CATALOG)
        tags.append("catalog:missing")
    elif how == 1:
        files[CATALOG] = b"AB-100 | no price | x | 1\n".hex()
        tags.append("catalog:bad-line")
    elif how == 2:
        files[ORDERS] = b"SO-1 2024-02-30 a AB-100*1\n".hex()
        tags.append("orders:bad-line")
    elif how == 3:
        files[MOVEMENTS] = b"junk\n".hex()
        tags.append("movements:bad-line")
    elif how == 4:
        files[ORDERS] = (bytes.fromhex(files[ORDERS]) + b"# \xff\n").hex()
        tags.append("orders:invalid-utf8")
    return new_case("checks_order", files, [argv], tags=tags)


def sc_dash_args(r):
    """`receive`, `ship` and `fulfil` take every argument as typed."""
    w = ledger(r, 2, 1)
    s, o = r.pick(w["products"])["sku"], w["orders"][0]["id"]
    files = file_set(r, w)
    d = iso(D(r.span(60, 90)))
    tags = ["argv:dash-led-argument"]
    steps = [r.pick([
        ["receive", d, s, "-5"], ["ship", d, s, "-5"], ["receive", d, s, "5", "-x"], ["ship", d, s, "1", "--json"],
        ["receive", d, s, "2", "--dir2"], ["ship", d, s, "--json"], ["receive", d, s, "--5"], ["receive", d, "-" + s, "5"],
        ["ship", d, s, "1", "- not an option"], ["fulfil", "-" + o, d], ["fulfil", o, d, "--json"], ["fulfil", o, "--json"],
        ["receive", d, s, "+5"], ["ship", d, s, "-0"], ["receive", d, s, "5", "-"],
    ])]
    if steps[0][0] in ("receive", "ship") and r.pct(50):
        steps.append(["history", s])
    steps, sub = wrap_steps(r, steps, tags, 15)
    return new_case("dash_args", files, steps, sub, tags=tags)


SLOTS = ["shelves", "quote", "receive_ship", "mistake", "fulfil", "docs", "quote", "mistake", "quote", "misc",
         "fulfil", "receive_ship", "usage", "docs", "mistake", "format", "quote", "fulfil", "usage", "misc"]


def make_case(r, i):
    slot = SLOTS[i % 20]
    r.quirky = r.pct(30)
    if slot == "shelves":
        fn = [sc_shelves, sc_shelves, sc_stock_edges, sc_history][r.below(4)]
    elif slot == "quote":
        fn = sc_quote
    elif slot == "receive_ship":
        fn = [sc_receive_ship, sc_receive_ship, sc_stock_rule][r.below(3)]
    elif slot == "fulfil":
        fn = [sc_fulfil, sc_fulfil, sc_fulfil_shortfall][r.below(3)]
    elif slot == "docs":
        fn = [sc_invoice_report, sc_invoice_report, sc_report_order][r.below(3)]
    elif slot == "mistake":
        fn = [sc_mistake_catalog, sc_mistake_catalog, sc_mistake_movements, sc_mistake_movements, sc_mistake_orders,
              sc_mistake_orders, sc_elsewhere][r.below(7)]
    elif slot == "format":
        fn = [sc_format, sc_format, sc_edges_of_files][r.below(3)]
    elif slot == "usage":
        fn = [sc_usage, sc_usage, sc_usage, sc_checks_order, sc_dash_args][r.below(5)]
    else:
        fn = [sc_unreadable, sc_unreadable, sc_closed_pipe, sc_closed_pipe, sc_dash_args][r.below(5)]
    case = fn(r)
    case["id"] = i
    return case


def generate(n=CASES, seed=SEED):
    r = Rng(seed)
    return [make_case(r, i) for i in range(n)]


# --- running a case ----------------------------------------------------------------------------
class Clock:
    def __init__(self, seconds):
        self.deadline = time.monotonic() + seconds

    def left(self):
        return self.deadline - time.monotonic()


def cli(cmd, env, work, argv, closed=False, clock=None):
    """One command: {"exit", "stdout", "stderr_empty", "stderr"}."""
    left = clock.left() if clock else RUN_TIMEOUT
    if left <= 0:
        return {"exit": "timeout", "stdout": "", "stderr_empty": False, "stderr": "case out of time"}
    pipe = None
    out = subprocess.PIPE
    if closed:
        rd, pipe = os.pipe()
        os.close(rd)                    # nobody reads: the first write fails with a broken pipe
        out = pipe
    try:
        p = subprocess.run(cmd + argv, cwd=work, env=env, stdout=out, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                           timeout=min(RUN_TIMEOUT, left))
        return {"exit": p.returncode, "stdout": (p.stdout or b"").decode("utf-8", "backslashreplace"),
                "stderr_empty": not p.stderr.strip(), "stderr": p.stderr.decode("utf-8", "backslashreplace")[-300:]}
    except subprocess.TimeoutExpired:
        return {"exit": "timeout", "stdout": "", "stderr_empty": False, "stderr": "timeout"}
    except OSError as exc:
        return {"exit": "oserror", "stdout": "", "stderr_empty": False, "stderr": str(exc)[:300]}
    finally:
        if pipe is not None:
            os.close(pipe)


def lines_of(data):
    """A movements file as its non-empty lines, whichever of LF and CRLF ends them."""
    return [x for x in re.split(r"\r\n|\n", data.decode("utf-8", "backslashreplace")) if x]


def run_case(cmd, env, case, clock=None):
    """[one record per command]: the answer, movements.txt as lines (None when absent) and whether the other two files are as written."""
    clock = clock or Clock(CASE_S)
    work = tempfile.mkdtemp(prefix="stockfuzz-")
    try:
        folder = os.path.join(work, case["sub"]) if case["sub"] else work
        os.makedirs(folder, exist_ok=True)
        original = {}
        for name, hx in case["files"].items():
            original[name] = bytes.fromhex(hx)
            with open(os.path.join(folder, name), "wb") as fh:
                fh.write(original[name])
        records = []
        for step_no, argv in enumerate(case["steps"]):
            closed = case["closed_stdout"] and step_no == len(case["steps"]) - 1
            path = os.path.join(folder, MOVEMENTS)
            before = open(path, "rb").read() if os.path.isfile(path) else None
            res = cli(cmd, env, work, argv, closed, clock)
            after = open(path, "rb").read() if os.path.isfile(path) else None
            res["kept"] = (before == after) if res["exit"] != 0 else None       # a refused request leaves the file exactly as it was
            res["file"] = lines_of(after) if after is not None else None
            res["untouched"] = all((open(os.path.join(folder, n), "rb").read() if os.path.isfile(os.path.join(folder, n)) else None)
                                   == original.get(n) for n in (CATALOG, ORDERS))
            res["what"] = "stockroom " + " ".join(argv)
            records.append(res)
        return records
    finally:
        shutil.rmtree(work, ignore_errors=True)


def split_command(argv):
    """(command, the rest) of a command line, `--dir X` taken out."""
    out, i = [], 0
    while i < len(argv):
        if argv[i] == "--dir":
            i += 2
            continue
        out.append(argv[i])
        i += 1
    return (out[0] if out else None), out[1:]


def mode_of(argv):
    cmd, rest = split_command(argv)
    if cmd in ("stock", "low", "history", "quote", "invoice") and "--json" in rest:
        return "json"
    if cmd == "report":
        if "--format" in rest and rest.index("--format") + 1 < len(rest):
            return {"csv": "csv", "json": "json"}.get(rest[rest.index("--format") + 1], "text")
        return "text"
    return "text"


def canon_out(mode, out, command=None):
    """Standard output as it counts: JSON as data, CSV as rows, text as its lines. The brief does not say whether the `delta` of
    `history --json` is the number -3 or the string "-3" (its text form shows the sign, "counts are numbers"), so both count."""
    if mode == "json":
        try:
            data = json.loads(out)
            if command == "history" and isinstance(data, list):
                for row in data:
                    if isinstance(row, dict) and isinstance(row.get("delta"), (str, int)) and not isinstance(row.get("delta"), bool):
                        try:
                            row["delta"] = int(row["delta"])
                        except ValueError:
                            pass
            return json.dumps(data, sort_keys=True)
        except ValueError:
            return "(not JSON) " + out
    if mode == "csv":
        try:
            return json.dumps([row for row in csv.reader(io.StringIO(out, newline="")) if row])
        except csv.Error:
            return "(not CSV) " + out
    lines = out.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


LOCATION = re.compile(r"(catalog|movements|orders)\.txt\W+line (\d+)")


def location(case, rec):
    """(file, line number) a mistake message of the reference names, for a case that pins one; else None."""
    if not case["locate"] or rec["exit"] != 1:
        return None
    m = LOCATION.search(rec["stderr"])
    return (m.group(1) + ".txt", m.group(2)) if m else None


def canon(case, argv, rec, loc):
    """What of one command's answer counts."""
    if case["closed_stdout"] and argv == case["steps"][-1]:
        return {"exit": rec["exit"], "stderr_empty": rec["stderr_empty"]}
    out = {"exit": rec["exit"], "stderr_empty": rec["stderr_empty"], "file": rec["file"], "untouched": rec["untouched"],
           "kept": rec.get("kept")}
    if rec["exit"] != 2:                # the brief says nothing about what exit 2 prints
        out["stdout"] = canon_out(mode_of(argv), rec["stdout"], split_command(argv)[0])
    if loc:
        err = rec["stderr"]
        out["names_line"] = loc[0] in err and re.search(r"(?<![0-9])%s(?![0-9])" % loc[1], err) is not None
    return out


def compare(case, ref, arm):
    """(index of the first command that differs or None, canonical reference, canonical arm)."""
    steps = case["steps"]
    for i, argv in enumerate(steps):
        if i >= len(ref) or i >= len(arm):
            break
        loc = location(case, ref[i])
        a, b = canon(case, argv, ref[i], loc), canon(case, argv, arm[i], loc)
        if a != b:
            return i, a, b
    return None, None, None


def show(text, limit=200):
    text = text.encode("unicode_escape").decode("ascii") if isinstance(text, str) else text
    return text if len(text) <= limit else text[:limit] + "..."


def case_files(case):
    return {n: show(bytes.fromhex(h).decode("utf-8", "backslashreplace"), 400) for n, h in case["files"].items()}


def window(text, other, limit=300):
    """`text` from a little before the first place it differs from `other`."""
    same = 0
    while same < min(len(text), len(other)) and text[same] == other[same]:
        same += 1
    start = max(0, same - 80)
    return ("..." if start else "") + text[start:start + limit] + ("..." if len(text) > start + limit else "")


def example(case, at, ref, arm):
    def view(rec, other):
        shown = {k: (show(v) if isinstance(v, str) else v) for k, v in rec.items() if k not in ("stderr", "what")}
        shown["stdout"] = show(window(rec["stdout"], other["stdout"]), 400)
        return shown
    return {"case": case["id"], "kind": case["kind"], "step": at, "what": ref[at]["what"], "steps": case["steps"],
            "dir": case["sub"], "files": case_files(case), "reference": view(ref[at], arm[at]), "arm": view(arm[at], ref[at]),
            "arm_stderr": show(arm[at]["stderr"])}


def signature(case, at, ref, arm):
    command = split_command(case["steps"][at])[0]
    return (case["kind"], command, ref[at]["exit"], arm[at]["exit"], ref[at]["stdout"] == arm[at]["stdout"], arm[at]["stderr_empty"])


def pick_examples(found):
    """Up to MAX_EXAMPLES: one per distinct kind of disagreement first, then the rest in case order."""
    seen, first, rest = set(), [], []
    for sig, ex in found:
        (rest if sig in seen else first).append(ex)
        seen.add(sig)
    return (first + rest)[:MAX_EXAMPLES]


def _rootcause():
    """bench/rootcause.py, loaded by path."""
    spec = importlib.util.spec_from_file_location("bench_rootcause", os.path.join(os.path.dirname(HERE), "rootcause.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def file_features(name, data):
    """What is odd about one file's bytes."""
    stem, found = name[:-4], set()
    if data.startswith(b"\xef\xbb\xbf"):
        found.add(stem + ":byte-order-mark")
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        found.add(stem + ":utf-16")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        found.add(stem + ":invalid-utf8")
        text = data.decode("utf-8", "replace")
    bare = text.replace("\r\n", "")
    if "\r\n" in text:
        found.add(stem + ":crlf")
        if "\n" in text.replace("\r\n", ""):
            found.add(stem + ":mixed-line-ends")
    if text and not text.endswith("\n"):
        found.add(stem + ":no-final-newline")
    lines = text.replace("\r\n", "\n").split("\n")
    if not any(x.strip() and not x.strip().startswith("#") for x in lines):
        found.add(stem + ":no-data")
    if any(x.strip().startswith("#") for x in lines):
        found.add(stem + ":comment")
    if any(not x.strip() for x in lines[:-1]):
        found.add(stem + ":blank-line")
    if "\t" in bare:
        found.add(stem + ":tab")
    if any(ord(c) > 127 for c in text.replace("\ufeff", "")):
        found.add(stem + ":non-ascii")
    if stem == "movements":
        dates = [re.split(r"[ \t]+", x.strip(), maxsplit=1)[0] for x in lines if x.strip() and not x.strip().startswith("#")]
        if dates != sorted(dates):
            found.add(stem + ":not-in-date-order")
    return found


ARITY = {"stock": (0, 0), "low": (0, 0), "history": (1, 1), "receive": (3, 4), "ship": (3, 4), "quote": (1, 1), "fulfil": (2, 2),
         "invoice": (1, 1), "report": (0, 0)}


def usage_error(argv):
    """Whether the brief calls this command line wrong (exit 2): no command, an unknown one, a missing value, an unknown option,
    the wrong number of arguments, a bad --format, a date that is not one."""
    if any(a == "--dir" and i + 1 >= len(argv) for i, a in enumerate(argv)):
        return True
    cmd, rest = split_command(argv)
    if cmd not in ARITY:
        return True
    positional, i = [], 0
    while i < len(rest):
        a = rest[i]
        if cmd in ("stock", "low", "history", "quote", "invoice") and a == "--json":
            i += 1
        elif cmd == "report" and a == "--format":
            if i + 1 >= len(rest) or rest[i + 1] not in ("text", "csv", "json"):
                return True
            i += 2
        elif a.startswith("-") and len(a) > 1 and cmd not in ("receive", "ship", "fulfil"):
            return True
        else:
            positional.append(a)
            i += 1
    if not ARITY[cmd][0] <= len(positional) <= ARITY[cmd][1]:
        return True
    if cmd in ("receive", "ship", "fulfil"):
        try:
            datetime.date(*[int(x) for x in positional[1 if cmd == "fulfil" else 0].split("-")])
            return not re.fullmatch("[0-9]{4}-[0-9]{2}-[0-9]{2}", positional[1 if cmd == "fulfil" else 0])
        except (ValueError, TypeError):
            return True
    return False


def argv_features(argv):
    """What is odd about one command line."""
    found = set()
    cmd, rest = split_command(argv)
    if usage_error(argv):
        found.add("argv:usage-error")
    if "--dir" in argv:
        found.add("argv:dir-option")
    if cmd is None:
        found.add("argv:no-command")
        return found
    if cmd not in ("stock", "low", "history", "receive", "ship", "quote", "fulfil", "invoice", "report"):
        found.add("argv:unknown-command")
        return found
    if cmd in ("receive", "ship", "fulfil"):
        if any(x.startswith("-") for x in rest):
            found.add("argv:dash-led-argument")
        if cmd != "fulfil" and len(rest) > 2 and rest[2].startswith(("-", "+")):
            found.add("argv:signed-quantity")
        if cmd != "fulfil" and len(rest) > 3 and rest[3].startswith("-"):
            found.add("argv:dash-led-note")
        if cmd != "fulfil" and len(rest) > 3 and ("\n" in rest[3] or "\r" in rest[3]):
            found.add("argv:note-with-line-break")
        if cmd != "fulfil" and len(rest) > 3 and any(ord(c) > 127 for c in rest[3]):
            found.add("argv:non-ascii-note")
        if cmd != "fulfil" and len(rest) > 3 and "  " in rest[3]:
            found.add("argv:note-with-spaces")
    else:
        flagged = [x for x in rest if x.startswith("-")]
        if any(x not in ("--json", "--format") for x in flagged):
            found.add("argv:unknown-option")
    if cmd == "report" and "--format" in rest:
        at = rest.index("--format")
        found.add("argv:format-" + (rest[at + 1] if at + 1 < len(rest) and rest[at + 1] in ("text", "csv", "json") else "bad"))
    if "--json" in rest and cmd not in ("receive", "ship", "fulfil", "report"):
        found.add("argv:json")
    if any(x in ("2024-02-30", "2023-02-29") or x in BAD_DATES for x in rest):
        found.add("argv:bad-date")
    return found


def data_rows(files, name):
    """The lines of a case's file that carry data (KeyError when the file is not there)."""
    text = bytes.fromhex(files[name]).decode("utf-8-sig")
    return [x.strip() for x in text.replace("\r\n", "\n").split("\n") if x.strip() and not x.strip().startswith("#")]


def request_features(files, argv):
    """What is wrong with the request itself, worked out from the files (an unknown SKU or order, a bad quantity, a movement
    that takes the stock below zero): the inputs the brief says are refused."""
    found = set()
    cmd, rest = split_command(argv)
    try:
        skus = {x.split("|")[0].strip().upper() for x in data_rows(files, CATALOG)}
        if cmd == "history" and rest and rest[0].upper() not in skus:
            found.add("request:unknown-sku")
        if cmd in ("receive", "ship") and len(rest) >= 3:
            date, sku, qty = rest[0], rest[1].upper(), rest[2]
            if sku not in skus:
                found.add("request:unknown-sku")
            elif not re.fullmatch("[0-9]+", qty) or int(qty) < 1:
                found.add("request:bad-quantity")
            elif cmd == "ship" and re.fullmatch("[0-9]{4}-[0-9]{2}-[0-9]{2}", date):
                moves = []
                for line in data_rows(files, MOVEMENTS) if MOVEMENTS in files else []:
                    d, s_, q = re.split(r"[ \t]+", line, maxsplit=3)[:3]
                    moves.append((d, s_.upper(), int(q)))
                moves.append((date, sku, -int(qty)))
                level = 0
                for d, s_, q in sorted(moves, key=lambda m: m[0]):
                    if s_ == sku:
                        level += q
                        if level < 0:
                            found.add("request:stock-below-zero")
                            break
        if cmd in ("quote", "invoice", "fulfil") and rest:
            orders = {}
            for x in data_rows(files, ORDERS) if ORDERS in files else []:
                o = re.split(r"[ \t]+", x, maxsplit=3)
                orders[o[0].upper()] = (o[1], {y.split("*")[0].upper() for y in o[3].split(",")})
            if rest[0].upper() not in orders:
                found.add("request:unknown-order")
            elif cmd == "fulfil" and len(rest) > 1 and rest[1] < orders[rest[0].upper()][0]:
                found.add("request:before-order-date")
            elif cmd == "invoice":
                sent = False
                for line in data_rows(files, MOVEMENTS) if MOVEMENTS in files else []:
                    m = re.split(r"[ \t]+", line, maxsplit=3)
                    if len(m) == 4 and m[3].strip() == "order " + rest[0].upper() and int(m[2]) < 0 and m[1].upper() in orders[rest[0].upper()][1]:
                        sent = True
                if not sent:
                    found.add("request:nothing-shipped")
    except (KeyError, IndexError, ValueError):
        return set()
    return found | ({"request:refused"} if found else set())


def price_features(files):
    """How the orders of a case reach the rounding the brief names, worked out from the brief's rules on its own files (nothing
    when they cannot be read). Only what is a rule of the brief: which discount, which half penny, which class of tax."""
    found = set()
    try:
        def rows(name):
            text = bytes.fromhex(files[name]).decode("utf-8-sig")
            return [x.strip() for x in text.replace("\r\n", "\n").split("\n") if x.strip() and not x.strip().startswith("#")]
        shop = {}
        for line in rows(CATALOG):
            f = [x.strip() for x in line.split("|")]
            whole, _, frac = f[2].partition(".")
            shop[f[0].upper()] = (int(whole) * 100 + int((frac + "00")[:2]), (f[4].lower() if len(f) > 4 else "standard"))
        for line in rows(ORDERS):
            lines = re.split(r"[ \t]+", line, maxsplit=3)[3]
            nets, taxes = [], []
            for piece in lines.split(","):
                sku, _, qty = piece.partition("*")
                unit, tax = shop[sku.upper()]
                q, gross = int(qty), shop[sku.upper()][0] * int(qty)
                pct = 10 if q >= 50 else 5 if q >= 10 else 0
                if pct:
                    found.add("pricing:volume-discount-%d" % pct)
                    if gross * pct % 100 == 50:
                        found.add("pricing:half-penny-volume")
                nets.append(gross - (gross * pct + 50) // 100)
                taxes.append(tax)
            sub = sum(nets)
            if 49999 <= sub <= 50001:
                found.add("pricing:subtotal-at-threshold")
            share = [0] * len(nets)
            if sub >= 50000:
                found.add("pricing:order-discount")
                disc = (sub * 3 + 50) // 100
                if sub * 3 % 100 == 50:
                    found.add("pricing:half-penny-order-discount")
                share = [disc * n // sub for n in nets]
                left = disc - sum(share)
                rems = [disc * n % sub for n in nets]
                ranked = sorted(range(len(nets)), key=lambda i: (-rems[i], i))
                if left:
                    found.add("pricing:shared-leftover-penny")
                    if left < len(nets) and rems[ranked[left - 1]] == rems[ranked[left]]:
                        found.add("pricing:shared-tie")
                for i in ranked[:left]:
                    share[i] += 1
            for net, sh, tax in zip(nets, share, taxes):
                found.add("pricing:tax-" + tax)
                if tax == "reduced" and (net - sh) * 5 % 100 == 50:
                    found.add("pricing:half-penny-tax")
    except (KeyError, IndexError, ValueError):
        return set()
    return found


def features(case, at=None, ref=None, arm=None):
    """The input features of a case (bench/rootcause.py): what is odd about the files and the command line of the step that
    differed, and what the generator marked it with (the kind of mistake, the rounding it reaches, ...). A feature every case
    shares would explain every divergence and hide the real causes; a case with nothing odd is labelled by its command."""
    found = set(case["tags"])
    for name, hx in case["files"].items():
        found |= file_features(name, bytes.fromhex(hx))
    found |= {"files:" + f.split(":")[1] for f in found
              if re.fullmatch(r"(catalog|movements|orders):(byte-order-mark|crlf|invalid-utf8|no-final-newline|utf-16)", f)}
    for name in (CATALOG, MOVEMENTS, ORDERS):
        if name not in case["files"]:
            found.add(name[:-4] + ":missing")
    steps = case["steps"] if at is None else [case["steps"][at]]
    for argv in steps:
        found |= argv_features(argv)
        found |= request_features(case["files"], argv)
    if any(split_command(a)[0] in ("quote", "invoice", "report", "fulfil") for a in steps):
        found |= price_features(case["files"])
    if case["closed_stdout"]:
        found.add("output:closed-pipe")
    found -= {"movements:missing"} if (at is not None and split_command(case["steps"][at])[0] in ("quote",)) else set()
    if not found:
        command = split_command(case["steps"][at if at is not None else 0])[0]
        found.add("command:%s" % command)
    return found


def difference(ref, arm):
    return _rootcause().diff_kind(ref, arm)


def run(cmd, env=None, cases=CASES, cap_s=CAP_S, reference=None):
    """The fragment for `cmd` (an argv list) against the reference. `reference` is (argv, env) of the oracle."""
    planned = generate(CASES)
    digest = case_hash(planned)
    if digest != FROZEN_HASH:
        raise SystemExit("fuzz.py (medium): the generator changed (case hash %s, frozen %s): update SEED / FROZEN_HASH "
                         "on purpose, or revert it" % (digest, FROZEN_HASH))
    env = dict(os.environ if env is None else env, PYTHONIOENCODING="utf-8", PYTHONDONTWRITEBYTECODE="1")
    if reference is None:
        ref_cmd = [sys.executable, "-m", "stockroom"]
        ref_env = dict(env, PYTHONPATH=REFERENCE_DIR)
        ref_env.pop("STOCKROOM_CMD", None)
    else:
        ref_cmd, ref_env = reference
    deadline = time.monotonic() + cap_s
    found, ran, population = [], 0, {}
    todo = planned[:cases]

    def both(case):
        ref = run_case(ref_cmd, ref_env, case)              # a failure here is the fuzz's own bug: let it show
        try:
            arm = run_case(cmd, env, case)
        except Exception as exc:                            # whatever the arm did that the harness cannot read
            arm = [dict(r_, exit="harness", stdout="", stderr_empty=False, stderr=type(exc).__name__ + ": " + str(exc)[:200])
                   for r_ in ref]
        return ref, arm

    with ThreadPoolExecutor(WORKERS) as pool:
        for at in range(0, len(todo), CHUNK):
            if ran and time.monotonic() > deadline:
                break
            chunk = todo[at:at + CHUNK]
            for case, (ref, arm) in zip(chunk, list(pool.map(both, chunk))):
                ran += 1
                for f in features(case):
                    population[f] = population.get(f, 0) + 1
                i, a, b = compare(case, ref, arm)
                if i is not None:
                    found.append((signature(case, i, ref, arm), example(case, i, ref, arm),
                                  (features(case, i, ref, arm), difference(a, b))))
    classes = _rootcause().classify([items for _, _, items in found], population)
    return {"fuzz_cases": ran, "fuzz_divergences": len(found), "fuzz_classes": classes["classes"],
            "fuzz_class_counts": classes["class_counts"], "fuzz_examples": pick_examples([(s, e) for s, e, _ in found]),
            "fuzz_seed": SEED, "fuzz_hash": digest}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Differential fuzz of a stockroom command against the reference.")
    ap.add_argument("--cmd", help="the arm's command line, a JSON argv list (default: $STOCKROOM_CMD)")
    ap.add_argument("--self", action="store_true", help="fuzz the reference against itself (0 divergences expected)")
    ap.add_argument("--cases", type=int, default=CASES)
    ap.add_argument("--cap", type=float, default=CAP_S, help="seconds before it stops starting new cases")
    ap.add_argument("--print-hash", action="store_true", help="print the generator's case hash and exit")
    a = ap.parse_args(argv)
    if a.print_hash:
        print(case_hash(generate(CASES)))
        return 0
    env = None
    if a.self:
        cmd = [sys.executable, "-m", "stockroom"]
        env = dict(os.environ, PYTHONPATH=REFERENCE_DIR)
    else:
        raw = a.cmd or os.environ.get("STOCKROOM_CMD")
        try:
            cmd = json.loads(raw) if raw else None
        except ValueError:
            cmd = None
        if not (isinstance(cmd, list) and cmd and all(isinstance(x, str) for x in cmd)):
            print("fuzz.py: give --cmd '[\"stockroom\"]' (or set STOCKROOM_CMD), or --self", file=sys.stderr)
            return 2
    print(json.dumps(run(cmd, env, a.cases, a.cap), indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

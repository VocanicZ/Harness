#!/usr/bin/env python3
"""fuzz.py — differential fuzz of an arm's `tallybook` against the reference implementation (PRD #345, #592).

The large fixture's hidden tests are hand-written; this feeds the arm and the reference (bench/fixture-large/reference/)
the SAME random command lines, files and HTTP requests and counts where they disagree. Same interface as
bench/fuzz.py (which delegates here for `--fixture large`):

    bench/fixture-large/fuzz.py --self                  # the reference against itself: must report 0 divergences
    bench/fixture-large/fuzz.py --cmd '["tallybook"]'   # an arm's command line (JSON argv); default $TALLYBOOK_CMD
    bench/fixture-large/fuzz.py --cases 200 --cap 60    # the first 200 cases / a shorter time cap (defaults 1000 / 600 s)

Prints one JSON object (exit 0; 2 for bad arguments or a generator that no longer matches its frozen hash):

    {"fuzz_cases": N, "fuzz_divergences": N, "fuzz_examples": [up to 10], "fuzz_seed": 592, "fuzz_hash": "…"}

The reference is the POST-change behaviour (`TALLYBOOK_PHASE` unset), run as `python -m tallybook`. Three kinds of
case, each in its own empty directory for both implementations:

  * offline (about 65%): one `tallybook --today 2024-06-15 calc ...` command line on random arguments and files (money,
    dates, schedules, queries, journals, reports, budgets, rates, rules, account paths, bank CSV); compared are the exit
    status, standard output and whether standard error is empty. Every `calc` output is decided by argv and files.
  * book (about 20%): a short script of commands on a fresh `--db` file (init, account/tx, journal import, bank CSV,
    rates, budgets, recurring, reports, export, a period lock and a refused operation); each step is compared like the above.
  * api (about 15%): the book is built with the command line, `tallybook serve --port 0` is started, a script of HTTP
    requests (good and bad) is played, the server is stopped with SIGTERM, and the book is dumped; compared are statuses,
    Content-Type, Allow and the bodies as data.

Left open by the brief and therefore not compared: the wording of any error message (for the API only that `error.message`
is non-empty text and `error.code` is the code), help texts beyond their first words, the text `lock set` / `lock clear`
print, the body and the exact 2xx status of `PUT /lock`, the code of a 404 for a path that does not exist, the port, headers
other than Content-Type and Allow, the body of a HEAD answer, and how a request line the server cannot read at all is
answered on the wire (not generated). Cases keep clear of what the brief does not pin down: two different mistakes in one
request or command (which one is reported first), `--upto` after `--today` (the CLI's horizon), a book year of 9999 with
budgets, text that a command stores and prints back with a byte-order mark or CR line ends, parents that only exist as part
of a longer account path where the brief does not say, non-ASCII digits in ids, and a closing date that is both before an
opening and before a posting.

PROVENANCE (#620): this is a BLIND generator. It was written for #592 from this fixture's brief
(bench/fixture-large/brief.md) and its reference implementation only, and committed before any arm had run on this fixture
(bench/results held no large-fixture run: the only run then was the pennywise one), so no arm's output, bug or divergence
shaped it. A change to it is a different measurement (see FROZEN_HASH) and must keep that property: write it from the brief
and the reference, never from what an arm got wrong.

The generator is FROZEN: bench/fuzz.py's PRNG (splitmix64), SEED and the SHA-256 of the case list (FROZEN_HASH). Change it
and this refuses to run until SEED / FROZEN_HASH are updated on purpose; that is a different measurement, so re-grade the
runs you compare. Stdlib only.
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE_DIR = os.path.join(HERE, "reference")


def _base():
    """bench/fuzz.py (the pennywise fuzz), loaded by path: the PRNG and the helpers shared by both fuzzers."""
    spec = importlib.util.spec_from_file_location("bench_fuzz_base", os.path.join(os.path.dirname(HERE), "fuzz.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_B = _base()
Rng, case_hash, show, pick_examples, MAX_EXAMPLES = _B.Rng, _B.case_hash, _B.show, _B.pick_examples, _B.MAX_EXAMPLES

PROVENANCE = ("blind: written from the brief and the reference implementation only, committed (#592) before any arm "
              "had run on this fixture; no arm output informed it")
SEED = 592
CASES = 1000
CAP_S = 600
RUN_TIMEOUT = 20            # one command of a case
CASE_S = 90                 # all the commands of one case, then the rest count as timed out
HTTP_TIMEOUT = 10
WORKERS = 4
CHUNK = 16
TODAY = "2024-06-15"
FROZEN_HASH = "58bb9280f8964332d0a7280bb32bd2c79b2644a2e446efb98c71bbaaf762f97d"

# --- pools ----------------------------------------------------------------------------------
CUR = ["USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "KWD", "SEK", "INR", "NZD", "NOK", "KRW", "BHD", "CNY", "MXN"]
EXP = {"USD": 2, "EUR": 2, "GBP": 2, "JPY": 0, "CHF": 2, "CAD": 2, "AUD": 2, "KWD": 3, "SEK": 2, "INR": 2, "NZD": 2,
       "NOK": 2, "KRW": 0, "BHD": 3, "CNY": 2, "MXN": 2}
COMMON_CUR = ["USD", "USD", "USD", "EUR", "EUR", "GBP", "JPY", "KWD"]
BAD_CUR = ["usd", "XXX", "US", "USDX", "", " USD", "Usd", "EURO", "123"]
BAD_NUMBERS = ["", "-", "+", "1.", ".5", "1,000.00", "1 000", "1_000", "--5", "+-5", "1e3", "NaN", "inf", "$5", " 5",
               "5 ", "٣.٥٠", "５.００", "0x10", "1.2.3", "1,5", "5.", "-.5", "12.505"]
EDGE_DATES = ["2024-02-29", "2024-01-31", "2023-02-28", "2024-03-31", "2024-04-30", "2024-12-31", "2024-01-01",
              "2000-02-29", "1900-03-01", "2100-02-28", "2024-05-31", "2023-12-31", "2024-08-31", "2024-10-31",
              "2025-02-28", "2028-02-29", "2023-01-31", "2024-06-15", "2024-09-30", "2025-01-01"]
MONTH_ENDS = ["2024-01-31", "2024-03-31", "2024-04-30", "2024-08-31", "2023-01-31", "2024-05-31", "2024-02-29", "2023-12-31",
              "2024-10-31", "2023-02-28", "2024-06-30", "2024-01-30", "2024-01-29", "2023-03-31", "2024-11-30", "2025-01-31",
              "2020-02-29", "2024-12-31", "2024-07-31", "2024-09-30"]
RANGE_DATES = ["0001-01-01", "9999-12-31", "0001-12-31", "9999-01-01", "1999-12-31", "2200-06-30"]
BAD_DATES = ["2024-02-30", "2023-02-29", "2024-13-01", "2024-00-10", "2024-03-00", "2024-3-1", "2024-03-1", "24-03-01",
             "20240301", "2024/03/01", "2024.03.01", "01-03-2024", " 2024-03-01", "2024-03-01 ", "2024-03-01T10:00",
             "1900-02-29", "2100-02-29", "0000-01-01", "٢٠٢٤-٠٣-٠١", "", "yesterday",
             "2024-04-31", "2024-06-31", "20240-03-01"]
GOOD_PERIODS = ["2024", "2024-03", "2024-Q1", "2024-03-01..2024-03-31", "2023-Q4", "2024-02", "2023-02", "2024-Q2",
                "2024-04-01..2024-04-29", "2024-01-01..2024-03-31", "2023-12-01..2024-01-31", "2024-03-05..2024-03-05",
                "2024-Q3", "2024-Q4", "2023", "2025-01", "2024-06", "2024-05", "2024-01-15..2024-02-14",
                "2024-03-01..2024-03-15", "2024-12", "2024-01", "1900-02", "2100-02", "2024-02-01..2024-02-29"]
EDGE_PERIODS = ["9999", "9999-12", "9999-Q4", "0001", "0001-01", "0001-Q1", "9999-12-31..9999-12-31"]
BAD_PERIODS = ["2024-3", "2024-13", "2024-00", "2024-Q0", "2024-Q5", "2024-q1", "2024Q1", "24", "12345", "0000",
               "2024-03-01", "2024-03-01..", "..2024-03-31", "2024-03-01...2024-03-31", "2024-03-01 .. 2024-03-31",
               "2024-03..2024-04", "2024-02-30..2024-03-31", "", " 2024", "2024-03 ", "2024-03-31..2024-03-01",
               "2024-Q1x", "this month"]
DOWS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
STEPS = ["week", "month", "quarter", "year"]
ROOTS = ["Assets", "Liabilities", "Equity", "Income", "Expenses"]
GOOD_SEGS = ["Bank", "Checking", "Food", "A", "B2", "Foo-bar", "Baz_1", "Cash", "Dining", "Travel", "X", "Savings"]
BAD_SEGS = ["bank", "Café", "with space", "", "1abc", "-x", "_x", "A:B", "Fo*", "***", "a b"]
PAYEES = ["Acme", "Corner Shop", "Café Zoë", "日本語 Shop", "O'Brien", "Ünï", "Market", "Landlord",
          "Bäcker, Bob", "ACME PAYROLL", "CAFE NERO 0412", "Nero", "a #hash", "semi;colon", "tab\tin", "",
          "say \"hi\"", "back\\slash", "emoji \U0001f642", "Starbucks", "Rent Co", "Shop  two"]
NARRATIONS = ["", "", "", "March pay", "weekly shop", "ré", "quote \" inside", "a  b", "with # hash", "x;y",
              "rent march", "Coffee break", "gift ☃"]
TAGS = ["food", "trip-2024", "salary", "a_b", "coffee", "x1", "lunch", "rent"]
SEARCH_WORDS = ["acme", "shop", "caf", "NERO", "日本", "o'brien", "market", "rent", "coffee", "zoë", "a",
                "and", "hash", "hi", "ü"]
BOOK_ACCOUNTS = [("Assets:Bank:Checking", "USD"), ("Assets:Cash", None), ("Assets:Euro", "EUR"), ("Assets:Yen", "JPY"),
                 ("Assets:Dinar", "KWD"), ("Liabilities:Card", "USD"), ("Equity:Opening", None), ("Income:Salary", None),
                 ("Expenses:Food", None), ("Expenses:Food:Dining", None), ("Expenses:Rent", None),
                 ("Expenses:Travel", None), ("Expenses:Fun", "USD"), ("Expenses:Misc", None), ("Expenses:Uncategorized", None)]
ACCOUNT_NOTES = ["", "", "main account", "café", "say \"x\"", "a;b", "back\\slash"]
RATE_PAIRS = [("USD", "EUR"), ("USD", "JPY"), ("EUR", "GBP"), ("USD", "GBP"), ("GBP", "USD"), ("USD", "KWD"),
              ("EUR", "USD"), ("EUR", "JPY")]
RATE_TEXTS = ["0.92", "150.5", "0.8", "1.25", "151.5", "0.3075", "0.125", "2", "1.00000001", "0.5", "0.0067", "3.25"]
EOLS = ["\n", "\r\n", "\r"]
JEOLS = ["\n", "\r\n"]
QUERY_FLAGS = ["*", "!"]
HEADER_NAMES = ["Date", "Payee", "Description", "Amount", "Debit", "Credit", "Ref", "Booking date"]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
FULL_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
               "November", "December"]


# --- small helpers --------------------------------------------------------------------------
def hexs(text):
    return text.encode("utf-8").hex()


def fmt_minor(minor, exp):
    s = "%d" % abs(minor)
    if exp:
        s = s.rjust(exp + 1, "0")
        s = s[:-exp] + "." + s[-exp:]
    return ("-" if minor < 0 else "") + s


def digits(r, n):
    return "".join(str(r.below(10)) for _ in range(n))


def last_dom(y, m):
    return ((date(y + (m == 12), m % 12 + 1, 1)) - timedelta(days=1)).day


def good_date(r, lo=2023, hi=2025):
    y = lo + r.below(hi - lo + 1)
    m = 1 + r.below(12)
    return "%04d-%02d-%02d" % (y, m, 1 + r.below(last_dom(y, m) if r.pct(30) else 28))


def date_text(r, bad=8):
    k = r.below(100)
    if k < bad:
        return r.pick(BAD_DATES)
    if k < bad + 20:
        return r.pick(EDGE_DATES)
    if k < bad + 24:
        return r.pick(RANGE_DATES)
    return good_date(r)


def shift(text, days):
    try:
        return (date.fromisoformat(text) + timedelta(days=days)).isoformat()
    except (ValueError, OverflowError):
        return text


def number(r, exp):
    """An amount text for a currency with `exp` decimals: mostly valid, some past what the currency allows."""
    k = r.below(100)
    if k < 6:
        whole = "0"
    elif k < 58:
        whole = str(r.below(1000))
    elif k < 72:
        whole = str(r.below(10 ** 6))
    elif k < 80:
        whole = str(1 + r.below(9)) + digits(r, r.pick([17, 18, 19, 25, 29, 35]))
    elif k < 85:
        whole = "00" + str(r.below(100))
    else:
        whole = r.pick(["9", "99", "999", "9999", "99999", "100", "1000"])
    kf = r.below(100)
    if exp == 0:
        frac = "" if kf < 94 else r.pick([".0", ".5", ".00"])
    elif kf < 62:
        frac = "." + digits(r, exp)
    elif kf < 76:
        frac = "." + digits(r, r.below(exp)) if exp > 1 else ""
        frac = frac if frac != "." else ""
    elif kf < 88:
        frac = ""
    elif kf < 95:
        frac = "." + digits(r, exp + 1)
    else:
        frac = "." + digits(r, exp) + "0"
    sg = r.below(100)
    sign = "" if sg < 66 else "-" if sg < 90 else "+" if sg < 96 else "-"
    return sign + whole + frac


def money(r, cur=None, bad=4):
    cur = cur or r.pick(COMMON_CUR if r.pct(60) else CUR)
    if r.pct(bad):
        k = r.below(6)
        if k == 0:
            return r.pick(BAD_NUMBERS) + " " + cur
        if k == 1:
            return number(r, EXP[cur]) + " " + r.pick(BAD_CUR)
        if k == 2:
            return number(r, EXP[cur]) + cur
        if k == 3:
            return number(r, EXP[cur]) + "  " + cur
        if k == 4:
            return " " + number(r, EXP[cur]) + " " + cur
        return number(r, EXP[cur])
    return number(r, EXP[cur]) + " " + cur


def good_money(r, cur=None):
    cur = cur or r.pick(COMMON_CUR)
    return fmt_minor(minor_pool(r, cur), EXP[cur]) + " " + cur


def minor_pool(r, cur=None, signed=False):
    """A plausible amount in minor units: tiny, typical, round, odd (rounding ties), or large."""
    k = r.below(100)
    if k < 22:
        v = 1 + r.below(9)
    elif k < 66:
        v = 1 + r.below(20000)
    elif k < 76:
        v = (1 + r.below(50)) * 100
    elif k < 90:
        v = 2 * r.below(5000) + 1
    else:
        v = 1 + r.below(10 ** 12)
    return -v if signed and r.pct(50) else v


def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def join_lines(r, lines, eols=JEOLS, final=True):
    """Lines joined by one line ending for the whole text (75%), or by a mix of `eols`."""
    eol = r.pick(eols) if r.pct(75) else None
    out = ""
    for i, line in enumerate(lines):
        out += line
        if i < len(lines) - 1 or (final and r.pct(85)):
            out += eol if eol is not None else r.pick(eols)
    return out


def file_bytes_hex(r, text, bom=6, bad=1):
    data = text.encode("utf-8")
    k = r.below(100)
    if k < bom:
        data = b"\xef\xbb\xbf" + data
    elif k < bom + bad:
        at = r.below(len(data) + 1)
        data = data[:at] + r.pick([b"\xff", b"\xc3\x28", b"\xe2\x82", b"\x80"]) + data[at:]
    return data.hex()


# --- the journal generator ------------------------------------------------------------------
def accounts_for(cur):
    return [a for a, c in BOOK_ACCOUNTS if c in (None, cur)]


TX_EDGE_DATES = ["2024-02-29", "2024-01-31", "2023-12-31", "2024-03-31", "2024-04-30", "2024-05-31", "2024-06-15", "2024-01-01",
                 "2024-02-28", "2024-03-01", "2024-06-30"]


def tx_date(r):
    k = r.below(100)
    if k < 20:
        return r.pick(TX_EDGE_DATES)
    y, m = (2023, 12) if r.pct(8) else (2024, 1 + r.below(7))
    return "%04d-%02d-%02d" % (y, m, 1 + r.below(28))


def posting_line(r, acct, minor, cur, note=True):
    indent = r.pick(["  ", "  ", "  ", "    ", "\t", " "])
    sep = r.pick(["  ", "  ", " ", "   ", "\t"])
    txt = fmt_minor(minor, EXP[cur])
    if minor > 0 and r.pct(8):
        txt = "+" + txt
    tail = ("  ; " + r.pick(["coffee", "note é", "a;b", "  x  ", ""])) if note and r.pct(14) else ""
    if tail.endswith("; "):
        tail = "  ;" if r.pct(50) else ""
    return indent + acct + sep + txt + r.pick([" ", " ", "  ", "\t"]) + cur + tail


def gen_tx(r, tiny=False):
    """A transaction as a list of journal lines (a balanced one, unless it relies on a worked-out amount)."""
    d = tx_date(r)
    flag = r.pick(["", "", "* ", "! "])
    payee = r.pick(PAYEES)
    narr = r.pick(NARRATIONS)
    tags = "".join(" #" + t for t in [r.pick(TAGS) for _ in range(r.pick([0, 0, 1, 1, 2]))])
    head = d + " " + flag + quote(payee) + ((" " + quote(narr)) if narr and (r.pct(80) or payee) else "") + tags
    if r.pct(8):
        head += "  ; trailing"
    lines = [head]
    k = r.below(100)
    cur = r.pick(COMMON_CUR)
    pool = accounts_for(cur)
    a, b = r.pick(pool), r.pick(pool)
    if a == b:
        b = pool[(pool.index(a) + 1) % len(pool)]
    m = (1 + r.below(9)) if tiny and r.pct(70) else minor_pool(r)
    if k < 58:
        lines += [posting_line(r, a, m, cur), posting_line(r, b, -m, cur)]
    elif k < 70:
        c = r.pick(pool)
        m2 = m // 3 + 1
        lines += [posting_line(r, a, m2, cur), posting_line(r, b, m - m2, cur), "  " + c]
    elif k < 82:
        cur2 = r.pick([c for c in COMMON_CUR if c != cur])
        pool2 = accounts_for(cur2)
        e, f = r.pick(pool2), r.pick(pool2)
        if e == f:
            f = pool2[(pool2.index(e) + 1) % len(pool2)]
        m2 = minor_pool(r)
        lines += [posting_line(r, a, m, cur), posting_line(r, b, -m, cur), posting_line(r, e, m2, cur2),
                  posting_line(r, f, -m2, cur2)]
    elif k < 92:
        lines += [posting_line(r, a, m, cur), "  " + b + (r.pick(["", "", "  ; filled"]))]
    else:
        lines += [posting_line(r, "Income:Salary", -m, cur), posting_line(r, "Assets:Bank:Checking", m, "USD")] \
            if cur == "USD" else [posting_line(r, a, m, cur), posting_line(r, b, -m, cur)]
    if r.pct(8):
        lines.insert(1 + r.below(len(lines) - 1), r.pick(["  ; inline comment", "# hash comment", "   ; more"]))
    return lines


def mistake(r, blocks):
    """One writing or book-keeping mistake put into the list of blocks (each a list of lines)."""
    txs = [b for b in blocks if b and re.match(r"\d{4}-", b[0])]
    kind = r.below(22)
    if not txs and (kind < 15 or kind >= 20):
        kind = 18
    t = r.pick(txs) if txs else None
    if kind == 0:
        t[0] = r.pick(BAD_DATES[:12]) + t[0][10:]
    elif kind == 1:
        t.append("  Expenses:Fun  1.00 USD")
    elif kind == 2:
        t[:] = [x.replace("Expenses:Food", "Expenses:Nope").replace("Assets:Cash", "Assets:Nowhere") for x in t]
    elif kind == 3:
        t[:] = [x.replace(" USD", " XXX", 1) if x.startswith((" ", "\t")) else x for x in t]
    elif kind == 4:
        t[:] = [re.sub(r"\s+USD$", "", x) if x.startswith((" ", "\t")) else x for x in t]
    elif kind == 5:
        del t[1:2]
        del t[1:2]
    elif kind == 6:
        t[:] = [re.sub(r"^(\s+\S+)\s+-?[\d.]+\s+[A-Z]{3}", r"\1", x) for x in t]
    elif kind == 7:
        t[1] = t[1].strip()
    elif kind == 8:
        t[0] = t[0].replace('"', "", 1)
    elif kind == 9:
        t[0] = re.sub(r'"([^"]*)"', r'"\1\\n"', t[0], count=1)
    elif kind == 10:
        t[:] = [x.replace("USD", "12.505 USD", 1) if x.startswith((" ", "\t")) and "USD" in x else x for x in t]
    elif kind == 11:
        t[:] = [re.sub(r"(-?\d+)\.(\d+)", r"\1,\2", x, count=1) if x.startswith((" ", "\t")) else x for x in t]
    elif kind == 12:
        t[0] = t[0].replace(" ", " $ ", 1)
    elif kind == 13:
        t.append("  Expenses:Food  5.00 USD extra")
    elif kind == 14:
        t.insert(1, "  Expenses:Old  1.00 USD")
        t.append("  Assets:Cash  -1.00 USD")
    elif kind == 15:
        blocks.insert(0, ["  Assets:Cash 5.00 USD"])
    elif kind == 16:
        blocks.insert(1 if blocks else 0, ["account Assets:Cash"])
    elif kind == 17:
        blocks.insert(r.below(len(blocks) + 1), [r.pick(["rate 2024-03-01 USD USD 1", "rate 2024-03-01 USD EUR 0",
                                                        "rate 2024-03-01 USD EUR .5", "rate 2024-03-01 USD EUR 1.123456789",
                                                        "rate 2024-03-01 USD EUR -1", "rate 2024-03-01 USD XXX 1.5",
                                                        "rate 2024-02-30 USD EUR 1.5", "rate 2024-03-01 USD EUR"])])
    elif kind == 18:
        blocks.insert(r.below(len(blocks) + 1), [r.pick(["account assets:Bank", "account Assets:Bank EUR open 2024-02-30",
                                                        "account Assets:Bank2 close 2023-01-01 open 2024-01-01",
                                                        "account Assets:Bank3 XXX", "account", "account Assets:Bank4 open",
                                                        "account Assets:Bank5 \"unclosed", "foo bar", "2024-03-01",
                                                        "balance Assets:Cash 5.00 USD"])])
    elif kind == 19:
        blocks.insert(r.below(len(blocks) + 1), ["", "\t", "  ; only a comment"])
    elif kind == 20 and txs:
        t[0] = t[0] + " " + r.pick(["#", "#-x", "#a b", "'x'"])
    else:
        t[0] = "2024-03-01 ? " + quote("Odd")


def gen_journal(r, bad=12, tiny=None, n=None, closed=True, rates=True, pair=None):
    """Journal text (str) plus its structure: (text, number of transactions)."""
    tiny = r.pct(25) if tiny is None else tiny
    blocks = []
    for path, cur in BOOK_ACCOUNTS:
        parts = ["account " + path]
        if cur and r.pct(70):
            parts.append(cur)
        if r.pct(70):
            parts.append("open " + r.pick(["2023-01-01", "2022-06-30", "2023-06-30"]))
        note = r.pick(ACCOUNT_NOTES)
        if note and r.pct(60):
            parts.append(quote(note))
        blocks.append([" ".join(parts) + r.pick(["", "", "  ; c"])])
    if closed and r.pct(40):
        blocks.append(["account Expenses:Old open 2023-01-01 close 2023-12-31"])
    if rates:
        for _ in range(r.below(5)):
            src, dst = r.pick(RATE_PAIRS)
            blocks.append(["rate %s %s %s %s" % (r.pick(["2024-01-01", "2024-02-15", "2024-03-01", "2023-12-31", "2024-05-31"]),
                                                  src, dst, r.pick(RATE_TEXTS))])
    if pair and r.pct(85):
        blocks.append(["rate %s %s %s %s" % (r.pick(["2024-01-01", "2024-02-15", "2023-12-31"]), pair[0], pair[1], r.pick(RATE_TEXTS))])
    count = r.below(14) if n is None else n
    for _ in range(count):
        blocks.append(gen_tx(r, tiny))
    if r.pct(bad):
        mistake(r, blocks)
    lines = []
    for b in blocks:
        lines.extend(b)
        if r.pct(70):
            lines.append(r.pick(["", "", "  ", "\t", "; note", "# note"]))
    return join_lines(r, lines), count


def tie_journal(r):
    """A small book built so that rounding to a tenth of a percent, or converting at a rate, lands exactly on a half:
    a salary, and two expenses of odd cents that add up to 16, 80, 400 or 2000 cents (shares of 6.25 % ...), in one month."""
    lines = []
    for path, cur in BOOK_ACCOUNTS:
        lines.append("account " + path + (" " + cur if cur else "") + " open 2023-01-01")
    lines.append("")
    lines.append("rate 2024-01-01 USD EUR " + r.pick(["0.5", "0.125", "0.375", "0.625", "1.5"]))
    if r.pct(40):
        lines.append("rate 2024-01-01 USD JPY " + r.pick(["150.5", "0.5", "1.5"]))
    month = r.pick([3, 3, 3, 1, 2, 6, 4])
    total = r.pick([16, 80, 400, 2000, 16, 80])
    p1 = r.pick(list(range(1, total, 2)))
    parts = [("Expenses:Food", p1), (r.pick(["Expenses:Rent", "Expenses:Food:Dining", "Expenses:Travel"]), total - p1)]
    lines += ["", '2024-01-01 * "Opening"', "  Assets:Bank:Checking  1000.00 USD", "  Equity:Opening"]
    income = r.pick([16, 80, 400, 2000, 100000])
    lines += ["", '2024-%02d-02 * "Acme"' % month, "  Assets:Bank:Checking  %s USD" % fmt_minor(income, 2),
              "  Income:Salary  %s USD" % fmt_minor(-income, 2)]
    for i, (acct, cents) in enumerate(parts):
        lines += ["", '2024-%02d-%02d * "Shop"' % (month, 3 + 2 * i), "  %s  %s USD" % (acct, fmt_minor(cents, 2)),
                  "  Assets:Bank:Checking  %s USD" % fmt_minor(-cents, 2)]
    return join_lines(r, lines), month


# --- the calc generators -----------------------------------------------------------------------
def calc_money(r):
    sub = r.pick(["parse", "parse", "format", "add", "sub", "scale", "scale", "scale", "allocate", "allocate", "convert", "convert", "convert"])
    if sub == "parse":
        return ["money", "parse", money(r)], {}
    if sub == "format":
        k = r.below(100)
        if k < 55:
            minor = str(r.below(100000) - 50000)
        elif k < 65:
            minor = str(10 ** 18 - 1 - r.below(5))
        elif k < 72:
            minor = "-" + str(10 ** 18 - 1 - r.below(5))
        elif k < 80:
            minor = "1" + "0" * r.pick([18, 19, 20])
        elif k < 90:
            minor = r.pick(["+5", "1.5", "", "abc", " 5", "--5", "1e3", "-", "0x1"])
        elif k < 94:
            minor = "000" + str(r.below(100))
        else:
            minor = str(r.below(10 ** 9))
        return ["money", "format", minor, r.pick(CUR) if r.pct(92) else r.pick(BAD_CUR)], {}
    if sub in ("add", "sub"):
        c = r.pick(COMMON_CUR)
        c2 = c if r.pct(80) else r.pick(CUR)
        return ["money", sub, money(r, c, 3), money(r, c2, 3)], {}
    if sub == "scale" and r.pct(55):
        # a tie by construction: m * 1 / (2k) with m = k * (2t + 1) is t + 1/2
        c = r.pick(COMMON_CUR)
        k = r.pick([1, 1, 2, 3, 5, 10, 25, 50, 100])
        m = k * (2 * r.below(20) + 1)
        sign = -1 if r.pct(40) else 1
        ratio = "%s1/%d" % (r.pick(["", "-"]), 2 * k) if r.pct(85) else "2/%d" % (4 * k)
        return ["money", "scale", fmt_minor(sign * m, EXP[c]) + " " + c, ratio], {}
    if sub == "scale":
        c = r.pick(COMMON_CUR)
        txt = fmt_minor(minor_pool(r, c, True) if not r.pct(50) else 2 * r.below(300) + 1, EXP[c]) + " " + c
        ratio = r.pick(["1/2", "3/2", "-1/2", "5/2", "1/4", "3/4", "1/10", "5/10", "25/100", "1/8", "7/8", "15/10", "-3/2",
                        "1/-2", "1/3", "2/3", "10/3", "7", "-7", "0", "0/5", "1/2", "1/2", "1/2", "3/2", "5/2", "-5/2",
                        "5/0", "1/0", "3/", "/3", "1/2/3", "1.5", "a/b", "1 /2", "+1/2", "-1/-2", "1/" + "9" * 18,
                        "9" * 18 + "/1", "1" + "0" * 18, "123456789012345678/987654321098765432"])
        return ["money", "scale", txt if r.pct(95) else money(r, c, 100), ratio], {}
    if sub == "allocate":
        c = r.pick(COMMON_CUR)
        weights = [r.pick(["0", "1", "1", "1", "2", "2", "3", "5", "7", "10", "100", "50"]) for _ in range(1 + r.below(6))]
        if r.pct(6):
            weights[r.below(len(weights))] = r.pick(["1.5", "-1", "a", "+2", "", "9" * 19])
        if r.pct(6):
            weights = []
        txt = fmt_minor(minor_pool(r, c, True), EXP[c]) + " " + c if r.pct(95) else money(r, c, 100)
        return ["money", "allocate", txt] + weights, {}
    if r.pct(50):
        sign = -1 if r.pct(35) else 1
        a, src, dst, rate = r.pick([(100, "USD", "JPY", "%d.5" % (100 + r.below(100))), (100, "USD", "EUR", r.pick(["0.125", "0.375", "0.625", "0.875"])),
                                    (100, "USD", "KRW", "%d.5" % (1000 + r.below(300))), (r.pick([1, 3, 5, 7, 9]), "JPY", "USD", "0.005"),
                                    (r.pick([5, 15, 25, 35]), "KWD", "USD", "1"), (300, "EUR", "JPY", "%d.5" % (50 + r.below(50))),
                                    (200, "GBP", "CHF", "1.2125"), (100, "USD", "EUR", "0.005")])
        return ["money", "convert", fmt_minor(sign * a, EXP[src]) + " " + src, dst, rate], {}
    c = r.pick(CUR if r.pct(30) else COMMON_CUR)
    to = r.pick([x for x in CUR if x != c]) if r.pct(88) else (c if r.pct(40) else r.pick(BAD_CUR))
    rate = r.pick(["150.5", "151.5", "0.125", "0.5", "1", "0.0067", "3.25", "0.92", "1.5", "2.5", "0.00000001",
                   "12345.12345678", "100", "0.375", "0.625", "1.125", "0.0001", "10", "0.9215", "1.00000001"])
    if r.pct(8):
        rate = r.pick(["0", "0.0", "-1.5", "+1.5", ".5", "1.", "1,5", "1e-3", "", "abc", "1.123456789", "0.000000000",
                       " 1.5", "1/2"])
    amt = fmt_minor(r.pick([1, 3, 5, 15, 25, 50, 100, 150, 1000, 99, 1234, 10000]) * (1 if r.pct(80) else -1), EXP[c]) + " " + c
    return ["money", "convert", amt if r.pct(94) else money(r, c, 100), to, rate], {}


def period_text(r, plain=False):
    k = r.below(100)
    if k < 66:
        return r.pick(GOOD_PERIODS)
    if plain:
        return good_date(r) + ".." + shift(good_date(r), r.below(100)) if r.pct(30) else r.pick(GOOD_PERIODS)
    if k < 76:
        return r.pick(EDGE_PERIODS)
    return r.pick(BAD_PERIODS)


def calc_dates(r):
    sub = r.pick(["parse", "add-months", "add-months", "add-months", "period", "period", "periods", "periods"])
    if sub == "parse":
        return ["date", "parse", date_text(r, 25)], {}
    if sub == "add-months":
        d = r.pick(MONTH_ENDS) if r.pct(60) else date_text(r, 8)
        n = r.pick(["0", "1", "-1", "2", "12", "-12", "13", "24", "48", "25", "-25", "3", "6", "11", "100", "-100", "1200",
                    "-1200", "120000", "1", "1", "-1", "--1", "+1", "1.5", "", "abc", " 1", "999999999999999999",
                    "-999999999999999999", "9999999999999999999", "-0", "00012"])
        return ["date", "add-months", d, n], {}
    if sub == "period":
        return ["date", "period", period_text(r)], {}
    d1 = date_text(r, 5)
    k = r.below(100)
    if k < 75:
        d2 = shift(d1, r.below(900)) if r.pct(90) else date_text(r, 3)
    elif k < 85:
        d2 = shift(d1, -1 - r.below(30))
    elif k < 92:
        d2 = d1
    else:
        d1, d2 = "0001-01-01", r.pick(["9999-12-31", "2200-01-01", "0500-01-01"])
    step = r.pick(STEPS) if r.pct(92) else r.pick(["day", "fortnight", "Month", "", "weeks", "MONTH"])
    if d1 == "0001-01-01" and step in ("week", "month"):
        step = r.pick(["quarter", "year"])
    return ["date", "periods", d1, d2, step], {}


def schedule_text(r):
    k = r.below(100)
    if k < 8:
        txt = "daily"
    elif k < 22:
        txt = "weekly on " + r.pick(DOWS)
    elif k < 44:
        txt = "monthly on " + r.pick([str(1 + r.below(31)), "last", "31", "30", "29", "1", "15", "last"])
    elif k < 52:
        txt = "yearly on " + r.pick(["03-15", "02-29", "12-31", "01-01", "06-30", "02-28", "07-05"])
    elif k < 80:
        unit = r.pick(["days", "weeks", "months", "years", "day", "week", "month", "year", "months", "month", "years"])
        txt = "every %d %s from %s" % (r.pick([1, 2, 3, 4, 6, 10, 12, 1, 2]), unit,
                                      r.pick(MONTH_ENDS) if unit.startswith(("month", "year")) and r.pct(65)
                                      else date_text(r, 0) if r.pct(70) else r.pick(EDGE_DATES))
    else:
        txt = r.pick(["daily on mon", "weekly", "monthly on 0", "monthly on 32", "weekly on someday", "yearly on 13-01",
                      "yearly on 02-30", "yearly on 3-15", "every 0 days from 2024-01-01", "every 2 weeks",
                      "every 2 fortnights from 2024-01-01", "every 2 weeks from 2024-02-30", "", "   ", "monthly",
                      "monthly on", "yearly on", "every -1 days from 2024-01-01", "every 1.5 days from 2024-01-01",
                      "monthly on 5th", "daily daily", "weekly on Mon Tue", "every 2 days 2024-01-01"])
    k2 = r.below(100)
    if k2 < 12:
        txt = txt.upper() if r.pct(50) else txt.title()
    elif k2 < 22:
        txt = re.sub(r" ", r.pick(["  ", "\t", "   "]), txt)
        txt = r.pick(["", " ", "\t"]) + txt + r.pick(["", " ", "  "])
    return txt


def calc_schedule(r):
    first = good_date(r, 2023, 2025) if r.pct(80) else r.pick(EDGE_DATES)
    k = r.below(100)
    span = r.pick([0, 7, 31, 62, 90, 100, 365, 800, 366, 60, 120, 400])
    to = shift(first, span) if k < 90 else (shift(first, -r.below(40)) if k < 95 else shift(first, 40001 + r.below(5)))
    argv = ["schedule", schedule_text(r)]
    opts = [("--from", first), ("--to", to)]
    if r.pct(45):
        opts.append(("--start", shift(first, r.below(200) - 100)))
    if r.pct(25):
        opts.append(("--end", shift(first, r.below(300))))
    if r.pct(25):
        opts.append(("--count", r.pick(["1", "2", "3", "5", "12", "0", "-1", "abc", "+3", "1000", "999999999999999999", ""])))
    if r.pct(3):
        opts[r.below(2)] = (opts[0][0], r.pick(BAD_DATES))
    if r.pct(2):
        opts.append(("--from", first))
    for name, val in opts:
        argv += [name, val] if r.pct(88) else ["%s=%s" % (name, val)]
    return argv, {}


def acct_path(r, bad=8):
    if r.pct(bad):
        segs = [r.pick(ROOTS + ["Savings", "assets", ""])] + [r.pick(GOOD_SEGS + BAD_SEGS) for _ in range(r.below(3))]
        return ":".join(segs)
    return ":".join([r.pick(ROOTS)] + [r.pick(GOOD_SEGS) for _ in range(r.below(4))])


def pattern_text(r):
    k = r.below(100)
    if k < 45:
        return acct_path(r, 3)
    segs = [r.pick(ROOTS + ["*", "**"])] + [r.pick(GOOD_SEGS + ["*", "*", "**"]) for _ in range(r.below(4))]
    if k > 90:
        segs[r.below(len(segs))] = r.pick(["F*", "***", "", "fo", "*a"])
    return ":".join(segs)


def calc_account(r):
    if r.pct(45):
        return ["account", "check", acct_path(r, 25)], {}
    pat = pattern_text(r)
    path = acct_path(r, 5) if r.pct(60) else (":".join(pat.split(":")[:1] + [r.pick(GOOD_SEGS) for _ in range(r.below(3))]))
    return ["account", "match", pat, path], {}


# rules files
REGEXES = ["nero", "^rent\\b", "coffee|tea", "a.c", "(?-i:Acme)", "^$", "\\d+", "[a-z]+s$", "x*", "(foo|bar)+baz", "caf",
           "^a", "e$", "\\bshop\\b", "(?i)nero", "[", "(", "*abc"]
RULE_ACTIONS = ["account Expenses:Food", "account Income:Salary", "tag coffee", "tag Coffee", "tag a_b-1", "flag *", "flag !",
                'narration "Coffee break"', 'narration ""', 'payee "Acme Ltd"', "account Assets:Bank:Checking"]


def rule_cond(r):
    k = r.below(100)
    sp = r.pick([" ", " ", " ", "", "  "])
    if k < 30:
        f, op = r.pick(["payee", "narration"]), r.pick(["=", "!=", "~", "!~", "~", "~"])
        val = r.pick(REGEXES[:15]) if "~" in op else r.pick(PAYEES + NARRATIONS).replace("\\", "").replace("\t", " ")
        if r.pct(4):
            val = r.pick(REGEXES[15:])
        return "%s%s%s%s%s" % (f, sp, op, sp, '"' + val.replace('"', '\\"') + '"')
    if k < 65:
        v = r.pick(["0", "-5", "10.00", "+3.5", "-500.00", "1000", "3.40", "-3.40", "12.5", "0.00"])
        if r.pct(25):
            v += r.pick(["USD", "GBP", "EUR", "JPY"])
        return "amount%s%s%s%s" % (sp, r.pick(["<", "<=", ">", ">=", "=", "!="]), sp, v)
    return "date%s%s%s%s" % (sp, r.pick(["<", "<=", ">", ">=", "=", "!="]), sp, r.pick(EDGE_DATES + ["2024-01-01", "2024-02-01"]))


def rule_line(r):
    k = r.below(100)
    if k < 5:
        conds = "any"
    else:
        conds = " and ".join(rule_cond(r) for _ in range(1 + r.below(3)))
    acts = []
    pool = list(RULE_ACTIONS)
    for _ in range(1 + r.below(3)):
        a = r.pick(pool)
        if a.split()[0] != "tag":
            pool = [x for x in pool if x.split()[0] != a.split()[0]]
        acts.append(a)
    line = "when %s then %s" % (conds, " ".join(acts))
    if r.pct(8):
        line = r.pick([line.replace("when", "When", 1), line.replace(" then", "", 1), "when then account Expenses:Food",
                       "when payee ~ coffee then tag x", "when amount < then tag x", "when payee < \"x\" then tag x",
                       "when any and amount < 0 then tag x", "when any then", "when any then tag", "when any then account",
                       "when any then account expenses", "when any then flag ?", "when any then tag -x",
                       "when any then flag * flag !", 'when any then payee ""', 'when any then payee "  "',
                       "when date = 2024-02-30 then tag x", 'when payee = "x then tag x', "when amount ~ \"1\" then tag x",
                       "when any then account Expenses:Food account Expenses:Fun", "when foo = 1 then tag x",
                       "when any then colour red", "when any then tag x extra", line + " trailing"])
    return line


def rules_text(r, eols=JEOLS):
    lines = []
    for _ in range(1 + r.below(6)):
        lines.append(rule_line(r))
        if r.pct(25):
            lines.append(r.pick(["", "  ", "# a comment", "   # indented", "#"]))
    return join_lines(r, lines, eols)


def calc_rules(r):
    text = rules_text(r)
    argv = ["rules", "rules.txt"]
    for name, val in (("--payee", r.pick(PAYEES)), ("--narration", r.pick(NARRATIONS)),
                      ("--amount", good_money(r, r.pick(["USD", "GBP", "EUR"])) if r.pct(92) else money(r, None, 100)),
                      ("--date", date_text(r, 6))):
        if r.pct(55):
            argv += [name, val]
    if r.pct(2):
        argv = ["rules", "rules.txt", "--payee"]
    return argv, {"rules.txt": file_bytes_hex(r, text)}


# queries
def q_term(r, depth):
    k = r.below(100)
    if k < 12:
        return "payee:" + r.pick(SEARCH_WORDS)
    if k < 20:
        return "narration:" + r.pick(["weekly", "march", "x", "pay", "coffee"])
    if k < 27:
        return "tag:" + r.pick(TAGS + ["Coffee", "nothing"])
    if k < 35:
        return "date:" + r.pick(GOOD_PERIODS)
    if k < 43:
        return "date%s%s%s%s" % (r.pick(["", " "]), r.pick(["<", "<=", ">", ">=", "=", "!="]), r.pick(["", " "]),
                                 r.pick(EDGE_DATES + ["2024-03-01"]))
    if k < 47:
        return "flag:" + r.pick(QUERY_FLAGS)
    if k < 50:
        return "id:" + str(r.below(12))
    if k < 62:
        return "account:" + r.pick(["Expenses", "Expenses:Food", "Expenses:*", "Assets", "Assets:**", "**:Dining",
                                    "Assets:Bank:Checking", "Income", "Liabilities", "Equity", "Expenses:Food:Dining",
                                    "Assets:*", "**", "Expenses:Fo", "Assets:Cash"])
    if k < 76:
        return "amount%s%s%s%s%s" % (r.pick(["", " "]), r.pick(["<", "<=", ">", ">=", "=", "!="]), r.pick(["", " "]),
                                    r.pick(["0", "5", "10.00", "-5", "+5", "12.5", "100", "0.05", "3.50"]),
                                    r.pick(["", "", "", "USD", "EUR"]))
    if k < 86:
        return r.pick(SEARCH_WORDS)
    if k < 92:
        return '"' + r.pick(["blue bottle", "corner shop", "café", "say \\\"hi\\\"", "a\\\\b", "x y"]) + '"'
    if k < 95 and depth < 2:
        return "(" + q_expr(r, depth + 1) + ")"
    return "payee:" + '"' + r.pick(["Corner Shop", "Café Zoë", "acme"]) + '"'


def q_unit(r, depth):
    return ("not " if r.pct(15) else "") + q_term(r, depth)


def q_expr(r, depth=0):
    parts = [q_unit(r, depth)]
    for _ in range(r.below(4)):
        parts.append(r.pick(["and", "or", "", "", "AND", "Or"]))
        parts.append(q_unit(r, depth))
    return " ".join(p for p in parts if p)


BAD_QUERIES = ["colour:red", "amount:5", "payee:", "amount>", "id:abc", "flag:x", "date:2024-3", "date:2024-13",
               "amount>x", "account:Fo*", "account:Expenses::Food", '"abc', '"abc"def', '""', "a and", "or a", "()", "not",
               "(payee:x", "payee:x)", ")", "(", "a b)", "amount>1.", "account:", "tag:", "date>=2024-3-1", "date>=x",
               "payee:x and ", "account:Nowhere", "account:Savings:Nothing", "id:-1", "flag:", "amount>1 USD",
               "amount>1usd", "narration:", "date:", "payee:\"\""]


def query_text(r):
    return r.pick(BAD_QUERIES) if r.pct(14) else (q_expr(r) if not r.pct(5) else r.pick(["", "  ", " \t "]))


def journal_case(r, bad=10, pair=None):
    text, _ = gen_journal(r, bad, pair=pair)
    return {"journal.txt": file_bytes_hex(r, text, 8, 1)}


def stdin_or_file(r, files, path_name, argv_fn, p=4):
    """Make a command read its file `path_name` from standard input now and then."""
    if r.pct(p):
        return argv_fn("-"), files.pop(path_name)
    return argv_fn(path_name), None


def calc_journal_cmd(r):
    sub = r.pick(["check", "check", "format", "format", "query", "query", "query", "rate", "budget", "budget", "report",
                  "report", "report", "report", "report"])
    pair = r.pick(RATE_PAIRS) if sub == "rate" and r.pct(80) else None
    files = journal_case(r, pair=pair)
    month = None
    if sub in ("budget", "report") and r.pct(55):
        text, month = tie_journal(r)
        files = {"journal.txt": file_bytes_hex(r, text, 8, 1)}
    jr = r.pct(2) and sub != "check" and sub != "format"
    jname = "missing.txt" if jr else "journal.txt"
    if r.pct(1) and not jr:
        jname = "."
    stdin = None
    if sub in ("check", "format"):
        argv = ["journal", sub, jname]
        if r.pct(4):
            argv[-1] = "-"
            stdin = files.pop("journal.txt")
        return argv, files, stdin
    if sub == "query":
        argv = ["query", query_text(r), "--journal", jname]
        if r.pct(30):
            argv.append("--json")
    elif sub == "rate":
        src, dst = pair if pair else (r.pick(COMMON_CUR), r.pick(COMMON_CUR))
        if r.pct(5):
            src = r.pick(BAD_CUR)
        if pair and r.pct(25):
            src, dst = dst, src
        argv = ["rate", src, dst, "--journal", jname, "--on", date_text(r, 5) if r.pct(15) else shift("2024-01-01", r.below(200))]
    elif sub == "budget":
        pat = r.pick(["Expenses:Food", "Expenses:*", "Expenses", "Expenses:*:Dining", "Expenses:Rent", "Income", "Expenses:Fun"])
        if r.pct(6):
            pat = r.pick(["**", "expenses", "Expenses:Fo*", "", "Expenses::Food", "Expenses:"])
        amt = r.pick(["4.00 USD", "8.00 USD", "400.00 USD", "300.00 USD", "100.00 USD", "1.00 USD", "1200 JPY", "0.20 USD",
                      "10000.00 USD", "900.00 USD", "2.00 USD", "0.40 USD", "20.00 USD"])
        if r.pct(5):
            amt = r.pick(["0.00 USD", "-5.00 USD", "5 usd", "5.00", "abc", "5.005 USD"])
        if month and r.pct(70):
            amt = r.pick(["4.00 USD", "4.00 USD", "4.00 USD", "8.00 USD", "2.00 USD", "0.40 USD", "16.00 USD", "1.60 USD"])
        period = ("2024-%02d" % month if r.pct(60) else r.pick(["2024-Q1", "2024-Q2", "2024"])) if month and r.pct(75) else period_text(r, True)
        if r.pct(8):
            amt, period = r.pick(["0.01 USD", "0.05 USD", "0.03 USD"]), r.pick(["2023-02-01..2023-02-14", "2023-02-01..2023-02-14", "2024-04-01..2024-04-15"])
        argv = ["budget", pat, amt, "--journal", jname, "--period", period]
        if r.pct(40):
            argv += ["--per", r.pick(["month", "quarter", "year", "month", "week"] if r.pct(90) else ["week", "Month", ""])]
        if r.pct(25):
            argv += ["--start", date_text(r, 5) if r.pct(30) else good_date(r, 2023, 2025)]
        if r.pct(30):
            argv.append("--json")
    else:
        kind = r.pick(["trial-balance", "balance-sheet", "balance-sheet", "income-statement", "income-statement", "cashflow",
                       "cashflow", "register", "register"])
        if r.pct(2):
            kind = r.pick(["networth", "Trial-Balance", ""])
        argv = ["report", kind]
        if kind == "register" or (r.pct(3) and kind != "register"):
            argv.append(r.pick(["Assets:Bank:Checking", "Expenses:Food", "Assets", "Expenses", "Assets:Cash", "Income:Salary",
                                "Liabilities:Card", "Equity:Opening", "Expenses:Food:Dining"]) if r.pct(92) else acct_path(r, 60))
        argv += ["--journal", jname]
        if r.pct(55):
            argv += ["--as-of", date_text(r, 5) if r.pct(40) else shift("2024-01-01", r.below(250))]
        if month and kind in ("income-statement", "cashflow", "balance-sheet", "register") and r.pct(75):
            argv += ["--period", "2024-%02d" % month] if r.pct(70) else ["--as-of", "2024-%02d-28" % month]
        elif r.pct(55):
            argv += ["--period", period_text(r, True) if r.pct(92) else period_text(r)]
        if r.pct(30 if not month else 45):
            argv += ["--convert", r.pick(["EUR", "USD", "GBP", "JPY", "EUR", "KWD"] if r.pct(94) else BAD_CUR)]
        if r.pct(25):
            argv.append("--rollup")
        if r.pct(30):
            argv.append("--json")
    if r.pct(3):
        pass
    if "--journal" in argv and argv[argv.index("--journal") + 1] == "journal.txt" and r.pct(4):
        argv[argv.index("--journal") + 1] = "-"
        stdin = files.pop("journal.txt")
    return argv, files, stdin


# bank CSV
DATE_FORMATS = ["%Y-%m-%d", "%d.%m.%Y", "%m/%d/%Y", "%d/%m/%y", "%d %b %Y", "%B %d, %Y", "%d-%b-%y", "%Y/%m/%d", "%%%Y-%m-%d"]


def fmt_date_by(fmt, d):
    out, i = "", 0
    while i < len(fmt):
        if fmt[i] == "%" and i + 1 < len(fmt):
            c = fmt[i + 1]
            i += 2
            if c == "Y":
                out += "%04d" % d.year
            elif c == "y":
                out += "%02d" % (d.year % 100)
            elif c == "m":
                out += "%02d" % d.month
            elif c == "d":
                out += "%02d" % d.day
            elif c == "b":
                out += MONTHS[d.month - 1]
            elif c == "B":
                out += FULL_MONTHS[d.month - 1]
            else:
                out += "%"
        else:
            out += fmt[i]
            i += 1
    return out


def csv_cell(s, delim):
    if any(c in s for c in (delim, '"', "\n", "\r")) or (s != s.strip() and delim != " "):
        return '"' + s.replace('"', '""') + '"'
    return s


def group_digits(whole, sep):
    out = ""
    while len(whole) > 3:
        out = sep + whole[-3:] + out
        whole = whole[:-3]
    return whole + out


def gen_profile_and_csv(r, clean=False):
    """(profile text, statement text, extra profile facts) for a bank statement with a random layout."""
    delims = [(",", ","), (";", ";"), ("\t", "tab"), ("|", "pipe"), (" ", "space"), (",", "comma"), (";", "semicolon")]
    delim, delim_word = r.pick(delims) if r.pct(45) else (",", None)
    cur = r.pick(["USD", "USD", "EUR", "JPY", "KWD", "GBP"]) if not clean else r.pick(["USD", "USD", "USD", "USD", "JPY", "KWD"])
    exp = EXP[cur]
    has_header = not r.pct(12)
    dfmt = r.pick(DATE_FORMATS) if r.pct(55) else "%Y-%m-%d"
    dec = "," if r.pct(30) and exp else "."
    thou = r.pick(["", "", "", "comma", "dot", "space", "apostrophe", ".", ",", "none", " "]) if r.pct(45) else ""
    thou_char = {"comma": ",", "dot": ".", "space": " ", "apostrophe": "'", "none": "", "": ""}.get(thou, thou)
    if thou_char == dec:
        thou, thou_char = "", ""
    two_col = r.pct(20)
    negate = r.pct(15)
    skip = r.pick([0, 0, 0, 1, 2])
    columns = ["Date", "Payee", "Description", "Amount"] if not two_col else ["Date", "Payee", "Description", "Debit", "Credit"]
    if r.pct(20):
        columns.append("Ref")
    ncols = len(columns)
    pos = {name: i + 1 for i, name in enumerate(columns)}

    def col(name):
        if not has_header:
            return "#%d" % pos[name]
        return r.pick(['"%s"' % name, name, name.lower(), name.upper(), "#%d" % pos[name]]) if r.pct(30) else name

    prof = []
    prof.append("date_column = " + col("Date"))
    prof.append("payee_column = " + col("Payee"))
    if r.pct(70):
        prof.append("narration_column = " + col("Description"))
    if two_col:
        prof.append("debit_column = " + col("Debit"))
        prof.append("credit_column = " + col("Credit"))
    else:
        prof.append("amount_column = " + col("Amount"))
    prof.append("currency = " + cur)
    prof.append("account = Assets:Bank:Checking")
    if r.pct(75 if not clean else 92):
        prof.append("default_account = " + r.pick(["Expenses:Misc", "Expenses:Food", "Expenses:Uncategorized"]))
    if dfmt != "%Y-%m-%d" or r.pct(20):
        prof.append("date_format = " + dfmt)
    if delim_word:
        prof.append("delimiter = " + delim_word)
    elif delim != ",":
        prof.append("delimiter = " + delim)
    if skip or r.pct(5):
        prof.append("skip_rows = %d" % skip)
    if not has_header:
        prof.append("has_header = " + r.pick(["no", "false", "NO", "False"]))
    elif r.pct(10):
        prof.append("has_header = " + r.pick(["yes", "true", "YES"]))
    if negate:
        prof.append("negate = yes")
    if dec != ".":
        prof.append("decimal_separator = " + dec)
    if thou:
        prof.append("thousands_separator = " + ('" "' if thou == " " else thou))
    if r.pct(15):
        prof.append("flag = " + r.pick(["*", "!"]))
    if r.pct(25):
        prof.append("tags = " + r.pick(["imported", "Bank,Q1", "a, b ,c", "x1,x1"]))
    if r.pct(8):
        prof.insert(r.below(len(prof) + 1), r.pick(["# a comment", "", "   "]))
    if r.pct(5 if not clean else 1):
        prof.insert(r.below(len(prof) + 1), r.pick(["date_column = Date", "foo = bar", "no equals", "skip_rows = -1",
                                                    "currency = ZZZ", "account = assets:x", "date_format = %Y-%m",
                                                    "delimiter = ab", "has_header = maybe", "negate = 1",
                                                    "decimal_separator = ;", "thousands_separator = xx", "flag = ?",
                                                    "tags = bad tag", "date_column = #0", "date_format = %Y-%m-%d-%d"]))
    if r.pct(3 if not clean else 0):
        prof = [p for p in prof if not p.startswith(("date_column", "currency", "account"))] + ["currency = " + cur]
    ptext = join_lines(r, prof)
    # the statement
    rows = []
    n = r.below(9)
    base = date(2024, 1 + r.below(5), 1 + r.below(27))
    for i in range(n):
        d = base + timedelta(days=r.below(40))
        minor = minor_pool(r, cur) if not r.pct(30) else r.pick([-1, -5, -1234, 5000, 123456, -123456789])
        minor = minor if r.pct(50) else -abs(minor)
        if r.pct(15):
            minor = r.pick([-3, 5, 25, 1])
        a = abs(minor)
        whole, frac = (fmt_minor(a, exp).split(".") + [""])[:2]
        if thou_char and len(whole) > 3 and r.pct(80):
            whole = group_digits(whole, thou_char)
        txt = whole + ((dec + frac) if exp else "")
        sign = "" if minor >= 0 else "-"
        if minor > 0 and r.pct(10):
            sign = "+"
        amount_cell = sign + txt
        if minor < 0 and r.pct(12):
            amount_cell = "(" + txt + ")"
        dcell, ccell = (txt if minor < 0 else ""), (txt if minor > 0 else "")
        if two_col and r.pct(6):
            dcell, ccell = txt, txt
        datecell = fmt_date_by(dfmt, d)
        if "%b" in dfmt and r.pct(30):
            datecell = datecell.upper() if r.pct(50) else datecell.lower()
        payee = r.pick(["Shop", "CAFE NERO 0412 LONDON", "ACME PAYROLL", "Café Zoë", "Rent Co", "Bob, the \"baker\"",
                        "two\nlines", "  spaced   out  ", "Market", "日本語", "a;b|c", "Shop"])
        desc = r.pick(["", "", "ref 12", "rent march", "multi\nline", "x  y", "café"])
        if r.pct(6 if not clean else 1):
            k = r.below(8)
            if k == 0:
                datecell = r.pick(["2024-02-30", "31.02.2024", "x", "", "2024-13-01", "1/2/3"])
            elif k == 1:
                amount_cell = txt = r.pick(["1.505", "abc", "", "12.34.56", "1,2,3", "0", "0.00", "-", "1e3", "5.", ".5"])
                dcell, ccell = txt, ""
            elif k == 2:
                payee = r.pick(["", "   "])
            elif k == 3:
                pass
            elif k == 4:
                dcell = ccell = ""
        cells = {"Date": datecell, "Payee": payee, "Description": desc, "Amount": amount_cell, "Debit": dcell,
                 "Credit": ccell, "Ref": "r%d" % i}
        row = [cells[c] for c in columns]
        if r.pct(5):
            row = row[:r.below(len(row))]
        if r.pct(4):
            row.append("extra")
        rows.append(row)
        if r.pct(12):
            rows.append(list(row))
    lines = []
    for _ in range(skip):
        lines.append(r.pick(["junk line", "Account statement, 2024", "", "a;b;c"]))
    if has_header:
        lines.append(delim.join(csv_cell(c, delim) for c in (columns if r.pct(60) else [c.upper() for c in columns])))
    for row in rows:
        if r.pct(6):
            lines.append(r.pick(["", delim * 2, "  "]))
        lines.append(delim.join(csv_cell(c, delim) for c in row))
    text = join_lines(r, lines, EOLS if r.pct(20) else JEOLS)
    return ptext, text


def calc_csv(r):
    ptext, ctext = gen_profile_and_csv(r)
    files = {"profile.txt": file_bytes_hex(r, ptext, 6, 1), "statement.csv": file_bytes_hex(r, ctext, 8, 1)}
    argv = ["csv", "profile.txt", "statement.csv"]
    if r.pct(40):
        files["rules.txt"] = file_bytes_hex(r, rules_text(r))
        argv += ["--rules", "rules.txt"]
    stdin = None
    if r.pct(4):
        which = r.pick(["profile.txt", "statement.csv"])
        argv[argv.index(which)] = "-"
        stdin = files.pop(which)
    if r.pct(3):
        argv[2] = "missing.csv"
    return argv, files, stdin


def usage_mistake(r):
    """A well-formed command line with exactly one mistake in the command line itself (exit status 2)."""
    templates = [
        (["money", "parse", "12.50 USD"], {}), (["money", "add", "1.00 USD", "2.00 USD"], {}),
        (["money", "scale", "10.00 USD", "1/3"], {}), (["money", "allocate", "100.00 USD", "1", "1"], {}),
        (["money", "convert", "10.00 USD", "JPY", "150.5"], {}), (["date", "parse", "2024-03-01"], {}),
        (["date", "add-months", "2024-01-31", "1"], {}), (["date", "period", "2024-Q1"], {}),
        (["date", "periods", "2024-01-01", "2024-03-01", "month"], {}),
        (["schedule", "daily", "--from", "2024-01-01", "--to", "2024-01-05"], {}),
        (["account", "check", "Assets:Bank"], {}), (["account", "match", "Assets", "Assets:Bank"], {}),
        (["journal", "format", "journal.txt"], {"journal.txt": hexs("account Assets:Cash\n")}),
        (["query", "payee:x", "--journal", "journal.txt", "--json"], {"journal.txt": hexs("account Assets:Cash\n")}),
        (["report", "trial-balance", "--journal", "journal.txt"], {"journal.txt": hexs("account Assets:Cash\n")}),
        (["rules", "rules.txt", "--payee", "x"], {"rules.txt": hexs("when any then tag a\n")}),
    ]
    argv, files = r.pick(templates)
    argv = list(argv)
    k = r.below(10)
    if k == 0:
        argv.pop()
    elif k == 1:
        argv.append("surplus")
    elif k == 2:
        argv.append("--bogus")
    elif k == 3:
        argv = argv[:1] + ["nope"] + argv[1:] if argv[0] in ("money", "date", "account", "journal") else ["nosuch"] + argv
    elif k == 4:
        argv.append("--json=1")
    elif k == 5:
        argv = argv[:1] if argv[0] in ("money", "date", "account", "journal") else argv + ["--journal", "journal.txt"] * 2
    elif k == 6:
        argv = argv + [argv[-2], argv[-1]] if len(argv) > 3 and argv[-2].startswith("--") else argv + ["--from", "2024-01-01"] * 2
    elif k == 7:
        argv = []
    elif k == 8:
        argv = argv + ["--", "extra"]
    else:
        argv = [argv[0]]
    return argv, files


def calc_case(r):
    k = r.below(100)
    stdin = None
    files = {}
    if k < 4:
        argv, files = usage_mistake(r)
    elif k < 24:
        argv, files = calc_money(r)
    elif k < 38:
        argv, files = calc_dates(r)
    elif k < 46:
        argv, files = calc_schedule(r)
    elif k < 51:
        argv, files = calc_account(r)
    elif k < 58:
        argv, files = calc_rules(r)
    elif k < 65:
        argv, files, stdin = calc_csv(r)
    else:
        argv, files, stdin = calc_journal_cmd(r)
    head = []
    needs_today = argv[:1] == ["report"]
    t = r.below(100)
    if t < 6 and not needs_today:
        head = []
    elif t < 8:
        head = ["--today", r.pick(["2024-03-31", "2024-02-29", "2023-12-31"])]
    else:
        head = ["--today", TODAY]
    if r.pct(3):
        head = ["--db", "nowhere/book.db"] + head
    if r.pct(1):
        head = ["--today", r.pick(BAD_DATES[:6])] + (head[2:] if head[:1] == ["--today"] else head)
    closed = r.pct(3) and argv[:2] not in (["money", "parse"],)
    return {"kind": "calc", "argv": head + ["calc"] + argv, "files": files, "stdin_hex": stdin, "closed_stdout": closed}


# --- the book (database flow) cases ------------------------------------------------------------
GLOBALS = ["--db", "book.db", "--today", TODAY]
FLOW_ACCOUNTS = BOOK_ACCOUNTS
KNOWN_ACCOUNTS = [a for a, _ in FLOW_ACCOUNTS]


def S(*argv, stdin=None, save=None):
    step = {"argv": GLOBALS + [str(a) for a in argv]}
    if stdin is not None:
        step["stdin_hex"] = stdin
    if save is not None:
        step["save"] = save
    return step


class Flow:
    """A script of CLI steps against one book, with the files they read."""

    def __init__(self, r):
        self.r, self.steps, self.files, self.n, self.closed = r, [], {}, 0, []

    def add(self, *argv, **kw):
        self.steps.append(S(*argv, **kw))

    def manual_book(self, dated=None, free=False):
        """init, then one journal import of a small book with the accounts of FLOW_ACCOUNTS and the given transactions
        (payee, date, first posting with its amount, the account that gets the rest)."""
        r = self.r
        self.add("init")
        txs = dated or [("Opening", "2024-01-01", "Assets:Bank:Checking 1000.00 USD", "Equity:Opening"),
                        ("Acme", "2024-03-01", "Assets:Bank:Checking 2500.00 USD", "Income:Salary"),
                        ("Market", "2024-03-02", "Expenses:Food 42.50 USD", "Assets:Bank:Checking")]
        lines = []
        for path, cur in FLOW_ACCOUNTS:
            lines.append("account " + path + (" " + cur if cur and not free and r.pct(60) else "") + " open 2023-01-01")
        for payee, d, a, b in txs:
            lines += ["", '%s * "%s"' % (d, payee), "  " + a.replace(" ", "  ", 1), "  " + b]
        self.files["seed.journal"] = hexs("\n".join(lines) + "\n")
        self.add("journal", "import", "seed.journal")
        self.n = len(txs)

    def journal_book(self, bad=4, tie=False):
        r = self.r
        self.add("init")
        if tie:
            text, _ = tie_journal(r)
            n = 4
        else:
            text, n = gen_journal(r, bad, rates=r.pct(80), pair=("USD", "EUR"))
        self.files["journal.txt"] = file_bytes_hex(r, text, 5, 0)
        if r.pct(8):
            self.steps.append(S("journal", "import", "-", stdin=self.files.pop("journal.txt")))
        else:
            self.add("journal", "import", "journal.txt")
        self.n = n

    def tx_add(self, bad=12, dated=None):
        r = self.r
        payee = r.pick(PAYEES) if r.pct(80) else "Shop"
        args = ["tx", "add", payee]
        d = dated or ("2024-%02d-%02d" % (1 + r.below(6), 1 + r.below(28)) if r.pct(75) else r.pick(TX_EDGE_DATES))
        if r.pct(8):
            d = None
        if d is not None:
            args += ["--date", d]
        if r.pct(30):
            args += ["--narration", r.pick(NARRATIONS) or "n"]
        if r.pct(15):
            args += ["--flag", r.pick(["*", "!"])]
        for _ in range(r.pick([0, 0, 1, 2])):
            args += ["--tag", r.pick(TAGS)]
        cur = r.pick(["USD", "USD", "EUR"])
        pool = [a for a, c in FLOW_ACCOUNTS if c in (None, cur) and not a.startswith("Equity")]
        a, b = r.pick(pool), r.pick(pool)
        if a == b:
            b = pool[(pool.index(a) + 1) % len(pool)]
        m = minor_pool(r)
        sp = r.pick([" ", "  ", " ", "\t"])
        p1 = "%s%s%s%s%s" % (a, sp, fmt_minor(m, 2), sp, cur) + (r.pick(["", "", " ; note", ";", " ;  café "]))
        p2 = b if r.pct(30) else "%s %s %s" % (b, fmt_minor(-m, 2), cur)
        good = True
        if r.pct(bad):
            good = False
            k = r.below(14)
            if k == 0:
                p2 = "%s %s %s" % (b, fmt_minor(-m - 1, 2), cur)
            elif k == 1:
                p2 = "Expenses:Nope " + fmt_minor(-m, 2) + " " + cur
            elif k == 2:
                p2 = None
            elif k == 3:
                p1, p2 = a, b
            elif k == 4:
                p2 = "%s %s" % (b, fmt_minor(-m, 2))
            elif k == 5:
                p2 = "%s %s %s extra" % (b, fmt_minor(-m, 2), cur)
            elif k == 6:
                p1 = "Assets:Bank:Checking %s EUR" % fmt_minor(m, 2)
                p2 = "Equity:Opening %s EUR" % fmt_minor(-m, 2)
            elif k == 7:
                args += ["--flag", "?"]
            elif k == 8:
                args += ["--tag", "bad tag"]
            elif k == 9:
                args += ["--date", r.pick(BAD_DATES[:8])]
            elif k == 10:
                p2 = "%s %s %s" % (b, fmt_minor(-m, 2), "usd")
            elif k == 11:
                p1 = ""
            elif k == 12:
                p2 = "Expenses:Old %s %s" % (fmt_minor(-m, 2), cur)
            else:
                args = args[:3] + ["--bogus"] + args[3:]
        args += ["-p", p1] if r.pct(85) else ["--posting", p1]
        if p2 is not None:
            args += ["-p", p2]
        if r.pct(15):
            args.append("--json")
        self.add(*args)
        if good:
            self.n += 1

    def listing(self):
        r = self.r
        k = r.below(5)
        if k < 2:
            args = ["tx", "list"]
            if r.pct(50):
                args += ["--query", query_text(r)]
        elif k < 4:
            args = ["query", query_text(r)]
            if r.pct(30):
                args.append("--count")
        else:
            args = ["tx", "list"]
        if "--count" not in args:
            if r.pct(35):
                args += ["--limit", r.pick(["0", "1", "2", "5", "100", "-1", "abc", "9" * 18, "9" * 19, "+3"])]
            if r.pct(35):
                args += ["--offset", r.pick(["0", "1", "3", "50", "-1", "x", "1.5"])]
            if r.pct(30):
                args.append("--json")
        self.add(*args)

    def one_tx(self):
        r = self.r
        tid = r.pick([str(1 + r.below(self.n + 2)), str(1 + r.below(max(self.n, 1))), str(1 + r.below(max(self.n, 1))),
                      str(1 + r.below(max(self.n, 1))), str(1 + r.below(max(self.n, 1))), "0", "-1", "abc", "1.5", "007", "+1"])
        if r.pct(55):
            self.add("tx", "show", tid, *(["--json"] if r.pct(30) else []))
        else:
            self.add("tx", "delete", tid)

    def account_op(self):
        r = self.r
        k = r.below(7)
        if k == 0:
            args = ["account", "list"]
            if r.pct(40):
                args += ["--type", r.pick(["asset", "liability", "equity", "income", "expense", "bogus"])]
            if r.pct(30):
                args += ["--under", r.pick(["Assets", "Expenses:Food", "Expenses", "Income", "Liabilities"])]
            if r.pct(25):
                args += ["--currency", r.pick(["USD", "EUR", "JPY"])]
            if r.pct(25):
                args.append("--open-only")
            if r.pct(30):
                args.append("--json")
        elif k == 1 or k == 2:
            args = ["account", "show", r.pick(KNOWN_ACCOUNTS + ["Expenses:Nope", "assets:cash", "Assets:Cash:", ""])]
            if r.pct(30):
                args.append("--json")
        elif k == 3:
            left = [a for a in KNOWN_ACCOUNTS if a not in self.closed]
            target = r.pick(left) if left and r.pct(90) else "Expenses:Nope"
            args = ["account", "close", target]
            on = r.pick(["2024-06-30", "2024-03-01", "2023-06-30", "2024-02-30", "2024-12-31"]) if r.pct(70) else None
            if on:
                args += ["--on", on]
            if on not in ("2024-02-30", "2024-03-01", "2023-06-30") and target != "Expenses:Nope":
                self.closed.append(target)
        elif k == 4:
            args = ["account", "add", r.pick(["Assets:Savings", "Assets:Cash", "Expenses:Fun:Cinema", "assets:x", "Income",
                                              "Assets:New-One", "Savings:Bank", "Liabilities:Loan:Car"])]
            if r.pct(40):
                args += ["--currency", r.pick(["USD", "EUR", "usd", "ZZZ", "JPY"])]
            if r.pct(30):
                args += ["--open", r.pick(["2024-01-01", "2024-13-01", "2023-06-30"])]
        elif k == 5:
            args = ["account", "show", r.pick(KNOWN_ACCOUNTS)]
        else:
            args = ["account", "list", "--json"]
        self.add(*args)

    def report(self):
        r = self.r
        kind = r.pick(["trial-balance", "balance-sheet", "balance-sheet", "income-statement", "income-statement", "cashflow",
                       "register", "register"])
        args = ["report", kind]
        if kind == "register":
            args.append(r.pick(KNOWN_ACCOUNTS + ["Assets", "Expenses", "Expenses:Nope"]))
        if kind in ("trial-balance", "balance-sheet") and r.pct(45):
            args += ["--as-of", date_text(r, 4) if r.pct(30) else shift("2024-01-01", r.below(200))]
        if kind in ("income-statement", "cashflow", "register") and r.pct(60):
            args += ["--period", period_text(r, True)]
        if kind in ("balance-sheet", "income-statement") and r.pct(15):
            args += ["--convert", r.pick(["EUR", "USD", "JPY", "GBP", "xx"])]
        if kind == "register" and r.pct(30):
            args.append("--rollup")
        if r.pct(35):
            args.append("--json")
        self.add(*args)

    def export(self):
        r = self.r
        args = ["export"]
        fmt = r.pick(["csv", "json", "journal", None, "xml"])
        if fmt:
            args += ["--format", fmt]
        if r.pct(25) and fmt != "journal":
            args += ["--query", query_text(r)]
        elif r.pct(5) and fmt == "journal":
            args += ["--query", "payee:a"]
        self.add(*args)

    def dbinfo(self):
        r = self.r
        self.add(*r.pick([["db", "info"], ["db", "info", "--json"], ["db", "check"], ["db", "version"], ["db", "info"]]))

    def rates(self):
        r = self.r
        k = r.below(5)
        src, dst = r.pick(RATE_PAIRS)
        if k < 2:
            self.add("rate", "set", src, dst, r.pick(RATE_TEXTS + ["0", "-1", ".5", "1.123456789", "abc"] if r.pct(10) else RATE_TEXTS),
                     *(["--on", r.pick(["2024-01-01", "2024-03-01", "2024-02-30", "2024-05-31"])] if r.pct(75) else []))
        elif k < 4:
            self.add("rate", "list", *(["--json"] if r.pct(30) else []))
        else:
            self.add("rate", "remove", src, dst, *(["--on", r.pick(["2024-01-01", "2024-03-01", "2024-05-31"])] if r.pct(80) else []))

    def budgets(self):
        r = self.r
        k = r.below(6)
        if k < 2:
            self.add("budget", "add", r.pick(["Expenses:Food", "Expenses:*", "Expenses", "Expenses:Rent", "**", "expenses"]),
                     r.pick(["400.00 USD", "4.00 USD", "8.00 USD", "1200 JPY", "0.00 USD", "5 usd", "300.00 USD", "2.00 USD"]),
                     *(["--per", r.pick(["month", "quarter", "year", "week"])] if r.pct(50) else []),
                     *(["--start", r.pick(["2024-01-01", "2024-03-20", "2023-06-01"])] if r.pct(50) else []))
        elif k < 3:
            self.add("budget", "list", *(["--json"] if r.pct(30) else []))
        elif k < 4:
            self.add("budget", "remove", r.pick(["Expenses:Food", "Expenses:*", "Expenses", "Nothing"]),
                     *(["--per", r.pick(["month", "quarter", "year"])] if r.pct(60) else []))
        else:
            self.add("budget", "status", *(["--period", period_text(r, True)] if r.pct(70) else []),
                     *(["--json"] if r.pct(30) else []))

    def recurring(self):
        r = self.r
        k = r.below(7)
        if k < 3:
            name = r.pick(["rent", "phone-bill", "salary", "2024_tax", "gym", "bad name", "-x", "rent"])
            cur = "USD"
            m = r.pick([90000, 1500, 250000, 1234, 5, 33333])
            args = ["recurring", "add", name, schedule_text(r) if r.pct(25) else r.pick(
                ["monthly on 1", "monthly on 31", "weekly on mon", "daily", "yearly on 02-29", "monthly on last",
                 "every 2 weeks from 2024-01-03", "every 3 months from 2024-01-31", "every 10 days from 2024-01-01"]),
                    r.pick(["Flat", "Gym", "Employer"])]
            if r.pct(70):
                args += ["--start", r.pick(["2024-01-01", "2024-02-10", "2024-03-31", "2024-05-01"])]
            if r.pct(25):
                args += ["--end", r.pick(["2024-04-30", "2024-12-31", "2023-01-01"])]
            if r.pct(25):
                args += ["--count", r.pick(["1", "2", "3", "5", "0", "-1", "x"])]
            if r.pct(30):
                args += ["--tag", r.pick(TAGS)]
            args += ["-p", "Expenses:Rent %s USD" % fmt_minor(m, 2), "-p", "Assets:Bank:Checking"]
            self.add(*args)
        elif k < 5:
            self.add("recurring", "materialize", *(["--upto", r.pick(["2024-01-31", "2024-03-31", "2024-06-15", "2024-02-29",
                                                                       "2024-06-14", "2024-04-15"])] if r.pct(65) else []),
                     *(["--json"] if r.pct(25) else []))
        elif k < 6:
            self.add("recurring", "list", *(["--json"] if r.pct(35) else []))
        else:
            self.add("recurring", "remove", r.pick(["rent", "gym", "salary", "nothing"]))

    def lock(self):
        r = self.r
        self.add("lock", *r.pick([["show"], ["set", r.pick(["2024-03-31", "2024-02-29", "2024-01-01", "2024-06-15"])],
                                  ["clear"], ["set", r.pick(BAD_DATES[:6])], ["show"], ["set"]]))

    def op(self, mix):
        r = self.r
        k = r.pick(mix)
        {"tx_add": self.tx_add, "list": self.listing, "tx_one": self.one_tx, "acct": self.account_op, "report": self.report,
         "export": self.export, "db": self.dbinfo, "rates": self.rates, "budgets": self.budgets, "recurring": self.recurring,
         "lock": self.lock}[k]()

    def finish(self):
        self.add("journal", "export")
        if self.r.pct(25):
            self.add("export", "--format", "json")


def flow_ledger(r):
    f = Flow(r)
    if r.pct(55):
        f.journal_book()
    else:
        f.manual_book()
    mix = ["tx_add"] * 4 + ["list"] * 4 + ["tx_one"] * 3 + ["acct"] * 3 + ["report"] * 4 + ["export"] * 2 + ["db"] * 2 + \
          ["rates", "budgets", "recurring"]
    for _ in range(2 + r.below(5)):
        f.op(mix)
    f.finish()
    return f


def flow_bank(r):
    f = Flow(r)
    f.manual_book([("Opening", "2024-01-01", "Assets:Bank:Checking 1000.00 USD", "Equity:Opening")], free=True)
    ptext, ctext = gen_profile_and_csv(r, True)
    f.files["profile.txt"] = file_bytes_hex(r, ptext.replace("\r\n", "\n"), 0, 0)       # stored as given: keep it plain
    f.files["stmt.csv"] = file_bytes_hex(r, ctext, 6, 1)
    use_rules = r.pct(50)
    if use_rules:
        f.files["rules.txt"] = file_bytes_hex(r, rules_text(r, ["\n"]), 0, 0)
    f.add("profile", "add", "bank", "profile.txt")
    if use_rules:
        f.add("rules", "set", "rules.txt")
    ways = r.pick([["--profile", "bank"], ["--profile", "bank"], ["--profile-file", "profile.txt"],
                   ["--profile", "bank", "--no-rules"]])
    f.add("import", "stmt.csv", *ways)
    if r.pct(80):
        f.add("import", "stmt.csv", *ways)
    if r.pct(15):
        f.add("import", "stmt.csv", *r.pick([["--profile", "bank", "--profile-file", "profile.txt"], [], ["--profile", "nope"]]))
    f.add("tx", "list")
    for _ in range(r.below(2)):
        f.op(["list", "report", "export", "db", "tx_one"])
    if r.pct(20):
        f.add("profile", r.pick(["list", "show", "remove"]), *(["bank"] if r.pct(60) else []))
    f.finish()
    return f


def flow_planning(r):
    f = Flow(r)
    if r.pct(60):
        f.journal_book(0, tie=r.pct(70))
    else:
        f.manual_book()
    for _ in range(1 + r.below(2)):
        f.op(["rates"] * 3 + ["budgets"] * 4 + ["recurring"] * 6 + ["report"] * 2 + ["list"] + ["tx_add"])
    f.add("recurring", "materialize", "--upto", r.pick(["2024-03-31", "2024-06-15", "2024-05-31"]))
    f.add("recurring", "materialize", "--upto", r.pick(["2024-03-31", "2024-06-15", "2024-05-31"]))
    f.add("budget", "status", "--period", r.pick(["2024-03", "2024-Q1", "2024", "2024-06", "2024-01-15..2024-02-14"]))
    f.add("report", "balance-sheet", "--as-of", "2024-06-15", "--convert", r.pick(["EUR", "JPY", "USD"]))
    f.finish()
    return f


def flow_lock(r):
    f = Flow(r)
    f.manual_book([("A", "2024-01-10", "Expenses:Food 10.00 USD", "Assets:Bank:Checking"),
                   ("B", "2024-02-15", "Expenses:Food 20.00 USD", "Assets:Bank:Checking"),
                   ("C", "2024-03-31", "Expenses:Food 30.00 USD", "Assets:Bank:Checking"),
                   ("D", "2024-04-20", "Expenses:Food 40.00 USD", "Assets:Bank:Checking")])
    lock_day = r.pick(["2024-03-31", "2024-03-31", "2024-02-15", "2024-04-19"])
    on_lock_day = {"2024-03-31": "3", "2024-02-15": "2"}.get(lock_day)
    f.add("lock", "set", lock_day)
    f.add("lock", "show")
    # the edges of the lock: its own day is covered, the next day is not
    f.add("tx", "add", "Edge", "--date", lock_day, "-p", "Expenses:Food 1.00 USD", "-p", "Assets:Bank:Checking")
    f.add("tx", "add", "Edge", "--date", shift(lock_day, 1), "-p", "Expenses:Food 1.00 USD", "-p", "Assets:Bank:Checking")
    if on_lock_day:
        f.add("tx", "delete", on_lock_day)
    for _ in range(r.below(3)):
        k = r.below(8)
        if k == 0:
            f.add("tx", "add", "Late", "--date", r.pick([shift(lock_day, -10), "2024-01-01", shift(lock_day, -1)]),
                  "-p", "Expenses:Food 5.00 USD", "-p", "Assets:Bank:Checking")
        elif k == 1:
            f.add("tx", "delete", str(1 + r.below(5)))
        elif k == 2:
            f.add("recurring", "add", "rent", "monthly on 1", "Flat", "--start", r.pick(["2024-01-01", "2024-03-01", "2024-04-01"]),
                  "-p", "Expenses:Rent 900.00 USD", "-p", "Assets:Bank:Checking")
            f.add("recurring", "materialize", "--upto", r.pick(["2024-02-01", "2024-03-31", "2024-05-31", "2024-06-15"]))
        elif k == 3:
            f.add("lock", *r.pick([["show"], ["set", r.pick(["2024-01-31", "2024-05-31"])], ["clear"]]))
        elif k == 4:
            ptext = ("date_column = Date\npayee_column = Payee\namount_column = Amount\ncurrency = USD\n"
                     "account = Assets:Bank:Checking\ndefault_account = Expenses:Misc\n")
            rows = ["Date,Payee,Amount", "%s,Shop,-5.00" % shift(lock_day, 5), "%s,Cafe,-7.50" % r.pick(
                [lock_day, shift(lock_day, -3), shift(lock_day, 9)])]
            f.files["profile.txt"], f.files["stmt.csv"] = hexs(ptext), hexs("\n".join(rows) + "\n")
            f.add("import", "stmt.csv", "--profile-file", "profile.txt")
        elif k == 5:
            f.add("tx", "list", "--json")
        elif k == 6:
            f.add("tx", "add", "Ok", "--date", shift(lock_day, 1 + r.below(30)), "-p", "Expenses:Food 6.00 USD",
                  "-p", "Assets:Bank:Checking")
        else:
            f.add("report", "register", "Expenses:Food")
    f.add("lock", "clear")
    f.add("tx", "delete", "1")
    f.finish()
    return f


def flow_file(r):
    f = Flow(r)
    k = r.below(6)
    if k == 0:
        f.add("db", "info")
        f.add("tx", "list")
        f.add("init")
        f.add("init")
        f.add("db", "version")
        f.add("db", "migrate")
        f.add("db", "info", "--json")
    elif k == 1:
        f.journal_book(0)
        f.add("db", "backup", "copy.db")
        f.add("db", "backup", r.pick(["copy.db", "nodir/copy.db"]))
        f.add("journal", "export", save="out.journal")
        f.steps.append({"argv": ["--db", "two.db", "--today", TODAY, "init"]})
        f.steps.append({"argv": ["--db", "two.db", "--today", TODAY, "journal", "import", "out.journal"]})
        f.steps.append({"argv": ["--db", "two.db", "--today", TODAY, "journal", "export"]})
        f.steps.append({"argv": ["--db", "copy.db", "--today", TODAY, "journal", "export"]})
    elif k == 2:
        f.manual_book()
        for _ in range(2 + r.below(3)):
            f.op(["tx_add"] * 5 + ["tx_one"] * 3 + ["list"] * 2)
        f.add("db", "check")
        f.steps.append({"argv": ["--db", "book.db", "--today", "not-a-date", "db", "info"]})
        f.steps.append({"argv": ["--db", "book.db", "--today", TODAY, "db", "info", "--json", "extra"]})
    elif k == 3:
        f.files["junk.db"] = hexs("this is not a database\n" * 20)
        f.steps.append({"argv": ["--db", "junk.db", "--today", TODAY, "init"]})
        f.steps.append({"argv": ["--db", "junk.db", "--today", TODAY, "db", "info"]})
        f.steps.append({"argv": ["--db", "missing/dir/book.db", "--today", TODAY, "init"]})
        f.steps.append({"argv": ["--db", ".", "--today", TODAY, "db", "info"]})
        f.steps.append({"argv": ["--today", TODAY, "init"]})
        f.steps.append({"argv": ["--today", TODAY, "account", "add", "Assets:Cash"]})
        f.steps.append({"argv": ["--today", TODAY, "account", "list"]})
    elif k == 4:
        f.journal_book(0)
        f.add("journal", "export")
        f.add("export", "--format", "csv")
        f.add("export", "--format", "json")
        f.add("db", "info")
        f.add("journal", "import", "journal.txt") if "journal.txt" in f.files else f.add("journal", "import", "missing.txt")
        f.add("db", "info")
    else:
        f.manual_book()
        f.add("rules", "set", "rules.txt")
        f.files["rules.txt"] = file_bytes_hex(r, rules_text(r, ["\n"]), 0, 0)
        f.add("rules", "set", "rules.txt")
        f.add("rules", "show")
        f.add("profile", "show", "nope")
        f.add("profile", "add", "bad name", "rules.txt")
        f.add("rate", "list")
        f.add("budget", "list")
    f.finish() if k not in (1,) else None
    return f


def flow_case(r):
    scen = r.pick(["ledger"] * 5 + ["bank"] * 2 + ["planning"] * 2 + ["lock"] * 2 + ["file"] * 1)
    f = {"ledger": flow_ledger, "bank": flow_bank, "planning": flow_planning, "lock": flow_lock, "file": flow_file}[scen](r)
    return {"kind": "book", "scenario": scen, "files": f.files, "steps": f.steps}


# --- the API session cases -----------------------------------------------------------------------
JSON_TYPE = "application/json"
API_SEEDS = ["Assets:Bank:Checking", "Assets:Cash", "Assets:Euro", "Expenses:Food", "Expenses:Food:Dining", "Expenses:Rent",
             "Income:Salary", "Equity:Opening", "Liabilities:Card", "Expenses:Travel", "Expenses:Fun"]


def URL(s, safe=""):
    out = ""
    for ch in s:
        if ch.isalnum() and ord(ch) < 128 or ch in "-_.~" + safe:
            out += ch
        else:
            out += "".join("%%%02X" % b for b in ch.encode("utf-8"))
    return out


def REQ(method, path, body=None, ctype=JSON_TYPE, **kw):
    req = {"method": method, "path": path}
    if body is not None:
        req["body"] = body if isinstance(body, str) else json.dumps(body)
        if ctype is not None:
            req["ctype"] = ctype
    req.update(kw)
    return req


def mobj(r, minor, cur):
    txt = fmt_minor(minor, EXP[cur])
    return {"amount": txt, "currency": cur} if r.pct(60) else "%s %s" % (txt, cur)


def api_tx_body(r, bad=None):
    cur = r.pick(["USD", "USD", "EUR"])
    pool = accounts_for(cur)
    a, b = r.pick(pool), r.pick(pool)
    if a == b:
        b = pool[(pool.index(a) + 1) % len(pool)]
    m = minor_pool(r)
    body = {"date": "2024-%02d-%02d" % (1 + r.below(6), 1 + r.below(28)) if r.pct(80) else r.pick(TX_EDGE_DATES), "payee": r.pick(PAYEES)}
    if r.pct(40):
        body["narration"] = r.pick(NARRATIONS)
    if r.pct(25):
        body["flag"] = r.pick(["*", "!"])
    if r.pct(40):
        body["tags"] = [r.pick(TAGS) for _ in range(1 + r.below(3))]
    p1 = {"account": a, "amount": mobj(r, m, cur)}
    p2 = {"account": b, "amount": mobj(r, -m, cur)} if r.pct(70) else {"account": b}
    if r.pct(20):
        p1["note"] = r.pick(["n", "café", ""])
    if r.pct(10):
        pass
    body["postings"] = [p1, p2]
    if bad == "unbalanced":
        p2["amount"] = mobj(r, -m - 1, cur)
    elif bad == "unknown_account":
        p2["account"] = "Expenses:Nope"
    elif bad == "single":
        body["postings"] = [p1]
    elif bad == "no_postings":
        body["postings"] = []
    elif bad == "bad_flag":
        body["flag"] = "?"
    elif bad == "bad_date":
        body["date"] = r.pick(["2024-02-30", "2024-3-1", "yesterday", "20240301", ""])
    elif bad == "missing_date":
        del body["date"]
    elif bad == "missing_payee":
        del body["payee"]
    elif bad == "unknown_field":
        body["colour"] = "red"
    elif bad == "bad_tags":
        body["tags"] = r.pick(["food", [1], ["bad tag"], [["x"]]])
    elif bad == "bad_amount":
        p1["amount"] = r.pick(["12.505 USD", "abc", "5", {"amount": "5.00"}, {"amount": 5, "currency": "USD"}, 12.5, "5.00 usd",
                               {"amount": "5.00", "currency": "USD", "x": 1}, True])
    elif bad == "two_missing":
        p1.pop("amount", None)
        p2.pop("amount", None)
    elif bad == "bad_posting_field":
        p1["colour"] = 1
    elif bad == "wrong_type":
        body["payee"] = r.pick([5, None, ["x"], True])
    elif bad == "closed_account":
        p2["account"] = "Expenses:Old"
    elif bad == "bad_id":
        body["id"] = 5
    elif bad == "nonunicode":
        body["narration"] = "x\ny"
    elif bad == "not_a_list":
        body["postings"] = r.pick(["x", {"account": a}, 5])
    return body


TX_BAD = ["unbalanced", "unknown_account", "single", "no_postings", "bad_flag", "bad_date", "missing_date", "missing_payee",
          "unknown_field", "bad_tags", "bad_amount", "two_missing", "bad_posting_field", "wrong_type", "bad_id", "not_a_list"]
LIMITS = ["0", "1", "2", "5", "100", "9223372036854775807", "9223372036854775808", "-1", "2.5", "ten", "+1", "", "007", "1e3"]
OFFSETS = ["0", "1", "2", "3", "7", "50", "9223372036854775807", "-1", "x", "1.0", ""]


def st_health(r, n, ctx):
    return [REQ("GET", "/health")]


def st_accounts_list(r, n, ctx):
    out = []
    for _ in range(1 + r.below(3)):
        params = []
        if r.pct(40):
            params.append("type=" + r.pick(["asset", "liability", "equity", "income", "expense", "bogus", ""]))
        if r.pct(35):
            params.append("under=" + URL(r.pick(["Assets", "Expenses", "Expenses:Food", "Assets:Bank", "Income", "Liabilities"]), ":"))
        if r.pct(25):
            params.append("currency=" + r.pick(["USD", "EUR", "JPY"]))
        if r.pct(30):
            params.append("include_closed=" + r.pick(["yes", "no", "true", "FALSE", "1", "0", "No", "maybe", "", "2"]))
        if r.pct(10):
            params.append("type=" + r.pick(["asset", "expense"]))
        if r.pct(10):
            params.append("colour=red")
        out.append(REQ("GET", "/accounts" + ("?" + "&".join(params) if params else "")))
    return out


def st_account_get(r, n, ctx):
    out = []
    for _ in range(1 + r.below(3)):
        p = r.pick(API_SEEDS + ["Assets", "Assets:Bank", "Expenses:Nope", "assets:cash", "Expenses:Old", "Café"])
        k = r.below(6)
        if k == 0:
            path = "/accounts/" + URL(p)
        elif k == 1:
            path = "/accounts/" + URL(p, ":")
        elif k == 2:
            path = "/accounts/" + URL(p, ":") + "#frag"
        elif k == 3:
            path = r.pick(["/accounts/", "/accounts/Assets:Cash/", "/Accounts", "/accounts/Assets%3acash", "/accounts/%41ssets:Cash"])
        else:
            path = "/accounts/" + URL(p, ":")
        out.append(REQ("GET", path, loose_code=(k == 3 and "%" not in path)))
    return out


def st_account_create(r, n, ctx):
    out = []
    for _ in range(1 + r.below(3)):
        k = r.below(12)
        if k < 4:
            body = {"path": r.pick(["Assets:Savings", "Expenses:Fun:Cinema", "Assets:Bank:Old", "Liabilities:Loan:Car",
                                    "Income:Gifts", "Expenses:Gym"])}
            if r.pct(50):
                body["currency"] = r.pick(["USD", "EUR", "JPY"])
            if r.pct(40):
                body["opened"] = r.pick(["2024-01-01", "2023-06-30", "2024-05-31"])
            if r.pct(30):
                body["note"] = r.pick(["note", "café", ""])
            if r.pct(15):
                body["type"] = "asset" if body["path"].startswith("Assets") else "expense" if body["path"].startswith("Expenses") else "liability"
            if r.pct(10):
                body["currency"] = None
            out.append(REQ("POST", "/accounts", body))
        elif k == 4:
            out.append(REQ("POST", "/accounts", {"path": r.pick(["Assets:Cash", "Expenses:Food"])}))
        elif k == 5:
            out.append(REQ("POST", "/accounts", {"path": r.pick(["assets:x", "Assets::X", "Savings:X", "Assets:Café", ""])}))
        elif k == 6:
            out.append(REQ("POST", "/accounts", {"path": "Assets:T1", "type": r.pick(["expense", "bogus", 5])}))
        elif k == 7:
            out.append(REQ("POST", "/accounts", {"path": "Assets:T2", "currency": r.pick(["usd", "ZZZ", 5, ""])}))
        elif k == 8:
            out.append(REQ("POST", "/accounts", {"path": "Assets:T3", "opened": r.pick(["2024-02-30", "yesterday", 5, "2024-3-1"])}))
        elif k == 9:
            out.append(REQ("POST", "/accounts", r.pick([{"colour": "red"}, {}, {"path": 5}, {"path": None},
                                                         {"path": "Assets:T4", "note": 5}, {"path": "Assets:T5", "x": 1}])))
        else:
            out.append(REQ("GET", "/accounts"))
    return out


def st_account_close(r, n, ctx):
    out = []
    for _ in range(1 + r.below(3)):
        left = [a for a in ["Expenses:Travel", "Expenses:Fun", "Assets:Cash", "Expenses:Rent", "Assets:Euro", "Expenses:Food:Dining"]
                if a not in ctx["closed"]]
        p = r.pick(left) if left and r.pct(88) else "Expenses:Nope"
        k = r.below(8)
        path = "/accounts/" + URL(p, ":") + "/close"
        if k < 3:
            out.append(REQ("POST", path, {"on": r.pick(["2024-06-30", "2024-12-31", "2025-01-01"])}))
            ctx["closed"].append(p)
        elif k == 3:
            out.append(REQ("POST", path, {}))
            ctx["closed"].append(p)
        elif k == 4:
            out.append(REQ("POST", path))
            ctx["closed"].append(p)
        elif k == 5:
            out.append(REQ("POST", path, {"on": r.pick(["2024-02-30", "yesterday", 5, "2024-3-1", ""])}))
        elif k == 6:
            out.append(REQ("POST", path, {"on": "2023-06-30"}))      # before the postings, after the account was opened
        else:
            out.append(REQ("POST", path, {"on": None}))
            ctx["closed"].append(p)
    out.append(REQ("GET", "/accounts?include_closed=no"))
    return out


def st_tx_list(r, n, ctx):
    out = []
    for _ in range(1 + r.below(4)):
        params = []
        if r.pct(55):
            params.append("q=" + URL(query_text(r) if r.pct(90) else r.pick(BAD_QUERIES), ":").replace("%20", r.pick(["%20", "+"])))
        if r.pct(55):
            params.append("limit=" + r.pick(LIMITS))
        if r.pct(55):
            params.append("offset=" + r.pick(OFFSETS))
        if r.pct(8):
            params.append("limit=" + r.pick(["2", "1"]))
        if r.pct(8):
            params.append("q=")
        if r.pct(8):
            params.append("colour=1")
        out.append(REQ("GET", "/transactions" + ("?" + "&".join(params) if params else "")))
    return out


def st_tx_get(r, n, ctx):
    out = []
    for _ in range(1 + r.below(3)):
        i = r.pick([str(1 + r.below(max(n, 1))), str(1 + r.below(max(n, 1))), "0" + str(1 + r.below(max(n, 1))), "0", str(n + 5),
                    "abc", "1.0", "+1", "-1", "99999999999999999999999", "1e1", "", "١"])
        path = "/transactions/" + URL(i)
        out.append(REQ("GET", path, loose_code=(i == "")))
    return out


def st_tx_create_ok(r, n, ctx):
    return [REQ("POST", "/transactions", api_tx_body(r)) for _ in range(1 + r.below(3))] + [REQ("GET", "/transactions?limit=3&offset=%d" % r.below(max(n, 1)))]


def st_tx_create_err(r, n, ctx):
    return [REQ("POST", "/transactions", api_tx_body(r, r.pick(TX_BAD))) for _ in range(1 + r.below(3))]


def st_tx_delete(r, n, ctx):
    i = 1 + r.below(max(n, 1))
    out = [REQ("DELETE", "/transactions/%d" % i), REQ("GET", "/transactions/%d" % i)]
    if r.pct(50):
        out.append(REQ("DELETE", "/transactions/%s" % r.pick([str(n + 9), "abc", "0", "%d" % i])))
    return out


def st_rates(r, n, ctx):
    out = []
    for _ in range(1 + r.below(4)):
        src, dst = r.pick(RATE_PAIRS)
        d = r.pick(["2024-01-01", "2024-03-01", "2024-05-31"])
        k = r.below(10)
        if k < 3:
            out.append(REQ("PUT", "/rates", {"src": src, "dst": dst, "date": d, "rate": r.pick(RATE_TEXTS)}))
        elif k == 3:
            out.append(REQ("PUT", "/rates", {"src": src, "dst": dst, "date": d, "rate": r.pick([0.9, 2, "0", "-1", ".5", "1.123456789",
                                                                                                 "abc", "", None])}))
        elif k == 4:
            out.append(REQ("PUT", "/rates", r.pick([{"src": src, "dst": dst, "date": d}, {"src": src, "dst": src, "date": d, "rate": "1.5"},
                                                    {"src": "usd", "dst": dst, "date": d, "rate": "1.5"},
                                                    {"src": src, "dst": dst, "date": "2024-02-30", "rate": "1.5"},
                                                    {"src": src, "dst": dst, "date": d, "rate": "1.5", "x": 1},
                                                    {"src": 5, "dst": dst, "date": d, "rate": "1.5"}])))
        elif k < 7:
            out.append(REQ("DELETE", "/rates?src=%s&dst=%s&date=%s" % (src, dst, d)))
        elif k == 7:
            out.append(REQ("DELETE", "/rates?" + r.pick(["src=USD&dst=EUR", "src=USD", "", "dst=EUR&date=2024-01-01",
                                                        "src=USD&dst=EUR&date=2024-02-30", "src=XXX&dst=EUR&date=2024-01-01"])))
        else:
            out.append(REQ("GET", "/rates"))
    return out


def st_budgets(r, n, ctx):
    out = []
    for _ in range(1 + r.below(4)):
        k = r.below(11)
        pat = r.pick(["Expenses:Food", "Expenses:*", "Expenses", "Expenses:Rent", "Expenses:Fun"])
        kind = r.pick(["month", "quarter", "year"])
        amt = r.pick(["400.00 USD", "4.00 USD", "8.00 USD", "300.00 USD", "1200 JPY", {"amount": "900.00", "currency": "USD"},
                      {"amount": "2.00", "currency": "USD"}])
        if k < 3:
            out.append(REQ("POST", "/budgets", {"pattern": pat, "period_kind": kind, "amount": amt,
                                                "start": r.pick(["2024-01-01", "2024-03-20", "2023-06-01"])}))
        elif k == 3:
            out.append(REQ("POST", "/budgets", r.pick([
                {"pattern": "**", "period_kind": "month", "amount": "5.00 USD", "start": "2024-01-01"},
                {"pattern": pat, "period_kind": "week", "amount": "5.00 USD", "start": "2024-01-01"},
                {"pattern": pat, "period_kind": "month", "amount": "0.00 USD", "start": "2024-01-01"},
                {"pattern": pat, "period_kind": "month", "amount": "5.00 USD", "start": "2024-02-30"},
                {"pattern": pat, "period_kind": "month", "amount": 5, "start": "2024-01-01"},
                {"pattern": pat, "period_kind": "month", "amount": "5.00 USD"},
                {"pattern": pat, "period_kind": "month", "amount": "5.00 USD", "start": "2024-01-01", "x": 1},
                {"pattern": "expenses", "period_kind": "month", "amount": "5.00 USD", "start": "2024-01-01"}])))
        elif k < 6:
            out.append(REQ("GET", "/budgets/status?period=" + URL(period_text(r, True), ":")))
        elif k == 6:
            out.append(REQ("GET", "/budgets/status" + r.pick(["", "?period=", "?period=2024-3", "?period=2024-03&period=2024-Q1",
                                                              "?colour=1"])))
        elif k == 7:
            out.append(REQ("DELETE", "/budgets?pattern=%s&period_kind=%s" % (URL(pat, ":*"), kind)))
        elif k == 8:
            out.append(REQ("DELETE", "/budgets" + r.pick(["", "?pattern=Expenses", "?period_kind=month", "?pattern=Expenses&period_kind=week"])))
        else:
            out.append(REQ("GET", "/budgets"))
    return out


def st_recurring(r, n, ctx):
    out = []
    name = r.pick(["rent", "gym", "salary", "2024_tax"])
    tmpl = {"payee": r.pick(["Flat", "Gym"]), "postings": [{"account": "Expenses:Rent", "amount": mobj(r, r.pick([90000, 1500, 1234]), "USD")},
                                                              {"account": "Assets:Bank:Checking"}]}
    if r.pct(30):
        tmpl["tags"] = [r.pick(TAGS)]
    if r.pct(20):
        tmpl["narration"] = "n"
    body = {"name": name, "schedule": r.pick(["monthly on 1", "weekly on mon", "monthly on 31", "daily", "Monthly On LAST",
                                               "every 2 weeks from 2024-01-03", "yearly on 02-29", "every 1 month from 2024-01-31"]),
            "start": r.pick(["2024-01-01", "2024-02-10", "2024-05-01"]), "template": tmpl}
    if r.pct(25):
        body["end"] = r.pick(["2024-04-30", "2024-12-31"])
    if r.pct(25):
        body["count"] = r.pick([1, 2, 3, 5])
    out.append(REQ("POST", "/recurring", body))
    for _ in range(r.below(3)):
        k = r.below(9)
        if k == 0:
            out.append(REQ("POST", "/recurring", body))
        elif k == 1:
            out.append(REQ("POST", "/recurring", dict(body, schedule=r.pick(["weekly", "monthly on 0", "", "daily on mon", 5]))))
        elif k == 2:
            out.append(REQ("POST", "/recurring", dict(body, name=r.pick(["bad name", "-x", "", 5]))))
        elif k == 3:
            out.append(REQ("POST", "/recurring", dict(body, count=r.pick([0, -1, "x", 1.5, True]), name="cnt")))
        elif k == 4:
            out.append(REQ("POST", "/recurring", dict(body, end="2023-01-01", name="endb")))
        elif k == 5:
            out.append(REQ("POST", "/recurring/materialize", r.pick([{}, {"upto": r.pick(["2024-03-31", "2024-06-15", "2024-12-31"])},
                                                                     None, {"upto": "2024-02-30"}, {"upto": 5}, {"x": 1}])))
        elif k == 6:
            out.append(REQ("DELETE", "/recurring?name=" + r.pick(["rent", "gym", "nothing", "salary"])))
        elif k == 7:
            out.append(REQ("DELETE", "/recurring"))
        else:
            out.append(REQ("GET", "/recurring"))
    out.append(REQ("POST", "/recurring/materialize", r.pick([{"upto": "2024-06-30"}, {}, None])))
    out.append(REQ("POST", "/recurring/materialize", {}))
    out.append(REQ("GET", "/recurring"))
    return out


def st_reports(r, n, ctx):
    out = []
    for _ in range(1 + r.below(4)):
        name = r.pick(["trial-balance", "balance-sheet", "balance-sheet", "income-statement", "income-statement", "cashflow",
                       "register", "register"])
        params = []
        if name in ("trial-balance", "balance-sheet") and r.pct(55):
            params.append("as_of=" + r.pick(["2024-03-31", "2024-06-15", "2024-01-31", "2023-12-31", "2024-12-31", "2024-02-30", "x"]))
        if name in ("income-statement", "cashflow") or (name == "register" and r.pct(50)):
            params.append("period=" + URL(period_text(r, True) if r.pct(92) else r.pick(BAD_PERIODS), ":"))
            if r.pct(5):
                params.pop()
        if name in ("balance-sheet", "income-statement") and r.pct(35):
            params.append("convert_to=" + r.pick(["EUR", "USD", "JPY", "GBP", "xx", "KWD"]))
        if name == "register":
            if r.pct(94):
                params.append("account=" + URL(r.pick(API_SEEDS + ["Assets", "Expenses"]), ":"))
            if r.pct(30):
                params.append("rollup=" + r.pick(["yes", "no", "true", "0", "maybe"]))
        if r.pct(30):
            params.append("format=" + r.pick(["json", "text", "xml", "csv", ""]))
        out.append(REQ("GET", "/reports/" + name + ("?" + "&".join(params) if params else "")))
    return out


def st_import(r, n, ctx):
    ptext, ctext = gen_profile_and_csv(r)
    out = []
    k = r.below(8)
    prof = URL(ptext, "")
    if k < 3:
        out.append(REQ("POST", "/import?profile=" + prof + r.pick(["", "&apply_rules=no", "&apply_rules=yes", "&apply_rules=maybe"]),
                       ctext, ctype=r.pick(["text/csv", "text/plain", "text/csv; charset=utf-8", "TEXT/CSV"])))
        out.append(REQ("POST", "/import?profile=" + prof, ctext, ctype="text/csv"))
    elif k < 5:
        body = {"csv": ctext, "profile": ptext}
        if r.pct(40):
            body["apply_rules"] = r.pick([True, False])
        out.append(REQ("POST", "/import", body))
        out.append(REQ("POST", "/import", body))
    elif k == 5:
        out.append(REQ("POST", "/import?profile=" + r.pick(["nope", "", "bank"]), ctext, ctype="text/csv"))
    elif k == 6:
        out.append(REQ("POST", "/import", r.pick([{"csv": ctext}, {"profile": ptext}, {"csv": 5, "profile": ptext},
                                                   {"csv": ctext, "profile": ptext, "apply_rules": "yes"},
                                                   {"csv": ctext, "profile": ptext, "x": 1}])))
    else:
        out.append(REQ("POST", "/import?profile=" + prof, "", ctype="text/csv"))
        out.append(REQ("POST", "/import?profile=" + prof, ctext, ctype="application/xml"))
    out.append(REQ("GET", "/transactions?limit=5&offset=%d" % n))
    return out


def st_rules_export(r, n, ctx):
    out = []
    for _ in range(1 + r.below(3)):
        k = r.below(8)
        if k < 2:
            out.append(REQ("PUT", "/rules", {"rules": rules_text(r)}))
        elif k == 2:
            out.append(REQ("PUT", "/rules", r.pick([{"rules": 5}, {}, {"rules": "when then"}, {"text": "x"}, {"rules": None},
                                                    {"rules": "when any then account assets"}])))
        elif k == 3:
            out.append(REQ("GET", "/rules"))
        else:
            fmt = r.pick(["json", "csv", "journal", "", "xml"])
            out.append(REQ("GET", "/export" + r.pick(["", "?format=" + fmt, "?format=" + fmt, "?format=" + fmt])))
    out.append(REQ("GET", "/rules"))
    return out


def st_lock(r, n, ctx):
    out = [REQ("GET", "/lock")]
    day = r.pick(["2024-03-31", "2024-02-29", "2024-04-30", "2024-01-31"])
    out.append(REQ("PUT", "/lock", {"lock_date": day}, loose_ok=True))
    out.append(REQ("GET", "/lock"))
    for when in (day, shift(day, 1)):       # the edges: the lock day itself is covered, the day after is not
        b = api_tx_body(r)
        b["date"] = when
        out.append(REQ("POST", "/transactions", b))
    for _ in range(r.below(4)):
        k = r.below(8)
        if k == 0:
            b = api_tx_body(r)
            b["date"] = r.pick([shift(day, -20), "2024-01-01", shift(day, -1)])
            out.append(REQ("POST", "/transactions", b))
        elif k == 1:
            b = api_tx_body(r)
            b["date"] = shift(day, 1 + r.below(40))
            out.append(REQ("POST", "/transactions", b))
        elif k == 2:
            out.append(REQ("DELETE", "/transactions/%d" % (1 + r.below(max(n, 1)))))
        elif k == 3:
            out.append(REQ("POST", "/recurring/materialize", {"upto": r.pick(["2024-03-31", "2024-06-15"])}))
        elif k == 4:
            out.append(REQ("PUT", "/lock", r.pick([{"lock_date": "2024-02-30"}, {"lock_date": 5}, {"lock_date": "x"},
                                                   {"lock_date": day, "x": 1}])))
        elif k == 5:
            out.append(REQ("PUT", "/lock", {"lock_date": r.pick(["2024-05-31", None, "2024-01-01"])}, loose_ok=True))
        elif k == 6:
            out.append(REQ("DELETE", "/lock"))
        else:
            out.append(REQ("GET", "/transactions?limit=2"))
    ptext = "date_column = Date\npayee_column = Payee\namount_column = Amount\ncurrency = USD\naccount = Assets:Bank:Checking\ndefault_account = Expenses:Food\n"
    out.append(REQ("POST", "/import", {"csv": "Date,Payee,Amount\n%s,Shop,-5.00\n%s,Cafe,-7.50\n" % (shift(day, 3), r.pick([day, shift(day, 4)])),
                                      "profile": ptext}))
    out.append(REQ("PUT", "/lock", {"lock_date": None}, loose_ok=True))
    out.append(REQ("GET", "/lock"))
    return out


PROTO = ["bad_json", "not_object", "bad_utf8", "wrong_type", "no_type", "charset", "upper_type", "unknown_path", "slash",
         "wrong_verb", "head", "options", "patch", "get_with_body", "fragment", "dup_param", "plus_space", "big", "exact_max",
         "bad_length", "garbage_line", "empty_post", "delete_with_body", "percent_path", "wrong_verb2", "encoded_empty"]


def st_protocol(r, n, ctx):
    out = []
    for _ in range(1 + r.below(4)):
        k = r.pick(PROTO)
        post = r.pick(["/accounts", "/transactions", "/budgets", "/recurring", "/recurring/materialize"])
        if k == "bad_json":
            out.append(REQ("POST", "/accounts", r.pick(["{", "nope", '{"path": "Assets:X",}', "{'path': 'x'}", "[1,", '{"a":1}}',
                                                         "﻿{}", "NaN", '{"path": "Assets:\\ud83d"}'])))
        elif k == "not_object":
            out.append(REQ("POST", "/accounts", r.pick(["[]", '"x"', "5", "null", "true", "[1,2]", '[{"path":"Assets:X"}]'])))
        elif k == "bad_utf8":
            out.append(REQ("POST", "/accounts", None, body_hex=r.pick([b'{"path": "Assets:\xff"}', b"\xff\xfe{}", b'{"path":"\xc3\x28"}']).hex(),
                           ctype=JSON_TYPE))
        elif k == "wrong_type":
            out.append(REQ("POST", r.pick(["/accounts", "/transactions", "/budgets", "/rates".replace("/rates", "/recurring")]),
                           r.pick(['{"path": "Assets:X"}', "x=1", "{}"]), ctype=r.pick(["text/plain", "text/csv", "application/xml",
                                                                                    "application/x-www-form-urlencoded", "json",
                                                                                    "application/jsonx"])))
        elif k == "no_type":
            out.append(REQ("POST", "/accounts", '{"path": "Assets:NoType"}', ctype=None))
        elif k == "charset":
            out.append(REQ("POST", "/accounts", {"path": "Assets:Cs%d" % r.below(100)},
                           ctype=r.pick(["application/json; charset=utf-8", "application/json;charset=UTF-8", "application/json ; x=y"])))
        elif k == "upper_type":
            out.append(REQ("POST", "/accounts", {"path": "Assets:Up%d" % r.below(100)}, ctype=r.pick(["APPLICATION/JSON", "Application/Json"])))
        elif k == "unknown_path":
            out.append(REQ(r.pick(["GET", "POST", "DELETE", "PUT"]), r.pick(["/", "/nothing", "/health/", "/accounts/", "/transactions//1",
                                                                              "/reports", "/reports/nothing", "/reports/trial-balance/x",
                                                                              "/ACCOUNTS", "/accounts/Assets:Cash/close/x", "/budgets/status/x",
                                                                              "/recurring/materialize/x", "/api/health", "/health.json",
                                                                              "/rates/1", "/export/csv", "/import/x", "/rules/x"]),
                           loose_code=True))
        elif k == "slash":
            out.append(REQ("GET", r.pick(["/accounts/Assets:Cash/", "/transactions/", "/health/", "/accounts//", "/budgets/", "/rates/"]),
                           loose_code=True))
        elif k == "wrong_verb":
            routes = {"/health": "GET", "/accounts": "GET, POST", "/accounts/Assets:Cash": "GET", "/accounts/Assets:Cash/close": "POST",
                      "/transactions": "GET, POST", "/transactions/1": "DELETE, GET", "/rates": "DELETE, GET, PUT",
                      "/budgets": "DELETE, GET, POST", "/budgets/status": "GET", "/recurring": "DELETE, GET, POST",
                      "/recurring/materialize": "POST", "/reports/cashflow": "GET", "/import": "POST", "/rules": "GET, PUT",
                      "/export": "GET"}
            path = r.pick(sorted(routes))
            allowed = [v.strip() for v in routes[path].split(",")]
            verb = r.pick([v for v in ["GET", "POST", "PUT", "DELETE", "PATCH"] if v not in allowed])
            out.append(REQ(verb, path))
        elif k == "wrong_verb2":
            out.append(REQ(r.pick(["PUT", "PATCH", "DELETE"]), r.pick(["/accounts", "/health", "/export", "/reports/register",
                                                                          "/transactions", "/rules".replace("/rules", "/budgets/status")])))
        elif k == "head":
            out.append(REQ("HEAD", r.pick(["/health", "/accounts", "/transactions", "/export"]), ignore_body=True))
        elif k == "options":
            out.append(REQ("OPTIONS", r.pick(["/health", "/accounts", "/rates"]), ignore_body=True))
        elif k == "patch":
            out.append(REQ("PATCH", r.pick(["/accounts", "/transactions/1", "/budgets"])))
        elif k == "get_with_body":
            out.append(REQ(r.pick(["GET", "DELETE"]), r.pick(["/health", "/accounts?type=asset", "/transactions/%d" % (1 + r.below(max(n, 1))),
                                                                "/rates?src=USD&dst=EUR&date=2024-01-01"]), r.pick(['{"x": 1}', "garbage", "[]"]),
                           ctype=r.pick([JSON_TYPE, "text/plain"])))
        elif k == "fragment":
            out.append(REQ("GET", r.pick(["/health#x", "/accounts?type=asset#frag&x=1", "/transactions?limit=1#?limit=2"])))
        elif k == "dup_param":
            out.append(REQ("GET", r.pick(["/transactions?limit=1&limit=2", "/transactions?limit=x&limit=2", "/accounts?type=bogus&type=asset",
                                          "/transactions?limit=2&limit=x", "/transactions?q=payee:a&q=payee:b"])))
        elif k == "plus_space":
            out.append(REQ("GET", "/transactions?q=payee:%s+or+payee:%s" % (r.pick(["acme", "corner"]), r.pick(["shop", "market"]))))
        elif k == "big":
            out.append(REQ("POST", "/accounts", None, body_kind="big", ctype=JSON_TYPE))
        elif k == "exact_max":
            out.append(REQ("POST", "/accounts", None, body_kind="max%d" % r.below(10), ctype=JSON_TYPE))
        elif k == "bad_length":
            out.append(REQ("POST", "/accounts", '{"path": "Assets:BadLen"}', headers={"Content-Length": r.pick(["abc", "1.5", "0x10", "12abc", "one"])},
                           raw_length=True))
        elif k == "garbage_line":
            out.append(REQ("GET", "/health", headers={"X-Odd": "a\tb  c", "Accept": "*/*"}))
        elif k == "empty_post":
            out.append(REQ("POST", post, None, ctype=r.pick([None, JSON_TYPE, "text/plain"]), empty=True))
        elif k == "delete_with_body":
            out.append(REQ("DELETE", "/transactions/%d" % (n + 20), "{}"))
        elif k == "percent_path":
            out.append(REQ("GET", r.pick(["/%68ealth", "/accounts/Assets%3ACash", "/accounts/Assets%3aCash", "/ac%63ounts", "/accounts/%E2%82%AC",
                                          "/accounts/%ZZ", "/accounts/%"]), loose_code=True))
        else:
            out.append(REQ("GET", "/accounts?type=%73et"))
    return out


STORIES = [(st_health, 2), (st_accounts_list, 4), (st_account_get, 4), (st_account_create, 5), (st_account_close, 3),
           (st_tx_list, 6), (st_tx_get, 3), (st_tx_create_ok, 5), (st_tx_create_err, 6), (st_tx_delete, 3), (st_rates, 4),
           (st_budgets, 5), (st_recurring, 5), (st_reports, 6), (st_import, 4), (st_rules_export, 3), (st_lock, 5),
           (st_protocol, 8)]


def api_case(r):
    if r.pct(25):
        text, _ = tie_journal(r)
        n = 4
    else:
        text, n = gen_journal(r, 0, tiny=r.pct(20), n=2 + r.below(10))
    weights = [fn for fn, w in STORIES for _ in range(w)]
    requests, ctx = [], {"closed": []}
    for _ in range(2 + r.below(4)):
        requests.extend(r.pick(weights)(r, n, ctx))
    requests = requests[:18]
    serve = ["serve", "--port", "0"] if r.pct(75) else ["serve", "--host", "127.0.0.1", "--port", "0"]
    return {"kind": "api", "files": {"journal.txt": file_bytes_hex(r, text, 5, 0)}, "n_tx": n, "serve": serve,
            "requests": requests}


# --- the plan -------------------------------------------------------------------------------------
SLOTS = "ccbccaccbcccabccaccb"[:20]          # per 20 cases: 13 offline, 4 book, 3 api, in every prefix of that length


def make_case(r, index):
    slot = SLOTS[index % 20]
    case = calc_case(r) if slot == "c" else flow_case(r) if slot == "b" else api_case(r)
    case["id"] = index
    return case


def generate(n=CASES, seed=SEED):
    r = Rng(seed)
    return [make_case(r, i) for i in range(n)]


# --- running a case ---------------------------------------------------------------------------------
class Clock:
    def __init__(self, seconds):
        self.deadline = time.monotonic() + seconds

    def left(self):
        return self.deadline - time.monotonic()


def cli(cmd, env, work, argv, stdin=None, closed=False, clock=None, timeout=None):
    """One command: {"exit", "stdout", "stderr_empty", "stderr"}."""
    left = clock.left() if clock else RUN_TIMEOUT
    if left <= 0:
        return {"exit": "timeout", "stdout": "", "stderr_empty": False, "stderr": "case out of time"}
    pipe = None
    out = subprocess.PIPE
    if closed:
        rd, pipe = os.pipe()
        os.close(rd)
        out = pipe
    try:
        p = subprocess.run(cmd + argv, cwd=work, env=env, input=stdin, stdout=out, stderr=subprocess.PIPE,
                           stdin=None if stdin is not None else subprocess.DEVNULL, timeout=min(timeout or RUN_TIMEOUT, left))
        return {"exit": p.returncode, "stdout": (p.stdout or b"").decode("utf-8", "backslashreplace"),
                "stderr_empty": not p.stderr.strip(), "stderr": p.stderr.decode("utf-8", "backslashreplace")[-300:]}
    except subprocess.TimeoutExpired:
        return {"exit": "timeout", "stdout": "", "stderr_empty": False, "stderr": "timeout"}
    except OSError as exc:
        return {"exit": "oserror", "stdout": "", "stderr_empty": False, "stderr": str(exc)[:300]}
    finally:
        if pipe is not None:
            os.close(pipe)


def write_files(work, files):
    for name, hx in files.items():
        with open(os.path.join(work, name), "wb") as fh:
            fh.write(bytes.fromhex(hx))


def command_of(argv):
    """argv without the leading global options (`--db X`, `--today D`)."""
    i = 0
    while i + 1 < len(argv) and argv[i] in ("--db", "--today"):
        i += 2
    return argv[i:]


def canon_cli(argv, res, closed=False):
    """What of a command's result counts: the status, the text on standard output (left open: the help texts beyond
    their first words, and what `lock set` / `lock clear` print) and whether standard error is empty."""
    if closed:
        return {"exit": res["exit"], "stderr_empty": res["stderr_empty"]}
    out = res["stdout"]
    cmd = command_of(argv)
    if any(a in ("--help", "-h") for a in cmd):
        out = "(usage text)" if out.startswith("usage: tallybook") else out
    elif cmd[:2] in (["lock", "set"], ["lock", "clear"]) and res["exit"] == 0:
        out = "(text left open)"
    return {"exit": res["exit"], "stdout": out, "stderr_empty": res["stderr_empty"]}


def run_calc(cmd, env, case, work, clock):
    write_files(work, case["files"])
    stdin = bytes.fromhex(case["stdin_hex"]) if case["stdin_hex"] is not None else None
    res = cli(cmd, env, work, case["argv"], stdin, case["closed_stdout"], clock)
    return [{"what": "tallybook " + " ".join(case["argv"]), "res": canon_cli(case["argv"], res, case["closed_stdout"]),
             "stderr": res["stderr"]}]


def run_book(cmd, env, case, work, clock):
    write_files(work, case["files"])
    events = []
    for step in case["steps"]:
        stdin = bytes.fromhex(step["stdin_hex"]) if "stdin_hex" in step else None
        res = cli(cmd, env, work, step["argv"], stdin, False, clock)
        if "save" in step:
            with open(os.path.join(work, step["save"]), "w", encoding="utf-8", newline="") as fh:
                fh.write(res["stdout"])
        events.append({"what": "tallybook " + " ".join(step["argv"]), "res": canon_cli(step["argv"], res), "stderr": res["stderr"]})
    return events


# the HTTP client
def build_request(req):
    """The bytes of one request."""
    if req["method"] == "RAW":
        return bytes.fromhex(req["raw_hex"])
    kind = req.get("body_kind")
    if kind == "big":            # one byte over the limit of 1 MiB
        body = b'{"path": "Assets:Big", "note": "' + b"x" * 1048576 + b'"}'
    elif kind:                   # exactly 1 MiB: a small object and white space
        head = b'{"path": "Assets:Max%s"}' % kind[3:].encode()
        body = head + b" " * (1048576 - len(head))
    else:
        body = bytes.fromhex(req["body_hex"]) if "body_hex" in req else req.get("body", "").encode("utf-8")
    head = ["%s %s HTTP/1.1" % (req["method"], req["path"]), "Host: 127.0.0.1", "Connection: close"]
    headers = dict(req.get("headers") or {})
    if req.get("ctype") and (body or req.get("empty")):
        headers["Content-Type"] = req["ctype"]
    if "Content-Length" not in headers and (body or req["method"] in ("POST", "PUT")):
        headers["Content-Length"] = str(len(body))
    head += ["%s: %s" % kv for kv in headers.items()]
    return ("\r\n".join(head) + "\r\n\r\n").encode("latin-1") + body


def http_call(port, req):
    data = build_request(req)
    got = b""
    note = None
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=HTTP_TIMEOUT)
    except OSError as exc:
        return {"error": "connect: " + str(exc)[:80]}
    try:
        try:
            sock.sendall(data)
        except OSError:
            note = "send failed"
        while True:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                return {"error": "timeout", "partial": got[:200].decode("latin-1")}
            except OSError:
                note = note or "reset"
                break
            if not chunk:
                break
            got += chunk
    finally:
        sock.close()
    if not got:
        return {"error": note or "no answer"}
    head, sep, body = got.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    m = re.match(r"HTTP/\d\.\d (\d{3})", lines[0])
    if not m:
        return {"error": "not HTTP: " + lines[0][:60]}
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return {"status": int(m.group(1)), "headers": headers, "body": body}


def canon_http(req, resp):
    if "error" in resp:
        return {"error": resp["error"]}
    status, headers, body = resp["status"], resp["headers"], resp["body"]
    if req.get("loose_ok") and 200 <= status < 300:          # the brief leaves the success answer open: only that it worked
        return {"status": "2xx"}
    ctype = re.sub(r"\s*;\s*", "; ", headers.get("content-type", "").lower()).strip()
    out = {"status": status, "type": ctype}
    if "allow" in headers:
        out["allow"] = headers["allow"]
    if req.get("ignore_body"):
        return out
    length = headers.get("content-length")
    out["length_ok"] = length is not None and length.isdigit() and int(length) == len(body)
    text = body.decode("utf-8", "replace")
    if ctype.startswith("application/json"):
        try:
            data = json.loads(text)
        except ValueError:
            out["body"] = text
            return out
        if status >= 400:
            err = data.get("error") if isinstance(data, dict) else None
            if isinstance(err, dict):
                code = err.get("code")
                msg = err.get("message")
                out["error"] = {"code": None if req.get("loose_code") else code,
                                "message_ok": isinstance(msg, str) and bool(msg.strip()), "keys": sorted(err)}
                out["keys"] = sorted(data)
            else:
                out["error"] = {"shape": "not an object", "value_type": type(err).__name__}
            return out
        out["json"] = data
    else:
        out["body"] = text
    return out


class Server:
    """`tallybook serve --port 0` as a child process; the port is read from its announce line."""

    def __init__(self, cmd, env, work, argv):
        self.out_lines, self.err = [], []
        self.proc = subprocess.Popen(cmd + argv, cwd=work, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        self.ready = threading.Event()
        self.port = None
        self.rest = []
        self.threads = [threading.Thread(target=self._read_out, daemon=True), threading.Thread(target=self._read_err, daemon=True)]
        for t in self.threads:
            t.start()

    def _read_out(self):
        for raw in iter(self.proc.stdout.readline, b""):
            line = raw.decode("utf-8", "backslashreplace")
            if self.port is None:
                m = re.fullmatch(r"tallybook listening on http://127\.0\.0\.1:(\d+)\r?\n?", line)
                self.first = line
                if m:
                    self.port = int(m.group(1))
                    self.ready.set()
                    continue
                self.ready.set()
            self.rest.append(line)

    def _read_err(self):
        data = self.proc.stderr.read()
        self.err.append(data.decode("utf-8", "backslashreplace"))

    def wait_ready(self, seconds):
        self.ready.wait(seconds)
        return self.port

    def stop(self):
        """SIGTERM and wait; (exit status, text after the announce line, stderr text)."""
        if self.proc.poll() is None:
            try:
                self.proc.send_signal(signal.SIGTERM) if os.name != "nt" else self.proc.terminate()
            except OSError:
                pass
        try:
            code = self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            code = "did not stop"
        for t in self.threads:
            t.join(2)
        return code, "".join(self.rest), "".join(self.err)


def run_api(cmd, env, case, work, clock):
    write_files(work, case["files"])
    events = []
    for argv in (["init"], ["journal", "import", "journal.txt"]):
        full = GLOBALS + argv
        res = cli(cmd, env, work, full, None, False, clock)
        events.append({"what": "tallybook " + " ".join(full), "res": canon_cli(full, res), "stderr": res["stderr"]})
    srv = Server(cmd, env, work, GLOBALS + case["serve"])
    port = srv.wait_ready(15)
    if port is None:
        code, rest, err = srv.stop()
        events.append({"what": "serve", "res": {"announce": False, "exit": code, "first": getattr(srv, "first", "")[:100]},
                       "stderr": err[-300:]})
        return events
    events.append({"what": "serve announce", "res": {"announce": True}, "stderr": ""})
    try:
        for req in case["requests"]:
            what = "%s %s" % (req["method"], req["path"][:120])
            resp = http_call(port, req)
            events.append({"what": what, "res": canon_http(req, resp), "stderr": "", "raw": raw_view(resp)})
    finally:
        code, rest, err = srv.stop()
    events.append({"what": "serve stop", "res": {"exit": code, "stdout_after_announce": rest, "stderr_empty": not err.strip()},
                   "stderr": err[-300:]})
    for argv in (["journal", "export"], ["export", "--format", "json"], ["db", "check"]):
        full = GLOBALS + argv
        res = cli(cmd, env, work, full, None, False, clock)
        events.append({"what": "tallybook " + " ".join(full), "res": canon_cli(full, res), "stderr": res["stderr"]})
    return events


def raw_view(resp):
    if "error" in resp:
        return str(resp["error"])
    return "%d %s" % (resp["status"], resp["body"][:200].decode("utf-8", "backslashreplace"))


def run_case(cmd, env, case, clock=None):
    work = tempfile.mkdtemp(prefix="tbfuzz-")
    clock = clock or Clock(CASE_S)
    try:
        run = {"calc": run_calc, "book": run_book, "api": run_api}[case["kind"]]
        return run(cmd, env, case, work, clock)
    finally:
        shutil.rmtree(work, ignore_errors=True)


# --- comparing ---------------------------------------------------------------------------------------
def first_difference(ref, arm):
    """Index of the first event where the two runs differ, or None."""
    for i in range(max(len(ref), len(arm))):
        if i >= len(ref) or i >= len(arm):
            return i
        if ref[i]["what"] != arm[i]["what"] or ref[i]["res"] != arm[i]["res"]:
            return i
    return None


def view(value, limit=300):
    if isinstance(value, str):
        return show(value, limit)
    if isinstance(value, dict):
        return {k: view(v, limit) for k, v in value.items()}
    if isinstance(value, list):
        return [view(v, limit) for v in value[:12]] + (["…"] if len(value) > 12 else [])
    return value


def case_input(case):
    files = {n: show(bytes.fromhex(h).decode("utf-8", "backslashreplace"), 300) for n, h in case.get("files", {}).items()}
    if case["kind"] == "calc":
        stdin = case["stdin_hex"]
        return {"files": files, "stdin": None if stdin is None else show(bytes.fromhex(stdin).decode("utf-8", "backslashreplace"), 300),
                "closed_stdout": case["closed_stdout"]}
    return {"files": files}


def example(case, at, ref, arm):
    mine = ref[at] if at < len(ref) else None
    theirs = arm[at] if at < len(arm) else None
    ex = {"case": case["id"], "kind": case["kind"]}
    if case["kind"] == "calc":
        ex["argv"] = case["argv"]
    ex["step"] = at
    ex["what"] = (mine or theirs)["what"] if (mine or theirs) else "?"
    ex.update(case_input(case))
    ex["reference"] = view(mine["res"]) if mine else "(no such step)"
    ex["arm"] = view(theirs["res"]) if theirs else "(no such step)"
    if mine and "raw" in mine:
        ex["reference_raw"] = show(mine["raw"], 200)
    if theirs and "raw" in theirs:
        ex["arm_raw"] = show(theirs["raw"], 200)
    ex["arm_stderr"] = show(theirs["stderr"]) if theirs else ""
    return ex


def signature(case, at, ref, arm):
    mine = ref[at]["res"] if at < len(ref) else {}
    theirs = arm[at]["res"] if at < len(arm) else {}
    what = (ref[at] if at < len(ref) else arm[at])["what"].split(" ")
    words = [w for w in what[1:] if not w.startswith("-") and not re.match(r"^\d|book\.db|\.", w)][:2]
    keys = tuple(sorted(k for k in set(mine) | set(theirs) if mine.get(k) != theirs.get(k)))
    return (case["kind"], tuple(words), keys, str(mine.get("status", mine.get("exit"))), str(theirs.get("status", theirs.get("exit"))))


def _rootcause():
    """bench/rootcause.py, loaded by path."""
    spec = importlib.util.spec_from_file_location("bench_rootcause", os.path.join(os.path.dirname(HERE), "rootcause.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def step_command(what):
    """The command of a step, without its values: `tallybook --db b.db tx add 5` -> `tx add`; `GET /accounts/12/close`
    -> `GET accounts/close`."""
    words = what.split(" ")
    if len(words) > 1 and words[0] in ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"):
        return words[0] + " " + "/".join(p for p in words[1].split("?")[0].split("/") if p and not p[:1].isdigit())
    return " ".join([w for w in command_of(words[1:]) if not w.startswith("-") and not re.match(r"^\d|.*\.", w)][:2])


def features(case, at, ref, arm):
    """The input features of a divergent case (bench/rootcause.py): the kind of case, the command of the step that
    differed, and the odd bytes in what the case hands the tool (non-ASCII text, a byte order mark, CR line ends,
    standard input, a closed output pipe)."""
    step = (ref[at] if at < len(ref) else arm[at])["what"]
    found = {"%s:%s" % (case["kind"], step_command(step) or "?")}
    blobs = [bytes.fromhex(h) for h in case.get("files", {}).values()]
    if case.get("stdin_hex") is not None:
        found.add("input:stdin")
        blobs.append(bytes.fromhex(case["stdin_hex"]))
    blobs += [bytes.fromhex(s["stdin_hex"]) for s in case.get("steps", []) if "stdin_hex" in s]
    text = b"\n".join(blobs).decode("utf-8", "replace")
    if any(b.startswith(b"\xef\xbb\xbf") for b in blobs):
        found.add("input:byte-order-mark")
    if "\r" in text.replace("\r\n", ""):
        found.add("input:lone-cr")
    if "\r\n" in text:
        found.add("input:crlf")
    if any(ord(c) > 127 for c in text + " ".join(case.get("argv", []))):
        found.add("input:non-ascii")
    if "\ufffd" in text:
        found.add("input:invalid-utf8")
    if case.get("closed_stdout"):
        found.add("output:closed-pipe")
    return found


def difference(ref, arm, at):
    mine = ref[at]["res"] if at < len(ref) else None
    theirs = arm[at]["res"] if at < len(arm) else None
    return _rootcause().diff_kind(mine, theirs)


def run(cmd, env=None, cases=CASES, cap_s=CAP_S, reference=None):
    """The fragment for `cmd` (an argv list) against the reference. `reference` is (argv, env) of the oracle."""
    planned = generate(CASES)
    digest = case_hash(planned)
    if digest != FROZEN_HASH:
        raise SystemExit("fuzz.py (large): the generator changed (case hash %s, frozen %s): update SEED / FROZEN_HASH "
                         "on purpose, or revert it" % (digest, FROZEN_HASH))
    env = dict(os.environ if env is None else env, PYTHONIOENCODING="utf-8", PYTHONDONTWRITEBYTECODE="1")
    env.pop("TALLYBOOK_DB", None)
    if reference is None:
        ref_cmd = [sys.executable, "-m", "tallybook"]
        ref_env = dict(env, PYTHONPATH=REFERENCE_DIR)
        ref_env.pop("TALLYBOOK_CMD", None)
        ref_env.pop("TALLYBOOK_PHASE", None)
    else:
        ref_cmd, ref_env = reference
    deadline = time.monotonic() + cap_s
    found, ran = [], 0
    todo = planned[:cases]

    def both(case):
        ref = run_case(ref_cmd, ref_env, case)              # a failure here is the fuzz's own bug: let it show
        try:
            arm = run_case(cmd, env, case)
        except Exception as exc:                            # whatever the arm did that the harness cannot read
            arm = [{"what": "(the fuzz could not run this case)", "res": {"harness_error": type(exc).__name__}, "stderr": str(exc)[:300]}]
        return ref, arm

    with ThreadPoolExecutor(WORKERS) as pool:
        for at in range(0, len(todo), CHUNK):
            if ran and time.monotonic() > deadline:
                break
            chunk = todo[at:at + CHUNK]
            for case, (ref, arm) in zip(chunk, list(pool.map(both, chunk))):
                ran += 1
                i = first_difference(ref, arm)
                if i is not None:
                    found.append((signature(case, i, ref, arm), example(case, i, ref, arm),
                                  (features(case, i, ref, arm), difference(ref, arm, i))))
    classes = _rootcause().classify([items for _, _, items in found])
    return {"fuzz_cases": ran, "fuzz_divergences": len(found), "fuzz_classes": classes["classes"],
            "fuzz_class_counts": classes["class_counts"], "fuzz_examples": pick_examples([(s, e) for s, e, _ in found]),
            "fuzz_seed": SEED, "fuzz_hash": digest}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Differential fuzz of a tallybook command against the reference.")
    ap.add_argument("--cmd", help="the arm's command line, a JSON argv list (default: $TALLYBOOK_CMD)")
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
        cmd = [sys.executable, "-m", "tallybook"]
        env = dict(os.environ, PYTHONPATH=REFERENCE_DIR)
    else:
        raw = a.cmd or os.environ.get("TALLYBOOK_CMD")
        try:
            cmd = json.loads(raw) if raw else None
        except ValueError:
            cmd = None
        if not (isinstance(cmd, list) and cmd and all(isinstance(x, str) for x in cmd)):
            print("fuzz.py: give --cmd '[\"tallybook\"]' (or set TALLYBOOK_CMD), or --self", file=sys.stderr)
            return 2
    print(json.dumps(run(cmd, env, a.cases, a.cap), indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

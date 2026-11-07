"""Blind differential-fuzz case generator for the `pennywise` fixture.

Written from the customer brief (brief.md) and the reference implementation only, before looking at any
arm's output or any earlier fuzz generator, so it measures general conformance rather than known bugs.

`generate(n, seed)` returns `n` deterministic case dicts (a prefix of any longer run with the same seed):

    {"id": int, "argv": [str, ...], "ledger_hex": hex | None, "stdin_hex": hex | None, "closed_stdout": bool}

`argv` is everything after `pennywise`; the ledger in the case's cwd is `LEDGER`, `-` is standard input.

Only behaviour the brief pins is generated.  Left out on purpose (the brief is silent or open): leading
whitespace on a line, whitespace-only "blank" lines, amounts like `.5` `5.` `1e3` `-0`, leading zeros,
non-ASCII digits or whitespace as separators, upper-case non-ASCII categories, U+2028 / form feed in
notes, a note holding a line break in `add`, abbreviated or `=`-joined options, `--help`, `--json` on
`export`, options of one command given to another, `add` with too many arguments or `-` as its file,
`add` onto a ledger that is already invalid or that uses CRLF/CR, an invalid entry combined with an
unwritable file, amounts or totals beyond about 1e12, and years below 1000.  A few classes the user asked
for as generic robustness are only partly pinned (exit 1 vs 2 for undecodable bytes, how a lone CR or a
byte order mark is read); they are switched by the *_PCT constants below so they can be set to 0.
"""

import datetime

LEDGER = "ledger.txt"

# Robustness classes the brief does not fully pin (percent of read cases that get them; 0 disables).
BOM_PCT = 1          # ledger starts with a UTF-8 byte order mark
CR_PCT = 1           # old-Mac lone-CR line endings
BAD_UTF8_PCT = 1     # bytes that are not valid UTF-8 (otherwise valid ledger)

_M = 0xFFFFFFFFFFFFFFFF


class Rng:
    def __init__(self, seed):
        self.x = seed & 0xFFFFFFFFFFFFFFFF

    def next(self):
        self.x = (self.x + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        z = self.x
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
        return z ^ (z >> 31)

    def below(self, n):
        return self.next() % n

    def pct(self, p):
        return self.below(100) < p

    def pick(self, seq):
        return seq[self.below(len(seq))]


# --------------------------------------------------------------------------- dates ("The ledger file")

DATE_NONEXISTENT = [
    "2024-02-30", "2023-02-29", "1900-02-29", "2024-04-31", "2024-09-31", "2024-11-31", "2024-13-01",
    "2024-00-15", "2024-06-00", "2024-01-32", "2023-02-31", "2021-02-29", "2024-12-32", "2024-99-99",
]
DATE_MALFORMED = [
    "2024-3-01", "2024-03-1", "24-03-01", "2024/03/01", "20240301", "03-01-2024", "01-03-2024",
    "2024.03.01", "2024-03-01T10:00", "2024-03-011", "12024-03-01", "2024-03", "2024", "March", "today",
    "2024-03-01x", "x2024-03-01", "2024--03-01", "2024-03-01-", "2024_03_01", "1-2-3",
]
DATE_SPECIAL = ["2024-02-29", "2000-02-29", "2020-02-29", "2024-12-31", "2024-01-01", "2023-12-31",
                "2025-01-01", "2024-03-31", "2024-04-30", "2023-02-28", "1000-01-01", "9999-12-31"]


def _iso(d):
    return d.isoformat()


def _dates(rng, count):
    """`count` valid dates in one of several shapes; same-day clusters exercise the stable order."""
    shape = rng.below(100)
    if shape < 50:
        base, span = datetime.date(2024, 3, 1), 31 + rng.below(90)
    elif shape < 70:
        base, span = datetime.date(2020 + rng.below(6), 1 + rng.below(12), 1 + rng.below(28)), 400
    elif shape < 85:
        base, span = datetime.date(2024, 3, 1 + rng.below(20)), 1 + rng.below(4)
    else:
        base, span = datetime.date(2023, 12, 20 + rng.below(10)), 30
    out = [base + datetime.timedelta(days=rng.below(span)) for _ in range(count)]
    if rng.pct(8) and count:
        out[rng.below(count)] = datetime.date.fromisoformat(rng.pick(DATE_SPECIAL[:10]))
    if rng.pct(30):
        out.sort()
    return out


# --------------------------------------------------------------------------- amounts

AMOUNT_BAD = [
    "12.505", "1,000.00", "abc", "12abc", "$5", "5$", "--5", "+-5", "5-", "NaN", "inf", "1.2.3", "0.001",
    "-12.345", "1,5", "1,000", "-", "+", "5.123", "-1,000.00", "+12.505", "12,50", "five", "5 5.5x",
]
AMOUNT_ZERO = ["0", "0.00", "+0", "+0.00", "0.0", "+0.0"]
AMOUNT_TRAP = ["0.10", "0.20", "0.01", "0.07", "-0.03", "0.30", "-0.10", "1.1", "2.2", "-3.3", "19.99",
               "-19.99", "0.99", "-0.99", "0.05"]
AMOUNT_EXTREME = ["99999999999.99", "-99999999999.99", "0.01", "-0.01", "100000000000", "-100000000000",
                  "12345678901.23", "+99999999999", "-0.99", "0.99"]


def _amount(rng, neg_pct=68):
    if rng.pct(2):
        return rng.pick(AMOUNT_ZERO)
    neg = rng.pct(neg_pct)
    m = rng.below(100)
    whole = rng.below(100) if m < 60 else rng.below(3000) if m < 90 else rng.below(100000) if m < 98 \
        else rng.below(10 ** 9)
    if rng.pct(7):
        whole = 0
    d = rng.below(100)
    digits = "" if d < 25 else str(rng.below(10)) if d < 40 else "%02d" % rng.below(100)
    if whole == 0 and not digits.strip("0"):
        neg = False
    sign = "-" if neg else ("+" if rng.pct(15) else "")
    return sign + str(whole) + ("." + digits if digits else "")


# --------------------------------------------------------------------------- categories and notes

CATS = ["groceries", "rent", "salary", "fuel", "utilities", "dining", "health", "gifts", "travel", "coffee",
        "insurance", "savings", "books", "pets"]
CATS_ODD = ["food-out", "cat2", "2024tax", "café", "日本", "naïve", "a_b", "x"]   # lower case already


def _case(rng, name):
    """Vary case with ASCII letters only (non-ASCII case folding is not something the brief promises)."""
    r = rng.below(100)
    if r < 70:
        return name
    if r < 82:
        return name[:1].upper() + name[1:] if "a" <= name[:1] <= "z" else name
    if r < 92:
        return "".join(c.upper() if "a" <= c <= "z" else c for c in name)
    return "".join(c.upper() if "a" <= c <= "z" and rng.pct(50) else c for c in name)


NOTES_PLAIN = ["weekly shop", "March pay", "bus ticket", "rent for march", "birthday", "dentist",
               "train to Leeds", "new shoes", "lunch with Sam", "electric bill", "refund", "coffee beans",
               "gift for mum", "42", "2024-03-02", "x", "two  spaces  inside", "12.505", "-5", "abc def ghi"]
NOTES_AWKWARD = ["milk, eggs, bread", 'the "good" cheese', "it's here", "-refund", "--force", "- item",
                 "#tag", "a # b", "50% off", "$5.00 -3", "a,b,\"c\"", "semi;colon", "back\\slash",
                 "ends with comma,", '"quoted"', "# looks like a comment"]
NOTES_UNICODE = ["café au lait", "日本語のメモ", "pizza 🍕", "Zażółć gęślą", "naïve señor", "price 5",
                 "emoji 👍🏽 ok", "Ünïcödé", "שלום"]
NOTES_TAB = ["a\tb", "col1\tcol2", "x \t y"]


def _note(rng, allow_tab=True):
    r = rng.below(100)
    if r < 60:
        return rng.pick(NOTES_PLAIN)
    if r < 78:
        return rng.pick(NOTES_AWKWARD)
    if r < 92:
        return rng.pick(NOTES_UNICODE)
    if r < 97 and allow_tab:
        return rng.pick(NOTES_TAB)
    if r < 98:
        return " ".join(rng.pick(NOTES_PLAIN) for _ in range(200))      # a long line
    return rng.pick(NOTES_PLAIN) + " " + rng.pick(NOTES_UNICODE)


def _sep(rng):
    r = rng.below(100)
    return " " if r < 72 else "  " if r < 82 else "\t" if r < 90 else " \t" if r < 94 else "\t\t" if r < 97 \
        else "      "


def _entry_line(rng, date, cat, amount, note, allow_trailing=True):
    line = _iso(date) + _sep(rng) + cat + _sep(rng) + amount
    if note:
        line += _sep(rng) + note
    if allow_trailing and rng.pct(6):
        line += rng.pick([" ", "  ", "\t", " \t ", "   "])
    return line


# --------------------------------------------------------------------------- bad ledger lines

def _bad_line(rng):
    date = _iso(datetime.date(2024, 3, 1 + rng.below(28)))
    cat = rng.pick(CATS)
    kind = rng.below(100)
    if kind < 22:
        return "%s %s %s %s" % (rng.pick(DATE_NONEXISTENT), cat, _amount(rng), rng.pick(NOTES_PLAIN))
    if kind < 38:
        return "%s %s %s" % (rng.pick(DATE_MALFORMED), cat, _amount(rng))
    if kind < 66:
        return "%s %s %s%s" % (date, cat, rng.pick(AMOUNT_BAD), " " + rng.pick(NOTES_PLAIN) if rng.pct(40) else "")
    if kind < 76:
        return rng.pick([date, date + " " + cat, "lonely", cat + " " + _amount(rng), date + "\t" + cat])
    if kind < 84:
        return "%s %s %s" % (cat, date, _amount(rng))                  # fields in the wrong order
    if kind < 92:
        return "%s %s %s" % (date, cat, rng.pick(["weekly shop", "birthday gift", "rent march"]))   # no amount
    return "%s %s %s" % (rng.pick(DATE_NONEXISTENT), cat, rng.pick(AMOUNT_BAD))


# --------------------------------------------------------------------------- whole ledgers

COMMENTS = ["# household, March", "# ledger", "#", "#no space", "# 2024-03-01 broken line here", "## section",
            "# note to self", "#2024-03-01 groceries abc", "# 日本 café", "# trailing space  ", "#\t tabbed"]


def _lines(rng, count, style, csv_safe):
    cats = [rng.pick(CATS) for _ in range(1 + rng.below(6))]
    if rng.pct(10):
        cats.append(rng.pick(CATS_ODD))
    fixed_case = rng.pct(50)
    spelled = {c: _case(rng, c) for c in cats}
    dates = _dates(rng, count)
    lines, used_dates, used_cats = [], [], set()
    if rng.pct(25):
        lines.append(rng.pick(COMMENTS))
    for d in dates:
        c = rng.pick(cats)
        shown = spelled[c] if fixed_case else _case(rng, c)
        if style == "trap":
            amount = rng.pick(AMOUNT_TRAP)
        elif style == "extreme":
            amount = rng.pick(AMOUNT_EXTREME)
        else:
            amount = _amount(rng)
        note = _note(rng, allow_tab=not csv_safe) if rng.pct(55) else ""
        if rng.pct(8):
            lines.append("")
        if rng.pct(8):
            lines.append(rng.pick(COMMENTS))
        lines.append(_entry_line(rng, d, shown, amount, note))
        used_dates.append(d)
        used_cats.add(c)
    if count == 0 and rng.pct(40):
        lines += [rng.pick(COMMENTS), "", rng.pick(COMMENTS)][: 1 + rng.below(3)]
    return lines, used_dates, sorted(used_cats)


def _ledger(rng, mode, mistake=False):
    """(bytes, info).  mode: read | csv (read, but CSV-neutral notes) | plain (clean, LF) | add (clean, LF)."""
    r = rng.below(100)
    if mode == "add":
        count = rng.below(9)
    elif mode == "plain":
        count = 1 + rng.below(6)
    else:
        count = 0 if r < 3 else 1 if r < 8 else 2 + rng.below(11) if r < 85 else 13 + rng.below(28) if r < 95 \
            else 41 + rng.below(210)
    s = rng.below(100)
    style = "trap" if s < 3 else "extreme" if s < 6 else "normal"
    if style == "extreme":
        count = min(count, 10)
    lines, dates, cats = _lines(rng, count, style, csv_safe=(mode == "csv"))
    if mistake:
        for _ in range(1 if rng.pct(80) else 2 + rng.below(2)):
            lines.insert(rng.below(len(lines) + 1), _bad_line(rng))
    clean = mode in ("plain", "add")
    bad_utf8 = False
    if mode in ("read", "csv") and not mistake and rng.pct(BAD_UTF8_PCT):
        bad_utf8 = True
        lines.insert(rng.below(len(lines) + 1), "\x00BAD" + str(rng.below(3)))   # replaced below by raw bytes

    if clean:
        eol = "\n"
        mixed = False
    else:
        e = rng.below(100)
        eol = "\r" if e < CR_PCT else "\r\n" if e < CR_PCT + 9 else "\n"
        mixed = eol == "\n" and rng.pct(2)
    final_nl = rng.pct(75 if mode == "add" else 88)

    chunks = []
    for i, line in enumerate(lines):
        last = i == len(lines) - 1
        if last and not final_nl:
            term = ""
        else:
            term = rng.pick(["\n", "\r\n"]) if mixed else eol
        chunks.append((line, term))
    out = b""
    for line, term in chunks:
        if line.startswith("\x00BAD"):
            junk = [b"# \xff\xfe junk", b"2024-03-05 cafe -3.50 caf\xe9", b"# \xc3\x28 broken", b"# trunc \xe2\x82"]
            out += junk[int(line[4:])] + term.encode()
        else:
            out += (line + term).encode("utf-8")
    if mode in ("read", "csv") and rng.pct(BOM_PCT):
        out = b"\xef\xbb\xbf" + out
    return out, {"dates": dates, "cats": cats, "mistake": mistake, "bad_utf8": bad_utf8}


# --------------------------------------------------------------------------- read commands

def _filter_date(rng, info):
    if info["dates"] and rng.pct(60):
        return rng.pick(info["dates"])
    if info["dates"] and rng.pct(75):
        return rng.pick(info["dates"]) + datetime.timedelta(days=rng.below(21) - 10)
    return datetime.date(2024, 1 + rng.below(12), 1 + rng.below(28))


def _list_opts(rng, info):
    groups = []
    if rng.pct(30):
        r = rng.below(100)
        if info["cats"] and r < 70:
            value = _case(rng, rng.pick(info["cats"]))
        elif r < 85:
            value = rng.pick(["nonexistent", "zzz", "misc"])
        else:
            value = rng.pick(CATS).upper()
        groups.append(["--category", value])
    since = until = None
    if rng.pct(30):
        since = _filter_date(rng, info)
        groups.append(["--since", _iso(since)])
    if rng.pct(25):
        until = _filter_date(rng, info)
        if since is not None and rng.pct(15):
            until = since                                         # a one-day window; both ends included
        groups.append(["--until", _iso(until)])
    if rng.pct(25):
        groups.append(["--json"])
    return groups


def _options(rng, cmd, info):
    if cmd == "balance":
        groups = [["--json"]] if rng.pct(25) else []
    elif cmd == "summary":
        groups = []
        if rng.pct(60):
            groups.append(["--by", "month" if rng.pct(60) else "category"])
        if rng.pct(25):
            groups.append(["--json"])
    elif cmd == "list":
        groups = _list_opts(rng, info)
    else:                                                          # export
        groups = [["--format", "csv"]] if rng.pct(20) else []
    for i in range(len(groups) - 1, 0, -1):                        # option order is free
        j = rng.below(i + 1)
        groups[i], groups[j] = groups[j], groups[i]
    return [a for g in groups for a in g]


def _read_case(rng, cmd):
    mistake = rng.pct(11)
    ledger, info = _ledger(rng, "csv" if cmd == "export" else "read", mistake)
    opts = _options(rng, cmd, info)
    closed = not mistake and not info["bad_utf8"] and rng.pct(2)
    if rng.pct(12):                                                # ledger on standard input
        stdin = ledger if not rng.pct(5) else None
        decoy = _ledger(rng, "plain")[0] if rng.pct(10) else None  # a different ledger.txt that must be ignored
        return [cmd, "-"] + opts, decoy, stdin, closed
    return [cmd, LEDGER] + opts, ledger, None, closed


# --------------------------------------------------------------------------- command-line and file problems

def _usage_case(rng):
    cmd = rng.pick(["balance", "summary", "list", "export"])
    sub = rng.below(100)
    f = "-" if rng.pct(10) else LEDGER
    if sub < 8:
        argv = []
    elif sub < 20:
        argv = [rng.pick(["bal", "totals", "import", "delete", "frobnicate", "sum", "ls", "report"]), f]
    elif sub < 32:
        argv = [rng.pick(["balance", "summary", "list", "export"])]
    elif sub < 42:
        argv = ["summary", f, "--by", rng.pick(["year", "week", "day", "categories", "months", ""])]
    elif sub < 50:
        argv = ["export", f, "--format", rng.pick(["json", "xml", "tsv", "yaml", ""])]
    elif sub < 70:
        bad = rng.pick(DATE_NONEXISTENT + DATE_MALFORMED + ["yesterday", "", "last week"])
        argv = ["list", f, rng.pick(["--since", "--until"]), bad]
        if rng.pct(30):
            argv += ["--json"]
    elif sub < 78:
        argv = rng.pick([["list", f, "--category"], ["list", f, "--since"], ["list", f, "--until"],
                         ["summary", f, "--by"], ["export", f, "--format"]])
    elif sub < 88:
        argv = [cmd, f, rng.pick(["--bogus", "--verbose", "--output", "--frobnicate"])]
    else:
        argv = [cmd, f, "extra"]
    ledger = None if rng.pct(15) else _ledger(rng, "plain")[0]
    stdin = _ledger(rng, "plain")[0] if f == "-" else None
    return argv, ledger, stdin, False


def _file_problem_case(rng):
    cmd = rng.pick(["balance", "summary", "list", "export"])
    sub = rng.below(100)
    ledger = None
    if sub < 45:
        path = LEDGER
    elif sub < 70:
        path = rng.pick(["nofile.txt", "missing/ledger.txt", "other.txt", "ledger.txt.bak"])
        if rng.pct(60):
            ledger = _ledger(rng, "plain")[0]                      # a good ledger.txt exists, but is not asked for
    elif sub < 85:
        path = "."                                                 # a directory is not a ledger
        ledger = _ledger(rng, "plain")[0] if rng.pct(50) else None
    else:
        path = "/nonexistent-dir/pennywise/ledger.txt"
    argv = [cmd, path] + (["--json"] if cmd != "export" and rng.pct(20) else [])
    return argv, ledger, None, False


# --------------------------------------------------------------------------- add

def _valid_add_fields(rng):
    date = rng.pick(DATE_SPECIAL[:10]) if rng.pct(15) else \
        _iso(datetime.date(2020 + rng.below(6), 1 + rng.below(12), 1 + rng.below(28)))
    cat = _case(rng, rng.pick(CATS_ODD if rng.pct(8) else CATS))
    amount = _amount(rng)
    r = rng.below(100)
    if r < 38:
        note = None
    elif r < 42:
        note = ""
    elif r < 46:
        note = rng.pick(["   ", "\t", " \t "])                    # trims to nothing
    else:
        note = _note(rng)
        if rng.pct(10):
            note = rng.pick(["  ", "\t", " "]) + note + rng.pick(["  ", " \t", " "])
    return [date, cat, amount] + ([note] if note is not None else [])


def _add_case(rng):
    ledger = None if rng.pct(30) else _ledger(rng, "add")[0]
    sub = rng.below(100)
    if sub < 72:
        fields = _valid_add_fields(rng)
    elif sub < 94:
        fields = _valid_add_fields(rng)
        which = rng.below(100)
        if which < 35:
            fields[0] = rng.pick(DATE_NONEXISTENT + DATE_MALFORMED + [""])
        elif which < 45:
            fields[1] = rng.pick(["", "two words", "tab\tsep", " ", "a b c"])
        elif which < 90:
            fields[2] = rng.pick(AMOUNT_BAD + ["", "-abc", "-12.505", "- 5"])
        else:
            fields[0] = rng.pick(DATE_NONEXISTENT)
            fields[2] = rng.pick(AMOUNT_BAD)
    elif sub < 97:
        full = _valid_add_fields(rng)
        return ["add", LEDGER] + full[: rng.below(3)], ledger, None, False        # too few arguments
    else:
        fields = _valid_add_fields(rng)
        path = rng.pick(["nodir/ledger.txt", "."])                                   # cannot be written
        return ["add", path] + fields, ledger, None, False
    return ["add", LEDGER] + fields, ledger, None, False


# --------------------------------------------------------------------------- driver

def _build(i, seed):
    rng = Rng((seed & _M) ^ (((i + 1) * 0xD1B54A32D192ED03) & _M))
    rng.next()
    roll = rng.below(100)
    if roll < 16:
        parts = _read_case(rng, "balance")
    elif roll < 35:
        parts = _read_case(rng, "summary")
    elif roll < 62:
        parts = _read_case(rng, "list")
    elif roll < 72:
        parts = _read_case(rng, "export")
    elif roll < 88:
        parts = _add_case(rng)
    elif roll < 95:
        parts = _usage_case(rng)
    else:
        parts = _file_problem_case(rng)
    argv, ledger, stdin, closed = parts
    return {"id": i, "argv": argv,
            "ledger_hex": None if ledger is None else ledger.hex(),
            "stdin_hex": None if stdin is None else stdin.hex(),
            "closed_stdout": bool(closed)}


def generate(n, seed):
    return [_build(i, seed) for i in range(n)]

"""Import bank statements: a CSV file plus a profile (how to read that bank's columns) become balanced transactions.

Each good row becomes a transaction of two postings, the bank account and a counter account chosen by the rules (or
the profile's default account). Bad rows are reported with their row number and never stop the good ones; rows that
were imported before are recognised and left out.
"""
import csv
import io
import re
from collections import Counter
from dataclasses import dataclass, field
from datetime import date
from typing import List, Tuple

from .currency import currency as _currency
from .errors import ParseError, TallybookError
from .model import Posting, Transaction
from .money import Money
from .rules import ACCOUNT_PATH, parse_rules


class CsvImportError(ParseError):
    """A profile or a file that cannot be imported at all (as opposed to one bad row). `.line` is the profile line
    for a bad profile setting, else None."""

    def __init__(self, message, line=None):
        super().__init__(("line %d: %s" % (line, message)) if line else message, line=line)
        self.line = line


_DELIMITERS = {"comma": ",", "tab": "\t", "semicolon": ";", "pipe": "|", "space": " "}
_THOUSANDS = {"none": "", "space": " ", "comma": ",", "dot": ".", "apostrophe": "'"}
_BOOLS = {"yes": True, "true": True, "no": False, "false": False}
_MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
           "november", "december"]
_SETTINGS = ("date_column", "date_format", "payee_column", "narration_column", "amount_column", "debit_column",
             "credit_column", "currency", "account", "default_account", "delimiter", "skip_rows", "has_header",
             "negate", "decimal_separator", "thousands_separator", "flag", "tags")
_DIRECTIVES = {"Y": r"(?P<Y>[0-9]{4})", "y": r"(?P<y>[0-9]{2})", "m": r"(?P<m>[0-9]{1,2})",
               "d": r"(?P<d>[0-9]{1,2})", "b": r"(?P<b>[A-Za-z]{3})", "B": r"(?P<B>[A-Za-z]+)"}


@dataclass
class ImportProfile:
    date_column: str
    payee_column: str
    currency: str
    account: str
    date_format: str = "%Y-%m-%d"
    narration_column: str = None
    amount_column: str = None
    debit_column: str = None
    credit_column: str = None
    default_account: str = None
    delimiter: str = ","
    skip_rows: int = 0
    has_header: bool = True
    negate: bool = False
    decimal_separator: str = "."
    thousands_separator: str = ""
    flag: str = "*"
    tags: Tuple[str, ...] = ()


@dataclass
class ImportResult:
    transactions: List[Transaction] = field(default_factory=list)
    duplicates: List[Transaction] = field(default_factory=list)
    errors: List[Tuple[int, str]] = field(default_factory=list)


# ---------------------------------------------------------------- profile

def _column_ref(value, has_header, lineno):
    m = re.fullmatch(r"#([0-9]+)", value)
    if m:
        if int(m.group(1)) < 1:
            raise CsvImportError("column numbers start at 1: %s" % value, lineno)
        return value
    if value.startswith("#") or not value:
        raise CsvImportError("invalid column %r (a header name or #N)" % value, lineno)
    if not has_header:
        raise CsvImportError("column %r must be given as #N because has_header is no" % value, lineno)
    return value


def _setting(settings, key, value, lineno):
    """Convert the text of one profile setting; `settings` holds those already read (has_header comes first)."""
    if key in ("date_column", "payee_column", "narration_column", "amount_column", "debit_column", "credit_column"):
        return _column_ref(value, settings.get("has_header", True), lineno)
    if key in ("account", "default_account"):
        if not ACCOUNT_PATH.match(value):
            raise CsvImportError("invalid account path %r" % value, lineno)
        return value
    if key == "currency":
        try:
            _currency(value)
        except TallybookError as e:
            raise CsvImportError(e.message, lineno)
        return value
    if key == "date_format":
        _compile_date_format(value, lineno)
        return value
    if key == "delimiter":
        value = _DELIMITERS.get(value, value)
        if len(value) != 1 or value in '"\r\n':
            raise CsvImportError("delimiter must be one character (or comma, tab, semicolon, pipe, space)", lineno)
        return value
    if key == "skip_rows":
        if not value.isdigit() or not value.isascii():
            raise CsvImportError("skip_rows must be a whole number, not %r" % value, lineno)
        return int(value)
    if key in ("has_header", "negate"):
        if value.lower() not in _BOOLS:
            raise CsvImportError("%s must be yes or no, not %r" % (key, value), lineno)
        return _BOOLS[value.lower()]
    if key == "decimal_separator":
        if value not in (".", ","):
            raise CsvImportError("decimal_separator must be . or ,", lineno)
        return value
    if key == "thousands_separator":
        value = _THOUSANDS.get(value, value)
        if value not in ("", ",", ".", " ", "'"):
            raise CsvImportError("thousands_separator must be none, comma, dot, space or apostrophe", lineno)
        return value
    if key == "flag":
        if value not in ("*", "!"):
            raise CsvImportError("flag must be * or !", lineno)
        return value
    tags = [t.strip().lower() for t in value.split(",") if t.strip()]
    if not tags or not all(re.fullmatch(r"[A-Za-z0-9_-]+", t) for t in tags):
        raise CsvImportError("tags must be a comma separated list of tag names", lineno)
    return tuple(sorted(set(tags)))


def parse_profile(text):
    if text.startswith("﻿"):
        text = text[1:]
    raw = {}
    for lineno, line in enumerate(text.split("\n"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, eq, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if not eq:
            raise CsvImportError("expected 'setting = value', found %r" % line, lineno)
        if key not in _SETTINGS:
            raise CsvImportError("unknown setting %r" % key, lineno)
        if key in raw:
            raise CsvImportError("%s is set twice" % key, lineno)
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        raw[key] = (value, lineno)
    settings = {}
    # has_header first: it decides how column names may be written
    for key in ["has_header"] + [k for k in raw if k != "has_header"]:
        if key in raw:
            settings[key] = _setting(settings, key, raw[key][0], raw[key][1])
    for key in ("date_column", "payee_column", "currency", "account"):
        if key not in settings:
            raise CsvImportError("missing required setting %r" % key)
    amount, debit, credit = (settings.get(k) for k in ("amount_column", "debit_column", "credit_column"))
    if amount and (debit or credit):
        raise CsvImportError("use either amount_column or debit_column with credit_column, not both")
    if not amount and not (debit and credit):
        raise CsvImportError("give amount_column, or both debit_column and credit_column")
    if settings.get("decimal_separator", ".") == settings.get("thousands_separator", ""):
        raise CsvImportError("decimal_separator and thousands_separator must differ")
    return ImportProfile(**settings)


# ---------------------------------------------------------------- cells

def _compile_date_format(fmt, lineno=None):
    parts, seen, i = [], set(), 0
    while i < len(fmt):
        if fmt[i] != "%":
            parts.append(re.escape(fmt[i]))
            i += 1
            continue
        code = fmt[i + 1:i + 2]
        i += 2
        if code == "%":
            parts.append("%")
        elif code in _DIRECTIVES:
            if code in seen:
                raise CsvImportError("date_format uses %%%s twice" % code, lineno)
            seen.add(code)
            parts.append(_DIRECTIVES[code])
        else:
            raise CsvImportError("date_format: unsupported directive %r (use %%Y %%y %%m %%d %%b %%B %%%%)"
                                 % ("%" + code), lineno)
    if len(seen & {"Y", "y"}) != 1 or len(seen & {"m", "b", "B"}) != 1 or "d" not in seen:
        raise CsvImportError("date_format needs a year (%Y or %y), a month (%m, %b or %B) and a day (%d)", lineno)
    return re.compile("".join(parts))


def _parse_date(cell, pattern):
    m = pattern.fullmatch(cell.strip())
    if m is None:
        raise ValueError
    g = m.groupdict()
    year = int(g["Y"]) if g.get("Y") else 2000 + int(g["y"])
    if g.get("m"):
        month = int(g["m"])
    elif g.get("B"):
        month = _MONTHS.index(g["B"].lower()) + 1
    else:
        names = [name[:3] for name in _MONTHS]
        month = names.index(g["b"].lower()) + 1
    return date(year, month, int(g["d"]))


def _amount_pattern(profile):
    dec = re.escape(profile.decimal_separator)
    if profile.thousands_separator:
        grouped = r"|[0-9]{1,3}(?:%s[0-9]{3})+" % re.escape(profile.thousands_separator)
    else:
        grouped = ""
    return re.compile(r"(?P<sign>[+-])?(?P<int>[0-9]+%s)(?:%s(?P<frac>[0-9]+))?" % (grouped, dec))


def _parse_amount(cell, profile, pattern):
    """The signed minor units of one amount cell; ValueError carries a message naming the cell."""
    text = cell.strip()
    negative = False
    if text.startswith("(") and text.endswith(")"):
        negative, text = True, text[1:-1].strip()
    m = pattern.fullmatch(text)
    if m is None or (negative and m.group("sign")):
        raise ValueError("invalid amount %r" % cell.strip())
    exponent = _currency(profile.currency).exponent
    frac = m.group("frac") or ""
    if len(frac) > exponent:
        raise ValueError("invalid amount %r: %s has at most %d decimal places" % (cell.strip(), profile.currency, exponent))
    whole = m.group("int").replace(profile.thousands_separator or "\0", "")
    minor = int(whole + frac.ljust(exponent, "0"))
    return -minor if negative or m.group("sign") == "-" else minor


def _clean(text):
    return " ".join(text.split())


# ---------------------------------------------------------------- import

class _RowError(Exception):
    pass


def _locate(ref, header):
    """The zero-based index of a column reference; `header` is the lower-cased header cells or None."""
    if ref.startswith("#"):
        return int(ref[1:]) - 1
    try:
        return header.index(ref.strip().lower())
    except ValueError:
        raise CsvImportError("the file has no column named %r" % ref)


def _cell(record, index, ref):
    if index >= len(record):
        raise _RowError("missing column %r (the row has %d columns)" % (ref, len(record)))
    return record[index]


def dedupe_key(tx, account):
    """(date, the amount of the first posting to `account`, payee), or None if the transaction has no such posting."""
    for p in tx.postings:
        if p.account == account:
            return (tx.date, p.amount, tx.payee)
    return None


def import_csv(text, profile, rules=None, existing=()):
    """Turn CSV text into an ImportResult. `profile` is an ImportProfile or profile text; `rules` a RuleSet, rules
    text or None; `existing` the transactions already in the book (for recognising rows imported before)."""
    if isinstance(profile, str):
        profile = parse_profile(profile)
    if isinstance(rules, str):
        rules = parse_rules(rules)
    if text.startswith("﻿"):
        text = text[1:]
    pattern = _compile_date_format(profile.date_format)
    amount_re = _amount_pattern(profile)
    already = Counter(k for k in (dedupe_key(t, profile.account) for t in existing) if k is not None)
    seen = Counter()

    stream = io.StringIO(text, newline="")
    consumed = 0
    for _ in range(profile.skip_rows):
        if not stream.readline():
            break
        consumed += 1
    reader = csv.reader(stream, delimiter=profile.delimiter, quotechar='"')
    result = ImportResult()
    columns = None          # name -> index, resolved on the header (or from #N when there is none)
    header = None
    last_end = consumed
    for record in reader:
        start, last_end = last_end + 1, consumed + reader.line_num
        if not any(cell.strip() for cell in record):
            continue
        if columns is None:
            header = [c.strip().lower() for c in record] if profile.has_header else None
            refs = {k: getattr(profile, k) for k in ("date_column", "payee_column", "narration_column",
                                                     "amount_column", "debit_column", "credit_column")}
            columns = {k: _locate(v, header) for k, v in refs.items() if v}
            if profile.has_header:
                continue
        try:
            tx = _build(record, columns, profile, pattern, amount_re, rules)
        except _RowError as e:
            result.errors.append((start, str(e)))
            continue
        key = dedupe_key(tx, profile.account)
        seen[key] += 1
        (result.duplicates if seen[key] <= already[key] else result.transactions).append(tx)
    if columns is None and profile.has_header:
        raise CsvImportError("the file has no header row")
    return result


def _build(record, columns, profile, pattern, amount_re, rules):
    ref = lambda name: getattr(profile, name)   # noqa: E731
    raw_date = _cell(record, columns["date_column"], ref("date_column")).strip()
    try:
        day = _parse_date(raw_date, pattern)
    except ValueError:
        raise _RowError("invalid date %r (expected the format %s)" % (raw_date, profile.date_format))
    payee = _clean(_cell(record, columns["payee_column"], ref("payee_column")))
    if not payee:
        raise _RowError("empty payee")
    narration = ""
    if "narration_column" in columns and columns["narration_column"] < len(record):
        narration = _clean(record[columns["narration_column"]])
    try:
        if "amount_column" in columns:
            minor = _parse_amount(_cell(record, columns["amount_column"], ref("amount_column")), profile, amount_re)
        else:
            debit = _cell(record, columns["debit_column"], ref("debit_column")).strip()
            credit = _cell(record, columns["credit_column"], ref("credit_column")).strip()
            if debit and credit:
                raise _RowError("both debit %r and credit %r are filled" % (debit, credit))
            if not debit and not credit:
                raise _RowError("no amount: debit and credit are both empty")
            minor = (_parse_amount(credit, profile, amount_re) if credit else 0) - \
                    (_parse_amount(debit, profile, amount_re) if debit else 0)
    except ValueError as e:
        raise _RowError(str(e))
    if profile.negate:
        minor = -minor
    if minor == 0:
        raise _RowError("the amount is zero")
    amount = Money(minor, profile.currency)

    actions = rules.apply({"payee": payee, "narration": narration, "amount": amount, "date": day}) if rules else None
    actions = actions or {}
    counter = actions.get("account") or profile.default_account
    if counter is None:
        raise _RowError("no account for this row: no rule matches and the profile has no default_account")
    tags = tuple(sorted(set(profile.tags) | set(actions.get("tags", ()))))
    return Transaction(date=day, payee=actions.get("payee", payee), narration=actions.get("narration", narration),
                       postings=[Posting(profile.account, amount), Posting(counter, -amount)], tags=tags,
                       flag=actions.get("flag", profile.flag))

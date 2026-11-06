"""The text journal: a plain file of account declarations, exchange rates and transactions, in the style of ledger-cli.

    account Assets:Bank:Checking USD open 2023-01-01 "main account"
    rate 2024-03-01 USD EUR 0.92

    2024-03-01 * "Employer" "March pay" #salary
      Income:Salary          -2500.00 USD
      Assets:Bank:Checking    2500.00 USD  ; net

`parse_journal` is strict and reports the 1-based line of the first mistake; `format_journal` writes the one canonical
layout, so format(parse(text)) == text for text that is already canonical. Parsing checks the syntax only: whether a
transaction balances or its accounts exist is the ledger's business (see Journal.to_ledger).
"""
import re
from dataclasses import dataclass, field
from datetime import date
from typing import List, Tuple

from .accounts import ROOT_TYPES, valid_path
from .currency import CURRENCIES
from .dates import format_date, parse_date
from .errors import ParseError, TallybookError
from .model import Account, Posting, Transaction
from .money import Money

_TAG = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
_RATE = re.compile(r"[0-9]+(?:\.[0-9]{1,8})?")
_CODE = re.compile(r"[A-Z]{3}")


class JournalError(ParseError):
    """A mistake in journal text. `.line` is the 1-based line number and the message starts with `line N: `."""

    def __init__(self, message, line=None, **detail):
        super().__init__(message, **detail)
        self.line = line


@dataclass
class Journal:
    accounts: List[Account] = field(default_factory=list)
    rates: List[Tuple[str, str, date, str]] = field(default_factory=list)    # (src, dst, date, rate text)
    transactions: List[Transaction] = field(default_factory=list)

    def to_ledger(self):
        """A new Ledger holding everything in this journal. Ledger and chart errors are raised as they are."""
        from .ledger import Ledger
        ledger = Ledger()
        for account in self.accounts:
            ledger.chart.add(account.path, account.type, account.currency, account.opened, account.note)
            if account.closed is not None:
                ledger.chart.close(account.path, account.closed)
        for src, dst, on, text in self.rates:
            ledger.rates.set(src, dst, text, on)
        for tx in self.transactions:
            ledger.add(tx)
        return ledger


# ---------------------------------------------------------------- reading

class _Reader:
    def __init__(self, text):
        if text.startswith("﻿"):
            text = text[1:]
        self.lines = re.split(r"\r\n|\n", text)
        self.n = 0

    def fail(self, message):
        raise JournalError("line %d: %s" % (self.n, message), line=self.n)

    def tokens(self, text):
        """Split a line into ("word", text) and ("str", text) tokens plus the `;` comment (None when absent)."""
        out, i, size = [], 0, len(text)
        while i < size:
            ch = text[i]
            if ch in " \t":
                i += 1
            elif ch == ";":
                return out, text[i + 1:].strip()
            elif ch == '"':
                i += 1
                buf = []
                while True:
                    if i >= size:
                        self.fail("unterminated quoted string")
                    ch = text[i]
                    if ch == "\\":
                        if i + 1 >= size or text[i + 1] not in '"\\':
                            self.fail("a backslash in a quoted string must be followed by \\ or \"")
                        buf.append(text[i + 1])
                        i += 2
                    elif ch == '"':
                        i += 1
                        break
                    else:
                        buf.append(ch)
                        i += 1
                out.append(("str", "".join(buf)))
                if i < size and text[i] not in " \t;":
                    self.fail("expected a space after a quoted string")
            else:
                j = i
                while j < size and text[j] not in " \t;":
                    if text[j] == '"':
                        self.fail("a quote can only start a quoted string")
                    j += 1
                out.append(("word", text[i:j]))
                i = j
        return out, None

    def wrap(self, call, *args):
        """Run a parser from another module; its error becomes a JournalError for the current line."""
        try:
            return call(*args)
        except JournalError:
            raise
        except TallybookError as exc:
            self.fail(exc.message)

    def parse(self):
        journal = Journal()
        seen = set()
        current = None
        for self.n, raw in enumerate(self.lines, 1):
            stripped = raw.strip(" \t")
            if not stripped:
                current = None
            elif stripped[0] in ";#":
                continue
            elif raw[0] in " \t":
                if current is None:
                    self.fail("a posting must follow a transaction line")
                current.postings.append(self.posting(raw))
            else:
                current = None
                word = stripped.split(None, 1)[0]
                if word == "account":
                    journal.accounts.append(self.account(raw, seen))
                elif word == "rate":
                    journal.rates.append(self.rate(raw))
                elif word[0].isdigit():
                    current = self.header(raw)
                    journal.transactions.append(current)
                else:
                    self.fail("unknown directive '%s'" % word)
        return journal

    def account(self, raw, seen):
        tokens, _ = self.tokens(raw)
        rest = list(tokens[1:])
        if not rest or rest[0][0] != "word" or not valid_path(rest[0][1]):
            self.fail("account needs a valid account path")
        path = rest.pop(0)[1]
        if path in seen:
            self.fail("account %s is declared twice" % path)
        seen.add(path)
        currency = opened = closed = None
        note = ""
        if rest and rest[0][0] == "word" and _CODE.fullmatch(rest[0][1]):
            currency = rest.pop(0)[1]
            if currency not in CURRENCIES:
                self.fail("unknown currency '%s'" % currency)
        for keyword in ("open", "close"):
            if len(rest) >= 2 and rest[0] == ("word", keyword):
                day = self.wrap(parse_date, rest[1][1]) if rest[1][0] == "word" else self.fail("bad date")
                rest = rest[2:]
                if keyword == "open":
                    opened = day
                else:
                    closed = day
        if rest and rest[0][0] == "str":
            note = rest.pop(0)[1]
        if rest:
            self.fail("unexpected '%s' in the account line" % rest[0][1])
        if opened is not None and closed is not None and closed < opened:
            self.fail("account %s is closed before it opens" % path)
        return Account(path, ROOT_TYPES[path.split(":")[0]], currency, opened, closed, note)

    def rate(self, raw):
        tokens, _ = self.tokens(raw)
        if len(tokens) != 5 or any(kind != "word" for kind, _ in tokens):
            self.fail("a rate line is: rate DATE FROM TO RATE")
        day = self.wrap(parse_date, tokens[1][1])
        src, dst, text = tokens[2][1], tokens[3][1], tokens[4][1]
        for code in (src, dst):
            if code not in CURRENCIES:
                self.fail("unknown currency '%s'" % code)
        if src == dst:
            self.fail("a rate needs two different currencies")
        if not _RATE.fullmatch(text) or not text.replace(".", "").strip("0"):
            self.fail("invalid rate '%s': a positive number with up to 8 decimals" % text)
        return (src, dst, day, text)

    def header(self, raw):
        tokens, _ = self.tokens(raw)
        if tokens[0][0] != "word":
            self.fail("a transaction line starts with a date")
        day = self.wrap(parse_date, tokens[0][1])
        rest = tokens[1:]
        flag = "*"
        if rest and rest[0][0] == "word" and rest[0][1] in ("*", "!"):
            flag = rest.pop(0)[1]
        strings = []
        while rest and rest[0][0] == "str" and len(strings) < 2:
            strings.append(rest.pop(0)[1])
        if not strings:
            self.fail('a transaction needs a quoted payee, like "Employer"')
        tags = set()
        for kind, value in rest:
            if kind != "word" or value[:1] != "#" or not _TAG.fullmatch(value[1:]):
                self.fail("unexpected '%s' in the transaction line (tags look like #salary)" % value)
            tags.add(value[1:])
        return Transaction(day, strings[0], strings[1] if len(strings) > 1 else "", [], tuple(sorted(tags)), flag)

    def posting(self, raw):
        tokens, comment = self.tokens(raw)
        if not tokens or any(kind != "word" for kind, _ in tokens):
            self.fail("a posting is an account, then optionally an amount and a currency")
        words = [value for _, value in tokens]
        account = words[0]
        if not valid_path(account):
            self.fail("invalid account path '%s'" % account)
        if len(words) == 1:
            amount = None
        elif len(words) == 3:
            amount = self.wrap(Money.of, words[1], words[2])
        else:
            self.fail("a posting is an account, then optionally an amount and a currency")
        return Posting(account, amount, comment or "")


def parse_journal(text):
    """Journal text to a Journal. Raises JournalError (with .line) on the first mistake."""
    return _Reader(text).parse()


# ---------------------------------------------------------------- writing

def _quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _format_account(account):
    parts = ["account", account.path]
    if account.currency:
        parts.append(account.currency)
    if account.opened is not None:
        parts += ["open", format_date(account.opened)]
    if account.closed is not None:
        parts += ["close", format_date(account.closed)]
    if account.note:
        parts.append(_quote(account.note))
    return " ".join(parts)


def format_transaction(tx):
    """One transaction as canonical text, ending with a newline. Postings are indented two spaces; account names
    are padded to the longest one that has an amount, then two spaces, then the amounts right-aligned to a common
    width, one space and the currency; a posting note follows after two spaces as `; note`."""
    header = "%s %s %s" % (format_date(tx.date), tx.flag, _quote(tx.payee))
    if tx.narration:
        header += " " + _quote(tx.narration)
    for tag in sorted(set(tx.tags)):
        header += " #" + tag
    amounts = [p.amount.amount_str() for p in tx.postings if p.amount is not None]
    name_width = max([len(p.account) for p in tx.postings if p.amount is not None] or [0])
    number_width = max([len(a) for a in amounts] or [0])
    lines = [header]
    for p in tx.postings:
        line = "  " + p.account
        if p.amount is not None:
            line = "  %s  %s %s" % (p.account.ljust(name_width), p.amount.amount_str().rjust(number_width),
                                    p.amount.currency)
        if p.note:
            line += "  ; " + p.note
        lines.append(line)
    return "\n".join(lines) + "\n"


def format_journal(journal):
    """Journal to canonical text: the account lines, then the rate lines, then the transactions, each group in list
    order and separated from the next by one blank line; the text ends with a single newline, empty for nothing."""
    groups = []
    if journal.accounts:
        groups.append("".join(_format_account(a) + "\n" for a in journal.accounts))
    if journal.rates:
        groups.append("".join("rate %s %s %s %s\n" % (format_date(on), src, dst, text)
                              for src, dst, on, text in journal.rates))
    groups.extend(format_transaction(tx) for tx in journal.transactions)
    return "\n".join(groups)

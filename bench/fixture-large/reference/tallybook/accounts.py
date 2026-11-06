"""The chart of accounts: a tree of colon-separated paths whose root segment decides the account type.

Adding `Assets:Bank:Checking` also makes sure `Assets:Bank` and `Assets` exist (as plain parent accounts), so the
chart is always a complete tree and "children", "descendants" and roll-ups never meet a hole.
"""
import re
from datetime import date, datetime

from .currency import CURRENCIES
from .errors import NotFoundError, ValidationError
from .model import ACCOUNT_TYPES, Account

ROOT_TYPES = {
    "Assets": "asset",
    "Liabilities": "liability",
    "Equity": "equity",
    "Income": "income",
    "Expenses": "expense",
}

_SEGMENT = re.compile(r"[A-Z][A-Za-z0-9_-]*")


class ChartError(ValidationError):
    """A bad account path, type, currency or date, a duplicate account, or a close that makes no sense."""


class DuplicateAccountError(ChartError):
    """Adding an account that is already in the chart; its code is `conflict`."""
    code = "conflict"


def _is_day(value):
    return isinstance(value, date) and not isinstance(value, datetime)


def valid_path(text):
    """True for `Assets`, `Assets:Bank:Checking`: every segment starts with an upper-case letter and continues with
    letters, digits, `_` or `-`, and the first segment is one of the five roots."""
    if not isinstance(text, str):
        return False
    segments = text.split(":")
    return segments[0] in ROOT_TYPES and all(_SEGMENT.fullmatch(s) for s in segments)


def parent_path(path):
    """`Assets:Bank:Checking` -> `Assets:Bank`; a root such as `Assets` has no parent (None)."""
    if not valid_path(path):
        raise ChartError("invalid account path: %r" % (path,))
    head, sep, _ = path.rpartition(":")
    return head if sep else None


def account_type(path):
    """The type an account path gets from its root segment: `Expenses:Food` -> `expense`."""
    if not valid_path(path):
        raise ChartError("invalid account path: %r" % (path,))
    return ROOT_TYPES[path.split(":")[0]]


def path_key(path):
    """Sort key of a path: its segments, so that `Assets:Bank` < `Assets:Bank:Checking` < `Assets:Bank2`."""
    return tuple(path.split(":"))


def _pattern_segments(pattern):
    if not isinstance(pattern, str) or not pattern:
        raise ChartError("invalid account pattern: %r" % (pattern,))
    segments = pattern.split(":")
    for seg in segments:
        if seg not in ("*", "**") and not _SEGMENT.fullmatch(seg):
            raise ChartError("invalid account pattern: %r" % (pattern,))
    return segments


def _match_segments(pattern, segments):
    if not pattern:
        return not segments
    head = pattern[0]
    if head == "**":
        # one or more segments, as many as makes the rest fit
        return any(_match_segments(pattern[1:], segments[take:]) for take in range(1, len(segments) + 1))
    if not segments:
        return False
    if head == "*" or head == segments[0]:
        return _match_segments(pattern[1:], segments[1:])
    return False


def path_matches(pattern, path):
    """Does an account path match an account pattern?

    A pattern without a wildcard is a plain path and matches that account and everything below it. With wildcards
    it is matched segment by segment, exactly: `*` is one segment, `**` is one or more segments.
    """
    segments = _pattern_segments(pattern)
    parts = path.split(":")
    if "*" not in segments and "**" not in segments:
        return parts[:len(segments)] == segments
    return _match_segments(segments, parts)


class Chart:
    def __init__(self):
        self._accounts = {}
        self._implicit = set()   # parents that were never added on their own

    def __contains__(self, path):
        return self.exists(path)

    # building
    def add(self, path, type=None, currency=None, opened=None, note=""):
        if not valid_path(path):
            raise ChartError("invalid account path: %r" % (path,))
        root_type = ROOT_TYPES[path.split(":")[0]]
        if type is not None:
            if type not in ACCOUNT_TYPES:
                raise ChartError("unknown account type: %r" % (type,))
            if type != root_type:
                raise ChartError("account %s is %s, not %s: the type comes from the first segment"
                                 % (path, root_type, type))
        if currency is not None and currency not in CURRENCIES:
            raise ChartError("unknown currency '%s' for account %s" % (currency, path))
        if opened is not None and not _is_day(opened):
            raise ChartError("the opening date of %s must be a date" % path)
        if not isinstance(note, str):
            raise ChartError("the note of %s must be text" % path)
        if path in self._accounts and path not in self._implicit:
            raise DuplicateAccountError("account already exists: %s" % path)
        ancestor = parent_path(path)
        while ancestor is not None:
            if ancestor not in self._accounts:
                self._accounts[ancestor] = Account(ancestor, root_type)
                self._implicit.add(ancestor)
            ancestor = parent_path(ancestor)
        if path in self._implicit:
            self._implicit.discard(path)
            account = self._accounts[path]
            account.currency, account.opened, account.note = currency, opened, note
            return account
        account = Account(path, root_type, currency, opened, None, note)
        self._accounts[path] = account
        return account

    def close(self, path, on):
        """Close an account as of a day. It can still be used on that day, not after it."""
        account = self.get(path)
        if not _is_day(on):
            raise ChartError("the closing date of %s must be a date" % path)
        if account.closed is not None:
            raise ChartError("account %s is already closed (on %s)" % (path, account.closed.isoformat()))
        if account.opened is not None and on < account.opened:
            raise ChartError("account %s cannot be closed on %s, before it opened on %s"
                             % (path, on.isoformat(), account.opened.isoformat()))
        account.closed = on
        return account

    # lookup
    def exists(self, path):
        return isinstance(path, str) and path in self._accounts

    def get(self, path):
        if not self.exists(path):
            raise NotFoundError("no such account: %s" % (path,), account=path)
        return self._accounts[path]

    def is_open(self, path, on):
        """Was the account usable on that day: opened on or before it, and not closed before it."""
        account = self.get(path)
        if account.opened is not None and on < account.opened:
            return False
        return account.closed is None or on <= account.closed

    def accounts(self):
        return [self._accounts[p] for p in sorted(self._accounts, key=path_key)]

    def children(self, path):
        self.get(path)
        return [a for a in self.accounts() if parent_path(a.path) == path]

    def descendants(self, path):
        self.get(path)
        prefix = path + ":"
        return [a for a in self.accounts() if a.path.startswith(prefix)]

    def is_leaf(self, path):
        return not self.children(path)

    def matches(self, pattern):
        """The accounts matching a pattern (see path_matches), sorted by path. A bad pattern is a ChartError."""
        _pattern_segments(pattern)
        return [a for a in self.accounts() if path_matches(pattern, a.path)]

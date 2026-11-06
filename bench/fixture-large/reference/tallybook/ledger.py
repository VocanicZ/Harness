"""The ledger: the validated, balanced list of transactions and the balances computed from it.

Every rule about what a transaction may be lives in `Ledger.add`; the stored transaction is a new object, the
one passed in is never touched. Nothing here reads the clock.
"""
import re
from collections import defaultdict
from datetime import date, datetime

from . import _phase
from .accounts import Chart, parent_path, path_key
from .currency import RateTable
from .errors import LockedPeriodError, NotFoundError, ValidationError
from .model import Posting, Transaction
from .money import Money, format_minor

_TAG = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")


class LedgerError(ValidationError):
    """A transaction that breaks a rule: it does not balance, names a bad account, and so on."""


def _is_day(value):
    return isinstance(value, date) and not isinstance(value, datetime)


def _one_line(value):
    return isinstance(value, str) and "\n" not in value and "\r" not in value


def _sorted_totals(totals):
    """{account: {currency: minor}} without zero entries, accounts in path order, currencies alphabetical."""
    result = {}
    for account in sorted(totals, key=path_key):
        per_currency = {c: totals[account][c] for c in sorted(totals[account]) if totals[account][c] != 0}
        if per_currency:
            result[account] = per_currency
    return result


class Ledger:
    def __init__(self, chart=None, rates=None):
        self.chart = chart if chart is not None else Chart()
        self.rates = rates if rates is not None else RateTable()
        self._txs = {}
        self._next_id = 1
        if not _phase.PRE:
            self.lock_date = None

    def __len__(self):
        return len(self._txs)

    # locking (a book without a lock date has no lock; before the period lock existed there was no attribute)
    def _check_lock(self, day, action):
        lock = getattr(self, "lock_date", None)
        if lock is not None and day <= lock:
            raise LockedPeriodError("the books are locked up to %s: cannot %s a transaction dated %s"
                                    % (lock.isoformat(), action, day.isoformat()), lock_date=lock)

    # adding
    def add(self, tx):
        """Validate a transaction, give it an id and keep it. Returns the stored transaction (a new object)."""
        if not _is_day(tx.date):
            raise LedgerError("the transaction date must be a date")
        self._check_lock(tx.date, "add")
        if tx.flag not in ("*", "!"):
            raise LedgerError("the flag must be * or !, got %r" % (tx.flag,))
        if not _one_line(tx.payee) or not _one_line(tx.narration):
            raise LedgerError("the payee and the narration must be single-line text")
        tags = self._clean_tags(tx.tags)
        tx_id = self._clean_id(tx.id)
        postings = self._balanced_postings(tx)
        stored = Transaction(tx.date, tx.payee, tx.narration, postings, tags, tx.flag, tx_id)
        self._txs[tx_id] = stored
        self._next_id = max(self._next_id, tx_id + 1)
        return stored

    def add_many(self, transactions):
        """Add several transactions in order, all or nothing: if one is refused nothing of the batch stays."""
        saved = (dict(self._txs), self._next_id)
        stored = []
        try:
            for tx in transactions:
                stored.append(self.add(tx))
        except Exception:
            self._txs, self._next_id = saved
            raise
        return stored

    def replace(self, tx_id, tx):
        """Swap a stored transaction for a new version that keeps the same id. All or nothing; the period lock
        is checked for the old date and for the new one."""
        old = self.get(tx_id)
        if tx.id is not None and tx.id != tx_id:
            raise LedgerError("a replacement keeps the id %d, not %r" % (tx_id, tx.id))
        self._check_lock(old.date, "replace")
        saved = (dict(self._txs), self._next_id)
        del self._txs[tx_id]
        try:
            return self.add(Transaction(tx.date, tx.payee, tx.narration, tx.postings, tx.tags, tx.flag, tx_id))
        except Exception:
            self._txs, self._next_id = saved
            raise

    def _clean_tags(self, tags):
        if isinstance(tags, str) or tags is None:
            raise LedgerError("tags must be a sequence of text")
        for tag in tags:
            if not isinstance(tag, str) or not _TAG.fullmatch(tag):
                raise LedgerError("invalid tag: %r" % (tag,))
        return tuple(sorted(set(tags)))

    def _clean_id(self, tx_id):
        if tx_id is None:
            return self._next_id
        if isinstance(tx_id, bool) or not isinstance(tx_id, int) or tx_id < 1:
            raise LedgerError("invalid transaction id: %r" % (tx_id,))
        if tx_id in self._txs:
            raise LedgerError("transaction id %d already exists" % tx_id)
        return tx_id

    def _balanced_postings(self, tx):
        if len(tx.postings) < 2:
            raise LedgerError("a transaction needs at least two postings")
        for index, posting in enumerate(tx.postings, 1):
            self._check_posting(tx.date, index, posting)
        blank = [p for p in tx.postings if p.amount is None]
        if len(blank) > 1:
            raise LedgerError("more than one posting without an amount: only one can be worked out")

        sums = defaultdict(int)
        for posting in tx.postings:
            if posting.amount is not None:
                sums[posting.amount.currency] += posting.amount.minor
        off = sorted(c for c in sums if sums[c] != 0)

        postings = []
        if blank:
            if not off:
                raise LedgerError("nothing to infer: the other postings already balance")
            for posting in tx.postings:
                if posting.amount is not None:
                    postings.append(posting)
                else:
                    for code in off:
                        postings.append(Posting(posting.account, Money(-sums[code], code), posting.note))
        else:
            if off:
                detail = ", ".join("%s %s" % (c, format_minor(sums[c], c)) for c in off)
                raise LedgerError("transaction does not balance: %s" % detail)
            postings = list(tx.postings)

        for posting in postings:
            held = self.chart.get(posting.account).currency
            if held is not None and posting.amount.currency != held:
                raise LedgerError("account %s only holds %s, not %s"
                                  % (posting.account, held, posting.amount.currency))
        return postings

    def _check_posting(self, day, index, posting):
        if not self.chart.exists(posting.account):
            raise LedgerError("unknown account: %s" % (posting.account,))
        if not self.chart.is_open(posting.account, day):
            raise LedgerError("account %s is not open on %s" % (posting.account, day.isoformat()))
        if posting.amount is not None and not isinstance(posting.amount, Money):
            raise LedgerError("posting %d: the amount must be a Money or None" % index)
        if not _one_line(posting.note):
            raise LedgerError("posting %d: the note must be single-line text" % index)

    # removing and looking up
    def remove(self, tx_id):
        """Delete a transaction and return it. Its id is not handed out again."""
        tx = self.get(tx_id)
        self._check_lock(tx.date, "delete")
        del self._txs[tx_id]
        return tx

    def get(self, tx_id):
        if isinstance(tx_id, bool) or tx_id not in self._txs:
            raise NotFoundError("no transaction with id %s" % (tx_id,), id=tx_id)
        return self._txs[tx_id]

    def transactions(self):
        """All transactions, oldest first; the same day by id."""
        return sorted(self._txs.values(), key=lambda t: (t.date, t.id))

    def postings(self):
        """Every (transaction, posting) pair in transactions() order, a transaction's postings in their order."""
        for tx in self.transactions():
            for posting in tx.postings:
                yield tx, posting

    # balances
    def _own_totals(self, as_of):
        totals = defaultdict(lambda: defaultdict(int))
        for tx, posting in self.postings():
            if as_of is None or tx.date <= as_of:
                totals[posting.account][posting.amount.currency] += posting.amount.minor
        return totals

    def balances(self, as_of=None):
        """{account: {currency: minor}} of what was posted to each account itself (no roll-up), up to and including
        `as_of`. Zero balances are left out."""
        return _sorted_totals(self._own_totals(as_of))

    def rollup_balances(self, as_of=None):
        """Like balances(), but every account also counts everything posted below it, so parents appear too."""
        rolled = defaultdict(lambda: defaultdict(int))
        for account, per_currency in self._own_totals(as_of).items():
            path = account
            while path is not None:
                for code, minor in per_currency.items():
                    rolled[path][code] += minor
                path = parent_path(path)
        return _sorted_totals(rolled)

    def balance(self, account, as_of=None, currency=None, rollup=True):
        """The balance of one account: a Money if `currency` is given, else {currency: Money} (zeros left out)."""
        self.chart.get(account)
        prefix = account + ":"
        totals = defaultdict(int)
        for tx, posting in self.postings():
            if as_of is not None and tx.date > as_of:
                continue
            if posting.account == account or (rollup and posting.account.startswith(prefix)):
                totals[posting.amount.currency] += posting.amount.minor
        if currency is not None:
            return Money(totals.get(currency, 0), currency)
        return {c: Money(totals[c], c) for c in sorted(totals) if totals[c] != 0}

"""Store: a tallybook book kept in one SQLite file. Every write is validated by the same Chart and Ledger the library
uses in memory, and is all-or-nothing."""
import json
import re
from dataclasses import dataclass, replace
from datetime import date

from .. import _phase
from ..accounts import Chart
from ..budgets import Budget
from ..csvimport import import_csv as _import_csv, parse_profile
from ..currency import RateTable
from ..errors import ConflictError, LockedPeriodError, NotFoundError, TallybookError, ValidationError
from ..ledger import Ledger
from ..model import ACCOUNT_TYPES, Account, Posting, Transaction
from ..money import Money
from ..query import Query, parse_query, select
from ..recurring import Recurring, instantiate, occurrences
from ..rules import parse_rules
from . import migrations
from .db import Database
from .migrations import LATEST_VERSION

LOCK_KEY = "lock_date"
PROFILE_PREFIX = "profile."
_PROFILE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
_TAG = re.compile(r"[^\s,]+")
_CHUNK = 500


@dataclass
class BulkAdd:
    """Result of `Store.add_transactions`: the stored transactions, and the positions (in the input) skipped because
    their import key was already recorded."""
    added: list
    skipped: list


@dataclass
class ImportOutcome:
    """Result of `Store.import_csv`: stored transactions, rows left out as duplicates, and row errors. When there are
    errors nothing was stored."""
    added: list
    duplicates: list
    errors: list


def _day(text):
    return date.fromisoformat(text) if text else None


def _iso(value):
    return value.isoformat() if value is not None else None


def _check_date(value, what):
    if not isinstance(value, date) or hasattr(value, "hour"):
        raise ValidationError("%s must be a date, got %r" % (what, value))
    return value


def _page(limit, offset):
    for name, value in (("limit", limit), ("offset", offset)):
        if value is None and name == "limit":
            continue
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValidationError("%s must be a whole number of at least 0, got %r" % (name, value))
    return limit, offset


def _clean_tags(tags):
    out = set()
    for tag in tags or ():
        if not isinstance(tag, str) or not _TAG.fullmatch(tag):
            raise ValidationError("invalid tag %r: tags are non-empty text without blanks or commas" % (tag,))
        out.add(tag)
    return tuple(sorted(out))


def _template_to_json(tx):
    return json.dumps({
        "payee": tx.payee, "narration": tx.narration, "flag": tx.flag, "tags": list(tx.tags),
        "postings": [{"account": p.account, "note": p.note,
                      "minor": None if p.amount is None else p.amount.minor,
                      "currency": None if p.amount is None else p.amount.currency} for p in tx.postings],
    }, sort_keys=True, ensure_ascii=False)


def _template_from_json(text, start):
    data = json.loads(text)
    postings = [Posting(p["account"], None if p["minor"] is None else Money(p["minor"], p["currency"]), p["note"])
                for p in data["postings"]]
    return Transaction(date=start, payee=data["payee"], narration=data["narration"], postings=postings,
                       tags=tuple(data["tags"]), flag=data["flag"])


def _import_key(tx, seen):
    """date|payee|first account|first amount|ordinal: the nth identical row of one file gets ordinal n."""
    first = tx.postings[0]
    base = "%s|%s|%s|%d %s" % (tx.date.isoformat(), tx.payee, first.account, first.amount.minor, first.amount.currency)
    seen[base] = seen.get(base, 0) + 1
    return "%s|%d" % (base, seen[base])


class Store:
    """Open with `Store.open(path, create=False)`. A book older than LATEST_VERSION opens but refuses every operation
    except `version`, `migrate` and `close` until `migrate()` has run."""

    def __init__(self, db):
        self.db = db
        self.path = db.path
        self._version = db.user_version()

    @classmethod
    def open(cls, path, create=False):
        db = Database.open(path, create, LATEST_VERSION)
        store = cls(db)
        if create and store._version == 0:
            try:
                store.migrate()
            except BaseException:
                db.close()
                raise
        return store

    # -- lifecycle and schema ------------------------------------------------------------------------------------

    @property
    def version(self):
        return self._version

    def migrate(self):
        self._open_check()
        try:
            return migrations.migrate(self.db)
        finally:
            self._version = self.db.user_version()

    def close(self):
        self.db.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def _open_check(self):
        if not self.db.is_open:
            raise ConflictError("the store is closed")

    def _ready(self):
        self._open_check()
        self._version = self.db.user_version()
        if self._version < LATEST_VERSION:
            raise ConflictError("database is at version %d, run `tallybook db migrate`" % self._version)

    def info(self):
        """Counts for a status display."""
        self._ready()
        counts = {name: self.db.scalar("SELECT count(*) FROM " + table) for name, table in (
            ("accounts", "accounts"), ("transactions", "transactions"), ("postings", "postings"),
            ("rates", "rates"), ("budgets", "budgets"), ("recurring", "recurring"))}
        counts.update(path=self.path, version=self._version)
        return counts

    def check(self):
        """Look for damage the store itself never causes (a hand-edited file, an interrupted copy). Returns a sorted
        list of problem descriptions; an empty list means the book is sound."""
        self._ready()
        problems = []
        for line in (r[0] for r in self.db.all("PRAGMA integrity_check")):
            if line != "ok":
                problems.append("file integrity: %s" % line)
        queries = (
            ("SELECT id FROM postings WHERE tx_id NOT IN (SELECT id FROM transactions)",
             "posting %d belongs to a missing transaction"),
            ("SELECT DISTINCT tx_id FROM tags WHERE tx_id NOT IN (SELECT id FROM transactions)",
             "tags of missing transaction %d"),
            ("SELECT DISTINCT tx_id FROM import_keys WHERE tx_id NOT IN (SELECT id FROM transactions)",
             "import keys of missing transaction %d"),
            ("SELECT id FROM transactions WHERE id NOT IN (SELECT tx_id FROM postings)",
             "transaction %d has no postings"),
        )
        for sql, text in queries:
            problems += [text % r[0] for r in self.db.all(sql)]
        for r in self.db.all("SELECT DISTINCT account FROM postings WHERE account NOT IN (SELECT path FROM accounts)"):
            problems.append("postings use the unknown account %s" % r[0])
        for r in self.db.all("SELECT tx_id, currency, sum(minor) AS total FROM postings GROUP BY tx_id, currency "
                             "HAVING total != 0"):
            problems.append("transaction %d does not balance in %s (off by %d)" % (r[0], r[1], r[2]))
        return sorted(problems)

    def backup(self, dest):
        """Copy the whole book to a new file `dest` (it must not exist) while the book stays open."""
        self._ready()
        import os
        import sqlite3
        dest = os.fspath(dest)
        if os.path.exists(dest):
            raise ConflictError("%s already exists" % dest)
        if not os.path.isdir(os.path.dirname(os.path.abspath(dest))):
            raise NotFoundError("no such directory: %s" % os.path.dirname(os.path.abspath(dest)))
        target = sqlite3.connect(dest)
        try:
            self.db.conn.backup(target)
        finally:
            target.close()

    # -- accounts ------------------------------------------------------------------------------------------------

    @staticmethod
    def _account(row):
        return Account(row["path"], row["type"], row["currency"], _day(row["opened"]), _day(row["closed"]), row["note"])

    def chart(self):
        """A fresh Chart holding the stored accounts (closed ones closed)."""
        self._ready()
        chart = Chart()
        for row in self.db.all("SELECT * FROM accounts ORDER BY path"):
            chart.add(row["path"], row["type"], row["currency"], _day(row["opened"]), row["note"])
            if row["closed"]:
                chart.close(row["path"], _day(row["closed"]))
        return chart

    def add_account(self, path, type=None, currency=None, opened=None, note=""):
        self._ready()
        with self.db.transaction():
            account = self.chart().add(path, type=type, currency=currency, opened=opened, note=note)
            self.db.execute("INSERT INTO accounts (path, type, currency, opened, note) VALUES (?, ?, ?, ?, ?)",
                            (path, account.type, currency, _iso(opened), note))
        return self.get_account(path)

    def get_account(self, path):
        self._ready()
        row = self.db.one("SELECT * FROM accounts WHERE path = ?", (path,))
        if row is None:
            raise NotFoundError("no such account: %s" % (path,), account=path)
        return self._account(row)

    def _account_filter(self, type, under, currency, include_closed):
        where, params = [], []
        if type is not None:
            if type not in ACCOUNT_TYPES:
                raise ValidationError("unknown account type: %r" % (type,))
            where.append("type = ?")
            params.append(type)
        if under is not None:
            where.append("(path = ? OR substr(path, 1, ?) = ?)")
            params += [under, len(under) + 1, under + ":"]
        if currency is not None:
            where.append("currency = ?")
            params.append(currency)
        if not include_closed:
            where.append("closed IS NULL")
        return (" WHERE " + " AND ".join(where)) if where else "", params

    def accounts(self, type=None, under=None, currency=None, include_closed=True):
        """Stored accounts sorted by path; `under` keeps that account and its descendants. Parents that exist only
        because a child was added are not listed (use `chart()` to see them)."""
        self._ready()
        where, params = self._account_filter(type, under, currency, include_closed)
        return [self._account(r) for r in self.db.all("SELECT * FROM accounts%s ORDER BY path" % where, params)]

    def count_accounts(self, type=None, under=None, currency=None, include_closed=True):
        self._ready()
        where, params = self._account_filter(type, under, currency, include_closed)
        return self.db.scalar("SELECT count(*) FROM accounts" + where, params)

    def close_account(self, path, on):
        """Close an account as of `on` (it stays usable on that day). Postings after `on` make that a ConflictError."""
        self._ready()
        with self.db.transaction():
            self.get_account(path)
            self.chart().close(path, on)
            latest = self.db.scalar("SELECT max(t.date) FROM postings p JOIN transactions t ON t.id = p.tx_id "
                                    "WHERE p.account = ?", (path,))
            if latest is not None and latest > on.isoformat():
                raise ConflictError("cannot close %s on %s: it has a posting on %s" % (path, on.isoformat(), latest))
            self.db.execute("UPDATE accounts SET closed = ? WHERE path = ?", (on.isoformat(), path))
        return self.get_account(path)

    def set_account_note(self, path, note):
        self._ready()
        if not isinstance(note, str):
            raise ValidationError("the note of %s must be text" % path)
        self.get_account(path)
        self.db.execute("UPDATE accounts SET note = ? WHERE path = ?", (note, path))
        return self.get_account(path)

    def delete_account(self, path):
        """Remove an account nothing has posted to."""
        self._ready()
        with self.db.transaction():
            self.get_account(path)
            if self.db.scalar("SELECT count(*) FROM postings WHERE account = ?", (path,)):
                raise ConflictError("cannot delete %s: transactions use it" % path)
            self.db.execute("DELETE FROM accounts WHERE path = ?", (path,))

    # -- transactions --------------------------------------------------------------------------------------------

    def _load(self, rows):
        """Transactions for `transaction` rows, in the order given, with postings and tags."""
        ids = [r["id"] for r in rows]
        postings, tags = {}, {}
        for at in range(0, len(ids), _CHUNK):
            marks = ",".join("?" * len(ids[at:at + _CHUNK]))
            for p in self.db.all("SELECT * FROM postings WHERE tx_id IN (%s) ORDER BY tx_id, seq" % marks,
                                 ids[at:at + _CHUNK]):
                postings.setdefault(p["tx_id"], []).append(Posting(p["account"], Money(p["minor"], p["currency"]), p["note"]))
            for t in self.db.all("SELECT tx_id, tag FROM tags WHERE tx_id IN (%s)" % marks, ids[at:at + _CHUNK]):
                tags.setdefault(t["tx_id"], []).append(t["tag"])
        return [Transaction(date=_day(r["date"]), payee=r["payee"], narration=r["narration"],
                            postings=postings.get(r["id"], []), tags=tuple(sorted(tags.get(r["id"], ()))),
                            flag=r["flag"], id=r["id"]) for r in rows]

    def _query(self, query):
        if isinstance(query, Query):
            return query
        if not isinstance(query, str):
            raise ValidationError("a query is text or a Query, got %r" % (query,))
        return parse_query(query, chart=self.chart())

    def get_transaction(self, tx_id):
        self._ready()
        row = self.db.one("SELECT * FROM transactions WHERE id = ?", (tx_id,))
        if row is None:
            raise NotFoundError("no such transaction: %s" % (tx_id,), id=tx_id)
        return self._load([row])[0]

    def transactions(self, query=None, limit=None, offset=0):
        """Transactions ordered by (date, id), optionally filtered by a query (text or Query), then paged."""
        self._ready()
        limit, offset = _page(limit, offset)
        if query is None or (isinstance(query, str) and not query.strip()):
            sql, params = "SELECT * FROM transactions ORDER BY date, id", []
            if limit is not None or offset:
                sql += " LIMIT ? OFFSET ?"
                params = [-1 if limit is None else limit, offset]
            return self._load(self.db.all(sql, params))
        parsed = self._query(query)
        found = select(self._load(self.db.all("SELECT * FROM transactions ORDER BY date, id")), parsed)
        return found[offset:None if limit is None else offset + limit]

    def count_transactions(self, query=None):
        self._ready()
        if query is None or (isinstance(query, str) and not query.strip()):
            return self.db.scalar("SELECT count(*) FROM transactions")
        return len(self.transactions(query))

    def _lock(self):
        return None

    def _check_lock(self, day, what):
        lock = self._lock()
        if lock is not None and day <= lock:
            raise LockedPeriodError("the books are locked up to %s: cannot %s a transaction dated %s"
                                    % (lock.isoformat(), what, day.isoformat()), lock_date=lock.isoformat())

    def _validator(self):
        """An empty Ledger over the stored chart and rates: it applies the library's rules to one new transaction."""
        return Ledger(self.chart(), self.rate_table())

    def _insert(self, ledger, tx, what="add"):
        if not isinstance(tx, Transaction):
            raise ValidationError("expected a Transaction, got %r" % (tx,))
        _check_date(tx.date, "the date of a transaction")
        self._check_lock(tx.date, what)
        if tx.flag not in ("*", "!"):
            raise ValidationError("invalid flag %r: expected '*' or '!'" % (tx.flag,))
        tags = _clean_tags(tx.tags)
        checked = ledger.add(Transaction(date=tx.date, payee=tx.payee, narration=tx.narration,
                                         postings=list(tx.postings), tags=tags, flag=tx.flag, id=None))
        cur = self.db.execute("INSERT INTO transactions (date, payee, narration, flag, cleared) VALUES (?, ?, ?, ?, ?)",
                              (tx.date.isoformat(), checked.payee, checked.narration, checked.flag,
                               1 if checked.flag == "*" else 0))
        new_id = cur.lastrowid
        for seq, p in enumerate(checked.postings):
            self.db.execute("INSERT INTO postings (tx_id, seq, account, minor, currency, note) VALUES (?, ?, ?, ?, ?, ?)",
                            (new_id, seq, p.account, p.amount.minor, p.amount.currency, p.note))
        for tag in tags:
            self.db.execute("INSERT INTO tags (tx_id, tag) VALUES (?, ?)", (new_id, tag))
        return replace(checked, id=new_id, tags=tags)

    def add_transaction(self, tx):
        """Validate through a Ledger (balance, accounts, currencies, the lock), store, and return it with its id.
        Any id on `tx` is ignored; ids are 1, 2, 3, ... and never reused."""
        self._ready()
        with self.db.transaction():
            return self._insert(self._validator(), tx)

    def add_transactions(self, txs, keys=None):
        """Add many in one all-or-nothing step. `keys` (one text per transaction) are import keys: a transaction whose
        key is already recorded is skipped, and the key is recorded with the stored transaction."""
        self._ready()
        txs = list(txs)
        if keys is not None:
            keys = list(keys)
            if len(keys) != len(txs):
                raise ValidationError("%d keys for %d transactions" % (len(keys), len(txs)))
        added, skipped = [], []
        with self.db.transaction():
            ledger = self._validator()
            for at, tx in enumerate(txs):
                key = keys[at] if keys is not None else None
                if key is not None and self.has_import_key(key):
                    skipped.append(at)
                    continue
                try:
                    stored = self._insert(ledger, tx, "import" if keys is not None else "add")
                except TallybookError as exc:
                    exc.detail.setdefault("index", at)
                    raise
                if key is not None:
                    self.db.execute("INSERT INTO import_keys (key, tx_id) VALUES (?, ?)", (key, stored.id))
                added.append(stored)
        return BulkAdd(added, skipped)

    def delete_transaction(self, tx_id):
        """Remove a transaction with its postings, tags and import key; returns what was removed."""
        self._ready()
        with self.db.transaction():
            tx = self.get_transaction(tx_id)
            self._check_lock(tx.date, "delete")
            for table, column in (("import_keys", "tx_id"), ("tags", "tx_id"), ("postings", "tx_id"),
                                  ("transactions", "id")):
                self.db.execute("DELETE FROM %s WHERE %s = ?" % (table, column), (tx_id,))
        return tx

    def has_import_key(self, key):
        self._ready()
        return self.db.one("SELECT 1 FROM import_keys WHERE key = ?", (key,)) is not None

    def ledger(self):
        """A Ledger holding the chart, the rates and every stored transaction (ids kept), with the lock date set."""
        self._ready()
        ledger = Ledger(self.chart(), self.rate_table())
        for tx in self.transactions():
            ledger.add(tx)
        if not _phase.PRE:
            ledger.lock_date = self._lock()
        return ledger

    # -- rates ---------------------------------------------------------------------------------------------------

    def set_rate(self, src, dst, rate_text, on):
        """Record (or replace, for the same pair and day) a rate; validated by RateTable.set."""
        self._ready()
        RateTable().set(src, dst, rate_text, on)
        self.db.execute("INSERT OR REPLACE INTO rates (src, dst, on_date, rate_text) VALUES (?, ?, ?, ?)",
                        (src, dst, on.isoformat(), rate_text))

    def remove_rate(self, src, dst, on):
        self._ready()
        _check_date(on, "the date of a rate")
        cur = self.db.execute("DELETE FROM rates WHERE src = ? AND dst = ? AND on_date = ?", (src, dst, on.isoformat()))
        if cur.rowcount == 0:
            raise NotFoundError("no rate %s -> %s set on %s" % (src, dst, on.isoformat()))

    def rate_rows(self):
        """(src, dst, date, rate_text) for every stored rate, sorted, the text as it was set."""
        self._ready()
        return [(r["src"], r["dst"], _day(r["on_date"]), r["rate_text"])
                for r in self.db.all("SELECT * FROM rates ORDER BY src, dst, on_date")]

    def rate_table(self):
        self._ready()
        table = RateTable()
        for src, dst, on, text in self.rate_rows():
            table.set(src, dst, text, on)
        return table

    # -- budgets -------------------------------------------------------------------------------------------------

    def add_budget(self, budget):
        """One budget per (pattern, period_kind); adding the pair again is a ConflictError."""
        self._ready()
        if not isinstance(budget, Budget):
            raise ValidationError("expected a Budget, got %r" % (budget,))
        if self.db.one("SELECT 1 FROM budgets WHERE pattern = ? AND period_kind = ?",
                       (budget.pattern, budget.period_kind)):
            raise ConflictError("there is already a %s budget for %s" % (budget.period_kind, budget.pattern))
        self.db.execute("INSERT INTO budgets (pattern, period_kind, minor, currency, start_date) VALUES (?, ?, ?, ?, ?)",
                        (budget.pattern, budget.period_kind, budget.amount.minor, budget.amount.currency,
                         budget.start.isoformat()))
        return budget

    def remove_budget(self, pattern, period_kind):
        self._ready()
        cur = self.db.execute("DELETE FROM budgets WHERE pattern = ? AND period_kind = ?", (pattern, period_kind))
        if cur.rowcount == 0:
            raise NotFoundError("no %s budget for %s" % (period_kind, pattern))

    def budgets(self):
        """All budgets sorted by (pattern, period_kind)."""
        self._ready()
        return [Budget(r["pattern"], r["period_kind"], Money(r["minor"], r["currency"]), _day(r["start_date"]))
                for r in self.db.all("SELECT * FROM budgets ORDER BY pattern, period_kind")]

    # -- recurring -----------------------------------------------------------------------------------------------

    def add_recurring(self, rec):
        """Store a Recurring (schedule kept as its canonical text, template as JSON). Names are unique."""
        self._ready()
        if not isinstance(rec, Recurring):
            raise ValidationError("expected a Recurring, got %r" % (rec,))
        if self.db.one("SELECT 1 FROM recurring WHERE name = ?", (rec.name,)):
            raise ConflictError("there is already a recurring item named %s" % rec.name)
        self.db.execute("INSERT INTO recurring (name, schedule, template, start_date, end_date, max_count) "
                        "VALUES (?, ?, ?, ?, ?, ?)",
                        (rec.name, str(rec.schedule), _template_to_json(rec.template), rec.start.isoformat(),
                         _iso(rec.end), rec.count))
        return rec

    def remove_recurring(self, name):
        """Remove the series; transactions it already produced stay."""
        self._ready()
        cur = self.db.execute("DELETE FROM recurring WHERE name = ?", (name,))
        if cur.rowcount == 0:
            raise NotFoundError("no recurring item named %s" % (name,))

    @staticmethod
    def _recurring(row):
        start = _day(row["start_date"])
        return Recurring(row["name"], row["schedule"], _template_from_json(row["template"], start), start,
                         _day(row["end_date"]), row["max_count"])

    def recurring(self):
        """All series sorted by name."""
        self._ready()
        return [self._recurring(r) for r in self.db.all("SELECT * FROM recurring ORDER BY name")]

    def materialized_through(self, name):
        """The last day `materialize` covered for the series (None when never)."""
        self._ready()
        row = self.db.one("SELECT materialized_through FROM recurring WHERE name = ?", (name,))
        if row is None:
            raise NotFoundError("no recurring item named %s" % (name,))
        return _day(row["materialized_through"])

    def materialize(self, upto=None, today=None):
        """Turn the occurrences of every series up to `upto` (default `today`; with both, the earlier) into stored
        transactions, skipping days already covered, and return them ordered by (date, name). All or nothing."""
        self._ready()
        horizon = [d for d in (upto, today) if d is not None]
        if not horizon:
            raise ValidationError("materialize needs upto or today")
        for d in horizon:
            _check_date(d, "the materialize date")
        horizon = min(horizon)
        made = []
        with self.db.transaction():
            ledger = self._validator()
            due = []
            for row in self.db.all("SELECT * FROM recurring ORDER BY name"):
                rec = self._recurring(row)
                done = _day(row["materialized_through"])
                for day in occurrences(rec, rec.start, horizon):
                    if done is None or day > done:
                        due.append((day, rec.name, rec))
                if done is None or horizon > done:
                    self.db.execute("UPDATE recurring SET materialized_through = ? WHERE name = ?",
                                    (horizon.isoformat(), rec.name))
            due.sort(key=lambda item: item[:2])
            for day, _, rec in due:
                made.append(self._insert(ledger, instantiate(rec, day), "materialize"))
        return made

    # -- rules, settings, profiles ---------------------------------------------------------------------------------

    def set_rules(self, text):
        """Replace the categorisation rules (validated by parse_rules). The text is stored exactly as given."""
        self._ready()
        if not isinstance(text, str):
            raise ValidationError("rules are text")
        parse_rules(text)
        self.db.execute("INSERT OR REPLACE INTO rules (id, body) VALUES (1, ?)", (text,))

    def rules_text(self):
        self._ready()
        row = self.db.one("SELECT body FROM rules WHERE id = 1")
        return row["body"] if row else ""

    def rules(self):
        return parse_rules(self.rules_text())

    def get_setting(self, key, default=None):
        self._ready()
        row = self.db.one("SELECT value FROM settings WHERE key = ?", (key,))
        return row["value"] if row else default

    def set_setting(self, key, value):
        self._ready()
        if not isinstance(key, str) or not key or not isinstance(value, str):
            raise ValidationError("a setting is a non-empty text key and a text value")
        self.db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (key, value))

    def delete_setting(self, key):
        self._ready()
        self.db.execute("DELETE FROM settings WHERE key = ?", (key,))

    def settings(self):
        self._ready()
        return {r["key"]: r["value"] for r in self.db.all("SELECT key, value FROM settings ORDER BY key")}

    if not _phase.PRE:
        def _lock(self):
            text = self.get_setting(LOCK_KEY)
            if text is None:
                return None
            try:
                return date.fromisoformat(text)
            except ValueError:
                raise ConflictError("the setting %s holds %r, which is not a date" % (LOCK_KEY, text))

        def lock_date(self):
            return self._lock()

        def set_lock(self, day):
            """Lock the books through `day` (a date), or unlock with None."""
            self._ready()
            if day is None:
                self.delete_setting(LOCK_KEY)
                return
            _check_date(day, "the lock date")
            self.set_setting(LOCK_KEY, day.isoformat())

    def set_profile(self, name, text):
        """Keep an import profile under a name for `import_csv`; validated by parse_profile."""
        if not isinstance(name, str) or not _PROFILE_NAME.fullmatch(name):
            raise ValidationError("invalid profile name %r" % (name,))
        parse_profile(text)
        self.set_setting(PROFILE_PREFIX + name, text)

    def profile_text(self, name):
        text = self.get_setting(PROFILE_PREFIX + name) if isinstance(name, str) else None
        if text is None:
            raise NotFoundError("no import profile named %s" % (name,))
        return text

    def profiles(self):
        return sorted(k[len(PROFILE_PREFIX):] for k in self.settings() if k.startswith(PROFILE_PREFIX))

    def remove_profile(self, name):
        self.profile_text(name)
        self.delete_setting(PROFILE_PREFIX + name)

    # -- import and journal ----------------------------------------------------------------------------------------

    def import_csv(self, text, profile, apply_rules=True):
        """Import bank CSV. `profile` is a stored profile name, profile text, or an ImportProfile. Rows already in the
        book (csvimport's own test) or whose import key is recorded are duplicates. Row errors store nothing."""
        self._ready()
        if isinstance(profile, str):
            name_like = _PROFILE_NAME.fullmatch(profile) is not None
            profile = parse_profile(self.profile_text(profile) if name_like else profile)
        result = _import_csv(text, profile, rules=self.rules() if apply_rules else None,
                             existing=self.transactions())
        if result.errors:
            return ImportOutcome([], list(result.duplicates), list(result.errors))
        seen = {}
        keys = [_import_key(tx, seen) for tx in result.transactions]
        bulk = self.add_transactions(result.transactions, keys)
        repeats = [result.transactions[i] for i in bulk.skipped]
        return ImportOutcome(bulk.added, list(result.duplicates) + repeats, [])

    def journal(self):
        """The whole book as a Journal (accounts, rates, transactions)."""
        self._ready()
        from ..journal import Journal
        return Journal(accounts=self.accounts(), rates=self.rate_rows(), transactions=self.transactions())

    def load_journal(self, journal):
        """Add a Journal's accounts, rates and transactions; all or nothing. Existing accounts are a ConflictError."""
        self._ready()
        with self.db.transaction():
            for account in journal.accounts:
                self.add_account(account.path, account.type, account.currency, account.opened, account.note)
                if account.closed is not None:
                    self.close_account(account.path, account.closed)
            for src, dst, on, text in journal.rates:
                self.set_rate(src, dst, text, on)
            added = self.add_transactions(journal.transactions).added
        return added

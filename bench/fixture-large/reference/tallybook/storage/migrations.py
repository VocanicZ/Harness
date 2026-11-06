"""The schema history. Each step moves a book file from version N-1 to N inside one transaction, together with the
`PRAGMA user_version` marker, so a failing step leaves the file exactly at N-1. There are no down-migrations."""
import re
import sqlite3

from ..errors import ConflictError, TallybookError

LATEST_VERSION = 4


class MigrationError(ConflictError):
    """A step could not be applied; the file is left at the previous version."""


_V1 = [
    """CREATE TABLE accounts (
        path     TEXT PRIMARY KEY,
        type     TEXT NOT NULL,
        currency TEXT,
        opened   TEXT,
        note     TEXT NOT NULL DEFAULT ''
    )""",
    """CREATE TABLE transactions (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        date      TEXT NOT NULL,
        payee     TEXT NOT NULL,
        narration TEXT NOT NULL DEFAULT '',
        cleared   INTEGER NOT NULL DEFAULT 1
    )""",
    """CREATE TABLE postings (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        tx_id    INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
        seq      INTEGER NOT NULL,
        account  TEXT NOT NULL REFERENCES accounts(path),
        minor    INTEGER NOT NULL,
        currency TEXT NOT NULL
    )""",
    "CREATE INDEX transactions_by_date ON transactions(date, id)",
    "CREATE INDEX postings_by_tx ON postings(tx_id, seq)",
]

_V2 = [
    """CREATE TABLE tags (
        tx_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
        tag   TEXT NOT NULL,
        PRIMARY KEY (tx_id, tag)
    )""",
    "ALTER TABLE transactions ADD COLUMN flag TEXT NOT NULL DEFAULT '*'",
    "ALTER TABLE postings ADD COLUMN note TEXT NOT NULL DEFAULT ''",
]

_V3 = [
    """CREATE TABLE rates (
        src       TEXT NOT NULL,
        dst       TEXT NOT NULL,
        on_date   TEXT NOT NULL,
        rate_text TEXT NOT NULL,
        PRIMARY KEY (src, dst, on_date)
    )""",
    "ALTER TABLE accounts ADD COLUMN closed TEXT",
]

_V4 = [
    """CREATE TABLE budgets (
        pattern     TEXT NOT NULL,
        period_kind TEXT NOT NULL,
        minor       INTEGER NOT NULL,
        currency    TEXT NOT NULL,
        start_date  TEXT NOT NULL,
        PRIMARY KEY (pattern, period_kind)
    )""",
    """CREATE TABLE recurring (
        name                 TEXT PRIMARY KEY,
        schedule             TEXT NOT NULL,
        template             TEXT NOT NULL,
        start_date           TEXT NOT NULL,
        end_date             TEXT,
        max_count            INTEGER,
        materialized_through TEXT
    )""",
    """CREATE TABLE rules (
        id   INTEGER PRIMARY KEY CHECK (id = 1),
        body TEXT NOT NULL
    )""",
    """CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )""",
    """CREATE TABLE import_keys (
        key   TEXT PRIMARY KEY,
        tx_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE
    )""",
]

_CODE = re.compile(r"^[A-Z]{3}$")


def _run(db, statements):
    for sql in statements:
        db.execute(sql)


def _step_1(db):
    _run(db, _V1)


def _step_2(db):
    """Adds tags, transactions.flag and postings.note. The legacy cleared column (1 or 0) becomes the flag: 1 -> '*',
    0 -> '!'. Any other cleared value stops the migration."""
    bad = db.one("SELECT id, cleared FROM transactions WHERE cleared IS NULL OR cleared NOT IN (0, 1) ORDER BY id")
    if bad is not None:
        raise MigrationError("transaction %d has cleared value %r, expected 0 or 1" % (bad["id"], bad["cleared"]))
    _run(db, _V2)
    db.execute("UPDATE transactions SET flag = '!' WHERE cleared = 0")


def _clean_currency(text, where):
    """Trim and upper-case a free-text currency; empty means 'no currency'. Anything but three letters is an error."""
    if text is None:
        return None
    code = text.strip().upper()
    if not code:
        return None
    if not _CODE.match(code):
        raise MigrationError("%s has an invalid currency %r" % (where, text))
    return code


def _step_3(db):
    """Adds rates and accounts.closed. Free-text currencies of accounts and postings become trimmed upper-case codes."""
    _run(db, _V3)
    for row in db.all("SELECT path, currency FROM accounts WHERE currency IS NOT NULL ORDER BY path"):
        code = _clean_currency(row["currency"], "account %s" % row["path"])
        if code != row["currency"]:
            db.execute("UPDATE accounts SET currency = ? WHERE path = ?", (code, row["path"]))
    for row in db.all("SELECT DISTINCT currency FROM postings"):
        code = _clean_currency(row["currency"], "a posting")
        if code is None:
            raise MigrationError("a posting has an empty currency")
        if code != row["currency"]:
            db.execute("UPDATE postings SET currency = ? WHERE currency = ?", (code, row["currency"]))


def _step_4(db):
    """Adds budgets, recurring, rules, settings and import_keys, all empty. Existing rows are untouched."""
    _run(db, _V4)


STEPS = {1: _step_1, 2: _step_2, 3: _step_3, 4: _step_4}


def migrate(db):
    """Apply every missing step, one transaction each; returns the versions applied (empty when up to date)."""
    applied = []
    for version in range(db.user_version() + 1, LATEST_VERSION + 1):
        try:
            with db.transaction():
                STEPS[version](db)
                db.execute("PRAGMA user_version = %d" % version)
        except MigrationError as exc:
            raise MigrationError("migration to version %d failed: %s (the database stays at version %d)"
                                 % (version, exc.message, version - 1))
        except (sqlite3.Error, TallybookError) as exc:
            raise MigrationError("migration to version %d failed: %s (the database stays at version %d)"
                                 % (version, exc, version - 1))
        applied.append(version)
    return applied

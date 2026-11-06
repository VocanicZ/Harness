"""Module 14, storage: the SQLite book file, its schema history, and the Store on top of it. Black box."""
import os
import sqlite3
import unittest
from datetime import date

from support import Base, lib, phase

D = date

# ---- the schema history, written out the way the brief states it (not taken from the solution) -----------------

DDL = {
    1: ["CREATE TABLE accounts (path TEXT PRIMARY KEY, type TEXT NOT NULL, currency TEXT, opened TEXT,"
        " note TEXT NOT NULL DEFAULT '')",
        "CREATE TABLE transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, payee TEXT NOT NULL,"
        " narration TEXT NOT NULL DEFAULT '', cleared INTEGER NOT NULL DEFAULT 1)",
        "CREATE TABLE postings (id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " tx_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,"
        " seq INTEGER NOT NULL, account TEXT NOT NULL REFERENCES accounts(path),"
        " minor INTEGER NOT NULL, currency TEXT NOT NULL)"],
    2: ["CREATE TABLE tags (tx_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,"
        " tag TEXT NOT NULL, PRIMARY KEY (tx_id, tag))",
        "ALTER TABLE transactions ADD COLUMN flag TEXT NOT NULL DEFAULT '*'",
        "ALTER TABLE postings ADD COLUMN note TEXT NOT NULL DEFAULT ''"],
    3: ["CREATE TABLE rates (src TEXT NOT NULL, dst TEXT NOT NULL, on_date TEXT NOT NULL, rate_text TEXT NOT NULL,"
        " PRIMARY KEY (src, dst, on_date))",
        "ALTER TABLE accounts ADD COLUMN closed TEXT"],
}
V4_TABLES = ["budgets", "recurring", "rules", "settings", "import_keys"]


def raw(path, sql, params=()):
    conn = sqlite3.connect(path)
    try:
        return conn.execute(sql, params).fetchall()
    finally:
        conn.close()


def raw_exec(path, *statements):
    conn = sqlite3.connect(path)
    try:
        for sql in statements:
            conn.execute(sql)
        conn.commit()
    finally:
        conn.close()


def tables(path):
    return {r[0] for r in raw(path, "SELECT name FROM sqlite_master WHERE type = 'table'")}


def user_version(path):
    return raw(path, "PRAGMA user_version")[0][0]


def insert(conn, table, **cols):
    conn.execute("INSERT INTO %s (%s) VALUES (%s)" % (table, ", ".join(cols), ", ".join("?" * len(cols))),
                 list(cols.values()))


def build_db(path, version, rows=True, cascades=True):
    """A book file exactly as an older release left it: the schema of `version`, plus (if `rows`) a few rows."""
    conn = sqlite3.connect(path)
    for v in range(1, version + 1):
        for sql in DDL[v]:
            conn.execute(sql if cascades else sql.replace(" ON DELETE CASCADE", ""))
    if rows:
        dirty = version < 3
        extra = {"closed": None} if version >= 3 else {}
        insert(conn, "accounts", path="Assets:Bank", type="asset", currency=" usd " if dirty else "USD",
               opened="2024-01-01", note="", **extra)
        insert(conn, "accounts", path="Equity:Opening", type="equity", currency=None, opened=None, note="", **extra)
        insert(conn, "accounts", path="Expenses:Food", type="expense", currency="" if dirty else None, opened=None,
               note="food", **extra)
        if version >= 3:
            insert(conn, "accounts", path="Assets:Old", type="asset", currency="USD", opened="2023-01-01", note="",
                   closed="2024-02-01")
        for tid, day, payee, narr, cleared in ((1, "2024-01-05", "Opening", "start", 1), (2, "2024-01-06", "Grocer", "weekly", 0)):
            flag = {"flag": "*" if cleared else "!"} if version >= 2 else {}
            insert(conn, "transactions", id=tid, date=day, payee=payee, narration=narr, cleared=cleared, **flag)
        cur = "usd" if dirty else "USD"
        note = lambda text: {"note": text} if version >= 2 else {}    # noqa: E731
        insert(conn, "postings", tx_id=1, seq=0, account="Assets:Bank", minor=100000, currency=cur, **note(""))
        insert(conn, "postings", tx_id=1, seq=1, account="Equity:Opening", minor=-100000, currency=cur, **note(""))
        insert(conn, "postings", tx_id=2, seq=0, account="Expenses:Food", minor=2550, currency="USD", **note("milk"))
        insert(conn, "postings", tx_id=2, seq=1, account="Assets:Bank", minor=-2550, currency="USD", **note(""))
        if version >= 2:
            for tid, tag in ((1, "start"), (1, "opening"), (2, "food")):
                insert(conn, "tags", tx_id=tid, tag=tag)
    conn.execute("PRAGMA user_version = %d" % version)
    conn.commit()
    conn.close()


def mod():
    return lib("storage")


def model():
    return lib("model")


def money(minor, cur="USD"):
    return lib("money").Money(minor, cur)


def posting(account, minor=None, cur="USD", note=""):
    return model().Posting(account, None if minor is None else money(minor, cur), note)


def make_tx(day, payee, amount, expense="Expenses:Food", bank="Assets:Bank", tags=(), flag="*", narration=""):
    """Spend `amount` minor USD units from `bank` on `expense`."""
    return model().Transaction(day, payee, narration, [posting(expense, amount), posting(bank, -amount)], tags, flag)


class StoreBase(Base):
    """A fresh, current-version book holding a small chart; `self.s` is open and closed automatically."""
    CHART = [("Assets:Bank", "USD"), ("Assets:Cash", None), ("Assets:Old", "USD"), ("Expenses:Food", None),
             ("Expenses:Rent", None), ("Expenses:Fun", None), ("Income:Salary", None), ("Equity:Opening", None)]

    def setUp(self):
        super().setUp()
        self.s = self.open(create=True)
        for path, cur in self.CHART:
            self.s.add_account(path, currency=cur)

    def open(self, create=False, path=None):
        store = mod().Store.open(path or self.db, create=create)
        self.addCleanup(store.close)
        return store


# ---- opening -----------------------------------------------------------------------------------------------------

class M14OpenTest(Base):
    def test_latest_version_is_4(self):
        self.assertEqual(mod().LATEST_VERSION, 4)

    def test_create_makes_a_current_book(self):
        with mod().Store.open(self.db, create=True) as s:
            self.assertEqual(s.version, 4)
        self.assertEqual(user_version(self.db), 4)
        self.assertTrue(set(V4_TABLES + ["accounts", "transactions", "postings", "tags", "rates"]) <= tables(self.db))

    def test_missing_file_without_create_is_not_found(self):
        with self.assertRaises(lib("errors").NotFoundError):
            mod().Store.open(self.db)
        self.assertFalse(os.path.exists(self.db))

    def test_missing_parent_directory_is_not_found(self):
        with self.assertRaises(lib("errors").NotFoundError):
            mod().Store.open(os.path.join(self.tmp, "nope", "book.db"), create=True)

    def test_create_on_an_existing_book_keeps_its_data(self):
        with mod().Store.open(self.db, create=True) as s:
            s.add_account("Assets:Bank")
        with mod().Store.open(self.db, create=True) as s:
            self.assertEqual([a.path for a in s.accounts()], ["Assets:Bank"])

    def test_create_does_not_migrate_an_old_book(self):
        build_db(self.db, 2)
        with mod().Store.open(self.db, create=True) as s:
            self.assertEqual(s.version, 2)
        self.assertEqual(user_version(self.db), 2)

    def test_path_objects_work(self):
        import pathlib
        with mod().Store.open(pathlib.Path(self.db), create=True) as s:
            self.assertEqual(s.version, 4)

    def test_a_text_file_is_not_a_database(self):
        path = self.write("book.db", "this is not a database, just some words " * 20)
        with self.assertRaises(lib("errors").ConflictError):
            mod().Store.open(path)

    def test_a_directory_is_not_a_database(self):
        with self.assertRaises(lib("errors").ConflictError):
            mod().Store.open(self.tmp)

    def test_someone_elses_sqlite_database_is_refused(self):
        raw_exec(self.db, "CREATE TABLE stuff (a)")
        with self.assertRaises(lib("errors").ConflictError):
            mod().Store.open(self.db)
        self.assertEqual(tables(self.db), {"stuff"})

    def test_a_newer_book_is_refused_and_left_alone(self):
        build_db(self.db, 3)
        raw_exec(self.db, "PRAGMA user_version = 9")
        with self.assertRaises(lib("errors").ConflictError):
            mod().Store.open(self.db)
        self.assertEqual(user_version(self.db), 9)

    def test_an_empty_sqlite_file_opens_at_version_zero(self):
        open(self.db, "wb").close()
        with mod().Store.open(self.db) as s:
            self.assertEqual(s.version, 0)
            with self.assertRaises(lib("errors").ConflictError):
                s.accounts()
            self.assertEqual(s.migrate(), [1, 2, 3, 4])
            self.assertEqual(s.accounts(), [])

    def test_create_on_an_empty_file_migrates_it(self):
        open(self.db, "wb").close()
        with mod().Store.open(self.db, create=True) as s:
            self.assertEqual(s.version, 4)

    def test_operations_after_close_fail(self):
        s = mod().Store.open(self.db, create=True)
        s.close()
        with self.assertRaises(lib("errors").ConflictError):
            s.accounts()

    def test_info_counts_rows(self):
        with mod().Store.open(self.db, create=True) as s:
            s.add_account("Assets:Bank")
            s.add_account("Expenses:Food")
            s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500))
            info = s.info()
        self.assertEqual((info["version"], info["accounts"], info["transactions"], info["postings"],
                          info["rates"], info["budgets"], info["recurring"]), (4, 2, 1, 2, 0, 0, 0))
        self.assertEqual(info["path"], self.db)


# ---- migrations --------------------------------------------------------------------------------------------------

class M14MigrationTest(Base):
    def migrated(self, version, **kw):
        build_db(self.db, version, **kw)
        s = mod().Store.open(self.db)
        self.addCleanup(s.close)
        return s

    def check_book(self, s, version):
        """What the seeded rows of build_db look like through the Store once everything is migrated."""
        accounts = {a.path: a for a in s.accounts()}
        expected = ["Assets:Bank", "Equity:Opening", "Expenses:Food"] + (["Assets:Old"] if version >= 3 else [])
        self.assertEqual(sorted(accounts), sorted(expected))
        self.assertEqual(accounts["Assets:Bank"].currency, "USD")
        self.assertEqual(accounts["Assets:Bank"].opened, D(2024, 1, 1))
        self.assertIsNone(accounts["Expenses:Food"].currency)
        self.assertEqual(accounts["Expenses:Food"].note, "food")
        self.assertIsNone(accounts["Assets:Bank"].closed)
        if version >= 3:
            self.assertEqual(accounts["Assets:Old"].closed, D(2024, 2, 1))
        txs = s.transactions()
        self.assertEqual([t.id for t in txs], [1, 2])
        self.assertEqual([(t.date, t.payee, t.narration, t.flag) for t in txs],
                         [(D(2024, 1, 5), "Opening", "start", "*"), (D(2024, 1, 6), "Grocer", "weekly", "!")])
        self.assertEqual([(p.account, p.amount.minor, p.amount.currency) for p in txs[0].postings],
                         [("Assets:Bank", 100000, "USD"), ("Equity:Opening", -100000, "USD")])
        self.assertEqual([(p.account, p.amount.minor, p.amount.currency) for p in txs[1].postings],
                         [("Expenses:Food", 2550, "USD"), ("Assets:Bank", -2550, "USD")])
        self.assertEqual(txs[0].tags, ("opening", "start") if version >= 2 else ())
        self.assertEqual(txs[1].tags, ("food",) if version >= 2 else ())
        self.assertEqual([p.note for p in txs[1].postings], ["milk", ""] if version >= 2 else ["", ""])

    def test_old_books_open_without_being_changed(self):
        for version in (1, 2, 3):
            with self.subTest(version=version):
                path = self.path("old%d.db" % version)
                build_db(path, version)
                with mod().Store.open(path) as s:
                    self.assertEqual(s.version, version)
                self.assertEqual(user_version(path), version)

    def test_operations_on_an_old_book_ask_for_a_migration(self):
        for version in (1, 2, 3):
            with self.subTest(version=version):
                path = self.path("old%d.db" % version)
                build_db(path, version)
                with mod().Store.open(path) as s:
                    for call in (s.accounts, s.transactions, lambda: s.count_transactions(), s.budgets, s.rules_text,
                                 lambda: s.get_setting("x"), s.chart, s.ledger):
                        with self.assertRaises(lib("errors").ConflictError) as ctx:
                            call()
                        self.assertIn("database is at version %d" % version, str(ctx.exception))
                        self.assertIn("db migrate", str(ctx.exception))

    def test_migrate_from_each_version_returns_the_steps_applied(self):
        for version in (1, 2, 3):
            with self.subTest(version=version):
                path = self.path("old%d.db" % version)
                build_db(path, version)
                with mod().Store.open(path) as s:
                    self.assertEqual(s.migrate(), list(range(version + 1, 5)))
                    self.assertEqual(s.version, 4)
                self.assertEqual(user_version(path), 4)
                self.assertTrue(set(V4_TABLES) <= tables(path))

    def test_data_survives_migration_from_each_version(self):
        for version in (1, 2, 3):
            with self.subTest(version=version):
                path = self.path("old%d.db" % version)
                build_db(path, version)
                with mod().Store.open(path) as s:
                    s.migrate()
                    self.check_book(s, version)

    def test_v1_cleared_becomes_the_flag(self):
        s = self.migrated(1)
        s.migrate()
        self.assertEqual(raw(self.db, "SELECT id, flag FROM transactions ORDER BY id"), [(1, "*"), (2, "!")])
        self.assertEqual(raw(self.db, "SELECT count(*) FROM tags"), [(0,)])

    def test_v3_cleans_account_and_posting_currencies(self):
        s = self.migrated(2)
        s.migrate()
        self.assertEqual(raw(self.db, "SELECT path, currency FROM accounts ORDER BY path"),
                         [("Assets:Bank", "USD"), ("Equity:Opening", None), ("Expenses:Food", None)])
        self.assertEqual(raw(self.db, "SELECT DISTINCT currency FROM postings"), [("USD",)])

    def test_v4_tables_start_empty(self):
        s = self.migrated(3)
        s.migrate()
        for table in V4_TABLES:
            self.assertEqual(raw(self.db, "SELECT count(*) FROM %s" % table), [(0,)], table)
        self.assertEqual(s.budgets(), [])
        self.assertEqual(s.recurring(), [])
        self.assertEqual(s.settings(), {})
        self.assertEqual(s.rules_text(), "")

    def test_migrate_twice_is_harmless(self):
        s = self.migrated(1)
        self.assertEqual(s.migrate(), [2, 3, 4])
        self.assertEqual(s.migrate(), [])
        self.check_book(s, 1)

    def test_a_migrated_book_equals_a_created_one(self):
        build_db(self.db, 3, rows=False)
        with mod().Store.open(self.db) as s:
            s.migrate()
        fresh = self.path("fresh.db")
        mod().Store.open(fresh, create=True).close()
        for table in sorted(tables(fresh)):
            if table.startswith("sqlite_"):
                continue
            cols = lambda p: [(r[1], r[2], r[3], r[5]) for r in raw(p, "PRAGMA table_info(%s)" % table)]   # noqa: E731
            self.assertEqual(sorted(cols(self.db)), sorted(cols(fresh)), table)

    def test_new_transactions_continue_after_the_old_ids(self):
        s = self.migrated(1)
        s.migrate()
        s.add_account("Expenses:Rent")
        tx = s.add_transaction(make_tx(D(2024, 2, 1), "Landlord", 90000, expense="Expenses:Rent"))
        self.assertEqual(tx.id, 3)
        self.assertEqual(s.ledger().balances()["Expenses:Rent"], {"USD": 90000})

    def test_a_migrated_book_balances_through_the_ledger(self):
        s = self.migrated(1)
        s.migrate()
        self.assertEqual(s.ledger().balances(), {"Assets:Bank": {"USD": 97450}, "Equity:Opening": {"USD": -100000},
                                                  "Expenses:Food": {"USD": 2550}})

    def test_a_bad_cleared_value_stops_step_two_and_changes_nothing(self):
        build_db(self.db, 1)
        raw_exec(self.db, "UPDATE transactions SET cleared = 2 WHERE id = 2")
        with mod().Store.open(self.db) as s:
            with self.assertRaises(lib("errors").ConflictError) as ctx:
                s.migrate()
            self.assertIn("migration to version 2 failed", str(ctx.exception))
            self.assertEqual(s.version, 1)
        self.assertEqual(user_version(self.db), 1)
        self.assertFalse({"tags", "rates", "budgets"} & tables(self.db))
        columns = [r[1] for r in raw(self.db, "PRAGMA table_info(transactions)")]
        self.assertEqual(columns, ["id", "date", "payee", "narration", "cleared"])
        self.assertEqual(raw(self.db, "SELECT id, cleared FROM transactions ORDER BY id"), [(1, 1), (2, 2)])

    def test_a_bad_currency_stops_step_three_and_leaves_version_two(self):
        build_db(self.db, 2)
        raw_exec(self.db, "UPDATE accounts SET currency = 'dollars' WHERE path = 'Expenses:Food'")
        with mod().Store.open(self.db) as s:
            with self.assertRaises(lib("errors").ConflictError) as ctx:
                s.migrate()
            self.assertIn("migration to version 3 failed", str(ctx.exception))
            self.assertEqual(s.version, 2)
        self.assertEqual(user_version(self.db), 2)
        self.assertNotIn("rates", tables(self.db))
        self.assertEqual(raw(self.db, "SELECT currency FROM accounts WHERE path = 'Assets:Bank'"), [(" usd ",)])
        self.assertEqual(raw(self.db, "SELECT DISTINCT currency FROM postings ORDER BY 1"), [("USD",), ("usd",)])

    def test_steps_before_a_failing_step_stay_applied(self):
        build_db(self.db, 1)
        raw_exec(self.db, "UPDATE accounts SET currency = 'dollars' WHERE path = 'Expenses:Food'")
        with mod().Store.open(self.db) as s:
            with self.assertRaises(lib("errors").ConflictError):
                s.migrate()
            self.assertEqual(s.version, 2)
        self.assertEqual(user_version(self.db), 2)
        self.assertIn("tags", tables(self.db))
        self.assertEqual(raw(self.db, "SELECT flag FROM transactions ORDER BY id"), [("*",), ("!",)])
        # repairing the data lets the next run finish
        raw_exec(self.db, "UPDATE accounts SET currency = 'eur' WHERE path = 'Expenses:Food'")
        with mod().Store.open(self.db) as s:
            self.assertEqual(s.migrate(), [3, 4])
            self.assertEqual(s.get_account("Expenses:Food").currency, "EUR")

    def test_a_posting_without_a_currency_stops_step_three(self):
        build_db(self.db, 2)
        raw_exec(self.db, "UPDATE postings SET currency = '' WHERE tx_id = 2")
        with mod().Store.open(self.db) as s:
            with self.assertRaises(lib("errors").ConflictError):
                s.migrate()
            self.assertEqual(s.version, 2)

    def test_a_step_that_cannot_create_its_tables_leaves_the_version(self):
        build_db(self.db, 3)
        raw_exec(self.db, "CREATE TABLE settings (x)")
        with mod().Store.open(self.db) as s:
            with self.assertRaises(lib("errors").ConflictError) as ctx:
                s.migrate()
            self.assertIn("migration to version 4 failed", str(ctx.exception))
            self.assertEqual(s.version, 3)
        self.assertEqual(user_version(self.db), 3)
        self.assertFalse({"budgets", "recurring", "rules", "import_keys"} & tables(self.db))

    def test_old_tables_without_cascades_still_delete_cleanly(self):
        build_db(self.db, 1, cascades=False)
        with mod().Store.open(self.db) as s:
            s.migrate()
            s.delete_transaction(2)
        self.assertEqual(raw(self.db, "SELECT count(*) FROM postings WHERE tx_id = 2"), [(0,)])
        self.assertEqual(raw(self.db, "SELECT count(*) FROM tags WHERE tx_id = 2"), [(0,)])
        self.assertEqual(raw(self.db, "SELECT count(*) FROM transactions"), [(1,)])


# ---- accounts ----------------------------------------------------------------------------------------------------

class M14AccountTest(StoreBase):
    CHART = []

    def test_add_returns_the_stored_account(self):
        acct = self.s.add_account("Assets:Bank:Checking", currency="USD", opened=D(2024, 1, 1), note="main")
        self.assertEqual((acct.path, acct.type, acct.currency, acct.opened, acct.closed, acct.note),
                         ("Assets:Bank:Checking", "asset", "USD", D(2024, 1, 1), None, "main"))
        self.assertEqual(self.s.get_account("Assets:Bank:Checking"), acct)

    def test_type_comes_from_the_first_segment(self):
        self.assertEqual(self.s.add_account("Income:Salary").type, "income")
        self.assertEqual(self.s.add_account("Liabilities:Card", type="liability").type, "liability")

    def test_invalid_accounts_are_refused_and_not_stored(self):
        for args, kwargs in ((("assets:bank",), {}), (("Assets:Bank",), {"type": "income"}),
                             (("Assets:Bank",), {"currency": "ZZZ"})):
            with self.subTest(args=args, kwargs=kwargs):
                with self.assertRaises(lib("errors").ValidationError):
                    self.s.add_account(*args, **kwargs)
        self.assertEqual(self.s.accounts(), [])

    def test_adding_a_path_twice_is_refused(self):
        self.s.add_account("Assets:Bank")
        with self.assertRaises(lib("errors").TallybookError):
            self.s.add_account("Assets:Bank")
        self.assertEqual(self.s.count_accounts(), 1)

    def test_get_of_an_unknown_account_is_not_found(self):
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.get_account("Assets:Nope")

    def test_listing_filters(self):
        for path, cur in (("Assets:Bank:Checking", "USD"), ("Assets:Bank:Savings", "EUR"), ("Assets:Cash", None),
                          ("Expenses:Food", None), ("Income:Salary", "USD")):
            self.s.add_account(path, currency=cur)
        self.s.close_account("Assets:Cash", D(2024, 1, 31))
        paths = lambda **kw: [a.path for a in self.s.accounts(**kw)]    # noqa: E731
        self.assertEqual(paths(), ["Assets:Bank:Checking", "Assets:Bank:Savings", "Assets:Cash", "Expenses:Food",
                                   "Income:Salary"])
        self.assertEqual(paths(type="asset"), ["Assets:Bank:Checking", "Assets:Bank:Savings", "Assets:Cash"])
        self.assertEqual(paths(under="Assets:Bank"), ["Assets:Bank:Checking", "Assets:Bank:Savings"])
        self.assertEqual(paths(currency="USD"), ["Assets:Bank:Checking", "Income:Salary"])
        self.assertEqual(paths(type="asset", include_closed=False), ["Assets:Bank:Checking", "Assets:Bank:Savings"])
        self.assertEqual(paths(under="Assets:Cash"), ["Assets:Cash"])
        self.assertEqual(paths(under="Assets:Ban"), [])
        self.assertEqual(self.s.count_accounts(type="asset"), 3)
        self.assertEqual(self.s.count_accounts(), 5)
        with self.assertRaises(lib("errors").ValidationError):
            self.s.accounts(type="cash")

    def test_chart_reflects_the_stored_accounts(self):
        self.s.add_account("Assets:Bank", currency="USD")
        self.s.add_account("Assets:Old")
        self.s.close_account("Assets:Old", D(2024, 1, 1))
        chart = self.s.chart()
        self.assertTrue(chart.exists("Assets:Bank"))
        self.assertEqual(chart.get("Assets:Old").closed, D(2024, 1, 1))
        self.assertEqual(chart.get("Assets:Bank").currency, "USD")

    def test_closing_an_account(self):
        self.s.add_account("Assets:Bank")
        self.s.add_account("Expenses:Food")
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500))
        acct = self.s.close_account("Assets:Bank", D(2024, 3, 1))
        self.assertEqual(acct.closed, D(2024, 3, 1))
        with self.assertRaises(lib("errors").ValidationError):
            self.s.add_transaction(make_tx(D(2024, 3, 2), "Shop", 500))
        with self.assertRaises(lib("errors").TallybookError):
            self.s.close_account("Assets:Bank", D(2024, 4, 1))

    def test_closing_before_an_existing_posting_is_a_conflict(self):
        self.s.add_account("Assets:Bank")
        self.s.add_account("Expenses:Food")
        self.s.add_transaction(make_tx(D(2024, 3, 10), "Shop", 500))
        with self.assertRaises(lib("errors").ConflictError):
            self.s.close_account("Assets:Bank", D(2024, 3, 9))
        self.assertIsNone(self.s.get_account("Assets:Bank").closed)

    def test_closing_an_unknown_account_is_not_found(self):
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.close_account("Assets:Nope", D(2024, 1, 1))

    def test_updating_the_note(self):
        self.s.add_account("Assets:Bank", note="old")
        self.assertEqual(self.s.set_account_note("Assets:Bank", "new").note, "new")
        self.assertEqual(self.s.get_account("Assets:Bank").note, "new")
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.set_account_note("Assets:Nope", "x")

    def test_deleting_an_account(self):
        self.s.add_account("Assets:Bank")
        self.s.add_account("Expenses:Food")
        self.s.add_account("Expenses:Fun")
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500))
        self.s.delete_account("Expenses:Fun")
        self.assertEqual([a.path for a in self.s.accounts()], ["Assets:Bank", "Expenses:Food"])
        with self.assertRaises(lib("errors").ConflictError):
            self.s.delete_account("Expenses:Food")
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.delete_account("Expenses:Fun")


# ---- transactions ------------------------------------------------------------------------------------------------

class M14TransactionTest(StoreBase):
    def test_ids_count_up_from_one_and_come_back_on_the_result(self):
        a = self.s.add_transaction(make_tx(D(2024, 3, 1), "A", 100))
        b = self.s.add_transaction(make_tx(D(2024, 3, 2), "B", 200))
        self.assertEqual((a.id, b.id), (1, 2))
        self.assertEqual(self.s.get_transaction(2), b)

    def test_an_id_on_the_input_is_ignored(self):
        tx = make_tx(D(2024, 3, 1), "A", 100)
        tx.id = 77
        self.assertEqual(self.s.add_transaction(tx).id, 1)

    def test_ids_are_never_reused(self):
        self.s.add_transaction(make_tx(D(2024, 3, 1), "A", 100))
        self.s.add_transaction(make_tx(D(2024, 3, 2), "B", 200))
        self.s.delete_transaction(2)
        self.assertEqual(self.s.add_transaction(make_tx(D(2024, 3, 3), "C", 300)).id, 3)

    def test_a_missing_amount_is_filled_in(self):
        tx = model().Transaction(D(2024, 3, 1), "Shop", "", [posting("Expenses:Food", 1250), posting("Assets:Bank")])
        stored = self.s.add_transaction(tx)
        self.assertEqual([(p.account, p.amount) for p in stored.postings],
                         [("Expenses:Food", money(1250)), ("Assets:Bank", money(-1250))])
        self.assertEqual(self.s.get_transaction(stored.id).postings, stored.postings)

    def test_everything_round_trips(self):
        tx = model().Transaction(D(2024, 3, 1), "Café", "two—words", [
            posting("Expenses:Food", 1250, note="latte"), posting("Assets:Cash", -1250, note="")], ("b", "a", "b"), "!")
        stored = self.s.add_transaction(tx)
        self.assertEqual(stored.tags, ("a", "b"))
        got = self.s.get_transaction(stored.id)
        self.assertEqual((got.date, got.payee, got.narration, got.flag, got.tags),
                         (D(2024, 3, 1), "Café", "two—words", "!", ("a", "b")))
        self.assertEqual(got.postings[0].note, "latte")
        self.assertEqual(got.postings[1].amount, money(-1250))

    def test_an_unbalanced_transaction_is_refused_and_stores_nothing(self):
        tx = model().Transaction(D(2024, 3, 1), "Shop", "", [posting("Expenses:Food", 1000), posting("Assets:Bank", -900)])
        with self.assertRaises(lib("errors").ValidationError):
            self.s.add_transaction(tx)
        self.assertEqual(self.s.count_transactions(), 0)
        self.assertEqual(raw(self.db, "SELECT count(*) FROM postings"), [(0,)])

    def test_unknown_account_closed_account_and_wrong_currency_are_refused(self):
        cases = {
            "unknown": make_tx(D(2024, 3, 1), "Shop", 500, expense="Expenses:Nope"),
            "wrong currency": model().Transaction(D(2024, 3, 1), "Shop", "", [
                posting("Expenses:Food", 500, "EUR"), posting("Assets:Bank", -500, "EUR")]),
        }
        for name, tx in cases.items():
            with self.subTest(name):
                with self.assertRaises(lib("errors").ValidationError):
                    self.s.add_transaction(tx)
        self.s.close_account("Assets:Old", D(2024, 1, 1))
        with self.assertRaises(lib("errors").ValidationError):
            self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500, bank="Assets:Old"))
        self.assertEqual(self.s.count_transactions(), 0)

    def test_a_bad_flag_is_refused(self):
        with self.assertRaises(lib("errors").ValidationError):
            self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500, flag="?"))

    def test_get_of_a_missing_transaction_is_not_found(self):
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.get_transaction(5)

    def test_listing_is_ordered_by_date_then_id(self):
        for day, payee in ((D(2024, 3, 5), "C"), (D(2024, 3, 1), "A"), (D(2024, 3, 5), "D"), (D(2024, 3, 2), "B")):
            self.s.add_transaction(make_tx(day, payee, 100))
        self.assertEqual([t.payee for t in self.s.transactions()], ["A", "B", "C", "D"])
        self.assertEqual([t.id for t in self.s.transactions()], [2, 4, 1, 3])

    def seed_many(self):
        for n in range(1, 8):
            self.s.add_transaction(make_tx(D(2024, 3, n), "Shop%d" % n, n * 100,
                                           expense="Expenses:Food" if n % 2 else "Expenses:Fun",
                                           tags=("odd",) if n % 2 else (), flag="*" if n < 5 else "!"))

    def test_limit_and_offset(self):
        self.seed_many()
        ids = lambda **kw: [t.id for t in self.s.transactions(**kw)]    # noqa: E731
        self.assertEqual(ids(limit=3), [1, 2, 3])
        self.assertEqual(ids(limit=3, offset=2), [3, 4, 5])
        self.assertEqual(ids(offset=5), [6, 7])
        self.assertEqual(ids(limit=0), [])
        self.assertEqual(ids(offset=7), [])
        self.assertEqual(ids(limit=100, offset=6), [7])

    def test_bad_limit_or_offset_is_a_validation_error(self):
        for kwargs in ({"limit": -1}, {"offset": -1}, {"limit": "3"}, {"offset": None}):
            with self.subTest(kwargs=kwargs):
                with self.assertRaises(lib("errors").ValidationError):
                    self.s.transactions(**kwargs)

    def test_queries_filter_then_page(self):
        self.seed_many()
        ids = lambda *a, **kw: [t.id for t in self.s.transactions(*a, **kw)]    # noqa: E731
        self.assertEqual(ids("tag:odd"), [1, 3, 5, 7])
        self.assertEqual(ids("tag:odd", limit=2), [1, 3])
        self.assertEqual(ids("tag:odd", limit=2, offset=1), [3, 5])
        self.assertEqual(ids("tag:odd", offset=3), [7])
        self.assertEqual(ids("flag:!"), [5, 6, 7])
        self.assertEqual(ids("account:Expenses:Fun"), [2, 4, 6])
        self.assertEqual(ids("payee:shop3"), [3])
        self.assertEqual(ids("date:2024-03-02..2024-03-04"), [2, 3, 4])
        self.assertEqual(ids("account:Expenses:Fun and flag:!"), [6])
        self.assertEqual(ids("tag:nothing"), [])

    def test_a_parsed_query_object_works_too(self):
        self.seed_many()
        q = lib("query").parse_query("tag:odd")
        self.assertEqual([t.id for t in self.s.transactions(q)], [1, 3, 5, 7])
        self.assertEqual(self.s.count_transactions(q), 4)

    def test_blank_query_means_everything(self):
        self.seed_many()
        self.assertEqual(self.s.count_transactions("  "), 7)
        self.assertEqual(len(self.s.transactions("")), 7)

    def test_count_ignores_paging(self):
        self.seed_many()
        self.assertEqual(self.s.count_transactions(), 7)
        self.assertEqual(self.s.count_transactions("tag:odd"), 4)
        self.assertEqual(self.s.count_transactions("flag:!"), 3)
        self.assertEqual(self.s.count_transactions("tag:none"), 0)

    def test_a_bad_query_is_a_parse_error(self):
        with self.assertRaises(lib("errors").ParseError):
            self.s.transactions("bogus:thing")
        with self.assertRaises(lib("errors").ParseError):
            self.s.count_transactions("account:Nowhere")

    def test_deleting_removes_postings_tags_and_the_import_key(self):
        keep = self.s.add_transaction(make_tx(D(2024, 3, 1), "Keep", 100, tags=("k",)))
        gone = self.s.add_transaction(make_tx(D(2024, 3, 2), "Gone", 200, tags=("x", "y")))
        self.s.add_transactions([make_tx(D(2024, 3, 3), "Keyed", 300)], keys=["k1"])
        removed = self.s.delete_transaction(gone.id)
        self.assertEqual((removed.id, removed.payee), (gone.id, "Gone"))
        self.s.delete_transaction(3)
        self.assertEqual(raw(self.db, "SELECT count(*) FROM postings WHERE tx_id IN (2, 3)"), [(0,)])
        self.assertEqual(raw(self.db, "SELECT count(*) FROM tags WHERE tx_id IN (2, 3)"), [(0,)])
        self.assertEqual(raw(self.db, "SELECT count(*) FROM import_keys"), [(0,)])
        self.assertEqual(raw(self.db, "SELECT count(*) FROM postings WHERE tx_id = 1"), [(2,)])
        self.assertEqual([t.id for t in self.s.transactions()], [keep.id])
        self.assertFalse(self.s.has_import_key("k1"))

    def test_deleting_a_missing_transaction_is_not_found(self):
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.delete_transaction(9)

    def test_the_ledger_holds_the_whole_book(self):
        self.s.add_transaction(make_tx(D(2024, 3, 1), "A", 500))
        self.s.add_transaction(make_tx(D(2024, 3, 2), "B", 250, expense="Expenses:Fun"))
        ledger = self.s.ledger()
        self.assertEqual([t.id for t in ledger.transactions()], [1, 2])
        self.assertEqual(ledger.balances(), {"Assets:Bank": {"USD": -750}, "Expenses:Food": {"USD": 500},
                                             "Expenses:Fun": {"USD": 250}})
        ledger.remove(1)     # the in-memory ledger is a copy
        self.assertEqual(self.s.count_transactions(), 2)


# ---- bulk add and csv import -------------------------------------------------------------------------------------

PROFILE = """date_column = Date
payee_column = Payee
amount_column = Amount
currency = USD
account = Assets:Bank
default_account = Expenses:Food
"""
CSV = "Date,Payee,Amount\n2024-03-01,Grocer,-12.50\n2024-03-02,Cafe,-3.00\n"


class M14ImportTest(StoreBase):
    def test_bulk_add_stores_all_and_returns_them(self):
        res = self.s.add_transactions([make_tx(D(2024, 3, n), "P%d" % n, n * 100) for n in (1, 2, 3)])
        self.assertEqual([t.id for t in res.added], [1, 2, 3])
        self.assertEqual(res.skipped, [])
        self.assertEqual(self.s.count_transactions(), 3)

    def test_bulk_add_is_all_or_nothing(self):
        txs = [make_tx(D(2024, 3, 1), "ok", 100), make_tx(D(2024, 3, 2), "bad", 100, expense="Expenses:Nope"),
               make_tx(D(2024, 3, 3), "ok", 100)]
        with self.assertRaises(lib("errors").ValidationError) as ctx:
            self.s.add_transactions(txs, keys=["a", "b", "c"])
        self.assertEqual(ctx.exception.detail["index"], 1)
        self.assertEqual(self.s.count_transactions(), 0)
        self.assertFalse(self.s.has_import_key("a"))

    def test_keys_make_a_second_add_skip(self):
        txs = [make_tx(D(2024, 3, 1), "A", 100), make_tx(D(2024, 3, 2), "B", 200)]
        self.assertEqual(len(self.s.add_transactions(txs, keys=["ka", "kb"]).added), 2)
        res = self.s.add_transactions(txs + [make_tx(D(2024, 3, 3), "C", 300)], keys=["ka", "kb", "kc"])
        self.assertEqual(res.skipped, [0, 1])
        self.assertEqual([t.payee for t in res.added], ["C"])
        self.assertEqual(self.s.count_transactions(), 3)
        self.assertTrue(self.s.has_import_key("kc"))

    def test_a_repeated_key_inside_one_batch_is_skipped(self):
        res = self.s.add_transactions([make_tx(D(2024, 3, 1), "A", 100), make_tx(D(2024, 3, 1), "A", 100)],
                                      keys=["same", "same"])
        self.assertEqual((len(res.added), res.skipped), (1, [1]))

    def test_wrong_number_of_keys_is_refused(self):
        with self.assertRaises(lib("errors").ValidationError):
            self.s.add_transactions([make_tx(D(2024, 3, 1), "A", 100)], keys=["a", "b"])

    def test_csv_import_stores_balanced_transactions(self):
        out = self.s.import_csv(CSV, PROFILE)
        self.assertEqual((len(out.added), out.duplicates, out.errors), (2, [], []))
        self.assertEqual(self.s.count_transactions(), 2)
        tx = self.s.transactions("payee:grocer")[0]
        self.assertEqual({p.account: p.amount for p in tx.postings},
                         {"Assets:Bank": money(-1250), "Expenses:Food": money(1250)})
        self.assertEqual(self.s.ledger().balance("Assets:Bank", currency="USD"), money(-1550))

    def test_importing_the_same_file_again_adds_nothing(self):
        self.s.import_csv(CSV, PROFILE)
        out = self.s.import_csv(CSV, PROFILE)
        self.assertEqual((len(out.added), len(out.duplicates)), (0, 2))
        self.assertEqual(self.s.count_transactions(), 2)

    def test_a_deleted_row_can_be_imported_again(self):
        self.s.import_csv(CSV, PROFILE)
        self.s.delete_transaction(1)
        out = self.s.import_csv(CSV, PROFILE)
        self.assertEqual((len(out.added), len(out.duplicates)), (1, 1))
        self.assertEqual(self.s.count_transactions(), 2)

    def test_identical_rows_in_one_file_are_both_kept(self):
        text = CSV + "2024-03-02,Cafe,-3.00\n"
        out = self.s.import_csv(text, PROFILE)
        self.assertEqual(len(out.added), 3)
        self.assertEqual(len(self.s.import_csv(text, PROFILE).added), 0)

    def test_a_bad_row_means_nothing_is_stored(self):
        out = self.s.import_csv(CSV + "2024-03-03,Bad,abc\n", PROFILE)
        self.assertEqual(out.added, [])
        self.assertEqual(len(out.errors), 1)
        self.assertEqual(self.s.count_transactions(), 0)

    def test_stored_rules_are_applied(self):
        self.s.set_rules('when payee = "Cafe" then account Expenses:Fun tag coffee\n')
        out = self.s.import_csv(CSV, PROFILE)
        cafe = [t for t in out.added if t.payee == "Cafe"][0]
        self.assertEqual({p.account for p in cafe.postings}, {"Assets:Bank", "Expenses:Fun"})
        self.assertEqual(cafe.tags, ("coffee",))
        grocer = [t for t in out.added if t.payee == "Grocer"][0]
        self.assertEqual({p.account for p in grocer.postings}, {"Assets:Bank", "Expenses:Food"})

    def test_rules_can_be_switched_off(self):
        self.s.set_rules('when payee = "Cafe" then account Expenses:Fun\n')
        out = self.s.import_csv(CSV, PROFILE, apply_rules=False)
        self.assertEqual({p.account for t in out.added for p in t.postings}, {"Assets:Bank", "Expenses:Food"})

    def test_stored_profiles(self):
        self.s.set_profile("bank-a", PROFILE)
        self.s.set_profile("bank-b", PROFILE)
        self.assertEqual(self.s.profiles(), ["bank-a", "bank-b"])
        self.assertEqual(self.s.profile_text("bank-a"), PROFILE)
        self.assertEqual(len(self.s.import_csv(CSV, "bank-a").added), 2)
        self.s.remove_profile("bank-b")
        self.assertEqual(self.s.profiles(), ["bank-a"])
        for call in (lambda: self.s.import_csv(CSV, "nosuch"), lambda: self.s.profile_text("nosuch"),
                     lambda: self.s.remove_profile("nosuch")):
            with self.assertRaises(lib("errors").NotFoundError):
                call()

    def test_bad_profiles_are_refused(self):
        with self.assertRaises(lib("errors").ParseError):
            self.s.set_profile("broken", "bogus_setting = 1\n")
        with self.assertRaises(lib("errors").ValidationError):
            self.s.set_profile("bad name", PROFILE)
        self.assertEqual(self.s.profiles(), [])

    def test_an_import_profile_object_works(self):
        profile = lib("csvimport").parse_profile(PROFILE)
        self.assertEqual(len(self.s.import_csv(CSV, profile).added), 2)

    def test_the_journal_round_trips_into_another_book(self):
        self.s.set_rate("EUR", "USD", "1.0850", D(2024, 1, 1))
        self.s.close_account("Assets:Old", D(2024, 2, 1))
        self.s.add_transaction(make_tx(D(2024, 3, 1), "A", 500, tags=("t",)))
        self.s.add_transaction(make_tx(D(2024, 3, 2), "B", 250, expense="Expenses:Fun", flag="!"))
        journal = self.s.journal()
        other = mod().Store.open(self.path("other.db"), create=True)
        self.addCleanup(other.close)
        added = other.load_journal(journal)
        self.assertEqual(len(added), 2)
        self.assertEqual(other.accounts(), self.s.accounts())
        self.assertEqual(other.transactions(), self.s.transactions())
        self.assertEqual(other.rate_rows(), self.s.rate_rows())

    def test_loading_a_journal_is_all_or_nothing(self):
        journal = self.s.journal()
        other = mod().Store.open(self.path("other.db"), create=True)
        self.addCleanup(other.close)
        other.add_account("Expenses:Rent")
        journal.accounts.append(lib("model").Account("Expenses:Rent", "expense"))
        with self.assertRaises(lib("errors").TallybookError):
            other.load_journal(journal)
        self.assertEqual([a.path for a in other.accounts()], ["Expenses:Rent"])


# ---- rates, budgets, recurring ------------------------------------------------------------------------------------

class M14RateBudgetTest(StoreBase):
    def test_rates_are_kept_exactly(self):
        self.s.set_rate("EUR", "USD", "1.0850", D(2024, 1, 1))
        self.s.set_rate("EUR", "USD", "1.1", D(2024, 3, 1))
        self.s.set_rate("USD", "JPY", "150", D(2024, 1, 1))
        self.assertEqual(self.s.rate_rows(), [("EUR", "USD", D(2024, 1, 1), "1.0850"), ("EUR", "USD", D(2024, 3, 1), "1.1"),
                                              ("USD", "JPY", D(2024, 1, 1), "150")])
        table = self.s.rate_table()
        self.assertEqual(str(table.rate("EUR", "USD", D(2024, 2, 1))), "217/200")
        self.assertEqual(table.convert(money(1000, "EUR"), "USD", D(2024, 3, 5)), money(1100))

    def test_setting_a_rate_again_replaces_it(self):
        self.s.set_rate("EUR", "USD", "1.10", D(2024, 1, 1))
        self.s.set_rate("EUR", "USD", "1.20", D(2024, 1, 1))
        self.assertEqual(self.s.rate_rows(), [("EUR", "USD", D(2024, 1, 1), "1.20")])

    def test_bad_rates_are_refused(self):
        for args in (("EUR", "USD", "0", D(2024, 1, 1)), ("EUR", "USD", "abc", D(2024, 1, 1)),
                     ("EUR", "EUR", "1", D(2024, 1, 1)), ("EUR", "ZZZ", "1.5", D(2024, 1, 1))):
            with self.subTest(args=args):
                with self.assertRaises(lib("errors").ValidationError):
                    self.s.set_rate(*args)
        self.assertEqual(self.s.rate_rows(), [])

    def test_removing_a_rate(self):
        self.s.set_rate("EUR", "USD", "1.10", D(2024, 1, 1))
        self.s.remove_rate("EUR", "USD", D(2024, 1, 1))
        self.assertEqual(self.s.rate_rows(), [])
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.remove_rate("EUR", "USD", D(2024, 1, 1))

    def test_budgets(self):
        B = lib("budgets").Budget
        food = B("Expenses:Food", "month", money(40000), D(2024, 1, 1))
        fun = B("Expenses:Fun", "month", money(10000), D(2024, 1, 1))
        year = B("Expenses:Food", "year", money(480000), D(2024, 1, 1))
        for b in (fun, food, year):
            self.s.add_budget(b)
        self.assertEqual(self.s.budgets(), [food, year, fun])
        with self.assertRaises(lib("errors").ConflictError):
            self.s.add_budget(B("Expenses:Food", "month", money(1), D(2024, 6, 1)))
        self.s.remove_budget("Expenses:Food", "month")
        self.assertEqual(self.s.budgets(), [year, fun])
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.remove_budget("Expenses:Food", "month")

    def test_a_budget_in_another_currency_keeps_it(self):
        b = lib("budgets").Budget("Expenses:*", "quarter", money(30000, "EUR"), D(2024, 1, 1))
        self.s.add_budget(b)
        self.assertEqual(self.s.budgets()[0].amount, money(30000, "EUR"))


def rent_series(name="rent", schedule="monthly on 1", start=D(2024, 1, 1), account="Expenses:Rent", amount=90000, **kw):
    template = model().Transaction(start, "Landlord", "rent", [posting(account, amount), posting("Assets:Bank")])
    return lib("recurring").Recurring(name, schedule, template, start, **kw)


class M14RecurringTest(StoreBase):
    def test_a_series_round_trips_with_its_limits(self):
        a = rent_series("a-rent")
        b = rent_series("b-gym", "weekly on fri", D(2024, 2, 2), "Expenses:Fun", 1500, end=D(2024, 6, 30), count=10)
        self.s.add_recurring(b)
        self.s.add_recurring(a)
        got = self.s.recurring()
        self.assertEqual([r.name for r in got], ["a-rent", "b-gym"])
        self.assertEqual(got, [a, b])
        self.assertEqual((got[1].end, got[1].count, str(got[1].schedule)), (D(2024, 6, 30), 10, "weekly on fri"))

    def test_names_are_unique_and_removal_needs_an_existing_one(self):
        self.s.add_recurring(rent_series())
        with self.assertRaises(lib("errors").ConflictError):
            self.s.add_recurring(rent_series())
        self.s.remove_recurring("rent")
        self.assertEqual(self.s.recurring(), [])
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.remove_recurring("rent")

    def test_materialize_makes_the_due_transactions(self):
        self.s.add_recurring(rent_series())
        made = self.s.materialize(upto=D(2024, 3, 15))
        self.assertEqual([t.date for t in made], [D(2024, 1, 1), D(2024, 2, 1), D(2024, 3, 1)])
        self.assertEqual([t.id for t in made], [1, 2, 3])
        self.assertTrue(all("recurring" in t.tags and t.payee == "Landlord" for t in made))
        self.assertEqual(made[0].postings[1].amount, money(-90000))
        self.assertEqual(self.s.count_transactions("tag:recurring"), 3)

    def test_materialize_twice_makes_nothing_twice(self):
        self.s.add_recurring(rent_series())
        self.s.materialize(upto=D(2024, 3, 15))
        self.assertEqual(self.s.materialize(upto=D(2024, 3, 15)), [])
        self.assertEqual(self.s.materialize(upto=D(2024, 2, 1)), [])
        later = self.s.materialize(upto=D(2024, 5, 1))
        self.assertEqual([t.date for t in later], [D(2024, 4, 1), D(2024, 5, 1)])
        self.assertEqual(self.s.count_transactions(), 5)
        self.assertEqual(self.s.materialized_through("rent"), D(2024, 5, 1))

    def test_materialized_through_starts_empty(self):
        self.s.add_recurring(rent_series())
        self.assertIsNone(self.s.materialized_through("rent"))
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.materialized_through("nope")

    def test_a_deleted_materialized_transaction_does_not_come_back(self):
        self.s.add_recurring(rent_series())
        self.s.materialize(upto=D(2024, 2, 1))
        self.s.delete_transaction(1)
        self.assertEqual(self.s.materialize(upto=D(2024, 2, 1)), [])
        self.assertEqual(self.s.count_transactions(), 1)

    def test_upto_and_today_the_earlier_one_wins(self):
        self.s.add_recurring(rent_series())
        made = self.s.materialize(upto=D(2024, 3, 15), today=D(2024, 2, 10))
        self.assertEqual([t.date for t in made], [D(2024, 1, 1), D(2024, 2, 1)])
        made = self.s.materialize(today=D(2024, 3, 20))
        self.assertEqual([t.date for t in made], [D(2024, 3, 1)])
        with self.assertRaises(lib("errors").ValidationError):
            self.s.materialize()

    def test_count_and_end_limit_a_series(self):
        self.s.add_recurring(rent_series("three", "daily", D(2024, 1, 1), "Expenses:Fun", 100, count=3))
        self.s.add_recurring(rent_series("ends", "monthly on 15", D(2024, 1, 1), "Expenses:Food", 200, end=D(2024, 2, 20)))
        made = self.s.materialize(upto=D(2024, 12, 31))
        self.assertEqual(sorted((t.date, t.postings[0].account) for t in made),
                         [(D(2024, 1, 1), "Expenses:Fun"), (D(2024, 1, 2), "Expenses:Fun"), (D(2024, 1, 3), "Expenses:Fun"),
                          (D(2024, 1, 15), "Expenses:Food"), (D(2024, 2, 15), "Expenses:Food")])
        self.assertEqual(self.s.materialize(upto=D(2025, 12, 31)), [])

    def test_several_series_are_made_in_date_order(self):
        self.s.add_recurring(rent_series("zeta", "monthly on 1", amount=100))
        self.s.add_recurring(rent_series("alpha", "monthly on 1", account="Expenses:Fun", amount=200))
        made = self.s.materialize(upto=D(2024, 2, 1))
        self.assertEqual([(t.date, t.postings[0].account) for t in made],
                         [(D(2024, 1, 1), "Expenses:Fun"), (D(2024, 1, 1), "Expenses:Rent"),
                          (D(2024, 2, 1), "Expenses:Fun"), (D(2024, 2, 1), "Expenses:Rent")])

    def test_a_series_added_later_starts_from_its_own_start(self):
        self.s.add_recurring(rent_series())
        self.s.materialize(upto=D(2024, 3, 1))
        self.s.add_recurring(rent_series("gym", "monthly on 10", D(2024, 1, 10), "Expenses:Fun", 1500))
        made = self.s.materialize(upto=D(2024, 3, 1))
        self.assertEqual([t.date for t in made], [D(2024, 1, 10), D(2024, 2, 10)])

    def test_a_failing_occurrence_stores_nothing_and_moves_nothing(self):
        self.s.add_account("Assets:Stash")
        self.s.close_account("Assets:Stash", D(2024, 2, 15))
        self.s.add_recurring(rent_series())
        bad = model().Transaction(D(2024, 1, 1), "Move", "", [posting("Assets:Stash", 100), posting("Assets:Bank")])
        self.s.add_recurring(lib("recurring").Recurring("move", "monthly on 1", bad, D(2024, 1, 1)))
        with self.assertRaises(lib("errors").ValidationError):
            self.s.materialize(upto=D(2024, 4, 1))
        self.assertEqual(self.s.count_transactions(), 0)
        self.assertIsNone(self.s.materialized_through("rent"))
        self.assertIsNone(self.s.materialized_through("move"))
        self.assertEqual(len(self.s.materialize(upto=D(2024, 2, 1))), 4)


# ---- rules and settings ------------------------------------------------------------------------------------------

class M14RulesSettingsTest(StoreBase):
    RULES = '# groceries\nwhen payee ~ "market" then account Expenses:Food tag food\nwhen any then account Expenses:Fun\n'

    def test_rules_are_stored_as_given(self):
        self.assertEqual(self.s.rules_text(), "")
        self.assertEqual(len(self.s.rules()), 0)
        self.s.set_rules(self.RULES)
        self.assertEqual(self.s.rules_text(), self.RULES)
        rules = self.s.rules()
        self.assertEqual(len(rules), 2)
        self.assertEqual(rules.apply({"payee": "market", "narration": "", "amount": money(-100), "date": D(2024, 1, 1)}),
                         {"account": "Expenses:Food", "tags": ["food"]})

    def test_setting_rules_replaces_them(self):
        self.s.set_rules(self.RULES)
        self.s.set_rules("when any then account Expenses:Fun\n")
        self.assertEqual(len(self.s.rules()), 1)
        self.s.set_rules("")
        self.assertEqual(len(self.s.rules()), 0)

    def test_invalid_rules_are_refused_and_change_nothing(self):
        self.s.set_rules(self.RULES)
        with self.assertRaises(lib("errors").ParseError):
            self.s.set_rules("when payee ~ then oops\n")
        self.assertEqual(self.s.rules_text(), self.RULES)

    def test_settings_basics(self):
        self.assertIsNone(self.s.get_setting("color"))
        self.assertEqual(self.s.get_setting("color", "red"), "red")
        self.s.set_setting("color", "blue")
        self.s.set_setting("color", "green")
        self.s.set_setting("a", "1")
        self.assertEqual(self.s.get_setting("color"), "green")
        self.assertEqual(self.s.settings(), {"a": "1", "color": "green"})
        self.assertEqual(list(self.s.settings()), ["a", "color"])
        self.s.delete_setting("color")
        self.s.delete_setting("color")
        self.assertIsNone(self.s.get_setting("color"))

    def test_settings_hold_text_only(self):
        for key, value in (("n", 5), ("", "x"), (None, "x"), ("k", None)):
            with self.subTest(key=key, value=value):
                with self.assertRaises(lib("errors").ValidationError):
                    self.s.set_setting(key, value)


# ---- the period lock (after the change) -----------------------------------------------------------------------------

@phase("post")
class M14LockTest(StoreBase):
    def test_no_lock_by_default(self):
        self.assertIsNone(self.s.lock_date())
        self.assertIsNone(self.s.ledger().lock_date)

    def test_set_show_and_clear(self):
        self.s.set_lock(D(2024, 3, 31))
        self.assertEqual(self.s.lock_date(), D(2024, 3, 31))
        self.assertEqual(self.s.ledger().lock_date, D(2024, 3, 31))
        self.s.set_lock(D(2024, 1, 31))
        self.assertEqual(self.s.lock_date(), D(2024, 1, 31))
        self.s.set_lock(None)
        self.assertIsNone(self.s.lock_date())

    def test_the_lock_survives_reopening(self):
        self.s.set_lock(D(2024, 3, 31))
        self.s.close()
        again = self.open()
        self.assertEqual(again.lock_date(), D(2024, 3, 31))

    def test_adding_on_or_before_the_lock_is_refused(self):
        self.s.set_lock(D(2024, 3, 31))
        for day in (D(2024, 3, 31), D(2024, 3, 1), D(2023, 1, 1)):
            with self.subTest(day=day):
                with self.assertRaises(lib("errors").LockedPeriodError) as ctx:
                    self.s.add_transaction(make_tx(day, "Shop", 100))
                self.assertEqual(ctx.exception.code, "locked")
        self.assertEqual(self.s.count_transactions(), 0)
        self.assertEqual(self.s.add_transaction(make_tx(D(2024, 4, 1), "Shop", 100)).id, 1)

    def test_deleting_inside_the_lock_is_refused(self):
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Old", 100))
        self.s.add_transaction(make_tx(D(2024, 4, 5), "New", 100))
        self.s.set_lock(D(2024, 3, 31))
        with self.assertRaises(lib("errors").LockedPeriodError):
            self.s.delete_transaction(1)
        self.assertEqual(self.s.count_transactions(), 2)
        self.s.delete_transaction(2)
        self.s.set_lock(None)
        self.s.delete_transaction(1)
        self.assertEqual(self.s.count_transactions(), 0)

    def test_a_bulk_add_with_one_locked_date_stores_nothing(self):
        self.s.set_lock(D(2024, 3, 31))
        txs = [make_tx(D(2024, 4, 1), "ok", 100), make_tx(D(2024, 3, 30), "locked", 100)]
        with self.assertRaises(lib("errors").LockedPeriodError):
            self.s.add_transactions(txs, keys=["a", "b"])
        self.assertEqual(self.s.count_transactions(), 0)
        self.assertFalse(self.s.has_import_key("a"))

    def test_csv_import_inside_the_lock_stores_nothing(self):
        self.s.set_lock(D(2024, 3, 1))
        with self.assertRaises(lib("errors").LockedPeriodError):
            self.s.import_csv(CSV, PROFILE)
        self.assertEqual(self.s.count_transactions(), 0)
        self.s.set_lock(D(2024, 2, 29))
        self.assertEqual(len(self.s.import_csv(CSV, PROFILE).added), 2)

    def test_materialization_inside_the_lock_stores_nothing(self):
        self.s.add_recurring(rent_series())
        self.s.set_lock(D(2024, 1, 31))
        with self.assertRaises(lib("errors").LockedPeriodError):
            self.s.materialize(upto=D(2024, 3, 1))
        self.assertEqual(self.s.count_transactions(), 0)
        self.assertIsNone(self.s.materialized_through("rent"))
        self.s.set_lock(None)
        self.assertEqual(len(self.s.materialize(upto=D(2024, 3, 1))), 3)

    def test_materialization_after_the_lock_is_fine(self):
        self.s.add_recurring(rent_series("later", start=D(2024, 4, 1)))
        self.s.set_lock(D(2024, 3, 31))
        self.assertEqual(len(self.s.materialize(upto=D(2024, 5, 1))), 2)


class M14CheckBackupTest(StoreBase):
    def test_a_healthy_book_has_no_problems(self):
        self.assertEqual(self.s.check(), [])
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500, tags=("a",)))
        self.assertEqual(self.s.check(), [])

    def test_check_finds_a_posting_of_an_unknown_account(self):
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500))
        raw_exec(self.db, "UPDATE postings SET account = 'Expenses:Ghost' WHERE tx_id = 1 AND seq = 0")
        self.assertTrue(self.s.check())

    def test_check_finds_an_unbalanced_transaction(self):
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500))
        raw_exec(self.db, "UPDATE postings SET minor = 400 WHERE tx_id = 1 AND seq = 0")
        self.assertTrue(self.s.check())

    def test_check_finds_orphans(self):
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500))
        raw_exec(self.db, "DELETE FROM transactions WHERE id = 1")
        self.assertTrue(self.s.check())

    def test_backup_makes_an_independent_copy(self):
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500))
        copy = self.path("copy.db")
        self.s.backup(copy)
        self.s.add_transaction(make_tx(D(2024, 3, 2), "Later", 100))
        other = self.open(path=copy)
        self.assertEqual([t.payee for t in other.transactions()], ["Shop"])
        self.assertEqual(other.version, 4)
        self.assertEqual(other.check(), [])

    def test_backup_never_overwrites(self):
        copy = self.write("copy.db", "precious")
        with self.assertRaises(lib("errors").ConflictError):
            self.s.backup(copy)
        self.assertEqual(self.read("copy.db"), "precious")
        with self.assertRaises(lib("errors").NotFoundError):
            self.s.backup(os.path.join(self.tmp, "nodir", "copy.db"))


# ---- persistence and sharing ---------------------------------------------------------------------------------------

class M14PersistenceTest(StoreBase):
    def test_everything_survives_reopening(self):
        s = self.s
        s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500, tags=("a",)))
        s.set_rate("EUR", "USD", "1.10", D(2024, 1, 1))
        s.add_budget(lib("budgets").Budget("Expenses:Food", "month", money(40000), D(2024, 1, 1)))
        s.add_recurring(rent_series())
        s.set_rules("when any then account Expenses:Fun\n")
        s.set_setting("k", "v")
        s.close_account("Assets:Old", D(2024, 2, 1))
        s.materialize(upto=D(2024, 2, 1))
        s.close()
        t = self.open()
        self.assertEqual(t.version, 4)
        self.assertEqual(t.count_transactions(), 3)
        self.assertEqual(t.get_transaction(1).tags, ("a",))
        self.assertEqual(t.rate_rows(), [("EUR", "USD", D(2024, 1, 1), "1.10")])
        self.assertEqual(len(t.budgets()), 1)
        self.assertEqual(t.recurring(), [rent_series()])
        self.assertEqual(t.materialized_through("rent"), D(2024, 2, 1))
        self.assertEqual(len(t.rules()), 1)
        self.assertEqual(t.get_setting("k"), "v")
        self.assertEqual(t.get_account("Assets:Old").closed, D(2024, 2, 1))
        self.assertEqual(t.materialize(upto=D(2024, 2, 1)), [])

    def test_a_second_store_sees_committed_writes(self):
        other = self.open()
        self.assertEqual(other.count_transactions(), 0)
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500))
        self.assertEqual(other.count_transactions(), 1)
        self.assertEqual(other.get_transaction(1).payee, "Shop")

    def test_two_stores_read_at_the_same_time(self):
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500))
        a, b = self.open(), self.open()
        self.assertEqual(a.transactions(), b.transactions())
        self.assertEqual(a.ledger().balances(), b.ledger().balances())
        a.close()
        self.assertEqual(b.count_transactions(), 1)

    def test_a_failed_write_leaves_other_stores_and_the_file_unchanged(self):
        other = self.open()
        with self.assertRaises(lib("errors").ValidationError):
            self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500, expense="Expenses:Nope"))
        self.assertEqual(other.count_transactions(), 0)
        self.s.add_transaction(make_tx(D(2024, 3, 1), "Shop", 500))
        self.assertEqual(other.count_transactions(), 1)


if __name__ == "__main__":
    unittest.main()

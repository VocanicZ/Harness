"""Module 05: the ledger (tallybook.ledger): validation, balancing, ids, balances. Black box."""
import datetime as dt
import unittest

from support import lib, phase

D = dt.date


def money(minor, cur="USD"):
    return lib("money").Money(minor, cur)


def post(account, minor=None, cur="USD", note=""):
    return lib("model").Posting(account, None if minor is None else money(minor, cur), note)


def tx(day, postings, payee="Shop", narration="", tags=(), flag="*", id=None):
    return lib("model").Transaction(day, payee, narration, list(postings), tags, flag, id)


def pair(day, minor, debit="Expenses:Food", credit="Assets:Cash", cur="USD", **kw):
    """A balanced two-posting transaction moving `minor` from credit to debit."""
    return tx(day, [post(debit, minor, cur), post(credit, -minor, cur)], **kw)


def make(*extra):
    """A ledger over the usual chart (plus any extra account paths)."""
    ledger = lib("ledger").Ledger()
    for path in ("Assets:Bank:Checking", "Assets:Bank:Savings", "Assets:Cash", "Liabilities:Card",
                 "Equity:Opening", "Income:Salary", "Expenses:Food", "Expenses:Rent") + extra:
        ledger.chart.add(path)
    return ledger


class Base(unittest.TestCase):
    def setUp(self):
        self.ledger = make()
        self.LedgerError = lib("ledger").LedgerError

    def fails(self, transaction, *needles):
        """Adding it raises LedgerError, whose message has every needle, and leaves the ledger as it was."""
        before = (len(self.ledger), self.ledger.balances())
        with self.assertRaises(self.LedgerError) as ctx:
            self.ledger.add(transaction)
        for needle in needles:
            self.assertIn(needle, str(ctx.exception))
        self.assertEqual((len(self.ledger), self.ledger.balances()), before)
        return ctx.exception


class M05Construction(Base):
    def test_defaults(self):
        ledger = lib("ledger").Ledger()
        self.assertIsInstance(ledger.chart, lib("accounts").Chart)
        self.assertIsInstance(ledger.rates, lib("currency").RateTable)
        self.assertEqual(len(ledger), 0)
        self.assertEqual(ledger.transactions(), [])
        self.assertEqual(ledger.balances(), {})

    def test_given_chart_and_rates_are_used(self):
        chart, rates = lib("accounts").Chart(), lib("currency").RateTable()
        chart.add("Assets:Cash")
        chart.add("Expenses:Food")
        ledger = lib("ledger").Ledger(chart, rates)
        self.assertIs(ledger.chart, chart)
        self.assertIs(ledger.rates, rates)
        ledger.add(pair(D(2024, 1, 1), 500))
        self.assertEqual(len(ledger), 1)

    def test_empty_given_chart_is_still_used(self):
        chart = lib("accounts").Chart()
        ledger = lib("ledger").Ledger(chart=chart)
        self.assertIs(ledger.chart, chart)

    def test_ledger_error_is_a_validation_error(self):
        errors = lib("errors")
        self.assertTrue(issubclass(self.LedgerError, errors.ValidationError))
        with self.assertRaises(errors.ValidationError) as ctx:
            self.ledger.add(tx(D(2024, 1, 1), [post("Assets:Cash", 5)]))
        self.assertEqual(ctx.exception.code, "validation")


class M05AddBasics(Base):
    def test_add_returns_the_stored_transaction_with_an_id(self):
        stored = self.ledger.add(pair(D(2024, 3, 1), 1250, payee="Cafe", narration="lunch", tags=("food",)))
        self.assertEqual(stored.id, 1)
        self.assertEqual((stored.date, stored.payee, stored.narration, stored.flag),
                         (D(2024, 3, 1), "Cafe", "lunch", "*"))
        self.assertEqual([(p.account, p.amount) for p in stored.postings],
                         [("Expenses:Food", money(1250)), ("Assets:Cash", money(-1250))])
        self.assertEqual(self.ledger.get(1), stored)

    def test_the_transaction_passed_in_is_not_modified(self):
        original = tx(D(2024, 3, 1), [post("Expenses:Food", 700), post("Assets:Cash")], tags=("b", "a", "a"))
        stored = self.ledger.add(original)
        self.assertIsNone(original.id)
        self.assertIsNone(original.postings[1].amount)
        self.assertEqual(len(original.postings), 2)
        self.assertEqual(original.tags, ("b", "a", "a"))
        self.assertIsNot(stored, original)
        self.assertEqual(stored.postings[1].amount, money(-700))

    def test_ids_count_up(self):
        ids = [self.ledger.add(pair(D(2024, 1, d), 100)).id for d in (5, 4, 6)]
        self.assertEqual(ids, [1, 2, 3])
        self.assertEqual(len(self.ledger), 3)

    def test_three_posting_split(self):
        stored = self.ledger.add(tx(D(2024, 2, 1), [post("Expenses:Food", 3000), post("Expenses:Rent", 7000),
                                                    post("Assets:Bank:Checking", -10000)]))
        self.assertEqual(len(stored.postings), 3)

    def test_zero_amount_postings_are_allowed(self):
        self.ledger.add(tx(D(2024, 2, 1), [post("Expenses:Food", 0), post("Assets:Cash", 0)]))
        self.assertEqual(self.ledger.balances(), {})

    def test_postings_to_a_parent_account_are_allowed(self):
        self.ledger.add(pair(D(2024, 2, 1), 100, debit="Assets:Bank", credit="Income:Salary"))
        self.assertEqual(self.ledger.balances(), {"Assets:Bank": {"USD": 100}, "Income:Salary": {"USD": -100}})

    def test_posting_notes_survive(self):
        stored = self.ledger.add(tx(D(2024, 2, 1), [post("Expenses:Food", 100, note="a"), post("Assets:Cash", -100)]))
        self.assertEqual([p.note for p in stored.postings], ["a", ""])

    def test_tags_are_sorted_deduplicated_and_a_tuple(self):
        stored = self.ledger.add(pair(D(2024, 1, 1), 100, tags=("trip-2024", "a_b", "Zed", "a_b", "food")))
        self.assertEqual(stored.tags, ("Zed", "a_b", "food", "trip-2024"))
        self.assertIsInstance(stored.tags, tuple)

    def test_flags(self):
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 1), 100, flag="!")).flag, "!")
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 1), 100)).flag, "*")

    def test_basic_field_rules(self):
        day = D(2024, 1, 1)
        self.fails(pair("2024-01-01", 100))
        self.fails(pair(dt.datetime(2024, 1, 1, 12, 0), 100))
        self.fails(pair(None, 100))
        self.fails(pair(day, 100, flag="?"))
        self.fails(pair(day, 100, flag=""))
        self.fails(pair(day, 100, payee="two\nlines"))
        self.fails(pair(day, 100, narration="two\nlines"))
        self.fails(pair(day, 100, payee=None))
        for tag in ("", "#x", "a b", "-x", "_x", "é", 5):
            with self.subTest(tag=tag):
                self.fails(pair(day, 100, tags=(tag,)))
        self.fails(tx(day, [post("Expenses:Food", 100, note="a\nb"), post("Assets:Cash", -100)]))
        self.fails(tx(day, [post("Expenses:Food", 100), lib("model").Posting("Assets:Cash", -100)]))

    def test_empty_payee_and_narration_are_fine(self):
        stored = self.ledger.add(pair(D(2024, 1, 1), 100, payee=""))
        self.assertEqual((stored.payee, stored.narration), ("", ""))


class M05Postings(Base):
    def test_needs_two_postings(self):
        day = D(2024, 1, 1)
        self.fails(tx(day, []), "at least two")
        self.fails(tx(day, [post("Assets:Cash", 0)]), "at least two")
        self.fails(tx(day, [post("Assets:Cash")]), "at least two")

    def test_unknown_account(self):
        e = self.fails(tx(D(2024, 1, 1), [post("Expenses:Nope", 100), post("Assets:Cash", -100)]),
                       "unknown account", "Expenses:Nope")
        self.assertEqual(e.code, "validation")

    def test_invalid_account_text_is_unknown_too(self):
        self.fails(tx(D(2024, 1, 1), [post("food", 100), post("Assets:Cash", -100)]), "unknown account")

    def test_account_not_yet_open(self):
        self.ledger.chart.add("Assets:New", opened=D(2024, 3, 10))
        self.fails(pair(D(2024, 3, 9), 100, credit="Assets:New"), "is not open on", "2024-03-09", "Assets:New")
        self.ledger.add(pair(D(2024, 3, 10), 100, credit="Assets:New"))

    def test_account_closed(self):
        self.ledger.chart.add("Assets:Old")
        self.ledger.chart.close("Assets:Old", D(2024, 6, 30))
        self.ledger.add(pair(D(2024, 6, 30), 100, credit="Assets:Old"))
        self.fails(pair(D(2024, 7, 1), 100, credit="Assets:Old"), "is not open on", "2024-07-01")
        self.ledger.add(pair(D(2024, 1, 1), 100, credit="Assets:Old"))

    def test_account_currency_restriction(self):
        self.ledger.chart.add("Assets:Euro", currency="EUR")
        self.ledger.add(pair(D(2024, 1, 1), 100, credit="Assets:Euro", cur="EUR", debit="Expenses:Food"))
        self.fails(pair(D(2024, 1, 1), 100, credit="Assets:Euro"), "only holds", "Assets:Euro", "EUR", "USD")

    def test_unrestricted_accounts_take_any_currency(self):
        self.ledger.add(pair(D(2024, 1, 1), 100))
        self.ledger.add(pair(D(2024, 1, 1), 100, cur="JPY"))
        self.assertEqual(self.ledger.balances()["Assets:Cash"], {"JPY": -100, "USD": -100})

    def test_restriction_applies_to_worked_out_amounts(self):
        self.ledger.chart.add("Assets:Euro", currency="EUR")
        self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 500), post("Assets:Euro")]), "only holds")

    def test_failed_add_does_not_use_up_an_id(self):
        self.ledger.add(pair(D(2024, 1, 1), 100))
        self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 100), post("Assets:Cash", -99)]))
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 2), 100)).id, 2)


class M05Balancing(Base):
    def test_unbalanced_names_the_currency_and_the_amount(self):
        self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 1000), post("Assets:Cash", -495)]),
                   "does not balance", "USD 5.05")
        self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 500), post("Assets:Cash", -1000)]),
                   "does not balance", "USD -5.00")

    def test_every_currency_must_balance_alone(self):
        self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 10000), post("Assets:Cash", -9200, "EUR")]),
                   "does not balance", "USD 100.00", "EUR -92.00")

    def test_message_lists_currencies_alphabetically(self):
        e = self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 100), post("Assets:Cash", 300, "EUR"),
                                          post("Assets:Bank:Checking", -50, "CHF")]), "does not balance")
        text = str(e)
        self.assertLess(text.index("CHF"), text.index("EUR"))
        self.assertLess(text.index("EUR"), text.index("USD"))
        self.assertIn("CHF -0.50", text)
        self.assertIn("EUR 3.00", text)
        self.assertIn("USD 1.00", text)

    def test_zero_decimal_currency_in_message(self):
        self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 500, "JPY"), post("Assets:Cash", -200, "JPY")]),
                   "JPY 300")

    def test_two_balanced_currency_pairs_in_one_transaction(self):
        stored = self.ledger.add(tx(D(2024, 1, 1), [
            post("Expenses:Food", 1000), post("Assets:Cash", -1000),
            post("Expenses:Rent", 900, "EUR"), post("Assets:Bank:Checking", -900, "EUR")]))
        self.assertEqual(len(stored.postings), 4)

    def test_currencies_may_net_across_postings(self):
        self.ledger.add(tx(D(2024, 1, 1), [post("Expenses:Food", 300), post("Expenses:Rent", 700),
                                           post("Assets:Cash", -1000)]))
        self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 300), post("Expenses:Rent", 700, "EUR"),
                                      post("Assets:Cash", -1000)]), "EUR")

    def test_one_missing_amount_is_worked_out(self):
        stored = self.ledger.add(tx(D(2024, 1, 1), [post("Expenses:Food", 1250), post("Assets:Cash")]))
        self.assertEqual(stored.postings[1].amount, money(-1250))
        stored = self.ledger.add(tx(D(2024, 1, 2), [post("Assets:Cash"), post("Income:Salary", -250000)]))
        self.assertEqual(stored.postings[0].amount, money(250000))

    def test_missing_amount_keeps_position_account_and_note(self):
        stored = self.ledger.add(tx(D(2024, 1, 1), [post("Expenses:Food", 100), post("Assets:Cash", note="from wallet"),
                                                    post("Expenses:Rent", 200)]))
        self.assertEqual([(p.account, p.amount.minor, p.note) for p in stored.postings],
                         [("Expenses:Food", 100, ""), ("Assets:Cash", -300, "from wallet"), ("Expenses:Rent", 200, "")])

    def test_missing_amount_in_several_currencies(self):
        stored = self.ledger.add(tx(D(2024, 1, 1), [
            post("Expenses:Food", 1000), post("Expenses:Rent", 20000, "JPY"), post("Assets:Cash", note="n"),
            post("Assets:Bank:Checking", 300, "EUR")]))
        self.assertEqual([(p.account, p.amount.minor, p.amount.currency, p.note) for p in stored.postings], [
            ("Expenses:Food", 1000, "USD", ""), ("Expenses:Rent", 20000, "JPY", ""),
            ("Assets:Cash", -300, "EUR", "n"), ("Assets:Cash", -20000, "JPY", "n"),
            ("Assets:Cash", -1000, "USD", "n"), ("Assets:Bank:Checking", 300, "EUR", "")])

    def test_nothing_to_infer(self):
        self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 100), post("Assets:Cash", -100), post("Expenses:Rent")]),
                   "nothing to infer")
        self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 0), post("Assets:Cash")]), "nothing to infer")

    def test_two_missing_amounts(self):
        self.fails(tx(D(2024, 1, 1), [post("Expenses:Food", 100), post("Assets:Cash"), post("Expenses:Rent")]),
                   "more than one posting without an amount")
        self.fails(tx(D(2024, 1, 1), [post("Assets:Cash"), post("Expenses:Rent")]),
                   "more than one posting without an amount")

    def test_big_amounts_are_exact(self):
        big = 10 ** 24 + 7
        stored = self.ledger.add(tx(D(2024, 1, 1), [post("Expenses:Food", big), post("Assets:Cash")]))
        self.assertEqual(stored.postings[1].amount.minor, -big)
        self.assertEqual(self.ledger.balances()["Expenses:Food"], {"USD": big})


class M05Ids(Base):
    def test_explicit_id_is_kept(self):
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 1), 100, id=7)).id, 7)
        self.assertEqual(self.ledger.get(7).id, 7)

    def test_automatic_ids_continue_after_the_highest(self):
        self.ledger.add(pair(D(2024, 1, 1), 100, id=10))
        self.ledger.add(pair(D(2024, 1, 1), 100, id=3))
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 1), 100)).id, 11)

    def test_duplicate_id(self):
        self.ledger.add(pair(D(2024, 1, 1), 100, id=2))
        self.fails(pair(D(2024, 1, 1), 100, id=2), "already exists")

    def test_invalid_ids(self):
        for bad in (0, -1, True, False, "3", 1.0, 2.5):
            with self.subTest(id=bad):
                self.fails(pair(D(2024, 1, 1), 100, id=bad))

    def test_ids_are_never_reused(self):
        self.ledger.add(pair(D(2024, 1, 1), 100))
        self.ledger.add(pair(D(2024, 1, 1), 100))
        self.ledger.remove(2)
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 1), 100)).id, 3)
        self.ledger.remove(3)
        self.ledger.remove(1)
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 1), 100)).id, 4)

    def test_a_removed_explicit_id_can_be_given_again(self):
        self.ledger.add(pair(D(2024, 1, 1), 100, id=5))
        self.ledger.remove(5)
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 1), 100, id=5)).id, 5)


class M05Batches(Base):
    def test_add_many_returns_the_stored_list(self):
        got = self.ledger.add_many([pair(D(2024, 1, 3), 100), pair(D(2024, 1, 1), 200),
                                    tx(D(2024, 1, 2), [post("Expenses:Food", 5), post("Assets:Cash")])])
        self.assertEqual([t.id for t in got], [1, 2, 3])
        self.assertEqual(got[2].postings[1].amount, money(-5))
        self.assertEqual(len(self.ledger), 3)

    def test_add_many_accepts_any_iterable_and_nothing(self):
        self.assertEqual(self.ledger.add_many([]), [])
        got = self.ledger.add_many(pair(D(2024, 1, d), 100) for d in (1, 2))
        self.assertEqual([t.id for t in got], [1, 2])

    def test_add_many_is_all_or_nothing(self):
        self.ledger.add(pair(D(2024, 1, 1), 100))
        batch = [pair(D(2024, 1, 2), 100), pair(D(2024, 1, 3), 100),
                 tx(D(2024, 1, 4), [post("Expenses:Food", 100), post("Assets:Cash", -99)])]
        before = self.ledger.balances()
        with self.assertRaises(self.LedgerError) as ctx:
            self.ledger.add_many(batch)
        self.assertIn("does not balance", str(ctx.exception))
        self.assertEqual(len(self.ledger), 1)
        self.assertEqual(self.ledger.balances(), before)
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 2), 100)).id, 2)

    def test_add_many_judges_later_items_against_earlier_ones(self):
        with self.assertRaises(self.LedgerError) as ctx:
            self.ledger.add_many([pair(D(2024, 1, 1), 100, id=4), pair(D(2024, 1, 2), 100, id=4)])
        self.assertIn("already exists", str(ctx.exception))
        self.assertEqual(len(self.ledger), 0)
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 2), 100)).id, 1)

    def test_replace_keeps_the_id(self):
        self.ledger.add(pair(D(2024, 1, 1), 100))
        self.ledger.add(pair(D(2024, 1, 2), 200))
        new = self.ledger.replace(1, pair(D(2024, 3, 3), 300, payee="Changed", tags=("x",)))
        self.assertEqual((new.id, new.payee, new.date, new.tags), (1, "Changed", D(2024, 3, 3), ("x",)))
        self.assertEqual(self.ledger.get(1), new)
        self.assertEqual([t.id for t in self.ledger.transactions()], [2, 1])
        self.assertEqual(self.ledger.balances()["Expenses:Food"], {"USD": 500})
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 5), 1)).id, 3)

    def test_replace_with_the_same_id_given(self):
        self.ledger.add(pair(D(2024, 1, 1), 100))
        self.assertEqual(self.ledger.replace(1, pair(D(2024, 1, 1), 150, id=1)).id, 1)
        self.fails_replace(1, pair(D(2024, 1, 1), 150, id=2), "")
        self.assertEqual(self.ledger.balances()["Expenses:Food"], {"USD": 150})

    def test_replace_works_out_amounts(self):
        self.ledger.add(pair(D(2024, 1, 1), 100))
        new = self.ledger.replace(1, tx(D(2024, 1, 1), [post("Expenses:Food", 900), post("Assets:Cash")]))
        self.assertEqual(new.postings[1].amount, money(-900))

    def test_a_refused_replace_leaves_the_old_one(self):
        old = self.ledger.add(pair(D(2024, 1, 1), 100))
        self.fails_replace(1, tx(D(2024, 1, 1), [post("Expenses:Food", 100), post("Assets:Cash", -1)]),
                           "does not balance")
        self.fails_replace(1, pair(D(2024, 1, 1), 100, debit="Expenses:Nope"), "unknown account")
        self.assertEqual(self.ledger.get(1), old)
        self.assertEqual(self.ledger.balances()["Expenses:Food"], {"USD": 100})
        self.assertEqual(self.ledger.add(pair(D(2024, 1, 1), 100)).id, 2)

    def test_replace_unknown_id(self):
        with self.assertRaises(lib("errors").NotFoundError):
            self.ledger.replace(5, pair(D(2024, 1, 1), 100))

    def fails_replace(self, tx_id, transaction, needle):
        with self.assertRaises(self.LedgerError) as ctx:
            self.ledger.replace(tx_id, transaction)
        self.assertIn(needle, str(ctx.exception))

    @phase("post")
    def test_add_many_and_replace_honour_the_lock(self):
        errors = lib("errors")
        self.ledger.add(pair(D(2024, 3, 10), 100))
        self.ledger.add(pair(D(2024, 5, 10), 100))
        self.ledger.lock_date = D(2024, 3, 31)
        with self.assertRaises(errors.LockedPeriodError):
            self.ledger.add_many([pair(D(2024, 6, 1), 100), pair(D(2024, 3, 31), 100)])
        self.assertEqual(len(self.ledger), 2)
        with self.assertRaises(errors.LockedPeriodError):
            self.ledger.replace(1, pair(D(2024, 6, 1), 100))
        with self.assertRaises(errors.LockedPeriodError):
            self.ledger.replace(2, pair(D(2024, 2, 1), 100))
        self.assertEqual([t.date for t in self.ledger.transactions()], [D(2024, 3, 10), D(2024, 5, 10)])
        self.assertEqual(self.ledger.replace(2, pair(D(2024, 7, 1), 5)).date, D(2024, 7, 1))


class M05Lookup(Base):
    def test_get_unknown(self):
        errors = lib("errors")
        for bad in (1, 0, -3, "x", None):
            with self.subTest(id=bad):
                with self.assertRaises(errors.NotFoundError) as ctx:
                    self.ledger.get(bad)
                self.assertIn("no transaction", str(ctx.exception))
                self.assertEqual(ctx.exception.code, "not_found")

    def test_remove(self):
        self.ledger.add(pair(D(2024, 1, 1), 100))
        second = self.ledger.add(pair(D(2024, 1, 2), 200))
        removed = self.ledger.remove(1)
        self.assertEqual(removed.id, 1)
        self.assertEqual(len(self.ledger), 1)
        self.assertEqual(self.ledger.transactions(), [second])
        self.assertEqual(self.ledger.balances(), {"Expenses:Food": {"USD": 200}, "Assets:Cash": {"USD": -200}})

    def test_remove_unknown_or_twice(self):
        errors = lib("errors")
        with self.assertRaises(errors.NotFoundError) as ctx:
            self.ledger.remove(9)
        self.assertIn("no transaction", str(ctx.exception))
        self.ledger.add(pair(D(2024, 1, 1), 100))
        self.ledger.remove(1)
        with self.assertRaises(errors.NotFoundError):
            self.ledger.remove(1)

    def test_transactions_sorted_by_date_then_id(self):
        a = self.ledger.add(pair(D(2024, 3, 5), 1))
        b = self.ledger.add(pair(D(2024, 3, 1), 2))
        c = self.ledger.add(pair(D(2024, 3, 5), 3))
        d = self.ledger.add(pair(D(2023, 12, 31), 4))
        self.assertEqual([t.id for t in self.ledger.transactions()], [d.id, b.id, a.id, c.id])

    def test_explicit_ids_order_same_day(self):
        self.ledger.add(pair(D(2024, 3, 5), 1, id=9))
        self.ledger.add(pair(D(2024, 3, 5), 2, id=4))
        self.assertEqual([t.id for t in self.ledger.transactions()], [4, 9])

    def test_postings_iteration(self):
        self.ledger.add(tx(D(2024, 3, 5), [post("Expenses:Food", 10), post("Assets:Cash")]))
        self.ledger.add(pair(D(2024, 3, 1), 20))
        pairs = [(t.id, p.account, p.amount.minor) for t, p in self.ledger.postings()]
        self.assertEqual(pairs, [(2, "Expenses:Food", 20), (2, "Assets:Cash", -20),
                                 (1, "Expenses:Food", 10), (1, "Assets:Cash", -10)])
        self.assertEqual(len(list(self.ledger.postings())), 4)


class M05Balances(Base):
    def setUp(self):
        super().setUp()
        add = self.ledger.add
        add(tx(D(2024, 1, 1), [post("Assets:Bank:Checking", 100000), post("Equity:Opening", -100000)]))
        add(tx(D(2024, 1, 5), [post("Expenses:Food", 4500), post("Assets:Bank:Checking")]))
        add(tx(D(2024, 2, 1), [post("Expenses:Rent", 60000), post("Assets:Bank:Checking")]))
        add(tx(D(2024, 2, 3), [post("Assets:Cash", 20000, "EUR"), post("Assets:Bank:Savings", -20000, "EUR")]))

    def test_balances_have_no_rollup(self):
        self.assertEqual(self.ledger.balances(), {
            "Assets:Bank:Checking": {"USD": 100000 - 4500 - 60000},
            "Assets:Bank:Savings": {"EUR": -20000},
            "Assets:Cash": {"EUR": 20000},
            "Equity:Opening": {"USD": -100000},
            "Expenses:Food": {"USD": 4500},
            "Expenses:Rent": {"USD": 60000}})
        self.assertNotIn("Assets", self.ledger.balances())
        self.assertNotIn("Assets:Bank", self.ledger.balances())

    def test_as_of_is_inclusive(self):
        self.assertEqual(self.ledger.balances(D(2024, 1, 4)), {"Assets:Bank:Checking": {"USD": 100000},
                                                              "Equity:Opening": {"USD": -100000}})
        self.assertEqual(self.ledger.balances(D(2024, 1, 5))["Expenses:Food"], {"USD": 4500})
        self.assertEqual(self.ledger.balances(D(2023, 12, 31)), {})
        self.assertEqual(self.ledger.balances(None), self.ledger.balances(D(2099, 1, 1)))

    def test_zero_balances_are_left_out(self):
        self.ledger.add(pair(D(2024, 3, 1), 4500, debit="Assets:Cash", credit="Expenses:Food"))
        self.assertNotIn("Expenses:Food", self.ledger.balances())
        self.ledger.add(pair(D(2024, 3, 2), 20000, debit="Assets:Bank:Savings", credit="Assets:Cash", cur="EUR"))
        self.assertNotIn("Assets:Bank:Savings", self.ledger.balances())
        self.assertEqual(self.ledger.balances()["Assets:Cash"], {"USD": 4500})

    def test_balances_are_plain_ints_per_currency(self):
        result = self.ledger.balances()
        self.assertIs(type(result), dict)
        self.assertIs(type(result["Assets:Cash"]), dict)
        self.assertIs(type(result["Assets:Cash"]["EUR"]), int)

    def test_rollup_balances(self):
        rolled = self.ledger.rollup_balances()
        self.assertEqual(rolled["Assets:Bank"], {"EUR": -20000, "USD": 35500})
        self.assertEqual(rolled["Assets"], {"USD": 35500})
        self.assertEqual(rolled["Assets:Bank:Checking"], {"USD": 35500})
        self.assertEqual(rolled["Expenses"], {"USD": 64500})
        self.assertEqual(rolled["Equity"], {"USD": -100000})

    def test_rollup_balances_as_of_and_zero(self):
        rolled = self.ledger.rollup_balances(D(2024, 1, 1))
        self.assertEqual(rolled, {"Assets": {"USD": 100000}, "Assets:Bank": {"USD": 100000},
                                  "Assets:Bank:Checking": {"USD": 100000},
                                  "Equity": {"USD": -100000}, "Equity:Opening": {"USD": -100000}})
        self.assertEqual(lib("ledger").Ledger().rollup_balances(), {})

    def test_balance_with_currency_returns_money(self):
        m = self.ledger.balance("Assets:Bank:Checking", currency="USD")
        self.assertEqual(m, money(35500))
        self.assertEqual(self.ledger.balance("Assets:Bank:Checking", currency="EUR"), money(0, "EUR"))
        self.assertIsInstance(m, lib("money").Money)

    def test_balance_without_currency_returns_dict_of_money(self):
        got = self.ledger.balance("Assets:Bank")
        self.assertEqual(got, {"EUR": money(-20000, "EUR"), "USD": money(35500)})
        self.assertEqual(self.ledger.balance("Income:Salary"), {})

    def test_balance_rollup_flag(self):
        self.assertEqual(self.ledger.balance("Assets:Bank", currency="USD"), money(35500))
        self.assertEqual(self.ledger.balance("Assets:Bank", currency="USD", rollup=False), money(0))
        self.assertEqual(self.ledger.balance("Assets:Bank:Checking", rollup=False), {"USD": money(35500)})
        self.assertEqual(self.ledger.balance("Assets:Bank", rollup=False), {})

    def test_balance_as_of(self):
        self.assertEqual(self.ledger.balance("Assets:Bank:Checking", D(2024, 1, 31), "USD"), money(95500))
        self.assertEqual(self.ledger.balance("Assets:Bank:Checking", as_of=D(2024, 1, 1), currency="USD"), money(100000))
        self.assertEqual(self.ledger.balance("Assets:Bank:Checking", as_of=D(2023, 1, 1), currency="USD"), money(0))

    def test_balance_unknown_account(self):
        errors = lib("errors")
        for path in ("Assets:Nope", "nope", ""):
            with self.subTest(path=path):
                with self.assertRaises(errors.NotFoundError):
                    self.ledger.balance(path)

    def test_balance_of_account_without_postings_is_empty(self):
        self.assertEqual(self.ledger.balance("Liabilities:Card"), {})
        self.assertEqual(self.ledger.balance("Liabilities", currency="USD"), money(0))

    def test_whole_segment_rollup(self):
        self.ledger.chart.add("Expenses:Food2")
        self.ledger.add(pair(D(2024, 4, 1), 77, debit="Expenses:Food2"))
        self.assertEqual(self.ledger.balance("Expenses:Food", currency="USD"), money(4500))
        self.assertEqual(self.ledger.balance("Expenses", currency="USD"), money(64500 + 77))

    def test_balances_do_not_depend_on_the_order_added(self):
        first, second = make(), make()
        items = [pair(D(2024, 1, d), d * 100) for d in range(1, 6)]
        for t in items:
            first.add(t)
        for t in reversed(items):
            second.add(t)
        self.assertEqual(first.balances(), second.balances())
        self.assertEqual(first.balances(D(2024, 1, 3)), second.balances(D(2024, 1, 3)))
        self.assertEqual(first.rollup_balances(), second.rollup_balances())

    def test_every_currency_sums_to_zero_over_the_whole_ledger(self):
        totals = {}
        for per_currency in self.ledger.balances().values():
            for code, minor in per_currency.items():
                totals[code] = totals.get(code, 0) + minor
        self.assertEqual({c: m for c, m in totals.items() if m}, {})


class M05PeriodLock(Base):
    @phase("post")
    def test_no_lock_by_default(self):
        self.assertIsNone(self.ledger.lock_date)
        self.assertIsNone(lib("ledger").Ledger().lock_date)

    @phase("post")
    def test_add_on_or_before_the_lock_is_refused(self):
        errors = lib("errors")
        self.ledger.lock_date = D(2024, 3, 31)
        for day in (D(2024, 3, 31), D(2024, 3, 1), D(1999, 1, 1)):
            with self.subTest(day=day):
                with self.assertRaises(errors.LockedPeriodError) as ctx:
                    self.ledger.add(pair(day, 100))
                self.assertEqual(ctx.exception.code, "locked")
                self.assertIn("locked", str(ctx.exception))
        self.assertEqual(len(self.ledger), 0)

    @phase("post")
    def test_add_after_the_lock_is_fine(self):
        self.ledger.lock_date = D(2024, 3, 31)
        self.assertEqual(self.ledger.add(pair(D(2024, 4, 1), 100)).id, 1)

    @phase("post")
    def test_remove_in_a_locked_period_is_refused(self):
        errors = lib("errors")
        old = self.ledger.add(pair(D(2024, 3, 15), 100))
        new = self.ledger.add(pair(D(2024, 4, 15), 100))
        self.ledger.lock_date = D(2024, 3, 31)
        with self.assertRaises(errors.LockedPeriodError) as ctx:
            self.ledger.remove(old.id)
        self.assertEqual(ctx.exception.code, "locked")
        self.assertEqual(len(self.ledger), 2)
        self.ledger.remove(new.id)
        self.assertEqual([t.id for t in self.ledger.transactions()], [old.id])

    @phase("post")
    def test_lock_on_the_day_itself_and_the_day_after(self):
        errors = lib("errors")
        t = self.ledger.add(pair(D(2024, 3, 31), 100))
        self.ledger.lock_date = D(2024, 3, 30)
        self.ledger.remove(t.id)                      # dated after the lock: allowed
        t = self.ledger.add(pair(D(2024, 3, 31), 100))
        self.ledger.lock_date = D(2024, 3, 31)
        with self.assertRaises(errors.LockedPeriodError):
            self.ledger.remove(t.id)

    @phase("post")
    def test_clearing_the_lock(self):
        self.ledger.lock_date = D(2024, 12, 31)
        with self.assertRaises(lib("errors").LockedPeriodError):
            self.ledger.add(pair(D(2024, 2, 1), 100))
        self.ledger.lock_date = None
        self.assertEqual(self.ledger.add(pair(D(2024, 2, 1), 100)).id, 1)

    @phase("post")
    def test_a_refused_add_changes_nothing(self):
        self.ledger.lock_date = D(2024, 3, 31)
        with self.assertRaises(lib("errors").LockedPeriodError):
            self.ledger.add(pair(D(2024, 3, 1), 100))
        self.assertEqual(self.ledger.add(pair(D(2024, 4, 2), 100)).id, 1)
        self.assertEqual(self.ledger.balances(), {"Expenses:Food": {"USD": 100}, "Assets:Cash": {"USD": -100}})

    @phase("post")
    def test_locked_error_is_a_conflict_not_a_validation_error(self):
        errors = lib("errors")
        self.assertTrue(issubclass(errors.LockedPeriodError, errors.ConflictError))
        self.ledger.lock_date = D(2024, 3, 31)
        with self.assertRaises(errors.ConflictError):
            self.ledger.add(pair(D(2024, 3, 1), 100))


if __name__ == "__main__":
    unittest.main()

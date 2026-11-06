"""Module 04: the chart of accounts (tallybook.accounts). Black box."""
import datetime as dt
import unittest

from support import lib

D = dt.date


def acc():
    return lib("accounts")


def paths(accounts):
    return [a.path for a in accounts]


def sample_chart():
    chart = acc().Chart()
    for path in ("Assets:Bank:Checking", "Assets:Bank:Savings", "Assets:Cash", "Liabilities:Card",
                 "Equity:Opening", "Income:Salary", "Expenses:Food:Groceries", "Expenses:Food:Dining",
                 "Expenses:Rent", "Expenses:Fun"):
        chart.add(path)
    return chart


class M04Paths(unittest.TestCase):
    def test_valid_paths(self):
        for text in ("Assets", "Expenses", "Assets:Bank", "Assets:Bank:Checking", "Expenses:Food-and_Drink",
                     "Assets:Bank2:Checking", "Income:A", "Liabilities:Card_1:X-9", "Equity:Opening"):
            with self.subTest(text=text):
                self.assertIs(acc().valid_path(text), True)

    def test_invalid_paths(self):
        for text in ("", "assets:Bank", "Assets:bank", "Assets::Bank", "Assets:", ":Assets", "Assets:Bank Account",
                     "Assets:Café", "Savings:Bank", "Savings", "Assets:1Bank", "Assets:_x", "Assets:-x",
                     "Assets:Bank:", "Assets Bank", " Assets", "Assets ", "Assets:Bank\n", "ASSETS", "Asset:Bank"):
            with self.subTest(text=text):
                self.assertIs(acc().valid_path(text), False)

    def test_valid_path_never_raises(self):
        for value in (None, 5, 1.5, b"Assets", ["Assets"], ("Assets",), object(), True):
            with self.subTest(value=value):
                self.assertIs(acc().valid_path(value), False)

    def test_parent_path(self):
        self.assertEqual(acc().parent_path("Assets:Bank:Checking"), "Assets:Bank")
        self.assertEqual(acc().parent_path("Assets:Bank"), "Assets")
        self.assertIsNone(acc().parent_path("Assets"))
        self.assertIsNone(acc().parent_path("Expenses"))

    def test_parent_path_of_invalid_is_a_chart_error(self):
        for text in ("", "assets", "Assets:", "Nope:Bank", None):
            with self.subTest(text=text):
                with self.assertRaises(acc().ChartError):
                    acc().parent_path(text)

    def test_account_type_from_root(self):
        table = {"Assets": "asset", "Liabilities": "liability", "Equity": "equity", "Income": "income",
                 "Expenses": "expense"}
        for root, kind in table.items():
            with self.subTest(root=root):
                self.assertEqual(acc().account_type(root), kind)
                self.assertEqual(acc().account_type(root + ":Deep:Down"), kind)
        with self.assertRaises(acc().ChartError):
            acc().account_type("Savings:Bank")

    def test_error_class_family(self):
        errors = lib("errors")
        self.assertTrue(issubclass(acc().ChartError, errors.ValidationError))
        with self.assertRaises(errors.ValidationError) as ctx:
            acc().Chart().add("bad path")
        self.assertEqual(ctx.exception.code, "validation")


class M04ChartBuilding(unittest.TestCase):
    def setUp(self):
        self.chart = acc().Chart()

    def test_add_returns_account_with_type_from_root(self):
        a = self.chart.add("Expenses:Food", note="eating")
        self.assertEqual((a.path, a.type, a.currency, a.opened, a.closed, a.note),
                         ("Expenses:Food", "expense", None, None, None, "eating"))
        b = self.chart.add("Assets:Bank", currency="EUR", opened=D(2024, 1, 5))
        self.assertEqual((b.type, b.currency, b.opened, b.note), ("asset", "EUR", D(2024, 1, 5), ""))
        self.assertIsInstance(a, lib("model").Account)

    def test_explicit_type_must_agree_with_the_root(self):
        self.assertEqual(self.chart.add("Assets:Cash", type="asset").type, "asset")
        with self.assertRaises(acc().ChartError):
            self.chart.add("Assets:Wallet", type="expense")
        with self.assertRaises(acc().ChartError):
            self.chart.add("Income:Gift", type="liability")
        with self.assertRaises(acc().ChartError):
            self.chart.add("Assets:Wallet", type="savings")
        self.assertFalse(self.chart.exists("Assets:Wallet"))

    def test_bad_paths_are_chart_errors(self):
        for path in ("", "assets", "Assets:bank", "Savings:Bank", "Assets::X", None, 12):
            with self.subTest(path=path):
                with self.assertRaises(acc().ChartError):
                    self.chart.add(path)
        self.assertEqual(self.chart.accounts(), [])

    def test_currency_must_be_known_code(self):
        self.assertEqual(self.chart.add("Assets:A", currency="JPY").currency, "JPY")
        for code in ("usd", "ZZZ", "US", "", 5):
            with self.subTest(code=code):
                with self.assertRaises(acc().ChartError):
                    self.chart.add("Assets:B", currency=code)
        self.assertFalse(self.chart.exists("Assets:B"))

    def test_opened_and_note_types(self):
        for bad in ("2024-01-01", dt.datetime(2024, 1, 1), 20240101):
            with self.subTest(opened=bad):
                with self.assertRaises(acc().ChartError):
                    self.chart.add("Assets:A", opened=bad)
        with self.assertRaises(acc().ChartError):
            self.chart.add("Assets:A", note=5)
        self.assertFalse(self.chart.exists("Assets:A"))

    def test_duplicate_is_a_conflict(self):
        self.chart.add("Assets:Cash")
        with self.assertRaises(acc().ChartError) as ctx:
            self.chart.add("Assets:Cash", currency="USD")
        self.assertEqual(ctx.exception.code, "conflict")
        self.assertIn("already exists", str(ctx.exception))
        self.assertIsNone(self.chart.get("Assets:Cash").currency)
        self.assertEqual(len(self.chart.accounts()), 2)   # Assets and Assets:Cash

    def test_malformed_is_validation_not_conflict(self):
        with self.assertRaises(acc().ChartError) as ctx:
            self.chart.add("nope")
        self.assertEqual(ctx.exception.code, "validation")

    def test_parents_are_created(self):
        self.chart.add("Assets:Bank:Checking")
        self.assertEqual(paths(self.chart.accounts()), ["Assets", "Assets:Bank", "Assets:Bank:Checking"])
        parent = self.chart.get("Assets:Bank")
        self.assertEqual((parent.type, parent.currency, parent.opened, parent.closed, parent.note),
                         ("asset", None, None, None, ""))
        self.chart.add("Expenses")
        self.assertEqual(len(self.chart.accounts()), 4)

    def test_a_created_parent_can_still_be_added(self):
        self.chart.add("Assets:Bank:Checking")
        a = self.chart.add("Assets:Bank", currency="USD", opened=D(2023, 5, 1), note="my bank")
        self.assertEqual((a.path, a.currency, a.opened, a.note), ("Assets:Bank", "USD", D(2023, 5, 1), "my bank"))
        self.assertEqual(self.chart.get("Assets:Bank").currency, "USD")
        self.assertEqual(len(self.chart.accounts()), 3)
        with self.assertRaises(acc().ChartError) as ctx:
            self.chart.add("Assets:Bank")
        self.assertEqual(ctx.exception.code, "conflict")

    def test_failed_add_creates_no_parents(self):
        with self.assertRaises(acc().ChartError):
            self.chart.add("Assets:Bank:Checking", currency="ZZZ")
        self.assertEqual(self.chart.accounts(), [])

    def test_chart_has_no_len_surprise(self):
        # `in` works like exists()
        self.chart.add("Assets:Cash")
        self.assertIn("Assets:Cash", self.chart)
        self.assertNotIn("Assets:Nope", self.chart)


class M04ChartLookup(unittest.TestCase):
    def setUp(self):
        self.chart = sample_chart()

    def test_get_and_exists(self):
        self.assertEqual(self.chart.get("Assets:Cash").path, "Assets:Cash")
        self.assertTrue(self.chart.exists("Assets:Bank"))      # a parent made by add
        self.assertTrue(self.chart.exists("Assets"))
        self.assertFalse(self.chart.exists("Assets:Nope"))

    def test_get_unknown_is_not_found(self):
        errors = lib("errors")
        for path in ("Assets:Nope", "bad path", "", None):
            with self.subTest(path=path):
                with self.assertRaises(errors.NotFoundError) as ctx:
                    self.chart.get(path)
                self.assertEqual(ctx.exception.code, "not_found")
                self.assertIn("no such account", str(ctx.exception))

    def test_exists_never_raises(self):
        for value in (None, 5, "", "bad path", ["Assets"], {}, object()):
            with self.subTest(value=value):
                self.assertIs(self.chart.exists(value), False)

    def test_accounts_sorted_by_segments(self):
        chart = acc().Chart()
        for path in ("Assets:Bank2", "Assets:Bank:Checking", "Assets:Bank", "Assets-X", "Assets:Zed", "Assets:Abc"):
            if path != "Assets-X":
                chart.add(path)
        self.assertEqual(paths(chart.accounts()),
                         ["Assets", "Assets:Abc", "Assets:Bank", "Assets:Bank:Checking", "Assets:Bank2", "Assets:Zed"])

    def test_accounts_full_listing(self):
        self.assertEqual(paths(self.chart.accounts()), [
            "Assets", "Assets:Bank", "Assets:Bank:Checking", "Assets:Bank:Savings", "Assets:Cash",
            "Equity", "Equity:Opening", "Expenses", "Expenses:Food", "Expenses:Food:Dining",
            "Expenses:Food:Groceries", "Expenses:Fun", "Expenses:Rent", "Income", "Income:Salary",
            "Liabilities", "Liabilities:Card"])

    def test_children(self):
        self.assertEqual(paths(self.chart.children("Expenses")),
                         ["Expenses:Food", "Expenses:Fun", "Expenses:Rent"])
        self.assertEqual(paths(self.chart.children("Assets:Bank")), ["Assets:Bank:Checking", "Assets:Bank:Savings"])
        self.assertEqual(self.chart.children("Expenses:Rent"), [])

    def test_descendants(self):
        self.assertEqual(paths(self.chart.descendants("Expenses:Food")),
                         ["Expenses:Food:Dining", "Expenses:Food:Groceries"])
        self.assertEqual(paths(self.chart.descendants("Assets")), [
            "Assets:Bank", "Assets:Bank:Checking", "Assets:Bank:Savings", "Assets:Cash"])
        self.assertEqual(self.chart.descendants("Assets:Cash"), [])

    def test_descendants_use_whole_segments(self):
        chart = acc().Chart()
        chart.add("Expenses:Food")
        chart.add("Expenses:Foods")
        chart.add("Expenses:Food:Extra")
        self.assertEqual(paths(chart.descendants("Expenses:Food")), ["Expenses:Food:Extra"])
        self.assertEqual(paths(chart.children("Expenses:Food")), ["Expenses:Food:Extra"])

    def test_is_leaf(self):
        self.assertTrue(self.chart.is_leaf("Assets:Cash"))
        self.assertTrue(self.chart.is_leaf("Expenses:Food:Dining"))
        self.assertFalse(self.chart.is_leaf("Assets"))
        self.assertFalse(self.chart.is_leaf("Expenses:Food"))

    def test_unknown_paths_are_not_found(self):
        errors = lib("errors")
        for method in (self.chart.children, self.chart.descendants, self.chart.is_leaf, self.chart.get):
            with self.subTest(method=method.__name__):
                with self.assertRaises(errors.NotFoundError):
                    method("Assets:Nope")
        with self.assertRaises(errors.NotFoundError):
            self.chart.is_open("Assets:Nope", D(2024, 1, 1))
        with self.assertRaises(errors.NotFoundError):
            self.chart.close("Assets:Nope", D(2024, 1, 1))


class M04OpenClose(unittest.TestCase):
    def setUp(self):
        self.chart = acc().Chart()

    def test_no_dates_means_always_open(self):
        self.chart.add("Assets:Cash")
        for day in (D(1900, 1, 1), D(2024, 6, 1), D(2999, 12, 31)):
            with self.subTest(day=day):
                self.assertIs(self.chart.is_open("Assets:Cash", day), True)

    def test_opened_is_inclusive(self):
        self.chart.add("Assets:Bank", opened=D(2024, 3, 10))
        self.assertIs(self.chart.is_open("Assets:Bank", D(2024, 3, 9)), False)
        self.assertIs(self.chart.is_open("Assets:Bank", D(2024, 3, 10)), True)
        self.assertIs(self.chart.is_open("Assets:Bank", D(2024, 3, 11)), True)

    def test_closing_day_is_the_last_usable_day(self):
        self.chart.add("Assets:Bank")
        a = self.chart.close("Assets:Bank", D(2024, 6, 30))
        self.assertEqual(a.closed, D(2024, 6, 30))
        self.assertIs(self.chart.is_open("Assets:Bank", D(2024, 6, 29)), True)
        self.assertIs(self.chart.is_open("Assets:Bank", D(2024, 6, 30)), True)
        self.assertIs(self.chart.is_open("Assets:Bank", D(2024, 7, 1)), False)
        self.assertEqual(self.chart.get("Assets:Bank").closed, D(2024, 6, 30))

    def test_close_updates_the_record_already_handed_out(self):
        a = self.chart.add("Assets:Bank")
        self.chart.close("Assets:Bank", D(2024, 1, 31))
        self.assertEqual(a.closed, D(2024, 1, 31))

    def test_open_and_close_window(self):
        self.chart.add("Assets:Bank", opened=D(2024, 1, 1))
        self.chart.close("Assets:Bank", D(2024, 12, 31))
        flags = [self.chart.is_open("Assets:Bank", D(2023, 12, 31)), self.chart.is_open("Assets:Bank", D(2024, 1, 1)),
                 self.chart.is_open("Assets:Bank", D(2024, 12, 31)), self.chart.is_open("Assets:Bank", D(2025, 1, 1))]
        self.assertEqual(flags, [False, True, True, False])

    def test_close_on_the_opening_day_is_allowed(self):
        self.chart.add("Assets:Bank", opened=D(2024, 5, 5))
        self.chart.close("Assets:Bank", D(2024, 5, 5))
        self.assertIs(self.chart.is_open("Assets:Bank", D(2024, 5, 5)), True)
        self.assertIs(self.chart.is_open("Assets:Bank", D(2024, 5, 6)), False)

    def test_close_before_opening_is_an_error(self):
        self.chart.add("Assets:Bank", opened=D(2024, 5, 5))
        with self.assertRaises(acc().ChartError):
            self.chart.close("Assets:Bank", D(2024, 5, 4))
        self.assertIsNone(self.chart.get("Assets:Bank").closed)

    def test_close_twice_is_an_error(self):
        self.chart.add("Assets:Bank")
        self.chart.close("Assets:Bank", D(2024, 5, 5))
        with self.assertRaises(acc().ChartError) as ctx:
            self.chart.close("Assets:Bank", D(2024, 8, 8))
        self.assertIn("already closed", str(ctx.exception))
        self.assertEqual(self.chart.get("Assets:Bank").closed, D(2024, 5, 5))

    def test_close_needs_a_real_date(self):
        self.chart.add("Assets:Bank")
        for bad in ("2024-05-05", None, 5, dt.datetime(2024, 5, 5)):
            with self.subTest(on=bad):
                with self.assertRaises(acc().ChartError):
                    self.chart.close("Assets:Bank", bad)
        self.assertIsNone(self.chart.get("Assets:Bank").closed)

    def test_closing_a_parent_leaves_children_alone(self):
        self.chart.add("Assets:Bank:Checking")
        self.chart.close("Assets:Bank", D(2024, 5, 5))
        self.assertIsNone(self.chart.get("Assets:Bank:Checking").closed)
        self.assertIs(self.chart.is_open("Assets:Bank:Checking", D(2030, 1, 1)), True)
        self.assertIs(self.chart.is_open("Assets:Bank", D(2030, 1, 1)), False)


class M04Patterns(unittest.TestCase):
    def setUp(self):
        self.chart = sample_chart()

    def match(self, pattern):
        return paths(self.chart.matches(pattern))

    def test_bare_path_is_the_account_and_below(self):
        self.assertEqual(self.match("Expenses:Food"),
                         ["Expenses:Food", "Expenses:Food:Dining", "Expenses:Food:Groceries"])
        self.assertEqual(self.match("Assets:Cash"), ["Assets:Cash"])
        self.assertEqual(len(self.match("Expenses")), 6)
        self.assertEqual(self.match("Assets:Bank")[0], "Assets:Bank")

    def test_bare_path_uses_whole_segments(self):
        chart = acc().Chart()
        for p in ("Expenses:Food", "Expenses:Foods", "Expenses:Food:X"):
            chart.add(p)
        self.assertEqual(paths(chart.matches("Expenses:Food")), ["Expenses:Food", "Expenses:Food:X"])

    def test_star_is_one_segment(self):
        self.assertEqual(self.match("Expenses:*"), ["Expenses:Food", "Expenses:Fun", "Expenses:Rent"])
        self.assertEqual(self.match("*"), ["Assets", "Equity", "Expenses", "Income", "Liabilities"])
        self.assertEqual(self.match("Assets:*:Checking"), ["Assets:Bank:Checking"])
        self.assertEqual(self.match("*:Food"), ["Expenses:Food"])
        self.assertEqual(self.match("Expenses:*:Dining"), ["Expenses:Food:Dining"])

    def test_double_star_is_one_or_more_segments(self):
        self.assertEqual(self.match("Expenses:**"), [
            "Expenses:Food", "Expenses:Food:Dining", "Expenses:Food:Groceries", "Expenses:Fun", "Expenses:Rent"])
        self.assertEqual(self.match("Assets:**:Checking"), ["Assets:Bank:Checking"])
        self.assertEqual(self.match("**:Dining"), ["Expenses:Food:Dining"])
        self.assertEqual(self.match("Expenses:**:Groceries"), ["Expenses:Food:Groceries"])

    def test_double_star_alone_is_everything(self):
        self.assertEqual(self.match("**"), paths(self.chart.accounts()))

    def test_wildcard_patterns_have_no_implicit_descendants(self):
        self.assertNotIn("Expenses:Food:Dining", self.match("Expenses:*"))
        self.assertNotIn("Expenses", self.match("Expenses:**"))
        self.assertEqual(self.match("Assets:*"), ["Assets:Bank", "Assets:Cash"])

    def test_unmatched_patterns_give_nothing(self):
        for pattern in ("Savings", "Savings:*", "Assets:Nope", "Assets:*:Nope", "Expenses:Food:Dining:Deeper"):
            with self.subTest(pattern=pattern):
                self.assertEqual(self.match(pattern), [])

    def test_matching_is_case_sensitive(self):
        self.assertEqual(self.match("Expenses:FOOD"), [])
        self.assertEqual(self.match("EXPENSES"), [])
        self.assertNotEqual(self.match("Expenses:Food"), [])

    def test_bad_patterns_are_chart_errors(self):
        for pattern in ("", "Expenses::Food", "Expenses:", ":Expenses", "Expenses:food", "Exp*", "Expenses:F*",
                        "***", "Expenses:***", "Expenses:Food Court", "Expenses:Café", None, 5):
            with self.subTest(pattern=pattern):
                with self.assertRaises(acc().ChartError):
                    self.chart.matches(pattern)
                with self.assertRaises(acc().ChartError):
                    acc().path_matches(pattern, "Expenses:Food")

    def test_lower_case_first_segment_is_a_bad_pattern(self):
        with self.assertRaises(acc().ChartError):
            self.chart.matches("expenses")

    def test_path_matches_without_a_chart(self):
        pm = acc().path_matches
        self.assertIs(pm("Expenses", "Expenses:Food:Dining"), True)
        self.assertIs(pm("Expenses:Food", "Expenses:Foods"), False)
        self.assertIs(pm("Expenses:*", "Expenses:Food"), True)
        self.assertIs(pm("Expenses:*", "Expenses:Food:Dining"), False)
        self.assertIs(pm("Expenses:**", "Expenses"), False)
        self.assertIs(pm("Expenses:**", "Expenses:A:B:C"), True)
        self.assertIs(pm("**", "Whatever:Nonexistent"), True)
        self.assertIs(pm("*", "Assets"), True)
        self.assertIs(pm("*", "Assets:Bank"), False)
        self.assertIs(pm("Assets:**:Checking", "Assets:Checking"), False)
        self.assertIs(pm("Assets:**:Checking", "Assets:A:B:Checking"), True)

    def test_matches_is_sorted_like_accounts(self):
        chart = acc().Chart()
        for p in ("Assets:Zed", "Assets:Bank2", "Assets:Bank:Checking", "Assets:Abc"):
            chart.add(p)
        self.assertEqual(paths(chart.matches("Assets:**")),
                         ["Assets:Abc", "Assets:Bank", "Assets:Bank:Checking", "Assets:Bank2", "Assets:Zed"])
        self.assertEqual([type(a).__name__ for a in chart.matches("Assets:*")], ["Account"] * 4)


if __name__ == "__main__":
    unittest.main()

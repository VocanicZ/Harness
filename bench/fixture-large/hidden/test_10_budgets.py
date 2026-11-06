"""Hidden tests of module 10: budgets (tallybook.budgets)."""
import unittest
from datetime import date
from decimal import Decimal

from support import lib, phase

D = date


def money(text):
    return lib("money").Money.parse(text)


def period(text):
    return lib("dates").Period.parse(text)


def make_ledger(spends, rates=None):
    """spends: (date, account, 'amount CUR'); each is balanced against Assets:Bank in the same currency."""
    model = lib("model")
    chart = lib("accounts").Chart()
    ledger = lib("ledger").Ledger(chart, rates)
    for when, account, amount in spends:
        for path in (account, "Assets:Bank"):
            if not chart.exists(path):
                chart.add(path)
        m = money(amount)
        ledger.add(model.Transaction(date=when, payee="shop", narration="",
                                     postings=[model.Posting(account, m), model.Posting("Assets:Bank", -m)]))
    return ledger


def budget(pattern="Expenses:Food", kind="month", amount="400.00 USD", start=D(2024, 1, 1)):
    return lib("budgets").Budget(pattern, kind, money(amount), start)


def status(budgets, ledger, per):
    return lib("budgets").budget_status(budgets, ledger, period(per))


FOOD = [
    (D(2024, 3, 3), "Expenses:Food:Groceries", "250.00 USD"),
    (D(2024, 3, 9), "Expenses:Food:Dining", "90.00 USD"),
    (D(2024, 3, 20), "Expenses:Food:Groceries", "-10.00 USD"),
]


class M10BudgetValue(unittest.TestCase):
    def test_fields_and_equality(self):
        b = budget()
        self.assertEqual((b.pattern, b.period_kind, b.amount, b.start),
                         ("Expenses:Food", "month", money("400.00 USD"), D(2024, 1, 1)))
        self.assertEqual(b, budget())
        self.assertEqual(hash(b), hash(budget()))
        self.assertNotEqual(b, budget(amount="401.00 USD"))
        with self.assertRaises(AttributeError):
            b.pattern = "Expenses"

    def test_each_period_kind_is_accepted(self):
        for kind in ("month", "quarter", "year"):
            with self.subTest(kind=kind):
                self.assertEqual(budget(kind=kind).period_kind, kind)

    def test_bad_period_kinds(self):
        for kind in ("week", "Month", "monthly", "", None, "months"):
            with self.subTest(kind=kind), self.assertRaises(lib("budgets").BudgetError):
                budget(kind=kind)

    def test_amount_must_be_positive_money(self):
        for amount in (money("0.00 USD"), money("-5.00 USD"), 400, "400.00 USD", None):
            with self.subTest(amount=amount), self.assertRaises(lib("budgets").BudgetError):
                lib("budgets").Budget("Expenses:Food", "month", amount, D(2024, 1, 1))
        self.assertEqual(budget(amount="0.01 USD").amount, money("0.01 USD"))

    def test_start_must_be_a_date(self):
        for start in ("2024-01-01", None, 20240101):
            with self.subTest(start=start), self.assertRaises(lib("budgets").BudgetError):
                lib("budgets").Budget("Expenses:Food", "month", money("1.00 USD"), start)

    def test_budget_error_is_a_validation_error(self):
        errors = lib("errors")
        self.assertTrue(issubclass(lib("budgets").BudgetError, errors.ValidationError))
        with self.assertRaises(lib("budgets").BudgetError) as ctx:
            budget(kind="week")
        self.assertEqual(ctx.exception.code, "validation")
        self.assertTrue(ctx.exception.message)

    def test_valid_patterns(self):
        for pattern in ("Expenses", "Expenses:Food", "Expenses:*", "*", "*:Food", "Expenses:*:Dining",
                        "Expenses:Food-2:A_b", "Assets:Bank"):
            with self.subTest(pattern=pattern):
                self.assertEqual(budget(pattern=pattern).pattern, pattern)

    def test_invalid_patterns(self):
        for pattern in ("", "expenses:food", "Expenses:", ":Food", "Expenses::Food", "**", "Expenses:**",
                        "Expenses:Fo*", "Expenses:Food Bar", "Expenses:1Food", None, "Expenses:Food:"):
            with self.subTest(pattern=pattern), self.assertRaises(lib("budgets").BudgetError):
                budget(pattern=pattern)


class M10BudgetStatus(unittest.TestCase):
    def test_basic_line(self):
        (line,) = status([budget()], make_ledger(FOOD), "2024-03")
        self.assertIsInstance(line, lib("budgets").BudgetLine)
        self.assertEqual(line.pattern, "Expenses:Food")
        self.assertEqual(line.period_kind, "month")
        self.assertEqual(line.budget, money("400.00 USD"))
        self.assertEqual(line.actual, money("330.00 USD"))
        self.assertEqual(line.remaining, money("70.00 USD"))
        self.assertEqual(line.percent, Decimal("82.5"))
        self.assertIs(line.over, False)
        self.assertEqual(line.accounts, (("Expenses:Food:Dining", money("90.00 USD")),
                                         ("Expenses:Food:Groceries", money("240.00 USD"))))

    def test_percent_is_a_decimal_with_one_place(self):
        cases = [(FOOD, "340.00 USD", "2024-03", "97.1"), ([], "400.00 USD", "2024-03", "0.0"),
                 ([(D(2024, 3, 1), "Expenses:Food", "400.00 USD")], "400.00 USD", "2024-03", "100.0"),
                 ([(D(2024, 3, 1), "Expenses:Food", "450.00 USD")], "400.00 USD", "2024-03", "112.5"),
                 ([(D(2024, 3, 1), "Expenses:Food", "-10.00 USD")], "400.00 USD", "2024-03", "-2.5"),
                 ([(D(2024, 3, 1), "Expenses:Food", "1.00 USD")], "3.00 USD", "2024-03", "33.3")]
        for spends, amount, per, want in cases:
            with self.subTest(want=want):
                (line,) = status([budget(amount=amount)], make_ledger(spends), per)
                self.assertIsInstance(line.percent, Decimal)
                self.assertEqual(str(line.percent), want)

    def test_overspent(self):
        (line,) = status([budget(amount="300.00 USD")], make_ledger(FOOD), "2024-03")
        self.assertEqual(line.remaining, money("-30.00 USD"))
        self.assertEqual(line.percent, Decimal("110.0"))
        self.assertIs(line.over, True)

    def test_exactly_used_up_is_not_over(self):
        (line,) = status([budget(amount="330.00 USD")], make_ledger(FOOD), "2024-03")
        self.assertIs(line.over, False)
        self.assertEqual(line.remaining, money("0.00 USD"))
        self.assertEqual(line.percent, Decimal("100.0"))

    def test_nothing_spent(self):
        (line,) = status([budget()], make_ledger([]), "2024-03")
        self.assertEqual(line.actual, money("0.00 USD"))
        self.assertEqual(line.remaining, money("400.00 USD"))
        self.assertEqual(line.accounts, ())
        self.assertEqual(line.percent, Decimal("0.0"))
        self.assertIs(line.over, False)

    def test_refund_only_gives_negative_spending(self):
        ledger = make_ledger([(D(2024, 3, 2), "Expenses:Food", "-10.00 USD")])
        (line,) = status([budget()], ledger, "2024-03")
        self.assertEqual(line.actual, money("-10.00 USD"))
        self.assertEqual(line.remaining, money("410.00 USD"))
        self.assertEqual(line.accounts, (("Expenses:Food", money("-10.00 USD")),))

    def test_period_bounds_are_inclusive(self):
        ledger = make_ledger([(D(2024, 2, 29), "Expenses:Food", "1.00 USD"), (D(2024, 3, 1), "Expenses:Food", "2.00 USD"),
                              (D(2024, 3, 31), "Expenses:Food", "4.00 USD"), (D(2024, 4, 1), "Expenses:Food", "8.00 USD")])
        (line,) = status([budget()], ledger, "2024-03")
        self.assertEqual(line.actual, money("6.00 USD"))
        (line,) = status([budget()], ledger, "2024-03-01..2024-03-01")
        self.assertEqual(line.actual, money("2.00 USD"))

    def test_accounts_leave_out_zero_and_sort_as_text(self):
        ledger = make_ledger([(D(2024, 3, 1), "Expenses:Food:Zed", "5.00 USD"), (D(2024, 3, 2), "Expenses:Food:Zed", "-5.00 USD"),
                              (D(2024, 3, 3), "Expenses:Food:Bar", "3.00 USD"), (D(2024, 3, 4), "Expenses:Food:Alpha", "1.00 USD"),
                              (D(2024, 3, 5), "Expenses:Food-X", "9.00 USD")])
        (line,) = status([budget(pattern="Expenses")], ledger, "2024-03")
        self.assertEqual([a for a, _ in line.accounts], ["Expenses:Food-X", "Expenses:Food:Alpha", "Expenses:Food:Bar"])
        self.assertEqual(line.actual, money("13.00 USD"))

    def test_pattern_matching(self):
        spends = [(D(2024, 3, 1), "Expenses", "1.00 USD"), (D(2024, 3, 1), "Expenses:Food", "2.00 USD"),
                  (D(2024, 3, 1), "Expenses:Food:Dining", "4.00 USD"), (D(2024, 3, 1), "Expenses:Foods", "8.00 USD"),
                  (D(2024, 3, 1), "Expenses:Fun:Dining", "16.00 USD"), (D(2024, 3, 1), "Expenses:Fun", "32.00 USD"),
                  (D(2024, 3, 1), "Expenses:Food:Dining:Cafe", "64.00 USD")]
        ledger = make_ledger(spends)
        cases = {"Expenses:Food": "70.00", "Expenses": "127.00", "Expenses:*": "126.00", "Expenses:*:Dining": "84.00",
                 "*": "127.00", "*:Food": "70.00", "Expenses:Food:Dining": "68.00", "Expenses:Fu": "0.00",
                 "Expenses:Fun:*": "16.00", "Expenses:Food:Dining:Cafe": "64.00"}
        for pattern, want in cases.items():
            with self.subTest(pattern=pattern):
                (line,) = status([budget(pattern=pattern)], ledger, "2024-03")
                self.assertEqual(line.actual, money(want + " USD"))

    def test_only_expense_accounts_count(self):
        ledger = make_ledger([(D(2024, 3, 1), "Income:Salary", "-500.00 USD"), (D(2024, 3, 1), "Liabilities:Card", "-5.00 USD"),
                              (D(2024, 3, 2), "Expenses:Food", "7.00 USD")])
        for pattern, want in (("Income", "0.00"), ("Assets", "0.00"), ("Liabilities", "0.00"), ("*", "7.00")):
            with self.subTest(pattern=pattern):
                (line,) = status([budget(pattern=pattern)], ledger, "2024-03")
                self.assertEqual(line.actual, money(want + " USD"))

    def test_other_currencies_are_ignored_not_converted(self):
        rates = lib("currency").RateTable()
        rates.set("EUR", "USD", "1.1", D(2024, 1, 1))
        ledger = make_ledger([(D(2024, 3, 1), "Expenses:Food", "10.00 USD"), (D(2024, 3, 2), "Expenses:Food", "99.00 EUR"),
                              (D(2024, 3, 3), "Expenses:Food", "500 JPY")], rates)
        (line,) = status([budget()], ledger, "2024-03")
        self.assertEqual(line.actual, money("10.00 USD"))
        self.assertEqual(line.accounts, (("Expenses:Food", money("10.00 USD")),))
        (line,) = status([budget(amount="100 JPY")], ledger, "2024-03")
        self.assertEqual((line.budget, line.actual), (money("100 JPY"), money("500 JPY")))
        self.assertIs(line.over, True)

    def test_multiple_budgets_count_the_same_spending(self):
        budgets = [budget(pattern="Expenses:Food", amount="400.00 USD"), budget(pattern="Expenses", amount="1000.00 USD"),
                   budget(pattern="Expenses:Food:Dining", amount="100.00 USD")]
        lines = status(budgets, make_ledger(FOOD), "2024-03")
        self.assertEqual([(l.pattern, l.actual.amount_str()) for l in lines],
                         [("Expenses", "330.00"), ("Expenses:Food", "330.00"), ("Expenses:Food:Dining", "90.00")])
        self.assertEqual([str(l.percent) for l in lines], ["33.0", "82.5", "90.0"])

    def test_equal_budgets_are_not_merged(self):
        lines = status([budget(), budget()], make_ledger(FOOD), "2024-03")
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[0], lines[1])

    def test_line_order(self):
        budgets = [budget("Expenses:Fun", "year"), budget("Expenses:Food", "year"), budget("Expenses:Food", "quarter"),
                   budget("Expenses:Food", "month", start=D(2024, 2, 1)), budget("Expenses:Food", "month", start=D(2024, 1, 1)),
                   budget("Expenses:Food", "month", amount="1.00 USD", start=D(2024, 1, 1))]
        lines = status(budgets, make_ledger([]), "2024-03")
        self.assertEqual([(l.pattern, l.period_kind) for l in lines],
                         [("Expenses:Food", "month")] * 3 + [("Expenses:Food", "quarter"), ("Expenses:Food", "year"),
                                                           ("Expenses:Fun", "year")])
        self.assertEqual([l.budget.amount_str() for l in lines[:3]], ["400.00", "1.00", "400.00"])

    def test_empty_inputs(self):
        self.assertEqual(status([], make_ledger(FOOD), "2024-03"), [])

    def test_ledger_is_not_changed(self):
        ledger = make_ledger(FOOD)
        before = [(t.id, t.date, t.postings) for t in ledger.transactions()]
        status([budget()], ledger, "2024-03")
        self.assertEqual(before, [(t.id, t.date, t.postings) for t in ledger.transactions()])

    def test_line_is_immutable(self):
        (line,) = status([budget()], make_ledger(FOOD), "2024-03")
        with self.assertRaises(AttributeError):
            line.percent = Decimal("1.0")

    def test_to_dict(self):
        (line,) = status([budget()], make_ledger(FOOD), "2024-03")
        self.assertEqual(line.to_dict(), {
            "pattern": "Expenses:Food", "period_kind": "month",
            "budget": {"amount": "400.00", "currency": "USD"},
            "actual": {"amount": "330.00", "currency": "USD"},
            "remaining": {"amount": "70.00", "currency": "USD"},
            "percent": "82.5", "over": False,
            "accounts": [{"account": "Expenses:Food:Dining", "amount": {"amount": "90.00", "currency": "USD"}},
                         {"account": "Expenses:Food:Groceries", "amount": {"amount": "240.00", "currency": "USD"}}]})


class M10Allowance(unittest.TestCase):
    def allowance(self, kind, amount, per, start=D(2024, 1, 1)):
        lines = status([budget(kind=kind, amount=amount, start=start)], make_ledger([]), per)
        return str(lines[0].budget) if lines else None

    def test_allowance_table(self):
        rows = [("month", "300.00 USD", "2024-03", "300.00 USD"),
                ("month", "300.00 USD", "2024-03-01..2024-03-15", "145.16 USD"),
                ("month", "100.00 USD", "2024-Q1", "300.00 USD"),
                ("month", "100.00 USD", "2024-01-15..2024-02-14", "103.11 USD"),
                ("quarter", "900.00 USD", "2024-02", "286.81 USD"),
                ("quarter", "900.00 USD", "2024-Q1", "900.00 USD"),
                ("quarter", "900.00 USD", "2024", "3600.00 USD"),
                ("year", "1200.00 USD", "2024-Q1", "298.36 USD"),
                ("year", "1200.00 USD", "2024", "1200.00 USD"),
                ("year", "1200 JPY", "2024-03", "102 JPY"),
                ("month", "400.00 USD", "2024-02", "400.00 USD"),
                ("month", "400.00 USD", "2024-02-29..2024-02-29", "13.79 USD"),
                ("month", "400 JPY", "2024-01", "400 JPY")]
        for kind, amount, per, want in rows:
            with self.subTest(kind=kind, amount=amount, period=per):
                self.assertEqual(self.allowance(kind, amount, per), want)

    def test_start_chooses_the_first_whole_period(self):
        self.assertEqual(self.allowance("month", "100.00 USD", "2024-Q1", start=D(2024, 3, 20)), "100.00 USD")
        self.assertEqual(self.allowance("month", "100.00 USD", "2024-Q1", start=D(2024, 2, 1)), "200.00 USD")
        self.assertEqual(self.allowance("month", "100.00 USD", "2024-03", start=D(2024, 3, 31)), "100.00 USD")
        self.assertEqual(self.allowance("quarter", "900.00 USD", "2024", start=D(2024, 5, 5)), "2700.00 USD")
        self.assertEqual(self.allowance("year", "1200.00 USD", "2024-06", start=D(2024, 12, 31)), "98.36 USD")
        self.assertIsNone(self.allowance("year", "1200.00 USD", "2024-06", start=D(2025, 1, 1)))

    def test_budget_not_yet_in_force_has_no_line(self):
        self.assertIsNone(self.allowance("month", "100.00 USD", "2024-02", start=D(2024, 3, 1)))
        self.assertIsNone(self.allowance("month", "100.00 USD", "2024-03-01..2024-03-31", start=D(2024, 4, 1)))
        self.assertIsNone(self.allowance("year", "100.00 USD", "2023-12", start=D(2024, 1, 1)))
        self.assertEqual(self.allowance("year", "1200.00 USD", "2023-12-01..2024-01-31"), "101.64 USD")

    def test_start_inside_the_asked_period(self):
        lines = status([budget(start=D(2024, 3, 10)), budget(pattern="Expenses", start=D(2024, 5, 1))],
                       make_ledger(FOOD), "2024-03-01..2024-04-30")
        self.assertEqual([(l.pattern, str(l.budget)) for l in lines], [("Expenses:Food", "800.00 USD")])

    def test_leap_and_common_years(self):
        self.assertEqual(self.allowance("year", "1200.00 USD", "2028-02"), "95.08 USD")
        self.assertEqual(self.allowance("year", "3650.00 USD", "2025-01-01..2025-01-10"), "100.00 USD")

    def test_zero_allowance_percent(self):
        none = status([budget(amount="0.04 USD")], make_ledger([]), "2024-03-05..2024-03-05")
        self.assertEqual(str(none[0].budget), "0.00 USD")
        self.assertEqual(str(none[0].percent), "0.0")
        spent = status([budget(amount="0.04 USD")], make_ledger([(D(2024, 3, 5), "Expenses:Food", "1.00 USD")]),
                       "2024-03-05..2024-03-05")
        self.assertEqual(str(spent[0].percent), "100.0")
        self.assertIs(spent[0].over, True)


class M10Rounding(unittest.TestCase):
    def percent(self, spent, allowed):
        ledger = make_ledger([(D(2024, 3, 1), "Expenses:Food", spent)])
        return str(status([budget(amount=allowed)], ledger, "2024-03")[0].percent)

    def test_untied_percent_rounds_to_nearest(self):
        for spent, allowed, want in (("1.00 USD", "3.00 USD", "33.3"), ("2.00 USD", "3.00 USD", "66.7"),
                                     ("0.01 USD", "3.00 USD", "0.3"), ("-2.00 USD", "3.00 USD", "-66.7")):
            with self.subTest(spent=spent):
                self.assertEqual(self.percent(spent, allowed), want)

    @phase("pre")
    def test_percent_ties_pre(self):
        for spent, want in (("0.01 USD", "0.3"), ("0.05 USD", "1.3"), ("0.03 USD", "0.8"), ("0.07 USD", "1.8"),
                            ("-0.01 USD", "-0.3"), ("-0.05 USD", "-1.3")):
            with self.subTest(spent=spent):
                self.assertEqual(self.percent(spent, "4.00 USD"), want)

    @phase("post")
    def test_percent_ties_post(self):
        for spent, want in (("0.01 USD", "0.2"), ("0.05 USD", "1.2"), ("0.03 USD", "0.8"), ("0.07 USD", "1.8"),
                            ("-0.01 USD", "-0.2"), ("-0.05 USD", "-1.2")):
            with self.subTest(spent=spent):
                self.assertEqual(self.percent(spent, "4.00 USD"), want)

    @phase("pre")
    def test_allowance_ties_pre(self):
        # 0.14 USD a month over one February day (1/28 of a month) is half a cent
        lines = status([budget(amount="0.14 USD", start=D(2023, 1, 1))], make_ledger([]), "2023-02-01..2023-02-01")
        self.assertEqual(str(lines[0].budget), "0.01 USD")
        lines = status([budget(amount="0.42 USD", start=D(2023, 1, 1))], make_ledger([]), "2023-02-01..2023-02-01")
        self.assertEqual(str(lines[0].budget), "0.02 USD")

    @phase("post")
    def test_allowance_ties_post(self):
        lines = status([budget(amount="0.14 USD", start=D(2023, 1, 1))], make_ledger([]), "2023-02-01..2023-02-01")
        self.assertEqual(str(lines[0].budget), "0.00 USD")
        lines = status([budget(amount="0.42 USD", start=D(2023, 1, 1))], make_ledger([]), "2023-02-01..2023-02-01")
        self.assertEqual(str(lines[0].budget), "0.02 USD")


if __name__ == "__main__":
    unittest.main()

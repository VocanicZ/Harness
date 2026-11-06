"""Hidden tests of module 12: reports (tallybook.reports)."""
import json
import unittest
from datetime import date

from support import lib, phase

D = date


def money(text):
    return lib("money").Money.parse(text)


def usd(text):
    return {"amount": text, "currency": "USD"}


def cur(text, code):
    return {"amount": text, "currency": code}


def period(text):
    return lib("dates").Period.parse(text)


def reports():
    return lib("reports")


def rate_table(*rates):
    table = lib("currency").RateTable()
    for src, dst, rate, on in rates:
        table.set(src, dst, rate, on)
    return table


def build(rows, extra_accounts=(), rates=None):
    """rows: (date, payee, [(account, 'amount CUR'), ...]) or the same plus an explicit id."""
    model = lib("model")
    chart = lib("accounts").Chart()
    ledger = lib("ledger").Ledger(chart, rates)
    for row in rows:
        when, payee, postings = row[:3]
        for account, _ in postings:
            if not chart.exists(account):
                chart.add(account)
        ledger.add(model.Transaction(date=when, payee=payee, narration="",
                                     postings=[model.Posting(a, money(m)) for a, m in postings],
                                     id=row[3] if len(row) > 3 else None))
    for account in extra_accounts:
        if not chart.exists(account):
            chart.add(account)
    return ledger


SAMPLE_ROWS = [
    (D(2024, 1, 1), "Opening", [("Assets:Bank:Checking", "1000.00 USD"), ("Equity:Opening", "-1000.00 USD")]),
    (D(2024, 3, 1), "Acme", [("Assets:Bank:Checking", "2500.00 USD"), ("Income:Salary", "-2500.00 USD")]),
    (D(2024, 3, 2), "Market", [("Expenses:Food", "42.50 USD"), ("Assets:Bank:Checking", "-42.50 USD")]),
    (D(2024, 3, 5), "Landlord", [("Expenses:Rent", "900.00 USD"), ("Liabilities:Card", "-900.00 USD")]),
    (D(2024, 3, 10), "ATM", [("Assets:Cash", "100.00 USD"), ("Assets:Bank:Checking", "-100.00 USD")]),
    (D(2024, 3, 12), "Corner", [("Expenses:Food", "12.00 USD"), ("Assets:Cash", "-12.00 USD")]),
    (D(2024, 4, 2), "Card payoff", [("Liabilities:Card", "900.00 USD"), ("Assets:Bank:Checking", "-900.00 USD")]),
    (D(2024, 4, 3), "Market", [("Expenses:Food", "30.00 USD"), ("Assets:Bank:Checking", "-30.00 USD")]),
]

# a book in two currencies
MC_ROWS = [
    (D(2024, 1, 1), "Opening", [("Assets:Bank", "100.00 USD"), ("Equity:Opening", "-100.00 USD")]),
    (D(2024, 1, 2), "Opening EUR", [("Assets:Bank", "50.00 EUR"), ("Equity:Opening", "-50.00 EUR")]),
    (D(2024, 2, 1), "Pay", [("Assets:Bank", "200.00 EUR"), ("Income:Salary", "-200.00 EUR")]),
    (D(2024, 2, 2), "Shop", [("Expenses:Food", "30.00 USD"), ("Assets:Bank", "-30.00 USD")]),
]


def sample():
    return build(SAMPLE_ROWS)


def multi(with_rates=True):
    rates = rate_table(("EUR", "USD", "1.1", D(2024, 1, 1)), ("EUR", "USD", "1.2", D(2024, 2, 15))) if with_rates else None
    return build(MC_ROWS, rates=rates)


MARCH = "2024-03"


class M12TrialBalance(unittest.TestCase):
    def test_sample(self):
        rep = reports().trial_balance(sample(), D(2024, 3, 31))
        self.assertEqual(rep, {
            "report": "trial_balance", "as_of": "2024-03-31",
            "accounts": [
                {"account": "Assets:Bank:Checking", "type": "asset", "debit": usd("3357.50"), "credit": None},
                {"account": "Assets:Cash", "type": "asset", "debit": usd("88.00"), "credit": None},
                {"account": "Equity:Opening", "type": "equity", "debit": None, "credit": usd("1000.00")},
                {"account": "Expenses:Food", "type": "expense", "debit": usd("54.50"), "credit": None},
                {"account": "Expenses:Rent", "type": "expense", "debit": usd("900.00"), "credit": None},
                {"account": "Income:Salary", "type": "income", "debit": None, "credit": usd("2500.00")},
                {"account": "Liabilities:Card", "type": "liability", "debit": None, "credit": usd("900.00")}],
            "totals": [{"currency": "USD", "debit": usd("4400.00"), "credit": usd("4400.00"), "balanced": True}]})

    def test_as_of_cuts_later_postings(self):
        rep = reports().trial_balance(sample(), D(2024, 3, 1))
        self.assertEqual([(a["account"], (a["debit"] or a["credit"])["amount"]) for a in rep["accounts"]],
                         [("Assets:Bank:Checking", "3500.00"), ("Equity:Opening", "1000.00"), ("Income:Salary", "2500.00")])
        rep = reports().trial_balance(sample(), D(2023, 12, 31))
        self.assertEqual((rep["accounts"], rep["totals"]), ([], []))

    def test_as_of_none_means_everything(self):
        rep = reports().trial_balance(sample(), None)
        self.assertIsNone(rep["as_of"])
        food = [a for a in rep["accounts"] if a["account"] == "Expenses:Food"][0]
        self.assertEqual(food["debit"], usd("84.50"))
        card = [a for a in rep["accounts"] if a["account"] == "Liabilities:Card"]
        self.assertEqual(card, [])  # paid off, zero balance is left out
        self.assertEqual(rep["totals"], [{"currency": "USD", "debit": usd("3500.00"), "credit": usd("3500.00"), "balanced": True}])

    def test_zero_balances_are_left_out_and_sorting_is_plain_text(self):
        ledger = build([
            (D(2024, 1, 1), "a", [("Expenses:Food:Alpha", "1.00 USD"), ("Expenses:Food-X", "2.00 USD"), ("Assets:Bank", "-3.00 USD")]),
            (D(2024, 1, 2), "b", [("Expenses:Zero", "5.00 USD"), ("Assets:Bank", "-5.00 USD")]),
            (D(2024, 1, 3), "c", [("Assets:Bank", "5.00 USD"), ("Expenses:Zero", "-5.00 USD")])])
        rep = reports().trial_balance(ledger, D(2024, 12, 31))
        self.assertEqual([a["account"] for a in rep["accounts"]], ["Assets:Bank", "Expenses:Food-X", "Expenses:Food:Alpha"])

    def test_two_currencies(self):
        rep = reports().trial_balance(multi(), D(2024, 12, 31))
        self.assertEqual([(a["account"], (a["debit"] or a["credit"])["currency"]) for a in rep["accounts"]],
                         [("Assets:Bank", "EUR"), ("Assets:Bank", "USD"), ("Equity:Opening", "EUR"), ("Equity:Opening", "USD"),
                          ("Expenses:Food", "USD"), ("Income:Salary", "EUR")])
        self.assertEqual(rep["totals"], [
            {"currency": "EUR", "debit": cur("250.00", "EUR"), "credit": cur("250.00", "EUR"), "balanced": True},
            {"currency": "USD", "debit": usd("100.00"), "credit": usd("100.00"), "balanced": True}])

    def test_empty_ledger(self):
        rep = reports().trial_balance(build([]), D(2024, 1, 1))
        self.assertEqual(rep, {"report": "trial_balance", "as_of": "2024-01-01", "accounts": [], "totals": []})

    def test_is_json_able(self):
        for as_of in (D(2024, 3, 31), None):
            json.dumps(reports().trial_balance(sample(), as_of))


class M12BalanceSheet(unittest.TestCase):
    def test_sample(self):
        rep = reports().balance_sheet(sample(), D(2024, 3, 31))
        self.assertEqual(rep, {
            "report": "balance_sheet", "as_of": "2024-03-31", "currency": None, "balanced": True,
            "assets": {"accounts": [{"account": "Assets:Bank:Checking", "balance": usd("3357.50")},
                                    {"account": "Assets:Cash", "balance": usd("88.00")}], "total": [usd("3445.50")]},
            "liabilities": {"accounts": [{"account": "Liabilities:Card", "balance": usd("900.00")}], "total": [usd("900.00")]},
            "equity": {"accounts": [{"account": "Equity:Opening", "balance": usd("1000.00")}],
                       "retained_earnings": [usd("1545.50")], "total": [usd("2545.50")]}})

    def test_later_month_after_paying_the_card(self):
        rep = reports().balance_sheet(sample(), D(2024, 4, 30))
        self.assertEqual(rep["liabilities"], {"accounts": [], "total": []})
        self.assertEqual(rep["assets"]["total"], [usd("2515.50")])
        self.assertEqual(rep["equity"]["retained_earnings"], [usd("1515.50")])
        self.assertEqual(rep["equity"]["total"], [usd("2515.50")])
        self.assertIs(rep["balanced"], True)

    def test_before_any_income_or_expense(self):
        rep = reports().balance_sheet(sample(), D(2024, 2, 15))
        self.assertEqual(rep["equity"]["retained_earnings"], [])
        self.assertEqual(rep["equity"]["total"], [usd("1000.00")])
        self.assertEqual(rep["assets"]["total"], [usd("1000.00")])
        self.assertIs(rep["balanced"], True)

    def test_as_of_none_and_empty_ledger(self):
        rep = reports().balance_sheet(sample(), None)
        self.assertIsNone(rep["as_of"])
        self.assertEqual(rep["assets"]["total"], [usd("2515.50")])
        empty = reports().balance_sheet(build([]), D(2024, 1, 1))
        for part in ("assets", "liabilities"):
            self.assertEqual(empty[part], {"accounts": [], "total": []})
        self.assertEqual(empty["equity"], {"accounts": [], "retained_earnings": [], "total": []})
        self.assertIs(empty["balanced"], True)

    def test_overdrawn_asset_and_negative_retained_earnings(self):
        ledger = build([(D(2024, 1, 5), "Shop", [("Expenses:Food", "20.00 USD"), ("Assets:Bank", "-20.00 USD")])])
        rep = reports().balance_sheet(ledger, D(2024, 1, 31))
        self.assertEqual(rep["assets"]["accounts"], [{"account": "Assets:Bank", "balance": usd("-20.00")}])
        self.assertEqual(rep["equity"]["retained_earnings"], [usd("-20.00")])
        self.assertEqual(rep["equity"]["total"], [usd("-20.00")])
        self.assertIs(rep["balanced"], True)

    def test_two_currencies_without_conversion(self):
        rep = reports().balance_sheet(multi(), D(2024, 12, 31))
        self.assertEqual(rep["assets"]["accounts"], [{"account": "Assets:Bank", "balance": cur("250.00", "EUR")},
                                                     {"account": "Assets:Bank", "balance": usd("70.00")}])
        self.assertEqual(rep["assets"]["total"], [cur("250.00", "EUR"), usd("70.00")])
        self.assertEqual(rep["equity"]["retained_earnings"], [cur("200.00", "EUR"), usd("-30.00")])
        self.assertEqual(rep["equity"]["total"], [cur("250.00", "EUR"), usd("70.00")])
        self.assertIs(rep["balanced"], True)
        self.assertIsNone(rep["currency"])

    def test_conversion(self):
        rep = reports().balance_sheet(multi(), D(2024, 2, 10), convert_to="USD")
        self.assertEqual(rep["currency"], "USD")
        lines = rep["assets"]["accounts"]
        self.assertEqual(lines[0], {"account": "Assets:Bank", "balance": usd("275.00"), "original": cur("250.00", "EUR")})
        self.assertEqual(lines[1], {"account": "Assets:Bank", "balance": usd("70.00"), "original": usd("70.00")})
        self.assertEqual(rep["assets"]["total"], [usd("345.00")])
        self.assertEqual(rep["liabilities"], {"accounts": [], "total": [usd("0.00")]})
        self.assertEqual(rep["equity"]["accounts"][0], {"account": "Equity:Opening", "balance": usd("55.00"), "original": cur("50.00", "EUR")})
        self.assertEqual(rep["equity"]["accounts"][1], {"account": "Equity:Opening", "balance": usd("100.00"), "original": usd("100.00")})
        self.assertEqual(rep["equity"]["retained_earnings"], [usd("190.00")])
        self.assertEqual(rep["equity"]["total"], [usd("345.00")])
        self.assertIs(rep["balanced"], True)

    def test_conversion_uses_the_rate_of_as_of(self):
        early = reports().balance_sheet(multi(), D(2024, 2, 14), convert_to="USD")
        late = reports().balance_sheet(multi(), D(2024, 2, 15), convert_to="USD")
        self.assertEqual(early["assets"]["total"], [usd("345.00")])
        self.assertEqual(late["assets"]["total"], [usd("370.00")])

    def test_conversion_to_the_only_currency_needs_no_rates(self):
        rep = reports().balance_sheet(sample(), D(2024, 3, 31), convert_to="USD")
        self.assertEqual(rep["assets"]["total"], [usd("3445.50")])
        self.assertEqual(rep["assets"]["accounts"][1], {"account": "Assets:Cash", "balance": usd("88.00"), "original": usd("88.00")})
        self.assertEqual(rep["equity"]["retained_earnings"], [usd("1545.50")])

    def test_conversion_to_a_currency_with_a_rate(self):
        ledger = build(SAMPLE_ROWS, rates=rate_table(("USD", "EUR", "0.5", D(2024, 1, 1))))
        rep = reports().balance_sheet(ledger, D(2024, 3, 31), convert_to="EUR")
        self.assertEqual(rep["assets"]["total"], [cur("1722.75", "EUR")])
        self.assertEqual(rep["liabilities"]["total"], [cur("450.00", "EUR")])
        self.assertEqual(rep["equity"]["retained_earnings"], [cur("772.75", "EUR")])
        self.assertEqual(rep["equity"]["total"], [cur("1272.75", "EUR")])
        self.assertIs(rep["balanced"], True)

    def test_conversion_problems(self):
        with self.assertRaises(lib("currency").CurrencyError):
            reports().balance_sheet(sample(), D(2024, 3, 31), convert_to="EUR")
        with self.assertRaises(lib("currency").CurrencyError):
            reports().balance_sheet(sample(), D(2024, 3, 31), convert_to="ZZZ")
        with self.assertRaises(reports().ReportError):
            reports().balance_sheet(multi(), None, convert_to="USD")

    def test_today_changes_nothing(self):
        plain = reports().balance_sheet(sample(), D(2024, 3, 31))
        self.assertEqual(reports().balance_sheet(sample(), D(2024, 3, 31), today=D(1999, 1, 1)), plain)
        self.assertEqual(reports().balance_sheet(sample(), D(2024, 3, 31), None, D(2030, 5, 5)), plain)

    @phase("pre")
    def test_conversion_ties_pre(self):
        ledger = build([(D(2024, 1, 1), "Open", [("Assets:Bank", "0.05 USD"), ("Equity:Opening", "-0.05 USD")])],
                       rates=rate_table(("USD", "EUR", "0.5", D(2024, 1, 1))))
        rep = reports().balance_sheet(ledger, D(2024, 1, 31), convert_to="EUR")
        self.assertEqual(rep["assets"]["total"], [cur("0.03", "EUR")])
        self.assertEqual(rep["equity"]["total"], [cur("0.03", "EUR")])

    @phase("post")
    def test_conversion_ties_post(self):
        ledger = build([(D(2024, 1, 1), "Open", [("Assets:Bank", "0.05 USD"), ("Equity:Opening", "-0.05 USD")])],
                       rates=rate_table(("USD", "EUR", "0.5", D(2024, 1, 1))))
        rep = reports().balance_sheet(ledger, D(2024, 1, 31), convert_to="EUR")
        self.assertEqual(rep["assets"]["total"], [cur("0.02", "EUR")])
        self.assertEqual(rep["equity"]["total"], [cur("0.02", "EUR")])

    def test_is_json_able(self):
        json.dumps(reports().balance_sheet(multi(), D(2024, 12, 31), convert_to="USD"))
        json.dumps(reports().balance_sheet(multi(), None))


class M12IncomeStatement(unittest.TestCase):
    def test_sample_march(self):
        rep = reports().income_statement(sample(), period(MARCH))
        self.assertEqual(rep, {
            "report": "income_statement", "start": "2024-03-01", "end": "2024-03-31", "currency": None,
            "income": {"accounts": [{"account": "Income:Salary", "amount": usd("2500.00"), "percent": "100.0"}],
                       "total": [usd("2500.00")]},
            "expenses": {"accounts": [{"account": "Expenses:Food", "amount": usd("54.50"), "percent": "5.7"},
                                      {"account": "Expenses:Rent", "amount": usd("900.00"), "percent": "94.3"}],
                         "total": [usd("954.50")]},
            "net": [usd("1545.50")]})

    def test_period_bounds_are_inclusive(self):
        rep = reports().income_statement(sample(), period("2024-03-02..2024-03-12"))
        self.assertEqual([a["amount"]["amount"] for a in rep["expenses"]["accounts"]], ["54.50", "900.00"])
        rep = reports().income_statement(sample(), period("2024-03-03..2024-03-11"))
        self.assertEqual([(a["account"], a["amount"]["amount"]) for a in rep["expenses"]["accounts"]], [("Expenses:Rent", "900.00")])
        self.assertEqual(rep["income"], {"accounts": [], "total": []})
        self.assertEqual(rep["expenses"]["accounts"][0]["percent"], "100.0")
        self.assertEqual(rep["net"], [usd("-900.00")])

    def test_other_types_and_other_months_are_ignored(self):
        rep = reports().income_statement(sample(), period("2024-04"))
        self.assertEqual(rep["income"], {"accounts": [], "total": []})
        self.assertEqual([(a["account"], a["amount"]["amount"]) for a in rep["expenses"]["accounts"]], [("Expenses:Food", "30.00")])
        self.assertEqual(rep["net"], [usd("-30.00")])

    def test_empty_period(self):
        rep = reports().income_statement(sample(), period("2024-05"))
        self.assertEqual((rep["income"], rep["expenses"], rep["net"]),
                         ({"accounts": [], "total": []}, {"accounts": [], "total": []}, []))

    def test_refund_gives_a_negative_line(self):
        ledger = build([(D(2024, 1, 5), "Shop", [("Expenses:Food", "30.00 USD"), ("Assets:Bank", "-30.00 USD")]),
                        (D(2024, 1, 6), "Back", [("Expenses:Games", "-10.00 USD"), ("Assets:Bank", "10.00 USD")])])
        rep = reports().income_statement(ledger, period("2024-01"))
        self.assertEqual([(a["account"], a["amount"]["amount"], a["percent"]) for a in rep["expenses"]["accounts"]],
                         [("Expenses:Food", "30.00", "150.0"), ("Expenses:Games", "-10.00", "-50.0")])
        self.assertEqual(rep["expenses"]["total"], [usd("20.00")])

    def test_zero_accounts_are_left_out_and_a_zero_total_gives_zero_percent(self):
        ledger = build([(D(2024, 1, 5), "Shop", [("Expenses:Food", "30.00 USD"), ("Assets:Bank", "-30.00 USD")]),
                        (D(2024, 1, 6), "Back", [("Expenses:Games", "-30.00 USD"), ("Assets:Bank", "30.00 USD")]),
                        (D(2024, 1, 7), "Zero", [("Expenses:Tea", "5.00 USD"), ("Assets:Bank", "-5.00 USD")]),
                        (D(2024, 1, 8), "Zero2", [("Expenses:Tea", "-5.00 USD"), ("Assets:Bank", "5.00 USD")])])
        rep = reports().income_statement(ledger, period("2024-01"))
        self.assertEqual([(a["account"], a["percent"]) for a in rep["expenses"]["accounts"]],
                         [("Expenses:Food", "0.0"), ("Expenses:Games", "0.0")])
        self.assertEqual(rep["expenses"]["total"], [usd("0.00")])
        self.assertEqual(rep["net"], [usd("0.00")])

    def test_two_currencies(self):
        rep = reports().income_statement(multi(), period("2024-02"))
        self.assertEqual(rep["income"], {"accounts": [{"account": "Income:Salary", "amount": cur("200.00", "EUR"), "percent": "100.0"}],
                                         "total": [cur("200.00", "EUR")]})
        self.assertEqual(rep["expenses"]["total"], [usd("30.00")])
        self.assertEqual(rep["net"], [cur("200.00", "EUR"), usd("-30.00")])

    def test_percentages_are_shares_per_currency(self):
        ledger = build([(D(2024, 1, 5), "a", [("Expenses:A", "1.00 USD"), ("Assets:Bank", "-1.00 USD")]),
                        (D(2024, 1, 5), "b", [("Expenses:B", "2.00 USD"), ("Assets:Bank", "-2.00 USD")]),
                        (D(2024, 1, 6), "c", [("Expenses:C", "7.00 EUR"), ("Assets:Bank", "-7.00 EUR")])])
        rep = reports().income_statement(ledger, period("2024-01"))
        self.assertEqual([(a["account"], a["percent"]) for a in rep["expenses"]["accounts"]],
                         [("Expenses:A", "33.3"), ("Expenses:B", "66.7"), ("Expenses:C", "100.0")])

    def test_conversion_uses_the_rate_at_the_end_of_the_period(self):
        rep = reports().income_statement(multi(), period("2024-02"), convert_to="USD")
        self.assertEqual(rep["currency"], "USD")
        self.assertEqual(rep["income"]["accounts"], [{"account": "Income:Salary", "amount": usd("240.00"),
                                                      "original": cur("200.00", "EUR"), "percent": "100.0"}])
        self.assertEqual(rep["expenses"]["accounts"], [{"account": "Expenses:Food", "amount": usd("30.00"),
                                                        "original": usd("30.00"), "percent": "100.0"}])
        self.assertEqual((rep["income"]["total"], rep["expenses"]["total"], rep["net"]), ([usd("240.00")], [usd("30.00")], [usd("210.00")]))
        early = reports().income_statement(multi(), period("2024-02-01..2024-02-14"), convert_to="USD")
        self.assertEqual(early["income"]["total"], [usd("220.00")])

    def test_conversion_of_an_empty_report_has_zero_totals(self):
        rep = reports().income_statement(multi(), period("2024-05"), convert_to="USD")
        self.assertEqual((rep["income"]["total"], rep["expenses"]["total"], rep["net"]), ([usd("0.00")], [usd("0.00")], [usd("0.00")]))

    def test_conversion_without_a_rate(self):
        with self.assertRaises(lib("currency").CurrencyError):
            reports().income_statement(multi(with_rates=False), period("2024-02"), convert_to="USD")

    def test_percent_after_conversion_is_of_the_converted_total(self):
        ledger = multi()
        ledger.chart.add("Income:Gift")
        ledger.add(lib("model").Transaction(date=D(2024, 2, 20), payee="x", narration="", postings=[
            lib("model").Posting("Income:Gift", money("-60.00 USD")), lib("model").Posting("Assets:Bank", money("60.00 USD"))]))
        rep = reports().income_statement(ledger, period("2024-02"), convert_to="USD")
        self.assertEqual([(a["account"], a["amount"]["amount"], a["percent"]) for a in rep["income"]["accounts"]],
                         [("Income:Gift", "60.00", "20.0"), ("Income:Salary", "240.00", "80.0")])

    @phase("pre")
    def test_percent_ties_pre(self):
        ledger = build([(D(2024, 1, 5), "a", [("Expenses:A", "0.05 USD"), ("Assets:Bank", "-0.05 USD")]),
                        (D(2024, 1, 6), "b", [("Expenses:B", "3.95 USD"), ("Assets:Bank", "-3.95 USD")]),
                        (D(2024, 1, 7), "c", [("Income:C", "-0.01 USD"), ("Assets:Bank", "0.01 USD")]),
                        (D(2024, 1, 8), "d", [("Income:D", "-0.03 USD"), ("Assets:Bank", "0.03 USD")])])
        rep = reports().income_statement(ledger, period("2024-01"))
        self.assertEqual([a["percent"] for a in rep["expenses"]["accounts"]], ["1.3", "98.8"])
        self.assertEqual([a["percent"] for a in rep["income"]["accounts"]], ["25.0", "75.0"])

    @phase("post")
    def test_percent_ties_post(self):
        ledger = build([(D(2024, 1, 5), "a", [("Expenses:A", "0.05 USD"), ("Assets:Bank", "-0.05 USD")]),
                        (D(2024, 1, 6), "b", [("Expenses:B", "3.95 USD"), ("Assets:Bank", "-3.95 USD")]),
                        (D(2024, 1, 7), "c", [("Income:C", "-0.01 USD"), ("Assets:Bank", "0.01 USD")]),
                        (D(2024, 1, 8), "d", [("Income:D", "-0.03 USD"), ("Assets:Bank", "0.03 USD")])])
        rep = reports().income_statement(ledger, period("2024-01"))
        self.assertEqual([a["percent"] for a in rep["expenses"]["accounts"]], ["1.2", "98.8"])
        self.assertEqual([a["percent"] for a in rep["income"]["accounts"]], ["25.0", "75.0"])

    def test_is_json_able(self):
        json.dumps(reports().income_statement(multi(), period("2024-02"), convert_to="USD"))


class M12Cashflow(unittest.TestCase):
    def test_sample_march(self):
        rep = reports().cashflow(sample(), period(MARCH))
        self.assertEqual(rep, {
            "report": "cashflow", "start": "2024-03-01", "end": "2024-03-31",
            "opening": [usd("1000.00")],
            "inflows": [{"account": "Income:Salary", "amount": usd("2500.00")}],
            "outflows": [{"account": "Expenses:Food", "amount": usd("54.50")}],
            "total_in": [usd("2500.00")], "total_out": [usd("54.50")], "net": [usd("2445.50")], "closing": [usd("3445.50")]})

    def test_sample_april_pays_off_the_card(self):
        rep = reports().cashflow(sample(), period("2024-04"))
        self.assertEqual(rep["opening"], [usd("3445.50")])
        self.assertEqual(rep["inflows"], [])
        self.assertEqual(rep["outflows"], [{"account": "Expenses:Food", "amount": usd("30.00")},
                                           {"account": "Liabilities:Card", "amount": usd("900.00")}])
        self.assertEqual((rep["total_in"], rep["total_out"], rep["net"], rep["closing"]),
                         ([usd("0.00")], [usd("930.00")], [usd("-930.00")], [usd("2515.50")]))

    def test_transfers_between_asset_accounts_cancel(self):
        rep = reports().cashflow(sample(), period("2024-03-10..2024-03-10"))
        self.assertEqual((rep["inflows"], rep["outflows"], rep["net"]), ([], [], [usd("0.00")]))
        self.assertEqual(rep["opening"], rep["closing"])

    def test_a_fee_on_a_transfer_is_the_only_flow(self):
        ledger = build([(D(2023, 12, 1), "Open", [("Assets:Bank", "500.00 USD"), ("Equity:Opening", "-500.00 USD")]),
                        (D(2024, 1, 5), "Move", [("Assets:Bank", "-101.00 USD"), ("Assets:Savings", "100.00 USD"), ("Expenses:Fees", "1.00 USD")])])
        rep = reports().cashflow(ledger, period("2024-01"))
        self.assertEqual(rep["inflows"], [])
        self.assertEqual(rep["outflows"], [{"account": "Expenses:Fees", "amount": usd("1.00")}])
        self.assertEqual(rep["opening"], [usd("500.00")])
        self.assertEqual(rep["net"], [usd("-1.00")])
        self.assertEqual(rep["closing"], [usd("499.00")])

    def test_a_category_is_netted_over_the_period(self):
        ledger = build([(D(2024, 1, 2), "Shop", [("Expenses:Food", "20.00 USD"), ("Assets:Bank", "-20.00 USD")]),
                        (D(2024, 1, 3), "Refund", [("Expenses:Food", "-5.00 USD"), ("Assets:Bank", "5.00 USD")]),
                        (D(2024, 1, 4), "Gift", [("Income:Gift", "-3.00 USD"), ("Assets:Bank", "3.00 USD")]),
                        (D(2024, 1, 5), "Gift back", [("Income:Gift", "3.00 USD"), ("Assets:Bank", "-3.00 USD")])])
        rep = reports().cashflow(ledger, period("2024-01"))
        self.assertEqual(rep["inflows"], [])
        self.assertEqual(rep["outflows"], [{"account": "Expenses:Food", "amount": usd("15.00")}])
        self.assertEqual((rep["total_in"], rep["total_out"], rep["net"]), ([usd("0.00")], [usd("15.00")], [usd("-15.00")]))

    def test_borrowing_is_an_inflow(self):
        ledger = build([(D(2024, 1, 2), "Loan", [("Assets:Bank", "500.00 USD"), ("Liabilities:Loan", "-500.00 USD")])])
        rep = reports().cashflow(ledger, period("2024-01"))
        self.assertEqual(rep["inflows"], [{"account": "Liabilities:Loan", "amount": usd("500.00")}])
        self.assertEqual((rep["opening"], rep["closing"]), ([usd("0.00")], [usd("500.00")]))

    def test_period_without_any_asset_history(self):
        rep = reports().cashflow(sample(), period("2023-06"))
        self.assertEqual((rep["opening"], rep["closing"], rep["net"], rep["total_in"], rep["total_out"]), ([], [], [], [], []))
        self.assertEqual((rep["inflows"], rep["outflows"]), ([], []))

    def test_quiet_period_after_activity(self):
        rep = reports().cashflow(sample(), period("2024-06"))
        self.assertEqual((rep["opening"], rep["closing"], rep["net"]), ([usd("2515.50")], [usd("2515.50")], [usd("0.00")]))

    def test_two_currencies(self):
        rep = reports().cashflow(multi(), period("2024-02"))
        self.assertEqual(rep["opening"], [cur("50.00", "EUR"), usd("100.00")])
        self.assertEqual(rep["inflows"], [{"account": "Income:Salary", "amount": cur("200.00", "EUR")}])
        self.assertEqual(rep["outflows"], [{"account": "Expenses:Food", "amount": usd("30.00")}])
        self.assertEqual(rep["total_in"], [cur("200.00", "EUR"), usd("0.00")])
        self.assertEqual(rep["total_out"], [cur("0.00", "EUR"), usd("30.00")])
        self.assertEqual(rep["net"], [cur("200.00", "EUR"), usd("-30.00")])
        self.assertEqual(rep["closing"], [cur("250.00", "EUR"), usd("70.00")])

    def test_closing_equals_the_asset_balance(self):
        ledger = sample()
        for per, as_of in (("2024-03", D(2024, 3, 31)), ("2024-04", D(2024, 4, 30)), ("2024-01", D(2024, 1, 31))):
            with self.subTest(period=per):
                rep = reports().cashflow(ledger, period(per))
                sheet = reports().balance_sheet(ledger, as_of)
                self.assertEqual(rep["closing"], sheet["assets"]["total"])

    def test_is_json_able(self):
        json.dumps(reports().cashflow(multi(), period("2024-02")))


class M12Register(unittest.TestCase):
    def test_checking_in_march(self):
        rep = reports().register(sample(), "Assets:Bank:Checking", period(MARCH))
        row = lambda d, i, payee, amt, bal: {"date": d, "id": i, "payee": payee, "narration": "",
                                             "account": "Assets:Bank:Checking", "amount": usd(amt), "balance": usd(bal)}
        self.assertEqual(rep, {
            "report": "register", "account": "Assets:Bank:Checking", "rollup": False, "start": "2024-03-01", "end": "2024-03-31",
            "opening": [usd("1000.00")], "closing": [usd("3357.50")],
            "rows": [row("2024-03-01", 2, "Acme", "2500.00", "3500.00"), row("2024-03-02", 3, "Market", "-42.50", "3457.50"),
                     row("2024-03-10", 5, "ATM", "-100.00", "3357.50")]})

    def test_without_a_period_everything_is_listed(self):
        rep = reports().register(sample(), "Assets:Bank:Checking")
        self.assertEqual((rep["start"], rep["end"]), (None, None))
        self.assertEqual(rep["opening"], [usd("0.00")])
        self.assertEqual([r["balance"]["amount"] for r in rep["rows"]], ["1000.00", "3500.00", "3457.50", "3357.50", "2457.50", "2427.50"])
        self.assertEqual(rep["closing"], [usd("2427.50")])

    def test_rollup_includes_sub_accounts(self):
        rep = reports().register(sample(), "Assets", period(MARCH), rollup=True)
        self.assertIs(rep["rollup"], True)
        self.assertEqual([(r["id"], r["account"], r["amount"]["amount"], r["balance"]["amount"]) for r in rep["rows"]], [
            (2, "Assets:Bank:Checking", "2500.00", "3500.00"), (3, "Assets:Bank:Checking", "-42.50", "3457.50"),
            (5, "Assets:Cash", "100.00", "3557.50"), (5, "Assets:Bank:Checking", "-100.00", "3457.50"),
            (6, "Assets:Cash", "-12.00", "3445.50")])
        self.assertEqual((rep["opening"], rep["closing"]), ([usd("1000.00")], [usd("3445.50")]))

    def test_without_rollup_a_parent_has_no_rows(self):
        rep = reports().register(sample(), "Assets:Bank", period(MARCH))
        self.assertEqual((rep["rows"], rep["opening"], rep["closing"]), ([], [], []))
        rep = reports().register(sample(), "Assets:Bank", period(MARCH), rollup=True)
        self.assertEqual(len(rep["rows"]), 3)

    def test_rollup_of_a_leaf_is_the_leaf(self):
        plain = reports().register(sample(), "Assets:Cash", period(MARCH))
        rolled = reports().register(sample(), "Assets:Cash", period(MARCH), rollup=True)
        self.assertEqual(plain["rows"], rolled["rows"])
        self.assertEqual([r["balance"]["amount"] for r in plain["rows"]], ["100.00", "88.00"])

    def test_rollup_does_not_match_a_longer_name(self):
        ledger = build([(D(2024, 1, 1), "a", [("Assets:Bank", "1.00 USD"), ("Assets:Bank-Old", "2.00 USD"), ("Equity:Opening", "-3.00 USD")])])
        rep = reports().register(ledger, "Assets:Bank", rollup=True)
        self.assertEqual([r["account"] for r in rep["rows"]], ["Assets:Bank"])

    def test_unknown_account(self):
        for account in ("Assets:Nope", "assets", "", "Expenses:Nothing"):
            with self.subTest(account=account), self.assertRaises(reports().ReportError):
                reports().register(sample(), account, period(MARCH))
        self.assertTrue(issubclass(reports().ReportError, lib("errors").ValidationError))

    def test_known_account_without_postings(self):
        ledger = build([], extra_accounts=["Assets:Empty"])
        rep = reports().register(ledger, "Assets:Empty", period(MARCH))
        self.assertEqual((rep["rows"], rep["opening"], rep["closing"]), ([], [], []))

    def test_two_currencies_have_separate_running_balances(self):
        rep = reports().register(multi(), "Assets:Bank")
        self.assertEqual([(r["date"], r["amount"]["currency"], r["balance"]["amount"]) for r in rep["rows"]],
                         [("2024-01-01", "USD", "100.00"), ("2024-01-02", "EUR", "50.00"), ("2024-02-01", "EUR", "250.00"),
                          ("2024-02-02", "USD", "70.00")])
        self.assertEqual(rep["opening"], [cur("0.00", "EUR"), usd("0.00")])
        self.assertEqual(rep["closing"], [cur("250.00", "EUR"), usd("70.00")])
        feb = reports().register(multi(), "Assets:Bank", period("2024-02"))
        self.assertEqual(feb["opening"], [cur("50.00", "EUR"), usd("100.00")])
        self.assertEqual([r["balance"]["amount"] for r in feb["rows"]], ["250.00", "70.00"])

    def test_order_is_date_then_id_then_posting_order(self):
        ledger = build([
            (D(2024, 5, 1), "later id", [("Assets:Bank", "1.00 USD"), ("Equity:Opening", "-1.00 USD")], 9),
            (D(2024, 5, 1), "earlier id", [("Assets:Bank", "2.00 USD"), ("Equity:Opening", "-2.00 USD")], 3),
            (D(2024, 4, 30), "older", [("Assets:Bank", "4.00 USD"), ("Equity:Opening", "-4.00 USD")], 20),
            (D(2024, 5, 1), "split", [("Assets:Bank", "8.00 USD"), ("Assets:Bank", "16.00 USD"), ("Equity:Opening", "-24.00 USD")], 5)])
        rep = reports().register(ledger, "Assets:Bank")
        self.assertEqual([(r["id"], r["amount"]["amount"]) for r in rep["rows"]],
                         [(20, "4.00"), (3, "2.00"), (5, "8.00"), (5, "16.00"), (9, "1.00")])
        self.assertEqual([r["balance"]["amount"] for r in rep["rows"]], ["4.00", "6.00", "14.00", "30.00", "31.00"])

    def test_payee_and_narration_are_on_the_rows(self):
        model = lib("model")
        ledger = build([])
        ledger.chart.add("Assets:Bank")
        ledger.chart.add("Equity:Opening")
        ledger.add(model.Transaction(date=D(2024, 1, 1), payee="Acme Corp", narration="first pay",
                                     postings=[model.Posting("Assets:Bank", money("1.00 USD")), model.Posting("Equity:Opening", money("-1.00 USD"))]))
        row = reports().register(ledger, "Assets:Bank")["rows"][0]
        self.assertEqual((row["payee"], row["narration"], row["id"], row["date"]), ("Acme Corp", "first pay", 1, "2024-01-01"))

    def test_is_json_able(self):
        json.dumps(reports().register(multi(), "Assets", rollup=True))


class M12NetWorth(unittest.TestCase):
    def point(self, date_text, assets, liabilities, net, code="USD"):
        return {"date": date_text, "assets": [cur(assets, code)], "liabilities": [cur(liabilities, code)], "net": [cur(net, code)]}

    def test_sample_by_month(self):
        rep = reports().net_worth(sample(), period("2024-01-15..2024-04-10"), "month")
        self.assertEqual(rep, {"report": "net_worth", "start": "2024-01-15", "end": "2024-04-10", "step": "month", "points": [
            self.point("2024-01-31", "1000.00", "0.00", "1000.00"), self.point("2024-02-29", "1000.00", "0.00", "1000.00"),
            self.point("2024-03-31", "3445.50", "900.00", "2545.50"), self.point("2024-04-30", "2515.50", "0.00", "2515.50")]})

    def test_default_step_is_month(self):
        self.assertEqual(reports().net_worth(sample(), period("2024-03")), reports().net_worth(sample(), period("2024-03"), "month"))

    def test_other_steps(self):
        rep = reports().net_worth(sample(), period("2024-01-01..2024-12-31"), "quarter")
        self.assertEqual([(p["date"], p["net"][0]["amount"]) for p in rep["points"]],
                         [("2024-03-31", "2545.50"), ("2024-06-30", "2515.50"), ("2024-09-30", "2515.50"), ("2024-12-31", "2515.50")])
        rep = reports().net_worth(sample(), period("2023-06-01..2024-02-01"), "year")
        self.assertEqual([(p["date"], p["assets"]) for p in rep["points"]], [("2023-12-31", []), ("2024-12-31", [usd("2515.50")])])
        rep = reports().net_worth(sample(), period("2024-03-10..2024-03-17"), "week")
        self.assertEqual([(p["date"], p["assets"][0]["amount"]) for p in rep["points"]], [("2024-03-10", "3457.50"), ("2024-03-17", "3445.50")])

    def test_dates_before_any_asset_or_liability_have_empty_lists(self):
        rep = reports().net_worth(sample(), period("2023-11-01..2023-12-31"), "month")
        self.assertEqual(rep["points"], [{"date": "2023-11-30", "assets": [], "liabilities": [], "net": []},
                                         {"date": "2023-12-31", "assets": [], "liabilities": [], "net": []}])

    def test_two_currencies(self):
        rep = reports().net_worth(multi(), period("2024-02"), "month")
        self.assertEqual(rep["points"], [{"date": "2024-02-29", "assets": [cur("250.00", "EUR"), usd("70.00")],
                                          "liabilities": [cur("0.00", "EUR"), usd("0.00")], "net": [cur("250.00", "EUR"), usd("70.00")]}])

    def test_liabilities_in_another_currency_count_in_that_currency(self):
        ledger = build([(D(2024, 1, 2), "Loan", [("Assets:Bank", "500.00 USD"), ("Liabilities:Loan", "-500.00 USD")]),
                        (D(2024, 1, 3), "Euro loan", [("Assets:Bank", "10.00 EUR"), ("Liabilities:Loan", "-10.00 EUR")])])
        (point,) = reports().net_worth(ledger, period("2024-01"), "month")["points"]
        self.assertEqual(point["net"], [cur("0.00", "EUR"), usd("0.00")])
        self.assertEqual(point["liabilities"], [cur("10.00", "EUR"), usd("500.00")])

    def test_bad_step(self):
        for step in ("days", "Month", "", None, "weekly"):
            with self.subTest(step=step), self.assertRaises(reports().ReportError):
                reports().net_worth(sample(), period(MARCH), step)

    def test_text(self):
        text = reports().render_text(reports().net_worth(sample(), period("2024-01-15..2024-04-10"), "month"))
        self.assertEqual(text, """\
Net worth 2024-01-15 to 2024-04-10 (by month)

Date             Assets  Liabilities          Net
----------  -----------  -----------  -----------
2024-01-31  1000.00 USD     0.00 USD  1000.00 USD
2024-02-29  1000.00 USD     0.00 USD  1000.00 USD
2024-03-31  3445.50 USD   900.00 USD  2545.50 USD
2024-04-30  2515.50 USD     0.00 USD  2515.50 USD
""")
        text = reports().render_text(reports().net_worth(sample(), period("2023-12-01..2023-12-31"), "month"))
        self.assertEqual(text, "Net worth 2023-12-01 to 2023-12-31 (by month)\n\nDate        Assets  Liabilities  Net\n"
                               "----------  ------  -----------  ---\n2023-12-31\n")

    def test_is_json_able(self):
        json.dumps(reports().net_worth(multi(), period("2024-01-01..2024-03-31"), "month"))


class M12Csv(unittest.TestCase):
    def csv(self, report):
        return reports().report_to_csv(report)

    def test_trial_balance(self):
        self.assertEqual(self.csv(reports().trial_balance(sample(), D(2024, 3, 31))), """\
account,type,currency,debit,credit
Assets:Bank:Checking,asset,USD,3357.50,
Assets:Cash,asset,USD,88.00,
Equity:Opening,equity,USD,,1000.00
Expenses:Food,expense,USD,54.50,
Expenses:Rent,expense,USD,900.00,
Income:Salary,income,USD,,2500.00
Liabilities:Card,liability,USD,,900.00
""")

    def test_balance_sheet(self):
        self.assertEqual(self.csv(reports().balance_sheet(sample(), D(2024, 3, 31))), """\
section,account,currency,balance
assets,Assets:Bank:Checking,USD,3357.50
assets,Assets:Cash,USD,88.00
liabilities,Liabilities:Card,USD,900.00
equity,Equity:Opening,USD,1000.00
equity,Retained earnings,USD,1545.50
""")

    def test_balance_sheet_two_currencies_keeps_retained_per_currency(self):
        lines = self.csv(reports().balance_sheet(multi(), D(2024, 12, 31))).splitlines()
        self.assertEqual(lines[-2:], ["equity,Retained earnings,EUR,200.00", "equity,Retained earnings,USD,-30.00"])

    def test_income_statement(self):
        self.assertEqual(self.csv(reports().income_statement(sample(), period(MARCH))), """\
section,account,currency,amount,percent
income,Income:Salary,USD,2500.00,100.0
expenses,Expenses:Food,USD,54.50,5.7
expenses,Expenses:Rent,USD,900.00,94.3
""")

    def test_cashflow(self):
        self.assertEqual(self.csv(reports().cashflow(sample(), period("2024-04"))), """\
section,account,currency,amount
opening,,USD,3445.50
out,Expenses:Food,USD,30.00
out,Liabilities:Card,USD,900.00
closing,,USD,2515.50
""")

    def test_register(self):
        self.assertEqual(self.csv(reports().register(sample(), "Assets:Cash")), """\
date,id,payee,narration,account,currency,amount,balance
2024-03-10,5,ATM,,Assets:Cash,USD,100.00,100.00
2024-03-12,6,Corner,,Assets:Cash,USD,-12.00,88.00
""")

    def test_register_quotes_and_missing_rows(self):
        model = lib("model")
        ledger = build([], extra_accounts=["Assets:Bank", "Equity:Opening"])
        ledger.add(model.Transaction(date=D(2024, 1, 1), payee="Acme, Inc", narration='the "first"',
                                     postings=[model.Posting("Assets:Bank", money("1.00 USD")), model.Posting("Equity:Opening", money("-1.00 USD"))]))
        self.assertEqual(self.csv(reports().register(ledger, "Assets:Bank")).splitlines()[1],
                         '2024-01-01,1,"Acme, Inc","the ""first""",Assets:Bank,USD,1.00,1.00')
        self.assertEqual(self.csv(reports().register(ledger, "Equity:Opening", period("2025-01"))),
                         "date,id,payee,narration,account,currency,amount,balance\n")

    def test_net_worth(self):
        self.assertEqual(self.csv(reports().net_worth(multi(), period("2024-02"), "month")), """\
date,currency,assets,liabilities,net
2024-02-29,EUR,250.00,0.00,250.00
2024-02-29,USD,70.00,0.00,70.00
""")

    def test_header_only_when_empty(self):
        self.assertEqual(self.csv(reports().trial_balance(build([]), None)), "account,type,currency,debit,credit\n")

    def test_not_a_report(self):
        for value in ({}, {"report": "x"}, None, "trial_balance", 5):
            with self.subTest(value=value), self.assertRaises(reports().ReportError):
                reports().report_to_csv(value)


SAMPLE_BALANCE_SHEET_TEXT = """\
Balance sheet as of 2024-03-31

Account                     Balance
----------------------  -----------
Assets
  Assets:Bank:Checking  3357.50 USD
  Assets:Cash             88.00 USD
Total assets            3445.50 USD

Liabilities
  Liabilities:Card       900.00 USD
Total liabilities        900.00 USD

Equity
  Equity:Opening        1000.00 USD
  Retained earnings     1545.50 USD
Total equity            2545.50 USD
"""

SAMPLE_INCOME_TEXT = """\
Income statement 2024-03-01 to 2024-03-31

Account               Amount  Percent
---------------  -----------  -------
Income
  Income:Salary  2500.00 USD   100.0%
Total income     2500.00 USD

Expenses
  Expenses:Food    54.50 USD     5.7%
  Expenses:Rent   900.00 USD    94.3%
Total expenses    954.50 USD

Net income       1545.50 USD
"""

SAMPLE_REGISTER_TEXT = """\
Register Assets:Bank:Checking 2024-03-01 to 2024-03-31

Date        Id  Payee            Account                    Amount      Balance
----------  --  ---------------  --------------------  -----------  -----------
                Opening balance                                     1000.00 USD
2024-03-01  2   Acme             Assets:Bank:Checking  2500.00 USD  3500.00 USD
2024-03-02  3   Market           Assets:Bank:Checking   -42.50 USD  3457.50 USD
2024-03-10  5   ATM              Assets:Bank:Checking  -100.00 USD  3357.50 USD
                Closing balance                                     3357.50 USD
"""

SAMPLE_TRIAL_TEXT = """\
Trial balance as of 2024-03-31

Account               Type             Debit       Credit
--------------------  ---------  -----------  -----------
Assets:Bank:Checking  asset      3357.50 USD
Assets:Cash           asset        88.00 USD
Equity:Opening        equity                  1000.00 USD
Expenses:Food         expense      54.50 USD
Expenses:Rent         expense     900.00 USD
Income:Salary         income                  2500.00 USD
Liabilities:Card      liability                900.00 USD
Total                            4400.00 USD  4400.00 USD
"""

SAMPLE_CASHFLOW_TEXT = """\
Cash flow 2024-03-01 to 2024-03-31

Account               Amount
---------------  -----------
Opening balance  1000.00 USD

Money in
  Income:Salary  2500.00 USD
Total money in   2500.00 USD

Money out
  Expenses:Food    54.50 USD
Total money out    54.50 USD

Net change       2445.50 USD
Closing balance  3445.50 USD
"""


class M12RenderText(unittest.TestCase):
    def test_trial_balance(self):
        self.assertEqual(reports().render_text(reports().trial_balance(sample(), D(2024, 3, 31))), SAMPLE_TRIAL_TEXT)

    def test_balance_sheet(self):
        self.assertEqual(reports().render_text(reports().balance_sheet(sample(), D(2024, 3, 31))), SAMPLE_BALANCE_SHEET_TEXT)

    def test_income_statement(self):
        self.assertEqual(reports().render_text(reports().income_statement(sample(), period(MARCH))), SAMPLE_INCOME_TEXT)

    def test_cashflow(self):
        self.assertEqual(reports().render_text(reports().cashflow(sample(), period(MARCH))), SAMPLE_CASHFLOW_TEXT)

    def test_register(self):
        self.assertEqual(reports().render_text(reports().register(sample(), "Assets:Bank:Checking", period(MARCH))), SAMPLE_REGISTER_TEXT)

    def test_register_with_rollup_and_without_period(self):
        text = reports().render_text(reports().register(sample(), "Assets", rollup=True))
        self.assertEqual(text, """\
Register Assets (with sub-accounts)

Date        Id  Payee            Account                    Amount      Balance
----------  --  ---------------  --------------------  -----------  -----------
                Opening balance                                        0.00 USD
2024-01-01  1   Opening          Assets:Bank:Checking  1000.00 USD  1000.00 USD
2024-03-01  2   Acme             Assets:Bank:Checking  2500.00 USD  3500.00 USD
2024-03-02  3   Market           Assets:Bank:Checking   -42.50 USD  3457.50 USD
2024-03-10  5   ATM              Assets:Cash            100.00 USD  3557.50 USD
2024-03-10  5   ATM              Assets:Bank:Checking  -100.00 USD  3457.50 USD
2024-03-12  6   Corner           Assets:Cash            -12.00 USD  3445.50 USD
2024-04-02  7   Card payoff      Assets:Bank:Checking  -900.00 USD  2545.50 USD
2024-04-03  8   Market           Assets:Bank:Checking   -30.00 USD  2515.50 USD
                Closing balance                                     2515.50 USD
""")

    def test_trial_balance_titles_and_empty_table(self):
        text = reports().render_text(reports().trial_balance(build([]), None))
        self.assertEqual(text, "Trial balance\n\nAccount  Type  Debit  Credit\n-------  ----  -----  ------\n")

    def test_balance_sheet_converted(self):
        text = reports().render_text(reports().balance_sheet(multi(), D(2024, 2, 10), convert_to="USD"))
        self.assertEqual(text, """\
Balance sheet as of 2024-02-10 (in USD)

Account                 Balance
-------------------  ----------
Assets
  Assets:Bank        275.00 USD
  Assets:Bank         70.00 USD
Total assets         345.00 USD

Liabilities
Total liabilities      0.00 USD

Equity
  Equity:Opening      55.00 USD
  Equity:Opening     100.00 USD
  Retained earnings  190.00 USD
Total equity         345.00 USD
""")

    def test_balance_sheet_without_date(self):
        lines = reports().render_text(reports().balance_sheet(sample(), None, convert_to=None)).splitlines()
        self.assertEqual(lines[0], "Balance sheet")
        lines = reports().render_text(reports().balance_sheet(build([]), D(2024, 1, 1))).splitlines()
        self.assertEqual(lines, ["Balance sheet as of 2024-01-01", "", "Account      Balance", "-----------  -------",
                                 "Assets", "", "Liabilities", "", "Equity"])

    def test_empty_income_statement(self):
        text = reports().render_text(reports().income_statement(build([]), period("2024-05")))
        self.assertEqual(text, "Income statement 2024-05-01 to 2024-05-31\n\nAccount   Amount  Percent\n--------  ------  -------\n"
                               "Income\n\nExpenses\n")

    def test_income_statement_converted(self):
        text = reports().render_text(reports().income_statement(multi(), period("2024-02"), convert_to="USD"))
        self.assertEqual(text, """\
Income statement 2024-02-01 to 2024-02-29 (in USD)

Account              Amount  Percent
---------------  ----------  -------
Income
  Income:Salary  240.00 USD   100.0%
Total income     240.00 USD

Expenses
  Expenses:Food   30.00 USD   100.0%
Total expenses    30.00 USD

Net income       210.00 USD
""")

    def test_cashflow_empty_ledger(self):
        text = reports().render_text(reports().cashflow(build([]), period("2024-05")))
        self.assertEqual(text, "Cash flow 2024-05-01 to 2024-05-31\n\nAccount    Amount\n---------  ------\nMoney in\n\nMoney out\n")

    def test_cashflow_two_currencies(self):
        text = reports().render_text(reports().cashflow(multi(), period("2024-02")))
        self.assertEqual(text, """\
Cash flow 2024-02-01 to 2024-02-29

Account              Amount
---------------  ----------
Opening balance   50.00 EUR
Opening balance  100.00 USD

Money in
  Income:Salary  200.00 EUR
Total money in   200.00 EUR
Total money in     0.00 USD

Money out
  Expenses:Food   30.00 USD
Total money out    0.00 EUR
Total money out   30.00 USD

Net change       200.00 EUR
Net change       -30.00 USD
Closing balance  250.00 EUR
Closing balance   70.00 USD
""")

    def test_text_is_clean(self):
        ledger = sample()
        texts = [reports().render_text(r) for r in (
            reports().trial_balance(ledger, D(2024, 3, 31)), reports().balance_sheet(ledger, D(2024, 4, 30)),
            reports().income_statement(ledger, period("2024-04")), reports().cashflow(ledger, period("2024-04")),
            reports().register(ledger, "Assets", period("2024-04"), rollup=True),
            reports().balance_sheet(multi(), D(2024, 12, 31)), reports().cashflow(multi(), period("2024-02")))]
        for text in texts:
            with self.subTest(first=text.splitlines()[0]):
                self.assertTrue(text.endswith("\n"))
                self.assertFalse(text.endswith("\n\n"))
                self.assertNotIn("\r", text)
                for line in text.splitlines():
                    self.assertEqual(line, line.rstrip())

    def test_not_a_report(self):
        for value in ({}, {"report": "nope"}, None, "trial_balance", [], {"report": None}):
            with self.subTest(value=value), self.assertRaises(reports().ReportError):
                reports().render_text(value)

    def test_unicode_text_widths_use_len(self):
        ledger = build([(D(2024, 1, 1), "Caf\u00e9 \u4e2d\u6587 Long Payee Name Here",
                         [("Assets:Bank", "1.00 USD"), ("Equity:Opening", "-1.00 USD")])])
        text = reports().render_text(reports().register(ledger, "Assets:Bank"))
        self.assertEqual(text, """\
Register Assets:Bank

Date        Id  Payee                         Account        Amount   Balance
----------  --  ----------------------------  -----------  --------  --------
                Opening balance                                      0.00 USD
2024-01-01  1   Caf\u00e9 \u4e2d\u6587 Long Payee Name Here  Assets:Bank  1.00 USD  1.00 USD
                Closing balance                                      1.00 USD
""")


if __name__ == "__main__":
    unittest.main()

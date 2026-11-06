"""Module 07: the query language (tallybook.query)."""
import unittest
from datetime import date

from support import lib


def query():
    return lib("query")


def make_tx(id, day, payee, narration, postings, tags=(), flag="*"):
    model, money = lib("model"), lib("money")
    return model.Transaction(
        date=day, payee=payee, narration=narration, tags=tuple(tags), flag=flag, id=id,
        postings=[model.Posting(acct, money.Money.parse(amt)) for acct, amt in postings])


def book():
    return [
        make_tx(1, date(2024, 3, 1), "Blue Bottle Coffee", "morning latte",
                [("Expenses:Food", "4.50 USD"), ("Assets:Bank:Checking", "-4.50 USD")], ["coffee"]),
        make_tx(2, date(2024, 3, 5), "Bakery Sweet", "bread and cake",
                [("Expenses:Food:Bakery", "12.00 USD"), ("Assets:Cash", "-12.00 USD")]),
        make_tx(3, date(2024, 2, 20), "ACME Payroll", "february salary",
                [("Assets:Bank:Checking", "2500.00 USD"), ("Income:Salary", "-2500.00 USD")], ["salary"]),
        make_tx(4, date(2024, 3, 15), "Landlord", "March rent",
                [("Expenses:Rent", "900.00 USD"), ("Assets:Bank:Checking", "-900.00 USD")], [], "!"),
        make_tx(5, date(2024, 4, 2), "Euro Cafe", "trip",
                [("Expenses:Food", "3.50 EUR"), ("Assets:Cash", "-3.50 EUR")], ["coffee", "trip"]),
        make_tx(6, date(2024, 3, 31), "Tokyo Ramen", "dinner",
                [("Expenses:Food", "1500 JPY"), ("Assets:Cash", "-1500 JPY")]),
    ]


class M07Base(unittest.TestCase):
    def ids(self, text, txs=None):
        return [t.id for t in query().select(book() if txs is None else txs, text)]

    def assertIds(self, text, expected):
        self.assertEqual(self.ids(text), expected, text)

    def err(self, text, **kw):
        with self.assertRaises(query().QueryError) as cm:
            query().parse_query(text, **kw)
        return cm.exception


class M07TextTerms(M07Base):
    def test_empty_query_matches_everything(self):
        for text in ("", "   ", "\t "):
            with self.subTest(text=text):
                self.assertIds(text, [1, 2, 3, 4, 5, 6])
        q = query().parse_query("  ")
        self.assertTrue(q.is_empty)
        self.assertFalse(query().parse_query("payee:x").is_empty)
        tx = book()[0]
        self.assertEqual(q.matching_postings(tx), tx.postings)

    def test_transaction_without_postings_only_matches_empty_query(self):
        bare = make_tx(9, date(2024, 1, 1), "Nothing", "", [])
        self.assertTrue(query().parse_query("").matches(bare))
        self.assertFalse(query().parse_query("payee:nothing").matches(bare))
        self.assertFalse(query().parse_query("not payee:other").matches(bare))

    def test_payee_is_a_case_insensitive_substring(self):
        self.assertIds("payee:bottle", [1])
        self.assertIds("payee:BAKERY", [2])
        self.assertIds("payee:a", [2, 3, 4, 5, 6])  # Bakery, ACME, Landlord, Euro Cafe, Tokyo Ramen
        self.assertIds("payee:nothing", [])
        self.assertIds("payee:ramen", [6])
        self.assertIds("payee:rent", [])  # "rent" is in a narration, not a payee

    def test_narration_is_a_case_insensitive_substring(self):
        self.assertIds("narration:RENT", [4])
        self.assertIds("narration:and", [2])
        self.assertIds("narration:latte", [1])
        self.assertIds("narration:coffee", [])

    def test_quoted_values_may_contain_spaces(self):
        self.assertIds('payee:"blue bottle"', [1])
        self.assertIds('payee:"Blue  Bottle"', [])
        self.assertIds('narration:"bread and"', [2])
        self.assertIds('"march rent"', [4])

    def test_bare_words_search_payee_and_narration(self):
        self.assertIds("coffee", [1])          # the payee of 1; no narration says coffee
        self.assertIds("rent", [4])            # a narration
        self.assertIds("landlord", [4])        # a payee
        self.assertIds("TRIP", [5])
        self.assertIds("cafe", [5])
        self.assertIds("zzz", [])

    def test_term_names_are_case_insensitive(self):
        self.assertIds("PAYEE:acme", [3])
        self.assertIds("Tag:salary", [3])
        self.assertIds("AMOUNT>2000", [3])
        self.assertIds("Date:2024-02", [3])

    def test_unicode_case_folding(self):
        txs = [make_tx(1, date(2024, 1, 1), "Café Zoé", "", [("Expenses:Food", "1.00 USD"), ("Assets:Cash", "-1.00 USD")])]
        self.assertEqual(self.ids("payee:CAFÉ", txs), [1])
        self.assertEqual(self.ids("zoÉ", txs), [1])

    def test_quote_escapes(self):
        txs = [
            make_tx(1, date(2024, 1, 1), 'Joe "Big" Diner', r"back\slash",
                    [("Expenses:Food", "1.00 USD"), ("Assets:Cash", "-1.00 USD")]),
            make_tx(2, date(2024, 1, 2), "Joe Small", "",
                    [("Expenses:Food", "1.00 USD"), ("Assets:Cash", "-1.00 USD")]),
        ]
        self.assertEqual(self.ids(r'payee:"joe \"big\""', txs), [1])
        self.assertEqual(self.ids(r'narration:"back\\slash"', txs), [1])   # \\ is one backslash
        self.assertEqual(self.ids(r'narration:"back\slash"', txs), [1])    # other backslashes are themselves
        self.assertEqual(self.ids(r'"\"big\""', txs), [1])

    def test_keywords_in_quotes_are_text(self):
        self.assertIds('"and"', [2, 4])      # bread AND cake, Landlord
        self.assertIds('"or"', [1, 4])       # mORning, LandlORd
        self.assertIds('"not"', [])
        self.assertIds("payee:and", [4])     # a value is never a keyword

    def test_values_stop_at_parentheses_and_spaces(self):
        self.assertIds("(payee:acme)", [3])
        self.assertIds("(payee:acme or payee:bakery)", [2, 3])
        self.assertIds("payee:acme(tag:salary)", [3])


class M07FieldTerms(M07Base):
    def test_tag_is_an_exact_match(self):
        self.assertIds("tag:coffee", [1, 5])
        self.assertIds("tag:cof", [])
        self.assertIds("tag:coffees", [])
        self.assertIds("tag:salary", [3])
        self.assertIds("tag:Coffee", [1, 5])

    def test_date_periods(self):
        self.assertIds("date:2024-03", [1, 2, 4, 6])
        self.assertIds("date:2024-Q1", [1, 2, 3, 4, 6])
        self.assertIds("date:2024-Q2", [5])
        self.assertIds("date:2024", [1, 2, 3, 4, 5, 6])
        self.assertIds("date:2023", [])
        self.assertIds("date:2024-03-01..2024-03-05", [1, 2])
        self.assertIds("date:2024-03-31..2024-04-02", [5, 6])

    def test_date_comparisons(self):
        self.assertIds("date>=2024-03-15", [4, 5, 6])
        self.assertIds("date>2024-03-15", [5, 6])
        self.assertIds("date<2024-03-01", [3])
        self.assertIds("date<=2024-03-01", [1, 3])
        self.assertIds("date=2024-03-05", [2])
        self.assertIds("date!=2024-03-05", [1, 3, 4, 5, 6])
        self.assertIds("date >= 2024-03-15 and date < 2024-04-01", [4, 6])

    def test_flag(self):
        self.assertIds("flag:!", [4])
        self.assertIds("flag:*", [1, 2, 3, 5, 6])
        self.assertIds("not flag:*", [4])

    def test_id(self):
        self.assertIds("id:3", [3])
        self.assertIds("id:99", [])
        self.assertIds("id:1 or id:6", [1, 6])
        unsaved = make_tx(None, date(2024, 1, 1), "X", "", [("Expenses:Food", "1.00 USD"), ("Assets:Cash", "-1.00 USD")])
        self.assertEqual(self.ids("id:1", [unsaved]), [])
        self.assertEqual(self.ids("payee:x", [unsaved]), [None])


class M07AccountAndAmount(M07Base):
    def test_account_matches_the_account_and_what_is_below_it(self):
        self.assertIds("account:Expenses:Food", [1, 2, 5, 6])    # 2 posts to Expenses:Food:Bakery
        self.assertIds("account:Expenses", [1, 2, 4, 5, 6])
        self.assertIds("account:Income", [3])
        self.assertIds("account:Assets:Bank", [1, 3, 4])
        self.assertIds("account:Assets:Bank:Checking", [1, 3, 4])
        self.assertIds("account:Expenses:Food:Bakery", [2])

    def test_account_is_whole_parts_and_case_sensitive(self):
        self.assertIds("account:Expenses:Foo", [])
        self.assertIds("account:Expense", [])
        self.assertIds("account:expenses", [])
        self.assertIds("account:Bank", [])

    def test_account_wildcards(self):
        self.assertIds("account:Expenses:*", [1, 2, 4, 5, 6])
        self.assertIds("account:Expenses:*:Bakery", [2])
        self.assertIds("account:*:Cash", [2, 5, 6])
        self.assertIds("account:*", [1, 2, 3, 4, 5, 6])
        self.assertIds("account:Assets:*:Checking", [1, 3, 4])
        self.assertIds("account:Income:*", [3])
        self.assertIds("account:Income:**", [3])
        self.assertIds("account:**:Bakery", [2])
        self.assertIds("account:**:Cash", [2, 5, 6])
        self.assertIds("account:**", [1, 2, 3, 4, 5, 6])

    def test_star_needs_exactly_one_part_and_double_star_may_be_none(self):
        root = [make_tx(1, date(2024, 1, 1), "x", "", [("Expenses", "1.00 USD"), ("Assets", "-1.00 USD")])]
        self.assertEqual(self.ids("account:Expenses:*", root), [])
        self.assertEqual(self.ids("account:Expenses:**", root), [1])
        self.assertEqual(self.ids("account:**:Expenses", root), [1])

    def test_invalid_account_patterns(self):
        for text in ("account:Fo*", "account:Expenses::Food", "account:Expenses:", "account::Food",
                     "account:Ex$p", "account:Expenses:F**"):
            with self.subTest(text=text):
                e = self.err(text)
                self.assertEqual(e.position, 1)

    def test_amount_compares_signed_posting_amounts(self):
        self.assertIds("amount>10", [2, 3, 4, 6])
        self.assertIds("amount>=12", [2, 3, 4, 6])
        self.assertIds("amount>12", [3, 4, 6])
        self.assertIds("amount<=-5", [2, 3, 4, 6])
        self.assertIds("amount<-900", [3, 6])
        self.assertIds("amount=-4.5", [1])
        self.assertIds("amount>1000", [3, 6])
        self.assertIds("amount>=+2500", [3])

    def test_amount_equality_is_numeric(self):
        self.assertIds("amount=3.5", [5])
        self.assertIds("amount=3.50", [5])
        self.assertIds("amount=4.5", [1])
        self.assertIds("amount=1500", [6])
        self.assertIds("amount=12.000", [2])
        self.assertIds("amount!=4.5 and amount!=-4.5 and amount<5 and amount>-5", [5])

    def test_amount_currency_suffix(self):
        self.assertIds("amount>10USD", [2, 3, 4])
        self.assertIds("amount>10JPY", [6])
        self.assertIds("amount>1EUR", [5])
        self.assertIds("amount>0EUR", [5])
        self.assertIds("amount<0EUR", [5])
        self.assertIds("amount>10", [2, 3, 4, 6])   # no code: any currency

    def test_spaces_around_comparison_operators(self):
        self.assertIds("amount > 10", [2, 3, 4, 6])
        self.assertIds("amount >= -5 and amount < 0", [1, 5])
        self.assertIds("  amount   <=   -900  ", [3, 4, 6])

    def test_terms_apply_to_one_posting_together(self):
        self.assertIds("account:Assets:Bank:Checking amount>0", [3])
        self.assertIds("account:Assets:Bank:Checking amount<0", [1, 4])
        self.assertIds("account:Expenses:Food amount>10", [2, 6])
        self.assertIds("account:Expenses amount<0", [])
        self.assertIds("account:Assets:Cash and amount<=-12", [2, 6])

    def test_two_account_terms_cannot_share_a_posting(self):
        self.assertIds("account:Assets:Bank:Checking and account:Expenses", [])
        self.assertIds("account:Assets:Bank:Checking or account:Expenses", [1, 2, 3, 4, 5, 6])
        self.assertIds("account:Income or account:Expenses:Rent", [3, 4])

    def test_not_is_judged_per_posting(self):
        self.assertIds("not account:Expenses", [1, 2, 3, 4, 5, 6])   # every transaction has a posting outside Expenses
        self.assertIds("not account:Assets", [1, 2, 3, 4, 5, 6])
        self.assertIds("not account:Assets and not account:Expenses", [3])      # only Income:Salary of 3
        self.assertIds("not account:Assets:Cash and not account:Expenses", [1, 3, 4])

    def test_matching_postings(self):
        tx = book()[0]
        q = query().parse_query("account:Expenses and amount>4")
        self.assertEqual(q.matching_postings(tx), [tx.postings[0]])
        self.assertEqual(query().parse_query("payee:blue").matching_postings(tx), tx.postings)
        self.assertEqual(query().parse_query("amount<0").matching_postings(tx), [tx.postings[1]])
        self.assertEqual(query().parse_query("payee:zzz").matching_postings(tx), [])
        self.assertEqual(query().parse_query("not account:Expenses").matching_postings(tx), [tx.postings[1]])
        self.assertTrue(q.matches(tx))
        self.assertFalse(query().parse_query("amount>5").matches(tx))
        # `or` mixes a transaction-level term with a posting-level one
        self.assertEqual(query().parse_query("payee:blue or amount>100").matching_postings(tx), tx.postings)
        self.assertEqual(query().parse_query("payee:zzz or amount>4").matching_postings(tx), [tx.postings[0]])

    def test_chart_checks_account_patterns(self):
        chart = lib("accounts").Chart()
        for path in ("Expenses:Food", "Expenses:Rent", "Assets:Bank:Checking"):
            chart.add(path)
        q = query().parse_query("account:Expenses:Food", chart=chart)
        self.assertEqual(self.ids("", None), [1, 2, 3, 4, 5, 6])
        self.assertTrue(q.matches(book()[0]))
        for ok in ("account:Expenses", "account:Expenses:*", "account:**:Checking", "account:Assets:Bank:Checking"):
            with self.subTest(ok=ok):
                query().parse_query(ok, chart=chart)
        for bad in ("account:Expenses:Fun", "account:Income", "account:Assets:Cash"):
            with self.subTest(bad=bad):
                self.assertEqual(self.err(bad, chart=chart).position, 1)
        e = self.err("payee:x and account:Income", chart=chart)
        self.assertEqual(e.position, 13)
        query().parse_query("account:Income")      # without a chart nothing is checked


class M07Combining(M07Base):
    def test_implicit_and(self):
        self.assertIds("payee:bakery amount>5", [2])
        self.assertIds("payee:bakery payee:sweet", [2])
        self.assertIds("payee:bakery payee:bottle", [])
        self.assertIds("tag:coffee date:2024-03", [1])
        self.assertIds("payee:bakery and amount>5", [2])

    def test_or_and_and_precedence(self):
        # a or (b and c)
        self.assertIds("tag:coffee or payee:acme and date:2024-03", [1, 5])
        self.assertIds("tag:coffee or payee:acme and date:2024-02", [1, 3, 5])
        self.assertIds("payee:acme and date:2024-03 or tag:coffee", [1, 5])
        self.assertIds("(tag:coffee or payee:acme) and date:2024-03", [1])

    def test_not_precedence(self):
        self.assertIds("not tag:coffee payee:bakery", [2])             # (not coffee) and bakery
        self.assertIds("not (tag:coffee payee:bakery)", [1, 2, 3, 4, 5, 6])
        self.assertIds("not tag:coffee or payee:blue", [1, 2, 3, 4, 6])
        self.assertIds("not not tag:coffee", [1, 5])
        self.assertIds("not tag:coffee", [2, 3, 4, 6])
        self.assertIds("tag:coffee and not payee:euro", [1])
        self.assertIds("tag:coffee not payee:euro", [1])

    def test_parentheses(self):
        self.assertIds("(payee:acme or tag:coffee) date:2024-03", [1])
        self.assertIds("((payee:acme))", [3])
        self.assertIds("payee:acme or (tag:coffee and (date:2024-03 or date:2024-04))", [1, 3, 5])
        self.assertIds("(payee:acme)(tag:coffee)", [])
        self.assertIds("not (payee:acme or payee:bakery or tag:coffee)", [4, 6])

    def test_keywords_are_case_insensitive(self):
        self.assertIds("payee:acme OR payee:bakery", [2, 3])
        self.assertIds("NOT tag:coffee AND payee:bakery", [2])
        self.assertIds("payee:acme Or payee:bakery", [2, 3])

    def test_select_keeps_the_order_given_and_accepts_text_or_query(self):
        txs = list(reversed(book()))
        self.assertEqual([t.id for t in query().select(txs, "tag:coffee")], [5, 1])
        q = query().parse_query("tag:coffee")
        self.assertEqual([t.id for t in query().select(txs, q)], [5, 1])
        self.assertEqual(query().select([], "tag:coffee"), [])
        self.assertEqual(len(query().select(txs, "")), 6)
        self.assertEqual(q.text, "tag:coffee")
        self.assertEqual(repr(q), "Query('tag:coffee')")

    def test_a_parsed_query_is_reusable(self):
        q = query().parse_query("date:2024-03 amount>10")
        self.assertEqual([t.id for t in book() if q.matches(t)], [2, 4, 6])
        self.assertEqual([t.id for t in book() if q.matches(t)], [2, 4, 6])


class M07Errors(M07Base):
    POSITIONS = [
        ("colour:red", 1),
        ("payee:x colour:red", 9),
        ("payee:", 1),
        ("payee:x amount>", 9),
        ("amount>", 1),
        ("narration:", 1),
        ("tag:", 1),
        ("id:abc", 1),
        ("id:-3", 1),
        ("flag:x", 1),
        ("flag:", 1),
        ("date:2024-13", 1),
        ("date:March", 1),
        ("date>=2024-02-30", 1),
        ("date>=2024-03", 1),
        ("amount>abc", 1),
        ("amount>10usd", 1),
        ("amount>1e3", 1),
        ("amount:5", 1),
        ('payee:""', 1),
        ('""', 1),
        ('x and payee:""', 7),
        ('payee:"abc', 7),
        ('"abc', 1),
        ('a and "abc', 7),
        ('"abc"def', 6),
        ('payee:"abc"def', 12),
        ("a and", 6),
        ("payee:x and ", 13),
        ("or a", 1),
        ("a or or b", 6),
        ("a and and b", 7),
        ("()", 2),
        ("not", 4),
        ("a not", 6),
        ("(a and)", 7),
        ("a)", 2),
        ("(a))", 4),
        (")", 1),
        ("(a", 1),
        ("a (b or c", 3),
        ("((a)", 1),
    ]

    def test_positions(self):
        for text, pos in self.POSITIONS:
            with self.subTest(text=text):
                e = self.err(text)
                self.assertEqual(e.position, pos)
                self.assertTrue(e.message.endswith("at position %d" % pos), e.message)

    def test_error_class_and_code(self):
        e = self.err("colour:red")
        self.assertIsInstance(e, lib("errors").ParseError)
        self.assertEqual(e.code, "parse")
        self.assertIn("position 1", str(e))
        with self.assertRaises(query().QueryError):
            query().select(book(), "payee:")

    def test_valid_edge_queries_do_not_raise(self):
        for text in ("a", "(a)", "not a", "a b c", "a or b or c", "account:**", "payee:x\\y", 'payee:"a\\"b"',
                     "date:2024-03-01..2024-03-31", "amount>-0.5", "amount<=+7USD"):
            with self.subTest(text=text):
                query().parse_query(text)


if __name__ == "__main__":
    unittest.main()

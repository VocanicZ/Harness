"""Module 06: the text journal (tallybook.journal): parsing, strict errors, canonical formatting. Black box."""
import datetime as dt
import unittest
from fractions import Fraction

from support import lib

D = dt.date

CANONICAL = '''account Assets:Bank:Checking USD open 2023-01-01 "main account"
account Income:Salary

rate 2024-03-01 USD EUR 0.92

2024-03-01 * "Employer" "March pay" #salary
  Income:Salary         -2500.00 USD
  Assets:Bank:Checking   2500.00 USD  ; net of tax

2024-03-02 ! "Corner shop"
  Expenses:Food  12.50 USD
  Assets:Cash
'''


def J():
    return lib("journal")


def money(minor, cur="USD"):
    return lib("money").Money(minor, cur)


def posting(account, minor=None, cur="USD", note=""):
    return lib("model").Posting(account, None if minor is None else money(minor, cur), note)


def transaction(day, postings, payee="Shop", narration="", tags=(), flag="*"):
    return lib("model").Transaction(day, payee, narration, list(postings), tags, flag)


def error_of(text):
    with unittest.TestCase().assertRaises(J().JournalError) as ctx:
        J().parse_journal(text)
    return ctx.exception


class M06Reading(unittest.TestCase):
    def test_parse_the_sample(self):
        j = J().parse_journal(CANONICAL)
        self.assertIsInstance(j, J().Journal)
        self.assertEqual([a.path for a in j.accounts], ["Assets:Bank:Checking", "Income:Salary"])
        a = j.accounts[0]
        self.assertEqual((a.type, a.currency, a.opened, a.closed, a.note),
                         ("asset", "USD", D(2023, 1, 1), None, "main account"))
        b = j.accounts[1]
        self.assertEqual((b.type, b.currency, b.opened, b.closed, b.note), ("income", None, None, None, ""))
        self.assertEqual(j.rates, [("USD", "EUR", D(2024, 3, 1), "0.92")])
        self.assertEqual(len(j.transactions), 2)
        t = j.transactions[0]
        self.assertEqual((t.date, t.flag, t.payee, t.narration, t.tags, t.id),
                         (D(2024, 3, 1), "*", "Employer", "March pay", ("salary",), None))
        self.assertEqual([(p.account, p.amount, p.note) for p in t.postings],
                         [("Income:Salary", money(-250000), ""), ("Assets:Bank:Checking", money(250000), "net of tax")])
        t2 = j.transactions[1]
        self.assertEqual((t2.flag, t2.payee, t2.narration, t2.tags), ("!", "Corner shop", "", ()))
        self.assertEqual([(p.account, p.amount) for p in t2.postings],
                         [("Expenses:Food", money(1250)), ("Assets:Cash", None)])

    def test_empty_and_comment_only_texts(self):
        for text in ("", "\n", "\n\n  \n", "; nothing\n", "# nothing\n  ; indented\n\n", "﻿", "﻿\n"):
            with self.subTest(text=text):
                j = J().parse_journal(text)
                self.assertEqual((j.accounts, j.rates, j.transactions), ([], [], []))

    def test_bom_and_crlf_are_tolerated(self):
        plain = J().parse_journal(CANONICAL)
        crlf = CANONICAL.replace("\n", "\r\n")
        self.assertEqual(J().parse_journal(crlf), plain)
        self.assertEqual(J().parse_journal("﻿" + CANONICAL), plain)
        self.assertEqual(J().parse_journal("﻿" + crlf), plain)

    def test_last_line_without_a_newline(self):
        j = J().parse_journal('2024-01-01 "A"\n  Assets:Cash  1.00 USD\n  Expenses:Food  -1.00 USD')
        self.assertEqual(len(j.transactions[0].postings), 2)

    def test_comments_are_ignored(self):
        text = ('; top comment\n# another\naccount Assets:Cash USD  ; trailing\n  # indented comment\n\n'
                'rate 2024-01-01 USD EUR 0.9 ; trailing\n\n'
                '2024-01-01 * "A" "B" #t ; trailing\n'
                '  ; a comment inside\n'
                '  Expenses:Food  1.00 USD\n'
                '# a column-0 comment inside\n'
                '  Assets:Cash  -1.00 USD\n')
        j = J().parse_journal(text)
        self.assertEqual(len(j.accounts), 1)
        self.assertEqual(j.accounts[0].note, "")
        self.assertEqual(len(j.rates), 1)
        self.assertEqual([p.account for p in j.transactions[0].postings], ["Expenses:Food", "Assets:Cash"])
        self.assertEqual(j.transactions[0].narration, "B")

    def test_posting_notes(self):
        j = J().parse_journal('2024-01-01 "A"\n  Expenses:Food  1.00 USD ; coffee, black \n  Assets:Cash ;\n'
                              '  Assets:Bank  -1.00 USD;tight\n')
        notes = [p.note for p in j.transactions[0].postings]
        self.assertEqual(notes, ["coffee, black", "", "tight"])
        self.assertEqual([p.amount for p in j.transactions[0].postings], [money(100), None, money(-100)])

    def test_semicolon_inside_a_quoted_string_is_text(self):
        j = J().parse_journal('2024-01-01 "A; B" "C # D" ; real comment\n  Assets:Cash  1.00 USD\n')
        self.assertEqual((j.transactions[0].payee, j.transactions[0].narration), ("A; B", "C # D"))

    def test_transaction_line_variants(self):
        text = ('2024-01-01 "OnlyPayee"\n\n2024-01-02 ! "P" "N"\n\n2024-01-03 * "" "Only narration"\n\n'
                '2024-01-04 "P" #b #a #b #c-1\n\n2024-01-05   *   "Spaced"    "Out"   #x\n')
        got = [(t.date.day, t.flag, t.payee, t.narration, t.tags) for t in J().parse_journal(text).transactions]
        self.assertEqual(got, [(1, "*", "OnlyPayee", "", ()), (2, "!", "P", "N", ()),
                               (3, "*", "", "Only narration", ()), (4, "*", "P", "", ("a", "b", "c-1")),
                               (5, "*", "Spaced", "Out", ("x",))])

    def test_string_escapes(self):
        j = J().parse_journal('2024-01-01 "He said \\"hi\\"" "back\\\\slash \\\\"\n')
        t = j.transactions[0]
        self.assertEqual(t.payee, 'He said "hi"')
        self.assertEqual(t.narration, "back\\slash \\")

    def test_unicode_text(self):
        j = J().parse_journal('2024-01-01 "Café Zoë" "naïve 日本語"\n')
        self.assertEqual((j.transactions[0].payee, j.transactions[0].narration), ("Café Zoë", "naïve 日本語"))

    def test_tabs_work_as_indentation_and_separators(self):
        j = J().parse_journal('2024-01-01\t*\t"A"\n\tExpenses:Food\t\t1.00\tUSD\n \tAssets:Cash\t-1.00 USD\n')
        self.assertEqual([p.amount for p in j.transactions[0].postings], [money(100), money(-100)])

    def test_amount_forms(self):
        j = J().parse_journal('2024-01-01 "A"\n  Assets:A  +5 JPY\n  Assets:B  -0.005 KWD\n  Assets:C  0.50 EUR\n'
                              '  Assets:D  -12 JPY\n')
        self.assertEqual([p.amount for p in j.transactions[0].postings],
                         [money(5, "JPY"), money(-5, "KWD"), money(50, "EUR"), money(-12, "JPY")])

    def test_account_directive_forms(self):
        text = ('account Assets:A\naccount Assets:B EUR\naccount Assets:C open 2024-01-01\n'
                'account Assets:D close 2024-12-31\naccount Assets:E JPY open 2024-01-01 close 2024-12-31 "old yen"\n'
                'account Assets:F "just a note"\naccount Expenses:G USD "n;ote"  ; comment\n')
        got = [(a.path, a.type, a.currency, a.opened, a.closed, a.note) for a in J().parse_journal(text).accounts]
        self.assertEqual(got, [
            ("Assets:A", "asset", None, None, None, ""), ("Assets:B", "asset", "EUR", None, None, ""),
            ("Assets:C", "asset", None, D(2024, 1, 1), None, ""), ("Assets:D", "asset", None, None, D(2024, 12, 31), ""),
            ("Assets:E", "asset", "JPY", D(2024, 1, 1), D(2024, 12, 31), "old yen"),
            ("Assets:F", "asset", None, None, None, "just a note"), ("Expenses:G", "expense", "USD", None, None, "n;ote")])

    def test_rate_forms_are_kept_as_written(self):
        text = 'rate 2024-01-01 USD EUR 0.920\nrate 2024-01-02 EUR JPY 150\nrate 2024-01-03 USD KWD 0.30700000\n'
        self.assertEqual([r[3] for r in J().parse_journal(text).rates], ["0.920", "150", "0.30700000"])
        self.assertEqual(J().parse_journal(text).rates[1], ("EUR", "JPY", D(2024, 1, 2), "150"))

    def test_a_transaction_without_postings_is_readable(self):
        j = J().parse_journal('2024-01-01 "A"\n\n2024-01-02 "B"\n  Assets:Cash  1.00 USD\n')
        self.assertEqual([len(t.postings) for t in j.transactions], [0, 1])

    def test_unbalanced_text_still_parses(self):
        j = J().parse_journal('2024-01-01 "A"\n  Assets:Cash  1.00 USD\n  Expenses:Food  5.00 USD\n')
        self.assertEqual(len(j.transactions[0].postings), 2)


class M06ReadingErrors(unittest.TestCase):
    def check(self, text, line):
        e = error_of(text)
        self.assertEqual(e.line, line, (text, str(e)))
        self.assertTrue(str(e).startswith("line %d: " % line), str(e))
        self.assertEqual(e.message, str(e))
        return e

    def test_error_class(self):
        errors = lib("errors")
        self.assertTrue(issubclass(J().JournalError, errors.ParseError))
        e = error_of("bogus\n")
        self.assertEqual(e.code, "parse")
        self.assertIsInstance(e, errors.TallybookError)

    def test_unknown_directives(self):
        for text in ("bogus\n", "include other.journal\n", "Accounts Assets:Cash\n", "- 2024-01-01\n", "x: y\n"):
            with self.subTest(text=text):
                self.check(text, 1)

    def test_line_numbers_count_blank_and_comment_lines(self):
        self.check("; c\n\n# d\n\nbogus\n", 5)
        self.check("account Assets:Cash\n\n\nrate 2024-01-01 USD USD 1\n", 4)

    def test_line_numbers_with_crlf_and_bom(self):
        self.check("﻿; c\r\n\r\nbogus\r\n", 3)
        self.check("﻿bogus\r\n", 1)

    def test_only_the_first_mistake_is_reported(self):
        self.check("account Assets:Cash\nbogus\nalso bogus\n", 2)

    def test_account_line_mistakes(self):
        for text in ("account\n", "account assets:cash\n", "account Savings:Bank\n", "account Assets:Cash ZZZ\n",
                     "account Assets:Cash usd\n", "account Assets:Cash open\n", "account Assets:Cash open 2024-02-30\n",
                     "account Assets:Cash close 2024-1-1\n", "account Assets:Cash close 2024-01-01 open 2023-01-01\n",
                     "account Assets:Cash open 2024-05-01 close 2024-04-30\n", 'account Assets:Cash "unterminated\n',
                     'account Assets:Cash "a" "b"\n', "account Assets:Cash extra\n", "account Assets:Cash USD USD\n"):
            with self.subTest(text=text):
                self.check(text, 1)

    def test_duplicate_account_is_reported_on_the_second(self):
        self.check("account Assets:Cash\naccount Assets:Bank\n\naccount Assets:Cash USD\n", 4)

    def test_rate_line_mistakes(self):
        for text in ("rate\n", "rate 2024-01-01 USD EUR\n", "rate 2024-01-01 USD EUR 0.9 extra\n",
                     "rate 2024-02-30 USD EUR 0.9\n", "rate 2024-01-01 USD USD 1\n", "rate 2024-01-01 USD ZZZ 1\n",
                     "rate 2024-01-01 usd EUR 1\n", "rate 2024-01-01 USD EUR 0\n", "rate 2024-01-01 USD EUR 0.000\n",
                     "rate 2024-01-01 USD EUR -1\n", "rate 2024-01-01 USD EUR .5\n", "rate 2024-01-01 USD EUR 1.\n",
                     "rate 2024-01-01 USD EUR 1e3\n", "rate 2024-01-01 USD EUR 0.123456789\n",
                     "rate 2024-01-01 USD EUR 1,5\n", "rate USD EUR 0.9\n"):
            with self.subTest(text=text):
                self.check(text, 1)

    def test_transaction_line_mistakes(self):
        for text in ("2024-02-30 \"A\"\n", "2024-3-1 \"A\"\n", "2024-01-01\n", "2024-01-01 *\n", "2024-01-01 Shop\n",
                     '2024-01-01 "A" "B" "C"\n', '2024-01-01 "A" B\n', '2024-01-01 "A" #\n', '2024-01-01 "A" #-x\n',
                     '2024-01-01 "A" #a#b\n', '2024-01-01 #t "A"\n', '2024-01-01 "A" #t "B"\n',
                     '2024-01-01 "unterminated\n', '2024-01-01 "bad \\n escape"\n',
                     '2024-01-01 "A" *\n', '2024-01-01 ? "A"\n', '2024-01-01 "trailing backslash\\\n',
                     '2024-01-01x "A"\n', '20240101 "A"\n'):
            with self.subTest(text=text):
                self.check(text, 1)

    def test_posting_mistakes(self):
        header = '2024-01-01 "A"\n'
        for posting in ("Assets:Cash 1.005 USD", "Assets:Cash 1 JPY 2", "Assets:Cash 1.00", "Assets:Cash USD",
                        "Assets:Cash 1.00 ZZZ", "Assets:Cash 1.0 JPY", "Assets:Cash 1,000.00 USD", "Assets:Cash 1.00 usd",
                        "Assets:Cash .5 USD", "Assets:Cash 1. USD", "assets:cash 1.00 USD", "Nowhere:Cash 1.00 USD",
                        "Assets:Cash:  1.00 USD", "Assets:Cash 1.00 USD extra",
                        "Assets:Cash 1.00 USD 2.00 USD", "Assets:Cash - 1.00 USD", "Assets:Cash 1.00USD"):
            with self.subTest(posting=posting):
                self.check(header + "  " + posting + "\n", 2)

    def test_mistake_in_a_later_posting_names_that_line(self):
        self.check('; c\n2024-01-01 "A"\n  Assets:Cash  1.00 USD\n  ; note\n  Expenses:Food  nope USD\n', 5)

    def test_posting_outside_a_transaction(self):
        self.check("  Assets:Cash  1.00 USD\n", 1)
        self.check('2024-01-01 "A"\n  Assets:Cash  1.00 USD\n\n  Expenses:Food  -1.00 USD\n', 4)
        self.check("account Assets:Cash\n  Assets:Cash  1.00 USD\n", 2)
        self.check('rate 2024-01-01 USD EUR 1\n  Assets:Cash\n', 2)

    def test_a_non_indented_line_ends_the_transaction(self):
        self.check('2024-01-01 "A"\n  Assets:Cash  1.00 USD\nExpenses:Food  -1.00 USD\n', 3)

    def test_the_mistake_is_reported_even_after_good_content(self):
        text = CANONICAL + "\n2024-03-03 \"Bad\"\n  Assets:Cash  1,00 USD\n"
        self.check(text, CANONICAL.count("\n") + 3)


class M06Writing(unittest.TestCase):
    def test_sample_round_trips_exactly(self):
        self.assertEqual(J().format_journal(J().parse_journal(CANONICAL)), CANONICAL)

    def test_formatting_a_built_journal(self):
        model = lib("model")
        j = J().Journal(
            accounts=[model.Account("Assets:Bank:Checking", "asset", "USD", D(2023, 1, 1), None, "main account"),
                      model.Account("Income:Salary", "income")],
            rates=[("USD", "EUR", D(2024, 3, 1), "0.92")],
            transactions=[
                transaction(D(2024, 3, 1), [posting("Income:Salary", -250000), posting("Assets:Bank:Checking", 250000, note="net of tax")],
                            payee="Employer", narration="March pay", tags=("salary",)),
                transaction(D(2024, 3, 2), [posting("Expenses:Food", 1250), posting("Assets:Cash")],
                            payee="Corner shop", flag="!")])
        self.assertEqual(J().format_journal(j), CANONICAL)

    def test_empty_journal(self):
        self.assertEqual(J().format_journal(J().Journal()), "")
        self.assertEqual(J().format_journal(J().parse_journal("")), "")

    def test_journal_defaults_are_independent(self):
        a, b = J().Journal(), J().Journal()
        a.accounts.append(lib("model").Account("Assets:X", "asset"))
        self.assertEqual(b.accounts, [])
        self.assertEqual(J().Journal(), J().Journal())
        self.assertNotEqual(a, b)

    def test_groups_are_left_out_when_empty(self):
        model = lib("model")
        acct = model.Account("Assets:Cash", "asset")
        tx = transaction(D(2024, 1, 1), [posting("Expenses:Food", 100), posting("Assets:Cash", -100)])
        rate = [("USD", "EUR", D(2024, 1, 1), "0.9")]
        text_tx = '2024-01-01 * "Shop"\n  Expenses:Food   1.00 USD\n  Assets:Cash    -1.00 USD\n'
        self.assertEqual(J().format_journal(J().Journal(transactions=[tx])), text_tx)
        self.assertEqual(J().format_journal(J().Journal(accounts=[acct])), "account Assets:Cash\n")
        self.assertEqual(J().format_journal(J().Journal(rates=rate)), "rate 2024-01-01 USD EUR 0.9\n")
        self.assertEqual(J().format_journal(J().Journal(accounts=[acct], transactions=[tx])),
                         "account Assets:Cash\n\n" + text_tx)
        self.assertEqual(J().format_journal(J().Journal(rates=rate, transactions=[tx])),
                         "rate 2024-01-01 USD EUR 0.9\n\n" + text_tx)
        self.assertEqual(J().format_journal(J().Journal(transactions=[tx, tx])), text_tx + "\n" + text_tx)

    def test_list_order_is_kept(self):
        model = lib("model")
        j = J().Journal(accounts=[model.Account("Assets:Z", "asset"), model.Account("Assets:A", "asset")],
                        rates=[("USD", "EUR", D(2024, 5, 1), "1"), ("USD", "EUR", D(2024, 1, 1), "2")],
                        transactions=[transaction(D(2024, 5, 1), [], payee="late"),
                                      transaction(D(2024, 1, 1), [], payee="early")])
        self.assertEqual(J().format_journal(j),
                         'account Assets:Z\naccount Assets:A\n\nrate 2024-05-01 USD EUR 1\nrate 2024-01-01 USD EUR 2\n\n'
                         '2024-05-01 * "late"\n\n2024-01-01 * "early"\n')

    def test_account_line_forms(self):
        model = lib("model")
        accounts = [model.Account("Assets:A", "asset"), model.Account("Assets:B", "asset", "EUR"),
                    model.Account("Assets:C", "asset", None, D(2024, 1, 1)),
                    model.Account("Assets:D", "asset", None, None, D(2024, 12, 31)),
                    model.Account("Assets:E", "asset", "JPY", D(2024, 1, 1), D(2024, 12, 31), "old \"yen\""),
                    model.Account("Assets:F", "asset", None, None, None, "just a note")]
        self.assertEqual(J().format_journal(J().Journal(accounts=accounts)), (
            'account Assets:A\naccount Assets:B EUR\naccount Assets:C open 2024-01-01\n'
            'account Assets:D close 2024-12-31\naccount Assets:E JPY open 2024-01-01 close 2024-12-31 "old \\"yen\\""\n'
            'account Assets:F "just a note"\n'))

    def test_alignment_rule(self):
        tx = transaction(D(2024, 5, 6), [
            posting("Expenses:Food:Groceries", 123456), posting("Expenses:Rent", 5),
            posting("Liabilities:Card", -123461), posting("Assets:Cash", None)], payee="Mixed")
        self.assertEqual(J().format_transaction(tx), (
            '2024-05-06 * "Mixed"\n'
            '  Expenses:Food:Groceries   1234.56 USD\n'
            '  Expenses:Rent                0.05 USD\n'
            '  Liabilities:Card         -1234.61 USD\n'
            '  Assets:Cash\n'))

    def test_account_width_ignores_postings_without_amounts(self):
        tx = transaction(D(2024, 5, 6), [posting("Expenses:Food", 100), posting("Assets:Bank:Checking:Very:Long")])
        self.assertEqual(J().format_transaction(tx),
                         '2024-05-06 * "Shop"\n  Expenses:Food  1.00 USD\n  Assets:Bank:Checking:Very:Long\n')

    def test_mixed_currencies_align_on_the_right_edge_of_the_number(self):
        tx = transaction(D(2024, 5, 6), [posting("Assets:A", 1000000, "JPY"), posting("Assets:Bk", -5, "KWD"),
                                         posting("Assets:Cash", 2500, "EUR")])
        self.assertEqual(J().format_transaction(tx), (
            '2024-05-06 * "Shop"\n'
            '  Assets:A     1000000 JPY\n'
            '  Assets:Bk     -0.005 KWD\n'
            '  Assets:Cash    25.00 EUR\n'))

    def test_notes_follow_after_two_spaces(self):
        tx = transaction(D(2024, 5, 6), [posting("Expenses:Food", 100, note="coffee"),
                                         posting("Assets:Cash", note="from wallet")])
        self.assertEqual(J().format_transaction(tx),
                         '2024-05-06 * "Shop"\n  Expenses:Food  1.00 USD  ; coffee\n  Assets:Cash  ; from wallet\n')

    def test_transaction_line_forms(self):
        t = transaction(D(2024, 5, 6), [], payee='Say "hi" \\ bye', narration="a ; b", tags=("zed", "alpha", "alpha"), flag="!")
        self.assertEqual(J().format_transaction(t), '2024-05-06 ! "Say \\"hi\\" \\\\ bye" "a ; b" #alpha #zed\n')
        self.assertEqual(J().format_transaction(transaction(D(2024, 5, 6), [], payee="")), '2024-05-06 * ""\n')
        self.assertEqual(J().format_transaction(transaction(D(2024, 5, 6), [], payee="", narration="n")),
                         '2024-05-06 * "" "n"\n')

    def test_format_transaction_ends_with_one_newline_and_no_trailing_spaces(self):
        tx = transaction(D(2024, 5, 6), [posting("Expenses:Food", 100), posting("Assets:Cash", -100)])
        text = J().format_transaction(tx)
        self.assertTrue(text.endswith("\n") and not text.endswith("\n\n"))
        self.assertTrue(all(line == line.rstrip() for line in text.splitlines()))
        self.assertNotIn("\r", text)

    def test_parse_of_format_gives_the_same_journal(self):
        model = lib("model")
        j = J().Journal(
            accounts=[model.Account("Assets:Cash", "asset", "USD", D(2024, 1, 1), D(2024, 9, 9), 'a "b" c'),
                      model.Account("Expenses:Food", "expense")],
            rates=[("EUR", "JPY", D(2024, 2, 2), "160.5")],
            transactions=[
                transaction(D(2024, 2, 2), [posting("Expenses:Food", 1234, note="x y"), posting("Assets:Cash")],
                            payee='Joe\'s "Place"', narration="back\\slash", tags=("a", "b-c")),
                transaction(D(2024, 2, 3), [posting("Assets:Cash", -700, "JPY"), posting("Expenses:Food", 700, "JPY")],
                            payee="Ünï", flag="!")])
        self.assertEqual(J().parse_journal(J().format_journal(j)), j)

    def test_format_normalises_a_messy_file(self):
        messy = ('﻿# my book\r\naccount   Assets:Cash   USD  ; cash\r\n\r\n\r\nrate 2024-01-01   USD  EUR  0.9\r\n'
                 '2024-01-01   "Shop"  #b   #a\r\n   Expenses:Food     5.5  USD   ;   tea \r\n\tAssets:Cash\r\n')
        self.assertEqual(J().format_journal(J().parse_journal(messy)),
                         'account Assets:Cash USD\n\nrate 2024-01-01 USD EUR 0.9\n\n'
                         '2024-01-01 * "Shop" #a #b\n  Expenses:Food  5.50 USD  ; tea\n  Assets:Cash\n')

    def test_format_is_idempotent(self):
        once = J().format_journal(J().parse_journal(CANONICAL.replace("  ", "    ")))
        self.assertEqual(once, CANONICAL)
        self.assertEqual(J().format_journal(J().parse_journal(once)), once)


class M06ToLedger(unittest.TestCase):
    TEXT = ('account Assets:Bank USD open 2024-01-01\naccount Assets:Old close 2024-02-29\n'
            'account Equity:Opening\naccount Expenses:Food\n\nrate 2024-01-01 USD EUR 0.92\n\n'
            '2024-01-02 "Start"\n  Assets:Bank  1000.00 USD\n  Equity:Opening\n\n'
            '2024-01-05 * "Shop" "food"\n  Expenses:Food  25.00 USD\n  Assets:Bank\n')

    def test_builds_a_ledger(self):
        ledger = J().parse_journal(self.TEXT).to_ledger()
        self.assertIsInstance(ledger, lib("ledger").Ledger)
        self.assertEqual([t.id for t in ledger.transactions()], [1, 2])
        self.assertEqual(ledger.balance("Assets:Bank", currency="USD"), money(97500))
        self.assertEqual(ledger.balance("Equity:Opening", currency="USD"), money(-100000))
        chart = ledger.chart
        self.assertEqual(chart.get("Assets:Bank").currency, "USD")
        self.assertEqual(chart.get("Assets:Bank").opened, D(2024, 1, 1))
        self.assertEqual(chart.get("Assets:Old").closed, D(2024, 2, 29))
        self.assertTrue(chart.exists("Assets"))
        self.assertEqual(ledger.rates.rate("USD", "EUR", D(2024, 6, 1)), Fraction(23, 25))

    def test_inferred_amounts_are_filled_in(self):
        ledger = J().parse_journal(self.TEXT).to_ledger()
        self.assertEqual([p.amount for p in ledger.get(2).postings], [money(2500), money(-2500)])

    def test_empty_journal_gives_an_empty_ledger(self):
        ledger = J().Journal().to_ledger()
        self.assertEqual(len(ledger), 0)
        self.assertEqual(ledger.chart.accounts(), [])

    def test_ledger_errors_come_out_unchanged(self):
        ledger_error = lib("ledger").LedgerError
        for text, needle in (
                ('account Assets:Cash\naccount Expenses:Food\n\n2024-01-01 "A"\n  Assets:Cash 1.00 USD\n  Expenses:Food 5.00 USD\n',
                 "does not balance"),
                ('account Assets:Cash\n\n2024-01-01 "A"\n  Assets:Cash 1.00 USD\n  Expenses:Nope -1.00 USD\n', "unknown account"),
                ('account Assets:Cash\naccount Expenses:Food open 2025-01-01\n\n2024-01-01 "A"\n  Assets:Cash 1.00 USD\n'
                 '  Expenses:Food -1.00 USD\n', "is not open on"),
                ('account Assets:Cash\n\n2024-01-01 "A"\n  Assets:Cash 1.00 USD\n', "at least two")):
            with self.subTest(needle=needle):
                with self.assertRaises(ledger_error) as ctx:
                    J().parse_journal(text).to_ledger()
                self.assertIn(needle, str(ctx.exception))

    def test_duplicate_accounts_in_a_built_journal_are_chart_errors(self):
        model = lib("model")
        j = J().Journal(accounts=[model.Account("Assets:A", "asset"), model.Account("Assets:A", "asset")])
        with self.assertRaises(lib("accounts").ChartError):
            j.to_ledger()

    def test_format_a_ledger_back(self):
        ledger = J().parse_journal(self.TEXT).to_ledger()
        journal = J().Journal(transactions=ledger.transactions())
        text = J().format_journal(journal)
        self.assertEqual(J().format_journal(J().parse_journal(text)), text)
        self.assertEqual(J().format_journal(journal), (
            '2024-01-02 * "Start"\n  Assets:Bank      1000.00 USD\n  Equity:Opening  -1000.00 USD\n\n'
            '2024-01-05 * "Shop" "food"\n  Expenses:Food   25.00 USD\n  Assets:Bank    -25.00 USD\n'))


if __name__ == "__main__":
    unittest.main()

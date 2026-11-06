"""Module 09: bank CSV import (tallybook.csvimport)."""
import unittest
from datetime import date

from support import lib

DEFAULTS = [
    ("date_column", "Date"),
    ("payee_column", "Payee"),
    ("narration_column", "Memo"),
    ("amount_column", "Amount"),
    ("currency", "USD"),
    ("account", "Assets:Bank:Checking"),
    ("default_account", "Expenses:Uncategorized"),
]
BANK = "Assets:Bank:Checking"
CSV = "Date,Payee,Memo,Amount\n2024-03-01,Blue Bottle,latte,-4.50\n2024-03-02,ACME,pay,2500.00\n"


def profile_text(**over):
    """The default profile with settings replaced (value None removes one, new names are appended)."""
    settings = dict(DEFAULTS)
    settings.update(over)
    return "".join("%s = %s\n" % (k, v) for k, v in settings.items() if v is not None)


def mod():
    return lib("csvimport")


def money(text):
    return lib("money").Money.parse(text)


def import_(text, rules=None, existing=(), **over):
    return mod().import_csv(text, mod().parse_profile(profile_text(**over)), rules, existing)


def tx(day, payee, amount, account=BANK, other="Expenses:Uncategorized"):
    model = lib("model")
    m = money(amount)
    return model.Transaction(date=day, payee=payee, narration="", postings=[
        model.Posting(account, m), model.Posting(other, -m)])


class M09Base(unittest.TestCase):
    def perr(self, text):
        with self.assertRaises(mod().CsvImportError) as cm:
            mod().parse_profile(text)
        return cm.exception

    def amounts(self, result):
        return [t.postings[0].amount.amount_str() for t in result.transactions]


class M09Profile(M09Base):
    def test_defaults(self):
        p = mod().parse_profile(profile_text(narration_column=None, default_account=None))
        self.assertIsInstance(p, mod().ImportProfile)
        self.assertEqual((p.date_column, p.payee_column, p.amount_column), ("Date", "Payee", "Amount"))
        self.assertEqual((p.currency, p.account), ("USD", BANK))
        self.assertEqual((p.narration_column, p.debit_column, p.credit_column, p.default_account), (None,) * 4)
        self.assertEqual((p.date_format, p.delimiter, p.skip_rows, p.has_header, p.negate),
                         ("%Y-%m-%d", ",", 0, True, False))
        self.assertEqual((p.decimal_separator, p.thousands_separator, p.flag, p.tags), (".", "", "*", ()))

    def test_every_setting(self):
        text = """# My bank
date_column = Booking date
date_format = %d.%m.%Y
payee_column = #3
narration_column = "Reference text"
debit_column = Debit
credit_column = Credit
currency = EUR
account = Assets:Bank
default_account = Expenses:Other
delimiter = semicolon
skip_rows = 2
has_header = YES
negate = true
decimal_separator = ,
thousands_separator = dot
flag = !
tags = Imported, bank
"""
        p = mod().parse_profile(text)
        self.assertEqual((p.date_column, p.date_format, p.payee_column), ("Booking date", "%d.%m.%Y", "#3"))
        self.assertEqual((p.narration_column, p.debit_column, p.credit_column, p.amount_column),
                         ("Reference text", "Debit", "Credit", None))
        self.assertEqual((p.currency, p.account, p.default_account), ("EUR", "Assets:Bank", "Expenses:Other"))
        self.assertEqual((p.delimiter, p.skip_rows, p.has_header, p.negate), (";", 2, True, True))
        self.assertEqual((p.decimal_separator, p.thousands_separator, p.flag), (",", ".", "!"))
        self.assertEqual(p.tags, ("bank", "imported"))

    def test_delimiter_and_thousands_words_and_characters(self):
        for value, want in (("comma", ","), ("tab", "\t"), ("semicolon", ";"), ("pipe", "|"), ("space", " "),
                            (";", ";"), ("|", "|")):
            with self.subTest(delimiter=value):
                self.assertEqual(mod().parse_profile(profile_text(delimiter=value)).delimiter, want)
        for value, want in (("none", ""), ("comma", ","), ("dot", "."), ("space", " "), ("apostrophe", "'"),
                            (",", ","), ("'", "'"), ('" "', " ")):
            with self.subTest(thousands=value):
                text = profile_text(thousands_separator=value, decimal_separator="," if want == "." else ".")
                self.assertEqual(mod().parse_profile(text).thousands_separator, want)

    def test_comments_blank_lines_spaces_and_quotes(self):
        text = "﻿\n# comment\n\n   date_column   =   Date  \npayee_column=Payee\n  # another\namount_column = #4\n" \
               "currency = USD\naccount = Assets:Cash\nnarration_column = \"  Memo  \"\n"
        p = mod().parse_profile(text)
        self.assertEqual((p.date_column, p.payee_column, p.amount_column, p.narration_column),
                         ("Date", "Payee", "#4", "  Memo  "))

    def test_hash_inside_a_value_is_not_a_comment(self):
        p = mod().parse_profile(profile_text(date_column="#1", payee_column="#2", amount_column="#3", narration_column=None))
        self.assertEqual((p.date_column, p.payee_column, p.amount_column), ("#1", "#2", "#3"))

    def test_bad_lines_name_their_line(self):
        base = profile_text()
        last = base.count("\n") + 1
        bad = ["nonsense", "colour = red", "date_column = Other", "currency = EUR", "narration_column = #0",
               "default_account = #x", "payee_column =", "account = expenses:food", "default_account = Bad::Path",
               "default_account = Expenses:", "currency = ZZZ", "date_format = %Y-%m", "date_format = %Q-%m-%d",
               "date_format = %Y %Y %m %d", "date_format = %d/%m", "date_format = %y-%m-%d-%B-%b",
               "date_format = %m-%d", "date_format = %Y-%m-%d %", "delimiter = ab", 'delimiter = "', "delimiter =",
               "skip_rows = -1", "skip_rows = two", "skip_rows = 1.5", "has_header = maybe", "negate = 1",
               "decimal_separator = ;", "decimal_separator = comma", "thousands_separator = x", "flag = ?", "flag = **",
               "tags =", "tags = a b!", "tags = ,"]
        for line in bad:
            with self.subTest(line=line):
                e = self.perr(base + line + "\n")
                self.assertEqual(e.line, last)
                self.assertTrue(e.message.startswith("line %d: " % last), e.message)

    def test_error_line_counts_comment_and_blank_lines(self):
        e = self.perr("# one\n\ndate_column = Date\n# four\nwhat is this\n")
        self.assertEqual(e.line, 5)
        self.assertIsInstance(e, lib("errors").ParseError)
        self.assertEqual(e.code, "parse")

    def test_column_names_need_a_header(self):
        e = self.perr("date_column = Date\n" + profile_text(date_column=None) + "has_header = no\n")
        self.assertEqual(e.line, 1)
        p = mod().parse_profile("has_header = no\n" + profile_text(date_column="#1", payee_column="#2",
                                                                    amount_column="#3", narration_column=None))
        self.assertFalse(p.has_header)
        e = self.perr(profile_text(has_header="no"))
        self.assertIsNotNone(e.line)

    def test_whole_profile_problems_have_no_line(self):
        problems = [
            profile_text(date_column=None), profile_text(payee_column=None), profile_text(currency=None),
            profile_text(account=None),
            profile_text(amount_column=None),                                       # no amount at all
            profile_text(debit_column="Debit"),                                     # amount and debit
            profile_text(amount_column=None, debit_column="Debit"),                 # debit alone
            profile_text(amount_column=None, credit_column="Credit"),               # credit alone
            profile_text(debit_column="Debit", credit_column="Credit"),             # both styles
            profile_text(decimal_separator=",", thousands_separator="comma"),       # same separator
            profile_text(thousands_separator="dot"),                                # default decimal is a dot
            "",
        ]
        for text in problems:
            with self.subTest(text=text):
                self.assertIsNone(self.perr(text).line)

    def test_a_good_profile_is_accepted_with_either_amount_style(self):
        mod().parse_profile(profile_text(amount_column=None, debit_column="Out", credit_column="In"))
        mod().parse_profile(profile_text(decimal_separator=",", thousands_separator="dot"))
        mod().parse_profile(profile_text(decimal_separator=",", thousands_separator="space"))
        mod().parse_profile(profile_text(date_format="%d %B %Y"))


class M09Rows(M09Base):
    def test_basic_import(self):
        r = import_(CSV)
        self.assertIsInstance(r, mod().ImportResult)
        self.assertEqual((r.duplicates, r.errors), ([], []))
        self.assertEqual(len(r.transactions), 2)
        a, b = r.transactions
        self.assertEqual((a.date, a.payee, a.narration, a.flag, a.id, a.tags), (date(2024, 3, 1), "Blue Bottle", "latte", "*", None, ()))
        self.assertEqual([(p.account, p.amount, p.note) for p in a.postings],
                         [(BANK, money("-4.50 USD"), ""), ("Expenses:Uncategorized", money("4.50 USD"), "")])
        self.assertEqual([(p.account, p.amount) for p in b.postings],
                         [(BANK, money("2500.00 USD")), ("Expenses:Uncategorized", money("-2500.00 USD"))])
        self.assertIsInstance(r.transactions, list)

    def test_every_transaction_balances(self):
        r = import_("Date,Payee,Memo,Amount\n2024-03-01,A,,-0.01\n2024-03-02,B,,99999.99\n2024-03-03,C,,0.10\n")
        for t in r.transactions:
            self.assertEqual(sum(p.amount.minor for p in t.postings), 0)
            self.assertEqual({p.amount.currency for p in t.postings}, {"USD"})

    def test_profile_and_rules_may_be_given_as_text(self):
        r = mod().import_csv(CSV, profile_text(), 'when payee = "ACME" then account Income:Salary')
        self.assertEqual([t.postings[1].account for t in r.transactions], ["Expenses:Uncategorized", "Income:Salary"])
        rules = lib("rules").parse_rules('when payee = "ACME" then account Income:Salary')
        r2 = mod().import_csv(CSV, mod().parse_profile(profile_text()), rules=rules, existing=[])
        self.assertEqual(r2.transactions, r.transactions)
        r3 = mod().import_csv(CSV, profile_text())
        self.assertEqual(len(r3.transactions), 2)

    def test_bom_and_crlf(self):
        text = "﻿" + CSV.replace("\n", "\r\n")
        r = import_(text)
        self.assertEqual(r.errors, [])
        self.assertEqual([t.payee for t in r.transactions], ["Blue Bottle", "ACME"])
        self.assertEqual([t.narration for t in r.transactions], ["latte", "pay"])

    def test_quoted_fields(self):
        text = ('Date,Payee,Memo,Amount\n'
                '2024-03-01,"Smith, John","he said ""hi""","-1,250.00"\n'
                '2024-03-02,"Two\nLines","  a\r\n b  ",3.00\n')
        r = import_(text, thousands_separator="comma")
        self.assertEqual(r.errors, [])
        a, b = r.transactions
        self.assertEqual((a.payee, a.narration, a.postings[0].amount), ("Smith, John", 'he said "hi"', money("-1250.00 USD")))
        self.assertEqual((b.payee, b.narration), ("Two Lines", "a b"))

    def test_whitespace_is_collapsed_and_trimmed(self):
        r = import_("Date,Payee,Memo,Amount\n  2024-03-01 ,  Blue   Bottle\t Co ,  x    y ,  -4.50  \n")
        t = r.transactions[0]
        self.assertEqual((t.payee, t.narration, t.date), ("Blue Bottle Co", "x y", date(2024, 3, 1)))

    def test_row_numbers_are_file_line_numbers(self):
        text = ('Date,Payee,Memo,Amount\n'          # 1
                '2024-03-01,A,,1.00\n'              # 2
                '\n'                                # 3
                '2024-03-02,"B\nB",,oops\n'         # 4-5
                '2024-03-03,C,,2.00\n'              # 6
                '2024-13-03,D,,2.00\n'              # 7
                ',,,\n'                             # 8
                '2024-03-04,E,,x\n')                # 9
        r = import_(text)
        self.assertEqual([row for row, _ in r.errors], [4, 7, 9])
        self.assertEqual(self.amounts(r), ["1.00", "2.00"])
        self.assertTrue(all(isinstance(m, str) and m for _, m in r.errors))
        self.assertTrue(all(isinstance(e, tuple) and len(e) == 2 for e in r.errors))

    def test_row_numbers_with_skip_rows_bom_and_crlf(self):
        text = "﻿Bank export\r\nAccount 1234\r\nDate,Payee,Memo,Amount\r\n2024-03-01,A,,x\r\n2024-03-02,B,,1.00\r\n"
        r = import_(text, skip_rows=2)
        self.assertEqual(r.errors[0][0], 4)
        self.assertEqual(len(r.transactions), 1)

    def test_skip_rows_throws_away_lines_even_if_not_csv(self):
        text = 'junk "unterminated, line\nmore,junk\nDate,Payee,Memo,Amount\n2024-03-01,A,,1.00\n'
        r = import_(text, skip_rows=2)
        self.assertEqual((r.errors, len(r.transactions)), ([], 1))
        with self.assertRaises(mod().CsvImportError):
            import_(CSV, skip_rows=50)

    def test_bad_rows_never_stop_good_ones(self):
        text = "Date,Payee,Memo,Amount\n" + "".join(
            "2024-03-%02d,P%d,,%s\n" % (i + 1, i, "x" if i % 2 else "1.00") for i in range(10))
        r = import_(text)
        self.assertEqual(len(r.transactions), 5)
        self.assertEqual([row for row, _ in r.errors], [3, 5, 7, 9, 11])

    def test_no_header_uses_numbered_columns(self):
        text = "2024-03-01,Blue Bottle,latte,-4.50\n2024-03-02,ACME,pay,2500.00\n"
        r = import_(text, has_header="no", date_column="#1", payee_column="#2", narration_column="#3", amount_column="#4")
        self.assertEqual([t.payee for t in r.transactions], ["Blue Bottle", "ACME"])
        bad = import_("2024-03-01,A,,x\n", has_header="no", date_column="#1", payee_column="#2", narration_column="#3",
                      amount_column="#4")
        self.assertEqual([row for row, _ in bad.errors], [1])
        empty = import_("", has_header="no", date_column="#1", payee_column="#2", narration_column="#3", amount_column="#4")
        self.assertEqual((empty.transactions, empty.duplicates, empty.errors), ([], [], []))

    def test_columns_by_header_name_or_number(self):
        text = "  amount ,MEMO, payee,date\n-4.50,latte,Blue Bottle,2024-03-01\n"
        r = import_(text)
        self.assertEqual((r.errors, len(r.transactions)), ([], 1))
        self.assertEqual(r.transactions[0].narration, "latte")
        r2 = import_("a,b,c,d\n-4.50,latte,Blue Bottle,2024-03-01\n", date_column="#4", payee_column="#3",
                     narration_column="#2", amount_column="#1")
        self.assertEqual(r2.transactions[0].payee, "Blue Bottle")
        dup = import_("Date,Payee,Payee,Amount,Memo\n2024-03-01,First,Second,1.00,\n")
        self.assertEqual(dup.transactions[0].payee, "First")

    def test_a_missing_header_column_stops_the_import(self):
        with self.assertRaises(mod().CsvImportError) as cm:
            import_("Date,Who,Memo,Amount\n2024-03-01,A,,1.00\n")
        self.assertIn("Payee", str(cm.exception))
        with self.assertRaises(mod().CsvImportError):
            import_("Date,Payee,Amount\n2024-03-01,A,1.00\n")       # no Memo column although the profile names one

    def test_no_header_row_is_an_error(self):
        for text in ("", "\n\n", "﻿", "   ,  \n"):
            with self.subTest(text=text):
                with self.assertRaises(mod().CsvImportError):
                    import_(text)
        self.assertEqual(import_("Date,Payee,Memo,Amount\n").transactions, [])

    def test_blank_lines_blank_records_and_extra_cells_are_ignored(self):
        text = "\nDate,Payee,Memo,Amount,Extra\n\n2024-03-01,A,,1.00,whatever,more\n  , ,\n\n2024-03-02,B,,2.00\n"
        r = import_(text)
        self.assertEqual((r.errors, self.amounts(r)), ([], ["1.00", "2.00"]))

    def test_delimiters(self):
        semi = CSV.replace(",", ";")
        self.assertEqual(self.amounts(import_(semi, delimiter="semicolon")), ["-4.50", "2500.00"])
        self.assertEqual(self.amounts(import_(CSV.replace(",", "\t"), delimiter="tab")), ["-4.50", "2500.00"])
        self.assertEqual(self.amounts(import_(CSV.replace(",", "|"), delimiter="|")), ["-4.50", "2500.00"])
        r = import_('Date;Payee;Memo;Amount\n2024-03-01;"a; b";;1,50\n', delimiter=";", decimal_separator=",")
        self.assertEqual(r.transactions[0].payee, "a; b")
        self.assertEqual(r.transactions[0].postings[0].amount, money("1.50 USD"))

    def test_payee_and_short_rows(self):
        text = ("Date,Payee,Memo,Amount\n"
                "2024-03-01,,x,1.00\n"          # 2 empty payee
                "2024-03-02,   ,x,1.00\n"       # 3
                "2024-03-03\n"                  # 4 short: no payee
                "2024-03-04,A\n"                # 5 short: no amount
                "2024-03-05,B,only memo\n"      # 6 short: no amount
                "2024-03-06,C\n")               # 7
        r = import_(text)
        self.assertEqual([row for row, _ in r.errors], [2, 3, 4, 5, 6, 7])
        self.assertEqual(r.transactions, [])
        self.assertIn("Amount", dict(r.errors)[5])
        self.assertIn("Amount", dict(r.errors)[6])

    def test_missing_narration_cell_is_empty(self):
        r = import_("Date,Payee,Memo,Amount\n2024-03-01,A,,1.00\n")
        self.assertEqual(r.transactions[0].narration, "")
        r = import_("Date,Payee,Amount\n2024-03-01,A,1.00\n", narration_column=None)
        self.assertEqual(r.transactions[0].narration, "")
        r = import_("Amount,Payee,Date,Memo\n1.00,A,2024-03-01\n")      # the row ends before the memo column
        self.assertEqual((r.errors, r.transactions[0].narration), ([], ""))

    def test_flag_and_tags_from_the_profile(self):
        r = import_(CSV, flag="!", tags="Imported, bank")
        self.assertEqual({(t.flag, t.tags) for t in r.transactions}, {("!", ("bank", "imported"))})


class M09Cells(M09Base):
    def amount_of(self, cell, **over):
        r = import_("Date,Payee,Memo,Amount\n2024-03-01,A,,\"%s\"\n" % cell, **over)
        if r.errors:
            return None
        return r.transactions[0].postings[0].amount

    def test_amount_forms(self):
        for cell, want in (("12", "12.00 USD"), ("12.5", "12.50 USD"), ("+12.50", "12.50 USD"), ("-12.50", "-12.50 USD"),
                           ("0.05", "0.05 USD"), ("-0.99", "-0.99 USD"), ("  7.00 ", "7.00 USD"), ("00012.30", "12.30 USD")):
            with self.subTest(cell=cell):
                self.assertEqual(self.amount_of(cell), money(want))

    def test_bad_amounts(self):
        for cell in ("", "abc", "1.505", "12 USD", "$12.50", "1,250.00", "1e3", ".5", "5.", "--5", "+-5", "1 000", "12.50-",
                     "(12.50", "12.50)", "1.2.3"):
            with self.subTest(cell=cell):
                self.assertIsNone(self.amount_of(cell))

    def test_parentheses_mean_negative(self):
        self.assertEqual(self.amount_of("(12.50)"), money("-12.50 USD"))
        self.assertIsNone(self.amount_of("(-12.50)"))
        self.assertIsNone(self.amount_of("(+12.50)"))
        self.assertIsNone(self.amount_of("()"))

    def test_thousands_and_decimal_separators(self):
        eu = dict(decimal_separator=",", thousands_separator="dot")
        for cell, want in (("1.234,56", "1234.56 USD"), ("1.234.567,89", "1234567.89 USD"), ("12,5", "12.50 USD"),
                           ("-1.000,00", "-1000.00 USD"), ("1234,56", "1234.56 USD"), ("999", "999.00 USD"),
                           ("(1.234,56)", "-1234.56 USD"), ("0,05", "0.05 USD")):
            with self.subTest(cell=cell):
                self.assertEqual(self.amount_of(cell, **eu), money(want))
        for cell in ("12.34.567,89", "1.23,45", "1,234.56", "1234.567,00", "12.3456", ".234,00", "1.2345,00"):
            with self.subTest(bad=cell):
                self.assertIsNone(self.amount_of(cell, **eu))

    def test_other_thousands_separators(self):
        self.assertEqual(self.amount_of("1 234,50", decimal_separator=",", thousands_separator="space"), money("1234.50 USD"))
        self.assertEqual(self.amount_of("1'234.50", thousands_separator="apostrophe"), money("1234.50 USD"))
        self.assertEqual(self.amount_of("1,234,567.00", thousands_separator="comma"), money("1234567.00 USD"))
        self.assertIsNone(self.amount_of("1,234,56.00", thousands_separator="comma"))
        self.assertIsNone(self.amount_of("1,234.00"))            # no thousands separator configured
        self.assertEqual(self.amount_of("12,50", decimal_separator=","), money("12.50 USD"))
        self.assertIsNone(self.amount_of("12.50", decimal_separator=","))

    def test_currency_exponent_limits_decimals(self):
        self.assertEqual(self.amount_of("1,500", currency="JPY", thousands_separator="comma"), money("1500 JPY"))
        self.assertEqual(self.amount_of("-300", currency="JPY"), money("-300 JPY"))
        self.assertIsNone(self.amount_of("1.5", currency="JPY"))
        self.assertIsNone(self.amount_of("1.0", currency="JPY"))
        self.assertEqual(self.amount_of("1.234", currency="KWD"), money("1.234 KWD"))
        self.assertIsNone(self.amount_of("1.2345", currency="KWD"))
        self.assertIsNone(self.amount_of("1.500"))               # three decimals for USD, even if the last is a zero
        r = import_("Date,Payee,Memo,Amount\n2024-03-01,A,,5\n", currency="JPY")
        self.assertEqual({p.amount.currency for p in r.transactions[0].postings}, {"JPY"})

    def test_zero_amount_is_an_error(self):
        for cell in ("0", "0.00", "-0.00", "+0", "(0.00)"):
            with self.subTest(cell=cell):
                self.assertIsNone(self.amount_of(cell))

    def test_negate_flips_every_sign(self):
        r = import_(CSV, negate="yes")
        self.assertEqual(self.amounts(r), ["4.50", "-2500.00"])
        self.assertEqual([t.postings[1].amount.amount_str() for t in r.transactions], ["-4.50", "2500.00"])
        self.assertEqual(self.amount_of("(5.00)", negate="yes"), money("5.00 USD"))

    def test_debit_and_credit_columns(self):
        text = ("Date,Payee,Memo,Debit,Credit\n"
                "2024-03-01,A,,4.50,\n"          # 2
                "2024-03-02,B,,,2500.00\n"       # 3
                "2024-03-03,C,,1.00,2.00\n"      # 4 both
                "2024-03-04,D,,,\n"              # 5 neither
                "2024-03-05,E,,  ,  \n"          # 6 neither
                "2024-03-06,F,,0.00,\n"          # 7 zero
                "2024-03-07,G,,x,\n"             # 8 bad
                "2024-03-08,H,,-3.00,\n"         # 9 a negative debit is money in
                "2024-03-09,I,,,(2.00)\n")       # 10 credit in parentheses is money out
        r = import_(text, amount_column=None, debit_column="Debit", credit_column="Credit")
        self.assertEqual([row for row, _ in r.errors], [4, 5, 6, 7, 8])
        self.assertEqual(self.amounts(r), ["-4.50", "2500.00", "3.00", "-2.00"])
        neg = import_(text, amount_column=None, debit_column="Debit", credit_column="Credit", negate="yes")
        self.assertEqual(self.amounts(neg), ["4.50", "-2500.00", "-3.00", "2.00"])

    def test_error_messages_quote_the_offending_cell(self):
        r = import_("Date,Payee,Memo,Amount\n31/02/2024,A,,1.00\n2024-03-01,B,,12abc\n2024-03-02,C,, 1.505 \n")
        self.assertEqual([row for row, _ in r.errors], [2, 3, 4])
        messages = dict(r.errors)
        self.assertIn("31/02/2024", messages[2])
        self.assertIn("12abc", messages[3])
        self.assertIn("1.505", messages[4])

    def test_dates_default_format(self):
        r = import_("Date,Payee,Memo,Amount\n2024-02-29,A,,1.00\n")
        self.assertEqual(r.transactions[0].date, date(2024, 2, 29))
        bad = import_("Date,Payee,Memo,Amount\n2023-02-29,A,,1.00\n2024-3-1,B,,1.00\n24-03-01,C,,1.00\n"
                      "2024-03-01 10:00,D,,1.00\n01/03/2024,E,,1.00\n,F,,1.00\n")
        self.assertEqual(len(bad.transactions), 1)       # 2024-3-1 is fine: one or two digits for %m and %d
        self.assertEqual([row for row, _ in bad.errors], [2, 4, 5, 6, 7])

    def test_date_formats(self):
        cases = [("%d/%m/%Y", "05/03/2024", date(2024, 3, 5)), ("%d/%m/%Y", "5/3/2024", date(2024, 3, 5)),
                 ("%m/%d/%Y", "03/05/2024", date(2024, 3, 5)), ("%m/%d/%y", "03/05/24", date(2024, 3, 5)),
                 ("%d.%m.%y", "31.12.99", date(2099, 12, 31)), ("%d %b %Y", "05 Mar 2024", date(2024, 3, 5)),
                 ("%d %b %Y", "5 mar 2024", date(2024, 3, 5)), ("%d %B %Y", "5 MARCH 2024", date(2024, 3, 5)),
                 ("%B %d, %Y", "September 30, 2024", date(2024, 9, 30)), ("%Y%m%d", "20240305", date(2024, 3, 5)),
                 ("%Y-%d-%m", "2024-05-03", date(2024, 3, 5)), ("%d-%b-%y", "05-Mar-24", date(2024, 3, 5)),
                 ("Paid %d/%m/%Y", "Paid 05/03/2024", date(2024, 3, 5)), ("%Y%%%m%%%d", "2024%03%05", date(2024, 3, 5)),
                 ("%b %d %Y", "Dec 01 2024", date(2024, 12, 1))]
        for fmt, cell, want in cases:
            with self.subTest(fmt=fmt, cell=cell):
                r = import_('Date,Payee,Memo,Amount\n"%s",A,,1.00\n' % cell, date_format=fmt)
                self.assertEqual(r.errors, [])
                self.assertEqual(r.transactions[0].date, want)

    def test_dates_that_do_not_fit_the_format(self):
        cases = [("%d/%m/%Y", "31/02/2024"), ("%d/%m/%Y", "05-03-2024"), ("%d/%m/%Y", "05/03/24"), ("%d/%m/%Y", "05/13/2024"),
                 ("%d %b %Y", "05 March 2024"), ("%d %B %Y", "05 Mar 2024"), ("%d %b %Y", "05 Foo 2024"),
                 ("%m/%d/%y", "03/05/2024"), ("%d/%m/%Y", "00/03/2024")]
        for fmt, cell in cases:
            with self.subTest(fmt=fmt, cell=cell):
                r = import_("Date,Payee,Memo,Amount\n%s,A,,1.00\n" % cell, date_format=fmt)
                self.assertEqual(r.transactions, [])
                self.assertEqual([row for row, _ in r.errors], [2])


class M09Rules(M09Base):
    RULES = '''
when payee ~ "bottle" and amount < 0 then account Expenses:Food tag coffee narration "Coffee break"
when payee = "acme" and amount > 0 then account Income:Salary tag Salary payee "ACME Ltd" flag !
when payee ~ "acme" then account Expenses:Misc
'''

    def test_rules_choose_accounts_and_decorations(self):
        r = import_(CSV, self.RULES, tags="bank")
        a, b = r.transactions
        self.assertEqual([p.account for p in a.postings], [BANK, "Expenses:Food"])
        self.assertEqual((a.tags, a.narration, a.payee, a.flag), (("bank", "coffee"), "Coffee break", "Blue Bottle", "*"))
        self.assertEqual([p.account for p in b.postings], [BANK, "Income:Salary"])
        self.assertEqual((b.tags, b.narration, b.payee, b.flag), (("bank", "salary"), "pay", "ACME Ltd", "!"))
        self.assertEqual([p.amount for p in b.postings], [money("2500.00 USD"), money("-2500.00 USD")])

    def test_rules_see_the_bank_postings_signed_amount_and_the_date(self):
        rules = ('when amount >= 100 then account Income:Big\n'
                 'when date >= 2024-03-02 and amount > 0 then account Income:Later\n'
                 'when amount < 0 then account Expenses:Out\n')
        text = "Date,Payee,Memo,Amount\n2024-03-01,A,,150.00\n2024-03-03,B,,5.00\n2024-03-01,C,,-5.00\n2024-03-01,D,,5.00\n"
        r = import_(text, rules)
        self.assertEqual([t.postings[1].account for t in r.transactions],
                         ["Income:Big", "Income:Later", "Expenses:Out", "Expenses:Uncategorized"])
        flipped = import_(text, rules, negate="yes")
        self.assertEqual([t.postings[1].account for t in flipped.transactions],
                         ["Expenses:Out", "Expenses:Out", "Expenses:Uncategorized", "Expenses:Out"])
        self.assertEqual(flipped.transactions[0].postings[0].amount, money("-150.00 USD"))

    def test_rules_see_the_cleaned_payee_and_narration(self):
        text = 'Date,Payee,Memo,Amount\n2024-03-01,"Blue\n  Bottle","two\nlines",-1.00\n'
        r = import_(text, 'when payee = "blue bottle" and narration = "two lines" then tag hit')
        self.assertEqual(r.transactions[0].tags, ("hit",))

    def test_no_account_anywhere_is_a_row_error(self):
        r = import_(CSV, None, default_account=None)
        self.assertEqual((r.transactions, [row for row, _ in r.errors]), ([], [2, 3]))
        r = import_(CSV, 'when payee = "ACME" then account Income:Salary', default_account=None)
        self.assertEqual([t.payee for t in r.transactions], ["ACME"])
        self.assertEqual([row for row, _ in r.errors], [2])
        r = import_(CSV, 'when payee = "ACME" then tag only', default_account=None)       # tags but no account
        self.assertEqual(([row for row, _ in r.errors], r.transactions), ([2, 3], []))

    def test_rule_tags_merge_with_profile_tags_sorted(self):
        r = import_(CSV, 'when any then tag zebra tag apple', tags="mango, apple")
        self.assertEqual({t.tags for t in r.transactions}, {("apple", "mango", "zebra")})

    def test_default_account_when_no_rule_matches(self):
        r = import_(CSV, 'when payee = "nobody" then account Income:X')
        self.assertEqual({t.postings[1].account for t in r.transactions}, {"Expenses:Uncategorized"})


class M09Duplicates(M09Base):
    def test_reimporting_gives_only_duplicates(self):
        first = import_(CSV)
        again = import_(CSV, existing=first.transactions)
        self.assertEqual(again.transactions, [])
        self.assertEqual(again.duplicates, first.transactions)
        self.assertEqual(again.errors, [])

    def test_partly_new_statement(self):
        first = import_(CSV)
        more = CSV + "2024-03-03,Landlord,rent,-900.00\n"
        r = import_(more, existing=first.transactions[:1])
        self.assertEqual([t.payee for t in r.duplicates], ["Blue Bottle"])
        self.assertEqual([t.payee for t in r.transactions], ["ACME", "Landlord"])

    def test_identical_rows_are_matched_by_ordinal(self):
        text = "Date,Payee,Memo,Amount\n" + "2024-03-01,Coffee,,-3.00\n" * 3 + "2024-03-02,Coffee,,-3.00\n"
        fresh = import_(text)
        self.assertEqual((len(fresh.transactions), len(fresh.duplicates)), (4, 0))
        one = import_(text, existing=fresh.transactions[:1])
        self.assertEqual((len(one.duplicates), len(one.transactions)), (1, 3))
        two = import_(text, existing=fresh.transactions[:2])
        self.assertEqual((len(two.duplicates), len(two.transactions)), (2, 2))
        allof = import_(text, existing=fresh.transactions)
        self.assertEqual((len(allof.duplicates), len(allof.transactions)), (4, 0))
        extra = import_(text, existing=fresh.transactions + fresh.transactions)
        self.assertEqual(len(extra.duplicates), 4)

    def test_the_key_is_date_amount_and_payee(self):
        existing = [tx(date(2024, 3, 1), "Blue Bottle", "-4.50 USD")]
        for row, dup in (("2024-03-01,Blue Bottle,,-4.50", True), ("2024-03-02,Blue Bottle,,-4.50", False),
                         ("2024-03-01,Blue Bottle,,-4.51", False), ("2024-03-01,Blue Bottle,,4.50", False),
                         ("2024-03-01,blue bottle,,-4.50", False), ("2024-03-01,Blue Bottle,other memo,-4.50", True)):
            with self.subTest(row=row):
                r = import_("Date,Payee,Memo,Amount\n" + row + "\n", existing=existing)
                self.assertEqual((len(r.duplicates), len(r.transactions)), (1, 0) if dup else (0, 1))

    def test_only_the_banks_account_counts(self):
        elsewhere = [tx(date(2024, 3, 1), "Blue Bottle", "-4.50 USD", account="Assets:Cash")]
        r = import_("Date,Payee,Memo,Amount\n2024-03-01,Blue Bottle,,-4.50\n", existing=elsewhere)
        self.assertEqual((len(r.duplicates), len(r.transactions)), (0, 1))
        model = lib("model")
        flipped = [model.Transaction(date=date(2024, 3, 1), payee="Blue Bottle", narration="", postings=[
            model.Posting("Expenses:Food", money("4.50 USD")), model.Posting(BANK, money("-4.50 USD"))])]
        r = import_("Date,Payee,Memo,Amount\n2024-03-01,Blue Bottle,,-4.50\n", existing=flipped)
        self.assertEqual((len(r.duplicates), len(r.transactions)), (1, 0))
        wrong_currency = [tx(date(2024, 3, 1), "Blue Bottle", "-4.50 EUR")]
        r = import_("Date,Payee,Memo,Amount\n2024-03-01,Blue Bottle,,-4.50\n", existing=wrong_currency)
        self.assertEqual(len(r.transactions), 1)

    def test_the_payee_is_the_one_after_the_rules(self):
        rules = 'when payee = "acme" then payee "ACME Ltd"'
        first = import_(CSV, rules)
        again = import_(CSV, rules, existing=first.transactions)
        self.assertEqual((len(again.transactions), len(again.duplicates)), (0, 2))
        without = import_(CSV, existing=first.transactions)      # the old payee no longer matches the stored one
        self.assertEqual([t.payee for t in without.transactions], ["ACME"])

    def test_rows_in_error_are_not_duplicates_or_new(self):
        text = "Date,Payee,Memo,Amount\n2024-03-01,A,,x\n2024-03-01,A,,-1.00\n"
        existing = [tx(date(2024, 3, 1), "A", "-1.00 USD")]
        r = import_(text, existing=existing)
        self.assertEqual(([row for row, _ in r.errors], len(r.duplicates), len(r.transactions)), ([2], 1, 0))

    def test_existing_may_be_any_iterable(self):
        first = import_(CSV)
        r = import_(CSV, existing=iter(first.transactions))
        self.assertEqual(len(r.duplicates), 2)
        r = import_(CSV, existing=tuple())
        self.assertEqual(len(r.transactions), 2)


if __name__ == "__main__":
    unittest.main()

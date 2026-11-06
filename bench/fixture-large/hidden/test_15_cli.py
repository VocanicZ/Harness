"""Hidden tests of module 15: the command line (`tallybook ...`), black box over TALLYBOOK_CMD.

The offline `calc` helpers need no book and are the bulk of the exact-format checks; the rest are stories over a
real book file. Behaviour that differs before and after the mid-run change (rounding ties, the period lock) is
tested twice, tagged @phase("pre") and @phase("post")."""
import atexit
import contextlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

from support import STANDARD_CHART, Base, Server, cli_argv, lib, phase

# ------------------------------------------------------------------------------------------------ sample data

# The sample book of the reports section, as canonical journal text (accounts in path order, 8 transactions).
SAMPLE = r"""account Assets:Bank:Checking USD
account Assets:Cash USD
account Equity:Opening USD
account Expenses:Food USD
account Expenses:Rent USD
account Income:Salary USD
account Liabilities:Card USD

rate 2024-03-01 USD EUR 0.92

2024-01-01 * "Opening"
  Equity:Opening        -1000.00 USD
  Assets:Bank:Checking   1000.00 USD

2024-03-01 * "Acme"
  Assets:Bank:Checking   2500.00 USD
  Income:Salary         -2500.00 USD

2024-03-02 * "Market"
  Expenses:Food          42.50 USD
  Assets:Bank:Checking  -42.50 USD

2024-03-05 * "Landlord"
  Expenses:Rent      900.00 USD
  Liabilities:Card  -900.00 USD

2024-03-10 * "ATM"
  Assets:Cash            100.00 USD
  Assets:Bank:Checking  -100.00 USD

2024-03-12 * "Corner"
  Expenses:Food   12.00 USD
  Assets:Cash    -12.00 USD

2024-04-02 * "Card payoff"
  Liabilities:Card       900.00 USD
  Assets:Bank:Checking  -900.00 USD

2024-04-03 * "Market"
  Expenses:Food          30.00 USD
  Assets:Bank:Checking  -30.00 USD
"""

BALANCE_SHEET = r"""Balance sheet as of 2024-03-31

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

INCOME_STATEMENT = r"""Income statement 2024-03-01 to 2024-03-31

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

REGISTER = r"""Register Assets:Bank:Checking 2024-03-01 to 2024-03-31

Date        Id  Payee            Account                    Amount      Balance
----------  --  ---------------  --------------------  -----------  -----------
                Opening balance                                     1000.00 USD
2024-03-01  2   Acme             Assets:Bank:Checking  2500.00 USD  3500.00 USD
2024-03-02  3   Market           Assets:Bank:Checking   -42.50 USD  3457.50 USD
2024-03-10  5   ATM              Assets:Bank:Checking  -100.00 USD  3357.50 USD
                Closing balance                                     3357.50 USD
"""

TRIAL_BALANCE = r"""Trial balance as of 2024-03-31

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

CASHFLOW = r"""Cash flow 2024-03-01 to 2024-03-31

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

# Two expense lines that make every percentage a tie at the tenth: 1/16 = 6.25 %, and a 0.01 spending on 4.00 = 0.25 %.
TIE_JOURNAL = """account Assets:Cash USD
account Expenses:Food USD
account Expenses:Rent USD

2024-03-02 * "A"
  Expenses:Food   0.01 USD
  Assets:Cash    -0.01 USD

2024-03-03 * "B"
  Expenses:Rent   0.15 USD
  Assets:Cash    -0.15 USD
"""

BANK_PROFILE = """date_column = Date
payee_column = Payee
narration_column = Memo
amount_column = Amount
currency = USD
account = Assets:Bank
default_account = Expenses:Misc
"""

BANK_CSV = """Date,Payee,Memo,Amount
2024-03-01,Corner Shop,milk,-5.00
2024-03-02,Employer,march pay,100.00
2024-03-03,Cafe Nero,latte,-3.40
"""

BANK_RULES = """when payee ~ "shop|nero" then account Expenses:Food tag coffee
when payee = "employer" then account Income:Pay
"""

BANK_CHART = [("Assets:Bank", "--currency", "USD"), "Expenses:Misc", "Expenses:Food", "Income:Pay"]


class CliBase(Base):
    _templates = {}

    def from_template(self, key, build):
        """Start from a book prepared once per run (by `build`, which drives the command line): a copy of its file."""
        path = CliBase._templates.get(key)
        if path is None:
            folder = tempfile.mkdtemp(prefix="tallybook-template-")
            atexit.register(shutil.rmtree, folder, True)
            path = os.path.join(folder, "template.db")
            real, self.db = self.db, path
            try:
                build()
            finally:
                self.db = real
            CliBase._templates[key] = path
        shutil.copyfile(path, self.db)

    def calc(self, *args, stdin=None):
        return self.tb("calc", *args, db=False, stdin=stdin)

    def out(self, *args, stdin=None, db=True):
        """Standard output of a command that must succeed quietly (status 0, nothing on standard error)."""
        r = self.tb(*args, stdin=stdin, db=db)
        self.assertEqual((r.rc, r.err), (0, ""), "tallybook %s" % " ".join(map(str, args)))
        return r.out

    def calc_out(self, *args, stdin=None):
        return self.out("calc", *args, stdin=stdin, db=False)

    def refused(self, r, status=1, what=""):
        """The command failed: given status, nothing on standard output, one `tallybook: ` message."""
        self.assertEqual(r.rc, status, what + " -> " + r.err)
        self.assertEqual(r.out, "", what)
        self.assertTrue(r.err.startswith("tallybook: "), "%s: %r" % (what, r.err))
        return r.err

    def fails(self, *args, status=1, stdin=None, db=True):
        r = self.tb(*args, stdin=stdin, db=db)
        return self.refused(r, status, "tallybook " + " ".join(map(str, args)))

    def sample(self, name="sample.journal"):
        return self.write(name, SAMPLE)

    def book_with_sample(self):
        def build():
            self.init()
            self.out("journal", "import", self.sample())
        self.from_template("sample", build)

    def standard_book(self):
        self.from_template("standard", lambda: self.init(*STANDARD_CHART))


# ------------------------------------------------------------------------------------------------ the command line

class M15CommandLine(CliBase):
    def test_version_and_help(self):
        self.assertEqual(self.out("--version", db=False), "tallybook 1.0.0\n")
        text = self.out("--help", db=False)
        self.assertTrue(text.startswith("usage: tallybook"))
        for word in ("init", "account", "tx", "journal", "import", "profile", "rules", "rate", "budget",
                     "recurring", "report", "query", "export", "serve", "calc", "db"):
            self.assertIn(word, text)
        self.assertEqual(self.out("-h", db=False), text)
        self.assertEqual(self.out("--help", "--bogus", db=False), text)       # read left to right: help comes first

    def test_help_of_one_command(self):
        text = self.out("tx", "add", "--help", db=False)
        self.assertTrue(text.startswith("usage: tallybook tx add"))
        group = self.out("account", "--help", db=False)
        for word in ("add", "list", "show", "close"):
            self.assertIn(word, group)
        self.assertTrue(self.out("calc", "money", "add", "-h", db=False).startswith("usage: tallybook calc money add"))

    def test_main_function_returns_the_status(self):
        main = lib("cli.main").main
        streams = [io.TextIOWrapper(io.BytesIO(), encoding="utf-8", write_through=True) for _ in range(2)]
        with contextlib.redirect_stdout(streams[0]), contextlib.redirect_stderr(streams[1]):
            codes = [main(["--version"]), main(["calc", "money", "parse", "12.50 USD"]),
                     main(["calc", "money", "parse", "12.5 usd"]), main(["bogus"])]
        self.assertEqual(codes, [0, 0, 1, 2])

    def test_usage_errors_are_status_two(self):
        cases = [
            [],                                       # no command at all
            ["bogus"],                                # unknown command
            ["account"],                              # a group without its word
            ["account", "bogus"],                     # unknown word
            ["--bogus"],                              # unknown global option
            ["--db"],                                 # global option without its value
            ["--db", "x", "--db", "y", "init"],       # given twice
            ["calc", "money", "add", "1.00 USD"],     # missing argument
            ["calc", "money", "add", "1.00 USD", "2.00 USD", "3.00 USD"],       # surplus argument
            ["calc", "money", "parse", "1.00 USD", "--bogus"],                   # unknown option
            ["calc", "rules", "r.txt", "--payee"],                               # missing option value
            ["account", "list", "--json=1"],                                     # a flag with a value
            ["calc", "rules", "r.txt", "--payee", "a", "--payee", "b"],         # given twice
            ["init", "--db", "x"],                    # global options are not read after the command
            ["calc", "money", "allocate", "10.00 USD"],               # at least one weight
            ["calc", "schedule", "daily", "--from", "2024-01-01"],    # required option missing
            ["calc", "report", "bogus", "--journal", "x"],            # unknown report
            ["calc", "report", "register", "--journal", "x"],         # register needs an account
            ["import", "x.csv"],                      # neither profile option
        ]
        for argv in cases:
            with self.subTest(argv=argv):
                err = self.fails(*argv, status=2, db=False)
                self.assertIn("Try 'tallybook --help'.", err)

    def test_option_syntax(self):
        rules = self.write("rules.txt", 'when payee = "ACME" then account Expenses:Food\n')
        want = "rule: 1\naccount: Expenses:Food\n"
        self.assertEqual(self.calc_out("rules", rules, "--payee", "acme"), want)
        self.assertEqual(self.calc_out("rules", rules, "--payee=acme"), want)
        self.assertEqual(self.calc_out("rules", "--payee", "acme", rules), want)      # options and arguments mix
        # a value option takes the next argument whatever it looks like, and --payee may be empty
        self.assertEqual(self.calc_out("rules", rules, "--payee", "--date"), "no match\n")
        self.assertEqual(self.calc_out("rules", rules, "--payee", ""), "no match\n")
        # abbreviations are not accepted
        self.fails("calc", "rules", rules, "--pay", "acme", status=2, db=False)

    def test_dash_values_are_plain_arguments(self):
        self.assertEqual(self.calc_out("money", "add", "-5.00 USD", "1.00 USD"), "-4.00 USD\n")
        self.assertEqual(self.calc_out("date", "add-months", "2024-03-31", "-1"), "2024-02-29\n")
        self.assertEqual(self.calc_out("money", "scale", "9.00 USD", "-1/3"), "-3.00 USD\n")
        self.assertEqual(self.calc_out("money", "format", "-5", "USD"), "-0.05 USD\n")
        self.assertEqual(self.calc_out("money", "add", "--", "-5.00 USD", "1.00 USD"), "-4.00 USD\n")
        self.assertEqual(self.calc_out("journal", "format", "-", stdin=""), "")

    def test_global_options_come_first_and_calc_ignores_the_book(self):
        # --db is ignored by calc, even when it names nothing
        self.assertEqual(self.out("--db", "/no/such/dir/x.db", "calc", "money", "parse", "1.00 USD", db=False),
                         "100 USD\n")
        r = self.tb("--today", "2024-13-45", "calc", "money", "parse", "1.00 USD", db=False)
        self.refused(r, 1, "bad --today")
        self.refused(self.tb("--today", "tomorrow", "--version", db=False), 1, "bad --today before --version")
        self.assertEqual(self.out("--today", "2024-03-01", "--version", db=False), "tallybook 1.0.0\n")

    def test_the_database_defaults(self):
        # no --db: the environment variable, then ./tallybook.db in the current directory
        env = dict(os.environ, TALLYBOOK_DB=self.path("env.db"))
        env.pop("TALLYBOOK_CMD", None)
        run = lambda extra_env, *a: subprocess.run(cli_argv() + list(a), capture_output=True, text=True,
                                                   encoding="utf-8", cwd=self.tmp, env=extra_env)
        r = run(env, "init")
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        self.assertEqual(r.stdout, "created %s (version 4)\n" % self.path("env.db"))
        plain = dict(os.environ)
        plain.pop("TALLYBOOK_DB", None)
        r = run(plain, "init")
        self.assertEqual(r.stdout, "created tallybook.db (version 4)\n")
        self.assertTrue(os.path.exists(self.path("tallybook.db")))

    def test_failures_print_nothing_on_stdout(self):
        self.standard_book()
        cases = [
            ["tx", "show", "99"], ["account", "show", "Assets:Nope"],
            ["tx", "add", "X", "-p", "Assets:Cash 5.00 USD"],            # does not balance
            ["tx", "list", "--limit", "many"], ["rate", "set", "USD", "EUR", "abc"],
        ]
        for argv in cases:
            with self.subTest(argv=argv):
                self.fails(*argv)

    def test_a_closed_reader_ends_quietly(self):
        proc = subprocess.Popen(cli_argv() + ["--help"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        proc.stdout.close()                      # like `| head -1` that has already gone away
        err = proc.stderr.read()
        self.assertEqual(proc.wait(timeout=30), 0)
        self.assertEqual(err, b"")
        proc.stderr.close()


# ------------------------------------------------------------------------------------------------ calc: money

class M15CalcMoney(CliBase):
    def test_parse_and_format(self):
        for text, want in [("12.50 USD", "1250 USD"), ("-0.05 USD", "-5 USD"), ("0 JPY", "0 JPY"),
                           ("1250 JPY", "1250 JPY"), ("1.234 KWD", "1234 KWD"), ("+7.10 EUR", "710 EUR"),
                           ("-0.00 USD", "0 USD")]:
            with self.subTest(text=text):
                self.assertEqual(self.calc_out("money", "parse", text), want + "\n")
        for minor, code, want in [("1250", "USD", "12.50 USD"), ("-5", "USD", "-0.05 USD"), ("0", "USD", "0.00 USD"),
                                  ("1250", "JPY", "1250 JPY"), ("-7", "KWD", "-0.007 KWD"),
                                  ("123456789012345678", "USD", "1234567890123456.78 USD"), ("007", "EUR", "0.07 EUR")]:
            with self.subTest(minor=minor, code=code):
                self.assertEqual(self.calc_out("money", "format", minor, code), want + "\n")

    def test_bad_values_are_status_one(self):
        cases = [["money", "parse", "12.5 usd"], ["money", "parse", "12.505 USD"], ["money", "parse", "12.50USD"],
                 ["money", "parse", "1,250.00 USD"], ["money", "format", "1.5", "USD"], ["money", "format", "+5", "USD"],
                 ["money", "format", "1234567890123456789", "USD"], ["money", "add", "1.00 USD", "1.00 EUR"],
                 ["money", "scale", "1.00 USD", "1/0"], ["money", "scale", "1.00 USD", "1.5"],
                 ["money", "allocate", "10.00 USD", "0", "0"], ["money", "allocate", "10.00 USD", "-1", "2"],
                 ["money", "convert", "10.00 USD", "USD", "1.5"], ["money", "convert", "10.00 USD", "EUR", "0"],
                 ["money", "convert", "10.00 USD", "ZZZ", "1.5"]]
        for argv in cases:
            with self.subTest(argv=argv):
                self.fails("calc", *argv, db=False)

    def test_add_sub_scale(self):
        self.assertEqual(self.calc_out("money", "add", "12.50 USD", "0.75 USD"), "13.25 USD\n")
        self.assertEqual(self.calc_out("money", "sub", "12.50 USD", "20.00 USD"), "-7.50 USD\n")
        self.assertEqual(self.calc_out("money", "add", "5 JPY", "7 JPY"), "12 JPY\n")
        self.assertEqual(self.calc_out("money", "add", "0.001 KWD", "0.002 KWD"), "0.003 KWD\n")
        self.assertEqual(self.calc_out("money", "scale", "10.00 USD", "1/3"), "3.33 USD\n")
        self.assertEqual(self.calc_out("money", "scale", "10.00 USD", "2/3"), "6.67 USD\n")
        self.assertEqual(self.calc_out("money", "scale", "10.00 USD", "3"), "30.00 USD\n")
        self.assertEqual(self.calc_out("money", "scale", "10.00 USD", "1/-4"), "-2.50 USD\n")
        self.assertEqual(self.calc_out("money", "scale", "-10.00 USD", "-1/3"), "3.33 USD\n")
        self.assertEqual(self.calc_out("money", "scale", "100 JPY", "0"), "0 JPY\n")
        self.assertEqual(self.calc_out("money", "scale", "0.01 USD", "1/3"), "0.00 USD\n")

    def test_allocate(self):
        self.assertEqual(self.calc_out("money", "allocate", "100.00 USD", "1", "1", "1"),
                         "33.34 USD\n33.33 USD\n33.33 USD\n")
        self.assertEqual(self.calc_out("money", "allocate", "0.05 USD", "1", "1"), "0.03 USD\n0.02 USD\n")
        self.assertEqual(self.calc_out("money", "allocate", "10.00 USD", "3"), "10.00 USD\n")
        self.assertEqual(self.calc_out("money", "allocate", "10.00 USD", "0", "5", "5"),
                         "0.00 USD\n5.00 USD\n5.00 USD\n")
        self.assertEqual(self.calc_out("money", "allocate", "-100.00 USD", "1", "1", "1"),
                         "-33.34 USD\n-33.33 USD\n-33.33 USD\n")
        self.assertEqual(self.calc_out("money", "allocate", "10 JPY", "1", "2"), "3 JPY\n7 JPY\n")
        self.assertEqual(self.calc_out("money", "allocate", "1.00 USD", "1", "1", "1", "1", "1", "1", "1"),
                         "0.15 USD\n0.15 USD\n0.14 USD\n0.14 USD\n0.14 USD\n0.14 USD\n0.14 USD\n")

    def test_convert(self):
        self.assertEqual(self.calc_out("money", "convert", "10.00 USD", "JPY", "150.5"), "1505 JPY\n")
        self.assertEqual(self.calc_out("money", "convert", "10.00 USD", "EUR", "0.92"), "9.20 EUR\n")
        self.assertEqual(self.calc_out("money", "convert", "1000 JPY", "USD", "0.0067"), "6.70 USD\n")
        self.assertEqual(self.calc_out("money", "convert", "1.000 KWD", "USD", "3.25"), "3.25 USD\n")
        self.assertEqual(self.calc_out("money", "convert", "-10.00 USD", "EUR", "0.92"), "-9.20 EUR\n")
        self.assertEqual(self.calc_out("money", "convert", "10.01 USD", "EUR", "0.92"), "9.21 EUR\n")

    @phase("pre")
    def test_scale_and_convert_ties_round_away_from_zero(self):
        self.assertEqual(self.calc_out("money", "scale", "0.25 USD", "1/2"), "0.13 USD\n")
        self.assertEqual(self.calc_out("money", "scale", "-0.25 USD", "1/2"), "-0.13 USD\n")
        self.assertEqual(self.calc_out("money", "scale", "0.15 USD", "1/2"), "0.08 USD\n")
        self.assertEqual(self.calc_out("money", "convert", "0.25 USD", "JPY", "10"), "3 JPY\n")
        self.assertEqual(self.calc_out("money", "convert", "0.05 USD", "JPY", "10"), "1 JPY\n")
        self.assertEqual(self.calc_out("money", "convert", "-0.05 USD", "JPY", "10"), "-1 JPY\n")

    @phase("post")
    def test_scale_and_convert_ties_round_half_even(self):
        self.assertEqual(self.calc_out("money", "scale", "0.25 USD", "1/2"), "0.12 USD\n")
        self.assertEqual(self.calc_out("money", "scale", "-0.25 USD", "1/2"), "-0.12 USD\n")
        self.assertEqual(self.calc_out("money", "scale", "0.15 USD", "1/2"), "0.08 USD\n")
        self.assertEqual(self.calc_out("money", "convert", "0.25 USD", "JPY", "10"), "2 JPY\n")
        self.assertEqual(self.calc_out("money", "convert", "0.05 USD", "JPY", "10"), "0 JPY\n")
        self.assertEqual(self.calc_out("money", "convert", "0.15 USD", "JPY", "10"), "2 JPY\n")


# ------------------------------------------------------------------------------------------------ calc: dates, schedules

class M15CalcDates(CliBase):
    def test_date_parse(self):
        for text, want in [("2024-03-01", "2024-03-01 Friday"), ("2024-02-29", "2024-02-29 Thursday"),
                           ("2023-12-31", "2023-12-31 Sunday"), ("2000-01-01", "2000-01-01 Saturday"),
                           ("2024-01-01", "2024-01-01 Monday")]:
            with self.subTest(text=text):
                self.assertEqual(self.calc_out("date", "parse", text), want + "\n")
        for text in ["2023-02-29", "2024-3-1", "2024-03-01 ", "yesterday"]:
            with self.subTest(text=text):
                self.fails("calc", "date", "parse", text, db=False)

    def test_add_months(self):
        for start, n, want in [("2024-01-31", "1", "2024-02-29"), ("2023-01-31", "1", "2023-02-28"),
                               ("2024-03-31", "-1", "2024-02-29"), ("2024-03-15", "0", "2024-03-15"),
                               ("2024-01-15", "12", "2025-01-15"), ("2024-01-15", "-13", "2022-12-15"),
                               ("2024-05-31", "1", "2024-06-30")]:
            with self.subTest(start=start, n=n):
                self.assertEqual(self.calc_out("date", "add-months", start, n), want + "\n")
        for argv in [["9999-12-31", "1"], ["0001-01-01", "-1"], ["2024-01-01", "1.5"],
                     ["2024-01-01", "999999999999999999"]]:
            with self.subTest(argv=argv):
                self.fails("calc", "date", "add-months", *argv, db=False)

    def test_period(self):
        month = "start: 2024-03-01\nend: 2024-03-31\ndays: 31\nlabel: 2024-03\nnext: 2024-04\n"
        self.assertEqual(self.calc_out("date", "period", "2024-03"), month)
        self.assertEqual(self.calc_out("date", "period", "2024-03-01..2024-03-31"), month)
        self.assertEqual(self.calc_out("date", "period", "2024-Q1"),
                         "start: 2024-01-01\nend: 2024-03-31\ndays: 91\nlabel: 2024-Q1\nnext: 2024-Q2\n")
        self.assertEqual(self.calc_out("date", "period", "2024"),
                         "start: 2024-01-01\nend: 2024-12-31\ndays: 366\nlabel: 2024\nnext: 2025\n")
        self.assertEqual(self.calc_out("date", "period", "2024-02-10..2024-02-19"),
                         "start: 2024-02-10\nend: 2024-02-19\ndays: 10\n"
                         "label: 2024-02-10..2024-02-19\nnext: 2024-02-20..2024-02-29\n")
        self.assertEqual(self.calc_out("date", "period", "2023-12"),
                         "start: 2023-12-01\nend: 2023-12-31\ndays: 31\nlabel: 2023-12\nnext: 2024-01\n")
        for text in ["2024-13", "2024-Q5", "2024-03-31..2024-03-01", "March"]:
            with self.subTest(text=text):
                self.fails("calc", "date", "period", text, db=False)
        self.fails("calc", "date", "period", "9999", db=False)           # there is no period after the calendar's end

    def test_periods(self):
        self.assertEqual(self.calc_out("date", "periods", "2024-01-15", "2024-03-02", "month"),
                         "2024-01\n2024-02\n2024-03\n")
        self.assertEqual(self.calc_out("date", "periods", "2024-02-10", "2024-08-01", "quarter"),
                         "2024-Q1\n2024-Q2\n2024-Q3\n")
        self.assertEqual(self.calc_out("date", "periods", "2023-06-01", "2024-02-01", "year"), "2023\n2024\n")
        self.assertEqual(self.calc_out("date", "periods", "2024-01-03", "2024-01-16", "week"),
                         "2024-01-01..2024-01-07\n2024-01-08..2024-01-14\n2024-01-15..2024-01-21\n")
        self.assertEqual(self.calc_out("date", "periods", "2024-03-05", "2024-03-05", "month"), "2024-03\n")
        for argv in [["2024-03-05", "2024-03-04", "month"], ["2024-03-05", "2024-04-04", "day"],
                     ["0001-01-01", "9999-12-31", "week"]]:
            with self.subTest(argv=argv):
                self.fails("calc", "date", "periods", *argv, db=False)
        self.assertEqual(len(self.calc_out("date", "periods", "1900-01-01", "2200-12-31", "year").splitlines()), 301)

    def test_schedule(self):
        run = lambda *a: self.calc_out("schedule", *a).split()
        self.assertEqual(run("monthly on 31", "--from", "2024-01-01", "--to", "2024-05-31"),
                         ["2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30", "2024-05-31"])
        self.assertEqual(run("weekly on mon", "--from", "2024-01-01", "--to", "2024-01-20"),
                         ["2024-01-01", "2024-01-08", "2024-01-15"])
        self.assertEqual(run("every 3 months from 2024-01-31", "--from", "2024-01-01", "--to", "2025-02-01"),
                         ["2024-01-31", "2024-04-30", "2024-07-31", "2024-10-31", "2025-01-31"])
        self.assertEqual(run("Monthly On LAST", "--from", "2024-02-01", "--to", "2024-03-31"),
                         ["2024-02-29", "2024-03-31"])
        self.assertEqual(run("yearly on 02-29", "--from", "2024-01-01", "--to", "2026-12-31"),
                         ["2024-02-29", "2025-02-28", "2026-02-28"])
        self.assertEqual(run("daily", "--from", "2024-03-01", "--to", "2024-03-03"),
                         ["2024-03-01", "2024-03-02", "2024-03-03"])
        self.assertEqual(self.calc_out("schedule", "daily", "--from", "2024-03-05", "--to", "2024-03-01"), "")
        self.assertEqual(run("daily", "--from=2024-03-01", "--to=2024-03-01"), ["2024-03-01"])

    def test_schedule_series_options_and_limits(self):
        run = lambda *a: self.calc_out("schedule", *a).split()
        self.assertEqual(run("monthly on 5", "--from", "2024-04-01", "--to", "2024-06-30", "--start", "2024-01-01",
                             "--count", "3"), [])
        self.assertEqual(run("monthly on 5", "--from", "2024-02-01", "--to", "2024-06-30", "--start", "2024-01-01",
                             "--count", "3"), ["2024-02-05", "2024-03-05"])
        self.assertEqual(run("monthly on 5", "--from", "2024-01-01", "--to", "2024-12-31", "--start", "2024-02-10"),
                         ["2024-03-05", "2024-04-05", "2024-05-05", "2024-06-05", "2024-07-05", "2024-08-05",
                          "2024-09-05", "2024-10-05", "2024-11-05", "2024-12-05"])
        self.assertEqual(run("monthly on 5", "--from", "2024-01-01", "--to", "2024-12-31", "--end", "2024-03-05"),
                         ["2024-01-05", "2024-02-05", "2024-03-05"])
        self.assertEqual(run("every 2 weeks from 2024-01-03", "--from", "2024-01-20", "--to", "2024-02-28",
                             "--start", "2024-01-20"), ["2024-01-31", "2024-02-14", "2024-02-28"])
        for argv in [["daily", "--from", "2024-01-01", "--to", "2024-01-05", "--count", "0"],
                     ["daily", "--from", "2024-01-01", "--to", "2024-01-05", "--end", "2023-12-31"],
                     ["daily on mon", "--from", "2024-01-01", "--to", "2024-01-05"],
                     ["daily", "--from", "2000-01-01", "--to", "2110-01-01"],                  # longer than 40000 days
                     ["daily", "--from", "2024-01-01", "--to", "2024-01-05", "--start", "1900-01-01"]]:
            with self.subTest(argv=argv):
                self.fails("calc", "schedule", *argv, db=False)
        long_run = self.calc_out("schedule", "daily", "--from", "2023-01-01", "--to", "2024-12-31").split()
        self.assertEqual((len(long_run), long_run[0], long_run[-1]), (731, "2023-01-01", "2024-12-31"))


# ------------------------------------------------------------------------------------------------ calc: library helpers

class M15CalcLibrary(CliBase):
    def test_account_check_and_match(self):
        self.assertEqual(self.calc_out("account", "check", "Assets:Bank:Checking"),
                         "path: Assets:Bank:Checking\ntype: asset\nparent: Assets:Bank\n")
        self.assertEqual(self.calc_out("account", "check", "Expenses"), "path: Expenses\ntype: expense\nparent: none\n")
        for bad in ["assets:Bank", "Assets::Bank", "Savings:Bank", ""]:
            with self.subTest(bad=bad):
                self.fails("calc", "account", "check", bad, db=False)
        for pattern, path, want in [("Expenses", "Expenses:Food", "yes"), ("Expenses:Food", "Expenses:Foods", "no"),
                                    ("Expenses:*", "Expenses:Food:Dining", "no"), ("Expenses:*", "Expenses:Food", "yes"),
                                    ("Expenses:**", "Expenses", "no"), ("Assets:*:Checking", "Assets:Bank:Checking", "yes"),
                                    ("**", "Income:Salary", "yes")]:
            with self.subTest(pattern=pattern, path=path):
                self.assertEqual(self.calc_out("account", "match", pattern, path), want + "\n")
        self.fails("calc", "account", "match", "Expenses:Fo*", "Expenses:Food", db=False)

    def test_rules(self):
        rules = self.write("rules.txt", "# coffee\n"
                           'when payee ~ "nero|coffee" and amount < 0 then account Expenses:Food tag coffee tag Treat'
                           ' narration "Coffee break"\n'
                           'when payee = "acme payroll" then account Income:Salary tag salary flag !\n'
                           "when amount >= 1000.00USD then payee \"Big one\"\n"
                           "when any then account Expenses:Misc\n")
        run = lambda *a: self.calc_out("rules", rules, *a)
        self.assertEqual(run("--payee", "CAFE NERO", "--amount", "-3.40 GBP"),
                         "rule: 2\naccount: Expenses:Food\nnarration: Coffee break\ntags: coffee,treat\n")
        self.assertEqual(run("--payee", "Acme Payroll"), "rule: 3\naccount: Income:Salary\nflag: !\ntags: salary\n")
        self.assertEqual(run("--payee", "x", "--amount", "1200.00 USD"), "rule: 4\npayee: Big one\n")
        self.assertEqual(run("--payee", "x", "--amount", "1200.00 EUR"), "rule: 5\naccount: Expenses:Misc\n")
        self.assertEqual(run("--payee", "cafe nero"), "rule: 5\naccount: Expenses:Misc\n")       # no amount: fails
        only_nero = self.write("r2.txt", 'when payee ~ "nero" then narration ""\n')
        self.assertEqual(self.calc_out("rules", only_nero, "--payee", "nero"), "rule: 1\nnarration:\n")
        self.assertEqual(self.calc_out("rules", only_nero, "--payee", "tea"), "no match\n")
        self.assertEqual(self.calc_out("rules", only_nero, "--narration", "nero"), "no match\n")
        self.fails("calc", "rules", self.write("bad.txt", "when payee = x then flag *\n"), db=False)
        self.fails("calc", "rules", self.path("missing.txt"), db=False)
        self.fails("calc", "rules", only_nero, "--amount", "3", db=False)
        self.fails("calc", "rules", only_nero, "--date", "2024-02-30", db=False)


# ------------------------------------------------------------------------------------------------ calc: journal files

class M15CalcJournal(CliBase):
    def test_journal_check(self):
        self.assertEqual(self.calc_out("journal", "check", self.sample()), "ok: 7 accounts, 1 rates, 8 transactions\n")
        self.assertEqual(self.calc_out("journal", "check", "-", stdin=SAMPLE), "ok: 7 accounts, 1 rates, 8 transactions\n")
        self.assertEqual(self.calc_out("journal", "check", "-", stdin=""), "ok: 0 accounts, 0 rates, 0 transactions\n")
        unbalanced = 'account Assets:A\naccount Expenses:B\n\n2024-01-01 * "x"\n  Assets:A  -5.00 USD\n  Expenses:B  4.00 USD\n'
        self.fails("calc", "journal", "check", "-", stdin=unbalanced, db=False)
        undeclared = '2024-01-01 * "x"\n  Assets:A  -5.00 USD\n  Expenses:B  5.00 USD\n'
        self.fails("calc", "journal", "check", "-", stdin=undeclared, db=False)
        # the same file is fine for `format`, which only reads the writing
        self.assertTrue(self.calc_out("journal", "format", "-", stdin=undeclared).startswith("2024-01-01 * \"x\""))

    def test_journal_format_is_canonical(self):
        messy = ("; my book\n\naccount Assets:Cash USD open 2023-01-01 \"cash\" ; trailing\naccount Expenses:Food\n\n"
                 "rate 2024-03-01 USD EUR 0.92\n\n2024-03-02 ! \"Corner shop\" #b #a ; hello\n"
                 "    Expenses:Food   12.50 USD    ; lunch\n\t; a comment inside\n    Assets:Cash\n")
        want = ('account Assets:Cash USD open 2023-01-01 "cash"\naccount Expenses:Food\n\n'
                "rate 2024-03-01 USD EUR 0.92\n\n"
                '2024-03-02 ! "Corner shop" #a #b\n  Expenses:Food  12.50 USD  ; lunch\n  Assets:Cash\n')
        self.assertEqual(self.calc_out("journal", "format", "-", stdin=messy), want)
        self.assertEqual(self.calc_out("journal", "format", "-", stdin=want), want)             # canonical stays
        self.assertEqual(self.calc_out("journal", "format", self.sample()), SAMPLE)
        self.assertEqual(self.calc_out("journal", "format", "-", stdin="; nothing here\n\n"), "")

    def test_journal_files_may_have_a_bom_and_crlf(self):
        text = "﻿" + SAMPLE.replace("\n", "\r\n")
        path = self.write("crlf.journal", text, newline="")
        self.assertEqual(self.calc_out("journal", "format", path), SAMPLE)
        self.assertEqual(self.calc_out("journal", "check", path), "ok: 7 accounts, 1 rates, 8 transactions\n")

    def test_journal_mistakes(self):
        err = self.fails("calc", "journal", "format", "-", stdin="account Assets:A\n\n2024-02-30 * \"x\"\n", db=False)
        self.assertIn("line 3", err)
        path = self.write("bad.journal", "account Assets:A\naccount assets:b\n")
        err = self.fails("calc", "journal", "check", path, db=False)
        self.assertIn("line 2", err)
        self.assertIn(path, err)
        self.fails("calc", "journal", "check", self.path("missing.journal"), db=False)
        binary = self.path("binary.journal")
        with open(binary, "wb") as fh:
            fh.write(b"account Assets:A \xff\xfe\n")
        self.fails("calc", "journal", "check", binary, db=False)
        self.fails("calc", "journal", "format", self.tmp, db=False)               # a directory

    def test_query(self):
        run = lambda q, *a: self.calc_out("query", q, "--journal", self.sample(), *a)
        self.assertEqual(run("payee:Market"),
                         "Id  Date        Flag  Payee   Narration  Tags\n"
                         "--  ----------  ----  ------  ---------  ----\n"
                         " 3  2024-03-02  *     Market\n"
                         " 8  2024-04-03  *     Market\n")
        self.assertEqual([t["id"] for t in json.loads(run("account:Expenses:Rent or payee:ATM", "--json"))], [4, 5])
        self.assertEqual(run("payee:Nobody"), "")
        self.assertEqual(run("payee:Nobody", "--json"), "[]\n")
        first = json.loads(run("payee:Acme", "--json"))[0]
        self.assertEqual(first["date"], "2024-03-01")
        self.assertEqual(first["postings"][0]["amount"], {"amount": "2500.00", "currency": "USD"})
        self.assertEqual(run(""), self.calc_out("query", "", "--journal", self.sample()))
        self.assertEqual(len(run("").splitlines()), 10)
        self.fails("calc", "query", "account:Nope", "--journal", self.sample(), db=False)
        self.fails("calc", "query", "payee:Market", db=False, status=2)
        stdin_run = self.calc_out("query", "payee:ATM", "--journal", "-", stdin=SAMPLE)
        self.assertIn("ATM", stdin_run)

    def test_rate(self):
        journal = self.write("rates.journal", "rate 2024-03-01 USD EUR 0.92\nrate 2024-03-10 USD EUR 0.9\n"
                                              "rate 2024-03-05 GBP USD 1.25\n")
        run = lambda *a: self.calc_out("rate", *a, "--journal", journal)
        self.assertEqual(run("USD", "EUR", "--on", "2024-03-01"), "23/25\n")
        self.assertEqual(run("USD", "EUR", "--on", "2024-03-09"), "23/25\n")
        self.assertEqual(run("USD", "EUR", "--on", "2024-03-10"), "9/10\n")
        self.assertEqual(run("EUR", "USD", "--on", "2024-03-10"), "10/9\n")
        self.assertEqual(run("USD", "GBP", "--on", "2024-03-05"), "4/5\n")
        self.assertEqual(run("USD", "USD", "--on", "2024-03-05"), "1/1\n")
        self.fails("calc", "rate", "USD", "EUR", "--on", "2024-02-29", "--journal", journal, db=False)
        self.fails("calc", "rate", "USD", "JPY", "--on", "2024-03-10", "--journal", journal, db=False)
        self.fails("calc", "rate", "USD", "EUR", "--on", "soon", "--journal", journal, db=False)
        self.fails("calc", "rate", "USD", "EUR", "--journal", journal, db=False, status=2)

    def test_budget(self):
        run = lambda *a: self.calc_out("budget", *a, "--journal", self.sample())
        self.assertEqual(run("Expenses:Food", "100.00 USD", "--period", "2024-03"),
                         "Pattern        Per        Budget     Actual  Remaining  Percent  Over\n"
                         "-------------  -----  ----------  ---------  ---------  -------  ----\n"
                         "Expenses:Food  month  100.00 USD  54.50 USD  45.50 USD    54.5%\n")
        self.assertEqual(run("Expenses:Food", "100.00 USD", "--period", "2024-Q1", "--per", "quarter"),
                         "Pattern        Per          Budget     Actual  Remaining  Percent  Over\n"
                         "-------------  -------  ----------  ---------  ---------  -------  ----\n"
                         "Expenses:Food  quarter  100.00 USD  54.50 USD  45.50 USD    54.5%\n")

    def test_budget_over_and_json(self):
        run = lambda *a: self.calc_out("budget", *a, "--journal", self.sample())
        lines = run("Expenses:Food", "50.00 USD", "--period", "2024-03").splitlines()
        self.assertTrue(lines[2].split()[-1] == "over")
        self.assertIn("109.0%", lines[2])
        data = json.loads(run("Expenses", "2000.00 USD", "--per", "quarter", "--period", "2024-Q1", "--json"))
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["actual"], {"amount": "954.50", "currency": "USD"})
        self.assertEqual(data[0]["budget"], {"amount": "2000.00", "currency": "USD"})
        self.assertEqual(data[0]["percent"], "47.7")
        self.assertIs(data[0]["over"], False)
        self.assertEqual(run("Expenses", "10.00 USD", "--period", "2024-03", "--start", "2024-06-01"), "")
        self.assertEqual(run("Expenses", "10.00 USD", "--period", "2024-03", "--start", "2024-06-01", "--json"), "[]\n")
        self.fails("calc", "budget", "Expenses", "10.00 USD", "--period", "2024-03", "--per", "week",
                   "--journal", self.sample(), db=False)
        self.fails("calc", "budget", "expenses", "10.00 USD", "--period", "2024-03", "--journal", self.sample(), db=False)
        self.fails("calc", "budget", "Expenses", "0.00 USD", "--period", "2024-03", "--journal", self.sample(), db=False)
        self.fails("calc", "budget", "Expenses", "10.00 USD", "--journal", self.sample(), db=False, status=2)

    @phase("pre")
    def test_ties_of_budget_and_report_percentages_go_up(self):
        journal = self.write("ties.journal", TIE_JOURNAL)
        lines = self.calc_out("budget", "Expenses:Food", "4.00 USD", "--period", "2024-03", "--journal", journal)
        self.assertIn("0.3%", lines)
        report = self.calc_out("report", "income-statement", "--journal", journal, "--period", "2024-03")
        self.assertIn("6.3%", report)
        self.assertIn("93.8%", report)
        data = json.loads(self.calc_out("report", "income-statement", "--journal", journal, "--period", "2024-03",
                                        "--json"))
        self.assertEqual([a["percent"] for a in data["expenses"]["accounts"]], ["6.3", "93.8"])

    @phase("post")
    def test_ties_of_budget_and_report_percentages_go_to_even(self):
        journal = self.write("ties.journal", TIE_JOURNAL)
        lines = self.calc_out("budget", "Expenses:Food", "4.00 USD", "--period", "2024-03", "--journal", journal)
        self.assertIn("0.2%", lines)
        report = self.calc_out("report", "income-statement", "--journal", journal, "--period", "2024-03")
        self.assertIn("6.2%", report)
        self.assertIn("93.8%", report)
        data = json.loads(self.calc_out("report", "income-statement", "--journal", journal, "--period", "2024-03",
                                        "--json"))
        self.assertEqual([a["percent"] for a in data["expenses"]["accounts"]], ["6.2", "93.8"])

    def test_reports_as_text(self):
        sample = self.sample()
        run = lambda *a: self.calc_out("report", *a, "--journal", sample)
        self.assertEqual(run("balance-sheet", "--as-of", "2024-03-31"), BALANCE_SHEET)
        self.assertEqual(run("income-statement", "--period", "2024-03"), INCOME_STATEMENT)
        self.assertEqual(run("register", "Assets:Bank:Checking", "--period", "2024-03"), REGISTER)
        self.assertEqual(run("trial-balance", "--as-of", "2024-03-31"), TRIAL_BALANCE)
        self.assertEqual(run("cashflow", "--period", "2024-03"), CASHFLOW)

    def test_reports_as_json(self):
        run = lambda *a: json.loads(self.calc_out("report", *a, "--journal", self.sample(), "--json"))
        tb = run("trial-balance", "--as-of", "2024-03-31")
        self.assertEqual((tb["report"], tb["as_of"]), ("trial_balance", "2024-03-31"))
        self.assertEqual(tb["totals"], [{"currency": "USD", "debit": {"amount": "4400.00", "currency": "USD"},
                                         "credit": {"amount": "4400.00", "currency": "USD"}, "balanced": True}])
        self.assertIsNone(run("trial-balance")["as_of"])
        bs = run("balance-sheet", "--as-of", "2024-03-31")
        self.assertEqual(bs["assets"]["total"], [{"amount": "3445.50", "currency": "USD"}])
        self.assertIs(bs["balanced"], True)
        inc = run("income-statement", "--period", "2024-03")
        self.assertEqual(inc["net"], [{"amount": "1545.50", "currency": "USD"}])
        flow = run("cashflow", "--period", "2024-04")
        self.assertEqual(flow["closing"], [{"amount": "2515.50", "currency": "USD"}])
        reg = run("register", "Expenses", "--rollup", "--period", "2024-03")
        self.assertEqual([r["id"] for r in reg["rows"]], [3, 4, 6])
        self.assertIs(reg["rollup"], True)
        raw = self.calc_out("report", "trial-balance", "--journal", self.sample(), "--json")
        self.assertEqual(raw, json.dumps(json.loads(raw), indent=2, sort_keys=True, ensure_ascii=False) + "\n")

    def test_report_options(self):
        sample = self.sample()
        run = lambda *a: self.calc_out("report", *a, "--journal", sample)
        converted = run("balance-sheet", "--as-of", "2024-03-31", "--convert", "EUR")
        self.assertTrue(converted.startswith("Balance sheet as of 2024-03-31 (in EUR)\n"))
        self.assertIn("3088.90 EUR", converted)                       # 3357.50 USD at 0.92
        self.assertIn("(in EUR)", run("income-statement", "--period", "2024-03", "--convert", "EUR"))
        self.assertTrue(run("register", "Expenses", "--rollup").startswith("Register Expenses (with sub-accounts)\n"))
        self.assertTrue(run("register", "Expenses", "--period", "2024-04").startswith(
            "Register Expenses 2024-04-01 to 2024-04-30\n"))
        # an option that does not belong to the kind is ignored, and so is a surplus account
        self.assertEqual(run("cashflow", "--period", "2024-03", "--as-of", "2023-01-01", "--rollup"), CASHFLOW)
        self.assertEqual(run("cashflow", "Assets", "--period", "2024-03"), CASHFLOW)
        # defaults come from --today
        today = self.out("--today", "2024-03-20", "calc", "report", "income-statement", "--journal", sample, db=False)
        self.assertEqual(today, INCOME_STATEMENT)
        sheet = self.out("--today", "2024-03-31", "calc", "report", "balance-sheet", "--journal", sample, db=False)
        self.assertEqual(sheet, BALANCE_SHEET)
        self.assertTrue(run("trial-balance").startswith("Trial balance\n"))

    def test_report_errors(self):
        sample = self.sample()
        self.fails("calc", "report", "register", "Assets:Nope", "--journal", sample, db=False)
        self.fails("calc", "report", "balance-sheet", "--journal", sample, "--as-of", "2024-03-31", "--convert", "GBP",
                   db=False)                                                  # no such rate
        self.fails("calc", "report", "income-statement", "--journal", sample, "--period", "2024-13", db=False)
        self.fails("calc", "report", "trial-balance", "--journal", sample, "--as-of", "2024-02-30", db=False)
        self.fails("calc", "report", "trial-balance", "--journal", self.path("missing.journal"), db=False)
        self.fails("calc", "report", "trial-balance", db=False, status=2)

    def test_csv(self):
        profile = self.write("bank.profile", BANK_PROFILE)
        statement = self.write("march.csv", BANK_CSV)
        want = ('2024-03-01 * "Corner Shop" "milk"\n  Assets:Bank    -5.00 USD\n  Expenses:Misc   5.00 USD\n\n'
                '2024-03-02 * "Employer" "march pay"\n  Assets:Bank     100.00 USD\n  Expenses:Misc  -100.00 USD\n\n'
                '2024-03-03 * "Cafe Nero" "latte"\n  Assets:Bank    -3.40 USD\n  Expenses:Misc   3.40 USD\n')
        self.assertEqual(self.calc_out("csv", profile, statement), want)
        self.assertEqual(self.calc_out("csv", profile, "-", stdin=BANK_CSV), want)
        ruled = self.calc_out("csv", profile, statement, "--rules", self.write("bank.rules", BANK_RULES))
        self.assertEqual(ruled,
                         '2024-03-01 * "Corner Shop" "milk" #coffee\n  Assets:Bank    -5.00 USD\n'
                         "  Expenses:Food   5.00 USD\n\n"
                         '2024-03-02 * "Employer" "march pay"\n  Assets:Bank   100.00 USD\n  Income:Pay   -100.00 USD\n\n'
                         '2024-03-03 * "Cafe Nero" "latte" #coffee\n  Assets:Bank    -3.40 USD\n'
                         "  Expenses:Food   3.40 USD\n")
        self.assertEqual(self.calc_out("csv", profile, self.write("none.csv", "Date,Payee,Memo,Amount\n")), "")

    def test_csv_mistakes(self):
        profile = self.write("bank.profile", BANK_PROFILE)
        bad_row = self.write("bad.csv", BANK_CSV + "2024-03-04,Shop,x,abc\n2024-13-01,Shop,x,5.00\n2024-03-06,Shop,x,1.50\n")
        err = self.fails("calc", "csv", profile, bad_row, db=False)
        self.assertIn("row 5: ", err)
        self.assertIn("row 6: ", err)
        self.assertNotIn("row 7", err)
        self.assertIn("abc", err)
        self.assertIn("2024-13-01", err)
        no_column = self.write("nocol.csv", "Day,Payee,Memo,Amount\n2024-03-01,A,b,1.00\n")
        self.fails("calc", "csv", profile, no_column, db=False)
        self.fails("calc", "csv", self.write("bad.profile", "currency = USD\n"), self.write("ok.csv", BANK_CSV), db=False)
        self.fails("calc", "csv", profile, self.path("missing.csv"), db=False)
        self.fails("calc", "csv", profile, db=False, status=2)
        self.fails("calc", "csv", profile, self.write("ok.csv", BANK_CSV), "--rules", self.path("missing.rules"), db=False)


# ------------------------------------------------------------------------------------------------ a book file

OLD_V1 = ["CREATE TABLE accounts (path TEXT PRIMARY KEY, type TEXT NOT NULL, currency TEXT, opened TEXT,"
          " note TEXT NOT NULL DEFAULT '')",
          "CREATE TABLE transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, payee TEXT NOT NULL,"
          " narration TEXT NOT NULL DEFAULT '', cleared INTEGER NOT NULL DEFAULT 1)",
          "CREATE TABLE postings (id INTEGER PRIMARY KEY AUTOINCREMENT,"
          " tx_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,"
          " seq INTEGER NOT NULL, account TEXT NOT NULL REFERENCES accounts(path),"
          " minor INTEGER NOT NULL, currency TEXT NOT NULL)"]


class M15BookFile(CliBase):
    def old_book(self):
        conn = sqlite3.connect(self.db)
        for sql in OLD_V1:
            conn.execute(sql)
        conn.execute("INSERT INTO accounts (path, type, currency) VALUES ('Assets:Bank', 'asset', ' usd ')")
        conn.execute("PRAGMA user_version = 1")
        conn.commit()
        conn.close()

    def test_init_creates_the_book_once(self):
        self.assertEqual(self.out("init"), "created %s (version 4)\n" % self.db)
        self.assertEqual(self.out("db", "version"), "4\n")
        self.assertEqual(self.out("init"), "%s is up to date (version 4)\n" % self.db)
        self.assertEqual(self.out("account", "list"), "")
        self.assertEqual(self.out("account", "list", "--json"), "[]\n")

    def test_init_refuses_what_is_not_a_book(self):
        with open(self.db, "w") as fh:
            fh.write("this is not a database, just some text\n")
        self.fails("init")
        self.fails("tx", "list")
        with open(self.db) as fh:
            self.assertEqual(fh.read(), "this is not a database, just some text\n")
        self.fails("--db", self.path("no-such-dir/book.db"), "init", db=False)

    def test_init_migrates_an_old_book(self):
        self.old_book()
        self.assertEqual(self.out("db", "version"), "1\n")
        err = self.fails("account", "list")
        self.assertIn("database is at version 1, run `tallybook db migrate`", err)
        self.assertEqual(self.out("init"), "migrated %s from version 1 to 4\n" % self.db)
        self.assertEqual(self.out("db", "version"), "4\n")
        self.assertEqual(json.loads(self.out("account", "show", "Assets:Bank", "--json"))["currency"], "USD")

    def test_db_migrate_lists_the_steps(self):
        self.old_book()
        self.assertEqual(self.out("db", "migrate"), "applied version 2\napplied version 3\napplied version 4\n")
        self.assertEqual(self.out("db", "migrate"), "database is up to date (version 4)\n")

    def test_every_command_needs_a_book(self):
        for argv in [["account", "list"], ["tx", "list"], ["query", "payee:x"], ["export"],
                     ["report", "trial-balance"], ["budget", "list"], ["rules", "show"], ["db", "version"],
                     ["serve", "--port", "0"]]:
            with self.subTest(argv=argv):
                err = self.fails(*argv)
                self.assertIn("no such database: %s (run `tallybook init`)" % self.db, err)
        self.assertFalse(os.path.exists(self.db))

    def test_db_info_check_backup(self):
        self.book_with_sample()
        self.assertEqual(self.out("db", "info"),
                         "path: %s\nversion: 4\naccounts: 7\ntransactions: 8\npostings: 16\nrates: 1\nbudgets: 0\n"
                         "recurring: 0\n" % self.db)
        info = json.loads(self.out("db", "info", "--json"))
        self.assertEqual((info["version"], info["transactions"], info["path"]), (4, 8, self.db))
        self.assertEqual(self.out("db", "check"), "ok\n")
        dest = self.path("copy.db")
        self.assertEqual(self.out("db", "backup", dest), "backed up to %s\n" % dest)
        self.assertEqual(self.out("--db", dest, "export", "--format", "journal", db=False), SAMPLE)
        self.fails("db", "backup", dest)                                  # it exists now
        self.fails("db", "backup", self.path("nodir/copy.db"))
        # damage the book behind its back: the check reports it on standard output and exits 1
        conn = sqlite3.connect(self.db)
        conn.execute("PRAGMA foreign_keys = OFF")
        conn.execute("DELETE FROM transactions WHERE id = 1")
        conn.commit()
        conn.close()
        r = self.tb("db", "check")
        self.assertEqual(r.rc, 1)
        self.assertGreaterEqual(len(r.lines), 1)

    def test_closing_the_chart(self):
        self.init(("Assets:Bank", "--currency", "USD", "--open", "2024-01-01", "--note", "main account"),
                  "Equity:Opening", "Expenses:Food")
        self.assertEqual(self.out("account", "list"),
                         "Account         Type     Currency  Opened      Closed  Note\n"
                         "--------------  -------  --------  ----------  ------  ------------\n"
                         "Assets:Bank     asset    USD       2024-01-01          main account\n"
                         "Equity:Opening  equity\n"
                         "Expenses:Food   expense\n")
        self.assertEqual(self.out("--today", "2024-06-30", "account", "close", "Expenses:Food"),
                         "closed account Expenses:Food on 2024-06-30\n")
        self.assertEqual(self.out("account", "close", "Equity:Opening", "--on", "2024-02-01"),
                         "closed account Equity:Opening on 2024-02-01\n")
        listed = json.loads(self.out("account", "list", "--json"))
        self.assertEqual([a["path"] for a in listed], ["Assets:Bank", "Equity:Opening", "Expenses:Food"])
        self.assertEqual(listed[0], {"path": "Assets:Bank", "type": "asset", "currency": "USD", "opened": "2024-01-01",
                                     "closed": None, "note": "main account"})
        self.assertEqual(listed[1]["closed"], "2024-02-01")
        self.assertEqual([a["path"] for a in json.loads(self.out("account", "list", "--open-only", "--json"))],
                         ["Assets:Bank"])
        self.fails("account", "close", "Expenses:Food", "--on", "2024-07-01")         # already closed
        self.fails("account", "close", "Assets:Nope")

    def test_account_listing_filters_and_show(self):
        self.init()
        self.out("journal", "import", "-", stdin="account Assets:Bank\naccount Assets:Bank:Checking USD\n"
                                                 "account Assets:Bank:Savings EUR\naccount Expenses:Food\n"
                                                 "account Income:Salary\n")
        paths = lambda *a: [x["path"] for x in json.loads(self.out("account", "list", "--json", *a))]
        self.assertEqual(paths("--type", "asset"), ["Assets:Bank", "Assets:Bank:Checking", "Assets:Bank:Savings"])
        self.assertEqual(paths("--under", "Assets:Bank:Checking"), ["Assets:Bank:Checking"])
        self.assertEqual(paths("--currency", "EUR"), ["Assets:Bank:Savings"])
        self.assertEqual(paths("--type", "income", "--currency", "EUR"), [])
        self.fails("account", "list", "--type", "bogus")
        self.out("tx", "add", "Pay", "--date", "2024-02-01", "-p", "Assets:Bank:Checking 10.00 USD", "-p", "Income:Salary")
        self.out("tx", "add", "Fx", "--date", "2024-02-02", "-p", "Assets:Bank:Savings 5.00 EUR",
                 "-p", "Income:Salary -5.00 EUR")
        self.assertEqual(self.out("account", "show", "Assets:Bank:Checking"),
                         "path: Assets:Bank:Checking\ntype: asset\ncurrency: USD\nopened: none\nclosed: none\nnote:\n"
                         "balance: 10.00 USD\n")
        self.assertEqual(self.out("account", "show", "Income:Salary").splitlines()[-1],
                         "balance: -5.00 EUR, -10.00 USD")
        shown = json.loads(self.out("account", "show", "Assets:Bank", "--json"))
        self.assertEqual(shown["balance"], [{"amount": "5.00", "currency": "EUR"}, {"amount": "10.00", "currency": "USD"}])
        self.assertEqual(self.out("account", "show", "Expenses:Food").splitlines()[-1], "balance: none")
        self.assertIn("currency: any", self.out("account", "show", "Expenses:Food"))
        self.fails("account", "show", "Assets:Nope")

    def test_account_mistakes(self):
        self.init("Assets:Bank")
        for argv in [["Assets:Bank"], ["assets:bank"], ["Assets:New", "--currency", "usd"],
                     ["Assets:New", "--open", "2024-02-30"]]:
            with self.subTest(argv=argv):
                self.fails("account", "add", *argv)
        self.assertEqual(self.out("account", "add", "Assets:Bank:Old", "--note", ""), "added account Assets:Bank:Old\n")
        self.assertEqual(len(json.loads(self.out("account", "list", "--json"))), 2)


# ------------------------------------------------------------------------------------------------ transactions

class M15Transactions(CliBase):
    def setUp(self):
        super().setUp()
        self.standard_book()

    def test_add_list_show_delete(self):
        self.assertEqual(self.out("tx", "add", "Opening", "--date", "2024-01-01", "-p", "Assets:Cash 100.00 USD",
                                  "-p", "Equity:Opening -100.00 USD"), "added transaction 1\n")
        self.assertEqual(self.out("tx", "add", "Market", "--date", "2024-03-02", "--narration", "weekly shop",
                                  "--tag", "food", "--tag", "home", "--flag", "!",
                                  "--posting", "Expenses:Food 42.50 USD ; veg", "--posting", "Assets:Cash"),
                         "added transaction 2\n")
        self.assertEqual(self.out("tx", "list"),
                         "Id  Date        Flag  Payee    Narration    Tags\n"
                         "--  ----------  ----  -------  -----------  -----------\n"
                         " 1  2024-01-01  *     Opening\n"
                         " 2  2024-03-02  !     Market   weekly shop  #food #home\n")
        self.assertEqual(self.out("tx", "show", "2"),
                         '; id 2\n2024-03-02 ! "Market" "weekly shop" #food #home\n'
                         "  Expenses:Food   42.50 USD  ; veg\n  Assets:Cash    -42.50 USD\n")
        shown = json.loads(self.out("tx", "show", "2", "--json"))
        self.assertEqual(shown, {"id": 2, "date": "2024-03-02", "flag": "!", "payee": "Market", "narration": "weekly shop",
                                 "tags": ["food", "home"],
                                 "postings": [{"account": "Expenses:Food", "amount": {"amount": "42.50", "currency": "USD"},
                                               "note": "veg"},
                                              {"account": "Assets:Cash", "amount": {"amount": "-42.50", "currency": "USD"},
                                               "note": ""}]})
        self.assertEqual(self.out("tx", "delete", "1"), "deleted transaction 1\n")
        self.assertEqual([t["id"] for t in json.loads(self.out("tx", "list", "--json"))], [2])
        self.fails("tx", "show", "1")

    def test_add_with_json_and_defaults(self):
        stored = json.loads(self.out("--today", "2024-05-06", "tx", "add", "Lunch", "-p", "Expenses:Food 9.00 USD",
                                     "-p", "Assets:Cash", "--json"))
        self.assertEqual((stored["id"], stored["date"], stored["flag"], stored["narration"], stored["tags"]),
                         (1, "2024-05-06", "*", "", []))
        self.assertEqual(stored["postings"][1]["amount"], {"amount": "-9.00", "currency": "USD"})     # filled in
        # white space inside a posting does not matter
        self.out("tx", "add", "Spaced", "--date", "2024-05-07", "-p", "  Expenses:Food    1.00   USD   ",
                 "-p", "Assets:Cash   -1.00 USD;note")
        shown = json.loads(self.out("tx", "show", "2", "--json"))
        self.assertEqual(shown["postings"][1]["note"], "note")

    def test_add_mistakes(self):
        base = ["tx", "add", "X", "--date", "2024-01-02"]
        for extra in [["-p", "Assets:Cash 5.00 USD"],                                        # does not balance
                      ["-p", "Assets:Cash 5.00 USD", "-p", "Expenses:Nope -5.00 USD"],       # unknown account
                      ["-p", "Assets:Cash 5.00", "-p", "Expenses:Food -5.00 USD"],           # no currency
                      ["-p", "Assets:Cash 5.001 USD", "-p", "Expenses:Food"],
                      ["-p", "Assets:Cash 5.00 USD", "-p", "Expenses:Food", "--flag", "?"], []]:
            with self.subTest(extra=extra):
                self.fails(*base, *extra)
        self.fails("tx", "add", "X", "--date", "2024-02-30", "-p", "Assets:Cash 5.00 USD", "-p", "Expenses:Food")
        self.fails("tx", "add", status=2)
        self.fails("tx", "add", "X", "-p", status=2)
        self.assertEqual(self.out("tx", "list"), "")                                          # nothing was stored

    def test_ids_must_be_whole_numbers(self):
        for argv in [["tx", "show", "abc"], ["tx", "show", "0"], ["tx", "delete", "x"], ["tx", "delete", "99"]]:
            with self.subTest(argv=argv):
                self.fails(*argv)
        self.fails("tx", "show", status=2)

    def fill(self):
        for day, payee, amount, acct in [("2024-01-05", "Shop", "10.00", "Expenses:Food"),
                                         ("2024-01-20", "Cafe", "4.50", "Expenses:Food"),
                                         ("2024-02-03", "Landlord", "800.00", "Expenses:Rent"),
                                         ("2024-02-10", "Shop", "22.00", "Expenses:Food"),
                                         ("2024-03-01", "Arcade", "5.00", "Expenses:Fun")]:
            self.out("tx", "add", payee, "--date", day, "-p", "%s %s USD" % (acct, amount), "-p", "Assets:Cash")

    def test_paging_and_queries(self):
        self.fill()
        ids = lambda *a: [t["id"] for t in json.loads(self.out(*a, "--json"))]
        self.assertEqual(ids("tx", "list"), [1, 2, 3, 4, 5])
        self.assertEqual(ids("tx", "list", "--limit", "2"), [1, 2])
        self.assertEqual(ids("tx", "list", "--limit", "2", "--offset", "3"), [4, 5])
        self.assertEqual(ids("tx", "list", "--offset", "4"), [5])
        self.assertEqual(ids("tx", "list", "--offset", "9"), [])
        self.assertEqual(ids("tx", "list", "--limit", "0"), [])
        self.assertEqual(ids("tx", "list", "--query", "payee:Shop"), [1, 4])
        self.assertEqual(ids("tx", "list", "--query", "payee:Shop", "--offset", "1"), [4])
        self.assertEqual(ids("query", "account:Expenses:Food"), [1, 2, 4])
        self.assertEqual(ids("query", "account:Expenses:Food", "--limit", "1", "--offset", "1"), [2])
        self.assertEqual(self.out("query", "account:Expenses:Food", "--count"), "3\n")
        self.assertEqual(self.out("query", "account:Expenses:Food", "--count", "--limit", "1"), "3\n")
        self.assertEqual(self.out("query", "payee:Nobody", "--count"), "0\n")
        self.assertEqual(self.out("query", "payee:Nobody"), "")
        self.assertEqual(self.out("query", "payee:Nobody", "--json"), "[]\n")
        self.assertEqual(self.out("tx", "list", "--query", "date:2024-02"), self.out("query", "date:2024-02"))
        for argv in [["tx", "list", "--limit", "-1"], ["tx", "list", "--offset", "x"], ["tx", "list", "--limit", "1.5"],
                     ["query", "account:Expenses:Nope"], ["tx", "list", "--query", "account:Expenses:Nope"]]:
            with self.subTest(argv=argv):
                self.fails(*argv)
        self.fails("query", status=2)

    def test_export_formats(self):
        self.out("tx", "add", "Café, Bäcker", "--date", "2024-03-01", "--flag", "!", "--narration", 'say "hi"',
                 "--tag", "lunch", "--tag", "a", "-p", "Expenses:Food 4.50 USD ; a, b", "-p", "Assets:Cash")
        self.out("tx", "add", "Plain", "--date", "2024-03-02", "-p", "Expenses:Rent 9.00 USD", "-p", "Assets:Cash")
        csv = ("id,date,flag,payee,narration,tags,account,amount,currency,note\n"
               '1,2024-03-01,!,"Café, Bäcker","say ""hi""",a;lunch,Expenses:Food,4.50,USD,"a, b"\n'
               '1,2024-03-01,!,"Café, Bäcker","say ""hi""",a;lunch,Assets:Cash,-4.50,USD,\n'
               "2,2024-03-02,*,Plain,,,Expenses:Rent,9.00,USD,\n"
               "2,2024-03-02,*,Plain,,,Assets:Cash,-9.00,USD,\n")
        self.assertEqual(self.out("export"), csv)
        self.assertEqual(self.out("export", "--format", "csv"), csv)
        self.assertEqual(self.out("export", "--format=csv", "--query", "payee:Plain"), "".join(csv.splitlines(True)[:1] + csv.splitlines(True)[3:]))
        data = json.loads(self.out("export", "--format", "json"))
        self.assertEqual([t["id"] for t in data], [1, 2])
        self.assertEqual(data[0]["tags"], ["a", "lunch"])
        raw = self.out("export", "--format", "json", "--query", "payee:Nobody")
        self.assertEqual(raw, "[]\n")
        self.assertEqual(self.out("export", "--format", "csv", "--query", "payee:Nobody"),
                         "id,date,flag,payee,narration,tags,account,amount,currency,note\n")
        journal = self.out("export", "--format", "journal")
        self.assertEqual(journal, self.out("journal", "export"))
        self.assertIn('2024-03-01 ! "Café, Bäcker" "say \\"hi\\"" #a #lunch\n', journal)
        self.fails("export", "--format", "xml")
        self.fails("export", "--format", "journal", "--query", "payee:Plain")
        self.fails("export", "--format", status=2)


# ------------------------------------------------------------------------------------------------ journals

class M15Journals(CliBase):
    def test_journal_round_trip(self):
        self.book_with_sample()
        self.assertEqual(self.out("journal", "export"), SAMPLE)
        self.assertEqual(self.out("export", "--format", "journal"), SAMPLE)
        other = self.path("other.db")
        self.out("--db", other, "init", db=False)
        self.assertEqual(self.out("--db", other, "journal", "import", "-", stdin=SAMPLE, db=False),
                         "imported 7 accounts, 1 rates, 8 transactions\n")
        self.assertEqual(self.out("--db", other, "journal", "export", db=False), SAMPLE)
        self.assertEqual(self.out("rate", "list"), "From  To   Date        Rate\n----  ---  ----------  ----\n"
                                                    "USD   EUR  2024-03-01  0.92\n")
        self.assertEqual(len(json.loads(self.out("tx", "list", "--json"))), 8)
        self.assertEqual(len(json.loads(self.out("account", "list", "--json"))), 7)

    def test_import_prints_the_counts_of_the_file(self):
        self.init()
        small = 'account Assets:Cash USD\naccount Expenses:Food\n\n2024-01-02 * "x"\n  Expenses:Food  1.00 USD\n  Assets:Cash\n'
        self.assertEqual(self.out("journal", "import", self.write("small.journal", small)),
                         "imported 2 accounts, 0 rates, 1 transactions\n")
        self.assertEqual(self.out("journal", "import", self.write("empty.journal", "; nothing\n")),
                         "imported 0 accounts, 0 rates, 0 transactions\n")

    def test_journal_import_is_all_or_nothing(self):
        self.init()
        before = self.out("journal", "export")
        mistake = SAMPLE.replace("2024-03-10 * \"ATM\"", "2024-03-10 * ATM")
        err = self.fails("journal", "import", "-", stdin=mistake)
        self.assertIn("line", err)
        self.assertIn("standard input", err)
        unbalanced = SAMPLE.replace("-2500.00 USD", "-2499.00 USD")
        self.fails("journal", "import", "-", stdin=unbalanced)
        self.assertEqual(self.out("journal", "export"), before)
        self.out("journal", "import", self.sample())
        self.fails("journal", "import", self.sample())                      # the accounts exist already
        self.assertEqual(len(json.loads(self.out("tx", "list", "--json"))), 8)
        self.fails("journal", "import", self.path("missing.journal"))
        self.fails("journal", "import", status=2)


# ------------------------------------------------------------------------------------------------ bank statements

class M15Statements(CliBase):
    def setUp(self):
        super().setUp()
        self.from_template("bank", lambda: self.init(*BANK_CHART))
        self.profile = self.write("bank.profile", BANK_PROFILE)
        self.csv = self.write("march.csv", BANK_CSV)

    def test_profiles(self):
        self.assertEqual(self.out("profile", "list"), "")
        self.assertEqual(self.out("profile", "list", "--json"), "[]\n")
        self.assertEqual(self.out("profile", "add", "bank", self.profile), "stored profile bank\n")
        self.out("profile", "add", "alt", self.write("alt.profile", "date_column = #1\npayee_column = #2\n"
                                                      "amount_column = #3\ncurrency = EUR\naccount = Assets:Bank"))
        self.assertEqual(self.out("profile", "list"), "alt\nbank\n")
        self.assertEqual(json.loads(self.out("profile", "list", "--json")), ["alt", "bank"])
        self.assertEqual(self.out("profile", "show", "bank"), BANK_PROFILE)
        self.assertEqual(self.out("profile", "show", "alt").splitlines()[-1], "account = Assets:Bank")   # newline added
        self.assertEqual(self.out("profile", "remove", "alt"), "removed profile alt\n")
        self.assertEqual(self.out("profile", "list"), "bank\n")
        self.fails("profile", "show", "alt")
        self.fails("profile", "remove", "alt")
        self.fails("profile", "add", "bank", self.write("bad.profile", "currency = USD\n"))
        self.fails("profile", "add", "bad name", self.profile)
        self.fails("profile", "add", "x", self.path("missing.profile"))
        self.assertEqual(self.out("profile", "list"), "bank\n")

    def test_rules(self):
        self.assertEqual(self.out("rules", "show"), "")
        rules = self.write("bank.rules", BANK_RULES)
        self.assertEqual(self.out("rules", "set", rules), "stored 2 rules\n")
        self.assertEqual(self.out("rules", "show"), BANK_RULES)
        self.assertEqual(self.out("rules", "set", "-", stdin='when any then account Expenses:Misc'), "stored 1 rules\n")
        self.assertEqual(self.out("rules", "show"), "when any then account Expenses:Misc\n")
        self.fails("rules", "set", self.write("bad.rules", "when payee ~ [ then flag *\n"))
        self.assertEqual(self.out("rules", "show"), "when any then account Expenses:Misc\n")      # unchanged
        self.assertEqual(self.out("rules", "set", self.write("none.rules", "# nothing\n")), "stored 0 rules\n")

    def test_import_with_a_stored_profile_and_rules(self):
        self.out("profile", "add", "bank", self.profile)
        self.out("rules", "set", self.write("bank.rules", BANK_RULES))
        self.assertEqual(self.out("import", self.csv, "--profile", "bank"), "imported 3 transactions, 0 duplicates\n")
        self.assertEqual(self.out("tx", "list"),
                         "Id  Date        Flag  Payee        Narration  Tags\n"
                         "--  ----------  ----  -----------  ---------  -------\n"
                         " 1  2024-03-01  *     Corner Shop  milk       #coffee\n"
                         " 2  2024-03-02  *     Employer     march pay\n"
                         " 3  2024-03-03  *     Cafe Nero    latte      #coffee\n")
        shown = self.out("tx", "show", "2")
        self.assertIn("Assets:Bank", shown)
        self.assertIn("Income:Pay", shown)
        self.assertIn("Expenses:Food", self.out("tx", "show", "1"))
        # the same statement again: every row is a duplicate, nothing doubles
        self.assertEqual(self.out("import", self.csv, "--profile", "bank"), "imported 0 transactions, 3 duplicates\n")
        self.assertEqual(len(json.loads(self.out("tx", "list", "--json"))), 3)
        more = self.write("april.csv", BANK_CSV + "2024-04-01,Shop,again,-1.00\n")
        self.assertEqual(self.out("import", more, "--profile", "bank"), "imported 1 transactions, 3 duplicates\n")

    def test_import_options(self):
        self.out("rules", "set", self.write("bank.rules", BANK_RULES))
        self.assertEqual(self.out("import", self.csv, "--profile-file", self.profile, "--no-rules"),
                         "imported 3 transactions, 0 duplicates\n")
        self.assertEqual(self.out("export", "--format", "csv").count("Expenses:Misc"), 3)      # no rule was applied
        self.assertEqual(self.out("export", "--format", "csv").count("Expenses:Food"), 0)
        again = self.out("import", "-", "--profile-file", self.profile, stdin=BANK_CSV)
        self.assertEqual(again, "imported 0 transactions, 3 duplicates\n")

    def test_import_mistakes(self):
        self.out("profile", "add", "bank", self.profile)
        bad = self.write("bad.csv", BANK_CSV + "2024-03-04,Shop,x,12.345\n2024-03-05,Shop,x,abc\n2024-03-06,Shop,x,1.00\n")
        err = self.fails("import", bad, "--profile", "bank")
        self.assertIn("row 5: ", err)
        self.assertIn("row 6: ", err)
        self.assertNotIn("row 7", err)
        self.assertEqual(self.out("tx", "list"), "")                              # not even the good rows
        self.fails("import", self.csv, "--profile", "nobody")
        self.fails("import", self.path("missing.csv"), "--profile", "bank")
        self.fails("import", self.csv, "--profile-file", self.path("missing.profile"))
        self.fails("import", self.csv, "--profile-file", self.write("bad.profile", "nonsense\n"))
        self.fails("import", self.csv, status=2)
        self.fails("import", self.csv, "--profile", "bank", "--profile-file", self.profile, status=2)
        self.fails("import", "--profile", "bank", status=2)
        self.out("account", "close", "Expenses:Misc", "--on", "2024-01-01")
        self.fails("import", self.csv, "--profile", "bank")                       # the counter account is closed
        self.assertEqual(self.out("tx", "list"), "")


# ------------------------------------------------------------------------------------------------ rates, budgets, recurring

class M15Planning(CliBase):
    def setUp(self):
        super().setUp()
        self.standard_book()

    def spend(self, day, payee, amount, account="Expenses:Food"):
        self.out("tx", "add", payee, "--date", day, "-p", "%s %s USD" % (account, amount), "-p", "Assets:Cash")

    def test_rates(self):
        self.assertEqual(self.out("rate", "list"), "")
        self.assertEqual(self.out("rate", "set", "USD", "EUR", "0.92", "--on", "2024-03-01"),
                         "set 1 USD = 0.92 EUR on 2024-03-01\n")
        self.assertEqual(self.out("--today", "2024-04-01", "rate", "set", "GBP", "USD", "1.25"),
                         "set 1 GBP = 1.25 USD on 2024-04-01\n")
        self.out("rate", "set", "USD", "EUR", "0.90", "--on", "2024-03-15")
        self.assertEqual(self.out("rate", "list"),
                         "From  To   Date        Rate\n----  ---  ----------  ----\n"
                         "GBP   USD  2024-04-01  1.25\nUSD   EUR  2024-03-01  0.92\nUSD   EUR  2024-03-15  0.90\n")
        self.assertEqual(json.loads(self.out("rate", "list", "--json"))[0],
                         {"from": "GBP", "to": "USD", "date": "2024-04-01", "rate": "1.25"})
        self.out("rate", "set", "USD", "EUR", "0.95", "--on", "2024-03-01")               # replaces that day's rate
        self.assertIn("USD   EUR  2024-03-01  0.95", self.out("rate", "list"))
        self.assertEqual(self.out("rate", "remove", "USD", "EUR", "--on", "2024-03-15"),
                         "removed rate USD -> EUR on 2024-03-15\n")
        self.assertEqual(len(self.out("rate", "list").splitlines()), 4)
        for argv in [["rate", "remove", "USD", "EUR", "--on", "2024-03-15"], ["rate", "set", "USD", "USD", "1"],
                     ["rate", "set", "USD", "EUR", "0"], ["rate", "set", "USD", "EUR", "1.5", "--on", "2024-02-30"]]:
            with self.subTest(argv=argv):
                self.fails(*argv)
        self.fails("rate", "set", "USD", "EUR", status=2)

    def test_budgets(self):
        self.assertEqual(self.out("budget", "list"), "")
        self.assertEqual(self.out("--today", "2024-01-15", "budget", "add", "Expenses:Food", "400.00 USD"),
                         "added budget Expenses:Food 400.00 USD per month\n")
        self.assertEqual(self.out("budget", "add", "Expenses", "9000.00 USD", "--per", "year", "--start", "2024-01-01"),
                         "added budget Expenses 9000.00 USD per year\n")
        self.assertEqual(self.out("budget", "list"),
                         "Pattern        Per         Amount  Start\n"
                         "-------------  -----  -----------  ----------\n"
                         "Expenses       year   9000.00 USD  2024-01-01\n"
                         "Expenses:Food  month   400.00 USD  2024-01-15\n")

    def test_budget_listing_json_and_mistakes(self):
        self.out("budget", "add", "Expenses:Food", "400.00 USD", "--start", "2024-01-15")
        self.out("budget", "add", "Expenses:Food", "1500.00 USD", "--per", "quarter", "--start", "2024-01-01")
        data = json.loads(self.out("budget", "list", "--json"))
        self.assertEqual(data[0], {"pattern": "Expenses:Food", "period_kind": "month",
                                   "amount": {"amount": "400.00", "currency": "USD"}, "start": "2024-01-15"})
        self.assertEqual([b["period_kind"] for b in data], ["month", "quarter"])
        for argv in [["add", "Expenses:Food", "400.00 USD"],                     # one per pattern and kind
                     ["add", "Expenses:Food", "400.00 USD", "--per", "week"], ["add", "Expenses", "0.00 USD"],
                     ["add", "Expenses", "5.00"], ["remove", "Expenses:Food", "--per", "year"],
                     ["status", "--period", "March"]]:
            with self.subTest(argv=argv):
                self.fails("budget", *argv)
        self.assertEqual(self.out("budget", "remove", "Expenses:Food", "--per", "quarter"),
                         "removed budget Expenses:Food per quarter\n")
        self.assertEqual(self.out("budget", "remove", "Expenses:Food"), "removed budget Expenses:Food per month\n")
        self.assertEqual(self.out("budget", "list"), "")

    def test_budget_status(self):
        self.out("budget", "add", "Expenses:Food", "400.00 USD", "--start", "2024-01-01")
        self.out("budget", "add", "Expenses:Fun", "100.00 USD", "--start", "2024-01-01")
        self.spend("2024-03-02", "Shop", "250.00")
        self.spend("2024-03-09", "Cafe", "90.00")
        self.spend("2024-03-10", "Arcade", "130.00", "Expenses:Fun")
        self.spend("2024-04-01", "Shop", "1.00")
        text = self.out("budget", "status", "--period", "2024-03")
        lines = text.splitlines()
        self.assertEqual(lines[0].split(), ["Pattern", "Per", "Budget", "Actual", "Remaining", "Percent", "Over"])
        self.assertEqual(lines[2].split(), ["Expenses:Food", "month", "400.00", "USD", "340.00", "USD", "60.00", "USD",
                                            "85.0%"])
        self.assertEqual(lines[3].split(), ["Expenses:Fun", "month", "100.00", "USD", "130.00", "USD", "-30.00", "USD",
                                            "130.0%", "over"])
        self.assertTrue(all(line == line.rstrip() for line in lines))
        self.assertEqual(text, self.out("--today", "2024-03-20", "budget", "status"))             # default: month of today
        data = json.loads(self.out("budget", "status", "--period", "2024-03", "--json"))
        self.assertEqual(data[0]["pattern"], "Expenses:Food")
        self.assertEqual(data[0]["accounts"], [{"account": "Expenses:Food", "amount": {"amount": "340.00", "currency": "USD"}}])
        self.assertEqual((data[0]["percent"], data[0]["over"], data[1]["over"]), ("85.0", False, True))
        self.assertEqual(self.out("budget", "status", "--period", "2023-12"), "")
        self.assertEqual(self.out("budget", "status", "--period", "2023-12", "--json"), "[]\n")

    def add_rent(self, *extra):
        return self.out("recurring", "add", "rent", "monthly on 1", "Landlord", "--start", "2024-01-01",
                        "--narration", "flat", "--tag", "home", "-p", "Expenses:Rent 900.00 USD",
                        "-p", "Assets:Bank:Checking", *extra)

    def test_recurring_entries(self):
        self.assertEqual(self.out("recurring", "list"), "")
        self.assertEqual(self.add_rent("--count", "5"), "added recurring rent\n")
        self.assertEqual(self.out("recurring", "list"),
                         "Name  Schedule      Start       End  Count  Through  Payee\n"
                         "----  ------------  ----------  ---  -----  -------  --------\n"
                         "rent  monthly on 1  2024-01-01       5               Landlord\n")
        data = json.loads(self.out("recurring", "list", "--json"))
        self.assertEqual(data[0]["schedule"], "monthly on 1")
        self.assertEqual((data[0]["end"], data[0]["count"], data[0]["materialized_through"]), (None, 5, None))
        self.assertEqual(data[0]["template"]["payee"], "Landlord")
        self.assertEqual(data[0]["template"]["tags"], ["home"])
        self.assertEqual(len(data[0]["template"]["postings"]), 2)
        self.assertEqual(self.out("recurring", "materialize", "--upto", "2024-02-15"), "created 2 transactions\n")
        self.assertEqual(self.out("recurring", "materialize", "--upto", "2024-02-15"), "created 0 transactions\n")
        self.assertEqual(self.out("--today", "2024-04-10", "recurring", "materialize"), "created 2 transactions\n")
        listed = json.loads(self.out("tx", "list", "--json"))
        self.assertEqual([t["date"] for t in listed], ["2024-01-01", "2024-02-01", "2024-03-01", "2024-04-01"])
        self.assertEqual(listed[0]["tags"], ["home", "recurring"])
        self.assertEqual(listed[0]["narration"], "flat")
        self.assertEqual(json.loads(self.out("recurring", "list", "--json"))[0]["materialized_through"], "2024-04-10")
        made = json.loads(self.out("recurring", "materialize", "--upto", "2024-12-31", "--json"))
        self.assertEqual([t["date"] for t in made], ["2024-05-01"])                          # the count of 5 stops it
        self.assertEqual(self.out("recurring", "remove", "rent"), "removed recurring rent\n")
        self.assertEqual(self.out("recurring", "list"), "")
        self.assertEqual(len(json.loads(self.out("tx", "list", "--json"))), 5)             # what was made stays

    def test_recurring_mistakes(self):
        self.add_rent()
        for argv in [["rent", "daily", "X", "-p", "Assets:Cash"], ["bad name", "daily", "X"], ["x", "weekly", "X"],
                     ["x", "daily", "X", "--count", "0"], ["x", "daily", "X", "-p", "nonsense words here now"]]:
            with self.subTest(argv=argv):
                self.fails("recurring", "add", *argv)
        self.fails("recurring", "remove", "ghost")
        self.fails("recurring", "materialize", "--upto", "2024-02-30")
        self.fails("recurring", "add", "x", status=2)
        # a template that cannot be booked stops the whole run and moves nothing forward
        self.out("recurring", "add", "bad", "daily", "Oops", "--start", "2024-01-01", "-p", "Expenses:Gone 1.00 USD",
                 "-p", "Assets:Cash -1.00 USD")
        self.fails("recurring", "materialize", "--upto", "2024-01-31")
        self.assertEqual(self.out("tx", "list"), "")


# ------------------------------------------------------------------------------------------------ reports on a book

class M15BookReports(CliBase):
    def setUp(self):
        super().setUp()
        self.book_with_sample()

    def test_the_five_reports(self):
        self.assertEqual(self.out("report", "balance-sheet", "--as-of", "2024-03-31"), BALANCE_SHEET)
        self.assertEqual(self.out("report", "income-statement", "--period", "2024-03"), INCOME_STATEMENT)
        self.assertEqual(self.out("report", "register", "Assets:Bank:Checking", "--period", "2024-03"), REGISTER)
        self.assertEqual(self.out("report", "trial-balance", "--as-of", "2024-03-31"), TRIAL_BALANCE)
        self.assertEqual(self.out("report", "cashflow", "--period", "2024-03"), CASHFLOW)

    def test_the_reports_agree_with_calc(self):
        for argv in [["trial-balance"], ["balance-sheet", "--as-of", "2024-04-30"], ["income-statement", "--period", "2024-Q1"],
                     ["cashflow", "--period", "2024-04"], ["register", "Expenses", "--rollup"],
                     ["register", "Assets:Cash", "--period", "2024-03-01..2024-03-31", "--json"]]:
            with self.subTest(argv=argv):
                self.assertEqual(self.out("report", *argv), self.calc_out("report", *argv, "--journal", self.sample()))

    def test_defaults_come_from_today(self):
        self.assertEqual(self.out("--today", "2024-03-31", "report", "balance-sheet"), BALANCE_SHEET)
        self.assertEqual(self.out("--today", "2024-03-12", "report", "income-statement"), INCOME_STATEMENT)
        self.assertEqual(self.out("--today", "2024-03-31", "report", "cashflow"), CASHFLOW)
        self.assertTrue(self.out("report", "trial-balance").startswith("Trial balance\n"))
        self.assertTrue(self.out("report", "register", "Assets:Cash").startswith("Register Assets:Cash\n"))

    def test_json_and_conversion(self):
        report = json.loads(self.out("report", "balance-sheet", "--as-of", "2024-03-31", "--convert", "EUR", "--json"))
        self.assertEqual(report["currency"], "EUR")
        self.assertEqual(report["assets"]["total"], [{"amount": "3169.86", "currency": "EUR"}])
        text = self.out("report", "income-statement", "--period", "2024-03", "--convert", "EUR")
        self.assertIn("(in EUR)", text.splitlines()[0])
        flat = json.loads(self.out("report", "trial-balance", "--json"))
        self.assertEqual(flat["report"], "trial_balance")
        self.assertEqual(len(flat["accounts"]), 6)

    def test_report_mistakes(self):
        for argv in [["register", "Assets:Nope"], ["balance-sheet", "--convert", "GBP"],
                     ["balance-sheet", "--as-of", "2024-03-31", "--convert", "GBP"], ["income-statement", "--period", "x"],
                     ["trial-balance", "--as-of", "2024-02-30"]]:
            with self.subTest(argv=argv):
                self.fails("report", *argv)
        self.fails("report", "register", status=2)
        self.fails("report", "bogus", status=2)
        self.fails("report", status=2)
        self.fails("report", "trial-balance", "--rollup", status=2)               # not an option of this report


# ------------------------------------------------------------------------------------------------ the web interface

class M15Serve(CliBase):
    def test_serve_announces_and_stops_cleanly(self):
        self.standard_book()
        srv = Server(self.db)
        self.addCleanup(srv.close)
        status, body = srv.get("/health")
        self.assertEqual(status, 200)
        srv.proc.terminate()
        self.assertEqual(srv.proc.wait(timeout=20), 0)

    def test_serve_refuses_what_it_cannot_serve(self):
        self.fails("serve", "--port", "0")                                    # no book
        self.fails("--db", self.db, "serve", "--port", "http", db=False)
        self.fails("--db", self.db, "serve", "--port", "70000", db=False)
        conn = sqlite3.connect(self.db)
        for sql in OLD_V1:
            conn.execute(sql)
        conn.execute("PRAGMA user_version = 1")
        conn.commit()
        conn.close()
        err = self.fails("serve", "--port", "0")
        self.assertIn("db migrate", err)


# ------------------------------------------------------------------------------------------------ the period lock

@phase("post")
class M15PeriodLock(CliBase):
    def setUp(self):
        super().setUp()
        self.standard_book()

    def add(self, day, amount="5.00", payee="X"):
        return self.tb("tx", "add", payee, "--date", day, "-p", "Expenses:Food %s USD" % amount, "-p", "Assets:Cash")

    def test_lock_commands(self):
        self.assertEqual(self.out("lock", "show"), "none\n")
        self.out("lock", "set", "2024-03-31")
        self.assertEqual(self.out("lock", "show"), "2024-03-31\n")
        self.out("lock", "set", "2024-02-01")                                                   # it may be moved
        self.assertEqual(self.out("lock", "show"), "2024-02-01\n")
        self.out("lock", "clear")
        self.assertEqual(self.out("lock", "show"), "none\n")
        self.out("lock", "clear")
        for argv in [["lock", "set", "2024-02-30"], ["lock", "set", "March"]]:
            self.fails(*argv)
        for argv in [["lock"], ["lock", "bogus"], ["lock", "set"], ["lock", "set", "2024-01-01", "2024-01-02"]]:
            self.fails(*argv, status=2)

    def test_a_locked_period_cannot_be_changed(self):
        self.out("tx", "add", "March", "--date", "2024-03-15", "-p", "Expenses:Food 5.00 USD", "-p", "Assets:Cash")
        self.out("lock", "set", "2024-03-31")
        for day in ["2024-03-31", "2024-03-01", "2023-01-01"]:
            with self.subTest(day=day):
                self.refused(self.add(day), 1, "add on a locked day")
        self.assertEqual(self.add("2024-04-01").rc, 0)                           # the day after is open
        self.assertEqual(len(json.loads(self.out("tx", "list", "--json"))), 2)
        self.refused(self.tb("tx", "delete", "1"), 1, "delete in the locked period")
        self.assertEqual(len(json.loads(self.out("tx", "list", "--json"))), 2)
        self.assertEqual(self.out("tx", "delete", "2"), "deleted transaction 2\n")
        self.out("lock", "clear")
        self.assertEqual(self.out("tx", "delete", "1"), "deleted transaction 1\n")
        self.assertEqual(self.add("2024-03-31").rc, 0)

    def test_the_lock_covers_journal_imports_and_statements(self):
        self.out("lock", "set", "2024-03-31")
        text = ("account Expenses:Other\naccount Assets:Wallet\n\n"
                '2024-04-01 * "ok"\n  Expenses:Other  1.00 USD\n  Assets:Wallet\n\n'
                '2024-03-01 * "late"\n  Expenses:Other  1.00 USD\n  Assets:Wallet\n')
        self.refused(self.tb("journal", "import", "-", stdin=text), 1, "journal with a locked transaction")
        self.assertEqual(self.out("tx", "list"), "")
        self.assertNotIn("Expenses:Other", self.out("account", "list"))                  # not even its accounts
        profile = self.write("p.profile", "date_column = Date\npayee_column = Payee\namount_column = Amount\n"
                                          "currency = USD\naccount = Assets:Cash\ndefault_account = Expenses:Food\n")
        rows = self.write("rows.csv", "Date,Payee,Amount\n2024-04-02,Open,-1.00\n2024-03-02,Locked,-1.00\n")
        self.refused(self.tb("import", rows, "--profile-file", profile), 1, "statement with a locked row")
        self.assertEqual(self.out("tx", "list"), "")                              # none of its rows was added
        self.out("lock", "clear")
        self.assertEqual(self.out("import", rows, "--profile-file", profile), "imported 2 transactions, 0 duplicates\n")
        self.assertEqual(self.out("journal", "import", "-", stdin=text), "imported 2 accounts, 0 rates, 2 transactions\n")

    def test_the_lock_covers_recurring_entries(self):
        self.out("recurring", "add", "rent", "monthly on 1", "Landlord", "--start", "2024-01-01",
                 "-p", "Expenses:Rent 900.00 USD", "-p", "Assets:Cash")
        self.out("lock", "set", "2024-02-15")
        self.refused(self.tb("recurring", "materialize", "--upto", "2024-04-01"), 1, "materialize into the lock")
        self.assertEqual(self.out("tx", "list"), "")
        self.out("lock", "clear")
        self.assertEqual(self.out("recurring", "materialize", "--upto", "2024-04-01"), "created 4 transactions\n")

    def test_the_lock_is_kept_in_the_book(self):
        self.out("lock", "set", "2024-06-30")
        self.assertEqual(self.out("lock", "show"), "2024-06-30\n")
        self.assertEqual(self.out("--today", "2025-01-01", "lock", "show"), "2024-06-30\n")
        self.assertEqual(self.out("calc", "money", "parse", "1.00 USD", db=False), "100 USD\n")     # calc never looks


@phase("pre")
class M15NoLockYet(CliBase):
    def test_lock_is_an_unknown_command(self):
        self.init()
        for argv in [["lock", "show"], ["lock", "set", "2024-03-31"], ["lock", "clear"], ["lock"]]:
            with self.subTest(argv=argv):
                self.fails(*argv, status=2)


if __name__ == "__main__":
    unittest.main()

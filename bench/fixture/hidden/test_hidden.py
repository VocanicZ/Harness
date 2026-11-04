"""Hidden acceptance tests for the Pennywise brief.

Black box: the library through `import pennywise`, the CLI through the command line. The grader
(bench/grade.py) exports PENNYWISE_CMD, a JSON argv list that runs the CLI.
"""
import csv
import datetime as dt
import importlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from decimal import Decimal as D

SAMPLE = """\
# household, March
2024-03-01 salary 2500.00 March pay
2024-03-02 groceries -42.50 weekly shop

2024-03-05 Rent -900
2024-03-09 Groceries -18.25
2024-04-01 salary +2500 April   pay
2024-04-03 fun -12.5 cinema\twith  friends
"""

SAMPLE_LIST = [
    "2024-03-01 salary 2500.00 March pay",
    "2024-03-02 groceries -42.50 weekly shop",
    "2024-03-05 rent -900.00",
    "2024-03-09 groceries -18.25",
    "2024-04-01 salary 2500.00 April   pay",
    "2024-04-03 fun -12.50 cinema\twith  friends",
]

SHUFFLED = """\
2024-05-03 b -1 second b
2024-05-01 a -2
2024-05-03 a -3 first a
2024-05-02 c 4
"""


def lib():
    return importlib.import_module("pennywise")


def cli_argv():
    raw = os.environ.get("PENNYWISE_CMD")
    return json.loads(raw) if raw else [sys.executable, "-m", "pennywise"]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pennywise-hidden-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def ledger(self, text=SAMPLE, name="house.txt"):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        return path

    def run_cli(self, *args, stdin=None):
        p = subprocess.run(cli_argv() + list(args), input=stdin, capture_output=True, text=True,
                           encoding="utf-8", cwd=self.tmp, timeout=30)
        return p.returncode, p.stdout, p.stderr

    def ok(self, *args, stdin=None):
        rc, out, err = self.run_cli(*args, stdin=stdin)
        self.assertEqual(rc, 0, "exit %s, stderr: %s" % (rc, err))
        return out


class ParseTests(Base):
    def test_parse_returns_entries_in_file_order(self):
        entries = lib().parse(SAMPLE)
        self.assertEqual([e.note for e in entries],
                         ["March pay", "weekly shop", "", "", "April   pay", "cinema\twith  friends"])
        self.assertEqual([e.date.day for e in entries], [1, 2, 5, 9, 1, 3])

    def test_parse_field_types(self):
        e = lib().parse("2024-03-02 groceries -42.50 weekly shop\n")[0]
        self.assertIsInstance(e.date, dt.date)
        self.assertEqual(e.date, dt.date(2024, 3, 2))
        self.assertIsInstance(e.category, str)
        self.assertIsInstance(e.amount, D)
        self.assertEqual(e.amount, D("-42.50"))
        self.assertIsInstance(e.note, str)

    def test_parse_categories_lowercased(self):
        cats = [e.category for e in lib().parse("2024-01-01 Rent -1\n2024-01-02 RENT -1\n2024-01-03 rent -1\n")]
        self.assertEqual(cats, ["rent", "rent", "rent"])

    def test_parse_amount_spellings(self):
        text = "\n".join("2024-01-01 x %s" % a for a in ["2500", "+2500", "2500.00", "12.5", "-0.99", "-7", "0"])
        self.assertEqual([e.amount for e in lib().parse(text)],
                         [D(2500), D(2500), D(2500), D("12.5"), D("-0.99"), D(-7), D(0)])

    def test_parse_note_is_rest_of_line_trimmed(self):
        e = lib().parse("2024-01-01   x   1   two   words  here   \n")[0]
        self.assertEqual(e.note, "two   words  here")

    def test_parse_tab_separated_fields(self):
        e = lib().parse("2024-01-01\tcoffee\t-3.20\tflat white\n")[0]
        self.assertEqual((e.category, e.amount, e.note), ("coffee", D("-3.20"), "flat white"))

    def test_parse_note_is_empty_string_when_missing(self):
        self.assertEqual(lib().parse("2024-01-01 x 1\n")[0].note, "")

    def test_parse_skips_blank_and_comment_lines(self):
        text = "\n   \n# a comment\n   # indented comment\n2024-01-01 x 1\n\n"
        self.assertEqual(len(lib().parse(text)), 1)

    def test_parse_empty_text(self):
        self.assertEqual(lib().parse(""), [])
        self.assertEqual(lib().parse("# nothing here\n\n"), [])

    def test_parse_without_trailing_newline(self):
        self.assertEqual(len(lib().parse("2024-01-01 x 1\n2024-01-02 y 2")), 2)

    def test_parse_windows_line_endings(self):
        entries = lib().parse("2024-01-01 x 1 hello\r\n2024-01-02 y 2\r\n")
        self.assertEqual([e.note for e in entries], ["hello", ""])

    def assertBad(self, text, line):
        p = lib()
        with self.assertRaises(p.ParseError) as ctx:
            p.parse(text)
        self.assertIsInstance(ctx.exception, ValueError)
        self.assertEqual(ctx.exception.line, line)
        self.assertIn("line %d" % line, str(ctx.exception))

    def test_error_not_enough_fields(self):
        self.assertBad("2024-01-01 x 1\n2024-01-02 y\n", 2)
        self.assertBad("2024-01-01\n", 1)

    def test_error_malformed_date(self):
        self.assertBad("01/02/2024 x 1\n", 1)
        self.assertBad("March-2nd x 1\n", 1)

    def test_error_date_that_does_not_exist(self):
        self.assertBad("2024-02-30 x 1\n", 1)
        self.assertBad("2023-02-29 x 1\n", 1)
        self.assertEqual(len(lib().parse("2024-02-29 x 1\n")), 1)

    def test_error_bad_amounts(self):
        for bad in ["abc", "12.505", "1,000.00", "--5", "$5", "5-"]:
            with self.subTest(amount=bad):
                self.assertBad("2024-01-01 x %s\n" % bad, 1)

    def test_error_line_number_counts_blank_and_comment_lines(self):
        self.assertBad("# header\n\n2024-01-01 x 1\n\n# more\n2024-01-02 y oops\n", 6)

    def test_error_reports_the_first_bad_line(self):
        self.assertBad("2024-01-01 x 1\nbroken\nalso broken\n", 2)


class SummaryTests(Base):
    def test_balance(self):
        p = lib()
        self.assertEqual(p.balance(p.parse(SAMPLE)), D("4026.75"))
        self.assertIsInstance(p.balance(p.parse(SAMPLE)), D)

    def test_balance_of_nothing_is_zero(self):
        self.assertEqual(lib().balance([]), D(0))
        self.assertIsInstance(lib().balance([]), D)

    def test_balance_is_exact(self):
        p = lib()
        self.assertEqual(p.balance(p.parse("2024-01-01 x 0.10\n" * 3)), D("0.30"))

    def test_by_category(self):
        p = lib()
        self.assertEqual(p.by_category(p.parse(SAMPLE)),
                         {"salary": D("5000.00"), "groceries": D("-60.75"), "rent": D(-900), "fun": D("-12.5")})

    def test_by_month(self):
        p = lib()
        self.assertEqual(p.by_month(p.parse(SAMPLE)), {"2024-03": D("1539.25"), "2024-04": D("2487.50")})

    def test_by_category_and_month_of_nothing(self):
        p = lib()
        self.assertEqual(p.by_category([]), {})
        self.assertEqual(p.by_month([]), {})

    def test_by_month_separates_years(self):
        p = lib()
        got = p.by_month(p.parse("2023-12-31 x 1\n2024-12-01 x 2\n2024-12-31 x 3\n"))
        self.assertEqual(got, {"2023-12": D(1), "2024-12": D(5)})


class FilterTests(Base):
    def setUp(self):
        super().setUp()
        self.p = lib()
        self.entries = self.p.parse(SAMPLE)

    def notes(self, entries):
        return [e.note or e.category for e in entries]

    def test_no_filters_returns_everything_in_order(self):
        self.assertEqual(self.p.filter_entries(self.entries), self.entries)

    def test_category_is_case_insensitive(self):
        for spelling in ("groceries", "Groceries", "GROCERIES"):
            got = self.p.filter_entries(self.entries, category=spelling)
            self.assertEqual([e.amount for e in got], [D("-42.50"), D("-18.25")])

    def test_unknown_category_matches_nothing(self):
        self.assertEqual(self.p.filter_entries(self.entries, category="nope"), [])

    def test_since_and_until_include_their_ends(self):
        got = self.p.filter_entries(self.entries, since=dt.date(2024, 3, 2), until=dt.date(2024, 3, 9))
        self.assertEqual([e.date.day for e in got], [2, 5, 9])

    def test_since_alone(self):
        got = self.p.filter_entries(self.entries, since=dt.date(2024, 4, 1))
        self.assertEqual([e.category for e in got], ["salary", "fun"])

    def test_until_alone(self):
        got = self.p.filter_entries(self.entries, until=dt.date(2024, 3, 1))
        self.assertEqual([e.category for e in got], ["salary"])

    def test_filters_combine(self):
        got = self.p.filter_entries(self.entries, category="salary", since=dt.date(2024, 3, 15))
        self.assertEqual([e.date for e in got], [dt.date(2024, 4, 1)])

    def test_order_given_is_kept(self):
        ordered = self.p.parse(SHUFFLED)
        got = self.p.filter_entries(ordered, since=dt.date(2024, 5, 1))
        self.assertEqual([e.category for e in got], ["b", "a", "a", "c"])

    def test_input_list_is_not_modified(self):
        before = list(self.entries)
        self.p.filter_entries(self.entries, category="rent")
        self.assertEqual(self.entries, before)


class CliBalanceTests(Base):
    def test_balance(self):
        self.assertEqual(self.ok("balance", self.ledger()), "4026.75\n")

    def test_balance_has_two_decimals(self):
        self.assertEqual(self.ok("balance", self.ledger("2024-01-01 x 5\n")), "5.00\n")
        self.assertEqual(self.ok("balance", self.ledger("2024-01-01 x -0.5\n")), "-0.50\n")

    def test_balance_of_an_empty_ledger(self):
        self.assertEqual(self.ok("balance", self.ledger("# nothing yet\n")), "0.00\n")

    def test_balance_json(self):
        out = self.ok("balance", self.ledger(), "--json")
        self.assertEqual(json.loads(out), {"balance": "4026.75"})

    def test_balance_from_stdin(self):
        self.assertEqual(self.ok("balance", "-", stdin=SAMPLE), "4026.75\n")


class CliSummaryTests(Base):
    def groups(self, out):
        return [tuple(line.split()) for line in out.splitlines()]

    def test_summary_defaults_to_category(self):
        out = self.ok("summary", self.ledger())
        self.assertEqual(self.groups(out), [("fun", "-12.50"), ("groceries", "-60.75"),
                                            ("rent", "-900.00"), ("salary", "5000.00")])

    def test_summary_by_category_explicit(self):
        self.assertEqual(self.ok("summary", self.ledger(), "--by", "category"),
                         self.ok("summary", self.ledger()))

    def test_summary_by_month(self):
        out = self.ok("summary", self.ledger(), "--by", "month")
        self.assertEqual(self.groups(out), [("2024-03", "1539.25"), ("2024-04", "2487.50")])

    def test_summary_lines_have_name_then_total(self):
        for line in self.ok("summary", self.ledger()).splitlines():
            self.assertRegex(line, r"^\S+\s+-?\d+\.\d\d$")

    def test_summary_json(self):
        out = self.ok("summary", self.ledger(), "--json")
        self.assertEqual(json.loads(out), {"fun": "-12.50", "groceries": "-60.75",
                                           "rent": "-900.00", "salary": "5000.00"})

    def test_summary_json_by_month(self):
        out = self.ok("summary", self.ledger(), "--by", "month", "--json")
        self.assertEqual(json.loads(out), {"2024-03": "1539.25", "2024-04": "2487.50"})

    def test_summary_of_an_empty_ledger(self):
        self.assertEqual(self.ok("summary", self.ledger("")).strip(), "")
        self.assertEqual(json.loads(self.ok("summary", self.ledger(""), "--json")), {})

    def test_summary_rejects_unknown_grouping(self):
        rc, out, _ = self.run_cli("summary", self.ledger(), "--by", "colour")
        self.assertEqual((rc, out), (2, ""))

    def test_summary_from_stdin(self):
        out = self.ok("summary", "-", "--by", "month", stdin=SAMPLE)
        self.assertEqual(self.groups(out), [("2024-03", "1539.25"), ("2024-04", "2487.50")])


class CliListTests(Base):
    def lines(self, *args, stdin=None):
        return self.ok("list", *args, stdin=stdin).splitlines()

    def test_list_everything(self):
        self.assertEqual(self.lines(self.ledger()), SAMPLE_LIST)

    def test_list_oldest_first_and_stable(self):
        got = self.lines(self.ledger(SHUFFLED))
        self.assertEqual(got, ["2024-05-01 a -2.00", "2024-05-02 c 4.00",
                               "2024-05-03 b -1.00 second b", "2024-05-03 a -3.00 first a"])

    def test_list_category_filter_ignores_case(self):
        want = ["2024-03-02 groceries -42.50 weekly shop", "2024-03-09 groceries -18.25"]
        self.assertEqual(self.lines(self.ledger(), "--category", "groceries"), want)
        self.assertEqual(self.lines(self.ledger(), "--category", "GROCERIES"), want)

    def test_list_since_and_until_include_their_ends(self):
        got = self.lines(self.ledger(), "--since", "2024-03-02", "--until", "2024-03-09")
        self.assertEqual(got, SAMPLE_LIST[1:4])

    def test_list_since_alone(self):
        self.assertEqual(self.lines(self.ledger(), "--since", "2024-04-01"), SAMPLE_LIST[4:])

    def test_list_until_alone(self):
        self.assertEqual(self.lines(self.ledger(), "--until", "2024-03-01"), SAMPLE_LIST[:1])

    def test_list_filters_combine(self):
        got = self.lines(self.ledger(), "--category", "salary", "--since", "2024-03-15")
        self.assertEqual(got, [SAMPLE_LIST[4]])

    def test_list_no_match_prints_nothing_and_succeeds(self):
        self.assertEqual(self.ok("list", self.ledger(), "--category", "nope"), "")

    def test_list_omits_note_without_trailing_space(self):
        for line in self.lines(self.ledger()):
            self.assertEqual(line, line.rstrip())

    def test_list_json(self):
        got = json.loads(self.ok("list", self.ledger(), "--json", "--category", "groceries"))
        self.assertEqual(got, [
            {"date": "2024-03-02", "category": "groceries", "amount": "-42.50", "note": "weekly shop"},
            {"date": "2024-03-09", "category": "groceries", "amount": "-18.25", "note": ""},
        ])

    def test_list_json_with_no_match_is_an_empty_array(self):
        self.assertEqual(json.loads(self.ok("list", self.ledger(), "--json", "--category", "nope")), [])

    def test_list_from_stdin(self):
        self.assertEqual(self.lines("-", stdin=SAMPLE), SAMPLE_LIST)

    def test_list_rejects_a_mistyped_date(self):
        for flag in ("--since", "--until"):
            with self.subTest(flag=flag):
                rc, out, _ = self.run_cli("list", self.ledger(), flag, "2024-13-45")
                self.assertEqual((rc, out), (2, ""))
        rc, _, _ = self.run_cli("list", self.ledger(), "--since", "yesterday")
        self.assertEqual(rc, 2)


class CliErrorTests(Base):
    BAD = "2024-01-01 x 1\n# fine\n\n2024-01-02 y oops\n2024-01-03 z 3\n"

    def test_bad_ledger_exits_1_naming_the_line(self):
        for cmd in (["balance"], ["summary"], ["list"], ["export"], ["balance", "--json"]):
            with self.subTest(cmd=cmd):
                rc, out, err = self.run_cli(cmd[0], self.ledger(self.BAD), *cmd[1:])
                self.assertEqual(rc, 1)
                self.assertEqual(out, "")
                self.assertIn("line 4", err)

    def test_bad_ledger_on_stdin(self):
        rc, out, err = self.run_cli("balance", "-", stdin=self.BAD)
        self.assertEqual((rc, out), (1, ""))
        self.assertIn("line 4", err)

    def test_missing_file_exits_2(self):
        for cmd in ("balance", "summary", "list", "export"):
            with self.subTest(cmd=cmd):
                rc, out, err = self.run_cli(cmd, os.path.join(self.tmp, "nope.txt"))
                self.assertEqual((rc, out), (2, ""))
                self.assertTrue(err.strip())

    def test_no_command_exits_2(self):
        rc, _, err = self.run_cli()
        self.assertEqual(rc, 2)
        self.assertTrue(err.strip())

    def test_unknown_command_exits_2(self):
        rc, out, _ = self.run_cli("frobnicate", self.ledger())
        self.assertEqual((rc, out), (2, ""))

    def test_command_without_a_file_exits_2(self):
        for cmd in ("balance", "summary", "list", "export"):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.run_cli(cmd)[0], 2)


class CliAddTests(Base):
    def test_add_appends_and_prints_the_line(self):
        path = self.ledger("2024-01-01 salary 100 pay\n")
        out = self.ok("add", path, "2024-05-01", "coffee", "-3.5", "flat white")
        self.assertEqual(out, "2024-05-01 coffee -3.50 flat white\n")
        with open(path, encoding="utf-8", newline="") as fh:
            self.assertEqual(fh.read(), "2024-01-01 salary 100 pay\n2024-05-01 coffee -3.50 flat white\n")

    def test_add_creates_a_missing_file(self):
        path = os.path.join(self.tmp, "new.txt")
        self.ok("add", path, "2024-05-01", "Coffee", "-3")
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "2024-05-01 coffee -3.00\n")

    def test_add_to_a_file_without_a_trailing_newline(self):
        path = self.ledger("2024-01-01 salary 100")
        self.ok("add", path, "2024-01-02", "x", "1")
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(fh.read().splitlines(), ["2024-01-01 salary 100", "2024-01-02 x 1.00"])

    def test_added_entry_shows_up_everywhere(self):
        path = self.ledger()
        self.ok("add", path, "2024-05-01", "coffee", "-3.50")
        self.assertEqual(self.ok("balance", path), "4023.25\n")
        self.assertEqual(self.ok("list", path, "--category", "coffee"), "2024-05-01 coffee -3.50\n")

    def test_add_without_a_note(self):
        self.assertEqual(self.ok("add", os.path.join(self.tmp, "n.txt"), "2024-05-01", "x", "2"),
                         "2024-05-01 x 2.00\n")

    def test_add_refuses_invalid_entries_and_leaves_the_file_alone(self):
        path = self.ledger("2024-01-01 salary 100 pay\n")
        self.ok("add", os.path.join(self.tmp, "proof.txt"), "2024-01-01", "x", "1")  # the command exists at all
        bad = [("2024-02-30", "x", "1"), ("nope", "x", "1"), ("2024-01-01", "x", "abc"),
               ("2024-01-01", "x", "1.234")]
        for args in bad:
            with self.subTest(args=args):
                rc, out, err = self.run_cli("add", path, *args)
                self.assertEqual((rc, out), (1, ""))
                self.assertTrue(err.strip())
                with open(path, encoding="utf-8") as fh:
                    self.assertEqual(fh.read(), "2024-01-01 salary 100 pay\n")

    def test_add_refused_entry_does_not_create_the_file(self):
        path = os.path.join(self.tmp, "never.txt")
        self.ok("add", os.path.join(self.tmp, "proof.txt"), "2024-01-01", "x", "1")  # the command exists at all
        self.assertEqual(self.run_cli("add", path, "2024-02-30", "x", "1")[0], 1)
        self.assertFalse(os.path.exists(path))


class CliExportTests(Base):
    def rows(self, out):
        return list(csv.reader(io.StringIO(out)))

    def test_export_csv(self):
        rows = self.rows(self.ok("export", self.ledger()))
        self.assertEqual(rows[0], ["date", "category", "amount", "note"])
        self.assertEqual(rows[1], ["2024-03-01", "salary", "2500.00", "March pay"])
        self.assertEqual(rows[3], ["2024-03-05", "rent", "-900.00", ""])
        self.assertEqual(len(rows), 7)

    def test_export_default_format_is_csv(self):
        path = self.ledger()
        self.assertEqual(self.ok("export", path), self.ok("export", path, "--format", "csv"))

    def test_export_is_ordered_like_list(self):
        rows = self.rows(self.ok("export", self.ledger(SHUFFLED)))
        self.assertEqual([r[1] for r in rows[1:]], ["a", "c", "b", "a"])

    def test_export_quotes_awkward_notes(self):
        path = self.ledger('2024-01-01 x 1 hello, "world"\n')
        rows = self.rows(self.ok("export", path))
        self.assertEqual(rows[1][3], 'hello, "world"')

    def test_export_header_only_for_an_empty_ledger(self):
        rows = self.rows(self.ok("export", self.ledger("")))
        self.assertEqual(rows, [["date", "category", "amount", "note"]])

    def test_export_from_stdin(self):
        self.assertEqual(len(self.rows(self.ok("export", "-", stdin=SAMPLE))), 7)

    def test_export_rejects_unknown_format(self):
        rc, out, _ = self.run_cli("export", self.ledger(), "--format", "xml")
        self.assertEqual((rc, out), (2, ""))


if __name__ == "__main__":
    unittest.main()

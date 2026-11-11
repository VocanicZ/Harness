"""Command line, exit statuses, which files a command reads, --dir, file formats, broken pipe."""
import json
import os
import subprocess
import unittest

from common import Base, CATALOG, MOVES, ORDERS, QUOTE_1001, cli_argv, cli_env

NOT_UTF8 = b"AB-100 | caf\xe9 | 1.00 | 1\n"

# every command with arguments that are right for the standard files
ALL_COMMANDS = [
    ("stock",), ("low",), ("history", "AB-100"), ("receive", "2024-03-06", "AB-100", "1"),
    ("ship", "2024-03-06", "AB-100", "1"), ("quote", "SO-1001"), ("fulfil", "SO-1001", "2024-03-05"),
    ("invoice", "SO-1001"), ("report",),
]
NEEDS_MOVEMENTS = [c for c in ALL_COMMANDS if c[0] not in ("quote",)]
NEEDS_ORDERS = [c for c in ALL_COMMANDS if c[0] in ("quote", "fulfil", "invoice", "report")]
SHELVES = [c for c in ALL_COMMANDS if c[0] in ("stock", "low", "history", "receive", "ship")]


class CommandLineTests(Base):
    def seed(self):
        self.files()

    def test_no_command_or_unknown_command(self):
        self.parts(self.part_no_command, self.part_unknown_command)

    def part_no_command(self):
        self.fails(code=2)
        self.fails("--dir", self.tmp, code=2)

    def part_unknown_command(self):
        for cmd in ("frobnicate", "stocks", "list"):
            with self.subTest(cmd=cmd):
                self.fails(cmd, code=2)

    def test_arguments_and_options(self):
        self.parts(self.part_wrong_number_of_arguments, self.part_unknown_options, self.part_options_are_spelled_out_in_full, self.part_options_without_their_value, self.part_bad_option_values)

    def part_wrong_number_of_arguments(self):
        wrong = [("stock", "x"), ("low", "x"), ("history",), ("history", "AB-100", "CD-205"), ("quote",),
                 ("quote", "SO-1001", "SO-1002"), ("invoice",), ("invoice", "SO-1001", "SO-1002"), ("fulfil",),
                 ("fulfil", "SO-1001"), ("fulfil", "SO-1001", "2024-03-05", "x"), ("receive",), ("receive", "2024-03-06"),
                 ("receive", "2024-03-06", "AB-100"), ("receive", "2024-03-06", "AB-100", "1", "note", "more"),
                 ("ship", "2024-03-06", "AB-100"), ("ship", "2024-03-06", "AB-100", "1", "note", "more"), ("report", "x")]
        for argv in wrong:
            with self.subTest(argv=argv):
                self.fails(*argv, code=2)

    def part_unknown_options(self):
        wrong = [("stock", "--bogus"), ("stock", "-x"), ("stock", "--format", "text"), ("low", "--bogus"),
                 ("history", "AB-100", "--nope"), ("quote", "SO-1001", "--nope"), ("invoice", "SO-1001", "-x"),
                 ("report", "--json"), ("report", "--bogus")]
        for argv in wrong:
            with self.subTest(argv=argv):
                self.fails(*argv, code=2)

    def part_options_are_spelled_out_in_full(self):
        for argv in [("stock", "--js"), ("history", "AB-100", "--j"), ("report", "--form", "csv"), ("report", "--f", "csv"),
                     ("stock", "--di", self.tmp), ("stock", "--d", self.tmp)]:
            with self.subTest(argv=argv):
                self.fails(*argv, code=2)

    def part_options_without_their_value(self):
        self.fails("report", "--format", code=2)
        self.fails("stock", "--dir", code=2)

    def part_bad_option_values(self):
        for fmt in ("xml", "yaml"):
            self.fails("report", "--format", fmt, code=2)

    def test_mistyped_dates(self):
        for date in ["2024-02-30", "2024-3-6", "06/03/2024", "yesterday", "20240306", "2024-13-01"]:
            for argv in (("receive", date, "AB-100", "1"), ("ship", date, "AB-100", "1"), ("fulfil", "SO-1001", date)):
                with self.subTest(argv=argv):
                    before = self.read("movements.txt")
                    self.fails(*argv, code=2)
                    self.assertEqual(self.read("movements.txt"), before)

    def test_checked_before_files_are_read(self):
        self.parts(self.part_the_command_line_is_checked_before_any_file_is_read, self.part_bad_movements_do_not_hide_a_command_line_mistake)

    def part_the_command_line_is_checked_before_any_file_is_read(self):
        self.put("catalog.txt", "broken\n")
        self.fails("stock", "extra", code=2)
        self.fails("stock", "--bogus", code=2)
        self.fails("receive", "2024-02-30", "AB-100", "1", code=2)
        self.fails("report", "--format", "xml", code=2)
        self.fails("--dir", os.path.join(self.tmp, "nowhere"), "stock", "extra", code=2)

    def part_bad_movements_do_not_hide_a_command_line_mistake(self):
        self.put("movements.txt", "broken\n")
        self.fails("ship", "2024-02-30", "AB-100", "1", code=2)
        self.fails("history", code=2)

    def test_the_files_are_read_before_the_request_is_carried_out(self):
        os.remove(self.path("catalog.txt"))
        # a missing catalogue (2) is found before an unknown SKU or a bad quantity (1) could be
        self.fails("history", "ZZ-999", code=2)
        self.fails("receive", "2024-03-06", "ZZ-999", "-5", code=2)
        self.fails("quote", "SO-4040", code=2)
        self.put("catalog.txt", "broken\n")
        self.fails("history", "ZZ-999", code=1, mentions=["catalog.txt", "line 1"])
        self.put("catalog.txt", CATALOG)
        self.put("orders.txt", "broken\n")
        self.fails("invoice", "SO-4040", code=1, mentions=["orders.txt", "line 1"])

    def test_arguments_taken_as_typed(self):
        self.parts(self.part_a_dash_led_quantity_is_a_bad_quantity_not_an_option, self.part_receive_ship_and_fulfil_take_no_options_but_dir)

    def part_a_dash_led_quantity_is_a_bad_quantity_not_an_option(self):
        before = self.read("movements.txt")
        self.fails("receive", "2024-03-06", "AB-100", "-5", code=1)
        self.fails("ship", "2024-03-06", "AB-100", "-1", code=1)
        self.assertEqual(self.read("movements.txt"), before)

    def part_receive_ship_and_fulfil_take_no_options_but_dir(self):
        self.fails("fulfil", "SO-1001", "2024-03-05", "--json", code=2)
        self.fails("receive", "2024-03-06", "AB-100", "1", "note", "--json", code=2)
        self.assertEqual(self.ok("receive", "--dir", self.tmp, "2024-03-06", "AB-100", "1", "--json"),
                         "2024-03-06 AB-100 +1 --json\n")


class ExitStatusTests(Base):
    def test_good_runs_and_empty_files(self):
        self.parts(self.part_good_runs_exit_0, self.part_missing_movements_and_orders_are_just_empty)

    def part_good_runs_exit_0(self):
        self.files()
        for argv in ALL_COMMANDS[:3] + [("quote", "SO-1001"), ("report",)]:
            with self.subTest(argv=argv):
                self.assertEqual(self.run_cli(*argv)[0], 0)

    def test_mistakes_in_catalogue_and_movements(self):
        self.parts(self.part_a_mistake_in_the_catalogue_is_exit_1_for_every_command, self.part_a_mistake_in_the_movements_is_exit_1_for_the_commands_that_read_them, self.part_stock_going_below_zero_in_the_movements_names_that_line)

    def part_a_mistake_in_the_catalogue_is_exit_1_for_every_command(self):
        self.files("# header\n\nAB-100 | only two\n", MOVES, ORDERS)
        for argv in ALL_COMMANDS:
            with self.subTest(argv=argv):
                self.fails(*argv, code=1, mentions=["catalog.txt", "line 3"])

    def part_a_mistake_in_the_movements_is_exit_1_for_the_commands_that_read_them(self):
        self.files(CATALOG, "2024-03-01 AB-100 +20\n# x\nbroken line\n", ORDERS)
        for argv in NEEDS_MOVEMENTS:
            with self.subTest(argv=argv):
                self.fails(*argv, code=1, mentions=["movements.txt", "line 3"])

    def part_stock_going_below_zero_in_the_movements_names_that_line(self):
        self.files(CATALOG, "2024-03-01 AB-100 +2\n\n2024-03-02 AB-100 -3\n", ORDERS)
        for argv in (("stock",), ("report",)):
            with self.subTest(argv=argv):
                self.fails(*argv, code=1, mentions=["movements.txt", "line 3"])

    def test_mistakes_in_orders(self):
        self.parts(self.part_a_mistake_in_the_orders_is_exit_1_for_the_commands_that_read_them, self.part_duplicate_order_in_the_file_is_a_mistake)

    def part_a_mistake_in_the_orders_is_exit_1_for_the_commands_that_read_them(self):
        self.files(CATALOG, MOVES, "SO-1 2024-03-03 a AB-100*1\n\nSO-2 2024-03-03 b ZZ-999*1\n")
        for argv in NEEDS_ORDERS:
            with self.subTest(argv=argv):
                self.fails(*argv, code=1, mentions=["orders.txt", "line 3"])

    def part_duplicate_order_in_the_file_is_a_mistake(self):
        self.files(CATALOG, MOVES, ORDERS + "so-1001 2024-03-10 dup AB-100*1\n")
        self.fails("quote", "SO-1002", code=1, mentions=["orders.txt", "line 3"])

    def test_unreadable_is_exit_2(self):
        self.parts(self.part_a_missing_catalogue_is_exit_2_for_every_command, self.part_a_folder_that_does_not_exist_is_exit_2, self.part_bytes_that_are_not_utf8_are_exit_2, self.part_a_catalogue_that_cannot_be_read_as_a_file_is_exit_2)

    def part_a_missing_catalogue_is_exit_2_for_every_command(self):
        self.files(None, MOVES, ORDERS)
        for argv in ALL_COMMANDS:
            with self.subTest(argv=argv):
                self.fails(*argv, code=2)

    def part_a_folder_that_does_not_exist_is_exit_2(self):
        for argv in ALL_COMMANDS:
            with self.subTest(argv=argv):
                self.fails("--dir", os.path.join(self.tmp, "nowhere"), *argv, code=2)

    def part_bytes_that_are_not_utf8_are_exit_2(self):
        self.files(NOT_UTF8, MOVES, ORDERS)
        self.fails("stock", code=2)
        self.files(CATALOG, NOT_UTF8, ORDERS)
        self.fails("stock", code=2)
        self.fails("report", code=2)
        self.files(CATALOG, MOVES, NOT_UTF8)
        self.fails("quote", "SO-1001", code=2)
        self.fails("report", code=2)

    def part_a_catalogue_that_cannot_be_read_as_a_file_is_exit_2(self):
        self.files(None, MOVES, ORDERS)
        os.mkdir(self.path("catalog.txt"))
        self.fails("stock", code=2)

    def part_missing_movements_and_orders_are_just_empty(self):
        self.files(CATALOG, None, None)
        self.assertEqual(self.lines("stock")[0], "AB-100 0 out Garden gnome")
        self.assertEqual(self.ok("history", "AB-100"), "")
        self.assertEqual(self.ok("report"), "")
        self.files(CATALOG, None, ORDERS)
        self.assertEqual(self.lines("quote", "SO-1001"), QUOTE_1001)
        self.fails("invoice", "SO-1001", code=1)

    def test_refusals_are_exit_1_with_nothing_on_stdout(self):
        self.files()
        for argv in [("history", "ZZ-999"), ("quote", "SO-4040"), ("invoice", "SO-4040"), ("invoice", "SO-1002"),
                     ("fulfil", "SO-4040", "2024-03-09"), ("fulfil", "SO-1002", "2024-03-01"),
                     ("receive", "2024-03-06", "ZZ-999", "1"), ("ship", "2024-03-06", "EF-310", "1")]:
            with self.subTest(argv=argv):
                self.fails(*argv, code=1)

    def test_read_only_commands(self):
        self.parts(self.part_commands_that_only_read_leave_the_files_alone, self.part_read_only_commands_do_not_create_files)

    def part_commands_that_only_read_leave_the_files_alone(self):
        self.files()
        before = {n: self.read(n) for n in ("catalog.txt", "movements.txt", "orders.txt")}
        for argv in [("stock",), ("low",), ("history", "AB-100"), ("quote", "SO-1001"), ("invoice", "SO-1001"),
                     ("report",), ("stock", "--json"), ("report", "--format", "csv")]:
            self.ok(*argv)
        self.assertEqual(before, {n: self.read(n) for n in before})

    def part_read_only_commands_do_not_create_files(self):
        self.files(CATALOG, None, None)
        for argv in [("stock",), ("low",), ("history", "AB-100"), ("report",)]:
            self.ok(*argv)
        self.assertEqual(sorted(os.listdir(self.tmp)), ["catalog.txt"])


class FilesNeededTests(Base):
    """A command reads only the files it needs; a mistake in any other file is not its business."""

    def test_the_shelves_commands_do_not_read_the_orders(self):
        for bad in ("garbage in here\nSO-1 2024 x\n", NOT_UTF8, "SO-1 2024-03-03 a ZZ-999*1\n"):
            self.files(CATALOG, MOVES, bad)
            for argv in SHELVES:
                with self.subTest(argv=argv, orders=bad):
                    self.assertEqual(self.run_cli(*argv)[0], 0)

    def part_quote_does_not_read_the_movements(self):
        self.parts(self.part_quote_does_not_read_the_movements, self.part_the_quote_still_works_when_the_movements_are_in_a_state_stock_never_could_be)

    def part_quote_does_not_read_the_movements(self):
        for bad in ("garbage in here\n", NOT_UTF8, "2024-03-01 AB-100 -5\n"):
            self.files(CATALOG, bad, ORDERS)
            with self.subTest(movements=bad):
                self.assertEqual(self.lines("quote", "SO-1001"), QUOTE_1001)
                self.assertEqual(self.js("quote", "SO-1001", "--json")["total"], "177.27")

    def part_the_quote_still_works_when_the_movements_are_in_a_state_stock_never_could_be(self):
        self.files(CATALOG, "2024-03-01 AB-100 +1\n2024-03-02 AB-100 -2\n", ORDERS)
        self.assertEqual(self.lines("quote", "SO-1001"), QUOTE_1001)

    def test_others_read_what_they_need(self):
        self.parts(self.part_fulfil_invoice_and_report_read_all_three_files, self.part_every_command_reads_the_catalogue)

    def part_fulfil_invoice_and_report_read_all_three_files(self):
        three = [("fulfil", "SO-1001", "2024-03-05"), ("invoice", "SO-1001"), ("report",)]
        for catalog, movements, orders, code in [
                (CATALOG, "broken\n", ORDERS, 1), (CATALOG, MOVES, "broken\n", 1),
                (CATALOG, NOT_UTF8, ORDERS, 2), (CATALOG, MOVES, NOT_UTF8, 2), (None, MOVES, ORDERS, 2)]:
            self.files(catalog, movements, orders)
            for argv in three:
                with self.subTest(argv=argv, code=code, movements=movements, orders=orders):
                    self.fails(*argv, code=code)

    def part_every_command_reads_the_catalogue(self):
        self.files("broken\n", None, None)
        for argv in ALL_COMMANDS:
            with self.subTest(argv=argv):
                self.fails(*argv, code=1)


class DirOptionTests(Base):
    def seed(self):
        self.data = os.path.join(self.tmp, "data")
        os.mkdir(self.data)
        self.elsewhere = os.path.join(self.tmp, "elsewhere")
        os.mkdir(self.elsewhere)
        for name, text in (("catalog.txt", CATALOG), ("movements.txt", MOVES), ("orders.txt", ORDERS)):
            with open(os.path.join(self.data, name), "w", encoding="utf-8", newline="") as fh:
                fh.write(text)

    def out(self, *args, cwd=None):
        rc, out, err = self.run_cli(*args, cwd=cwd or self.elsewhere)
        self.assertEqual(rc, 0, err)
        return out

    def test_dir_position(self):
        self.parts(self.part_dir_may_come_before_the_command, self.part_dir_may_come_after_the_command, self.part_dir_may_come_between_the_arguments, self.part_dir_works_with_json)

    def part_dir_may_come_before_the_command(self):
        self.assertEqual(self.out("--dir", self.data, "quote", "SO-1001").splitlines(), QUOTE_1001)

    def part_dir_may_come_after_the_command(self):
        self.assertEqual(self.out("quote", "SO-1001", "--dir", self.data).splitlines(), QUOTE_1001)
        self.assertEqual(self.out("stock", "--dir", self.data).splitlines()[0], "AB-100 17 ok Garden gnome")

    def part_dir_may_come_between_the_arguments(self):
        self.assertEqual(self.out("history", "--dir", self.data, "AB-100").splitlines()[0], "2024-03-01 +20 20 first delivery")
        self.assertEqual(self.out("report", "--dir", self.data, "--format", "csv").splitlines()[0][:5], "order")
        self.assertEqual(json.loads(self.out("report", "--format", "json", "--dir", self.data))[0]["order"], "SO-1001")

    def part_dir_works_with_json(self):
        self.assertEqual(json.loads(self.out("stock", "--json", "--dir", self.data))[0]["sku"], "AB-100")

    def test_default_and_relative(self):
        self.parts(self.part_default_is_the_current_folder, self.part_dir_may_be_relative, self.part_the_current_folder_is_ignored_when_dir_is_given)

    def part_default_is_the_current_folder(self):
        self.assertEqual(self.out("quote", "SO-1001", cwd=self.data).splitlines(), QUOTE_1001)

    def part_dir_may_be_relative(self):
        self.assertEqual(self.out("--dir", "data", "quote", "SO-1001", cwd=self.tmp).splitlines(), QUOTE_1001)
        self.assertEqual(self.out("--dir", os.path.join("..", "data"), "quote", "SO-1001").splitlines(), QUOTE_1001)

    def part_the_current_folder_is_ignored_when_dir_is_given(self):
        with open(os.path.join(self.elsewhere, "catalog.txt"), "w") as fh:
            fh.write("ZZ-999 | Decoy | 1.00 | 1\n")
        self.assertEqual(self.out("stock", "--dir", self.data).splitlines()[0], "AB-100 17 ok Garden gnome")

    def test_writes_go_to_the_dir(self):
        self.parts(self.part_receive_ship_and_fulfil_write_into_the_dir, self.part_ship_into_a_dir_creates_movements_there)

    def part_receive_ship_and_fulfil_write_into_the_dir(self):
        self.out("receive", "--dir", self.data, "2024-03-06", "AB-100", "5", "n")
        self.out("ship", "2024-03-07", "AB-100", "1", "--dir", self.data)
        self.out("fulfil", "SO-1002", "--dir", self.data, "2024-03-09")
        with open(os.path.join(self.data, "movements.txt"), "rb") as fh:
            tail = fh.read()[len(MOVES):]
        self.assertEqual(tail, b"2024-03-06 AB-100 +5 n\n2024-03-07 AB-100 -1\n2024-03-09 AB-100 -2 order SO-1002\n")
        self.assertEqual(os.listdir(self.elsewhere), [])

    def part_ship_into_a_dir_creates_movements_there(self):
        os.remove(os.path.join(self.data, "movements.txt"))
        self.out("receive", "2024-03-06", "AB-100", "5", "--dir", self.data)
        self.assertEqual(os.listdir(self.elsewhere), [])
        self.assertTrue(os.path.exists(os.path.join(self.data, "movements.txt")))

    def test_errors_name_the_file_found_in_dir(self):
        with open(os.path.join(self.data, "orders.txt"), "a") as fh:
            fh.write("nonsense\n")
        rc, out, err = self.run_cli("quote", "SO-1001", "--dir", self.data, cwd=self.elsewhere)
        self.assertEqual((rc, out), (1, ""))
        self.assertIn("orders.txt", err)
        self.assertIn("line 3", err)


class FileFormatTests(Base):
    def test_bom_and_crlf(self):
        self.parts(self.part_byte_order_marks_and_windows_line_endings_in_all_three_files, self.part_a_byte_order_mark_does_not_shift_line_numbers_or_hide_a_mistake_on_line_one, self.part_windows_line_endings_count_lines_the_same)

    def part_byte_order_marks_and_windows_line_endings_in_all_three_files(self):
        bom = b"\xef\xbb\xbf"
        for name, text in (("catalog.txt", CATALOG), ("movements.txt", MOVES), ("orders.txt", ORDERS)):
            self.put(name, bom + text.replace("\n", "\r\n").encode())
        self.assertEqual(self.lines("stock"), ["AB-100 17 ok Garden gnome", "CD-205 40 low Seed packet, mix",
                                               "EF-310 0 out Gift voucher"])
        self.assertEqual(self.lines("history", "AB-100")[1], "2024-03-04 -3 17 order SO-1001")
        self.assertEqual(self.lines("quote", "SO-1001"), QUOTE_1001)
        self.assertEqual(self.lines("fulfil", "SO-1001", "2024-03-05")[-1], "status complete")
        self.assertEqual(self.lines("invoice", "SO-1001")[0], "invoice SO-1001 2024-03-03 acme")

    def part_a_byte_order_mark_does_not_shift_line_numbers_or_hide_a_mistake_on_line_one(self):
        self.put("catalog.txt", b"\xef\xbb\xbfAB-100 | only two\n")
        self.fails("stock", code=1, mentions=["catalog.txt", "line 1"])
        self.put("catalog.txt", b"\xef\xbb\xbf# comment\nAB-100 | a | 1.00 | 1\n")
        self.put("movements.txt", b"\xef\xbb\xbf2024-03-01 AB-100 oops\n")
        self.fails("stock", code=1, mentions=["movements.txt", "line 1"])

    def part_windows_line_endings_count_lines_the_same(self):
        self.put("catalog.txt", "# c\r\n\r\nAB-100 | a | 1.00 | 1\r\nCD-205 | b | oops | 1\r\n")
        self.fails("stock", code=1, mentions=["catalog.txt", "line 4"])

    def test_endings_and_blank_lines(self):
        self.parts(self.part_no_final_newline_in_any_file, self.part_blank_and_comment_lines_with_leading_whitespace_are_ignored_and_counted)

    def part_no_final_newline_in_any_file(self):
        self.files(CATALOG.rstrip("\n"), MOVES.rstrip("\n"), ORDERS.rstrip("\n"))
        self.assertEqual(self.lines("quote", "SO-1002")[0], "SO-1002 2024-03-09 Bea")
        self.assertEqual(self.lines("stock")[0], "AB-100 17 ok Garden gnome")

    def part_blank_and_comment_lines_with_leading_whitespace_are_ignored_and_counted(self):
        self.put("catalog.txt", "  # c\n\t\n   \nAB-100 | a | 1.00 | 1\n  # more\nCD-205 | b | 1.00 | oops\n")
        self.fails("stock", code=1, mentions=["catalog.txt", "line 6"])

    def test_utf8_and_odd_separators(self):
        self.parts(self.part_names_and_customers_may_use_any_utf8, self.part_the_odd_line_separators_do_not_split_lines_in_the_files)

    def part_names_and_customers_may_use_any_utf8(self):
        self.files("AB-100 | Crème brûlée | 3.00 | 1\n", "2024-03-01 AB-100 +5 déjà vu\n",
                   "SO-1 2024-03-02 Zoë AB-100*1\n")
        self.assertEqual(self.lines("quote", "SO-1")[0], "SO-1 2024-03-02 Zoë")
        self.assertEqual(self.js("stock", "--json")[0]["name"], "Crème brûlée")
        self.assertEqual(self.js("history", "AB-100", "--json")[0]["note"], "déjà vu")
        self.assertEqual(self.js("report", "--format", "json")[0]["customer"], "Zoë")

    def part_the_odd_line_separators_do_not_split_lines_in_the_files(self):
        self.files("AB-100 | One Two\x0cThree\x85Four\rFive | 1.00 | 1\nCD-205 | b | oops | 1\n", None, None)
        self.fails("stock", code=1, mentions=["catalog.txt", "line 2"])


class BrokenPipeTests(Base):
    def stop_early(self, *args):
        p = subprocess.Popen(cli_argv() + list(args), cwd=self.tmp, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=cli_env())
        first = p.stdout.readline()
        p.stdout.close()
        err = p.stderr.read()
        p.stderr.close()
        rc = p.wait(timeout=60)
        return rc, first, err

    def test_stock_piped_to_a_reader_that_stops(self):
        rows = ["%s%s-%03d | Item %d | 1.00 | 1" % (a, b, n, n) for a in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                for b in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" for n in range(12)]
        self.files("\n".join(rows) + "\n", None, None)
        rc, first, err = self.stop_early("stock")
        self.assertEqual(first, b"AA-000 0 out Item 0\n")
        self.assertEqual(rc, 0)
        self.assertEqual(err, b"")

    def test_report_piped_to_a_reader_that_stops(self):
        self.files("AB-100 | a | 1.00 | 1\n", None,
                   "".join("SO-%d 2024-03-03 customer AB-100*1\n" % n for n in range(1, 4001)))
        rc, first, err = self.stop_early("report", "--format", "csv")
        self.assertEqual(first, b"order,date,customer,status,ordered,shipped,quoted,invoiced\n")
        self.assertEqual(rc, 0)
        self.assertEqual(err, b"")


if __name__ == "__main__":
    unittest.main()

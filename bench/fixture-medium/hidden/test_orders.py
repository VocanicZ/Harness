"""orders.txt: parse_orders."""
import datetime as dt
import unittest

from common import Base, CATALOG, ORDERS, lib

CAT = "AB-100 | a | 1 | 1\nCD-205 | b | 1 | 1\nEF-310 | c | 1 | 0\n"


class OrderParseTests(Base):
    def parse(self, text, catalog=CAT):
        p = lib()
        return p.parse_orders(text, p.parse_catalog(catalog))

    def test_example_and_types(self):
        self.parts(self.part_example_orders, self.part_field_types, self.part_orders_come_back_in_the_order_of_the_text)

    def part_example_orders(self):
        orders = self.parse(ORDERS, CATALOG)
        self.assertEqual(len(orders), 2)
        a, b = orders
        self.assertEqual((a.id, a.date, a.customer), ("SO-1001", dt.date(2024, 3, 3), "acme"))
        self.assertEqual([tuple(x) for x in a.lines], [("AB-100", 12), ("CD-205", 3)])
        self.assertEqual((b.id, b.date, b.customer), ("SO-1002", dt.date(2024, 3, 9), "Bea"))
        self.assertEqual([tuple(x) for x in b.lines], [("AB-100", 2)])

    def part_field_types(self):
        o = self.parse("SO-1 2024-03-03 acme AB-100*12\n")[0]
        self.assertIsInstance(o.id, str)
        self.assertIsInstance(o.date, dt.date)
        self.assertIsInstance(o.customer, str)
        self.assertIsInstance(o.lines, list)
        self.assertIsInstance(o.lines[0][0], str)
        self.assertIsInstance(o.lines[0][1], int)

    def part_orders_come_back_in_the_order_of_the_text(self):
        orders = self.parse("SO-5 2024-03-09 a AB-100*1\nSO-2 2024-03-01 b AB-100*1\nSO-9 2024-03-05 c AB-100*1\n")
        self.assertEqual([o.id for o in orders], ["SO-5", "SO-2", "SO-9"])

    def test_order_numbers(self):
        self.parts(self.part_order_number_is_shown_in_upper_case, self.part_so_7_and_so_007_are_two_different_orders)

    def part_order_number_is_shown_in_upper_case(self):
        orders = self.parse("so-1 2024-03-03 a AB-100*1\nSo-2 2024-03-03 a AB-100*1\n")
        self.assertEqual([o.id for o in orders], ["SO-1", "SO-2"])

    def part_so_7_and_so_007_are_two_different_orders(self):
        orders = self.parse("SO-7 2024-03-03 a AB-100*1\nSO-007 2024-03-04 b AB-100*2\n")
        self.assertEqual([o.id for o in orders], ["SO-7", "SO-007"])

    def test_customer_and_lines(self):
        self.parts(self.part_customer_is_shown_as_typed, self.part_lines_in_the_order_written_with_upper_case_skus, self.part_large_quantity)

    def part_customer_is_shown_as_typed(self):
        orders = self.parse("SO-1 2024-03-03 BeA AB-100*1\nSO-2 2024-03-03 Zoë_o'Neil-3 AB-100*1\n")
        self.assertEqual([o.customer for o in orders], ["BeA", "Zoë_o'Neil-3"])

    def part_lines_in_the_order_written_with_upper_case_skus(self):
        o = self.parse("SO-1 2024-03-03 a ef-310*7,AB-100*1,Cd-205*30\n")[0]
        self.assertEqual([tuple(x) for x in o.lines], [("EF-310", 7), ("AB-100", 1), ("CD-205", 30)])

    def test_separators_and_ignored_lines(self):
        self.parts(self.part_fields_separated_by_any_spaces_or_tabs, self.part_blank_and_comment_lines_are_ignored, self.part_empty_text, self.part_windows_line_endings_and_no_final_newline)

    def part_fields_separated_by_any_spaces_or_tabs(self):
        o = self.parse("  SO-1 \t 2024-03-03\t\tacme   AB-100*2,CD-205*1 \n")[0]
        self.assertEqual((o.id, o.customer, [tuple(x) for x in o.lines]), ("SO-1", "acme", [("AB-100", 2), ("CD-205", 1)]))

    def part_blank_and_comment_lines_are_ignored(self):
        self.assertEqual(len(self.parse("\n# c\n   # d\n\t\nSO-1 2024-03-03 a AB-100*1\n\n")), 1)

    def part_empty_text(self):
        self.assertEqual(self.parse(""), [])
        self.assertEqual(self.parse("# none yet\n"), [])

    def part_windows_line_endings_and_no_final_newline(self):
        orders = self.parse("SO-1 2024-03-03 a AB-100*1\r\n\r\nSO-2 2024-03-04 b CD-205*2")
        self.assertEqual([(o.id, o.lines[0][0]) for o in orders], [("SO-1", "AB-100"), ("SO-2", "CD-205")])

    def part_large_quantity(self):
        self.assertEqual(self.parse("SO-1 2024-03-03 a AB-100*100000\n")[0].lines[0][1], 100000)


class OrderErrorTests(Base):
    OK = "SO-1 2024-03-03 acme AB-100*2\n"

    def bad(self, text, line, catalog=CAT):
        p = lib()
        self.assertParseError(p.parse_orders, text, p.parse_catalog(catalog), line=line)

    def one(self, row, line=1):
        self.bad(row + "\n", line)

    def test_field_mistakes(self):
        self.parts(self.part_wrong_number_of_fields, self.part_customer_is_one_word, self.part_spaces_inside_the_lines_field_are_a_mistake)

    def part_wrong_number_of_fields(self):
        for row in ["SO-1", "SO-1 2024-03-03", "SO-1 2024-03-03 acme", "SO-1 2024-03-03 acme AB-100*1 extra"]:
            with self.subTest(row=row):
                self.one(row)

    def part_customer_is_one_word(self):
        self.one("SO-1 2024-03-03 acme corp AB-100*1")

    def part_spaces_inside_the_lines_field_are_a_mistake(self):
        self.one("SO-1 2024-03-03 acme AB-100*1, CD-205*2")
        self.one("SO-1 2024-03-03 acme AB-100*1 ,CD-205*2")

    def test_order_number_and_date_mistakes(self):
        self.parts(self.part_bad_order_numbers, self.part_duplicate_order_blames_the_second_line, self.part_bad_dates)

    def part_bad_order_numbers(self):
        for oid in ["SO-", "SO1", "PO-1", "SO-1a", "SO--1", "SO-+1", "1001", "SOS-1", "SO-1.5"]:
            with self.subTest(order=oid):
                self.one("%s 2024-03-03 acme AB-100*1" % oid)

    def part_duplicate_order_blames_the_second_line(self):
        self.bad(self.OK + "SO-2 2024-03-03 b AB-100*1\nSO-1 2024-03-04 c AB-100*1\n", 3)
        self.bad(self.OK + "so-1 2024-03-04 c AB-100*1\n", 2)

    def part_bad_dates(self):
        for d in ["2024-02-30", "2024-13-01", "03/03/2024", "2024-3-3", "yesterday", "20240303"]:
            with self.subTest(date=d):
                self.one("SO-1 %s acme AB-100*1" % d)

    def test_order_line_mistakes(self):
        self.parts(self.part_bad_order_lines, self.part_unknown_sku, self.part_bad_quantities, self.part_a_sku_may_appear_once_per_order)

    def part_bad_order_lines(self):
        for lines in ["AB-100", "AB-100*", "*3", "AB-100*1,", ",AB-100*1", "AB-100*1,,CD-205*1", "AB-100:3", "AB-100*1*2",
                      "AB100*1"]:
            with self.subTest(lines=lines):
                self.one("SO-1 2024-03-03 acme %s" % lines)

    def part_unknown_sku(self):
        self.one("SO-1 2024-03-03 acme ZZ-999*1")
        self.one("SO-1 2024-03-03 acme AB-100*1,ZZ-999*1")

    def part_bad_quantities(self):
        for q in ["0", "-1", "+1", "1.5", "abc", "1e2", "00"]:
            with self.subTest(quantity=q):
                self.one("SO-1 2024-03-03 acme AB-100*%s" % q)

    def part_a_sku_may_appear_once_per_order(self):
        self.one("SO-1 2024-03-03 acme AB-100*1,AB-100*2")
        self.one("SO-1 2024-03-03 acme AB-100*1,CD-205*1,ab-100*2")
        # the same SKU on different orders is fine
        p = lib()
        self.assertEqual(len(p.parse_orders("SO-1 2024-03-03 a AB-100*1\nSO-2 2024-03-03 b AB-100*1\n", p.parse_catalog(CAT))), 2)

    def test_line_numbers(self):
        self.parts(self.part_line_number_counts_blank_and_comment_lines, self.part_line_number_with_windows_line_endings, self.part_odd_characters_do_not_shift_line_numbers, self.part_first_mistake_is_the_one_reported)

    def part_line_number_counts_blank_and_comment_lines(self):
        self.bad("# header\n\n" + self.OK + "\n  # more\nSO-2 2024-03-03 acme AB-100*0\n", 6)

    def part_line_number_with_windows_line_endings(self):
        self.bad("# header\r\n" + self.OK.replace("\n", "\r\n") + "\r\nSO-2 2024-03-03 acme AB-100*0\r\n", 4)

    def part_odd_characters_do_not_shift_line_numbers(self):
        self.bad("SO-1 2024-03-03 a b\x0cc\x85d\re AB-100*1\nSO-2 2024-03-03 acme AB-100*0\n", 2)

    def part_first_mistake_is_the_one_reported(self):
        self.bad(self.OK + "broken\nalso broken\n", 2)


if __name__ == "__main__":
    unittest.main()

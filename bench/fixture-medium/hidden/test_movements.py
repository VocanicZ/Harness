"""movements.txt: parse_movements, the never-below-zero rule, stock_levels."""
import datetime as dt
import unittest

from common import Base, CATALOG, MOVES, lib

CAT2 = "AB-100 | a | 1 | 1\nCD-205 | b | 1 | 1\nEF-310 | c | 1 | 0\n"


class MovementParseTests(Base):
    def parse(self, text, catalog=CATALOG):
        p = lib()
        return p.parse_movements(text, p.parse_catalog(catalog))

    def test_example_and_types(self):
        self.parts(self.part_example_movements, self.part_field_types, self.part_movements_come_back_in_the_order_of_the_text)

    def part_example_movements(self):
        moves = self.parse(MOVES)
        self.assertEqual([(m.date, m.sku, m.quantity, m.note) for m in moves], [
            (dt.date(2024, 3, 1), "AB-100", 20, "first delivery"),
            (dt.date(2024, 3, 4), "AB-100", -3, "order SO-1001"),
            (dt.date(2024, 3, 5), "CD-205", 40, ""),
        ])

    def part_field_types(self):
        m = self.parse("2024-03-01 AB-100 +20 note\n")[0]
        self.assertIsInstance(m.date, dt.date)
        self.assertIsInstance(m.sku, str)
        self.assertIsInstance(m.quantity, int)
        self.assertIsInstance(m.note, str)

    def part_movements_come_back_in_the_order_of_the_text(self):
        moves = self.parse("2024-05-03 AB-100 +5 c\n2024-05-01 AB-100 +5 a\n2024-05-03 AB-100 -1 d\n2024-05-02 CD-205 +1 b\n")
        self.assertEqual([m.note for m in moves], ["c", "a", "d", "b"])

    def test_field_forms(self):
        self.parts(self.part_quantity_spellings, self.part_sku_in_any_case_is_stored_upper, self.part_fields_separated_by_spaces_or_tabs)

    def part_quantity_spellings(self):
        moves = self.parse("".join("2024-03-01 AB-100 %s\n" % q for q in ["+20", "20", "-3", "+1"]))
        self.assertEqual([m.quantity for m in moves], [20, 20, -3, 1])
        self.assertTrue(all(isinstance(m.quantity, int) for m in moves))

    def part_sku_in_any_case_is_stored_upper(self):
        moves = self.parse("2024-03-01 ab-100 +5\n2024-03-01 Cd-205 +5\n")
        self.assertEqual([m.sku for m in moves], ["AB-100", "CD-205"])

    def test_notes(self):
        self.parts(self.part_note_is_the_rest_of_the_line_exactly, self.part_note_is_empty_string_when_missing)

    def part_note_is_the_rest_of_the_line_exactly(self):
        moves = self.parse("2024-03-01   AB-100   +5   two   words \t and | a # bar   \n"
                           "2024-03-01 AB-100 +1 # not a comment\n")
        self.assertEqual(moves[0].note, "two   words \t and | a # bar")
        self.assertEqual(moves[1].note, "# not a comment")

    def part_note_is_empty_string_when_missing(self):
        for text in ["2024-03-01 AB-100 +5\n", "2024-03-01 AB-100 +5   \n", "2024-03-01 AB-100 +5\t"]:
            with self.subTest(text=text):
                self.assertEqual(self.parse(text)[0].note, "")

    def part_fields_separated_by_spaces_or_tabs(self):
        m = self.parse("2024-03-01\tAB-100 \t +5 \t\tdelivery here\n")[0]
        self.assertEqual((m.date, m.sku, m.quantity, m.note), (dt.date(2024, 3, 1), "AB-100", 5, "delivery here"))

    def test_ignored_lines_and_empty_text(self):
        self.parts(self.part_blank_and_comment_lines_are_ignored, self.part_empty_text)

    def part_blank_and_comment_lines_are_ignored(self):
        self.assertEqual(len(self.parse("\n# c\n  # d\n \t\n2024-03-01 AB-100 +5\n\n")), 1)

    def part_empty_text(self):
        self.assertEqual(self.parse(""), [])
        self.assertEqual(self.parse("# nothing\n"), [])

    def test_line_endings(self):
        self.parts(self.part_windows_line_endings, self.part_last_line_without_a_newline, self.part_only_lf_and_crlf_end_a_line)

    def part_windows_line_endings(self):
        moves = self.parse("2024-03-01 AB-100 +5 hello\r\n\r\n2024-03-02 CD-205 +2\r\n")
        self.assertEqual([m.note for m in moves], ["hello", ""])

    def part_last_line_without_a_newline(self):
        self.assertEqual(len(self.parse("2024-03-01 AB-100 +5\n2024-03-02 AB-100 +5")), 2)

    def part_only_lf_and_crlf_end_a_line(self):
        notes = ["a\rb", "a\x0bb", "a\x0cb", "a\x1cb", "a\x85b", "a b", "a b"]
        moves = self.parse("".join("2024-03-01 AB-100 +1 %s\n" % n for n in notes))
        self.assertEqual([m.note for m in moves], notes)


class MovementErrorTests(Base):
    def bad(self, text, line, catalog=CAT2):
        p = lib()
        self.assertParseError(p.parse_movements, text, p.parse_catalog(catalog), line=line)

    OK = "2024-03-01 AB-100 +10\n"

    def test_field_and_date_mistakes(self):
        self.parts(self.part_not_enough_fields, self.part_bad_dates, self.part_leap_day_exists_in_a_leap_year)

    def part_not_enough_fields(self):
        self.bad(self.OK + "2024-03-02 AB-100\n", 2)
        self.bad("2024-03-02\n", 1)
        self.bad("2024-03-02 AB-100  \n", 1)

    def part_bad_dates(self):
        for d in ["01/02/2024", "2024/03/01", "2024-3-1", "20240301", "2024-13-01", "2024-00-10", "2024-03-00",
                  "2024-03-32", "March-2nd", "2024-02-30", "2023-02-29", "2024-04-31", "24-03-01"]:
            with self.subTest(date=d):
                self.bad("%s AB-100 +1\n" % d, 1)

    def part_leap_day_exists_in_a_leap_year(self):
        p = lib()
        self.assertEqual(p.parse_movements("2024-02-29 AB-100 +1\n", p.parse_catalog(CAT2))[0].date, dt.date(2024, 2, 29))

    def test_sku_and_quantity_mistakes(self):
        self.parts(self.part_unknown_or_malformed_sku, self.part_bad_quantities)

    def part_unknown_or_malformed_sku(self):
        for sku in ["ZZ-999", "AB-101", "AB100", "nonsense", "A-100"]:
            with self.subTest(sku=sku):
                self.bad(self.OK + "2024-03-02 %s +1\n" % sku, 2)

    def part_bad_quantities(self):
        for q in ["0", "+0", "-0", "2.5", "abc", "1e3", "--3", "+-3", "1,000", "5x", "+"]:
            with self.subTest(quantity=q):
                self.bad(self.OK + "2024-03-02 AB-100 %s\n" % q, 2)

    def test_line_numbers(self):
        self.parts(self.part_line_number_counts_blank_and_comment_lines, self.part_line_number_with_windows_line_endings, self.part_odd_characters_do_not_shift_line_numbers, self.part_first_mistake_is_the_one_reported)

    def part_line_number_counts_blank_and_comment_lines(self):
        self.bad("# header\n\n" + self.OK + "\n   # more\n2024-03-02 AB-100 oops\n", 6)

    def part_line_number_with_windows_line_endings(self):
        self.bad("# header\r\n2024-03-01 AB-100 +10\r\n\r\n2024-03-02 AB-100 oops\r\n", 4)

    def part_odd_characters_do_not_shift_line_numbers(self):
        self.bad("2024-03-01 AB-100 +10 a b\x0cc\x85d\re\n2024-03-02 AB-100 oops\n", 2)

    def part_first_mistake_is_the_one_reported(self):
        self.bad(self.OK + "broken\nalso broken\n", 2)


class StockRuleTests(Base):
    """The stock of a product may never be below zero at any point of the date order; the line that takes it
    below zero is the mistake."""

    def bad(self, text, line):
        p = lib()
        self.assertParseError(p.parse_movements, text, p.parse_catalog(CAT2), line=line)

    def good(self, text):
        p = lib()
        return p.parse_movements(text, p.parse_catalog(CAT2))

    def test_below_zero_is_blamed(self):
        self.parts(self.part_taking_the_stock_below_zero_blames_that_line, self.part_going_to_exactly_zero_is_fine, self.part_a_shipment_from_nothing_is_a_mistake, self.part_going_below_zero_is_a_mistake_even_if_later_movements_restore_it)

    def part_taking_the_stock_below_zero_blames_that_line(self):
        self.bad("2024-03-01 AB-100 +5\n2024-03-02 AB-100 -6\n", 2)

    def part_going_to_exactly_zero_is_fine(self):
        self.assertEqual(len(self.good("2024-03-01 AB-100 +5\n2024-03-02 AB-100 -5\n")), 2)

    def part_a_shipment_from_nothing_is_a_mistake(self):
        self.bad("# no stock yet\n2024-03-02 AB-100 -1\n", 2)

    def test_date_order(self):
        self.parts(self.part_a_line_earlier_in_the_file_but_later_in_time_is_checked_in_date_order, self.part_the_blamed_line_is_the_one_that_crosses_zero_in_date_order)

    def part_a_line_earlier_in_the_file_but_later_in_time_is_checked_in_date_order(self):
        self.assertEqual(len(self.good("2024-03-05 AB-100 -5\n2024-03-01 AB-100 +5\n")), 2)

    def part_the_blamed_line_is_the_one_that_crosses_zero_in_date_order(self):
        # in date order: +5, -4 (line 3), -3 (line 2) -> line 2 takes it below zero, not the last line of the file
        self.bad("2024-03-01 AB-100 +5\n2024-03-03 AB-100 -3\n2024-03-02 AB-100 -4\n", 2)

    def test_same_day_movements_keep_the_order_of_the_file(self):
        self.bad("2024-03-02 AB-100 -5\n2024-03-02 AB-100 +5\n", 1)
        self.bad("2024-03-01 AB-100 +1\n2024-03-02 AB-100 -5\n2024-03-02 AB-100 +5\n", 2)
        self.assertEqual(len(self.good("2024-03-02 AB-100 +5\n2024-03-02 AB-100 -5\n")), 2)

    def part_going_below_zero_is_a_mistake_even_if_later_movements_restore_it(self):
        self.bad("2024-03-01 AB-100 +3\n2024-03-02 AB-100 -5\n2024-03-03 AB-100 +10\n", 2)

    def test_each_product_is_checked_on_its_own(self):
        self.bad("2024-03-01 AB-100 +5\n2024-03-02 CD-205 -1\n", 2)
        self.assertEqual(len(self.good("2024-03-01 AB-100 +5\n2024-03-01 CD-205 +1\n2024-03-02 CD-205 -1\n")), 3)

    def test_line_numbers_when_blaming(self):
        self.parts(self.part_blank_and_comment_lines_count_when_blaming, self.part_a_syntax_mistake_after_good_stock_movements_is_reported)

    def part_blank_and_comment_lines_count_when_blaming(self):
        self.bad("# stock\n2024-03-01 AB-100 +1\n\n# oops\n2024-03-02 AB-100 -2\n", 5)

    def part_a_syntax_mistake_after_good_stock_movements_is_reported(self):
        self.bad("2024-03-01 AB-100 +1\n2024-03-02 AB-100 -1\n2024-03-03 AB-100 oops\n", 3)


class StockLevelTests(Base):
    def levels(self, movements, catalog=CAT2):
        p = lib()
        cat = p.parse_catalog(catalog)
        return p.stock_levels(cat, p.parse_movements(movements, cat))

    def test_example_and_unmoved_products(self):
        self.parts(self.part_example, self.part_every_product_is_listed_zero_when_it_never_moved)

    def part_example(self):
        p = lib()
        cat = p.parse_catalog(CATALOG)
        self.assertEqual(p.stock_levels(cat, p.parse_movements(MOVES, cat)), {"AB-100": 17, "CD-205": 40, "EF-310": 0})

    def part_every_product_is_listed_zero_when_it_never_moved(self):
        got = self.levels("")
        self.assertEqual(got, {"AB-100": 0, "CD-205": 0, "EF-310": 0})
        self.assertIsInstance(got, dict)

    def test_levels_are_ints_and_sum_every_movement(self):
        got = self.levels("2024-03-05 AB-100 -4\n2024-03-01 AB-100 +10\n2024-03-02 ab-100 +1\n2024-03-02 CD-205 7\n")
        self.assertEqual(got, {"AB-100": 7, "CD-205": 7, "EF-310": 0})
        self.assertTrue(all(type(v) is int for v in got.values()))


if __name__ == "__main__":
    unittest.main()

"""catalog.txt: parse_catalog."""
import unittest
from decimal import Decimal as D

from common import Base, CATALOG, lib


class CatalogParseTests(Base):
    def test_example_and_types(self):
        self.parts(self.part_example_catalog, self.part_result_is_a_dict_keyed_by_sku, self.part_field_types)

    def part_example_catalog(self):
        cat = lib().parse_catalog(CATALOG)
        self.assertEqual(set(cat), {"AB-100", "CD-205", "EF-310"})
        gnome, seeds, voucher = cat["AB-100"], cat["CD-205"], cat["EF-310"]
        self.assertEqual((gnome.sku, gnome.name, gnome.price, gnome.reorder, gnome.tax),
                         ("AB-100", "Garden gnome", D("12.50"), 5, "standard"))
        self.assertEqual((seeds.sku, seeds.name, seeds.price, seeds.reorder, seeds.tax),
                         ("CD-205", "Seed packet, mix", D("1.99"), 40, "reduced"))
        self.assertEqual((voucher.sku, voucher.name, voucher.price, voucher.reorder, voucher.tax),
                         ("EF-310", "Gift voucher", D("25.00"), 0, "standard"))

    def part_result_is_a_dict_keyed_by_sku(self):
        cat = lib().parse_catalog(CATALOG)
        self.assertIsInstance(cat, dict)
        for key, product in cat.items():
            self.assertEqual(key, product.sku)

    def part_field_types(self):
        p = lib().parse_catalog("AB-100 | x | 12.50 | 5 | zero\n")["AB-100"]
        self.assertIsInstance(p.price, D)
        self.assertIsInstance(p.reorder, int)
        self.assertIsInstance(p.name, str)
        self.assertIsInstance(p.tax, str)

    def test_sku_rules(self):
        self.parts(self.part_sku_is_upper_cased, self.part_sku_shapes_accepted)

    def part_sku_is_upper_cased(self):
        cat = lib().parse_catalog("cd-205 | a | 1 | 1\naB-100 | b | 1 | 1\n")
        self.assertEqual(set(cat), {"CD-205", "AB-100"})
        self.assertEqual({p.sku for p in cat.values()}, {"CD-205", "AB-100"})

    def part_sku_shapes_accepted(self):
        cat = lib().parse_catalog("AB-100 | a | 1 | 1\nABC-123 | b | 1 | 1\nABCD-999 | c | 1 | 1\nzz-000 | d | 1 | 1\n")
        self.assertEqual(set(cat), {"AB-100", "ABC-123", "ABCD-999", "ZZ-000"})

    def test_ignored_lines_and_empty_text(self):
        self.parts(self.part_empty_and_comment_only_text, self.part_blank_and_comment_lines_are_ignored)

    def part_empty_and_comment_only_text(self):
        self.assertEqual(lib().parse_catalog(""), {})
        self.assertEqual(lib().parse_catalog("# nothing\n\n   \n  # still nothing\n"), {})

    def part_blank_and_comment_lines_are_ignored(self):
        cat = lib().parse_catalog("\n# c\n   # indented\n\t\nAB-100 | a | 1 | 1\n\n")
        self.assertEqual(list(cat), ["AB-100"])

    def test_field_values(self):
        self.parts(self.part_fields_are_trimmed_including_tabs, self.part_price_spellings, self.part_reorder_zero_and_larger, self.part_name_may_hold_anything_but_the_bar)

    def part_fields_are_trimmed_including_tabs(self):
        p = lib().parse_catalog("  AB-100\t|\t  Garden   gnome \t| 12.50\t|  5 |\treduced \t\n")["AB-100"]
        self.assertEqual((p.name, p.price, p.reorder, p.tax), ("Garden   gnome", D("12.50"), 5, "reduced"))

    def test_tax_classes(self):
        self.parts(self.part_tax_classes_in_any_case, self.part_tax_defaults_to_standard_when_left_out)

    def part_tax_classes_in_any_case(self):
        cat = lib().parse_catalog("AA-001 | a | 1 | 1 | Standard\nAA-002 | b | 1 | 1 | REDUCED\nAA-003 | c | 1 | 1 | zero\n")
        self.assertEqual([cat[k].tax for k in ("AA-001", "AA-002", "AA-003")], ["standard", "reduced", "zero"])

    def part_tax_defaults_to_standard_when_left_out(self):
        self.assertEqual(lib().parse_catalog("AA-001 | a | 1 | 1\n")["AA-001"].tax, "standard")

    def part_price_spellings(self):
        text = "".join("AA-%03d | p | %s | 1\n" % (i, s) for i, s in enumerate(["12", "12.5", "1.99", "0.01", "1000", "0.10"], 1))
        cat = lib().parse_catalog(text)
        self.assertEqual([cat["AA-%03d" % i].price for i in range(1, 7)],
                         [D(12), D("12.5"), D("1.99"), D("0.01"), D(1000), D("0.1")])

    def part_reorder_zero_and_larger(self):
        cat = lib().parse_catalog("AA-001 | a | 1 | 0\nAA-002 | b | 1 | 250\n")
        self.assertEqual((cat["AA-001"].reorder, cat["AA-002"].reorder), (0, 250))

    def part_name_may_hold_anything_but_the_bar(self):
        names = ["Seed packet, mix", "Crème brûlée kit", "Tea # 2 (large) \"best\" 50%", "A  double  space", "x"]
        text = "".join("AA-%03d | %s | 1 | 1\n" % (i, n) for i, n in enumerate(names, 1))
        cat = lib().parse_catalog(text)
        self.assertEqual([cat["AA-%03d" % i].name for i in range(1, 6)], names)

    def test_line_endings(self):
        self.parts(self.part_windows_line_endings, self.part_last_line_without_a_newline, self.part_only_lf_and_crlf_end_a_line)

    def part_windows_line_endings(self):
        cat = lib().parse_catalog("# c\r\nAB-100 | Garden gnome | 12.50 | 5 | reduced\r\n\r\nCD-205 | Seeds | 1.99 | 40\r\n")
        self.assertEqual((cat["AB-100"].name, cat["AB-100"].tax), ("Garden gnome", "reduced"))
        self.assertEqual((cat["CD-205"].reorder, cat["CD-205"].tax), (40, "standard"))

    def part_last_line_without_a_newline(self):
        self.assertEqual(set(lib().parse_catalog("AB-100 | a | 1 | 1\nCD-205 | b | 2 | 2")), {"AB-100", "CD-205"})

    def part_only_lf_and_crlf_end_a_line(self):
        odd = ["a\rb", "a\x0bb", "a\x0cb", "a\x1cb", "a\x85b", "a b", "a b"]
        text = "".join("AA-%03d | %s | 1 | 1\n" % (i, n) for i, n in enumerate(odd, 1))
        cat = lib().parse_catalog(text)
        self.assertEqual([cat["AA-%03d" % i].name for i in range(1, len(odd) + 1)], odd)
        self.assertEqual(len(cat), len(odd))


class CatalogErrorTests(Base):
    def bad(self, text, line):
        self.assertParseError(lib().parse_catalog, text, line=line)

    GOOD = "AB-100 | Garden gnome | 12.50 | 5 | standard\n"

    def one(self, tail, line=1):
        self.bad(tail + "\n", line)

    def test_field_count_and_sku_mistakes(self):
        self.parts(self.part_wrong_number_of_fields, self.part_bad_skus)

    def part_wrong_number_of_fields(self):
        for bad in ["AB-100", "AB-100 | name", "AB-100 | name | 1.00", "AB-100 | n | 1.00 | 1 | zero | extra",
                    "AB-100 | n | 1.00 | 1 | zero | extra | more"]:
            with self.subTest(line=bad):
                self.one(bad)
        self.bad(self.GOOD + "CD-205 | n | 1.00\n", 2)

    def part_bad_skus(self):
        for sku in ["A-100", "ABCDE-100", "AB-10", "AB-1000", "AB100", "AB-10x", "12-345", "AB 100", "AB_100", "-100",
                    "AB-", "", "AB-100x"]:
            with self.subTest(sku=sku):
                self.one("%s | name | 1.00 | 1" % sku)

    def test_duplicate_skus(self):
        self.parts(self.part_duplicate_sku_blames_the_second_line, self.part_duplicate_sku_in_another_case)

    def part_duplicate_sku_blames_the_second_line(self):
        self.bad(self.GOOD + "CD-205 | n | 1 | 1\nAB-100 | other | 2 | 2\n", 3)

    def part_duplicate_sku_in_another_case(self):
        self.bad("ab-100 | a | 1 | 1\nAB-100 | b | 1 | 1\n", 2)
        self.bad("AB-100 | a | 1 | 1\nAb-100 | b | 1 | 1\n", 2)

    def test_name_and_price_mistakes(self):
        self.parts(self.part_empty_name, self.part_bad_prices)

    def part_empty_name(self):
        self.one("AB-100 |  | 1.00 | 5")
        self.one("AB-100 | \t | 1.00 | 5")

    def part_bad_prices(self):
        for price in ["", "0", "0.00", "0.0", "0.001", "12.505", "1,000.00", "-3", "-0.50", "abc", "1.2.3", "1e2", "5p"]:
            with self.subTest(price=price):
                self.one("AB-100 | name | %s | 1" % price)

    def test_reorder_and_tax_mistakes(self):
        self.parts(self.part_bad_reorder_levels, self.part_bad_tax_classes)

    def part_bad_reorder_levels(self):
        for reorder in ["", "-1", "2.5", "abc", "1e2", "five", "1 2"]:
            with self.subTest(reorder=reorder):
                self.one("AB-100 | name | 1.00 | %s" % reorder)

    def part_bad_tax_classes(self):
        for tax in ["exempt", "20%", "std", "5", "standard extra", "none"]:
            with self.subTest(tax=tax):
                self.one("AB-100 | name | 1.00 | 1 | %s" % tax)

    def test_line_numbers(self):
        self.parts(self.part_line_number_counts_blank_and_comment_lines, self.part_line_number_with_windows_line_endings, self.part_odd_characters_do_not_shift_line_numbers)

    def part_line_number_counts_blank_and_comment_lines(self):
        self.bad("# header\n\n   \nAB-100 | a | 1 | 1\n\t# more\n\nCD-205 | b | oops | 1\n", 7)

    def part_line_number_with_windows_line_endings(self):
        self.bad("# header\r\n\r\nAB-100 | a | 1 | 1\r\nCD-205 | b | oops | 1\r\n", 4)

    def part_odd_characters_do_not_shift_line_numbers(self):
        self.bad("AB-100 | one two\x0cthree\x85four\rfive | 1 | 1\nCD-205 | b | oops | 1\n", 2)

    def test_first_mistake_is_reported(self):
        self.parts(self.part_first_mistake_is_the_one_reported, self.part_mistake_on_the_last_line_without_a_newline)

    def part_first_mistake_is_the_one_reported(self):
        self.bad(self.GOOD + "broken\nalso | broken\n", 2)

    def part_mistake_on_the_last_line_without_a_newline(self):
        self.bad(self.GOOD + "CD-205 | b | 0", 2)

    def test_error_carries_line_attribute_and_message(self):
        p = lib()
        with self.assertRaises(p.ParseError) as ctx:
            p.parse_catalog("\n\nXX | y\n")
        self.assertIsInstance(ctx.exception, ValueError)
        self.assertIsInstance(ctx.exception.line, int)
        self.assertEqual(ctx.exception.line, 3)
        self.assertIn("line 3", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()

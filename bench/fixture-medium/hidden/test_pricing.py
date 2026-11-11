"""price_order: volume discounts, the order discount, sharing it out, tax, rounding."""
import unittest
from decimal import Decimal as D

from common import Base, CATALOG, ORDERS, lib


class PriceBase(Base):
    def price(self, *rows):
        """rows: (unit price, quantity, tax class); the quote of one order of those lines (product i is AA-00i)."""
        p = lib()
        catalog = p.parse_catalog("".join("AA-%03d | Item %d | %s | 1 | %s\n" % (i, i, r[0], r[2])
                                          for i, r in enumerate(rows, 1)))
        order = p.parse_orders("SO-1 2024-01-01 cust " + ",".join("AA-%03d*%d" % (i, r[1])
                                                                     for i, r in enumerate(rows, 1)) + "\n", catalog)[0]
        return p.price_order(order, catalog)

    def check(self, quote, lines, subtotal, order_discount, tax, total):
        """lines: (unit, gross, discount, net) as text, one per order line."""
        self.assertEqual(len(quote.lines), len(lines))
        for got, (unit, gross, discount, net) in zip(quote.lines, lines):
            self.assertMoney(got.unit, unit)
            self.assertMoney(got.gross, gross)
            self.assertMoney(got.discount, discount)
            self.assertMoney(got.net, net)
        self.assertMoney(quote.subtotal, subtotal)
        self.assertMoney(quote.order_discount, order_discount)
        self.assertMoney(quote.tax, tax)
        self.assertMoney(quote.total, total)


class QuoteShapeTests(PriceBase):
    def test_quote_shape(self):
        self.parts(self.part_example_order, self.part_quantities_are_ints_and_lines_keep_the_order_written, self.part_every_amount_is_a_two_decimal_decimal)

    def part_example_order(self):
        p = lib()
        cat = p.parse_catalog(CATALOG)
        order = p.parse_orders(ORDERS, cat)[0]
        q = p.price_order(order, cat)
        self.assertEqual([(l.sku, l.quantity) for l in q.lines], [("AB-100", 12), ("CD-205", 3)])
        self.check(q, [("12.50", "150.00", "-7.50", "142.50"), ("1.99", "5.97", "0.00", "5.97")],
                   "148.47", "0.00", "28.80", "177.27")

    def part_quantities_are_ints_and_lines_keep_the_order_written(self):
        q = self.price(("1.00", 3, "zero"), ("2.00", 1, "zero"))
        self.assertEqual([(l.sku, l.quantity) for l in q.lines], [("AA-001", 3), ("AA-002", 1)])
        self.assertTrue(all(isinstance(l.quantity, int) for l in q.lines))

    def part_every_amount_is_a_two_decimal_decimal(self):
        q = self.price(("5", 1, "zero"))
        self.check(q, [("5.00", "5.00", "0.00", "5.00")], "5.00", "0.00", "0.00", "5.00")

    def test_discounts_are_zero_or_negative(self):
        q = self.price(("1.00", 60, "zero"), ("600.00", 1, "zero"))
        for l in q.lines:
            self.assertLessEqual(l.discount, 0)
        self.assertLess(q.lines[0].discount, 0)
        self.assertLess(q.order_discount, 0)


class VolumeDiscountTests(PriceBase):
    def test_tiers_at_the_edges(self):
        self.parts(self.part_nine_units_get_no_discount, self.part_ten_units_get_five_percent, self.part_forty_nine_units_still_get_five_percent, self.part_fifty_units_get_ten_percent_not_both, self.part_a_hundred_units_still_ten_percent)

    def part_nine_units_get_no_discount(self):
        self.check(self.price(("1.00", 9, "zero")), [("1.00", "9.00", "0.00", "9.00")], "9.00", "0.00", "0.00", "9.00")

    def part_ten_units_get_five_percent(self):
        self.check(self.price(("1.00", 10, "zero")), [("1.00", "10.00", "-0.50", "9.50")], "9.50", "0.00", "0.00", "9.50")

    def part_forty_nine_units_still_get_five_percent(self):
        self.check(self.price(("1.00", 49, "zero")), [("1.00", "49.00", "-2.45", "46.55")], "46.55", "0.00", "0.00", "46.55")

    def part_fifty_units_get_ten_percent_not_both(self):
        self.check(self.price(("1.00", 50, "zero")), [("1.00", "50.00", "-5.00", "45.00")], "45.00", "0.00", "0.00", "45.00")

    def part_a_hundred_units_still_ten_percent(self):
        self.check(self.price(("1.00", 100, "zero")), [("1.00", "100.00", "-10.00", "90.00")], "90.00", "0.00", "0.00", "90.00")

    def test_the_tier_depends_on_each_lines_own_quantity(self):
        q = self.price(("2.00", 9, "zero"), ("2.00", 10, "zero"), ("2.00", 50, "zero"))
        self.check(q, [("2.00", "18.00", "0.00", "18.00"), ("2.00", "20.00", "-1.00", "19.00"),
                       ("2.00", "100.00", "-10.00", "90.00")], "127.00", "0.00", "0.00", "127.00")

    def test_halves_round_up(self):
        self.parts(self.part_halves_round_up_in_the_five_percent_tier, self.part_more_halves_round_up_in_the_five_percent_tier)

    def part_halves_round_up_in_the_five_percent_tier(self):
        self.check(self.price(("0.05", 10, "zero")), [("0.05", "0.50", "-0.03", "0.47")], "0.47", "0.00", "0.00", "0.47")
        self.check(self.price(("0.01", 10, "zero")), [("0.01", "0.10", "-0.01", "0.09")], "0.09", "0.00", "0.00", "0.09")

    def part_more_halves_round_up_in_the_five_percent_tier(self):
        # 5.50 * 5% = 0.275 -> 0.28; 4.10 * 5% = 0.205 -> 0.21; 9.90 * 5% = 0.495 -> 0.50
        self.check(self.price(("0.50", 11, "zero")), [("0.50", "5.50", "-0.28", "5.22")], "5.22", "0.00", "0.00", "5.22")
        self.check(self.price(("0.41", 10, "zero")), [("0.41", "4.10", "-0.21", "3.89")], "3.89", "0.00", "0.00", "3.89")
        self.check(self.price(("0.99", 10, "zero")), [("0.99", "9.90", "-0.50", "9.40")], "9.40", "0.00", "0.00", "9.40")


class TaxTests(PriceBase):
    def test_rates_and_totals(self):
        self.parts(self.part_each_class_has_its_rate, self.part_tax_is_charged_on_the_net_after_the_volume_discount, self.part_total_is_subtotal_plus_tax_when_there_is_no_order_discount)

    def part_each_class_has_its_rate(self):
        q = self.price(("10.00", 1, "standard"), ("10.00", 1, "reduced"), ("10.00", 1, "zero"))
        self.check(q, [("10.00", "10.00", "0.00", "10.00")] * 3, "30.00", "0.00", "2.50", "32.50")

    def part_tax_is_charged_on_the_net_after_the_volume_discount(self):
        self.check(self.price(("10.00", 10, "standard")), [("10.00", "100.00", "-5.00", "95.00")],
                   "95.00", "0.00", "19.00", "114.00")

    def test_rounding(self):
        self.parts(self.part_tax_halves_round_up, self.part_tax_below_a_half_penny_rounds_down_and_above_rounds_up)

    def part_tax_halves_round_up(self):
        self.check(self.price(("0.10", 1, "reduced")), [("0.10", "0.10", "0.00", "0.10")], "0.10", "0.00", "0.01", "0.11")
        self.check(self.price(("0.30", 1, "reduced")), [("0.30", "0.30", "0.00", "0.30")], "0.30", "0.00", "0.02", "0.32")
        self.check(self.price(("0.50", 1, "reduced")), [("0.50", "0.50", "0.00", "0.50")], "0.50", "0.00", "0.03", "0.53")

    def part_tax_below_a_half_penny_rounds_down_and_above_rounds_up(self):
        self.check(self.price(("0.03", 1, "standard")), [("0.03", "0.03", "0.00", "0.03")], "0.03", "0.00", "0.01", "0.04")
        self.check(self.price(("0.02", 1, "standard")), [("0.02", "0.02", "0.00", "0.02")], "0.02", "0.00", "0.00", "0.02")

    def test_tax_is_rounded_per_line_then_added_up(self):
        # each line: 5% of 0.30 = 0.015 -> 0.02; together 0.04 (not 0.03 from 5% of 0.60)
        q = self.price(("0.30", 1, "reduced"), ("0.30", 1, "reduced"))
        self.check(q, [("0.30", "0.30", "0.00", "0.30")] * 2, "0.60", "0.00", "0.04", "0.64")

    def part_total_is_subtotal_plus_tax_when_there_is_no_order_discount(self):
        q = self.price(("12.50", 4, "standard"), ("3.20", 3, "reduced"))
        self.check(q, [("12.50", "50.00", "0.00", "50.00"), ("3.20", "9.60", "0.00", "9.60")], "59.60", "0.00", "10.48", "70.08")


class OrderDiscountTests(PriceBase):
    def test_threshold(self):
        self.parts(self.part_just_under_500_gets_no_order_discount, self.part_exactly_500_gets_three_percent)

    def part_just_under_500_gets_no_order_discount(self):
        self.check(self.price(("499.99", 1, "standard")), [("499.99", "499.99", "0.00", "499.99")],
                   "499.99", "0.00", "100.00", "599.99")

    def part_exactly_500_gets_three_percent(self):
        self.check(self.price(("500.00", 1, "standard")), [("500.00", "500.00", "0.00", "500.00")],
                   "500.00", "-15.00", "97.00", "582.00")

    def test_threshold_on_the_subtotal(self):
        self.parts(self.part_the_threshold_looks_at_the_subtotal_after_volume_discounts, self.part_the_threshold_adds_up_all_the_lines)

    def part_the_threshold_looks_at_the_subtotal_after_volume_discounts(self):
        # gross 500.00, net 450.00: no order discount
        self.check(self.price(("10.00", 50, "standard")), [("10.00", "500.00", "-50.00", "450.00")],
                   "450.00", "0.00", "90.00", "540.00")
        # gross 556.00, net 500.40: the order discount applies, 3% of 500.40 = 15.012
        self.check(self.price(("11.12", 50, "standard")), [("11.12", "556.00", "-55.60", "500.40")],
                   "500.40", "-15.01", "97.08", "582.47")

    def part_the_threshold_adds_up_all_the_lines(self):
        q = self.price(("250.00", 1, "zero"), ("249.99", 1, "zero"))
        self.assertMoney(q.order_discount, "0.00")
        q = self.price(("250.00", 1, "zero"), ("250.00", 1, "zero"))
        self.assertMoney(q.order_discount, "-15.00")
        self.assertMoney(q.total, "485.00")

    def test_order_discount_halves_round_up(self):
        # 3% of 501.50 = 15.045 -> 15.05
        self.check(self.price(("501.50", 1, "standard")), [("501.50", "501.50", "0.00", "501.50")],
                   "501.50", "-15.05", "97.29", "583.74")

    def test_effect_on_lines_and_tax(self):
        self.parts(self.part_the_order_discount_does_not_change_the_lines, self.part_tax_is_on_the_amount_left_after_the_order_discount)

    def part_the_order_discount_does_not_change_the_lines(self):
        q = self.price(("300.00", 1, "zero"), ("300.00", 1, "zero"))
        self.check(q, [("300.00", "300.00", "0.00", "300.00")] * 2, "600.00", "-18.00", "0.00", "582.00")

    def part_tax_is_on_the_amount_left_after_the_order_discount(self):
        q = self.price(("600.00", 1, "standard"))
        self.check(q, [("600.00", "600.00", "0.00", "600.00")], "600.00", "-18.00", "116.40", "698.40")

    def test_order_discount_with_volume_discounts_and_all_three_classes(self):
        q = self.price(("12.00", 60, "standard"), ("3.33", 15, "reduced"), ("99.99", 1, "zero"))
        self.check(q, [("12.00", "720.00", "-72.00", "648.00"), ("3.33", "49.95", "-2.50", "47.45"),
                       ("99.99", "99.99", "0.00", "99.99")], "795.44", "-23.86", "128.01", "899.59")


class ShareOutTests(PriceBase):
    """The order discount is shared by net, rounded down, leftover pennies to the biggest lost fractions."""

    def test_ties_go_to_the_earlier_line(self):
        self.parts(self.part_leftover_penny_goes_to_the_earlier_line_on_a_tie, self.part_leftover_penny_goes_to_the_earlier_line_on_a_tie_with_the_classes_swapped)

    def part_leftover_penny_goes_to_the_earlier_line_on_a_tie(self):
        # shares 3.01 / 3.00 / 9.00 of 15.01: the tied first two lines are taxed standard / reduced
        q = self.price(("100.10", 1, "standard"), ("100.10", 1, "reduced"), ("300.00", 1, "zero"))
        self.check(q, [("100.10", "100.10", "0.00", "100.10"), ("100.10", "100.10", "0.00", "100.10"),
                       ("300.00", "300.00", "0.00", "300.00")], "500.20", "-15.01", "24.28", "509.47")

    def part_leftover_penny_goes_to_the_earlier_line_on_a_tie_with_the_classes_swapped(self):
        # shares 3.01 / 3.00 / 9.00: tax 4.86 + 19.42 on the reduced/standard pair
        q = self.price(("100.10", 1, "reduced"), ("100.10", 1, "standard"), ("300.00", 1, "zero"))
        self.assertMoney(q.order_discount, "-15.01")
        self.assertMoney(q.tax, "24.27")
        self.assertMoney(q.total, "509.46")

    def test_two_leftover_pennies_go_to_the_two_earlier_lines_of_three_tied_ones(self):
        # 15.05 over three equal 167.19 lines: 5.02 / 5.02 / 5.01
        q = self.price(("167.19", 1, "standard"), ("167.19", 1, "standard"), ("167.19", 1, "reduced"))
        self.assertMoney(q.subtotal, "501.57")
        self.assertMoney(q.order_discount, "-15.05")
        self.assertMoney(q.tax, "72.97")
        self.assertMoney(q.total, "559.49")

    def test_biggest_lost_fraction(self):
        self.parts(self.part_leftover_goes_by_the_size_of_the_lost_fraction_not_by_position_or_size, self.part_another_share_with_mixed_classes)

    def part_leftover_goes_by_the_size_of_the_lost_fraction_not_by_position_or_size(self):
        q = self.price(("253.99", 1, "standard"), ("211.78", 1, "standard"), ("207.41", 1, "reduced"))
        self.check(q, [("253.99", "253.99", "0.00", "253.99"), ("211.78", "211.78", "0.00", "211.78"),
                       ("207.41", "207.41", "0.00", "207.41")], "673.18", "-20.20", "100.41", "753.39")

    def part_another_share_with_mixed_classes(self):
        q = self.price(("280.47", 1, "reduced"), ("209.87", 1, "standard"), ("93.47", 1, "reduced"))
        self.check(q, [("280.47", "280.47", "0.00", "280.47"), ("209.87", "209.87", "0.00", "209.87"),
                       ("93.47", "93.47", "0.00", "93.47")], "583.81", "-17.51", "58.84", "625.14")

    def test_a_single_line_takes_the_whole_discount(self):
        q = self.price(("501.50", 1, "reduced"))
        self.check(q, [("501.50", "501.50", "0.00", "501.50")], "501.50", "-15.05", "24.32", "510.77")


if __name__ == "__main__":
    unittest.main()

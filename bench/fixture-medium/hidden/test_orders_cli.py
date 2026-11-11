"""The orders commands: quote, fulfil, invoice, report."""
import csv
import io
import json
import unittest

from common import Base, CATALOG, MOVES, ORDERS, QUOTE_1001

BIG_CATALOG = """\
AB-100 | Anvil | 12.00 | 1 | standard
CD-205 | Cushion | 3.33 | 1 | reduced
EF-310 | Ember | 99.99 | 1 | zero
"""
BIG_ORDER = "SO-9 2024-04-01 kim AB-100*60,CD-205*15,EF-310*1\n"
BIG_QUOTE = [
    "SO-9 2024-04-01 kim",
    "AB-100 60 12.00 720.00 -72.00 648.00",
    "CD-205 15 3.33 49.95 -2.50 47.45",
    "EF-310 1 99.99 99.99 0.00 99.99",
    "subtotal 795.44",
    "order discount -23.86",
    "tax 128.01",
    "total 899.59",
]


class QuoteCliTests(Base):
    def test_text(self):
        self.parts(self.part_example, self.part_second_order, self.part_order_number_may_be_typed_in_any_case, self.part_lines_come_in_the_order_written_and_whole_prices_get_two_decimals)

    def part_example(self):
        self.files()
        self.assertEqual(self.lines("quote", "SO-1001"), QUOTE_1001)

    def part_second_order(self):
        self.files()
        self.assertEqual(self.lines("quote", "SO-1002"), [
            "SO-1002 2024-03-09 Bea", "AB-100 2 12.50 25.00 0.00 25.00",
            "subtotal 25.00", "order discount 0.00", "tax 5.00", "total 30.00"])

    def part_order_number_may_be_typed_in_any_case(self):
        self.files()
        self.assertEqual(self.lines("quote", "so-1001"), QUOTE_1001)

    def part_json(self):
        self.parts(self.part_json, self.part_json_option_may_come_first, self.part_json_with_an_order_discount)

    def part_json(self):
        self.files()
        self.assertEqual(self.js("quote", "SO-1001", "--json"), {
            "order": "SO-1001", "date": "2024-03-03", "customer": "acme",
            "lines": [
                {"sku": "AB-100", "quantity": 12, "unit": "12.50", "gross": "150.00", "discount": "-7.50", "net": "142.50"},
                {"sku": "CD-205", "quantity": 3, "unit": "1.99", "gross": "5.97", "discount": "0.00", "net": "5.97"},
            ],
            "subtotal": "148.47", "order_discount": "0.00", "tax": "28.80", "total": "177.27"})

    def part_json_option_may_come_first(self):
        self.files()
        self.assertEqual(self.js("quote", "--json", "SO-1002")["total"], "30.00")

    def test_volume_and_order_discounts_carry_a_minus_sign(self):
        self.files(BIG_CATALOG, None, BIG_ORDER)
        self.assertEqual(self.lines("quote", "SO-9"), BIG_QUOTE)

    def part_json_with_an_order_discount(self):
        self.files(BIG_CATALOG, None, BIG_ORDER)
        got = self.js("quote", "SO-9", "--json")
        self.assertEqual(got["order_discount"], "-23.86")
        self.assertEqual([l["discount"] for l in got["lines"]], ["-72.00", "-2.50", "0.00"])
        self.assertEqual((got["subtotal"], got["tax"], got["total"]), ("795.44", "128.01", "899.59"))

    def part_lines_come_in_the_order_written_and_whole_prices_get_two_decimals(self):
        self.files("AB-100 | a | 12 | 1\nEF-310 | b | 7.5 | 1 | zero\n", None, "SO-5 2024-01-02 Zoe ef-310*2,ab-100*1\n")
        self.assertEqual(self.lines("quote", "SO-5"), [
            "SO-5 2024-01-02 Zoe", "EF-310 2 7.50 15.00 0.00 15.00", "AB-100 1 12.00 12.00 0.00 12.00",
            "subtotal 27.00", "order discount 0.00", "tax 2.40", "total 29.40"])

    def test_order_numbers(self):
        self.parts(self.part_so_7_and_so_007_are_different_orders, self.part_unknown_order_is_refused)

    def part_so_7_and_so_007_are_different_orders(self):
        self.files(CATALOG, None, "SO-7 2024-01-02 a AB-100*1\nSO-007 2024-01-03 b AB-100*2\n")
        self.assertEqual(self.lines("quote", "SO-7")[0], "SO-7 2024-01-02 a")
        self.assertEqual(self.lines("quote", "SO-007")[0], "SO-007 2024-01-03 b")
        self.fails("quote", "SO-0007")

    def part_unknown_order_is_refused(self):
        self.files()
        for order in ("SO-9999", "nonsense", "SO-1"):
            with self.subTest(order=order):
                self.fails("quote", order)

    def test_missing_files(self):
        self.parts(self.part_works_without_a_movements_file, self.part_no_orders_file_means_no_orders)

    def part_works_without_a_movements_file(self):
        self.files(CATALOG, None, ORDERS)
        self.assertEqual(self.lines("quote", "SO-1001"), QUOTE_1001)

    def part_no_orders_file_means_no_orders(self):
        self.files(CATALOG, None, None)
        self.fails("quote", "SO-1001")


class FulfilCliTests(Base):
    def moves(self):
        return self.read("movements.txt")

    def test_partial_then_complete(self):
        self.parts(self.part_ships_what_the_shelves_cover_and_reports_the_rest, self.part_a_second_run_on_the_same_day_changes_nothing, self.part_a_later_run_ships_the_rest_and_completes_the_order, self.part_everything_at_once_is_complete)

    def part_ships_what_the_shelves_cover_and_reports_the_rest(self):
        self.files()
        out = self.lines("fulfil", "SO-1001", "2024-03-04")
        self.assertEqual(out, ["AB-100 shipped 9 backordered 0", "CD-205 shipped 0 backordered 3", "status partial"])
        self.assertEqual(self.moves(), MOVES.encode() + b"2024-03-04 AB-100 -9 order SO-1001\n")

    def part_a_second_run_on_the_same_day_changes_nothing(self):
        self.files()
        self.ok("fulfil", "SO-1001", "2024-03-04")
        after_first = self.moves()
        out = self.lines("fulfil", "SO-1001", "2024-03-04")
        self.assertEqual(out, ["AB-100 shipped 0 backordered 0", "CD-205 shipped 0 backordered 3", "status partial"])
        self.assertEqual(self.moves(), after_first)

    def part_a_later_run_ships_the_rest_and_completes_the_order(self):
        self.files()
        self.ok("fulfil", "SO-1001", "2024-03-04")
        out = self.lines("fulfil", "SO-1001", "2024-03-05")
        self.assertEqual(out, ["AB-100 shipped 0 backordered 0", "CD-205 shipped 3 backordered 0", "status complete"])
        self.assertTrue(self.moves().endswith(b"2024-03-04 AB-100 -9 order SO-1001\n2024-03-05 CD-205 -3 order SO-1001\n"))
        again = self.moves()
        self.assertEqual(self.lines("fulfil", "SO-1001", "2024-03-06"),
                         ["AB-100 shipped 0 backordered 0", "CD-205 shipped 0 backordered 0", "status complete"])
        self.assertEqual(self.moves(), again)

    def part_everything_at_once_is_complete(self):
        self.files()
        out = self.lines("fulfil", "SO-1001", "2024-03-05")
        self.assertEqual(out, ["AB-100 shipped 9 backordered 0", "CD-205 shipped 3 backordered 0", "status complete"])
        self.assertTrue(self.moves().endswith(b"2024-03-05 AB-100 -9 order SO-1001\n2024-03-05 CD-205 -3 order SO-1001\n"))

    def test_open_and_partial_status(self):
        self.parts(self.part_nothing_in_stock_is_open_and_adds_nothing, self.part_open_means_nothing_shipped_on_any_line_so_far, self.part_no_movements_file_means_nothing_in_stock)

    def part_nothing_in_stock_is_open_and_adds_nothing(self):
        self.files(CATALOG, "", ORDERS)
        out = self.lines("fulfil", "SO-1002", "2024-03-09")
        self.assertEqual(out, ["AB-100 shipped 0 backordered 2", "status open"])
        self.assertEqual(self.moves(), b"")

    def part_open_means_nothing_shipped_on_any_line_so_far(self):
        # AB-100 has an earlier shipment, nothing more can ship now: partial, not open
        self.files(CATALOG, "2024-03-01 AB-100 +3\n2024-03-02 AB-100 -3 order SO-1001\n", ORDERS)
        out = self.lines("fulfil", "SO-1001", "2024-03-03")
        self.assertEqual(out, ["AB-100 shipped 0 backordered 9", "CD-205 shipped 0 backordered 3", "status partial"])

    def test_shortage(self):
        self.parts(self.part_a_shortage_ships_what_there_is, self.part_the_stock_after_everything_dated_up_to_the_day_limits_the_shipment)

    def part_a_shortage_ships_what_there_is(self):
        self.files(CATALOG, "2024-03-01 AB-100 +5\n2024-03-01 CD-205 +1\n", ORDERS)
        out = self.lines("fulfil", "so-1001", "2024-03-03")
        self.assertEqual(out, ["AB-100 shipped 5 backordered 7", "CD-205 shipped 1 backordered 2", "status partial"])
        # the order number is written in upper case in the note
        self.assertTrue(self.moves().endswith(b"2024-03-03 AB-100 -5 order SO-1001\n2024-03-03 CD-205 -1 order SO-1001\n"))

    def test_earlier_shipments_by_note(self):
        self.parts(self.part_earlier_shipments_of_the_order_are_counted_by_their_note, self.part_other_notes_do_not_count_as_shipments_of_the_order, self.part_a_note_with_trailing_spaces_in_the_file_still_counts, self.part_so_7_and_so_007_do_not_share_shipments, self.part_shipments_beyond_the_quantity_ordered_count_only_up_to_it)

    def part_earlier_shipments_of_the_order_are_counted_by_their_note(self):
        moves = "2024-03-01 AB-100 +20\n2024-03-02 AB-100 -2 order SO-1001\n2024-03-02 AB-100 -3 order SO-1001\n"
        self.files(CATALOG, moves, ORDERS)
        out = self.lines("fulfil", "SO-1001", "2024-03-03")
        self.assertEqual(out[0], "AB-100 shipped 7 backordered 0")

    def part_other_notes_do_not_count_as_shipments_of_the_order(self):
        moves = ("2024-03-01 AB-100 +40\n2024-03-02 AB-100 -1 order so-1001\n2024-03-02 AB-100 -1 Order SO-1001\n"
                 "2024-03-02 AB-100 -1 order SO-1001 again\n2024-03-02 AB-100 -1 for order SO-1001\n"
                 "2024-03-02 AB-100 -1 order SO-1002\n2024-03-02 AB-100 -1 order SO-01001\n2024-03-02 AB-100 -1\n"
                 "2024-03-02 AB-100 +5 order SO-1001\n")
        self.files(CATALOG, moves, ORDERS)
        out = self.lines("fulfil", "SO-1001", "2024-03-03")
        self.assertEqual(out[0], "AB-100 shipped 12 backordered 0")

    def part_a_note_with_trailing_spaces_in_the_file_still_counts(self):
        self.files(CATALOG, "2024-03-01 AB-100 +20\n2024-03-02 AB-100 -4 order SO-1001   \n", ORDERS)
        self.assertEqual(self.lines("fulfil", "SO-1001", "2024-03-03")[0], "AB-100 shipped 8 backordered 0")

    def part_so_7_and_so_007_do_not_share_shipments(self):
        self.files(CATALOG, "2024-03-01 AB-100 +20\n2024-03-02 AB-100 -4 order SO-007\n",
                   "SO-7 2024-03-01 a AB-100*10\nSO-007 2024-03-01 b AB-100*10\n")
        self.assertEqual(self.lines("fulfil", "SO-7", "2024-03-03")[0], "AB-100 shipped 10 backordered 0")
        self.assertEqual(self.lines("fulfil", "SO-007", "2024-03-03")[0], "AB-100 shipped 6 backordered 0")

    def part_shipments_beyond_the_quantity_ordered_count_only_up_to_it(self):
        self.files(CATALOG, "2024-03-01 AB-100 +50\n2024-03-02 AB-100 -15 order SO-1001\n", ORDERS)
        self.assertEqual(self.lines("fulfil", "SO-1001", "2024-03-03")[0], "AB-100 shipped 0 backordered 0")

    def part_the_stock_after_everything_dated_up_to_the_day_limits_the_shipment(self):
        # CD-205 only arrives on 03-05
        self.files()
        self.assertEqual(self.lines("fulfil", "SO-1001", "2024-03-04")[1], "CD-205 shipped 0 backordered 3")

    def test_later_movements_limit_the_shipment(self):
        moves = "2024-03-01 AB-100 +10\n2024-03-10 AB-100 -8 other order\n2024-03-12 AB-100 +100\n"
        self.files(CATALOG, moves, "SO-1 2024-03-01 acme AB-100*10\n")
        out = self.lines("fulfil", "SO-1", "2024-03-05")
        self.assertEqual(out, ["AB-100 shipped 2 backordered 8", "status partial"])
        self.assertEqual(self.moves(), moves.encode() + b"2024-03-05 AB-100 -2 order SO-1\n")
        # the file is still valid: the stock stays at or above zero
        self.assertEqual(self.lines("stock")[0], "AB-100 100 ok Garden gnome")
        out = self.lines("fulfil", "SO-1", "2024-03-12")
        self.assertEqual(out, ["AB-100 shipped 8 backordered 0", "status complete"])

    def test_later_dips_and_same_day(self):
        self.parts(self.part_a_later_dip_below_the_stock_today_is_the_limit_even_if_stock_recovers, self.part_movements_on_the_day_itself_all_count)

    def part_a_later_dip_below_the_stock_today_is_the_limit_even_if_stock_recovers(self):
        moves = "2024-03-01 AB-100 +4\n2024-03-05 AB-100 -4 x\n2024-03-05 AB-100 +6 y\n"
        self.files(CATALOG, moves, "SO-1 2024-03-01 acme AB-100*10\n")
        # on 03-04 the stock is 4, but it hits 0 on 03-05: nothing can ship
        self.assertEqual(self.lines("fulfil", "SO-1", "2024-03-04"), ["AB-100 shipped 0 backordered 10", "status open"])
        self.assertEqual(self.moves(), moves.encode())

    def part_movements_on_the_day_itself_all_count(self):
        moves = "2024-03-01 AB-100 +4\n2024-03-05 AB-100 -4 x\n2024-03-05 AB-100 +6 y\n"
        self.files(CATALOG, moves, "SO-1 2024-03-01 acme AB-100*10\n")
        self.assertEqual(self.lines("fulfil", "SO-1", "2024-03-05"), ["AB-100 shipped 6 backordered 4", "status partial"])
        self.assertEqual(self.moves(), moves.encode() + b"2024-03-05 AB-100 -6 order SO-1\n")

    def test_date_against_the_order_date(self):
        self.parts(self.part_a_date_before_the_order_date_is_refused, self.part_the_order_date_itself_is_fine)

    def part_a_date_before_the_order_date_is_refused(self):
        self.files()
        before = self.moves()
        self.fails("fulfil", "SO-1002", "2024-03-08")
        self.assertEqual(self.moves(), before)

    def part_the_order_date_itself_is_fine(self):
        self.files(CATALOG, "2024-03-01 AB-100 +5\n", ORDERS)
        self.assertEqual(self.lines("fulfil", "SO-1002", "2024-03-09"), ["AB-100 shipped 2 backordered 0", "status complete"])

    def test_unknown_order_is_refused(self):
        self.files()
        before = self.moves()
        self.fails("fulfil", "SO-4040", "2024-03-09")
        self.assertEqual(self.moves(), before)

    def part_no_movements_file_means_nothing_in_stock(self):
        self.files(CATALOG, None, "SO-1 2024-03-01 a AB-100*1\n")
        self.assertEqual(self.lines("fulfil", "SO-1", "2024-03-01"), ["AB-100 shipped 0 backordered 1", "status open"])

    def test_file_handling(self):
        self.parts(self.part_missing_final_newline_gets_one_before_the_shipment, self.part_shipped_stock_shows_in_stock_and_history)

    def part_missing_final_newline_gets_one_before_the_shipment(self):
        self.files(CATALOG, "2024-03-01 AB-100 +20", ORDERS)
        self.ok("fulfil", "SO-1002", "2024-03-09")
        self.assertEqual(self.moves(), b"2024-03-01 AB-100 +20\n2024-03-09 AB-100 -2 order SO-1002\n")

    def part_shipped_stock_shows_in_stock_and_history(self):
        self.files()
        self.ok("fulfil", "SO-1001", "2024-03-05")
        self.assertEqual(self.lines("stock")[0], "AB-100 8 ok Garden gnome")
        self.assertEqual(self.lines("history", "AB-100")[-1], "2024-03-05 -9 8 order SO-1001")


class InvoiceCliTests(Base):
    def test_partial_and_full(self):
        self.parts(self.part_partial_shipment_is_invoiced_on_what_shipped, self.part_fully_shipped_order_invoices_like_the_quote, self.part_order_number_in_any_case)

    def part_partial_shipment_is_invoiced_on_what_shipped(self):
        self.files()
        # 3 of the 12 gnomes shipped on 03-04: no volume discount at 3 units, nothing for the seed packets
        self.assertEqual(self.lines("invoice", "SO-1001"), [
            "invoice SO-1001 2024-03-03 acme", "AB-100 3 12.50 37.50 0.00 37.50",
            "subtotal 37.50", "order discount 0.00", "tax 7.50", "total 45.00"])

    def part_fully_shipped_order_invoices_like_the_quote(self):
        self.files()
        self.ok("fulfil", "SO-1001", "2024-03-05")
        self.assertEqual(self.lines("invoice", "SO-1001"), ["invoice " + QUOTE_1001[0]] + QUOTE_1001[1:])

    def part_order_number_in_any_case(self):
        self.files()
        self.assertEqual(self.lines("invoice", "so-1001")[0], "invoice SO-1001 2024-03-03 acme")

    def test_json(self):
        self.files()
        self.assertEqual(self.js("invoice", "SO-1001", "--json"), {
            "order": "SO-1001", "date": "2024-03-03", "customer": "acme",
            "lines": [{"sku": "AB-100", "quantity": 3, "unit": "12.50", "gross": "37.50", "discount": "0.00", "net": "37.50"}],
            "subtotal": "37.50", "order_discount": "0.00", "tax": "7.50", "total": "45.00"})

    def test_follows_what_shipped(self):
        self.parts(self.part_volume_discount_follows_the_quantity_shipped, self.part_order_discount_follows_the_amount_shipped)

    def part_volume_discount_follows_the_quantity_shipped(self):
        # 50 ordered, 49 in stock: 49 get the 5% tier, not the 10% one
        self.files("AB-100 | a | 1.00 | 1\n", "2024-03-01 AB-100 +49\n", "SO-1 2024-03-01 a AB-100*50\n")
        self.ok("fulfil", "SO-1", "2024-03-01")
        self.assertEqual(self.lines("invoice", "SO-1"), [
            "invoice SO-1 2024-03-01 a", "AB-100 49 1.00 49.00 -2.45 46.55",
            "subtotal 46.55", "order discount 0.00", "tax 9.31", "total 55.86"])

    def part_order_discount_follows_the_amount_shipped(self):
        self.files("ZZ-100 | a | 300.00 | 1\n", "2024-03-01 ZZ-100 +1\n", "SO-1 2024-03-01 a ZZ-100*2\n")
        self.assertEqual(self.lines("quote", "SO-1")[-4:], ["subtotal 600.00", "order discount -18.00", "tax 116.40", "total 698.40"])
        self.ok("fulfil", "SO-1", "2024-03-01")
        self.assertEqual(self.lines("invoice", "SO-1")[-4:], ["subtotal 300.00", "order discount 0.00", "tax 60.00", "total 360.00"])

    def test_which_lines(self):
        self.parts(self.part_lines_with_nothing_shipped_are_left_out_and_the_rest_keep_their_order, self.part_shipments_beyond_the_quantity_ordered_are_capped, self.part_only_shipments_of_that_order_and_of_its_own_products_count)

    def part_lines_with_nothing_shipped_are_left_out_and_the_rest_keep_their_order(self):
        self.files(CATALOG, "2024-03-01 CD-205 +9\n2024-03-01 AB-100 +1\n",
                   "SO-1 2024-03-01 a AB-100*1,EF-310*2,CD-205*4\n")
        self.ok("fulfil", "SO-1", "2024-03-01")
        got = self.lines("invoice", "SO-1")
        self.assertEqual([l.split()[0] for l in got[1:3]], ["AB-100", "CD-205"])
        self.assertEqual(len(got), 7)

    def part_shipments_beyond_the_quantity_ordered_are_capped(self):
        self.files(CATALOG, "2024-03-01 AB-100 +50\n2024-03-02 AB-100 -15 order SO-1002\n", ORDERS)
        self.assertEqual(self.lines("invoice", "SO-1002")[1], "AB-100 2 12.50 25.00 0.00 25.00")

    def part_only_shipments_of_that_order_and_of_its_own_products_count(self):
        moves = ("2024-03-01 AB-100 +50\n2024-03-01 EF-310 +5\n2024-03-02 AB-100 -4 order SO-1001\n"
                 "2024-03-02 EF-310 -1 order SO-1001\n2024-03-02 AB-100 -2 order SO-1002\n"
                 "2024-03-02 AB-100 +7 order SO-1001\n2024-03-02 AB-100 -1 order so-1001\n")
        self.files(CATALOG, moves, ORDERS)
        self.assertEqual(self.lines("invoice", "SO-1001")[1:-4], ["AB-100 4 12.50 50.00 0.00 50.00"])
        self.assertEqual(self.lines("invoice", "SO-1002")[1:-4], ["AB-100 2 12.50 25.00 0.00 25.00"])

    def test_refused(self):
        self.parts(self.part_nothing_shipped_is_refused, self.part_notes_that_are_not_exactly_the_order_do_not_count_as_shipments, self.part_unknown_order_is_refused)

    def part_nothing_shipped_is_refused(self):
        self.files(CATALOG, "2024-03-01 AB-100 +20\n", ORDERS)
        self.fails("invoice", "SO-1001")
        self.fails("invoice", "SO-1001", "--json")

    def part_notes_that_are_not_exactly_the_order_do_not_count_as_shipments(self):
        moves = "2024-03-01 AB-100 +20\n2024-03-02 AB-100 -4 order so-1001\n2024-03-02 AB-100 -4 order SO-1001 x\n"
        self.files(CATALOG, moves, ORDERS)
        self.fails("invoice", "SO-1001")

    def part_unknown_order_is_refused(self):
        self.files()
        self.fails("invoice", "SO-4040")


REPORT_ORDERS = """\
SO-1002 2024-03-09 Bea ab-100*2
SO-1001 2024-03-03 acme AB-100*12,CD-205*3
SO-1003 2024-03-03 zed EF-310*1
"""


class ReportCliTests(Base):
    TEXT = [
        "SO-1001 2024-03-03 acme partial 3/15 177.27 45.00",
        "SO-1003 2024-03-03 zed open 0/1 30.00 0.00",
        "SO-1002 2024-03-09 Bea open 0/2 30.00 0.00",
    ]
    ROWS = [
        {"order": "SO-1001", "date": "2024-03-03", "customer": "acme", "status": "partial", "ordered": 15, "shipped": 3,
         "quoted": "177.27", "invoiced": "45.00"},
        {"order": "SO-1003", "date": "2024-03-03", "customer": "zed", "status": "open", "ordered": 1, "shipped": 0,
         "quoted": "30.00", "invoiced": "0.00"},
        {"order": "SO-1002", "date": "2024-03-09", "customer": "Bea", "status": "open", "ordered": 2, "shipped": 0,
         "quoted": "30.00", "invoiced": "0.00"},
    ]

    def seed(self):
        self.files(CATALOG, MOVES, REPORT_ORDERS)

    def test_text(self):
        self.parts(self.part_text_is_the_default_one_row_per_order_by_date_then_number, self.part_text_explicit)

    def part_text_is_the_default_one_row_per_order_by_date_then_number(self):
        self.assertEqual(self.lines("report"), self.TEXT)

    def part_text_explicit(self):
        self.assertEqual(self.lines("report", "--format", "text"), self.TEXT)

    def test_csv(self):
        out = self.ok("report", "--format", "csv")
        rows = list(csv.reader(io.StringIO(out)))
        self.assertEqual(rows[0], ["order", "date", "customer", "status", "ordered", "shipped", "quoted", "invoiced"])
        self.assertEqual(rows[1:], [[r[k] if isinstance(r[k], str) else str(r[k]) for k in rows[0]] for r in self.ROWS])
        self.assertEqual(out.splitlines()[0], "order,date,customer,status,ordered,shipped,quoted,invoiced")
        self.assertEqual(out.splitlines()[1], "SO-1001,2024-03-03,acme,partial,15,3,177.27,45.00")

    def part_json(self):
        self.parts(self.part_json, self.part_json_types)

    def part_json(self):
        self.assertEqual(self.js("report", "--format", "json"), self.ROWS)

    def part_json_types(self):
        for row in self.js("report", "--format", "json"):
            self.assertEqual(set(row), set(self.ROWS[0]))
            self.assertIs(type(row["ordered"]), int)
            self.assertIs(type(row["shipped"]), int)
            self.assertIs(type(row["quoted"]), str)
            self.assertIs(type(row["invoiced"]), str)

    def test_statuses_and_amounts(self):
        self.parts(self.part_complete_orders, self.part_shipped_units_are_capped_at_the_ordered_units, self.part_invoiced_is_the_invoices_total_for_what_shipped)

    def part_complete_orders(self):
        self.ok("fulfil", "SO-1001", "2024-03-05")
        self.ok("fulfil", "SO-1002", "2024-03-09")
        self.assertEqual(self.lines("report"), [
            "SO-1001 2024-03-03 acme complete 15/15 177.27 177.27",
            "SO-1003 2024-03-03 zed open 0/1 30.00 0.00",
            "SO-1002 2024-03-09 Bea complete 2/2 30.00 30.00"])

    def part_shipped_units_are_capped_at_the_ordered_units(self):
        self.put("movements.txt", MOVES + "2024-03-06 AB-100 -1 order SO-1002\n2024-03-06 AB-100 -5 order SO-1002\n")
        self.assertIn("SO-1002 2024-03-09 Bea complete 2/2 30.00 30.00", self.lines("report"))

    def part_invoiced_is_the_invoices_total_for_what_shipped(self):
        row = [r for r in self.js("report", "--format", "json") if r["order"] == "SO-1001"][0]
        self.assertEqual(row["invoiced"], self.lines("invoice", "SO-1001")[-1].split()[1])

    def test_edges(self):
        self.parts(self.part_no_orders_at_all, self.part_orders_on_one_day_are_listed_by_order_number, self.part_bad_format_is_a_command_line_mistake)

    def part_no_orders_at_all(self):
        self.files(CATALOG, MOVES, None)
        self.assertEqual(self.ok("report"), "")
        self.assertEqual(self.js("report", "--format", "json"), [])
        self.assertEqual(self.lines("report", "--format", "csv")[0], "order,date,customer,status,ordered,shipped,quoted,invoiced")

    def part_orders_on_one_day_are_listed_by_order_number(self):
        self.files(CATALOG, "", "SO-1013 2024-03-03 c AB-100*1\nSO-1011 2024-03-03 a AB-100*1\nSO-1012 2024-03-02 b AB-100*1\n"
                                "SO-1010 2024-03-04 d AB-100*1\n")
        self.assertEqual([l.split()[0] for l in self.lines("report")], ["SO-1012", "SO-1011", "SO-1013", "SO-1010"])

    def part_bad_format_is_a_command_line_mistake(self):
        for fmt in ("xml", "yaml"):
            with self.subTest(fmt=fmt):
                self.fails("report", "--format", fmt, code=2)


if __name__ == "__main__":
    unittest.main()

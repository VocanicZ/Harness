"""The shelves commands: stock, low, history, receive, ship."""
import json
import os
import unittest

from common import Base, CATALOG, MOVES, delta_of

# Scrambled file order, mixed case: the commands list by SKU.
SHELF_CATALOG = """\
# the shelves
AA-008 | Sold out again | 1.00 | 4
aa-003 | Three  spaces | 1.00 | 3 | reduced
AA-001 | One | 1.00 | 3
AA-005 | Reorder nothing, none held | 1.00 | 0 | zero
AA-002 | Two | 1.00 | 3
AA-007 | Untouched | 1.00 | 2
AA-006 | Reorder nothing, some held | 1.00 | 0
AA-004 | Four | 1.00 | 3
"""

SHELF_MOVES = """\
2024-03-01 AA-001 +5
2024-03-01 AA-002 +3
2024-03-01 AA-003 +1
2024-03-01 aa-004 +4
2024-03-01 AA-006 +2
2024-03-01 AA-008 +2
2024-03-02 AA-008 -2 all gone
"""

STOCK_TEXT = [
    "AA-001 5 ok One",
    "AA-002 3 low Two",
    "AA-003 1 low Three  spaces",
    "AA-004 4 ok Four",
    "AA-005 0 out Reorder nothing, none held",
    "AA-006 2 ok Reorder nothing, some held",
    "AA-007 0 out Untouched",
    "AA-008 0 out Sold out again",
]

LOW_TEXT = [
    "AA-002 3 3 3",
    "AA-003 1 3 5",
    "AA-005 0 0 1",
    "AA-007 0 2 4",
    "AA-008 0 4 8",
]


class StockCliTests(Base):
    def test_text(self):
        self.parts(self.part_example, self.part_status_boundaries_and_order_by_sku, self.part_every_product_is_listed_when_there_are_no_movements, self.part_stock_counts_movements_in_any_file_order)

    def part_example(self):
        self.files()
        self.assertEqual(self.lines("stock"), ["AB-100 17 ok Garden gnome", "CD-205 40 low Seed packet, mix",
                                               "EF-310 0 out Gift voucher"])

    def part_status_boundaries_and_order_by_sku(self):
        self.files(SHELF_CATALOG, SHELF_MOVES, None)
        self.assertEqual(self.lines("stock"), STOCK_TEXT)

    def test_json(self):
        self.files(SHELF_CATALOG, SHELF_MOVES, None)
        got = self.js("stock", "--json")
        self.assertEqual(got[:3], [
            {"sku": "AA-001", "name": "One", "onhand": 5, "status": "ok"},
            {"sku": "AA-002", "name": "Two", "onhand": 3, "status": "low"},
            {"sku": "AA-003", "name": "Three  spaces", "onhand": 1, "status": "low"},
        ])
        self.assertEqual([(r["sku"], r["onhand"], r["status"]) for r in got],
                         [(l.split()[0], int(l.split()[1]), l.split()[2]) for l in STOCK_TEXT])
        self.assertTrue(all(set(r) == {"sku", "name", "onhand", "status"} for r in got))
        self.assertTrue(all(type(r["onhand"]) is int for r in got))

    def part_every_product_is_listed_when_there_are_no_movements(self):
        self.files(CATALOG, None, None)
        self.assertEqual(self.lines("stock"), ["AB-100 0 out Garden gnome", "CD-205 0 out Seed packet, mix",
                                               "EF-310 0 out Gift voucher"])

    def part_stock_counts_movements_in_any_file_order(self):
        self.files(CATALOG, "2024-03-09 AB-100 -4\n2024-03-01 AB-100 +10\n", None)
        self.assertEqual(self.lines("stock")[0], "AB-100 6 ok Garden gnome")

    def test_empty_catalog_and_unicode(self):
        self.parts(self.part_empty_catalog_prints_nothing, self.part_unicode_name)

    def part_empty_catalog_prints_nothing(self):
        self.files("# no products yet\n", None, None)
        self.assertEqual(self.ok("stock"), "")
        self.assertEqual(self.js("stock", "--json"), [])

    def part_unicode_name(self):
        self.files("AB-100 | Crème brûlée kit | 3.00 | 1\n", None, None)
        self.assertEqual(self.js("stock", "--json")[0]["name"], "Crème brûlée kit")


class LowCliTests(Base):
    def test_text(self):
        self.parts(self.part_example, self.part_boundaries_and_how_much_to_buy)

    def part_example(self):
        self.files()
        self.assertEqual(self.lines("low"), ["CD-205 40 40 40", "EF-310 0 0 1"])

    def part_boundaries_and_how_much_to_buy(self):
        self.files(SHELF_CATALOG, SHELF_MOVES, None)
        self.assertEqual(self.lines("low"), LOW_TEXT)

    def test_json(self):
        self.files(SHELF_CATALOG, SHELF_MOVES, None)
        got = self.js("low", "--json")
        self.assertEqual(got, [{"sku": l.split()[0], "onhand": int(l.split()[1]), "reorder": int(l.split()[2]),
                                "buy": int(l.split()[3])} for l in LOW_TEXT])

    def test_nothing_low_prints_nothing_and_succeeds(self):
        self.files("AB-100 | a | 1.00 | 2\n", "2024-03-01 AB-100 +3\n", None)
        self.assertEqual(self.ok("low"), "")
        self.assertEqual(self.js("low", "--json"), [])


class HistoryCliTests(Base):
    MOVES = """\
2024-03-05 AA-001 -2 sold two
2024-03-01 aa-001 +10 delivery
2024-03-05 AA-001 +1
2024-03-03 AA-002 4 other product
2024-03-05 AA-001 -1   late  note   
"""
    CAT = "AA-001 | One | 1.00 | 3\nAA-002 | Two | 1.00 | 3\nAA-003 | Three | 1.00 | 3\n"

    def test_text(self):
        self.parts(self.part_example, self.part_movements_in_the_order_they_count_with_running_balance, self.part_only_that_products_movements, self.part_sku_is_accepted_in_any_case)

    def part_example(self):
        self.files()
        self.assertEqual(self.lines("history", "AB-100"), ["2024-03-01 +20 20 first delivery",
                                                           "2024-03-04 -3 17 order SO-1001"])

    def part_movements_in_the_order_they_count_with_running_balance(self):
        self.files(self.CAT, self.MOVES, None)
        self.assertEqual(self.lines("history", "AA-001"), [
            "2024-03-01 +10 10 delivery",
            "2024-03-05 -2 8 sold two",
            "2024-03-05 +1 9",
            "2024-03-05 -1 8 late  note",
        ])

    def part_only_that_products_movements(self):
        self.files(self.CAT, self.MOVES, None)
        self.assertEqual(self.lines("history", "AA-002"), ["2024-03-03 +4 4 other product"])

    def part_sku_is_accepted_in_any_case(self):
        self.files(self.CAT, self.MOVES, None)
        self.assertEqual(self.lines("history", "aa-002"), ["2024-03-03 +4 4 other product"])

    def part_json(self):
        self.parts(self.part_json, self.part_json_option_may_come_before_the_sku)

    def part_json(self):
        self.files(self.CAT, self.MOVES, None)
        got = self.js("history", "AA-001", "--json")
        self.assertEqual(len(got), 4)
        self.assertTrue(all(set(r) == {"date", "delta", "balance", "note"} for r in got))
        self.assertEqual([r["date"] for r in got], ["2024-03-01", "2024-03-05", "2024-03-05", "2024-03-05"])
        self.assertEqual([delta_of(r["delta"]) for r in got], [10, -2, 1, -1])
        self.assertEqual([r["balance"] for r in got], [10, 8, 9, 8])
        self.assertTrue(all(type(r["balance"]) is int for r in got))
        self.assertEqual([r["note"] for r in got], ["delivery", "sold two", "", "late  note"])

    def part_json_option_may_come_before_the_sku(self):
        self.files(self.CAT, self.MOVES, None)
        self.assertEqual(self.js("history", "--json", "AA-002")[0]["balance"], 4)

    def test_empty_and_unknown(self):
        self.parts(self.part_a_product_that_never_moved_has_an_empty_history, self.part_unknown_sku_is_refused)

    def part_a_product_that_never_moved_has_an_empty_history(self):
        self.files(self.CAT, self.MOVES, None)
        self.assertEqual(self.ok("history", "AA-003"), "")
        self.assertEqual(self.js("history", "AA-003", "--json"), [])

    def part_unknown_sku_is_refused(self):
        self.files(self.CAT, self.MOVES, None)
        for sku in ("ZZ-999", "nonsense", "AA-004"):
            with self.subTest(sku=sku):
                self.fails("history", sku)

    def test_odd_characters_in_a_note_stay_in_the_note(self):
        self.files(self.CAT, "2024-03-01 AA-001 +10 a\rb c\x0cd\x85e\n2024-03-02 AA-001 -1 next\n", None)
        got = self.js("history", "AA-001", "--json")
        self.assertEqual([r["note"] for r in got], ["a\rb c\x0cd\x85e", "next"])


class ReceiveShipTests(Base):
    def seed(self):
        self.files()

    def moves(self):
        return self.read("movements.txt")

    def test_append_and_print(self):
        self.parts(self.part_receive_appends_the_line_and_prints_it, self.part_ship_appends_the_line_and_prints_it, self.part_no_note_leaves_the_note_and_its_space_out, self.part_sku_is_written_in_upper_case)

    def part_receive_appends_the_line_and_prints_it(self):
        out = self.ok("receive", "2024-03-06", "AB-100", "5", "second delivery")
        self.assertEqual(out, "2024-03-06 AB-100 +5 second delivery\n")
        self.assertEqual(self.moves(), MOVES.encode() + b"2024-03-06 AB-100 +5 second delivery\n")

    def part_ship_appends_the_line_and_prints_it(self):
        out = self.ok("ship", "2024-03-06", "AB-100", "5", "walk-in")
        self.assertEqual(out, "2024-03-06 AB-100 -5 walk-in\n")
        self.assertEqual(self.moves(), MOVES.encode() + b"2024-03-06 AB-100 -5 walk-in\n")

    def part_no_note_leaves_the_note_and_its_space_out(self):
        self.assertEqual(self.ok("receive", "2024-03-06", "AB-100", "5"), "2024-03-06 AB-100 +5\n")
        self.assertEqual(self.ok("ship", "2024-03-07", "AB-100", "2"), "2024-03-07 AB-100 -2\n")
        self.assertTrue(self.moves().endswith(b"2024-03-06 AB-100 +5\n2024-03-07 AB-100 -2\n"))

    def part_sku_is_written_in_upper_case(self):
        self.assertEqual(self.ok("receive", "2024-03-06", "cd-205", "1"), "2024-03-06 CD-205 +1\n")

    def test_file_handling(self):
        self.parts(self.part_creates_movements_txt_when_it_is_missing, self.part_adds_the_missing_final_newline_first, self.part_blank_lines_and_comments_in_the_file_are_left_alone, self.part_the_new_line_goes_at_the_end_whatever_its_date)

    def part_creates_movements_txt_when_it_is_missing(self):
        os.remove(self.path("movements.txt"))
        self.assertEqual(self.ok("receive", "2024-03-06", "AB-100", "5", "first"), "2024-03-06 AB-100 +5 first\n")
        self.assertEqual(self.moves(), b"2024-03-06 AB-100 +5 first\n")

    def part_adds_the_missing_final_newline_first(self):
        self.put("movements.txt", "2024-03-01 AB-100 +20")
        self.ok("ship", "2024-03-02", "AB-100", "2")
        self.assertEqual(self.moves(), b"2024-03-01 AB-100 +20\n2024-03-02 AB-100 -2\n")

    def part_the_new_line_goes_at_the_end_whatever_its_date(self):
        self.ok("receive", "2024-02-01", "CD-205", "3")
        self.assertEqual(self.moves(), MOVES.encode() + b"2024-02-01 CD-205 +3\n")

    def test_effects_on_the_shelves(self):
        self.parts(self.part_the_new_movement_shows_up_in_the_other_commands, self.part_shipping_everything_down_to_zero_is_allowed)

    def part_the_new_movement_shows_up_in_the_other_commands(self):
        self.ok("receive", "2024-03-06", "EF-310", "7", "vouchers")
        self.assertIn("EF-310 7 ok Gift voucher", self.lines("stock"))
        self.assertEqual(self.lines("history", "EF-310"), ["2024-03-06 +7 7 vouchers"])
        self.ok("ship", "2024-03-07", "EF-310", "7")
        self.assertEqual(self.lines("history", "EF-310")[-1], "2024-03-07 -7 0")

    def part_shipping_everything_down_to_zero_is_allowed(self):
        self.ok("ship", "2024-03-06", "AB-100", "17")
        self.assertIn("AB-100 0 out Garden gnome", self.lines("stock"))

    def test_notes(self):
        self.parts(self.part_the_note_is_kept_as_typed_inside, self.part_a_dash_led_note_is_a_note)

    def part_the_note_is_kept_as_typed_inside(self):
        self.ok("receive", "2024-03-06", "AB-100", "1", "two  words\tand # a | bar")
        self.assertEqual(self.js("history", "AB-100", "--json")[-1]["note"], "two  words\tand # a | bar")

    def part_a_dash_led_note_is_a_note(self):
        self.assertEqual(self.ok("receive", "2024-03-06", "AB-100", "1", "-urgent"), "2024-03-06 AB-100 +1 -urgent\n")
        self.assertEqual(self.ok("ship", "2024-03-07", "AB-100", "1", "--json"), "2024-03-07 AB-100 -1 --json\n")

    def refused(self, *args):
        before = self.moves()
        self.fails(*args)
        self.assertEqual(self.moves(), before)

    def test_refused_input(self):
        self.parts(self.part_refused_unknown_sku, self.part_refused_bad_quantities, self.part_refused_note_with_a_line_break)

    def part_refused_unknown_sku(self):
        self.refused("receive", "2024-03-06", "ZZ-999", "5")
        self.refused("ship", "2024-03-06", "ZZ-999", "5")
        self.refused("receive", "2024-03-06", "nonsense", "5")

    def part_refused_bad_quantities(self):
        for q in ["0", "-5", "+5", "2.5", "abc", "1e2", "5x"]:
            with self.subTest(quantity=q):
                self.refused("receive", "2024-03-06", "AB-100", q)
                self.refused("ship", "2024-03-06", "AB-100", q)

    def test_refused_stock(self):
        self.parts(self.part_refused_when_stock_would_go_below_zero, self.part_refused_when_a_shipment_in_the_past_would_starve_a_later_movement, self.part_same_day_shipment_counts_after_what_is_already_in_the_file)

    def part_refused_when_stock_would_go_below_zero(self):
        self.refused("ship", "2024-03-06", "AB-100", "18")
        self.refused("ship", "2024-03-06", "EF-310", "1")

    def part_refused_when_a_shipment_in_the_past_would_starve_a_later_movement(self):
        # 20 in on 03-01, 3 out on 03-04: shipping 18 on 03-02 leaves 2 for the 3 that go out on 03-04
        self.refused("ship", "2024-03-02", "AB-100", "18")
        self.ok("ship", "2024-03-02", "AB-100", "17")

    def part_same_day_shipment_counts_after_what_is_already_in_the_file(self):
        self.put("movements.txt", "2024-03-01 AB-100 +5\n")
        self.refused("ship", "2024-03-01", "AB-100", "6")
        self.ok("ship", "2024-03-01", "AB-100", "5")

    def part_refused_note_with_a_line_break(self):
        self.refused("receive", "2024-03-06", "AB-100", "5", "two\nlines")
        self.refused("ship", "2024-03-06", "AB-100", "1", "two\r\nlines")

    def test_refusal_leaves_the_file_alone(self):
        self.parts(self.part_refusal_leaves_a_file_without_final_newline_byte_for_byte_alone, self.part_refusal_does_not_create_the_file, self.part_a_mistake_in_the_movements_file_stops_receive)

    def part_refusal_leaves_a_file_without_final_newline_byte_for_byte_alone(self):
        self.put("movements.txt", "2024-03-01 AB-100 +20")
        self.refused("ship", "2024-03-06", "AB-100", "21")
        self.assertEqual(self.moves(), b"2024-03-01 AB-100 +20")

    def part_refusal_does_not_create_the_file(self):
        os.remove(self.path("movements.txt"))
        self.fails("ship", "2024-03-06", "AB-100", "1")
        self.fails("receive", "2024-03-06", "ZZ-999", "1")
        self.assertIsNone(self.moves())

    def part_a_mistake_in_the_movements_file_stops_receive(self):
        self.put("movements.txt", "2024-03-01 AB-100 +20\nbroken\n")
        before = self.moves()
        self.fails("receive", "2024-03-06", "AB-100", "1", mentions=["movements.txt", "line 2"])
        self.assertEqual(self.moves(), before)

    def part_blank_lines_and_comments_in_the_file_are_left_alone(self):
        text = "# my stock\n\n2024-03-01 AB-100 +20\n\n# end\n"
        self.put("movements.txt", text)
        self.ok("ship", "2024-03-06", "AB-100", "1")
        self.assertEqual(self.moves(), text.encode() + b"2024-03-06 AB-100 -1\n")


if __name__ == "__main__":
    unittest.main()

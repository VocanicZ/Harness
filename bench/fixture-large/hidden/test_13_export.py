"""Hidden tests of module 13: export (tallybook.export)."""
import csv
import io
import json
import unittest
from datetime import date

from support import lib

D = date


def export():
    return lib("export")


def money(text):
    return lib("money").Money.parse(text)


def tx(day, payee, narration="", postings=(), tags=(), flag="*", tx_id=None):
    model = lib("model")
    ps = [model.Posting(a, None if m is None else money(m), *([n] if n else [])) for a, m, n in postings]
    return model.Transaction(date=day, payee=payee, narration=narration, postings=ps, tags=tags, flag=flag, id=tx_id)


COFFEE = tx(D(2024, 3, 1), "Café, Bäcker", 'say "hi"',
            [("Expenses:Food", "4.50 USD", "a, b"), ("Assets:Cash", "-4.50 USD", "")], ("lunch", "a"), "!", 7)
PLAIN = tx(D(2024, 3, 2), "Flat", "", [("Expenses:Rent", "900 JPY", ""), ("Assets:Bank", None, "")])
HEADER = "id,date,flag,payee,narration,tags,account,amount,currency,note\n"


class M13Csv(unittest.TestCase):
    def test_header_only_for_no_transactions(self):
        self.assertEqual(export().transactions_to_csv([]), HEADER)
        self.assertEqual(export().transactions_to_csv(iter(())), HEADER)

    def test_one_record_per_posting(self):
        out = export().transactions_to_csv([COFFEE])
        self.assertEqual(out, HEADER +
                         '7,2024-03-01,!,"Café, Bäcker","say ""hi""",a;lunch,Expenses:Food,4.50,USD,"a, b"\n'
                         '7,2024-03-01,!,"Café, Bäcker","say ""hi""",a;lunch,Assets:Cash,-4.50,USD,\n')

    def test_missing_id_and_missing_amount(self):
        out = export().transactions_to_csv([PLAIN])
        self.assertEqual(out, HEADER + ",2024-03-02,*,Flat,,,Expenses:Rent,900,JPY,\n,2024-03-02,*,Flat,,,Assets:Bank,,,\n")

    def test_transaction_without_postings(self):
        out = export().transactions_to_csv([tx(D(2024, 5, 6), "Empty", "n", [], ("t",), "!", 3)])
        self.assertEqual(out, HEADER + "3,2024-05-06,!,Empty,n,t,,,,\n")

    def test_order_is_the_order_given(self):
        a, b = tx(D(2024, 3, 9), "late", "", [("A:B", "1.00 USD", "")], (), "*", 2), \
            tx(D(2024, 3, 1), "early", "", [("A:B", "2.00 USD", "")], (), "*", 1)
        rows = list(csv.reader(io.StringIO(export().transactions_to_csv([a, b]))))
        self.assertEqual([r[3] for r in rows[1:]], ["late", "early"])
        rows = list(csv.reader(io.StringIO(export().transactions_to_csv([b, a]))))
        self.assertEqual([r[3] for r in rows[1:]], ["early", "late"])

    def test_quoting_is_minimal(self):
        cases = {"plain": "plain", "with space": "with space", " lead": " lead", "a,b": '"a,b"', 'say "x"': '"say ""x"""',
                 "two\nlines": '"two\nlines"', "cr\rhere": '"cr\rhere"', "": "", "semi;colon": "semi;colon",
                 "tab\there": "tab\there", "'single'": "'single'", "ü中": "ü中"}
        for narration, written in cases.items():
            with self.subTest(narration=narration):
                out = export().transactions_to_csv([tx(D(2024, 1, 1), "p", narration, [("A:B", "1.00 USD", "")], (), "*", 1)])
                self.assertEqual(out, HEADER + "1,2024-01-01,*,p,%s,,A:B,1.00,USD,\n" % written)

    def test_line_endings(self):
        out = export().transactions_to_csv([COFFEE, PLAIN])
        self.assertNotIn("\r\n", out)
        self.assertTrue(out.endswith("\n"))
        self.assertFalse(out.endswith("\n\n"))

    def test_csv_round_trips_through_the_csv_module(self):
        rows = list(csv.reader(io.StringIO(export().transactions_to_csv([COFFEE, PLAIN]), newline="")))
        self.assertEqual(rows[0], HEADER.strip().split(","))
        self.assertEqual(rows[1], ["7", "2024-03-01", "!", "Café, Bäcker", 'say "hi"', "a;lunch", "Expenses:Food",
                                   "4.50", "USD", "a, b"])
        self.assertEqual(len(rows), 5)

    def test_amount_formats(self):
        cases = [("0.05 USD", "0.05"), ("-0.05 USD", "-0.05"), ("1234567.89 EUR", "1234567.89"), ("500 JPY", "500"),
                 ("-12.345 KWD", "-12.345"), ("0.00 USD", "0.00"), ("100 JPY", "100")]
        for text, want in cases:
            with self.subTest(text=text):
                out = export().transactions_to_csv([tx(D(2024, 1, 1), "p", "", [("A:B", text, "")], (), "*", 1)])
                self.assertEqual(out.splitlines()[1].split(",")[7:9], [want, text.split()[1]])

    def test_tags_sorted_joined_and_deduplicated(self):
        for tags, want in (((), ""), (("b", "a", "c"), "a;b;c"), (["x", "x"], "x"), (("Zed", "alpha"), "Zed;alpha")):
            with self.subTest(tags=tags):
                out = export().transactions_to_csv([tx(D(2024, 1, 1), "p", "", [("A:B", "1.00 USD", "")], tags, "*", 1)])
                self.assertEqual(out.splitlines()[1].split(",")[5], want)

    def test_to_csv_generic(self):
        out = export().to_csv(["a", "b"], [[1, None], ["x,y", 'q"']])
        self.assertEqual(out, 'a,b\n1,\n"x,y","q"""\n')
        self.assertEqual(export().to_csv(["only"], []), "only\n")
        self.assertEqual(export().to_csv(["h,1"], [[True]]), '"h,1"\nTrue\n')

    def test_input_is_not_changed(self):
        before = (COFFEE.tags, list(COFFEE.postings), COFFEE.id)
        export().transactions_to_csv([COFFEE])
        export().transactions_to_json([COFFEE])
        self.assertEqual((COFFEE.tags, list(COFFEE.postings), COFFEE.id), before)


class M13Json(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(export().transactions_to_json([]), "[]\n")

    def test_shape(self):
        data = json.loads(export().transactions_to_json([COFFEE, PLAIN]))
        self.assertEqual(data[0], {
            "id": 7, "date": "2024-03-01", "flag": "!", "payee": "Café, Bäcker", "narration": 'say "hi"',
            "tags": ["a", "lunch"],
            "postings": [{"account": "Expenses:Food", "amount": {"amount": "4.50", "currency": "USD"}, "note": "a, b"},
                         {"account": "Assets:Cash", "amount": {"amount": "-4.50", "currency": "USD"}, "note": ""}]})
        self.assertIsNone(data[1]["id"])
        self.assertEqual(data[1]["postings"][0]["amount"], {"amount": "900", "currency": "JPY"})
        self.assertIsNone(data[1]["postings"][1]["amount"])
        self.assertEqual(data[1]["tags"], [])

    def test_text_format(self):
        expected = json.dumps(json.loads(export().transactions_to_json([COFFEE])), indent=2, sort_keys=True,
                              ensure_ascii=False) + "\n"
        self.assertEqual(export().transactions_to_json([COFFEE]), expected)
        out = export().transactions_to_json([COFFEE])
        self.assertIn("Café, Bäcker", out)
        self.assertNotIn("\\u00e9", out)
        self.assertTrue(out.startswith("[\n  {\n    \"date\": \"2024-03-01\","))
        self.assertTrue(out.endswith("}\n]\n"))

    def test_keys_are_sorted(self):
        out = export().transactions_to_json([COFFEE])
        keys = ["date", "flag", "id", "narration", "payee", "postings", "tags"]
        positions = [out.index('"%s":' % k) for k in keys]
        self.assertEqual(positions, sorted(positions))

    def test_order_and_tags(self):
        a = tx(D(2024, 3, 9), "late", "", [("A:B", "1.00 USD", "")], ("z", "a", "z"), "*", 2)
        b = tx(D(2024, 3, 1), "early", "", [("A:B", "2.00 USD", "")], [], "!", 1)
        data = json.loads(export().transactions_to_json([a, b]))
        self.assertEqual([t["payee"] for t in data], ["late", "early"])
        self.assertEqual(data[0]["tags"], ["a", "z"])

    def test_helpers(self):
        self.assertEqual(export().money_to_dict(money("-0.50 USD")), {"amount": "-0.50", "currency": "USD"})
        self.assertIsNone(export().money_to_dict(None))
        self.assertEqual(export().transaction_to_dict(COFFEE), json.loads(export().transactions_to_json([COFFEE]))[0])
        self.assertEqual(export().to_json({"b": [1, {"d": 1, "c": "é"}], "a": None}),
                         '{\n  "a": null,\n  "b": [\n    1,\n    {\n      "c": "é",\n      "d": 1\n    }\n  ]\n}\n')
        self.assertEqual(export().to_json([]), "[]\n")


class M13Table(unittest.TestCase):
    def test_documented_example(self):
        out = export().render_table(["Name", "Qty", "Price"], [["Apple", 3, "1.50"], ["Kiwi", 12, "10.25"], ["Ünï", None, "x\ty"]], "lrr")
        self.assertEqual(out, "Name   Qty  Price\n-----  ---  -----\nApple    3   1.50\nKiwi    12  10.25\nÜnï           x y\n")

    def test_default_alignment_is_left(self):
        out = export().render_table(["A", "Bee"], [["xxx", "1"], ["y", "22"]])
        self.assertEqual(out, "A    Bee\n---  ---\nxxx  1\ny    22\n")

    def test_alignment_as_string_or_list(self):
        rows = [["a", "1"], ["bbb", "22"]]
        want = "Col   N\n---  --\na     1\nbbb  22\n"
        self.assertEqual(export().render_table(["Col", "N"], rows, "lr"), want)
        self.assertEqual(export().render_table(["Col", "N"], rows, ["l", "r"]), want)
        self.assertEqual(export().render_table(["Col", "N"], rows, ("l", "r")), want)

    def test_right_alignment_pads_titles_too(self):
        out = export().render_table(["Amount", "X"], [["1", "2"]], "rr")
        self.assertEqual(out, "Amount  X\n------  -\n     1  2\n")

    def test_no_trailing_spaces_anywhere(self):
        out = export().render_table(["Left", "Mid", "Last"], [["a", "b", "c"], ["long text", "", ""], ["", "", "x"]], "lll")
        for line in out.splitlines():
            self.assertEqual(line, line.rstrip())
        self.assertEqual(out, "Left       Mid  Last\n---------  ---  ----\na          b    c\n"
                              "long text\n" + " " * 16 + "x\n")

    def test_width_is_len(self):
        out = export().render_table(["h"], [["中文"], ["é"], ["abc"]])
        self.assertEqual(out, "h\n---\n中文\né\nabc\n")
        out = export().render_table(["h", "n"], [["中文", "1"]], "lr")
        self.assertEqual(out, "h   n\n--  -\n中文  1\n")

    def test_cells_are_str_and_none_is_empty(self):
        out = export().render_table(["a", "b", "c", "d"], [[1, 2.5, True, None], [None, None, None, "z"]], "rrll")
        self.assertEqual(out, "a    b  c     d\n-  ---  ----  -\n1  2.5  True\n" + " " * 14 + "z\n")

    def test_whitespace_inside_cells_becomes_single_spaces(self):
        out = export().render_table(["h"], [["a\nb"], ["c\r\nd"], ["e\tf"]])
        self.assertEqual(out, "h\n----\na b\nc  d\ne f\n")

    def test_no_rows(self):
        self.assertEqual(export().render_table(["Name", "Qty"], []), "Name  Qty\n----  ---\n")

    def test_no_headers(self):
        self.assertEqual(export().render_table([], []), "")
        self.assertEqual(export().render_table([], [[]]), "")

    def test_wide_titles_set_the_width(self):
        self.assertEqual(export().render_table(["A very long title", "n"], [["x", "1"]], "lr"),
                         "A very long title  n\n-----------------  -\nx                  1\n")

    def test_single_column(self):
        self.assertEqual(export().render_table(["x"], [["1"], ["22"]], "r"), " x\n--\n 1\n22\n")

    def test_errors(self):
        render = export().render_table
        for headers, rows, align in ((["a", "b"], [["1"]], None), (["a"], [["1", "2"]], None), (["a", "b"], [["1", "2"]], "l"),
                                      (["a", "b"], [["1", "2"]], "lrr"), (["a", "b"], [["1", "2"]], "lx"),
                                      (["a", "b"], [["1", "2"]], "lL"), (["a"], [["1"]], ["left"]), (["a", "b"], [["1", "2"]], "")):
            with self.subTest(headers=headers, rows=rows, align=align), self.assertRaises(export().ExportError):
                render(headers, rows, align)

    def test_export_error_class(self):
        self.assertTrue(issubclass(export().ExportError, lib("errors").ValidationError))
        with self.assertRaises(export().ExportError) as ctx:
            export().render_table(["a"], [["1", "2"]])
        self.assertEqual(ctx.exception.code, "validation")

    def test_rows_may_be_tuples_or_generators(self):
        out = export().render_table(("a", "b"), ((i, i * i) for i in range(3)), "rr")
        self.assertEqual(out, "a  b\n-  -\n0  0\n1  1\n2  4\n")

    def test_ends_with_exactly_one_newline(self):
        out = export().render_table(["a"], [["b"]])
        self.assertTrue(out.endswith("b\n"))
        self.assertFalse(out.endswith("\n\n"))


class M13FromJson(unittest.TestCase):
    def load(self, text):
        return export().transactions_from_json(text)

    def test_round_trip(self):
        a = tx(D(2024, 3, 1), "Caf\u00e9, B\u00e4cker", 'say "hi"',
               [("Expenses:Food", "4.50 USD", "a, b"), ("Assets:Cash", "-4.50 USD", "")], ("a", "lunch"), "!", 7)
        txs = [a, PLAIN, tx(D(2024, 1, 1), "Empty", "", [], ("x",), "*", 2)]
        self.assertEqual(self.load(export().transactions_to_json(txs)), txs)
        self.assertEqual(self.load("[]"), [])
        self.assertEqual(self.load(export().transactions_to_json([])), [])

    def test_result_types(self):
        (t,) = self.load(export().transactions_to_json([PLAIN]))
        self.assertIsInstance(t, lib("model").Transaction)
        self.assertEqual(t.date, D(2024, 3, 2))
        self.assertIsInstance(t.postings[0], lib("model").Posting)
        self.assertEqual(t.postings[0].amount, money("900 JPY"))
        self.assertIsNone(t.postings[1].amount)
        self.assertEqual(t.tags, ())
        self.assertIsNone(t.id)

    def test_defaults_for_optional_fields(self):
        (t,) = self.load('[{"date": "2024-05-06", "payee": "P", "postings": []}]')
        self.assertEqual((t.id, t.flag, t.narration, t.tags, t.postings), (None, "*", "", (), []))
        (t,) = self.load('[{"date": "2024-05-06", "payee": "P", "id": null, "postings": [{"account": "A:B"}]}]')
        self.assertEqual((t.id, t.postings[0].note, t.postings[0].amount), (None, "", None))

    def test_tags_are_sorted_and_unique(self):
        (t,) = self.load('[{"date": "2024-05-06", "payee": "P", "tags": ["b", "a", "b"], "postings": []}]')
        self.assertEqual(t.tags, ("a", "b"))

    def test_errors(self):
        good = '{"date": "2024-05-06", "payee": "P", "postings": [%s]}'
        bad = ["", "nope", "{}", "[1]", '["x"]', "null", '"text"',
               '[{"payee": "P", "postings": []}]', '[{"date": "2024-05-06", "postings": []}]',
               '[{"date": "2024-05-06", "payee": "P"}]', '[{"date": "2024-05-06", "payee": "P", "postings": {}}]',
               '[{"date": "2024-02-30", "payee": "P", "postings": []}]', '[{"date": "2024-2-3", "payee": "P", "postings": []}]',
               '[{"date": 20240506, "payee": "P", "postings": []}]', '[{"date": "2024-05-06", "payee": 5, "postings": []}]',
               '[{"date": "2024-05-06", "payee": "P", "postings": [], "extra": 1}]',
               '[{"date": "2024-05-06", "payee": "P", "id": 0, "postings": []}]',
               '[{"date": "2024-05-06", "payee": "P", "id": true, "postings": []}]',
               '[{"date": "2024-05-06", "payee": "P", "id": "7", "postings": []}]',
               '[{"date": "2024-05-06", "payee": "P", "flag": "?", "postings": []}]',
               '[{"date": "2024-05-06", "payee": "P", "tags": "a", "postings": []}]',
               '[{"date": "2024-05-06", "payee": "P", "tags": [1], "postings": []}]',
               '[%s]' % (good % '1'), '[%s]' % (good % '{"amount": null}'), '[%s]' % (good % '{"account": 5}'),
               '[%s]' % (good % '{"account": "A", "amount": "1.00 USD"}'),
               '[%s]' % (good % '{"account": "A", "amount": {"amount": "1.00"}}'),
               '[%s]' % (good % '{"account": "A", "amount": {"amount": "1.00", "currency": "USD", "x": 1}}'),
               '[%s]' % (good % '{"account": "A", "amount": {"amount": 1, "currency": "USD"}}'),
               '[%s]' % (good % '{"account": "A", "amount": {"amount": "1.005", "currency": "USD"}}'),
               '[%s]' % (good % '{"account": "A", "amount": {"amount": "1.00", "currency": "ZZZ"}}'),
               '[%s]' % (good % '{"account": "A", "note": 3}'), '[%s]' % (good % '{"account": "A", "color": "red"}')]
        for text in bad:
            with self.subTest(text=text), self.assertRaises(export().ExportError):
                self.load(text)

    def test_error_messages_say_where(self):
        text = '[{"date": "2024-05-06", "payee": "P", "postings": []}, {"date": "2024-05-06", "payee": "Q", "postings": [' \
               '{"account": "A", "amount": null}, {"account": "B", "amount": {"amount": "x", "currency": "USD"}}]}]'
        with self.assertRaises(export().ExportError) as ctx:
            self.load(text)
        self.assertTrue(ctx.exception.message.startswith("transaction 2 posting 2"), ctx.exception.message)
        with self.assertRaises(export().ExportError) as ctx:
            self.load('[{"date": "2024-05-06", "payee": "P", "postings": []}, {"payee": "Q"}, 5]')
        self.assertTrue(ctx.exception.message.startswith("transaction 2"), ctx.exception.message)
        with self.assertRaises(export().ExportError) as ctx:
            self.load('[{"date": "2024-05-06", "payee": "P", "postings": []}, 5]')
        self.assertTrue(ctx.exception.message.startswith("transaction 2"), ctx.exception.message)

    def test_whitespace_and_unicode_in_text(self):
        (t,) = self.load('[{"date": "2024-05-06", "payee": "Caf\\u00e9 \u4e2d", "narration": "a\\nb", "postings": []}]')
        self.assertEqual((t.payee, t.narration), ("Caf\u00e9 \u4e2d", "a\nb"))


if __name__ == "__main__":
    unittest.main()

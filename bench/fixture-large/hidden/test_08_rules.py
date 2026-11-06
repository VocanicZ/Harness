"""Module 08: categorisation rules (tallybook.rules)."""
import unittest
from datetime import date

from support import lib


def rules():
    return lib("rules")


def money(text):
    return lib("money").Money.parse(text)


def fields(payee="", narration="", amount="-5.00 USD", day=date(2024, 3, 2)):
    out = {"payee": payee, "narration": narration, "date": day}
    if amount is not None:
        out["amount"] = money(amount)
    return out


def tx(payee="CAFE NERO", narration="card 0412", amount="-3.40 GBP", tags=(), flag="*", id=7, account="Expenses:Misc"):
    model = lib("model")
    m = money(amount)
    return model.Transaction(date=date(2024, 3, 2), payee=payee, narration=narration, tags=tuple(tags), flag=flag, id=id,
                             postings=[model.Posting("Assets:Bank", m), model.Posting(account, -m)])


class M08Base(unittest.TestCase):
    def apply(self, text, **kw):
        return rules().parse_rules(text).apply(fields(**kw))

    def err(self, text):
        with self.assertRaises(rules().RulesError) as cm:
            rules().parse_rules(text)
        return cm.exception


class M08Parsing(M08Base):
    SAMPLE = '''# coffee and lunch
when payee ~ "nero|starbucks" and amount < 0 then account Expenses:Food tag coffee narration "Coffee break"

when payee = "ACME PAYROLL" then account Income:Salary tag salary flag *
   # an indented comment
when any then account Expenses:Misc
'''

    def test_rules_are_counted_and_numbered(self):
        rs = rules().parse_rules(self.SAMPLE)
        self.assertEqual(len(rs), 3)
        self.assertEqual([r.line for r in rs], [2, 4, 6])
        self.assertIsInstance(rs, rules().RuleSet)
        self.assertTrue(all(isinstance(r, rules().Rule) for r in rs))

    def test_empty_and_comment_only_text(self):
        for text in ("", "\n\n", "# nothing\n  # here\n", "   \n"):
            with self.subTest(text=text):
                rs = rules().parse_rules(text)
                self.assertEqual(len(rs), 0)
                self.assertIsNone(rs.apply(fields(payee="x")))

    def test_line_endings_and_bom(self):
        crlf = self.SAMPLE.replace("\n", "\r\n")
        self.assertEqual([r.line for r in rules().parse_rules(crlf)], [2, 4, 6])
        self.assertEqual(len(rules().parse_rules("﻿" + self.SAMPLE)), 3)
        self.assertEqual(self.apply("﻿when any then tag a\n"), {"tags": ["a"]})

    def test_spaces_around_operators_are_optional(self):
        for text in ('when amount<0 then tag x', 'when amount < 0 then tag x', 'when   amount<0   then   tag   x'):
            with self.subTest(text=text):
                self.assertEqual(self.apply(text), {"tags": ["x"]})
        self.assertEqual(self.apply('when payee~"caf" then tag x', payee="Cafe"), {"tags": ["x"]})
        self.assertEqual(self.apply('when payee!="a" then tag x', payee="b"), {"tags": ["x"]})

    def test_a_hash_inside_a_line_is_text(self):
        self.assertEqual(self.apply('when any then narration "a # b"'), {"narration": "a # b"})
        self.assertEqual(self.apply('when payee ~ "#1" then tag x', payee="shop #1"), {"tags": ["x"]})


class M08Conditions(M08Base):
    def test_regex_is_a_case_insensitive_search(self):
        text = 'when payee ~ "nero" then tag hit'
        self.assertEqual(self.apply(text, payee="CAFE NERO 0412 LONDON"), {"tags": ["hit"]})
        self.assertEqual(self.apply(text, payee="Caffe Nero"), {"tags": ["hit"]})
        self.assertIsNone(self.apply(text, payee="Starbucks"))
        self.assertIsNone(self.apply(text, payee=""))

    def test_regex_features(self):
        self.assertEqual(self.apply('when payee ~ "^rent" then tag a', payee="Rent march"), {"tags": ["a"]})
        self.assertIsNone(self.apply('when payee ~ "^rent" then tag a', payee="March rent"))
        self.assertEqual(self.apply('when payee ~ "nero|starbucks" then tag a', payee="STARBUCKS #12"), {"tags": ["a"]})
        self.assertEqual(self.apply(r'when narration ~ "ref \d+$" then tag a', narration="ref 1234"), {"tags": ["a"]})
        self.assertIsNone(self.apply(r'when narration ~ "ref \d+$" then tag a', narration="ref abc"))

    def test_case_sensitive_part_with_inline_flag(self):
        text = 'when payee ~ "(?-i:ACME) payroll" then tag a'
        self.assertEqual(self.apply(text, payee="ACME PAYROLL"), {"tags": ["a"]})
        self.assertEqual(self.apply(text, payee="acme payroll"), None)

    def test_negated_regex(self):
        text = 'when payee !~ "coffee" then tag other'
        self.assertEqual(self.apply(text, payee="Bakery"), {"tags": ["other"]})
        self.assertIsNone(self.apply(text, payee="Blue COFFEE Co"))

    def test_equals_is_the_whole_text_ignoring_case(self):
        text = 'when payee = "acme payroll" then tag a'
        self.assertEqual(self.apply(text, payee="ACME Payroll"), {"tags": ["a"]})
        self.assertIsNone(self.apply(text, payee="ACME Payroll Ltd"))
        self.assertIsNone(self.apply(text, payee=" ACME Payroll"))
        ne = 'when narration != "x" then tag a'
        self.assertEqual(self.apply(ne, narration="y"), {"tags": ["a"]})
        self.assertIsNone(self.apply(ne, narration="X"))

    def test_narration_conditions(self):
        text = 'when narration ~ "salary" and payee = "acme" then tag pay'
        self.assertEqual(self.apply(text, payee="Acme", narration="February Salary"), {"tags": ["pay"]})
        self.assertIsNone(self.apply(text, payee="Acme", narration="bonus"))

    def test_quote_and_backslash_handling(self):
        self.assertEqual(self.apply(r'when payee = "joe \"big\" diner" then tag a', payee='Joe "Big" Diner'),
                         {"tags": ["a"]})
        # a backslash and the next character are kept as written
        self.assertEqual(self.apply(r'when payee = "a\b" then tag a', payee=r"A\B"), {"tags": ["a"]})
        # \\ stays two characters; as a regular expression that is one literal backslash
        self.assertEqual(self.apply(r'when payee ~ "a\\b" then tag a', payee=r"a\b"), {"tags": ["a"]})
        self.assertEqual(self.apply(r'when payee = "a\\b" then tag a', payee="a\\\\b"), {"tags": ["a"]})
        self.assertIsNone(self.apply(r'when payee = "a\\b" then tag a', payee="a\\b"))
        self.assertEqual(self.apply(r'when any then narration "say \"hi\" \n"'), {"narration": r'say "hi" \n'})

    def test_amount_comparisons_are_signed(self):
        cases = [("amount < 0", "-5.00 USD", True), ("amount < 0", "5.00 USD", False), ("amount < 0", "0.00 USD", False),
                 ("amount <= 0", "0.00 USD", True), ("amount > 10", "10.01 USD", True), ("amount > 10", "10.00 USD", False),
                 ("amount >= 10", "10.00 USD", True), ("amount = 3.5", "3.50 USD", True), ("amount = 3.5", "3.51 USD", False),
                 ("amount != 3.5", "3.51 USD", True), ("amount != 3.5", "3.50 USD", False), ("amount <= -500", "-500.00 USD", True),
                 ("amount <= -500", "-499.99 USD", False), ("amount > +1", "2.00 USD", True), ("amount >= 1500", "1500 JPY", True),
                 ("amount < 0.5", "0.49 USD", True)]
        for cond, amount, want in cases:
            with self.subTest(cond=cond, amount=amount):
                got = self.apply("when %s then tag a" % cond, amount=amount)
                self.assertEqual(got, {"tags": ["a"]} if want else None)

    def test_amount_currency_code(self):
        text = "when amount < -10GBP then tag a"
        self.assertEqual(self.apply(text, amount="-11.00 GBP"), {"tags": ["a"]})
        self.assertIsNone(self.apply(text, amount="-11.00 USD"))
        self.assertIsNone(self.apply(text, amount="-9.00 GBP"))
        self.assertEqual(self.apply("when amount < -10 then tag a", amount="-11.00 USD"), {"tags": ["a"]})
        self.assertIsNone(self.apply("when amount != 5USD then tag a", amount="7.00 EUR"))

    def test_missing_amount_and_date_never_satisfy(self):
        for cond in ("amount < 0", "amount > 0", "amount != 5", "amount = 0"):
            with self.subTest(cond=cond):
                self.assertIsNone(self.apply("when %s then tag a" % cond, amount=None))
        fields_no_date = {"payee": "x", "narration": "", "amount": money("1.00 USD")}
        rs = rules().parse_rules("when date != 2024-01-01 then tag a")
        self.assertIsNone(rs.apply(fields_no_date))

    def test_date_conditions(self):
        text = "when date >= 2024-03-01 and date < 2024-04-01 then tag march"
        self.assertEqual(self.apply(text, day=date(2024, 3, 1)), {"tags": ["march"]})
        self.assertEqual(self.apply(text, day=date(2024, 3, 31)), {"tags": ["march"]})
        self.assertIsNone(self.apply(text, day=date(2024, 4, 1)))
        self.assertIsNone(self.apply(text, day=date(2024, 2, 29)))
        self.assertEqual(self.apply("when date = 2024-02-29 then tag a", day=date(2024, 2, 29)), {"tags": ["a"]})
        self.assertEqual(self.apply("when date != 2024-02-29 then tag a", day=date(2024, 3, 1)), {"tags": ["a"]})

    def test_missing_payee_and_narration_are_empty_texts(self):
        rs = rules().parse_rules('when payee = "" then tag a\nwhen narration !~ "x" then tag b')
        self.assertEqual(rs.apply({"amount": money("1.00 USD"), "date": date(2024, 1, 1)}), {"tags": ["a"]})
        self.assertEqual(rs.apply({"payee": "z"}), {"tags": ["b"]})

    def test_any_matches_everything(self):
        self.assertEqual(self.apply("when any then account Expenses:Misc"), {"account": "Expenses:Misc"})
        self.assertEqual(self.apply("when any then flag !", amount=None), {"flag": "!"})

    def test_all_conditions_must_hold(self):
        text = 'when payee ~ "shop" and amount < 0 and date >= 2024-01-01 then tag a'
        self.assertEqual(self.apply(text, payee="Shop", amount="-1.00 USD"), {"tags": ["a"]})
        self.assertIsNone(self.apply(text, payee="Shop", amount="1.00 USD"))
        self.assertIsNone(self.apply(text, payee="Bar", amount="-1.00 USD"))
        self.assertIsNone(self.apply(text, payee="Shop", amount="-1.00 USD", day=date(2023, 12, 31)))


class M08Actions(M08Base):
    def test_first_matching_rule_wins(self):
        text = '''when payee ~ "cafe" then account Expenses:Food
when payee ~ "cafe nero" then account Expenses:Coffee tag coffee
when any then account Expenses:Misc
'''
        rs = rules().parse_rules(text)
        self.assertEqual(rs.apply(fields(payee="Cafe Nero")), {"account": "Expenses:Food"})
        self.assertEqual(rs.apply(fields(payee="Bank fee")), {"account": "Expenses:Misc"})
        self.assertEqual(rs.match(fields(payee="Cafe Nero")).line, 1)
        self.assertEqual(rs.match(fields(payee="x")).line, 3)
        self.assertIsNone(rules().parse_rules('when payee = "q" then tag a').match(fields(payee="z")))

    def test_apply_returns_only_what_the_rule_sets(self):
        rs = rules().parse_rules('when any then account Expenses:Food tag Coffee tag trip narration "Latte" payee "Nero" flag !')
        self.assertEqual(rs.apply(fields()), {"account": "Expenses:Food", "tags": ["coffee", "trip"], "narration": "Latte",
                                              "payee": "Nero", "flag": "!"})
        self.assertEqual(self.apply("when any then flag *"), {"flag": "*"})
        self.assertEqual(self.apply('when any then narration ""'), {"narration": ""})
        self.assertEqual(self.apply("when any then account Assets:Bank-2:My_Cash"), {"account": "Assets:Bank-2:My_Cash"})

    def test_tags_are_lower_case_unique_and_in_written_order(self):
        got = self.apply("when any then tag Zed tag alpha tag ZED tag a-1 tag b_2 tag alpha")
        self.assertEqual(got, {"tags": ["zed", "alpha", "a-1", "b_2"]})

    def test_actions_in_any_order(self):
        got = self.apply('when any then flag ! tag x narration "n" account Income:Other')
        self.assertEqual(got, {"flag": "!", "tags": ["x"], "narration": "n", "account": "Income:Other"})

    def test_apply_returns_a_new_dict_each_time(self):
        rs = rules().parse_rules("when any then tag a account Expenses:Food")
        first = rs.apply(fields())
        first["tags"].append("mutated")
        first["account"] = "Nope"
        self.assertEqual(rs.apply(fields()), {"tags": ["a"], "account": "Expenses:Food"})

    def test_categorize_a_two_posting_transaction(self):
        rs = rules().parse_rules('when payee ~ "nero" and amount < 0 then account Expenses:Food tag coffee '
                                 'narration "Coffee break" payee "Caffe Nero" flag !')
        t = tx(tags=["trip"])
        out = rs.categorize(t)
        self.assertEqual(out.payee, "Caffe Nero")
        self.assertEqual(out.narration, "Coffee break")
        self.assertEqual(out.flag, "!")
        self.assertEqual(out.tags, ("coffee", "trip"))
        self.assertEqual([p.account for p in out.postings], ["Assets:Bank", "Expenses:Food"])
        self.assertEqual([p.amount for p in out.postings], [money("-3.40 GBP"), money("3.40 GBP")])
        self.assertEqual((out.date, out.id), (t.date, 7))
        # the original is untouched
        self.assertEqual((t.payee, t.flag, t.tags, t.postings[1].account), ("CAFE NERO", "*", ("trip",), "Expenses:Misc"))

    def test_categorize_without_a_match_changes_nothing(self):
        rs = rules().parse_rules('when payee = "zzz" then account Expenses:Food')
        t = tx()
        self.assertEqual(rs.categorize(t), t)
        self.assertEqual(lib("rules").parse_rules("").categorize(t), t)

    def test_categorize_uses_the_first_postings_amount(self):
        rs = rules().parse_rules("when amount < 0 then tag out\nwhen amount > 0 then tag in")
        self.assertEqual(rs.categorize(tx(amount="-1.00 USD")).tags, ("out",))
        self.assertEqual(rs.categorize(tx(amount="1.00 USD")).tags, ("in",))

    def test_categorize_account_needs_exactly_two_postings(self):
        model = lib("model")
        rs = rules().parse_rules("when any then account Expenses:Food tag x")
        three = model.Transaction(date=date(2024, 1, 1), payee="p", narration="", id=1, postings=[
            model.Posting("Assets:Bank", money("-10.00 USD")), model.Posting("Expenses:A", money("6.00 USD")),
            model.Posting("Expenses:B", money("4.00 USD"))])
        out = rs.categorize(three)
        self.assertEqual(out.postings, three.postings)
        self.assertEqual(out.tags, ("x",))
        one = model.Transaction(date=date(2024, 1, 1), payee="p", narration="", postings=[
            model.Posting("Assets:Bank", money("-10.00 USD"))])
        self.assertEqual(rs.categorize(one).postings, one.postings)
        none = model.Transaction(date=date(2024, 1, 1), payee="p", narration="")
        self.assertEqual(rs.categorize(none).tags, ("x",))

    def test_categorize_keeps_unset_attributes_and_merges_tags_sorted(self):
        rs = rules().parse_rules("when any then tag zebra tag Apple")
        out = rs.categorize(tx(tags=["mango", "apple"], flag="!"))
        self.assertEqual(out.tags, ("apple", "mango", "zebra"))
        self.assertEqual((out.payee, out.narration, out.flag), ("CAFE NERO", "card 0412", "!"))
        self.assertIsInstance(out.tags, tuple)


class M08Errors(M08Base):
    BAD = [
        ("payee ~ \"x\" then tag a", 1),                       # no when
        ("When any then tag a", 1),                            # keywords are lower case
        ("when any THEN tag a", 1),
        ("when Payee ~ \"x\" then tag a", 1),
        ("when payee ~ \"x\" tag a", 1),                       # no then
        ("when payee ~ \"x\" then", 1),                        # nothing after then
        ("when any", 1),
        ("when any and payee = \"x\" then tag a", 1),          # any stands alone
        ("when then tag a", 1),
        ("when colour = \"x\" then tag a", 1),                 # unknown field
        ("when payee < \"x\" then tag a", 1),                  # operator not for the field
        ("when amount ~ \"1\" then tag a", 1),
        ("when date ~ 2024-01-01 then tag a", 1),
        ("when payee ~ coffee then tag a", 1),                 # not quoted
        ("when payee ~ \"coffee then tag a", 1),               # unterminated
        ("when payee ~ \"([\" then tag a", 1),                 # bad regex
        ("when amount < abc then tag a", 1),
        ("when amount < 1e3 then tag a", 1),
        ("when amount < 5usd then tag a", 1),
        ("when amount < then tag a", 1),
        ("when date >= 2024-02-30 then tag a", 1),
        ("when date >= 2024-3-1 then tag a", 1),
        ("when any then colour red", 1),                       # unknown action
        ("when any then account expenses:food", 1),
        ("when any then account Expenses::Food", 1),
        ("when any then account Expenses:Food:", 1),
        ("when any then account", 1),
        ("when any then flag x", 1),
        ("when any then flag", 1),
        ("when any then tag", 1),
        ("when any then tag a/b", 1),
        ("when any then tag a account A:B account C:D", 1),     # twice
        ("when any then narration \"a\" narration \"b\"", 1),
        ("when any then flag * flag !", 1),
        ("when any then payee \"a\" payee \"b\"", 1),
        ("when any then payee \"\"", 1),
        ("when any then payee \"   \"", 1),
        ("when any then narration x", 1),
        ("when any then tag a extra", 1),
    ]

    def test_each_mistake_is_a_rules_error_naming_its_line(self):
        for text, _ in self.BAD:
            with self.subTest(text=text):
                e = self.err(text)
                self.assertEqual(e.line, 1)
                self.assertTrue(e.message.startswith("line 1: "), e.message)

    def test_error_class(self):
        e = self.err("nonsense")
        self.assertIsInstance(e, lib("errors").ParseError)
        self.assertEqual(e.code, "parse")
        self.assertEqual(str(e), e.message)

    def test_line_numbers_count_blank_and_comment_lines(self):
        text = '# header\n\nwhen any then tag a\n  # note\n\nwhen payee ~ "(" then tag b\nwhen any then tag c\n'
        self.assertEqual(self.err(text).line, 6)
        self.assertTrue(self.err(text).message.startswith("line 6: "))
        crlf = text.replace("\n", "\r\n")
        self.assertEqual(self.err(crlf).line, 6)

    def test_first_bad_line_is_reported(self):
        text = "when any then tag a\nbad one\nworse one\n"
        self.assertEqual(self.err(text).line, 2)

    def test_valid_edge_rules_are_accepted(self):
        for text in ('when payee ~ "" then tag a', 'when payee = "" then tag a', 'when amount = 0 then tag a',
                     'when amount < -0.001 then tag a', 'when any then narration "tab\there"',
                     'when payee ~ "a|b" and payee !~ "c" and narration != "d" and amount >= 1USD and date <= 2024-12-31 then tag a'):
            with self.subTest(text=text):
                self.assertEqual(len(rules().parse_rules(text)), 1)


if __name__ == "__main__":
    unittest.main()

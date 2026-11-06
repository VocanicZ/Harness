"""Module 01: tallybook.money (and the currency codes it depends on)."""
import unittest

from support import lib, phase

money = lib("money")
currency_mod = lib("currency")
errors = lib("errors")

Money = money.Money
MoneyError = money.MoneyError
CurrencyError = currency_mod.CurrencyError
parse_amount = money.parse_amount
format_minor = money.format_minor
round_div = money.round_div


class M01MoneyValue(unittest.TestCase):
    def test_attributes_and_repr(self):
        m = Money(1250, "USD")
        self.assertEqual((m.minor, m.currency), (1250, "USD"))
        self.assertEqual(repr(m), "Money(1250, 'USD')")
        self.assertEqual(repr(Money(-5, "JPY")), "Money(-5, 'JPY')")

    def test_str(self):
        for minor, cur, text in [(1250, "USD", "12.50 USD"), (-5, "USD", "-0.05 USD"), (1250, "JPY", "1250 JPY"),
                                 (1234, "KWD", "1.234 KWD"), (0, "EUR", "0.00 EUR"), (0, "JPY", "0 JPY")]:
            with self.subTest(text=text):
                self.assertEqual(str(Money(minor, cur)), text)

    def test_amount_str_table(self):
        table = [(1250, "USD", "12.50"), (5, "USD", "0.05"), (-5, "USD", "-0.05"), (0, "USD", "0.00"),
                 (1250, "JPY", "1250"), (-1, "JPY", "-1"), (1234, "KWD", "1.234"), (-7, "KWD", "-0.007"),
                 (7, "KWD", "0.007"), (100000, "KWD", "100.000"), (99, "USD", "0.99"), (100, "USD", "1.00"),
                 (123456789012345678901234567890, "USD", "1234567890123456789012345678.90")]
        for minor, cur, text in table:
            with self.subTest(minor=minor, cur=cur):
                self.assertEqual(Money(minor, cur).amount_str(), text)
                self.assertEqual(format_minor(minor, cur), text)

    def test_no_negative_zero(self):
        self.assertEqual(Money(0, "USD").amount_str(), "0.00")
        self.assertEqual(str(Money.parse("-0.00 USD")), "0.00 USD")
        self.assertEqual(Money.parse("-0 JPY"), Money(0, "JPY"))
        self.assertEqual(Money.parse("-0.000 KWD").amount_str(), "0.000")
        self.assertEqual(-Money(0, "USD"), Money(0, "USD"))
        self.assertEqual(str(-Money(0, "USD")), "0.00 USD")

    def test_immutable(self):
        m = Money(5, "USD")
        with self.assertRaises((AttributeError, TypeError)):
            m.minor = 6
        self.assertEqual(m.minor, 5)

    def test_hashable_and_equality(self):
        self.assertEqual(Money(5, "USD"), Money(5, "USD"))
        self.assertEqual(hash(Money(5, "USD")), hash(Money(5, "USD")))
        self.assertNotEqual(Money(5, "USD"), Money(6, "USD"))
        self.assertNotEqual(Money(5, "USD"), Money(5, "EUR"))
        self.assertFalse(Money(0, "USD") == Money(0, "EUR"))
        self.assertTrue(Money(0, "USD") != Money(0, "EUR"))
        self.assertEqual(len({Money(5, "USD"), Money(5, "USD"), Money(5, "EUR")}), 2)
        self.assertEqual({Money(5, "USD"): "x"}[Money(5, "USD")], "x")

    def test_equality_with_other_types_is_false(self):
        m = Money(5, "USD")
        for other in (5, "5.00 USD", None, (5, "USD"), 5.0):
            with self.subTest(other=other):
                self.assertFalse(m == other)
                self.assertTrue(m != other)

    def test_minor_must_be_an_integer(self):
        for bad in (12.5, 12.0, "1250", None, True, False, (1,)):
            with self.subTest(bad=bad):
                with self.assertRaises(MoneyError):
                    Money(bad, "USD")

    def test_unknown_currency(self):
        for bad in ("usd", "XXX", "USDX", "", " USD", None, 840):
            with self.subTest(bad=bad):
                with self.assertRaises(CurrencyError):
                    Money(1, bad)

    def test_error_classes(self):
        self.assertTrue(issubclass(MoneyError, errors.ValidationError))
        self.assertTrue(issubclass(CurrencyError, errors.ValidationError))
        with self.assertRaises(errors.ValidationError) as cm:
            Money(1.5, "USD")
        self.assertEqual(cm.exception.code, "validation")

    def test_zero_and_exponent(self):
        self.assertEqual(Money.zero("USD"), Money(0, "USD"))
        self.assertEqual(Money.zero("JPY").currency, "JPY")
        self.assertEqual([Money(1, c).exponent for c in ("USD", "JPY", "KWD")], [2, 0, 3])

    def test_huge_values_are_exact(self):
        big = 10 ** 30
        m = Money(big, "USD")
        self.assertEqual((m + Money(1, "USD")).minor, big + 1)
        self.assertEqual((m * 3).minor, 3 * big)
        self.assertEqual(m.scale(1, 3).minor, big // 3)
        self.assertEqual(m.amount_str(), "10000000000000000000000000000.00")
        self.assertEqual(Money.parse(str(m)), m)
        self.assertEqual(Money.parse("99999999999999999999999999999999.99 USD").minor, 10 ** 34 - 1)
        parts = Money(big + 7, "USD").allocate([1, 1, 1])
        self.assertEqual(sum(p.minor for p in parts), big + 7)
        self.assertEqual(Money(-big, "JPY").amount_str(), "-1" + "0" * 30)


class M01MoneyParse(unittest.TestCase):
    def test_parse_amount_accepts(self):
        table = [("12", 1200), ("12.5", 1250), ("12.50", 1250), ("+12.50", 1250), ("-12.50", -1250),
                 ("007.50", 750), ("0", 0), ("0.05", 5), ("-0.05", -5), ("0.00", 0), ("1000000", 100000000),
                 ("123456789012345678901234567890.99", 12345678901234567890123456789099), ("5.0", 500), ("+0", 0),
                 ("-0", 0), ("-0.00", 0), ("+0.00", 0), ("0.9", 90), ("00", 0)]
        for text, minor in table:
            with self.subTest(text=text):
                self.assertEqual(parse_amount(text, "USD"), minor)
                self.assertIs(type(parse_amount(text, "USD")), int)

    def test_parse_amount_decimal_limit(self):
        for text in ("12.505", "12.500", "0.001", "1.234", "-0.100"):
            with self.subTest(text=text):
                with self.assertRaises(MoneyError) as cm:
                    parse_amount(text, "USD")
                self.assertIn(text, str(cm.exception))

    def test_parse_amount_jpy_has_no_decimals(self):
        self.assertEqual(parse_amount("5", "JPY"), 5)
        self.assertEqual(parse_amount("-1500", "JPY"), -1500)
        for text in ("5.0", "5.5", "0.5", "5.", "0.00"):
            with self.subTest(text=text):
                with self.assertRaises(MoneyError) as cm:
                    parse_amount(text, "JPY")
                self.assertIn(text, str(cm.exception))

    def test_parse_amount_kwd_has_three(self):
        self.assertEqual(parse_amount("1.234", "KWD"), 1234)
        self.assertEqual(parse_amount("1.2", "KWD"), 1200)
        self.assertEqual(parse_amount("-0.007", "KWD"), -7)
        self.assertEqual(parse_amount("5", "KWD"), 5000)
        with self.assertRaises(MoneyError):
            parse_amount("1.2345", "KWD")

    def test_parse_amount_refuses_malformed_text(self):
        bad = ["", "-", "+", "1.", ".5", ".", "1,000.00", "1 000", "1_000", "--5", "+-5", "-+5", "1e3", "1E3",
               "NaN", "inf", "-inf", "$5", "5$", " 5", "5 ", "\t5", "5\n", "1.2.3", "- 5", "5-", "0x10", "1/2",
               "1,5", "٣", "١٢", "１２", "12.٥", "abc", "12.50 USD", "(5)"]
        for text in bad:
            with self.subTest(text=text):
                with self.assertRaises(MoneyError) as cm:
                    parse_amount(text, "USD")
                self.assertIn(text, str(cm.exception))

    def test_parse_amount_needs_text(self):
        for bad in (5, 12.5, None, b"5", True):
            with self.subTest(bad=bad):
                with self.assertRaises(MoneyError):
                    parse_amount(bad, "USD")

    def test_parse_amount_unknown_currency(self):
        for code in ("usd", "XXX", ""):
            with self.subTest(code=code):
                with self.assertRaises(CurrencyError) as cm:
                    parse_amount("5", code)
                self.assertIn(code, str(cm.exception))

    def test_money_of(self):
        self.assertEqual(Money.of("12.50", "USD"), Money(1250, "USD"))
        self.assertEqual(Money.of("-3", "JPY"), Money(-3, "JPY"))
        self.assertEqual(Money.of("0.007", "KWD"), Money(7, "KWD"))
        with self.assertRaises(MoneyError):
            Money.of("1.005", "EUR")
        with self.assertRaises(CurrencyError):
            Money.of("1", "eur")

    def test_money_parse_accepts(self):
        table = [("12.50 USD", Money(1250, "USD")), ("-3 JPY", Money(-3, "JPY")), ("0.007 KWD", Money(7, "KWD")),
                 ("+5 EUR", Money(500, "EUR")), ("0 GBP", Money(0, "GBP")), ("-0.00 CHF", Money(0, "CHF")),
                 ("1000000.00 INR", Money(100000000, "INR"))]
        for text, expected in table:
            with self.subTest(text=text):
                self.assertEqual(Money.parse(text), expected)

    def test_money_parse_needs_exactly_one_space(self):
        bad = ["12.50USD", "12.50  USD", " 12.50 USD", "12.50 USD ", "12.50 USD EUR", "12.50", "USD",
               "", " ", "12.50 ", " USD", "12.50\tUSD", "12.50\nUSD", "12.50,USD"]
        for text in bad:
            with self.subTest(text=text):
                with self.assertRaises(MoneyError) as cm:
                    Money.parse(text)
                self.assertIn(text, str(cm.exception))

    def test_money_parse_bad_amount_or_currency(self):
        for text in ("12.505 USD", "1.5 JPY", "1,000 USD", ".5 USD", "1. USD", "-- USD"):
            with self.subTest(text=text):
                with self.assertRaises(MoneyError) as cm:
                    Money.parse(text)
                self.assertIn(text.split(" ")[0], str(cm.exception))
        for text in ("12.50 usd", "12.50 XXX", "12.50 US"):
            with self.subTest(text=text):
                with self.assertRaises(CurrencyError) as cm:
                    Money.parse(text)
                self.assertIn(text.split(" ")[1], str(cm.exception))
        with self.assertRaises(MoneyError):
            Money.parse(None)

    def test_round_trip_through_text(self):
        values = [0, 1, -1, 5, -5, 99, 100, -100, 101, 1250, -123456, 10 ** 20 + 7, -(10 ** 25) - 3]
        for cur in ("USD", "JPY", "KWD", "EUR", "BHD", "KRW"):
            for v in values:
                with self.subTest(cur=cur, v=v):
                    m = Money(v, cur)
                    self.assertEqual(Money.parse(str(m)), m)
                    self.assertEqual(Money.of(m.amount_str(), cur), m)
                    self.assertEqual(parse_amount(format_minor(v, cur), cur), v)

    def test_format_minor_validation(self):
        self.assertEqual(format_minor(-5, "USD"), "-0.05")
        self.assertEqual(format_minor(10 ** 18, "JPY"), "1" + "0" * 18)
        with self.assertRaises(MoneyError):
            format_minor(1.5, "USD")
        with self.assertRaises(MoneyError):
            format_minor("5", "USD")
        with self.assertRaises(CurrencyError):
            format_minor(5, "usd")


class M01MoneyArithmetic(unittest.TestCase):
    def test_add_and_subtract(self):
        a, b = Money(1250, "USD"), Money(75, "USD")
        self.assertEqual(a + b, Money(1325, "USD"))
        self.assertEqual(a - b, Money(1175, "USD"))
        self.assertEqual(b - a, Money(-1175, "USD"))
        self.assertEqual(a - a, Money(0, "USD"))
        self.assertIsInstance(a + b, Money)

    def test_mixed_currencies_refuse_to_add_or_subtract(self):
        a, b = Money(100, "USD"), Money(100, "EUR")
        for op in (lambda: a + b, lambda: a - b):
            with self.assertRaises(MoneyError) as cm:
                op()
            self.assertIn("USD", str(cm.exception))
            self.assertIn("EUR", str(cm.exception))

    def test_mixed_currencies_refuse_ordering(self):
        a, b = Money(100, "USD"), Money(200, "JPY")
        for op in (lambda: a < b, lambda: a <= b, lambda: a > b, lambda: a >= b):
            with self.assertRaises(MoneyError) as cm:
                op()
            self.assertIn("USD", str(cm.exception))
            self.assertIn("JPY", str(cm.exception))
        self.assertFalse(a == b)

    def test_ordering(self):
        small, big = Money(-5, "USD"), Money(7, "USD")
        self.assertTrue(small < big)
        self.assertTrue(small <= big)
        self.assertTrue(big > small)
        self.assertTrue(big >= small)
        self.assertTrue(big <= Money(7, "USD"))
        self.assertTrue(big >= Money(7, "USD"))
        self.assertFalse(big < Money(7, "USD"))
        self.assertFalse(big > Money(7, "USD"))
        self.assertEqual(sorted([big, small, Money(0, "USD")]), [small, Money(0, "USD"), big])
        self.assertEqual(max(big, small), big)

    def test_negation_and_abs(self):
        m = Money(-250, "EUR")
        self.assertEqual(-m, Money(250, "EUR"))
        self.assertEqual(abs(m), Money(250, "EUR"))
        self.assertEqual(abs(Money(250, "EUR")), Money(250, "EUR"))
        self.assertEqual(-(-m), m)

    def test_multiply_by_integer(self):
        m = Money(125, "USD")
        self.assertEqual(m * 3, Money(375, "USD"))
        self.assertEqual(3 * m, Money(375, "USD"))
        self.assertEqual(m * 0, Money(0, "USD"))
        self.assertEqual(m * -2, Money(-250, "USD"))
        self.assertEqual(Money(-125, "USD") * -2, Money(250, "USD"))

    def test_mixing_with_plain_numbers_is_a_type_error(self):
        m = Money(100, "USD")
        for op in (lambda: m * 1.5, lambda: 1.5 * m, lambda: m * m, lambda: m + 5, lambda: 5 + m,
                   lambda: m - 5, lambda: m * "2", lambda: m < 5, lambda: m * None):
            with self.subTest():
                with self.assertRaises(TypeError):
                    op()

    def test_is_zero_and_sign(self):
        self.assertTrue(Money(0, "USD").is_zero())
        self.assertFalse(Money(1, "USD").is_zero())
        self.assertFalse(Money(-1, "USD").is_zero())
        self.assertEqual([Money(v, "JPY").sign() for v in (-50, -1, 0, 1, 50)], [-1, -1, 0, 1, 1])
        self.assertTrue(Money(5, "USD") - Money(5, "USD") == Money(0, "USD"))

    def test_scale_by_ratio(self):
        m = Money(1000, "USD")
        self.assertEqual(m.scale(15, 100), Money(150, "USD"))
        self.assertEqual(m.scale(3), Money(3000, "USD"))
        self.assertEqual(m.scale(0), Money(0, "USD"))
        self.assertEqual(m.scale(1, 3), Money(333, "USD"))
        self.assertEqual(m.scale(2, 3), Money(667, "USD"))
        self.assertEqual(Money(-1000, "USD").scale(1, 3), Money(-333, "USD"))
        self.assertEqual(Money(-1000, "USD").scale(2, 3), Money(-667, "USD"))
        self.assertEqual(m.scale(-1, 4), Money(-250, "USD"))
        self.assertEqual(m.scale(1, -4), Money(-250, "USD"))
        self.assertEqual(m.scale(-1, -4), Money(250, "USD"))
        self.assertEqual(Money(7, "JPY").scale(2, 7), Money(2, "JPY"))
        self.assertEqual(m.scale(105, 100).currency, "USD")

    def test_scale_validation(self):
        m = Money(1000, "USD")
        for args in ((1, 0), (0, 0), (1.5, 2), (1, 2.0), ("1", 2), (None, 1), (True, 1)):
            with self.subTest(args=args):
                with self.assertRaises(MoneyError):
                    m.scale(*args)


class M01Rounding(unittest.TestCase):
    def test_round_div_exact_and_not_a_tie(self):
        table = [(6, 3, 2), (0, 5, 0), (-6, 3, -2), (7, 1, 7), (-7, 1, -7), (5, 3, 2), (-5, 3, -2), (4, 3, 1),
                 (-4, 3, -1), (7, 3, 2), (24999, 10000, 2), (25001, 10000, 3), (-25001, 10000, -3),
                 (-24999, 10000, -2), (1, 3, 0), (-1, 3, 0), (2, 3, 1), (99, 100, 1), (49, 100, 0), (51, 100, 1),
                 (10 ** 30 + 1, 10 ** 30, 1), (3 * 10 ** 30 + 1, 3, 10 ** 30)]
        for n, d, q in table:
            with self.subTest(n=n, d=d):
                self.assertEqual(round_div(n, d), q)
                self.assertIs(type(round_div(n, d)), int)

    @phase("pre")
    def test_round_div_ties_go_away_from_zero(self):
        table = [(1, 2, 1), (3, 2, 2), (5, 2, 3), (7, 2, 4), (-1, 2, -1), (-3, 2, -2), (-5, 2, -3), (-7, 2, -4),
                 (10, 4, 3), (14, 4, 4), (-10, 4, -3), (25, 10, 3), (35, 10, 4), (-25, 10, -3), (5, 10, 1),
                 (2 * 10 ** 30 + 1, 2, 10 ** 30 + 1)]
        for n, d, q in table:
            with self.subTest(n=n, d=d):
                self.assertEqual(round_div(n, d), q)

    @phase("post")
    def test_round_div_ties_go_to_even(self):
        table = [(1, 2, 0), (3, 2, 2), (5, 2, 2), (7, 2, 4), (-1, 2, 0), (-3, 2, -2), (-5, 2, -2), (-7, 2, -4),
                 (10, 4, 2), (14, 4, 4), (-10, 4, -2), (25, 10, 2), (35, 10, 4), (-25, 10, -2), (5, 10, 0),
                 (2 * 10 ** 30 + 1, 2, 10 ** 30)]
        for n, d, q in table:
            with self.subTest(n=n, d=d):
                self.assertEqual(round_div(n, d), q)

    def test_round_div_validation(self):
        for n, d in ((1, 0), (1, -2), (0, 0), (1.0, 2), (1, 2.0), ("1", 2), (None, 2), (True, 2), (1, True)):
            with self.subTest(n=n, d=d):
                with self.assertRaises(MoneyError):
                    round_div(n, d)

    @phase("pre")
    def test_scale_half_minor_units_round_away_from_zero(self):
        for minor, expected in [(1, 1), (3, 2), (5, 3), (7, 4), (-1, -1), (-3, -2), (-5, -3)]:
            with self.subTest(minor=minor):
                self.assertEqual(Money(minor, "USD").scale(1, 2), Money(expected, "USD"))
        self.assertEqual(Money(5, "USD").scale(-1, 2), Money(-3, "USD"))
        self.assertEqual(Money(50, "USD").scale(5, 100), Money(3, "USD"))     # 2.5
        self.assertEqual(Money(250, "JPY").scale(1, 100), Money(3, "JPY"))    # 2.5
        self.assertEqual(Money(-250, "JPY").scale(1, 100), Money(-3, "JPY"))
        self.assertEqual(Money(5, "KWD").scale(1, 2), Money(3, "KWD"))

    @phase("post")
    def test_scale_half_minor_units_round_to_even(self):
        for minor, expected in [(1, 0), (3, 2), (5, 2), (7, 4), (-1, 0), (-3, -2), (-5, -2)]:
            with self.subTest(minor=minor):
                self.assertEqual(Money(minor, "USD").scale(1, 2), Money(expected, "USD"))
        self.assertEqual(Money(5, "USD").scale(-1, 2), Money(-2, "USD"))
        self.assertEqual(Money(50, "USD").scale(5, 100), Money(2, "USD"))     # 2.5
        self.assertEqual(Money(250, "JPY").scale(1, 100), Money(2, "JPY"))    # 2.5
        self.assertEqual(Money(-250, "JPY").scale(1, 100), Money(-2, "JPY"))
        self.assertEqual(Money(5, "KWD").scale(1, 2), Money(2, "KWD"))

    def test_scale_halves_that_are_the_same_either_way(self):
        # 1.5 and 3.5 are halves whose even neighbour is also the one away from zero.
        self.assertEqual(Money(3, "USD").scale(1, 2), Money(2, "USD"))
        self.assertEqual(Money(7, "USD").scale(1, 2), Money(4, "USD"))
        self.assertEqual(Money(-3, "USD").scale(1, 2), Money(-2, "USD"))
        self.assertEqual(Money(15, "USD").scale(1, 10), Money(2, "USD"))


class M01Allocate(unittest.TestCase):
    @staticmethod
    def minors(m, weights):
        return [p.minor for p in m.allocate(weights)]

    def test_equal_parts_leave_the_spare_to_the_earlier(self):
        self.assertEqual(self.minors(Money(100, "USD"), [1, 1, 1]), [34, 33, 33])
        self.assertEqual(self.minors(Money(101, "USD"), [1, 1, 1]), [34, 34, 33])
        self.assertEqual(self.minors(Money(1, "USD"), [1, 1]), [1, 0])
        self.assertEqual(self.minors(Money(2, "USD"), [1, 1, 1]), [1, 1, 0])
        self.assertEqual(self.minors(Money(1, "USD"), [1, 1, 1, 1]), [1, 0, 0, 0])
        self.assertEqual(self.minors(Money(10, "USD"), [1, 1, 1, 1, 1, 1, 1]), [2, 2, 2, 1, 1, 1, 1])

    def test_ties_on_remainder_go_to_the_earlier_index(self):
        self.assertEqual(self.minors(Money(10, "USD"), [3, 1]), [8, 2])
        self.assertEqual(self.minors(Money(10, "USD"), [1, 3]), [3, 7])
        self.assertEqual(self.minors(Money(5, "USD"), [1, 1]), [3, 2])
        self.assertEqual(self.minors(Money(3, "USD"), [1, 1]), [2, 1])

    def test_largest_remainder_not_largest_weight(self):
        self.assertEqual(self.minors(Money(7, "USD"), [5, 3, 1]), [4, 2, 1])
        self.assertEqual(self.minors(Money(5, "USD"), [1, 2, 2]), [1, 2, 2])
        self.assertEqual(self.minors(Money(10, "USD"), [1, 2]), [3, 7])
        self.assertEqual(self.minors(Money(100, "USD"), [1, 1, 2]), [25, 25, 50])
        self.assertEqual(self.minors(Money(11, "USD"), [3, 3, 4]), [3, 3, 5])
        self.assertEqual(self.minors(Money(19, "USD"), [1, 4, 5]), [2, 8, 9])

    def test_zero_weights_get_nothing(self):
        self.assertEqual(self.minors(Money(5, "USD"), [0, 1, 1]), [0, 3, 2])
        self.assertEqual(self.minors(Money(5, "USD"), [1, 0, 0]), [5, 0, 0])
        self.assertEqual(self.minors(Money(7, "USD"), [0, 0, 3]), [0, 0, 7])
        self.assertEqual(self.minors(Money(100, "USD"), [1, 0, 1, 0, 1]), [34, 0, 33, 0, 33])

    def test_negative_amounts_mirror_positive(self):
        self.assertEqual(self.minors(Money(-100, "USD"), [1, 1, 1]), [-34, -33, -33])
        self.assertEqual(self.minors(Money(-10, "USD"), [3, 1]), [-8, -2])
        self.assertEqual(self.minors(Money(-5, "USD"), [0, 1, 1]), [0, -3, -2])
        self.assertEqual(self.minors(Money(-1, "USD"), [1, 1]), [-1, 0])

    def test_zero_and_single_weight(self):
        self.assertEqual(self.minors(Money(0, "USD"), [1, 2, 3]), [0, 0, 0])
        self.assertEqual(self.minors(Money(1234, "USD"), [1]), [1234])
        self.assertEqual(self.minors(Money(-1234, "USD"), [7]), [-1234])
        self.assertEqual(self.minors(Money(1234, "USD"), [0, 5]), [0, 1234])

    def test_weights_are_scale_free(self):
        for amount in (1, 10, 99, 100, 101, 12345):
            with self.subTest(amount=amount):
                self.assertEqual(self.minors(Money(amount, "USD"), [1, 1, 2]),
                                 self.minors(Money(amount, "USD"), [50, 50, 100]))
                self.assertEqual(self.minors(Money(amount, "USD"), [3, 5]),
                                 self.minors(Money(amount, "USD"), [30, 50]))

    def test_result_shape(self):
        parts = Money(100, "JPY").allocate([1, 1, 1])
        self.assertIsInstance(parts, list)
        self.assertEqual(len(parts), 3)
        self.assertTrue(all(isinstance(p, Money) and p.currency == "JPY" for p in parts))
        self.assertEqual(Money(1000, "KWD").allocate([1, 2]), [Money(333, "KWD"), Money(667, "KWD")])

    def test_parts_always_add_up_and_stay_within_one_unit(self):
        weight_sets = [[1], [1, 1], [1, 2, 3], [5, 3, 1], [1, 1, 1, 1, 1, 1, 1], [0, 3, 0, 4], [7, 7, 7], [1, 99],
                       [2, 3, 5, 7, 11], [100, 1, 1]]
        for amount in list(range(-60, 61)) + [999, -999, 10 ** 12 + 1, -(10 ** 12) - 1]:
            for weights in weight_sets:
                with self.subTest(amount=amount, weights=weights):
                    parts = self.minors(Money(amount, "USD"), weights)
                    self.assertEqual(sum(parts), amount)
                    total = sum(weights)
                    for part, w in zip(parts, weights):
                        self.assertLess(abs(part * total - amount * w), total)
                        if w == 0:
                            self.assertEqual(part, 0)
                        self.assertTrue(part == 0 or (part > 0) == (amount > 0))

    def test_invalid_weights(self):
        m = Money(100, "USD")
        for weights in ([], [0], [0, 0, 0], [-1, 2], [1, -1], [1.5, 1], [1, "2"], [None], [True, 1]):
            with self.subTest(weights=weights):
                with self.assertRaises(MoneyError):
                    m.allocate(weights)

    def test_allocation_does_not_depend_on_the_rounding_rule(self):
        # Ten dollars three ways, and an amount whose shares are exact halves: leftovers, not rounding.
        self.assertEqual(self.minors(Money(1000, "USD"), [1, 1, 1]), [334, 333, 333])
        self.assertEqual(self.minors(Money(5, "USD"), [1, 1]), [3, 2])
        self.assertEqual(self.minors(Money(15, "USD"), [1, 1]), [8, 7])
        self.assertEqual(self.minors(Money(-15, "USD"), [1, 1]), [-8, -7])
        self.assertEqual(self.minors(Money(25, "USD"), [1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), [3, 3, 3, 3, 3, 2, 2, 2, 2, 2])


if __name__ == "__main__":
    unittest.main()

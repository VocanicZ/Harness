"""Module 02: tallybook.currency (the currency table and dated exchange rates)."""
import dataclasses
import unittest
from datetime import date
from fractions import Fraction

from support import lib, phase

cur = lib("currency")
errors = lib("errors")
money = lib("money")

CurrencyError = cur.CurrencyError
RateTable = cur.RateTable
Money = money.Money

TABLE = [("USD", 2, "US Dollar", "$"), ("EUR", 2, "Euro", "€"), ("GBP", 2, "British Pound", "£"),
         ("JPY", 0, "Japanese Yen", "¥"), ("CHF", 2, "Swiss Franc", "CHF"),
         ("CAD", 2, "Canadian Dollar", "CA$"), ("AUD", 2, "Australian Dollar", "A$"),
         ("KWD", 3, "Kuwaiti Dinar", "KD"), ("SEK", 2, "Swedish Krona", "kr"), ("INR", 2, "Indian Rupee", "₹"),
         ("NZD", 2, "New Zealand Dollar", "NZ$"), ("NOK", 2, "Norwegian Krone", "kr"),
         ("KRW", 0, "South Korean Won", "₩"), ("BHD", 3, "Bahraini Dinar", "BD"),
         ("CNY", 2, "Chinese Yuan", "CN¥"), ("MXN", 2, "Mexican Peso", "MX$")]


def d(text):
    y, m, day = map(int, text.split("-"))
    return date(y, m, day)


class M02CurrencyTable(unittest.TestCase):
    def test_table_contents(self):
        for code, exponent, name, symbol in TABLE:
            with self.subTest(code=code):
                c = cur.CURRENCIES[code]
                self.assertEqual((c.code, c.exponent, c.name, c.symbol), (code, exponent, name, symbol))

    def test_table_is_keyed_by_code(self):
        self.assertIsInstance(cur.CURRENCIES, dict)
        for code, c in cur.CURRENCIES.items():
            with self.subTest(code=code):
                self.assertEqual(code, c.code)
                self.assertIsInstance(c, cur.Currency)
                self.assertRegex(code, r"^[A-Z]{3}$")

    def test_currency_is_immutable_and_hashable(self):
        c = cur.currency("USD")
        with self.assertRaises((AttributeError, TypeError)):
            c.exponent = 3
        self.assertEqual(c, cur.Currency("USD", 2, "US Dollar", "$"))
        self.assertEqual(len({c, cur.currency("USD"), cur.currency("EUR")}), 2)

    def test_lookup(self):
        self.assertEqual(cur.currency("KWD").exponent, 3)
        self.assertEqual(cur.currency("JPY").exponent, 0)
        self.assertEqual(cur.currency("EUR"), cur.CURRENCIES["EUR"])
        self.assertEqual(cur.currency("GBP").symbol, "£")

    def test_unknown_codes_name_the_code(self):
        for bad in ("usd", "Usd", " USD", "USD ", "USDX", "US", "", "XXX", "ZZZ", "U$D"):
            with self.subTest(code=bad):
                with self.assertRaises(CurrencyError) as cm:
                    cur.currency(bad)
                self.assertIn(bad, str(cm.exception))
                self.assertEqual(cm.exception.message, str(cm.exception))

    def test_non_string_codes_are_unknown(self):
        for bad in (None, 840, b"USD", ("USD",)):
            with self.subTest(code=bad):
                with self.assertRaises(CurrencyError):
                    cur.currency(bad)

    def test_error_is_a_validation_error(self):
        self.assertTrue(issubclass(CurrencyError, errors.ValidationError))
        with self.assertRaises(errors.ValidationError) as cm:
            cur.currency("nope")
        self.assertEqual(cm.exception.code, "validation")


class M02RateSet(unittest.TestCase):
    def setUp(self):
        self.rt = RateTable()

    def test_new_table_is_empty(self):
        self.assertEqual(self.rt.entries(), [])
        with self.assertRaises(CurrencyError):
            self.rt.rate("USD", "EUR", date(2024, 3, 1))

    def test_set_stores_an_exact_fraction(self):
        self.assertIsNone(self.rt.set("USD", "EUR", "0.9215", d("2024-03-01")))
        r = self.rt.rate("USD", "EUR", d("2024-03-15"))
        self.assertIsInstance(r, Fraction)
        self.assertEqual(r, Fraction(1843, 2000))
        self.rt.set("EUR", "GBP", "0.1", d("2024-03-01"))
        self.assertEqual(self.rt.rate("EUR", "GBP", d("2024-03-01")), Fraction(1, 10))

    def test_valid_rate_texts(self):
        table = [("150.5", Fraction(301, 2)), ("0.9215", Fraction(1843, 2000)), ("1", Fraction(1)),
                 ("0.00000001", Fraction(1, 10 ** 8)), ("12345.12345678", Fraction(1234512345678, 10 ** 8)),
                 ("007.5", Fraction(15, 2)), ("2.50", Fraction(5, 2)), ("100", Fraction(100)),
                 ("0.12345678", Fraction(12345678, 10 ** 8)), ("1.00000000", Fraction(1))]
        for text, expected in table:
            with self.subTest(text=text):
                rt = RateTable()
                rt.set("USD", "JPY", text, d("2024-01-01"))
                self.assertEqual(rt.rate("USD", "JPY", d("2024-01-01")), expected)

    def test_invalid_rate_texts_name_the_text(self):
        bad = ["0", "0.0", "0.00000000", "-1.5", "+1.5", ".5", "1.", "1,5", "1e-3", "1E3", "", "abc", " 1.5", "1.5 ",
               "1.123456789", "1.000000000", "1_0", "NaN", "inf", "1/2", "0x1", "٣"]
        for text in bad:
            with self.subTest(text=text):
                with self.assertRaises(CurrencyError) as cm:
                    self.rt.set("USD", "EUR", text, d("2024-01-01"))
                self.assertIn(text, str(cm.exception))
        self.assertEqual(self.rt.entries(), [])

    def test_rate_must_be_text(self):
        for bad in (0.9, 2, Fraction(1, 2), None, b"1.5"):
            with self.subTest(bad=bad):
                with self.assertRaises(CurrencyError):
                    self.rt.set("USD", "EUR", bad, d("2024-01-01"))

    def test_same_currency_and_unknown_currency(self):
        with self.assertRaises(CurrencyError):
            self.rt.set("USD", "USD", "1", d("2024-01-01"))
        for src, dst in (("usd", "EUR"), ("USD", "eur"), ("USD", "XXX"), ("XXX", "EUR"), (None, "EUR")):
            with self.subTest(src=src, dst=dst):
                with self.assertRaises(CurrencyError):
                    self.rt.set(src, dst, "1.5", d("2024-01-01"))
        self.assertEqual(self.rt.entries(), [])

    def test_day_must_be_a_date(self):
        for bad in ("2024-03-01", None, 20240301, (2024, 3, 1)):
            with self.subTest(bad=bad):
                with self.assertRaises(CurrencyError):
                    self.rt.set("USD", "EUR", "0.9", bad)

    def test_setting_the_same_day_replaces(self):
        self.rt.set("USD", "EUR", "0.9", d("2024-03-01"))
        self.rt.set("USD", "EUR", "0.95", d("2024-03-01"))
        self.assertEqual(self.rt.rate("USD", "EUR", d("2024-03-01")), Fraction(19, 20))
        self.assertEqual(self.rt.entries(), [("USD", "EUR", d("2024-03-01"), Fraction(19, 20))])

    def test_tables_are_independent(self):
        other = RateTable()
        self.rt.set("USD", "EUR", "0.9", d("2024-03-01"))
        self.assertEqual(other.entries(), [])


class M02RateLookup(unittest.TestCase):
    def setUp(self):
        self.rt = RateTable()
        self.rt.set("USD", "EUR", "0.5", d("2024-03-01"))
        self.rt.set("USD", "EUR", "0.75", d("2024-03-10"))

    def test_latest_rate_on_or_before(self):
        table = [("2024-03-01", Fraction(1, 2)), ("2024-03-02", Fraction(1, 2)), ("2024-03-09", Fraction(1, 2)),
                 ("2024-03-10", Fraction(3, 4)), ("2024-03-11", Fraction(3, 4)), ("2030-01-01", Fraction(3, 4))]
        for day, expected in table:
            with self.subTest(day=day):
                self.assertEqual(self.rt.rate("USD", "EUR", d(day)), expected)

    def test_before_the_first_rate_is_an_error(self):
        with self.assertRaises(CurrencyError) as cm:
            self.rt.rate("USD", "EUR", d("2024-02-29"))
        self.assertEqual(str(cm.exception), "no rate USD -> EUR on 2024-02-29")

    def test_inverse_of_the_latest_opposite_rate(self):
        self.assertEqual(self.rt.rate("EUR", "USD", d("2024-03-10")), Fraction(4, 3))
        self.assertEqual(self.rt.rate("EUR", "USD", d("2024-03-05")), Fraction(2))
        self.assertEqual(self.rt.rate("EUR", "USD", d("2024-03-01")), Fraction(2))
        with self.assertRaises(CurrencyError) as cm:
            self.rt.rate("EUR", "USD", d("2024-02-01"))
        self.assertEqual(str(cm.exception), "no rate EUR -> USD on 2024-02-01")

    def test_inverse_is_exact(self):
        rt = RateTable()
        rt.set("USD", "JPY", "0.3", d("2024-01-01"))
        self.assertEqual(rt.rate("JPY", "USD", d("2024-01-01")), Fraction(10, 3))
        self.assertEqual(rt.rate("USD", "JPY", d("2024-01-01")) * rt.rate("JPY", "USD", d("2024-01-01")), 1)

    def test_a_direct_rate_beats_the_inverse_even_when_older(self):
        self.rt.set("EUR", "USD", "1.5", d("2024-03-02"))
        self.assertEqual(self.rt.rate("EUR", "USD", d("2024-03-10")), Fraction(3, 2))
        self.assertEqual(self.rt.rate("EUR", "USD", d("2024-03-20")), Fraction(3, 2))
        # before the direct rate exists, the inverse still answers
        self.assertEqual(self.rt.rate("EUR", "USD", d("2024-03-01")), Fraction(2))
        # and the forward direction still reads its own entries
        self.assertEqual(self.rt.rate("USD", "EUR", d("2024-03-10")), Fraction(3, 4))

    def test_no_going_through_a_third_currency(self):
        self.rt.set("EUR", "GBP", "0.8", d("2024-03-01"))
        for src, dst in (("USD", "GBP"), ("GBP", "USD")):
            with self.subTest(src=src, dst=dst):
                with self.assertRaises(CurrencyError) as cm:
                    self.rt.rate(src, dst, d("2024-03-15"))
                self.assertEqual(str(cm.exception), "no rate %s -> %s on 2024-03-15" % (src, dst))

    def test_same_currency_is_one(self):
        self.assertEqual(self.rt.rate("GBP", "GBP", d("1999-01-01")), Fraction(1))
        self.assertEqual(self.rt.rate("USD", "USD", d("2024-03-10")), 1)
        self.assertIsInstance(self.rt.rate("JPY", "JPY", d("2024-03-10")), Fraction)
        with self.assertRaises(CurrencyError):
            self.rt.rate("XXX", "XXX", d("2024-03-10"))

    def test_lookup_validates_arguments(self):
        for args in (("usd", "EUR", d("2024-03-10")), ("USD", "XXX", d("2024-03-10")),
                     ("USD", "EUR", "2024-03-10"), ("USD", "EUR", None)):
            with self.subTest(args=args):
                with self.assertRaises(CurrencyError):
                    self.rt.rate(*args)

    def test_entries_are_sorted(self):
        self.rt.set("EUR", "GBP", "0.8", d("2024-02-01"))
        self.rt.set("AUD", "USD", "0.65", d("2024-05-01"))
        self.rt.set("USD", "EUR", "0.6", d("2024-01-01"))
        self.assertEqual(self.rt.entries(), [
            ("AUD", "USD", d("2024-05-01"), Fraction(13, 20)),
            ("EUR", "GBP", d("2024-02-01"), Fraction(4, 5)),
            ("USD", "EUR", d("2024-01-01"), Fraction(3, 5)),
            ("USD", "EUR", d("2024-03-01"), Fraction(1, 2)),
            ("USD", "EUR", d("2024-03-10"), Fraction(3, 4))])
        self.assertIsInstance(self.rt.entries(), list)

    def test_entries_do_not_include_inverses(self):
        self.assertEqual(len(self.rt.entries()), 2)
        self.assertTrue(all(e[:2] == ("USD", "EUR") for e in self.rt.entries()))

    def test_remove_falls_back_to_the_earlier_rate(self):
        self.assertIsNone(self.rt.remove("USD", "EUR", d("2024-03-10")))
        self.assertEqual(self.rt.rate("USD", "EUR", d("2024-03-20")), Fraction(1, 2))
        self.assertEqual(len(self.rt.entries()), 1)
        self.rt.remove("USD", "EUR", d("2024-03-01"))
        self.assertEqual(self.rt.entries(), [])
        with self.assertRaises(CurrencyError):
            self.rt.rate("USD", "EUR", d("2024-03-20"))

    def test_remove_must_match_exactly(self):
        for args in (("USD", "EUR", d("2024-03-05")), ("EUR", "USD", d("2024-03-01")), ("USD", "GBP", d("2024-03-01"))):
            with self.subTest(args=args):
                with self.assertRaises(CurrencyError) as cm:
                    self.rt.remove(*args)
                self.assertIn(args[0], str(cm.exception))
                self.assertIn(args[1], str(cm.exception))
                self.assertIn(args[2].isoformat(), str(cm.exception))
        self.assertEqual(len(self.rt.entries()), 2)
        self.assertEqual(str(self._remove_error()), "no rate USD -> EUR set on 2024-03-05")

    def _remove_error(self):
        try:
            self.rt.remove("USD", "EUR", d("2024-03-05"))
        except CurrencyError as exc:
            return exc


class M02Convert(unittest.TestCase):
    def setUp(self):
        self.rt = RateTable()
        self.day = d("2024-03-01")

    def conv(self, text, dst, rate):
        m = Money.parse(text)
        rt = RateTable()
        rt.set(m.currency, dst, rate, self.day)
        return rt.convert(m, dst, self.day)

    def test_usd_to_jpy_drops_the_decimals(self):
        self.assertEqual(self.conv("100.00 USD", "JPY", "150.5"), Money(15050, "JPY"))
        self.assertEqual(self.conv("1.00 USD", "JPY", "151.5"), Money(152, "JPY"))
        self.assertEqual(self.conv("12.34 USD", "JPY", "100"), Money(1234, "JPY"))
        self.assertEqual(self.conv("0.01 USD", "JPY", "100"), Money(1, "JPY"))
        self.assertEqual(self.conv("2.50 USD", "JPY", "150.5"), Money(376, "JPY"))   # 376.25

    def test_kwd_to_usd_loses_a_decimal(self):
        self.assertEqual(self.conv("1.000 KWD", "USD", "3.25"), Money(325, "USD"))
        self.assertEqual(self.conv("1.234 KWD", "USD", "3.25"), Money(401, "USD"))   # 401.05
        self.assertEqual(self.conv("10.000 KWD", "USD", "3.25"), Money(3250, "USD"))
        self.assertEqual(self.conv("0.001 KWD", "USD", "3.25"), Money(0, "USD"))     # 0.325 cents

    def test_usd_to_kwd_gains_a_decimal(self):
        self.assertEqual(self.conv("3.25 USD", "KWD", "0.3077"), Money(1000, "KWD"))  # 0.99999...
        self.assertEqual(self.conv("1.00 USD", "KWD", "0.5"), Money(500, "KWD"))
        self.assertEqual(self.conv("0.01 USD", "KWD", "0.3"), Money(3, "KWD"))

    def test_jpy_to_usd(self):
        self.assertEqual(self.conv("1500 JPY", "USD", "0.0067"), Money(1005, "USD"))
        self.assertEqual(self.conv("1 JPY", "USD", "0.0067"), Money(1, "USD"))        # 0.67 cents
        self.assertEqual(self.conv("100 JPY", "USD", "0.0067"), Money(67, "USD"))
        self.assertEqual(self.conv("1 JPY", "USD", "0.004"), Money(0, "USD"))

    def test_same_exponent_pairs(self):
        self.assertEqual(self.conv("100.00 USD", "EUR", "0.9215"), Money(9215, "EUR"))
        self.assertEqual(self.conv("0.99 USD", "EUR", "0.9215"), Money(91, "EUR"))    # 91.2285
        self.assertEqual(self.conv("100 JPY", "KRW", "9.5"), Money(950, "KRW"))
        self.assertEqual(self.conv("1.000 KWD", "BHD", "1.2"), Money(1200, "BHD"))

    def test_negative_amounts_are_symmetric(self):
        self.assertEqual(self.conv("-100.00 USD", "JPY", "150.5"), Money(-15050, "JPY"))
        self.assertEqual(self.conv("-1.234 KWD", "USD", "3.25"), Money(-401, "USD"))
        self.assertEqual(self.conv("-1500 JPY", "USD", "0.0067"), Money(-1005, "USD"))
        self.assertEqual(self.conv("-0.99 USD", "EUR", "0.9215"), Money(-91, "EUR"))

    def test_zero_converts_to_zero(self):
        self.assertEqual(self.conv("0.00 USD", "JPY", "150.5"), Money(0, "JPY"))
        self.assertEqual(self.conv("0 JPY", "KWD", "0.02"), Money(0, "KWD"))

    @phase("pre")
    def test_halves_round_away_from_zero(self):
        self.assertEqual(self.conv("1.00 USD", "JPY", "150.5"), Money(151, "JPY"))
        self.assertEqual(self.conv("-1.00 USD", "JPY", "150.5"), Money(-151, "JPY"))
        self.assertEqual(self.conv("1.00 USD", "EUR", "0.125"), Money(13, "EUR"))      # 12.5 cents
        self.assertEqual(self.conv("-1.00 USD", "EUR", "0.125"), Money(-13, "EUR"))
        self.assertEqual(self.conv("0.005 KWD", "USD", "5"), Money(3, "USD"))          # 2.5 cents
        self.assertEqual(self.conv("2.50 USD", "JPY", "151"), Money(378, "JPY"))       # 377.5
        self.assertEqual(self.conv("3.00 USD", "JPY", "150.5"), Money(452, "JPY"))     # 451.5

    @phase("post")
    def test_halves_round_to_even(self):
        self.assertEqual(self.conv("1.00 USD", "JPY", "150.5"), Money(150, "JPY"))
        self.assertEqual(self.conv("-1.00 USD", "JPY", "150.5"), Money(-150, "JPY"))
        self.assertEqual(self.conv("1.00 USD", "EUR", "0.125"), Money(12, "EUR"))      # 12.5 cents
        self.assertEqual(self.conv("-1.00 USD", "EUR", "0.125"), Money(-12, "EUR"))
        self.assertEqual(self.conv("0.005 KWD", "USD", "5"), Money(2, "USD"))          # 2.5 cents
        self.assertEqual(self.conv("2.50 USD", "JPY", "151"), Money(378, "JPY"))       # 377.5
        self.assertEqual(self.conv("3.00 USD", "JPY", "150.5"), Money(452, "JPY"))     # 451.5

    def test_halves_that_are_not_ties_or_agree_in_both_rules(self):
        self.assertEqual(self.conv("1.00 USD", "JPY", "151.5"), Money(152, "JPY"))     # 151.5, even neighbour 152
        self.assertEqual(self.conv("1.00 USD", "JPY", "150.51"), Money(151, "JPY"))
        self.assertEqual(self.conv("1.00 USD", "JPY", "150.49"), Money(150, "JPY"))
        self.assertEqual(self.conv("1.00 USD", "EUR", "0.135"), Money(14, "EUR"))      # 13.5 cents

    def test_same_currency_is_returned_unchanged(self):
        m = Money(12345, "USD")
        self.assertEqual(self.rt.convert(m, "USD", self.day), m)
        self.assertEqual(self.rt.convert(Money(-7, "JPY"), "JPY", self.day), Money(-7, "JPY"))
        with self.assertRaises(CurrencyError):
            self.rt.convert(m, "usd", self.day)

    def test_conversion_uses_the_rate_of_the_day(self):
        self.rt.set("USD", "JPY", "100", d("2024-01-01"))
        self.rt.set("USD", "JPY", "150", d("2024-06-01"))
        m = Money(1000, "USD")
        self.assertEqual(self.rt.convert(m, "JPY", d("2024-03-01")), Money(1000, "JPY"))
        self.assertEqual(self.rt.convert(m, "JPY", d("2024-06-01")), Money(1500, "JPY"))
        with self.assertRaises(CurrencyError) as cm:
            self.rt.convert(m, "JPY", d("2023-12-31"))
        self.assertEqual(str(cm.exception), "no rate USD -> JPY on 2023-12-31")

    def test_conversion_through_the_inverse_rate(self):
        self.rt.set("JPY", "USD", "0.01", self.day)
        self.assertEqual(self.rt.convert(Money(1000, "USD"), "JPY", self.day), Money(1000, "JPY"))
        self.rt.set("EUR", "USD", "1.25", self.day)
        self.assertEqual(self.rt.convert(Money(1000, "USD"), "EUR", self.day), Money(800, "EUR"))
        self.assertEqual(self.rt.convert(Money(1000, "EUR"), "USD", self.day), Money(1250, "USD"))

    def test_conversion_errors(self):
        with self.assertRaises(CurrencyError) as cm:
            self.rt.convert(Money(100, "USD"), "EUR", d("2024-03-01"))
        self.assertEqual(str(cm.exception), "no rate USD -> EUR on 2024-03-01")
        for bad in (100, "1.00 USD", None, 1.5):
            with self.subTest(bad=bad):
                with self.assertRaises(CurrencyError):
                    self.rt.convert(bad, "EUR", self.day)
        with self.assertRaises(CurrencyError):
            self.rt.convert(Money(100, "USD"), "XXX", self.day)

    def test_big_amounts_stay_exact(self):
        self.rt.set("USD", "EUR", "0.12345678", self.day)
        big = Money(10 ** 24, "USD")
        self.assertEqual(self.rt.convert(big, "EUR", self.day), Money(10 ** 24 * 12345678 // 10 ** 8, "EUR"))


if __name__ == "__main__":
    unittest.main()

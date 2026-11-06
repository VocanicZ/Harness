"""Module 03: tallybook.dates (strict dates, month arithmetic, periods)."""
import unittest
from datetime import date, timedelta

from support import lib

dates = lib("dates")
errors = lib("errors")

DateError = dates.DateError
Period = dates.Period
parse_date = dates.parse_date
format_date = dates.format_date
add_months = dates.add_months
last_day = dates.last_day
periods = dates.periods


def d(text):
    y, m, day = map(int, text.split("-"))
    return date(y, m, day)


def P(text):
    return Period.parse(text)


class M03ParseDate(unittest.TestCase):
    def test_valid_dates(self):
        for text, expected in [("2024-03-01", date(2024, 3, 1)), ("2024-02-29", date(2024, 2, 29)),
                               ("2000-02-29", date(2000, 2, 29)), ("9999-12-31", date(9999, 12, 31)),
                               ("0001-01-01", date(1, 1, 1)), ("2023-12-31", date(2023, 12, 31)),
                               ("1999-01-09", date(1999, 1, 9)), ("2024-10-10", date(2024, 10, 10))]:
            with self.subTest(text=text):
                result = parse_date(text)
                self.assertEqual(result, expected)
                self.assertIs(type(result), date)

    def test_days_that_do_not_exist(self):
        for text in ("2023-02-29", "1900-02-29", "2100-02-29", "2024-02-30", "2024-04-31", "2024-06-31",
                     "2024-09-31", "2024-11-31", "2024-13-01", "2024-00-10", "2024-03-00", "2024-03-32",
                     "2024-99-99", "0000-01-01"):
            with self.subTest(text=text):
                with self.assertRaises(DateError) as cm:
                    parse_date(text)
                self.assertIn(text, str(cm.exception))

    def test_malformed_text(self):
        bad = ["2024-3-1", "2024-03-1", "2024-3-01", "24-03-01", "20240-03-01", "20240301", "2024/03/01",
               "2024.03.01", "01-03-2024", "03/01/2024", " 2024-03-01", "2024-03-01 ", "2024-03-01\n", "\t2024-03-01",
               "2024-03-01T10:00", "2024-03-01 10:00", "2024-03-01Z", "2024-03", "2024", "", " ", "-2024-03-01",
               "+2024-03-01", "2024--03-01", "2024-03-01-", "March 1 2024", "2024-Mar-01", "today", "now",
               "٢٠٢٤-٠٣-٠١", "２０２４-０３-０１"]
        for text in bad:
            with self.subTest(text=text):
                with self.assertRaises(DateError) as cm:
                    parse_date(text)
                self.assertIn(text, str(cm.exception))

    def test_input_must_be_text(self):
        for bad in (None, 20240301, date(2024, 3, 1), b"2024-03-01", 2024.0, ("2024", "03", "01")):
            with self.subTest(bad=bad):
                with self.assertRaises(DateError):
                    parse_date(bad)

    def test_error_class(self):
        self.assertTrue(issubclass(DateError, errors.ParseError))
        with self.assertRaises(errors.ParseError) as cm:
            parse_date("nope")
        self.assertEqual(cm.exception.code, "parse")
        self.assertIn("nope", cm.exception.message)

    def test_format_date(self):
        self.assertEqual(format_date(date(2024, 3, 5)), "2024-03-05")
        self.assertEqual(format_date(date(999, 1, 2)), "0999-01-02")
        self.assertEqual(format_date(date(1, 1, 1)), "0001-01-01")
        self.assertEqual(format_date(date(9999, 12, 31)), "9999-12-31")
        for bad in ("2024-03-05", None, 20240305, (2024, 3, 5)):
            with self.subTest(bad=bad):
                with self.assertRaises(DateError):
                    format_date(bad)

    def test_round_trip(self):
        day = date(1, 1, 1)
        seen = 0
        while day < date(2100, 1, 1):
            self.assertEqual(parse_date(format_date(day)), day)
            seen += 1
            day += timedelta(days=211)
        self.assertGreater(seen, 100)
        for day in (date(2024, 2, 29), date(1999, 12, 31), date(9999, 12, 31), date(1, 1, 1), date(2000, 2, 29)):
            self.assertEqual(parse_date(format_date(day)), day)


class M03MonthArithmetic(unittest.TestCase):
    def test_last_day(self):
        table = [(2024, 2, 29), (2023, 2, 28), (1900, 2, 28), (2000, 2, 29), (2100, 2, 28), (2024, 1, 31),
                 (2024, 3, 31), (2024, 4, 30), (2024, 5, 31), (2024, 6, 30), (2024, 7, 31), (2024, 8, 31),
                 (2024, 9, 30), (2024, 10, 31), (2024, 11, 30), (2024, 12, 31), (9999, 12, 31), (1, 2, 28),
                 (4, 2, 29)]
        for year, month, expected in table:
            with self.subTest(year=year, month=month):
                result = last_day(year, month)
                self.assertEqual(result, expected)
                self.assertIs(type(result), int)

    def test_last_day_validation(self):
        for year, month in ((2024, 0), (2024, 13), (2024, -1), (0, 1), (10000, 1), (-5, 1), (2024.0, 1),
                            (2024, 1.0), ("2024", 1), (2024, "1"), (None, 1), (2024, None), (True, 1), (2024, True)):
            with self.subTest(year=year, month=month):
                with self.assertRaises(DateError):
                    last_day(year, month)

    def test_add_months_clamps_to_the_end_of_the_month(self):
        table = [("2024-01-31", 1, "2024-02-29"), ("2023-01-31", 1, "2023-02-28"), ("2024-03-31", -1, "2024-02-29"),
                 ("2024-02-29", 12, "2025-02-28"), ("2024-02-29", 48, "2028-02-29"), ("2024-01-15", 0, "2024-01-15"),
                 ("2024-11-30", 3, "2025-02-28"), ("2024-12-15", 1, "2025-01-15"), ("2024-01-15", -1, "2023-12-15"),
                 ("2024-05-31", 1, "2024-06-30"), ("2024-01-31", 25, "2026-02-28"), ("2024-08-31", 6, "2025-02-28"),
                 ("2024-01-30", 1, "2024-02-29"), ("2024-01-29", 1, "2024-02-29"), ("2023-01-29", 1, "2023-02-28"),
                 ("2024-10-31", -2, "2024-08-31"), ("2024-10-31", -1, "2024-09-30"), ("2024-03-15", -15, "2022-12-15"),
                 ("2024-02-29", -12, "2023-02-28"), ("2024-02-29", 1, "2024-03-29"), ("2024-06-30", 6, "2024-12-30"),
                 ("2024-06-30", 1200, "2124-06-30"), ("2024-01-01", -24, "2022-01-01"), ("2024-12-31", 2, "2025-02-28")]
        for start, n, expected in table:
            with self.subTest(start=start, n=n):
                result = add_months(d(start), n)
                self.assertEqual(result, d(expected))
                self.assertIs(type(result), date)

    def test_add_months_works_from_the_original_date(self):
        start = d("2024-01-31")
        self.assertEqual(add_months(add_months(start, 1), 1), d("2024-03-29"))
        self.assertEqual(add_months(start, 2), d("2024-03-31"))
        self.assertEqual([add_months(start, n).day for n in range(0, 12)], [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])

    def test_add_months_inverse_for_early_days(self):
        for day in (1, 15, 28):
            for n in (-30, -13, -1, 0, 1, 5, 12, 40):
                with self.subTest(day=day, n=n):
                    start = date(2024, 6, day)
                    self.assertEqual(add_months(add_months(start, n), -n), start)

    def test_add_months_leaves_the_calendar(self):
        for start, n in ((date(9999, 12, 31), 1), (date(9999, 1, 1), 12), (date(1, 1, 1), -1), (date(2024, 1, 1), 120000),
                         (date(2024, 1, 1), -120000)):
            with self.subTest(start=start, n=n):
                with self.assertRaises(DateError):
                    add_months(start, n)
        self.assertEqual(add_months(date(9999, 11, 30), 1), date(9999, 12, 30))
        self.assertEqual(add_months(date(1, 2, 1), -1), date(1, 1, 1))

    def test_add_months_argument_types(self):
        for args in ((d("2024-01-31"), 1.5), (d("2024-01-31"), True), (d("2024-01-31"), "1"), (d("2024-01-31"), None),
                     ("2024-01-31", 1), (None, 1), (20240131, 1)):
            with self.subTest(args=args):
                with self.assertRaises(DateError):
                    add_months(*args)


class M03PeriodBasics(unittest.TestCase):
    def test_construct_and_attributes(self):
        p = Period(date(2024, 3, 5), date(2024, 3, 20))
        self.assertEqual((p.start, p.end), (date(2024, 3, 5), date(2024, 3, 20)))
        self.assertEqual(p, Period(date(2024, 3, 5), date(2024, 3, 20)))
        self.assertNotEqual(p, Period(date(2024, 3, 5), date(2024, 3, 21)))
        self.assertEqual(len({p, Period(date(2024, 3, 5), date(2024, 3, 20)), P("2024-03")}), 2)
        with self.assertRaises((AttributeError, TypeError)):
            p.end = date(2024, 4, 1)

    def test_empty_periods_are_refused(self):
        with self.assertRaises(DateError) as cm:
            Period(date(2024, 3, 5), date(2024, 3, 4))
        self.assertIn("2024-03-05", str(cm.exception))
        self.assertIn("2024-03-04", str(cm.exception))
        with self.assertRaises(DateError):
            Period(date(2025, 1, 1), date(2024, 1, 1))
        one = Period(date(2024, 3, 5), date(2024, 3, 5))
        self.assertEqual(one.days, 1)

    def test_constructor_needs_dates(self):
        for args in (("2024-03-01", date(2024, 3, 31)), (date(2024, 3, 1), "2024-03-31"), (None, None),
                     (20240301, 20240331)):
            with self.subTest(args=args):
                with self.assertRaises(DateError):
                    Period(*args)

    def test_days(self):
        table = [("2024-01", 31), ("2024-02", 29), ("2023-02", 28), ("2024-04", 30), ("2024", 366), ("2023", 365),
                 ("2024-Q1", 91), ("2023-Q1", 90), ("2024-Q2", 91), ("2024-Q3", 92), ("2024-Q4", 92),
                 ("2024-03-05..2024-03-05", 1), ("2024-03-05..2024-03-06", 2), ("2023-12-31..2024-01-01", 2),
                 ("2024-02-28..2024-03-01", 3), ("2023-02-28..2023-03-01", 2)]
        for text, expected in table:
            with self.subTest(text=text):
                self.assertEqual(P(text).days, expected)
                self.assertIs(type(P(text).days), int)

    def test_contains_includes_both_ends(self):
        p = P("2024-03")
        self.assertTrue(p.contains(date(2024, 3, 1)))
        self.assertTrue(p.contains(date(2024, 3, 31)))
        self.assertTrue(p.contains(date(2024, 3, 15)))
        self.assertFalse(p.contains(date(2024, 2, 29)))
        self.assertFalse(p.contains(date(2024, 4, 1)))
        self.assertFalse(p.contains(date(2023, 3, 15)))
        one = P("2024-03-05..2024-03-05")
        self.assertTrue(one.contains(date(2024, 3, 5)))
        self.assertFalse(one.contains(date(2024, 3, 6)))
        for bad in ("2024-03-15", None, 15, "x"):
            with self.subTest(bad=bad):
                with self.assertRaises(DateError):
                    p.contains(bad)

    def test_label_of_whole_calendar_periods(self):
        table = [(date(2024, 1, 1), date(2024, 12, 31), "2024"), (date(2023, 1, 1), date(2023, 12, 31), "2023"),
                 (date(2024, 3, 1), date(2024, 3, 31), "2024-03"), (date(2024, 2, 1), date(2024, 2, 29), "2024-02"),
                 (date(2023, 2, 1), date(2023, 2, 28), "2023-02"), (date(2024, 12, 1), date(2024, 12, 31), "2024-12"),
                 (date(2024, 1, 1), date(2024, 3, 31), "2024-Q1"), (date(2024, 4, 1), date(2024, 6, 30), "2024-Q2"),
                 (date(2024, 7, 1), date(2024, 9, 30), "2024-Q3"), (date(2024, 10, 1), date(2024, 12, 31), "2024-Q4"),
                 (date(999, 1, 1), date(999, 12, 31), "0999"), (date(5, 3, 1), date(5, 3, 31), "0005-03")]
        for start, end, label in table:
            with self.subTest(label=label):
                p = Period(start, end)
                self.assertEqual(p.label, label)
                self.assertEqual(str(p), label)

    def test_label_of_other_periods_is_the_range(self):
        table = ["2024-03-05..2024-03-20", "2024-03-01..2024-03-30", "2024-03-02..2024-03-31", "2024-04-01..2024-04-29",
                 "2024-01-01..2024-12-30", "2024-01-01..2025-12-31", "2024-02-01..2024-04-30", "2024-01-01..2024-06-30",
                 "2024-03-01..2024-05-31", "2024-02-01..2024-03-31", "2023-12-01..2024-01-31", "2024-03-05..2024-03-05",
                 "2024-01-02..2024-12-31", "2024-01-01..2024-02-28", "2024-04-01..2024-05-31", "2024-07-01..2024-12-31"]
        for text in table:
            with self.subTest(text=text):
                self.assertEqual(P(text).label, text)

    def test_label_depends_only_on_the_dates(self):
        self.assertEqual(P("2024-01-01..2024-03-31").label, "2024-Q1")
        self.assertEqual(P("2024-03-01..2024-03-31").label, "2024-03")
        self.assertEqual(P("2024-01-01..2024-12-31").label, "2024")
        self.assertEqual(P("2024-Q1").label, "2024-Q1")
        self.assertEqual(P("2024-02").label, "2024-02")
        self.assertEqual(P("2023-02-01..2023-02-28").label, "2023-02")

    def test_parse_of_a_label_gives_the_period_back(self):
        for text in ("2024", "2024-03", "2024-Q3", "2024-03-05..2024-03-20", "2024-03-05..2024-03-05",
                     "2024-01-01..2025-12-31", "2023-12-01..2024-01-31", "0999-01-01..0999-12-31"):
            with self.subTest(text=text):
                p = P(text)
                self.assertEqual(Period.parse(p.label), p)
                self.assertEqual(P(p.label).label, p.label)


class M03PeriodParse(unittest.TestCase):
    def test_year_month_quarter(self):
        table = [("2024", "2024-01-01", "2024-12-31"), ("2023", "2023-01-01", "2023-12-31"),
                 ("0001", "0001-01-01", "0001-12-31"), ("9999", "9999-01-01", "9999-12-31"),
                 ("2024-03", "2024-03-01", "2024-03-31"), ("2024-02", "2024-02-01", "2024-02-29"),
                 ("2023-02", "2023-02-01", "2023-02-28"), ("2024-12", "2024-12-01", "2024-12-31"),
                 ("2024-04", "2024-04-01", "2024-04-30"), ("1900-02", "1900-02-01", "1900-02-28"),
                 ("2024-Q1", "2024-01-01", "2024-03-31"), ("2024-Q2", "2024-04-01", "2024-06-30"),
                 ("2024-Q3", "2024-07-01", "2024-09-30"), ("2024-Q4", "2024-10-01", "2024-12-31"),
                 ("2023-Q1", "2023-01-01", "2023-03-31")]
        for text, start, end in table:
            with self.subTest(text=text):
                p = P(text)
                self.assertEqual((p.start, p.end), (d(start), d(end)))
                self.assertIsInstance(p, Period)

    def test_ranges(self):
        table = [("2024-03-01..2024-03-31", "2024-03-01", "2024-03-31"), ("2024-03-05..2024-03-05", "2024-03-05", "2024-03-05"),
                 ("2023-12-25..2024-01-05", "2023-12-25", "2024-01-05"), ("2024-02-28..2024-03-01", "2024-02-28", "2024-03-01"),
                 ("2020-01-01..2030-12-31", "2020-01-01", "2030-12-31")]
        for text, start, end in table:
            with self.subTest(text=text):
                p = P(text)
                self.assertEqual((p.start, p.end), (d(start), d(end)))

    def test_refused_texts_name_the_text(self):
        bad = ["2024-3", "2024-13", "2024-00", "2024-Q0", "2024-Q5", "2024-q1", "2024-Q", "2024Q1", "2024-Q12", "24",
               "12345", "202", "0000", "0000-01", "2024-03-01", "2024-03-01..", "..2024-03-31", "..", "2024-03-01...2024-03-31",
               "2024-03-01 .. 2024-03-31", "2024-03-01 ..2024-03-31", "2024-03..2024-04", "2024..2025",
               "2024-02-30..2024-03-31", "2024-03-01..2024-02-30", "2024-03-01..2024-03-31..2024-04-30", "",
               " ", " 2024", "2024 ", " 2024-03", "2024-03 ", "2024-03\n", "2024-03-01 to 2024-03-31",
               "2024-03-01:2024-03-31", "2024-03-01,2024-03-31", "March 2024", "2024/03", "2024-Q1 ", "Q1",
               "٢٠٢٤"]
        for text in bad:
            with self.subTest(text=text):
                with self.assertRaises(DateError) as cm:
                    P(text)
                self.assertIn(text, str(cm.exception))

    def test_empty_range_is_refused(self):
        for text in ("2024-03-31..2024-03-01", "2024-03-02..2024-03-01", "2025-01-01..2024-12-31"):
            with self.subTest(text=text):
                with self.assertRaises(DateError) as cm:
                    P(text)
                self.assertIn(text, str(cm.exception))

    def test_input_must_be_text(self):
        for bad in (None, 2024, date(2024, 3, 1), b"2024", ("2024",)):
            with self.subTest(bad=bad):
                with self.assertRaises(DateError):
                    Period.parse(bad)


class M03PeriodNext(unittest.TestCase):
    def test_next_month(self):
        table = [("2024-02", "2024-03"), ("2024-12", "2025-01"), ("2024-01", "2024-02"), ("2023-01", "2023-02"),
                 ("2024-04", "2024-05"), ("2024-10", "2024-11"), ("2024-03", "2024-04")]
        for text, expected in table:
            with self.subTest(text=text):
                n = P(text).next()
                self.assertEqual(n, P(expected))
                self.assertEqual(n.label, expected)
        self.assertEqual(P("2024-01").next().days, 29)
        self.assertEqual(P("2024-02").next().days, 31)
        self.assertEqual(P("2023-01").next().days, 28)

    def test_next_quarter(self):
        table = [("2024-Q1", "2024-Q2"), ("2024-Q2", "2024-Q3"), ("2024-Q3", "2024-Q4"), ("2024-Q4", "2025-Q1")]
        for text, expected in table:
            with self.subTest(text=text):
                self.assertEqual(P(text).next(), P(expected))
        self.assertEqual(P("2024-Q4").next().start, date(2025, 1, 1))
        self.assertEqual(P("2024-Q1").next().end, date(2024, 6, 30))

    def test_next_year(self):
        self.assertEqual(P("2024").next(), P("2025"))
        self.assertEqual(P("2023").next().days, 366)
        self.assertEqual(P("1999").next().label, "2000")

    def test_next_range_keeps_its_length(self):
        table = [("2024-03-05..2024-03-14", "2024-03-15..2024-03-24"), ("2024-03-05..2024-03-05", "2024-03-06..2024-03-06"),
                 ("2024-03-31..2024-03-31", "2024-04-01..2024-04-01"), ("2024-02-26..2024-03-03", "2024-03-04..2024-03-10"),
                 ("2024-12-25..2025-01-03", "2025-01-04..2025-01-13"), ("2024-03-10..2024-04-09", "2024-04-10..2024-05-10"),
                 ("2024-04-01..2024-04-29", "2024-04-30..2024-05-28"), ("2024-02-01..2024-04-30", "2024-05-01..2024-07-29")]
        for text, expected in table:
            with self.subTest(text=text):
                n = P(text).next()
                self.assertEqual(n, P(expected))
                self.assertEqual(n.days, P(text).days)

    def test_next_follows_the_kind_even_when_written_as_a_range(self):
        self.assertEqual(P("2024-03-01..2024-03-31").next(), P("2024-04"))
        self.assertEqual(P("2024-01-01..2024-03-31").next(), P("2024-Q2"))
        self.assertEqual(P("2024-01-01..2024-12-31").next(), P("2025"))
        self.assertEqual(P("2024-02-01..2024-02-29").next(), P("2024-03-01..2024-03-31"))

    def test_next_chain_has_no_gaps(self):
        for text in ("2024-01", "2024-Q3", "2023", "2024-03-05..2024-03-14", "2024-01-31..2024-01-31"):
            with self.subTest(text=text):
                p = P(text)
                for _ in range(30):
                    n = p.next()
                    self.assertEqual(n.start, p.end + timedelta(days=1))
                    p = n

    def test_next_past_the_end_of_the_calendar(self):
        for text in ("9999-12", "9999-Q4", "9999", "9999-12-25..9999-12-31", "9999-12-31..9999-12-31"):
            with self.subTest(text=text):
                with self.assertRaises(DateError):
                    P(text).next()
        self.assertEqual(P("9999-11").next(), P("9999-12"))


class M03Periods(unittest.TestCase):
    def labels(self, start, end, step):
        return [p.label for p in periods(d(start), d(end), step)]

    def test_months(self):
        self.assertEqual(self.labels("2024-01-15", "2024-03-02", "month"), ["2024-01", "2024-02", "2024-03"])
        self.assertEqual(self.labels("2023-11-30", "2024-02-01", "month"), ["2023-11", "2023-12", "2024-01", "2024-02"])
        result = periods(d("2024-01-15"), d("2024-03-02"), "month")
        self.assertIsInstance(result, list)
        self.assertEqual((result[0].start, result[-1].end), (d("2024-01-01"), d("2024-03-31")))
        self.assertTrue(all(isinstance(p, Period) for p in result))

    def test_a_year_of_months(self):
        result = periods(d("2024-01-01"), d("2024-12-31"), "month")
        self.assertEqual([p.label for p in result], ["2024-%02d" % m for m in range(1, 13)])
        self.assertEqual(sum(p.days for p in result), 366)
        self.assertEqual(sum(p.days for p in periods(d("2023-01-01"), d("2023-12-31"), "month")), 365)

    def test_quarters(self):
        self.assertEqual(self.labels("2023-11-15", "2024-02-03", "quarter"), ["2023-Q4", "2024-Q1"])
        self.assertEqual(self.labels("2024-01-01", "2024-12-31", "quarter"), ["2024-Q1", "2024-Q2", "2024-Q3", "2024-Q4"])
        self.assertEqual(self.labels("2024-05-05", "2025-04-01", "quarter"), ["2024-Q2", "2024-Q3", "2024-Q4", "2025-Q1", "2025-Q2"])
        self.assertEqual(self.labels("2024-03-31", "2024-04-01", "quarter"), ["2024-Q1", "2024-Q2"])

    def test_years(self):
        self.assertEqual(self.labels("2022-06-01", "2024-02-01", "year"), ["2022", "2023", "2024"])
        self.assertEqual(self.labels("2024-12-31", "2025-01-01", "year"), ["2024", "2025"])
        self.assertEqual(self.labels("2024-01-01", "2024-12-31", "year"), ["2024"])

    def test_weeks_run_monday_to_sunday(self):
        result = periods(d("2024-03-06"), d("2024-03-18"), "week")
        self.assertEqual([p.label for p in result], ["2024-03-04..2024-03-10", "2024-03-11..2024-03-17", "2024-03-18..2024-03-24"])
        self.assertTrue(all(p.days == 7 for p in result))
        self.assertTrue(all(p.start.weekday() == 0 and p.end.weekday() == 6 for p in result))

    def test_weeks_across_month_and_year_ends(self):
        self.assertEqual(self.labels("2024-12-30", "2025-01-05", "week"), ["2024-12-30..2025-01-05"])
        self.assertEqual(self.labels("2024-12-29", "2025-01-06", "week"),
                         ["2024-12-23..2024-12-29", "2024-12-30..2025-01-05", "2025-01-06..2025-01-12"])
        self.assertEqual(self.labels("2024-02-28", "2024-03-05", "week"), ["2024-02-26..2024-03-03", "2024-03-04..2024-03-10"])

    def test_one_period_when_start_and_end_share_it(self):
        for step, day, label in (("month", "2024-03-15", "2024-03"), ("quarter", "2024-03-15", "2024-Q1"),
                                 ("year", "2024-03-15", "2024"), ("week", "2024-03-06", "2024-03-04..2024-03-10")):
            with self.subTest(step=step):
                self.assertEqual(self.labels(day, day, step), [label])
        self.assertEqual(self.labels("2024-03-01", "2024-03-31", "month"), ["2024-03"])
        self.assertEqual(self.labels("2024-03-04", "2024-03-10", "week"), ["2024-03-04..2024-03-10"])

    def test_periods_have_no_gaps_or_overlaps(self):
        for step in ("week", "month", "quarter", "year"):
            with self.subTest(step=step):
                result = periods(d("2023-02-17"), d("2025-11-09"), step)
                self.assertTrue(result[0].contains(d("2023-02-17")))
                self.assertTrue(result[-1].contains(d("2025-11-09")))
                self.assertFalse(result[-1].start > d("2025-11-09"))
                for a, b in zip(result, result[1:]):
                    self.assertEqual(b.start, a.end + timedelta(days=1))
                self.assertEqual(sum(p.days for p in result), (result[-1].end - result[0].start).days + 1)

    def test_empty_range_is_refused(self):
        for step in ("week", "month", "quarter", "year"):
            with self.subTest(step=step):
                with self.assertRaises(DateError):
                    periods(d("2024-03-02"), d("2024-03-01"), step)

    def test_unknown_step(self):
        for step in ("day", "fortnight", "Month", "months", "", None, 1, "quarterly"):
            with self.subTest(step=step):
                with self.assertRaises(DateError) as cm:
                    periods(d("2024-01-01"), d("2024-02-01"), step)
                self.assertIn(str(step), str(cm.exception))

    def test_arguments_must_be_dates(self):
        for args in (("2024-01-01", d("2024-02-01")), (d("2024-01-01"), "2024-02-01"), (None, None)):
            with self.subTest(args=args):
                with self.assertRaises(DateError):
                    periods(args[0], args[1], "month")

    def test_whole_calendar_edges(self):
        self.assertEqual(self.labels("9999-11-01", "9999-12-31", "month"), ["9999-11", "9999-12"])
        self.assertEqual(self.labels("0001-01-01", "0001-02-01", "month"), ["0001-01", "0001-02"])
        self.assertEqual(self.labels("9999-12-31", "9999-12-31", "year"), ["9999"])


if __name__ == "__main__":
    unittest.main()

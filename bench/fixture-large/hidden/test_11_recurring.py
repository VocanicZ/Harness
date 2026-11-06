"""Hidden tests of module 11: recurring transactions (tallybook.recurring)."""
import unittest
from datetime import date

from support import lib

D = date


def rec_mod():
    return lib("recurring")


def template(payee="Flat", narration="rent", tags=("home",), flag="*", amount=True):
    model, money = lib("model"), lib("money")
    postings = [model.Posting("Expenses:Rent", money.Money.parse("900.00 USD") if amount else None, "r"),
                model.Posting("Assets:Bank", money.Money.parse("-900.00 USD"), "")]
    return model.Transaction(date=D(2000, 1, 1), payee=payee, narration=narration, postings=postings,
                             tags=tags, flag=flag)


def series(schedule, start, until, **kw):
    """Dates of a Recurring over start..until, from its own start."""
    first = kw.pop("first", start)
    rec = rec_mod().Recurring("item", schedule, template(), first, **kw)
    return rec_mod().occurrences(rec, start, until)


def ds(*triples):
    return [D(*t) for t in triples]


class M11ParseSchedule(unittest.TestCase):
    def test_every_documented_shape_parses(self):
        for text in ("daily", "weekly on mon", "weekly on sun", "monthly on 5", "monthly on 31", "monthly on 1",
                     "monthly on last", "yearly on 03-15", "yearly on 02-29", "every 2 weeks from 2024-01-03",
                     "every 3 months from 2024-01-31", "every 1 day from 2024-01-01", "every 5 years from 2020-02-29"):
            with self.subTest(text=text):
                self.assertIsInstance(rec_mod().parse_schedule(text), rec_mod().Schedule)

    def test_all_weekday_names(self):
        for name in ("mon", "tue", "wed", "thu", "fri", "sat", "sun"):
            with self.subTest(day=name):
                s = rec_mod().parse_schedule("weekly on " + name)
                self.assertEqual(str(s), "weekly on " + name)

    def test_case_and_blanks_do_not_matter(self):
        want = rec_mod().parse_schedule("monthly on last")
        for text in ("Monthly On LAST", "  monthly   on\tlast  ", "MONTHLY ON Last"):
            with self.subTest(text=text):
                self.assertEqual(rec_mod().parse_schedule(text), want)
        self.assertEqual(rec_mod().parse_schedule("DAILY"), rec_mod().parse_schedule("daily"))

    def test_rejected_texts(self):
        bad = ["", "   ", "weekly", "daily on mon", "monthly on 0", "monthly on 32", "monthly on", "monthly on first",
               "monthly on -1", "weekly on someday", "weekly on monday", "yearly on 13-01", "yearly on 02-30",
               "yearly on 3-15", "yearly on 03-15-2024", "yearly on 00-10", "every 0 days from 2024-01-01",
               "every -1 days from 2024-01-01", "every 2 weeks", "every 2 fortnights from 2024-01-01",
               "every 2 weeks from 2024-02-30", "every two weeks from 2024-01-01", "every 2 weeks since 2024-01-01",
               "every weeks from 2024-01-01", "every 2 weeks from 2024-1-1", "hourly", "monthly on 5 and 6",
               None, 5, ["daily"]]
        for text in bad:
            with self.subTest(text=text), self.assertRaises(rec_mod().RecurringError):
                rec_mod().parse_schedule(text)

    def test_error_class_and_message(self):
        with self.assertRaises(rec_mod().RecurringError) as ctx:
            rec_mod().parse_schedule("hourly")
        self.assertTrue(issubclass(rec_mod().RecurringError, lib("errors").ValidationError))
        self.assertEqual(ctx.exception.code, "validation")
        self.assertIn("monthly on", ctx.exception.message)

    def test_equality_and_hash(self):
        parse = rec_mod().parse_schedule
        self.assertEqual(parse("every 1 week from 2024-01-03"), parse("every 1 weeks from 2024-01-03"))
        self.assertEqual(hash(parse("daily")), hash(parse("Daily")))
        self.assertNotEqual(parse("weekly on mon"), parse("weekly on tue"))
        self.assertNotEqual(parse("monthly on 5"), parse("monthly on last"))
        self.assertNotEqual(parse("every 2 weeks from 2024-01-03"), parse("every 2 weeks from 2024-01-04"))
        self.assertEqual(len({parse("daily"), parse("DAILY"), parse("weekly on mon")}), 2)

    def test_canonical_text(self):
        cases = {"DAILY": "daily", "weekly   on  Mon": "weekly on mon", "monthly on 5": "monthly on 5",
                 "Monthly on LAST": "monthly on last", "yearly on 03-15": "yearly on 03-15",
                 "every 2 weeks from 2024-01-03": "every 2 weeks from 2024-01-03",
                 "every 1 weeks from 2024-01-03": "every 1 week from 2024-01-03",
                 "every 1 day from 2024-01-03": "every 1 day from 2024-01-03",
                 "every 3 Months from 2024-01-31": "every 3 months from 2024-01-31",
                 "every 2 year from 2024-01-31": "every 2 years from 2024-01-31",
                 "every 7 days from 2024-01-31": "every 7 days from 2024-01-31"}
        for text, canonical in cases.items():
            with self.subTest(text=text):
                s = rec_mod().parse_schedule(text)
                self.assertEqual(str(s), canonical)
                self.assertEqual(rec_mod().parse_schedule(str(s)), s)


class M11ScheduleDates(unittest.TestCase):
    def between(self, text, start, end):
        return rec_mod().parse_schedule(text).between(start, end)

    def test_daily(self):
        self.assertEqual(self.between("daily", D(2024, 2, 27), D(2024, 3, 2)),
                         ds((2024, 2, 27), (2024, 2, 28), (2024, 2, 29), (2024, 3, 1), (2024, 3, 2)))
        self.assertEqual(self.between("daily", D(2024, 2, 27), D(2024, 2, 27)), [D(2024, 2, 27)])
        self.assertEqual(self.between("daily", D(2024, 2, 28), D(2024, 2, 27)), [])

    def test_weekly(self):
        self.assertEqual(self.between("weekly on mon", D(2024, 1, 1), D(2024, 1, 31)),
                         ds((2024, 1, 1), (2024, 1, 8), (2024, 1, 15), (2024, 1, 22), (2024, 1, 29)))
        self.assertEqual(self.between("weekly on sun", D(2024, 1, 1), D(2024, 1, 14)), ds((2024, 1, 7), (2024, 1, 14)))
        self.assertEqual(self.between("weekly on fri", D(2024, 1, 6), D(2024, 1, 11)), [])
        self.assertEqual(self.between("weekly on wed", D(2023, 12, 28), D(2024, 1, 10)), ds((2024, 1, 3), (2024, 1, 10)))

    def test_monthly_fixed_day(self):
        self.assertEqual(self.between("monthly on 5", D(2024, 1, 1), D(2024, 4, 30)),
                         ds((2024, 1, 5), (2024, 2, 5), (2024, 3, 5), (2024, 4, 5)))
        self.assertEqual(self.between("monthly on 5", D(2024, 1, 6), D(2024, 3, 4)), [D(2024, 2, 5)])
        self.assertEqual(self.between("monthly on 5", D(2024, 1, 5), D(2024, 1, 5)), [D(2024, 1, 5)])

    def test_monthly_clamps_to_month_end(self):
        self.assertEqual(self.between("monthly on 31", D(2024, 1, 1), D(2024, 5, 31)),
                         ds((2024, 1, 31), (2024, 2, 29), (2024, 3, 31), (2024, 4, 30), (2024, 5, 31)))
        self.assertEqual(self.between("monthly on 30", D(2023, 1, 1), D(2023, 3, 31)),
                         ds((2023, 1, 30), (2023, 2, 28), (2023, 3, 30)))
        self.assertEqual(self.between("monthly on 29", D(2023, 2, 1), D(2024, 2, 29))[0], D(2023, 2, 28))
        self.assertEqual(self.between("monthly on 29", D(2024, 2, 1), D(2024, 2, 29)), [D(2024, 2, 29)])

    def test_monthly_last(self):
        self.assertEqual(self.between("monthly on last", D(2023, 12, 1), D(2024, 4, 30)),
                         ds((2023, 12, 31), (2024, 1, 31), (2024, 2, 29), (2024, 3, 31), (2024, 4, 30)))
        self.assertEqual(self.between("monthly on last", D(2023, 2, 1), D(2023, 2, 28)), [D(2023, 2, 28)])
        self.assertEqual(self.between("monthly on last", D(2023, 2, 1), D(2023, 2, 27)), [])

    def test_yearly(self):
        self.assertEqual(self.between("yearly on 03-15", D(2023, 1, 1), D(2025, 12, 31)),
                         ds((2023, 3, 15), (2024, 3, 15), (2025, 3, 15)))
        self.assertEqual(self.between("yearly on 03-15", D(2023, 3, 16), D(2024, 3, 14)), [])
        self.assertEqual(self.between("yearly on 02-29", D(2024, 1, 1), D(2028, 12, 31)),
                         ds((2024, 2, 29), (2025, 2, 28), (2026, 2, 28), (2027, 2, 28), (2028, 2, 29)))
        self.assertEqual(self.between("yearly on 12-31", D(2024, 12, 31), D(2025, 1, 1)), [D(2024, 12, 31)])

    def test_every_days_and_weeks(self):
        self.assertEqual(self.between("every 10 days from 2024-01-01", D(2024, 1, 1), D(2024, 2, 10)),
                         ds((2024, 1, 1), (2024, 1, 11), (2024, 1, 21), (2024, 1, 31), (2024, 2, 10)))
        self.assertEqual(self.between("every 2 weeks from 2024-01-03", D(2024, 1, 1), D(2024, 2, 14)),
                         ds((2024, 1, 3), (2024, 1, 17), (2024, 1, 31), (2024, 2, 14)))
        self.assertEqual(self.between("every 2 weeks from 2024-01-03", D(2024, 1, 18), D(2024, 2, 13)), [D(2024, 1, 31)])
        self.assertEqual(self.between("every 1 day from 2024-01-03", D(2024, 1, 1), D(2024, 1, 5)),
                         ds((2024, 1, 3), (2024, 1, 4), (2024, 1, 5)))

    def test_every_never_before_the_anchor(self):
        for text in ("every 3 days from 2024-03-01", "every 2 weeks from 2024-03-01",
                     "every 1 months from 2024-03-01", "every 1 years from 2024-03-01"):
            with self.subTest(text=text):
                self.assertEqual(self.between(text, D(2024, 1, 1), D(2024, 2, 28)), [])
                self.assertEqual(self.between(text, D(2024, 1, 1), D(2024, 3, 1)), [D(2024, 3, 1)])

    def test_every_months_counts_from_the_anchor(self):
        self.assertEqual(self.between("every 3 months from 2024-01-31", D(2024, 1, 1), D(2025, 1, 31)),
                         ds((2024, 1, 31), (2024, 4, 30), (2024, 7, 31), (2024, 10, 31), (2025, 1, 31)))
        self.assertEqual(self.between("every 1 months from 2024-01-31", D(2024, 1, 1), D(2024, 5, 31)),
                         ds((2024, 1, 31), (2024, 2, 29), (2024, 3, 31), (2024, 4, 30), (2024, 5, 31)))
        self.assertEqual(self.between("every 2 months from 2024-01-15", D(2024, 1, 1), D(2024, 7, 31)),
                         ds((2024, 1, 15), (2024, 3, 15), (2024, 5, 15), (2024, 7, 15)))
        self.assertEqual(self.between("every 3 months from 2024-01-31", D(2024, 8, 1), D(2024, 12, 31)), [D(2024, 10, 31)])

    def test_every_years(self):
        self.assertEqual(self.between("every 1 years from 2024-02-29", D(2024, 1, 1), D(2028, 12, 31)),
                         ds((2024, 2, 29), (2025, 2, 28), (2026, 2, 28), (2027, 2, 28), (2028, 2, 29)))
        self.assertEqual(self.between("every 2 years from 2020-06-01", D(2020, 1, 1), D(2026, 12, 31)),
                         ds((2020, 6, 1), (2022, 6, 1), (2024, 6, 1), (2026, 6, 1)))

    def test_far_windows_work(self):
        self.assertEqual(self.between("every 2 weeks from 2000-01-05", D(2030, 1, 1), D(2030, 1, 31)),
                         ds((2030, 1, 9), (2030, 1, 23)))
        self.assertEqual(self.between("every 7 months from 1990-03-31", D(2030, 1, 1), D(2030, 12, 31)),
                         ds((2030, 6, 30)))


class M11RecurringItem(unittest.TestCase):
    def make(self, **kw):
        args = dict(name="rent", schedule="monthly on 1", template=template(), start=D(2024, 1, 1))
        args.update(kw)
        return rec_mod().Recurring(args.pop("name"), args.pop("schedule"), args.pop("template"), args.pop("start"), **args)

    def test_attributes(self):
        tpl = template()
        r = rec_mod().Recurring("rent", "monthly on 1", tpl, D(2024, 1, 1), end=D(2024, 12, 1), count=5)
        self.assertEqual((r.name, r.start, r.end, r.count), ("rent", D(2024, 1, 1), D(2024, 12, 1), 5))
        self.assertEqual(r.schedule, rec_mod().parse_schedule("monthly on 1"))
        self.assertEqual(r.template, tpl)
        plain = self.make()
        self.assertIsNone(plain.end)
        self.assertIsNone(plain.count)

    def test_schedule_object_or_text(self):
        s = rec_mod().parse_schedule("weekly on fri")
        self.assertEqual(self.make(schedule=s).schedule, s)
        self.assertEqual(self.make(schedule="WEEKLY ON FRI").schedule, s)

    def test_equality(self):
        self.assertEqual(self.make(), self.make())
        self.assertNotEqual(self.make(), self.make(name="other"))
        self.assertNotEqual(self.make(), self.make(count=2))
        self.assertNotEqual(self.make(), self.make(end=D(2025, 1, 1)))

    def test_valid_names(self):
        for name in ("rent", "phone-bill", "2024_tax", "A", "a_b-c9"):
            with self.subTest(name=name):
                self.assertEqual(self.make(name=name).name, name)

    def test_invalid_names(self):
        for name in ("", "-rent", "_rent", "my rent", "rent!", "mietzahlungä", None, 5, "a:b"):
            with self.subTest(name=name), self.assertRaises(rec_mod().RecurringError):
                self.make(name=name)

    def test_invalid_arguments(self):
        for kw in ({"schedule": "hourly"}, {"schedule": 5}, {"schedule": None}, {"template": "x"}, {"template": None},
                   {"start": "2024-01-01"}, {"start": None}, {"end": D(2023, 12, 31)}, {"end": "2024-12-31"},
                   {"count": 0}, {"count": -1}, {"count": "3"}, {"count": 1.0}, {"count": True}):
            with self.subTest(kw=kw), self.assertRaises(rec_mod().RecurringError):
                self.make(**kw)

    def test_end_may_equal_start(self):
        self.assertEqual(self.make(end=D(2024, 1, 1)).end, D(2024, 1, 1))


class M11Occurrences(unittest.TestCase):
    def test_window_is_inclusive(self):
        got = series("monthly on 1", D(2024, 3, 1), D(2024, 5, 1), first=D(2024, 1, 1))
        self.assertEqual(got, ds((2024, 3, 1), (2024, 4, 1), (2024, 5, 1)))

    def test_window_before_start_gets_nothing_before_start(self):
        got = series("monthly on 1", D(2023, 6, 1), D(2024, 2, 1), first=D(2024, 1, 1))
        self.assertEqual(got, ds((2024, 1, 1), (2024, 2, 1)))

    def test_start_day_is_included_when_it_matches(self):
        self.assertEqual(series("weekly on mon", D(2024, 1, 1), D(2024, 1, 15), first=D(2024, 1, 1)),
                         ds((2024, 1, 1), (2024, 1, 8), (2024, 1, 15)))

    def test_start_in_the_middle_of_a_month(self):
        self.assertEqual(series("monthly on 5", D(2024, 1, 1), D(2024, 4, 30), first=D(2024, 2, 10)),
                         ds((2024, 3, 5), (2024, 4, 5)))
        self.assertEqual(series("monthly on 5", D(2024, 1, 1), D(2024, 4, 30), first=D(2024, 2, 5)),
                         ds((2024, 2, 5), (2024, 3, 5), (2024, 4, 5)))

    def test_end_is_inclusive(self):
        got = series("monthly on 5", D(2024, 1, 1), D(2024, 12, 31), end=D(2024, 3, 5))
        self.assertEqual(got, ds((2024, 1, 5), (2024, 2, 5), (2024, 3, 5)))
        got = series("monthly on 5", D(2024, 1, 1), D(2024, 12, 31), end=D(2024, 3, 4))
        self.assertEqual(got, ds((2024, 1, 5), (2024, 2, 5)))

    def test_count_limits_the_series(self):
        self.assertEqual(series("monthly on 5", D(2024, 1, 1), D(2024, 12, 31), count=3),
                         ds((2024, 1, 5), (2024, 2, 5), (2024, 3, 5)))
        self.assertEqual(series("daily", D(2024, 1, 1), D(2024, 1, 31), count=1), [D(2024, 1, 1)])

    def test_count_counts_from_the_series_start_not_the_window(self):
        self.assertEqual(series("monthly on 5", D(2024, 4, 1), D(2024, 6, 30), first=D(2024, 1, 1), count=3), [])
        self.assertEqual(series("monthly on 5", D(2024, 2, 1), D(2024, 6, 30), first=D(2024, 1, 1), count=3),
                         ds((2024, 2, 5), (2024, 3, 5)))

    def test_end_and_count_whichever_comes_first(self):
        self.assertEqual(series("daily", D(2024, 1, 1), D(2024, 1, 31), end=D(2024, 1, 3), count=10),
                         ds((2024, 1, 1), (2024, 1, 2), (2024, 1, 3)))
        self.assertEqual(series("daily", D(2024, 1, 1), D(2024, 1, 31), end=D(2024, 1, 20), count=2),
                         ds((2024, 1, 1), (2024, 1, 2)))

    def test_every_keeps_the_anchor_rhythm_after_a_later_start(self):
        got = series("every 2 weeks from 2024-01-03", D(2024, 1, 1), D(2024, 3, 1), first=D(2024, 1, 20))
        self.assertEqual(got, ds((2024, 1, 31), (2024, 2, 14), (2024, 2, 28)))

    def test_every_with_an_anchor_after_the_start(self):
        got = series("every 2 weeks from 2024-02-07", D(2024, 1, 1), D(2024, 3, 1), first=D(2024, 1, 1))
        self.assertEqual(got, ds((2024, 2, 7), (2024, 2, 21)))
        got = series("every 2 weeks from 2024-02-07", D(2024, 1, 1), D(2024, 3, 1), first=D(2024, 1, 1), count=1)
        self.assertEqual(got, [D(2024, 2, 7)])

    def test_every_months_with_a_later_start(self):
        got = series("every 3 months from 2024-01-31", D(2024, 1, 1), D(2025, 6, 30), first=D(2024, 5, 1))
        self.assertEqual(got, ds((2024, 7, 31), (2024, 10, 31), (2025, 1, 31), (2025, 4, 30)))

    def test_empty_or_reversed_window(self):
        self.assertEqual(series("daily", D(2024, 1, 10), D(2024, 1, 9), first=D(2024, 1, 1)), [])
        self.assertEqual(series("daily", D(2024, 1, 10), D(2024, 1, 10), first=D(2024, 1, 1)), [D(2024, 1, 10)])

    def test_end_before_window(self):
        self.assertEqual(series("daily", D(2024, 2, 1), D(2024, 2, 5), first=D(2024, 1, 1), end=D(2024, 1, 31)), [])

    def test_long_series_are_fast(self):
        got = series("daily", D(2024, 1, 1), D(2024, 12, 31), first=D(2000, 1, 1))
        self.assertEqual(len(got), 366)

    def test_weekly_with_start_on_another_weekday(self):
        got = series("weekly on fri", D(2024, 1, 1), D(2024, 1, 31), first=D(2024, 1, 10))
        self.assertEqual(got, ds((2024, 1, 12), (2024, 1, 19), (2024, 1, 26)))


class M11Expand(unittest.TestCase):
    def rec(self, name="rent", schedule="monthly on 1", start=D(2024, 1, 1), **kw):
        tpl = kw.pop("template", None) or template()
        return rec_mod().Recurring(name, schedule, tpl, start, **kw)

    def test_dated_copies(self):
        out = rec_mod().expand([self.rec()], D(2024, 2, 1), D(2024, 3, 31))
        self.assertEqual([t.date for t in out], [D(2024, 2, 1), D(2024, 3, 1)])
        model = lib("model")
        for t in out:
            self.assertIsInstance(t, model.Transaction)
            self.assertEqual((t.payee, t.narration, t.flag, t.id), ("Flat", "rent", "*", None))
            self.assertEqual(t.tags, ("home", "recurring"))
            self.assertEqual([(p.account, str(p.amount), p.note) for p in t.postings],
                             [("Expenses:Rent", "900.00 USD", "r"), ("Assets:Bank", "-900.00 USD", "")])

    def test_tags_sorted_unique_with_recurring(self):
        for tags, want in (((), ("recurring",)), (("zeta", "alpha"), ("alpha", "recurring", "zeta")),
                           (("recurring",), ("recurring",)), (("home", "home"), ("home", "recurring"))):
            with self.subTest(tags=tags):
                (t,) = rec_mod().expand([self.rec(template=template(tags=tags))], D(2024, 1, 1), D(2024, 1, 1))
                self.assertEqual(tuple(t.tags), want)

    def test_flag_is_copied(self):
        (t,) = rec_mod().expand([self.rec(template=template(flag="!"))], D(2024, 1, 1), D(2024, 1, 1))
        self.assertEqual(t.flag, "!")

    def test_missing_amount_stays_missing(self):
        (t,) = rec_mod().expand([self.rec(template=template(amount=False))], D(2024, 1, 1), D(2024, 1, 1))
        self.assertIsNone(t.postings[0].amount)

    def test_template_date_is_ignored_and_template_untouched(self):
        tpl = template()
        before = (tpl.date, tpl.payee, list(tpl.postings), tuple(tpl.tags), tpl.id)
        out = rec_mod().expand([self.rec(template=tpl)], D(2024, 1, 1), D(2024, 3, 31))
        out[0].postings.append(lib("model").Posting("Assets:Cash", lib("money").Money.parse("1.00 USD")))
        self.assertEqual(len(out[1].postings), 2)
        self.assertEqual((tpl.date, tpl.payee, list(tpl.postings), tuple(tpl.tags), tpl.id), before)

    def test_ordering_by_date_then_name_then_position(self):
        a = self.rec("b-item", "monthly on 1")
        b = self.rec("a-item", "monthly on 1", template=template(payee="A"))
        c = self.rec("c-item", "monthly on 15", template=template(payee="C"))
        d = self.rec("a-item", "monthly on 1", template=template(payee="A2"))
        out = rec_mod().expand([a, c, b, d], D(2024, 1, 1), D(2024, 2, 29))
        self.assertEqual([(t.date.isoformat(), t.payee) for t in out],
                         [("2024-01-01", "A"), ("2024-01-01", "A2"), ("2024-01-01", "Flat"), ("2024-01-15", "C"),
                          ("2024-02-01", "A"), ("2024-02-01", "A2"), ("2024-02-01", "Flat"), ("2024-02-15", "C")])

    def test_name_order_is_plain_text(self):
        x = self.rec("Zed", "daily", template=template(payee="Z"))
        y = self.rec("alpha", "daily", template=template(payee="a"))
        out = rec_mod().expand([y, x], D(2024, 1, 1), D(2024, 1, 1))
        self.assertEqual([t.payee for t in out], ["Z", "a"])

    def test_limits_apply(self):
        out = rec_mod().expand([self.rec(count=2), self.rec("other", "monthly on 2", end=D(2024, 2, 2))],
                               D(2024, 1, 1), D(2024, 12, 31))
        self.assertEqual([(t.date.isoformat()) for t in out], ["2024-01-01", "2024-01-02", "2024-02-01", "2024-02-02"])

    def test_empty_inputs(self):
        self.assertEqual(rec_mod().expand([], D(2024, 1, 1), D(2024, 12, 31)), [])
        self.assertEqual(rec_mod().expand([self.rec()], D(2024, 2, 2), D(2024, 2, 28)), [])
        self.assertEqual(rec_mod().expand([self.rec()], D(2024, 3, 1), D(2024, 2, 1)), [])

    def test_expand_is_deterministic_and_repeatable(self):
        recs = [self.rec(), self.rec("x", "weekly on mon")]
        first = rec_mod().expand(recs, D(2024, 1, 1), D(2024, 3, 31))
        second = rec_mod().expand(recs, D(2024, 1, 1), D(2024, 3, 31))
        self.assertEqual(first, second)
        self.assertEqual(len(first), 3 + 13)

    def test_instantiate(self):
        t = rec_mod().instantiate(self.rec(), D(2024, 7, 7))
        self.assertEqual((t.date, t.payee, t.tags, t.id), (D(2024, 7, 7), "Flat", ("home", "recurring"), None))


class M11Helpers(unittest.TestCase):
    def rec(self, schedule="monthly on 5", start=D(2024, 1, 1), **kw):
        return rec_mod().Recurring("item", schedule, template(), start, **kw)

    def test_next_occurrence(self):
        r = self.rec()
        nxt = rec_mod().next_occurrence
        self.assertEqual(nxt(r, D(2024, 2, 5)), D(2024, 3, 5))
        self.assertEqual(nxt(r, D(2024, 2, 4)), D(2024, 2, 5))
        self.assertEqual(nxt(r, D(2023, 6, 1)), D(2024, 1, 5))
        self.assertEqual(nxt(r, D(2024, 1, 4)), D(2024, 1, 5))
        self.assertEqual(nxt(r, D(2024, 1, 5)), D(2024, 2, 5))
        self.assertEqual(nxt(r, D(2024, 12, 31)), D(2025, 1, 5))

    def test_next_occurrence_respects_end_and_count(self):
        nxt = rec_mod().next_occurrence
        r = self.rec(end=D(2024, 3, 5))
        self.assertEqual(nxt(r, D(2024, 2, 5)), D(2024, 3, 5))
        self.assertIsNone(nxt(r, D(2024, 3, 5)))
        r = self.rec(count=2)
        self.assertEqual(nxt(r, D(2024, 1, 5)), D(2024, 2, 5))
        self.assertIsNone(nxt(r, D(2024, 2, 5)))
        self.assertIsNone(nxt(r, D(2030, 1, 1)))

    def test_next_occurrence_with_every_and_a_later_start(self):
        r = self.rec("every 10 days from 2024-01-01", start=D(2024, 1, 15))
        self.assertEqual(rec_mod().next_occurrence(r, D(2024, 1, 1)), D(2024, 1, 21))
        self.assertEqual(rec_mod().next_occurrence(r, D(2024, 1, 21)), D(2024, 1, 31))

    def test_describe_table(self):
        cases = {"daily": "every day", "weekly on mon": "every Monday", "weekly on tue": "every Tuesday",
                 "weekly on wed": "every Wednesday", "weekly on thu": "every Thursday", "weekly on fri": "every Friday",
                 "weekly on sat": "every Saturday", "weekly on sun": "every Sunday",
                 "monthly on 5": "on the 5th of every month", "monthly on last": "on the last day of every month",
                 "yearly on 03-15": "every year on 15 March", "yearly on 07-05": "every year on 5 July",
                 "yearly on 12-31": "every year on 31 December", "yearly on 01-01": "every year on 1 January",
                 "every 2 weeks from 2024-01-03": "every 2 weeks from 2024-01-03",
                 "every 1 month from 2024-01-31": "every month from 2024-01-31",
                 "every 1 days from 2024-01-31": "every day from 2024-01-31",
                 "every 1 week from 2024-01-31": "every week from 2024-01-31",
                 "every 1 years from 2024-02-29": "every year from 2024-02-29",
                 "every 3 months from 2024-01-31": "every 3 months from 2024-01-31",
                 "every 10 days from 2024-01-31": "every 10 days from 2024-01-31",
                 "every 2 years from 2024-01-31": "every 2 years from 2024-01-31"}
        for text, want in cases.items():
            with self.subTest(text=text):
                self.assertEqual(rec_mod().describe(rec_mod().parse_schedule(text)), want)

    def test_describe_ordinals(self):
        suffix = {1: "st", 2: "nd", 3: "rd", 21: "st", 22: "nd", 23: "rd", 31: "st"}
        for day in range(1, 32):
            with self.subTest(day=day):
                want = "on the %d%s of every month" % (day, suffix.get(day, "th"))
                self.assertEqual(rec_mod().describe(rec_mod().parse_schedule("monthly on %d" % day)), want)


if __name__ == "__main__":
    unittest.main()

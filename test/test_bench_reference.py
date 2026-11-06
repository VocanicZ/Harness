#!/usr/bin/env python3
"""test_bench_reference.py — #380: the benchmark's reference solution (bench/fixture/reference/), in
process. test_bench_fixture.sh grades it black-box through bench/grade.py; this calls its CLI helpers
directly, so a regression names the helper instead of an opaque hidden-test id."""
import argparse, contextlib, datetime, io, json, os, subprocess, sys, tempfile
from decimal import Decimal as D

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.normpath(os.path.join(HERE, "..", "bench", "fixture", "reference"))
sys.path.insert(0, REF)
sys.dont_write_bytecode = True
import pennywise                       # noqa: E402
from pennywise import cli, ledger      # noqa: E402

TEXT = "2024-03-05 rent -900\n2024-03-01 salary 2500 pay, March\n2024-03-01 fun -12.5\n2024-04-02 salary 2500\n"


def run(argv, stdin=""):
    out, err = io.StringIO(), io.StringIO()
    old = sys.stdin
    sys.stdin = io.StringIO(stdin)
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cli.main(argv)
    finally:
        sys.stdin = old
    return rc, out.getvalue(), err.getvalue()


def test_date_accepts_iso_and_rejects_the_rest():
    assert cli._date("2024-02-29") == datetime.date(2024, 2, 29)
    for bad in ("2023-02-29", "02/03/2024", "yesterday"):
        try: cli._date(bad)
        except argparse.ArgumentTypeError: continue
        raise AssertionError("accepted %r" % bad)


def test_money_has_two_decimals():
    assert cli._money(D("5")) == "5.00" and cli._money(D("-0.5")) == "-0.50"


def test_sorted_is_by_date_and_stable():
    got = cli._sorted(ledger.parse(TEXT))
    assert [(e.date.isoformat(), e.category) for e in got] == [
        ("2024-03-01", "salary"), ("2024-03-01", "fun"), ("2024-03-05", "rent"), ("2024-04-02", "salary")]


def test_emit_json_prints_one_json_line():
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        cli._emit_json({"a": "1.00"})
    assert json.loads(out.getvalue()) == {"a": "1.00"} and out.getvalue().endswith("\n")


def test_summary_by_category_and_month():
    rc, out, _ = run(["summary", "-"], TEXT)
    assert rc == 0 and out.splitlines() == ["fun  -12.50", "rent  -900.00", "salary  5000.00"], out
    rc, out, _ = run(["summary", "-", "--by", "month", "--json"], TEXT)
    assert json.loads(out) == {"2024-03": "1587.50", "2024-04": "2500.00"}, out


def test_export_csv_quotes_and_orders_like_list():
    rc, out, _ = run(["export", "-"], TEXT)
    assert rc == 0 and out.splitlines() == [
        "date,category,amount,note", '2024-03-01,salary,2500.00,"pay, March"', "2024-03-01,fun,-12.50,",
        "2024-03-05,rent,-900.00,", "2024-04-02,salary,2500.00,"], out


def test_bad_ledger_names_the_line_and_prints_nothing_else():
    rc, out, err = run(["balance", "-"], "2024-01-01 x 1\nnope\n")
    assert (rc, out) == (1, "") and "line 2" in err, (rc, out, err)


def test_module_entry_point_runs_the_cli():
    # python -m pennywise: pennywise/__main__.py hands main()'s status to sys.exit
    main_py = os.path.join(REF, "pennywise", "__main__.py")
    assert "sys.exit(main())" in open(main_py).read()
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "l.txt")
        open(path, "w").write(TEXT)
        env = dict(os.environ, PYTHONPATH=REF, PYTHONDONTWRITEBYTECODE="1")
        p = subprocess.run([sys.executable, "-m", "pennywise", "balance", path], env=env, cwd=d,
                           capture_output=True, text=True)
        assert (p.returncode, p.stdout) == (0, "4087.50\n"), (p.returncode, p.stdout, p.stderr)
        p = subprocess.run([sys.executable, "-m", "pennywise", "balance", os.path.join(d, "none")], env=env,
                           cwd=d, capture_output=True, text=True)
        assert p.returncode == 2, p.returncode


# --- #589: the shapes the brief covers that the hidden tests never pass ------------------------------------
def add_to(path, *args):
    return run(["add", path] + list(args))


def test_add_takes_a_dash_led_amount_and_note_as_typed():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "l.txt")
        rc, out, err = add_to(path, "2024-01-01", "Refund", "-5", "-refund")
        assert (rc, out, err) == (0, "2024-01-01 refund -5.00 -refund\n", ""), (rc, out, err)
        assert open(path).read() == out
        rc, out, _ = add_to(path, "2024-01-02", "x", "-0.99", "--flag and more")
        assert rc == 0 and out == "2024-01-02 x -0.99 --flag and more\n"
        rc, out, _ = add_to(path, "--", "2024-01-03", "x", "5", "-")
        assert (rc, out) == (0, "2024-01-03 x 5.00 -\n")
        assert len(open(path).read().splitlines()) == 3


def test_add_with_a_dash_led_bad_amount_is_a_ledger_mistake_not_a_usage_error():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "l.txt")
        for amount in ("-abc", "-", "-5x", "--5"):
            rc, out, err = add_to(path, "2024-01-01", "x", amount)
            assert (rc, out) == (1, "") and "bad amount" in err, (amount, rc, out, err)
        assert not os.path.exists(path)


def exit_code(argv):
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return cli.main(argv)
    except SystemExit as exc:
        return exc.code


def test_add_still_needs_its_arguments_and_still_answers_help():
    assert exit_code(["add", "f", "2024-01-01", "x"]) == 2
    assert exit_code(["add", "f", "2024-01-01", "x", "5", "n", "extra"]) == 2
    assert exit_code(["add", "--help"]) == 0


def test_add_refuses_what_would_corrupt_the_ledger():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "l.txt")
        open(path, "w").write("2024-01-01 a 1\n")
        for args in (("2024-01-02", "two words", "5"), ("2024-01-02", "", "5"), ("2024-01-02", "x", "5", "a\nb"),
                     ("2024-01-02", "x", "5", "a\rb"), ("2024-01-02\n", "x", "5"), ("2024-01-02", "x", "5\n")):
            rc, out, err = add_to(path, *args)
            assert (rc, out) == (1, "") and err, (args, rc, out, err)
        assert open(path).read() == "2024-01-01 a 1\n"


def test_add_keeps_a_file_that_is_not_utf8_as_it_was():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "l.txt")
        open(path, "wb").write(b"2024-01-01 a 1 \xff\xfe")
        rc, out, _ = add_to(path, "2024-01-02", "b", "2")
        assert rc == 0 and open(path, "rb").read() == b"2024-01-01 a 1 \xff\xfe\n2024-01-02 b 2.00\n"


def test_a_byte_order_mark_is_not_part_of_the_first_date():
    assert [e.category for e in ledger.parse("\ufeff2024-01-01 a 1\n2024-01-02 b 2\n")] == ["a", "b"]
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "l.txt")
        open(path, "wb").write(b"\xef\xbb\xbf2024-01-01 a 1\n")
        rc, out, err = run(["balance", path])
        assert (rc, out, err) == (0, "1.00\n", ""), (rc, out, err)
        open(path, "wb").write(b"2024-01-01 a 1\n2024-01-02 b 2\xff\n")
        rc, out, err = run(["balance", path])
        assert (rc, out) == (2, "") and "cannot read" in err, (rc, out, err)


def test_a_line_ends_at_lf_crlf_or_a_lone_cr_and_nowhere_else():
    for sep in ("\n", "\r\n", "\r"):
        try:
            ledger.parse("2024-01-01 a 1" + sep + "# c" + sep + "nope" + sep)
        except ledger.ParseError as exc:
            assert exc.line == 3, (repr(sep), exc.line)
        else:
            raise AssertionError("accepted a bad line")
    for odd in ("\f", "\x0b", "\x85", "\u2028", "\u2029"):
        text = "2024-01-01 a 1 x%sy\nnope\n" % odd
        try:
            ledger.parse(text)
        except ledger.ParseError as exc:
            assert exc.line == 2, (repr(odd), exc.line)
        else:
            raise AssertionError("accepted a bad line")
        assert ledger.parse("2024-01-01 a 1 x%sy\n" % odd)[0].note == "x%sy" % odd


def test_a_date_or_amount_with_a_trailing_newline_or_unicode_digits_is_refused():
    for bad in ("2024-01-01\n", "\u0662024-01-01"):
        try:
            ledger.parse_date(bad)
        except ValueError:
            continue
        raise AssertionError("accepted %r" % bad)
    for bad in ("5\n", "\u0665"):
        try:
            ledger.parse_amount(bad)
        except ValueError:
            continue
        raise AssertionError("accepted %r" % bad)


def test_negative_zero_prints_as_zero():
    assert cli._money(D("-0")) == "0.00" and ledger.format_entry(ledger.parse("2024-01-01 a -0")[0]) == "2024-01-01 a 0.00"
    rc, out, _ = run(["list", "-", "--json"], "2024-01-01 a -0\n")
    assert json.loads(out)[0]["amount"] == "0.00", out


class ClosedPipe(io.StringIO):
    def write(self, text):
        raise BrokenPipeError(32, "Broken pipe")


def test_a_reader_that_went_away_ends_the_output_quietly():
    old = sys.stdout
    sys.stdout = ClosedPipe()
    try:
        sys.stdin, keep = io.StringIO(TEXT), sys.stdin
        try:
            rc = cli.main(["list", "-"])
        finally:
            sys.stdin = keep
    finally:
        sys.stdout = old
    assert rc == 0


def test_list_into_a_closed_pipe_leaves_no_traceback():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "l.txt")
        open(path, "w").write(TEXT)
        r, w = os.pipe()
        os.close(r)                      # `pennywise list | head -0`: nobody reads
        env = dict(os.environ, PYTHONPATH=REF, PYTHONDONTWRITEBYTECODE="1")
        try:
            p = subprocess.run([sys.executable, "-m", "pennywise", "list", path], env=env, cwd=d, stdout=w,
                               stderr=subprocess.PIPE)
        finally:
            os.close(w)
        assert (p.returncode, p.stderr) == (0, b""), (p.returncode, p.stderr)


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

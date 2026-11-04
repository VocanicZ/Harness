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


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

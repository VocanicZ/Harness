#!/usr/bin/env python3
"""test_bench_shiprule.py — #620 (PRD #345): bench/shiprule.py applies the README's ship rule: at least 5 runs each; median
fuzz class count no higher than the baseline's; no class the baseline never showed; blind-review mean not down by more than
0.5. Each rule is shown to be the one that stops a change."""
import contextlib, io, json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "bench"))
sys.dont_write_bytecode = True
import shiprule                                     # noqa: E402

CR, DASH, BOM = "ledger:lone-cr x stdout", "argv:dash-led-argument x exit", "ledger:byte-order-mark x stdout"


def run(classes, review=7.0, arm="harness", status="ok"):
    counts = {c: 3 for c in classes}
    doc = {"arm": arm, "status": status, "fuzz_classes": len(counts), "fuzz_class_counts": counts,
           "fuzz_divergences": 3 * len(counts), "fuzz_cases": 1000}
    if review is not None:
        doc["review_score"] = review
    return doc


def many(n, classes, **kw):
    return [run(classes, **kw) for _ in range(n)]


BASE = many(5, [CR, DASH])


def test_the_same_fleet_ships():
    v = shiprule.evaluate(BASE, many(5, [CR, DASH]))
    assert v["ship"] and v["reasons"] == [] and all(v["rules"].values()), v


def test_fewer_classes_and_a_better_review_ship():
    assert shiprule.evaluate(BASE, many(5, [CR], review=8.0))["ship"]


def test_a_higher_median_class_count_does_not_ship():
    cand = many(3, [CR, DASH, BOM]) + many(2, [CR])
    v = shiprule.evaluate(many(5, [CR, DASH, BOM], review=7.0)[:2] + many(3, [CR, DASH]), cand)
    assert not v["ship"] and v["rules"]["median_classes"] is False, v
    assert "median class count" in v["reasons"][0]


def test_a_median_that_is_no_higher_ships_even_if_one_run_is_worse():
    cand = many(3, [CR, DASH]) + [run([CR, DASH, BOM]), run([CR])]
    v = shiprule.evaluate(BASE, cand)
    assert v["rules"]["median_classes"] is True
    assert not v["ship"] and v["rules"]["no_new_class"] is False and v["new_classes"] == [BOM], v   # but a new class is a stop


def test_a_new_class_does_not_ship_even_when_the_count_drops():
    cand = many(5, [BOM])
    v = shiprule.evaluate(BASE, cand)
    assert v["rules"]["median_classes"] is True and not v["ship"] and v["new_classes"] == [BOM], v


def test_the_review_may_drop_by_half_a_point_and_no_more():
    assert shiprule.evaluate(BASE, many(5, [CR, DASH], review=6.5))["ship"]
    v = shiprule.evaluate(BASE, many(5, [CR, DASH], review=6.4))
    assert not v["ship"] and v["rules"]["review_mean"] is False and "review mean" in v["reasons"][0], v


def test_fewer_than_five_runs_cannot_ship():
    v = shiprule.evaluate(BASE, many(4, [CR]))
    assert not v["ship"] and v["rules"] == {} and "candidate: 4 runs" in v["reasons"][0], v
    assert not shiprule.evaluate(many(4, [CR, DASH]), many(5, [CR]))["ship"]


def test_runs_without_classes_or_a_review_cannot_ship():
    v = shiprule.evaluate(BASE, many(5, [CR], review=None))
    assert not v["ship"] and any("with a review" in r for r in v["reasons"]), v
    legacy = [{"arm": "harness", "status": "ok", "fuzz_divergences": 387, "fuzz_cases": 1000}] * 5
    v = shiprule.evaluate(legacy, BASE)
    assert not v["ship"] and any("with fuzz classes" in r for r in v["reasons"]), v


def test_the_command_line_reads_files_and_folders_and_filters_by_arm():
    with tempfile.TemporaryDirectory() as tmp:
        for name, docs in (("base", BASE + many(5, [BOM], arm="plain")), ("cand", many(5, [CR], review=8.0))):
            os.makedirs(os.path.join(tmp, name))
            for i, d in enumerate(docs):
                json.dump(d, open(os.path.join(tmp, name, "%s-%d.json" % (d["arm"], i)), "w"))
        json.dump({"status": "aggregate", "arm": "harness"}, open(os.path.join(tmp, "base", "agg.json"), "w"))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = shiprule.main(["--baseline", os.path.join(tmp, "base"), "--candidate", os.path.join(tmp, "cand"), "--arm", "harness"])
        v = json.loads(out.getvalue())
        assert code == 0 and v["ship"] and v["baseline"]["runs"] == 5, v
        with contextlib.redirect_stdout(io.StringIO()):
            assert shiprule.main(["--baseline", os.path.join(tmp, "cand"), "--candidate", os.path.join(tmp, "base")]) == 1
        with contextlib.redirect_stderr(io.StringIO()):
            assert shiprule.main(["--baseline", os.path.join(tmp, "nope"), "--candidate", tmp]) == 2


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

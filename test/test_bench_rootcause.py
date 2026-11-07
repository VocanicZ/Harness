#!/usr/bin/env python3
"""test_bench_rootcause.py — #620 (PRD #345): bench/rootcause.py groups fuzz divergences into root-cause classes.
Covered: the grouping itself (one cause that many cases share is one class; a bystander feature does not open a
second; the result does not depend on the order); the pennywise features of a case; and the acceptance case: two
bugs planted in a copy of the reference that make 100 cases diverge are reported as 2 classes, while the raw count
stays 100."""
import importlib.util, os, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "bench"))
sys.dont_write_bytecode = True
import fuzz                                         # noqa: E402
import rootcause as rc                              # noqa: E402

REF = fuzz.REFERENCE_DIR
SELF_CMD = [sys.executable, "-m", "pennywise"]
LONE_CR = ("ledger.py", 'r"\\r\\n|\\r|\\n"', 'r"\\r\\n|\\n"')
DASH_ADD = ("cli.py", "args = (_add_args(argv) if argv[:1] == [\"add\"] else None)", "args = (None)")


def env_for(path):
    return dict(os.environ, PYTHONPATH=path)


def patched_copy(dest, edits):
    shutil.copytree(REF, dest, ignore=shutil.ignore_patterns("__pycache__"))
    for rel, old, new in edits:
        p = os.path.join(dest, "pennywise", rel)
        text = open(p, encoding="utf-8").read()
        assert old in text, (rel, old)
        open(p, "w", encoding="utf-8").write(text.replace(old, new))
    return dest


def case(i, argv, ledger=None, stdin=None):
    return {"id": i, "argv": argv, "ledger_hex": None if ledger is None else ledger.encode().hex(),
            "stdin_hex": None if stdin is None else stdin.encode().hex(), "closed_stdout": False}


def test_one_shared_cause_is_one_class_whatever_the_raw_count():
    items = [({"ledger:lone-cr"}, "stdout")] * 100
    assert rc.classify(items) == {"classes": 1, "class_counts": {"ledger:lone-cr x stdout": 100}}


def test_a_bystander_feature_does_not_open_a_second_class():
    items = [({"ledger:lone-cr", "ledger:byte-order-mark"}, "exit")] * 3 + [({"ledger:lone-cr"}, "exit")] * 5
    got = rc.classify(items)
    assert got["classes"] == 1 and got["class_counts"] == {"ledger:lone-cr x exit": 8}, got


def test_the_same_feature_with_another_difference_is_another_class():
    items = [({"ledger:lone-cr"}, "stdout")] * 4 + [({"ledger:lone-cr"}, "exit")] * 2
    assert rc.classify(items)["classes"] == 2


def test_a_tie_goes_to_the_rarer_feature_not_the_commoner_one():
    items = [({"ledger:comment", "ledger:lone-cr"}, "exit")]
    assert rc.classify(items)["class_counts"] == {"ledger:comment x exit": 1}                 # no population: the label decides
    pop = {"ledger:comment": 700, "ledger:lone-cr": 5}
    assert rc.classify(items, pop)["class_counts"] == {"ledger:lone-cr x exit": 1}


def test_the_grouping_does_not_depend_on_the_order_and_ties_are_stable():
    items = [({"b", "a"}, "exit"), ({"a"}, "exit"), ({"c", "d"}, "file"), ({"d"}, "file"), ({"x"}, "stdout")]
    want = rc.classify(items)
    assert want["classes"] == 3, want
    assert rc.classify(list(reversed(items))) == want
    assert rc.classify([({"p", "q"}, "exit")]) == {"classes": 1, "class_counts": {"p x exit": 1}}   # tie: lowest label


def test_a_case_with_no_feature_is_one_unmarked_class_and_no_divergence_is_no_class():
    assert rc.classify([(set(), "exit")] * 3) == {"classes": 1, "class_counts": {"unmarked x exit": 3}}
    assert rc.classify([]) == {"classes": 0, "class_counts": {}}


def test_what_differed_is_named_in_a_fixed_order():
    a = {"exit": 0, "stdout": "x", "stderr_empty": True, "file": None}
    assert rc.diff_kind(a, dict(a, exit=1, stdout="y")) == "exit"
    assert rc.diff_kind(a, dict(a, stdout="y")) == "stdout"
    assert rc.diff_kind(a, dict(a, stderr_empty=False)) == "stderr"
    assert rc.diff_kind(a, dict(a, file=["x"])) == "file"
    assert rc.diff_kind(a, None) == "missing"
    assert rc.diff_kind({"status": 200}, {"status": 400, "json": 1}) == "status"


def test_pennywise_features_name_the_oddities_of_the_input():
    f = fuzz.features
    assert f(case(0, ["balance", "ledger.txt"], "2024-01-01 a 5\r2024-01-02 b 6\r")) >= {"ledger:lone-cr"}
    assert "ledger:crlf" in f(case(0, ["list", "ledger.txt"], "2024-01-01 a 5\r\n"))
    assert "ledger:lone-cr" not in f(case(0, ["list", "ledger.txt"], "2024-01-01 a 5\r\n"))
    assert "ledger:byte-order-mark" in f(case(0, ["list", "-"], stdin="﻿2024-01-01 a 5\n"))
    assert "argv:stdin" in f(case(0, ["list", "-"], stdin="x\n"))
    assert "argv:dash-led-argument" in f(case(0, ["add", "ledger.txt", "2024-01-01", "a", "5", "-refund"]))
    assert "argv:double-dash" in f(case(0, ["add", "ledger.txt", "--", "2024-01-01", "a", "5"]))
    assert "argv:unknown-command" in f(case(0, ["frobnicate", "ledger.txt"]))
    assert "argv:no-command" in f(case(0, []))
    plain = f(case(0, ["balance", "ledger.txt"], "2024-01-01 a 5\n"))
    assert plain == {"command:balance"}, plain             # an ordinary input is labelled by its command


def test_two_planted_root_causes_that_make_100_cases_diverge_are_two_classes():
    cr_ledger = "2024-01-01 food 5\r2024-01-02 gas -3\r2024-01-03 rent 7\r"
    cases = []
    for i in range(50):                                     # root cause 1: a lone CR is no line end
        cases.append(case(i, [["balance", "summary", "list", "export"][i % 4], "ledger.txt"],
                          cr_ledger.replace("food", "f%d" % i)))
    for i in range(50, 100):                                # root cause 2: dash-led words after `add` are options
        cases.append(case(i, ["add", "ledger.txt", "2024-01-0%d" % (1 + i % 9), "food", "5", "-refund%d" % i],
                          "2024-01-01 food 1\n"))
    for i in range(100, 130):                               # innocent cases: the same for the reference
        cases.append(case(i, ["balance", "ledger.txt"], "2024-01-01 food %d\n" % i))
    with tempfile.TemporaryDirectory() as tmp:
        bug = patched_copy(os.path.join(tmp, "bug"), [LONE_CR, DASH_ADD])
        env = dict(env_for(bug), PYTHONIOENCODING="utf-8", PYTHONDONTWRITEBYTECODE="1")
        ref = (SELF_CMD, dict(env_for(REF), PYTHONIOENCODING="utf-8", PYTHONDONTWRITEBYTECODE="1"))
        found, ran, population = fuzz.execute(cases, SELF_CMD, env, ref, 300)
        clean_found, _, _ = fuzz.execute(cases[:20] + cases[100:], SELF_CMD, ref[1], ref, 300)
    assert ran == len(cases) and clean_found == []
    assert population["ledger:lone-cr"] == 50 and population["argv:dash-led-argument"] == 50, population
    got = fuzz.fragment(found, ran, "h", population)
    assert got["fuzz_divergences"] == 100, got["fuzz_class_counts"]
    assert got["fuzz_classes"] == 2, got["fuzz_class_counts"]
    assert sorted(got["fuzz_class_counts"].values()) == [50, 50], got["fuzz_class_counts"]
    assert set(k.split(" x ")[0] for k in got["fuzz_class_counts"]) == {"ledger:lone-cr", "argv:dash-led-argument"}


def test_the_large_fixtures_fuzz_reports_classes_too():
    spec = importlib.util.spec_from_file_location("large_fuzz", os.path.join(ROOT, "bench", "fixture-large", "fuzz.py"))
    large = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(large)
    assert large.step_command("tallybook --db b.db --today 2024-06-15 tx add --amount 5") == "tx add"
    assert large.step_command("GET /accounts/12/close?x=1") == "GET accounts/close"
    case_ = {"kind": "calc", "argv": ["calc", "x"], "files": {"in.csv": b"\xef\xbb\xbfa\r2\xc3\xa9".hex()},
             "stdin_hex": None, "closed_stdout": False}
    ref = [{"what": "tallybook calc money", "res": {"exit": 0}}]
    arm = [{"what": "tallybook calc money", "res": {"exit": 1}}]
    got = large.features(case_, 0, ref, arm)
    assert got == {"calc:calc money", "input:byte-order-mark", "input:lone-cr", "input:non-ascii"}, got
    assert large.difference(ref, arm, 0) == "exit"


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

#!/usr/bin/env python3
"""test_bench_crossover.py — #621 (PRD #345): bench/crossover.py, the size x arm table, the crossovers and the thresholds.

Covered: a cell from an aggregate and from a single run (n=1); the quality verdict (matches / beats / behind, the blind
review's 0.5 tolerance); the time and cost ratios; the crossover only counts at 5 runs a side; the thresholds move only
when a stated size brackets them and never from the file being rewritten (so a second run changes nothing); the
README section and tier.toml are written and `--check` finds them stale; the medium fixture is registered, sized and
shaped as the issue says (two subsystems, 6-10 issues of work), and the plain arm's scripted nudge and the Harness arm's
tier override are what the issue names."""
import importlib.util, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BENCH = os.path.join(ROOT, "bench")
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cx = load("t_crossover", os.path.join(BENCH, "crossover.py"))
fixtures = load("t_cx_fixtures", os.path.join(BENCH, "fixtures.py"))


def summ(median, lo=None, hi=None, n=5):
    return {"n": n, "median": median, "min": median if lo is None else lo, "max": median if hi is None else hi}


def agg(n=5, wall=100.0, cost=1.0, passed=80, total=80, classes=0, review=None, nudges=0):
    m = {"wall_s": summ(wall, n=n), "cost_usd": summ(cost, n=n), "hidden_passed": summ(passed, n=n), "hidden_total": summ(total, n=n),
         "fuzz_classes": summ(classes, n=n), "continue_replies": summ(nudges, n=n)}
    if review is not None:
        m["review_score"] = summ(review, n=n)
    return {"status": "aggregate", "runs_requested": 5, "runs_completed": n, "stopped": None, "aggregate": {"n": n, "metrics": m}}


def results(tmp, **sizes):
    """sizes: small={"plain": agg(), "harness": agg()} -> a results dir with run-<size>/<arm>.json and the inputs file."""
    inputs = {}
    for size, arms in sizes.items():
        inputs[size] = "run-" + size
        os.makedirs(os.path.join(tmp, "run-" + size))
        for arm, doc in arms.items():
            with open(os.path.join(tmp, "run-" + size, arm + ".json"), "w") as fh:
                json.dump(doc, fh)
    with open(os.path.join(tmp, cx.INPUTS), "w") as fh:
        json.dump(inputs, fh)
    return tmp


def build(**sizes):
    tmp = tempfile.mkdtemp()
    try:
        results(tmp, **sizes)
        return cx.build(tmp, cx.read_inputs(tmp, {}))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --- cells ------------------------------------------------------------------------------------
def test_a_cell_is_the_median_and_range_and_a_single_run_is_n_1():
    c = cx.cell(agg(wall=120.0, passed=78, total=80))
    assert c["n"] == 5 and c["wall_s"]["median"] == 120.0 and c["hidden_pct"]["median"] == 97.5 and c["interventions"] == 0
    one = cx.cell({"status": "ok", "wall_s": 60.0, "cost_usd": 0.5, "hidden_tests": {"passed": 80, "total": 80, "failed": 0}})
    assert one["n"] == 1 and one["wall_s"]["median"] == 60.0 and one["requested"] == 1


def test_a_size_with_no_run_is_not_run_and_a_missing_arm_is_left_out():
    doc = build(small={"plain": agg()})
    assert list(doc["table"]) == ["small"] and list(doc["table"]["small"]) == ["plain"] and doc["verdicts"] == {}
    md = cx.table_md(doc["table"])
    assert "**medium** (`medium`): not run" in md and "**large** (`large`): not run" in md


# --- verdicts ---------------------------------------------------------------------------------
def test_quality_matches_beats_or_is_behind_on_every_gate():
    p = cx.cell(agg(classes=3, review=6.0))
    assert cx.quality(cx.cell(agg(classes=3, review=6.0)), p)[0] == "matches"
    assert cx.quality(cx.cell(agg(classes=0, review=6.0)), p) == ("beats", ["fuzz classes"])
    assert cx.quality(cx.cell(agg(classes=4, review=9.0)), p) == ("behind", ["fuzz classes"]), "one worse gate is behind however good the rest"
    assert cx.quality(cx.cell(agg(passed=79, classes=0)), p)[0] == "behind", "a lower hidden-test pass rate is behind"
    assert cx.quality(cx.cell(agg(classes=3, review=5.6)), p)[0] == "matches", "the review may drop by 0.5"
    assert cx.quality(cx.cell(agg(classes=3, review=5.4)), p)[0] == "behind"
    bare = {"n": 5, "hidden_pct": None, "fuzz_classes": None, "review_score": None}
    assert cx.quality(bare, bare) == ("unknown", [])


def test_time_and_cost_are_ratios_and_time_is_met_only_when_harness_is_not_slower():
    doc = build(small={"plain": agg(wall=100, cost=1), "harness": agg(wall=2650, cost=14.4), "harness-3": agg(wall=90, cost=30)})
    v = doc["verdicts"]["small"]
    assert v["harness"]["time_ratio"] == 26.5 and v["harness"]["cost_ratio"] == 14.4 and not v["harness"]["time_met"]
    assert v["harness-3"]["time_met"] and v["harness-3"]["cost_ratio"] == 30.0


# --- crossovers -------------------------------------------------------------------------------
def test_the_crossover_needs_five_runs_a_side():
    four = build(small={"plain": agg(n=5, classes=3), "harness": agg(n=4, classes=0)})
    assert four["crossover"]["quality"] is None and four["crossover"]["unstated"] == ["small"]
    five = build(small={"plain": agg(classes=3), "harness": agg(classes=0)})
    assert five["crossover"]["quality"] == "small" and five["crossover"]["time"] is None


def test_the_time_crossover_is_the_smallest_size_where_three_workers_are_no_slower_and_no_worse():
    doc = build(small={"plain": agg(wall=100, classes=0), "harness": agg(wall=3000), "harness-3": agg(wall=2000)},
                medium={"plain": agg(wall=900, classes=2), "harness": agg(wall=2400), "harness-3": agg(wall=1500)},
                large={"plain": agg(wall=9000, classes=6), "harness": agg(wall=7000), "harness-3": agg(wall=4000, classes=1)})
    assert doc["crossover"]["quality"] == "small" and doc["crossover"]["time"] == "large"


# --- thresholds -------------------------------------------------------------------------------
def test_nothing_moves_without_a_stated_bracket():
    doc = build(small={"plain": agg(n=3), "harness": agg(n=3)})
    assert doc["thresholds"]["direct"] == cx.PROVISIONAL["direct"] and doc["thresholds"]["fleet"] == cx.PROVISIONAL["fleet"]
    assert doc["notes"][0].startswith("no limit moved")


def test_the_fleet_floor_falls_to_the_crossover_size_and_the_direct_limit_rises_to_the_last_sufficient_size():
    doc = build(small={"plain": agg(wall=100, classes=0), "harness": agg(wall=3000), "harness-3": agg(wall=2000)},
                medium={"plain": agg(wall=900, classes=0), "harness": agg(wall=2400), "harness-3": agg(wall=1500)},
                large={"plain": agg(wall=9000, classes=6), "harness": agg(wall=7000), "harness-3": agg(wall=4000, classes=1)})
    th, d = doc["thresholds"], doc["sizes"]
    assert th["direct"]["max_criteria"] == d["medium"]["criteria"], "plain is sufficient up to the medium fixture"
    assert th["direct"]["max_files"] == max(10, d["medium"]["files"]) and th["direct"]["max_changed_lines"] == max(500, d["medium"]["lines"])
    assert th["fleet"]["min_criteria"] == d["medium"]["criteria"] + 1, "the fleet floor stays above the direct limit"
    assert th["fleet"]["min_subsystems"] == cx.PROVISIONAL["fleet"]["min_subsystems"], "large's 5 subsystems is above the 3 already set"
    assert any(n.startswith("direct.max_criteria") for n in doc["notes"]), doc["notes"]


def test_estimates_are_fitted_only_from_two_sizes_or_more():
    one = build(small={"plain": agg(wall=100, cost=1), "harness": agg(wall=3000, cost=10)})
    assert one["thresholds"]["estimate"] == cx.PROVISIONAL["estimate"]
    two = build(small={"plain": agg(wall=180, cost=0.6), "harness": agg(wall=4000, cost=8)},
                medium={"plain": agg(wall=900, cost=3.0), "harness": agg(wall=6000, cost=20)})
    e = two["thresholds"]["estimate"]
    assert e["direct_minutes_per_criterion"] > 0 and e["fleet_usd_per_criterion"] > 0 and e != cx.PROVISIONAL["estimate"]


def test_writing_is_idempotent_and_check_finds_a_stale_file():
    tmp = tempfile.mkdtemp()
    try:
        res = results(os.path.join(tmp, "res"), small={"plain": agg(classes=3), "harness": agg(classes=0)})
        toml, readme = os.path.join(tmp, "tier.toml"), os.path.join(tmp, "README.md")
        shutil.copy(os.path.join(ROOT, "scripts", "tier.toml"), toml)
        open(readme, "w").write("# Project\n")
        argv = [sys.executable, os.path.join(BENCH, "crossover.py"), "--results-dir", res, "--tier", toml, "--readme", readme]
        assert subprocess.run(argv + ["--check"], capture_output=True).returncode == 1, "stale before it is written"
        subprocess.run(argv + ["--write-tier", toml, "--write-readme", readme], check=True)
        once = (open(toml).read(), open(readme).read())
        subprocess.run(argv + ["--write-tier", toml, "--write-readme", readme], check=True)
        assert (open(toml).read(), open(readme).read()) == once, "a second write changes nothing"
        assert subprocess.run(argv + ["--check"], capture_output=True).returncode == 0
        assert cx.START in once[1] and "## When to use Harness" in once[1] and "calibrated_from" in once[0]
        open(readme, "w").write(once[1].replace("Harness against plain", "Harness versus plain"))
        assert subprocess.run(argv + ["--check"], capture_output=True).returncode == 1
        sys.path.insert(0, os.path.join(ROOT, "scripts"))
        tier = load("t_cx_tier", os.path.join(ROOT, "scripts", "tier.py"))
        assert tier.load(toml)["direct"]["max_criteria"] >= 8, "the rewritten tier.toml still loads"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --- the medium fixture and the arms ----------------------------------------------------------
def test_the_medium_fixture_is_registered_with_its_brief_reference_hidden_tests_and_fuzz():
    fx = fixtures.load("medium")
    assert (fx.name, fx.package, fx.cmd_env, fx.phases, fx.milestones, fx.change) == ("medium", "stockroom", "STOCKROOM_CMD", False, False, None)
    for path in (fx.brief, fx.runner, fx.fuzz, os.path.join(fx.reference, "pyproject.toml"), os.path.join(fx.reference, "stockroom", "cli.py")):
        assert os.path.isfile(path), path
    assert len([n for n in os.listdir(fx.hidden) if n.startswith("test_")]) >= 1


def test_the_medium_fixture_has_two_subsystems_and_six_to_ten_issues_of_work():
    fx = fixtures.load("medium")
    doc = json.load(open(fx.shape))
    issues = {i["id"]: i for i in doc["issues"]}
    assert 6 <= len(issues) <= 10 and len(issues) == len(doc["issues"]), len(issues)
    assert sorted({i["subsystem"] for i in doc["issues"]}) == ["orders", "shelves"]
    depth = {}

    def depth_of(i, trail=()):
        assert i not in trail, "cycle through %s" % i
        if i not in depth:
            for d in issues[i]["needs"]:
                assert d in issues, "%s needs unknown %s" % (i, d)
            depth[i] = 1 + max([depth_of(d, trail + (i,)) for d in issues[i]["needs"]] or [0])
        return depth[i]

    levels = {}
    for i in issues:
        levels.setdefault(depth_of(i), []).append(i)
    assert max(len(v) for v in levels.values()) >= 2, "at least two issues can run side by side"
    sizes = cx.descriptor("medium")
    small, large = cx.descriptor("small"), cx.descriptor("large")
    assert small["lines"] < sizes["lines"] < large["lines"] and small["criteria"] < sizes["criteria"] < large["criteria"]


def test_the_medium_hidden_tests_pass_on_the_reference_and_there_are_enough_of_them():
    fx = fixtures.load("medium")
    tmp = tempfile.mkdtemp()
    try:
        env = dict(os.environ, PYTHONPATH=fx.reference, PYTHONDONTWRITEBYTECODE="1",
                   **{fx.cmd_env: json.dumps([sys.executable, "-m", "stockroom"])})
        out = os.path.join(tmp, "r.json")
        subprocess.run([sys.executable, fx.runner, "--run", out], env=env, cwd=tmp, check=True, timeout=300,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        res = json.load(open(out))
        assert len(res) >= 100, len(res)
        bad = [t["id"] + ": " + t["message"] for t in res if t["status"] != "passed"]
        assert not bad, bad[:3]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_the_medium_hidden_tests_fail_on_a_reference_with_a_planted_bug():
    fx = fixtures.load("medium")
    tmp = tempfile.mkdtemp()
    try:
        ref = os.path.join(tmp, "ref")
        shutil.copytree(fx.reference, ref)
        path = os.path.join(ref, "stockroom", "money.py")
        src = open(path).read()
        assert "(pennies * rate + 50) // 100" in src
        open(path, "w").write(src.replace("(pennies * rate + 50) // 100", "(pennies * rate + 49) // 100"))
        env = dict(os.environ, PYTHONPATH=ref, PYTHONDONTWRITEBYTECODE="1",
                   **{fx.cmd_env: json.dumps([sys.executable, "-m", "stockroom"])})
        out = os.path.join(tmp, "r.json")
        subprocess.run([sys.executable, fx.runner, "--run", out], env=env, cwd=tmp, check=True, timeout=300,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert any(t["status"] != "passed" for t in json.load(open(out))), "half-down rounding goes unnoticed"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_the_plain_arms_scripted_nudge_is_the_one_the_issue_names_and_harness_is_told_the_tier_is_fleet():
    plain = load("t_cx_plain", os.path.join(BENCH, "arms", "plain.py"))
    harness = load("t_cx_harness", os.path.join(BENCH, "arms", "harness.py"))
    assert plain.CONTINUE_REPLY == "continue until the brief is fully done"
    note = harness.AUTONOMY_NOTE
    assert "tier check" in note and "fleet" in note and "--prefer fleet" in note


def run_all():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print("  ok: %s" % name)
        except Exception as exc:   # noqa: BLE001
            import traceback
            failed += 1
            print("  FAIL: %s — %s" % (name, exc))
            traceback.print_exc()
    print("── %s" % ("all pass" if not failed else "%d FAILED" % failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(run_all())

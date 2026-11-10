#!/usr/bin/env python3
"""test_bench_large.py — #592 (PRD #345): the benchmark's large fixture and what the runner does with it.

Covered: the fixture registry (bench/fixtures.py); the mid-run change and the milestones (bench/progress.py: fired
by progress or by an arm that is done, handed over once, regressions, the first full pass); the measures in the
aggregate (caps hit, the 1 -> 3 worker speed-up); bench/grade.py scoring by module and by phase; the runner end to end
with the stub arm and the plain arm (fake gh, fake grader, fake claude): `--fixture large` seeds the large brief,
grades at milestones, injects the change once, and records the large fixture's measures; bench/figures.py's own
table for the large fixture."""
import importlib.util, json, os, shutil, stat, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import test_bench_run as tb                                    # noqa: E402  (Env, with_env, bench_run)
import test_bench_plain as tp                                  # noqa: E402  (Plain, the fake claude)

BENCH = os.path.join(tb.ROOT, "bench")
LARGE = os.path.join(BENCH, "fixture-large")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fixtures = load("t_fixtures", os.path.join(BENCH, "fixtures.py"))
progress = load("t_progress", os.path.join(BENCH, "progress.py"))
aggregate = load("t_aggregate", os.path.join(BENCH, "aggregate.py"))
grade = load("t_grade", os.path.join(BENCH, "grade.py"))
figures = load("t_figures", os.path.join(BENCH, "figures.py"))


# --- the registry -----------------------------------------------------------------------------
def test_the_registry_knows_both_fixtures_and_defaults_to_pennywise():
    assert fixtures.names() == ["pennywise", "large"] and fixtures.DEFAULT == "pennywise"
    p, lg = fixtures.load(), fixtures.load("large")
    assert (p.name, p.package, p.cmd_env, p.phases, p.milestones, p.change) == ("pennywise", "pennywise", "PENNYWISE_CMD", False, False, None)
    assert p.brief == os.path.join(BENCH, "fixture", "brief.md") and p.plain_max_replies == 20
    assert p.fuzz == os.path.join(BENCH, "fuzz.py")
    assert (lg.name, lg.package, lg.cmd_env, lg.phases, lg.milestones) == ("large", "tallybook", "TALLYBOOK_CMD", True, True)
    assert lg.change_at == 0.5 and lg.plain_max_replies == 50, "the plain arm's reply cap is raised to 50 for the large fixture"
    assert lg.brief == os.path.join(LARGE, "brief.md") and lg.runner == os.path.join(LARGE, "hidden", "run_hidden.py")
    assert lg.fuzz == os.path.join(LARGE, "fuzz.py") and lg.reference == os.path.join(LARGE, "reference")
    try:
        fixtures.load("nope")
    except ValueError as e:
        assert "nope" in str(e)
    else:
        raise AssertionError("an unknown fixture is refused")


def test_the_change_request_is_one_text_with_the_three_changes():
    text = fixtures.load("large").change
    assert text.endswith("\n") and not text.endswith("\n\n")
    for needle in ("half to even", "lock date", "LockedPeriodError", "tallybook lock", "PUT /lock", '"code"', "422"):
        assert needle in text, needle


def test_module_of_reads_the_class_name_prefix():
    lg = fixtures.load("large")
    assert [lg.module_of(i) for i in ("M07QueryTerms.test_x", "M16Api.test_y", "Other.test_z", "M7.t", "")] == ["07", "16", None, None, None]
    assert sorted(lg.modules) == ["%02d" % i for i in range(1, 17)]


def test_the_shape_is_30_to_40_issues_acyclic_at_least_4_wide_and_covers_every_module():
    doc = json.load(open(os.path.join(LARGE, "shape.json")))
    issues = {i["id"]: i for i in doc["issues"]}
    assert len(issues) == len(doc["issues"]) and 30 <= len(issues) <= 40, len(issues)
    depth = {}

    def depth_of(i, trail=()):
        assert i not in trail, "cycle through %s" % i
        if i not in depth:
            for d in issues[i]["needs"]:
                assert d in issues, "%s needs unknown %s" % (i, d)
            depth[i] = 1 + max([depth_of(d, trail + (i,)) for d in issues[i]["needs"]] or [0])
        return depth[i]
    for i in issues:
        depth_of(i)
    widths = {}
    for i, d in depth.items():
        widths[d] = widths.get(d, 0) + 1
    assert max(widths.values()) >= 4, "no depth holds 4 independent issues: 3 workers could not all be busy: %s" % widths
    assert sum(1 for w in widths.values() if w >= 4) >= 2, widths
    covered = {m for i in issues.values() for m in i["modules"]}
    assert covered == set(fixtures.load("large").modules), covered ^ set(fixtures.load("large").modules)


# --- the change and the milestones --------------------------------------------------------------
def test_the_change_is_handed_over_once_after_it_fires():
    c = progress.Change("text\n", 0.5)
    assert c.take() is None and not c.due(), "not fired: nothing to take"
    assert c.fire("progress", 51.2) is True and c.fire("arm-done") is False, "it fires once; the first trigger stays"
    assert c.due() and c.take() == "text\n" and not c.due()
    assert c.take() is None and c.take(done=True) is None, "once taken it never comes again"
    r = c.record()
    assert (r["fired"], r["trigger"], r["progress_pct"], r["delivered"], r["threshold_pct"]) == (True, "progress", 51.2, True, 50.0), r


def test_an_arm_that_is_done_before_the_change_fired_is_handed_it_then():
    c = progress.Change("late\n", 0.5)
    assert c.take(done=False) is None
    assert c.take(done=True) == "late\n"
    r = c.record()
    assert (r["fired"], r["trigger"], r["progress_pct"], r["delivered"]) == (True, "arm-done", None, True), r


def ms(t, phase, **tests):
    return {"t_s": t, "phase": phase, "tests": tests}


def test_regressions_are_tests_that_passed_at_a_milestone_and_failed_at_a_later_one():
    m = [ms(10, "pre", a=True, b=True, c=False, only_pre=True),
         ms(20, "pre", a=True, b=False, c=True, only_pre=True),
         ms(30, "post", a=True, b=False, c=True, d=False),
         ms(40, "post", a=False, b=True, c=True, d=True)]
    assert progress.regressions(m) == ["a", "b"], "b failed again after passing; a failed in the last one; c, d never regressed"
    assert progress.regressions([]) == [] and progress.regressions([ms(1, "pre", a=False), ms(2, "pre", a=True)]) == []
    s = progress.summarize(m, None)
    assert s["regressions"] == 2 and s["regressed_tests"] == ["a", "b"] and s["change"] is None
    assert [x["passed"] for x in s["milestones"]] == [3, 3, 2, 3] and [x["total"] for x in s["milestones"]] == [4, 4, 4, 4]


def test_the_first_full_pass_is_the_first_post_change_milestone_where_everything_passes():
    m = [ms(10, "pre", a=True, b=True), ms(20, "post", a=True, b=False), ms(30, "post", a=True, b=True), ms(40, "post", a=True, b=True)]
    assert progress.first_full_pass(m) == 30, "an all-pass before the change does not count"
    assert progress.first_full_pass(m[:2]) is None and progress.first_full_pass([ms(5, "post")]) is None


def test_a_milestone_is_made_from_the_graders_fragment():
    frag = {"details": {"tests": [{"id": "M01A.t1", "status": "passed"}, {"id": "M01A.t2", "status": "failed"}]}}
    assert progress.milestone_of(frag, 12.3456, "pre") == {"t_s": 12.346, "phase": "pre", "tests": {"M01A.t1": True, "M01A.t2": False}}
    assert progress.milestone_of({"details": {"error": "x"}}, 1, "pre") is None and progress.milestone_of(None, 1, "pre") is None


# --- the aggregate ------------------------------------------------------------------------------
def test_the_aggregate_counts_cap_hits_and_the_large_measures():
    docs = [{"status": "ok", "capped": None, "regressions": 2, "compactions": 1, "usd_per_passed_test": 0.5, "first_full_pass_s": 100},
            {"status": "capped", "capped": "wall", "regressions": 6, "compactions": 3, "usd_per_passed_test": 1.5},
            {"status": "capped", "capped": "cost"}, {"status": "error", "capped": None}]
    agg = aggregate.aggregate(docs)
    assert agg["n"] == 3 and agg["cap_hits"] == {"runs": 2, "of": 3, "wall": 1, "cost": 1}, agg
    assert agg["metrics"]["regressions"]["median"] == 4 and agg["metrics"]["compactions"]["max"] == 3
    assert agg["metrics"]["usd_per_passed_test"]["median"] == 1.0 and agg["metrics"]["first_full_pass_s"]["n"] == 1


def test_the_speedup_is_wall_one_over_wall_three_and_says_when_a_cap_cut_a_side_short():
    one, three = {"status": "ok", "wall_s": 3000.0, "capped": None}, {"status": "ok", "wall_s": 1200.0, "capped": None}
    assert aggregate.speedup(one, three) == {"x": 2.5, "wall_1_s": 3000.0, "wall_3_s": 1200.0, "capped": False}
    assert aggregate.speedup(dict(one, status="capped", capped="wall"), three)["capped"] is True
    agg = {"status": "aggregate", "aggregate": {"metrics": {"wall_s": {"n": 3, "median": 600.0, "min": 500.0, "max": 900.0}},
                                                 "cap_hits": {"runs": 0, "of": 3, "wall": 0, "cost": 0}}}
    assert aggregate.speedup(one, agg)["x"] == 5.0
    assert aggregate.speedup({"status": "error"}, three) is None and aggregate.speedup(one, {"status": "ok", "wall_s": 0}) is None


# --- the grader ---------------------------------------------------------------------------------
def test_the_graders_fragment_scores_each_module():
    lg = fixtures.load("large")
    tests = [{"id": "M01Money.test_a", "status": "passed"}, {"id": "M01Money.test_b", "status": "failed"},
             {"id": "M16Api.test_a", "status": "passed"}, {"id": "Odd.test", "status": "passed"}]
    f = grade.fragment(tests, 4, {}, None, lg)
    assert f["modules"] == {"01": {"passed": 1, "total": 2}, "16": {"passed": 1, "total": 1}, "other": {"passed": 1, "total": 1}}, f
    assert "modules" not in grade.fragment(tests, 4, {}, None, fixtures.load()), "pennywise has no modules"
    assert "fuzz" not in grade.fragment(tests, 4, {}), "no fuzz key when the fuzz was not run"


def test_the_grader_refuses_a_bad_fixture_or_phase():
    for args in (["--fixture", "nope"], ["--phase", "mid"]):
        p = subprocess.run([sys.executable, os.path.join(BENCH, "grade.py"), tempfile.gettempdir()] + args, capture_output=True, text=True)
        assert p.returncode == 2, (args, p.stdout, p.stderr)


# --- the runner end to end, with fakes ------------------------------------------------------------
# A grader that answers per call, from $FAKE_GRADE_SEQ ("2,4,4,..." tests passing at each call, 4 tests of the 5 below in
# the pre phase; the post phase lists a different 5th). The call counter lives in $FAKE_GRADE_STATE.
SEQ_GRADER = r'''#!/usr/bin/env python3
import json, os, sys
state = os.environ["FAKE_GRADE_STATE"]
n = sum(1 for _ in open(state)) if os.path.exists(state) else 0
open(state, "a").write(" ".join(sys.argv[2:]) + "\n")
seq = [int(x) for x in os.environ["FAKE_GRADE_SEQ"].split(",")]
passing = seq[min(n, len(seq) - 1)]
phase = sys.argv[sys.argv.index("--phase") + 1] if "--phase" in sys.argv else "post"
ids = ["M01Money.t%d" % i for i in range(4)] + ["M16Api.pre" if phase == "pre" else "M16Api.post"]
tests = [{"id": i, "status": "passed" if k < passing else "failed", "message": ""} for k, i in enumerate(ids)]
frag = {"passed": passing, "failed": len(ids) - passing, "total": len(ids), "details": {"install": "pip", "tests": tests}}
if "--tests-only" not in sys.argv:
    frag["fuzz"] = {"error": "fuzz not run in this test"}
print(json.dumps(frag))
'''


def large_env(seq, **kw):
    e = tb.Env(**kw)
    e.grader = os.path.join(e.d, "seq-grader.py")
    e.write_exe(e.grader, SEQ_GRADER)
    e.env.update(FAKE_GRADE_SEQ=seq, FAKE_GRADE_STATE=os.path.join(e.d, "grade-calls"))
    return e


def grade_calls(e):
    p = os.path.join(e.d, "grade-calls")
    return [l.split() for l in open(p).read().splitlines()] if os.path.exists(p) else []


def large_result(e, arm="stub"):
    return e.result(arm)


def test_the_large_fixture_seeds_its_brief_grades_at_milestones_and_hands_over_the_change_on_progress():
    e = large_env("0,1,3,5")
    try:
        p = e.run("stub", "--fixture", "large", "--arm-opt", "sleep=6", "--arm-opt", "change=1", "--progress-poll-secs", "0.4",
                  extra_env={})
        assert p.returncode == 0, (p.stdout, p.stderr)
        r = large_result(e)
        assert tb.bench_run.validate(r) == [], tb.bench_run.validate(r)
        assert r["fixture"] == "large" and r["run_id"] == "t1"
        calls = grade_calls(e)
        assert all("--fixture" in c and c[c.index("--fixture") + 1] == "large" for c in calls), calls
        assert any("--tests-only" in c for c in calls[:-1]) and "--tests-only" not in calls[-1], "milestones skip the fuzz; the final grade runs it"
        phases = [c[c.index("--phase") + 1] if "--phase" in c else "post" for c in calls]   # the final grade is post by default
        assert phases[0] == "pre" and phases[-1] == "post" and "pre" in phases and "post" in phases, phases
        ch = r["change"]
        assert ch["fired"] and ch["trigger"] == "progress" and ch["delivered"] and 60 <= ch["progress_pct"] <= 80, ch
        assert open(os.path.join(e.results, "t1", "stub.logs", "change.txt")).read() == fixtures.load("large").change
        assert r["counts"]["changes_taken"] == 1, r["counts"]
        assert len(r["milestones"]) == len(calls) and r["milestones"][-1]["phase"] == "post"
        assert r["milestones"][-1]["passed"] == r["hidden_tests"]["passed"] == 5
        assert r["first_full_pass_s"] is not None and r["regressions"] == 0 and r["compactions"] == 0
        assert abs(r["usd_per_passed_test"] - r["cost_usd"] / 5) < 1e-3
        ms_file = json.load(open(os.path.join(e.results, "t1", "stub.logs", "milestones.json")))
        assert len(ms_file) == len(r["milestones"]) and "M01Money.t0" in ms_file[0]["tests"]
        assert e.repos() == [] and r["repo_deleted"] is True
    finally:
        e.close()


def test_an_arm_that_finishes_before_the_change_fired_is_handed_it_then_and_a_regression_is_counted():
    e = large_env("4,4,2,2", usd_pct=None) if False else large_env("4,2,4")
    try:
        p = e.run("stub", "--fixture", "large", "--arm-opt", "sleep=0.3", "--arm-opt", "change=1", "--progress-poll-secs", "30")
        assert p.returncode == 0, (p.stdout, p.stderr)
        r = large_result(e)
        assert r["change"]["trigger"] == "arm-done" and r["change"]["delivered"] is True, r["change"]
        assert len(r["milestones"]) == 1, "no poll fell inside the run: only the final grade is a milestone"
        assert r["regressions"] == 0 and r["hidden_tests"]["passed"] == 4
    finally:
        e.close()


def test_a_test_that_passed_at_a_milestone_and_fails_in_the_final_grade_is_a_regression():
    e = large_env("5,5,3")      # the polls see 5 / 5, the final grade 3 / 5: tests t3 and the api test regressed
    try:
        p = e.run("stub", "--fixture", "large", "--arm-opt", "sleep=2", "--progress-poll-secs", "0.5")
        assert p.returncode == 0, (p.stdout, p.stderr)
        r = large_result(e)
        assert r["hidden_tests"]["passed"] == 3 and r["regressions"] == 2, (r["hidden_tests"]["passed"], r["regressions"], r["milestones"])
        assert r["regressed_tests"] == ["M01Money.t3", "M16Api.post"], r["regressed_tests"]
    finally:
        e.close()


def test_the_default_fixture_is_graded_once_and_records_no_milestones():
    e = tb.Env()
    try:
        p = e.run("stub")
        assert p.returncode == 0, (p.stdout, p.stderr)
        r = e.result()
        assert r["fixture"] == "pennywise" and "milestones" not in r and "change" not in r and "regressions" not in r
        assert "modules" not in r["hidden_tests"] and r["compactions"] == 0
        assert r["hidden_tests"]["details"]["files"] == ["brief.md"]
        brief = open(os.path.join(tb.ROOT, "bench", "fixture", "brief.md")).read()
        assert brief  # the seeded brief is the original one: see the seeding test in test_bench_run.py
    finally:
        e.close()


def test_the_large_run_has_its_own_run_id_and_directory():
    e = large_env("5")
    try:
        argv = [sys.executable, tb.RUN, "--results-dir", e.results, "--run-dir", e.rundir, "--events", e.events,
                "--poll-secs", "0.05", "--grace-secs", "2", "--grader", e.grader, "--runs", "1", "--fixture", "large", "stub"]
        p = subprocess.run(argv, env=e.env, capture_output=True, text=True, timeout=300)
        assert p.returncode == 0, (p.stdout, p.stderr)
        runs = os.listdir(e.results)
        assert len(runs) == 1 and runs[0].endswith("Z-large"), runs
    finally:
        e.close()


def test_the_speedup_lands_in_the_three_worker_results():
    d = tempfile.mkdtemp(prefix="bench-link-")
    try:
        run = os.path.join(d, "r1")
        os.makedirs(run)
        for arm, wall in (("harness", 4000.0), ("harness-3", 1600.0)):
            with open(os.path.join(run, arm + ".json"), "w") as fh:
                json.dump({"schema": 1, "arm": arm, "status": "ok", "capped": None, "wall_s": wall}, fh)
        sp = tb.bench_run.link_speedup(d, "r1")
        assert sp["x"] == 2.5
        doc = json.load(open(os.path.join(run, "harness-3.json")))
        assert doc["speedup_1_to_3"] == sp and "speedup_1_to_3" not in json.load(open(os.path.join(run, "harness.json")))
        assert tb.bench_run.link_speedup(d, "missing") is None
    finally:
        shutil.rmtree(d, ignore_errors=True)


# --- the plain arm with a change ----------------------------------------------------------------
def test_the_plain_arm_is_handed_the_change_when_it_would_stop_and_carries_on():
    p = tp.Plain(["commit|All done, pushed to main.", "commit|Brought in line with the change.", "commit|more"])
    p.e.grader = os.path.join(p.e.d, "seq-grader.py")
    p.e.write_exe(p.e.grader, SEQ_GRADER)
    p.e.env.update(FAKE_GRADE_SEQ="1", FAKE_GRADE_STATE=os.path.join(p.e.d, "grade-calls"))
    try:
        r = p.run("--fixture", "large", "--progress-poll-secs", "30")
        assert r.returncode == 0, (r.stdout, r.stderr)
        res = p.result()
        calls = p.calls()
        assert len(calls) == 2, [c["prompt"][:60] for c in calls]
        change = fixtures.load("large").change
        assert calls[1]["prompt"] == tp.plain.CHANGE_INTRO + change.rstrip("\n") + "\n" + tp.plain.CHANGE_OUTRO, calls[1]["prompt"]
        assert calls[0]["prompt"].startswith(open(os.path.join(LARGE, "brief.md")).read().rstrip("\n"))
        assert res["counts"]["continue_replies"] == 0 and res["change"]["trigger"] == "arm-done" and res["change"]["delivered"]
        assert tb.bench_run.validate(res) == []
    finally:
        p.close()


class FakeCtx:
    """What plain.turn() reads: the log dir, spawn, extra, change_due."""

    def __init__(self, logs, argvs):
        self.logs, self.extra, self.argvs, self.due_after = logs, {}, argvs, 1
        self.lines_seen, self.procs = 0, []

    def spawn(self, argv, **kw):
        p = subprocess.Popen(argv, **kw)
        self.procs.append(p)
        return p

    def change_due(self):
        self.lines_seen += 1
        return self.lines_seen > self.due_after

    def add_transcripts(self, *a):
        pass


def test_a_long_plain_turn_is_interrupted_when_the_change_is_due_and_the_session_is_kept():
    d = tempfile.mkdtemp(prefix="bench-turn-")
    try:
        slow = os.path.join(d, "claude")
        with open(slow, "w") as fh:
            fh.write("#!/usr/bin/env python3\nimport json, sys, time\nsys.stdin.read()\n"
                     "print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 's1', 'skills': [], 'plugins': [],"
                     " 'mcp_servers': [], 'slash_commands': [], 'tools': []}), flush=True)\n"
                     "for i in range(200):\n    print(json.dumps({'type': 'assistant', 'session_id': 's1', 'message': {'content': []}}), flush=True)\n"
                     "    time.sleep(0.05)\n")
        os.chmod(slow, 0o755)
        ctx = FakeCtx(d, [])
        ctx.clone = d
        t0 = time.time()
        st = tp.plain._stats()
        out = tp.plain.turn(ctx, sys.executable + " " + slow, "brief", None, 1, st, [], None)
        assert out["interrupted"] is True and out["session"] == "s1" and out["result"] is None, out
        assert time.time() - t0 < 5, "the turn was cut short, not run to its 10 s end"
    finally:
        shutil.rmtree(d, ignore_errors=True)


# --- figures ------------------------------------------------------------------------------------
def test_figures_gives_the_large_fixture_its_own_table_and_the_speedup_line():
    d = tempfile.mkdtemp(prefix="bench-fig-")
    try:
        res = os.path.join(d, "results")
        os.makedirs(os.path.join(res, "r-large"))
        base = {"schema": 1, "run_id": "r-large", "fixture": "large", "status": "ok", "capped": None, "wall_s": 3600.0, "coding_s": 3000.0,
                "testing_s": 300.0, "test_calls": 4, "tokens": {"input": 1, "output": 2, "cache_read": 3, "cache_write": 4},
                "cost_usd": 12.0, "usd_per_pct": 1.0, "usd_per_pct_source": "fallback", "weekly_window_pct": 12.0, "models": {},
                "hidden_tests": {"passed": 300, "failed": 20, "total": 320}, "counts": {"commits": 40, "continue_replies": 7},
                "caps": {"wall_s": 21600, "cost_usd": 80.0}, "repo_deleted": True, "regressions": 3, "compactions": 2,
                "usd_per_passed_test": 0.04, "first_full_pass_s": None, "quality": "skipped (docker)", "coverage": "skipped (x)",
                "change": {"fired": True, "trigger": "progress", "progress_pct": 52.5, "delivered": True}}
        for arm, wall in (("plain", 7200.0), ("harness", 4000.0), ("harness-3", 1600.0)):
            with open(os.path.join(res, "r-large", arm + ".json"), "w") as fh:
                json.dump(dict(base, arm=arm, wall_s=wall, repo="o/%s" % arm, logs=arm + ".logs"), fh)
        readme = os.path.join(d, "README.md")
        with open(readme, "w") as fh:
            fh.write("# x\n\n<!-- bench:begin — generated by bench/figures.py from bench/results/; do not edit by hand -->\n\n<!-- bench:end -->\n")
        p = subprocess.run([sys.executable, os.path.join(BENCH, "figures.py"), "--results-dir", res, "--readme", readme],
                           capture_output=True, text=True)
        assert p.returncode == 0, (p.stdout, p.stderr)
        text = open(readme).read()
        assert "### Large fixture (tallybook)" in text and "bench/results/r-large/" in text, text
        for cell in ("Wall time to first full pass", "$ per passed test", "Regressions", "Compactions", "Caps hit", "at 52.5%", "$0.040",
                     "300 / 320", "2.50x"):
            assert cell in text, cell
        assert "speed-up of 2.50x" in text and "INVALID RUN" in text, "no quality scan ran in this fixture's results"
        again = subprocess.run([sys.executable, os.path.join(BENCH, "figures.py"), "--results-dir", res, "--readme", readme, "--check"],
                               capture_output=True, text=True)
        assert again.returncode in (0, 1) and "stale" not in again.stderr.replace("stale: " + os.path.join(res, "benchmark.svg"), ""), again.stderr
    finally:
        shutil.rmtree(d, ignore_errors=True)


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

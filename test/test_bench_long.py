#!/usr/bin/env python3
"""test_bench_long.py — #1257, #1262 (PRD #345): the long-session fixture (bench/fixture-long, tabula) and the seeding of its existing code.

Covered: the registry knows `long` and its seed; the seed is an existing repo of a few thousand lines whose tests pass, the
reference is the seed plus the fourteen commands, the hidden tests pass on the reference and fail on the seed for the new commands
only, the shape (fourteen issues, one shared module, nothing needs anything) and the brief (one section per command, blind to the
hidden tests), the grader builds it with pip, the fuzz finds nothing on the reference and finds a planted bug, and `Gh.seed`
commits the seed beside the brief (and only the brief when a fixture has no seed)."""
import importlib.util, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BENCH = os.path.join(ROOT, "bench")
LONG = os.path.join(BENCH, "fixture-long")
sys.dont_write_bytecode = True
COMMANDS = ["sort", "filter", "group", "join", "pivot", "dedupe", "stats", "select", "rename", "rank", "concat", "melt", "window", "bucket"]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fixtures = load("t_long_fixtures", os.path.join(BENCH, "fixtures.py"))
fuzz = load("t_long_fuzz", os.path.join(LONG, "fuzz.py"))
runmod = load("t_long_run", os.path.join(BENCH, "run.py"))


def lines_of(root):
    total = 0
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        total += sum(len(open(os.path.join(base, f), encoding="utf-8").read().splitlines()) for f in files)
    return total


def py(args, cwd, pythonpath=None, **kw):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", BENCH_FUZZ_CASES="30")
    env.pop("TABULA_CMD", None)
    if pythonpath:
        env["PYTHONPATH"] = pythonpath
    return subprocess.run([sys.executable] + args, cwd=cwd, env=env, capture_output=True, text=True, timeout=600, **kw)


def grade(repo):
    p = py([os.path.join(BENCH, "grade.py"), repo, "--fixture", "long"], BENCH)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)


def test_the_registry_knows_the_long_fixture_and_its_seed():
    fx = fixtures.load("long")
    assert fixtures.names()[-1] == "long"
    assert (fx.name, fx.package, fx.cmd_env, fx.phases, fx.milestones, fx.change) == ("long", "tabula", "TABULA_CMD", False, False, None)
    assert fx.seed == os.path.join(LONG, "seed") and os.path.isdir(fx.seed)
    assert fx.brief == os.path.join(LONG, "brief.md") and fx.fuzz == os.path.join(LONG, "fuzz.py")
    assert fixtures.load("medium").seed is None and fixtures.load().seed is None


def test_the_seed_is_an_existing_repo_of_a_few_thousand_lines_with_passing_tests():
    seed = os.path.join(LONG, "seed")
    engine = os.path.join(seed, "tabula", "engine.py")
    assert lines_of(seed) >= 2000 and len(open(engine, encoding="utf-8").read().splitlines()) >= 1000
    for name in COMMANDS:
        assert "def cmd_%s(" % name not in open(engine, encoding="utf-8").read(), name
    p = py(["-m", "unittest", "discover", "tests"], seed, seed)
    assert p.returncode == 0, p.stderr[-500:]


def test_the_reference_is_the_seed_plus_the_fourteen_commands():
    seed, ref = os.path.join(LONG, "seed"), os.path.join(LONG, "reference")
    for base, dirs, files in os.walk(seed):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for f in files:
            assert os.path.isfile(os.path.join(ref, os.path.relpath(os.path.join(base, f), seed))), f
    text = open(os.path.join(ref, "tabula", "engine.py"), encoding="utf-8").read()
    for name in COMMANDS:
        assert "def cmd_%s(" % name in text and '"%s": (cmd_%s' % (name, name) in text, name


def test_the_hidden_tests_pass_on_the_reference_and_fail_on_the_seed_for_the_new_commands():
    ref = grade(os.path.join(LONG, "reference"))
    assert ref["failed"] == 0 and ref["total"] >= 160 and ref["details"]["install"] == "pip", ref["details"].get("error")
    assert ref["fuzz"]["fuzz_divergences"] == 0 and ref["fuzz"]["fuzz_cases"] == 30
    seed = grade(os.path.join(LONG, "seed"))
    failed = {t["id"].split(".")[0] for t in seed["details"]["tests"] if t["status"] != "passed"}
    assert seed["total"] == ref["total"] and 0 < seed["passed"] < seed["total"]
    assert failed == {"SortTests", "FilterTests", "GroupTests", "JoinTests", "PivotTests", "DedupeTests", "StatsTests", "SelectTests", "RenameTests", "RankTests", "ConcatTests", "MeltTests", "WindowTests", "BucketTests"}, failed


def test_the_shape_is_fourteen_independent_issues_on_one_module_and_the_brief_has_a_section_each():
    shape = json.load(open(os.path.join(LONG, "shape.json"), encoding="utf-8"))
    issues = shape["issues"]
    assert len(issues) == 14 and len({i["id"] for i in issues}) == len(issues)
    assert all(i["edits"] == shape["shared_module"] == "tabula/engine.py" and i["needs"] == [] for i in issues)
    brief = open(os.path.join(LONG, "brief.md"), encoding="utf-8").read()
    assert [l[3:] for l in brief.splitlines() if l.startswith("## ")][:14] == COMMANDS
    for needle in ("hidden", "reference", "fixture-long", "TABULA_CMD"):
        assert needle not in brief, needle
    assert "tabula/engine.py" in brief


def test_the_fuzz_finds_nothing_on_the_reference_and_finds_a_planted_bug():
    assert fuzz.run([sys.executable, "-m", "tabula"], dict(os.environ, PYTHONPATH=fuzz.REFERENCE_DIR), cases=60)["fuzz_divergences"] == 0
    assert fuzz.generate(20) == fuzz.generate(500)[:20] and fuzz.case_hash(fuzz.generate(5)) == fuzz.case_hash(fuzz.generate(5))
    d = tempfile.mkdtemp(prefix="long-bug-")
    try:
        bug = os.path.join(d, "ref")
        shutil.copytree(fuzz.REFERENCE_DIR, bug, ignore=shutil.ignore_patterns("__pycache__"))
        path = os.path.join(bug, "tabula", "engine.py")
        text = open(path, encoding="utf-8").read()
        assert 'opts.get("keep", "first") == "last"' in text
        open(path, "w", encoding="utf-8").write(text.replace('opts.get("keep", "first") == "last"', 'opts.get("keep", "first") == "never"'))
        got = fuzz.run([sys.executable, "-m", "tabula"], dict(os.environ, PYTHONPATH=bug), cases=500)
        assert got["fuzz_divergences"] > 0 and got["fuzz_examples"] and "dedupe" in got["fuzz_examples"][0]["command"], got
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_gh_seed_commits_the_existing_code_beside_the_brief_and_only_the_brief_without_one():
    d = tempfile.mkdtemp(prefix="long-seed-")
    try:
        for name, existing, want in (("with", os.path.join(LONG, "seed"), True), ("without", None, False)):
            bare, clone = os.path.join(d, name + ".git"), os.path.join(d, name)
            subprocess.run(["git", "init", "-q", "--bare", bare], check=True)
            subprocess.run(["git", "clone", "-q", bare, clone], check=True, capture_output=True)
            runmod.Gh(lambda msg: None).seed("o/r", clone, fixtures.load("long").brief, existing)
            files = subprocess.run(["git", "-C", bare, "ls-tree", "-r", "--name-only", "main"], capture_output=True, text=True, check=True).stdout.split()
            assert ("tabula/engine.py" in files and "pyproject.toml" in files and "tests/test_engine.py" in files) == want, files
            assert "brief.md" in files and not any("__pycache__" in f for f in files)
            if not want:
                assert files == ["brief.md"]
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

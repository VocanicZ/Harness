#!/usr/bin/env python3
"""test_bench_testcov.py — #588 (PRD #345): bench/testcov.py, line and branch coverage of an arm's own tests,
subprocesses counted. Covered: a repo whose CLI is only reached through `python -m pkg` child processes still
reports that code as covered (and the same repo's untested branch as missed); the total / line / branch
percentages; a missing tests/ directory, a missing repo and a missing coverage.py are `coverage: "skipped
(<reason>)"` with exit 0, never an error; --arm-json merges the fragment into an arm's results file."""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TESTCOV = os.path.join(ROOT, "bench", "testcov.py")
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(ROOT, "bench"))
import testcov as bench_testcov                      # noqa: E402

try:
    import coverage  # noqa: F401
    HAVE_COVERAGE = True
except ImportError:
    HAVE_COVERAGE = False

CORE = '''def sign(n):
    if n < 0:
        return "neg"
    return "pos"
'''
CLI = '''import sys
from .core import sign


def main(argv=None):
    n = int((argv if argv is not None else sys.argv[1:])[0])
    print(sign(n))
    return 0
'''
MAIN = "import sys\nfrom .cli import main\nsys.exit(main())\n"
# the only way these tests reach cli.py / __main__.py is a child process; core.sign is called in-process for
# "pos" only when PARTIAL, and for both signs through the child otherwise
TESTS_FULL = '''import subprocess, sys, unittest


class T(unittest.TestCase):
    def run_cli(self, n):
        return subprocess.run([sys.executable, "-m", "pkg", n], capture_output=True, text=True).stdout.strip()

    def test_both(self):
        self.assertEqual(self.run_cli("-3"), "neg")
        self.assertEqual(self.run_cli("3"), "pos")
'''
TESTS_PARTIAL = TESTS_FULL.replace('        self.assertEqual(self.run_cli("-3"), "neg")\n', "")


def make_repo(tests, with_tests_dir=True):
    d = tempfile.mkdtemp(prefix="bench-testcov-")
    for rel, text in (("src/pkg/__init__.py", ""), ("src/pkg/core.py", CORE), ("src/pkg/cli.py", CLI),
                      ("src/pkg/__main__.py", MAIN)) + ((("tests/test_t.py", tests),) if with_tests_dir else ()):
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            fh.write(text)
    return d


def cli(repo, *args):
    p = subprocess.run([sys.executable, TESTCOV, repo, *args], capture_output=True, text=True, timeout=300)
    assert p.returncode == 0, (p.returncode, p.stdout, p.stderr)
    return json.loads(p.stdout)


def test_code_reached_only_through_a_subprocess_counts():
    if not HAVE_COVERAGE:
        print("  skip: coverage.py is not installed here"); return
    d = make_repo(TESTS_FULL)
    try:
        c = cli(d)["coverage"]
        # core.py, cli.py and __main__.py run only in child processes: all of it, both branches, is covered
        assert c == {"line_pct": 100.0, "branch_pct": 100.0, "total_pct": 100.0, "tests": "unittest"}, c
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_an_untested_branch_lowers_branch_and_total_coverage():
    if not HAVE_COVERAGE:
        print("  skip: coverage.py is not installed here"); return
    d = make_repo(TESTS_PARTIAL)
    try:
        c = cli(d)["coverage"]
        assert c["branch_pct"] == 50.0 and c["line_pct"] < 100.0 and c["line_pct"] > 80.0, c
        assert c["branch_pct"] < c["total_pct"] < 100.0, c
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_the_repo_itself_is_left_untouched():
    if not HAVE_COVERAGE:
        print("  skip: coverage.py is not installed here"); return
    d = make_repo(TESTS_FULL)
    try:
        before = sorted(os.path.join(r, f) for r, _, fs in os.walk(d) for f in fs)
        cli(d)
        assert sorted(os.path.join(r, f) for r, _, fs in os.walk(d) for f in fs) == before
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_no_tests_directory_is_a_skip_not_an_error():
    d = make_repo("", with_tests_dir=False)
    try:
        c = cli(d)["coverage"]
        assert c in ("skipped (the repo has no tests/ directory)", "skipped (coverage.py is not installed (pip install coverage))"), c
        if HAVE_COVERAGE:
            assert c == "skipped (the repo has no tests/ directory)", c
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_a_missing_repo_is_a_skip():
    c = cli(os.path.join(tempfile.gettempdir(), "bench-testcov-does-not-exist"))["coverage"]
    assert c.startswith("skipped (") and "no repo to measure" in c or "coverage.py is not installed" in c, c


def test_without_coverage_py_the_run_is_skipped_with_how_to_fix_it():
    saved = sys.modules.get("coverage", "absent")
    sys.modules["coverage"] = None                      # `import coverage` now raises ImportError
    d = make_repo(TESTS_FULL)
    try:
        assert bench_testcov.fragment(d) == {"coverage": "skipped (coverage.py is not installed (pip install coverage))"}
    finally:
        if saved == "absent":
            sys.modules.pop("coverage", None)
        else:
            sys.modules["coverage"] = saved
        shutil.rmtree(d, ignore_errors=True)


def test_arm_json_gets_the_fragment_merged_in():
    d = make_repo(TESTS_FULL, with_tests_dir=False)
    try:
        arm = os.path.join(d, "plain.json")
        with open(arm, "w") as fh:
            json.dump({"arm": "plain", "status": "ok"}, fh)
        f = cli(d, "--arm-json", arm)
        assert json.load(open(arm)) == dict({"arm": "plain", "status": "ok"}, **f)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_pytest_is_used_only_for_a_suite_that_does_not_use_unittest():
    d = tempfile.mkdtemp(prefix="bench-testcov-")
    try:
        os.makedirs(os.path.join(d, "tests"))
        with open(os.path.join(d, "tests", "test_a.py"), "w") as fh:
            fh.write("def test_a():\n    assert True\n")
        assert bench_testcov.test_argv(d)[1] == "pytest"
        with open(os.path.join(d, "tests", "test_b.py"), "w") as fh:
            fh.write("import unittest\n")
        assert bench_testcov.test_argv(d)[1] == "unittest"
    finally:
        shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

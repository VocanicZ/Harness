#!/usr/bin/env python3
"""testcov.py — line and branch coverage of one benchmark arm's own test suite (#588, PRD #345). NEVER blocking.

    bench/testcov.py <repo-dir> [--arm-json FILE] [--timeout 600]

Runs the arm's own tests (`python -m unittest discover -s tests`, the benchmark's convention; pytest when the
repo has no unittest-style test but asks for it in its README) on a throwaway copy of <repo-dir> — an arm's
final default branch — under coverage.py with branch measurement, and prints a results fragment as JSON:

    {"coverage": {"line_pct": 95.7, "branch_pct": 86.7, "total_pct": 94.0, "tests": "unittest"}}
    {"coverage": "skipped (coverage.py is not installed)"}

SUBPROCESSES COUNT. The pennywise CLI is mostly exercised by tests that run `python -m pennywise` in a child
process, which a plain `coverage run` does not see. So the run sets `parallel = True` and `COVERAGE_PROCESS_START`
and puts a `sitecustomize` on PYTHONPATH that calls `coverage.process_startup()`: every Python child writes its
own data file, and they are combined before reporting. The measured source is the repo's `src/` (else the repo
root minus its tests); the tests themselves are not counted. `total_pct` is coverage.py's own branch-aware
total (covered lines + covered branches over statements + branches), the figure `coverage report` prints.

With --arm-json the fragment is also merged into that arm's results file (bench/run.py does the same through
this module). coverage.py missing, tests that do not run, no measurable source: `coverage: "skipped (<reason>)"`
and exit 0 — the bench never fails because of this. Exit 2 is bad arguments only. Stdlib + coverage.py.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile

sys.dont_write_bytecode = True
COPY_IGNORE = shutil.ignore_patterns(".git", "__pycache__", "*.pyc", ".harness", ".venv", "venv", "node_modules")
SITECUSTOMIZE = "import coverage\ncoverage.process_startup()\n"


class Skip(Exception):
    """A reason coverage cannot be had. Never an error of the bench."""


def skipped(reason):
    return {"coverage": "skipped (" + " ".join(str(reason).split())[:300] + ")"}


def _run(argv, env, cwd, timeout):
    try:
        return subprocess.run(argv, env=env, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Skip(f"{os.path.basename(argv[2] if len(argv) > 2 else argv[0])} timed out after {timeout:g}s")
    except OSError as e:
        raise Skip(f"cannot run {argv[0]}: {e}")


def has_unittest_tests(tests_dir):
    for root, _, files in os.walk(tests_dir):
        for f in files:
            if f.startswith("test") and f.endswith(".py"):
                try:
                    with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
                        if "unittest" in fh.read():
                            return True
                except OSError:
                    pass
    return False


def test_argv(copy):
    """The module run under coverage: unittest discovery, or pytest for a suite that does not use unittest."""
    tests = os.path.join(copy, "tests")
    if not os.path.isdir(tests):
        raise Skip("the repo has no tests/ directory")
    if has_unittest_tests(tests):
        return ["-m", "unittest", "discover", "-s", "tests"], "unittest"
    return ["-m", "pytest", "-q", "tests"], "pytest"


def measure(repo_dir, timeout=600.0):
    """{"line_pct", "branch_pct", "tests"} for the repo's own tests; raises Skip with the reason when it cannot be had."""
    if not os.path.isdir(repo_dir):
        raise Skip(f"no repo to measure at {repo_dir}")
    try:
        import coverage  # noqa: F401  (importable here means importable in the children: same interpreter)
    except ImportError:
        raise Skip("coverage.py is not installed (pip install coverage)")
    work = tempfile.mkdtemp(prefix="bench-cov-")
    try:
        copy = os.path.join(work, "repo")
        shutil.copytree(repo_dir, copy, symlinks=True, ignore=COPY_IGNORE)
        src = os.path.join(copy, "src")
        sources = src if os.path.isdir(src) else copy
        data = os.path.join(work, "data")
        os.makedirs(data)
        site = os.path.join(work, "site")
        os.makedirs(site)
        with open(os.path.join(site, "sitecustomize.py"), "w", encoding="utf-8") as fh:
            fh.write(SITECUSTOMIZE)
        rc = os.path.join(work, "coveragerc")
        omit = "" if sources == src else f"omit =\n    {copy}/tests/*\n"
        with open(rc, "w", encoding="utf-8") as fh:
            fh.write(f"[run]\nbranch = True\nparallel = True\nsigterm = True\nsource =\n    {sources}\n"
                     f"data_file = {data}/.coverage\n{omit}")
        argv, kind = test_argv(copy)
        env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP")}
        env.update(PYTHONPATH=os.pathsep.join([site, sources, copy]), COVERAGE_PROCESS_START=rc,
                   PYTHONDONTWRITEBYTECODE="1", PYTHONIOENCODING="utf-8", COVERAGE_RCFILE=rc)
        p = _run([sys.executable, "-m", "coverage", "run", "--rcfile", rc] + argv, env, copy, timeout)
        if not [f for f in os.listdir(data) if f.startswith(".coverage")]:
            raise Skip("the tests wrote no coverage data: " + " ".join((p.stderr or p.stdout).strip().splitlines()[-1:])[-150:])
        c = _run([sys.executable, "-m", "coverage", "combine", "--rcfile", rc, data], env, copy, 120)
        if c.returncode != 0:
            raise Skip("coverage combine failed: " + (c.stderr or c.stdout).strip()[-150:])
        out = os.path.join(work, "cov.json")
        j = _run([sys.executable, "-m", "coverage", "json", "--rcfile", rc, "-o", out], env, copy, 120)
        if j.returncode != 0 or not os.path.isfile(out):
            raise Skip("coverage json failed: " + (j.stderr or j.stdout).strip()[-150:])
        with open(out, encoding="utf-8") as fh:
            t = json.load(fh).get("totals", {})
        stmts, branches = t.get("num_statements", 0), t.get("num_branches", 0)
        if not stmts:
            raise Skip("no measurable source code")
        line = 100.0 * t.get("covered_lines", 0) / stmts
        branch = 100.0 * t.get("covered_branches", 0) / branches if branches else None
        if branch is None:
            raise Skip("the source has no branches to measure")
        return {"line_pct": round(line, 1), "branch_pct": round(branch, 1),
                "total_pct": round(100.0 * (t.get("covered_lines", 0) + t.get("covered_branches", 0)) /
                                   (stmts + branches), 1), "tests": kind}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def fragment(repo_dir, **kw):
    """{"coverage": {...} | "skipped (<reason>)"} — never raises."""
    try:
        return {"coverage": measure(repo_dir, **kw)}
    except Skip as e:
        return skipped(e)
    except Exception as e:   # anything unforeseen is still a skip: this must not fail a bench run
        return skipped(f"unexpected {type(e).__name__}: {e}")


def merge_into(path, frag):
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    doc.update(frag)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Line and branch coverage of an arm's own tests, subprocesses counted.")
    ap.add_argument("repo_dir")
    ap.add_argument("--arm-json", help="merge the fragment into this arm results file")
    ap.add_argument("--timeout", type=float, default=600.0)
    a = ap.parse_args(argv)
    frag = fragment(os.path.abspath(a.repo_dir), timeout=a.timeout)
    if a.arm_json:
        try:
            merge_into(a.arm_json, frag)
        except (OSError, ValueError) as e:
            print(f"testcov.py: could not update {a.arm_json}: {e}", file=sys.stderr)
    print(json.dumps(frag))
    return 0


if __name__ == "__main__":
    sys.exit(main())

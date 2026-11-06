#!/usr/bin/env python3
"""grade.py — score a checked-out repo against the benchmark's hidden tests.

    bench/grade.py REPO_DIR            # JSON fragment on stdout
    bench/grade.py REPO_DIR --fuzz-only [--arm-json RESULTS.json]   # only the fuzz fragment (a backfill)

REPO_DIR is a checkout of a run's final default branch. It is copied (never modified) into a
throwaway directory, built there with `pip install --target` (no network, no build isolation), and
the hidden tests in bench/fixture/hidden/ are run against that copy. When the build fails, the copy
itself is put on PYTHONPATH and the CLI runs as `python -m pennywise`; the fragment says which.

Then the same build is fuzzed against the reference implementation (bench/fuzz.py, #589): the same random argv and
ledger files through both, counting where standard output, standard error being empty or the exit status differ.

Emits one JSON object, always exit 0 once it could grade (even for a score of 0):

    {"passed": N, "failed": N, "total": N,
     "details": {"install": "pip"|"pythonpath", "tests": [{"id", "status", "message"}], "error"?},
     "fuzz": {"fuzz_cases": N, "fuzz_divergences": N, "fuzz_examples": [≤10], "fuzz_seed": N, "fuzz_hash": "…"}
              | {"error": "…"}}

Exit 2 only when REPO_DIR is not a directory. Stdlib only.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HIDDEN = os.path.join(HERE, "fixture", "hidden")
RUNNER = os.path.join(HIDDEN, "run_hidden.py")
INSTALL_TIMEOUT = 180
RUN_TIMEOUT = 600
COPY_IGNORE = shutil.ignore_patterns(".git", "__pycache__", "*.pyc", ".harness", ".venv", "venv", "node_modules")


def run_runner(mode, out_path, env=None, cwd=None, timeout=RUN_TIMEOUT):
    subprocess.run([sys.executable, RUNNER, mode, out_path], env=env, cwd=cwd, timeout=timeout,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    with open(out_path, encoding="utf-8") as fh:
        return json.load(fh)


def build(copy, work, env):
    """Install the copy into work/site; return (mode, PYTHONPATH, CLI argv)."""
    site = os.path.join(work, "site")
    try:
        subprocess.run([sys.executable, "-m", "pip", "install", "--no-deps", "--no-build-isolation", "--no-index",
                        "--quiet", "--target", site, copy], env=env, cwd=work, timeout=INSTALL_TIMEOUT,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    except (subprocess.SubprocessError, OSError):
        shutil.rmtree(site, ignore_errors=True)
    else:
        for name in ("pennywise", "pennywise.exe", "pennywise.cmd"):
            script = os.path.join(site, "bin", name) if os.name != "nt" else os.path.join(site, "Scripts", name)
            if os.path.isfile(script):
                return "pip", site, [script]
        return "pip", site, [sys.executable, "-m", "pennywise"]
    path = os.pathsep.join([copy, os.path.join(copy, "src")])
    return "pythonpath", path, [sys.executable, "-m", "pennywise"]


def fragment(tests, total, details, fuzz=None):
    passed = sum(1 for t in tests if t["status"] == "passed")
    out = {"passed": passed, "failed": total - passed, "total": total, "details": details}
    if fuzz is not None:
        out["fuzz"] = fuzz
    return out


def run_fuzz(argv, env, cases=None, cap_s=None):
    """bench/fuzz.py against the built copy; never fails the grade: a fuzz that could not run says why."""
    try:
        spec = importlib.util.spec_from_file_location("bench_fuzz", os.path.join(HERE, "fuzz.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.run(argv, env, cases=cases or int(os.environ.get("BENCH_FUZZ_CASES") or mod.CASES),
                       cap_s=cap_s or float(os.environ.get("BENCH_FUZZ_CAP_S") or mod.CAP_S))
    except (Exception, SystemExit) as exc:
        return {"error": ("fuzz did not run: %s" % (exc if isinstance(exc, SystemExit) else type(exc).__name__))[:300]}


def prepare(repo, work):
    """Copy `repo` into work/repo and build it there: (mode, env for running it, CLI argv)."""
    copy = os.path.join(work, "repo")
    shutil.copytree(repo, copy, symlinks=True, ignore=COPY_IGNORE)
    cache = os.path.join(work, "cache")
    os.makedirs(cache)
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP")}
    # HOME stays: a user-site pip/setuptools lives under it. Only the caches move to the throwaway dir.
    env.update(XDG_CACHE_HOME=cache, PIP_CACHE_DIR=cache, PYTHONDONTWRITEBYTECODE="1",
               PIP_DISABLE_PIP_VERSION_CHECK="1", PIP_NO_INPUT="1", PYTHONIOENCODING="utf-8")
    mode, pythonpath, argv = build(copy, work, env)
    env.update(PYTHONPATH=pythonpath, PENNYWISE_CMD=json.dumps(argv))
    return mode, env, argv


def grade(repo):
    work = tempfile.mkdtemp(prefix="bench-grade-")
    try:
        ids = run_runner("--list", os.path.join(work, "ids.json"))
        total = len(ids)
        mode, env, argv = prepare(repo, work)
        details = {"install": mode, "tests": []}
        try:
            tests = run_runner("--run", os.path.join(work, "results.json"), env=env, cwd=work)
        except (subprocess.SubprocessError, OSError, ValueError) as exc:
            details["error"] = "hidden tests did not finish: %s" % type(exc).__name__
            tests = []
        by_id = {t["id"]: t for t in tests}
        details["tests"] = [by_id.get(i, {"id": i, "status": "failed", "message": "did not run"}) for i in ids]
        return fragment(details["tests"], total, details, run_fuzz(argv, env))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def fuzz_only(repo):
    """Just the fuzz fragment for `repo` (a backfill of a run graded before bench/fuzz.py existed)."""
    work = tempfile.mkdtemp(prefix="bench-grade-")
    try:
        _, env, argv = prepare(repo, work)
        return run_fuzz(argv, env)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def merge_fuzz(arm_json, fuzz):
    """Put a fuzz fragment into an arm's results JSON (`fuzz_*` keys) and into its logs' grade.json."""
    with open(arm_json, encoding="utf-8") as fh:
        doc = json.load(fh)
    for key in [k for k in doc if k.startswith("fuzz_")]:
        del doc[key]
    if "error" in fuzz:
        doc["fuzz_error"] = fuzz["error"]
    else:
        doc.update(fuzz)
    with open(arm_json, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    grade_json = os.path.join(os.path.dirname(os.path.abspath(arm_json)), str(doc.get("logs") or ""), "grade.json")
    if os.path.isfile(grade_json):
        with open(grade_json, encoding="utf-8") as fh:
            frag = json.load(fh)
        frag["fuzz"] = fuzz
        with open(grade_json, "w", encoding="utf-8") as fh:
            json.dump(frag, fh, indent=2, ensure_ascii=False)
            fh.write("\n")


def main(argv):
    args = argv[1:]
    only = "--fuzz-only" in args
    arm_json = None
    if "--arm-json" in args:
        at = args.index("--arm-json")
        arm_json = args[at + 1] if at + 1 < len(args) else None
        args = args[:at] + args[at + 2:]
    args = [a for a in args if a != "--fuzz-only"]
    if len(args) != 1 or args[0] in ("-h", "--help") or (arm_json and not only) or ("--arm-json" in argv and not arm_json):
        print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
        return 2
    if not os.path.isdir(args[0]):
        print("grade.py: not a directory: %s" % args[0], file=sys.stderr)
        return 2
    if only:
        fuzz = fuzz_only(os.path.abspath(args[0]))
        if arm_json:
            merge_fuzz(arm_json, fuzz)
        print(json.dumps(fuzz, indent=2))
        return 0
    print(json.dumps(grade(os.path.abspath(args[0])), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

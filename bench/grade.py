#!/usr/bin/env python3
"""grade.py — score a checked-out repo against the benchmark's hidden tests.

    bench/grade.py REPO_DIR            # JSON fragment on stdout

REPO_DIR is a checkout of a run's final default branch. It is copied (never modified) into a
throwaway directory, built there with `pip install --target` (no network, no build isolation), and
the hidden tests in bench/fixture/hidden/ are run against that copy. When the build fails, the copy
itself is put on PYTHONPATH and the CLI runs as `python -m pennywise`; the fragment says which.

Emits one JSON object, always exit 0 once it could grade (even for a score of 0):

    {"passed": N, "failed": N, "total": N,
     "details": {"install": "pip"|"pythonpath", "tests": [{"id", "status", "message"}], "error"?}}

Exit 2 only when REPO_DIR is not a directory. Stdlib only.
"""
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


def fragment(tests, total, details):
    passed = sum(1 for t in tests if t["status"] == "passed")
    return {"passed": passed, "failed": total - passed, "total": total, "details": details}


def grade(repo):
    work = tempfile.mkdtemp(prefix="bench-grade-")
    try:
        ids = run_runner("--list", os.path.join(work, "ids.json"))
        total = len(ids)
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
        details = {"install": mode, "tests": []}
        try:
            tests = run_runner("--run", os.path.join(work, "results.json"), env=env, cwd=work)
        except (subprocess.SubprocessError, OSError, ValueError) as exc:
            details["error"] = "hidden tests did not finish: %s" % type(exc).__name__
            tests = []
        by_id = {t["id"]: t for t in tests}
        details["tests"] = [by_id.get(i, {"id": i, "status": "failed", "message": "did not run"}) for i in ids]
        return fragment(details["tests"], total, details)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
        return 2
    if not os.path.isdir(argv[1]):
        print("grade.py: not a directory: %s" % argv[1], file=sys.stderr)
        return 2
    print(json.dumps(grade(os.path.abspath(argv[1])), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

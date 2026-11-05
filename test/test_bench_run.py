#!/usr/bin/env python3
"""test_bench_run.py — #381 (PRD #345): the benchmark runner core, bench/run.py. gh is a fake on PATH
(bare repos in a temp dir), the arm is bench/arms/stub.py, usage comes from a stub HARNESS_USAGE_CMD.
Covered: a run creates a private repo seeded with the brief only, records a schema-valid results JSON
and deletes the repo (also on failure, cap and a failed delete); the guard refuses a usage-HELD account,
short headroom, no weekly reading and no $ per 1%, and --dry-run creates and spends nothing; a stub
arm over the wall or $ cap is stopped and recorded as capped."""
import glob, json, os, shutil, stat, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RUN = os.path.join(ROOT, "bench", "run.py")
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(ROOT, "bench"))
import run as bench_run                      # noqa: E402

FAKE_GH = r'''#!/usr/bin/env bash
H="$FAKE_GH_HOME"; echo "gh $*" >> "$H/calls.log"
case "$1 $2" in
  "api user") echo bencher;;
  "repo create") n="${3#*/}"; git init -q --bare -b main "$H/repos/$n.git" && echo "$*" > "$H/repos/$n.create";;
  "repo clone") n="${3#*/}"; git clone -q "$H/repos/$n.git" "$4" 2>/dev/null;;
  "repo delete") [[ -n "${FAKE_GH_DELETE_FAIL:-}" ]] && { echo "no delete_repo scope" >&2; exit 1; }
                 n="${3#*/}"; rm -rf "$H/repos/$n.git" "$H/repos/$n.create";;
  "api -X") :;;
  *) echo "fake gh: unexpected $*" >&2; exit 9;;
esac
'''
# No test may start a real SonarQube: the fake docker on PATH has no daemon, so bench/quality.py skips.
FAKE_DOCKER = r'''#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2; exit 1
'''
FAKE_GRADER = r'''#!/usr/bin/env python3
import json, os, sys
files = sorted(os.listdir(sys.argv[1]))
print(json.dumps({"passed": 3, "failed": 1, "total": 4, "details": {"files": [f for f in files if f != ".git"]}}))
'''
USAGE = "printf 'acct\\tseven_day\\t%s\\t0\\n' %s"


class Env:
    def __init__(self, usage_pct="10", per_pct="1"):
        self.d = tempfile.mkdtemp(prefix="bench-test-")
        self.h = os.path.join(self.d, "gh"); os.makedirs(os.path.join(self.h, "repos"))
        self.bin = os.path.join(self.d, "bin"); os.makedirs(self.bin)
        self.write_exe(os.path.join(self.bin, "gh"), FAKE_GH)
        self.write_exe(os.path.join(self.bin, "docker"), FAKE_DOCKER)
        self.grader = os.path.join(self.d, "grader.py"); self.write_exe(self.grader, FAKE_GRADER)
        self.results = os.path.join(self.d, "results")
        self.rundir = os.path.join(self.d, "run"); os.makedirs(self.rundir)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("HARNESS_") and k not in ("RUN_DIR", "STATE_DIR")}
        self.env.update(PATH=self.bin + os.pathsep + os.environ["PATH"], FAKE_GH_HOME=self.h, PYTHONDONTWRITEBYTECODE="1",
                        HARNESS_FLEETS_DIR=os.path.join(self.d, "home", "fleets"),   # #541: the host pins move together
                        CLAUDE_CONFIG_DIR=os.path.join(self.d, "acct"), HARNESS_HOME=os.path.join(self.d, "home"))
        if usage_pct is not None:
            self.env["HARNESS_USAGE_CMD"] = USAGE % (usage_pct, "")
        if per_pct is not None:
            self.env["HARNESS_ONE_USD_PER_PCT"] = per_pct
        os.makedirs(os.path.join(self.d, "acct"))

    @staticmethod
    def write_exe(path, text):
        with open(path, "w") as fh:
            fh.write(text)
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)

    def run(self, *args, grader=True, extra_env=None):
        argv = [sys.executable, RUN, "--results-dir", self.results, "--run-dir", self.rundir,
                "--events", os.path.join(self.d, "no-events.jsonl"), "--poll-secs", "0.05", "--grace-secs", "2",
                "--run-id", "t1"] + (["--grader", self.grader] if grader else []) + list(args)
        return subprocess.run(argv, env=dict(self.env, **(extra_env or {})), capture_output=True, text=True, timeout=300)

    def calls(self):
        p = os.path.join(self.h, "calls.log")
        return open(p).read().splitlines() if os.path.exists(p) else []

    def repos(self):
        return glob.glob(os.path.join(self.h, "repos", "*.git"))

    def result(self, arm="stub"):
        return json.load(open(os.path.join(self.results, "t1", arm + ".json")))

    def close(self):
        shutil.rmtree(self.d, ignore_errors=True)


def with_env(**kw):
    def deco(fn):
        def wrapped():
            e = Env(**kw)
            try:
                fn(e)
            finally:
                e.close()
        wrapped.__name__ = fn.__name__
        return wrapped
    return deco


@with_env()
def test_stub_run_records_a_valid_result_and_deletes_the_repo(e):
    p = e.run("stub", "--arm-opt", "cost=2")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert bench_run.validate(r) == [], bench_run.validate(r)
    assert (r["status"], r["capped"], r["error"]) == ("ok", None, None)
    assert r["repo"].startswith("bencher/bench-t1-stub"), r["repo"]
    assert r["repo_deleted"] is True and e.repos() == []
    # private, no Actions, and the repo held the brief and nothing else
    assert any(c.startswith("gh repo create") and "--private" in c for c in e.calls()), e.calls()
    assert any("actions/permissions" in c and "enabled=false" in c for c in e.calls()), e.calls()
    assert r["hidden_tests"]["details"]["files"] == ["brief.md"], r["hidden_tests"]
    assert (r["hidden_tests"]["passed"], r["hidden_tests"]["total"]) == (3, 4)
    # measured from the transcript: tokens, models, $ at list price, coding vs testing, counts
    assert r["tokens"]["output"] == 80000 and r["tokens"]["input"] == 10, r["tokens"]
    assert list(r["models"]) == ["claude-opus-4-1"] and abs(r["cost_usd"] - 2.0) < 0.01, (r["models"], r["cost_usd"])
    assert r["testing_s"] == 1 and r["coding_s"] == 2 and r["test_calls"] == 1, r
    assert r["counts"] == {"commits": 1, "stub": 1}, r["counts"]
    assert abs(r["weekly_window_pct"] - 2.0) < 0.01 and r["usd_per_pct_source"] == "fallback", r
    assert r["caps"] == {"wall_s": 21600, "cost_usd": 80.0}
    logs = os.path.join(e.results, "t1", "stub.logs")
    for f in ("run.log", "grade.json"):
        assert os.path.isfile(os.path.join(logs, f)), f
    assert glob.glob(os.path.join(logs, "transcripts", "*.jsonl")), "transcripts kept as raw logs"


@with_env()
def test_without_docker_the_run_records_quality_skipped_and_exits_0(e):
    p = e.run("stub")                                   # the fake docker has no daemon
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert r["quality"].startswith("skipped (docker daemon not reachable"), r["quality"]
    assert "sonarqube" not in r and bench_run.validate(r) == [], bench_run.validate(r)
    assert r["status"] == "ok" and r["repo_deleted"] is True


QUALITY_OK = r'''#!/usr/bin/env python3
import json, os, sys
assert os.path.isfile(os.path.join(sys.argv[1], "brief.md")), "scans the graded clone"
print(json.dumps({"quality": "ok", "sonarqube": {"bugs": 2, "vulnerabilities": 0, "code_smells": 7,
      "maintainability_rating": "A", "duplicated_lines_density": 1.5, "coverage": None}}))
'''


@with_env()
def test_a_quality_scan_is_recorded_beside_the_arm_results(e):
    q = os.path.join(e.d, "quality_ok.py"); e.write_exe(q, QUALITY_OK)
    p = e.run("stub", "--quality", q)
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert r["quality"] == "ok" and r["sonarqube"]["bugs"] == 2 and r["sonarqube"]["maintainability_rating"] == "A", r
    assert bench_run.validate(r) == []


@with_env()
def test_a_quality_scan_that_fails_never_fails_the_run(e):
    bad = os.path.join(e.d, "quality_bad.py"); e.write_exe(bad, "#!/usr/bin/env python3\nimport sys\nprint('boom', file=sys.stderr); sys.exit(7)\n")
    p = e.run("stub", "--quality", bad)
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert r["quality"].startswith("skipped (quality scan failed") and "boom" in r["quality"], r["quality"]
    assert r["status"] == "ok" and bench_run.validate(r) == [] and e.repos() == []
    junk = os.path.join(e.d, "quality_junk.py"); e.write_exe(junk, "#!/usr/bin/env python3\nprint('not json')\n")
    assert e.run("stub", "--quality", junk).returncode == 0
    assert e.result()["quality"].startswith("skipped (quality scan failed")


@with_env()
def test_wall_cap_stops_the_arm_and_is_recorded_as_capped(e):
    p = e.run("stub", "--arm-opt", "sleep=60", "--wall-cap-secs", "0.4")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert (r["status"], r["capped"]) == ("capped", "wall"), r
    assert bench_run.validate(r) == [] and r["wall_s"] < 30, r["wall_s"]
    assert r["repo_deleted"] is True and e.repos() == []


@with_env()
def test_cost_cap_stops_the_arm_and_is_recorded_as_capped(e):
    p = e.run("stub", "--arm-opt", "cost=100", "--arm-opt", "sleep=60", "--expected-usd", "1")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert (r["status"], r["capped"]) == ("capped", "cost"), r
    assert r["cost_usd"] >= 80 and r["wall_s"] < 30, (r["cost_usd"], r["wall_s"])
    assert bench_run.validate(r) == [] and e.repos() == []


@with_env()
def test_a_failing_arm_is_recorded_and_the_repo_still_deleted(e):
    p = e.run("stub", "--arm-opt", "fail=1")
    assert p.returncode == 1, (p.stdout, p.stderr)
    r = e.result()
    assert r["status"] == "error" and "told to fail" in r["error"], r
    assert bench_run.validate(r) == [] and r["repo_deleted"] is True and e.repos() == []


@with_env()
def test_a_repo_that_cannot_be_deleted_is_named_and_flagged(e):
    p = e.run("stub", extra_env={"FAKE_GH_DELETE_FAIL": "1"})
    assert p.returncode == 4, (p.returncode, p.stderr)
    assert "COULD NOT DELETE bencher/bench-t1-stub" in p.stderr, p.stderr
    assert e.result()["repo_deleted"] is False


@with_env()
def test_guard_refuses_while_an_account_is_usage_held(e):
    os.makedirs(os.path.join(e.rundir, "usage-holds"))
    open(os.path.join(e.rundir, "usage-holds", "acct.hold"), "w").write("acct\tseven_day\t95\t0\n")
    p = e.run("stub")
    assert p.returncode == 3 and "usage-HELD" in p.stderr and "acct" in p.stderr, (p.returncode, p.stderr)
    assert e.calls() == [] and not os.path.exists(e.results), "a refused run creates and records nothing"


@with_env(usage_pct="50")
def test_guard_refuses_when_forecast_headroom_is_short(e):
    p = e.run("stub")   # 50% now + $80 at $1 per 1% + 2% reserve > 98%
    assert p.returncode == 3 and "50% now + 80% expected" in p.stderr, (p.returncode, p.stderr)
    assert e.calls() == [] and not os.path.exists(e.results)
    # the same window fits a smaller expected spend, and 98% is the line
    assert e.run("stub", "--dry-run", "--expected-usd", "46").returncode == 0
    assert e.run("stub", "--dry-run", "--expected-usd", "47").returncode == 3


@with_env(usage_pct=None)
def test_guard_refuses_without_a_usage_reading(e):
    e.env["HARNESS_USAGE_CMD"] = "exit 1"
    p = e.run("stub")
    assert p.returncode == 3 and "no weekly usage reading" in p.stderr, (p.returncode, p.stderr)
    assert e.calls() == []


@with_env(per_pct=None)
def test_guard_refuses_without_a_usd_per_pct(e):
    p = e.run("stub")
    assert p.returncode == 3 and "no $ per 1%" in p.stderr, (p.returncode, p.stderr)
    assert e.calls() == []


@with_env()
def test_dry_run_shows_the_decision_and_spends_nothing(e):
    p = e.run("stub", "--dry-run")
    assert p.returncode == 0 and "bench guard: OK" in p.stdout and "acct seven_day 10% + 80% + 2% = 92%" in p.stdout, p.stdout
    assert e.calls() == [] and not os.path.exists(e.results) and e.repos() == []
    os.makedirs(os.path.join(e.rundir, "usage-holds"))
    open(os.path.join(e.rundir, "usage-holds", "acct.hold"), "w").write("acct\tseven_day\t95\t0\n")
    p = e.run("stub", "--dry-run")
    assert p.returncode == 3 and "REFUSED" in p.stderr and e.calls() == []


@with_env()
def test_unknown_arm_and_bad_options_are_usage_errors(e):
    assert e.run("nope").returncode == 2
    assert e.run("../stub").returncode == 2
    assert e.run("stub", "--arm-opt", "novalue").returncode == 2
    assert e.run("stub", "--wall-cap-secs", "0").returncode == 2
    assert e.calls() == []


@with_env()
def test_the_real_grader_scores_the_seeded_repo_zero(e):
    # nothing but the brief was seeded: the hidden tests all fail, and the grader does not crash
    p = e.run("stub", grader=False)
    assert p.returncode == 0, (p.stdout, p.stderr)
    h = e.result()["hidden_tests"]
    assert h["passed"] == 0 and h["total"] and h["failed"] == h["total"], h


def test_validate_names_what_is_wrong():
    good = {"schema": 1, "run_id": "x", "arm": "a", "repo": "o/r", "status": "ok", "capped": None, "error": None,
            "started_at": "t", "ended_at": "t", "wall_s": 1.0, "coding_s": None, "testing_s": None, "test_calls": None,
            "tokens": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0}, "cost_usd": 0.0, "usd_per_pct": None,
            "usd_per_pct_source": "none", "weekly_window_pct": None, "models": {},
            "hidden_tests": {"passed": 0, "failed": 0, "total": 0}, "counts": {},
            "caps": {"wall_s": 1, "cost_usd": 1}, "repo_deleted": True, "logs": "a.logs"}
    assert bench_run.validate(good) == []
    assert bench_run.validate(dict(good, status="capped")) != []                 # capped without a cap
    assert bench_run.validate(dict(good, status="ok", capped="wall")) != []       # a cap on an ok run
    assert bench_run.validate({k: v for k, v in good.items() if k != "tokens"}) == ["missing tokens"]
    assert bench_run.validate(dict(good, wall_s="1")) != []
    assert bench_run.validate(dict(good, tokens={"input": 0})) != []
    assert bench_run.validate(dict(good, quality="skipped (no docker)")) == []
    assert bench_run.validate(dict(good, quality="ok", sonarqube={"bugs": 0})) == []
    assert bench_run.validate(dict(good, quality="ok")) != []                     # ok without measures
    assert bench_run.validate(dict(good, quality="skipped (x)", sonarqube={})) != []


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

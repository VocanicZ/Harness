#!/usr/bin/env python3
"""test_bench_run.py — #381 (PRD #345): the benchmark runner core, bench/run.py. gh is a fake on PATH
(bare repos in a temp dir), the arm is bench/arms/stub.py, usage comes from a stub HARNESS_USAGE_CMD.
Covered: a run creates a private repo seeded with the brief only, records a schema-valid results JSON
and deletes the repo (also on failure, cap and a failed delete); the guard refuses a usage-HELD account,
short headroom, no weekly reading and no $ per 1%, and --dry-run creates and spends nothing; a stub
arm over the wall or $ cap is stopped and recorded as capped."""
import glob, importlib.util, json, os, shutil, stat, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RUN = os.path.join(ROOT, "bench", "run.py")
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(ROOT, "bench"))
import run as bench_run                      # noqa: E402

FAKE_GH = r'''#!/usr/bin/env bash
H="$FAKE_GH_HOME"
if [[ "$1 $2" == "api -i" ]]; then   # the guard's read-only scope probe (#578): not a call that creates or spends
  echo "HTTP/2.0 200 OK"; echo "Content-Type: application/json"
  [[ "${FAKE_GH_SCOPES-unset}" != "none" ]] && echo "X-Oauth-Scopes: ${FAKE_GH_SCOPES-gist, read:org, repo, workflow, delete_repo}"
  echo; echo '{"login":"bencher"}'; exit 0
fi
echo "gh $*" >> "$H/calls.log"
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
        self.env["BENCH_MIN_FREE_GB"] = "0"   # these tests are not about the host's disk: see the disk-guard tests
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
        if not any(a == "--runs" or a.startswith("--runs=") for a in args):
            argv += ["--runs", "1"]   # most tests are about one run; the default of 5 has its own (#591)
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
    assert list(r["models"]) == ["claude-opus-4-5"] and abs(r["cost_usd"] - 2.0) < 0.01, (r["models"], r["cost_usd"])
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


@with_env(usage_pct="97")
def test_a_negative_nan_inf_or_non_numeric_budget_is_a_usage_error_never_a_pass(e):   # #709
    for opt in ("--expected-usd", "--cost-cap-usd"):
        for bad in ("-50", "-0.01", "nan", "NaN", "inf", "-inf", "1e999", "ten", ""):
            p = e.run("stub", "--dry-run", opt + "=" + bad)
            assert p.returncode == 2 and opt in p.stderr and "bench guard" not in p.stdout, (opt, bad, p.returncode, p.stdout, p.stderr)
    assert e.calls() == [] and not os.path.exists(e.results)
    # a real overspend is still a guard refusal (exit 3), not a usage error
    assert e.run("stub", "--dry-run", "--expected-usd=10").returncode == 3


@with_env(usage_pct="50")
def test_a_nan_inf_zero_or_negative_time_option_is_a_usage_error_naming_it(e):   # #747
    for opt in ("--wall-cap-secs", "--poll-secs", "--grace-secs", "--progress-poll-secs"):
        for bad in ("nan", "NaN", "inf", "-inf", "1e999", "0", "-1", "-0.5", "ten", ""):
            p = e.run("stub", "--dry-run", opt + "=" + bad)
            assert p.returncode == 2 and opt in p.stderr and "bench guard" not in p.stdout, (opt, bad, p.returncode, p.stdout, p.stderr)
        assert e.run("stub", "--dry-run", opt + "=0.5", "--expected-usd=1").returncode == 0, opt
    assert e.calls() == [] and not os.path.exists(e.results)


@with_env(usage_pct="50")
def test_a_time_option_above_threading_timeout_max_is_a_usage_error_naming_the_limit(e):   # #858
    import threading
    limit = format(threading.TIMEOUT_MAX, "g")
    for opt in ("--poll-secs", "--grace-secs", "--progress-poll-secs", "--wall-cap-secs"):
        for bad in ("100000000000000000000", "1" + "0" * 40, str(int(threading.TIMEOUT_MAX) + 1000)):
            p = e.run("stub", "--dry-run", opt + "=" + bad)
            assert p.returncode == 2 and opt in p.stderr and limit in p.stderr and "bench guard" not in p.stdout, (opt, bad, p.returncode, p.stdout, p.stderr)
        assert e.run("stub", "--dry-run", opt + "=" + str(int(threading.TIMEOUT_MAX) - 1000), "--expected-usd=1").returncode == 0, opt
    assert e.calls() == [] and not os.path.exists(e.results)


@with_env(usage_pct="50")
def test_a_run_dir_that_is_missing_empty_or_not_a_directory_is_a_usage_error(e):   # #860
    os.makedirs(os.path.join(e.rundir, "usage-holds"))
    with open(os.path.join(e.rundir, "usage-holds", "acct.hold"), "w") as fh:
        fh.write("acct\tseven_day\t99\n")
    assert e.run("stub", "--dry-run").returncode == 3   # the hold is read from a real run dir
    afile = os.path.join(e.d, "afile")
    open(afile, "w").close()
    for bad in ("/nonexistent/run", "-x", "", afile):
        p = e.run("stub", "--dry-run", "--run-dir=" + bad)
        assert p.returncode == 2 and "--run-dir" in p.stderr and "bench guard" not in p.stdout, (bad, p.returncode, p.stdout, p.stderr)
    assert e.calls() == [] and not os.path.exists(e.results)


@with_env(usage_pct="50")
def test_money_and_seconds_options_are_ascii_decimal_only(e):   # #805
    for opt in ("--cost-cap-usd", "--expected-usd", "--wall-cap-secs", "--poll-secs", "--grace-secs", "--progress-poll-secs"):
        for bad in ("\uff15", "\u0663", "1_0", "+5", "1\uff10", "\u0665.\u0665", "1_0.5", "+0.5"):
            p = e.run("stub", "--dry-run", opt + "=" + bad)
            assert p.returncode == 2 and opt in p.stderr and "bench guard" not in p.stdout, (opt, bad, p.returncode, p.stdout, p.stderr)
        for good in ("5", "0.5", "5.", ".5"):
            assert e.run("stub", "--dry-run", opt + "=" + good, "--expected-usd=1").returncode == 0, (opt, good)
    assert e.calls() == [] and not os.path.exists(e.results)


@with_env(usage_pct="50")
def test_a_zero_expected_budget_is_accepted(e):   # #709
    assert e.run("stub", "--dry-run", "--expected-usd", "0").returncode == 0


@with_env(usage_pct="10")
def test_a_bad_numeric_env_knob_refuses_the_run(e):   # #709
    assert e.run("stub", "--dry-run").returncode == 0
    for name, bad in (("HARNESS_ONE_STOP_PCT", "nan"), ("HARNESS_ONE_STOP_PCT", "inf"), ("HARNESS_ONE_STOP_PCT", "-5"),
                      ("HARNESS_ONE_STOP_PCT", "250"), ("HARNESS_ONE_STOP_PCT", "high"),
                      ("HARNESS_ONE_RESERVE_PCT", "nan"), ("HARNESS_ONE_RESERVE_PCT", "-50"),
                      ("HARNESS_ONE_RESERVE_PCT", "inf"), ("BENCH_MIN_FREE_GB", "nan"), ("BENCH_MIN_FREE_GB", "-1")):
        p = e.run("stub", "--dry-run", extra_env={name: bad})
        assert p.returncode == 3 and "REFUSED" in p.stderr and name in p.stderr, (name, bad, p.returncode, p.stdout, p.stderr)
        assert e.calls() == [] and not os.path.exists(e.results)
    # an optional arm records the refusal as a skip, with the cause
    p = e.run("stub", "--optional", extra_env={"HARNESS_ONE_STOP_PCT": "nan"})
    assert p.returncode == 0 and e.result()["status"] == "skipped" and e.result()["reason"] == "bad-setting", (p.stdout, p.stderr)
    assert bench_run.validate(e.result()) == []
    # a valid value is still honoured, an empty one is the default
    assert e.run("stub", "--dry-run", extra_env={"HARNESS_ONE_STOP_PCT": "100"}).returncode == 0
    assert e.run("stub", "--dry-run", extra_env={"HARNESS_ONE_STOP_PCT": ""}).returncode == 0


@with_env(usage_pct="10")
def test_the_env_knobs_and_usage_pct_take_only_ascii_decimal_numbers(e):   # #835
    forms = ("1_0", "+5", "\uff15", "\uff15\uff10", "1\uff10")
    for name in ("HARNESS_ONE_STOP_PCT", "HARNESS_ONE_RESERVE_PCT", "BENCH_MIN_FREE_GB"):
        for bad in forms:
            p = e.run("stub", "--dry-run", extra_env={name: bad})
            assert p.returncode == 3 and "REFUSED" in p.stderr and f"{name}=" in p.stderr, (name, bad, p.returncode, p.stderr)
            assert e.calls() == [] and not os.path.exists(e.results)
    # a plain ASCII value still works
    assert e.run("stub", "--dry-run", extra_env={"HARNESS_ONE_STOP_PCT": "99.5"}).returncode == 0
    # a usage pct in those forms is no reading: the guard has nothing to go on and refuses
    for bad in forms:
        e.env["HARNESS_USAGE_CMD"] = f"printf 'acct\\tseven_day\\t{bad}\\t0\\n'"
        p = e.run("stub", "--dry-run")
        assert p.returncode == 3 and "no weekly usage reading" in p.stderr, (bad, p.returncode, p.stderr)
    assert bench_run._num("1_0") is None and bench_run._num("+5") is None and bench_run._num("\uff15") is None
    assert bench_run._num(" 12.5 ") == 12.5 and bench_run._num("-3") == -3 and bench_run._num(".5") == 0.5


@with_env(usage_pct="97")
def test_a_non_finite_usage_reading_or_usd_per_pct_refuses(e):   # #709
    e.env["HARNESS_USAGE_CMD"] = "printf 'acct\\tseven_day\\tnan\\t0\\n'"
    p = e.run("stub", "--dry-run")
    assert p.returncode == 3 and "no weekly usage reading" in p.stderr, (p.stdout, p.stderr)
    e.env["HARNESS_USAGE_CMD"] = "printf 'acct\\tseven_day\\t10\\t0\\n'"
    for bad in ("inf", "nan"):
        p = e.run("stub", "--dry-run", "--expected-usd", "5", extra_env={"HARNESS_ONE_USD_PER_PCT": bad})
        assert p.returncode == 3 and "REFUSED" in p.stderr, (bad, p.stdout, p.stderr)
    # a set but unusable value is "invalid" and named, never "unset" (#746); a tiny one is refused too
    for bad in ("inf", "nan", "1e-300", "0", "-2", "nope"):
        p = e.run("stub", "--dry-run", "--expected-usd", "5", extra_env={"HARNESS_ONE_USD_PER_PCT": bad})
        assert p.returncode == 3 and f"HARNESS_ONE_USD_PER_PCT={bad} invalid" in p.stderr, (bad, p.stdout, p.stderr)
        assert "unset" not in p.stderr, (bad, p.stderr)


@with_env(usage_pct="10")
def test_a_usage_reading_outside_0_100_is_refused_naming_the_value(e):   # #757
    for bad in ("-5", "-0.5", "100.5", "140"):
        e.env["HARNESS_USAGE_CMD"] = f"printf 'acct\\tseven_day\\t{bad}\\t0\\n'"
        p = e.run("stub", "--dry-run")
        assert p.returncode == 3 and "REFUSED" in p.stderr, (bad, p.stdout, p.stderr)
        assert f"usage reading {bad} for acct seven_day is outside 0-100%" in p.stderr, (bad, p.stderr)
        assert "-5% +" not in p.stderr and "% now" not in p.stderr, (bad, p.stderr)   # no arithmetic on it
    # the bounds themselves are readings
    for ok in ("0", "100"):
        e.env["HARNESS_USAGE_CMD"] = f"printf 'acct\\tseven_day\\t{ok}\\t0\\n'"
        p = e.run("stub", "--dry-run")
        assert "outside 0-100" not in p.stderr, (ok, p.stderr)


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
def test_a_run_id_that_would_leave_the_results_dir_is_a_usage_error_and_writes_nothing(e):   # #674
    for bad in ("../escaped", "a/b", "a\\b", "..", "x..y", "/abs", ""):
        for extra in ((), ("--optional",)):
            p = e.run("stub", "--run-id=" + bad, *extra)
            assert p.returncode == 2 and "--run-id" in p.stderr, (bad, extra, p.returncode, p.stderr)
    assert not os.path.exists(os.path.join(e.d, "escaped")) and not os.path.exists(e.results), os.listdir(e.d)
    assert e.calls() == []


@with_env()
def test_a_run_id_must_be_one_safe_component_of_bounded_length(e):   # #717
    for bad in (".", "-x", "--flag", "x" * 129, "5000".join(["y"] * 1250), "a b", "a:b", "a\nb", "ünï", "x\n"):
        for extra in ((), ("--optional",)):
            p = e.run("stub", "--run-id=" + bad, *extra)
            assert p.returncode == 2 and "--run-id" in p.stderr, (bad[:20], extra, p.returncode, p.stderr)
    assert not os.path.exists(e.results), os.listdir(e.d)
    assert e.calls() == []
    for ok in ("run-20261106", "x" * 128, "a.b_c-d", ".hidden", "r1"):
        p = e.run("stub", "--run-id=" + ok, "--dry-run")
        assert p.returncode == 0, (ok[:20], p.returncode, p.stderr)


@with_env()
def test_an_owner_must_be_a_valid_github_owner_name_before_any_gh_call(e):   # #836
    for bad in ("-x", "-", "--flag", "a--b", "x-", "", "a b", "a/b", "a_b", "a.b", "x\n", "ünï", "x" * 40):
        for extra in ((), ("--optional",), ("--dry-run",)):
            p = e.run("stub", "--owner=" + bad, *extra)
            assert p.returncode == 2 and "--owner" in p.stderr, (bad[:20], extra, p.returncode, p.stderr)
    p = e.run("stub", "--owner", "-")
    assert p.returncode == 2 and "--owner" in p.stderr, (p.returncode, p.stderr)
    assert not os.path.exists(e.results), os.listdir(e.d)
    assert e.calls() == []
    for ok in ("octocat", "a", "a-b", "A1-b2", "x" * 39, "7up"):
        p = e.run("stub", "--owner=" + ok, "--dry-run")
        assert p.returncode == 0, (ok[:20], p.returncode, p.stderr)


@with_env()
def test_results_dir_must_be_non_empty_and_not_dash_leading(e):   # #862
    for bad in ("", "-x", "-", "--flag"):
        for extra in ((), ("--optional",), ("--dry-run",)):
            p = e.run("stub", "--results-dir=" + bad, *extra)
            assert p.returncode == 2 and "--results-dir" in p.stderr, (bad, extra, p.returncode, p.stderr)
    assert not os.path.exists(e.results), os.listdir(e.d)
    assert e.calls() == []
    p = e.run("stub", "--results-dir", "-")
    assert p.returncode == 2 and "--results-dir" in p.stderr, (p.returncode, p.stderr)
    p = e.run("stub", "--results-dir=" + e.results, "--dry-run")
    assert p.returncode == 0, (p.returncode, p.stderr)


@with_env()
def test_the_real_grader_scores_the_seeded_repo_zero(e):
    # nothing but the brief was seeded: the hidden tests all fail, and the grader does not crash
    p = e.run("stub", grader=False, extra_env={"BENCH_FUZZ_CASES": "20"})
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    h = r["hidden_tests"]
    assert h["passed"] == 0 and h["total"] and h["failed"] == h["total"], h
    # #589: nothing built to fuzz is not an error: most cases diverge from the reference, none crash the grader
    assert r["fuzz_cases"] == 20 and 10 < r["fuzz_divergences"] <= 20 and "fuzz" not in h, r
    assert bench_run.validate(r) == [] and len(r["fuzz_examples"]) == 10, r


FUZZ_GRADER = r'''#!/usr/bin/env python3
import json
print(json.dumps({"passed": 3, "failed": 1, "total": 4, "details": {"install": "pip", "tests": []},
                  "fuzz": {"fuzz_cases": 1000, "fuzz_divergences": 7, "fuzz_examples": [{"case": 4}],
                           "fuzz_seed": 589, "fuzz_hash": "ab" * 32}}))
'''
FUZZ_ERROR_GRADER = FUZZ_GRADER.replace('{"fuzz_cases": 1000, "fuzz_divergences": 7, "fuzz_examples": [{"case": 4}],\n                           "fuzz_seed": 589, "fuzz_hash": "ab" * 32}', '{"error": "fuzz did not run: OSError"}')


@with_env()
def test_the_fuzz_fragment_becomes_fuzz_fields_and_stays_out_of_hidden_tests(e):
    e.write_exe(e.grader, FUZZ_GRADER)
    assert e.run("stub").returncode == 0
    r = e.result()
    assert bench_run.validate(r) == [], bench_run.validate(r)
    assert (r["fuzz_cases"], r["fuzz_divergences"], r["fuzz_seed"], r["fuzz_hash"]) == (1000, 7, 589, "ab" * 32), r
    assert r["fuzz_examples"] == [{"case": 4}] and "fuzz" not in r["hidden_tests"], r
    assert (r["hidden_tests"]["passed"], r["hidden_tests"]["total"]) == (3, 4)
    kept = json.load(open(os.path.join(e.results, "t1", "stub.logs", "grade.json")))
    assert kept["fuzz"]["fuzz_divergences"] == 7, kept


@with_env()
def test_a_fuzz_that_could_not_run_is_recorded_not_fatal(e):
    e.write_exe(e.grader, FUZZ_ERROR_GRADER)
    assert e.run("stub").returncode == 0
    r = e.result()
    assert r["fuzz_error"] == "fuzz did not run: OSError" and "fuzz_cases" not in r and bench_run.validate(r) == [], r


def test_fuzz_fields_reads_only_what_the_grader_gave():
    assert bench_run.fuzz_fields(None) == {} and bench_run.fuzz_fields("x") == {}
    got = bench_run.fuzz_fields({"fuzz_cases": 5, "fuzz_divergences": 1, "fuzz_examples": [], "fuzz_seed": 1,
                                 "fuzz_hash": "h", "junk": 1})
    assert got == {"fuzz_cases": 5, "fuzz_divergences": 1, "fuzz_examples": [], "fuzz_seed": 1, "fuzz_hash": "h"}
    assert bench_run.fuzz_fields({"error": "boom"}) == {"fuzz_error": "boom"}
    assert bench_run.fuzz_fields({}) == {"fuzz_error": "fuzz did not run"}


@with_env(usage_pct="50")
def test_an_optional_arm_the_guard_refuses_is_recorded_as_skipped_with_its_cause_and_spends_nothing(e):
    p = e.run("stub", "--optional")
    assert p.returncode == 0, (p.returncode, p.stdout, p.stderr)
    assert "stub skipped: budget" in p.stdout and "REFUSED" in p.stdout, p.stdout
    assert e.calls() == [] and e.repos() == [], "no repo was created, nothing was spent"
    r = e.result()
    assert bench_run.validate(r) == [] and (r["status"], r["reason"], r["arm"]) == ("skipped", "budget", "stub"), r
    g = r["guard"]
    assert g["windows"][0]["now_pct"] == 50 and g["windows"][0]["fits"] is False and g["stop_pct"] == 98, g
    assert any("50% now + 80% expected" in x for x in g["reasons"]), g["reasons"]
    assert not os.path.exists(os.path.join(e.results, "t1", "stub.logs")), "no run logs: nothing ran"


@with_env(usage_pct="50")
def test_without_optional_the_refusal_stays_exit_3_and_records_nothing(e):
    p = e.run("stub")
    assert p.returncode == 3 and not os.path.exists(e.results), (p.returncode, p.stderr)
    q = e.run("stub", "--optional", "--dry-run")   # a dry run never records, optional or not
    assert q.returncode == 3 and not os.path.exists(e.results), (q.returncode, q.stderr)


@with_env()
def test_guard_refuses_when_the_host_disk_is_short_and_an_optional_arm_records_it(e):
    e.env["BENCH_MIN_FREE_GB"] = "1000000"   # no host has this much free
    p = e.run("stub")
    assert p.returncode == 3 and "host disk:" in p.stderr and "GB free < 1e+06 GB" in p.stderr, (p.returncode, p.stderr)
    assert e.calls() == [] and not os.path.exists(e.results)
    q = e.run("stub", "--optional")
    assert q.returncode == 0 and "stub skipped: disk:" in q.stdout, (q.returncode, q.stdout, q.stderr)
    r = e.result()
    assert bench_run.validate(r) == [] and r["status"] == "skipped" and r["reason"] == "disk", r   # #577: the usage fit
    g = r["guard"]
    assert g["causes"] == ["disk"] and all(w["fits"] for w in g["windows"]), g
    assert g["min_free_gb"] == 1e6 and g["disk"] and all(x["fits"] is False and x["free_gb"] > 0 for x in g["disk"]), g
    assert any(x.startswith("host disk:") for x in g["reasons"]), g["reasons"]
    assert e.calls() == [] and e.repos() == [], "nothing was created or spent"


@with_env()
def test_guard_refuses_a_token_without_delete_repo_before_creating_any_repo(e):
    p = e.run("stub", extra_env={"FAKE_GH_SCOPES": "gist, read:org, repo, workflow"})
    assert p.returncode == 3 and "lacks the delete_repo scope" in p.stderr, (p.returncode, p.stderr)
    assert "gh auth refresh -s delete_repo" in p.stderr, p.stderr
    assert e.calls() == [] and e.repos() == [] and not os.path.exists(e.results), "no repo, no record"
    q = e.run("stub", "--dry-run", extra_env={"FAKE_GH_SCOPES": ""})   # an empty scope list lacks it too
    assert q.returncode == 3 and "scopes: none" in q.stderr, (q.returncode, q.stderr)


@with_env()
def test_guard_passes_a_token_with_delete_repo(e):
    p = e.run("stub", extra_env={"FAKE_GH_SCOPES": "repo,delete_repo"})
    assert p.returncode == 0, (p.returncode, p.stderr)
    assert e.result()["repo_deleted"] is True


@with_env()
def test_guard_passes_a_token_with_no_scope_header(e):
    p = e.run("stub", extra_env={"FAKE_GH_SCOPES": "none"})   # fine-grained token: no X-OAuth-Scopes header
    assert p.returncode == 0, (p.returncode, p.stderr)
    assert e.result()["repo_deleted"] is True


@with_env()
def test_an_optional_arm_refused_for_the_scope_is_recorded_as_skipped(e):
    p = e.run("stub", "--optional", extra_env={"FAKE_GH_SCOPES": "repo"})
    assert p.returncode == 0 and "stub skipped: no-delete-repo" in p.stdout, (p.returncode, p.stdout, p.stderr)
    r = e.result()
    assert bench_run.validate(r) == [] and (r["status"], r["reason"]) == ("skipped", "no-delete-repo"), r
    assert r["guard"]["gh_scopes"] == ["repo"] and e.calls() == [] and e.repos() == [], r["guard"]


@with_env()
def test_an_optional_arm_with_headroom_runs_normally(e):
    p = e.run("stub", "--optional")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert r["status"] == "ok" and bench_run.validate(r) == [], r


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
    fz = dict(good, fuzz_cases=10, fuzz_divergences=3, fuzz_examples=[{}] * 3, fuzz_seed=589, fuzz_hash="h")
    assert bench_run.validate(fz) == [] and bench_run.validate(dict(good, fuzz_error="x")) == []   # optional (#589)
    assert bench_run.validate(dict(fz, fuzz_cases="10")) != [] and bench_run.validate(dict(fz, fuzz_divergences=11)) != []
    assert bench_run.validate(dict(fz, fuzz_examples=[{}] * 11)) != [] and bench_run.validate(dict(fz, fuzz_seed=True)) != []
    prov = {"engine_commit": "abc", "skill_version": "sha256:1", "cli_version": None}
    assert bench_run.validate(dict(good, provenance=prov, effort={"medium": 3}, configured={"model": "opus", "effort": None})) == []
    for bad in (dict(provenance={"engine_commit": "abc"}), dict(provenance=dict(prov, cli_version=3)), dict(effort={"medium": "3"}),
                dict(effort=["medium"]), dict(configured={"model": "opus"}), dict(configured={"model": 1, "effort": None})):
        assert bench_run.validate(dict(good, **bad)) != [], bad
    assert bench_run.validate(dict(good, coverage={"line_pct": 97, "branch_pct": 94.5})) == []
    assert bench_run.validate(dict(good, coverage="skipped (coverage.py is not installed)")) == []
    assert bench_run.validate(dict(good, coverage={"line_pct": 97})) != []        # no branch %
    assert bench_run.validate(dict(good, coverage="ok")) != []
    skipped = {"schema": 1, "run_id": "x", "arm": "hx", "status": "skipped", "reason": "budget", "skipped_at": "t", "guard": {}}
    assert bench_run.validate(skipped) == []
    assert bench_run.validate(dict(skipped, reason="tired")) != []
    for ok in ("disk", "held", "no-usage-reading", "no-calibration", "disk,budget"):
        assert bench_run.validate(dict(skipped, reason=ok)) == [], ok
    for bad in ("", "disk,disk", "disk,tired", "budget,"):
        assert bench_run.validate(dict(skipped, reason=bad)) != [], bad
    assert bench_run.validate(dict(skipped, reason="tired")) != [] and bench_run.validate({k: v for k, v in skipped.items() if k != "guard"}) != []


@with_env(usage_pct="50")
def test_a_usage_only_refusal_records_reason_budget(e):
    q = e.run("stub", "--optional")
    assert q.returncode == 0 and "stub skipped: budget:" in q.stdout, (q.returncode, q.stdout)
    r = e.result()
    assert r["reason"] == "budget" and r["guard"]["causes"] == ["budget"], r


@with_env(usage_pct="50")
def test_a_mixed_refusal_records_every_cause(e):
    e.env["BENCH_MIN_FREE_GB"] = "1000000"
    q = e.run("stub", "--optional")
    assert q.returncode == 0 and "stub skipped: disk,budget:" in q.stdout, (q.returncode, q.stdout)
    r = e.result()
    assert bench_run.validate(r) == [] and r["reason"] == "disk,budget" and r["guard"]["causes"] == ["disk", "budget"], r
    assert len(r["guard"]["reasons"]) >= 2, r["guard"]["reasons"]


@with_env(usage_pct=None)
def test_a_missing_usage_reading_records_reason_no_usage_reading(e):
    q = e.run("stub", "--optional")
    assert q.returncode == 0, (q.returncode, q.stdout, q.stderr)
    assert e.result()["reason"] == "no-usage-reading", e.result()


@with_env(per_pct=None)
def test_a_missing_calibration_records_reason_no_calibration(e):
    q = e.run("stub", "--optional")
    assert q.returncode == 0, (q.returncode, q.stdout, q.stderr)
    assert e.result()["reason"] == "no-calibration", e.result()


@with_env()
def test_a_usage_held_account_records_reason_held(e):
    os.makedirs(os.path.join(e.rundir, "usage-holds"))
    with open(os.path.join(e.rundir, "usage-holds", "main.hold"), "w") as fh:
        fh.write("seven_day 99\n")
    q = e.run("stub", "--optional")
    assert q.returncode == 0, (q.returncode, q.stdout, q.stderr)
    r = e.result()
    assert r["reason"] == "held" and r["guard"]["causes"] == ["held"] and r["guard"]["held"], r


@with_env()
def test_subagent_transcripts_are_kept_in_a_layout_measure_reads_back(e):
    p = e.run("stub", "--arm-opt", "cost=2", "--arm-opt", "subagents=1")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert r["tokens"]["output"] == 160000, r["tokens"]       # the session and its sub-agent, counted live
    logs = os.path.join(e.results, "t1", "stub.logs")
    kept = os.path.join(logs, "transcripts", "0-stub-session", "subagents", "agent-a1.jsonl")
    assert os.path.isfile(kept), glob.glob(os.path.join(logs, "**"), recursive=True)
    fc, st = bench_run._load("forecast"), bench_run._load("stats")
    m = bench_run.remeasure(fc, st, logs)
    assert m["tokens"] == r["tokens"] and abs(m["cost_usd"] - r["cost_usd"]) < 1e-4, (m, r)
    assert bench_run.verify_logs(fc, st, r, logs) == []


@with_env()
def test_every_arms_results_record_the_effort_the_transcripts_show_and_the_provenance(e):
    e.write_exe(os.path.join(e.bin, "claude"), "#!/usr/bin/env bash\necho '9.9.9 (Claude Code)'\n")
    p = e.run("stub", "--arm-opt", "effort=high")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert r["effort"] == {"high": 1}, r.get("effort")
    head = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    assert r["provenance"]["engine_commit"].startswith(head) and r["provenance"]["cli_version"] == "9.9.9 (Claude Code)", r["provenance"]
    assert r["provenance"]["skill_version"].startswith("sha256:") and bench_run.validate(r) == []
    logs = os.path.join(e.results, "t1", "stub.logs")
    fc, st = bench_run._load("forecast"), bench_run._load("stats")
    assert bench_run.verify_logs(fc, st, r, logs) == [], "the kept transcripts reproduce the recorded effort"
    bad = bench_run.verify_logs(fc, st, dict(r, effort={"medium": 1}), logs)
    assert len(bad) == 1 and bad[0].startswith("effort: results JSON {'medium': 1}, logs {'high': 1}"), bad


@with_env()
def test_a_missing_claude_binary_leaves_the_cli_version_null_and_never_fails_the_run(e):
    p = e.run("stub", "--arm-opt", "claude=/nonexistent/claude")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert r["provenance"]["cli_version"] is None and r["effort"] == {} and bench_run.validate(r) == [], r


@with_env()
def test_logs_that_lost_their_subagent_transcripts_do_not_reproduce_the_results(e):
    assert e.run("stub", "--arm-opt", "cost=2", "--arm-opt", "subagents=1").returncode == 0
    logs = os.path.join(e.results, "t1", "stub.logs")
    shutil.rmtree(os.path.join(logs, "transcripts", "0-stub-session"))
    bad = bench_run.verify_logs(bench_run._load("forecast"), bench_run._load("stats"), e.result(), logs)
    assert any(m.startswith("tokens.output") for m in bad) and any(m.startswith("cost_usd") for m in bad), bad


@with_env()
def test_logs_with_no_transcripts_do_not_reproduce_a_recorded_measurement(e):
    assert e.run("stub", "--arm-opt", "cost=2").returncode == 0
    logs = os.path.join(e.results, "t1", "stub.logs")
    shutil.rmtree(os.path.join(logs, "transcripts"))
    bad = bench_run.verify_logs(bench_run._load("forecast"), bench_run._load("stats"), e.result(), logs)
    assert len(bad) == 1 and "no transcripts" in bad[0], bad


@with_env()
def test_figures_check_fails_when_an_arms_logs_do_not_reproduce_its_results(e):
    assert e.run("stub", "--arm-opt", "cost=2", "--arm-opt", "subagents=1").returncode == 0
    readme = os.path.join(e.d, "README.md")
    with open(readme, "w") as fh:
        fh.write("# T\n\n<!-- bench:begin — x -->\nOLD\n<!-- bench:end -->\n")
    fig = [sys.executable, os.path.join(ROOT, "bench", "figures.py"), "--results-dir", e.results, "--readme", readme]
    assert subprocess.run(fig, capture_output=True, text=True).returncode == 0     # write README + figure
    ok = subprocess.run(fig + ["--check"], capture_output=True, text=True)
    assert ok.returncode == 0, ok.stderr
    shutil.rmtree(os.path.join(e.results, "t1", "stub.logs", "transcripts", "0-stub-session"))
    bad = subprocess.run(fig + ["--check"], capture_output=True, text=True)
    assert bad.returncode == 1 and "logs do not reproduce results: stub: tokens.output" in bad.stderr, bad.stderr


def test_the_disk_guard_measures_only_the_temp_dir_not_the_checkout():
    seen, real_tmp, real_du = [], bench_run.tempfile.gettempdir, bench_run.shutil.disk_usage
    fake_tmp = tempfile.mkdtemp()           # a directory that exists on every OS ("/tmp" is nothing on Windows) and is not the checkout
    bench_run.tempfile.gettempdir = lambda: fake_tmp
    bench_run.shutil.disk_usage = lambda p: seen.append(p) or real_du(p)
    try:
        out = bench_run.disk_free()
    finally:
        bench_run.tempfile.gettempdir, bench_run.shutil.disk_usage = real_tmp, real_du
        shutil.rmtree(fake_tmp, ignore_errors=True)
    assert seen == [fake_tmp] and [x["path"] for x in out] == [fake_tmp], (seen, out)


def test_aggregate_summarises_own_test_coverage_and_ignores_skipped_ones():
    import aggregate
    ok = lambda l, b, t: {"status": "ok", "coverage": {"line_pct": l, "branch_pct": b, "total_pct": t}}
    m = aggregate.aggregate([ok(90.0, 80.0, 85.0), ok(96.0, 90.0, 93.0), {"status": "ok", "coverage": "skipped (x)"}])["metrics"]
    assert m["cov_line_pct"] == {"n": 2, "median": 93.0, "min": 90.0, "max": 96.0}, m
    assert m["cov_branch_pct"]["median"] == 85.0 and m["cov_total_pct"]["max"] == 93.0, m
    assert "cov_line_pct" not in aggregate.aggregate([{"status": "ok", "coverage": "skipped (x)"}])["metrics"]


def test_engine_commit_reads_the_archive_stamp_when_git_cannot_resolve_head():
    """#653: the release gate runs on a `git archive` extraction (no .git). `git archive` expands the stamp file's
    `$Format:%H$` (export-subst), so engine_commit() falls back to it; an unexpanded stamp (a checkout) is no commit."""
    import armlib
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "bench"))
        stamp = os.path.join(d, "bench", "ENGINE_COMMIT")
        assert armlib.engine_commit(d) is None, "no git, no stamp"
        sha = "0123456789abcdef0123456789abcdef01234567"
        with open(stamp, "w") as fh:
            fh.write(sha + "\n")
        assert armlib.engine_commit(d) == sha, "no .git: the archive stamp"
        with open(stamp, "w") as fh:
            fh.write("$Format:%H$\n")
        assert armlib.engine_commit(d) is None, "an unexpanded stamp is not a commit"
    assert re_commit(armlib.engine_commit(ROOT)), "a git checkout still reads HEAD"


def re_commit(v):
    import re
    return bool(v) and re.fullmatch(r"[0-9a-f]{40,64}(-dirty)?", v) is not None


def test_usage_errors_spell_a_form_feed_and_u2028_as_vis_does():   # #899
    for ch, esc in (("\x0c", "\\u000c"), ("\u2028", "\\u2028")):
        r = subprocess.run([sys.executable, RUN, "stub", "--run-id", f"a{ch}b"], capture_output=True, text=True)
        assert r.returncode != 0 and f"'a{esc}b'" in r.stderr, (r.returncode, r.stderr)
        assert ch not in r.stderr and "\\x0c" not in r.stderr, repr(r.stderr)
        assert bench_run._short(f"a{ch}b") == f"'a{esc}b'"
        try:
            bench_run.load_arm(f"a{ch}b", ROOT)
        except ValueError as e:
            assert f"'a{esc}b'" in str(e) and "\\x0c" not in str(e), str(e)
        else:
            raise AssertionError("expected ValueError")


def test_fixture_choice_error_spells_a_form_feed_and_u2028_as_vis_does():   # #912
    for ch, esc in (("\x0c", "\\u000c"), ("\u2028", "\\u2028")):
        r = subprocess.run([sys.executable, RUN, "stub", "--fixture", f"p{ch}"], capture_output=True, text=True)
        assert r.returncode == 2 and f"invalid choice: 'p{esc}' (choose from pennywise, large)" in r.stderr, (r.returncode, r.stderr)
        assert ch not in r.stderr and "\\x0c" not in r.stderr, repr(r.stderr)
    r = subprocess.run([sys.executable, RUN, "stub", "-h"], capture_output=True, text=True)
    assert "--fixture {pennywise,large}" in r.stdout, r.stdout
    assert bench_run.parse_args(["stub", "--fixture", "large"]).fixture == "large"


@with_env()
def test_argparse_and_bench_usage_errors_share_the_bench_prefix(e):   # #913
    argparse_err = e.run("stub", "--runs=-x")      # argparse's own error
    bench_err = e.run("stub", "--runs=-1")         # bench's own check
    for p in (argparse_err, bench_err):
        assert p.returncode == 2, (p.returncode, p.stderr)
        last = p.stderr.strip().splitlines()[-1]
        assert last.startswith("bench: "), last
        assert "bench/run.py:" not in p.stderr, p.stderr
    assert "error: argument --runs" in argparse_err.stderr and "--runs must be at least 1" in bench_err.stderr
    assert e.calls() == []


# --- --runs N: median and range over repeated runs (#591) ---------------------------------------------
def counter_usage(step, start=10):
    """A HARNESS_USAGE_CMD whose weekly reading climbs `step` points at every call: each guard sees what the earlier runs used."""
    return ("f=\"$STATE_FILE\"; n=$(cat \"$f\" 2>/dev/null || echo 0); echo $((n+1)) > \"$f\"; "
            f"printf 'acct\\tseven_day\\t%s\\t0\\n' $(({start} + n * {step}))")


def batch(e, arm="stub"):
    d = os.path.join(e.results, "t1")
    agg = json.load(open(os.path.join(d, arm + ".json")))
    runs = [json.load(open(os.path.join(d, r["file"]))) for r in agg["runs"]]
    return agg, runs


def creates(e):
    return [c for c in e.calls() if c.startswith("gh repo create")]


def test_runs_defaults_to_five_and_must_be_positive():
    assert bench_run.parse_args(["stub"]).runs == 5
    assert bench_run.parse_args(["stub", "--runs", "3"]).runs == 3


@with_env()
def test_runs_below_one_is_a_usage_error(e):
    p = e.run("stub", "--runs", "0")
    assert p.returncode == 2 and "--runs must be at least 1" in p.stderr and e.calls() == []


@with_env()
def test_runs_and_workers_above_the_cap_are_one_line_usage_errors(e):   # #897
    for opt, cap in (("--runs", bench_run.RUNS_MAX), ("--workers", bench_run.WORKERS_MAX)):
        for bad in (str(cap + 1), "99999999999999999999"):
            p = e.run("stub", "--dry-run", opt, bad)
            lines = p.stderr.strip().splitlines()
            assert p.returncode == 2 and len(lines) == 1 and opt in lines[0] and str(cap) in lines[0], (opt, bad, p.returncode, p.stderr)
            assert "would run" not in p.stdout and "bench guard" not in p.stdout, (opt, bad, p.stdout)
        assert e.run("stub", "--dry-run", opt, str(cap), "--expected-usd", "1").returncode in (0, 3), opt   # the cap itself is in range
    assert e.calls() == []


@with_env()
def test_runs_and_workers_are_ascii_digits_only(e):   # #784
    for opt in ("--runs", "--workers"):
        for bad in ("1_1", "+5", "\uff12\uff10"):
            p = e.run("stub", "--dry-run", f"{opt}={bad}")
            assert p.returncode == 2 and opt in p.stderr and repr(bad) in p.stderr and "bench guard" not in p.stdout, (opt, bad, p.returncode, p.stdout, p.stderr)
    assert e.calls() == []


@with_env()
def test_over_long_numbers_are_one_line_usage_errors(e):   # #880
    cases = [(opt, bad, word) for opt in ("--runs", "--workers")
             for bad, word in (("9" * 5000, "too large"), ("0" * 5000 + "1", "too long"))]
    cases += [(opt, "9" * 5000, "too large") for opt in ("--cost-cap-usd", "--wall-cap-secs")]
    for opt, bad, word in cases:
        p = e.run("stub", "--dry-run", f"{opt}={bad}")
        line = p.stderr.rstrip("\n").rsplit("\n", 1)[-1]   # argparse's one-line error, after the usage block
        assert p.returncode == 2 and opt in line and word in line, (opt, word, p.returncode, p.stderr[-300:])
        assert bad not in p.stderr and "invalid _int_arg" not in line and "finite number" not in line and len(line) < 200, (opt, len(line))
    assert e.calls() == []


@with_env()
def test_runs_n_records_n_results_per_arm_plus_an_aggregate(e):
    p = e.run("stub", "--runs", "3", "--arm-opt", "cost=1,3,2", "--expected-usd", "5")
    assert p.returncode == 0, (p.stdout, p.stderr)
    agg, runs = batch(e)
    assert bench_run.validate(agg) == [], bench_run.validate(agg)
    assert (agg["status"], agg["runs_requested"], agg["runs_completed"], agg["stopped"]) == ("aggregate", 3, 3, None)
    assert [r["file"] for r in agg["runs"]] == [f"stub.runs/run-0{i}.json" for i in (1, 2, 3)]
    assert [r["run"] for r in runs] == [1, 2, 3] and all(bench_run.validate(r) == [] for r in runs)
    assert [round(r["cost_usd"]) for r in runs] == [1, 3, 2]
    c = agg["aggregate"]["metrics"]["cost_usd"]
    assert (c["n"], round(c["median"]), round(c["min"]), round(c["max"])) == (3, 2, 1, 3), c
    assert {"wall_s", "tokens", "hidden_passed", "coding_s"} <= set(agg["aggregate"]["metrics"])
    # each run had its own private repo, all deleted; its own logs sit beside its result
    names = sorted(c.split()[3].split("/")[1] for c in creates(e))
    assert names == [f"bench-t1-stub-r0{i}" for i in (1, 2, 3)], names
    assert all(r["repo_deleted"] is True for r in runs) and e.repos() == []
    for i in (1, 2, 3):
        assert os.path.isfile(os.path.join(e.results, "t1", "stub.runs", f"run-0{i}.logs", "run.log"))
    assert not os.path.exists(os.path.join(e.results, "t1", "stub.logs")), "no single-run files in a batch"
    assert "3 of 3 runs completed" in p.stdout, p.stdout


@with_env()
def test_runs_1_keeps_the_single_run_files(e):
    assert e.run("stub").returncode == 0
    assert e.result()["status"] == "ok" and "run" not in e.result()
    assert os.path.isdir(os.path.join(e.results, "t1", "stub.logs"))
    assert [c.split()[3].split("/")[1] for c in creates(e)] == ["bench-t1-stub"]


@with_env(usage_pct=None)
def test_a_batch_stops_early_when_the_budget_runs_out_and_records_why(e):
    e.env["HARNESS_USAGE_CMD"] = counter_usage(30)
    e.env["STATE_FILE"] = os.path.join(e.d, "usage-calls")
    p = e.run("stub", "--runs", "5", "--expected-usd", "10", "--optional")   # 10 -> 40 -> 70 -> 100%: the 4th run does not fit
    assert p.returncode == 0, (p.stdout, p.stderr)
    agg, runs = batch(e)
    assert bench_run.validate(agg) == []
    assert (agg["runs_requested"], agg["runs_completed"], len(runs)) == (5, 3, 3), agg
    st = agg["stopped"]
    assert st["reason"] == "guard" and st["causes"] == ["budget"] and "acct seven_day" in st["detail"], st
    assert len(creates(e)) == 3 and e.repos() == [], "the refused run created nothing"
    assert "stopped early: guard" in p.stdout and "REFUSED" in p.stderr, (p.stdout, p.stderr)


@with_env(usage_pct=None)
def test_a_refusal_before_the_first_run_is_still_exit_3_and_records_nothing(e):
    e.env["HARNESS_USAGE_CMD"] = counter_usage(0, start=96)
    e.env["STATE_FILE"] = os.path.join(e.d, "usage-calls")
    p = e.run("stub", "--runs", "3", "--expected-usd", "10")
    assert p.returncode == 3 and e.calls() == [] and not os.path.exists(e.results), (p.returncode, p.stderr)


@with_env()
def test_a_failing_arm_stops_the_batch_and_is_recorded(e):
    p = e.run("stub", "--runs", "3", "--arm-opt", "fail=1", "--expected-usd", "5")
    assert p.returncode == 1, (p.stdout, p.stderr)
    agg, runs = batch(e)
    assert bench_run.validate(agg) == [] and [r["status"] for r in runs] == ["error"]
    assert (agg["runs_completed"], agg["stopped"]["reason"]) == (0, "arm-error") and "told to fail" in agg["stopped"]["detail"]
    assert agg["aggregate"] == {"n": 0, "metrics": {}, "cap_hits": {"runs": 0, "of": 0, "wall": 0, "cost": 0}} and len(creates(e)) == 1


@with_env()
def test_a_repo_that_cannot_be_deleted_stops_the_batch(e):
    p = e.run("stub", "--runs", "3", "--expected-usd", "5", extra_env={"FAKE_GH_DELETE_FAIL": "1"})
    assert p.returncode == 4 and "COULD NOT DELETE bencher/bench-t1-stub-r01" in p.stderr, (p.returncode, p.stderr)
    agg, runs = batch(e)
    assert bench_run.validate(agg) == [] and agg["stopped"]["reason"] == "repo-not-deleted"
    assert (agg["runs_completed"], len(creates(e))) == (1, 1) and runs[0]["repo_deleted"] is False


@with_env()
def test_capped_runs_are_kept_in_the_batch_with_their_cap(e):
    p = e.run("stub", "--runs", "2", "--arm-opt", "sleep=60", "--wall-cap-secs", "0.4", "--expected-usd", "5")
    assert p.returncode == 0, (p.stdout, p.stderr)
    agg, runs = batch(e)
    assert bench_run.validate(agg) == [] and agg["stopped"] is None
    assert [(r["status"], r["capped"]) for r in runs] == [("capped", "wall")] * 2 and agg["runs_completed"] == 2


def test_summarize_and_aggregate_count_only_finished_runs():
    agg = bench_run.agglib()
    assert agg.summarize([]) is None and agg.summarize([None, True]) is None
    assert agg.summarize([3, 1, 2, None]) == {"n": 3, "median": 2, "min": 1, "max": 3}
    assert agg.summarize([1, 2, 3, 10])["median"] == 2.5
    doc = lambda status, cost, passed: {"status": status, "cost_usd": cost, "wall_s": 9,
                                        "tokens": {"input": 1, "output": 2, "cache_read": 3, "cache_write": 4},
                                        "hidden_tests": {"passed": passed, "failed": 0, "total": 80},
                                        "sonarqube": {"coverage": 50 + passed}}
    got = agg.aggregate([doc("ok", 4, 70), doc("error", 99, 0), doc("capped", 6, 80)])
    m = got["metrics"]
    assert got["n"] == 2 and m["cost_usd"] == {"n": 2, "median": 5, "min": 4, "max": 6}, got
    assert m["tokens"]["median"] == 10 and m["hidden_passed"]["max"] == 80 and m["coverage"]["min"] == 120
    assert "fuzz_divergences" not in m, "a metric no run has is left out"
    ungraded = dict(doc("ok", 1, 0), hidden_tests={"passed": 0, "failed": None, "total": None})
    assert "hidden_passed" not in agg.aggregate([ungraded])["metrics"], "an ungraded run has no pass count"


def test_validate_aggregate_names_what_is_wrong():
    agg = bench_run.agglib()
    good = {"schema": 1, "run_id": "r", "arm": "stub", "status": "aggregate", "runs_requested": 2, "runs_completed": 1,
            "stopped": {"reason": "guard", "detail": "budget"},
            "runs": [{"run": 1, "file": "stub.runs/run-01.json", "status": "ok"}],
            "aggregate": {"n": 1, "metrics": {"cost_usd": {"n": 1, "median": 1, "min": 1, "max": 1}}}}
    assert agg.validate_aggregate(good) == []
    assert agg.validate_aggregate(dict(good, stopped=None))[0].startswith("stopped is null but fewer runs completed")
    assert "stopped: want" in agg.validate_aggregate(dict(good, stopped={"reason": "tired", "detail": ""}))[0]
    assert agg.validate_aggregate(dict(good, runs_completed=2)) != []
    bad = dict(good, aggregate={"n": 1, "metrics": {"cost_usd": {"n": 1, "median": 5, "min": 1, "max": 2}}})
    assert "aggregate.metrics.cost_usd" in agg.validate_aggregate(bad)[0]
    assert agg.validate_aggregate({k: v for k, v in good.items() if k != "runs"}) == ["missing runs"]
    assert bench_run.validate(good) == [], "run.validate dispatches an aggregate record"


@with_env()
def test_figures_check_re_measures_every_runs_logs_in_a_batch(e):
    assert e.run("stub", "--runs", "2", "--arm-opt", "cost=2,3", "--arm-opt", "subagents=1", "--expected-usd", "5").returncode == 0
    readme = os.path.join(e.d, "README.md")
    with open(readme, "w") as fh:
        fh.write("# T\n\n<!-- bench:begin — x -->\nOLD\n<!-- bench:end -->\n")
    fig = [sys.executable, os.path.join(ROOT, "bench", "figures.py"), "--results-dir", e.results, "--readme", readme]
    assert subprocess.run(fig, capture_output=True, text=True).returncode == 0
    ok = subprocess.run(fig + ["--check"], capture_output=True, text=True)
    assert ok.returncode == 0, ok.stderr
    text = open(readme).read()
    assert "| stub | n=2 |" in text and "$5.00 ($4.00–$6.00)" in text, text   # sub-agents double each run's price
    shutil.rmtree(os.path.join(e.results, "t1", "stub.runs", "run-02.logs", "transcripts", "0-stub-session"))
    bad = subprocess.run(fig + ["--check"], capture_output=True, text=True)
    assert bad.returncode == 1 and "logs do not reproduce results: stub run 2: tokens.output" in bad.stderr, bad.stderr


# --- #615: the prompt-cache TTL's measures --------------------------------------------------
def _ttl_transcript(path, turns):
    """turns: [(seconds from start, cache_creation {5m, 1h} or None, cache_read)] — one assistant message each."""
    rows = []
    for i, (t, cc, rd) in enumerate(turns):
        u = {"input_tokens": 1, "output_tokens": 1, "cache_read_input_tokens": rd}
        if cc is not None:
            u["cache_creation_input_tokens"] = sum(cc.values())
            u["cache_creation"] = {"ephemeral_5m_input_tokens": cc.get("5m", 0), "ephemeral_1h_input_tokens": cc.get("1h", 0)}
        rows.append({"type": "assistant", "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(1794304800 + t)),
                     "message": {"id": f"m{i}", "model": "claude-opus-4-5", "usage": u, "content": []}})
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("".join(json.dumps(r) + "\n" for r in rows))


def test_measure_splits_cache_writes_by_ttl_and_prices_the_cache_at_each(tmp_path=None):
    d = tempfile.mkdtemp()
    try:
        tr = os.path.join(d, "s.jsonl")
        # 1000 written at 5m, 400 at 1h, one block that records no split (all 5m), a read of 5000
        _ttl_transcript(tr, [(0, {"5m": 1000}, 0), (10, {"1h": 400}, 5000), (20, None, 0)])
        with open(tr, "a") as fh:
            fh.write(json.dumps({"type": "assistant", "timestamp": "2026-11-07T10:00:30Z", "message": {
                "id": "legacy", "model": "claude-opus-4-5", "content": [],
                "usage": {"input_tokens": 1, "output_tokens": 1, "cache_creation_input_tokens": 200}}}) + "\n")
        fc, st = bench_run._load("forecast"), bench_run._load("stats")
        m = bench_run.measure(fc, st, [tr])
        assert (m["cache_write_5m"], m["cache_write_1h"]) == (1200, 400), m
        assert m["tokens"]["cache_write"] == 1600 == m["cache_write_5m"] + m["cache_write_1h"], m["tokens"]
        _, _, pw5, pw1, pr = fc.price("claude-opus-4-5")
        assert abs(m["cache_cost_usd"] - (1200 * pw5 + 400 * pw1 + 5000 * pr) / 1e6) < 1e-4, m["cache_cost_usd"]
        assert pw1 > pw5, "the 1h write costs more than the 5m one: that is the saving"
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_measure_reports_the_turn_gap_distribution_and_counts_the_gaps_a_5m_cache_misses():
    d = tempfile.mkdtemp()
    try:
        tr = os.path.join(d, "s.jsonl")
        # gaps: 10s, 20s, 400s (over 5m), 30s, 3700s (over 5m and 1h)
        _ttl_transcript(tr, [(0, None, 1), (10, None, 1), (30, None, 1), (430, None, 1), (460, None, 1), (4160, None, 1)])
        fc, st = bench_run._load("forecast"), bench_run._load("stats")
        g = bench_run.measure(fc, st, [tr])["turn_gaps"]
        assert g == {"turns": 6, "p50_s": 30.0, "p90_s": 3700.0, "max_s": 3700.0, "over_5m": 2, "over_1h": 1}, g
        assert bench_run.gap_stats([]) is None and bench_run.measure(fc, st, [])["turn_gaps"] is None
    finally:
        shutil.rmtree(d, ignore_errors=True)


@with_env()
def test_a_run_records_its_cache_ttl_split_gaps_and_the_logs_reproduce_them(e):
    p = e.run("stub", "--arm-opt", "cost=2")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = e.result()
    assert bench_run.validate(r) == [], bench_run.validate(r)
    assert r["cache_ttl"] == "5m" and r["cache_write_5m"] == 0 and r["cache_write_1h"] == 0, r
    assert r["cache_cost_usd"] == 0 and r["turn_gaps"] is None, r      # the stub's one-message transcript has no cache and no gap
    logs = os.path.join(e.results, "t1", "stub.logs")
    fc, st = bench_run._load("forecast"), bench_run._load("stats")
    assert bench_run.verify_logs(fc, st, r, logs) == []
    assert bench_run.verify_logs(fc, st, dict(r, cache_write_1h=7), logs) != []   # a split the logs do not hold
    assert bench_run.validate(dict(r, cache_ttl="2h")) != []
    assert bench_run.validate(dict(r, turn_gaps={"turns": 2})) != []


def test_the_ttl_measures_aggregate_and_the_bench_fleet_env_carries_the_setting():
    import aggregate
    doc = {"cache_write_5m": 10, "cache_write_1h": 3, "cache_cost_usd": 0.5,
           "turn_gaps": {"turns": 4, "p50_s": 5.0, "p90_s": 400.0, "max_s": 400.0, "over_5m": 1, "over_1h": 0}}
    got = {k: f(doc) for k, f in aggregate.METRICS.items() if k in ("cache_write_5m", "cache_write_1h", "cache_cost_usd", "gap_p90_s", "gaps_over_5m")}
    assert got == {"cache_write_5m": 10, "cache_write_1h": 3, "cache_cost_usd": 0.5, "gap_p90_s": 400.0, "gaps_over_5m": 1}, got
    assert aggregate.METRICS["gap_p90_s"]({"turn_gaps": None}) is None
    spec = importlib.util.spec_from_file_location("bench_arm_h615", os.path.join(ROOT, "bench", "arms", "harness.py"))
    assert "HARNESS_CACHE_TTL" in [l for l in open(spec.origin) if l.startswith("PASS_ENV")][0]


def test_usage_output_that_starts_with_a_bom_reads_the_same_account_and_usage():   # #678
    saved = os.environ.get("HARNESS_USAGE_CMD")
    try:
        got = {}
        for name, bom in (("plain", ""), ("bom", "\\357\\273\\277")):
            os.environ["HARNESS_USAGE_CMD"] = "printf '%sdefault\\tseven_day\\t42\\t0\\r\\nother\\tfive_hour\\t7\\t0\\r\\n'" % bom
            got[name] = bench_run.usage_readings()
        assert got["plain"] == [("default", "seven_day", 42.0, "0"), ("other", "five_hour", 7.0, "0")], got
        assert got["bom"] == got["plain"], got
    finally:
        if saved is None:
            os.environ.pop("HARNESS_USAGE_CMD", None)
        else:
            os.environ["HARNESS_USAGE_CMD"] = saved


def test_usage_line_is_split_only_on_newline_and_a_bom_on_a_later_line_is_stripped():   # #714
    saved = os.environ.get("HARNESS_USAGE_CMD")
    try:
        def read(printf_arg):
            os.environ["HARNESS_USAGE_CMD"] = "printf '%s'" % printf_arg
            return bench_run.usage_readings()
        # form feed and U+2028 inside a field stay in it: never re-split into an account named "x"
        assert read("cfg\\fx\\tseven_day\\t40\\n") == [("cfg\fx", "seven_day", 40.0, "")]
        assert read("cfg\\342\\200\\250x\\tseven_day\\t40\\n") == [("cfg x", "seven_day", 40.0, "")]
        assert read("a\\tseven_day\\f40\\n") == []                      # a pct that holds a form feed is malformed, not re-split
        assert read("a\\tseven_day\\t4\\f0\\n") == []
        # a BOM at the start of a later line is not part of that account's name; CRLF still reads
        assert read("a\\tseven_day\\t42\\r\\n\\357\\273\\277b\\tfive_hour\\t7\\r\\n") == [
            ("a", "seven_day", 42.0, ""), ("b", "five_hour", 7.0, "")]
    finally:
        if saved is None:
            os.environ.pop("HARNESS_USAGE_CMD", None)
        else:
            os.environ["HARNESS_USAGE_CMD"] = saved


def test_usage_output_with_lone_cr_line_endings_reads_the_same_rows_as_lf():   # #864
    class _Done:
        returncode = 0
        def __init__(self, out):
            self.stdout = out
    lf = "a\tseven_day\t42\t0\nb\tfive_hour\t7\t0\n"
    saved_run, saved_cmd = bench_run.subprocess.run, os.environ.get("HARNESS_USAGE_CMD")
    try:
        os.environ["HARNESS_USAGE_CMD"] = "true"
        got = {}
        for name, text in (("lf", lf), ("crlf", lf.replace("\n", "\r\n")), ("cr", lf.replace("\n", "\r")),
                           ("cr_bom", lf.replace("\n", "\r﻿"))):
            # the parser must not lean on subprocess's own newline translation: hand it the raw text
            bench_run.subprocess.run = lambda *a, _t=text, **k: _Done(_t)
            got[name] = bench_run.usage_readings()
        want = [("a", "seven_day", 42.0, "0"), ("b", "five_hour", 7.0, "0")]
        assert got["lf"] == want, got
        assert got["crlf"] == want and got["cr"] == want, got
        assert got["cr_bom"] == want, got
    finally:
        bench_run.subprocess.run = saved_run
        if saved_cmd is None:
            os.environ.pop("HARNESS_USAGE_CMD", None)
        else:
            os.environ["HARNESS_USAGE_CMD"] = saved_cmd


def test_a_usage_hold_file_with_a_leading_bom_names_the_account_without_it():   # #807
    rdir = tempfile.mkdtemp(prefix="hold-bom-")
    try:
        os.makedirs(os.path.join(rdir, "usage-holds"))
        with open(os.path.join(rdir, "usage-holds", "acct1.hold"), "wb") as fh:
            fh.write(b"\xef\xbb\xbfacct1\tseven_day\t95\t0\n")
        with open(os.path.join(rdir, "usage-holds", "acct2.hold"), "wb") as fh:
            fh.write(b"\xef\xbb\xbf")   # BOM only: the account falls back to the file name
        assert bench_run.held_accounts(rdir) == [("acct1", "seven_day", "95"), ("acct2", "", "")]
    finally:
        shutil.rmtree(rdir, ignore_errors=True)


def test_guard_text_escapes_line_separators_and_controls_in_an_account_name():   # #756
    bad = "ac\u2028ct\u2029\x85\x0c\x01"
    want = "ac\\u2028ct\\u2029\\u0085\\u000c\\u0001"
    ok = {"ok": True, "reserve_pct": 2, "stop_pct": 98, "windows": [
        {"account": bad, "window": "seven_day", "now_pct": 1, "need_pct": 2, "total_pct": 5}]}
    refused = {"ok": False, "reasons": [f"account {bad} is usage-HELD (seven_day window at 95%): x", "second"]}
    for text in (bench_run.render_guard(ok), bench_run.render_guard(refused)):
        assert want in text, repr(text)
        assert not any(c in text for c in "\u2028\u2029\x85\x0c\x01"), repr(text)
    assert bench_run.render_guard(refused).count("\n") == 2   # the guard's own newlines stay: header + 2 reasons


@with_env()
def test_long_string_option_values_are_clipped_in_bench_errors(e):   # #911
    """A 5000-character arm, --arm-opt, --run-dir, --fixture, --run-id, --owner or --results-dir is echoed as 20 characters and an ellipsis."""
    x = "a" * 5000
    clip = "'" + "a" * 20 + "'\u2026"
    for args, want in (([x], clip), (["stub", "--arm-opt", x], clip), (["stub", "--run-dir", x], clip),
                       (["stub", "--fixture", x], clip), (["stub", "--run-id=-" + x], "'-" + "a" * 19 + "'\u2026"),
                       (["stub", "--owner", x], clip), (["stub", "--results-dir=-" + x], "'-" + "a" * 19 + "'\u2026")):
        p = e.run(*args, "--dry-run")
        line = next((ln for ln in p.stderr.splitlines() if want in ln), "")   # the one error line, after any usage block
        assert p.returncode == 2 and want in line and len(line) < 250 and "a" * 21 not in p.stderr, (args[-2:], p.returncode, p.stderr[-300:])
    assert e.calls() == []


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

#!/usr/bin/env python3
"""test_bench_hx.py — #386 (PRD #345): the Hx arm, bench/arms/hx.py, run through the real runner (bench/run.py)
with a fake gh (bare repos + a board), a fake `node` and a fake Hx checkout (bin/hx.mjs is a python script).
Covered: the arm runs `hx init --yes`, `hx prd <brief> --title`, `hx run --watch` in the run clone and leaves
Hx's config at its defaults except worktreeRoot; Hx is cloned at the PINNED commit; the environment is scrubbed
(no HARNESS_*, STATE_DIR, API key); the `hx run` it spawned is stopped through its own handle (SIGINT) on done,
on a cap and on an error, and a decoy process is untouched; an `hx run` that exits early is restarted; results
carry issues_closed, prs_merged, workers and the models that ran; a failed `hx init` is a recorded error."""
import importlib.util, json, os, signal, subprocess, sys, tempfile, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import test_bench_run as tb                                    # noqa: E402  (Env, bench_run)

spec = importlib.util.spec_from_file_location("hx_arm", os.path.join(tb.ROOT, "bench", "arms", "hx.py"))
hx_arm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hx_arm)

FAKE_GH = tb.FAKE_GH.replace('  "api -X") :;;', '''  "issue list") if [[ " $* " == *" --label prd "* ]]; then cat "$H/prds.json" 2>/dev/null || echo '[]'; else cat "$H/closed.json" 2>/dev/null || echo '[]'; fi;;
  "pr list") cat "$H/prs.json" 2>/dev/null || echo '[]';;
  "api -X") :;;''')

FAKE_NODE = r'''#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
if a == ["--version"]:
    print("v24.0.0"); sys.exit(0)
a = [x for x in a if not x.startswith("--disable-warning")]
os.execv(sys.executable, [sys.executable] + a)
'''

# The fake Hx: init writes .hx/config.json, prd files a PRD on the fake board, run --watch records a usage row and a
# transcript, closes the PRD (unless FAKE_NO_FINISH) and then waits; SIGINT is logged and ends it.
FAKE_HX = r'''#!/usr/bin/env python3
import json, os, signal, sys, time
d = os.environ["FAKE_HX_DIR"]
argv = sys.argv[1:]
env = {k: v for k, v in os.environ.items() if k.startswith("HARNESS_") or k in ("STATE_DIR", "RUN_DIR", "ANTHROPIC_API_KEY")}
with open(os.path.join(d, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"args": argv, "cwd": os.getcwd(), "env": env}) + "\n")
board = os.environ["FAKE_GH_HOME"]
def put(name, data):
    with open(os.path.join(board, name), "w") as f: json.dump(data, f)
state = os.path.join(os.getcwd(), ".hx")
cmd = argv[0]
if cmd == "init":
    if os.environ.get("FAKE_INIT_FAIL"):
        print("no gh login", file=sys.stderr); sys.exit(1)
    os.makedirs(state, exist_ok=True)
    with open(os.path.join(state, "config.json"), "w") as f:
        json.dump({"repo": "o/r", "workers": 2, "autoWorkers": True, "model": "claude-opus-5-5", "worktreeRoot": "/hx-wt/r"}, f)
elif cmd == "prd":
    put("prds.json", [{"number": 1, "state": "OPEN"}])
    print("https://github.com/o/r/issues/1")
elif cmd == "run":
    n = sum(1 for l in open(os.path.join(d, "calls.jsonl")) if json.loads(l)["args"][:1] == ["run"])
    def on_int(*_):
        with open(os.path.join(d, "sigint.log"), "a") as f: f.write("sigint %d\n" % n)
        sys.exit(0)
    signal.signal(signal.SIGINT, on_int)
    if os.environ.get("FAKE_DIE_ALWAYS") or (os.environ.get("FAKE_DIE_ONCE") and n == 1):
        sys.exit(3)
    sid = "hx-lane-%d" % n
    cfg = os.environ["CLAUDE_CONFIG_DIR"]
    os.makedirs(os.path.join(cfg, "projects", "p"), exist_ok=True)
    with open(os.path.join(cfg, "projects", "p", sid + ".jsonl"), "w") as t:
        t.write(json.dumps({"type": "assistant", "timestamp": "2026-11-06T10:00:00Z",
                            "message": {"id": "hx%d" % n, "model": "claude-opus-5-5",
                                        "usage": {"input_tokens": 70, "output_tokens": 700}, "content": []}}) + "\n")
    os.makedirs(state, exist_ok=True)
    with open(os.path.join(state, "usage.jsonl"), "a") as u:
        u.write(json.dumps({"ts": "2026-11-06T10:00:00Z", "issue": 2, "role": "impl", "sessionId": sid}) + "\n")
    if not os.environ.get("FAKE_NO_FINISH"):
        put("prds.json", [{"number": 1, "state": "CLOSED"}])
        put("closed.json", [{"number": 1, "labels": [{"name": "prd"}]}, {"number": 2, "labels": []}, {"number": 3, "labels": []}])
        put("prs.json", [{"number": 4}, {"number": 5}])
    time.sleep(120)
'''


class Arm:
    """tb.Env plus a fake gh board, a fake node and Hx checkout; a decoy process beside them."""

    def __init__(self, extra_env=None):
        self.e = tb.Env()
        self.fd = os.path.join(self.e.d, "fake"); os.makedirs(os.path.join(self.fd, "hx", "bin"))
        self.node = os.path.join(self.fd, "node")
        tb.Env.write_exe(self.node, FAKE_NODE)
        with open(os.path.join(self.fd, "hx", "bin", "hx.mjs"), "w") as fh:
            fh.write(FAKE_HX)
        tb.Env.write_exe(os.path.join(self.e.bin, "gh"), FAKE_GH)
        self.e.env.update(FAKE_HX_DIR=self.fd, ANTHROPIC_API_KEY="sk-ant-must-not-reach-anyone")
        self.extra = dict(extra_env or {})
        self.decoy = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"], start_new_session=True)

    def run(self, *args):
        return self.e.run("hx", "--arm-opt", f"node={self.node}", "--arm-opt", f"hx_src={os.path.join(self.fd, 'hx')}",
                          "--arm-opt", "poll=0.05", *args, extra_env=self.extra)

    def calls(self, cmd=None):
        p = os.path.join(self.fd, "calls.jsonl")
        rows = [json.loads(l) for l in open(p)] if os.path.exists(p) else []
        return [c for c in rows if cmd is None or c["args"][:1] == [cmd]]

    def sigints(self):
        p = os.path.join(self.fd, "sigint.log")
        return open(p).read().split() if os.path.exists(p) else []

    def result(self):
        return self.e.result("hx")

    def close(self):
        try:
            os.killpg(self.decoy.pid, signal.SIGKILL)
        except OSError:
            pass
        self.decoy.wait()
        self.e.close()


def with_arm(**kw):
    def deco(fn):
        def wrapped():
            a = Arm(**kw)
            try:
                fn(a)
            finally:
                a.close()
        wrapped.__name__ = fn.__name__
        return wrapped
    return deco


@with_arm()
def test_the_brief_is_filed_with_hx_prd_and_run_watch_starts_with_default_config(a):
    p = a.run()
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result()
    assert tb.bench_run.validate(r) == [] and (r["status"], r["error"]) == ("ok", None), r
    init, prd, run = a.calls("init")[0], a.calls("prd")[0], a.calls("run")[0]
    assert init["args"] == ["init", "--yes"] and init["cwd"].endswith("/clone"), init
    brief = open(os.path.join(tb.ROOT, "bench", "fixture", "brief.md")).read()
    title = [l[2:].strip() for l in brief.splitlines() if l.startswith("# ")][0]
    assert prd["args"][0] == "prd" and prd["args"][1].endswith("/clone/brief.md"), prd
    assert prd["args"][2:] == ["--title", "PRD: " + title], prd["args"]
    assert run["args"] == ["run", "--watch"], "no --workers: Hx's own default"
    cfg = json.load(open(os.path.join(a.e.results, "t1", "hx.logs", "config.json")))
    assert cfg["workers"] == 2 and cfg["model"] == "claude-opus-5-5" and cfg["autoWorkers"] is True, cfg
    assert cfg["worktreeRoot"].endswith("/hx-wt") and not cfg["worktreeRoot"].startswith("/hx-wt"), cfg
    assert r["counts"]["workers"] == 2


@with_arm()
def test_results_carry_counts_models_logs_and_the_install_record(a):
    assert a.run().returncode == 0
    r = a.result()
    assert r["counts"]["issues_closed"] == 2 and r["counts"]["prs_merged"] == 2, r["counts"]   # the PRD is not an issue
    assert list(r["models"]) == ["claude-opus-5-5"] and r["tokens"]["output"] == 700, r
    assert r["repo_deleted"] is True and r["repo"].startswith("bencher/bench-t1-hx")
    logs = os.path.join(a.e.results, "t1", "hx.logs")
    for f in ("hx.json", "usage.jsonl", "config.json", "run.out"):
        assert os.path.isfile(os.path.join(logs, f)), f
    rec = json.load(open(os.path.join(logs, "hx.json")))
    assert rec["pinned"] == hx_arm.HX_COMMIT and rec["node"] == "v24.0.0" and rec["repo"] == hx_arm.HX_REPO, rec


@with_arm(extra_env={"HARNESS_POOL": "9", "HARNESS_MODEL_MANAGER": "host", "STATE_DIR": "/host/.harness",
                     "RUN_DIR": "/host/.harness/run"})
def test_the_environment_is_scrubbed_of_the_hosts_fleet_and_api_keys(a):
    assert a.run().returncode == 0
    calls = a.calls()
    assert {c["args"][0] for c in calls} == {"init", "prd", "run"}
    for c in calls:
        assert c["env"] == {}, c["env"]
        assert c["cwd"].endswith("/clone"), c


@with_arm()
def test_a_finished_run_stops_the_hx_run_it_started_with_sigint_and_nothing_else(a):
    assert a.run().returncode == 0
    assert a.sigints() == ["sigint", "1"], a.sigints()
    assert a.decoy.poll() is None, "an unrelated process is untouched"


@with_arm(extra_env={"FAKE_NO_FINISH": "1"})
def test_a_capped_run_stops_the_hx_run_and_still_measures_what_ran(a):
    p = a.run("--wall-cap-secs", "3")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result()
    assert (r["status"], r["capped"]) == ("capped", "wall") and tb.bench_run.validate(r) == [], r
    assert a.sigints() == ["sigint", "1"] and a.decoy.poll() is None
    assert list(r["models"]) == ["claude-opus-5-5"], "the session that ran before the cap is measured"


@with_arm(extra_env={"FAKE_DIE_ONCE": "1"})
def test_an_hx_run_that_exits_before_the_prd_closes_is_started_again(a):
    p = a.run()
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result()
    assert r["status"] == "ok" and r["counts"]["fleet_restarts"] == 1, r
    assert [c["args"] for c in a.calls("run")] == [["run", "--watch"]] * 2


@with_arm(extra_env={"FAKE_DIE_ALWAYS": "1"})
def test_an_hx_run_that_never_stays_up_is_a_recorded_error_after_three_restarts(a):
    p = a.run()
    assert p.returncode == 1, (p.stdout, p.stderr)
    r = a.result()
    assert r["status"] == "error" and "exited (3) before the PRD closed" in r["error"], r
    assert r["counts"]["fleet_restarts"] == 3 and len(a.calls("run")) == 4 and r["repo_deleted"] is True


@with_arm(extra_env={"FAKE_INIT_FAIL": "1"})
def test_a_failed_hx_init_is_a_recorded_error_and_nothing_runs(a):
    p = a.run()
    assert p.returncode == 1, (p.stdout, p.stderr)
    r = a.result()
    assert r["status"] == "error" and "hx init failed: no gh login" in r["error"], r
    assert a.calls("prd") == [] and a.calls("run") == [] and r["repo_deleted"] is True


def test_install_clones_the_pinned_commit_and_refuses_any_other():
    d = tempfile.mkdtemp(prefix="hx-pin-")
    was = hx_arm.HX_REPO, hx_arm.HX_COMMIT
    try:
        up = os.path.join(d, "upstream")
        g = lambda *a: subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", up] + list(a),
                                      check=True, capture_output=True, text=True).stdout.strip()
        os.makedirs(up)
        g("init", "-q", "-b", "main")
        open(os.path.join(up, "f"), "w").write("1")
        g("add", "f"); g("commit", "-q", "-m", "one")
        pinned = g("rev-parse", "HEAD")
        open(os.path.join(up, "f"), "w").write("2")
        g("commit", "-q", "-am", "two")
        ctx = type("C", (), {"opts": {}, "log": staticmethod(lambda m: None)})()
        hx_arm.HX_REPO, hx_arm.HX_COMMIT = up, pinned
        work = os.path.join(d, "w"); os.makedirs(work)
        src, head = hx_arm.install(ctx, work)
        assert head == pinned and open(os.path.join(src, "f")).read() == "1", "the pin, not the branch head"
        hx_arm.HX_COMMIT = "0" * 40
        try:
            hx_arm.install(ctx, os.path.join(d, "w2")); raise AssertionError("an unknown pin must fail")
        except RuntimeError as e:
            assert "installing Hx failed" in str(e), e
    finally:
        hx_arm.HX_REPO, hx_arm.HX_COMMIT = was
        shutil.rmtree(d, ignore_errors=True)


def test_the_real_pin_is_a_full_commit_sha_and_the_arm_is_loadable_by_the_runner():
    assert len(hx_arm.HX_COMMIT) == 40 and set(hx_arm.HX_COMMIT) <= set("0123456789abcdef")
    mod = tb.bench_run.load_arm("hx", os.path.join(tb.ROOT, "bench", "arms"))
    assert callable(mod.run)


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

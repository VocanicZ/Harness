#!/usr/bin/env python3
"""test_bench_harness.py — #383 (PRD #345): the Harness arm, bench/arms/harness.py (and harness-3), run
through the real runner (bench/run.py) with a fake gh (bare repos + a board), a fake `claude` standing in for
the /harness front door and a fake `harness` engine that starts a detached resident worker.
Covered: the arm drives `/harness <brief>` (the brief file, then the fixed unattended line) and passes
--workers N through as HARNESS_POOL; the run fleet is isolated (its own HARNESS_HOME and state dir, a run
prefix, the host's HARNESS_*/STATE_DIR scrubbed, no API key) and is stopped only by `harness stop --state-dir
<its own>` — a decoy "host fleet" in another state dir survives, on done, on a cap and on an error; the
scripted continue reply; a fleet that dies is restarted with --recover; results carry issues_closed,
prs_merged and the models that ran (front door and lanes)."""
import json, os, signal, subprocess, sys, time, types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import importlib.util
import test_bench_run as tb                                    # noqa: E402  (Env, with_env, bench_run)

spec = importlib.util.spec_from_file_location("harness_arm", os.path.join(tb.ROOT, "bench", "arms", "harness.py"))
harness_arm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness_arm)

# gh: the runner's fake plus the two reads the arm makes of the board.
FAKE_GH = tb.FAKE_GH.replace('  "api -X") :;;', '''  "issue list") if [[ " $* " == *" --label prd "* ]]; then cat "$H/prds.json" 2>/dev/null || echo '[]'; else cat "$H/closed.json" 2>/dev/null || echo '[]'; fi;;
  "pr list") cat "$H/prs.json" 2>/dev/null || echo '[]';;
  "api -X") :;;''')

# The engine: init writes the config, start launches a detached resident worker with a pidfile, stop kills the
# pids of the state dir it is given and nothing else. Every call is logged with the environment it saw.
FAKE_HARNESS = r'''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time, types
d = os.environ["FAKE_HARNESS_DIR"]
argv = sys.argv[1:]
state = None
if "--state-dir" in argv:
    i = argv.index("--state-dir"); state = argv[i + 1]; del argv[i:i + 2]
state = state or os.environ.get("STATE_DIR") or os.path.join(os.getcwd(), ".harness")
env = {k: v for k, v in os.environ.items() if k.startswith("HARNESS_") or k in ("STATE_DIR", "RUN_DIR", "ANTHROPIC_API_KEY")}
with open(os.path.join(d, "engine.jsonl"), "a") as f:
    f.write(json.dumps({"args": argv, "state_dir": state, "cwd": os.getcwd(), "env": env}) + "\n")
cmd = argv[0] if argv else ""
board = os.environ["FAKE_GH_HOME"]
def put(name, data):
    with open(os.path.join(board, name), "w") as f: json.dump(data, f)
if cmd == "init":
    os.makedirs(os.path.join(state, "run"), exist_ok=True)
    with open(os.path.join(state, "config"), "w") as f:
        for k, v in sorted(env.items()):
            if k.startswith("HARNESS_"): f.write(': "${%s:=%s}"\n' % (k, v))
elif cmd == "start":
    n = sum(1 for l in open(os.path.join(d, "engine.jsonl")) if json.loads(l)["args"][:1] == ["start"])
    p = subprocess.Popen([sys.executable, __file__, "_worker", state, str(n)], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=os.environ)
    os.makedirs(os.path.join(state, "run"), exist_ok=True)
    with open(os.path.join(state, "run", "pool-1.pid"), "w") as f: f.write(str(p.pid))
elif cmd == "stop":
    run = os.path.join(state, "run")
    for f in sorted(os.listdir(run)) if os.path.isdir(run) else []:
        if f.endswith(".pid"):
            try: os.kill(int(open(os.path.join(run, f)).read().split()[0]), signal.SIGTERM)
            except (OSError, ValueError): pass
            os.remove(os.path.join(run, f))
elif cmd == "stats":
    print(json.dumps({"fake": True}))
elif cmd == "_worker":
    n = int(argv[2])
    time.sleep(0.3)
    if os.environ.get("FAKE_DIE_ONCE") and n == 1:
        sys.exit(0)
    home = os.environ["HARNESS_HOME"]; cfg = os.environ["CLAUDE_CONFIG_DIR"]
    sid = "lane-%d" % n
    os.makedirs(os.path.join(cfg, "projects", "p"), exist_ok=True)
    with open(os.path.join(cfg, "projects", "p", sid + ".jsonl"), "w") as t:
        t.write(json.dumps({"type": "assistant", "timestamp": "2026-11-04T10:00:00Z",
                            "message": {"id": "lane%d" % n, "model": "claude-sonnet-5-5",
                                        "usage": {"input_tokens": 50, "output_tokens": 500}, "content": []}}) + "\n")
    os.makedirs(home, exist_ok=True)
    with open(os.path.join(home, "events.jsonl"), "a") as e:
        e.write(json.dumps({"ts": "2026-11-04T10:00:00Z", "event": "launch", "session": sid, "issue": 2}) + "\n")
    if not os.environ.get("FAKE_NO_FINISH"):
        put("prds.json", [{"number": 1, "state": "CLOSED"}])
        put("closed.json", [{"number": 1, "labels": [{"name": "prd"}]}, {"number": 2, "labels": [{"name": "ready-for-agent"}]},
                            {"number": 3, "labels": [{"name": "ready-for-agent"}]}])
        put("prs.json", [{"number": 4}, {"number": 5}])
    time.sleep(120)
'''

# The /harness front door: replays $FAKE_CLAUDE_DIR/plan, one `<action>|<reply text>` per turn. `start` files the
# PRD and runs `harness init` + `harness start` off PATH as the skill would; `start-error` does that and then
# reports an error; `none` does nothing. Past the plan: `none|still going`.
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
d = os.environ["FAKE_CLAUDE_DIR"]
argv = sys.argv[1:]
prompt = sys.stdin.read()
env = {k: v for k, v in os.environ.items() if k.startswith("HARNESS_") or k in ("STATE_DIR", "RUN_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")}
with open(os.path.join(d, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"argv": argv, "prompt": prompt, "cwd": os.getcwd(), "env": env, "path0": os.environ["PATH"].split(os.pathsep)[0]}) + "\n")
n = sum(1 for _ in open(os.path.join(d, "calls.jsonl")))
plan = [l.rstrip("\n") for l in open(os.path.join(d, "plan")) if l.strip()]
action, _, text = (plan[n - 1] if n <= len(plan) else "none|still going").partition("|")
sid = argv[argv.index("--resume") + 1] if "--resume" in argv else open(os.path.join(d, "sid")).read().strip()
print(json.dumps({"type": "system", "subtype": "init", "session_id": sid, "model": "claude-opus-5-5"}), flush=True)
cfg = os.environ["CLAUDE_CONFIG_DIR"]
os.makedirs(os.path.join(cfg, "projects", "p"), exist_ok=True)
with open(os.path.join(cfg, "projects", "p", sid + ".jsonl"), "a") as t:
    t.write(json.dumps({"type": "assistant", "timestamp": "2026-11-04T10:00:0%dZ" % (n % 10),
                        "message": {"id": "front%d" % n, "model": "claude-opus-5-5",
                                    "usage": {"input_tokens": 100, "output_tokens": 1000}, "content": []}}) + "\n")
if action.startswith("start"):
    with open(os.path.join(os.environ["FAKE_GH_HOME"], "prds.json"), "w") as f: json.dump([{"number": 1, "state": "OPEN"}], f)
    subprocess.run(["harness", "init"], check=True)
    subprocess.run(["harness", "start"], check=True)
print(json.dumps({"type": "result", "subtype": "success", "is_error": action == "start-error", "session_id": sid, "result": text}), flush=True)
'''


class Arm:
    """tb.Env plus a fake gh board, a fake front door and a fake engine; a decoy host fleet beside them."""

    def __init__(self, plan, extra_env=None):
        self.e = tb.Env()
        self.fd = os.path.join(self.e.d, "fake"); os.makedirs(self.fd)
        self.claude = os.path.join(self.fd, "claude")
        os.makedirs(os.path.join(self.fd, "bin"))
        self.harness = os.path.join(self.fd, "bin", "harness")
        tb.Env.write_exe(self.claude, FAKE_CLAUDE)
        tb.Env.write_exe(self.harness, FAKE_HARNESS)
        tb.Env.write_exe(os.path.join(self.e.bin, "gh"), FAKE_GH)
        for name, text in (("plan", "\n".join(plan) + "\n"), ("sid", "front-door-session")):
            with open(os.path.join(self.fd, name), "w") as fh:
                fh.write(text)
        self.e.env.update(FAKE_CLAUDE_DIR=self.fd, FAKE_HARNESS_DIR=self.fd, ANTHROPIC_API_KEY="sk-ant-must-not-reach-anyone")
        self.extra = dict(extra_env or {})
        # a host fleet: its own state dir and a live worker the arm must never touch
        self.host_state = os.path.join(self.e.d, "host", ".harness")
        os.makedirs(os.path.join(self.host_state, "run"))
        self.decoy = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"], start_new_session=True)
        with open(os.path.join(self.host_state, "run", "pool-1.pid"), "w") as fh:
            fh.write(str(self.decoy.pid))

    def run(self, arm="harness", *args):
        return self.e.run(arm, "--arm-opt", f"claude={self.claude}", "--arm-opt", f"harness={self.harness}",
                          "--arm-opt", "poll=0.05", *args, extra_env=self.extra)

    def front_calls(self):
        p = os.path.join(self.fd, "calls.jsonl")
        return [json.loads(l) for l in open(p)] if os.path.exists(p) else []

    def _engine(self):
        p = os.path.join(self.fd, "engine.jsonl")
        return [json.loads(l) for l in open(p)] if os.path.exists(p) else []

    def result(self, arm="harness"):
        return self.e.result(arm)

    def decoy_alive(self):
        return self.decoy.poll() is None

    def close(self):
        try:
            os.killpg(self.decoy.pid, signal.SIGKILL)
        except OSError:
            pass
        self.decoy.wait()
        self.e.close()


def with_arm(plan, **kw):
    def deco(fn):
        def wrapped():
            a = Arm(plan, **kw)
            try:
                fn(a)
            finally:
                a.close()
        wrapped.__name__ = fn.__name__
        return wrapped
    return deco


def calls_of(a, cmd):
    return [c for c in a._engine() if c["args"][:1] == [cmd]]


# --- the front door and the pool size ------------------------------------------------------------
@with_arm(["start|The fleet is running."])
def test_the_brief_goes_through_slash_harness_and_workers_pass_through(a):
    p = a.run("harness", "--workers", "3")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result()
    assert tb.bench_run.validate(r) == [] and (r["status"], r["error"]) == ("ok", None), r
    front = a.front_calls()
    assert len(front) == 1, front
    brief = open(os.path.join(tb.ROOT, "bench", "fixture", "brief.md")).read().rstrip("\n")
    assert front[0]["prompt"].startswith("/harness " + brief), front[0]["prompt"][:120]
    assert front[0]["prompt"].rstrip().endswith(harness_arm.AUTONOMY_NOTE.strip()), "the unattended line closes it"
    assert "--bare" not in front[0]["argv"] and "--model" not in front[0]["argv"] and "--effort" not in front[0]["argv"]
    assert front[0]["env"]["HARNESS_POOL"] == "3", front[0]["env"]            # --workers N reaches the fleet config
    init, start = calls_of(a, "init")[0], calls_of(a, "start")[0]
    for c in (init, start):
        assert c["env"]["HARNESS_POOL"] == "3" and c["env"]["HARNESS_MODE"] == "prd", c["env"]
        assert c["env"]["HARNESS_REPO"] == r["repo"] and c["env"]["HARNESS_AUTONOMOUS"] == "true", c["env"]
    assert r["counts"]["workers"] == 3


@with_arm(["start|The fleet is running.", "start|The fleet is running."])
def test_one_worker_is_the_default_and_harness_3_defaults_to_three(a):
    assert a.run("harness").returncode == 0
    assert calls_of(a, "init")[0]["env"]["HARNESS_POOL"] == "1" and a.result()["counts"]["workers"] == 1
    q = a.run("harness-3", "--run-id", "t3")
    assert q.returncode == 0, (q.stdout, q.stderr)
    assert calls_of(a, "init")[-1]["env"]["HARNESS_POOL"] == "3"


@with_arm(["start|The fleet is running."])
def test_results_carry_issue_and_pr_counts_and_the_models_that_ran(a):
    assert a.run("harness").returncode == 0
    r = a.result()
    assert r["counts"]["issues_closed"] == 2 and r["counts"]["prs_merged"] == 2, r["counts"]   # the PRD is not an issue
    assert sorted(r["models"]) == ["claude-opus-5-5", "claude-sonnet-5-5"], r["models"]          # front door + a lane
    assert r["tokens"]["output"] == 1500 and r["cost_usd"] > 0, r["tokens"]
    assert r["repo_deleted"] is True and r["repo"].startswith("bencher/bench-t1-harness")
    logs = os.path.join(a.e.results, "t1", "harness.logs")
    for f in ("fleet.json", "fleet.config", "events.jsonl", "stats.json", "launch.txt", "front-01.stream.jsonl"):
        assert os.path.isfile(os.path.join(logs, f)), f


# --- isolation ----------------------------------------------------------------------------------------
HOST = {"STATE_DIR": "/host/fleet/.harness", "RUN_DIR": "/host/fleet/.harness/run", "HARNESS_SESS_PREFIX": "hzhost",
        "HARNESS_POOL": "9", "HARNESS_MODEL_MANAGER": "host-model", "HARNESS_MODEL_IMPLEMENTER": "host-model",
        "HARNESS_EFFORT_MANAGER": "low", "HARNESS_REPO": "host/repo", "HARNESS_MODE": "issue-only",
        "HARNESS_HOME": "/host/home", "HARNESS_USE_POLLER": "1", "HARNESS_EVENTS_FILE": "/host/events.jsonl"}


@with_arm(["start|ok"], extra_env=HOST)
def test_the_run_fleet_is_isolated_from_the_hosts(a):
    p = a.run("harness")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result()
    for c in [x["env"] for x in a.front_calls()] + [x["env"] for x in a._engine()]:
        assert "STATE_DIR" not in c and "RUN_DIR" not in c, c
        assert "HARNESS_MODEL_MANAGER" not in c and "HARNESS_EFFORT_MANAGER" not in c and "HARNESS_EVENTS_FILE" not in c, c
        assert "ANTHROPIC_API_KEY" not in c, "no API key reaches the front door or the fleet"
        assert c["HARNESS_REPO"] == r["repo"] and c["HARNESS_MODE"] == "prd" and c["HARNESS_POOL"] == "1", c
        assert c["HARNESS_SESS_PREFIX"].startswith("bn") and c["HARNESS_SESS_PREFIX"] != "hzhost", c
        assert c["HARNESS_HOME"] != "/host/home" and "harness-home" in c["HARNESS_HOME"], c
        assert c["HARNESS_USE_POLLER"] == "0", "no host-level poller is started by the run fleet"
    init = calls_of(a, "init")[0]
    assert init["state_dir"].endswith("/clone/.harness") and init["cwd"].endswith("/clone"), init
    assert [x["path0"] for x in a.front_calls()] == [os.path.dirname(a.harness)], "the engine measured is on PATH"
    assert a.decoy_alive() and os.path.exists(os.path.join(a.host_state, "run", "pool-1.pid")), "the host fleet is untouched"


# --- stopping -----------------------------------------------------------------------------------------
def _stopped_only_its_own(a):
    stops = calls_of(a, "stop")
    assert len(stops) == 1, stops
    s = stops[0]
    assert s["args"] == ["stop"] and s["state_dir"].endswith("/clone/.harness"), s
    assert s["state_dir"] != a.host_state and s["env"]["HARNESS_HOME"] != "/host/home", s
    assert a.decoy_alive() and os.path.exists(os.path.join(a.host_state, "run", "pool-1.pid")), "the host fleet is untouched"
    for st in calls_of(a, "start"):   # the resident worker of the run fleet is gone: its pid file was removed by the stop
        assert not os.path.exists(os.path.join(st["state_dir"], "run", "pool-1.pid"))


@with_arm(["start|ok"], extra_env=HOST)
def test_a_finished_run_stops_only_the_fleet_it_started(a):
    assert a.run("harness").returncode == 0
    _stopped_only_its_own(a)


@with_arm(["start|ok"], extra_env=dict(HOST, FAKE_NO_FINISH="1"))
def test_a_capped_run_stops_only_the_fleet_it_started(a):
    p = a.run("harness", "--wall-cap-secs", "3")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result()
    assert (r["status"], r["capped"]) == ("capped", "wall") and tb.bench_run.validate(r) == [], r
    _stopped_only_its_own(a)
    assert sorted(r["models"]) == ["claude-opus-5-5", "claude-sonnet-5-5"], "the lane that ran before the cap is measured"


@with_arm(["start-error|boom"], extra_env=HOST)
def test_a_failed_front_door_still_stops_the_fleet_it_had_started(a):
    p = a.run("harness")
    assert p.returncode == 1, (p.stdout, p.stderr)
    r = a.result()
    assert r["status"] == "error" and "front-door claude turn failed" in r["error"], r
    _stopped_only_its_own(a)


# --- the front door's loop and the fleet's health -----------------------------------------------------
@with_arm(["none|Shall I go ahead and start it?", "start|Started."])
def test_a_front_door_that_stops_early_gets_the_scripted_reply(a):
    assert a.run("harness").returncode == 0
    front = a.front_calls()
    assert len(front) == 2 and front[1]["prompt"] == "keep going, decide for yourself", front
    assert front[1]["argv"][-2:] == ["--resume", "front-door-session"], front[1]["argv"]
    assert a.result()["counts"]["continue_replies"] == 1


@with_arm([])
def test_no_fleet_after_five_replies_is_an_error_and_nothing_is_stopped(a):
    p = a.run("harness")
    assert p.returncode == 1, (p.stdout, p.stderr)
    r = a.result()
    assert r["status"] == "error" and "did not start a fleet after 5 continue replies" in r["error"], r
    assert r["counts"]["continue_replies"] == 5 and len(a.front_calls()) == 6
    assert r["models"] and r["repo_deleted"] is True
    assert a._engine() == [] or calls_of(a, "stop") == [], "no state dir was ever made, so there is nothing to stop"


@with_arm(["start|ok"], extra_env=dict(HOST, FAKE_DIE_ONCE="1"))
def test_a_fleet_that_died_is_restarted_with_recover(a):
    p = a.run("harness")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result()
    assert r["status"] == "ok" and r["counts"]["fleet_restarts"] == 1, r
    starts = calls_of(a, "start")
    assert [s["args"] for s in starts] == [["start"], ["start", "--recover"]], starts
    assert starts[1]["state_dir"].endswith("/clone/.harness")


def test_session_prefix_is_per_run_and_the_env_scrub_units():
    p1, p2 = harness_arm.session_prefix("o/bench-a-harness"), harness_arm.session_prefix("o/bench-b-harness")
    assert p1 != p2 and p1.startswith("bn") and p1 == harness_arm.session_prefix("o/bench-a-harness")

    ctx = types.SimpleNamespace(repo="o/bench-a-harness", clone="/tmp/w/clone", log=lambda m: None)
    f = harness_arm.Fleet(ctx, 2, "/e/bin/harness")
    assert f.state == "/tmp/w/clone/.harness" and f.home == "/tmp/w/harness-home"
    env = f.env({"PATH": "/usr/bin", "HARNESS_POOL": "9", "STATE_DIR": "/x", "ANTHROPIC_API_KEY": "k",
                 "HARNESS_USAGE_CMD": "u", "HARNESS_MODEL_MANAGER": "m", "OTHER": "1"})
    assert env["HARNESS_POOL"] == "2" and env["HARNESS_USAGE_CMD"] == "u" and env["OTHER"] == "1"
    assert "STATE_DIR" not in env and "ANTHROPIC_API_KEY" not in env and "HARNESS_MODEL_MANAGER" not in env
    assert env["PATH"].startswith("/e/bin" + os.pathsep)


def test_harness_3_delegates_to_the_harness_arm_with_three_workers_unless_told_otherwise():
    spec3 = importlib.util.spec_from_file_location("harness3_arm", os.path.join(tb.ROOT, "bench", "arms", "harness-3.py"))
    h3 = importlib.util.module_from_spec(spec3)
    spec3.loader.exec_module(h3)
    seen = []
    h3._base.run = lambda ctx: seen.append(dict(ctx.opts)) or "ran"

    class Ctx:
        def __init__(self, opts): self.opts = opts
    assert h3.run(Ctx({})) == "ran" and seen[-1] == {"workers": "3"}
    h3.run(Ctx({"workers": "2"}))
    assert seen[-1] == {"workers": "2"}, "an explicit --workers wins"


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

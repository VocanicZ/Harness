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
import json, os, re, signal, subprocess, sys, time, types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import importlib.util
import test_bench_run as tb                                    # noqa: E402  (Env, with_env, bench_run)

spec = importlib.util.spec_from_file_location("harness_arm", os.path.join(tb.ROOT, "bench", "arms", "harness.py"))
harness_arm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness_arm)
armlib = harness_arm.armlib

# gh: the runner's fake plus the two reads the arm makes of the board.
FAKE_GH = tb.FAKE_GH.replace('  "api -X") :;;', '''  "issue list") if [[ " $* " == *" --label prd "* ]]; then cat "$H/prds.json" 2>/dev/null || echo '[]'; else cat "$H/closed.json" 2>/dev/null || echo '[]'; fi;;
  "pr list") cat "$H/prs.json" 2>/dev/null || echo '[]';;
  "api -X") :;;''')

# The engine: init writes the config, start launches a detached resident worker with a pidfile, stop kills the
# pids of the state dir it is given and nothing else. Every call is logged with the environment it saw.
FAKE_HARNESS = r'''#!/usr/bin/env python3
import json, os, re, signal, subprocess, sys, time, types
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
                            "effort": os.environ.get("HARNESS_EFFORT_IMPLEMENTER", "high"),
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
import json, os, subprocess, sys, time
d = os.environ["FAKE_CLAUDE_DIR"]
argv = sys.argv[1:]
cfg = os.environ["CLAUDE_CONFIG_DIR"]
if argv[:1] == ["--version"]:
    print("9.9.9 (Claude Code)"); sys.exit(0)
if argv[:1] == ["plugin"]:   # `claude plugin install <p>@<m> --scope user` into the config dir it is given
    with open(os.path.join(d, "plugin_calls.jsonl"), "a") as f:
        f.write(json.dumps({"argv": argv, "config": cfg}) + "\n")
    if argv[1:2] == ["install"]:
        reg = os.path.join(cfg, "plugins", "installed_plugins.json")
        os.makedirs(os.path.dirname(reg), exist_ok=True)
        cur = json.load(open(reg)) if os.path.exists(reg) else {"plugins": {}}
        cur["plugins"][argv[2]] = [{"scope": "user"}]
        json.dump(cur, open(reg, "w"))
    sys.exit(0)
prompt = sys.stdin.read()
env = {k: v for k, v in os.environ.items() if k.startswith("HARNESS_") or k in ("STATE_DIR", "RUN_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CONFIG_DIR")}
with open(os.path.join(d, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"argv": argv, "prompt": prompt, "cwd": os.getcwd(), "env": env, "path0": os.environ["PATH"].split(os.pathsep)[0]}) + "\n")
n = sum(1 for _ in open(os.path.join(d, "calls.jsonl")))
plan = [l.rstrip("\n") for l in open(os.path.join(d, "plan")) if l.strip()]
action, _, text = (plan[n - 1] if n <= len(plan) else "none|still going").partition("|")
sid = argv[argv.index("--resume") + 1] if "--resume" in argv else open(os.path.join(d, "sid")).read().strip()
# the init lists what the config dir holds, like the real CLI: skills (plus two the CLI bundles), installed plugins
# (plus a built-in), and an MCP server only when $FAKE_MCP says the config leaked one
sk = os.path.join(cfg, "skills")
reg = os.path.join(cfg, "plugins", "installed_plugins.json")
plugins = [{"name": k.split("@")[0], "path": "/p/" + k, "source": k} for k in sorted(json.load(open(reg))["plugins"])] if os.path.exists(reg) else []
extra_skills = [x for x in os.environ.get("FAKE_HOST_SKILLS", "").split(",") if x]   # a host skill that leaked in
print(json.dumps({"type": "system", "subtype": "init", "session_id": sid, "model": "claude-opus-5-5",
                  "skills": ["init", "review"] + (sorted(os.listdir(sk)) if os.path.isdir(sk) else []) + extra_skills,
                  "plugins": plugins + [{"name": "cc-plugin-telemetry", "path": "builtin", "source": "cc-plugin-telemetry@builtin"}],
                  "mcp_servers": [{"name": x} for x in os.environ.get("FAKE_MCP", "").split(",") if x]}), flush=True)
if os.environ.get("FAKE_MCP"):   # #609: a leaked MCP server must end the session at its init; wait for the arm's terminate
    time.sleep(60)   # instead of racing it to `harness init` (a loaded host lost that race one run in two)
os.makedirs(os.path.join(cfg, "projects", "p"), exist_ok=True)
with open(os.path.join(cfg, "projects", "p", sid + ".jsonl"), "a") as t:
    t.write(json.dumps({"type": "assistant", "timestamp": "2026-11-04T10:00:0%dZ" % (n % 10),
                        "effort": argv[argv.index("--effort") + 1] if "--effort" in argv else "medium",
                        "message": {"id": "front%d" % n, "model": "claude-opus-5-5",
                                    "usage": {"input_tokens": 100, "output_tokens": 1000}, "content": []}}) + "\n")
if action.startswith("start"):   # start, start-error, start-restart
    with open(os.path.join(os.environ["FAKE_GH_HOME"], "prds.json"), "w") as f: json.dump([{"number": 1, "state": "OPEN"}], f)
    def sh(*args):   # a Bash call of the front-door session: in the stream as a tool_use, then run for real
        print(json.dumps({"type": "assistant", "session_id": sid, "message": {"content": [
            {"type": "tool_use", "name": "Bash", "input": {"command": "harness " + " ".join(args) + " 2>&1 | tail -5"}}]}}), flush=True)
        subprocess.run(["harness", *args], check=True, stdout=subprocess.DEVNULL)
    sh("init")
    sh("start")
    if action == "start-restart":   # the front door repairs the fleet by hand and starts it again
        sh("stop")
        sh("start", "--recover")
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


# --- the isolated Claude config, the matched arm and the provenance (#590) ----------------------------------
def _host_config(a):
    """A host user's config with a login, a skill, a plugin and an MCP server of its own: none may reach the run."""
    cfg = a.e.env["CLAUDE_CONFIG_DIR"]
    os.makedirs(os.path.join(cfg, "skills", "host-only-skill"))
    os.makedirs(os.path.join(cfg, "plugins"))
    with open(os.path.join(cfg, ".credentials.json"), "w") as fh:
        fh.write('{"login": true}')
    with open(os.path.join(cfg, "plugins", "installed_plugins.json"), "w") as fh:
        json.dump({"plugins": {"host-plugin@elsewhere": [{}]}}, fh)
    with open(os.path.join(cfg, ".claude.json"), "w") as fh:
        json.dump({"mcpServers": {"host-mcp": {}}}, fh)
    return cfg


def _plugin_calls(a):
    p = os.path.join(a.fd, "plugin_calls.jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


@with_arm(["start|The fleet is running."])
def test_the_front_door_and_the_fleet_run_on_an_isolated_config_with_only_the_engines_skills_and_plugins(a):
    host = _host_config(a)
    p = a.run("harness")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result()
    assert tb.bench_run.validate(r) == [] and r["status"] == "ok", r
    iso = {c["env"]["CLAUDE_CONFIG_DIR"] for c in a.front_calls()} | {c["config"] for c in _plugin_calls(a)}
    assert len(iso) == 1 and iso != {host} and list(iso)[0].endswith("/claude-config"), (iso, host)
    iso = iso.pop()
    for c in a.front_calls():   # the user-skills dir the engine links into is the isolated one's too
        assert c["env"]["HARNESS_USER_SKILLS"] == iso + "/skills", c["env"]
    start = calls_of(a, "start")[0]["env"]
    assert start["HARNESS_USER_SKILLS"] == iso + "/skills" and start["HARNESS_CLAUDE_CONFIG_DIRS"].split(os.pathsep)[0] == iso
    # the host's skill / plugin / MCP server are not in what the front door loaded
    logs = os.path.join(a.e.results, "t1", "harness.logs")
    init = json.load(open(os.path.join(logs, "init.json")))
    view = init["view"]
    engine = sorted(armlib.engine_skills())
    assert view["skills"] == ["init", "review"] + engine, view          # two the CLI bundles, then the engine's own
    assert view["plugins"] == ["ralph-loop", "superpowers"] and view["mcp_servers"] == [], view
    assert "host-only-skill" not in view["skills"] and "host-plugin" not in view["plugins"]
    assert r["isolation"] == {"config": "isolated", "engine_skills": engine, "engine_plugins": ["ralph-loop", "superpowers"]}, r["isolation"]
    # the plugins went in through claude itself, into the isolated dir, at user scope
    installs = [c["argv"] for c in _plugin_calls(a) if c["argv"][1:2] == ["install"]]
    assert installs == [["plugin", "install", "ralph-loop@claude-plugins-official", "--scope", "user"],
                        ["plugin", "install", "superpowers@claude-plugins-official", "--scope", "user"]], installs
    assert os.listdir(os.path.join(host, "skills")) == ["host-only-skill"], "the host's own config is untouched"


@with_arm(["start|ok"], extra_env={"FAKE_MCP": "claude-artifacts"})
def test_a_front_door_init_listing_an_mcp_server_stops_the_arm_before_any_work(a):
    p = a.run("harness")
    assert p.returncode == 1, (p.stdout, p.stderr)
    r = a.result()
    assert r["status"] == "error" and "isolation check failed" in r["error"] and "1 mcp servers" in r["error"], r["error"]
    assert calls_of(a, "init") == [] and calls_of(a, "start") == [], "no fleet was set up"


def test_the_isolated_config_links_only_the_login_and_installs_the_engines_skills():
    import tempfile, shutil
    d = tempfile.mkdtemp()
    try:
        host = os.path.join(d, "host"); os.makedirs(os.path.join(host, "skills", "mine"))
        open(os.path.join(host, ".credentials.json"), "w").write("{}")
        open(os.path.join(host, "settings.json"), "w").write('{"hooks": {}}')
        cfg = armlib.isolated_config(os.path.join(d, "iso"), {"CLAUDE_CONFIG_DIR": host})
        assert cfg["login"] == os.path.join(host, ".credentials.json")
        assert sorted(os.listdir(cfg["path"])) == [".claude.json", ".credentials.json"], "the login and nothing else of the host's"
        assert os.path.islink(os.path.join(cfg["path"], ".credentials.json"))
        names = armlib.install_engine_skills(cfg["path"])
        assert names == sorted(armlib.engine_skills()) and "harness" in names and "mine" not in names
        assert os.path.isfile(os.path.join(cfg["path"], "skills", "harness", "SKILL.md")), "the /harness front door resolves"
        assert os.path.isfile(os.path.join(cfg["path"], "skills", "harness-arc", "SKILL.md"))
        none = armlib.isolated_config(os.path.join(d, "iso2"), {"CLAUDE_CONFIG_DIR": os.path.join(d, "nothing")})
        assert none["login"] is None and os.listdir(none["path"]) == [".claude.json"]
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_isolation_problems_name_foreign_plugins_and_mcp_servers_and_leave_builtins_and_skills_alone():
    ok = {"skills": ["a", "b"], "plugins": [{"name": "ralph-loop", "path": "/p"}, {"name": "t", "path": "builtin"}], "mcp_servers": []}
    assert armlib.isolation_problems(ok, armlib.ENGINE_PLUGINS) == []
    bad = dict(ok, plugins=ok["plugins"] + [{"name": "caveman", "source": "caveman@m", "path": "/x"}],
               mcp_servers=[{"name": "m1"}])
    got = armlib.isolation_problems(bad, armlib.ENGINE_PLUGINS)
    assert len(got) == 2 and "1 mcp servers" in got[0] and "1 plugins" in got[1] and "caveman" in got[1], got
    assert armlib.isolation_problems({"skills": 7, "plugins": 2, "mcp_servers": 0}, armlib.ENGINE_PLUGINS) == [], "bare counts have no names"


@with_arm(["start|The fleet is running."])
def test_the_headline_harness_arm_keeps_the_engines_defaults(a):
    assert a.run("harness").returncode == 0
    front = a.front_calls()[0]
    assert "--model" not in front["argv"] and "--effort" not in front["argv"] and "--strict-mcp-config" in front["argv"]
    for c in (front, calls_of(a, "init")[0], calls_of(a, "start")[0]):
        assert not [k for k in c["env"] if k.startswith(("HARNESS_MODEL_", "HARNESS_EFFORT_"))], c["env"]
    r = a.result()
    assert r["configured"] == {"model": None, "effort": None} and tb.bench_run.validate(r) == [], r


@with_arm(["start|The fleet is running."], extra_env=dict(HOST))
def test_the_matched_arm_runs_every_role_on_opus_at_plains_effort(a):
    p = a.run("harness-opus", "--optional")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result("harness-opus")
    assert tb.bench_run.validate(r) == [] and r["status"] == "ok" and r["arm"] == "harness-opus", r
    front = a.front_calls()[0]
    assert front["argv"][front["argv"].index("--model") + 1] == "opus" and front["argv"][front["argv"].index("--effort") + 1] == "medium"
    for c in (front, calls_of(a, "init")[0], calls_of(a, "start")[0]):
        env = c["env"]
        assert (env["HARNESS_MODEL_MANAGER"], env["HARNESS_MODEL_IMPLEMENTER"]) == ("opus", "opus"), env
        assert (env["HARNESS_EFFORT_MANAGER"], env["HARNESS_EFFORT_IMPLEMENTER"]) == ("medium", "medium"), env
    assert r["configured"] == {"model": "opus", "effort": "medium"}, r["configured"]
    assert r["counts"]["workers"] == 1


@with_arm(["start|ok"])
def test_the_matched_arm_takes_model_and_effort_overrides(a):
    assert a.run("harness-opus", "--arm-opt", "effort=low", "--arm-opt", "model=sonnet").returncode == 0
    assert a.result("harness-opus")["configured"] == {"model": "sonnet", "effort": "low"}


@with_arm([])
def test_the_matched_arm_records_a_real_skip_reason_when_the_guard_refuses(a):
    held = os.path.join(a.e.rundir, "usage-holds")
    os.makedirs(held)
    open(os.path.join(held, "acct.hold"), "w").write("held")
    p = a.run("harness-opus", "--optional")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result("harness-opus")
    assert (r["status"], r["reason"]) == ("skipped", "held") and tb.bench_run.validate(r) == [], r
    assert a.front_calls() == [] and a.e.repos() == [], "nothing was created or run"


@with_arm(["start|ok"])
def test_results_record_the_effort_the_transcripts_show_and_the_provenance(a):
    assert a.run("harness").returncode == 0
    r = a.result()
    assert r["effort"] == {"high": 1, "medium": 1}, r["effort"]            # the front door's turn and the lane's
    head = subprocess.run(["git", "-C", tb.ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    prov = r["provenance"]
    assert prov["engine_commit"].startswith(head), (prov, head)
    assert re.fullmatch(r"sha256:[0-9a-f]{16}", prov["skill_version"]) and prov["cli_version"] == "9.9.9 (Claude Code)", prov
    assert prov["skill_version"] == armlib.skill_version(), "the skill the arm installed is the checkout's"
    assert tb.bench_run.validate(r) == []


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


@with_arm(["start-restart|ok"])
def test_restarts_the_front_door_made_by_hand_are_counted_and_the_loaded_config_recorded(a):
    p = a.run("harness")
    assert p.returncode == 0, (p.stdout, p.stderr)
    r = a.result()
    assert tb.bench_run.validate(r) == [] and r["status"] == "ok", r
    assert r["counts"]["fleet_restarts"] == 1, r["counts"]          # init+start, then stop+start --recover by hand
    n = len(armlib.engine_skills())
    assert r["claude_config"] == {"source": "front-door init", "skills": 2 + n, "plugins": 2, "mcp_servers": 0}, r.get("claude_config")
    logs = os.path.join(a.e.results, "t1", "harness.logs")
    assert harness_arm.front_restarts(logs) == 1 and harness_arm.logged_restarts(logs) == 1


@with_arm(["start|ok"], extra_env=dict(FAKE_DIE_ONCE="1"))
def test_the_arms_own_restart_and_the_front_doors_add_up_and_a_plain_start_adds_none(a):
    assert a.run("harness").returncode == 0
    r = a.result()
    logs = os.path.join(a.e.results, "t1", "harness.logs")
    assert harness_arm.front_restarts(logs) == 0, "one `harness start` is the launch, not a restart"
    assert r["counts"]["fleet_restarts"] == 1 and harness_arm.logged_restarts(logs) == 1, r["counts"]


def test_claude_config_and_front_restarts_read_the_stream_defensively(tmp_path=None):
    import tempfile
    d = tempfile.mkdtemp()
    try:
        assert harness_arm.claude_config(d) is None and harness_arm.front_restarts(d) == 0
        with open(os.path.join(d, "front-01.stream.jsonl"), "w") as f:
            f.write("not json\n")
            f.write(json.dumps({"type": "system", "subtype": "init", "skills": 186, "plugins": 10, "mcp_servers": 4}) + "\n")
        assert harness_arm.claude_config(d) == {"source": "front-door init", "skills": 186, "plugins": 10, "mcp_servers": 4}
        with open(os.path.join(d, "front-01.stream.jsonl"), "w") as f:
            f.write(json.dumps({"type": "system", "subtype": "init", "skills": 1}) + "\n")
        assert harness_arm.claude_config(d) is None, "an init without the three figures is not a record"
    finally:
        import shutil; shutil.rmtree(d, ignore_errors=True)


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

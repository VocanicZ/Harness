#!/usr/bin/env python3
"""test_bench_plain.py — #382 (PRD #345): the plain Claude Code arm, bench/arms/plain.py, run through the
real runner (bench/run.py) with a fake gh (bare repos) and a fake claude that prints stream-json turns.
Covered: the isolation proof (passes on a clean init, builtin plugins aside; fails — before any work, as an
error result — on an init listing any skill, plugin or MCP server); the continue-reply loop (stops at
"done", stops at the 20-reply cap, the count lands in the results JSON, `--resume` carries the session and
the reply is the scripted line); the launch line holds no --bare, no API key and no config dir; models,
tokens and commits come out of the transcript and the repo."""
import json, os, shlex, stat, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, HERE)
import importlib.util
import test_bench_run as tb                                    # noqa: E402  (Env, with_env, bench_run)

spec = importlib.util.spec_from_file_location("plain_arm", os.path.join(tb.ROOT, "bench", "arms", "plain.py"))
plain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plain)

# A claude that replays $FAKE_CLAUDE_DIR/plan, one line per turn: `<action>|<reply text>`, action `commit`
# (commit + push to origin main from claude's cwd) or `none`. Past the plan: `none|still going`.
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
d = os.environ["FAKE_CLAUDE_DIR"]
argv = sys.argv[1:]
if argv[:1] == ["--version"]:
    print("9.9.9 (Claude Code)"); sys.exit(0)
prompt = sys.stdin.read()
with open(os.path.join(d, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"argv": argv, "prompt": prompt, "cwd": os.getcwd(), "api_key": os.environ.get("ANTHROPIC_API_KEY"),
                        "no_memory": os.environ.get("CLAUDE_CODE_DISABLE_AUTO_MEMORY"),
                        "config": os.environ.get("CLAUDE_CONFIG_DIR"),
                        "config_files": sorted(os.listdir(os.environ["CLAUDE_CONFIG_DIR"]))}) + "\n")
n = sum(1 for _ in open(os.path.join(d, "calls.jsonl")))
plan = [l.rstrip("\n") for l in open(os.path.join(d, "plan")) if l.strip()]
action, _, text = (plan[n - 1] if n <= len(plan) else "none|still going").partition("|")
sid = argv[argv.index("--resume") + 1] if "--resume" in argv else open(os.path.join(d, "sid")).read().strip()
init = json.load(open(os.path.join(d, "init.json")))
if init.pop("from_config", False):   # list what the config dir holds, like the real CLI (plus a CLI built-in plugin)
    cfg = os.environ["CLAUDE_CONFIG_DIR"]
    sk = os.path.join(cfg, "skills")
    init.update(skills=sorted(os.listdir(sk)) if os.path.isdir(sk) else [], mcp_servers=[], slash_commands=[],
                plugins=[{"name": "cc-plugin-telemetry", "path": "builtin", "source": "cc-plugin-telemetry@builtin"}])
init.update(type="system", subtype="init", session_id=sid, model="claude-opus-5-5")
print(json.dumps(init), flush=True)
cfg = os.environ["CLAUDE_CONFIG_DIR"]
os.makedirs(os.path.join(cfg, "projects", "p"), exist_ok=True)
with open(os.path.join(cfg, "projects", "p", sid + ".jsonl"), "a") as t:
    t.write(json.dumps({"type": "assistant", "timestamp": "2026-11-04T10:00:0%dZ" % (n % 10),
                        "effort": "medium", "message": {"id": "m%d" % n, "model": "claude-opus-5-5",
                                    "usage": {"input_tokens": 100, "output_tokens": 1000}, "content": []}}) + "\n")
if action == "commit":
    g = ["git", "-c", "user.name=fake", "-c", "user.email=f@x"]
    open("pennywise.py", "a").write("# turn %d\n" % n)
    subprocess.run(["git", "add", "-A"], check=True)
    subprocess.run(g + ["commit", "-qm", "turn %d" % n], check=True)
    subprocess.run(["git", "push", "-q", "origin", "main"], check=True)
print(json.dumps({"type": "assistant", "session_id": sid, "message": {"content": [{"type": "text", "text": text}]}}), flush=True)
print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "session_id": sid, "result": text}), flush=True)
'''
CLEAN = {"skills": [], "mcp_servers": [], "slash_commands": [], "tools": ["Bash"],
         "plugins": [{"name": "cc-plugin-telemetry", "path": "builtin", "source": "cc-plugin-telemetry@builtin"}]}


class Plain:
    """tb.Env plus a fake claude on a plan."""

    def __init__(self, plan, init=None):
        self.e = tb.Env()
        self.fd = os.path.join(self.e.d, "fake-claude"); os.makedirs(self.fd)
        self.exe = os.path.join(self.fd, "claude")
        tb.Env.write_exe(self.exe, FAKE_CLAUDE)
        for name, text in (("plan", "\n".join(plan) + "\n"), ("init.json", json.dumps(init or CLEAN)),
                           ("sid", str(uuid.uuid4()))):
            with open(os.path.join(self.fd, name), "w") as fh:
                fh.write(text)
        self.e.env.update(FAKE_CLAUDE_DIR=self.fd, HARNESS_CLAUDE_CONFIG_DIRS=self.e.env["CLAUDE_CONFIG_DIR"],
                          ANTHROPIC_API_KEY="sk-ant-must-not-reach-claude")

    def run(self, *args):
        return self.e.run("plain", "--arm-opt", f"claude={shlex.quote(sys.executable)} {shlex.quote(self.exe)}", *args)

    def calls(self):
        p = os.path.join(self.fd, "calls.jsonl")
        return [json.loads(l) for l in open(p)] if os.path.exists(p) else []

    def result(self):
        return self.e.result("plain")

    def logs(self, name):
        return os.path.join(self.e.results, "t1", "plain.logs", name)

    def close(self):
        self.e.close()


def with_plain(plan, init=None):
    def deco(fn):
        def wrapped():
            p = Plain(plan, init)
            try:
                fn(p)
            finally:
                p.close()
        wrapped.__name__ = fn.__name__
        return wrapped
    return deco


@with_plain(["none|I built the parser. Want me to carry on with the CLI?", "commit|All done, pushed to main."])
def test_a_stopped_session_gets_the_scripted_reply_until_done(p):
    r = p.run()
    assert r.returncode == 0, (r.stdout, r.stderr)
    res = p.result()
    assert tb.bench_run.validate(res) == [] and (res["status"], res["error"]) == ("ok", None), res
    assert res["counts"] == {"continue_replies": 1, "commits": 1}, res["counts"]
    calls = p.calls()
    assert len(calls) == 2, calls
    brief = open(os.path.join(tb.ROOT, "bench", "fixture", "brief.md")).read().rstrip("\n")
    assert calls[0]["prompt"].startswith(brief) and "--resume" not in calls[0]["argv"], calls[0]
    sid = open(os.path.join(p.fd, "sid")).read().strip()
    assert calls[1]["prompt"] == "keep going, decide for yourself", calls[1]
    assert calls[1]["argv"][-2:] == ["--resume", sid], calls[1]["argv"]
    # measured from the transcript the arm registered: both turns, the model that actually ran
    assert list(res["models"]) == ["claude-opus-5-5"] and res["tokens"]["output"] == 2000, res["models"]
    assert res["cost_usd"] > 0


@with_plain(["commit|Done. Everything is in main."])
def test_done_on_the_first_turn_needs_no_reply(p):
    assert p.run().returncode == 0
    assert p.result()["counts"] == {"continue_replies": 0, "commits": 1} and len(p.calls()) == 1


@with_plain(["commit|Pushed the first cut, anything else you want?", "none|Nothing else, it is all in main."])
def test_a_trailing_question_is_not_done_even_with_the_work_pushed(p):
    assert p.run().returncode == 0
    assert p.result()["counts"] == {"continue_replies": 1, "commits": 1} and len(p.calls()) == 2


@with_plain([])
def test_the_reply_cap_is_20_and_the_count_lands_in_the_results(p):
    r = p.run()
    assert r.returncode == 0, (r.stdout, r.stderr)
    res = p.result()
    assert res["status"] == "ok" and tb.bench_run.validate(res) == [], res
    assert res["counts"] == {"continue_replies": 20, "commits": 0}, res["counts"]
    calls = p.calls()
    assert len(calls) == 21, len(calls)                      # the brief plus 20 replies, then it stops
    assert all(c["prompt"] == "keep going, decide for yourself" for c in calls[1:])


def _isolation_fails(p, why):
    r = p.run()
    assert r.returncode == 1, (r.stdout, r.stderr)
    res = p.result()
    assert res["status"] == "error" and "isolation" in res["error"] and why in res["error"], res["error"]
    assert len(p.calls()) == 1, "no work after a bad init"
    assert "continue_replies" not in res["counts"] or res["counts"]["continue_replies"] == 0
    assert res["cost_usd"] == 0 and res["models"] == {}, "nothing is measured for a session that never ran"


@with_plain(["commit|done"], dict(CLEAN, skills=["superpowers:brainstorming"]))
def test_isolation_fails_on_an_init_listing_a_skill(p):
    _isolation_fails(p, "1 skills")


@with_plain(["commit|done"], dict(CLEAN, plugins=CLEAN["plugins"] + [{"name": "caveman", "path": "/x", "source": "caveman@m"}]))
def test_isolation_fails_on_an_init_listing_a_plugin(p):
    _isolation_fails(p, "1 plugins")


@with_plain(["commit|done"], dict(CLEAN, mcp_servers=[{"name": "claude-artifacts", "status": "connected"}]))
def test_isolation_fails_on_an_init_listing_an_mcp_server(p):
    _isolation_fails(p, "1 mcp servers")


@with_plain(["commit|done"])
def test_isolation_proof_is_kept_in_the_run_log(p):
    assert p.run().returncode == 0
    proof = json.load(open(p.logs("init.json")))
    assert proof["isolation"] == {"skills": 0, "plugins": 0, "plugins_builtin": 1, "mcp_servers": 0}, proof
    assert proof["init"]["model"] == "claude-opus-5-5"


@with_plain(["none|go on?", "commit|done"])
def test_the_launch_line_has_no_bare_no_api_key_no_config_dir(p):
    assert p.run().returncode == 0
    calls = p.calls()
    for c in calls:
        line = " ".join(c["argv"])
        assert "--bare" not in c["argv"] and "sk-ant" not in line and "CLAUDE_CONFIG_DIR" not in line, line
        assert "--config-dir" not in c["argv"] and p.e.env["CLAUDE_CONFIG_DIR"] not in line, line
        assert c["api_key"] is None, "the API key must not reach claude"
        assert c["no_memory"] == "1"
        assert c["cwd"] != p.e.d and "--model" not in c["argv"], "default model, run in the clone"
        for flag in ("--disable-slash-commands", "--strict-mcp-config"):
            assert flag in c["argv"], (flag, c["argv"])
        assert c["argv"][c["argv"].index("--setting-sources") + 1] == "project,local"
    logged = open(p.logs("launch.txt")).read().splitlines()
    assert len(logged) == 2 and all("--bare" not in l for l in logged), logged


def _host_with_a_user_setup(p):
    cfg = p.e.env["CLAUDE_CONFIG_DIR"]
    os.makedirs(os.path.join(cfg, "skills", "host-only-skill"))
    with open(os.path.join(cfg, ".credentials.json"), "w") as fh:
        fh.write("{}")
    with open(os.path.join(cfg, "settings.json"), "w") as fh:
        fh.write('{"hooks": {"SessionStart": []}, "enabledPlugins": {"host-plugin@x": true}}')
    return cfg


@with_plain(["none|go on?", "commit|done"], dict(CLEAN, from_config=True))
def test_every_turn_runs_on_the_isolated_config_not_the_hosts(p):
    host = _host_with_a_user_setup(p)
    assert p.run().returncode == 0
    calls = p.calls()
    assert len(calls) == 2
    for c in calls:
        assert c["config"] != host and c["config"].endswith("/claude-config"), (c["config"], host)
        assert c["config"] == calls[0]["config"], "the same dir every turn"
    # before the first turn the dir holds the login and nothing else of the host's (later turns add the session's own projects/)
    assert calls[0]["config_files"] == [".claude.json", ".credentials.json"], calls[0]["config_files"]
    proof = json.load(open(p.logs("init.json")))
    assert proof["view"] == {"skills": [], "plugins": [], "mcp_servers": []} and proof["isolation"]["plugins_builtin"] == 1, proof
    res = p.result()
    assert res["claude_config"] == {"source": "isolated config dir, session init", "skills": 0, "plugins": 0, "mcp_servers": 0}
    assert res["configured"] == {"model": None, "effort": None} and tb.bench_run.validate(res) == [], res


@with_plain(["commit|done"])
def test_results_record_effort_and_provenance_for_the_plain_arm_too(p):
    assert p.run().returncode == 0
    res = p.result()
    assert res["effort"] == {"medium": 1}, res["effort"]
    prov = res["provenance"]
    assert prov["cli_version"] == "9.9.9 (Claude Code)" and prov["engine_commit"] and prov["skill_version"].startswith("sha256:"), prov
    assert tb.bench_run.validate(res) == []


def test_both_arms_init_the_same_isolated_config_apart_from_what_the_engine_installs():
    import test_bench_harness as th
    p = Plain(["commit|done"], dict(CLEAN, from_config=True))
    a = th.Arm(["start|ok"])
    try:
        for e in (p.e, a.e):
            os.makedirs(os.path.join(e.env["CLAUDE_CONFIG_DIR"], "skills", "host-only-skill"))
        assert p.run().returncode == 0
        assert a.run("harness").returncode == 0
        pv = json.load(open(p.logs("init.json")))["view"]
        hv = json.load(open(os.path.join(a.e.results, "t1", "harness.logs", "init.json")))["view"]
        engine_skills, engine_plugins = set(th.armlib.engine_skills()), set(th.armlib.ENGINE_PLUGINS)
        bundled = {"init", "review"}        # the CLI's own, which the harness fake lists and plain's `--disable-slash-commands` hides
        rest = {"skills": sorted(set(hv["skills"]) - engine_skills - bundled), "mcp_servers": hv["mcp_servers"],
                "plugins": sorted(set(hv["plugins"]) - engine_plugins)}
        assert rest == pv == {"skills": [], "plugins": [], "mcp_servers": []}, (rest, pv)
        assert set(hv["skills"]) >= engine_skills and set(hv["plugins"]) == engine_plugins, hv
        assert "host-only-skill" not in hv["skills"] + pv["skills"]
    finally:
        p.close(); a.close()


def test_launch_argv_and_isolation_units():
    argv = plain.launch_argv("claude")
    assert argv[0] == "claude" and "--bare" not in argv and "--resume" not in argv
    assert plain.launch_argv("claude", "S")[-2:] == ["--resume", "S"]
    env = plain.child_env({"ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t", "KEEP": "1"})
    assert env == {"KEEP": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"}, env
    assert plain.isolation(CLEAN)[1] == []
    assert plain.isolation({})[1] == []
    assert plain.isolation(dict(CLEAN, skills=["a"], mcp_servers=["m"]))[1] == ["1 skills", "1 mcp servers"]


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

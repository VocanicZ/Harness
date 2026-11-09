"""test_opencode_headless.py — #482: the headless opencode lane runner (scripts/cli/opencode_headless.py), driven
against fake-opencode replaying the real `opencode run --format json` captures in
test/fixtures/cli/opencode/run-json/ (see ../fixtures/cli/opencode/README.md). The turn fold over each
capture, the command a turn runs (no session on the first turn, `--session <id>` after, OpenCode's own id
read off its first event), the question-deny env, a lane relaunched on a session OpenCode lost, the limit and
transient states, and `watch`. The lane protocol itself (inbox, interrupt, stop, pane) is the core's, proved
by test_headless_core.py and test_claude_headless.py."""
import importlib.util, json, os, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hlproc import RUNNER_PY, WINDOWS, alive, gone, kill_tree  # noqa: E402,F401
ROOT = os.path.normpath(os.path.join(HERE, ".."))
RUNNER = os.path.join(ROOT, "scripts", "cli", "opencode_headless.py")
FIX = os.path.join(HERE, "fixtures", "cli", "opencode", "run-json")
FAKE = os.path.join(FIX, "fake-opencode")
spec = importlib.util.spec_from_file_location("opencode_headless", RUNNER)
oh = importlib.util.module_from_spec(spec); spec.loader.exec_module(oh)


def fixture(name):
    return [json.loads(l) for l in open(os.path.join(FIX, f"{name}.jsonl")) if l.strip()]


def wait_for(pred, what, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {what}")


class Lane:
    """A runner on a fresh lane dir, its opencode the fake replaying <plan>."""

    def __init__(self, plan, session_id=None, resume=False, effort=None, flags="--auto", model=None, xdg=None):
        self.tmp = tempfile.mkdtemp()
        self.lane, self.fake, self.wd, self.xdg = (os.path.join(self.tmp, p) for p in ("lane", "fake", "wd", "xdg"))
        self.xdg = xdg or self.xdg   # OpenCode's database: shared with an earlier lane to resume its session
        for p in (self.lane, self.fake, self.wd):
            os.makedirs(p)
        with open(os.path.join(self.fake, "plan"), "w") as f:
            f.write("\n".join(plan) + "\n")
        env = dict(os.environ, FAKE_CLAUDE_DIR=self.fake, XDG_DATA_HOME=self.xdg)
        cmd = [RUNNER_PY, RUNNER, "run", "--lane", self.lane, "--cwd", self.wd,
               "--bin", f"{RUNNER_PY} {FAKE}", f"--flags={flags}"]
        for flag, val in (("--session-id", session_id), ("--effort", effort), ("--model", model)):
            if val:
                cmd += [flag, val]
        if resume:
            cmd += ["--resume"]
        self.proc = subprocess.Popen(cmd, env=env)
        wait_for(lambda: self.state().get("runner_pid") == self.proc.pid or self.proc.poll() is not None,
                 "the runner's first state")
        assert self.proc.poll() is None, f"the runner exited {self.proc.returncode} at start"

    def send(self, text):
        assert subprocess.run([sys.executable, RUNNER, "send", "--lane", self.lane, text]).returncode == 0

    def state(self):
        return oh.read_state(self.lane)

    def calls(self):
        try:
            return [json.loads(l) for l in open(os.path.join(self.fake, "calls.jsonl"))]
        except OSError:
            return []

    def events(self):
        return [json.loads(l) for l in open(os.path.join(self.lane, "events.jsonl"))]

    def wait_turn(self, n, state=None):
        st = wait_for(lambda: (lambda s: s if s.get("turn") == n and s.get("state") != "busy" else None)(self.state()),
                      f"turn {n} to end")
        if state:
            assert st["state"] == state, f"turn {n}: state {st['state']!r}, want {state!r} ({st})"
        return st

    def stop(self):
        subprocess.run([sys.executable, RUNNER, "stop", "--lane", self.lane, "--timeout", "15"])
        self.proc.wait(timeout=15)


# --- the fold over each real capture ------------------------------------------------------------
def test_classify_each_capture():
    st, reply, err, _ = oh.classify(fixture("normal"), 0)
    assert (st, reply, err) == ("idle", "PONG", None), (st, reply, err)
    # a turn that called a tool: the reply is the text of its LAST message, not the tool call's step
    st, reply, err, _ = oh.classify(fixture("tool-use"), 0)
    assert (st, reply, err) == ("idle", "DONE", None), (st, reply, err)
    st, reply, err, resets = oh.classify(fixture("limit"), 1)
    assert st == "limit" and "usage limit reached" in err and 0 < resets - time.time() <= 60, (st, err, resets)   # retry-after: 60
    ev = fixture("limit-quota")   # OpenAI's insufficient_quota, with no word of when it lifts
    ev[0]["error"]["data"]["responseHeaders"].pop("retry-after")
    st, reply, err, resets = oh.classify(ev, 1)
    assert st == "limit" and "exceeded your current quota" in err and resets is None, (st, err, resets)
    st, reply, err, resets = oh.classify(fixture("transient"), 1)
    assert st == "transient" and "Service Unavailable" in err and resets is None, (st, err)


def test_limit_is_read_from_the_error_not_the_status_alone():
    # a 429 that is not a quota (a rate limit OpenCode's retries gave up on) is transient: retryable
    ev = fixture("limit-quota")
    assert oh.classify(ev, 1)[0] == "limit"
    ev[0]["error"]["data"].update(message="Too Many Requests", responseBody='{"error": {"message": "Too Many Requests"}}')
    assert oh.classify(ev, 1)[0] == "transient"
    # the quota wording in the body alone makes it a limit
    ev = fixture("limit-quota")
    ev[0]["error"]["data"]["message"] = "Provider returned error"
    assert oh.classify(ev, 1)[0] == "limit"
    # the provider's own "It will reset in 5 minutes" wins over a retry-after
    ev[0]["error"]["data"]["message"] = "5-hour usage limit reached. It will reset in 5 minutes."
    assert 290 <= oh.classify(ev, 1)[3] - time.time() <= 300


def test_exit_without_a_finished_step_is_transient():
    st, reply, err, _ = oh.classify(fixture("normal")[:2], 143)
    assert st == "transient" and "no finished step" in err, (st, err)
    # a finished step with a failing exit is not a clean turn either
    assert oh.classify(fixture("normal"), 1)[0] == "transient"


def test_session_not_found_is_no_conversation():
    t = oh.Turn()
    assert t.outcome(1, "\x1b[91m\x1b[1mError: \x1b[0mSession not found")[0] == "transient" and t.no_conversation
    t = oh.Turn()
    t.outcome(1, "boom"); assert not t.no_conversation


def test_token_usage_is_summed_over_steps():
    t = oh.Turn()
    for e in fixture("tool-use"):
        t.feed(e)
    assert t.tokens["input"] > 0 and t.tokens["output"] > 0 and t.session_id.startswith("ses_"), t.tokens


# --- the command a turn runs --------------------------------------------------------------------
def test_argv_first_turn_names_no_session_then_continues_it():
    a = oh.ADAPTER
    assert a.argv(["opencode"], "lane-uuid", False, "opencode/big-pickle", "high", ["--auto"]) == \
        ["opencode", "run", "--format", "json", "-m", "opencode/big-pickle", "--variant", "high", "--auto"]
    assert a.argv(["opencode"], "ses_abc", True, None, None, ["--auto"]) == \
        ["opencode", "run", "--format", "json", "--session", "ses_abc", "--auto"]


def test_turn_env_denies_questions_and_pins_the_cli():
    env = oh.ADAPTER.env()
    assert json.loads(env["OPENCODE_CONFIG_CONTENT"]) == {"permission": {"question": "deny"}}
    assert env["OPENCODE_DISABLE_AUTOUPDATE"] == "1"


# --- through the runner -------------------------------------------------------------------------
def test_session_opencode_picked_is_continued_and_the_env_reaches_it():
    lane = Lane(["normal", "tool-use"], session_id="lane-uuid-not-an-opencode-id", effort="high", model="opencode/big-pickle")
    try:
        lane.send("first"); st = lane.wait_turn(1, "idle")
        sid = st["session_id"]
        assert sid.startswith("ses_") and st["session_started"] is True and st["last_reply"] == "PONG", st
        lane.send("second"); st = lane.wait_turn(2, "idle")
        a0, a1 = (c["argv"] for c in lane.calls())
        assert "--session" not in a0 and a0[a0.index("--variant") + 1] == "high" and "-m" in a0, a0
        assert a1[a1.index("--session") + 1] == sid, a1
        assert st["session_id"] == sid and st["last_reply"] == "DONE", st
        assert [c["prompt"] for c in lane.calls()] == ["first", "second"]
        assert st["adapter"] == "opencode" and st["account"] == "default" and st["rate_limit"] is None, st
    finally:
        lane.stop()


def test_resume_flag_continues_the_session_from_the_first_turn():
    seed = Lane(["normal"])   # a real session to resume: its rows are in seed.xdg
    try:
        seed.send("seed"); sid = seed.wait_turn(1, "idle")["session_id"]
    finally:
        seed.stop()
    lane = Lane(["tool-use"], session_id=sid, resume=True, xdg=seed.xdg)
    try:
        assert lane.state()["session_started"] is True
        lane.send("resume prompt")
        st = lane.wait_turn(1, "idle")
        a0 = lane.calls()[0]["argv"]
        assert a0[a0.index("--session") + 1] == sid, a0
        assert st["session_id"] == sid and st["last_reply"] == "DONE", st
    finally:
        lane.stop()


def test_resume_of_a_session_opencode_lost_starts_a_new_one():
    lane = Lane(["no-conversation", "normal", "normal"], session_id="ses_doesnotexist000", resume=True)
    try:
        lane.send("resume prompt")
        st = lane.wait_turn(2, "idle")
        calls = lane.calls()
        assert [c["prompt"] for c in calls] == ["resume prompt", "resume prompt"], calls
        a0, a1 = (c["argv"] for c in calls)
        assert a0[a0.index("--session") + 1] == "ses_doesnotexist000", a0
        assert "--session" not in a1, a1
        assert st["session_id"] != "ses_doesnotexist000" and st["session_id"].startswith("ses_"), st
        assert st["session_started"] is True and st["last_reply"] == "PONG", st
        assert any(e.get("subtype") == "resume_missing" for e in lane.events()), "the fallback is logged"
        lane.send("later"); lane.wait_turn(3, "idle")
        a2 = lane.calls()[2]["argv"]
        assert a2[a2.index("--session") + 1] == st["session_id"], a2
    finally:
        lane.stop()


def test_limit_and_transient_turns_park_the_lane_and_the_next_runs():
    lane = Lane(["limit", "transient", "normal"])
    try:
        lane.send("one"); st = lane.wait_turn(1, "limit")
        assert "usage limit reached" in st["error"] and st["limit_resets_at"], st
        lane.send("two"); st = lane.wait_turn(2, "transient")
        assert "Service Unavailable" in st["error"] and not st.get("limit_resets_at"), st
        lane.send("three"); st = lane.wait_turn(3, "idle")
        assert st["last_reply"] == "PONG" and st["error"] is None, st
    finally:
        lane.stop()


def test_watch_prints_turns_tools_replies_and_errors():
    lane = Lane(["normal", "tool-use", "limit"])
    try:
        for n in (1, 2, 3):
            lane.send(f"msg{n}"); lane.wait_turn(n)
        out = subprocess.run([sys.executable, RUNNER, "watch", "--lane", lane.lane, "--no-follow"],
                             capture_output=True, text=True).stdout
        assert "── turn 1 (message) ── msg1" in out and "PONG" in out, out
        assert "· bash echo hi > proof.txt" in out and "DONE" in out and "── turn 2 ended: idle" in out, out
        assert "· error: " in out and "usage limit reached" in out and "── turn 3 ended: limit" in out, out
    finally:
        lane.stop()


def test_pane_reads_as_the_claude_shapes_the_watchdog_regexes_know():
    lane = Lane(["limit", "transient"])
    try:
        lane.send("one"); lane.wait_turn(1, "limit")
        p = subprocess.run([sys.executable, RUNNER, "pane", "--lane", lane.lane], capture_output=True, text=True).stdout
        assert "You've hit your usage limit" in p and "\n❯ " in p, p
        lane.send("two"); lane.wait_turn(2, "transient")
        p = subprocess.run([sys.executable, RUNNER, "pane", "--lane", lane.lane], capture_output=True, text=True).stdout
        assert "⎿  API Error: " in p and "Service Unavailable" in p, p
    finally:
        lane.stop()


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

"""test_hermes_headless.py — #484: the headless hermes lane runner (scripts/cli/hermes_headless.py), driven
against fake-hermes replaying the real `hermes chat --format stream-json` captures in
test/fixtures/cli/hermes/stream-json/ (see ../fixtures/cli/hermes/README.md). The turn fold over each
capture, the command a turn runs (`-c <session> --create-if-missing`, the message on stdin, the lane's profile as
HERMES_HOME), the limit and transient states, the gateway stopped after a killed turn, and `watch`. The lane
protocol itself (inbox, interrupt, stop, pane) is the core's, proved by test_headless_core.py and
test_claude_headless.py."""
import importlib.util, json, os, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
RUNNER = os.path.join(ROOT, "scripts", "cli", "hermes_headless.py")
FIX = os.path.join(HERE, "fixtures", "cli", "hermes", "stream-json")
FAKE = os.path.join(FIX, "fake-hermes")
spec = importlib.util.spec_from_file_location("hermes_headless", RUNNER)
hh = importlib.util.module_from_spec(spec); spec.loader.exec_module(hh)


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
    """A runner on a fresh lane dir, its hermes the fake replaying <plan>, its profile under a throwaway home."""

    def __init__(self, plan, session_id="lane-uuid", resume=False, op_home=None):
        self.tmp = tempfile.mkdtemp()
        self.lane, self.fake, self.wd, self.op = (os.path.join(self.tmp, p) for p in ("lane", "fake", "wd", "op"))
        self.op = op_home or self.op
        for p in (self.lane, self.fake, self.wd):
            os.makedirs(p)
        with open(os.path.join(self.fake, "plan"), "w") as f:
            f.write("\n".join(plan) + "\n")
        env = dict(os.environ, FAKE_CLAUDE_DIR=self.fake, HARNESS_HERMES_HOME=self.op)
        cmd = [sys.executable, RUNNER, "run", "--lane", self.lane, "--cwd", self.wd,
               "--bin", f"{sys.executable} {FAKE}", "--session-id", session_id]
        if resume:
            cmd += ["--resume"]
        self.proc = subprocess.Popen(cmd, env=env)
        wait_for(lambda: self.state().get("runner_pid") == self.proc.pid or self.proc.poll() is not None,
                 "the runner's first state")
        assert self.proc.poll() is None, f"the runner exited {self.proc.returncode} at start"

    def send(self, text):
        assert subprocess.run([sys.executable, RUNNER, "send", "--lane", self.lane, text]).returncode == 0

    def state(self):
        return hh.read_state(self.lane)

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
    st, reply, err, _ = hh.classify(fixture("normal"), 0)
    assert (st, reply, err) == ("idle", "PONG", None), (st, reply, err)
    # a turn that called a tool: the reply is the `result`'s text, not the "\n\n" the tool call left in the stream
    st, reply, err, _ = hh.classify(fixture("tool-use"), 0)
    assert (st, reply, err) == ("idle", "DONE", None), (st, reply, err)
    st, reply, err, resets = hh.classify(fixture("limit"), 1)
    assert st == "limit" and "usage limit" in err and 7000 < resets - time.time() <= 7200, (st, err, resets)   # "(in 2h 00m)"
    st, reply, err, resets = hh.classify(fixture("transient"), 1)
    assert st == "transient" and "503" in err and resets is None, (st, err)


def test_limit_is_read_from_the_error_not_the_exit_alone():
    base = {"type": "result", "session_id": "local-x", "exit_code": 1, "text": "", "tokens": {}}
    # a plain 429 with no reset (the provider's per-minute throttle) and a 503 are transient: they retry
    assert hh.classify([dict(base, error="HTTP 429: Too Many Requests")], 1)[0] == "transient"
    assert hh.classify([dict(base, error="HTTP 503: Service Unavailable")], 1)[0] == "transient"
    # a quota, credits, a Nous account's rate limit: the account's, not a passing fault
    for e in ("HTTP 429: You exceeded your current quota", "Billing or credits exhausted — add credits",
              "Your Nous account has hit its rate limit; it resets in 3h 5m", "HTTP 429: usage limit reached"):
        assert hh.classify([dict(base, error=e)], 1)[0] == "limit", e
    # when it lifts: "resets in ~1h 59m", "(in 2h 00m)"; neither -> unknown
    r = hh.classify([dict(base, error="Rate limited after 3 retries — HTTP 429: x (resets in ~1h 59m)")], 1)
    assert r[0] == "limit" and 7100 < r[3] - time.time() <= 7140, r
    r = hh.classify([dict(base, error="HTTP 429: usage limit", text="Limit resets at 13:01 (in 2h 00m).")], 1)
    assert 7100 < r[3] - time.time() <= 7200, r
    assert hh.classify([dict(base, error="HTTP 429: usage limit reached")], 1)[3] is None


def test_exit_without_a_result_is_transient():
    st, reply, err, _ = hh.classify(fixture("normal")[:2], 143)
    assert st == "transient" and "no result" in err, (st, err)
    # a result that says it failed is not a clean turn even when the process exited 0
    ev = fixture("normal")
    ev[-1]["exit_code"] = 1
    assert hh.classify(ev, 0)[0] == "transient"


def test_reply_falls_back_to_the_text_said_after_the_last_tool_call():
    ev = [e for e in fixture("tool-use") if e["type"] != "result"]
    t = hh.Turn()
    for e in ev:
        t.feed(e)
    assert t.reply == "DONE", t.reply


def test_token_usage_and_session_id_come_from_the_result():
    t = hh.Turn()
    for e in fixture("tool-use"):
        t.feed(e)
    assert t.tokens["input"] > 0 and t.tokens["output"] > 0 and t.session_id.startswith("local-"), (t.tokens, t.session_id)


# --- the command a turn runs --------------------------------------------------------------------
def test_argv_names_the_session_the_same_way_every_turn():
    a = hh.ADAPTER
    want = ["hermes", "chat", "--format", "stream-json", "--yolo", "--accept-hooks", "-c", "SID", "--create-if-missing",
            "--query-file", "-"]
    assert a.argv(["hermes"], "SID", False, "gpt-4.1", "high", []) == want   # model, effort: the profile's config
    assert a.argv(["hermes"], "SID", True, None, None, []) == want


def test_turn_runs_in_the_lane_profile_hermes_sh_seeds():
    wd = "/work/tree"
    # scripts/cli/hermes.sh `_hermes_home`: <operator home>/profiles/harness<sha1 of the worktree, 12 hex>
    sha = subprocess.run(["bash", "-c", "printf '%s' \"$1\" | sha1sum | cut -c1-12", "x", wd], capture_output=True, text=True).stdout.strip()
    old = os.environ.get("HARNESS_HERMES_HOME")
    os.environ["HARNESS_HERMES_HOME"] = "/op"
    try:
        assert hh.ADAPTER.env(wd) == {"HERMES_HOME": f"/op/profiles/harness{sha}"}, hh.ADAPTER.env(wd)
        os.environ.pop("HARNESS_HERMES_HOME")
        assert hh.ADAPTER.env(wd)["HERMES_HOME"] == os.path.join(os.path.expanduser("~"), ".hermes", "profiles", f"harness{sha}")
    finally:
        if old is not None:
            os.environ["HARNESS_HERMES_HOME"] = old


# --- through the runner -------------------------------------------------------------------------
def test_session_is_titled_with_the_lane_id_then_continued_by_hermes_id():
    lane = Lane(["normal", "tool-use"], session_id="lane-uuid")
    try:
        lane.send("first"); st = lane.wait_turn(1, "idle")
        sid = st["session_id"]
        assert sid.startswith("local-") and st["session_started"] is True and st["last_reply"] == "PONG", st
        lane.send("second"); st = lane.wait_turn(2, "idle")
        a0, a1 = (c["argv"] for c in lane.calls())
        assert a0[a0.index("-c") + 1] == "lane-uuid" and "--create-if-missing" in a0 and "--query-file" in a0, a0
        assert a1[a1.index("-c") + 1] == sid, a1
        assert st["session_id"] == sid and st["last_reply"] == "DONE", st
        assert [c["prompt"] for c in lane.calls()] == ["first", "second"]
        assert st["adapter"] == "hermes" and st["account"] == "default" and st["rate_limit"] is None, st
        # the fake wrote the lane's profile's state.db: the turns ran in HERMES_HOME the adapter set
        profiles = os.listdir(os.path.join(lane.op, "profiles"))
        assert len(profiles) == 1 and profiles[0].startswith("harness"), profiles
        assert os.path.exists(os.path.join(lane.op, "profiles", profiles[0], "state.db"))
    finally:
        lane.stop()


def test_resume_flag_continues_the_session_from_the_first_turn():
    lane = Lane(["tool-use"], session_id="local-abc123", resume=True)
    try:
        assert lane.state()["session_started"] is True
        lane.send("resume prompt")
        lane.wait_turn(1, "idle")
        a0 = lane.calls()[0]["argv"]
        assert a0[a0.index("-c") + 1] == "local-abc123", a0
    finally:
        lane.stop()


def test_limit_and_transient_turns_park_the_lane_and_the_next_runs():
    lane = Lane(["limit", "transient", "normal"])
    try:
        lane.send("one"); st = lane.wait_turn(1, "limit")
        assert "usage limit" in st["error"] and st["limit_resets_at"], st
        lane.send("two"); st = lane.wait_turn(2, "transient")
        assert "503" in st["error"] and not st.get("limit_resets_at"), st
        lane.send("three"); st = lane.wait_turn(3, "idle")
        assert st["last_reply"] == "PONG" and st["error"] is None, st
    finally:
        lane.stop()


def test_stopping_a_running_turn_stops_the_lane_gateway():
    lane = Lane(["hang"])
    try:
        lane.send("go")
        wait_for(lambda: os.path.exists(os.path.join(lane.fake, "pids")), "the hung turn")
        stops = os.path.join(lane.fake, "gateway-stops")
        assert not os.path.exists(stops)
    finally:
        lane.stop()
    # the turn's tree was killed, and hermes's gateway (which ran its commands) stopped in the lane's profile
    profile = open(os.path.join(lane.fake, "gateway-stops")).read().strip()
    assert profile == hh.lane_home(lane.wd) or profile.startswith(os.path.join(lane.op, "profiles", "harness")), profile


def test_interrupting_a_running_turn_stops_the_lane_gateway_and_the_lane_goes_on():
    lane = Lane(["hang", "normal"])
    try:
        lane.send("go")
        wait_for(lambda: os.path.exists(os.path.join(lane.fake, "pids")), "the hung turn")
        assert subprocess.run([sys.executable, RUNNER, "interrupt", "--lane", lane.lane]).returncode == 0
        st = lane.wait_turn(1)
        assert st["state"] == "idle" and st["error"] == "interrupted", st
        wait_for(lambda: os.path.exists(os.path.join(lane.fake, "gateway-stops")), "the gateway stop")
        # the stop parked the profile and hermes refuses a turn in a parked one: the lane lifted the park
        lane.send("after"); st = lane.wait_turn(2, "idle")
        assert st["last_reply"] == "PONG", st
        assert not os.path.exists(os.path.join(hh.lane_home(lane.wd), "gateway.parked"))
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
        assert "· terminal echo hi > proof.txt" in out and "DONE" in out and "── turn 2 ended: idle" in out, out
        assert "· error: " in out and "usage limit" in out and "── turn 3 ended: limit" in out, out
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
        assert "⎿  API Error: " in p and "503" in p, p
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

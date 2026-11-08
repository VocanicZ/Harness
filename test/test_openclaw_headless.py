"""test_openclaw_headless.py — #485: the headless openclaw lane runner (scripts/cli/openclaw_headless.py), driven
against fake-openclaw replaying the real `openclaw agent exec --json` captures in
test/fixtures/cli/openclaw/agent-json/ (see ../fixtures/cli/openclaw/README.md). The fold over each capture's
envelope, the core's reading of a pretty-printed document, the command a turn runs (`agent exec --json
--message-file -`, the lane's flags), the lane keeping its own id whatever session each turn is, the transcript
the stats sweep reads, the limit and transient states, and `watch`. The lane protocol itself (inbox, interrupt,
stop, pane) is the core's, proved by test_headless_core.py and test_claude_headless.py."""
import importlib.util, json, os, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hlproc import RUNNER_PY, WINDOWS, alive, gone, kill_tree  # noqa: E402,F401
ROOT = os.path.normpath(os.path.join(HERE, ".."))
RUNNER = os.path.join(ROOT, "scripts", "cli", "openclaw_headless.py")
FIX = os.path.join(HERE, "fixtures", "cli", "openclaw", "agent-json")
FAKE = os.path.join(FIX, "fake-openclaw")
spec = importlib.util.spec_from_file_location("openclaw_headless", RUNNER)
oh = importlib.util.module_from_spec(spec); spec.loader.exec_module(oh)


def fixture(name):
    return [json.load(open(os.path.join(FIX, f"{name}.json")))]


def wait_for(pred, what, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {what}")


class Lane:
    """A runner on a fresh lane dir, its openclaw the fake replaying <plan>, flags as openclaw.sh passes them."""

    def __init__(self, plan, session_id="lane-uuid", model=None, effort=None):
        self.tmp = tempfile.mkdtemp()
        self.lane, self.fake, self.wd = (os.path.join(self.tmp, p) for p in ("lane", "fake", "wd"))
        self.state_dir = os.path.join(self.wd, ".harness-openclaw")
        for p in (self.lane, self.fake, self.wd):
            os.makedirs(p)
        with open(os.path.join(self.fake, "plan"), "w") as f:
            f.write("\n".join(plan) + "\n")
        env = dict(os.environ, FAKE_CLAUDE_DIR=self.fake, HARNESS_OPENCLAW_CONFIG=os.path.join(self.tmp, "op", "openclaw.json"))
        flags = f"--config {self.state_dir}/openclaw.json --cwd {self.wd} --state-dir {self.state_dir} --timeout 60"
        cmd = [RUNNER_PY, RUNNER, "run", "--lane", self.lane, "--cwd", self.wd,
               "--bin", f"{sys.executable} {FAKE}", "--session-id", session_id, "--flags", flags]
        if model:
            cmd += ["--model", model]
        if effort:
            cmd += ["--effort", effort]
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

    def runs(self, session_id="lane-uuid"):
        return [json.loads(l) for l in open(os.path.join(self.state_dir, "runs", f"{session_id}.jsonl"))]

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
    st, reply, err, _ = oh.classify(fixture("tool-use"), 0)
    assert (st, reply, err) == ("idle", "DONE", None), (st, reply, err)
    st, reply, err, resets = oh.classify(fixture("limit"), 1)   # `Retry-After: 7200 seconds`
    assert st == "limit" and "usage limit" in err and 7100 < resets - time.time() <= 7200, (st, err, resets)
    st, reply, err, resets = oh.classify(fixture("transient"), 1)
    assert st == "transient" and "temporarily overloaded" in err and resets is None, (st, err, resets)


def test_limit_is_read_from_the_error_text():
    base = {"ok": False, "status": "error", "final": "", "payloads": [], "sessionId": "x"}

    def kind(msg):
        return oh.classify([dict(base, error={"message": msg, "kind": "exception"})], 1)

    # OpenClaw's own copy once its 429 retries give up, its billing copy, a provider's quota or usage limit: the account's
    for m in ("⚠️ The AI service needs a short break. Please try again in a few minutes.",
              "⚠️ The AI service reported a billing problem. Please check your account.",
              "⚠️ You have reached your usage limit for this period.; Retry-After: 7200 seconds",
              "You exceeded your current quota"):
        assert kind(m)[0] == "limit", m
    # a 5xx once retries gave up, or anything else: a passing fault
    for m in ("The AI service is temporarily overloaded. Please try again in a moment.", "Selected model is at capacity",
              "connect ECONNREFUSED"):
        assert kind(m)[0] == "transient", m
    # when it lifts: Retry-After when the message names one, else unknown
    assert kind("usage limit; Retry-After: 90 seconds")[3] - time.time() <= 90
    assert kind("⚠️ The AI service needs a short break.")[3] is None


def test_exit_without_an_envelope_is_transient_and_an_ok_envelope_is_idle():
    st, reply, err, _ = oh.classify([], 143)
    assert st == "transient" and "exited 143 with no JSON envelope" in err, (st, err)
    # stray output is no envelope; the process's stderr tail is the reason
    t = oh.ADAPTER.new_turn()
    t.feed({"type": "harness", "subtype": "stdout", "line": "warning"})
    assert t.outcome(1, "\x1b[31mboom\x1b[0m")[2].endswith(": boom")
    # an ok envelope with no final text is still a finished turn, with no reply
    st, reply, err, _ = oh.classify([{"ok": True, "status": "ok", "final": "", "payloads": []}], 0)
    assert (st, reply, err) == ("idle", None, None)


# --- the core reads one pretty-printed document -------------------------------------------------
def test_document_reader_joins_lines_and_marks_stray_output():
    import headless_core as core
    text = open(os.path.join(FIX, "tool-use.json")).read()
    r = core.DocumentReader()
    got = []
    for line in text.splitlines(keepends=True):   # a line at a time, as the runner reads it
        got += r.feed(line)
    assert got == fixture("tool-use") and r.flush() == []
    # output before the document and a document cut short are `stdout` markers, as for the line reader
    r = core.DocumentReader()
    got = r.feed("note: starting\n") + r.feed('{"ok": true,\n  "final": "x"}\n')
    assert got == [{"type": "harness", "subtype": "stdout", "line": "note: starting"}, {"ok": True, "final": "x"}], got
    r = core.DocumentReader()
    assert r.feed('{"ok": tr') == [] and r.flush() == [{"type": "harness", "subtype": "stdout", "line": '{"ok": tr'}]
    # two documents in a row are two events
    assert core.DocumentReader().feed('{"a": 1}\n{"b": 2}\n') == [{"a": 1}, {"b": 2}]


# --- the command a turn runs --------------------------------------------------------------------
def test_argv_is_an_isolated_json_turn_with_the_message_on_stdin():
    a = oh.ADAPTER
    flags = ["--config", "/wd/.harness-openclaw/openclaw.json", "--cwd", "/wd", "--state-dir", "/wd/.harness-openclaw", "--timeout", "60"]
    want = ["openclaw", "agent", "exec", "--json", "--message-file", "-"]
    assert a.argv(["openclaw"], "SID", False, None, None, flags) == want + flags
    # no resume id exists: a lane's later turns, and a relaunched lane's first, run the same command; model and effort are flags
    assert a.argv(["openclaw"], "SID", True, "claude-cli/claude-haiku-5-5", "low", flags) == \
        want + ["--model", "claude-cli/claude-haiku-5-5", "--thinking", "low"] + flags
    assert a.state_dir == "/wd/.harness-openclaw" and a.lane_session == "SID"


def test_turn_includes_the_operators_config_root():
    old = {k: os.environ.pop(k, None) for k in ("HARNESS_OPENCLAW_CONFIG", "OPENCLAW_CONFIG_PATH", "OPENCLAW_STATE_DIR")}
    try:
        assert oh.ADAPTER.env("/wd") == {"OPENCLAW_INCLUDE_ROOTS": os.path.join(os.path.expanduser("~"), ".openclaw")}
        os.environ["OPENCLAW_STATE_DIR"] = "/state"
        assert oh.ADAPTER.env("/wd") == {"OPENCLAW_INCLUDE_ROOTS": "/state"}
        os.environ["OPENCLAW_CONFIG_PATH"] = "/cfg/o.json"   # openclaw.sh `_openclaw_op_config`: this wins over the state dir
        assert oh.ADAPTER.env("/wd") == {"OPENCLAW_INCLUDE_ROOTS": "/cfg"}
        os.environ["HARNESS_OPENCLAW_CONFIG"] = "/h/o.json"
        assert oh.ADAPTER.env("/wd") == {"OPENCLAW_INCLUDE_ROOTS": "/h"}
    finally:
        for k, v in old.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v


# --- through the runner -------------------------------------------------------------------------
def test_lane_keeps_its_own_id_across_turns_that_are_each_a_new_openclaw_session():
    lane = Lane(["normal", "tool-use"], session_id="lane-uuid", model="claude-cli/claude-haiku-5-5", effort="low")
    try:
        lane.send("first"); st = lane.wait_turn(1, "idle")
        assert st["session_id"] == "lane-uuid" and st["session_started"] is True and st["last_reply"] == "PONG", st
        lane.send("second"); st = lane.wait_turn(2, "idle")
        assert st["session_id"] == "lane-uuid" and st["last_reply"] == "DONE", st
        a0, a1 = (c["argv"] for c in lane.calls())
        assert a0 == a1 and a0[:5] == ["agent", "exec", "--json", "--message-file", "-"], (a0, a1)
        assert a0[a0.index("--model") + 1] == "claude-cli/claude-haiku-5-5" and a0[a0.index("--thinking") + 1] == "low", a0
        assert a0[a0.index("--state-dir") + 1] == lane.state_dir and a0[a0.index("--cwd") + 1] == lane.wd, a0
        assert [c["prompt"] for c in lane.calls()] == ["first", "second"]
        assert all(c["cwd"] == lane.wd for c in lane.calls()), "the turn runs in the worktree"
        assert lane.calls()[0]["include_roots"] == os.path.join(lane.tmp, "op"), lane.calls()[0]
        assert st["adapter"] == "openclaw" and st["account"] == "default" and st["rate_limit"] is None, st
        # each turn's envelope was recorded under the lane's id: what openclaw_transcripts / openclaw_usage fold
        runs = lane.runs()
        assert [r["final"] for r in runs] == ["PONG", "DONE"] and runs[0]["sessionId"] != runs[1]["sessionId"], runs
        assert runs[0]["usage"] == {"input": 2, "output": 5, "cacheWrite": 41805} and "ended" in runs[0]["harness"], runs[0]
    finally:
        lane.stop()


def test_a_relaunched_lane_runs_the_same_command():
    lane = Lane(["normal"], session_id="carried-on")
    try:
        lane.send("resume prompt"); st = lane.wait_turn(1, "idle")
        assert st["session_id"] == "carried-on", st
        assert "--resume" not in lane.calls()[0]["argv"] and "--session-id" not in lane.calls()[0]["argv"]
        assert os.path.exists(os.path.join(lane.state_dir, "runs", "carried-on.jsonl"))
    finally:
        lane.stop()


def test_limit_and_transient_turns_park_the_lane_and_the_next_runs():
    lane = Lane(["limit", "transient", "normal"])
    try:
        lane.send("one"); st = lane.wait_turn(1, "limit")
        assert "usage limit" in st["error"] and st["limit_resets_at"] and st["exit"] == 1, st
        lane.send("two"); st = lane.wait_turn(2, "transient")
        assert "overloaded" in st["error"] and not st.get("limit_resets_at"), st
        lane.send("three"); st = lane.wait_turn(3, "idle")
        assert st["last_reply"] == "PONG" and st["error"] is None, st
        assert st["session_id"] == "lane-uuid"
    finally:
        lane.stop()


def test_reply_replaced_by_the_plan_and_the_turn_end_markers():
    lane = Lane(["normal all done <promise>X</promise>"])
    try:
        lane.send("go"); st = lane.wait_turn(1, "idle")
        assert st["last_reply"] == "all done <promise>X</promise>", st
        ev = lane.events()
        assert [e.get("subtype") for e in ev if e.get("type") == "harness"] == ["turn_start", "turn_end"], ev
        assert any(e.get("ok") is True for e in ev), "the envelope is one event in events.jsonl"
    finally:
        lane.stop()


def test_stopping_a_running_turn_ends_it_and_its_child():
    lane = Lane(["hang"])
    try:
        lane.send("go")
        pids = wait_for(lambda: open(os.path.join(lane.fake, "pids")).read().split() if os.path.exists(os.path.join(lane.fake, "pids")) else None,
                        "the hung turn")
    finally:
        lane.stop()
    assert lane.state()["state"] == "ended"
    for p in pids:
        wait_for(lambda p=p: subprocess.run(["bash", "-c", f"! kill -0 {p} 2>/dev/null"]).returncode == 0, f"pid {p} to go")


def test_watch_prints_turns_tools_replies_and_errors():
    lane = Lane(["normal", "tool-use", "limit"])
    try:
        for n in (1, 2, 3):
            lane.send(f"msg{n}"); lane.wait_turn(n)
        out = subprocess.run([sys.executable, RUNNER, "watch", "--lane", lane.lane, "--no-follow"],
                             capture_output=True, text=True).stdout
        assert "── turn 1 (message) ── msg1" in out and "PONG" in out, out
        assert "· tools: mcp__openclaw__exec" in out and "DONE" in out and "── turn 2 ended: idle" in out, out
        assert "· error: ⚠️ You have reached your usage limit" in out and "── turn 3 ended: limit" in out, out
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
        assert "⎿  API Error: " in p and "overloaded" in p, p
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

"""test_agy_headless.py — #486: the headless agy lane runner (scripts/cli/agy_headless.py), driven against fake-agy
replaying the real `agy --input-format stream-json --output-format stream-json -p=` captures in
test/fixtures/cli/agy/stream-json/ (see ../fixtures/cli/agy/README.md). The turn fold over each capture, the command a
turn runs (no conversation on the first turn, `--conversation <id>` after, agy's own id read off its first event), the
message sent as a stream-json user line on stdin, a lane relaunched on a conversation agy lost, the limit and transient
states, and `watch`. The lane protocol itself (inbox, interrupt, stop, pane) is the core's, proved by
test_headless_core.py and test_claude_headless.py."""
import importlib.util, json, os, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hlproc import RUNNER_PY, WINDOWS, alive, gone, kill_tree  # noqa: E402,F401
ROOT = os.path.normpath(os.path.join(HERE, ".."))
RUNNER = os.path.join(ROOT, "scripts", "cli", "agy_headless.py")
FIX = os.path.join(HERE, "fixtures", "cli", "agy", "stream-json")
FAKE = os.path.join(FIX, "fake-agy")
spec = importlib.util.spec_from_file_location("agy_headless", RUNNER)
ah = importlib.util.module_from_spec(spec); spec.loader.exec_module(ah)


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
    """A runner on a fresh lane dir, its agy the fake replaying <plan>."""

    def __init__(self, plan, session_id=None, resume=False, effort=None, flags="--dangerously-skip-permissions", model=None, home=None):
        self.tmp = tempfile.mkdtemp()
        self.lane, self.fake, self.wd = (os.path.join(self.tmp, p) for p in ("lane", "fake", "wd"))
        self.home = home or os.path.join(self.tmp, "agy-home")   # agy's state dir: shared with an earlier lane to resume its conversation
        for p in (self.lane, self.fake, self.wd):
            os.makedirs(p)
        with open(os.path.join(self.fake, "plan"), "w") as f:
            f.write("\n".join(plan) + "\n")
        env = dict(os.environ, FAKE_CLAUDE_DIR=self.fake, HARNESS_AGY_HOME=self.home)
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
        return ah.read_state(self.lane)

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
    st, reply, err, _ = ah.classify(fixture("normal"), 0)
    assert (st, reply, err) == ("idle", "PONG", None), (st, reply, err)
    # a turn that called a tool: the reply is the text of its last agent_response, the tool step has none
    st, reply, err, _ = ah.classify(fixture("tool-use"), 0)
    assert (st, reply, err) == ("idle", "DONE", None), (st, reply, err)
    st, reply, err, resets = ah.classify(fixture("limit"), 3)
    assert st == "limit" and "Individual quota reached" in err, (st, err)
    want = 93 * 3600 + 37 * 60 + 49   # "Resets in 93h37m49s"
    assert abs(resets - (time.time() + want)) < 5, (resets, want)
    st, reply, err, resets = ah.classify(fixture("transient"), 3)
    assert st == "transient" and "Agent execution terminated due to error" in err and resets is None, (st, err, resets)
    # a conversation agy lost is run afresh by agy itself: a clean turn
    assert ah.classify(fixture("no-conversation"), 0)[:3] == ("idle", "PONG", None)


def test_limit_is_read_from_the_error_text():
    ev = fixture("limit")
    for text, limit in (("Individual quota reached. Resets in 4m", True), ("You have exhausted your quota on this model.", True),
                        ("Your AI credits balance is too low to continue.", True), ("Quota exhausted", True),
                        # a per-minute 429 agy's retries gave up on is not the account's quota: retryable
                        ("RESOURCE_EXHAUSTED (code 429): Too many requests, try again shortly", False)):
        ev[-1]["result"]["error"] = text
        assert (ah.classify(ev, 3)[0] == "limit") is limit, text
    ev[-1]["result"]["error"] = "Individual quota reached. Resets in 1h2m3s"
    assert abs(ah.classify(ev, 3)[3] - (time.time() + 3723)) < 5
    ev[-1]["result"]["error"] = "You have exhausted your quota on this model."
    assert ah.classify(ev, 3)[3] is None   # no word of when it lifts


def test_resets_in_parses_every_unit():
    assert ah.resets_in("Resets in 93h41m3s") == 93 * 3600 + 41 * 60 + 3
    assert ah.resets_in("Resets in 2d1h") == 2 * 86400 + 3600
    assert ah.resets_in("Resets in 45s") == 45
    assert ah.resets_in("no word of it") is None and ah.resets_in("") is None and ah.resets_in(None) is None


def test_exit_without_a_success_result_is_transient():
    st, reply, err, _ = ah.classify(fixture("normal")[:2], 143)
    assert st == "transient" and "no result record" in err, (st, err)
    st, reply, err, _ = ah.classify(fixture("normal")[:2], 1, "boom")
    assert st == "transient" and err.endswith(": boom"), (st, err)
    # a SUCCESS result with a failing exit is not a clean turn either
    assert ah.classify(fixture("normal"), 3)[0] == "transient"


def test_reply_is_the_last_step_not_the_joined_response():
    # a turn the Stop hook re-fed answers twice; `response` joins the answers (README), the reply is the last one
    ev = fixture("normal")
    ev[-1]["result"]["response"] = "PONG\nPONG\n"
    ev.insert(-1, {"event": "step_update", "step_update": {"conversation_id": "c", "step_index": 3, "state": "ACTIVE",
                                                           "step_type": "agent_response", "text_delta": "FINAL"}})
    assert ah.classify(ev, 0)[:2] == ("idle", "FINAL")
    # …and `response` stands in where no step streamed text
    ev = [e for e in fixture("normal") if e.get("event") != "step_update"]
    assert ah.classify(ev, 0)[:2] == ("idle", "PONG")


def test_conversation_id_is_read_off_the_stream():
    t = ah.Turn()
    for e in fixture("normal"):
        t.feed(e)
    assert t.session_id == "2aa65b53-c7aa-4c7f-8f48-e3ae7ff8c66c" and t.result["status"] == "SUCCESS"
    t = ah.Turn()
    t.feed({"event": "init", "conversation_id": "from-init"}); assert t.session_id == "from-init"
    t.feed({"event": "step_update", "step_update": {"conversation_id": "from-step"}}); assert t.session_id == "from-step"
    t.feed("not an event"); t.feed({"event": "step_update", "step_update": "nope"}); assert t.session_id == "from-step"


# --- the command a turn runs --------------------------------------------------------------------
def test_argv_first_turn_names_no_conversation_then_continues_it():
    a = ah.ADAPTER
    head = ["agy", "--input-format", "stream-json", "--output-format", "stream-json", "-p="]
    assert a.argv(["agy"], "lane-uuid", False, None, None, ["--dangerously-skip-permissions"]) == head + ["--dangerously-skip-permissions"]
    assert a.argv(["agy"], "conv-1", True, "claude-sonnet-4-6", "high", ["--dangerously-skip-permissions"]) == \
        head + ["--conversation", "conv-1", "--model", "claude-sonnet-4-6", "--effort", "high", "--dangerously-skip-permissions"]


def test_message_goes_on_stdin_as_one_stream_json_user_line():
    p = ah.ADAPTER.stdin_payload('line one\nline "two" — ünï')
    assert p.endswith("\n") and p.count("\n") == 1, repr(p)   # one NDJSON line, the message's own newlines escaped
    assert json.loads(p) == {"event": "user", "message": {"content": 'line one\nline "two" — ünï'}}


# --- through the runner -------------------------------------------------------------------------
def test_conversation_agy_picked_is_continued():
    lane = Lane(["normal", "tool-use"], session_id="lane-uuid-not-an-agy-id", effort="high", model="claude-sonnet-4-6")
    try:
        lane.send("first"); st = lane.wait_turn(1, "idle")
        sid = st["session_id"]
        assert sid != "lane-uuid-not-an-agy-id" and st["session_started"] is True and st["last_reply"] == "PONG", st
        lane.send("second\nwith a second line"); st = lane.wait_turn(2, "idle")
        a0, a1 = (c["argv"] for c in lane.calls())
        assert "--conversation" not in a0 and a0[a0.index("--effort") + 1] == "high" and "--model" in a0 and "-p=" in a0, a0
        assert a1[a1.index("--conversation") + 1] == sid, a1
        assert st["session_id"] == sid and st["last_reply"] == "DONE", st
        assert [c["prompt"] for c in lane.calls()] == ["first", "second\nwith a second line"]
        assert st["adapter"] == "agy" and st["account"] == "default" and st["rate_limit"] is None, st
    finally:
        lane.stop()


def test_resume_flag_continues_the_conversation_from_the_first_turn():
    seed = Lane(["normal"])   # a real conversation to resume: its database is in seed.home
    try:
        seed.send("seed"); sid = seed.wait_turn(1, "idle")["session_id"]
    finally:
        seed.stop()
    lane = Lane(["tool-use"], session_id=sid, resume=True, home=seed.home)
    try:
        assert lane.state()["session_started"] is True
        lane.send("resume prompt")
        st = lane.wait_turn(1, "idle")
        a0 = lane.calls()[0]["argv"]
        assert a0[a0.index("--conversation") + 1] == sid, a0
        assert st["session_id"] == sid and st["last_reply"] == "DONE", st
    finally:
        lane.stop()


def test_resume_of_a_conversation_agy_lost_adopts_the_new_one():
    lane = Lane(["no-conversation", "normal"], session_id="00000000-0000-4000-8000-000000000000", resume=True)
    try:
        lane.send("resume prompt")
        st = lane.wait_turn(1, "idle")
        calls = lane.calls()
        assert [c["prompt"] for c in calls] == ["resume prompt"], calls   # agy ran it in a new conversation: no second run
        a0 = calls[0]["argv"]
        assert a0[a0.index("--conversation") + 1] == "00000000-0000-4000-8000-000000000000", a0
        assert st["session_id"] != "00000000-0000-4000-8000-000000000000" and st["session_started"] is True, st
        assert st["last_reply"] == "PONG" and st["state"] == "idle", st
        assert not any(e.get("subtype") == "resume_missing" for e in lane.events())
        lane.send("later"); lane.wait_turn(2, "idle")
        a1 = lane.calls()[1]["argv"]
        assert a1[a1.index("--conversation") + 1] == st["session_id"], a1
    finally:
        lane.stop()


def test_limit_and_transient_turns_park_the_lane_and_the_next_runs():
    lane = Lane(["limit", "transient", "normal"])
    try:
        lane.send("one"); st = lane.wait_turn(1, "limit")
        assert "Individual quota reached" in st["error"] and st["limit_resets_at"] > time.time() + 90 * 3600, st
        assert st["rate_limit"]["status"] == "rejected", st
        lane.send("two"); st = lane.wait_turn(2, "transient")
        assert "Agent execution terminated" in st["error"] and not st.get("limit_resets_at"), st
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
        assert "· run_command echo hi > proof.txt" in out and "DONE" in out and "── turn 2 ended: idle" in out, out
        assert "· error: " in out and "Individual quota reached" in out and "── turn 3 ended: limit" in out, out
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
        assert "⎿  API Error: " in p and "Agent execution terminated" in p, p
    finally:
        lane.stop()


# --- the fake itself: the matrix's headless-* rows lean on what it leaves on disk -------------------
def test_fake_agy_leaves_what_agy_leaves_new_conversation_and_has_conversation():
    """fake-agy's new_conversation() records a conversation as agy does and has_conversation() finds it again: a run with
    no --conversation makes one (database, workspace map, brain transcript), a run naming it continues it, a run naming
    one it lacks is agy's `not found` warning and a new conversation. `-p /usage` prints the windows and runs no turn."""
    tmp = tempfile.mkdtemp()
    fake, home, wd = (os.path.join(tmp, p) for p in ("fake", "home", "wd"))
    for p in (fake, wd):
        os.makedirs(p)
    open(os.path.join(fake, "plan"), "w").write("normal\nnormal\nnormal\n")
    env = dict(os.environ, FAKE_CLAUDE_DIR=fake, HARNESS_AGY_HOME=home)
    line = json.dumps({"event": "user", "message": {"content": "hi"}}) + "\n"

    def run(*extra, stdin=line):
        return subprocess.run([sys.executable, FAKE, "--input-format", "stream-json", "--output-format", "stream-json", "-p=", *extra],
                              input=stdin, capture_output=True, text=True, cwd=wd, env=env)

    def cid(r):
        return json.loads(r.stdout.splitlines()[0])["conversation_id"]
    first = run(); a = cid(first)
    assert first.returncode == 0 and os.path.isdir(os.path.join(home, "brain", a)), first.stderr
    assert json.load(open(os.path.join(home, "cache", "last_conversations.json")))[os.path.realpath(wd)] == a
    assert os.path.exists(os.path.join(home, "conversations", a + ".db"))
    again = run("--conversation", a)
    assert cid(again) == a and again.stderr == "", again.stderr
    lost = run("--conversation", "00000000-0000-4000-8000-000000000000")
    assert cid(lost) not in ("00000000-0000-4000-8000-000000000000", a) and "not found" in lost.stderr, lost.stderr
    bad = run(stdin="just text\n")   # a prompt that is not a stream-json user line is agy's own refusal
    assert bad.returncode == 3 and "failed to decode stream input" in bad.stderr, bad.stderr
    usage = subprocess.run([sys.executable, FAKE, "-p", "/usage", "--output-format", "json"], capture_output=True, text=True, env=env)
    assert usage.returncode == 0 and json.loads(usage.stdout)["command"]["data"]["groups"], usage.stdout


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

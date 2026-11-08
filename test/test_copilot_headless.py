"""test_copilot_headless.py — #483 (PRD #475): the headless copilot lane runner (scripts/cli/copilot_headless.py,
the copilot adapter on the shared core), driven against fake-copilot replaying the captures in
test/fixtures/cli/copilot/stream-json/ (see its README.md). The seven behaviours docs/reference.md's
"Headless adapter contract" asks of an adapter's own test, against copilot's output: a turn's start (the
message on stdin, `--session-id=<id>`), the resume id carried across turns and relaunches, the event parse
(`result`, the last `assistant.message`), usage (the session-state file a turn leaves, which the stats sweep
reads, and a quota reading in the stream), a limit → `limit`, a transient error → `transient`, and interrupt
and stop leaving no child process behind."""
import importlib.util, json, os, signal, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hlproc import RUNNER_PY, WINDOWS, alive, gone, kill_tree  # noqa: E402,F401
ROOT = os.path.normpath(os.path.join(HERE, ".."))
RUNNER = os.path.join(ROOT, "scripts", "cli", "copilot_headless.py")
FIX = os.path.join(HERE, "fixtures", "cli", "copilot", "stream-json")
FAKE = os.path.join(FIX, "fake-copilot")
spec = importlib.util.spec_from_file_location("copilot_headless", RUNNER)
ch = importlib.util.module_from_spec(spec); spec.loader.exec_module(ch)


def fixture(name):
    return [json.loads(l) for l in open(os.path.join(FIX, f"{name}.jsonl")) if l.strip()]


def wait_for(pred, what, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {what}")


def sid_arg(argv):
    return [a.split("=", 1)[1] for a in argv if a.startswith("--session-id=")]


class Lane:
    """A runner on a fresh lane dir, its copilot the fake replaying <plan>, its COPILOT_HOME a temp dir."""

    def __init__(self, plan, session_id=None, hold=False, resume=False, flags="--yolo --no-ask-user --no-auto-update",
                 extra=()):
        self.tmp = tempfile.mkdtemp()
        self.lane, self.fake, self.wd, self.home = (os.path.join(self.tmp, p) for p in ("lane", "fake", "wd", "home"))
        for p in (self.lane, self.fake, self.wd, self.home):
            os.makedirs(p)
        with open(os.path.join(self.fake, "plan"), "w") as f:
            f.write("\n".join(plan) + "\n")
        if hold:
            self.hold()
        self.env = dict(os.environ, FAKE_CLAUDE_DIR=self.fake, COPILOT_HOME=self.home)
        cmd = [RUNNER_PY, RUNNER, "run", "--lane", self.lane, "--cwd", self.wd,
               "--bin", f"{sys.executable} {FAKE}", f"--flags={flags}", *extra]
        if session_id:
            cmd += ["--session-id", session_id]
        if resume:
            cmd += ["--resume"]
        self.proc = subprocess.Popen(cmd, env=self.env)
        wait_for(lambda: self.state().get("runner_pid") == self.proc.pid or self.proc.poll() is not None,
                 "the runner's first state")
        assert self.proc.poll() is None, f"the runner exited {self.proc.returncode} at start"

    def hold(self):
        open(os.path.join(self.fake, "hold"), "w").close()

    def release(self):
        os.remove(os.path.join(self.fake, "hold"))

    def send(self, text, kind="message"):
        r = subprocess.run([sys.executable, RUNNER, "send", "--lane", self.lane, "--kind", kind, text])
        assert r.returncode == 0

    def state(self):
        return ch.read_state(self.lane)

    def calls(self):
        try:
            return [json.loads(l) for l in open(os.path.join(self.fake, "calls.jsonl"))]
        except OSError:
            return []

    def events(self):
        return [json.loads(l) for l in open(os.path.join(self.lane, "events.jsonl"))]

    def disk(self, sid):
        with open(os.path.join(self.home, "session-state", sid, "events.jsonl")) as f:
            return [json.loads(l) for l in f]

    def wait_turn(self, n, state=None):
        st = wait_for(lambda: (lambda s: s if s.get("turn") == n and s.get("state") != "busy" else None)(self.state()),
                      f"turn {n} to end")
        if state:
            assert st["state"] == state, f"turn {n}: state {st['state']!r}, want {state!r} ({st})"
        return st

    def stop(self):
        r = subprocess.run([sys.executable, RUNNER, "stop", "--lane", self.lane, "--timeout", "15"])
        self.proc.wait(timeout=15)
        return r.returncode


# --- the argv of one turn -------------------------------------------------------------------------
def test_argv_names_the_session_every_turn_and_the_message_stays_off_it():
    a = ch.ADAPTER
    first = a.argv(["copilot"], "S1", False, None, None, ["--yolo"])
    later = a.argv(["copilot"], "S1", True, None, None, ["--yolo"])
    assert first == ["copilot", "--output-format", "json", "--session-id=S1", "--yolo"], first
    assert later == first, "copilot resumes an existing --session-id: the same flag on every turn"
    assert "-p" not in first and "--resume" not in later, "the message goes on stdin"
    assert a.argv(["copilot"], None, False, None, None, []) == ["copilot", "--output-format", "json"]


def test_argv_model_and_effort():
    a = ch.ADAPTER
    assert a.argv(["c"], "S", False, "gpt-6-luna", "high", []) == \
        ["c", "--output-format", "json", "--session-id=S", "--model=gpt-6-luna", "--effort=high"]
    # Auto refuses a reasoning effort in this mode ("Model "auto" does not support reasoning effort")
    assert not any(x.startswith("--effort") for x in a.argv(["c"], "S", False, None, "high", []))
    assert not any(x.startswith("--effort") for x in a.argv(["c"], "S", False, "auto", "high", []))
    assert "--model=auto" in a.argv(["c"], "S", False, "auto", None, [])


# --- the fold over each capture -------------------------------------------------------------------
def test_classify_each_capture():
    st, reply, err, _ = ch.classify(fixture("normal"), 0)
    assert (st, reply, err) == ("idle", "PONG", None), (st, reply, err)
    st, reply, err, _ = ch.classify(fixture("tool-use"), 0)
    assert (st, reply, err) == ("idle", "DONE", None), (st, reply, err)
    st, reply, err, resets = ch.classify(fixture("limit"), 1)
    assert st == "limit" and "rate limit" in err and resets is None, (st, err, resets)
    st, reply, err, resets = ch.classify(fixture("transient"), 1)
    assert st == "transient" and "503" in err and resets is None, (st, err)


def test_session_id_is_read_off_the_result_record():
    t = ch.ADAPTER.new_turn()
    for e in fixture("normal"):
        t.feed(e)
    assert t.session_id == "76c3c769-eeb0-432a-be3b-84d73234e933"


def test_a_turn_with_no_result_is_transient_and_says_why():
    st, _, err, _ = ch.classify(fixture("normal")[:3], 143)
    assert st == "transient" and "no result record" in err, (st, err)
    # what the real CLI printed for a model it does not have (rc 1, nothing on stdout but the start-up events)
    st, _, err, _ = ch.classify([], 1, 'Error: Model "bogus-model" from --model flag is not available.')
    assert st == "transient" and "bogus-model" in err, (st, err)
    # …and for a session it cannot find
    st, _, err, _ = ch.classify([], 1, "Error: No session, task, or name matched '0000'.")
    assert st == "transient" and "No session" in err, (st, err)


def test_limit_is_read_from_the_error_text_of_a_failed_turn_only():
    for msg in ("You've hit your rate limit. Please wait for your limit to reset.",
                "You've hit the rate limit for this model.", "You've hit your session rate limit.",
                "You've reached your weekly rate limit.", "You've run out of your included AI credits for the month.",
                "You've reached the spending limit for this session.", "You've reached your additional usage limit."):
        ev = [e for e in fixture("limit")]
        for e in ev:
            if e["type"] == "session.error":
                e["data"]["message"] = msg
        assert ch.classify(ev, 1)[0] == "limit", msg
    # the same words in a turn that ended well (a reply about rate limits) are no limit
    ev = fixture("normal")
    for e in ev:
        if e["type"] == "assistant.message":
            e["data"]["content"] = "You've hit your rate limit, said the docs."
    assert ch.classify(ev, 0)[0] == "idle"
    # a limit with no result record: copilot printed it on stderr and exited
    assert ch.classify([], 1, "Error: You've reached your weekly rate limit.")[0] == "limit"


def test_a_session_error_alone_does_not_fail_a_turn_that_ended_well():
    ev = fixture("normal")
    ev.insert(3, {"type": "session.error", "data": {"errorType": "session", "message": "MCP server failed to start"}})
    assert ch.classify(ev, 0)[:3] == ("idle", "PONG", None)


def test_reply_is_the_last_non_empty_message_of_the_sessions_own_agent():
    t = ch.ADAPTER.new_turn()
    for e in fixture("tool-use"):
        t.feed(e)
    assert t.reply == "DONE"   # the first assistant.message, the tool request, has no content
    t.feed({"type": "assistant.message", "agentId": "sub-1", "data": {"content": "sub-agent talk"}})
    assert t.reply == "DONE"


def test_quota_snapshot_in_the_stream_is_kept_as_the_rate_limit():
    t = ch.ADAPTER.new_turn()
    t.feed({"type": "model.model_call_success", "data": {"quotaSnapshots": {"chat": {"remainingPercentage": 90.0}}}})
    assert t.rate_limit == {"quotaSnapshots": {"chat": {"remainingPercentage": 90.0}}}
    t.feed(fixture("normal")[1])
    assert t.rate_limit["quotaSnapshots"]["chat"]["remainingPercentage"] == 90.0


def test_watch_lines():
    wl = ch.watch_line
    assert wl({"type": "harness", "subtype": "turn_start", "turn": 2, "kind": "nudge", "message": "go"}) == "── turn 2 (nudge) ── go"
    assert wl({"type": "harness", "subtype": "turn_end", "turn": 2, "state": "idle"}) == "── turn 2 ended: idle"
    ev = fixture("tool-use")
    lines = [l for l in (wl(e) for e in ev) if l]
    assert "· bash echo hi > proof.txt" in lines and "DONE" in lines, lines
    assert wl({"type": "session.error", "data": {"message": "boom"}}) == "· error: boom"
    assert wl({"type": "session.usage_checkpoint", "data": {}}) is None
    assert wl({"type": "assistant.message", "data": {"content": "", "toolRequests": [{}]}}) is None


# --- the runner against the fake ------------------------------------------------------------------
def test_inbox_order_session_carried_last_reply_and_what_the_cli_leaves_on_disk():
    sid = "11111111-2222-3333-4444-555555555555"
    lane = Lane(["normal", "tool-use", "normal"], session_id=sid)
    try:
        assert lane.state()["state"] == "idle" and lane.state()["adapter"] == "copilot"
        for m in ("first message", "second message", "third message"):
            lane.send(m)
        st = lane.wait_turn(3, "idle")
        calls = lane.calls()
        assert [c["prompt"] for c in calls] == ["first message", "second message", "third message"], calls
        assert all(sid_arg(c["argv"]) == [sid] for c in calls), [c["argv"] for c in calls]
        assert all(c["argv"][:2] == ["--output-format", "json"] for c in calls)
        assert all("--yolo" in c["argv"] for c in calls)
        assert st["session_id"] == sid and st["last_reply"] == "PONG" and st["error"] is None, st
        r = subprocess.run([sys.executable, RUNNER, "state", "--lane", lane.lane, "--field", "last_reply"],
                           capture_output=True, text=True)
        assert r.stdout.strip() == "PONG", r.stdout
        ev = lane.events()
        kinds = [(e.get("subtype"), e.get("turn")) for e in ev if e.get("type") == "harness"]
        assert kinds == [("turn_start", 1), ("turn_end", 1), ("turn_start", 2), ("turn_end", 2),
                         ("turn_start", 3), ("turn_end", 3)], kinds
        cp = [e for e in ev if e.get("type") != "harness"]
        assert len(cp) == 2 * len(fixture("normal")) + len(fixture("tool-use"))
        assert any(e["type"] == "tool.execution_start" for e in cp), "tool use replayed"
        # the session-state file copilot leaves, where the stats sweep reads the lane's usage from
        disk = lane.disk(sid)
        assert [e["data"]["content"] for e in disk if e["type"] == "user.message"] == \
            ["first message", "second message", "third message"]
        assert sum(1 for e in disk if e["type"] == "session.usage_record") == 1 + 2 + 1
    finally:
        assert lane.stop() == 0


def test_session_id_copilot_reports_is_kept():
    lane = Lane(["normal"])
    try:
        lane.send("a")
        st = lane.wait_turn(1, "idle")
        assert sid_arg(lane.calls()[0]["argv"]) == [], "no id was given: copilot picks its own"
        assert st["session_id"] == "76c3c769-eeb0-432a-be3b-84d73234e933" and st["session_started"] is True, st
        lane.send("b")
        lane.wait_turn(2, "idle")
        assert sid_arg(lane.calls()[1]["argv"]) == [st["session_id"]], "…and the next turn names it"
    finally:
        lane.stop()


def test_mid_turn_message_waits_for_next_turn():
    lane = Lane(["normal", "normal"], hold=True)
    try:
        lane.send("bootstrap", kind="bootstrap")
        st = wait_for(lambda: (lambda s: s if s.get("state") == "busy" else None)(lane.state()), "busy")
        assert st["turn"] == 1 and isinstance(st["turn_started"], float) and st["claude_pid"], st
        lane.send("nudge", kind="nudge")
        wait_for(lambda: lane.state().get("queued") == 1, "the nudge queued")
        time.sleep(0.3)
        assert len(lane.calls()) == 1 and lane.state()["state"] == "busy", "no second turn while one runs"
        assert "esc to interrupt" in ch.pane(lane.lane) and "❯ nudge" in ch.pane(lane.lane)
        lane.release()
        st = lane.wait_turn(2, "idle")
        assert [c["prompt"] for c in lane.calls()] == ["bootstrap", "nudge"]
        assert st["queued"] == 0 and st["turn_started"] is None
    finally:
        lane.stop()


def test_state_transitions_idle_busy_limit_transient_idle():
    lane = Lane(["normal", "limit", "transient", "normal"])
    try:
        assert lane.state()["state"] == "idle"
        lane.hold(); lane.send("one")
        wait_for(lambda: lane.state().get("state") == "busy", "busy")
        lane.release()
        lane.wait_turn(1, "idle")
        lane.send("two")
        st = lane.wait_turn(2, "limit")
        assert "rate limit" in st["error"] and st["exit"] == 1 and st["limit_resets_at"] is None, st
        assert st["rate_limit"]["status"] == "rejected", st
        assert "You've hit your usage limit" in ch.pane(lane.lane), "drawn the way the watchdog reads a limit"
        lane.send("three")
        st = lane.wait_turn(3, "transient")
        assert "503" in st["error"] and st["limit_resets_at"] is None, st
        assert "API Error" in ch.pane(lane.lane)
        lane.send("four")
        st = lane.wait_turn(4, "idle")
        assert st["error"] is None and st["last_reply"] == "PONG", st
    finally:
        lane.stop()


def _hang_then(stop):
    lane = Lane(["hang"])
    cop = grandchild = None
    try:
        lane.send("long turn")
        pids = wait_for(lambda: open(os.path.join(lane.fake, "pids")).read().split()
                        if os.path.exists(os.path.join(lane.fake, "pids")) else None, "the hung turn's pids")
        cop, grandchild = map(int, pids)
        assert lane.state()["state"] == "busy" and lane.state()["claude_pid"] == cop
        stop(lane)
        assert lane.proc.returncode == 0, lane.proc.returncode
        wait_for(lambda: gone(cop) and gone(grandchild), "the turn's whole tree to end", timeout=10)
        st = lane.state()
        assert st["state"] == "ended" and st["claude_pid"] is None, st
        ends = [e for e in lane.events() if e.get("subtype") == "turn_end"]
        assert ends and ends[-1].get("stopped") is True, ends
    finally:   # a failed run must not leak its fake turn either: kill only the pids it started
        if lane.proc.poll() is None:
            lane.proc.kill()
        for p in (cop, grandchild):
            if p and not gone(p):
                kill_tree(p)


def test_stop_request_leaves_no_child_behind():
    def request(lane):
        assert lane.stop() == 0, "harness stop: the runner did not report ended"
    _hang_then(request)


def test_sigterm_leaves_no_child_behind():
    def term(lane):
        if WINDOWS:   # no signal reaches a Windows process from outside (it would be TerminateProcess): its termination request is the stop file
            assert lane.stop() == 0, "the runner did not report ended"
        else:
            lane.proc.send_signal(signal.SIGTERM); lane.proc.wait(timeout=15)
    _hang_then(term)


def test_interrupt_ends_the_turn_not_the_runner():
    lane = Lane(["hang", "normal"])
    cop = grandchild = None
    try:
        lane.send("long turn")
        pids = wait_for(lambda: open(os.path.join(lane.fake, "pids")).read().split()
                        if os.path.exists(os.path.join(lane.fake, "pids")) else None, "the hung turn's pids")
        cop, grandchild = map(int, pids)
        lane.hold(); lane.send("next")
        assert subprocess.run([sys.executable, RUNNER, "interrupt", "--lane", lane.lane]).returncode == 0
        wait_for(lambda: gone(cop) and gone(grandchild), "the interrupted turn's tree to end", timeout=10)
        st = wait_for(lambda: (lambda s: s if s.get("turn") == 2 else None)(lane.state()), "the queued turn")
        assert lane.proc.poll() is None, "the runner must stay up"
        assert st["interrupted"] == 1 and ch.pane(lane.lane).count("Interrupted") == 1, st
        lane.release()
        st = lane.wait_turn(2, "idle")
        assert st["interrupted"] == 0 and st["last_reply"] == "PONG", st
    finally:
        lane.stop()
        for p in (cop, grandchild):
            if p and not gone(p):
                kill_tree(p)


def test_restart_and_resume_carry_the_same_session():
    sid = "aaaaaaaa-0000-0000-0000-000000000000"
    lane = Lane(["normal", "normal", "normal"], session_id=sid)
    lane.send("before restart"); lane.wait_turn(1, "idle"); lane.stop()
    # a relaunch: a new runner on the same session id, told it exists (--resume, #350)
    p = subprocess.Popen([RUNNER_PY, RUNNER, "run", "--lane", lane.lane, "--cwd", lane.wd, "--session-id", sid,
                          "--resume", "--bin", f"{sys.executable} {FAKE}"], env=lane.env)
    try:
        wait_for(lambda: ch.read_state(lane.lane).get("runner_pid") == p.pid, "the restarted runner")
        lane.send("after restart"); lane.wait_turn(2, "idle")
        calls = lane.calls()
        assert [c["prompt"] for c in calls] == ["before restart", "after restart"], calls
        assert sid_arg(calls[0]["argv"]) == sid_arg(calls[1]["argv"]) == [sid]
        assert [e["data"]["content"] for e in lane.disk(sid) if e["type"] == "user.message"] == \
            ["before restart", "after restart"], "one session file across the relaunch"
    finally:
        subprocess.run([sys.executable, RUNNER, "stop", "--lane", lane.lane]); p.wait(timeout=15)


def test_first_turn_of_a_resumed_lane_names_the_existing_session():
    sid = "bbbbbbbb-0000-0000-0000-000000000000"
    lane = Lane(["normal", "normal"], session_id=sid, resume=True)
    try:
        assert lane.state()["session_started"] is True, lane.state()
        lane.send("resume prompt")
        st = lane.wait_turn(1, "idle")
        assert sid_arg(lane.calls()[0]["argv"]) == [sid] and st["session_id"] == sid and st["last_reply"] == "PONG", st
    finally:
        lane.stop()


def test_model_and_effort_reach_the_command_line():
    lane = Lane(["normal"], session_id="dddddddd-0000-0000-0000-000000000000",
                extra=["--model", "gpt-6-luna", "--effort", "low"])
    try:
        lane.send("go"); lane.wait_turn(1, "idle")
        argv = lane.calls()[0]["argv"]
        assert "--model=gpt-6-luna" in argv and "--effort=low" in argv, argv
    finally:
        lane.stop()


def test_missing_copilot_fails_the_turn_not_the_runner():
    tmp = tempfile.mkdtemp(); lane = os.path.join(tmp, "lane")
    p = subprocess.Popen([RUNNER_PY, RUNNER, "run", "--lane", lane, "--cwd", tmp,
                          "--bin", os.path.join(tmp, "no-such-copilot"), "--message", "hello"])
    try:
        st = wait_for(lambda: (lambda s: s if s.get("turn") == 1 and s.get("state") == "transient" else None)(
            ch.read_state(lane)), "the failed turn")
        assert "cannot start copilot" in st["error"] and p.poll() is None, st
    finally:
        subprocess.run([sys.executable, RUNNER, "stop", "--lane", lane]); p.wait(timeout=15)


def test_entry_point_prog_and_adapter_listing():
    r = subprocess.run([sys.executable, RUNNER, "--help"], capture_output=True, text=True)
    assert r.returncode == 0 and "copilot_headless.py" in r.stdout, r
    r = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "cli", "headless_core.py"), "watch", "--help"],
                       capture_output=True, text=True)
    assert r.returncode == 0
    assert ch.core.load_adapter("copilot").name == "copilot", "headless_core finds the adapter by the name state.json holds"


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn(); print("ok  ", name)
            except Exception as e:   # noqa: BLE001
                fails += 1; print("FAIL", name, "-", repr(e))
    sys.exit(1 if fails else 0)

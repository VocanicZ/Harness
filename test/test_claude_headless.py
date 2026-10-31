"""test_claude_headless.py — #347: the headless claude lane runner (scripts/cli/claude_headless.py),
driven against fake-claude replaying the real stream-json captures in test/fixtures/cli/claude/stream-json/
(see its README.md). Inbox order, a mid-turn message queued to the next turn, state transitions
idle → busy → idle / limit / transient, the session id carried across turns, the last reply readable
from state.json, and a stop (the `stop` request or a SIGTERM) leaving no child process behind."""
import importlib.util, json, os, signal, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
RUNNER = os.path.join(ROOT, "scripts", "cli", "claude_headless.py")
FIX = os.path.join(HERE, "fixtures", "cli", "claude", "stream-json")
FAKE = os.path.join(FIX, "fake-claude")
spec = importlib.util.spec_from_file_location("claude_headless", RUNNER)
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


class Lane:
    """A runner on a fresh lane dir, its claude the fake replaying <plan>."""

    def __init__(self, plan, session_id=None, hold=False):
        self.tmp = tempfile.mkdtemp()
        self.lane, self.fake, self.wd = (os.path.join(self.tmp, p) for p in ("lane", "fake", "wd"))
        for p in (self.lane, self.fake, self.wd):
            os.makedirs(p)
        with open(os.path.join(self.fake, "plan"), "w") as f:
            f.write("\n".join(plan) + "\n")
        if hold:
            self.hold()
        env = dict(os.environ, FAKE_CLAUDE_DIR=self.fake)
        cmd = [sys.executable, RUNNER, "run", "--lane", self.lane, "--cwd", self.wd,
               "--bin", f"{sys.executable} {FAKE}", "--flags=--dangerously-skip-permissions"]
        if session_id:
            cmd += ["--session-id", session_id]
        self.proc = subprocess.Popen(cmd, env=env)
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


def gone(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return True
    try:   # reaped-later zombies count as gone
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[-1].split()[0] == "Z"
    except OSError:
        return True


# --- the fold over each real capture ------------------------------------------------------------
def test_classify_each_capture():
    st, reply, err, _ = ch.classify(fixture("normal"), 0)
    assert (st, reply, err) == ("idle", "PONG", None), (st, reply, err)
    st, reply, err, _ = ch.classify(fixture("tool-use"), 0)
    assert (st, reply, err) == ("idle", "DONE", None), (st, reply, err)
    st, reply, err, resets = ch.classify(fixture("limit"), 1)
    assert st == "limit" and "limit" in err and resets == 1793448695, (st, err, resets)
    st, reply, err, resets = ch.classify(fixture("transient"), 1)
    assert st == "transient" and "529" in err and resets is None, (st, err)
    st, reply, err, _ = ch.classify(fixture("transient")[:5], 143)
    assert st == "transient" and "no result event" in err, (st, err)


def test_limit_is_read_from_events_not_text():
    # the rejected rate_limit_event alone makes an error result a limit, whatever its text says
    ev = [e for e in fixture("limit")]
    for e in ev:
        if e.get("type") == "result":
            e.pop("api_error", None); e["result"] = "something else"
    assert ch.classify(ev, 1)[0] == "limit"
    # a plain 429 with no rejected window is transient (claude's own API rate limit, retryable)
    ev = [e for e in fixture("limit") if e.get("type") != "rate_limit_event"]
    for e in ev:
        if e.get("type") == "result":
            e.pop("api_error", None)
    assert ch.classify(ev, 1)[0] == "transient"


def test_inbox_keeps_partial_lines_and_raw_text():
    lane = tempfile.mkdtemp()
    ch.send(lane, "one\ntwo lines", kind="bootstrap")
    with open(os.path.join(lane, "inbox.jsonl"), "ab") as f:
        f.write(b"plain text\n{\"text\": \"half")
    msgs, off = ch.read_inbox(lane, 0)
    assert [m["text"] for m in msgs] == ["one\ntwo lines", "plain text"], msgs
    assert msgs[0]["kind"] == "bootstrap"
    with open(os.path.join(lane, "inbox.jsonl"), "ab") as f:
        f.write(b"\"}\n")
    msgs, off2 = ch.read_inbox(lane, off)
    assert [m["text"] for m in msgs] == ["half"] and off2 == os.path.getsize(os.path.join(lane, "inbox.jsonl"))


# --- the runner against the fake ----------------------------------------------------------------
def test_inbox_order_session_carried_last_reply():
    sid = "11111111-2222-3333-4444-555555555555"
    lane = Lane(["normal", "tool-use", "normal"], session_id=sid)
    try:
        assert lane.state()["state"] == "idle"
        for m in ("first message", "second message", "third message"):
            lane.send(m)
        st = lane.wait_turn(3, "idle")
        calls = lane.calls()
        assert [c["prompt"] for c in calls] == ["first message", "second message", "third message"], calls
        a0, a1, a2 = (c["argv"] for c in calls)
        assert a0[a0.index("--session-id") + 1] == sid and "--resume" not in a0, a0
        assert a1[a1.index("--resume") + 1] == sid and a2[a2.index("--resume") + 1] == sid, (a1, a2)
        assert all(a[:4] == ["-p", "--output-format", "stream-json", "--verbose"] for a in (a0, a1, a2))
        assert "--dangerously-skip-permissions" in a0
        assert st["session_id"] == sid and st["last_reply"] == "PONG" and st["error"] is None, st
        r = subprocess.run([sys.executable, RUNNER, "state", "--lane", lane.lane, "--field", "last_reply"],
                           capture_output=True, text=True)
        assert r.stdout.strip() == "PONG", r.stdout
        # events.jsonl: every replayed event, in order, between each turn's markers
        ev = lane.events()
        kinds = [(e.get("subtype"), e.get("turn")) for e in ev if e.get("type") == "harness"]
        assert kinds == [("turn_start", 1), ("turn_end", 1), ("turn_start", 2), ("turn_end", 2),
                         ("turn_start", 3), ("turn_end", 3)], kinds
        claude_ev = [e for e in ev if e.get("type") != "harness"]
        assert len(claude_ev) == 2 * len(fixture("normal")) + len(fixture("tool-use"))
        assert any(e.get("type") == "user" and "tool_use_result" in e for e in claude_ev), "tool use replayed"
    finally:
        assert lane.stop() == 0


def test_session_id_claude_picked_is_resumed():
    lane = Lane(["normal", "normal"])
    try:
        lane.send("a"); lane.send("b")
        st = lane.wait_turn(2, "idle")
        picked = fixture("normal")[0]["session_id"]
        a0, a1 = (c["argv"] for c in lane.calls())
        assert "--session-id" not in a0 and "--resume" not in a0, a0
        assert a1[a1.index("--resume") + 1] == picked and st["session_id"] == picked, (a1, st)
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
        lane.release()
        st = lane.wait_turn(2, "idle")
        assert [c["prompt"] for c in lane.calls()] == ["bootstrap", "nudge"]
        assert st["queued"] == 0 and st["turn_started"] is None
        marks = [e for e in lane.events() if e.get("type") == "harness"]
        assert [m.get("kind") for m in marks if m["subtype"] == "turn_start"] == ["bootstrap", "nudge"]
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
        assert st["limit_resets_at"] == 1793448695 and "5-hour limit" in st["error"] and st["exit"] == 1, st
        assert st["rate_limit"]["status"] == "rejected", st
        lane.send("three")
        st = lane.wait_turn(3, "transient")
        assert "529" in st["error"] and st["limit_resets_at"] is None, st
        lane.send("four")
        st = lane.wait_turn(4, "idle")
        assert st["error"] is None and st["last_reply"] == "PONG", st
    finally:
        lane.stop()


def _hang_then(stop):
    lane = Lane(["hang"])
    claude = grandchild = None
    try:
        lane.send("long turn")
        pids = wait_for(lambda: open(os.path.join(lane.fake, "pids")).read().split()
                        if os.path.exists(os.path.join(lane.fake, "pids")) else None, "the hung turn's pids")
        claude, grandchild = map(int, pids)
        assert lane.state()["state"] == "busy" and lane.state()["claude_pid"] == claude
        stop(lane)
        assert lane.proc.returncode == 0, lane.proc.returncode
        wait_for(lambda: gone(claude) and gone(grandchild), "the turn's whole tree to end", timeout=10)
        st = lane.state()
        assert st["state"] == "ended" and st["claude_pid"] is None, st
        ends = [e for e in lane.events() if e.get("subtype") == "turn_end"]
        assert ends and ends[-1].get("stopped") is True, ends
    finally:   # a failed run must not leak its fake turn either: kill only the pids it started
        if lane.proc.poll() is None:
            lane.proc.kill()
        for p in (claude, grandchild):
            if p and not gone(p):
                os.kill(p, signal.SIGKILL)


def test_stop_request_leaves_no_child_behind():
    def request(lane):
        assert lane.stop() == 0, "harness stop: the runner did not report ended"
    _hang_then(request)


def test_sigterm_leaves_no_child_behind():
    def term(lane):
        lane.proc.send_signal(signal.SIGTERM); lane.proc.wait(timeout=15)
    _hang_then(term)


def test_restart_resumes_session_and_inbox_position():
    lane = Lane(["normal", "normal"], session_id="aaaaaaaa-0000-0000-0000-000000000000")
    lane.send("before restart"); lane.wait_turn(1, "idle"); lane.stop()
    env = dict(os.environ, FAKE_CLAUDE_DIR=lane.fake)
    p = subprocess.Popen([sys.executable, RUNNER, "run", "--lane", lane.lane, "--cwd", lane.wd,
                          "--bin", f"{sys.executable} {FAKE}"], env=env)
    try:
        wait_for(lambda: ch.read_state(lane.lane).get("runner_pid") == p.pid, "the restarted runner")
        lane.send("after restart"); lane.wait_turn(2, "idle")
        calls = lane.calls()
        assert [c["prompt"] for c in calls] == ["before restart", "after restart"], calls
        assert calls[1]["argv"][calls[1]["argv"].index("--resume") + 1] == "aaaaaaaa-0000-0000-0000-000000000000"
    finally:
        subprocess.run([sys.executable, RUNNER, "stop", "--lane", lane.lane]); p.wait(timeout=15)


def test_killed_runner_redelivers_queued_not_delivered():
    # SIGKILL mid-turn with a message queued: the restart delivers the queued one, not the first again
    lane = Lane(["normal", "normal"], hold=True)
    lane.send("delivered"); wait_for(lambda: lane.state().get("state") == "busy", "busy")
    lane.send("queued"); wait_for(lambda: lane.state().get("queued") == 1, "queued")
    lane.proc.kill(); lane.proc.wait()
    os.kill(lane.calls()[0]["pid"], signal.SIGKILL)   # the fake turn the killed runner left
    lane.release()
    env = dict(os.environ, FAKE_CLAUDE_DIR=lane.fake)
    p = subprocess.Popen([sys.executable, RUNNER, "run", "--lane", lane.lane, "--cwd", lane.wd,
                          "--bin", f"{sys.executable} {FAKE}"], env=env)
    try:
        lane.wait_turn(2, "idle")
        assert [c["prompt"] for c in lane.calls()] == ["delivered", "queued"], lane.calls()
    finally:
        subprocess.run([sys.executable, RUNNER, "stop", "--lane", lane.lane]); p.wait(timeout=15)


def test_missing_claude_fails_the_turn_not_the_runner():
    tmp = tempfile.mkdtemp(); lane = os.path.join(tmp, "lane")
    p = subprocess.Popen([sys.executable, RUNNER, "run", "--lane", lane, "--cwd", tmp,
                          "--bin", os.path.join(tmp, "no-such-claude"), "--message", "hello"])
    try:
        st = wait_for(lambda: (lambda s: s if s.get("turn") == 1 and s.get("state") == "transient" else None)(
            ch.read_state(lane)), "the failed turn")
        assert "cannot start claude" in st["error"] and p.poll() is None, st
    finally:
        subprocess.run([sys.executable, RUNNER, "stop", "--lane", lane]); p.wait(timeout=15)


# --- #349: what the headless session backend reads and asks of a lane ----------------------------
def test_interrupt_ends_the_turn_not_the_runner():
    lane = Lane(["hang", "normal"])
    claude = grandchild = None
    try:
        lane.send("long turn")
        pids = wait_for(lambda: open(os.path.join(lane.fake, "pids")).read().split()
                        if os.path.exists(os.path.join(lane.fake, "pids")) else None, "the hung turn's pids")
        claude, grandchild = map(int, pids)
        lane.hold(); lane.send("next")
        assert subprocess.run([sys.executable, RUNNER, "interrupt", "--lane", lane.lane]).returncode == 0
        wait_for(lambda: gone(claude) and gone(grandchild), "the interrupted turn's tree to end", timeout=10)
        st = wait_for(lambda: (lambda s: s if s.get("turn") == 2 else None)(lane.state()), "the queued turn")
        assert lane.proc.poll() is None, "the runner must stay up"
        assert st["interrupted"] == 1, st
        assert ch.pane(lane.lane).count("Interrupted") == 1, "the next turn's screen still shows the interrupt"
        ends = [e for e in lane.events() if e.get("subtype") == "turn_end"]
        assert ends[0].get("interrupted") is True and ends[0]["state"] == "idle", ends
        lane.release()
        st = lane.wait_turn(2, "idle")
        assert st["interrupted"] == 0 and st["last_reply"] == "PONG", st
        assert "Interrupted" not in ch.pane(lane.lane), "a turn that ends on its own clears it"
    finally:
        lane.stop()
        for p in (claude, grandchild):
            if p and not gone(p):
                os.kill(p, signal.SIGKILL)


def test_stale_interrupt_does_not_end_the_next_turn():
    lane = Lane(["normal"])
    try:
        open(os.path.join(lane.lane, "interrupt"), "w").close()   # aimed at a turn that is over
        time.sleep(0.5)
        lane.send("hello")
        st = lane.wait_turn(1, "idle")
        assert not st["interrupted"] and st["last_reply"] == "PONG", st
    finally:
        lane.stop()


def test_interrupt_aimed_at_an_ended_turn_spares_the_next():
    lane = Lane(["normal", "normal"], hold=True)
    try:
        lane.send("one"); wait_for(lambda: lane.state().get("state") == "busy", "busy")
        with open(os.path.join(lane.lane, "interrupt"), "w") as f:
            f.write("7")   # written for a turn that ended before the request landed
        time.sleep(0.5)
        lane.release()
        st = lane.wait_turn(1, "idle")
        assert not st["interrupted"] and st["last_reply"] == "PONG", st
        assert not os.path.exists(os.path.join(lane.lane, "interrupt")), "the stray request is consumed"
        # the CLI aims at the running turn, and writes nothing while none runs
        assert subprocess.run([sys.executable, RUNNER, "interrupt", "--lane", lane.lane]).returncode == 0
        assert not os.path.exists(os.path.join(lane.lane, "interrupt"))
    finally:
        lane.stop()


def test_pane_draws_state_in_claude_shapes():
    lane = tempfile.mkdtemp()
    assert ch.pane(lane) is None
    base = {"turn": 1, "inbox_offset": 0}
    ch.write_json_atomic(ch.paths(lane)["state"], dict(base, state="busy", turn_started=1000))
    p = ch.pane(lane, now=1075)
    assert "✻ Working… (1m 15s · esc to interrupt)" in p and "\n❯ \n" in p, p
    ch.send(lane, "Please continue — queued\nsecond line")
    p = ch.pane(lane, now=1075)
    assert "❯ Please continue — queued\nsecond line\n" in p, p
    ch.write_json_atomic(ch.paths(lane)["state"], dict(base, state="limit", inbox_offset=10**6,
                         last_reply="You've hit your 5-hour limit · resets 12:11pm (UTC)"))
    p = ch.pane(lane)
    assert "You've hit your usage limit · resets 12:11pm (UTC)" in p and "esc to interrupt" not in p, p
    ch.write_json_atomic(ch.paths(lane)["state"], dict(base, state="limit", inbox_offset=10**6, limit_resets_at=0))
    assert "You've hit your usage limit\n" in ch.pane(lane)
    ch.write_json_atomic(ch.paths(lane)["state"], dict(base, state="transient", inbox_offset=10**6,
                         error="API Error: 529 Overloaded.", last_reply="API Error: 529 Overloaded."))
    assert "  ⎿  API Error: 529 Overloaded." in ch.pane(lane)
    ch.write_json_atomic(ch.paths(lane)["state"], dict(base, state="idle", inbox_offset=10**6,
                         last_reply="the words API Error and 429 in a reply"))
    p = ch.pane(lane)
    assert "API Error" not in p and "429" not in p, "the reply text is never drawn"


def test_watch_prints_turns_tools_and_replies():
    lane = Lane(["normal", "tool-use"])
    try:
        lane.send("one"); lane.wait_turn(1, "idle"); lane.send("two"); lane.wait_turn(2, "idle")
        r = subprocess.run([sys.executable, RUNNER, "watch", "--lane", lane.lane, "--no-follow"],
                           capture_output=True, text=True)
        out = r.stdout
        assert r.returncode == 0 and "── turn 1 (message) ── one" in out and "← PONG" in out, out
        assert "· Bash echo hi > proof.txt" in out and "← DONE" in out and "── turn 2 ended: idle" in out, out
        r = subprocess.run([sys.executable, RUNNER, "watch", "--lane", lane.lane, "--no-follow", "--lines", "1"],
                           capture_output=True, text=True)
        assert r.stdout.strip() == "── turn 2 ended: idle", r.stdout
    finally:
        lane.stop()


def test_lane_dir_from_environment():
    lane = tempfile.mkdtemp()
    r = subprocess.run([sys.executable, RUNNER, "send", "from-env"], env=dict(os.environ, HARNESS_LANE_DIR=lane))
    assert r.returncode == 0 and ch.read_inbox(lane, 0)[0][0]["text"] == "from-env"
    env = {k: v for k, v in os.environ.items() if k != "HARNESS_LANE_DIR"}
    assert subprocess.run([sys.executable, RUNNER, "send", "x"], env=env, capture_output=True).returncode != 0


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

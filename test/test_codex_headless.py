"""test_codex_headless.py — #481: the headless codex lane runner (scripts/cli/codex_headless.py), driven against
fake-codex replaying the `codex exec --json` captures in test/fixtures/cli/codex/stream-json/ (see its
README.md). It shows the seven behaviours docs/reference.md ("Headless adapter contract") asks of an adapter,
on codex's own stream: a turn start (no thread id yet), the resume id (the thread the first turn reported,
`exec resume <id>` from the second), the event parse, usage, a limit → `limit`, a transient failure and a
thread codex lost → a fresh one, and interrupt and stop leaving no child behind."""
import importlib.util, json, os, signal, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hlproc import RUNNER_PY, WINDOWS, alive, gone, kill_tree  # noqa: E402,F401
ROOT = os.path.normpath(os.path.join(HERE, ".."))
RUNNER = os.path.join(ROOT, "scripts", "cli", "codex_headless.py")
FIX = os.path.join(HERE, "fixtures", "cli", "codex", "stream-json")
FAKE = os.path.join(FIX, "fake-codex")
spec = importlib.util.spec_from_file_location("codex_headless", RUNNER)
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
    """A runner on a fresh lane dir, its codex the fake replaying <plan>."""

    def __init__(self, plan, session_id=None, resume=False, hold=False, flags="--dangerously-bypass-approvals-and-sandbox"):
        self.tmp = tempfile.mkdtemp()
        self.lane, self.fake, self.wd = (os.path.join(self.tmp, p) for p in ("lane", "fake", "wd"))
        for p in (self.lane, self.fake, self.wd):
            os.makedirs(p)
        with open(os.path.join(self.fake, "plan"), "w") as f:
            f.write("\n".join(plan) + "\n")
        if hold:
            open(os.path.join(self.fake, "hold"), "w").close()
        env = dict(os.environ, FAKE_CLAUDE_DIR=self.fake)
        env.pop("CODEX_HOME", None)
        cmd = [RUNNER_PY, RUNNER, "run", "--lane", self.lane, "--cwd", self.wd,
               "--bin", f"{sys.executable} {FAKE}", f"--flags={flags}"]
        if session_id:
            cmd += ["--session-id", session_id]
        if resume:
            cmd += ["--resume"]
        self.proc = subprocess.Popen(cmd, env=env)
        wait_for(lambda: self.state().get("runner_pid") == self.proc.pid or self.proc.poll() is not None, "the runner's first state")
        assert self.proc.poll() is None, f"the runner exited {self.proc.returncode} at start"

    def release(self):
        os.remove(os.path.join(self.fake, "hold"))

    def send(self, text):
        assert subprocess.run([sys.executable, RUNNER, "send", "--lane", self.lane, text]).returncode == 0

    def state(self):
        return ch.core.read_state(self.lane)

    def calls(self):
        try:
            return [json.loads(l) for l in open(os.path.join(self.fake, "calls.jsonl"))]
        except OSError:
            return []

    def wait_turn(self, n, state=None):
        st = wait_for(lambda: (lambda s: s if s.get("turn") == n and s.get("state") != "busy" else None)(self.state()),
                      f"turn {n} to end")
        if state:
            assert st["state"] == state, f"turn {n}: state {st['state']!r}, want {state!r} ({st})"
        return st

    def stop(self):
        subprocess.run([sys.executable, RUNNER, "stop", "--lane", self.lane], stdout=subprocess.DEVNULL)
        try:
            self.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.proc.kill()


# --- the turn reader, over each capture -------------------------------------------------------------------
def test_classify_each_capture():
    assert ch.classify(fixture("normal")) == ("idle", "PONG", None, None)
    assert ch.classify(fixture("tool-use")) == ("idle", "DONE", None, None)
    state, reply, error, resets = ch.classify(fixture("limit"), 1)
    assert (state, reply, resets) == ("limit", None, ch.limit_resets_at(error))
    assert "hit your usage limit" in error and isinstance(resets, int)
    state, _, error, resets = ch.classify(fixture("transient"), 1)
    assert (state, resets) == ("transient", None) and "503" in error


def test_limit_reset_time_is_read_from_the_message():
    msg = "You've hit your usage limit. Upgrade to Plus to continue using Codex (https://x), or try again at Nov 18th, 2026 3:21 PM."
    want = int(time.mktime(time.strptime("2026-11-18 15:21", "%Y-%m-%d %H:%M")))
    assert ch.limit_resets_at(msg) == want
    assert ch.limit_resets_at("try again at Dec 2nd, 2026 12:05 AM") == int(time.mktime(time.strptime("2026-12-02 00:05", "%Y-%m-%d %H:%M")))
    assert ch.limit_resets_at("or try again later.") is None and ch.limit_resets_at(None) is None


def test_limit_is_read_from_events_not_text():
    # a reply that talks about a usage limit is no limit: only a failed turn is read
    evs = [{"type": "thread.started", "thread_id": "t"},
           {"type": "item.completed", "item": {"type": "agent_message", "text": "You've hit your usage limit, said the user"}},
           {"type": "turn.completed", "usage": {}}]
    assert ch.classify(evs)[0] == "idle"
    assert ch.classify([{"type": "thread.started", "thread_id": "t"}], 1)[0] == "transient"   # exit with no turn event


def test_usage_and_retry_are_reported():
    t = ch.Turn()
    for ev in fixture("transient")[:4]:
        t.feed(ev)
    assert t.retry == {"attempt": 2, "max_retries": 5, "error": t.error} and "Reconnecting... 2/5" in t.error
    for ev in fixture("transient")[4:]:
        t.feed(ev)
    assert t.retry is None   # the turn is over: nothing is being retried
    t = ch.Turn()
    for ev in fixture("normal"):
        t.feed(ev)
    assert t.session_id and t.rate_limit == {"status": "allowed", "usage": fixture("normal")[-1]["usage"]}
    t = ch.Turn()
    for ev in fixture("limit"):
        t.feed(ev)
    assert t.rate_limit["status"] == "rejected" and t.rate_limit["resetsAt"] == ch.limit_resets_at(t.rate_limit["message"])
    t.feed("not a dict"); t.feed({"type": "something.new"})   # an event it does not know never raises


def test_a_thread_codex_lost_is_flagged_from_its_stderr():
    t = ch.Turn()
    state, _, _, _ = t.outcome(1, open(os.path.join(FIX, "no-conversation.stderr")).read().strip())
    assert state == "transient" and t.no_conversation
    t = ch.Turn()
    t.outcome(1, "some other error")
    assert not t.no_conversation


# --- the command of one turn ------------------------------------------------------------------------------
def test_argv_new_thread_then_resume():
    a = ch.ADAPTER
    assert a.argv(["codex"], "harness-uuid", False, "m1", "high", ["--dangerously-bypass-approvals-and-sandbox"]) == [
        "codex", "exec", "--json", "--skip-git-repo-check", "-m", "m1", "-c", "model_reasoning_effort=high",
        "--dangerously-bypass-approvals-and-sandbox", "-"]   # codex names its thread: Harness's uuid is not passed
    assert a.argv(["codex"], "thread-1", True, None, None, ["-c", "x=1"]) == [
        "codex", "exec", "resume", "--json", "--skip-git-repo-check", "-c", "x=1", "thread-1", "-"]
    assert a.name == "codex" and a.account() == "codex"


# --- the runner on a lane ---------------------------------------------------------------------------------
def test_threads_are_started_once_and_resumed_after():
    lane = Lane(["normal", "tool-use"], session_id="harness-uuid")
    try:
        lane.send("first"); st = lane.wait_turn(1, "idle")
        thread = st["session_id"]
        assert thread != "harness-uuid" and len(thread) == 36 and st["session_started"] is True   # the thread codex reported
        assert st["last_reply"] == "PONG" and st["account"] == "codex" and st["adapter"] == "codex"
        assert st["rate_limit"]["status"] == "allowed" and st["rate_limit"]["usage"]["output_tokens"] == 9
        lane.send("second"); st = lane.wait_turn(2, "idle")
        c = lane.calls()
        assert [x["prompt"] for x in c] == ["first", "second"]
        assert "resume" not in c[0]["argv"] and "harness-uuid" not in c[0]["argv"] and c[0]["argv"][-1] == "-"
        assert c[1]["argv"][c[1]["argv"].index("exec") + 1] == "resume" and thread in c[1]["argv"]
        assert st["session_id"] == thread and st["last_reply"] == "DONE"
        assert "--json" in c[0]["argv"] and "--dangerously-bypass-approvals-and-sandbox" in c[0]["argv"]
    finally:
        lane.stop()


def test_resume_flag_resumes_the_thread_from_the_first_turn():
    tid = "01a1a487-1b40-76e1-a768-fdf24ab3c819"
    lane = Lane(["normal"], session_id=tid, resume=True)
    try:
        lane.send("go"); lane.wait_turn(1, "idle")
        argv = lane.calls()[0]["argv"]
        assert argv[argv.index("exec") + 1] == "resume" and tid in argv
        assert lane.state()["session_id"] == tid
    finally:
        lane.stop()


def test_limit_parks_the_lane_with_its_reset_time():
    lane = Lane(["limit", "normal"])
    try:
        lane.send("go"); st = lane.wait_turn(1, "limit")
        assert st["limit_resets_at"] == ch.limit_resets_at(st["error"]) and "usage limit" in st["error"]
        assert st["rate_limit"]["status"] == "rejected"
        pane = subprocess.run([sys.executable, RUNNER, "pane", "--lane", lane.lane], capture_output=True, text=True).stdout
        assert "You've hit your usage limit · resets" in pane   # the shape the watchdog's limit regex reads
        lane.send("again"); lane.wait_turn(2, "idle")   # the watchdog's nudge is the lane's next turn
    finally:
        lane.stop()


def test_transient_failure_is_a_stall_then_the_next_turn_runs():
    lane = Lane(["transient", "normal"])
    try:
        lane.send("go"); st = lane.wait_turn(1, "transient")
        assert "503" in st["error"] and st["limit_resets_at"] is None
        pane = subprocess.run([sys.executable, RUNNER, "pane", "--lane", lane.lane], capture_output=True, text=True).stdout
        assert "API Error: " in pane
        lane.send("nudge"); lane.wait_turn(2, "idle")
    finally:
        lane.stop()


def test_a_thread_codex_lost_is_started_afresh():
    lane = Lane(["no-conversation", "normal"], session_id="01a1a487-1b40-76e1-a768-fdf24ab3c819", resume=True)
    try:
        lane.send("go"); st = lane.wait_turn(2, "idle")   # the failed try and the fresh start are two turns
        c = lane.calls()
        assert len(c) == 2 and st["last_reply"] == "PONG"
        assert "resume" in c[0]["argv"] and "resume" not in c[1]["argv"]   # the same message, as a new thread
        assert [x["prompt"] for x in c] == ["go", "go"]
        assert st["session_id"] != "01a1a487-1b40-76e1-a768-fdf24ab3c819" and st["session_started"] is True   # the new thread
    finally:
        lane.stop()


def test_interrupt_and_stop_leave_no_child_behind():
    lane = Lane(["hang", "normal"])
    try:
        lane.send("go")
        wait_for(lambda: os.path.exists(os.path.join(lane.fake, "pids")), "the hung turn")
        cpid, gpid = map(int, open(os.path.join(lane.fake, "pids")).read().split())
        assert subprocess.run([sys.executable, RUNNER, "interrupt", "--lane", lane.lane]).returncode == 0
        wait_for(lambda: not alive(cpid) and not alive(gpid), "the interrupted turn's tree to end")
        assert lane.proc.poll() is None   # the lane stays up, idle
        st = lane.wait_turn(1, "idle")
        assert st["error"] == "interrupted"
        lane.send("after"); lane.wait_turn(2, "idle")
    finally:
        lane.stop()
    lane = Lane(["hang"])
    try:
        lane.send("go")
        wait_for(lambda: os.path.exists(os.path.join(lane.fake, "pids")), "the hung turn")
        cpid, gpid = map(int, open(os.path.join(lane.fake, "pids")).read().split())
        lane.stop()
        wait_for(lambda: not alive(cpid) and not alive(gpid), "stop to end the turn's tree")
        assert lane.state()["state"] == "ended"
    finally:
        lane.stop()


def test_watch_prints_turns_replies_and_failures():
    lines = [ch.watch_line(e) for e in
             [{"type": "harness", "subtype": "turn_start", "turn": 1, "kind": "message", "message": "hello"}]
             + fixture("normal") + fixture("transient") + fixture("limit")
             + [{"type": "harness", "subtype": "turn_end", "turn": 1, "state": "idle"},
                {"type": "item.completed", "item": {"type": "command_execution", "command": "echo hi > proof.txt\nsecond"}}]]
    shown = [l for l in lines if l]
    assert shown[0] == "── turn 1 (message) ── hello" and "PONG" in shown
    assert "· reconnecting 3/5" in shown and "· usage limit reached" in shown
    assert any(l.startswith("· turn failed: unexpected status 503") for l in shown)
    assert "── turn 1 ended: idle" in shown and shown[-1] == "· $ echo hi > proof.txt"
    assert ch.watch_line({"type": "turn.started"}) is None and ch.watch_line({"type": "item.completed", "item": {"type": "reasoning"}}) is None


if __name__ == "__main__":
    sys.exit(subprocess.call([sys.executable, "-m", "pytest", "-q", __file__] + sys.argv[1:]))

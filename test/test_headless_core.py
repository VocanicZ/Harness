"""test_headless_core.py — #480: the shared headless runner core (scripts/cli/headless_core.py) proved
through a tiny fake-CLI adapter, independent of claude. test/fixtures/headless-core/fake_cli.py is a
made-up agent CLI (its own argv, its own `{"ev": ...}` wire format) and fake_headless.py the smallest
adapter that satisfies the contract in docs/reference.md. What these tests show about the core is what a
per-CLI adapter can count on: a turn starts with the message on stdin, the session id the CLI reports is
the one resumed, events are parsed into state.json and events.jsonl, usage lands in `rate_limit`, a limit
is the `limit` state with its reset, a failed turn is `transient` and the next message retries, an
interrupt ends the turn and not the lane, a stop ends both."""
import importlib.util, json, os, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hlproc import RUNNER_PY, WINDOWS, alive, gone, kill_tree  # noqa: E402,F401
ROOT = os.path.normpath(os.path.join(HERE, ".."))
FIX = os.path.join(HERE, "fixtures", "headless-core")
ENTRY = os.path.join(FIX, "fake_headless.py")
FAKE = os.path.join(FIX, "fake_cli.py")
CORE = os.path.join(ROOT, "scripts", "cli", "headless_core.py")
spec = importlib.util.spec_from_file_location("fake_headless", ENTRY)
fh = importlib.util.module_from_spec(spec); spec.loader.exec_module(fh)
core = fh.core


def wait_for(pred, what, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {what}")


class Lane:
    """A core runner on a fresh lane dir, its CLI the fake replaying <plan>."""

    def __init__(self, plan, session_id=None, resume=False, model=None):
        self.tmp = tempfile.mkdtemp()
        self.lane, self.fake, self.wd = (os.path.join(self.tmp, p) for p in ("lane", "fake", "wd"))
        for p in (self.lane, self.fake, self.wd):
            os.makedirs(p)
        with open(os.path.join(self.fake, "plan"), "w") as f:
            f.write("\n".join(plan) + "\n")
        env = dict(os.environ, FAKE_CLI_DIR=self.fake)
        cmd = [RUNNER_PY, ENTRY, "run", "--lane", self.lane, "--cwd", self.wd, "--bin", f"{sys.executable} {FAKE}"]
        if session_id:
            cmd += ["--session-id", session_id]
        if resume:
            cmd += ["--resume"]
        if model:
            cmd += ["--model", model]
        self.proc = subprocess.Popen(cmd, env=env)
        wait_for(lambda: self.state().get("runner_pid") == self.proc.pid or self.proc.poll() is not None,
                 "the runner's first state")
        assert self.proc.poll() is None, f"the runner exited {self.proc.returncode} at start"

    def hold(self, on=True):
        p = os.path.join(self.fake, "hold")
        if on:
            open(p, "w").close()
        elif os.path.exists(p):
            os.remove(p)

    def send(self, text, kind="message"):
        core.send(self.lane, text, kind)

    def state(self):
        return core.read_state(self.lane)

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
        if self.proc.poll() is None:
            r = subprocess.run([sys.executable, ENTRY, "stop", "--lane", self.lane, "--timeout", "15"])
            assert r.returncode == 0, "stop did not end the runner"
        self.proc.wait(timeout=15)


def test_turn_starts_with_the_message_on_stdin_and_the_adapters_argv():
    L = Lane(["ok first reply", "ok second"], session_id="sess-A", model="m1")
    try:
        L.hold()
        L.send("do the thing\nsecond line")
        st = wait_for(lambda: (lambda s: s if s.get("state") == "busy" else None)(L.state()), "a busy turn")
        assert st["turn"] == 1 and st["turn_started"] and st["claude_pid"], st
        call = wait_for(lambda: L.calls(), "the CLI's first call")[0]
        assert call["prompt"] == "do the thing\nsecond line", call
        assert call["argv"] == ["run", "--new", "sess-A", "--model", "m1"], call["argv"]
        L.hold(False)
        st = L.wait_turn(1, "idle")
        assert st["last_reply"] == "first reply" and st["error"] is None and st["claude_pid"] is None, st
        assert st["adapter"] == "fake" and st["account"] == "fake-account", st
    finally:
        L.stop()


def test_the_session_id_the_cli_reports_is_the_one_resumed():
    L = Lane(["ok one", "ok two"])   # no id named: the fake picks `fake-1`
    try:
        L.send("a"); st = L.wait_turn(1, "idle")
        assert st["session_id"] == "fake-1" and st["session_started"] is True, st
        L.send("b"); L.wait_turn(2, "idle")
        argvs = [c["argv"] for c in L.calls()]
        assert argvs == [["run", "--new"], ["run", "--resume", "fake-1"]], argvs
    finally:
        L.stop()


def test_resume_flag_resumes_from_the_first_turn():
    L = Lane(["ok back"], session_id="old-sess", resume=True)
    try:
        L.send("carry on"); L.wait_turn(1, "idle")
        assert L.calls()[0]["argv"] == ["run", "--resume", "old-sess"], L.calls()
    finally:
        L.stop()


def test_events_are_parsed_into_events_jsonl_and_state():
    L = Lane(["ok the reply"])
    try:
        L.send("go", kind="nudge"); L.wait_turn(1, "idle")
        ev = L.events()
        kinds = [(e.get("type"), e.get("subtype") or e.get("ev")) for e in ev]
        assert kinds == [("harness", "turn_start"), (None, "hello"), (None, "usage"), (None, "final"),
                         ("harness", "turn_end")], kinds
        assert ev[0]["kind"] == "nudge" and ev[0]["message"] == "go" and ev[-1]["state"] == "idle", ev
        # `watch` prints what the adapter's watch_line makes of an event, and the core's markers
        import io
        out = io.StringIO()
        core.watch(L.lane, follow=False, out=out, adapter=fh.ADAPTER)
        assert out.getvalue() == "the reply\n", out.getvalue()
    finally:
        L.stop()


def test_usage_the_adapter_reports_lands_in_state():
    L = Lane(["ok a", "ok b"])
    try:
        L.send("a"); st = L.wait_turn(1, "idle")
        assert st["rate_limit"] == {"window": "5h", "used_pct": 41}, st["rate_limit"]
        first_at = st["rate_limit_at"]
        assert first_at, st
        L.send("b"); st = L.wait_turn(2, "idle")
        assert st["rate_limit"]["used_pct"] == 42 and st["rate_limit_at"] > first_at, st
    finally:
        L.stop()


def test_a_limit_is_the_limit_state_with_its_reset_and_the_next_message_recovers():
    L = Lane(["quota", "ok back"])
    try:
        L.send("a"); st = L.wait_turn(1, "limit")
        assert st["limit_resets_at"] == 1893456000 and "quota exhausted" in st["error"], st
        pane = core.pane(L.lane)
        assert "You've hit your usage limit" in pane and "esc to interrupt" not in pane, pane
        L.send("b"); st = L.wait_turn(2, "idle")
        assert st["last_reply"] == "back" and st["limit_resets_at"] is None and st["error"] is None, st
    finally:
        L.stop()


def test_a_failed_turn_is_transient_and_the_next_message_retries():
    L = Lane(["flaky", "crash", "ok fine"])
    try:
        L.send("a"); st = L.wait_turn(1, "transient")
        assert "no final event" in st["error"] and st["retry"] is None, st
        assert "API Error" in core.pane(L.lane)
        L.send("b"); st = L.wait_turn(2, "transient")
        assert "exited 7" in st["error"], st
        L.send("c"); st = L.wait_turn(3, "idle")
        assert st["last_reply"] == "fine" and st["error"] is None, st
    finally:
        L.stop()


def test_a_missing_cli_fails_the_turn_not_the_runner():
    L = Lane([])
    try:
        # a second lane whose binary does not exist
        lane2 = os.path.join(L.tmp, "lane2"); os.makedirs(lane2)
        p = subprocess.Popen([RUNNER_PY, ENTRY, "run", "--lane", lane2, "--cwd", L.wd, "--bin", "/nonexistent/fake-cli",
                              "--message", "hi"])
        try:
            st = wait_for(lambda: (lambda s: s if s.get("turn") == 1 and s.get("state") != "busy" else None)(core.read_state(lane2)),
                          "the failed turn")
            assert st["state"] == "transient" and "cannot start fake" in st["error"] and p.poll() is None, st
        finally:
            subprocess.run([sys.executable, ENTRY, "stop", "--lane", lane2])
            p.wait(timeout=15)
    finally:
        L.stop()


def _hang(L):
    L.send("hang please")
    pids = wait_for(lambda: os.path.exists(os.path.join(L.fake, "pids")) and
                    open(os.path.join(L.fake, "pids")).read().split() or None, "the hung turn's pids")
    return [int(p) for p in pids]


def test_interrupt_ends_the_turn_not_the_lane():
    L = Lane(["hang", "ok after"])
    try:
        cli, grand = _hang(L)
        assert L.state()["state"] == "busy"
        subprocess.run([sys.executable, ENTRY, "interrupt", "--lane", L.lane], check=True)
        st = L.wait_turn(1, "idle")
        assert st["interrupted"] == 1 and st["error"] == "interrupted" and L.proc.poll() is None, st
        assert gone(cli) and gone(grand), "the interrupted turn's whole process tree is gone"
        assert core.pane(L.lane).count("Interrupted") == 1
        L.send("next"); st = L.wait_turn(2, "idle")
        assert st["last_reply"] == "after" and st["interrupted"] == 0, st
    finally:
        L.stop()


def test_stop_ends_the_running_turn_and_the_lane():
    L = Lane(["hang"])
    try:
        cli, grand = _hang(L)
        L.stop()
        assert L.state()["state"] == "ended" and L.proc.returncode == 0, L.state()
        assert gone(cli) and gone(grand), "no child left behind"
    finally:
        if L.proc.poll() is None:
            L.proc.kill()


def test_restart_resumes_the_session_and_inbox_position():
    L = Lane(["ok one"])
    try:
        L.send("a"); L.wait_turn(1, "idle")
    finally:
        L.stop()
    env = dict(os.environ, FAKE_CLI_DIR=L.fake)
    with open(os.path.join(L.fake, "plan"), "a") as f:
        f.write("ok two\n")
    p = subprocess.Popen([RUNNER_PY, ENTRY, "run", "--lane", L.lane, "--cwd", L.wd, "--bin", f"{sys.executable} {FAKE}"], env=env)
    try:
        wait_for(lambda: L.state().get("runner_pid") == p.pid, "the restarted runner")
        L.send("b"); L.wait_turn(2, "idle")
        assert [c["argv"] for c in L.calls()] == [["run", "--new"], ["run", "--resume", "fake-1"]], L.calls()
    finally:
        subprocess.run([sys.executable, ENTRY, "stop", "--lane", L.lane])
        p.wait(timeout=15)


def test_the_core_loads_an_adapter_by_cli_name_and_refuses_a_missing_one():
    ad = core.load_adapter("claude")
    assert ad.name == "claude" and callable(ad.new_turn) and callable(ad.argv)
    r = subprocess.run([sys.executable, CORE, "run", "--adapter", "nosuchcli", "--lane", tempfile.mkdtemp(), "--cwd", "."],
                       capture_output=True, text=True)
    assert r.returncode != 0 and "no headless adapter for 'nosuchcli'" in r.stderr, r

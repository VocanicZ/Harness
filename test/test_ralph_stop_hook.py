"""test_ralph_stop_hook.py — #616 (PRD #587): the engine-owned goal-loop Stop hook of Claude lanes
(plugins/claude/harness-ralph/hooks/stop-hook.py), driven the way Claude Code drives it: the Stop hook JSON on
stdin, the lane's cwd holding .claude/ralph-loop.local.md, a transcript in Claude Code's JSONL shape (rows
taken from bench/results/run-20261106's reviewer transcript). It must end the loop on the promise even when
the final message is flushed after Stop fires, give no re-feed while a background sub-agent runs, and nudge
with a short reminder instead of the task file (the task only after a compaction)."""
import json, os, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
PLUGIN = os.path.join(ROOT, "plugins", "claude", "harness-ralph")
HOOK = os.path.join(PLUGIN, "hooks", "stop-hook.py")
MARK = "UNIQUE_TASK_MARKER_9f3a"
TASK = f"You are an implementation engineer.\n\nGOAL: implement issue #7, get it merged.\n\nSteps:\n1. {MARK}\n2. more steps\n"
PROMISE = "ISSUE 7 DONE"
SID = "11111111-2222-3333-4444-555555555555"


class Lane:
    def __init__(self, tmp, session_id=SID, max_iter=0, iteration=1, promise=PROMISE):
        self.cwd = os.path.join(tmp, "wd")
        os.makedirs(os.path.join(self.cwd, ".claude"))
        self.state = os.path.join(self.cwd, ".claude", "ralph-loop.local.md")
        self.transcript = os.path.join(tmp, "transcript.jsonl")
        sid = f"session_id: {session_id}\n" if session_id else ""
        with open(self.state, "w") as f:
            f.write(f'---\nactive: true\niteration: {iteration}\n{sid}max_iterations: {max_iter}\n'
                    f'completion_promise: "{promise}"\nstarted_at: "2026-11-07T00:00:00Z"\n---\n\n{TASK}')
        self.rows = []
        self.session_id = session_id

    def write(self):
        with open(self.transcript, "w") as f:
            for r in self.rows:
                f.write(json.dumps(r) + "\n")

    def append(self, row):
        self.rows.append(row)
        with open(self.transcript, "a") as f:
            f.write(json.dumps(row) + "\n")

    def say(self, text):
        self.append({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}})

    def launch_agent(self, aid, ts=None):
        ts = ts or time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        self.append({"type": "user", "timestamp": ts, "toolUseResult": {"isAsync": True, "status": "async_launched", "agentId": aid},
                     "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": [
                         {"type": "text", "text": f"Async agent launched successfully.\nagentId: {aid} (internal ID)"}]}]}})

    def agent_done(self, aid, status="completed"):
        self.append({"type": "attachment", "attachment": {"type": "queued_command", "prompt":
                     f"<task-notification>\n<task-id>{aid}</task-id>\n<status>{status}</status>\n</task-notification>"}})

    def compact(self):
        self.append({"type": "system", "subtype": "compact_boundary"})
        self.append({"type": "user", "isCompactSummary": True, "message": {"role": "user", "content": "summary"}})

    def stop_input(self, **extra):
        d = {"hook_event_name": "Stop", "session_id": self.session_id or "x", "transcript_path": self.transcript,
             "cwd": self.cwd, "stop_hook_active": False}
        d.update(extra)
        return d

    def stop(self, flush_ms=0, stale_s=None, **extra):
        env = dict(os.environ, HARNESS_RALPH_FLUSH_MS=str(flush_ms))
        if stale_s is not None:
            env["HARNESS_RALPH_AGENT_STALE_S"] = str(stale_s)
        p = subprocess.run([sys.executable, HOOK], input=json.dumps(self.stop_input(**extra)), capture_output=True, text=True,
                           env=env, timeout=30)
        assert p.returncode == 0, p.stderr
        return json.loads(p.stdout) if p.stdout.strip() else None

    def frontmatter(self, key):
        for line in open(self.state).read().split("---")[1].splitlines():
            if line.startswith(key + ":"):
                return line.split(":", 1)[1].strip()


def lane(**kw):
    tmp = tempfile.mkdtemp(prefix="ralphhook-")
    return Lane(tmp, **kw)


# --- the promise ends the loop --------------------------------------------------------------------
def test_the_promise_in_the_last_message_ends_the_loop_with_no_refeed():
    L = lane()
    L.say("working"); L.say(f"All done.\n<promise>{PROMISE}</promise>"); L.write()
    assert L.stop() is None
    assert not os.path.exists(L.state), "the state file is the loop's done signal (cli_done)"


def test_a_promise_flushed_200ms_after_stop_fires_ends_the_loop_with_no_refeed():
    L = lane()
    L.say("working on it"); L.write()
    threading.Timer(0.2, L.say, [f"<promise>{PROMISE}</promise>"]).start()
    assert L.stop(flush_ms=1500) is None, "the hook looks again before it nudges"
    assert not os.path.exists(L.state)


def test_the_flush_race_is_real_without_the_wait():
    # Same transcript, no wait: the hook sees only the earlier message and re-feeds. Pins that the test above
    # is red without the re-check.
    # The flush must land after the hook's one look: 0.2s is plenty where a python start is ~50ms, but a native Windows start
    # (the venv launcher, then the interpreter) takes longer than that, and the promise was already there to find (#1110).
    # So the delay is twice what one hook run takes here, with 0.2s as the floor.
    probe = lane(); probe.say("working on it"); probe.write()
    t0 = time.time(); probe.stop(flush_ms=0); delay = max(0.2, 2 * (time.time() - t0))
    L = lane()
    L.say("working on it"); L.write()
    timer = threading.Timer(delay, L.say, [f"<promise>{PROMISE}</promise>"]); timer.start()
    out = L.stop(flush_ms=0)
    assert out and out["decision"] == "block"
    timer.join()


def _hook_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location("ralph_stop_hook", HOOK)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def test_flush_ms_inf_falls_back_to_the_default_and_the_hook_finishes_in_time():
    # Unfixed, inf waits forever -> the hook runs into its 30s timeout instead of nudging.
    L = lane()
    L.say("working"); L.write()
    env = dict(os.environ, HARNESS_RALPH_FLUSH_MS="inf")
    t0 = time.time()
    p = subprocess.run([sys.executable, HOOK], input=json.dumps(L.stop_input()), capture_output=True, text=True,
                       env=env, timeout=10)
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout)["decision"] == "block"
    assert time.time() - t0 < 8
    assert "HARNESS_RALPH_FLUSH_MS='inf'" in p.stderr


def test_flush_wait_is_capped_below_the_hook_timeout_for_1e9_and_non_finite_values():
    m = _hook_module()
    saved = os.environ.get("HARNESS_RALPH_FLUSH_MS")
    try:
        for raw, want in [("1e9", 20.0), ("20001", 20.0), ("20000", 20.0), ("inf", 1.5), ("-inf", 1.5), ("nan", 1.5),
                          ("abc", 1.5), ("1500", 1.5), ("0", 0.0)]:
            os.environ["HARNESS_RALPH_FLUSH_MS"] = raw
            assert m.flush_wait_s() == want, raw
        os.environ.pop("HARNESS_RALPH_FLUSH_MS")
        assert m.flush_wait_s() == 1.5
    finally:
        if saved is not None:
            os.environ["HARNESS_RALPH_FLUSH_MS"] = saved
    assert m.flush_wait_s() * 1000 < 30000


def test_the_hooks_own_last_assistant_message_counts_when_the_transcript_lags():
    L = lane()
    L.say("working"); L.write()
    assert L.stop(last_assistant_message=f"<promise>{PROMISE}</promise>") is None
    assert not os.path.exists(L.state)


def test_a_promise_quoted_earlier_or_a_different_promise_does_not_end_it():
    L = lane()
    L.say(f"<promise>{PROMISE}</promise>"); L.say("oh wait, more to do"); L.write()
    assert L.stop()["decision"] == "block", "only the last message counts"
    L2 = lane()
    L2.say("<promise>SOMETHING ELSE</promise>"); L2.write()
    assert L2.stop()["decision"] == "block" and os.path.exists(L2.state)


def test_max_iterations_ends_the_loop():
    L = lane(max_iter=3, iteration=3)
    L.say("still going"); L.write()
    assert L.stop() is None and not os.path.exists(L.state)


# --- no re-feed while a sub-agent runs ------------------------------------------------------------
def test_a_stop_while_a_sub_agent_runs_gives_no_refeed():
    L = lane()
    L.say("launching a reviewer"); L.launch_agent("a14ea2d902ddf816d"); L.say("Still waiting on the review sub-agent."); L.write()
    assert L.stop(stale_s=3600) is None
    assert os.path.exists(L.state) and L.frontmatter("iteration") == "1", "no nudge, no iteration counted"


def test_once_the_sub_agent_reports_done_the_next_stop_nudges_again():
    L = lane()
    L.launch_agent("a14ea2d902ddf816d"); L.agent_done("a14ea2d902ddf816d"); L.say("review is in, nothing more to do"); L.write()
    out = L.stop(stale_s=3600)
    assert out and out["decision"] == "block" and L.frontmatter("iteration") == "2"


def test_a_sub_agent_that_never_reports_does_not_hold_the_nudge_forever():
    L = lane()
    L.launch_agent("deadbeef", ts="2026-11-07T00:00:10.000Z"); L.say("waiting"); L.write()
    sub = os.path.join(L.transcript[:-6], "subagents"); os.makedirs(sub)
    f = os.path.join(sub, "agent-deadbeef.jsonl"); open(f, "w").write("{}\n")
    old = time.time() - 7200; os.utime(f, (old, old))
    assert L.stop(stale_s=1800)["decision"] == "block", "its transcript has not moved for two hours"
    os.utime(f, None)
    assert L.stop(stale_s=1800) is None, "a fresh sub-agent transcript means it is working"


def test_the_promise_wins_over_a_running_sub_agent():
    L = lane()
    L.launch_agent("a1"); L.say(f"<promise>{PROMISE}</promise>"); L.write()
    assert L.stop() is None and not os.path.exists(L.state)


# --- the nudge ------------------------------------------------------------------------------------
def test_a_refeed_without_compaction_is_the_short_nudge_not_the_task_file():
    L = lane()
    L.say("did some of it"); L.write()
    out = L.stop()
    assert out["decision"] == "block"
    assert MARK not in out["reason"] and "Steps:" not in out["reason"], "the task file is not re-sent"
    assert "Not done: implement issue #7, get it merged." in out["reason"] and f"<promise>{PROMISE}</promise>" in out["reason"]
    assert len(out["reason"]) < len(TASK) * 3 and len(out["reason"]) < 400
    assert "Ralph iteration 2" in out["systemMessage"] and L.frontmatter("iteration") == "2"
    assert MARK in open(L.state).read(), "the state file keeps the task (write_state's copy; the other CLIs read it)"
    assert L.stop()["reason"] == out["reason"] and L.frontmatter("iteration") == "3"


def test_after_a_compaction_the_task_is_re_sent_once():
    L = lane()
    L.say("did some of it"); L.compact(); L.write()
    out = L.stop()
    assert MARK in out["reason"] and "Steps:" in out["reason"], "the lane may have lost the task"
    assert L.frontmatter("compactions_fed") == "1"
    again = L.stop()
    assert MARK not in again["reason"], "that compaction has been answered"
    L.compact()
    assert MARK in L.stop()["reason"], "a second compaction is answered too"
    assert L.frontmatter("compactions_fed") == "2" and L.frontmatter("iteration") == "4"


def test_a_missing_transcript_still_nudges_short():
    L = lane()
    out = L.stop()
    assert out["decision"] == "block" and MARK not in out["reason"]


# --- whose loop it is -----------------------------------------------------------------------------
def test_another_session_in_the_project_is_left_alone():
    L = lane()
    L.say("other session"); L.write()
    assert L.stop(session_id="99999999-0000-0000-0000-000000000000") is None
    assert os.path.exists(L.state) and L.frontmatter("iteration") == "1"


def test_no_state_file_means_no_loop():
    L = lane()
    os.unlink(L.state)
    assert L.stop() is None


def test_a_legacy_state_without_a_session_id_is_everyones():
    L = lane(session_id="")
    L.say("x"); L.write()
    assert L.stop()["decision"] == "block"


def test_the_plugin_is_wired_for_claude_code():
    hooks = json.load(open(os.path.join(PLUGIN, "hooks", "hooks.json")))["hooks"]["Stop"][0]["hooks"][0]
    assert hooks["type"] == "command" and "${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.py" in hooks["command"]
    assert json.load(open(os.path.join(PLUGIN, ".claude-plugin", "plugin.json")))["name"] == "harness-ralph"


if __name__ == "__main__":
    # test/run.sh runs this file as `python3 <file>` (#892): without a runner here it would define the tests and exit 0.
    import traceback
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except Exception:
                print(f"  FAIL: {name}"); traceback.print_exc(); fails += 1
    print(f"-- {'all pass' if not fails else str(fails) + ' FAILED'}")
    sys.exit(1 if fails else 0)

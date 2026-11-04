#!/usr/bin/env python3
"""copilot_headless.py — the headless lane runner for `copilot` (#483, PRD #475): the copilot ADAPTER on the
shared core (headless_core.py, #480) and the entry point the copilot lane runs.

Each turn is one `copilot --output-format json` process in the lane's worktree, the message on its stdin
(copilot reads a piped prompt in its non-interactive mode, so no `-p <text>` and no argv length limit). The
CLI prints its session events as JSONL and ends with a `result` record (`exitCode`, `sessionId`, `usage`).
Every turn names the lane's session with `--session-id=<id>`: copilot resumes that session when it exists
and creates it under that id when it does not (`copilot --help`: "Resume an existing session or task by ID,
or set the UUID for a new session"), so the lane is ONE copilot session across turns, a relaunch resumes
it, and a session the CLI no longer has is started afresh under the same id with no recovery path of its
own. The lane files, the states, interrupt, stop and the pane the watchdog reads are the core's — see
headless_core.py. This file holds only what is copilot's: how a turn is started, how its JSON is read and
how an event is shown to `watch`.

  copilot_headless.py run   --lane <dir> --cwd <wd> [--bin <copilot command>] [--session-id <id> [--resume]]
                            [--model <m>] [--effort <e>] [--flags="<extra copilot flags>"]
                            [--message <first message>]
  copilot_headless.py send | state | stop | interrupt | pane | watch     # the core's, unchanged

Usage: the CLI writes `session.usage_record` events to $COPILOT_HOME/session-state/<id>/events.jsonl
for headless turns as for a pane's, so the stats sweep and cli_usage read a lane's tokens from there
(copilot.sh copilot_usage), exactly as for a tmux lane. Limits: a quota that ends a turn is a `session.error`
(or, when the CLI cannot start the turn at all, a line on stderr) whose text is one of the limit strings
copilot.sh copilot_limit_re lists.
"""
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the core sits beside this file
import headless_core as core
from headless_core import (paths, read_state, write_json_atomic, send, read_inbox, undelivered, pane,
                           kill_tree, spawn, utf8_stdio, WINDOWS, POLL_S)

# The strings the 1.0.105 runtime ends a turn with when the account's quota is out (the same list as
# copilot.sh copilot_limit_re, test/fixtures/cli/copilot/README.md `limit.txt`).
LIMIT_RE = re.compile(
    r"You've hit (your|the) (session )?rate limit|You've reached your weekly rate limit|"
    r"You've run out of your included AI credits|You've reached the spending limit for this session|"
    r"You've reached your additional usage limit")


# --- reading a turn's events --------------------------------------------------------------------
class Turn:
    """Folds one turn's JSON events into its outcome."""

    def __init__(self):
        self.session_id = None
        self.result = None          # the `result` record, once seen
        self.reply = None           # the last non-empty assistant.message of the session's own agent
        self.error = None           # the last session.error message
        self.rate_limit = None      # the latest quota reading, or the limit that ended the turn
        self.retry = None           # copilot's own in-turn retries print no event: never set
        self.no_conversation = False  # --session-id starts a missing session itself: never set

    def feed(self, ev):
        if not isinstance(ev, dict):
            return
        t, data = ev.get("type"), ev.get("data") if isinstance(ev.get("data"), dict) else {}
        if t == "result":
            self.result = ev
            if isinstance(ev.get("sessionId"), str) and ev["sessionId"]:
                self.session_id = ev["sessionId"]
        elif t in ("session.start", "session.resume") and isinstance(data.get("sessionId"), str):
            self.session_id = data["sessionId"] or self.session_id
        elif t == "assistant.message" and not ev.get("agentId"):
            if isinstance(data.get("content"), str) and data["content"].strip():
                self.reply = data["content"]
        elif t == "session.error":
            msg = data.get("message")
            if isinstance(msg, str) and msg.strip():
                self.error = msg.strip()
        if isinstance(data.get("quotaSnapshots"), dict) and data["quotaSnapshots"]:
            self.rate_limit = {"quotaSnapshots": data["quotaSnapshots"]}

    def outcome(self, rc, stderr_tail=""):
        """(state, reply, error, limit_resets_at) for the turn once its process exited with <rc>."""
        r = self.result
        if r is not None and not r.get("exitCode") and not rc:
            return "idle", self.reply, None, None
        error = self.error or (stderr_tail if r is None else "") or f"copilot exited {rc if rc else r.get('exitCode')}"
        if r is None:
            why = f"copilot exited {rc} with no result record"
            error = f"{why}: {self.error or stderr_tail}" if (self.error or stderr_tail) else why
        # A quota that is out is the account's, whatever else the turn printed: the lane waits for it.
        # Copilot names no reset time in the message, so none is reported (the windows are cli_limit_usage's).
        if LIMIT_RE.search(error):
            self.rate_limit = {"status": "rejected", "message": error}
            return "limit", self.reply, error, None
        return "transient", self.reply, error, None


# --- showing an event to `watch` ----------------------------------------------------------------
def watch_line(ev):
    """One events.jsonl event as `harness attach` prints it; None for the ones it leaves out."""
    t, data = ev.get("type"), ev.get("data") if isinstance(ev.get("data"), dict) else {}
    if t == "harness":
        return core.harness_watch_line(ev)
    if t == "assistant.message":
        text = data.get("content") if isinstance(data.get("content"), str) else ""
        return text.strip() or None
    if t == "tool.execution_start":
        args = data.get("arguments") if isinstance(data.get("arguments"), dict) else {}
        arg = args.get("command") or args.get("path") or args.get("file_path") or args.get("description") or ""
        arg = str(arg).splitlines()[0][:160] if arg else ""
        return f"· {data.get('toolName')} {arg}".rstrip()
    if t == "session.error":
        return f"· error: {data.get('message')}"
    return None


# --- the adapter --------------------------------------------------------------------------------
class CopilotAdapter:
    """The contract the core runs a CLI through (docs/reference.md, "Headless adapter contract")."""
    name = "copilot"

    @property
    def default_bin(self):
        return os.environ.get("HARNESS_COPILOT_BIN") or "copilot"

    def account(self):
        """The account the lane runs on: its COPILOT_HOME's name (the way claude's is its config dir's)."""
        return os.path.basename((os.environ.get("COPILOT_HOME") or "default").rstrip("/\\")) or "default"

    def argv(self, bin_, session_id, session_started, model, effort, flags):
        """One turn's command (the message goes on its stdin). `--session-id` names the lane's session on
        every turn: the first creates it, each later one (and a relaunch) resumes it. `--effort` rides only
        with a model named: Auto refuses a reasoning effort in this mode ("Model "auto" does not support
        reasoning effort configuration")."""
        a = list(bin_) + ["--output-format", "json"]
        if session_id:
            a.append(f"--session-id={session_id}")
        if model:
            a.append(f"--model={model}")
        if effort and model and model != "auto":
            a.append(f"--effort={effort}")
        return a + list(flags)

    def new_turn(self):
        return Turn()

    watch_line = staticmethod(watch_line)


ADAPTER = CopilotAdapter()


class Runner(core.Runner):
    def __init__(self, *a, **kw):
        super().__init__(ADAPTER, *a, **kw)


def classify(events, rc=0, stderr_tail=""):
    """The outcome of a copilot turn that printed <events> and exited <rc>."""
    turn = ADAPTER.new_turn()
    for ev in events:
        turn.feed(ev)
    return turn.outcome(rc, stderr_tail)


def main(argv=None):
    return core.main(argv, adapter=ADAPTER, prog="copilot_headless.py")


if __name__ == "__main__":
    sys.exit(main())

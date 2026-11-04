#!/usr/bin/env python3
"""agy_headless.py — the headless lane runner for `agy` (#486, PRD #475): the agy ADAPTER on the shared core
(headless_core.py, #480) and the entry point an agy lane runs.

Each turn is one `agy --input-format stream-json --output-format stream-json -p=` process in the lane's
worktree (Antigravity CLI 1.4). Print mode with `--input-format stream-json` reads its prompt from stdin as one
JSON line, `{"event":"user","message":{"content":"<text>"}}`, runs one turn for it and exits when stdin closes,
so the message never rides argv (no length limit, no quoting) and the bare `-p=` only switches print mode on
(a prompt on the command line is refused beside that input format). agy names its own conversations: the first
turn passes none, its id arrives on the first event (`init.conversation_id`), and every later turn passes
`--conversation <id>`, so the lane is ONE agy conversation across turns. The lane files, states, interrupt,
stop and the pane the watchdog reads are the core's — see headless_core.py. This file holds only what is agy's:
how a turn is started, how its stream is read and how an event is shown to `watch`.

  agy_headless.py run   --lane <dir> --cwd <wd> [--bin <agy command>] [--session-id <id> [--resume]]
                        [--model <m>] [--effort <e>] [--flags="<extra agy flags>"]
                        [--message <first message>]
  agy_headless.py send | state | stop | interrupt | pane | watch     # the core's, unchanged

What the stream is (test/fixtures/cli/agy/stream-json/): one JSON object per line, each with an `event`:
`init` (the conversation id, the tools, the permission mode), `step_update` (one per state change of a step:
`user_input`, `agent_response` with the `text_delta` it streamed and the `usage` of its model call, `tool` with
`tool_name` and `tool_info`, `error_message`, `system_message`) and a last `result` (`status` SUCCESS or ERROR,
the whole `response`, `error`, `usage`, `finished_reason`). The exit code is 0 for SUCCESS and 3 after an ERROR
result (a stderr `error: …` line and an `AGY_ERROR: {…}` line say the same). agy retries 5xx and a per-minute
429 itself; what reaches the stream is its give-up.

A conversation id agy no longer has is no error: agy prints `warning: conversation "<id>" not found` on stderr
and runs the message in a NEW conversation, whose id is on the stream. The lane adopts it (the core saves the
turn's `session_id`), so there is nothing to run again and `no_conversation` is never set.

Usage: the stream's `usage` carries token counts but no model, so the stats sweep and cli_usage read a lane's
tokens from agy's own conversation database (agy.sh agy_usage), exactly as for a tmux lane. Windows: the 5-hour
and weekly buckets are `agy -p /usage` (agy.sh agy_limit_usage), a call that runs no turn. A turn that ends on
the account's quota says when it lifts ("Resets in 93h41m3s"); that is the lane's `limit_resets_at`.
"""
import json, os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the core sits beside this file
import headless_core as core
from headless_core import (paths, read_state, write_json_atomic, send, read_inbox, undelivered, pane,
                           kill_tree, spawn, utf8_stdio, WINDOWS, POLL_S)

# An error that is the account's quota, not a passing fault: the 1.4 runtime's own wording (test/fixtures/cli/agy/
# stream-json/limit.jsonl, captured) and the strings of the binary agy.sh agy_limit_re lists for a pane.
LIMIT_RE = re.compile(r"Individual quota reached|exhausted your quota|Quota exhausted|AI credits balance is too low", re.I)
RESETS_IN_RE = re.compile(r"Resets in ((?:\d+[dhms])+)", re.I)
UNIT_S = {"d": 86400, "h": 3600, "m": 60, "s": 1}


def resets_in(text):
    """Seconds the error says its quota lifts in ("Resets in 93h41m3s"), or None when it says nothing."""
    m = RESETS_IN_RE.search(text or "")
    if not m:
        return None
    secs = sum(int(n) * UNIT_S[u.lower()] for n, u in re.findall(r"(\d+)([dhms])", m.group(1), re.I))
    return secs or None


# --- reading a turn's events --------------------------------------------------------------------
class Turn:
    """Folds one turn's `--output-format stream-json` events into its outcome."""

    def __init__(self):
        self.session_id = None
        self.result = None          # the `result` record's body, once seen
        self.reply = None           # the last non-empty agent_response step's text
        self.steps = {}             # step_index -> the text its agent_response streamed
        self.error = None           # an error_message step has no text of its own: the result's `error` is the message
        self.rate_limit = None      # agy streams no quota meter (the windows are agy -p /usage): the limit that ended the turn
        self.retry = None           # agy's own in-turn retries print no event: never set
        self.no_conversation = False   # a lost conversation is started afresh by agy itself: never set

    def feed(self, ev):
        if not isinstance(ev, dict):
            return
        kind = ev.get("event")
        if kind == "init":
            self._conversation(ev.get("conversation_id"))
        elif kind == "step_update" and isinstance(ev.get("step_update"), dict):
            su = ev["step_update"]
            self._conversation(su.get("conversation_id"))
            if su.get("step_type") == "agent_response" and isinstance(su.get("text_delta"), str):
                idx = su.get("step_index")
                self.steps[idx] = self.steps.get(idx, "") + su["text_delta"]
                text = self.steps[idx].strip()
                if text:
                    self.reply = text
        elif kind == "result" and isinstance(ev.get("result"), dict):
            self.result = ev["result"]
            self._conversation(self.result.get("conversation_id"))
            # `response` is every agent_response of the turn joined (a turn the Stop hook re-fed answers twice:
            # "PONG\nPONG\n"): the reply is the last step's own text, `response` only where no step streamed one.
            if self.reply is None and isinstance(self.result.get("response"), str) and self.result["response"].strip():
                self.reply = self.result["response"].strip()
            if isinstance(self.result.get("error"), str) and self.result["error"].strip():
                self.error = self.result["error"].strip()

    def _conversation(self, cid):
        if isinstance(cid, str) and cid:
            self.session_id = cid

    def outcome(self, rc, stderr_tail=""):
        """(state, reply, error, limit_resets_at) for the turn once its process exited with <rc>."""
        r = self.result
        if r is not None and r.get("status") == "SUCCESS" and not rc:
            return "idle", self.reply, None, None
        if r is None:
            why = f"agy exited {rc} with no result record"
            error = f"{why}: {stderr_tail}" if stderr_tail else why
        else:
            error = self.error or stderr_tail or f"agy exited {rc}: result {r.get('status')}"
        # A quota that is out is the account's, whatever else the turn printed: the lane waits for it.
        if LIMIT_RE.search(error) or LIMIT_RE.search(stderr_tail or ""):
            secs = resets_in(error) or resets_in(stderr_tail)
            self.rate_limit = {"status": "rejected", "message": error}
            return "limit", self.reply, error, int(time.time()) + secs if secs else None
        return "transient", self.reply, error, None


# --- showing an event to `watch` ----------------------------------------------------------------
def watch_line(ev):
    """One events.jsonl event as `harness attach` prints it; None for the ones it leaves out. The agent's
    narration streams in deltas, so what shows is each tool call and the turn's final answer."""
    if ev.get("type") == "harness":
        return core.harness_watch_line(ev)
    kind = ev.get("event")
    if kind == "step_update" and isinstance(ev.get("step_update"), dict):
        su = ev["step_update"]
        if su.get("step_type") == "tool" and su.get("state") == "ACTIVE":
            info = su.get("tool_info") if isinstance(su.get("tool_info"), dict) else {}
            params = info.get("parameters") if isinstance(info.get("parameters"), dict) else {}
            arg = (params.get("CommandLine") or params.get("AbsolutePath") or params.get("TargetFile")
                   or params.get("Pattern") or params.get("Query") or params.get("Url") or "")
            arg = str(arg).splitlines()[0][:160] if arg else ""
            return f"· {su.get('tool_name')} {arg}".rstrip()
    elif kind == "result" and isinstance(ev.get("result"), dict):
        r = ev["result"]
        if r.get("status") == "SUCCESS":
            return str(r.get("response") or "").strip() or None
        return f"· error: {r.get('error') or r.get('status')}"
    return None


# --- the adapter --------------------------------------------------------------------------------
class AgyAdapter:
    """The contract the core runs a CLI through (docs/reference.md, "Headless adapter contract")."""
    name = "agy"

    @property
    def default_bin(self):
        return os.environ.get("HARNESS_AGY_BIN") or "agy"

    def account(self):
        """agy has one signed-in account per machine and no config-dir switch: its windows are the machine's."""
        return "default"

    def argv(self, bin_, session_id, session_started, model, effort, flags):
        """One turn's command (the message goes on its stdin as a stream-json user line, `stdin_payload`).
        The first turn of a new conversation names none, agy picks its own id; every later one continues it
        with --conversation. `-p=` is print mode with the prompt left to stdin."""
        a = list(bin_) + ["--input-format", "stream-json", "--output-format", "stream-json", "-p="]
        if session_id and session_started:
            a += ["--conversation", session_id]
        if model:
            a += ["--model", model]
        if effort:
            a += ["--effort", effort]
        return a + list(flags)

    def stdin_payload(self, text):
        """The message as agy's stream input takes it: one JSON line, event `user`, the text as its content."""
        return json.dumps({"event": "user", "message": {"content": text}}, ensure_ascii=False) + "\n"

    def new_turn(self):
        return Turn()

    watch_line = staticmethod(watch_line)


ADAPTER = AgyAdapter()


class Runner(core.Runner):
    def __init__(self, *a, **kw):
        super().__init__(ADAPTER, *a, **kw)


def classify(events, rc=0, stderr_tail=""):
    """The outcome of an agy turn that printed <events> and exited <rc>."""
    turn = ADAPTER.new_turn()
    for ev in events:
        turn.feed(ev)
    return turn.outcome(rc, stderr_tail)


def main(argv=None):
    return core.main(argv, adapter=ADAPTER, prog="agy_headless.py")


if __name__ == "__main__":
    sys.exit(main())

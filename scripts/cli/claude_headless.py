#!/usr/bin/env python3
"""claude_headless.py — the headless lane runner for `claude` (#347, PRD #344): the claude ADAPTER on the
shared core (headless_core.py, #480) and the entry point the claude lane runs.

Each turn is one `claude -p --output-format stream-json --verbose` process in the lane's worktree; every
turn after the first passes `--resume <session id>`, so the lane is ONE claude session across turns. The
lane files (inbox.jsonl, events.jsonl, stderr.log, state.json, stop, interrupt), the states, interrupt,
stop and the pane the watchdog reads are the core's — see headless_core.py. This file holds only what is
claude's: how a turn is started, how its stream-json is read, and how an event is shown to `watch`.

  claude_headless.py run   --lane <dir> --cwd <wd> [--bin <claude command>] [--session-id <id> [--resume]]
                           [--model <m>] [--effort <e>] [--flags="<extra claude flags>"]
                           [--message <first message>]
  claude_headless.py send | state | stop | interrupt | pane | watch     # the core's, unchanged

A new CLI's adapter is a file like this one, scripts/cli/<cli>_headless.py: docs/reference.md, "Headless
adapter contract".
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the core sits beside this file
import headless_core as core
# The lane protocol and the screen, re-exported: tests and the session backend name them here.
from headless_core import (paths, read_state, write_json_atomic, send, read_inbox, undelivered, pane,
                           kill_tree, spawn, utf8_stdio, WINDOWS, POLL_S)


# --- reading a turn's events --------------------------------------------------------------------
class Turn:
    """Folds one turn's stream-json events into its outcome."""

    def __init__(self):
        self.session_id = None
        self.result = None          # the `result` event, once seen
        self.rejected = None        # rate_limit_info of a `rejected` rate_limit_event
        self.rate_limit = None      # the latest rate_limit_info
        self.retry = None           # the latest api_retry, while claude retries
        self.no_conversation = False  # claude had no session to --resume (#350)

    def feed(self, ev):
        if not isinstance(ev, dict):
            return
        if isinstance(ev.get("session_id"), str) and ev["session_id"]:
            self.session_id = ev["session_id"]
        t = ev.get("type")
        if t == "rate_limit_event":
            info = ev.get("rate_limit_info") or {}
            self.rate_limit = info
            if info.get("status") == "rejected":
                self.rejected = info
        elif t == "system" and ev.get("subtype") == "api_retry":
            self.retry = {k: ev.get(k) for k in ("attempt", "max_retries", "error_status", "error", "retry_delay_ms")}
        elif t == "result":
            self.result = ev
            errs = ev.get("errors") if isinstance(ev.get("errors"), list) else []
            self.no_conversation = any("No conversation found" in str(e) for e in errs)

    def outcome(self, rc, stderr_tail=""):
        """(state, reply, error, limit_resets_at) for the turn once its process exited with <rc>."""
        r = self.result
        if r is None:
            why = f"claude exited {rc} with no result event"
            return "transient", None, f"{why}: {stderr_tail}" if stderr_tail else why, None
        reply = r.get("result") if isinstance(r.get("result"), str) else None
        if not r.get("is_error") and r.get("subtype", "success") == "success":
            return "idle", reply, None, None
        error = reply or r.get("subtype") or "error"
        if r.get("api_error") == "usage_limit_reached" or self.rejected is not None:
            return "limit", reply, error, (self.rejected or {}).get("resetsAt")
        return "transient", reply, error, None


# --- showing an event to `watch` ----------------------------------------------------------------
def watch_line(ev):
    """One events.jsonl event as `harness attach` prints it; None for the ones it leaves out."""
    t, sub = ev.get("type"), ev.get("subtype")
    if t == "harness":
        return core.harness_watch_line(ev)
    if t == "assistant":
        parts = []
        for c in (ev.get("message") or {}).get("content") or []:
            if c.get("type") == "text" and c.get("text", "").strip():
                parts.append(c["text"].strip())
            elif c.get("type") == "tool_use":
                inp = c.get("input") or {}
                arg = inp.get("command") or inp.get("file_path") or inp.get("description") or ""
                parts.append(f"· {c.get('name')} {str(arg).splitlines()[0][:160] if arg else ''}".rstrip())
        return "\n".join(parts) or None
    if t == "system" and sub == "api_retry":
        return f"· API retry {ev.get('attempt')}/{ev.get('max_retries')} ({ev.get('error_status')})"
    if t == "rate_limit_event" and (ev.get("rate_limit_info") or {}).get("status") == "rejected":
        return "· usage limit reached"
    if t == "result":
        return f"← {ev.get('result')}" if isinstance(ev.get("result"), str) else None
    return None


# --- the adapter --------------------------------------------------------------------------------
class ClaudeAdapter:
    """The contract the core runs a CLI through (docs/reference.md, "Headless adapter contract")."""
    name = "claude"

    @property
    def default_bin(self):
        return os.environ.get("HARNESS_CLAUDE_BIN") or "claude"

    def account(self):
        """The account the lane runs on: its config dir's name, as usage-statusline.sh names a pane's (#352)."""
        return os.path.basename((os.environ.get("CLAUDE_CONFIG_DIR") or "default").rstrip("/\\")) or "default"

    def argv(self, bin_, session_id, session_started, model, effort, flags):
        """One turn's command (the message goes on its stdin). The first turn of a new session names the
        id, every later one resumes it."""
        a = list(bin_) + ["-p", "--output-format", "stream-json", "--verbose"]
        if session_id:
            a += ["--resume", session_id] if session_started else ["--session-id", session_id]
        if model:
            a += ["--model", model]
        if effort:
            a += ["--effort", effort]
        return a + list(flags)

    def new_turn(self):
        return Turn()

    watch_line = staticmethod(watch_line)


ADAPTER = ClaudeAdapter()


class Runner(core.Runner):
    def __init__(self, *a, **kw):
        super().__init__(ADAPTER, *a, **kw)


def classify(events, rc=0):
    """The outcome of a claude turn that printed <events> and exited <rc>."""
    return core.classify(ADAPTER, events, rc)


def main(argv=None):
    return core.main(argv, adapter=ADAPTER, prog="claude_headless.py")


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""codex_headless.py — the headless lane runner for `codex` (#481, PRD #475): the codex ADAPTER on the shared
core (headless_core.py, #480) and the entry point the codex lane runs.

Each turn is one `codex exec --json` process in the lane's worktree; every turn after the first is
`codex exec resume <thread id>`, so the lane is ONE codex thread across turns. Codex names its own thread
(a UUIDv7): the first turn's `thread.started` event carries it, and the core saves it as the lane's session
id. The lane files, the states, interrupt, stop and the pane the watchdog reads are the core's — see
headless_core.py. This file holds only what is codex's: how a turn is started, how its JSONL is read, and
how an event is shown to `watch`.

  codex_headless.py run   --lane <dir> --cwd <wd> [--bin <codex command>] [--session-id <id> [--resume]]
                          [--model <m>] [--effort <e>] [--flags="<extra codex flags>"]
                          [--message <first message>]
  codex_headless.py send | state | stop | interrupt | pane | watch     # the core's, unchanged

The stream (test/fixtures/cli/codex/stream-json/README.md): `thread.started`, `turn.started`, `item.*`,
`error`, then `turn.completed` (with the turn's `usage`) or `turn.failed`. It carries no rate-limit
windows: those are in the rollout codex writes under $CODEX_HOME/sessions for every `exec` turn, which
`codex_limit_usage` (scripts/cli/codex.sh) reads as it does for a pane. A usage limit ends the turn with
`turn.failed` and the message "You've hit your usage limit. … try again at <date>".
"""
import os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the core sits beside this file
import headless_core as core

# `Reconnecting... 2/5 (…)`: codex's own retry of a failed request, printed as an `error` event.
RECONNECT = re.compile(r"Reconnecting\.\.\.\s*(\d+)\s*/\s*(\d+)")
LIMIT = re.compile(r"hit your usage limit|usage limit reached", re.I)
# "…, or try again at Nov 18th, 2026 3:21 PM." — the account's local time, as codex prints it.
RESET_AT = re.compile(r"try again at ([A-Z][a-z]{2})[a-z]* (\d{1,2})(?:st|nd|rd|th)?, (\d{4}) (\d{1,2}):(\d{2}) ?([AP]M)")
NO_THREAD = "no rollout found for thread id"   # codex had no thread to `exec resume` (stderr, no event)


def limit_resets_at(message):
    """The epoch second a usage-limit message says the account can be used again; None when it names none."""
    m = RESET_AT.search(message or "")
    if not m:
        return None
    mon, day, year, hh, mm, ap = m.groups()
    try:
        t = time.strptime(f"{mon} {day} {year} {hh}:{mm} {ap}", "%b %d %Y %I:%M %p")
        return int(time.mktime(t))
    except (ValueError, OverflowError):
        return None


# --- reading a turn's events --------------------------------------------------------------------
class Turn:
    """Folds one turn's `codex exec --json` events into its outcome."""

    def __init__(self):
        self.session_id = None
        self.reply = None           # the last agent_message of the turn
        self.completed = None       # the `turn.completed` event, once seen
        self.failed = None          # the message of `turn.failed`, once seen
        self.error = None           # the latest `error` event's message
        self.rate_limit = None      # what the turn reported about usage / the limit
        self.retry = None           # codex's own reconnect, while it retries
        self.no_conversation = False  # codex had no thread to resume (#350)

    def feed(self, ev):
        if not isinstance(ev, dict):
            return
        t = ev.get("type")
        if t == "thread.started" and isinstance(ev.get("thread_id"), str) and ev["thread_id"]:
            self.session_id = ev["thread_id"]
        elif t == "item.completed":
            item = ev.get("item") or {}
            if item.get("type") == "agent_message" and isinstance(item.get("text"), str):
                self.reply = item["text"]
        elif t == "error":
            msg = ev.get("message") if isinstance(ev.get("message"), str) else ""
            self.error = msg
            m = RECONNECT.search(msg)
            if m:
                self.retry = {"attempt": int(m.group(1)), "max_retries": int(m.group(2)), "error": msg}
        elif t == "turn.completed":
            self.completed = ev
            self.retry = None
            self.rate_limit = {"status": "allowed", "usage": ev.get("usage") or {}}
        elif t == "turn.failed":
            err = ev.get("error")
            self.failed = (err.get("message") if isinstance(err, dict) else err) or self.error or "turn failed"
            self.retry = None
            if LIMIT.search(str(self.failed)):
                self.rate_limit = {"status": "rejected", "message": str(self.failed),
                                   "resetsAt": limit_resets_at(str(self.failed))}

    def outcome(self, rc, stderr_tail=""):
        """(state, reply, error, limit_resets_at) for the turn once its process exited with <rc>."""
        if self.failed is not None:
            msg = str(self.failed)
            if LIMIT.search(msg):
                return "limit", self.reply, msg, limit_resets_at(msg)
            return "transient", self.reply, msg, None
        if self.completed is not None:
            return "idle", self.reply, None, None
        if NO_THREAD in (stderr_tail or ""):
            self.no_conversation = True
            return "transient", None, stderr_tail, None
        why = f"codex exited {rc} with no turn.completed event"
        return "transient", self.reply, f"{why}: {stderr_tail}" if stderr_tail else why, None


# --- showing an event to `watch` ----------------------------------------------------------------
def watch_line(ev):
    """One events.jsonl event as `harness attach` prints it; None for the ones it leaves out."""
    line = core.harness_watch_line(ev)
    if line is not None or ev.get("type") == "harness":
        return line
    t = ev.get("type")
    if t == "item.completed":
        item = ev.get("item") or {}
        kind = item.get("type")
        if kind == "agent_message" and str(item.get("text", "")).strip():
            return str(item["text"]).strip()
        if kind == "command_execution":
            cmd = str(item.get("command") or "").splitlines()
            return f"· $ {cmd[0][:160]}" if cmd else None
        if kind == "file_change":
            return "· file change " + ", ".join(str(c.get("path")) for c in item.get("changes") or [] if isinstance(c, dict))[:160]
        if kind == "mcp_tool_call":
            return f"· {item.get('server')}.{item.get('tool')}"
        if kind == "web_search":
            return f"· web search {item.get('query', '')}".rstrip()
        return None
    if t == "error" and RECONNECT.search(str(ev.get("message"))):
        m = RECONNECT.search(ev["message"])
        return f"· reconnecting {m.group(1)}/{m.group(2)}"
    if t == "turn.failed":
        err = ev.get("error")
        msg = err.get("message") if isinstance(err, dict) else err
        return "· usage limit reached" if LIMIT.search(str(msg)) else f"· turn failed: {str(msg)[:200]}"
    return None


# --- the adapter --------------------------------------------------------------------------------
class CodexAdapter:
    """The contract the core runs a CLI through (docs/reference.md, "Headless adapter contract")."""
    name = "codex"

    @property
    def default_bin(self):
        return os.environ.get("HARNESS_CODEX_BIN") or "codex"

    def account(self):
        """The account's rate-limit id: the `limit_id` of the rollout windows codex_limit_usage reports."""
        return "codex"

    def argv(self, bin_, session_id, session_started, model, effort, flags):
        """One turn's command (the message goes on its stdin: the trailing `-`). Codex names its own
        thread, so a new session starts with no id and every later turn resumes the one the first
        reported."""
        a = list(bin_) + ["exec"] + (["resume"] if session_started and session_id else [])
        a += ["--json", "--skip-git-repo-check"]
        if model:
            a += ["-m", model]
        if effort:
            a += ["-c", f"model_reasoning_effort={effort}"]
        a += list(flags)
        if session_started and session_id:
            a.append(session_id)
        return a + ["-"]

    def new_turn(self):
        return Turn()

    watch_line = staticmethod(watch_line)


ADAPTER = CodexAdapter()


class Runner(core.Runner):
    def __init__(self, *a, **kw):
        super().__init__(ADAPTER, *a, **kw)


def classify(events, rc=0):
    """The outcome of a codex turn that printed <events> and exited <rc>."""
    return core.classify(ADAPTER, events, rc)


def main(argv=None):
    return core.main(argv, adapter=ADAPTER, prog="codex_headless.py")


if __name__ == "__main__":
    sys.exit(main())

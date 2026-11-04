#!/usr/bin/env python3
"""opencode_headless.py — the headless lane runner for `opencode` (#482, PRD #475): the opencode ADAPTER on
the shared core (headless_core.py, #480) and the entry point an opencode lane runs.

Each turn is one `opencode run --format json` process in the lane's worktree (OpenCode 1.x), the message on
its stdin. OpenCode names its own sessions (`ses_…`): the first turn passes none, the id arrives on its
first event, and every later turn passes `--session <id>`, so the lane is ONE opencode session across
turns. The lane files, states, interrupt, stop and the pane the watchdog reads are the core's; this file
holds only what is opencode's: how a turn is started, how its JSON events are read, how an event is shown
to `watch`.

  opencode_headless.py run   --lane <dir> --cwd <wd> [--bin <opencode command>] [--session-id <id> [--resume]]
                             [--effort <variant>] [--flags="<extra opencode run flags>"] [--message <first message>]
  opencode_headless.py send | state | stop | interrupt | pane | watch     # the core's, unchanged

What `opencode run --format json` prints (test/fixtures/cli/opencode/run-json/): one JSON event per line,
`step_start`, `tool_use` (a finished tool call), `text` (a finished text part), `step_finish` (`reason`:
`tool-calls` while the turn goes on, `stop` when it is done; `tokens`), and `error` (`error.name`,
`error.data`). Each carries `sessionID`. The reply is the text of the turn's last message. OpenCode retries
a failed model call itself (five times); an `error` event is what is left once it gave up, and the process
exits 1 after it. There is no quota meter (the matrix's usage-windows row is n/a): a limit shows only as
the provider's error, so `rate_limit` is never set. A session id that does not exist ends in no JSON at
all, `Error: Session not found` on stderr and exit 1.
"""
import json, os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the core sits beside this file
import headless_core as core
from headless_core import (paths, read_state, write_json_atomic, send, read_inbox, undelivered, pane,
                           kill_tree, spawn, utf8_stdio, WINDOWS, POLL_S)

# An error that is the account's quota, not a passing fault: the wordings OpenCode and the providers use
# (test/fixtures/cli/opencode/README.md, `limit.txt`): OpenAI's insufficient_quota, OpenCode Zen's
# FreeUsageLimitError / GoUsageLimitError ("<limit> usage limit reached. It will reset in …", "Free usage
# exceeded, subscribe to Go").
LIMIT_RE = re.compile(r"insufficient_quota|exceeded your current quota|usage limit reached|Free usage (exceeded|limit)"
                      r"|FreeUsageLimitError|GoUsageLimitError|Quota exceeded", re.I)
RESET_IN_RE = re.compile(r"reset in (\d+) (second|minute|hour|day)", re.I)
UNIT_S = {"second": 1, "minute": 60, "hour": 3600, "day": 86400}


# --- reading a turn's events --------------------------------------------------------------------
class Turn:
    """Folds one turn's `opencode run --format json` events into its outcome."""

    def __init__(self):
        self.session_id = None
        self.rate_limit = None      # OpenCode has no quota meter: never set
        self.retry = None           # OpenCode's own retries are not in the stream: never set
        self.no_conversation = False   # opencode had no session to --session (#350)
        self.finished = None        # the reason of the last step_finish (`stop` ends a turn)
        self.error = None           # the `error` event's error object, once seen
        self.texts = {}             # message id -> its text parts, in order
        self.last_text = None       # the message id of the latest text part
        self.tokens = {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0}

    def feed(self, ev):
        if not isinstance(ev, dict):
            return
        if isinstance(ev.get("sessionID"), str) and ev["sessionID"]:
            self.session_id = ev["sessionID"]
        t, part = ev.get("type"), ev.get("part") if isinstance(ev.get("part"), dict) else {}
        if t == "text" and isinstance(part.get("text"), str):
            mid = part.get("messageID") or ""
            self.texts.setdefault(mid, []).append(part["text"])
            self.last_text = mid
        elif t == "step_finish":
            self.finished = part.get("reason") or "stop"
            k = part.get("tokens") if isinstance(part.get("tokens"), dict) else {}
            cache = k.get("cache") if isinstance(k.get("cache"), dict) else {}
            for key, val in (("input", k.get("input")), ("output", k.get("output")), ("reasoning", k.get("reasoning")),
                             ("cache_read", cache.get("read")), ("cache_write", cache.get("write"))):
                self.tokens[key] += int(val or 0)
        elif t == "error":
            self.error = ev.get("error") if isinstance(ev.get("error"), dict) else {"data": {"message": str(ev.get("error"))}}

    @property
    def reply(self):
        """The text of the turn's last message that had any."""
        if self.last_text is None:
            return None
        return "".join(self.texts.get(self.last_text, [])).strip() or None

    def error_text(self):
        e = self.error or {}
        d = e.get("data") if isinstance(e.get("data"), dict) else {}
        return str(d.get("message") or e.get("message") or e.get("name") or "error")

    def is_limit(self):
        e = self.error or {}
        d = e.get("data") if isinstance(e.get("data"), dict) else {}
        return bool(LIMIT_RE.search(" ".join(str(x) for x in (e.get("name"), d.get("message"), d.get("responseBody")))))

    def resets_at(self, text):
        """When a limit lifts (epoch seconds), as far as the error says: the provider's own "It will reset in 1
        minute", else the seconds of the response's retry-after header; None when it says neither."""
        m = RESET_IN_RE.search(text)
        if m:
            return int(time.time()) + int(m.group(1)) * UNIT_S[m.group(2).lower()]
        d = (self.error or {}).get("data")
        h = d.get("responseHeaders") if isinstance(d, dict) and isinstance(d.get("responseHeaders"), dict) else {}
        after = str(h.get("retry-after", "")).strip()
        return int(time.time()) + int(after) if after.isdigit() and int(after) > 0 else None

    def outcome(self, rc, stderr_tail=""):
        """(state, reply, error, limit_resets_at) for the turn once its process exited with <rc>."""
        if self.error is not None:
            text = self.error_text()
            if self.is_limit():
                return "limit", self.reply, text, self.resets_at(text)
            return "transient", self.reply, text, None
        if self.finished == "stop" and rc == 0:
            return "idle", self.reply, None, None
        tail = re.sub(r"\x1b\[[0-9;]*m", "", stderr_tail or "").strip()
        self.no_conversation = "Session not found" in tail
        why = f"opencode exited {rc} with no finished step"
        return "transient", self.reply, f"{why}: {tail}" if tail else why, None


# --- showing an event to `watch` ----------------------------------------------------------------
def watch_line(ev):
    """One events.jsonl event as `harness attach` prints it; None for the ones it leaves out."""
    if ev.get("type") == "harness":
        return core.harness_watch_line(ev)
    t, part = ev.get("type"), ev.get("part") if isinstance(ev.get("part"), dict) else {}
    if t == "text" and str(part.get("text", "")).strip():
        return part["text"].strip()
    if t == "tool_use":
        inp = (part.get("state") or {}).get("input") or {}
        arg = inp.get("command") or inp.get("filePath") or inp.get("pattern") or inp.get("description") or ""
        return f"· {part.get('tool')} {str(arg).splitlines()[0][:160] if arg else ''}".rstrip()
    if t == "error":
        turn = Turn()
        turn.feed(ev)
        return f"· error: {turn.error_text()}"
    return None


# --- the adapter --------------------------------------------------------------------------------
class OpencodeAdapter:
    """The contract the core runs a CLI through (docs/reference.md, "Headless adapter contract")."""
    name = "opencode"

    @property
    def default_bin(self):
        return os.environ.get("HARNESS_OPENCODE_BIN") or "opencode"

    def account(self):
        """OpenCode has one local store and no account switcher: its usage is never read off the lane."""
        return "default"

    def argv(self, bin_, session_id, session_started, model, effort, flags):
        """One turn's command (the message goes on its stdin). The first turn of a new session names none,
        OpenCode picks its own id; every later one continues it with --session."""
        a = list(bin_) + ["run", "--format", "json"]
        if session_id and session_started:
            a += ["--session", session_id]
        if model:
            a += ["-m", model]
        if effort:
            a += ["--variant", effort]
        return a + list(flags)

    def env(self, cwd=None):
        """A lane must never stop on a question no one will answer (`permission.question: deny`, merged above
        the project's own config, as the pane launch's inline config does), and never swap the CLI under a
        running fleet."""
        return {"OPENCODE_CONFIG_CONTENT": json.dumps({"permission": {"question": "deny"}}, separators=(",", ":")),
                "OPENCODE_DISABLE_AUTOUPDATE": "1"}

    def new_turn(self):
        return Turn()

    watch_line = staticmethod(watch_line)


ADAPTER = OpencodeAdapter()


class Runner(core.Runner):
    def __init__(self, *a, **kw):
        super().__init__(ADAPTER, *a, **kw)


def classify(events, rc=0):
    """The outcome of an opencode turn that printed <events> and exited <rc>."""
    return core.classify(ADAPTER, events, rc)


def main(argv=None):
    return core.main(argv, adapter=ADAPTER, prog="opencode_headless.py")


if __name__ == "__main__":
    sys.exit(main())

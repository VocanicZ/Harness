#!/usr/bin/env python3
"""hermes_headless.py — the headless lane runner for `hermes` (#484, PRD #475): the hermes ADAPTER on the
shared core (headless_core.py, #480) and the entry point a hermes lane runs.

Each turn is one `hermes chat --format stream-json -c <session> --create-if-missing` process in the lane's
worktree (Hermes Agent 0.22), the message on its stdin (`--query-file -`). `-c <title>` names the lane's
session: the first turn creates it, titled with the lane's id, and every later turn continues it, so the lane
is ONE hermes session across turns whatever id the core holds (`-c` takes a title or Hermes's own `local-…`
id, which the first `result` event reports and the core then keeps). The lane's model and effort are not on
the command: Hermes refuses `-m` and `--reasoning` beside `-c … --create-if-missing`, so hermes.sh seeds them
into the lane's profile (`hermes_headless`), which every turn runs in (HERMES_HOME, `env()`) — the same
profile, with its own state.db and config, a tmux hermes lane has (scripts/cli/hermes.sh). The lane files,
states, interrupt, stop and the pane the watchdog reads are the core's; this file holds only what is
hermes's: how a turn is started, how its JSON events are read, how an event is shown to `watch`.

  hermes_headless.py run   --lane <dir> --cwd <wd> [--bin <hermes command>] [--session-id <id> [--resume]]
                           [--flags="<extra hermes chat flags>"] [--message <first message>]
  hermes_headless.py send | state | stop | interrupt | pane | watch     # the core's, unchanged

What `hermes chat --format stream-json` prints (test/fixtures/cli/hermes/stream-json/): one JSON event per
line, `system` (`init`, first), `text` (a delta of the reply), `tool_use` (`name`, `input`), `tool_result`
(`output`, `is_error`) and last a `result` (`session_id`, `exit_code`, `text`: the turn's final reply,
`tokens`, and `error` when the turn failed). A turn that ran ends in a `result` with `exit_code` 0; one whose
model call failed (Hermes retries it itself, a 429 three times) ends in a `result` with `exit_code` 1 and
`error`; one that Hermes could not start at all (a session it does not have) is a `result` with an empty
`session_id` and `error`. Usage windows are not in the stream: `hermes usage --json` reads the provider's
(hermes.sh `hermes_limit_usage`), so `rate_limit` is never set; the session's tokens are read from the lane
profile's state.db when it ends, as for a tmux lane.

A hermes turn outlives its client: its commands run in the host gateway (docs/cli-capabilities.md,
lane environment), so killing the process tree on a stop or an interrupt leaves the turn's command
running. `abort_turn` stops the lane's gateway (`hermes gateway stop -y`, that profile's part only), as
`hermes_kill` does for a tmux lane, and lifts the park that stop leaves on the profile so the next turn can run.
"""
import hashlib, json, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the core sits beside this file
import headless_core as core
from headless_core import (paths, read_state, write_json_atomic, send, read_inbox, undelivered, pane,
                           kill_tree, spawn, utf8_stdio, WINDOWS, POLL_S)

# An error that is the account's quota or credit, not a passing fault: Hermes's wordings
# (test/fixtures/cli/hermes/stream-json/README.md; docs/cli-capabilities.md, hermes "limit string"): a 429 that
# names its reset ("usage limit", "Limit resets at 13:01 (in 2h 00m)"), exhausted credits or billing, and a
# Nous account's quota. A 429 with no reset is the provider's per-minute throttle, as transient as a 503.
LIMIT_RE = re.compile(r"usage limit|limit resets at|rate[- ]limited[^\n]*resets in|billing or credits exhausted"
                      r"|credit exhaustion|insufficient_quota|exceeded your current quota|has hit its rate limit"
                      r"|resets? in ~?\d", re.I)
IN_RE = re.compile(r"\(in (?:(\d+)d )?(?:(\d+)h )?(?:(\d+)m)?\)|resets in ~?(?:(\d+)d ?)?(?:(\d+)h ?)?(?:(\d+)m ?)?(?![\dhdm])", re.I)


def lane_home(cwd):
    """The lane's Hermes home: a profile of the operator's, named for its worktree (hermes.sh `_hermes_home`)."""
    op = os.environ.get("HARNESS_HERMES_HOME") or os.path.join(os.path.expanduser("~"), ".hermes")
    return os.path.join(op, "profiles", "harness" + hashlib.sha1(cwd.encode("utf-8")).hexdigest()[:12])


# --- reading a turn's events --------------------------------------------------------------------
class Turn:
    """Folds one turn's `hermes chat --format stream-json` events into its outcome."""

    def __init__(self):
        self.session_id = None
        self.rate_limit = None      # Hermes reports no window in the stream: never set
        self.retry = None           # Hermes's own retries are not in the stream: never set
        self.no_conversation = False   # never: `-c … --create-if-missing` makes the session it lacks
        self.result = None          # the `result` event, once seen
        self.said = []              # text deltas since the turn's last tool call: the reply if there is no result
        self.tokens = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0}

    def feed(self, ev):
        if not isinstance(ev, dict):
            return
        t = ev.get("type")
        if t == "text" and isinstance(ev.get("text"), str):
            self.said.append(ev["text"])
        elif t == "tool_use":
            self.said = []
        elif t == "result":
            self.result = ev
            if isinstance(ev.get("session_id"), str) and ev["session_id"]:
                self.session_id = ev["session_id"]
            k = ev.get("tokens") if isinstance(ev.get("tokens"), dict) else {}
            for key in self.tokens:
                self.tokens[key] += int(k.get(key) or 0)

    @property
    def reply(self):
        """The turn's final reply: the `result`'s text, else the text said since its last tool call."""
        text = (self.result or {}).get("text") if self.result else None
        text = text if isinstance(text, str) else "".join(self.said)
        return text.strip() or None

    def error_text(self):
        e = (self.result or {}).get("error")
        return str(e) if e else self.reply or "error"

    def is_limit(self):
        r = self.result or {}
        return bool(LIMIT_RE.search(" ".join(str(x) for x in (r.get("error"), r.get("text")) if x)))

    def resets_at(self):
        """When a limit lifts (epoch seconds), as far as the turn says: "Limit resets at 07:54 (in 2h 00m)" or
        "resets in ~2h"; None when it says neither."""
        r = self.result or {}
        for text in (r.get("text"), r.get("error")):
            for m in IN_RE.finditer(str(text or "")):
                d, h, mi = (int(x or 0) for x in (m.group(1) or m.group(4), m.group(2) or m.group(5), m.group(3) or m.group(6)))
                if d or h or mi:
                    return int(time.time()) + d * 86400 + h * 3600 + mi * 60
        return None

    def outcome(self, rc, stderr_tail=""):
        """(state, reply, error, limit_resets_at) for the turn once its process exited with <rc>."""
        r = self.result
        if r is not None:
            failed = r.get("error") or r.get("exit_code") not in (0, None)
            if not failed:
                return "idle", self.reply, None, None
            if self.is_limit():
                return "limit", None, self.error_text(), self.resets_at()
            return "transient", None, self.error_text(), None
        tail = re.sub(r"\x1b\[[0-9;]*m", "", stderr_tail or "").strip()
        why = f"hermes exited {rc} with no result"
        return "transient", self.reply, f"{why}: {tail}" if tail else why, None


# --- showing an event to `watch` ----------------------------------------------------------------
def watch_line(ev):
    """One events.jsonl event as `harness attach` prints it; None for the ones it leaves out."""
    if ev.get("type") == "harness":
        return core.harness_watch_line(ev)
    t = ev.get("type")
    if t == "result":
        text = str(ev.get("text") or "").strip()
        return f"· error: {ev['error']}" if ev.get("error") else (text or None)
    if t == "tool_use":
        inp = ev.get("input") if isinstance(ev.get("input"), dict) else {}
        arg = inp.get("command") or inp.get("path") or inp.get("file_path") or inp.get("pattern") or inp.get("query") or ""
        return f"· {ev.get('name')} {str(arg).splitlines()[0][:160] if arg else ''}".rstrip()
    return None   # `text` is a delta (the `result` carries the whole reply), `system` and `tool_result` are noise


# --- the adapter --------------------------------------------------------------------------------
class HermesAdapter:
    """The contract the core runs a CLI through (docs/reference.md, "Headless adapter contract")."""
    name = "hermes"

    @property
    def default_bin(self):
        return os.environ.get("HARNESS_HERMES_BIN") or "hermes"

    def account(self):
        """A lane's usage windows are the provider's, read by `hermes usage --json` in the newest lane profile:
        never off the lane's own state."""
        return "default"

    def argv(self, bin_, session_id, session_started, model, effort, flags):
        """One turn's command (the message goes on its stdin). Every turn names the session the same way,
        `-c <session> --create-if-missing`: the first creates it under the lane's id, each later one (and a
        relaunched lane's first, which names Hermes's own id) finds it. Model and effort are the lane
        profile's config, not flags (Hermes refuses them beside -c). --yolo and --accept-hooks: nobody is
        there to approve a command or a hook."""
        a = list(bin_) + ["chat", "--format", "stream-json", "--yolo", "--accept-hooks"]
        if session_id:
            a += ["-c", session_id, "--create-if-missing"]
        return a + list(flags) + ["--query-file", "-"]

    def env(self, cwd):
        """The turn runs in the lane's profile (hermes.sh seeded it), found from the worktree as hermes.sh
        names it."""
        return {"HERMES_HOME": lane_home(cwd)}

    def abort_turn(self, bin_, cwd):
        """Stop the lane's gateway: the turn's command is the gateway's, and it outlived the killed client. The stop
        also parks the profile (`gateway.parked`), and a parked profile's next `chat` waits 60 s and fails
        (`Gateway starting: deadline`): an interrupted lane goes on, so the park is lifted again."""
        home = lane_home(cwd)
        try:
            subprocess.run(list(bin_) + ["gateway", "stop", "-y"], cwd=cwd, env={**os.environ, "HERMES_HOME": home},
                           timeout=60, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError):
            pass
        try:
            os.unlink(os.path.join(home, "gateway.parked"))
        except OSError:
            pass

    def new_turn(self):
        return Turn()

    watch_line = staticmethod(watch_line)


ADAPTER = HermesAdapter()


class Runner(core.Runner):
    def __init__(self, *a, **kw):
        super().__init__(ADAPTER, *a, **kw)


def classify(events, rc=0):
    """The outcome of a hermes turn that printed <events> and exited <rc>."""
    return core.classify(ADAPTER, events, rc)


def main(argv=None):
    return core.main(argv, adapter=ADAPTER, prog="hermes_headless.py")


if __name__ == "__main__":
    sys.exit(main())

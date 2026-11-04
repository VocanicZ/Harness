#!/usr/bin/env python3
"""openclaw_headless.py — the headless lane runner for `openclaw` (#485, PRD #475): the openclaw ADAPTER on the
shared core (headless_core.py, #480) and the entry point an openclaw lane runs.

Each turn is one `openclaw agent exec --json --message-file -` process (OpenClaw 2026.10), the message on its
stdin, run on the lane's own config (--config: the operator's config included, `tools.exec.mode` full, the user
skill dirs: openclaw.sh `_openclaw_config`, the same one a tmux lane's loop runs on), with the worktree as
--cwd and the lane's `<wd>/.harness-openclaw` as --state-dir. openclaw.sh passes those, and --timeout, as the
runner's --flags. `agent exec` has no resume id: every turn is its own isolated OpenClaw session, and the lane
is Harness's — its id (the launch's, what the stats sweep and a relaunched lane look the lane up by) stays the
lane's whatever `sessionId` an envelope carries, and each turn's envelope is appended to
`<state-dir>/runs/<lane id>.jsonl`, the transcript a tmux lane's loop (openclaw-loop.sh) writes, which
`openclaw_transcripts` / `openclaw_usage` read for the stats sweep. The lane files, states, interrupt, stop and
the pane the watchdog reads are the core's; this file holds only what is openclaw's: how a turn is started, how
its envelope is read, how it is shown to `watch`.

  openclaw_headless.py run   --lane <dir> --cwd <wd> [--bin <openclaw command>] [--session-id <id> [--resume]]
                             [--model <provider/model>] [--effort <thinking level>] [--flags="<agent exec flags>"]
                             [--message <first message>]
  openclaw_headless.py send | state | stop | interrupt | pane | watch     # the core's, unchanged

What `openclaw agent exec --json` prints (test/fixtures/cli/openclaw/agent-json/): ONE pretty-printed JSON
document on stdout when the turn ends, no stream — the stable agent-exec envelope: `ok`, `status` (`ok` or
`error`), `final` (the reply), `payloads`, `usage` (`input`, `output`, `cacheRead`, `cacheWrite`), `toolSummary`,
`model`, `provider`, `sessionId`, and for a failed turn `error` (`message`, `kind`). The adapter sets
`json_documents`, so the core reads the envelope whole. OpenClaw retries a failed model call itself (a 503 seven
times, a plain 429 ten, over minutes); the `error` is what is left once it gave up, and the process exits 1. A
limit is the provider's own message when it names one (`⚠️ You have reached your usage limit for this period.;
Retry-After: 7200 seconds`) or OpenClaw's copy once its retries give up (`⚠️ The AI service needs a short
break.`, a billing failure's). Usage windows are not in the envelope: `openclaw status --usage --json` reads the
provider's (openclaw.sh `openclaw_limit_usage`), so `rate_limit` is never set.
"""
import json, os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the core sits beside this file
import headless_core as core
from headless_core import (paths, read_state, write_json_atomic, send, read_inbox, undelivered, pane,
                           kill_tree, spawn, utf8_stdio, WINDOWS, POLL_S)

# An error that is the account's quota or billing, not a passing fault: the wordings openclaw.sh's own
# `openclaw_limit_re` reads off a pane (test/fixtures/cli/openclaw/README.md, limit.txt, limit-short-break.txt):
# a provider's usage limit or quota message, OpenClaw's copy once its 429 retries give up, and its billing copy.
LIMIT_RE = re.compile(r"usage limit|quota|The AI service needs a short break|The AI service reported a billing problem", re.I)
RETRY_AFTER_RE = re.compile(r"Retry-After: *(\d+) *seconds?", re.I)


# --- reading a turn's envelope ------------------------------------------------------------------
class Turn:
    """Folds one turn's `openclaw agent exec --json` envelope into its outcome."""

    def __init__(self, adapter=None):
        self.session_id = None      # the lane's own id once an envelope arrives (see the module doc)
        self.rate_limit = None      # the envelope carries no window: never set
        self.retry = None           # OpenClaw's own retries are not reported: never set
        self.no_conversation = False   # every turn is a new isolated session: there is none to lose
        self.adapter = adapter      # names the lane's id and state dir: the core builds the turn before its argv
        self.envelope = None

    def feed(self, ev):
        if not isinstance(ev, dict) or not isinstance(ev.get("ok"), bool):   # a runner marker or stray output
            return
        self.envelope = ev
        lane, state_dir = (self.adapter.lane_session, self.adapter.state_dir) if self.adapter else (None, None)
        self.session_id = lane
        if lane and state_dir:   # the transcript, where the lane's id names the file
            runs = os.path.join(state_dir, "runs", f"{lane}.jsonl")
            try:
                os.makedirs(os.path.dirname(runs), exist_ok=True)
                with open(runs, "a", encoding="utf-8") as f:
                    f.write(json.dumps({**ev, "harness": {"ended": int(time.time())}},
                                       separators=(",", ":"), ensure_ascii=False) + "\n")
            except OSError:
                pass   # a transcript that cannot be written costs the stats sweep this turn's usage, not the turn

    @property
    def reply(self):
        final = (self.envelope or {}).get("final")
        return final.strip() or None if isinstance(final, str) else None

    def error_text(self):
        e = (self.envelope or {}).get("error")
        msg = e.get("message") if isinstance(e, dict) else e
        return str(msg or (self.envelope or {}).get("status") or "error")

    def is_limit(self):
        return bool(LIMIT_RE.search(self.error_text()))

    def resets_at(self):
        """When a limit lifts (epoch seconds), as far as the error says: `Retry-After: 7200 seconds`; None when it
        says nothing (OpenClaw's own `short break` copy)."""
        m = RETRY_AFTER_RE.search(self.error_text())
        return int(time.time()) + int(m.group(1)) if m and int(m.group(1)) > 0 else None

    def outcome(self, rc, stderr_tail=""):
        """(state, reply, error, limit_resets_at) for the turn once its process exited with <rc>."""
        env = self.envelope
        if env is not None:
            if env.get("ok") and env.get("status", "ok") == "ok":
                return "idle", self.reply, None, None
            if self.is_limit():
                return "limit", self.reply, self.error_text(), self.resets_at()
            return "transient", self.reply, self.error_text(), None
        tail = re.sub(r"\x1b\[[0-9;]*m", "", stderr_tail or "").strip()
        why = f"openclaw agent exec exited {rc} with no JSON envelope"
        return "transient", None, f"{why}: {tail}" if tail else why, None


# --- showing an event to `watch` ----------------------------------------------------------------
def watch_line(ev):
    """One events.jsonl event as `harness attach` prints it; None for the ones it leaves out."""
    if ev.get("type") == "harness":
        return core.harness_watch_line(ev)
    if not isinstance(ev.get("ok"), bool):
        return None
    t = Turn()
    t.feed(ev)
    lines = []
    tools = ((ev.get("toolSummary") or {}).get("tools") or []) if isinstance(ev.get("toolSummary"), dict) else []
    if tools:
        lines.append("· tools: " + ", ".join(str(x) for x in tools))
    if t.reply and ev.get("ok"):
        lines.append(t.reply)
    elif not ev.get("ok"):
        lines.append(f"· error: {t.error_text()}")
    return "\n".join(lines) or None


# --- the adapter --------------------------------------------------------------------------------
def operator_config():
    """The operator's OpenClaw config, as openclaw.sh `_openclaw_op_config` names it: what a lane's own includes."""
    return (os.environ.get("HARNESS_OPENCLAW_CONFIG") or os.environ.get("OPENCLAW_CONFIG_PATH")
            or os.path.join(os.environ.get("OPENCLAW_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".openclaw"),
                            "openclaw.json"))


class OpenclawAdapter:
    """The contract the core runs a CLI through (docs/reference.md, "Headless adapter contract")."""
    name = "openclaw"
    json_documents = True       # the turn prints one pretty-printed envelope (headless_core.DocumentReader)

    def __init__(self):
        self.lane_session = None   # the lane's id, as the last argv() was given it
        self.state_dir = None      # the --state-dir that argv's flags name

    @property
    def default_bin(self):
        return os.environ.get("HARNESS_OPENCLAW_BIN") or "openclaw"

    def account(self):
        """OpenClaw has no account switcher: a lane's usage windows are the operator's providers', read by
        `openclaw status --usage --json`, never off the lane's own state."""
        return "default"

    def argv(self, bin_, session_id, session_started, model, effort, flags):
        """One turn's command (the message goes on its stdin, --message-file -). `agent exec` takes no session id:
        a turn is its own session, so every turn's command is the same but for the message. openclaw.sh's flags
        carry the lane's --config, --cwd, --state-dir and --timeout; the lane's model (<provider>/<model>) and
        effort (--thinking) are the runner's own."""
        flags = list(flags)
        self.lane_session = session_id
        self.state_dir = next((flags[i + 1] for i, f in enumerate(flags[:-1]) if f == "--state-dir"), None)
        a = list(bin_) + ["agent", "exec", "--json", "--message-file", "-"]
        if model:
            a += ["--model", model]
        if effort:
            a += ["--thinking", effort]
        return a + flags

    def env(self, cwd=None):
        """The lane's config lives outside the operator's config dir and includes the operator's file, which
        OpenClaw reads only from a root it is told it may (OPENCLAW_INCLUDE_ROOTS), as the pane's launch line says."""
        return {"OPENCLAW_INCLUDE_ROOTS": os.path.dirname(operator_config())}

    def new_turn(self):
        return Turn(self)

    watch_line = staticmethod(watch_line)


ADAPTER = OpenclawAdapter()


class Runner(core.Runner):
    def __init__(self, *a, **kw):
        super().__init__(ADAPTER, *a, **kw)


def classify(events, rc=0):
    """The outcome of an openclaw turn that printed <events> and exited <rc>."""
    return core.classify(ADAPTER, events, rc)


def main(argv=None):
    return core.main(argv, adapter=ADAPTER, prog="openclaw_headless.py")


if __name__ == "__main__":
    sys.exit(main())

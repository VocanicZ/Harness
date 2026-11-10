#!/usr/bin/env python3
"""headless_core.py — the shared headless lane runner (#347, PRD #344; split per-CLI in #480, PRD #475).

The long-running program a headless lane runs in place of a CLI's interactive TUI. The runner is ONE
core plus one small per-CLI adapter (`scripts/cli/<cli>_headless.py`, contract in docs/reference.md
"Headless adapter contract"). The core owns everything a CLI does not change:

  inbox.jsonl   messages for the lane, one JSON object per line (`send` appends them). Each message is
                delivered, in order, as the next turn; one arriving mid-turn waits for that turn to end.
                A non-JSON line is taken as a message of its own text.
  events.jsonl  every JSON event the turn's process printed, one per line, in order, plus the runner's own
                `{"type":"harness","subtype":"turn_start"|"turn_end"|"stdout"|...}` markers.
  stderr.log    the turn process's stderr, appended per turn.
  state.json    what the engine reads, rewritten whole (write + rename) on every change:
                  state         idle | busy | limit | transient | ended — from the adapter's reading of the
                                turn's events and exit (never from screen text). A headless lane has no
                                dialog states (trust, permission).
                  session_id    the CLI session the lane resumes
                  session_started  true once that session exists (every later turn resumes it)
                  turn          turns started so far; turn_started is the running turn's start (epoch)
                                and null when none runs
                  last_reply    the last turn's reply text; error is set when that turn failed
                  limit_resets_at, rate_limit, retry, queued, runner_pid, claude_pid (the running turn's
                  process, whatever the CLI), updated, ...
                  rate_limit is the adapter's latest rate-limit info, rate_limit_at when it last changed,
                  account the config dir the lane runs on (#352: the usage watch reads both),
                  adapter the CLI whose adapter runs the lane (`watch` loads its event formatter)
  stop          a stop request (`stop` writes it). A stop — this file, SIGTERM, SIGHUP or SIGINT — ends
                the running turn's whole process tree, writes state `ended` and exits.
  interrupt     an interrupt request (#349, `interrupt` writes it): ends the RUNNING turn's process tree
                and only that — the file names the turn it is aimed at, so it never ends a later one;
                the turn ends `idle`, `interrupted` counts it (the interrupted turns since
                one last ended on its own), the runner stays up and delivers whatever is queued next. One
                left over from a turn that already ended is dropped.

An ADAPTER starts one turn and reads its stream; the core never names a CLI. It supplies (see ClaudeAdapter
in claude_headless.py for the reference one): `name`, `default_bin`, `account()`, `argv(...)` (one turn's
command, with that CLI's resume id), `new_turn()` (an object that `feed`s events and gives the turn's
`outcome(rc, stderr_tail)`, usage `rate_limit`, `retry` and `no_conversation`), and `watch_line(ev)`. It may
also supply `env(cwd)`: variables set on every turn's process (<cwd> is the lane's worktree), `stdin_payload(text)`: what a turn's
process is sent on stdin for a message (default: the text itself), and `abort_turn(bin, cwd)`: called after the runner kills a
turn's process tree on a stop or an interrupt, for a CLI whose turn outlives its client (hermes: its host
gateway runs the turn's commands). An adapter whose CLI prints one JSON document per turn rather than one
event per line (openclaw's pretty-printed envelope) sets `json_documents = True`: the core then reads stdout
as whole documents (DocumentReader), each one an event.

The headless session backend (scripts/session/headless.sh, #349) runs this program as a lane and reads
the lane through it: `pane` renders state.json and the undelivered inbox as the screen the claude
adapter's pane regexes already read (scripts/cli/claude.sh), and `watch` follows events.jsonl as
`harness attach` shows it.

Portable by construction (ADR 0001): python3 stdlib only, and the core path uses none of /proc, flock
or setsid-only tricks. The one platform branch is kill_tree(): a POSIX process group (plus a `ps`
walk for descendants that left it) on Linux, `taskkill /T /F` on Windows. A runner restarted on the
same lane directory picks up its session id and inbox position from state.json.

A lane relaunched to carry on an earlier one (#350: `harness resume`, the crash-recovery sweep) passes
`--resume` with that session's id: its first turn already resumes the session. If the CLI no longer has
it (another config dir, a cleared ~/.claude), the adapter's turn reports `no_conversation` and the
runner runs the same message again as a new session under the same id, so the lane id never changes.

  <cli>_headless.py run   --lane <dir> --cwd <wd> [--bin <command>] [--session-id <id> [--resume]]
                          [--model <m>] [--effort <e>] [--flags="<extra flags>"]
                          [--message <first message>]
  <cli>_headless.py send  --lane <dir> [--kind <label>] (<message> | -)     # - reads stdin
  <cli>_headless.py state --lane <dir> [--field <name>]
  <cli>_headless.py stop  --lane <dir> [--timeout <s>]
  <cli>_headless.py interrupt --lane <dir>
  <cli>_headless.py pane  --lane <dir>                  # the lane as a claude-shaped screen
  <cli>_headless.py watch --lane <dir> [--lines <n>] [--no-follow]

headless_core.py itself takes the same commands, `run` with `--adapter <cli>` naming the adapter; the
lane-reading ones (state, send, stop, interrupt, pane, watch) need no adapter, so the session backend
calls them here for a lane of any CLI. --lane defaults to $HARNESS_LANE_DIR, which the headless session
backend sets for the lane it starts.
"""
import argparse, json, os, shlex, shutil, signal, subprocess, sys, threading, time

WINDOWS = os.name == "nt"
POLL_S = 0.1


# --- lane files ---------------------------------------------------------------------------------
def paths(lane):
    return {k: os.path.join(lane, f) for k, f in (
        ("inbox", "inbox.jsonl"), ("events", "events.jsonl"), ("stderr", "stderr.log"),
        ("state", "state.json"), ("stop", "stop"), ("interrupt", "interrupt"))}


def flags_model(flags):
    """The model a claude flag list names (`--model X` or `--model=X`), else None."""
    for i, f in enumerate(flags):
        if f.startswith("--model="):
            return f.split("=", 1)[1] or None
        if f == "--model" and i + 1 < len(flags):
            return flags[i + 1]
    return None


def read_state(lane):
    try:
        with open(paths(lane)["state"], encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def write_json_atomic(path, data):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
    for _ in range(50):   # Windows refuses the rename while a reader holds the target open
        try:
            os.replace(tmp, path); return
        except PermissionError:
            time.sleep(0.02)
    os.replace(tmp, path)


def send(lane, text, kind="message"):
    """Append one message to the lane's inbox — a single write of one line, so concurrent senders
    never interleave inside a message."""
    os.makedirs(lane, exist_ok=True)
    line = json.dumps({"text": text, "kind": kind, "at": int(time.time())}, ensure_ascii=False) + "\n"
    with open(paths(lane)["inbox"], "ab") as f:
        f.write(line.encode("utf-8"))


def read_inbox(lane, offset):
    """(messages, new offset): the complete lines of the inbox past <offset>, each message's "_end"
    the offset just past its line. A line still being written (no newline yet) is left for the next
    read."""
    try:
        with open(paths(lane)["inbox"], "rb") as f:
            f.seek(offset); data = f.read()
    except OSError:
        return [], offset
    end = data.rfind(b"\n")
    if end < 0:
        return [], offset
    msgs, pos = [], offset
    for raw in data[:end].split(b"\n"):
        pos += len(raw) + 1
        line = raw.decode("utf-8", errors="replace").rstrip("\r")
        if not line.strip():
            continue
        try:
            d = json.loads(line)
            msg = d if isinstance(d, dict) and isinstance(d.get("text"), str) else {"text": line}
        except ValueError:
            msg = {"text": line}
        msg["_end"] = pos
        msgs.append(msg)
    return msgs, offset + end + 1


# --- reading a turn's events (the adapter's) ---------------------------------------------------
class DocumentReader:
    """Stdout read as JSON documents, not lines (an adapter with `json_documents = True`: openclaw prints one
    pretty-printed envelope per turn). `feed(text)` takes the next piece of stdout and returns the events it
    completed: each whole JSON document is one event, a line that cannot start one is a `stdout` marker, as
    the line reader makes it. `flush()` at the end of stdout turns whatever is left (a document cut short)
    into `stdout` markers."""

    def __init__(self):
        self.pending = ""
        self.decoder = json.JSONDecoder()

    @staticmethod
    def _marker(line):
        return {"type": "harness", "subtype": "stdout", "line": line.rstrip("\r\n")}

    def feed(self, text):
        self.pending += text
        out = []
        while self.pending.strip():
            head = self.pending.lstrip()
            if head[0] not in "{[":   # not a document: its first line is plain output
                line, _, rest = head.partition("\n")
                out.append(self._marker(line)); self.pending = rest
                continue
            try:
                ev, end = self.decoder.raw_decode(head)
            except ValueError:   # incomplete so far: wait for more
                break
            out.append(ev if isinstance(ev, dict) else self._marker(head[:end]))
            self.pending = head[end:]
        if not self.pending.strip():
            self.pending = ""
        return out

    def flush(self):
        out = [self._marker(l) for l in self.pending.splitlines() if l.strip()]
        self.pending = ""
        return out


def classify(adapter, events, rc=0):
    """The outcome of a turn that printed <events> and exited <rc> — the adapter's turn fold over a list."""
    t = adapter.new_turn()
    for ev in events:
        t.feed(ev)
    return t.outcome(rc)


def harness_watch_line(ev):
    """The runner's own markers (turn_start, turn_end, stdout) as `harness attach` prints them — the part of an
    adapter's watch_line every CLI shares. None for any other event."""
    if ev.get("type") != "harness":
        return None
    sub = ev.get("subtype")
    if sub == "turn_start":
        return f"── turn {ev.get('turn')} ({ev.get('kind', 'message')}) ── {ev.get('message', '')}"
    if sub == "turn_end":
        extra = " (interrupted)" if ev.get("interrupted") else " (stopped)" if ev.get("stopped") else ""
        return f"── turn {ev.get('turn')} ended: {ev.get('state')}{extra}"
    if sub == "stdout":
        return ev.get("line")
    return None


# --- process trees ------------------------------------------------------------------------------
def _descendants(root):
    """Every pid under <root> (POSIX `ps`; empty when ps cannot say)."""
    try:
        out = subprocess.run(["ps", "-e", "-o", "pid=,ppid="], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    kids = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) == 2 and p[0].isdigit() and p[1].isdigit():
            kids.setdefault(int(p[1]), []).append(int(p[0]))
    seen, todo = [], [root]
    while todo:
        for k in kids.get(todo.pop(), []):
            if k not in seen:
                seen.append(k); todo.append(k)
    return seen


def kill_tree(proc, grace=3.0):
    """End <proc> and everything it started. POSIX: proc leads its own process group (spawn()); TERM
    the group and every descendant found before the kill (one that left the group too), then KILL
    whatever outlives <grace>. Windows: taskkill /T /F."""
    if WINDOWS:
        if proc.poll() is not None:
            return
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
        proc.wait(); return
    tree = _descendants(proc.pid)

    def signal_all(sig):
        try:
            os.killpg(proc.pid, sig)
        except OSError:
            pass
        for p in tree:
            try:
                os.kill(p, sig)
            except OSError:
                pass

    signal_all(signal.SIGTERM)
    deadline = time.time() + grace
    while time.time() < deadline and (proc.poll() is None or any(_alive(p) for p in tree)):
        time.sleep(0.05)
    signal_all(signal.SIGKILL)
    proc.wait()


def _alive(pid):
    try:
        os.kill(pid, 0); return True
    except OSError:
        return False


def spawn(argv, cwd, stdout, stderr, env=None):
    """Start one turn's process. <env> are variables set on top of this process's own (the adapter's `env()`)."""
    kw = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if WINDOWS else {"start_new_session": True}
    if env:
        kw["env"] = {**os.environ, **env}
    return subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr, **kw)


# --- the runner ---------------------------------------------------------------------------------
class Runner:
    def __init__(self, adapter, lane, cwd, bin_=None, session_id=None, model=None, effort=None, flags="", resume=False):
        self.adapter = adapter
        self.lane, self.cwd, self.p = lane, cwd, paths(lane)
        bin_ = bin_ or adapter.default_bin
        self.bin = shlex.split(bin_) if not WINDOWS else shlex.split(bin_, posix=False)
        found = shutil.which(self.bin[0]) if self.bin else None
        if found:
            self.bin[0] = found
        self.model, self.effort, self.flags = model, effort, shlex.split(flags or "")
        self.stopping = False
        self.state_seen = False   # state.json written by this runner (lane_gone)
        self.queue = []      # read from the inbox, not yet delivered
        prev = read_state(lane)
        self.state = {
            "state": "idle", "session_id": prev.get("session_id") or session_id,
            "session_started": bool(prev.get("session_started") or (resume and session_id)),
            "turn": int(prev.get("turn") or 0),
            "turn_started": None, "last_turn_ended": prev.get("last_turn_ended"),
            "last_reply": prev.get("last_reply"), "error": prev.get("error"),
            "limit_resets_at": prev.get("limit_resets_at"), "rate_limit": prev.get("rate_limit"),
            "retry": None, "queued": 0, "inbox_offset": int(prev.get("inbox_offset") or 0),
            "exit": prev.get("exit"), "runner_pid": os.getpid(), "claude_pid": None, "cwd": cwd,
            "interrupted": int(prev.get("interrupted") or 0),
            # #352: the account the lane runs on (the adapter names it: claude's config dir, as
            # usage-statusline.sh names a pane's) and when rate_limit last changed — a headless claude runs
            # no status line, so its rate_limit_event windows are how the usage watch sees it.
            "account": adapter.account(),
            "rate_limit_at": prev.get("rate_limit_at"),
            "adapter": adapter.name,
            # The model the lane runs (--model, else the one in its claude flags): fleetview reads it here where `ps`
            # cannot show a native process's argv (Git Bash's ps knows only MSYS pids, #606).
            "model": self.model or flags_model(self.flags),
        }
        if prev.get("state") in ("limit", "transient"):
            self.state["state"] = prev["state"]
        # state.json's inbox_offset is past the last DELIVERED message (moved when its turn starts), so
        # a runner that dies with messages queued delivers them after a restart; the read position is
        # this process's own.
        self.read_offset = self.state["inbox_offset"]

    def save(self, **kw):
        if kw.get("rate_limit") and kw["rate_limit"] != self.state.get("rate_limit"):
            kw["rate_limit_at"] = time.time()
        self.state.update(kw)
        self.state["queued"] = len(self.queue)
        self.state["updated"] = time.time()
        if self.lane_gone():
            return
        try:
            write_json_atomic(self.p["state"], self.state)
            self.state_seen = True
        except FileNotFoundError:
            if not self.lane_gone():
                raise

    def event(self, ev):
        if self.lane_gone():
            return
        try:
            with open(self.p["events"], "a", encoding="utf-8") as f:
                f.write(json.dumps(ev, separators=(",", ":"), ensure_ascii=False) + "\n")
        except FileNotFoundError:
            if not self.lane_gone():
                raise

    # #419: the lane dir is gone (a test's or a dev run's temp root deleted under a live runner). The
    # stop file lives IN that dir, so no stop can ever reach the runner again: it stops itself, and
    # writes nothing more — a write would raise, and recreating the dir would resurrect a dead lane.
    def lane_gone(self):
        if not os.path.isdir(self.lane):
            return True
        # Windows refuses to remove a directory while the turn's process holds stderr.log open: the dir stays and its
        # other files go. A runner that wrote its state and finds it gone is as deleted as one whose dir is (#606).
        return WINDOWS and self.state_seen and not os.path.exists(self.p["state"])

    def poll_inbox(self):
        msgs, self.read_offset = read_inbox(self.lane, self.read_offset)
        if msgs:
            self.queue.extend(msgs)
            self.save()

    def stop_requested(self):
        return self.stopping or os.path.exists(self.p["stop"]) or self.lane_gone()

    def take_interrupt(self, turn=None):
        """True once per interrupt request aimed at <turn> (the file names the turn it was written for;
        an empty one, any), which it consumes. A request for another turn is consumed and ignored."""
        try:
            with open(self.p["interrupt"], encoding="utf-8") as f:
                aimed = f.read().strip()
            os.remove(self.p["interrupt"])
        except OSError:
            return False
        return turn is not None and aimed in ("", str(turn))

    def argv(self):
        return self.adapter.argv(self.bin, self.state["session_id"], self.state["session_started"],
                                 self.model, self.effort, self.flags)

    def adapter_env(self):
        """The variables the adapter sets on a turn's process (an adapter without `env()` sets none)."""
        env = getattr(self.adapter, "env", None)
        return dict(env(self.cwd)) if callable(env) else {}

    def stdin_payload(self, text):
        """What a turn's process reads on stdin for the message <text>: the text itself, or what the adapter's optional
        `stdin_payload(text)` makes of it (agy reads a turn's prompt as one JSON line, not as raw text)."""
        hook = getattr(self.adapter, "stdin_payload", None)
        return hook(text) if callable(hook) else text

    def abort_turn(self):
        """The adapter's cleanup once a turn's process tree was killed (an adapter without `abort_turn()` has none)."""
        hook = getattr(self.adapter, "abort_turn", None)
        if callable(hook):
            try:
                hook(self.bin, self.cwd)
            except Exception:   # a failed cleanup never keeps the lane from ending the turn
                pass

    def run_turn(self, msg):
        if self.lane_gone():   # #419: nowhere to log the turn, and no lane left to run it for
            return
        n = self.state["turn"] + 1
        started = time.time()
        self.event({"type": "harness", "subtype": "turn_start", "turn": n, "kind": msg.get("kind", "message"),
                    "message": msg["text"].splitlines()[0][:200] if msg["text"] else "", "at": started})
        turn = self.adapter.new_turn()
        with open(self.p["stderr"], "ab") as err:
            try:
                proc = spawn(self.argv(), self.cwd, subprocess.PIPE, err, self.adapter_env())
            except OSError as e:   # no CLI to run: the turn fails, the runner stays up
                self.event({"type": "harness", "subtype": "turn_end", "turn": n, "state": "transient",
                            "exit": None, "at": time.time()})
                self.save(state="transient", turn=n, error=f"cannot start {self.adapter.name}: {e}", exit=None,
                          inbox_offset=msg.get("_end", self.state["inbox_offset"]), last_turn_ended=time.time())
                return
            self.save(state="busy", turn=n, turn_started=started, claude_pid=proc.pid, retry=None,
                      inbox_offset=msg.get("_end", self.state["inbox_offset"]))
            try:   # the message goes on stdin: no argv length limit, no quoting
                proc.stdin.write(self.stdin_payload(msg["text"]).encode("utf-8")); proc.stdin.close()
            except OSError:
                pass
            lock = threading.Lock()

            def handle(ev):
                with lock:
                    self.event(ev)
                    before = (turn.session_id, turn.retry, turn.rate_limit)
                    turn.feed(ev)
                    if turn.session_id and not self.state["session_started"]:
                        self.save(session_id=turn.session_id, session_started=True)
                    elif (turn.session_id, turn.retry, turn.rate_limit) != before:
                        self.save(session_id=turn.session_id or self.state["session_id"],
                                  retry=turn.retry, rate_limit=turn.rate_limit or self.state["rate_limit"])

            def reader():
                docs = DocumentReader() if getattr(self.adapter, "json_documents", False) else None
                for raw in proc.stdout:
                    text = raw.decode("utf-8", errors="replace")
                    if docs is not None:   # one JSON document, whatever its line breaks
                        for ev in docs.feed(text):
                            handle(ev)
                        continue
                    line = text.rstrip("\r\n")
                    if not line.strip():
                        continue
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        ev = {"type": "harness", "subtype": "stdout", "line": line}
                    handle(ev)
                if docs is not None:
                    for ev in docs.flush():
                        handle(ev)
            th = threading.Thread(target=reader, daemon=True); th.start()
            stopped = interrupted = False
            while proc.poll() is None:
                if self.stop_requested():
                    kill_tree(proc); self.abort_turn(); stopped = True; break
                if self.take_interrupt(n):
                    kill_tree(proc); self.abort_turn(); interrupted = True; break
                with lock:
                    self.poll_inbox()
                time.sleep(POLL_S)
            th.join(timeout=5)
            rc = proc.wait()
        with lock:
            if stopped:
                self.event({"type": "harness", "subtype": "turn_end", "turn": n, "state": "ended", "exit": rc,
                            "stopped": True, "at": time.time()})
                self.save(claude_pid=None, turn_started=None, exit=rc, retry=None, error="stopped mid-turn")
                return
            if interrupted:   # the turn is over, the lane is not: idle, with whatever is queued up next
                self.event({"type": "harness", "subtype": "turn_end", "turn": n, "state": "idle", "exit": rc,
                            "interrupted": True, "at": time.time()})
                self.save(state="idle", last_reply=None, error="interrupted", exit=rc,
                          interrupted=int(self.state.get("interrupted") or 0) + 1,
                          claude_pid=None, turn_started=None, retry=None, last_turn_ended=time.time(),
                          session_id=turn.session_id or self.state["session_id"])
                return
            state, reply, error, resets = turn.outcome(rc, self._stderr_tail())
            self.event({"type": "harness", "subtype": "turn_end", "turn": n, "state": state, "exit": rc,
                        "at": time.time()})
            if turn.no_conversation and self.state["session_started"]:
                # #350: the session to resume is gone — start it afresh under the same id, same message
                self.event({"type": "harness", "subtype": "resume_missing", "turn": n,
                            "session_id": self.state["session_id"], "at": time.time()})
                self.save(session_started=False, claude_pid=None, turn_started=None, retry=None)
                return self.run_turn(msg)
            self.save(state=state, last_reply=reply, error=error, limit_resets_at=resets, exit=rc, interrupted=0,
                      claude_pid=None, turn_started=None, retry=None, last_turn_ended=time.time(),
                      session_id=turn.session_id or self.state["session_id"],
                      rate_limit=turn.rate_limit or self.state["rate_limit"])

    def _stderr_tail(self):
        try:
            with open(self.p["stderr"], "rb") as f:
                f.seek(max(0, os.path.getsize(self.p["stderr"]) - 2048))
                lines = [l for l in f.read().decode("utf-8", "replace").splitlines() if l.strip()]
            return lines[-1].strip()[:300] if lines else ""
        except OSError:
            return ""

    def run(self):
        os.makedirs(self.lane, exist_ok=True)
        try:
            os.remove(self.p["stop"])
        except OSError:
            pass

        def on_signal(*_):
            self.stopping = True
        for s in ("SIGTERM", "SIGHUP", "SIGINT"):
            if hasattr(signal, s):
                signal.signal(getattr(signal, s), on_signal)
        self.save()
        while not self.stop_requested():
            self.poll_inbox()
            if self.queue:
                msg = self.queue.pop(0)
                self.take_interrupt()   # one aimed at a turn that has since ended must not end this one
                self.run_turn(msg)
            else:
                self.take_interrupt()
                time.sleep(POLL_S)
        self.save(state="ended", claude_pid=None, turn_started=None)
        return 0


# --- reading a lane (the headless session backend, #349) ----------------------------------------
def undelivered(lane, st=None):
    """The texts of the inbox messages no turn has taken yet (past state.json's inbox_offset)."""
    st = read_state(lane) if st is None else st
    msgs, _ = read_inbox(lane, int(st.get("inbox_offset") or 0))
    return [m["text"] for m in msgs]


def _dur(secs):
    secs = max(0, int(secs))
    h, m, s = secs // 3600, secs % 3600 // 60, secs % 60
    return " ".join(f"{v}{u}" for v, u in ((h, "h"), (m, "m")) if v) + (" " if h or m else "") + f"{s}s"


def _resets(st):
    """`resets <when>` for a limit: the words claude's own limit reply used, else the window's resetsAt."""
    reply = st.get("last_reply") or st.get("error") or ""
    i = reply.find("resets ")
    if i >= 0:
        return reply[i:].splitlines()[0].strip()
    at = st.get("limit_resets_at")
    if isinstance(at, (int, float)) and at > 0:
        return time.strftime("resets %H:%M (UTC)", time.gmtime(at))
    return ""


def pane(lane, now=None):
    """The lane as the screen claude's TUI would show in that state, in the shapes the claude adapter's
    pane regexes read (scripts/cli/claude.sh): the spinner `(<timer> · esc to interrupt)` while a turn
    runs, `You've hit your usage limit · resets …` / `API Error: …` / `Interrupted` above an idle prompt
    after such a turn, and the input box `❯ <text>` holding every message still waiting in the inbox
    (what turn.sh reads as input queued behind a turn). The reply text itself is never drawn: words in it
    ("API Error", "429") would read as the lane's own state. None when the lane has no state yet."""
    st = read_state(lane)
    if not st:
        return None
    now = time.time() if now is None else now
    out, state = [], st.get("state")
    if state == "busy":
        started = st.get("turn_started") or now
        retry = st.get("retry") or {}
        what = f"Retrying (attempt {retry.get('attempt')}/{retry.get('max_retries')})" if retry else "Working"
        out.append(f"✻ {what}… ({_dur(now - started)} · esc to interrupt)")
    elif state == "limit":
        out.append("  ⎿  You've hit your usage limit" + (f" · {_resets(st)}" if _resets(st) else ""))
    elif state == "transient":
        err = " ".join(str(st.get("error") or "the turn failed").split())[:200]
        out.append(f"  ⎿  API Error: {err}" if not err.startswith("API Error") else f"  ⎿  {err}")
    elif state == "ended":
        out.append("  ⎿  (the lane has ended)")
    # One line per interrupted turn since the last turn that ended on its own — kept while the next turn
    # runs, as the TUI's scrollback keeps it: turn.sh counts these lines to see an interrupt land.
    out.extend(["  ⎿  Interrupted · What should Claude do instead?"] * int(st.get("interrupted") or 0))
    queued = undelivered(lane, st)
    rule = "─" * 60
    out.append(rule)
    lines = "\n".join(queued).splitlines() or [""]
    out.append("❯ " + lines[0])
    out.extend(lines[1:])
    out.append(rule)
    return "\n".join(out) + "\n"


def harness_watch_line(ev):
    """The lines of `watch` that are the core's own — a turn's start and end, and a CLI line that was not
    JSON — as `harness attach` prints them. None for any other event: the adapter's to show."""
    t, sub = ev.get("type"), ev.get("subtype")
    if t != "harness":
        return None
    if sub == "turn_start":
        return f"── turn {ev.get('turn')} ({ev.get('kind', 'message')}) ── {ev.get('message', '')}"
    if sub == "turn_end":
        extra = " (interrupted)" if ev.get("interrupted") else " (stopped)" if ev.get("stopped") else ""
        return f"── turn {ev.get('turn')} ended: {ev.get('state')}{extra}"
    if sub == "stdout":
        return ev.get("line")
    return None


def load_adapter(name):
    """The adapter module scripts/cli/<name>_headless.py, by file path (it imports this core itself), and
    its ADAPTER object. A lane's state.json names its adapter."""
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, f"{name}_headless.py")
    if not os.path.isfile(path):
        raise SystemExit(f"no headless adapter for {name!r}: {path} does not exist")
    import importlib.util
    spec = importlib.util.spec_from_file_location(f"{name}_headless", path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod.ADAPTER


def watch(lane, lines=40, follow=True, out=sys.stdout, adapter=None):
    """Print the lane's last <lines> events, then (follow) each new one as it lands. Read-only. <adapter>
    formats them (the lane's own, read from state.json, when none is given)."""
    if adapter is None:
        adapter = load_adapter(read_state(lane).get("adapter") or "claude")
    path = paths(lane)["events"]
    pos, first = 0, True
    while True:
        try:
            with open(path, "rb") as f:
                f.seek(pos); data = f.read()
        except OSError:
            data = b""
        end = data.rfind(b"\n")
        if end >= 0:
            raw = data[:end].split(b"\n"); pos += end + 1
            shown = [l for l in (adapter.watch_line(_loads(r)) for r in raw) if l]
            if first:
                shown = shown[-lines:]
            for l in shown:
                print(l, file=out, flush=True)
        first = False
        if not follow:
            return 0
        time.sleep(0.5)


def _loads(raw):
    try:
        ev = json.loads(raw.decode("utf-8", "replace"))
        return ev if isinstance(ev, dict) else {}
    except ValueError:
        return {}


# --- CLI ----------------------------------------------------------------------------------------
def utf8_stdio():
    """#406: stdin/stdout/stderr in UTF-8 whatever the console code page. A piped stdio on native
    Windows is the ANSI code page (cp1252): `pane` could not print ✻ ❯ ─, and `send … -` read the
    engine's UTF-8 as cp1252. The lane files are UTF-8 already; this makes the pipes match.
    Output is LF too (#606): Windows text mode turns every printed "\n" into "\r\n", and the bash that reads `state`,
    `pane` and `watch` through `$(…)` kept the "\r" (a reply that never equalled the one it was compared with)."""
    for s, kw in ((sys.stdin, {}), (sys.stdout, {"newline": "\n"}), (sys.stderr, {"newline": "\n"})):
        try:
            s.reconfigure(encoding="utf-8", **kw)
        except (AttributeError, ValueError, OSError):   # not a TextIOWrapper (a test's StringIO), or closed
            pass


def main(argv=None, adapter=None, prog="headless_core.py"):
    """The runner's command line. <adapter> is the entry point's own (claude_headless.py passes claude's);
    headless_core.py itself takes `run --adapter <cli>`."""
    utf8_stdio()
    ap = argparse.ArgumentParser(prog=prog, description="headless lane runner (#347, #480)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    lane = {"default": os.environ.get("HARNESS_LANE_DIR"), "required": not os.environ.get("HARNESS_LANE_DIR")}
    r = sub.add_parser("run"); r.add_argument("--lane", **lane); r.add_argument("--cwd", required=True)
    if adapter is None:
        r.add_argument("--adapter", required=True, help="the CLI whose scripts/cli/<cli>_headless.py runs the turns")
    r.add_argument("--bin", default=None, help="the CLI's command (default: the adapter's own)")
    r.add_argument("--session-id"); r.add_argument("--model"); r.add_argument("--effort")
    r.add_argument("--flags", default=""); r.add_argument("--message")
    r.add_argument("--resume", action="store_true", help="--session-id names a session that already exists")
    s = sub.add_parser("send"); s.add_argument("--lane", **lane); s.add_argument("--kind", default="message")
    s.add_argument("text")
    q = sub.add_parser("state"); q.add_argument("--lane", **lane); q.add_argument("--field")
    k = sub.add_parser("stop"); k.add_argument("--lane", **lane); k.add_argument("--timeout", type=float, default=15)
    i = sub.add_parser("interrupt"); i.add_argument("--lane", **lane)
    v = sub.add_parser("pane"); v.add_argument("--lane", **lane)
    w = sub.add_parser("watch"); w.add_argument("--lane", **lane); w.add_argument("--lines", type=int, default=40)
    w.add_argument("--no-follow", dest="follow", action="store_false")
    a = ap.parse_args(argv)

    if a.cmd == "run":
        if not WINDOWS:   # its own session: a hangup or Ctrl-C aimed at whoever started it is not the lane's
            try:
                os.setsid()
            except OSError:   # already a session (group) leader: `setsid` started it
                pass
        if a.message:
            send(a.lane, a.message, kind="bootstrap")
        ad = adapter or load_adapter(a.adapter)
        return Runner(ad, a.lane, a.cwd, a.bin or ad.default_bin, a.session_id, a.model, a.effort, a.flags, a.resume).run()
    if a.cmd == "send":
        send(a.lane, sys.stdin.read() if a.text == "-" else a.text, a.kind)
        return 0
    if a.cmd == "state":
        st = read_state(a.lane)
        if not st:
            print("no runner state in " + a.lane, file=sys.stderr); return 1
        if a.field:
            v = st.get(a.field)
            print("" if v is None else v if isinstance(v, str) else json.dumps(v))
        else:
            print(json.dumps(st, ensure_ascii=False))
        return 0
    if a.cmd == "stop":
        os.makedirs(a.lane, exist_ok=True)
        open(paths(a.lane)["stop"], "w").close()
        pid = read_state(a.lane).get("runner_pid")
        if pid and not WINDOWS:
            try:
                os.kill(int(pid), signal.SIGTERM)
            except (OSError, ValueError):
                pass
        deadline = time.time() + a.timeout
        while time.time() < deadline:
            if read_state(a.lane).get("state") == "ended":
                return 0
            time.sleep(POLL_S)
        print(f"runner in {a.lane} did not stop within {a.timeout:g}s", file=sys.stderr)
        return 1
    if a.cmd == "interrupt":   # aimed at the turn running now: one that ends first must not take the next
        st = read_state(a.lane)
        if st.get("state") != "busy":
            return 0
        os.makedirs(a.lane, exist_ok=True)
        with open(paths(a.lane)["interrupt"], "w", encoding="utf-8") as f:
            f.write(str(st.get("turn") or ""))
        return 0
    if a.cmd == "pane":
        text = pane(a.lane)
        if text is None:
            print("no runner state in " + a.lane, file=sys.stderr); return 1
        sys.stdout.write(text); return 0
    if a.cmd == "watch":
        try:
            return watch(a.lane, a.lines, a.follow)   # the lane's own adapter, off state.json
        except KeyboardInterrupt:
            return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())

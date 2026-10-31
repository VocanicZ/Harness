#!/usr/bin/env python3
"""claude_headless.py — the headless lane runner for `claude` (#347, PRD #344).

The long-running program a headless lane runs in place of claude's interactive TUI. Each turn is one
`claude -p --output-format stream-json --verbose` process in the lane's worktree; every turn after the
first passes `--resume <session id>`, so the lane is ONE claude session across turns. The lane is
exposed over files in its lane directory, never over a pane:

  inbox.jsonl   messages for the lane, one JSON object per line (`send` appends them). Each message is
                delivered, in order, as the next turn; one arriving mid-turn waits for that turn to end.
                A non-JSON line is taken as a message of its own text.
  events.jsonl  every stream-json event claude printed, one per line, in order, plus the runner's own
                `{"type":"harness","subtype":"turn_start"|"turn_end"|"stdout"|...}` markers.
  stderr.log    claude's stderr, appended per turn.
  state.json    what the engine reads, rewritten whole (write + rename) on every change:
                  state         idle | busy | limit | transient | ended — from stream-json events
                                (result / rate_limit_event / api_retry / the process exit), never from
                                screen text. A headless lane has no dialog states (trust, permission).
                  session_id    the claude session the lane resumes
                  turn          turns started so far; turn_started is the running turn's start (epoch)
                                and null when none runs
                  last_reply    the last turn's `result` text; error is set when that turn failed
                  limit_resets_at, rate_limit, retry, queued, runner_pid, claude_pid, updated, ...
  stop          a stop request (`stop` writes it). A stop — this file, SIGTERM, SIGHUP or SIGINT — ends
                the running turn's whole process tree, writes state `ended` and exits.
  interrupt     an interrupt request (#349, `interrupt` writes it): ends the RUNNING turn's process tree
                and only that — the file names the turn it is aimed at, so it never ends a later one;
                the turn ends `idle`, `interrupted` counts it (the interrupted turns since
                one last ended on its own), the runner stays up and delivers whatever is queued next. One
                left over from a turn that already ended is dropped.

The headless session backend (scripts/session/headless.sh, #349) runs this program as a lane and reads
the lane through it: `pane` renders state.json and the undelivered inbox as the screen the claude
adapter's pane regexes already read (scripts/cli/claude.sh), and `watch` follows events.jsonl as
`harness attach` shows it.

Portable by construction (ADR 0001): python3 stdlib only, and the core path uses none of /proc, flock
or setsid-only tricks. The one platform branch is kill_tree(): a POSIX process group (plus a `ps`
walk for descendants that left it) on Linux, `taskkill /T /F` on Windows. A runner restarted on the
same lane directory picks up its session id and inbox position from state.json.

  claude_headless.py run   --lane <dir> --cwd <wd> [--bin <claude command>] [--session-id <id>]
                           [--model <m>] [--effort <e>] [--flags="<extra claude flags>"]
                           [--message <first message>]
  claude_headless.py send  --lane <dir> [--kind <label>] (<message> | -)     # - reads stdin
  claude_headless.py state --lane <dir> [--field <name>]
  claude_headless.py stop  --lane <dir> [--timeout <s>]
  claude_headless.py interrupt --lane <dir>
  claude_headless.py pane  --lane <dir>                  # the lane as a claude-shaped screen
  claude_headless.py watch --lane <dir> [--lines <n>] [--no-follow]

--lane defaults to $HARNESS_LANE_DIR, which the headless session backend sets for the lane it starts.
"""
import argparse, json, os, shlex, shutil, signal, subprocess, sys, threading, time

WINDOWS = os.name == "nt"
POLL_S = 0.1


# --- lane files ---------------------------------------------------------------------------------
def paths(lane):
    return {k: os.path.join(lane, f) for k, f in (
        ("inbox", "inbox.jsonl"), ("events", "events.jsonl"), ("stderr", "stderr.log"),
        ("state", "state.json"), ("stop", "stop"), ("interrupt", "interrupt"))}


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


# --- reading a turn's events --------------------------------------------------------------------
class Turn:
    """Folds one turn's stream-json events into its outcome."""

    def __init__(self):
        self.session_id = None
        self.result = None          # the `result` event, once seen
        self.rejected = None        # rate_limit_info of a `rejected` rate_limit_event
        self.rate_limit = None      # the latest rate_limit_info
        self.retry = None           # the latest api_retry, while claude retries

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


def classify(events, rc=0):
    """The outcome of a turn that printed <events> and exited <rc> — Turn.outcome over a list."""
    t = Turn()
    for ev in events:
        t.feed(ev)
    return t.outcome(rc)


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


def spawn(argv, cwd, stdout, stderr):
    kw = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if WINDOWS else {"start_new_session": True}
    return subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr, **kw)


# --- the runner ---------------------------------------------------------------------------------
class Runner:
    def __init__(self, lane, cwd, bin_="claude", session_id=None, model=None, effort=None, flags=""):
        self.lane, self.cwd, self.p = lane, cwd, paths(lane)
        self.bin = shlex.split(bin_) if not WINDOWS else shlex.split(bin_, posix=False)
        found = shutil.which(self.bin[0]) if self.bin else None
        if found:
            self.bin[0] = found
        self.model, self.effort, self.flags = model, effort, shlex.split(flags or "")
        self.stopping = False
        self.queue = []      # read from the inbox, not yet delivered
        prev = read_state(lane)
        self.state = {
            "state": "idle", "session_id": prev.get("session_id") or session_id,
            "session_started": bool(prev.get("session_started")), "turn": int(prev.get("turn") or 0),
            "turn_started": None, "last_turn_ended": prev.get("last_turn_ended"),
            "last_reply": prev.get("last_reply"), "error": prev.get("error"),
            "limit_resets_at": prev.get("limit_resets_at"), "rate_limit": prev.get("rate_limit"),
            "retry": None, "queued": 0, "inbox_offset": int(prev.get("inbox_offset") or 0),
            "exit": prev.get("exit"), "runner_pid": os.getpid(), "claude_pid": None, "cwd": cwd,
            "interrupted": int(prev.get("interrupted") or 0),
        }
        if prev.get("state") in ("limit", "transient"):
            self.state["state"] = prev["state"]
        # state.json's inbox_offset is past the last DELIVERED message (moved when its turn starts), so
        # a runner that dies with messages queued delivers them after a restart; the read position is
        # this process's own.
        self.read_offset = self.state["inbox_offset"]

    def save(self, **kw):
        self.state.update(kw)
        self.state["queued"] = len(self.queue)
        self.state["updated"] = time.time()
        write_json_atomic(self.p["state"], self.state)

    def event(self, ev):
        with open(self.p["events"], "a", encoding="utf-8") as f:
            f.write(json.dumps(ev, separators=(",", ":"), ensure_ascii=False) + "\n")

    def poll_inbox(self):
        msgs, self.read_offset = read_inbox(self.lane, self.read_offset)
        if msgs:
            self.queue.extend(msgs)
            self.save()

    def stop_requested(self):
        return self.stopping or os.path.exists(self.p["stop"])

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
        sid = self.state["session_id"]
        a = list(self.bin) + ["-p", "--output-format", "stream-json", "--verbose"]
        if sid:
            a += ["--resume", sid] if self.state["session_started"] else ["--session-id", sid]
        if self.model:
            a += ["--model", self.model]
        if self.effort:
            a += ["--effort", self.effort]
        return a + self.flags

    def run_turn(self, msg):
        n = self.state["turn"] + 1
        started = time.time()
        self.event({"type": "harness", "subtype": "turn_start", "turn": n, "kind": msg.get("kind", "message"),
                    "message": msg["text"].splitlines()[0][:200] if msg["text"] else "", "at": started})
        turn = Turn()
        with open(self.p["stderr"], "ab") as err:
            try:
                proc = spawn(self.argv(), self.cwd, subprocess.PIPE, err)
            except OSError as e:   # no claude to run: the turn fails, the runner stays up
                self.event({"type": "harness", "subtype": "turn_end", "turn": n, "state": "transient",
                            "exit": None, "at": time.time()})
                self.save(state="transient", turn=n, error=f"cannot start claude: {e}", exit=None,
                          inbox_offset=msg.get("_end", self.state["inbox_offset"]), last_turn_ended=time.time())
                return
            self.save(state="busy", turn=n, turn_started=started, claude_pid=proc.pid, retry=None,
                      inbox_offset=msg.get("_end", self.state["inbox_offset"]))
            try:   # the message goes on stdin: no argv length limit, no quoting
                proc.stdin.write(msg["text"].encode("utf-8")); proc.stdin.close()
            except OSError:
                pass
            lock = threading.Lock()

            def reader():
                for raw in proc.stdout:
                    line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                    if not line.strip():
                        continue
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        ev = {"type": "harness", "subtype": "stdout", "line": line}
                    with lock:
                        self.event(ev)
                        before = (turn.session_id, turn.retry, turn.rate_limit)
                        turn.feed(ev)
                        if turn.session_id and not self.state["session_started"]:
                            self.save(session_id=turn.session_id, session_started=True)
                        elif (turn.session_id, turn.retry, turn.rate_limit) != before:
                            self.save(session_id=turn.session_id or self.state["session_id"],
                                      retry=turn.retry, rate_limit=turn.rate_limit or self.state["rate_limit"])
            th = threading.Thread(target=reader, daemon=True); th.start()
            stopped = interrupted = False
            while proc.poll() is None:
                if self.stop_requested():
                    kill_tree(proc); stopped = True; break
                if self.take_interrupt(n):
                    kill_tree(proc); interrupted = True; break
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


def _watch_line(ev):
    """One events.jsonl event as `harness attach` prints it; None for the ones it leaves out."""
    t, sub = ev.get("type"), ev.get("subtype")
    if t == "harness" and sub == "turn_start":
        return f"── turn {ev.get('turn')} ({ev.get('kind', 'message')}) ── {ev.get('message', '')}"
    if t == "harness" and sub == "turn_end":
        extra = " (interrupted)" if ev.get("interrupted") else " (stopped)" if ev.get("stopped") else ""
        return f"── turn {ev.get('turn')} ended: {ev.get('state')}{extra}"
    if t == "harness" and sub == "stdout":
        return ev.get("line")
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


def watch(lane, lines=40, follow=True, out=sys.stdout):
    """Print the lane's last <lines> events, then (follow) each new one as it lands. Read-only."""
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
            shown = [l for l in (_watch_line(_loads(r)) for r in raw) if l]
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
def main(argv=None):
    ap = argparse.ArgumentParser(prog="claude_headless.py", description="headless claude lane runner (#347)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    lane = {"default": os.environ.get("HARNESS_LANE_DIR"), "required": not os.environ.get("HARNESS_LANE_DIR")}
    r = sub.add_parser("run"); r.add_argument("--lane", **lane); r.add_argument("--cwd", required=True)
    r.add_argument("--bin", default=os.environ.get("HARNESS_CLAUDE_BIN") or "claude")
    r.add_argument("--session-id"); r.add_argument("--model"); r.add_argument("--effort")
    r.add_argument("--flags", default=""); r.add_argument("--message")
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
        return Runner(a.lane, a.cwd, a.bin, a.session_id, a.model, a.effort, a.flags).run()
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
            return watch(a.lane, a.lines, a.follow)
        except KeyboardInterrupt:
            return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())

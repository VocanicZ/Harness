#!/usr/bin/env python3
"""waitlib.py — engine-owned waits (#1066, follow-up to #1042): park a lane for a long job, a queue or a usage limit
and let the ENGINE do the waiting, so no model call is spent while it waits.

A lane that starts a long job (a test batch, a winsma run, a gate, a bench) starts it detached, writes a WAIT SPEC and
ENDS ITS TURN. The worker tick (bash, already polling every POLL / HARNESS_TEND_TICK) reads the spec; when its
condition holds, or its deadline passes, the engine resumes the lane's session ONCE (a message through the adapter's
resume path: the headless inbox, or the pane) with

    wait done: <condition>, rc=<n>, log tail: <last log lines>

The spec is one JSON file, $HARNESS_WAIT_FILE (the engine puts it in the lane's environment: run/<session>.wait).

  waitlib.py run   --deadline-s N [--log F] [--file F] [--what T] -- <command…>
                      start <command> detached (own session, output to --log, exit code to <log>.rc) and write the
                      spec "its wrapper process exited". The one command a lane needs; then it ends its turn.
  waitlib.py set   --deadline-s N [--file F] [--what T] [--log F] [--rc-file F]
                   (--pid P | --path F | --regex R --log F | --winsma ISSUE | --limit [--until EPOCH])
                      write a spec for a job the lane started itself. --pid: the process exits; --path: the file
                      appears; --regex: a line of --log (from now on) matches; --winsma: that issue's ticket is first
                      in the winsma queue (the engine asks the host); --limit: the usage limit has cleared (a --deadline-s that ends
                      before --until is refused, #1100: omit it and the park waits for the reset).
  waitlib.py check [--file F]      JSON: {"done", "reason", "rc", "tail", "what"}; exit 0 done, 1 pending, 2 no spec,
                                   3 the condition is the engine's to judge (winsma, limit)
  waitlib.py fire  [--file F] [--satisfied REASON]
                      if the condition holds (or the engine says it does: --satisfied), atomically take the spec (a
                      rename: exactly one caller wins) and print the resume message. exit 0 fired, 1 pending, 2 none.
  waitlib.py show  [--file F] [--field NAME]       the spec (or one field of it)
  waitlib.py fields [--file F] NAME…               the named fields on one TAB-separated line (empty when unset)
  waitlib.py clear [--file F]                      drop the spec
  waitlib.py parked --dir D        the redispatch specs under D, one per line: <file> TAB <issue> TAB <deadline epoch> TAB <created epoch>
                                   TAB <cond> TAB <not-before epoch>
  waitlib.py forget --dir D --issue N   drop the redispatch specs under D that wait for issue N

A long wait PARKS the lane (#1154): `set --limit --until U` (or `set --path F`) whose earliest wake is more than
HARNESS_QUOTA_PARK_MIN_S (default 2h) away, from an implementation lane, writes the spec with `resume=redispatch` and posts the
handoff / swaps `agent-working` for `waiting-quota` (scripts/quota-park.sh): the lane's session ends, its pool slot is free, and the
engine re-dispatches the issue once the wait is over (quota_wake_tick). `--resume inject` keeps the slot instead; a shorter wait does
by itself. A park refuses (nothing written) while the worktree is dirty or unpushed.

Conditions: pid | file | regex | winsma | limit. `resume` is `inject` (the lane stays alive; the message is its next
turn) or `redispatch` (the lane's session ended and the issue was handed back — winsma.sh park, #1034: the engine
removes the waiting label, the pool relaunches the issue). A deadline applies to every condition; a spec without one
gets WAIT_DEFAULT_DEADLINE_S, and none is ever longer than WAIT_MAX_DEADLINE_S.

Portable by construction (ADR 0001): python3 stdlib only.
"""
import argparse, json, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import portable  # noqa: E402  (pid_alive, ADR 0001)

WINDOWS = os.name == "nt"
WAIT_DEFAULT_DEADLINE_S = 6 * 3600
WAIT_MAX_DEADLINE_S = 24 * 3600
QUOTA_PARK_MIN_S = 2 * 3600   # #1154: a wait whose earliest wake is further away than this parks the lane (HARNESS_QUOTA_PARK_MIN_S)
TAIL_LINES = 20
TAIL_CHARS = 1500
SCAN_BYTES = 1 << 20          # a regex wait looks at no more than the newest MiB of the log it appended since the spec


def now():
    return time.time()


# --- processes -----------------------------------------------------------------------------------------
def pid_alive(pid, start=None):
    """True while <pid> runs (portable.pid_alive: os.kill(pid, 0) is CTRL_C_EVENT on Windows, and the pid is an MSYS one there)."""
    return isinstance(pid, int) and pid > 1 and portable.pid_alive(pid)


def own_pidns():
    """The pid namespace this process runs in (Linux: the link /proc/self/ns/pid points at), else None (Windows, macOS)."""
    return portable.pid_namespace()


def foreign_pidns(spec):
    """#1228: the pid of <spec> was recorded in another pid namespace than this process's (a lane under `bwrap --unshare-pid` writes
    the pid it sees; the engine reads it on the host, where it names an unrelated process or none). A spec without a `pidns` (older
    specs, Windows, macOS) is judged as before."""
    ns = spec.get("pidns")
    return bool(ns) and ns != own_pidns()


def spec_pid_alive(spec):
    """Is the job a pid wait names still running? `run` on native Windows records the job wrapper's WINDOWS pid (spec["winpid"]):
    portable.pid_alive reads an MSYS pid, finds no such MSYS process, and called every live job exited (#1109)."""
    if isinstance(spec.get("winpid"), int) and spec["winpid"] > 1:
        return portable.win_process_alive(spec["winpid"])
    return pid_alive(spec.get("pid"))


# --- the spec ------------------------------------------------------------------------------------------
def spec_path(arg=None):
    p = arg or os.environ.get("HARNESS_WAIT_FILE")
    if not p:
        sys.exit("waitlib: no wait file — pass --file, or run inside a lane (the engine sets HARNESS_WAIT_FILE)")
    return p


def read_spec(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def write_spec(path, spec):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(spec, f, separators=(",", ":"), ensure_ascii=False)
    for _ in range(50):   # Windows refuses the rename while a reader holds the target open
        try:
            os.replace(tmp, path); return
        except PermissionError:
            time.sleep(0.02)
    os.replace(tmp, path)


def tail_of(path):
    """The last TAIL_LINES lines of <path>, flattened to one line, at most TAIL_CHARS."""
    if not path:
        return ""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END); size = f.tell(); f.seek(max(0, size - 64 * 1024)); data = f.read()
    except OSError:
        return ""
    lines = [l.rstrip("\r") for l in data.decode("utf-8", errors="replace").splitlines() if l.strip()]
    out = " | ".join(lines[-TAIL_LINES:])
    return out[-TAIL_CHARS:]


def read_rc(spec):
    """The job's exit code from its rc file, or None."""
    p = spec.get("rc_file")
    if not p:
        return None
    try:
        with open(p, encoding="utf-8") as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def condition_text(spec):
    c = spec.get("cond")
    if c == "pid":
        return f"pid {spec.get('pid')} exited"
    if c == "file":
        return f"file {spec.get('path')} appeared"
    if c == "regex":
        return f"/{spec.get('regex')}/ matched in {spec.get('log')}"
    if c == "winsma":
        return f"#{spec.get('issue')} is first in the winsma queue"
    if c == "limit":
        return "usage limit cleared"
    return str(c)


def evaluate(spec, t=None):
    """Judge the condition. -> {"done": bool, "reason": text, "external": bool} — `external` when the engine judges it
    (winsma, limit); the deadline still applies to those."""
    t = now() if t is None else t
    c = spec.get("cond")
    held = {"done": False, "reason": "", "external": c in ("winsma", "limit")}
    if c == "pid":
        # #1228: the job's rc file is the answer both sides can read (`run` writes it, /tmp is shared); a pid from another pid
        # namespace means nothing here, so such a wait ends by its rc file or its deadline only
        if spec.get("rc_file") and os.path.exists(spec["rc_file"]):
            return {"done": True, "reason": condition_text(spec), "external": False}
        if not foreign_pidns(spec) and not spec_pid_alive(spec):
            return {"done": True, "reason": condition_text(spec), "external": False}
    elif c == "file":
        if spec.get("path") and os.path.exists(spec["path"]):
            return {"done": True, "reason": condition_text(spec), "external": False}
    elif c == "regex":
        try:
            rx = re.compile(spec.get("regex") or "")
            with open(spec.get("log") or "", "rb") as f:
                f.seek(0, os.SEEK_END); size = f.tell()
                start = max(int(spec.get("log_offset") or 0), size - SCAN_BYTES, 0)
                if size < int(spec.get("log_offset") or 0):   # the log was truncated or replaced: read it all
                    start = max(0, size - SCAN_BYTES)
                f.seek(start); text = f.read().decode("utf-8", errors="replace")
            if any(rx.search(line) for line in text.splitlines()):
                return {"done": True, "reason": condition_text(spec), "external": False}
        except (OSError, re.error):
            pass
    dl = spec.get("deadline")
    if isinstance(dl, (int, float)) and dl > 0 and t >= dl:
        return {"done": True, "reason": f"deadline passed ({condition_text(spec)} not seen)", "external": False, "deadline": True}
    return held


def message(spec, reason):
    rc = read_rc(spec)
    log = spec.get("log")
    tail = tail_of(log) or "(empty)"
    return f"wait done: {reason}, rc={'-' if rc is None else rc}, log tail: {tail}"


# --- commands ------------------------------------------------------------------------------------------
def clamp_deadline_s(n):
    if n is None or n <= 0:
        n = WAIT_DEFAULT_DEADLINE_S
    return min(float(n), float(WAIT_MAX_DEADLINE_S))


def new_spec(a, cond, **kw):
    t = now()
    spec = {"v": 1, "cond": cond, "created": t, "resume": a.resume or "inject",
            "deadline": 0 if (cond == "limit" and not a.deadline_s) else t + clamp_deadline_s(a.deadline_s)}
    if a.log:
        spec["log"] = os.path.abspath(a.log)
    if a.rc_file:
        spec["rc_file"] = os.path.abspath(a.rc_file)
    spec.update(kw)
    spec["what"] = a.what or condition_text(spec)
    return spec


def quota_park_min_s():
    try:
        return max(0.0, float(os.environ.get("HARNESS_QUOTA_PARK_MIN_S", QUOTA_PARK_MIN_S)))
    except ValueError:
        return float(QUOTA_PARK_MIN_S)


def wake_at(spec):
    """The earliest moment the ENGINE may wake a parked lane for <spec>: the reset time of a limit wait, the deadline of a file
    wait (the file itself may appear earlier: the engine looks), 0 for any other condition (a pid or a log line can fire at any time)."""
    if spec.get("cond") == "limit":
        return float(spec.get("not_before") or 0)
    if spec.get("cond") == "file":
        return float(spec.get("deadline") or 0)
    return 0.0


def lane_issue():
    """(issue, slug) of the implementation lane this process runs in (the engine's HARNESS_* env), else None: only an
    implementation lane has an issue to park (a review or bug lane keeps its slot)."""
    issue, slug = os.environ.get("HARNESS_ISSUE", ""), os.environ.get("HARNESS_REPO", "")
    if os.environ.get("HARNESS_KIND") == "impl" and issue.isdigit() and slug:
        return int(issue), slug
    return None


def should_park(spec, a):
    """#1154: park (give the pool slot up) rather than hold it — for a limit or file wait of an implementation lane. `--resume inject`
    never; `--resume redispatch` always; unset: when the earliest wake is more than HARNESS_QUOTA_PARK_MIN_S away (a file wait
    only when its --deadline-s was given: the default deadline is no promise of a long wait). The winsma park (#1034) is no
    business of this: winsma.sh parks it."""
    if spec.get("cond") not in ("limit", "file") or a.resume == "inject" or lane_issue() is None:
        return False
    if a.resume == "redispatch":
        return True
    if spec.get("cond") == "file" and not a.deadline_s:
        return False
    w = wake_at(spec)
    return w > 0 and w - now() > quota_park_min_s()


def do_park(path, spec):
    """Hand the issue back: the spec (resume=redispatch) is written first, then scripts/quota-park.sh posts the handoff and swaps the
    labels. A refusal (dirty or unpushed worktree, gh failed) removes the spec again: the lane keeps its slot and its session."""
    issue, slug = lane_issue()
    spec.update({"resume": "redispatch", "issue": issue, "slug": slug,
                 "label": os.environ.get("HARNESS_LABEL_WAITING_QUOTA", "waiting-quota")})
    write_spec(path, spec)
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "quota-park.sh")
    try:
        r = subprocess.run(["bash", script, str(issue), slug, str(int(wake_at(spec))), spec.get("what", "")],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True)
    except OSError as e:
        r = subprocess.CompletedProcess([], 1, "", f"cannot run {script}: {e}")
    if r.returncode != 0:
        try:
            os.unlink(path)
        except OSError:
            pass
        sys.exit(f"waitlib set: this wait is {int(max(0, wake_at(spec) - now()) // 60)} min away, so it parks the lane (frees your pool slot) "
                 f"and the park was refused: {(r.stderr or r.stdout).strip()}\nFix that and set the wait again, or pass --resume inject to keep your slot.")
    print(f"wait set: {spec['what']}; PARKED (#{issue}, {spec['label']}): your session ends now and the engine re-dispatches the issue as a "
          f"resume once the wait is over. Do nothing more: no promise, no further tool calls.")


def _pidns_kw():
    ns = own_pidns()
    return {"pidns": ns} if ns else {}


def cmd_set(a):
    path = spec_path(a.file)
    kinds = [x for x in (a.pid, a.path, a.regex, a.winsma, a.limit or None) if x is not None]
    if len(kinds) != 1:
        sys.exit("waitlib set: give exactly one of --pid, --path, --regex, --winsma, --limit")
    if a.pid is not None:
        spec = new_spec(a, "pid", pid=a.pid, **_pidns_kw())
    elif a.path is not None:
        spec = new_spec(a, "file", path=os.path.abspath(a.path))
    elif a.regex is not None:
        if not a.log:
            sys.exit("waitlib set: --regex needs --log")
        try:
            re.compile(a.regex)
        except re.error as e:
            sys.exit(f"waitlib set: bad --regex: {e}")
        try:
            off = os.path.getsize(a.log)
        except OSError:
            off = 0
        spec = new_spec(a, "regex", regex=a.regex, log_offset=off)
    elif a.winsma is not None:
        spec = new_spec(a, "winsma", issue=a.winsma, slug=a.slug or "", label=a.label or "")
    else:
        if a.until and a.deadline_s and now() + clamp_deadline_s(a.deadline_s) < a.until:
            # #1100: the deadline resumes the lane too, so one that ends before --until wakes it into a limit that has
            # not cleared; the engine consumes the spec and the lane sits idle with none (seen three times on #1035).
            sys.exit(f"waitlib set: a limit park's deadline must not end before --until ({int(clamp_deadline_s(a.deadline_s))}s from now "
                     f"ends {int(a.until - now() - clamp_deadline_s(a.deadline_s))}s before it); omit --deadline-s")
        spec = new_spec(a, "limit", not_before=a.until or 0, account=a.account or "")
    if should_park(spec, a):
        return do_park(path, spec)
    write_spec(path, spec)
    print(f"wait set: {spec['what']}; deadline {time.strftime('%H:%M:%S', time.localtime(spec['deadline'])) if spec['deadline'] else 'none'}. "
          f"End your turn now: the engine resumes this session once, with the result, when it holds.")


def cmd_run(a):
    path = spec_path(a.file)
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    if not cmd:
        sys.exit("waitlib run: no command (waitlib.py run --deadline-s N --log F -- <command…>)")
    log = os.path.abspath(a.log or (os.path.splitext(path)[0] + ".job.log"))
    rc_file = log + ".rc"
    try:
        os.unlink(rc_file)
    except OSError:
        pass
    me = os.path.abspath(__file__)
    kw = {}
    if WINDOWS:
        kw["creationflags"] = 0x00000200 | 0x00000008   # CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS
    else:
        kw["start_new_session"] = True
    out = open(log, "ab")
    p = subprocess.Popen([sys.executable, me, "_exec", "--rc-file", rc_file, "--"] + cmd,
                         stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, cwd=os.getcwd(), **kw)
    out.close()
    a.pid, a.path, a.regex, a.winsma, a.limit, a.rc_file = p.pid, None, None, None, False, rc_file
    a.log = log
    a.what = a.what or f"job `{' '.join(cmd)[:80]}` (pid {p.pid}) exited"
    spec = new_spec(a, "pid", pid=p.pid, **({"winpid": p.pid} if WINDOWS else {}), **_pidns_kw())
    write_spec(path, spec)
    print(f"wait set: {spec['what']}; log {log}; deadline {time.strftime('%H:%M:%S', time.localtime(spec['deadline']))}. "
          f"End your turn now: the engine resumes this session once, with the result, when the job exits.")


def cmd_exec(a):
    """The job's wrapper: run the command, write its exit code, exit with it."""
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    try:
        rc = subprocess.call(portable.resolve_argv(cmd))   # a bare `bash` is Git's, not System32's WSL launcher (#1109)
    except OSError as e:
        print(f"waitlib: cannot run {cmd[:1]}: {e}", file=sys.stderr); rc = 127
    tmp = f"{a.rc_file}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(f"{rc}\n")
    os.replace(tmp, a.rc_file)
    sys.exit(rc if 0 <= rc < 256 else 1)


def cmd_check(a):
    path = spec_path(a.file)
    spec = read_spec(path)
    if spec is None:
        print(json.dumps({"done": False, "reason": "no wait spec"})); return 2
    ev = evaluate(spec)
    out = {"done": ev["done"], "reason": ev["reason"], "what": spec.get("what"), "cond": spec.get("cond"),
           "rc": read_rc(spec), "tail": tail_of(spec.get("log"))}
    print(json.dumps(out))
    if ev["done"]:
        return 0
    return 3 if ev["external"] else 1


def cmd_fire(a):
    path = spec_path(a.file)
    spec = read_spec(path)
    if spec is None:
        return 2
    if a.satisfied:
        reason = a.satisfied
    else:
        ev = evaluate(spec)
        if not ev["done"]:
            return 1
        reason = ev["reason"]
    taken = f"{path}.fired.{os.getpid()}"
    try:
        os.rename(path, taken)   # one winner: a second caller finds no spec
    except OSError:
        return 2
    try:
        os.unlink(taken)
    except OSError:
        pass
    print(message(spec, reason))
    return 0


def cmd_show(a):
    spec = read_spec(spec_path(a.file))
    if spec is None:
        return 1
    if a.field:
        v = spec.get(a.field, "")
        print("" if v is None else v)
    else:
        print(json.dumps(spec))
    return 0


def cmd_fields(a):
    spec = read_spec(spec_path(a.file))
    if spec is None:
        return 1
    print("\t".join("" if spec.get(n) is None else str(spec.get(n)).replace("\t", " ").replace("\n", " ") for n in a.names))
    return 0


def cmd_clear(a):
    try:
        os.unlink(spec_path(a.file))
    except OSError:
        pass
    return 0


def parked_specs(d):
    """[(path, spec)] of the `redispatch` specs under <d> (winsma, #1034; a long wait, #1154): the lanes that ended and handed their issue back."""
    out = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return out
    for n in names:
        if not n.endswith(".wait"):
            continue
        spec = read_spec(os.path.join(d, n))
        if spec and spec.get("resume") == "redispatch" and spec.get("issue") is not None:
            out.append((os.path.join(d, n), spec))
    return out


def cmd_parked(a):
    for path, spec in parked_specs(a.dir):
        print(f"{path}\t{spec.get('issue')}\t{int(spec.get('deadline') or 0)}\t{int(spec.get('created') or 0)}\t{spec.get('cond')}\t{int(wake_at(spec))}")
    return 0


def cmd_forget(a):
    for path, spec in parked_specs(a.dir):
        if str(spec.get("issue")) == str(a.issue):
            try:
                os.unlink(path)
            except OSError:
                pass
    return 0


def build():
    ap = argparse.ArgumentParser(prog="waitlib.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd_name", required=True)

    def common(p):
        p.add_argument("--file")
        p.add_argument("--deadline-s", type=float, default=None)
        p.add_argument("--what")
        p.add_argument("--log")
        p.add_argument("--rc-file")
        p.add_argument("--resume", choices=("inject", "redispatch"))
    s = sub.add_parser("set"); common(s)
    s.add_argument("--pid", type=int); s.add_argument("--path"); s.add_argument("--regex")
    s.add_argument("--winsma", type=int); s.add_argument("--limit", action="store_true")
    s.add_argument("--until", type=float); s.add_argument("--account"); s.add_argument("--slug"); s.add_argument("--label")
    s.set_defaults(fn=cmd_set)
    r = sub.add_parser("run"); common(r); r.add_argument("cmd", nargs=argparse.REMAINDER); r.set_defaults(fn=cmd_run)
    x = sub.add_parser("_exec"); x.add_argument("--rc-file", required=True); x.add_argument("cmd", nargs=argparse.REMAINDER)
    x.set_defaults(fn=cmd_exec)
    c = sub.add_parser("check"); c.add_argument("--file"); c.set_defaults(fn=cmd_check)
    f = sub.add_parser("fire"); f.add_argument("--file"); f.add_argument("--satisfied"); f.set_defaults(fn=cmd_fire)
    sh = sub.add_parser("show"); sh.add_argument("--file"); sh.add_argument("--field"); sh.set_defaults(fn=cmd_show)
    fl = sub.add_parser("fields"); fl.add_argument("--file"); fl.add_argument("names", nargs="+"); fl.set_defaults(fn=cmd_fields)
    cl = sub.add_parser("clear"); cl.add_argument("--file"); cl.set_defaults(fn=cmd_clear)
    pk = sub.add_parser("parked"); pk.add_argument("--dir", required=True); pk.set_defaults(fn=cmd_parked)
    fg = sub.add_parser("forget"); fg.add_argument("--dir", required=True); fg.add_argument("--issue", required=True)
    fg.set_defaults(fn=cmd_forget)
    return ap


def main(argv=None):
    a = build().parse_args(argv)
    return a.fn(a) or 0


if __name__ == "__main__":
    sys.exit(main())

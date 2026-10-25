#!/usr/bin/env python3
"""stats.py — the host-wide Harness event log and the `harness stats` report over it (#185).

Every fleet on the host appends one JSON line per event to $HARNESS_HOME/events.jsonl (default
~/.harness/events.jsonl), under flock. The model, effort and token usage of each session come from
Claude Code's own transcripts: every launch passes `--session-id <uuid>`, and Claude Code writes
$CLAUDE_CONFIG_DIR/projects/<slugified cwd>/<uuid>.jsonl plus <uuid>/subagents/agent-*.jsonl, each
assistant line carrying message.model + message.usage.

    stats.py emit <event> [--ctx F] [--write-ctx F] [-c k=v]... [k=v]...   append one event
    stats.py parent-prd <slug>        PRD number of the issue body on stdin (## Parent), or nothing
    stats.py report [--prd N|--issue N] [-R owner/repo] [--since 7d] [--fleet P] [--model M] [--json]
    stats.py backfill                 rebuild session_end for past sessions from their transcripts

`emit` never raises: any failure exits 1 having printed nothing, and the bash caller (lib.sh
harness_event) swallows it — logging must never block or fail dispatch.
"""
import fcntl, glob, json, os, re, sys, time
from datetime import datetime, timedelta, timezone

USAGE_KEYS = (("input_tokens", "input"), ("output_tokens", "output"),
              ("cache_creation_input_tokens", "cache_create"), ("cache_read_input_tokens", "cache_read"))
# The context a session's later events inherit (nudge, watchdog_kill, session_end, …).
CTX_KEYS = ("prefix", "project", "repo", "unit", "issue", "prd", "kind", "session",
            "model", "effort", "worktree", "launched")
LOCK_WAIT_S = 2.0   # flock is tried non-blocking for this long, then the event is dropped


def home():
    return os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")


def events_path():
    return os.environ.get("HARNESS_EVENTS_FILE") or os.path.join(home(), "events.jsonl")


def now_iso(t=None):
    return datetime.fromtimestamp(time.time() if t is None else t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(s):
    """ISO-8601 (Z or offset, optional fraction) → epoch seconds, or None."""
    if not s:
        return None
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _coerce(v):
    return int(v) if re.fullmatch(r"-?\d+", v) else v


def parse_kv(items):
    out = {}
    for it in items:
        k, sep, v = it.partition("=")
        if sep and k and v != "":
            out[k] = _coerce(v)
    return out


def append_event(rec, path=None):
    """Append one JSON line under flock. True on success; False (never an exception) otherwise."""
    path = path or events_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as fh:
            deadline = time.monotonic() + LOCK_WAIT_S
            while True:
                try:
                    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        return False
                    time.sleep(0.05)
            fh.write(json.dumps(rec) + "\n")
            fh.flush()
        return True
    except Exception:
        return False


# --- launch context ----------------------------------------------------------
def goal_fields(goal):
    """kind/issue/prd implied by a session's GOAL string (drive.sh spawn_* / inject.sh)."""
    name, _, rest = (goal or "").partition(":")
    q = rest.split(":")
    if name == "ISSUE" and q[0].isdigit():
        return {"kind": "impl", "issue": int(q[0])}
    if name == "BUG" and q[0].isdigit():
        return {"kind": "bug-fix" if q[1:] == ["fix"] else "bug-triage", "issue": int(q[0])}
    if name == "REVIEW":
        return {"kind": "review", **({"prd": int(q[0])} if q[0].isdigit() else {})}
    if name in ("PLAN", "PRD", "DECOMPOSE"):
        return {"kind": "orch", **({"prd": int(q[0])} if q[0].isdigit() else {})}
    if name == "INJECT":
        return {"kind": "inject"}
    return {}


def model_effort(flags, worktree=None):
    """(model, effort) a launch runs with. A --model/--effort in the CLI flags wins; otherwise the
    model a worktree hook routed into the worktree's .claude/settings(.local).json."""
    toks = (flags or "").split()
    got = {}
    for i, t in enumerate(toks):
        for name in ("model", "effort"):
            if t == f"--{name}" and i + 1 < len(toks):
                got[name] = toks[i + 1]
            elif t.startswith(f"--{name}="):
                got[name] = t.split("=", 1)[1]
    if "model" not in got and worktree:
        for f in ("settings.local.json", "settings.json"):
            try:
                with open(os.path.join(worktree, ".claude", f)) as fh:
                    m = json.load(fh).get("model")
            except Exception:
                continue
            if m:
                got["model"] = m
                break
    return got.get("model"), got.get("effort")


def ralph_iter(worktree):
    try:
        with open(os.path.join(worktree, ".claude", "ralph-loop.local.md")) as fh:
            m = re.search(r"^iteration:\s*(\d+)", fh.read(), re.MULTILINE)
        return int(m.group(1)) if m else None
    except Exception:
        return None


# --- transcripts -------------------------------------------------------------
def config_dirs():
    """Every Claude config dir a session's transcript can land in. The pane picks its account from
    .bashrc AFTER the worker launched it (see lib.sh ensure_trusted), so search them all."""
    seen, out = set(), []
    cands = [os.environ.get("CLAUDE_CONFIG_DIR"), os.path.expanduser("~/.claude")]
    cands += sorted(glob.glob(os.path.expanduser("~/.claude-switch/accounts/*")))
    extra = os.environ.get("HARNESS_CLAUDE_CONFIG_DIRS")
    if extra is not None:   # test seam: replaces the search list outright
        cands = extra.split(os.pathsep)
    for c in cands:
        if c and c not in seen and os.path.isdir(c):
            seen.add(c)
            out.append(c)
    return out


def find_transcript(session, dirs=None):
    for d in dirs if dirs is not None else config_dirs():
        hits = glob.glob(os.path.join(d, "projects", "*", f"{session}.jsonl"))
        if hits:
            return hits[0]
    return None


def _file_usage(path, acc, span):
    """Fold one transcript into acc {model: {input,output,cache_create,cache_read}}. A streamed
    message is written once per content block with the SAME message id and usage, so usage is
    taken once per id (the last line wins), never summed per line."""
    per_id = {}
    try:
        with open(path) as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                t = parse_ts(r.get("timestamp"))
                if t is not None:
                    span[0] = t if span[0] is None else min(span[0], t)
                    span[1] = t if span[1] is None else max(span[1], t)
                if r.get("type") != "assistant":
                    continue
                m = r.get("message") or {}
                u, model = m.get("usage"), m.get("model")
                if not u or not model or model == "<synthetic>":
                    continue
                per_id[m.get("id") or r.get("uuid") or len(per_id)] = (model, u)
    except OSError:
        return
    for model, u in per_id.values():
        tot = acc.setdefault(model, {k: 0 for _, k in USAGE_KEYS})
        for src, dst in USAGE_KEYS:
            tot[dst] += int(u.get(src) or 0)


def session_usage(transcript):
    """({model: usage}, first_ts, last_ts) over the main transcript AND every subagent transcript."""
    acc, span = {}, [None, None]
    _file_usage(transcript, acc, span)
    for sub in sorted(glob.glob(os.path.join(transcript[:-len(".jsonl")], "subagents", "*.jsonl"))):
        _file_usage(sub, acc, span)
    return acc, span[0], span[1]


# --- emit --------------------------------------------------------------------
def read_ctx(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return {}


def write_ctx(path, ctx):
    try:
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w") as fh:
            json.dump(ctx, fh)
        os.replace(tmp, path)
    except Exception:
        pass


def build_event(event, common, ctx, kv, now=None):
    """The record for one event. Precedence: common fields < the session's ctx < explicit k=v."""
    now = time.time() if now is None else now
    rec = dict(common)
    rec.update(ctx)
    rec.update(goal_fields(kv.pop("goal", "")))
    flags = kv.pop("flags", None)
    rec.update(kv)
    if event == "launch":
        model, effort = model_effort(flags, rec.get("worktree"))
        rec.setdefault("model", model)
        rec.setdefault("effort", effort)
    if event == "session_end":
        launched = rec.get("launched")
        tr = find_transcript(rec["session"]) if rec.get("session") else None
        last = None
        if tr and "usage" not in rec:
            rec["usage"], _, last = session_usage(tr)
        if "wall_s" not in rec and isinstance(launched, int):
            rec["wall_s"] = max(0, int((last or now) - launched))
        it = ralph_iter(rec["worktree"]) if rec.get("worktree") else None
        if it is not None:
            rec.setdefault("ralph_iter", it)
    rec.pop("launched", None)
    rec.pop("event", None)
    rec.pop("ts", None)
    rec = {"ts": now_iso(now), "event": event, **rec}   # ts + event lead every line, for grep
    return {k: v for k, v in rec.items() if v is not None and v != ""}


def cmd_emit(argv):
    if not argv:
        return 2
    event, rest = argv[0], argv[1:]
    common, kv, ctx_in, ctx_out, i = {}, [], None, None, 0
    while i < len(rest):
        a = rest[i]
        if a in ("--ctx", "--write-ctx", "-c") and i + 1 < len(rest):
            v = rest[i + 1]
            if a == "--ctx":
                ctx_in = v
            elif a == "--write-ctx":
                ctx_out = v
            else:
                common.update(parse_kv([v]))
            i += 2
            continue
        kv.append(a)
        i += 1
    now = time.time()
    rec = build_event(event, common, read_ctx(ctx_in) if ctx_in else {}, parse_kv(kv), now)
    if ctx_out:   # written BEFORE the append: a dead events log must not lose the session context
        ctx = {k: rec[k] for k in CTX_KEYS if k in rec}
        ctx.setdefault("launched", int(now))
        write_ctx(ctx_out, ctx)
    return 0 if append_event(rec) else 1


# --- report ------------------------------------------------------------------
def load_events(path=None):
    out = []
    try:
        with open(path or events_path()) as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    out.append(r)
    except OSError:
        pass
    return out


def parse_since(s, now=None):
    """'7d' / '24h' / '30m' / an ISO date → epoch seconds."""
    now = time.time() if now is None else now
    m = re.fullmatch(r"(\d+)([dhm])", s or "")
    if m:
        return now - int(m.group(1)) * {"d": 86400, "h": 3600, "m": 60}[m.group(2)]
    t = parse_ts(s if "T" in (s or "") else f"{s}T00:00:00+00:00")
    if t is None:
        raise ValueError(f"bad --since: {s!r} (want 7d, 24h, 30m or YYYY-MM-DD)")
    return t


def add_usage(into, usage, model_filter=None):
    for model, u in (usage or {}).items():
        if model_filter and model_filter not in model:
            continue
        tot = into.setdefault(model, {k: 0 for _, k in USAGE_KEYS})
        for _, k in USAGE_KEYS:
            tot[k] += int(u.get(k) or 0)
    return into


def sessions(events):
    """One record per session id, merged from its launch + session_end (+ the rest)."""
    by = {}
    for e in events:
        sid = e.get("session")
        if not sid:
            continue
        s = by.setdefault(sid, {"session": sid, "usage": {}, "watchdog_kills": 0, "nudges": 0})
        ev = e.get("event")
        for k in ("prefix", "project", "repo", "unit", "issue", "prd", "kind", "model", "effort"):
            if e.get(k) is not None and (ev == "launch" or s.get(k) is None):
                s[k] = e[k]
        if ev == "launch":
            s["launched"] = e.get("ts")
        elif ev == "session_end":
            s["usage"] = e.get("usage") or {}
            s["wall_s"] = e.get("wall_s")
            s["ended"] = e.get("ts")
        elif ev == "watchdog_kill":
            s["watchdog_kills"] += 1
        elif ev == "nudge":
            s["nudges"] += 1
    return list(by.values())


def _sess_matches(s, model):
    return not model or any(model in m for m in s["usage"]) or model in (s.get("model") or "")


def filter_events(events, since=None, fleet=None, repo=None):
    out = []
    for e in events:
        t = parse_ts(e.get("ts"))
        if since is not None and (t is None or t < since):
            continue
        if fleet and e.get("prefix") != fleet:
            continue
        if repo and (e.get("repo") or "").lower() != repo.lower():
            continue
        out.append(e)
    return out


def _retries(sess):
    """watchdog kills + re-dispatches (every launch of the same (repo, issue, kind) after the first)."""
    seen, redispatch = {}, 0
    for s in sess:
        if s.get("issue") is None or "launched" not in s:
            continue
        key = (s.get("repo"), s.get("issue"), s.get("kind"))
        redispatch += 1 if key in seen else 0
        seen[key] = True
    return redispatch + sum(s["watchdog_kills"] for s in sess)


def fleet_summary(events, model=None):
    """Per fleet (session prefix): sessions, tokens by model, issues/PRDs closed, retries, HOLD minutes."""
    fleets = {}
    for e in events:
        f = fleets.setdefault(e.get("prefix") or "?", {"events": []})
        f["events"].append(e)
    out = {}
    for pfx, f in sorted(fleets.items()):
        evs = f["events"]
        sess = [s for s in sessions(evs) if _sess_matches(s, model)]
        tokens = {}
        for s in sess:
            add_usage(tokens, s["usage"], model)
        out[pfx] = {
            "sessions": len(sess),
            "tokens": tokens,
            "issues_closed": len({(e.get("repo"), e.get("issue")) for e in evs if e.get("event") == "merged"}),
            "prds_closed": len({(e.get("repo"), e.get("prd")) for e in evs if e.get("event") == "prd_closed"}),
            "retries": _retries(sess),
            "hold_minutes": round(sum(int(e.get("secs") or 0) for e in evs if e.get("event") == "hold") / 60, 1),
        }
    return out


def _sess_row(s, model=None):
    return {"session": s["session"], "kind": s.get("kind"), "model": s.get("model"),
            "effort": s.get("effort"), "launched": s.get("launched"), "wall_s": s.get("wall_s"),
            "usage": add_usage({}, s["usage"], model), "watchdog_kills": s["watchdog_kills"]}


def prd_rollup(events, prd, model=None):
    """PRD #prd and every child: each issue's sessions, model/effort, tokens, wall time and retries,
    rolled up to the PRD. A child is any session attributed to the PRD (`prd` field); the PRD's own
    DECOMPOSE/REVIEW sessions carry no issue and roll up under `issue: null`."""
    sess = [s for s in sessions(events) if s.get("prd") == prd and _sess_matches(s, model)]
    groups = {}
    for s in sess:
        groups.setdefault(s.get("issue"), []).append(s)
    children, total = [], {"sessions": 0, "tokens": {}, "wall_s": 0, "retries": 0}
    for issue in sorted(groups, key=lambda i: (i is not None, i or 0)):
        ss = sorted(groups[issue], key=lambda s: s.get("launched") or "")
        row = {"issue": issue, "sessions": [_sess_row(s, model) for s in ss], "tokens": {},
               "wall_s": sum(int(s.get("wall_s") or 0) for s in ss), "retries": _retries(ss)}
        for s in ss:
            add_usage(row["tokens"], s["usage"], model)
        children.append(row)
        total["sessions"] += len(ss)
        add_usage(total["tokens"], row["tokens"])
        total["wall_s"] += row["wall_s"]
        total["retries"] += row["retries"]
    return {"prd": prd, "children": children, "total": total}


def issue_timeline(events, issue):
    tl = sorted((e for e in events if e.get("issue") == issue), key=lambda e: e.get("ts") or "")
    return {"issue": issue, "events": tl,
            "sessions": [_sess_row(s) for s in sessions(tl)]}


def _tok(usage):
    parts = []
    for model, u in sorted(usage.items()):
        parts.append(f"{model}: out {u['output']:,} in {u['input']:,} "
                     f"cache_create {u['cache_create']:,} cache_read {u['cache_read']:,}")
    return "; ".join(parts) or "-"


def _hms(s):
    s = int(s or 0)
    return f"{s // 3600}h{s % 3600 // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def render_text(kind, data):
    out = []
    if kind == "fleet":
        if not data:
            out.append("no events in range")
        for pfx, f in data.items():
            out.append(f"fleet {pfx}: sessions {f['sessions']}  issues closed {f['issues_closed']}  "
                       f"PRDs closed {f['prds_closed']}  retries {f['retries']}  HOLD {f['hold_minutes']}m")
            out.append(f"  tokens  {_tok(f['tokens'])}")
    elif kind == "prd":
        t = data["total"]
        out.append(f"PRD #{data['prd']}: sessions {t['sessions']}  wall {_hms(t['wall_s'])}  retries {t['retries']}")
        out.append(f"  tokens  {_tok(t['tokens'])}")
        for c in data["children"]:
            label = f"#{c['issue']}" if c["issue"] is not None else "(PRD orchestration)"
            out.append(f"  {label}: sessions {len(c['sessions'])}  wall {_hms(c['wall_s'])}  retries {c['retries']}")
            for s in c["sessions"]:
                out.append(f"    {s['launched'] or '?'}  {s['kind'] or '?'}  {s['model'] or '?'}/{s['effort'] or '?'}  "
                           f"wall {_hms(s['wall_s'])}  {_tok(s['usage'])}")
    elif kind == "issue":
        out.append(f"issue #{data['issue']}: {len(data['sessions'])} session(s)")
        for e in data["events"]:
            extra = " ".join(f"{k}={e[k]}" for k in ("kind", "model", "effort", "reason", "pr", "wall_s", "reset")
                             if k in e)
            line = f"  {e.get('ts')}  {e.get('event')}  {extra}".rstrip()
            if e.get("usage"):
                line += f"  {_tok(e['usage'])}"
            out.append(line)
    return "\n".join(out)


def cmd_report(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="harness stats", description="Harness event-log report (#185)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--prd", type=int)
    g.add_argument("--issue", type=int)
    g.add_argument("--backfill", action="store_true", help="rebuild session_end for past sessions")
    ap.add_argument("-R", "--repo")
    ap.add_argument("--since", help="7d, 24h, 30m or YYYY-MM-DD (default: 7d for the fleet summary)")
    ap.add_argument("--fleet", help="session prefix")
    ap.add_argument("--model", help="substring of a model id")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--events", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    if a.backfill:
        n = backfill(a.events)
        print(f"backfilled {n} session(s)")
        return 0
    try:
        since = parse_since(a.since) if a.since else (None if (a.prd or a.issue) else parse_since("7d"))
    except ValueError as e:
        print(f"harness stats: {e}", file=sys.stderr)
        return 2
    evs = filter_events(load_events(a.events), since, a.fleet, a.repo)
    if a.prd is not None:
        kind, data = "prd", prd_rollup(evs, a.prd, a.model)
    elif a.issue is not None:
        kind, data = "issue", issue_timeline(evs, a.issue)
    else:
        kind, data = "fleet", fleet_summary(evs, a.model)
    print(json.dumps(data, indent=2) if a.json else render_text(kind, data))
    return 0


# --- backfill ----------------------------------------------------------------
def _slugify(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def _fleets():
    out = []
    for f in sorted(glob.glob(os.path.join(os.environ.get("HARNESS_FLEETS_DIR") or os.path.join(home(), "fleets"), "*.json"))):
        try:
            with open(f) as fh:
                out.append(json.load(fh))
        except Exception:
            continue
    return out


def _unit_repo(project_state, unit, slugs):
    """The repo a unit drives: its targets.tsv row, else the fleet's only slug."""
    try:
        with open(os.path.join(project_state, "targets.tsv")) as fh:
            for line in fh:
                cols = line.rstrip("\n").split("\t")
                if len(cols) >= 2 and not line.startswith("#") and cols[0] == unit:
                    name = cols[1].split("/")[-1].lower()
                    return next((s for s in slugs if s.split("/")[-1].lower() == name), cols[1])
    except OSError:
        pass
    return slugs[0] if len(slugs) == 1 else None


def classify_dir(name, fleets):
    """Attribution for a transcript project-dir name, from the worktree naming scheme
    (…-harness-worktrees-<unit>-i<N> / bug-<slug>-i<N> / triage-<slug>-i<N> / orch-<slug>-p<N>)."""
    for fl in fleets:
        root = os.path.dirname(fl.get("project") or "")
        lead = _slugify(root) + "--harness-worktrees-"
        if not root or not name.startswith(lead):
            continue
        rest, slugs = name[len(lead):], fl.get("slugs") or []
        rec = {"prefix": fl.get("prefix"), "project": root}
        by_san = {_slugify(s.replace("/", "_")): s for s in slugs}
        for pat, kind, field in ((r"orch-(.+)-p(\d+)", "orch", "prd"), (r"bug-(.+)-i(\d+)", "bug-fix", "issue"),
                                 (r"triage-(.+)-i(\d+)", "bug-triage", "issue")):
            m = re.fullmatch(pat, rest)
            if m:
                rec.update({"kind": kind, field: int(m.group(2))})
                if m.group(1) in by_san:
                    rec["repo"] = by_san[m.group(1)]
                return rec
        m = re.fullmatch(r"(.+)-i(\d+)", rest)
        if m:
            rec.update({"kind": "impl", "unit": m.group(1), "issue": int(m.group(2))})
            repo = _unit_repo(fl.get("project"), m.group(1), slugs)
            if repo:
                rec["repo"] = repo
            return rec
        return rec
    m = re.search(r"-harness-worktrees-(?:(orch)-.+-p(\d+)|(.+)-i(\d+))$", name)
    if m:
        return {"kind": "orch", "prd": int(m.group(2))} if m.group(1) else \
               {"kind": "impl", "unit": m.group(3), "issue": int(m.group(4))}
    return None


def backfill(path=None):
    """Write a session_end (backfill: true) for every Harness-worktree transcript the log has none for.
    Worker logs carry only HH:MM:SS, no date, so lifecycle events are not reconstructed from them."""
    have = {e.get("session") for e in load_events(path) if e.get("event") == "session_end"}
    fleets, n = _fleets(), 0
    for d in config_dirs():
        for pdir in sorted(glob.glob(os.path.join(d, "projects", "*"))):
            attr = classify_dir(os.path.basename(pdir), fleets)
            if attr is None:
                continue
            for tr in sorted(glob.glob(os.path.join(pdir, "*.jsonl"))):
                sid = os.path.basename(tr)[:-len(".jsonl")]
                if sid in have:
                    continue
                usage, first, last = session_usage(tr)
                if not usage:
                    continue
                rec = dict(attr, session=sid, usage=usage, backfill=True, event="session_end",
                           ts=now_iso(last or os.path.getmtime(tr)))
                if first is not None and last is not None:
                    rec["wall_s"] = int(last - first)
                if append_event(rec, path):
                    have.add(sid)
                    n += 1
    return n


def cmd_parent_prd(argv):
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "issuelib", os.path.join(os.path.dirname(os.path.abspath(__file__)), "issuelib.py"))
    il = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(il)
    slug = argv[0] if argv else ""
    p = il.parse_parent(sys.stdin.read(), slug)
    if p and (not slug or p[0].lower() == slug.lower()):
        print(p[1])
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    cmd, rest = (argv[0], argv[1:]) if argv else ("report", [])
    if cmd == "emit":
        try:
            return cmd_emit(rest)
        except Exception:
            return 1
    if cmd == "parent-prd":
        return cmd_parent_prd(rest)
    if cmd == "backfill":
        return cmd_report(["--backfill"] + rest)
    if cmd == "report":
        return cmd_report(rest)
    return cmd_report(argv)


if __name__ == "__main__":
    sys.exit(main())

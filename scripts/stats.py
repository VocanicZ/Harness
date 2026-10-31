#!/usr/bin/env python3
"""stats.py — the host-wide Harness event log and the `harness stats` report over it (#185).

Every fleet on the host appends one JSON line per event to $HARNESS_HOME/events.jsonl (default
~/.harness/events.jsonl), under an exclusive lock (portable.lock_nb: flock, or msvcrt on Windows). A launch's model and effort are the CLI adapter's
(lib.sh launch_agent: cli_model_effort, #307). A session's token usage comes from Claude Code's own
transcripts (another CLI's adapter folds its own: usage_tsv, #188): every launch passes `--session-id <uuid>`, and Claude Code writes
$CLAUDE_CONFIG_DIR/projects/<slugified cwd>/<uuid>.jsonl plus <uuid>/subagents/agent-*.jsonl, each
assistant line carrying message.model + message.usage. A headless lane's claude (#352) may keep no
transcript there: its session_end usage is then folded from the lane's events.jsonl (each turn's
stream-json `result` modelUsage, or its assistant messages' usage when it ended without one), found by
the session id the lane's state.json names.

    stats.py emit <event> [--ctx F] [--write-ctx F] [-c k=v]... [k=v]...   append one event
    stats.py parent-prd <slug>        PRD number of the issue body on stdin (## Parent), or nothing
    stats.py report [--prd N|--issue N] [-R owner/repo] [--since 7d] [--fleet P] [--model M] [--json]
    stats.py backfill                 rebuild session_end for past sessions from their transcripts
    stats.py goal-env <goal> [prd]    KIND=/ISSUE=/PRD= lines for a lane's HARNESS_* session env (#186)
    stats.py transcripts <session>    a claude session's transcript paths, sub-agents included (#188)
    stats.py usage <transcript>...    per-model `<model>\t<in>\t<out>\t<cache_read>\t<cache_write>` (#188)

rtdd activity (#186) lives beside it in $HARNESS_HOME/rtdd-events.jsonl: every lane session is
launched with RTDD_EVENT_LOG pointing there plus HARNESS_SESSION/ISSUE/KIND/PRD/PREFIX/REPO, and rtdd
appends one line per invocation, copying the HARNESS_* vars into its `ctx` (VocanicZ/rtdd#503, v1).
The report joins each line to its session on ctx.HARNESS_SESSION.

`emit` never raises: any failure exits 1 having printed nothing, and the bash caller (lib.sh
harness_event) swallows it — logging must never block or fail dispatch.
"""
import glob, json, os, re, sys, time
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import portable  # noqa: E402  #355: flock / msvcrt.locking

USAGE_KEYS = (("input_tokens", "input"), ("output_tokens", "output"),
              ("cache_creation_input_tokens", "cache_create"), ("cache_read_input_tokens", "cache_read"))
# The context a session's later events inherit (nudge, watchdog_kill, session_end, …).
CTX_KEYS = ("prefix", "project", "repo", "unit", "issue", "prd", "kind", "session",
            "model", "effort", "worktree", "launched")
LOCK_WAIT_S = 2.0   # the lock is tried non-blocking for this long, then the event is dropped


def home():
    return os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")


def events_path():
    return os.environ.get("HARNESS_EVENTS_FILE") or os.path.join(home(), "events.jsonl")


def rtdd_events_path():
    return os.environ.get("HARNESS_RTDD_EVENTS_FILE") or os.path.join(home(), "rtdd-events.jsonl")


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
    """Append one JSON line under an exclusive lock (portable.lock_nb). True on success; False (never an exception) otherwise."""
    path = path or events_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as fh:
            deadline = time.monotonic() + LOCK_WAIT_S
            while True:
                try:
                    portable.lock_nb(fh)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        return False
                    time.sleep(0.05)
            try:
                fh.write(json.dumps(rec) + "\n")
                fh.flush()
            finally:
                portable.unlock(fh)
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


def goal_env(goal, prd=""):
    """The HARNESS_* suffixes (KIND, ISSUE, PRD) launch_agent exports into a lane session, from the
    same GOAL parse the launch event uses — so an rtdd event's ctx and the session agree."""
    f = goal_fields(goal)
    if str(prd).isdigit():
        f["prd"] = int(prd)
    return [f"{k.upper()}={f[k]}" for k in ("kind", "issue", "prd") if k in f]


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


def lanes_root():
    """Where headless lanes live (scripts/session/headless.sh _hl_root)."""
    return os.environ.get("HARNESS_HEADLESS_DIR") or os.path.join(home(), "lanes")


def lane_events(session):
    """A headless lane's events.jsonl (#352) for claude session <session>: the stream-json claude printed
    for every turn, whose `result` events carry each turn's usage per model. The lane whose state.json
    names that session; None when there is none."""
    for f in sorted(glob.glob(os.path.join(lanes_root(), "*", "state.json"))):
        try:
            with open(f, encoding="utf-8") as fh:
                st = json.load(fh)
        except (OSError, ValueError):
            continue
        ev = os.path.join(os.path.dirname(f), "events.jsonl")
        if isinstance(st, dict) and st.get("session_id") == session and os.path.isfile(ev):
            return ev
    return None


def find_transcript(session, dirs=None):
    for d in dirs if dirs is not None else config_dirs():
        hits = glob.glob(os.path.join(d, "projects", "*", f"{session}.jsonl"))
        if hits:
            return hits[0]
    return None


# A stream-json `result` event's modelUsage (claude -p, #352): each turn's whole usage per model, the
# turn's sub-agents and side calls included, which its `assistant` events alone do not carry.
MODEL_USAGE_KEYS = (("inputTokens", "input"), ("outputTokens", "output"),
                    ("cacheCreationInputTokens", "cache_create"), ("cacheReadInputTokens", "cache_read"))


def _file_usage(path, acc, span):
    """Fold one transcript into acc {model: {input,output,cache_create,cache_read}}. A streamed
    message is written once per content block with the SAME message id and usage, so usage is
    taken once per id (the last line wins), never summed per line. A headless lane's events.jsonl
    (stream-json, its turns split by the runner's `turn_start` markers) is folded per turn: a turn's
    `result` modelUsage when it has one (the turn's total), else — a turn interrupted, killed or cut off
    before its result — the usage its assistant messages carry."""
    segs = [({}, [])]   # (per_id, result modelUsages) per turn; a transcript is one segment
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
                if r.get("type") == "harness" and r.get("subtype") == "turn_start":
                    segs.append(({}, []))
                    continue
                if r.get("type") == "result" and isinstance(r.get("modelUsage"), dict):
                    segs[-1][1].append(r["modelUsage"])
                    continue
                if r.get("type") != "assistant":
                    continue
                m = r.get("message") or {}
                u, model = m.get("usage"), m.get("model")
                if not u or not model or model == "<synthetic>":
                    continue
                per_id = segs[-1][0]
                per_id[m.get("id") or r.get("uuid") or len(per_id)] = (model, u)
    except OSError:
        return
    for per_id, results in segs:
        for mu in results:
            for model, u in mu.items():
                if not isinstance(u, dict) or model == "<synthetic>":
                    continue
                tot = acc.setdefault(model, {k: 0 for _, k in USAGE_KEYS})
                for src, dst in MODEL_USAGE_KEYS:
                    tot[dst] += int(u.get(src) or 0)
        for model, u in per_id.values() if not results else ():
            tot = acc.setdefault(model, {k: 0 for _, k in USAGE_KEYS})
            for src, dst in USAGE_KEYS:
                tot[dst] += int(u.get(src) or 0)


def transcript_files(transcript):
    """The main transcript and every subagent transcript beside it."""
    return [transcript] + sorted(glob.glob(os.path.join(transcript[:-len(".jsonl")], "subagents", "*.jsonl")))


def usage_tsv(acc):
    """{model: usage} as the CLI adapter's `<model>\t<input>\t<output>\t<cache_read>\t<cache_write>` lines."""
    return "".join(f"{m}\t{u['input']}\t{u['output']}\t{u['cache_read']}\t{u['cache_create']}\n" for m, u in sorted(acc.items()))


def parse_usage_tsv(text):
    """The inverse of usage_tsv: a CLI adapter's usage lines (#188) as {model: usage}."""
    acc = {}
    for line in str(text).splitlines():
        p = line.split("\t")
        if len(p) != 5:
            continue
        try:
            n = [int(x) for x in p[1:]]
        except ValueError:
            continue
        tot = acc.setdefault(p[0], {k: 0 for _, k in USAGE_KEYS})
        for k, v in zip(("input", "output", "cache_read", "cache_create"), n):
            tot[k] += v
    return acc


def session_usage(transcript):
    """({model: usage}, first_ts, last_ts) over the main transcript AND every subagent transcript."""
    acc, span = {}, [None, None]
    for f in transcript_files(transcript):
        _file_usage(f, acc, span)
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
    rec.update(kv)   # a launch's model= and effort= are the CLI adapter's (cli_model_effort, #307)
    if event == "session_end":
        launched = rec.get("launched")
        tr = find_transcript(rec["session"]) if rec.get("session") else None
        if not tr and rec.get("session") and "usage" not in rec:
            tr = lane_events(rec["session"])   # #352: a headless lane whose claude kept no transcript
        last = None
        tsv = rec.pop("usage_tsv", None)   # #188: what the CLI adapter folded from its own transcripts
        if tr and "usage" not in rec:
            rec["usage"], _, last = session_usage(tr)
        elif tsv and "usage" not in rec:
            rec["usage"] = parse_usage_tsv(tsv) or None
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
        s = by.setdefault(sid, {"session": sid, "usage": {}, "watchdog_kills": 0, "nudges": 0,
                                "turn_interrupts": 0})
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
        elif ev == "turn_interrupted":
            s["turn_interrupts"] += 1
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


def fleet_summary(events, model=None, rtdd=()):
    """Per fleet (session prefix): sessions, tokens by model, issues/PRDs closed, retries, HOLD minutes,
    and rtdd: selective vs full-suite `which` calls, plus each `rtdd_missing` start (#186)."""
    fleets = {}
    for e in events:
        f = fleets.setdefault(e.get("prefix") or "?", {"events": [], "rtdd": []})
        f["events"].append(e)
    for r in rtdd:
        fleets.setdefault(r.get("prefix") or "?", {"events": [], "rtdd": []})["rtdd"].append(r)
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
            "rtdd": rtdd_summary(f["rtdd"]),
        }
        r = out[pfx]["rtdd"]
        if r.get("selective", 0) + r.get("full_suite", 0):
            r["selective_share"] = round(r["selective"] / (r["selective"] + r["full_suite"]), 2)
        missing = sum(1 for e in evs if e.get("event") == "rtdd_missing")
        if missing:
            r["missing"] = missing
    return out


def _sess_row(s, model=None, rtdd=()):
    return {"session": s["session"], "kind": s.get("kind"), "model": s.get("model"),
            "effort": s.get("effort"), "launched": s.get("launched"), "wall_s": s.get("wall_s"),
            "usage": add_usage({}, s["usage"], model), "watchdog_kills": s["watchdog_kills"],
            "rtdd": rtdd_summary([r for r in rtdd if r.get("session") == s["session"]])}


# --- rtdd events (#186) --------------------------------------------------------
def join_rtdd(rtdd, events):
    """Attribute each rtdd event line to its Harness session. ctx.HARNESS_SESSION names the session;
    the session's own launch record (prefix/repo/issue/prd/kind) wins over the rest of the ctx, which
    only fills in for a session the events log no longer has."""
    by = {s["session"]: s for s in sessions(events)}
    out = []
    for r in rtdd:
        ctx = r.get("ctx") if isinstance(r.get("ctx"), dict) else {}
        rec = {"ts": r.get("ts"), "session": ctx.get("HARNESS_SESSION"), "rtdd": r}
        for k in ("prefix", "repo", "issue", "prd", "kind"):
            v = ctx.get(f"HARNESS_{k.upper()}")
            if v is not None and v != "":
                rec[k] = _coerce(str(v)) if k in ("issue", "prd") else v
        s = by.get(rec["session"]) if rec["session"] else None
        for k in ("prefix", "repo", "issue", "prd", "kind"):
            if s and s.get(k) is not None:
                rec[k] = s[k]
        out.append(rec)
    return out


def _rtdd_full_suite(r):
    """A `which` that left the lane on the full suite: rtdd failed, chose the whole suite itself (a v0.2
    tier-2 pick / fidelity none), or selected nothing — an empty selection sends the lane to the
    full-suite bar."""
    if r.get("exit") not in (None, 0) or r.get("tier") == "T2" or r.get("selection_fidelity") == "none":
        return True
    return int(r.get("round1") or 0) + int(r.get("round2") or 0) == 0


def rtdd_summary(recs):
    """Totals over joined rtdd events; {} when there are none, so the rtdd columns render empty."""
    if not recs:
        return {}
    out = {"calls": {}, "which": 0, "changed_nodes": 0, "round1": 0, "round2": 0, "stale_graph": 0,
           "graph_sources": {}, "wall_ms": 0, "selective": 0, "full_suite": 0, "backfilled": 0}
    for rec in recs:
        r = rec["rtdd"]
        cmd = r.get("cmd") or "?"
        out["calls"][cmd] = out["calls"].get(cmd, 0) + 1
        out["wall_ms"] += int(r.get("duration_ms") or 0)
        g = r.get("graph") if isinstance(r.get("graph"), dict) else {}
        out["stale_graph"] += 1 if int(g.get("stale_files") or 0) > 0 else 0
        if g.get("source"):
            out["graph_sources"][g["source"]] = out["graph_sources"].get(g["source"], 0) + 1
        if r.get("backfill"):   # a transcript count: no selection data to classify
            out["backfilled"] += 1
        if cmd != "which":
            continue
        out["which"] += 1
        for k in ("changed_nodes", "round1", "round2"):
            out[k] += int(r.get(k) or 0)
        if not r.get("backfill"):
            out["full_suite" if _rtdd_full_suite(r) else "selective"] += 1
    return out


def prd_rollup(events, prd, model=None, rtdd=()):
    """PRD #prd and every child: each issue's sessions, model/effort, tokens, wall time and retries,
    rolled up to the PRD. A child is any session attributed to the PRD (`prd` field); the PRD's own
    DECOMPOSE/REVIEW sessions carry no issue and roll up under `issue: null`."""
    sess = [s for s in sessions(events) if s.get("prd") == prd and _sess_matches(s, model)]
    kept = {s["session"] for s in sess}
    rtdd = [r for r in rtdd if r.get("prd") == prd and (not model or r.get("session") in kept)]
    groups = {}
    for s in sess:
        groups.setdefault(s.get("issue"), []).append(s)
    for r in rtdd:
        groups.setdefault(r.get("issue"), [])
    children, total = [], {"sessions": 0, "tokens": {}, "wall_s": 0, "retries": 0, "rtdd": rtdd_summary(rtdd)}
    for issue in sorted(groups, key=lambda i: (i is not None, i or 0)):
        ss = sorted(groups[issue], key=lambda s: s.get("launched") or "")
        rr = [r for r in rtdd if r.get("issue") == issue]
        row = {"issue": issue, "sessions": [_sess_row(s, model, rr) for s in ss], "tokens": {},
               "wall_s": sum(int(s.get("wall_s") or 0) for s in ss), "retries": _retries(ss),
               "rtdd": rtdd_summary(rr)}
        for s in ss:
            add_usage(row["tokens"], s["usage"], model)
        children.append(row)
        total["sessions"] += len(ss)
        add_usage(total["tokens"], row["tokens"])
        total["wall_s"] += row["wall_s"]
        total["retries"] += row["retries"]
    return {"prd": prd, "children": children, "total": total}


def issue_timeline(events, issue, rtdd=()):
    tl = sorted((e for e in events if e.get("issue") == issue), key=lambda e: e.get("ts") or "")
    rr = [r for r in rtdd if r.get("issue") == issue]
    return {"issue": issue, "events": tl, "rtdd": rtdd_summary(rr),
            "sessions": [_sess_row(s, rtdd=rr) for s in sessions(tl)]}


def _tok(usage):
    parts = []
    for model, u in sorted(usage.items()):
        parts.append(f"{model}: out {u['output']:,} in {u['input']:,} "
                     f"cache_create {u['cache_create']:,} cache_read {u['cache_read']:,}")
    return "; ".join(parts) or "-"


def _rtdd(r):
    if not r:
        return "-"
    parts = [f"which {r.get('which', 0)}"] if "which" in r else []
    if "which" in r:
        parts += [f"changed nodes {r['changed_nodes']}", f"round1 {r['round1']}", f"round2 {r['round2']}",
                  f"stale graph {r['stale_graph']}", f"selective {r['selective']}/{r['selective'] + r['full_suite']}"]
        others = {c: n for c, n in r["calls"].items() if c != "which"}
        if others:
            parts.append(" ".join(f"{c} {n}" for c, n in sorted(others.items())))
        if r["backfilled"]:
            parts.append(f"backfilled {r['backfilled']}")
        parts.append(f"{r['wall_ms'] / 1000:.1f}s")
    if "selective_share" in r:
        parts.append(f"{round(r['selective_share'] * 100)}% selective")
    if r.get("missing"):
        parts.append(f"rtdd missing at {r['missing']} start(s)")
    return "  ".join(parts)


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
            out.append(f"  rtdd    {_rtdd(f['rtdd'])}")
    elif kind == "prd":
        t = data["total"]
        out.append(f"PRD #{data['prd']}: sessions {t['sessions']}  wall {_hms(t['wall_s'])}  retries {t['retries']}")
        out.append(f"  tokens  {_tok(t['tokens'])}")
        out.append(f"  rtdd    {_rtdd(t['rtdd'])}")
        for c in data["children"]:
            label = f"#{c['issue']}" if c["issue"] is not None else "(PRD orchestration)"
            out.append(f"  {label}: sessions {len(c['sessions'])}  wall {_hms(c['wall_s'])}  retries {c['retries']}"
                       f"  rtdd {_rtdd(c['rtdd'])}")
            for s in c["sessions"]:
                out.append(f"    {s['launched'] or '?'}  {s['kind'] or '?'}  {s['model'] or '?'}/{s['effort'] or '?'}  "
                           f"wall {_hms(s['wall_s'])}  {_tok(s['usage'])}")
    elif kind == "issue":
        out.append(f"issue #{data['issue']}: {len(data['sessions'])} session(s)")
        for e in data["events"]:
            extra = " ".join(f"{k}={e[k]}" for k in ("kind", "model", "effort", "reason", "pr", "wall_s", "reset",
                                                         "turn_s", "queued_nudges")
                             if k in e)
            line = f"  {e.get('ts')}  {e.get('event')}  {extra}".rstrip()
            if e.get("usage"):
                line += f"  {_tok(e['usage'])}"
            out.append(line)
        out.append(f"  rtdd  {_rtdd(data['rtdd'])}")
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
    ap.add_argument("--rtdd-events", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    if a.backfill:
        n, calls = backfill(a.events), backfill_rtdd(a.rtdd_events)
        print(f"backfilled {n} session(s), {calls} rtdd call(s)")
        return 0
    try:
        since = parse_since(a.since) if a.since else (None if (a.prd or a.issue) else parse_since("7d"))
    except ValueError as e:
        print(f"harness stats: {e}", file=sys.stderr)
        return 2
    every = load_events(a.events)
    evs = filter_events(every, since, a.fleet, a.repo)
    # joined against EVERY event: a --since that cuts a session's launch must not orphan its rtdd calls
    rtdd = filter_events(join_rtdd(load_events(a.rtdd_events or rtdd_events_path()), every), since, a.fleet, a.repo)
    if a.prd is not None:
        kind, data = "prd", prd_rollup(evs, a.prd, a.model, rtdd)
    elif a.issue is not None:
        kind, data = "issue", issue_timeline(evs, a.issue, rtdd)
    else:
        kind, data = "fleet", fleet_summary(evs, a.model, rtdd)
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


RTDD_CALL_RE = re.compile(r"(?:^|[\s;&|(`])rtdd\s+(which|init|run|seed)\b")


def rtdd_calls(transcript):
    """[(ts, cmd)] for every `rtdd which|init` (and the pre-v0.3 run/seed verbs) a session's Bash tool
    calls ran, over the main transcript and its subagents. A streamed message repeats its blocks, so
    each tool_use id counts once."""
    seen, out = set(), []
    for path in [transcript] + sorted(glob.glob(os.path.join(transcript[:-len(".jsonl")], "subagents", "*.jsonl"))):
        try:
            fh = open(path)
        except OSError:
            continue
        with fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                content = (r.get("message") or {}).get("content") if r.get("type") == "assistant" else None
                for b in content if isinstance(content, list) else ():
                    if not isinstance(b, dict) or b.get("type") != "tool_use" or b.get("name") != "Bash":
                        continue
                    if b.get("id") in seen:
                        continue
                    seen.add(b.get("id"))
                    for m in RTDD_CALL_RE.finditer(str((b.get("input") or {}).get("command") or "")):
                        out.append((r.get("timestamp"), m.group(1)))
    return out


def _harness_transcripts():
    """(attribution, session id, transcript) for every Harness-worktree main transcript on the host."""
    fleets = _fleets()
    for d in config_dirs():
        for pdir in sorted(glob.glob(os.path.join(d, "projects", "*"))):
            attr = classify_dir(os.path.basename(pdir), fleets)
            if attr is None:
                continue
            for tr in sorted(glob.glob(os.path.join(pdir, "*.jsonl"))):
                yield attr, os.path.basename(tr)[:-len(".jsonl")], tr


def backfill(path=None):
    """Write a session_end (backfill: true) for every Harness-worktree transcript the log has none for.
    Worker logs carry only HH:MM:SS, no date, so lifecycle events are not reconstructed from them."""
    have = {e.get("session") for e in load_events(path) if e.get("event") == "session_end"}
    n = 0
    for attr, sid, tr in _harness_transcripts():
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


def backfill_rtdd(path=None):
    """For every Harness session with no rtdd events (one from before RTDD_EVENT_LOG was exported),
    write one backfilled rtdd line per `rtdd` Bash call in its transcripts — counts only, no
    selection data (#186). Returns the number of calls written."""
    path = path or rtdd_events_path()
    have = {e["ctx"].get("HARNESS_SESSION") for e in load_events(path) if isinstance(e.get("ctx"), dict)}
    n = 0
    for attr, sid, tr in _harness_transcripts():
        if sid in have:
            continue
        ctx = {f"HARNESS_{k.upper()}": str(attr[k]) for k in ("prefix", "repo", "issue", "prd", "kind") if k in attr}
        ctx["HARNESS_SESSION"] = sid
        for ts, cmd in rtdd_calls(tr):
            n += 1 if append_event({"v": 1, "ts": ts, "cmd": cmd, "backfill": True, "ctx": ctx}, path) else 0
        have.add(sid)
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
    if cmd == "goal-env":
        print("\n".join(goal_env(*rest[:2])))
        return 0
    if cmd == "transcripts":   # the claude adapter's cli_transcripts (#188)
        tr = find_transcript(rest[0]) if rest else None
        print("\n".join(transcript_files(tr)) if tr else "")
        return 0
    if cmd == "usage":         # the claude adapter's cli_usage (#188)
        acc, span = {}, [None, None]
        for f in rest:
            _file_usage(f, acc, span)
        sys.stdout.write(usage_tsv(acc))
        return 0
    if cmd == "backfill":
        return cmd_report(["--backfill"] + rest)
    if cmd == "report":
        return cmd_report(rest)
    return cmd_report(argv)


if __name__ == "__main__":
    sys.exit(main())

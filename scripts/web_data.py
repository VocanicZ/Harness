#!/usr/bin/env python3
"""web_data.py — the read model behind `harness web` (#223): the only web module that touches the host.

Every adapter is a pure read of LOCAL state that returns plain dicts: the fleet registry
($HARNESS_FLEETS_DIR), each fleet's run dir and config, the poller's board snapshots
($HARNESS_SNAPSHOTS_DIR), `tmux ls`, the supervisor's log, pane files and alarm counters, and the
rate-limit files (#225). None of them calls `gh` — fleetview.issue_counts and gh_budget do, and so do
issuelib.rate_limits / rate_report, so they are never reached from here; the board snapshot's tally
and the `.rate` files stand in for them. A missing or garbled source degrades its own field to None
(rendered "unknown") and never fails the view, the rule fleetview.py follows too.

issue_view() (#228) is the issue drawer's model: the board issue, its DAG state and deps, the PR and
CI state the poller cached in the snapshot (`pulls` / `checks` — never fetched here), its live session
and its timeline from the host event log.

signature() (#227) is the cheap change detector behind the SSE collector: a `stat` of every file the
views read, the liveness of every pid they judge, and `tmux ls` — a rebuild runs only when it moves.
"""
import glob
import hashlib
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleetview  # noqa: E402
import issuelib   # noqa: E402
import stats      # noqa: E402
import supervise_rules  # noqa: E402
import web_dag    # noqa: E402

tally = fleetview.tally


def snapshots_dir():
    home = os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")
    return os.environ.get("HARNESS_SNAPSHOTS_DIR") or os.path.join(home, "snapshots")


def registry():
    """Every readable fleet record on this host, in filename order."""
    return fleetview.load_registry(fleetview.fleets_dir())


def fleet_state(rec):
    """(state, live workers): running / paused / stopped / dead / missing, lower-cased fleetview."""
    state, workers = fleetview.fleet_state(rec)
    return state.lower(), workers


def board(slug):
    """The poller's snapshot of <slug>, or None when it is missing, garbled or of an unknown schema."""
    snap = issuelib._load_snapshot(os.path.join(snapshots_dir(), issuelib._slug_filename(slug)))
    if not isinstance(snap, dict) or snap.get("schema_version") != issuelib.SNAPSHOT_SCHEMA_VERSION:
        return None
    if not isinstance(snap.get("issues"), list):
        return None
    return snap


def _int(v, default=None):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def fleet_entry(rec):
    """One fleet's overview row: {prefix, root, state, repos: [{slug, asof, tally}], workers, pool, asof}."""
    project = rec["project"]
    entry = {"prefix": rec.get("prefix") or "?", "root": os.path.dirname(project.rstrip("/")) or project,
             "state": "missing", "repos": [], "workers": 0, "pool": None, "asof": None}
    state, workers = fleet_state(rec)
    slugs = fleetview.fleet_slugs(rec)
    entry["repos"] = [{"slug": s, "asof": None, "tally": None} for s in slugs]
    if state == "missing":
        return entry
    cfg = fleetview.read_config(project)
    labels = fleetview.fleet_labels(cfg)
    for repo in entry["repos"]:
        snap = board(repo["slug"])
        if snap is not None:
            repo["asof"] = _int(snap.get("generated_at"))
            repo["tally"] = tally(snap["issues"], labels)
    known = [r["tally"] for r in entry["repos"] if r["tally"] is not None]
    # fleetview.render_fleet's COMPLETE rule (nothing pending on any repo), on the snapshot instead of gh
    if state in ("running", "stopped") and slugs and len(known) == len(slugs) \
            and not any(t["pending"] for t in known):
        state = "complete"
    stamps = [r["asof"] for r in entry["repos"] if r["asof"] is not None]
    entry.update(state=state, workers=workers, pool=_int(cfg.get("HARNESS_POOL", "3")),
                 asof=min(stamps) if stamps else None)
    return entry


# --- health (#225): the supervisor's own state, read rather than recomputed ----------------------
SUP_DEFAULTS = {"NUDGE_MIN": 45, "KILL_MIN": 120, "INTERVAL": 300}   # supervise.sh's defaults
SUP_CONF_RE = re.compile(r"^(NUDGE_MIN|KILL_MIN|INTERVAL)=(\d+)$")
# A pane file the supervisor has not rewritten for this many of its passes describes the past (the
# supervisor is not running): its session's activity is unknown, never frozen.
PANE_STALE_PASSES = 3
SUP_LINE_RE = re.compile(r"^\S+ \S+ (ACT|WARN|DRY|ERROR) ")


def _home():
    return os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")


def sup_state_dir():
    return os.environ.get("HARNESS_SUPERVISE_STATE") or os.path.join(_home(), "supervise")


def sup_log_path():
    return os.environ.get("HARNESS_SUPERVISE_LOG") or os.path.join(_home(), "supervise.log")


def supervise_conf(path=None):
    """NUDGE_MIN / KILL_MIN / INTERVAL from supervise.conf, matched line by line, never sourced."""
    path = path or os.environ.get("HARNESS_SUPERVISE_CONF") or os.path.join(_home(), "supervise.conf")
    conf = dict(SUP_DEFAULTS)
    try:
        with open(path) as fh:
            for line in fh:
                m = SUP_CONF_RE.match(line.strip())
                if m:
                    conf[m.group(1)] = int(m.group(2))
    except OSError:
        pass
    return conf


def _read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return None


def session_kind(name):
    if "-bug-" in name:
        return "bug"
    if "-inject-" in name:
        return "inject"
    m = re.search(r"-([ip])\d+$", name)
    return {"i": "impl", "p": "orch"}[m.group(1)] if m else "-"


def pane_activity(name, now, conf):
    """The supervisor's view of one session: active / quiet / nudged / frozen, or None when it has no
    fresh pane file for it (no supervisor, or not one of its sessions)."""
    path = os.path.join(sup_state_dir(), "panes", name)
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return None
    line = _read(path)
    if line is None or now - mtime > PANE_STALE_PASSES * conf["INTERVAL"]:
        return None
    return supervise_rules.pane_activity(line, now, conf["NUDGE_MIN"], conf["KILL_MIN"])["state"]


CLI_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cli")


def cli_config_var():
    """The config key naming a fleet's CLI, as the adapter dispatcher declares it (CLI_CONFIG_VAR):
    dispatch.sh is the one place that names it (#188)."""
    m = re.search(r"^CLI_CONFIG_VAR=(\w+)", _read(os.path.join(CLI_DIR, "dispatch.sh")) or "", re.MULTILINE)
    return m.group(1) if m else None


def fleet_cli(cfg):
    """The fleet's agent CLI (its config's CLI key, default claude) and whether it has an adapter."""
    key = cli_config_var()
    cli = (cfg.get(key) if key else None) or "claude"
    return cli, os.path.isfile(os.path.join(CLI_DIR, cli + ".sh"))


def live_sessions(prefix, now, sessions=None, models=None, run_dir=None, cfg=None, conf=None):
    """[{"name", "issue", "kind", "age_s", "model", "cli", "activity"}] for every live `<prefix>-…`
    tmux session. The model is the pane's `--model` flag, else the session's launch context
    (<run_dir>/<session>.stats); a CLI with no adapter gets no model rather than a guessed one."""
    sessions = fleetview.host_sessions() if sessions is None else sessions
    models = fleetview.session_models() if models is None else models
    conf = supervise_conf() if conf is None else conf
    cli, adapted = fleet_cli(cfg or {})
    out = []
    for name in sorted(n for n in sessions if n.startswith(prefix + "-")):
        ctx = issuelib._read_json(os.path.join(run_dir, name + ".stats")) if run_dir else None
        ctx = ctx if isinstance(ctx, dict) else {}
        created = sessions[name]
        out.append({"name": name, "issue": fleetview.session_issue(name), "repo": ctx.get("repo"),
                    "kind": ctx.get("kind") or session_kind(name),
                    "age_s": None if created is None else max(0, int(now) - created),
                    "model": (models.get(name) or ctx.get("model")) if adapted else None,
                    "cli": cli, "activity": pane_activity(name, now, conf)})
    return out


def stale_locks(rec, boards, live, labels=None, state=None):
    """[{"kind": "label" | "pidfile" | "claim", "what"[, "repo"]}]: an open board issue carrying the
    working label with no live session (fleetview.render_fleet's orphan rule, on the board); a `*.pid`
    in the run dir whose process is gone (doctor.sh's rule — a DEAD fleet's own worker/priority pids
    are its `dead` verdict, not more items); a claim whose recorded pid is gone (lib.sh is_claimed)."""
    labels = labels or fleetview.fleet_labels({})
    out = []
    for slug, snap in boards.items():
        if snap is None:
            continue
        for i in snap["issues"]:
            names = {l.get("name") if isinstance(l, dict) else l for l in i.get("labels") or []}
            if str(i.get("state", "")).upper() == "OPEN" and labels["working"] in names \
                    and i.get("number") not in live:
                out.append({"kind": "label", "what": f"#{i['number']}", "repo": slug})
    run_dir = rec.get("run_dir") or os.path.join(rec["project"], "run")
    for p in sorted(glob.glob(os.path.join(run_dir, "*.pid"))):
        base = os.path.basename(p)
        if state == "dead" and (base.startswith("worker-") or base == "priority.pid"):
            continue
        if not fleetview.pid_alive(p):
            out.append({"kind": "pidfile", "what": base})
    for p in sorted(glob.glob(os.path.join(run_dir, "claims", "*.claim"))):
        if not claim_alive(p):
            out.append({"kind": "claim", "what": os.path.basename(p)[:-len(".claim")]})
    return out


def claim_alive(path):
    """The claim's recorded pid (its second field) is a live process — lib.sh is_claimed's rule."""
    fields = (_read(path) or "").split()
    pid = fields[1] if len(fields) > 1 else ""
    if not pid.isdigit():
        return False
    try:
        os.kill(int(pid), 0)
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def rate_state(now):
    """[{"key", "resources": {res: {"limit", "remaining", "reset"}}, "checked_at", "hold_until"}], one
    per token the host has seen, from the `.rate` / `.hold` files alone — never a probe."""
    d = issuelib._rate_dir()
    try:
        names = os.listdir(d)
    except OSError:
        return []
    out = []
    for key in sorted({n.rsplit(".", 1)[0] for n in names if n.endswith((".rate", ".hold"))}):
        rate = issuelib._read_json(os.path.join(d, key + ".rate"))
        rate = rate if isinstance(rate, dict) else {}
        res = rate.get("resources") if isinstance(rate.get("resources"), dict) else {}
        hold = issuelib._read_json(os.path.join(d, key + ".hold"))
        reset = _int(hold.get("reset")) if isinstance(hold, dict) else None
        out.append({"key": key,
                    "resources": {k: {f: _int(v.get(f)) for f in ("limit", "remaining", "reset")}
                                  for k, v in sorted(res.items()) if isinstance(v, dict)},
                    "checked_at": _int(rate.get("checked_at")),
                    "hold_until": reset if reset is not None and reset > now else None})
    return out


def _names(prefix):
    return re.compile(r"(?<![\w.-])" + re.escape(prefix) + r"(?=-|\]|\)|\s|$)")


def supervisor(prefix, now=None, n=8):
    """{"actions": the last <n> ACT/WARN/DRY/ERROR lines of the supervisor log naming <prefix>,
    "alarms": [{"key", "message"}] still firing in supervise/rules/<prefix>.json}."""
    names = _names(prefix)
    acts = [ln for ln in fleetview._tail_lines(sup_log_path()) if SUP_LINE_RE.match(ln) and names.search(ln)]
    c = supervise_rules.load(os.path.join(sup_state_dir(), "rules", prefix + ".json"))
    msgs = c.get("messages") if isinstance(c.get("messages"), dict) else {}
    firing = c.get("firing") if isinstance(c.get("firing"), list) else []
    return {"actions": acts[-n:], "alarms": [{"key": str(k), "message": str(msgs.get(k, ""))} for k in firing]}


def attention(fleet):
    """What on this fleet needs a human: [{"kind", "what"}], kind ∈ frozen | stale-lock |
    stale-pidfile | stale-claim | alarm | dead | missing. Empty is healthy."""
    out = [{"kind": fleet["state"], "what": fleet["prefix"]}] if fleet["state"] in ("dead", "missing") else []
    out += [{"kind": "frozen", "what": s["name"]} for s in fleet.get("sessions") or () if s["activity"] == "frozen"]
    kinds = {"label": "stale-lock", "pidfile": "stale-pidfile", "claim": "stale-claim"}
    out += [dict(l, kind=kinds[l["kind"]]) for l in fleet.get("stale_locks") or ()]
    out += [{"kind": "alarm", "what": a["key"], "message": a["message"]}
            for a in (fleet.get("supervisor") or {}).get("alarms") or ()]
    return out


def fleet_health(entry, rec, now, sessions, models, conf):
    """Add `sessions`, `stale_locks`, `supervisor` and `attention` to one fleet_entry."""
    if entry["state"] == "missing":
        entry.update(sessions=[], stale_locks=[], supervisor={"actions": [], "alarms": []})
        entry["attention"] = attention(entry)
        return entry
    cfg = fleetview.read_config(rec["project"])
    run_dir = rec.get("run_dir") or os.path.join(rec["project"], "run")
    entry["sessions"] = live_sessions(entry["prefix"], now, sessions, models, run_dir, cfg, conf)
    live = {fleetview.session_number(s["name"]) for s in entry["sessions"]} - {None}
    boards = {slug: board(slug) for slug in fleetview.fleet_slugs(rec)}
    entry["stale_locks"] = stale_locks(rec, boards, live, fleetview.fleet_labels(cfg), entry["state"])
    entry["supervisor"] = supervisor(entry["prefix"], now)
    entry["attention"] = attention(entry)
    return entry


def host_view(now=None):
    """{"asof": oldest board generated_at any fleet used (or None), "fleets": [fleet_entry + health],
    "rate": rate_state, "attention": host-wide items}. A rate-limit hold is host-wide — every fleet
    spends the same token — so it never marks one fleet unhealthy."""
    now = int(time.time()) if now is None else int(now)
    sessions, models, conf = fleetview.host_sessions(), fleetview.session_models(), supervise_conf()
    fleets = [fleet_health(fleet_entry(rec), rec, now, sessions, models, conf) for rec in registry()]
    stamps = [f["asof"] for f in fleets if f["asof"] is not None]
    rate = rate_state(now)
    return {"asof": min(stamps) if stamps else None, "fleets": fleets, "rate": rate,
            "attention": [{"kind": "rate-hold", "what": r["key"], "until": r["hold_until"]}
                          for r in rate if r["hold_until"]]}


def _stat(path):
    try:
        st = os.stat(path)
    except OSError:
        return (path,)
    return (path, st.st_ino, st.st_size, st.st_mtime_ns)


def _stats(pattern):
    return tuple(_stat(p) for p in sorted(glob.glob(pattern)))


# A fleet's run-dir files the views read (fleet_state, stale_locks, live_sessions) — never its logs,
# which grow on every agent turn and would rebuild every view each tick for nothing.
RUN_INPUTS = ("*.pid", "PAUSED", "*.stats", os.path.join("claims", "*.claim"))


def signature():
    """A value that changes whenever an input of host_view or fleet_view does: the stat (inode, size,
    mtime) of the registry, every board snapshot, the event logs, the supervisor's log, conf, pane and
    rule files, the rate-limit files and each fleet's config and run-dir inputs; whether each pid file
    and claim names a live process; and the `tmux ls` session list. Reads nothing remote."""
    sup = sup_state_dir()
    sig = [_stats(os.path.join(fleetview.fleets_dir(), "*.json")),
           _stats(os.path.join(snapshots_dir(), "*.json")),
           _stat(stats.events_path()), _stat(stats.rtdd_events_path()),
           _stat(sup_log_path()),
           _stat(os.environ.get("HARNESS_SUPERVISE_CONF") or os.path.join(_home(), "supervise.conf")),
           _stats(os.path.join(sup, "panes", "*")), _stats(os.path.join(sup, "rules", "*.json")),
           _stats(os.path.join(issuelib._rate_dir(), "*"))]
    for rec in registry():
        run_dir = rec.get("run_dir") or os.path.join(rec["project"], "run")
        sig.append(_stat(os.path.join(rec["project"], "config")))
        for pat in RUN_INPUTS:
            sig.append(_stats(os.path.join(run_dir, pat)))
        sig.append(tuple(fleetview.pid_alive(p) for p in sorted(glob.glob(os.path.join(run_dir, "*.pid")))))
        sig.append(tuple(claim_alive(p) for p in sorted(glob.glob(os.path.join(run_dir, "claims", "*.claim")))))
    sessions = sorted(fleetview.host_sessions().items(), key=lambda kv: kv[0])
    sig.append(hashlib.sha1(repr(sessions).encode()).hexdigest())
    return tuple(sig)


def live_numbers(prefix):
    """Issue numbers with a live `<prefix>-…-i<N>` tmux session — `tmux ls` only, never gh."""
    return frozenset(n for n in (fleetview.session_number(s) for s in fleetview.host_sessions()
                                 if s.startswith(prefix + "-")) if n is not None)


def fleet_record(prefix):
    """The registry record carrying <prefix>, or None."""
    return next((r for r in registry() if (r.get("prefix") or "?") == prefix), None)


def fleet_view(prefix, now=None):
    """/fleet/<prefix>: {"prefix", "root", "state", "asof", "units": [web_dag.unit_graph | stub]}, or
    None for a prefix no registry record carries. A unit whose board is missing or unreadable is
    {"slug", "asof": None, "prds": [], "edges": [], "unparented": [], "issues": {}, "missing": True}."""
    rec = fleet_record(prefix)
    if rec is None:
        return None
    entry = fleet_entry(rec)
    labels = fleetview.fleet_labels(fleetview.read_config(rec["project"])) if entry["state"] != "missing" \
        else fleetview.fleet_labels({})
    live = live_numbers(prefix)
    units = []
    for slug in fleetview.fleet_slugs(rec):
        snap = board(slug)
        if snap is None:
            units.append({"slug": slug, "asof": None, "prds": [], "edges": [], "unparented": [],
                          "issues": {}, "missing": True})
        else:
            units.append(dict(web_dag.unit_graph(snap, labels, live), slug=slug))
    stamps = [u["asof"] for u in units if u["asof"] is not None]
    return {"prefix": entry["prefix"], "root": entry["root"], "state": entry["state"],
            "asof": min(stamps) if stamps else None, "units": units}


# --- the issue drawer (#228) ---------------------------------------------------------------------
def _find(snap, n):
    return next((i for i in snap["issues"] if i.get("number") == n), None)


def issue_slug(prefix, n):
    """The first of <prefix>'s repos whose board carries issue <n> (a `?issue=N` link names no repo)."""
    rec = fleet_record(prefix)
    for slug in fleetview.fleet_slugs(rec) if rec else ():
        snap = board(slug)
        if snap is not None and _find(snap, n) is not None:
            return slug
    return None


def issue_view(prefix, slug, n, now=None):
    """The drawer for issue <n> of <slug> on fleet <prefix>: {"prefix", "slug", "number", "title", "url",
    "state", "labels", "blocked_by": [{"number", "state"}], "parent", "pr": {...} | None, "pr_cached",
    "ci", "session": live_sessions row | None, "timeline": [event], "asof"}, or None when the fleet
    does not serve <slug> or its board has no such issue.

    PR and CI come from the snapshot's `pulls` / `checks` alone. A snapshot written before the poller
    cached them has no `pulls`: then `pr_cached` is False (rendered "unknown", never fetched); with it,
    no PR for <n> is `pr: None`. `ci` is the PR head's combined status, None when not cached."""
    now = int(time.time()) if now is None else int(now)
    rec = fleet_record(prefix)
    if rec is None or slug not in fleetview.fleet_slugs(rec):
        return None
    snap = board(slug)
    issue = _find(snap, n) if snap is not None else None
    if issue is None:
        return None
    cfg = fleetview.read_config(rec["project"]) if os.path.isdir(rec["project"]) else {}
    labels = fleetview.fleet_labels(cfg)
    run_dir = rec.get("run_dir") or os.path.join(rec["project"], "run")
    sessions = live_sessions(prefix, now, run_dir=run_dir, cfg=cfg)
    live = frozenset(fleetview.session_number(s["name"]) for s in sessions) - {None}
    graph = web_dag.unit_graph(snap, labels, live)
    nodes = graph["issues"]

    def state_of(num):
        if num in nodes:
            return nodes[num]["state"]
        other = _find(snap, num)
        if other is None:
            return "unknown"
        return "closed" if str(other.get("state", "")).upper() == "CLOSED" else "open"

    pulls = snap.get("pulls")
    cached = isinstance(pulls, list)
    mine = [p for p in pulls or () if isinstance(p, dict) and p.get("issue") == n]
    pr = max(mine, key=lambda p: p.get("number") or 0) if mine else None
    checks = snap.get("checks") if isinstance(snap.get("checks"), dict) else {}
    ci = (checks.get(pr.get("head_sha")) or {}).get("state") if pr else None
    session = next((s for s in sessions if fleetview.session_number(s["name"]) == n
                    and s.get("repo") in (None, slug)), None)
    events = [e for e in stats.load_events() if e.get("repo") == slug]
    body = issue.get("body")
    return {"prefix": prefix, "slug": slug, "number": n, "title": issue.get("title") or "",
            "url": f"https://github.com/{slug}/issues/{n}", "state": state_of(n),
            "labels": sorted({lb.get("name") for lb in issue.get("labels") or [] if lb.get("name")}),
            "blocked_by": [{"number": d, "state": state_of(d)} for d in web_dag.blocked_by_last(body)],
            "parent": web_dag.parent_of(body), "pr": pr, "pr_cached": cached, "ci": ci,
            "session": session, "timeline": stats.issue_timeline(events, n)["events"],
            "asof": graph["asof"]}

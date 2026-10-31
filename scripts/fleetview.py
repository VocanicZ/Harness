#!/usr/bin/env python3
"""fleetview.py [--watch [secs]] — the HOST view of `harness status`: every fleet on this host (#184).

`harness status` outside any Harness project used to die with "not inside a Harness project", so an
operator with six fleets had to `cd` into each one to see whether anything was stuck. bin/harness now
runs this instead when no .harness/config is found walking up from the cwd (and always on
`harness status --all`). Inside a project, status.sh is unchanged.

The fleet list is the host registry the start-time prefix guard already keeps — one JSON file per
fleet under $HARNESS_FLEETS_DIR (default ~/.harness/fleets) holding prefix, project, run_dir and
slugs. Everything else is read-only and best-effort: a probe that fails (no tmux server, gh offline,
a project dir that is gone) degrades its own line and never the whole view, and the exit is 0.

Every external probe goes through run_cmd, the one seam the tests replace.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import session_backend  # noqa: E402  #346: the session backend's probes
import portable         # noqa: E402  #355: pid_alive (os.kill(pid, 0) is CTRL_C_EVENT on Windows)

# A HOLD streak shorter than this is ordinary weather (one dropped poll) and stays quiet.
HOLD_WARN = int(os.environ.get("HARNESS_HOLD_WARN", "3") or 3)
# --watch refreshes issue counts at most this often: one `gh issue list` per repo per frame would
# itself burn the shared budget this view exists to report on.
GH_TTL = int(os.environ.get("HARNESS_STATUS_GH_TTL", "60") or 60)
HOLD_MARK = "transient gh failure"
RATE_SIGS = ("rate limit", "rate-limit", "http 403", "403 forbidden", "http 429", "too many requests")
CONFIG_RE = re.compile(r'^\s*:\s*"\$\{(HARNESS_[A-Z0-9_]+):=(.*)\}"\s*$')


def run_cmd(argv, timeout=20):
    """(returncode, stdout) — never raises; a missing binary or a hang is just a failed probe."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""
    return p.returncode, p.stdout


def fleets_dir():
    home = os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")
    return os.environ.get("HARNESS_FLEETS_DIR") or os.path.join(home, "fleets")


def load_registry(d):
    """Every readable fleet record in <d>, in filename order. Malformed files are skipped."""
    recs = []
    for path in sorted(glob.glob(os.path.join(d, "*.json"))):
        try:
            with open(path) as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(rec, dict) and rec.get("project"):
            recs.append(rec)
    return recs


def read_config(state_dir):
    """The `: "${HARNESS_X:=val}"` lines of a project's config, parsed — never sourced."""
    cfg = {}
    try:
        with open(os.path.join(state_dir, "config")) as fh:
            for line in fh:
                m = CONFIG_RE.match(line)
                if m:
                    cfg[m.group(1)] = m.group(2)
    except OSError:
        pass
    return cfg


def pid_alive(path):
    try:
        with open(path) as fh:
            pid = int(fh.read().strip())
    except (OSError, ValueError):
        return False
    return portable.pid_alive(pid)


def fmt_age(secs):
    secs = max(0, int(secs))
    if secs < 90:
        return f"{secs}s"
    if secs < 90 * 60:
        return f"{secs // 60}m"
    if secs < 48 * 3600:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


def session_issue(name):
    """The work a session name carries: `…-i184` → #184, `…-p24` → PRD #24, bug lane → bug #N."""
    m = re.search(r"-bug-.*-(\d+)-([a-z]+)$", name)
    if m:
        return f"bug #{m.group(1)} ({m.group(2)})"
    m = re.search(r"-([ip])(\d+)$", name)
    if m:
        return ("#" if m.group(1) == "i" else "PRD #") + m.group(2)
    return "-"


def session_number(name):
    m = re.search(r"-[ip](\d+)$", name) or re.search(r"-bug-.*-(\d+)-[a-z]+$", name)
    return int(m.group(1)) if m else None


def _probe(argv_of, column, cache=None):
    """[(session name, value)] from one probe per session backend (session_backend.BACKENDS): fleets
    sharing a host may run on different backends, and this view is every fleet's. <column> names the
    value in a headless lane row (session_backend.LANE_COLUMN); a tmux probe prints `<name>\\t<value>`.
    <cache> ({argv: (rc, out)}) lets the probes of one pass share a command: every headless probe is the
    same lane-rows call. A backend whose probe fails, or that has none, adds nothing."""
    pairs = []
    for b in session_backend.BACKENDS:
        argv = argv_of(b)
        if not argv:
            continue
        key = tuple(argv)
        if cache is not None and key in cache:
            rc, out = cache[key]
        else:
            rc, out = run_cmd(argv)
            if cache is not None:
                cache[key] = (rc, out)
        if rc != 0:
            continue
        col = session_backend.LANE_COLUMN[column] if b == "headless" else 1
        for line in out.splitlines():
            f = line.split("\t")
            pairs.append((f[0], f[col] if len(f) > col else ""))
    return pairs


def host_sessions(cache=None):
    """{session name: created epoch} for every live session — tmux sessions and headless lanes alike;
    {} when there is none."""
    return {name: int(created) if created.strip().isdigit() else None
            for name, created in _probe(session_backend.list_created_argv, "created", cache) if name}


def session_states(cache=None):
    """{session name: state} for every live session whose backend keeps one: a headless lane's idle |
    busy | limit | transient (#352). A tmux pane has none."""
    return {name: st.strip() for name, st in _probe(session_backend.states_argv, "state", cache)
            if name and st.strip()}


def host_probe():
    """(host_sessions, session_models, session_states) in one pass: each backend's commands run once."""
    cache = {}
    return host_sessions(cache), session_models(cache), session_states(cache)


def session_models(cache=None):
    """{session name: model} — read off the `--model X` flag of a process under each session's pane (a
    headless lane: its runner, whose argv carries the lane's claude flags)."""
    panes = {}
    for name, pid in _probe(session_backend.pane_pids_argv, "pid", cache):
        if pid.strip().isdigit():
            panes.setdefault(name, []).append(int(pid))
    if not panes:
        return {}
    rc, out = run_cmd(["ps", "-eo", "pid=,ppid=,args="])
    kids, args = {}, {}
    for line in out.splitlines() if rc == 0 else []:
        parts = line.split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            pid, ppid = int(parts[0]), int(parts[1])
            args[pid] = parts[2] if len(parts) > 2 else ""
            kids.setdefault(ppid, []).append(pid)
    models = {}
    for name, roots in panes.items():
        todo, seen = list(roots), set()
        while todo:
            pid = todo.pop(0)
            if pid in seen:
                continue
            seen.add(pid)
            m = re.search(r"--model[= ](\S+)", args.get(pid, ""))
            if m:
                models[name] = m.group(1)
                break
            todo.extend(kids.get(pid, []))
    return models


def issue_counts(slug, labels):
    """{open, unblocked, working: [numbers], pending} for one repo, or None when gh cannot answer."""
    rc, out = run_cmd(["gh", "issue", "list", "-R", slug, "--state", "open", "--limit", "1000",
                       "--json", "number,labels"])
    if rc != 0:
        return None
    try:
        issues = json.loads(out or "[]")
    except ValueError:
        return None
    return tally(issues, labels)


def tally(issues, labels):
    """{open, unblocked, working: [numbers], pending} over a repo's issues. Issues carrying a `state`
    other than OPEN are skipped, so a board snapshot (every state) and gh's open-only list (no state
    field) count alike — `harness web` reads the snapshot, issue_counts above reads gh (#223)."""
    c = {"open": 0, "unblocked": 0, "working": [], "pending": 0}
    for it in issues:
        if str(it.get("state") or "OPEN").upper() != "OPEN":
            continue
        names = {lb.get("name") for lb in it.get("labels") or []}
        c["open"] += 1
        if labels["blocked"] not in names:
            c["unblocked"] += 1
        if labels["working"] in names:
            c["working"].append(it.get("number"))
        if names & {labels["ready"], labels["working"], labels["prd"]}:
            c["pending"] += 1
    return c


def gh_budget(now):
    """One line on the shared GitHub token's budget, or None. `gh api rate_limit` is itself free."""
    rc, out = run_cmd(["gh", "api", "rate_limit"])
    if rc != 0:
        return None
    try:
        res = json.loads(out).get("resources") or {}
    except (ValueError, AttributeError):
        return None
    parts = []
    for key in ("core", "graphql"):
        r = res.get(key)
        if not isinstance(r, dict) or "remaining" not in r:
            continue
        reset = int(r.get("reset") or 0)
        when = time.strftime("%H:%M", time.localtime(reset)) if reset else "?"
        parts.append(f"{key} {r['remaining']}/{r.get('limit', '?')} (reset {when}, in {fmt_age(reset - now)})")
    return "GitHub budget: " + " · ".join(parts) if parts else None


def _tail_lines(path, nbytes=65536):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - nbytes))
            data = fh.read().decode("utf-8", "replace")
    except OSError:
        return []
    return [ln for ln in data.splitlines() if ln.strip()]


def hold_streak(lines):
    """(count, reason) of the trailing run of HOLD lines: a fleet that is polling but not working."""
    n, rate = 0, False
    for ln in reversed(lines):
        if HOLD_MARK not in ln:
            break
        n += 1
        rate = rate or any(s in ln.lower() for s in RATE_SIGS)
    return n, ("rate limit" if rate else "network")


def log_summary(run_dir, now):
    """(last line, age secs, hold count, hold reason) across the run dir's logs, or None."""
    logs = [p for p in glob.glob(os.path.join(run_dir, "*.log")) if os.path.isfile(p)]
    if not logs:
        return None
    newest = max(logs, key=os.path.getmtime)
    lines = _tail_lines(newest)
    holds = max((hold_streak(_tail_lines(p)) for p in logs), key=lambda h: h[0])
    return (lines[-1] if lines else "", now - os.path.getmtime(newest)) + holds


def fleet_state(rec):
    """missing / PAUSED / RUNNING / DEAD (pid files, no live process) / STOPPED, and live workers."""
    project = rec["project"]
    if not os.path.isdir(project):
        return "missing", 0
    run_dir = rec.get("run_dir") or os.path.join(project, "run")
    pids = glob.glob(os.path.join(run_dir, "worker-*.pid")) + glob.glob(os.path.join(run_dir, "priority.pid"))
    workers_up = sum(pid_alive(p) for p in pids if os.path.basename(p).startswith("worker-"))
    if os.path.isfile(os.path.join(run_dir, "PAUSED")):
        return "PAUSED", workers_up
    if any(pid_alive(p) for p in pids):
        return "RUNNING", workers_up
    return ("DEAD" if pids else "STOPPED"), 0


def fleet_slugs(rec):
    return rec.get("slugs") or ([rec["slug"]] if rec.get("slug") else [])


def fleet_labels(cfg):
    return {"ready": cfg.get("HARNESS_LABEL_READY", "ready-for-agent"),
            "working": cfg.get("HARNESS_LABEL_WORKING", "agent-working"),
            "blocked": cfg.get("HARNESS_LABEL_BLOCKED", "agent-blocked"),
            "prd": cfg.get("HARNESS_LABEL_PRD", "prd")}


def render_fleet(rec, sessions, models, now, counts_for, states=None):
    project, prefix = rec["project"], rec.get("prefix") or "?"
    slugs = fleet_slugs(rec)
    root = os.path.dirname(project.rstrip("/")) or project
    state, workers_up = fleet_state(rec)
    if state == "missing":
        return [f"■ {prefix:<8} {root}   missing",
                f"  project dir is gone: {project} (stale registry entry — `harness doctor --fix` prunes it)"]

    cfg = read_config(project)
    labels = fleet_labels(cfg)
    mine = sorted(n for n in sessions if n.startswith(prefix + "-"))
    counts = {s: counts_for(s, labels) for s in slugs}
    known = [c for c in counts.values() if c is not None]
    if state in ("RUNNING", "STOPPED") and slugs and len(known) == len(slugs) \
            and not any(c["pending"] for c in known):
        state = "COMPLETE"

    out = [f"■ {prefix:<8} {root}   {state}",
           f"  repos: {' '.join(slugs) or '-'}   mode: {cfg.get('HARNESS_MODE', 'issue-only')}"
           f"   workers: {workers_up}/{cfg.get('HARNESS_POOL', '3')}"]
    if mine:
        out.append(f"  sessions ({len(mine)}):")
        for n in mine:
            created = sessions[n]
            age = fmt_age(now - created) if created else "?"
            st = (states or {}).get(n)
            out.append(f"    ⟳ {n:<28} {session_issue(n):<14} {age:>5}  {models.get(n, '?')}"
                       + (f"  [{st}]" if st else ""))
    else:
        out.append("  sessions: none live")
    live_nums = {session_number(n) for n in mine} - {None}
    for slug in slugs:
        c = counts[slug]
        if c is None:
            out.append(f"  {slug}: issue counts unavailable (gh)")
            continue
        out.append(f"  {slug}: open {c['open']} · unblocked {c['unblocked']} · {labels['working']} {len(c['working'])}")
        orphans = sorted(n for n in c["working"] if n not in live_nums)
        if orphans:
            out.append(f"    ⚠ {labels['working']} with no live session: "
                       + " ".join(f"#{n}" for n in orphans))
    logs = log_summary(rec.get("run_dir") or os.path.join(project, "run"), now)
    if logs is None:
        out.append("  log: (none)")
    else:
        line, age, holds, reason = logs
        out.append(f"  log ({fmt_age(age)} ago): {line[:110]}")
        if holds >= HOLD_WARN:
            out.append(f"  ⚠ HOLD streak: {HOLD_MARK} ×{holds} ({reason})")
    return out


def render(now=None, counts_cache=None):
    now = int(now if now is not None else time.time())
    d = fleets_dir()
    recs = load_registry(d)
    out = ["═══════════════════  Harness — every fleet on this host  ═══════════════════",
           f"  registry: {d}   fleets: {len(recs)}   {time.strftime('%H:%M:%S', time.localtime(now))}"]
    budget = gh_budget(now)
    out.append("  " + (budget or "GitHub budget: unavailable (gh)"))
    if not recs:
        out.append("  (no fleets registered on this host — `harness start` in a project registers it)")
        return out
    cache = counts_cache if counts_cache is not None else {}

    def counts_for(slug, labels):
        key = (slug, tuple(sorted(labels.items())))
        hit = cache.get(key)
        if hit is None or now - hit[0] >= GH_TTL:
            hit = cache[key] = (now, issue_counts(slug, labels))
        return hit[1]

    # Warm the cache concurrently: one serial `gh issue list` per repo is seconds each, and a host
    # with six fleets would otherwise wait on them one after another.
    wanted = {(s, tuple(sorted(fleet_labels(read_config(r["project"])).items())))
              for r in recs if os.path.isdir(r["project"]) for s in fleet_slugs(r)}
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda k: counts_for(k[0], dict(k[1])), wanted))
    sessions, models, states = host_probe()
    for rec in recs:
        out.append("───────────────────────────────────────────────────────────────────────────")
        out.extend(render_fleet(rec, sessions, models, now, counts_for, states))
    out.append("═══════════════════════════════════════════════════════════════════════════")
    return out


def main(argv):
    if argv and argv[0] == "--watch":
        secs = int(argv[1]) if len(argv) > 1 and argv[1].isdigit() else 8
        cache = {}
        try:
            while True:
                frame = "\n".join(render(counts_cache=cache))
                sys.stdout.write("\x1b[H\x1b[J" + frame + f"\n  ↻ live every {secs}s · Ctrl-C stops watching (NOT the fleets)\n")
                sys.stdout.flush()
                time.sleep(secs)
        except KeyboardInterrupt:
            print("(stopped watching — fleets keep running in background)")
        return 0
    print("\n".join(render()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

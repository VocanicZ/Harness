#!/usr/bin/env python3
"""web_data.py — the read model behind `harness web` (#223): the only web module that touches the host.

Every adapter is a pure read of LOCAL state that returns plain dicts: the fleet registry
($HARNESS_FLEETS_DIR), each fleet's run dir and config, and the poller's board snapshots
($HARNESS_SNAPSHOTS_DIR). None of them calls `gh` — fleetview.issue_counts and gh_budget do, so they
are never reached from here; the board snapshot's tally stands in for them. A missing or garbled
source degrades its own field to None (rendered "unknown") and never fails the view, the rule
fleetview.py follows too.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleetview  # noqa: E402
import issuelib   # noqa: E402
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


def host_view(now=None):
    """{"asof": oldest board generated_at any fleet used (or None), "fleets": [fleet_entry]}."""
    fleets = [fleet_entry(rec) for rec in registry()]
    stamps = [f["asof"] for f in fleets if f["asof"] is not None]
    return {"asof": min(stamps) if stamps else None, "fleets": fleets}


def live_numbers(prefix):
    """Issue numbers with a live `<prefix>-…-i<N>` tmux session — `tmux ls` only, never gh."""
    return frozenset(n for n in (fleetview.session_number(s) for s in fleetview.host_sessions()
                                 if s.startswith(prefix + "-")) if n is not None)


def fleet_view(prefix, now=None):
    """/fleet/<prefix>: {"prefix", "root", "state", "asof", "units": [web_dag.unit_graph | stub]}, or
    None for a prefix no registry record carries. A unit whose board is missing or unreadable is
    {"slug", "asof": None, "prds": [], "edges": [], "unparented": [], "issues": {}, "missing": True}."""
    rec = next((r for r in registry() if (r.get("prefix") or "?") == prefix), None)
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

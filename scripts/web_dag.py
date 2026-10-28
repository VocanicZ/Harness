#!/usr/bin/env python3
"""web_dag.py — the PRD → issue DAG behind `harness web`'s fleet page (#224), from one board snapshot.

A port of skill/harness-arc/scripts/status-page.py's semantics (the script itself is gone, #230), not its code paths: children are
attributed by `## Parent`, dependency edges come from the LAST `## Blocked by` section (a `None` in it
means no edges), layering is longest-path with a cycle guard, and a PRD is done / waiting / running /
ready exactly as status-page.py derives it. test/test_web_dag.py pins all of that to status-page.py's
own answer (arc_model) on one recorded board, frozen in test/fixtures/web/arc-golden.json.

awaiting() (#229) is the "Awaiting you" panel: status-page.py's wayfinder tickets plus the two other kinds
of human-only work, agent-blocked questions and operator issues.

issuelib.parse_blocked_by reads the FIRST section, so it is not reused here. Pure functions of the
board dict: nothing here reads the host or runs a command.
"""
import re

# a child's state, checked in this order (unit_graph)
CHILD_STATES = ("closed", "agent-blocked", "in-progress", "in-review", "blocked", "open")


def blocked_by_last(body):
    """Deps from the LAST `## Blocked by` header only — prose may mention it earlier."""
    if not body:
        return []
    parts = re.split(r"^## Blocked by\s*$", body, flags=re.M)
    if len(parts) < 2:
        return []
    tail = parts[-1]
    tail = re.split(r"^## ", tail, flags=re.M)[0]
    if re.search(r"\bNone\b", tail):
        return []
    return sorted({int(n) for n in re.findall(r"#(\d+)", tail)})


def parent_of(body):
    if not body:
        return None
    m = re.search(r"^## Parent\s*\n+\s*#(\d+)", body, flags=re.M)
    return int(m.group(1)) if m else None


def layers(nodes, deps):
    """Longest-path layering over the edges inside <nodes>, so a fork renders as a fork."""
    lay, seen = {}, set()

    def depth(n):
        if n in lay:
            return lay[n]
        if n in seen:
            return 0          # cycle guard
        seen.add(n)
        d = 0 if not deps.get(n) else 1 + max(
            (depth(p) for p in deps[n] if p in nodes), default=-1)
        lay[n] = d
        return d

    for n in nodes:
        depth(n)
    return lay


def _names(issue):
    return {lb.get("name") for lb in issue.get("labels") or []}


def _closed(issue):
    return str(issue.get("state") or "OPEN").upper() == "CLOSED"


def unit_graph(board, labels, live=frozenset()):
    """One repo's DAG: {"slug", "asof", "prds", "edges", "unparented", "issues"}.

    <labels> is fleetview.fleet_labels (prd / working / blocked / ready); <live> the issue numbers with
    a live session. PRDs (sorted by number) carry their `children`, layered among siblings only.
    Wayfinder issues are neither children nor unparented: they are `awaiting` (#229), with the rest of
    the human-only work. Edges are [from, to] between nodes drawn on the same level: PRD → PRD,
    child → sibling child."""
    slug = board.get("slug") or ""
    issues = sorted((i for i in board.get("issues") or [] if isinstance(i.get("number"), int)),
                    key=lambda i: i["number"])
    by_num = {i["number"]: i for i in issues}
    branches = set(board.get("issue_branches") or [])
    closed = {i["number"] for i in issues if _closed(i)}

    prd_issues = [i for i in issues if labels["prd"] in _names(i)]
    prd_nums = {p["number"] for p in prd_issues}
    rest = [i for i in issues if labels["prd"] not in _names(i)
            and not any((n or "").startswith("wayfinder") for n in _names(i))]

    def node(i, parent):
        return {"number": i["number"], "title": i.get("title") or "", "state": None,
                "url": f"https://github.com/{slug}/issues/{i['number']}",
                "labels": sorted(n for n in _names(i) if n), "deps": blocked_by_last(i.get("body")),
                "layer": 0, "parent": parent}

    nodes = {}
    for p in prd_issues:
        nodes[p["number"]] = dict(node(p, parent_of(p.get("body"))), kids={"open": 0, "closed": 0}, children=[])
    unparented = []
    for i in rest:
        pa = parent_of(i.get("body"))
        n = node(i, pa if pa in prd_nums else None)
        nodes[i["number"]] = n
        if pa in prd_nums:
            nodes[pa]["children"].append(n)
            nodes[pa]["kids"]["closed" if _closed(i) else "open"] += 1
        else:
            unparented.append(n)

    # PRDs: status-page.py's state_of and layering, verbatim in meaning
    working = {i["number"] for i in issues if labels["working"] in _names(i)}
    prds = [nodes[p["number"]] for p in prd_issues]
    for p in prds:
        n = p["number"]
        if n in closed:
            p["state"] = "done"
        elif any(d not in closed for d in p["deps"]):
            p["state"] = "waiting"
        elif p["kids"]["open"] or p["kids"]["closed"] or n in working:
            p["state"] = "running"
        else:
            p["state"] = "ready"
    for n, d in layers(prd_nums, {p["number"]: p["deps"] for p in prds}).items():
        nodes[n]["layer"] = d
    edges = [[d, p["number"]] for p in prds for d in p["deps"] if d in prd_nums]

    def child_state(c):
        n, names = c["number"], set(c["labels"])
        if n in closed:
            return "closed"
        if labels["blocked"] in names:
            return "agent-blocked"
        if n in live:
            return "in-progress"
        if n in branches:
            return "in-review"
        if any(d not in closed for d in c["deps"]):
            return "blocked"
        return "open"

    for group in [p["children"] for p in prds] + [unparented]:
        sib = {c["number"] for c in group}
        for c in group:
            c["state"] = child_state(c)
        for n, d in layers(sib, {c["number"]: c["deps"] for c in group}).items():
            nodes[n]["layer"] = d
        edges += [[d, c["number"]] for c in group for d in c["deps"] if d in sib]

    asof = board.get("generated_at")
    return {"slug": slug, "asof": asof if isinstance(asof, int) else None, "prds": prds,
            "edges": edges, "unparented": unparented, "issues": nodes, "awaiting": awaiting(board, labels)}


AWAITING_KINDS = ("wayfinder", "agent-blocked", "operator")
OPS_RE = re.compile(r"^\s*\[ops\]", re.I)


def awaiting(board, labels):
    """The work only a human can do: [{"kind", "number", "title", "url", "resolved", "needs"}].

    kind is "wayfinder" (any `wayfinder:*` issue but the map, open or closed — status-page.py's
    tickets, closed = resolved), "agent-blocked" (an open issue carrying the blocked label) or
    "operator" (an open issue titled `[ops] …` that no agent would claim: no prd / ready / working
    label). The kinds are exclusive, in that order. needs is the last `## Blocked by`, less any
    blocker CLOSED on the board (#273) — one not on the board has unknown state and stays. Open items
    come first, by kind then number; resolved tickets last."""
    slug = board.get("slug") or ""
    agent = {labels["prd"], labels["ready"], labels["working"]}
    issues = board.get("issues") or []
    closed = {i.get("number") for i in issues if _closed(i)}
    out = []
    for i in issues:
        n, names = i.get("number"), _names(i)
        if not isinstance(n, int):
            continue
        if any((x or "").startswith("wayfinder:") and x != "wayfinder:map" for x in names):
            kind = "wayfinder"
        elif _closed(i):
            continue
        elif labels["blocked"] in names:
            kind = "agent-blocked"
        elif OPS_RE.match(i.get("title") or "") and not names & agent:
            kind = "operator"
        else:
            continue
        out.append({"kind": kind, "number": n, "title": i.get("title") or "",
                    "url": f"https://github.com/{slug}/issues/{n}", "resolved": _closed(i),
                    "needs": [d for d in blocked_by_last(i.get("body")) if d not in closed]})
    return sorted(out, key=lambda a: (a["resolved"], AWAITING_KINDS.index(a["kind"]), a["number"]))


def arc_projection(graph):
    """The golden shape — status-page.py's arc_model as it reads back from JSON (string keys)."""
    prds = graph["prds"]
    return {"deps": {str(p["number"]): list(p["deps"]) for p in prds},
            "kids": {str(p["number"]): dict(p["kids"]) for p in prds},
            "layers": {str(p["number"]): p["layer"] for p in prds},
            "states": {str(p["number"]): p["state"] for p in prds},
            "tickets": sorted([a["number"], a["resolved"]] for a in graph["awaiting"] if a["kind"] == "wayfinder")}

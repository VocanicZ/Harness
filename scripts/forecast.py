#!/usr/bin/env python3
"""forecast.py — `harness forecast <issue>`: per-phase cost forecast for one issue (#363, PRD #362).

Reads the host event log (stats.py, #185) for the past issue lanes (impl / bug-fix sessions) and
splits each lane's spend into phases from its Claude transcripts (main + sub-agents):

    explore  everything before the lane's first edit
    test     Edit/Write/MultiEdit/NotebookEdit on a test path
    impl     any other edit
    gate     a test/gate runner (test/run.sh, ci-local, swarm-suite, rtdd which, pytest, …)
    ship     gh pr / git push / gh issue close|edit|comment

A message's cost goes to the phase its own tool calls leave the lane in; usage is taken once per
message/request id. Tokens are priced at list price per model. A lane with no transcript (another
CLI, whose adapter folded its usage into session_end — usage_tsv, #188) adds its priced total,
spread over the phases by the attributed lanes' mean mix. A lane under MIN_LANE_USD died at turn 1
and is skipped.

The distribution is p50/p80/p95 per phase and in total, scaled by the issue's body length over the
median body of the pool's issues (clamped to SCALE_CLAMP). The pool is the issue's PRD siblings in
its repo, else every lane of the unit (its repo), else every lane on the host — each fallback is
named in the output. % of a usage window needs a $-per-% calibration (#364); until then it is n/a.

    forecast.py <issue> [-R owner/repo] [--unit U] [--json]
"""
import importlib.util, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


st = _load("stats")

PHASES = ("explore", "test", "impl", "gate", "ship")
LANE_KINDS = ("impl", "bug-fix")
MIN_LANES = 3            # fewer past lanes than this in a pool → fall back to the next, wider one
MIN_LANE_USD = 0.5       # a lane that spent less died at turn 1
SCALE_CLAMP = (0.6, 2.0)
QUANTILES = (("p50", 0.5), ("p80", 0.8), ("p95", 0.95))

# $ per Mtok at list price: input, output, 5-minute cache write, 1-hour cache write, cache read.
# A model no family matches is priced as Opus — the conservative end, for a budget gate.
PRICE = {"opus": (5, 25, 6.25, 10, 0.5), "sonnet": (3, 15, 3.75, 6, 0.3), "haiku": (1, 5, 1.25, 2, 0.1)}

EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
TEST_PATH = re.compile(r"(^|/)(tests?|spec)/|_test\.|\.test\.|(^|/)test_[^/]*$|\.bats$")
GATE_CMD = re.compile(r"test/run\.sh|ci-local|swarm-suite|\brtdd\s+(run|which)\b|\bpytest\b|\bgo test\b"
                      r"|\bbats\b|\bnpm (run )?test\b|\bvitest\b|\bcargo test\b|(^|[\s/])test_[\w.-]*\.(sh|py)\b"
                      r"|_test\.(sh|py|go)\b")
SHIP_CMD = re.compile(r"\b(gh pr|git push|gh issue (close|edit|comment))\b")


def price(model):
    m = (model or "").lower()
    return next((v for k, v in PRICE.items() if k in m), PRICE["opus"])


def raw_cost(u, model):
    """$ for one message's raw Claude usage block (cache writes split 5m / 1h when it says so)."""
    pi, po, pw5, pw1, pr = price(model)
    cc = u.get("cache_creation") or {}
    w1 = int(cc.get("ephemeral_1h_input_tokens") or 0)
    w5 = cc.get("ephemeral_5m_input_tokens")
    w5 = int(u.get("cache_creation_input_tokens") or 0) - w1 if w5 is None else int(w5)
    return (int(u.get("input_tokens") or 0) * pi + int(u.get("output_tokens") or 0) * po + w5 * pw5
            + w1 * pw1 + int(u.get("cache_read_input_tokens") or 0) * pr) / 1e6


def usage_cost(usage):
    """$ for a folded {model: {input, output, cache_create, cache_read}} (stats.py / usage_tsv)."""
    tot = 0.0
    for model, u in (usage or {}).items():
        pi, po, pw5, _, pr = price(model)
        tot += (int(u.get("input") or 0) * pi + int(u.get("output") or 0) * po
                + int(u.get("cache_create") or 0) * pw5 + int(u.get("cache_read") or 0) * pr) / 1e6
    return tot


# --- phase attribution -------------------------------------------------------
def phase_of(block, cur, edited):
    name, inp = block.get("name", ""), block.get("input") or {}
    if name in EDIT_TOOLS:
        return "test" if TEST_PATH.search(str(inp.get("file_path") or inp.get("notebook_path") or "")) else "impl"
    if name == "Bash":
        cmd = str(inp.get("command") or "")
        if SHIP_CMD.search(cmd):
            return "ship"
        if GATE_CMD.search(cmd):
            return "gate"
    return cur if edited else "explore"


def _messages(path):
    """[(key, model, usage, tool_use blocks)] in first-seen order. A streamed message is written once
    per content block under one id: its blocks are gathered and its (last) usage taken once."""
    order, by = [], {}
    try:
        fh = open(path, errors="replace")
    except OSError:
        return []
    with fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if not isinstance(r, dict) or r.get("type") != "assistant":
                continue
            m = r.get("message") or {}
            if not m.get("usage") or not m.get("model") or m.get("model") == "<synthetic>":
                continue
            key = m.get("id") or r.get("requestId") or r.get("uuid") or f"{path}:{len(order)}"
            if key not in by:
                by[key] = [key, m["model"], None, []]
                order.append(key)
            by[key][2] = m["usage"]
            content = m.get("content")
            by[key][3] += [b for b in content if isinstance(b, dict) and b.get("type") == "tool_use"] \
                if isinstance(content, list) else []
    return [tuple(by[k]) for k in order]


def transcript_phases(files):
    """{phase: $} over a lane's transcript files (main + sub-agents), each message once across all of
    them. Every file starts in explore: a sub-agent explores before it edits, too."""
    out, seen = {p: 0.0 for p in PHASES}, set()
    for f in files:
        cur, edited = "explore", False
        for key, model, usage, tools in _messages(f):
            for b in tools:
                cur = phase_of(b, cur, edited)
                edited = edited or cur in ("test", "impl")
            if key in seen:
                continue
            seen.add(key)
            out[cur] += raw_cost(usage, model)
    return out


# --- lanes -------------------------------------------------------------------
def lanes(events, find=None):
    """One lane per (repo, issue) over its impl / bug-fix sessions: {repo, issue, unit, prd, sessions,
    phases {phase: $} or None (no transcript for any session), total $}."""
    find = find or st.find_transcript
    by = {}
    for s in st.sessions(events):
        if s.get("kind") not in LANE_KINDS or s.get("issue") is None:
            continue
        key = ((s.get("repo") or "").lower(), s["issue"])
        ln = by.setdefault(key, {"repo": s.get("repo"), "issue": s["issue"], "unit": s.get("unit"),
                                 "prd": s.get("prd"), "sessions": 0, "phases": None, "unattributed": 0.0})
        ln["sessions"] += 1
        for k in ("repo", "unit", "prd"):
            ln[k] = ln[k] if ln[k] is not None else s.get(k)
        tr = find(s["session"])
        if tr:
            ph = transcript_phases(st.transcript_files(tr))
            ln["phases"] = {p: (ln["phases"] or {}).get(p, 0.0) + ph[p] for p in PHASES}
        else:
            ln["unattributed"] += usage_cost(s.get("usage"))
    for ln in by.values():
        ln["total"] = sum((ln["phases"] or {}).values()) + ln["unattributed"]
    return list(by.values())


def spread(pool):
    """Each lane's {phase: $}: its attributed phases plus its unattributed $ (no transcript) spread by
    the pool's mean phase mix — evenly when no lane in the pool has a transcript."""
    mix = {p: 0.0 for p in PHASES}
    attributed = [ln for ln in pool if ln["phases"] and sum(ln["phases"].values()) > 0]
    for ln in attributed:
        t = sum(ln["phases"].values())
        for p in PHASES:
            mix[p] += ln["phases"][p] / t / len(attributed)
    if not attributed:
        mix = {p: 1 / len(PHASES) for p in PHASES}
    return [{p: (ln["phases"] or {}).get(p, 0.0) + ln["unattributed"] * mix[p] for p in PHASES} for ln in pool]


def quantile(vals, q):
    """Nearest-rank: the value at index floor(q·n) of the sorted list, capped at the last."""
    v = sorted(vals)
    return v[min(len(v) - 1, int(q * len(v)))] if v else 0.0


def median_len(lens):
    v = sorted(x for x in lens if x)
    if not v:
        return None
    n = len(v)
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2


def size_scale(body_len, pool_lens):
    """(scale, median): body length over the pool's median body, clamped; 1.0 when either is unknown."""
    med = median_len(pool_lens)
    if not body_len or not med:
        return 1.0, med
    return max(SCALE_CLAMP[0], min(SCALE_CLAMP[1], body_len / med)), med


def choose_pool(all_lanes, repo, issue, prd):
    """(tier, pool, notes): the narrowest pool with MIN_LANES lanes — the issue's PRD siblings, then its
    unit (repo), then the host. The issue's own lanes are never in its pool. notes say why each
    narrower tier was passed over."""
    rl = (repo or "").lower()
    others = [ln for ln in all_lanes if ln["total"] >= MIN_LANE_USD
              and not ((ln["repo"] or "").lower() == rl and ln["issue"] == issue)]
    unit = [ln for ln in others if rl and (ln["repo"] or "").lower() == rl]
    notes = []
    if prd is not None:
        sib = [ln for ln in unit if ln["prd"] == prd]
        if len(sib) >= MIN_LANES:
            return "prd", sib, notes
        notes.append(f"PRD #{prd} has {len(sib)} past lane(s), need {MIN_LANES}")
    else:
        notes.append(f"#{issue} names no parent PRD")
    if len(unit) >= MIN_LANES:
        return "unit", unit, notes
    notes.append(f"unit {repo or '?'} has {len(unit)} past lane(s), need {MIN_LANES}")
    if others:
        return "host", others, notes
    return "none", [], notes


def forecast(events, repo, issue, body=None, bodies=None, unit=None, find=None):
    """The forecast dict for `issue` of `repo`. body: the issue's body text (None = unknown); bodies:
    {issue number: body} for `repo`, used for the pool's median body length and the issue's PRD."""
    bodies = bodies or {}
    all_lanes = lanes(events, find)
    rl = (repo or "").lower()
    own = [ln for ln in all_lanes if (ln["repo"] or "").lower() == rl and ln["issue"] == issue]
    prd = next((ln["prd"] for ln in own if ln["prd"] is not None), None)
    if prd is None and body:
        p = _load("issuelib").parse_parent(body, repo or "")
        if p and (not repo or p[0].lower() == rl):
            prd = p[1]
    unit = unit or next((ln["unit"] for ln in own if ln["unit"]), None) \
        or next((ln["unit"] for ln in all_lanes if (ln["repo"] or "").lower() == rl and ln["unit"]), None)
    tier, pool, notes = choose_pool(all_lanes, repo, issue, prd)
    if not own:
        notes.insert(0, f"#{issue} has no history")
    pool_lens = [len(bodies[ln["issue"]]) for ln in pool
                 if ln["issue"] in bodies and (ln["repo"] or "").lower() == rl]
    if not pool_lens:   # a host-wide pool, or no body known for its issues: the repo's issues at large
        pool_lens = [len(b) for n, b in bodies.items() if n != issue]
    body_len = len(body) if body is not None else None
    scale, med = size_scale(body_len, pool_lens)
    per = spread(pool)
    phases = {p: {q: round(quantile([x[p] for x in per], v) * scale, 2) for q, v in QUANTILES} for p in PHASES}
    totals = [ln["total"] for ln in pool]
    total = {q: round(quantile(totals, v) * scale, 2) for q, v in QUANTILES}
    return {
        "issue": issue, "repo": repo, "unit": unit, "prd": prd,
        "basis": {"tier": tier, "lanes": len(pool), "fallback": tier != "prd", "notes": notes,
                  "no_transcript": sum(1 for ln in pool if not ln["phases"])},
        "size": {"body": body_len, "median_body": med, "scale": round(scale, 2), "clamp": list(SCALE_CLAMP)},
        "phases": phases, "total": total,
        "pct": None,   # % of each usage window: needs the $-per-% calibration (#364)
        "spent": {"sessions": sum(ln["sessions"] for ln in own), "usd": round(sum(ln["total"] for ln in own), 2)},
    }


def render(f):
    tier = {"prd": f"PRD #{f['prd']} siblings", "unit": f"unit {f['unit'] or f['repo']}",
            "host": "host-wide", "none": "none"}[f["basis"]["tier"]]
    b = f["basis"]
    out = [f"forecast #{f['issue']} {f['repo'] or '?'}" + (f" (unit {f['unit']})" if f["unit"] else "")]
    line = f"  basis: {tier} — {b['lanes']} past lane(s)"
    if b["no_transcript"]:
        line += f", {b['no_transcript']} without a transcript (spread by the phase mix)"
    out.append(line)
    if b["fallback"]:
        out.append(f"  FALLBACK to {tier}: " + "; ".join(b["notes"]))
    s = f["size"]
    if s["body"] is None or s["median_body"] is None:
        out.append(f"  size: scale x{s['scale']:.2f} (body length unknown)")
    else:
        out.append(f"  size: body {s['body']} chars vs median {s['median_body']:.0f} → scale x{s['scale']:.2f} "
                   f"(clamped {s['clamp'][0]}–{s['clamp'][1]})")
    out.append(f"  {'phase':8} {'p50 $':>8} {'p80 $':>8} {'p95 $':>8}   % of window")
    for p in PHASES:
        r = f["phases"][p]
        out.append(f"  {p:8} {r['p50']:8.2f} {r['p80']:8.2f} {r['p95']:8.2f}   n/a")
    t = f["total"]
    out.append(f"  {'TOTAL':8} {t['p50']:8.2f} {t['p80']:8.2f} {t['p95']:8.2f}   n/a")
    out.append("  % of each usage window: n/a until a $-per-% calibration exists (#364)")
    if f["spent"]["sessions"]:
        out.append(f"  already spent on #{f['issue']}: ${f['spent']['usd']:.2f} over {f['spent']['sessions']} session(s)")
    return "\n".join(out)


# --- project / GitHub --------------------------------------------------------
def project_units(state_dir):
    """[(unit, repo)] of the project at state_dir: targets.tsv rows, or the single topology's `main`."""
    if not state_dir:
        return []
    cfg = {}
    try:
        with open(os.path.join(state_dir, "config")) as fh:
            for m in re.finditer(r'(HARNESS_(?:TOPOLOGY|REPO|OWNER)):=([^}"]*)', fh.read()):
                cfg[m.group(1)] = m.group(2)
    except OSError:
        pass
    # The config file only, never the environment: a lane session exports its own HARNESS_REPO (#186).
    owner = cfg.get("HARNESS_OWNER")
    own = lambda r: r if "/" in r or not owner else f"{owner}/{r}"
    if cfg.get("HARNESS_TOPOLOGY") == "single":
        return [("main", own(cfg["HARNESS_REPO"]))] if cfg.get("HARNESS_REPO") else []
    out = []
    try:
        with open(os.environ.get("TARGETS_TSV") or os.path.join(state_dir, "targets.tsv")) as fh:
            for line in fh:
                cols = line.rstrip("\n").split("\t")
                if not line.startswith("#") and len(cols) >= 2 and cols[0]:
                    out.append((cols[0], own(cols[1])))
    except OSError:
        pass
    return out


def resolve_repo(issue, repo, unit, events, state_dir):
    """(repo, unit) or raise ValueError: -R wins; else the issue's own lanes; else the project's unit."""
    units = project_units(state_dir)
    if unit and not repo:
        repo = next((r for u, r in units if u == unit), None)
        if not repo:
            raise ValueError(f"no unit {unit!r} in this project")
    if not repo:
        mine = {s.get("repo") for s in st.sessions(events)
                if s.get("issue") == issue and s.get("kind") in LANE_KINDS and s.get("repo")}
        if len(mine) == 1:
            repo = mine.pop()
        elif len(units) == 1:
            repo, unit = units[0][1], unit or units[0][0]
        else:
            raise ValueError(f"cannot tell which repo #{issue} is in — pass -R owner/repo or --unit")
    unit = unit or next((u for u, r in units if r.lower() == repo.lower()), None)
    return repo, unit


def gh_bodies(repo, issue):
    """(body of `issue` or None, {number: body} of the repo's issues) from gh; ({} / None) on failure."""
    def gh(args):
        try:
            return subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=60).stdout
        except Exception:
            return ""
    bodies = {}
    try:
        for it in json.loads(gh(["issue", "list", "-R", repo, "--state", "all", "--limit", "1000",
                                 "--json", "number,body"]) or "[]"):
            bodies[it["number"]] = it.get("body") or ""
    except (ValueError, KeyError, TypeError):
        pass
    body = bodies.get(issue)
    if body is None:
        try:
            body = json.loads(gh(["issue", "view", str(issue), "-R", repo, "--json", "body"]) or "{}").get("body")
        except ValueError:
            body = None
    return body, bodies


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(prog="harness forecast",
                                 description="per-phase p50/p80/p95 cost forecast for one issue (#363)")
    ap.add_argument("issue", type=int)
    ap.add_argument("-R", "--repo", help="owner/repo (default: the issue's own lanes, else the project's unit)")
    ap.add_argument("--unit", help="unit of the current project (multi-unit projects)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--events", help=argparse.SUPPRESS)
    ap.add_argument("--bodies", help=argparse.SUPPRESS)   # test seam: gh `issue list --json number,body` output
    a = ap.parse_args(sys.argv[1:] if argv is None else argv)
    events = st.load_events(a.events)
    try:
        repo, unit = resolve_repo(a.issue, a.repo, a.unit, events, os.environ.get("STATE_DIR"))
    except ValueError as e:
        print(f"harness forecast: {e}", file=sys.stderr)
        return 2
    if a.bodies:
        with open(a.bodies) as fh:
            bodies = {it["number"]: it.get("body") or "" for it in json.load(fh)}
        body = bodies.get(a.issue)
    else:
        body, bodies = gh_bodies(repo, a.issue)
    f = forecast(events, repo, a.issue, body, bodies, unit)
    print(json.dumps(f, indent=2) if a.json else render(f))
    if f["basis"]["tier"] == "none":
        print("harness forecast: no past lanes on this host to forecast from", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

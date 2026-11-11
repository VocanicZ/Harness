#!/usr/bin/env python3
"""bench/crossover.py — when is Harness worth it? One Claude Code session against Harness at three sizes (#621, PRD #345).

Reads the aggregates `bench/run.py --runs N` wrote for the plain arm and the Harness arms on the small
(`pennywise`), medium (`medium`) and large (`large`) fixtures and answers with data:

    size x arm table   wall time, cost, quality (hidden tests, fuzz classes, blind review), nudges, interventions
    crossover          the smallest size where Harness matches or beats plain on QUALITY, and the smallest where
                       Harness with a pool of 3 also matches or beats it on TIME
    thresholds         the tier thresholds (scripts/tier.toml, "when to use Harness", #619) recalibrated from it
    README section     "When to use Harness", built from the table

    bench/crossover.py                          # the table, crossovers and thresholds as text
    bench/crossover.py --json                   # the same as one JSON object
    bench/crossover.py --markdown               # the README's "When to use Harness" section
    bench/crossover.py --write-readme README.md # replace the section between its markers
    bench/crossover.py --write-tier scripts/tier.toml   # rewrite the calibrated lines of tier.toml
    bench/crossover.py --check                  # exit 1 when README.md or tier.toml disagree with the results

The runs behind each size are named in `bench/results/crossover.inputs.json` (`{"small": "run-ID", ...}`; a size
with no entry is "not run"). `--run SIZE=RUN_ID` overrides one. Stdlib only.

THE RULES (stated here so a number is never moved by a judgement made after seeing it):

* A cell is the median and range over the runs of one arm on one fixture. A cell with fewer than 5 runs is
  INDICATIVE (labelled with its n) and supports no claim; a verdict needs 5 on both sides (#591).
* QUALITY, Harness against plain: Harness must be no worse on EVERY gate it has a number for (hidden-test pass
  rate not lower; median fuzz root-cause classes not higher; blind review score not lower by more than 0.5, the
  ship rule's tolerance, #620) -> `matches`, or `beats` when it is also strictly better on at least one. Else `behind`.
* TIME: the Harness arm's median wall time at most plain's (a pool of 3 is the one that can).
* COST: ratio of medians, reported; it decides nothing.
* CROSSOVER: the smallest size (small < medium < large) with a stated quality verdict of `matches` or `beats`
  (quality), and the smallest where that holds for the pool-3 arm and its TIME verdict is also met (time).
* THRESHOLDS move only when bracketed: a direct limit rises to the size of the largest stated size where Harness
  does not cross over on time (plain is sufficient there); a fleet floor falls to the size of the smallest where
  it crosses over on both. A size that was not run, or has fewer than 5 runs, moves nothing. The `[estimate]`
  lines are re-fitted from the measured medians (they only show a time and a cost; they decide nothing).
"""
import argparse, importlib.util, json, math, os, re, sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RESULTS = os.path.join(HERE, "results")
INPUTS = "crossover.inputs.json"
SIZES = ("small", "medium", "large")
FIXTURE = {"small": "pennywise", "medium": "medium", "large": "large"}
ARMS = ("plain", "harness", "harness-3", "harness-opus")
HEADLINE = ("plain", "harness", "harness-3")
MIN_RUNS = 5
REVIEW_TOLERANCE = 0.5
START, END = "<!-- when-to-use:start -->", "<!-- when-to-use:end -->"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


aggregate = _load("crossover_aggregate", os.path.join(HERE, "aggregate.py"))
fixtures = _load("crossover_fixtures", os.path.join(HERE, "fixtures.py"))


# --- what a fixture weighs ----------------------------------------------------------------
def descriptor(size):
    """The tier check's inputs for a fixture, measured the same way every time: `criteria` is the bullet items in the
    brief, `lines` the non-blank non-comment Python lines of the reference, `files` its .py files, `subsystems` the
    manifest's (default 1)."""
    fx = fixtures.load(FIXTURE[size])
    with open(fx.brief, encoding="utf-8") as fh:
        criteria = sum(1 for line in fh if re.match(r"\s*([-*]|[0-9]+\.)\s", line))
    lines = files = 0
    for base, _, names in os.walk(fx.reference):
        for name in names:
            if name.endswith(".py"):
                files += 1
                with open(os.path.join(base, name), encoding="utf-8") as fh:
                    lines += sum(1 for line in fh if line.strip() and not line.strip().startswith("#"))
    manifest = {}
    path = os.path.join(fx.dir, "fixture.json")
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            manifest = json.load(fh)
    return {"criteria": criteria, "lines": lines, "files": files, "subsystems": int(manifest.get("subsystems", 1))}


# --- cells ----------------------------------------------------------------------------------
def _m(metrics, name):
    s = (metrics or {}).get(name)
    return s if isinstance(s, dict) and s.get("n") else None


def cell(doc):
    """One arm on one fixture, from its results JSON (an aggregate, or a single run shown as n=1)."""
    if doc.get("status") != "aggregate":
        doc = dict(doc, status=doc.get("status"))
        agg = aggregate.aggregate([doc])
        n, requested, stopped = agg["n"], 1, None
        metrics = agg["metrics"]
    else:
        n, requested, stopped = doc.get("runs_completed") or 0, doc.get("runs_requested"), doc.get("stopped")
        metrics = (doc.get("aggregate") or {}).get("metrics") or {}
    passed, total = _m(metrics, "hidden_passed"), _m(metrics, "hidden_total")
    pct = None
    if passed and total and total["median"]:
        pct = {k: round(100.0 * passed[k] / total["median"], 1) for k in ("median", "min", "max")}
    out = {"n": n, "requested": requested, "stopped": stopped, "hidden_pct": pct}
    for key in ("wall_s", "cost_usd", "fuzz_classes", "fuzz_divergences", "review_score", "continue_replies", "compactions",
                "regressions", "coverage"):
        s = _m(metrics, key)
        out[key] = {k: s[k] for k in ("median", "min", "max")} if s else None
    out["cap_hits"] = doc.get("cap_hits") or (doc.get("aggregate") or {}).get("cap_hits")
    # a human intervention is anything typed into a run by hand: the runner has no input channel, so it is 0 unless a
    # run's own counts say otherwise
    out["interventions"] = (_m(metrics, "human_interventions") or {}).get("max", 0)
    return out


def read_inputs(results_dir, overrides):
    path = os.path.join(results_dir, INPUTS)
    runs = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            runs = {k: v for k, v in json.load(fh).items() if k in SIZES and v}
    runs.update(overrides)
    return runs


def follow_up(results_dir):
    """The issue that runs what is still missing (`"follow_up": "#N"` in the inputs file), or None."""
    path = os.path.join(results_dir, INPUTS)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as fh:
        v = json.load(fh).get("follow_up")
    return v if isinstance(v, str) and re.fullmatch(r"#[0-9]+", v) else None


def gather(results_dir, runs):
    """{size: {arm: cell}} for the sizes that have a run id and the arms whose results file exists."""
    table = {}
    for size in SIZES:
        run_id = runs.get(size)
        if not run_id:
            continue
        for arm in ARMS:
            path = os.path.join(results_dir, run_id, arm + ".json")
            if os.path.isfile(path):
                with open(path, encoding="utf-8") as fh:
                    table.setdefault(size, {})[arm] = cell(json.load(fh))
    return table


# --- verdicts -------------------------------------------------------------------------------
def med(c, key):
    return None if not c or not c.get(key) else c[key]["median"]


def quality(h, p):
    """(verdict, reasons): matches / beats / behind / unknown, Harness cell `h` against plain `p`."""
    better, worse, seen = [], [], 0
    pairs = (("hidden_pct", "hidden tests", +1, 0.0), ("fuzz_classes", "fuzz classes", -1, 0.0),
             ("review_score", "blind review", +1, REVIEW_TOLERANCE))
    for key, label, sign, tol in pairs:
        a, b = med(h, key), med(p, key)
        if a is None or b is None:
            continue
        seen += 1
        diff = sign * (a - b)
        if diff < -tol - 1e-9:
            worse.append(label)
        elif diff > 1e-9:
            better.append(label)
    if not seen:
        return "unknown", []
    return ("behind", worse) if worse else (("beats", better) if better else ("matches", []))


def stated(*cells):
    return all(c and c["n"] >= MIN_RUNS for c in cells)


def verdicts(table):
    """{size: {arm: {quality, why, time_ratio, cost_ratio, time_met, stated}}} for each Harness arm against plain."""
    out = {}
    for size, arms in table.items():
        p = arms.get("plain")
        for arm in ("harness", "harness-3", "harness-opus"):
            h = arms.get(arm)
            if not (p and h):
                continue
            q, why = quality(h, p)
            tw, pw, hc, pc = med(h, "wall_s"), med(p, "wall_s"), med(h, "cost_usd"), med(p, "cost_usd")
            out.setdefault(size, {})[arm] = {
                "quality": q, "why": why,
                "time_ratio": round(tw / pw, 2) if tw and pw else None,
                "cost_ratio": round(hc / pc, 2) if hc and pc else None,
                "time_met": bool(tw and pw and tw <= pw), "stated": stated(h, p)}
    return out


def crossovers(table, verd):
    """{"quality": size|None, "time": size|None, "unstated": [sizes with a verdict but fewer than 5 runs a side]}."""
    res = {"quality": None, "time": None, "unstated": []}
    for size in SIZES:
        v1, v3 = (verd.get(size) or {}).get("harness"), (verd.get(size) or {}).get("harness-3")
        for v in (v1, v3):
            if v and not v["stated"] and size not in res["unstated"]:
                res["unstated"].append(size)
        qual = [v for v in (v1, v3) if v and v["stated"] and v["quality"] in ("matches", "beats")]
        if res["quality"] is None and qual:
            res["quality"] = size
        if res["time"] is None and v3 and v3["stated"] and v3["quality"] in ("matches", "beats") and v3["time_met"]:
            res["time"] = size
    return res


# --- thresholds -----------------------------------------------------------------------------
# The thresholds as #619 shipped them (provisional). Every derivation starts from THESE, never from the file it is
# about to rewrite, so running it twice gives the same file and `--check` is stable.
PROVISIONAL = {
    "direct": {"max_criteria": 8, "max_changed_lines": 500, "max_files": 10, "max_subsystems": 1, "max_unattended_minutes": 45},
    "fleet": {"min_criteria": 16, "min_subsystems": 3, "min_workstreams": 2, "min_pool": 2, "min_unattended_minutes": 120},
    "estimate": {"direct_minutes_base": 3, "direct_minutes_per_criterion": 1.5, "direct_usd_base": 0.30,
                 "direct_usd_per_criterion": 0.10, "fleet_minutes_base": 12, "fleet_minutes_per_criterion": 2,
                 "fleet_usd_base": 2.50, "fleet_usd_per_criterion": 0.30},
}


def derive(table, verd, cross, current):
    """The thresholds `current` (tier.py's loaded config) becomes, and the reasons each one did or did not move."""
    cfg = json.loads(json.dumps(current))
    notes = []
    sizes = {s: descriptor(s) for s in table}
    dims = (("criteria", "max_criteria", "min_criteria"), ("lines", "max_changed_lines", None),
            ("files", "max_files", None), ("subsystems", "max_subsystems", "min_subsystems"))
    # a direct limit rises to the largest size where plain is sufficient: stated, and Harness does not cross over on time
    sufficient = [s for s in SIZES if s in verd and (verd[s].get("harness-3") or verd[s].get("harness"))
                  and all(v["stated"] for v in verd[s].values() if v) and s != cross["time"]
                  and (cross["time"] is None or SIZES.index(s) < SIZES.index(cross["time"]))]
    if sufficient:
        top = sizes[sufficient[-1]]
        for dim, dkey, _ in dims:
            if top[dim] > cfg["direct"][dkey]:
                notes.append("direct.%s %s -> %s (plain is sufficient at %s)" % (dkey, cfg["direct"][dkey], top[dim], sufficient[-1]))
                cfg["direct"][dkey] = top[dim]
    if cross["time"]:
        at = sizes[cross["time"]]
        for dim, _, fkey in dims:
            if fkey and at[dim] < cfg["fleet"][fkey]:
                notes.append("fleet.%s %s -> %s (Harness crosses over at %s)" % (fkey, cfg["fleet"][fkey], at[dim], cross["time"]))
                cfg["fleet"][fkey] = at[dim]
    for dim, dkey, fkey in dims:   # direct < fleet in every dimension they share
        if fkey and cfg["fleet"][fkey] <= cfg["direct"][dkey]:
            cfg["fleet"][fkey] = cfg["direct"][dkey] + 1
    if not notes:
        notes.append("no limit moved: %s" % ("no size has a stated verdict (fewer than %d runs a side, or not run)" % MIN_RUNS
                                              if not any(v["stated"] for s in verd.values() for v in s.values())
                                              else "the stated sizes do not bracket a limit"))
    fit_estimates(cfg, table, sizes, notes)
    return cfg, notes, sizes


def fit_estimates(cfg, table, sizes, notes):
    """`[estimate]` from the measured medians, least squares on criteria, only when two sizes or more are measured for
    the arm: one point cannot give a slope, and a line through one point and the old slope is a guess."""
    e = cfg["estimate"]
    for path, arm in (("direct", "plain"), ("fleet", "harness")):
        pts = {"minutes": [], "usd": []}
        for size, arms in table.items():
            c = arms.get(arm)
            if c and c["n"] >= 1 and med(c, "wall_s") and med(c, "cost_usd"):
                pts["minutes"].append((sizes[size]["criteria"], med(c, "wall_s") / 60.0))
                pts["usd"].append((sizes[size]["criteria"], med(c, "cost_usd")))
        for unit, data in pts.items():
            if len(data) < 2:
                continue
            bkey, skey = "%s_%s_base" % (path, unit), "%s_%s_per_criterion" % (path, unit)
            n = len(data)
            sx, sy = sum(x for x, _ in data), sum(y for _, y in data)
            sxx, sxy = sum(x * x for x, _ in data), sum(x * y for x, y in data)
            den = n * sxx - sx * sx
            slope = max((n * sxy - sx * sy) / den, 0.0) if den else e[skey]
            base = max((sy - slope * sx) / n, 0.0)
            new = (round(base, 2), round(slope, 3))
            if (e[bkey], e[skey]) != new:
                notes.append("estimate.%s %s -> %s, %s %s -> %s (fitted to %d measured sizes)" % (
                    bkey, e[bkey], new[0], skey, e[skey], new[1], n))
            e[bkey], e[skey] = new
    if not any(n.startswith("estimate.") for n in notes):
        notes.append("the [estimate] lines are unchanged (they need two measured sizes)")


# --- rendering ------------------------------------------------------------------------------
def fmt_range(s, scale=1.0, nd=1, unit=""):
    if not s:
        return "—"
    f = lambda v: ("%.*f" % (nd, v / scale)).rstrip("0").rstrip(".") if nd else "%d" % round(v / scale)
    one = f(s["median"]) + unit
    return one if s["min"] == s["max"] else "%s (%s–%s)" % (one, f(s["min"]), f(s["max"]))


def fmt_time(s):
    if not s:
        return "—"
    mins = s["median"] / 60.0
    unit, scale = ("min", 60.0) if mins < 120 else ("h", 3600.0)
    return fmt_range(s, scale, 1, " " + unit)


def row_cells(c):
    n = "n=%d" % c["n"] + ("" if c["n"] >= MIN_RUNS else ", indicative")
    hid = "—" if not c["hidden_pct"] else fmt_range(c["hidden_pct"], 1.0, 1, "%")
    return [n, fmt_time(c["wall_s"]), "$" + fmt_range(c["cost_usd"], 1.0, 2) if c["cost_usd"] else "—", hid,
            fmt_range(c["fuzz_classes"], 1.0, 0), fmt_range(c["review_score"], 1.0, 1), fmt_range(c["continue_replies"], 1.0, 0),
            "%d" % c["interventions"]]


HEAD = ["arm", "runs", "wall time", "cost", "hidden tests", "fuzz classes", "blind review /10", "nudges", "interventions"]


def table_md(table):
    lines = []
    for size in SIZES:
        arms = table.get(size)
        if not arms:
            lines += ["**%s** (`%s`): not run" % (size, FIXTURE[size]), ""]
            continue
        d = descriptor(size)
        lines += ["**%s** (`%s`: %d criteria, %d lines, %d files, %d subsystem%s)" % (
            size, FIXTURE[size], d["criteria"], d["lines"], d["files"], d["subsystems"], "" if d["subsystems"] == 1 else "s"), "",
            "| " + " | ".join(HEAD) + " |", "|" + "---|" * len(HEAD)]
        for arm in ARMS:
            if arm in arms:
                lines.append("| " + " | ".join([arm] + row_cells(arms[arm])) + " |")
        lines.append("")
    return "\n".join(lines).rstrip("\n")


def verdict_md(verd):
    rows = ["| size | arm | quality vs plain | time vs plain | cost vs plain | verdict |", "|---|---|---|---|---|---|"]
    for size in SIZES:
        for arm, v in (verd.get(size) or {}).items():
            why = " (%s)" % ", ".join(v["why"]) if v["why"] else ""
            rows.append("| %s | %s | %s%s | %s | %s | %s |" % (
                size, arm, v["quality"], why, "—" if v["time_ratio"] is None else "×%s" % v["time_ratio"],
                "—" if v["cost_ratio"] is None else "×%s" % v["cost_ratio"], "stated" if v["stated"] else "indicative (n<%d)" % MIN_RUNS))
    return "\n".join(rows) if len(rows) > 2 else "No size has both a plain and a Harness arm yet."


def build(results_dir, runs):
    table = gather(results_dir, runs)
    verd = verdicts(table)
    cross = crossovers(table, verd)
    cfg, notes, sizes = derive(table, verd, cross, PROVISIONAL)
    return {"follow_up": follow_up(results_dir), "runs": runs, "sizes": {s: descriptor(s) for s in SIZES}, "table": table, "verdicts": verd, "crossover": cross,
            "thresholds": {"direct": cfg["direct"], "fleet": cfg["fleet"], "estimate": cfg["estimate"]}, "notes": notes}


def crossover_text(cross):
    def line(label, size):
        return "%s: %s." % (label, "at the %s fixture" % size if size else "not reached at a size with 5 runs a side")
    out = [line("Quality (Harness matches or beats plain)", cross["quality"]),
           line("Time (Harness with 3 workers also matches or beats plain)", cross["time"])]
    if cross["unstated"]:
        out.append("Indicative only (fewer than %d runs a side): %s." % (MIN_RUNS, ", ".join(cross["unstated"])))
    return out


def _cap(text):
    return text[:1].upper() + text[1:]


def todo_text(doc):
    """What is still to run, and the issue that runs it."""
    missing = [s for s in SIZES if s not in doc["table"] or "plain" not in doc["table"][s]]
    thin = [s for s in doc["crossover"]["unstated"] if s not in missing]
    if not (missing or thin):
        return ""
    bits = (["not run: " + ", ".join(missing)] if missing else []) + (["fewer than %d runs: %s" % (MIN_RUNS, ", ".join(thin))] if thin else [])
    return " Still to run (%s)%s." % ("; ".join(bits), " in " + doc["follow_up"] if doc.get("follow_up") else "")


def markdown(doc):
    runs = doc["runs"]
    src = ", ".join("%s `%s`" % (s, runs[s]) for s in SIZES if s in runs) or "no run yet"
    cross = doc["crossover"]
    th = doc["thresholds"]
    out = ["## When to use Harness", "",
           "Generated by `bench/crossover.py` from `bench/results/` (%s). One Claude Code session start to finish against "
           "Harness start to finish, no human help for either, at three sizes, median and (range) over the runs. A cell "
           "with fewer than %d runs is marked indicative and supports no claim." % (src, MIN_RUNS), "",
           table_md(doc["table"]), "", "**Harness against plain**", "", verdict_md(doc["verdicts"]), "",
           "**The crossover.** " + " ".join(crossover_text(cross)) + todo_text(doc), "",
           "**The tier thresholds** (`scripts/tier.toml`, read by `harness tier decide`): direct up to %d criteria, %d changed "
           "lines, %d files and %d subsystem%s; fleet from %d criteria, %d subsystems or %d independent workstreams with a pool "
           "of %d. %s" % (th["direct"]["max_criteria"], th["direct"]["max_changed_lines"], th["direct"]["max_files"],
                          th["direct"]["max_subsystems"], "" if th["direct"]["max_subsystems"] == 1 else "s",
                          th["fleet"]["min_criteria"], th["fleet"]["min_subsystems"], th["fleet"]["min_workstreams"],
                          th["fleet"]["min_pool"], _cap("; ".join(doc["notes"]) + ".")), ""]
    return "\n".join(out)


def text(doc):
    return "\n".join([table_md(doc["table"]), "", verdict_md(doc["verdicts"]), ""] + crossover_text(doc["crossover"]) + [todo_text(doc).strip()] +
                     [""] + ["thresholds: " + n for n in doc["notes"]])


# --- writing --------------------------------------------------------------------------------
def write_readme(path, doc):
    with open(path, encoding="utf-8") as fh:
        body = fh.read()
    section = "%s\n%s\n%s" % (START, markdown(doc).rstrip("\n"), END)
    if START in body and END in body:
        new = re.sub(re.escape(START) + r".*?" + re.escape(END), lambda m: section, body, count=1, flags=re.S)
    else:
        new = body.rstrip("\n") + "\n\n" + section + "\n"
    if new != body:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(new)
    return new != body


CAL_START, CAL_END = "# --- calibration:start (bench/crossover.py writes this block) ---", "# --- calibration:end ---"


def tier_block(doc):
    th = doc["thresholds"]
    runs = ", ".join("%s=%s" % (s, doc["runs"][s]) for s in SIZES if s in doc["runs"]) or "none yet"
    lines = [CAL_START, "# measured by #621 from: %s" % runs]
    lines += ["# %s" % l for l in crossover_text(doc["crossover"])]
    lines += ["# %s" % n for n in doc["notes"]]
    lines += ["calibrated_from = \"%s\"" % runs.replace('"', "'"), CAL_END]
    return "\n".join(lines)


def write_tier(path, doc):
    """Put the derived numbers into the existing keys of tier.toml (comments and layout kept) and refresh the block."""
    with open(path, encoding="utf-8") as fh:
        body = fh.read()
    new = body
    sec = None
    out = []
    for line in new.split("\n"):
        m = re.match(r"\[(\w+)\]", line)
        if m:
            sec = m.group(1)
        k = re.match(r"(\s*)(\w+)(\s*=\s*)([-0-9.eE+]+)(.*)$", line)
        if k and sec in doc["thresholds"] and k.group(2) in doc["thresholds"][sec]:
            v = doc["thresholds"][sec][k.group(2)]
            if float(k.group(4)) != float(v):   # an unchanged value keeps its spelling (0.30 stays 0.30)
                line = "%s%s%s%s%s" % (k.group(1), k.group(2), k.group(3), v, k.group(5))
        out.append(line)
    new = "\n".join(out)
    block = tier_block(doc)
    if CAL_START in new:
        new = re.sub(re.escape(CAL_START) + r".*?" + re.escape(CAL_END), lambda m: block, new, count=1, flags=re.S)
    else:
        new = new.rstrip("\n") + "\n\n" + block + "\n"
    if new != body:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(new)
    return new != body


def check(doc, readme, tier_path):
    """[problem] when the README section or tier.toml disagree with what the results derive."""
    problems = []
    with open(readme, encoding="utf-8") as fh:
        body = fh.read()
    want = "%s\n%s\n%s" % (START, markdown(doc).rstrip("\n"), END)
    if want not in body:
        problems.append("%s: the \"When to use Harness\" section is not what bench/crossover.py --markdown prints" % readme)
    with open(tier_path, encoding="utf-8") as fh:
        have = fh.read()
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "tier.toml")
        with open(copy, "w", encoding="utf-8") as fh:
            fh.write(have)
        write_tier(copy, doc)
        with open(copy, encoding="utf-8") as fh:
            if fh.read() != have:
                problems.append("%s: its thresholds are not what bench/crossover.py --write-tier derives" % tier_path)
    return problems


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--results-dir", default=RESULTS)
    ap.add_argument("--run", action="append", default=[], metavar="SIZE=RUN_ID", help="override the run behind a size")
    ap.add_argument("--tier", default=os.path.join(ROOT, "scripts", "tier.toml"))
    ap.add_argument("--readme", default=os.path.join(ROOT, "README.md"))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--write-readme", metavar="README")
    ap.add_argument("--write-tier", metavar="TOML")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    over = {}
    for item in a.run:
        size, _, run_id = item.partition("=")
        if size not in SIZES or not run_id:
            print("crossover.py: --run wants SIZE=RUN_ID with SIZE one of %s" % ", ".join(SIZES), file=sys.stderr)
            return 2
        over[size] = run_id
    doc = build(a.results_dir, read_inputs(a.results_dir, over))
    if a.check:
        problems = check(doc, a.readme, a.tier)
        for p in problems:
            print(p, file=sys.stderr)
        return 1 if problems else 0
    if a.write_tier:
        write_tier(a.write_tier, doc)
    if a.write_readme:
        write_readme(a.write_readme, doc)
    if a.json:
        print(json.dumps(doc, indent=2))
    elif a.markdown:
        print(markdown(doc))
    elif not (a.write_tier or a.write_readme):
        print(text(doc))
    return 0


if __name__ == "__main__":
    sys.exit(main())

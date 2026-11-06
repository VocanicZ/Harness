#!/usr/bin/env python3
"""bench/aggregate.py — median and range over the runs of one arm (#591, PRD #345). Stdlib only.

`bench/run.py --runs N` runs an arm N times, each in its own private repo, and records every run as its own
results JSON beside an aggregate (`<arm>.json`, `status: "aggregate"`). This module holds what both
`bench/run.py` (writing the aggregate) and `bench/figures.py` (reading it, and recomputing it for `--check`)
share: which numbers of a results JSON are aggregated, how a list of them is summarised, and the schema of the
aggregate record.

    extract(doc)          {metric: number} of one run's results JSON (a metric the run lacks is left out)
    summarize(values)     {"n", "median", "min", "max"} of the numbers in `values`, or None when there are none
    aggregate(docs)       {"n": runs counted, "metrics": {metric: summary}} over the runs that completed
    validate_aggregate(d) [problem] for an aggregate record

Only runs that finished (`status` ok or capped) are counted: an errored run has no usable measurement. A capped
run is counted at what it spent before its cap stopped it, and its cap is recorded on the run itself.
"""
import statistics

COMPLETED = ("ok", "capped")
STOP_REASONS = ("guard", "arm-error", "repo-not-deleted")
SCHEMA = 1


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def tokens_total(doc):
    t = doc.get("tokens")
    if not isinstance(t, dict):
        return None
    vals = [num(t.get(k)) for k in ("input", "output", "cache_read", "cache_write")]
    return None if all(v is None for v in vals) else sum(v or 0 for v in vals)


def _token(key):
    def get(doc):
        t = doc.get("tokens")
        return num(t.get(key)) if isinstance(t, dict) else None
    return get


def _hidden(key):
    def get(doc):
        h = doc.get("hidden_tests")
        if not isinstance(h, dict) or num(h.get("total")) is None:   # an ungraded run has no pass count
            return None
        return num(h.get(key))
    return get


def _sonar(key):
    def get(doc):
        s = doc.get("sonarqube")
        return num(s.get(key)) if isinstance(s, dict) else None
    return get


def _count(key):
    def get(doc):
        c = doc.get("counts")
        return num(c.get(key)) if isinstance(c, dict) else None
    return get


def _field(key):
    return lambda doc: num(doc.get(key))


# metric name -> how to read it from one run's results JSON, in the order a record lists them
METRICS = {
    "wall_s": _field("wall_s"), "coding_s": _field("coding_s"), "testing_s": _field("testing_s"),
    "test_calls": _field("test_calls"), "cost_usd": _field("cost_usd"),
    "weekly_window_pct": _field("weekly_window_pct"), "tokens": tokens_total,
    "tokens_input": _token("input"), "tokens_output": _token("output"),
    "tokens_cache_read": _token("cache_read"), "tokens_cache_write": _token("cache_write"),
    "hidden_passed": _hidden("passed"), "hidden_total": _hidden("total"),
    "fuzz_divergences": _field("fuzz_divergences"), "fuzz_cases": _field("fuzz_cases"),
    "coverage": _sonar("coverage"), "sonar_bugs": _sonar("bugs"), "sonar_vulnerabilities": _sonar("vulnerabilities"),
    "sonar_code_smells": _sonar("code_smells"), "sonar_duplicated_lines_density": _sonar("duplicated_lines_density"),
    "issues_closed": _count("issues_closed"), "prs_merged": _count("prs_merged"), "commits": _count("commits"),
    "continue_replies": _count("continue_replies"),
}


def extract(doc):
    """{metric: number} of one run's results JSON; a metric the run did not produce is left out."""
    out = {}
    for name, get in METRICS.items():
        v = get(doc)
        if v is not None:
            out[name] = v
    return out


def summarize(values):
    """{"n", "median", "min", "max"} over the numbers in `values`, or None when there are none."""
    vals = [v for v in values if num(v) is not None]
    if not vals:
        return None
    return {"n": len(vals), "median": round(statistics.median(vals), 4), "min": round(min(vals), 4),
            "max": round(max(vals), 4)}


def completed(docs):
    return [d for d in docs if d.get("status") in COMPLETED]


def aggregate(docs):
    """{"n", "metrics"} over the runs in `docs` that completed. Deterministic: the same runs, the same bytes."""
    done = completed(docs)
    rows = [extract(d) for d in done]
    metrics = {}
    for name in METRICS:
        s = summarize([r.get(name) for r in rows])
        if s is not None:
            metrics[name] = s
    return {"n": len(done), "metrics": metrics}


def validate_aggregate(d):
    """[problem] — empty when `d` is a well-formed aggregate record (bench/README.md)."""
    def isint(v):
        return isinstance(v, int) and not isinstance(v, bool)
    bad = []
    for k, t in (("schema", int), ("run_id", str), ("arm", str), ("status", str), ("runs_requested", int),
                 ("runs_completed", int), ("runs", list), ("aggregate", dict)):
        if k not in d or not isinstance(d[k], t) or (t is int and isinstance(d[k], bool)):
            bad.append(f"missing {k}" if k not in d else f"{k}: {type(d[k]).__name__}")
    if "stopped" not in d or not (d["stopped"] is None or isinstance(d["stopped"], dict)):
        bad.append("missing stopped" if "stopped" not in d else f"stopped: {type(d['stopped']).__name__}")
    if bad:
        return bad
    if d["schema"] != SCHEMA or d["status"] != "aggregate":
        bad.append("an aggregate record must be schema 1, status aggregate")
    if d["runs_requested"] < 1 or not 0 <= d["runs_completed"] <= len(d["runs"]) <= d["runs_requested"]:
        bad.append("runs_completed <= len(runs) <= runs_requested, and runs_requested >= 1")
    for r in d["runs"]:
        if not (isinstance(r, dict) and isint(r.get("run")) and isinstance(r.get("file"), str)
                and isinstance(r.get("status"), str)):
            bad.append("runs: each is {run, file, status}")
            break
    if not bad and sum(1 for r in d["runs"] if r["status"] in COMPLETED) != d["runs_completed"]:
        bad.append("runs_completed does not match the runs that are ok or capped")
    st = d["stopped"]
    if st is None:
        if d["runs_completed"] != d["runs_requested"]:
            bad.append("stopped is null but fewer runs completed than were requested: record why")
    elif not (st.get("reason") in STOP_REASONS and isinstance(st.get("detail"), str)):
        bad.append("stopped: want {reason: " + "|".join(STOP_REASONS) + ", detail}")
    agg = d["aggregate"]
    if not isinstance(agg.get("metrics"), dict) or agg.get("n") != d["runs_completed"]:
        bad.append("aggregate: want {n == runs_completed, metrics}")
    else:
        for name, s in agg["metrics"].items():
            if name not in METRICS or not (isinstance(s, dict) and sorted(s) == ["max", "median", "min", "n"]
                                           and all(num(s[k]) is not None for k in s)
                                           and s["min"] <= s["median"] <= s["max"] and 1 <= s["n"] <= agg["n"]):
                bad.append(f"aggregate.metrics.{name}: want {{n, median, min, max}} with min <= median <= max")
    return bad

#!/usr/bin/env python3
"""shiprule.py — may a fleet change ship? The bench's quality gate, as a script (PRD #345, #620). Stdlib only.

Cost and time cuts (PRD #587) are only wins if quality holds, and "it feels the same" is not evidence. The rule, from
bench/README.md ("Ship rule"), compares at least 5 runs of the change with at least 5 runs of the baseline fleet:

  1. the median number of fuzz root-cause classes (`fuzz_classes`) is no higher than the baseline's;
  2. no class appears in the change's runs that the baseline's runs never showed (`fuzz_class_counts`);
  3. the mean blind-review score (`review_score`, out of 10) has not dropped by more than 0.5.

    bench/shiprule.py --baseline RUN.json... --candidate RUN.json...   # files, or folders of them
    bench/shiprule.py --baseline DIR --candidate DIR --arm harness     # only the results of one arm

Prints the verdict as JSON and exits 0 when the change may ship, 1 when it may not (a rule failed, too few runs, or runs that
lack the fuzz classes or the review: the rule cannot be applied without them), 2 for bad arguments. A run's JSON is what
bench/run.py wrote, plus `review_score` / `review` from bench/review.py.
"""
import argparse
import json
import os
import statistics
import sys

MIN_RUNS = 5
MAX_REVIEW_DROP = 0.5


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def collect(paths, arm=None):
    """The per-run results documents under `paths` (files, or folders searched for *.json): runs only, no aggregates or skips."""
    docs = []
    for p in paths:
        files = [p] if os.path.isfile(p) else sorted(os.path.join(d, f) for d, _, fs in os.walk(p)
                                                      for f in fs if f.endswith(".json"))
        for f in files:
            try:
                with open(f, encoding="utf-8") as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(doc, dict) and doc.get("status") in ("ok", "capped") and (arm is None or doc.get("arm") == arm):
                docs.append(doc)
    return docs


def usable(docs, key):
    return [d for d in docs if num(d.get(key)) is not None]


def evaluate(baseline, candidate, min_runs=MIN_RUNS):
    """The verdict {"ship": bool, "rules": {...}, "reasons": [...], "baseline"/"candidate": numbers} for two lists of run docs."""
    reasons, rules = [], {}
    figures = {}
    for name, docs in (("baseline", baseline), ("candidate", candidate)):
        classes, reviews = usable(docs, "fuzz_classes"), usable(docs, "review_score")
        figures[name] = {"runs": len(docs), "with_classes": len(classes), "with_review": len(reviews),
                         "median_classes": statistics.median([d["fuzz_classes"] for d in classes]) if classes else None,
                         "review_mean": round(statistics.fmean([d["review_score"] for d in reviews]), 2) if reviews else None,
                         "classes": sorted({c for d in classes for c in (d.get("fuzz_class_counts") or {})})}
        for what, n in (("runs", len(docs)), ("runs with fuzz classes", len(classes)), ("runs with a review", len(reviews))):
            if n < min_runs:
                reasons.append("%s: %d %s, the rule needs %d" % (name, n, what, min_runs))
    b, c = figures["baseline"], figures["candidate"]
    if not reasons:
        rules["median_classes"] = c["median_classes"] <= b["median_classes"]
        new = sorted(set(c["classes"]) - set(b["classes"]))
        rules["no_new_class"] = not new
        rules["review_mean"] = c["review_mean"] >= b["review_mean"] - MAX_REVIEW_DROP
        if not rules["median_classes"]:
            reasons.append("median class count %g is above the baseline's %g" % (c["median_classes"], b["median_classes"]))
        if new:
            reasons.append("new classes: " + ", ".join(new))
        if not rules["review_mean"]:
            reasons.append("review mean %.2f dropped by more than %g from %.2f" % (c["review_mean"], MAX_REVIEW_DROP, b["review_mean"]))
    return {"ship": not reasons and all(rules.values()), "rules": rules, "reasons": reasons,
            "baseline": {k: v for k, v in b.items() if k != "classes"}, "candidate": {k: v for k, v in c.items() if k != "classes"},
            "new_classes": sorted(set(c["classes"]) - set(b["classes"]))}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply the bench ship rule to a baseline and a candidate set of runs.")
    ap.add_argument("--baseline", nargs="+", required=True, metavar="PATH")
    ap.add_argument("--candidate", nargs="+", required=True, metavar="PATH")
    ap.add_argument("--arm", help="only the runs of this arm")
    ap.add_argument("--min-runs", type=int, default=MIN_RUNS)
    a = ap.parse_args(argv)
    for p in a.baseline + a.candidate:
        if not os.path.exists(p):
            print("shiprule.py: no such file or folder: %s" % p, file=sys.stderr)
            return 2
    verdict = evaluate(collect(a.baseline, a.arm), collect(a.candidate, a.arm), a.min_runs)
    print(json.dumps(verdict, indent=2))
    return 0 if verdict["ship"] else 1


if __name__ == "__main__":
    sys.exit(main())

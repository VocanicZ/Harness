#!/usr/bin/env python3
"""test_bench_figures.py — #384 (PRD #345): bench/figures.py generates the README Benchmark table and
the figure from bench/results/. Covered: sample results JSON give the table and an SVG; running twice
gives identical bytes; missing optional data (null splits, no SonarQube, an ungraded run, absent optional
arms) renders as n/a or "skipped: <reason>", never an error; SonarQube columns appear only when present;
the README is rewritten only between its markers; --check flags stale files; the committed README and
figure are current with the committed results."""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIG = os.path.join(ROOT, "bench", "figures.py")
sys.dont_write_bytecode = True

FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail}"))
    if not cond:
        FAILS.append(name)


def doc(arm, **kw):
    d = {"schema": 1, "run_id": "r1", "arm": arm, "repo": "o/bench-r1-" + arm, "status": "ok", "capped": None,
         "error": None, "started_at": "2026-11-01T00:00:00Z", "ended_at": "2026-11-01T01:00:00Z", "wall_s": 3725,
         "coding_s": 3000.0, "testing_s": 600.0, "test_calls": 4,
         "tokens": {"input": 1200, "output": 250000, "cache_read": 12000000, "cache_write": 800000},
         "cost_usd": 41.5, "usd_per_pct": 20.0, "usd_per_pct_source": "fit", "weekly_window_pct": 2.1,
         "models": {"claude-opus-4-1": {"messages": 9}}, "hidden_tests": {"passed": 17, "failed": 3, "total": 20, "details": {}},
         "counts": {"commits": 12, "continue_replies": 3}, "caps": {"wall_s": 21600, "cost_usd": 80},
         "repo_deleted": True, "logs": "x.logs"}
    d.update(kw)
    return d


def put(d, *parts, data):
    p = os.path.join(d, *parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as fh:
        json.dump(data, fh)


def readme_with_markers(d):
    p = os.path.join(d, "README.md")
    with open(p, "w") as fh:
        fh.write("# T\n\nintro by hand\n\n## Benchmark\n\n<!-- bench:begin — x -->\nOLD\n<!-- bench:end -->\n\ntail by hand\n")
    return p


def run(d, *extra, readme=None):
    r = subprocess.run([sys.executable, "-I", FIG, "--results-dir", os.path.join(d, "results"),
                        "--readme", readme or os.path.join(d, "README.md"), *extra], capture_output=True, text=True)
    return r


def slurp(p, mode="rb"):
    with open(p, mode) as fh:
        return fh.read()


tmp = tempfile.mkdtemp(prefix="bench-figures-")
try:
    # --- full sample: table + figure, byte-for-byte on a second run ------------------------
    d = os.path.join(tmp, "full"); os.makedirs(d)
    put(d, "results", "r1", "plain.json", data=doc("plain"))
    put(d, "results", "r1", "harness.json", data=doc(
        "harness", wall_s=7200, coding_s=5000, testing_s=1900, cost_usd=60.25, weekly_window_pct=3.0,
        counts={"issues_closed": 6, "prs_merged": 6}, models={"claude-opus-4-1": {}, "claude-sonnet-4-5": {}},
        status="capped", capped="cost"))
    put(d, "results", "r1", "skipped.json", data={"hx": "Hx needs a second account"})
    readme = readme_with_markers(d)
    r = run(d)
    check("generates without error", r.returncode == 0, r.stderr)
    text = slurp(readme, "r")
    svg_path = os.path.join(d, "results", "benchmark.svg")
    check("figure written", os.path.isfile(svg_path))
    svg = slurp(svg_path, "r") if os.path.isfile(svg_path) else ""
    check("figure is an svg with both arms", svg.startswith("<svg") and "Plain Claude Code" in svg and "Harness (1 worker)" in svg)
    check("table header columns", all(c in text for c in ("Wall time", "Coding", "Testing", "List price", "% of weekly window",
                                                          "Hidden tests passed", "Issues / PRs / commits", "Continue replies",
                                                          "Cap status", "Models", "in / out / cache read / cache write")))
    check("plain row", "| Plain Claude Code | within caps | 1h 02m | 50m 00s | 10m 00s | 13.1M | 1.2k / 250.0k / 12.0M / 800.0k | $41.50 | 2.1% | 17 / 20 | 12 commits | 3 | claude-opus-4-1 |" in text, text)
    check("harness row: capped, issues/PRs, models",
          "| Harness (1 worker) | capped: cost | 2h 00m | 1h 23m | 31m 40s |" in text and "6 issues, 6 PRs" in text and "claude-opus-4-1, claude-sonnet-4-5" in text, text)
    check("harness row has n/a continue replies", "| 6 issues, 6 PRs | n/a |" in text, text)
    check("skipped optional arm with reason", "| Hx | skipped: Hx needs a second account | n/a |" in text, text)
    check("optional arm without a reason is skipped: not run", "| Harness (3 workers) | skipped: not run |" in text, text)
    check("no SonarQube column without data", "SonarQube" not in text)
    check("figure referenced relative to README", "![Benchmark: wall time and list-price cost per arm](results/benchmark.svg)" in text, text)
    check("hand-written text outside the markers untouched",
          text.startswith("# T\n\nintro by hand\n\n## Benchmark\n\n<!-- bench:begin") and text.endswith("<!-- bench:end -->\n\ntail by hand\n") and "OLD" not in text)
    first = (slurp(readme), slurp(svg_path))
    r2 = run(d)
    check("second run succeeds", r2.returncode == 0, r2.stderr)
    check("second run is byte-for-byte identical (README and figure)", (slurp(readme), slurp(svg_path)) == first)
    os.remove(svg_path); os.remove(readme); readme_with_markers(d)
    run(d)
    check("regenerating from scratch reproduces the same bytes", (slurp(readme), slurp(svg_path)) == first)
    check("no CR in the figure or README", b"\r" not in first[1] and b"\r" not in first[0])
    check("--check passes when current", run(d, "--check").returncode == 0)
    with open(svg_path, "a") as fh:
        fh.write("<!-- edited -->\n")
    rc = run(d, "--check")
    check("--check flags a hand-edited figure", rc.returncode == 1 and "benchmark.svg" in rc.stderr, rc.stderr)
    check("--check writes nothing", slurp(svg_path, "r").endswith("<!-- edited -->\n"))
    run(d)
    check("a run repairs the edited figure", (slurp(readme), slurp(svg_path)) == first)

    # --- optional data: SonarQube appears only when present --------------------------------
    d2 = os.path.join(tmp, "sonar"); os.makedirs(d2)
    put(d2, "results", "r1", "plain.json", data=doc("plain", sonarqube={"bugs": 1, "vulnerabilities": 0, "code_smells": 7,
                                                                          "maintainability_rating": "A", "coverage": 81.5}))
    put(d2, "results", "r1", "harness.json", data=doc("harness"))
    readme2 = readme_with_markers(d2)
    r = run(d2)
    t2 = slurp(readme2, "r")
    check("SonarQube column when a result has it", r.returncode == 0 and "| SonarQube |" in t2 and "bugs 1, vulns 0, smells 7, maint. A, cov 81.5%" in t2, t2 + r.stderr)
    check("arm without SonarQube data shows n/a", t2.count("| n/a |\n") >= 1 and "| claude-opus-4-1 | n/a |" in t2, t2)

    # --- missing data never errors ---------------------------------------------------------
    d3 = os.path.join(tmp, "sparse"); os.makedirs(d3)
    put(d3, "results", "r1", "plain.json", data=doc("plain", coding_s=None, testing_s=None, test_calls=None, weekly_window_pct=None,
                                                  usd_per_pct=None, usd_per_pct_source="none", models={}, counts={},
                                                  hidden_tests={"passed": 0, "failed": None, "total": None, "details": {"error": "boom"}},
                                                  status="error", error="arm failed"))
    put(d3, "results", "r1", "odd.json", data={"arm": "odd"})
    with open(os.path.join(d3, "results", "r1", "broken.json"), "w") as fh:
        fh.write("{not json")
    readme3 = readme_with_markers(d3)
    r = run(d3)
    t3 = slurp(readme3, "r")
    check("sparse results do not error", r.returncode == 0, r.stderr)
    check("null split, window and models render n/a", "| Plain Claude Code | error | 1h 02m | n/a | n/a | 13.1M |" in t3 and "| n/a | n/a | n/a (not graded) | n/a | n/a | n/a |" in t3, t3)
    check("a result with only an arm name renders a row", "| odd | n/a | n/a | n/a | n/a | n/a | n/a / n/a / n/a / n/a | n/a |" in t3, t3)
    sv = slurp(os.path.join(d3, "results", "benchmark.svg"), "r")
    check("figure draws a not-split wall bar when the split is null", "#9aa0a6" in sv and "</svg>" in sv)

    # --- no results at all, bad invocations ------------------------------------------------
    d4 = os.path.join(tmp, "empty"); os.makedirs(d4)
    readme4 = readme_with_markers(d4)
    r = run(d4)
    check("no results: ok, says so, no figure", r.returncode == 0 and "No benchmark results are committed yet" in slurp(readme4, "r")
          and not os.path.exists(os.path.join(d4, "results", "benchmark.svg")), r.stderr)
    r = run(d4, "--run-id", "nope")
    check("unknown --run-id exits 2", r.returncode == 2, r.stderr)
    nm = os.path.join(d4, "plain-readme.md")
    with open(nm, "w") as fh:
        fh.write("# no markers\n")
    r = run(d4, readme=nm)
    check("README without markers exits 2 and is untouched", r.returncode == 2 and slurp(nm, "r") == "# no markers\n", r.stderr)

    # --- latest run wins; --run-id picks another -------------------------------------------
    d5 = os.path.join(tmp, "runs"); os.makedirs(d5)
    put(d5, "results", "2026-11-01", "plain.json", data=doc("plain", run_id="2026-11-01", cost_usd=1.0))
    put(d5, "results", "2026-11-02", "plain.json", data=doc("plain", run_id="2026-11-02", cost_usd=2.0))
    readme5 = readme_with_markers(d5)
    run(d5)
    check("latest run is shown", "$2.00" in slurp(readme5, "r") and "results/2026-11-02/" in slurp(readme5, "r"))
    run(d5, "--run-id", "2026-11-01")
    check("--run-id selects an older run", "$1.00" in slurp(readme5, "r") and "$2.00" not in slurp(readme5, "r"))

    # --- the committed README and figure are current with the committed results -------------
    r = subprocess.run([sys.executable, "-I", FIG, "--check"], capture_output=True, text=True)
    check("committed README/figure are current (run bench/figures.py)", r.returncode == 0, r.stderr)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

if FAILS:
    print(f"{len(FAILS)} FAILED")
    sys.exit(1)
print("all passed")

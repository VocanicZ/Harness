#!/usr/bin/env python3
"""test_bench_figures.py — #384 (PRD #345): bench/figures.py generates the README Benchmark table and
the figure from bench/results/. Covered: sample results JSON give the table and an SVG; running twice
gives identical bytes; missing optional data (null splits, no SonarQube, an ungraded run, absent optional
arms) renders as n/a or "skipped: <reason>", never an error; the SonarQube and Coverage columns are always there; a skipped quality scan marks the run invalid;
the README is rewritten only between its markers; --check flags stale files; the committed README and
figure are current with the committed results."""
import json, os, re, shutil, subprocess, sys, tempfile

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
                                                          "Hidden tests passed", "Fuzz divergences", "Issues / PRs / commits", "Continue replies",
                                                          "Cap status", "Models", "in / out / cache read / cache write")))
    check("plain row", "| Plain Claude Code | n=1 | within caps | 1h 02m | 50m 00s | 10m 00s | 13.1M | 1.2k / 250.0k / 12.0M / 800.0k | $41.50 | 2.1% | 17 / 20 | n/a | 12 commits | 3 | claude-opus-4-1 | n/a (not measured) | n/a (not measured) |" in text, text)
    check("harness row: capped, issues/PRs, models",
          "| Harness (1 worker) | n=1 | capped: cost | 2h 00m | 1h 23m | 31m 40s |" in text and "6 issues, 6 PRs" in text and "claude-opus-4-1, claude-sonnet-4-5" in text, text)
    check("harness row has n/a continue replies", "| n/a | 6 issues, 6 PRs | n/a |" in text, text)
    check("skipped optional arm with reason", "| Hx | n/a | skipped: Hx needs a second account | n/a |" in text, text)
    check("optional arm without a reason is skipped: not run", "| Harness (3 workers) | n/a | skipped: not run |" in text, text)
    check("SonarQube and Coverage columns are always shown, n/a (not measured) without data",
          "| SonarQube | Coverage (own tests) |" in text and text.count("n/a (not measured) | n/a (not measured) |") >= 2, text)
    check("no fuzz note while no arm has fuzz results", "**Fuzz divergences:**" not in text)
    check("SonarQube and Coverage columns are always shown, n/a (not measured) without data",
          "| SonarQube | Coverage (own tests) |" in text and text.count("n/a (not measured) | n/a (not measured) |") >= 2, text)
    # a `status: skipped` <arm>.json (bench/run.py --optional, #386) is a skipped row, and is not a measured arm
    put(d, "results", "r1", "harness-3.json", data={"schema": 1, "run_id": "r1", "arm": "harness-3", "status": "skipped",
                                                    "reason": "budget", "skipped_at": "t", "guard": {}})
    run(d)
    text2 = slurp(readme, "r")
    check("a skipped <arm>.json renders as skipped: budget", "| Harness (3 workers) | n/a | skipped: budget | n/a |" in text2, text2)
    check("a skipped record is not a plotted arm", "Harness (3 workers)" not in slurp(svg_path, "r"))
    # #577: the cell shows the guard's real cause(s), whatever they are
    put(d, "results", "r1", "harness-3.json", data={"schema": 1, "run_id": "r1", "arm": "harness-3", "status": "skipped",
                                                    "reason": "disk,budget", "skipped_at": "t", "guard": {}})
    run(d)
    check("a skipped <arm>.json shows every cause", "| Harness (3 workers) | n/a | skipped: disk,budget | n/a |" in slurp(readme, "r"))
    os.remove(os.path.join(d, "results", "r1", "harness-3.json")); run(d)
    check("no undeleted-repos note while every repo was deleted", "Repos not deleted" not in slurp(readme, "r"))
    # #578: a run that left its repo behind says so in the README
    put(d, "results", "r1", "plain.json", data=doc("plain", repo="o/bench-r1-plain", repo_deleted=False))
    run(d)
    left = slurp(readme, "r")
    check("an undeleted repo is named in the README", "**Repos not deleted:**" in left and "`o/bench-r1-plain`" in left
          and "`repo_deleted: false`" in left and "bench-r1-harness" not in left, left)
    check("--check passes with the undeleted note", run(d, "--check").returncode == 0)
    put(d, "results", "r1", "plain.json", data=doc("plain")); run(d)
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
    check("SonarQube column shows a result's measures", r.returncode == 0 and "| SonarQube |" in t2 and "bugs 1, vulns 0, smells 7, maint. A |" in t2 and "cov 81.5" not in t2, t2 + r.stderr)
    check("arm without SonarQube data shows n/a (not measured)", "| claude-opus-4-1 | n/a (not measured) | n/a (not measured) |\n" in t2, t2)

    # --- quality + coverage columns, and an invalid run (#588) -----------------------------
    d9 = os.path.join(tmp, "invalid"); os.makedirs(d9)
    sq = {"bugs": 0, "vulnerabilities": 0, "code_smells": 0, "maintainability_rating": "A", "duplicated_lines_density": 0.0}
    put(d9, "results", "r1", "plain.json", data=doc("plain", quality="ok", sonarqube=sq,
                                                    coverage={"line_pct": 95.7, "branch_pct": 86.7, "total_pct": 94.0}))
    put(d9, "results", "r1", "harness.json", data=doc("harness", quality="skipped (Not enough free disk space for Elasticsearch)",
                                                      coverage="skipped (coverage.py is not installed)"))
    readme9 = readme_with_markers(d9)
    r = run(d9)
    t9 = slurp(readme9, "r")
    check("a skipped quality scan marks the run invalid at the top of the section",
          r.returncode == 0 and "**INVALID RUN: rerun.**" in t9.split("Generated by")[0]
          and "Harness (1 worker): quality skipped (Not enough free disk space for Elasticsearch)" in t9
          and "Plain Claude Code: quality" not in t9, t9)
    check("coverage cell: total, line and branch %", "| 94% (line 95.7%, branch 86.7%) |" in t9, t9)
    check("a skipped scan and a skipped coverage run are n/a (reason)",
          "| n/a (Not enough free disk space for Elasticsearch) | n/a (coverage.py is not installed) |" in t9, t9)
    check("--check passes on an invalid run once its README is written", run(d9, "--check").returncode == 0)
    put(d9, "results", "r1", "harness.json", data=doc("harness", quality="ok", sonarqube=sq,
                                                      coverage={"line_pct": 98.7, "branch_pct": 97.8}))
    run(d9)
    t9 = slurp(readme9, "r")
    check("every arm's scan ok: the run is not marked invalid", "INVALID" not in t9 and "| line 98.7%, branch 97.8% |" in t9, t9)
    put(d9, "results", "r1", "harness.json", data=doc("harness"))   # no quality key at all: not measured is invalid too
    run(d9)
    check("an arm with no quality result is invalid too", "Harness (1 worker): quality not measured" in slurp(readme9, "r"))

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
    check("null split, window and models render n/a", "| Plain Claude Code | n=1 | error | 1h 02m | n/a | n/a | 13.1M |" in t3 and "| n/a | n/a | n/a (not graded) | n/a | n/a | n/a |" in t3, t3)
    check("a result with only an arm name renders a row", "| odd | n=1 | n/a | n/a | n/a | n/a | n/a | n/a / n/a / n/a / n/a | n/a |" in t3, t3)
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

    # --- #583: bars are wall_s long; time outside sessions is its own segment ----------------
    d6 = os.path.join(tmp, "geom"); os.makedirs(d6)
    put(d6, "results", "r1", "plain.json", data=doc("plain", wall_s=600, coding_s=300.0, testing_s=100.0))
    put(d6, "results", "r1", "harness.json", data=doc("harness", wall_s=6000, coding_s=1000.0, testing_s=500.0))
    put(d6, "results", "r1", "hx.json", data=doc("hx", wall_s=3000, coding_s=None, testing_s=None))
    readme6 = readme_with_markers(d6)
    run(d6)
    sv6 = slurp(os.path.join(d6, "results", "benchmark.svg"), "r")
    rows = {}
    for x, y, wd, fill in re.findall(r'<rect x="([\d.]+)" y="(\d+)" width="([\d.]+)" height="18" fill="(#\w+)"/>', sv6):
        rows.setdefault(int(y), []).append((float(x), float(wd), fill))
    # time bars start at x=170 (the cost bars are in the other panel); rows are 34px apart from y=66
    bars = {i: [r for r in rows.get(66 + 34 * i, []) if r[0] < 420] for i in range(3)}
    width = {i: round(sum(r[1] for r in b), 1) for i, b in bars.items()}
    check("bar length is proportional to wall_s (600 : 6000 : 3000)",
          width[1] == 250 and abs(width[0] - 25) <= 0.2 and abs(width[2] - 125) <= 0.2, str(width))
    check("segments tile the bar: coding, testing, outside sessions",
          [r[2] for r in bars[1]] == ["#4c78a8", "#f58518", "#b8a2d6"]
          and all(abs(a[0] + a[1] - b[0]) <= 0.11 for a, b in zip(bars[1], bars[1][1:])), str(bars[1]))
    check("outside-sessions segment is wall_s - coding_s - testing_s",
          abs(bars[1][2][1] - 4500 / 6000 * 250) <= 0.2 and abs(bars[0][2][1] - 200 / 6000 * 250) <= 0.2, str(bars))
    check("an arm without a split is one unsplit wall bar", [r[2] for r in bars[2]] == ["#9aa0a6"], str(bars[2]))
    check("the legend names the outside-sessions segment", "outside sessions" in sv6 and "#b8a2d6" in sv6)
    t6 = slurp(readme6, "r")
    check("README says what Coding/Testing measure and what the rest of Wall time is",
          "Coding and Testing count time inside agent sessions" in t6 and "rest of Wall time is time outside them" in t6, t6)
    # a split that overruns wall_s (not a measured outcome) still tiles the bar, with no negative segment
    put(d6, "results", "r2", "plain.json", data=doc("plain", wall_s=100, coding_s=90.0, testing_s=60.0))
    run(d6, "--run-id", "r2")
    sv7 = slurp(os.path.join(d6, "results", "benchmark.svg"), "r")
    check("an overrunning split clamps the outside segment at 0 (no outside rect)",
          'height="18" fill="#b8a2d6"' not in sv7, sv7)

    # --- #584: the Harness arm's loaded Claude config and its manual repair are disclosed under the table ---
    d7 = tempfile.mkdtemp(dir=tmp)
    readme7 = readme_with_markers(d7)
    put(d7, "results", "r1", "plain.json", data=doc("plain"))
    run(d7)
    check("no config sentence or note when no arm recorded one",
          "Claude config" not in slurp(readme7, "r") and "**Note" not in slurp(readme7, "r"))
    put(d7, "results", "r1", "harness.json", data=doc(
        "harness", claude_config={"source": "front-door init", "skills": 186, "plugins": 6, "mcp_servers": 4},
        note="Fixed the tmux dir by hand\nand restarted once."))
    put(d7, "results", "r1", "plain.json", data=doc(
        "plain", claude_config={"source": "front-door init", "skills": 0, "plugins": 0, "mcp_servers": 0}))
    run(d7)
    t7 = slurp(readme7, "r")
    check("the loaded config is stated under the table, with its counts",
          "**Claude config:** the Harness (1 worker) arm's sessions ran on the operator's own Claude setup, not an isolated "
          "one: its front-door init loaded 186 skills, 6 user plugins and 4 MCP servers" in t7, t7)
    check("an arm that loaded nothing is said to have run isolated",
          "**Claude config:** the Plain Claude Code arm's sessions ran isolated; its front-door init loaded no skills, "
          "plugins or MCP servers." in t7, t7)
    check("the arm's note is shown verbatim on one line", "**Note, Harness (1 worker):** Fixed the tmux dir by hand and restarted once." in t7, t7)
    check("the config and note sit after the table and before the end marker",
          t7.index("| Harness (1 worker)") < t7.index("**Claude config:**") < t7.index("**Note, ") < t7.index("<!-- bench:end -->"))
    check("--check passes with the config and note", run(d7, "--check").returncode == 0)
    put(d7, "results", "r1", "harness.json", data=doc("harness", claude_config={"skills": "many"}, note="  "))
    run(d7)
    check("a malformed claude_config and a blank note render nothing for that arm",
          "Harness (1 worker)'s" not in slurp(readme7, "r") and "**Note, Harness" not in slurp(readme7, "r"))

    # --check re-reads the config and the restarts from the committed logs (the front door's stream, run.log)
    d8 = tempfile.mkdtemp(dir=tmp)
    src = os.path.join(ROOT, "bench", "results", "run-20261106")
    rd8 = os.path.join(d8, "results", "r1")
    os.makedirs(os.path.join(rd8, "harness.logs"))
    for name in ("transcripts", "front-01.stream.jsonl", "run.log"):
        os.symlink(os.path.join(src, "harness.logs", name), os.path.join(rd8, "harness.logs", name))
    committed = json.load(open(os.path.join(src, "harness.json")))
    readme8 = readme_with_markers(d8)
    put(d8, "results", "r1", "harness.json", data=committed)
    run(d8)
    r8 = run(d8, "--check")
    check("the committed Harness results reproduce from their logs, config and restarts included", r8.returncode == 0, r8.stderr)
    bad = dict(committed, claude_config=dict(committed["claude_config"], skills=0))
    put(d8, "results", "r1", "harness.json", data=bad)
    run(d8)
    r8 = run(d8, "--check")
    check("--check fails when the recorded skills count differs from the front-door init",
          r8.returncode == 1 and "claude_config" in r8.stderr, r8.stderr)
    bad = dict(committed, counts=dict(committed["counts"], fleet_restarts=0))
    put(d8, "results", "r1", "harness.json", data=bad)
    run(d8)
    r8 = run(d8, "--check")
    check("--check fails when fleet_restarts hides the restart the front door made",
          r8.returncode == 1 and "fleet_restarts" in r8.stderr, r8.stderr)

    # --- #590: models, effort and provenance per arm; the isolated Harness config; the matched arm's row ---
    d10 = tempfile.mkdtemp(dir=tmp)
    readme10 = readme_with_markers(d10)
    prov = {"engine_commit": "0123456789abcdef0123456789abcdef01234567-dirty", "skill_version": "sha256:aaaabbbbccccdddd",
            "cli_version": "2.1.319 (Claude Code)"}
    put(d10, "results", "r1", "plain.json", data=doc(
        "plain", effort={"medium": 42}, configured={"model": None, "effort": None}, provenance=dict(prov, skill_version=None)))
    put(d10, "results", "r1", "harness-opus.json", data=doc(
        "harness-opus", effort={"medium": 90}, configured={"model": "opus", "effort": "medium"}, provenance=prov,
        claude_config={"source": "front-door init", "skills": 21, "plugins": 2, "mcp_servers": 0},
        isolation={"config": "isolated", "engine_skills": ["harness"] * 19, "engine_plugins": ["ralph-loop", "superpowers"]}))
    run(d10)
    t10 = slurp(readme10, "r")
    check("the matched arm has a table row of its own, not a skipped one", "| Harness (all Opus, plain's effort) | n=1 | within caps" in t10, t10)
    check("each arm's models, effort, asked-for settings and provenance are stated under the table",
          "**Run settings, Plain Claude Code:** models claude-opus-4-1; effort by message medium (42); asked for model default, "
          "effort default; engine commit `0123456789ab-dirty`; `/harness` skill n/a; Claude Code CLI `2.1.319 (Claude Code)`." in t10
          and "**Run settings, Harness (all Opus, plain's effort):** models claude-opus-4-1; effort by message medium (90); asked for "
              "model opus, effort medium; engine commit `0123456789ab-dirty`; `/harness` skill `sha256:aaaabbbbccccdddd`; Claude Code CLI "
              "`2.1.319 (Claude Code)`." in t10, t10)
    check("an isolated Harness config is described as plain's plus the engine's own, not as the operator's",
          "the Harness (all Opus, plain's effort) arm's sessions ran on the same isolated Claude config as the plain arm, plus only what "
          "the Harness engine installs (19 skills, 2 plugins); its front-door init loaded 21 skills (the CLI's bundled ones included), "
          "2 plugins and 0 MCP servers." in t10 and "operator's own" not in t10, t10)
    check("--check passes with the settings notes", run(d10, "--check").returncode == 0)
    d11 = tempfile.mkdtemp(dir=tmp)
    readme11 = readme_with_markers(d11)
    put(d11, "results", "r1", "plain.json", data=doc("plain"))
    run(d11)
    t11 = slurp(readme11, "r")
    check("an arm without settings records adds no Run settings line, and the matched arm shows as not run",
          "Run settings" not in t11 and "| Harness (all Opus, plain's effort) | n/a | skipped: not run" in t11, t11)

    # --- #589: the Fuzz divergences column and its note ------------------------------------
    d9 = os.path.join(tmp, "fuzz"); os.makedirs(d9)
    ex = [{"case": 1, "argv": ["add", "f", "d", "c", "-5", "-refund"]}]
    put(d9, "results", "r1", "plain.json", data=doc("plain", fuzz_cases=1000, fuzz_divergences=250, fuzz_examples=ex,
                                                    fuzz_seed=589, fuzz_hash="0123456789abcdef" * 4))
    put(d9, "results", "r1", "harness.json", data=doc("harness", fuzz_cases=1000, fuzz_divergences=0, fuzz_examples=[],
                                                      fuzz_seed=589, fuzz_hash="0123456789abcdef" * 4))
    put(d9, "results", "r1", "harness-3.json", data=doc("harness-3", fuzz_error="fuzz did not run: OSError"))
    readme9 = readme_with_markers(d9)
    run(d9)
    t9 = slurp(readme9, "r")
    check("fuzz divergences per arm in the table", "| 17 / 20 | 250 / 1000 | 12 commits |" in t9 and "| 17 / 20 | 0 / 1000 |" in t9, t9)
    check("an arm whose fuzz could not run says so", "| 17 / 20 | n/a (fuzz error) |" in t9, t9)
    check("the fuzz note names what is counted, the seed and the hash",
          "**Fuzz divergences:**" in t9 and "seed 589" in t9 and "`0123456789ab…`" in t9 and "`fuzz_examples`" in t9, t9)
    check("--check passes with fuzz results", run(d9, "--check").returncode == 0)

    # --- #591: --runs N — median and range in the table, whiskers in the figure, n for every arm ----------
    sys.path.insert(0, os.path.join(ROOT, "bench"))
    import aggregate as agglib                                                  # noqa: E402
    d12 = os.path.join(tmp, "batch"); os.makedirs(d12)

    def batch_docs(arm, specs, requested, stopped=None):
        """Write <arm>.runs/run-NN.json for each (status, cost, wall, passed, div) and the aggregate <arm>.json."""
        docs, runs = [], []
        for i, (status, cost, wall, passed, div) in enumerate(specs, 1):
            f = f"{arm}.runs/run-{i:02d}.json"
            r = doc(arm, run=i, status=status, cost_usd=cost, wall_s=wall, coding_s=wall * 0.6, testing_s=wall * 0.1,
                    hidden_tests={"passed": passed, "failed": 80 - passed, "total": 80}, fuzz_cases=1000,
                    fuzz_divergences=div, logs=f"run-{i:02d}.logs", counts={"commits": i + 2})
            put(d12, "results", "r1", f, data=r)
            docs.append(r)
            runs.append({"run": i, "file": f, "status": status, "capped": None})
        a = agglib.aggregate(docs)
        put(d12, "results", "r1", arm + ".json", data={
            "schema": 1, "run_id": "r1", "arm": arm, "status": "aggregate", "runs_requested": requested,
            "runs_completed": a["n"], "stopped": stopped, "runs": runs, "aggregate": a})
    batch_docs("plain", [("ok", 10.0, 600, 70, 5), ("ok", 30.0, 1200, 80, 9), ("ok", 20.0, 900, 75, 7)], 3)
    batch_docs("harness", [("ok", 40.0, 3000, 80, 1), ("ok", 50.0, 3600, 80, 2)], 5,
               {"reason": "guard", "causes": ["budget"], "detail": "acct seven_day: 70% now + 10% expected > 98%"})
    put(d12, "results", "r1", "hx.json", data=doc("hx"))        # a legacy single-run result beside the batches
    readme12 = readme_with_markers(d12)
    r12 = run(d12)
    t12 = slurp(readme12, "r")
    svg12 = slurp(os.path.join(d12, "results", "benchmark.svg"), "r")
    check("a batch renders without error", r12.returncode == 0, r12.stderr)
    check("the table has an n column: n=3, n=2 of 5 for a stopped batch, n=1 for a single run",
          "| Arm | n |" in t12 and "| Plain Claude Code | n=3 |" in t12 and "| Harness (1 worker) | n=2 of 5 |" in t12
          and "| Hx | n=1 |" in t12, t12)
    check("time and cost cells show the median and the min–max range",
          "| 15m 00s (10m 00s–20m 00s) |" in t12 and "$20.00 ($10.00–$30.00)" in t12, t12)
    check("hidden tests and fuzz cells show the median and range over the cases", "75 (70–80) / 80" in t12 and "7 (5–9) / 1000" in t12, t12)
    check("work counts show a range too", "4 (3–5) commits" in t12, t12)
    check("a single run's cells are plain values, as before", "| Hx | n=1 | within caps | 1h 02m | 50m 00s | 10m 00s |" in t12, t12)
    check("the figure labels every arm with n and draws whiskers only where there are several runs",
          "Plain Claude Code <tspan" in svg12 and ">n=3</tspan>" in svg12 and ">n=2 of 5</tspan>" in svg12 and ">n=1</tspan>" in svg12
          and svg12.count('stroke-width="1.5"') == 4 and "whiskers: min–max" in svg12, svg12)
    check("the median is the bar: plain's wall-time label is the median 15m", ">15m 00s</text>" in svg12 and ">$20.00</text>" in svg12, svg12)
    check("an early stop is told under the table with its reason",
          "**Stopped early, Harness (1 worker):** 2 of 5 runs completed (2 started); stopped because guard: acct seven_day" in t12, t12)
    check("the README says what n and the range mean", "**Runs:** `n` is the number of runs" in t12 and "`n=1` is a single run" in t12, t12)
    check("a batch is byte-for-byte reproducible", (slurp(readme12), slurp(os.path.join(d12, "results", "benchmark.svg"))) ==
          (lambda: (run(d12), (slurp(readme12), slurp(os.path.join(d12, "results", "benchmark.svg"))))[1])())
    check("--check passes on a batch", run(d12, "--check").returncode == 0, run(d12, "--check").stderr)
    # an aggregate that no longer matches its runs, or a run file that went missing, fails --check
    stored = json.load(open(os.path.join(d12, "results", "r1", "plain.json")))
    stored["aggregate"]["metrics"]["cost_usd"]["median"] = 99.0
    put(d12, "results", "r1", "plain.json", data=stored)
    bad12 = run(d12, "--check")
    check("--check fails when the aggregate differs from its runs", bad12.returncode == 1 and "aggregate does not match its runs: plain: " in bad12.stderr, bad12.stderr)
    batch_docs("plain", [("ok", 10.0, 600, 70, 5), ("ok", 30.0, 1200, 80, 9), ("ok", 20.0, 900, 75, 7)], 3)
    os.remove(os.path.join(d12, "results", "r1", "plain.runs", "run-02.json"))
    gone = run(d12, "--check")
    check("--check fails when a run file is missing", gone.returncode == 1 and "run file plain.runs/run-02.json cannot be read" in gone.stderr, gone.stderr)
    # an errored run is listed but not counted; a batch with no finished run still renders
    batch_docs("plain", [("error", 1.0, 5, 0, 0), ("ok", 12.0, 600, 70, 5)], 3,
               {"reason": "arm-error", "detail": "the arm failed"})
    run(d12)
    t13 = slurp(readme12, "r")
    check("an errored run is not in the medians but shows in the cap status",
          "| Plain Claude Code | n=1 of 3 | 1 error, 1 within caps | 10m 00s |" in t13 and "$12.00 |" in t13, t13)
    batch_docs("plain", [("error", 1.0, 5, 0, 0)], 3, {"reason": "arm-error", "detail": "the arm failed"})
    r14 = run(d12)
    t14 = slurp(readme12, "r")
    check("a batch with no finished run renders n=0 and n/a, not an error",
          r14.returncode == 0 and "| Plain Claude Code | n=0 of 3 | error | n/a | n/a | n/a | n/a |" in t14, t14 + r14.stderr)

    # --- the committed README and figure are current with the committed results -------------
    r = subprocess.run([sys.executable, "-I", FIG, "--check"], capture_output=True, text=True)
    check("committed README/figure are current (run bench/figures.py)", r.returncode == 0, r.stderr)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

if FAILS:
    print(f"{len(FAILS)} FAILED")
    sys.exit(1)
print("all passed")

"""test_review_findings.py — #1183 (PRD #1180): a PRD review round files AT MOST ONE follow-up issue, however many findings it
has (each follow-up lane costs about $0.31 and 2.4 minutes). scripts/review_findings.py turns the round's findings plus the
tier `direct` limits (scripts/tier.toml) into the plan the reviewer files. Fixture reviews only: no network, no live gh
(`file` runs against a stub gh on PATH)."""
import importlib.util, json, os, stat, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
PY = os.path.join(ROOT, "scripts", "review_findings.py")
sys.path.insert(0, os.path.join(ROOT, "scripts"))
spec = importlib.util.spec_from_file_location("review_findings", PY)
rf = importlib.util.module_from_spec(spec); spec.loader.exec_module(rf)
import tier

CFG = tier.load()
D = CFG["direct"]
FAILS = []


def check(cond, msg):
    if cond:
        print(f"  ok: {msg}")
    else:
        print(f"  FAIL: {msg}")
        FAILS.append(msg)


def F(i, sev="blocking", files=None, **kw):
    f = {"severity": sev, "title": f"finding {i}", "files": ["scripts/a.py"] if files is None else files,
         "tests": ["test/test_a.sh"], "repro": f"run cmd {i}", "expected": "exit 0", "actual": "exit 1"}
    f.update(kw)
    return f


def plan(findings, prd=7):
    return rf.plan(rf.normalise(findings), prd, CFG)


def boxes(body):
    return [l for l in body.splitlines() if l.startswith("- [ ] ")]


def trailer_ok(body, prd=7):
    return body.rstrip().endswith(f"## Blocked by\nNone\n\n## Parent\n#{prd}\n\nPart of #{prd}") and "\n## Scope\n" in body


def test_k0_files_nothing():
    p = plan([])
    check(p["issue"] is None and p["title"] is None and p["notes"] == "", "K=0: no issue, no notes")


def test_k5_mixed_files_one_issue_with_every_blocking_checkbox():
    fs = [F(1), F(2, "non-blocking"), F(3), F(4, "non-blocking"), F(5), F(6)]
    p = plan(fs)
    check(p["issue"] is not None, "K=6 mixed: one issue")
    bs = boxes(p["issue"])
    check(all(any(f"finding {i}**" in b for b in bs) for i in (1, 3, 5, 6)), "every blocking finding is a checkbox")
    check(len(bs) == 4, "only the blocking ones are checkboxes while the non-blocking fit the direct limits")
    check("finding 2" in p["notes"] and "finding 4" in p["notes"], "the within-limit non-blocking findings are notes")
    check(p["counts"]["in_issue"] == 4 and p["counts"]["in_notes"] == 2, "counts say 4 in the issue, 2 in notes")
    check(trailer_ok(p["issue"]), "the body ends with Blocked by None / Parent / Part of and has a ## Scope")


def test_at_most_one_issue_for_many_findings():
    for k in (1, 5, 9, 25, 60):
        p = plan([F(i, "blocking" if i % 2 else "non-blocking", files=[f"d{i}/f.py"]) for i in range(k)])
        check(isinstance(p["issue"], (str, type(None))) and (p["issue"] is None or len(boxes(p["issue"])) >= 1),
              f"K={k}: the plan holds one issue body or none, never a list")


def test_non_blocking_only_below_limits_files_no_issue():
    p = plan([F(i, "non-blocking") for i in range(D["max_criteria"])])
    check(p["issue"] is None and p["title"] is None, "non-blocking only, exactly at max_criteria: no issue")
    check(p["notes"].count("**[non-blocking]") == D["max_criteria"], "every one of them is in the notes")
    check("Repro: run cmd 3" in p["notes"] and "Actual: exit 1" in p["notes"], "a note keeps the repro and actual")


def test_non_blocking_over_each_limit_files_one_issue():
    over_criteria = [F(i, "non-blocking") for i in range(D["max_criteria"] + 1)]
    check(plan(over_criteria)["issue"] is not None, "one over max_criteria: one issue")
    over_files = [F(0, "non-blocking", files=[f"scripts/f{i}.py" for i in range(D["max_files"] + 1)])]
    check(plan(over_files)["issue"] is not None, "one over max_files: one issue")
    check(plan([F(0, "non-blocking", files=[f"scripts/f{i}.py" for i in range(D["max_files"])])])["issue"] is None,
          "exactly max_files: still notes")
    two_subsystems = [F(1, "non-blocking", files=["scripts/a.py"]), F(2, "non-blocking", files=["docs/b.md"])]
    check(D["max_subsystems"] != 1 or plan(two_subsystems)["issue"] is not None, "two subsystems over max_subsystems=1: one issue")
    check(plan([F(1, "non-blocking", lines=D["max_changed_lines"] + 1)])["issue"] is not None, "over max_changed_lines: one issue")
    check(plan([F(1, "non-blocking", lines=D["max_changed_lines"])])["issue"] is None, "exactly max_changed_lines: notes")
    p = plan(over_criteria)
    check(len(boxes(p["issue"])) == len(over_criteria) and p["notes"] == "", "over the limits they all go in the one issue, none in notes")


def test_blocking_plus_non_blocking_over_limits_goes_in_one_issue():
    fs = [F(0)] + [F(i, "non-blocking") for i in range(1, D["max_criteria"] + 2)]
    p = plan(fs)
    check(len(boxes(p["issue"])) == len(fs) and p["notes"] == "", "blocking and over-limit non-blocking share the one issue")


def test_limits_come_from_tier_toml():
    cfg = json.loads(json.dumps(CFG))
    cfg["direct"]["max_criteria"] = 2
    check(rf.plan(rf.normalise([F(i, "non-blocking") for i in range(3)]), 7, cfg)["issue"] is not None, "a lowered max_criteria files the issue")
    cfg["direct"]["max_criteria"] = 99
    check(rf.plan(rf.normalise([F(i, "non-blocking") for i in range(20)]), 7, cfg)["issue"] is None, "a raised max_criteria keeps them notes")


def test_missing_or_odd_severity_is_blocking():
    for sev in (None, "", "  ", "BLOCKER", 3, "Blocking"):
        f = F(1)
        if sev is None:
            f.pop("severity")
        else:
            f["severity"] = sev
        p = plan([f])
        check(p["issue"] is not None and len(boxes(p["issue"])) == 1, f"severity {sev!r} defaults to blocking")
    for sev in ("Non-Blocking", "non_blocking", "NON BLOCKING", "nonblocking"):
        check(plan([F(1, sev)])["issue"] is None, f"severity {sev!r} reads as non-blocking")


def test_empty_files_list():
    p = plan([F(1, files=[])])
    check("Files: none named" in p["issue"] and "**[blocking] finding 1**\n" in p["issue"], "an empty files list files with a 'none named' Scope and no empty ()")
    check(trailer_ok(p["issue"]), "and the trailer is intact")
    p = plan([dict(F(1), files=None, tests=None)])
    check("Files: none named" in p["issue"] and "Tests: none named" in p["issue"], "files and tests null: both 'none named'")


def test_title_with_newlines_and_unicode_stays_one_checkbox_line():
    t = "café ☃\nsecond third\x0cfourth \U0001f600"
    p = plan([F(1, title=t)])
    bs = boxes(p["issue"])
    check(len(bs) == 1 and "café ☃ second third fourth \U0001f600" in bs[0], "newline, U+2028 and form feed in a title fold to spaces")
    check(" " not in p["issue"] and "\x0c" not in p["issue"], "no separator or control character reaches the body")
    p = plan([F(1, repro="line one\nline two\r\nline three four")])
    check("  - Repro: line one\n    line two\n    line three\n    four" in p["issue"], "a multi-line repro is indented under its checkbox")
    check(len(boxes(p["issue"])) == 1, "and does not start a second checkbox")
    p = plan([F(1, repro="x\n- [ ] sneaky")])
    check(len(boxes(p["issue"])) == 1, "a repro line that looks like a checkbox is indented, not a second box")


def test_files_and_tests_are_a_deduplicated_union():
    p = plan([F(1, files=["scripts/a.py", "scripts/b.py"], tests=["t1", "t2"]), F(2, files="scripts/b.py, scripts/c.py", tests=["t2", "t3"])])
    check("Files: scripts/a.py, scripts/b.py, scripts/c.py\nTests: t1, t2, t3" in p["issue"], "## Scope is the union, once each, in order")


def test_title_names_the_first_blocking_finding():
    p = plan([F(1, "non-blocking", title="nit"), F(2, title="real bug"), F(3)])
    check(p["title"] == "Review findings: real bug (+2 more)" or p["title"].startswith("Review findings: real bug"), "the title leads with a blocking finding")
    check(len(plan([F(1, title="x" * 300)])["title"]) < 100, "a long title is cut")


def test_body_size_is_capped():
    p = plan([F(i, repro="x" * 10000) for i in range(30)])
    check(len(p["issue"]) <= rf.BODY_MAX + 300 and trailer_ok(p["issue"]), "a huge round still files a body GitHub accepts, trailer intact")


def test_big_round_shortens_fields_before_dropping_a_finding():
    p = plan([F(i, repro="x" * 3000, actual="y" * 3000, expected="z" * 3000) for i in range(12)])
    check(len(boxes(p["issue"])) == 12 and len(p["issue"]) <= rf.BODY_MAX, "12 long findings: every checkbox kept, body under the limit")


def test_security_style_finding_carries_detail():
    p = plan([F(1, title="Security: SQL injection", detail="root cause: ...\ntrace: a.py:10\nremediation: bind params")])
    check("  - Detail: root cause: ...\n    trace: a.py:10\n    remediation: bind params" in p["issue"], "detail carries a security finding's trace and remediation")


def run(args, stdin="", env=None, input_file=None):
    e = dict(os.environ, **(env or {}))
    return subprocess.run([sys.executable, PY] + args, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, env=e)


def test_cli_plan_json_and_errors():
    fs = [F(1), F(2, "non-blocking")]
    r = run(["plan", "--prd", "7"], json.dumps(fs))
    d = json.loads(r.stdout)
    check(r.returncode == 0 and d["issue"] and "finding 2" in d["notes"], "plan prints the JSON plan on stdout, exit 0")
    r = run(["plan", "--prd", "7"], json.dumps({"findings": fs}))
    check(r.returncode == 0 and json.loads(r.stdout)["issue"], "a {findings: [...]} object is accepted")
    r = run(["plan", "--prd", "7"], "")
    check(r.returncode == 0 and json.loads(r.stdout)["issue"] is None, "empty stdin is K=0")
    r = run(["plan", "--prd", "7"], "not json")
    check(r.returncode == 2 and "not valid JSON" in r.stderr and "Traceback" not in r.stderr, "bad JSON: one line on stderr, exit 2")
    r = run(["plan", "--prd", "7"], '{"a": 1}')
    check(r.returncode == 2 and "must be a JSON list" in r.stderr, "an object without findings: exit 2")
    r = run(["plan", "--prd", "7"], '["x"]')
    check(r.returncode == 2 and "finding 1 is not a JSON object" in r.stderr, "a non-object finding: exit 2")
    r = run(["plan", "--prd", "0"], "[]")
    check(r.returncode == 2 and "not an issue number" in r.stderr, "--prd 0: exit 2")
    r = run(["plan", "--prd", "7", "--input", "/nonexistent/f.json"])
    check(r.returncode == 2 and "Traceback" not in r.stderr, "a missing --input file: exit 2, no traceback")
    with tempfile.TemporaryDirectory() as d_:
        path = os.path.join(d_, "f.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(fs, fh)
        r = run(["plan", "--prd", "7", "--input", path])
        check(r.returncode == 0 and json.loads(r.stdout)["issue"], "--input FILE reads the findings from a file")


def test_cli_file_makes_exactly_one_gh_issue_create():
    with tempfile.TemporaryDirectory() as d_:
        log, stub = os.path.join(d_, "gh.log"), os.path.join(d_, "bin")
        os.mkdir(stub)
        gh = os.path.join(stub, "gh")
        with open(gh, "w") as fh:
            fh.write('#!/usr/bin/env bash\n{ printf "%s\\n" "$*"; } >> "$GH_LOG"\n'
                     'while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$GH_LOG.body"; shift; done\n'
                     'echo https://github.com/acme/widget/issues/42\n')
        os.chmod(gh, os.stat(gh).st_mode | stat.S_IEXEC)
        env = {"PATH": stub + os.pathsep + os.environ["PATH"], "GH_LOG": log}
        fs = [F(i, "blocking" if i < 3 else "non-blocking", files=[f"d{i}/f.py"]) for i in range(7)]
        r = run(["file", "--prd", "7", "-R", "acme/widget", "--label", "ready-for-agent"], json.dumps(fs), env)
        d = json.loads(r.stdout)
        calls = open(log).read().splitlines()
        check(r.returncode == 0 and len(calls) == 1 and calls[0].startswith("issue create -R acme/widget --title "), "K=7: exactly one gh issue create")
        check("--label ready-for-agent" in calls[0], "the issue carries the ready label")
        check(d["url"] == "https://github.com/acme/widget/issues/42", "the URL gh printed is in the output")
        check(open(log + ".body").read() == d["issue"], "the body gh got is the plan's body")
        os.unlink(log)
        r = run(["file", "--prd", "7", "-R", "acme/widget", "--label", "ready-for-agent"], json.dumps([F(1, "non-blocking")]), env)
        check(r.returncode == 0 and not os.path.exists(log) and json.loads(r.stdout)["issue"] is None, "non-blocking below the limits: gh is never called")
        r = run(["file", "--prd", "7", "-R", "acme/widget", "--label", "ready-for-agent"], "[]", env)
        check(r.returncode == 0 and not os.path.exists(log), "K=0: gh is never called")
        with open(gh, "w") as fh:
            fh.write('#!/usr/bin/env bash\necho "gh: no auth" >&2\nexit 1\n')
        r = run(["file", "--prd", "7", "-R", "acme/widget", "--label", "ready-for-agent"], json.dumps([F(1)]), env)
        check(r.returncode == 3 and "could not create the issue: gh: no auth" in r.stderr, "a failing gh: exit 3 naming gh's message")


def test_tier_toml_error_is_one_line():
    with tempfile.TemporaryDirectory() as d_:
        bad = os.path.join(d_, "tier.toml")
        with open(bad, "w") as fh:
            fh.write("[direct]\nmax_criteria = 0\n")
        r = run(["plan", "--prd", "7"], "[]", {"HARNESS_TIER_TOML": bad})
        check(r.returncode == 2 and "max_criteria" in r.stderr and "Traceback" not in r.stderr, "a bad tier.toml: exit 2 naming the key")


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            print(name)
            fn()
    print(f"-- {'all pass' if not FAILS else str(len(FAILS)) + ' FAILED'}")
    sys.exit(1 if FAILS else 0)

#!/usr/bin/env python3
"""review_findings.py — one follow-up issue per PRD review round, however many findings it has (#1183, PRD #1180).

    review_findings.py plan --prd N [--input FILE]            print the plan as JSON
    review_findings.py file --prd N -R owner/repo --label L [--input FILE]
                                                              print the plan, and create the issue it names

Every follow-up lane costs about $0.31 and 2.4 minutes, so a review round files AT MOST ONE issue. The reviewer
(prompts/review.md) feeds every finding it collected in the pass through this helper and files exactly what it
returns, so the rule is code, not prose the reviewer may read differently each round.

Input: a JSON list (or {"findings": [...]}) read from --input or stdin. One object per finding:

    severity   "blocking" | "non-blocking". Missing, empty or unrecognised means blocking: a finding nobody
               classified must never be dropped to a note.
    title      one line
    files      the source files it lives in (a list; a comma separated string is accepted)
    tests      the test files that cover them (from `rtdd explain`)
    repro      the exact command or call that shows it
    expected, actual
    detail     anything else (a security finding's root cause, trace and remediation)
    lines      optional estimate of the diff the fix needs
    subsystem  optional; default is the first path component of each file (all root files are one subsystem)

The rule:

  1. No findings: no issue, no notes.
  2. Blocking findings are mandatory work. Any blocking finding files the one issue.
  3. Non-blocking findings are weighed against the tier `direct` limits in tier.toml (max_criteria = the count of
     non-blocking findings, max_files = the files they name, max_subsystems, max_changed_lines = the sum of their
     `lines` estimates). At or under every limit they are NOTES for the PRD comment and file no issue, with or
     without blocking findings beside them: the lane that fixes the blocking ones is already paid for, and small
     extras are cheaper left as notes than added to its checklist. Over a limit they go into the one issue.
  4. A round with only non-blocking findings under the limits files nothing.

Output: {"issue": <body>|null, "title": <title>|null, "notes": <PRD-comment text, "" when none>, "reason": ..., "counts": ...}.
The body holds the checklist (`- [ ] ...`, one per finding with its repro, expected and actual), a `## Scope` section
(the union of files and tests) and the `## Blocked by` / `## Parent` trailer the engine parses.
"""
import argparse, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import tier

BLOCKING, NON_BLOCKING = "blocking", "non-blocking"
FIELD_MAX = 3000        # one field of one finding; an issue body may hold 65536 characters in all
BODY_MAX = 60000


class FindingsError(Exception):
    """The input is not a findings list — one line, never a traceback."""


def _text(v):
    return v if isinstance(v, str) else ("" if v is None else str(v))


def _one_line(v):
    """A title or a path on one line: any whitespace run, U+2028 and a form feed included, becomes one space."""
    return " ".join(_text(v).split())


def _lines(v, cap=FIELD_MAX):
    """A free-text field as a list of lines (splitlines also splits on U+2028, U+0085 and a form feed), trimmed of blank ends."""
    s = _text(v)
    if len(s) > cap:
        s = s[:cap] + " ... (truncated)"
    out = [l.rstrip() for l in s.splitlines()]
    while out and not out[0].strip():
        out.pop(0)
    while out and not out[-1].strip():
        out.pop()
    return out


def _list(v):
    """files / tests: a list, or a string split on commas; stripped, empties dropped, duplicates kept once, in order."""
    if isinstance(v, str):
        v = v.split(",")
    elif not isinstance(v, (list, tuple)):
        v = [] if v is None else [v]
    seen, out = set(), []
    for x in v:
        x = _one_line(x).replace("\\", "/")
        if x and x not in seen:
            seen.add(x)
            out.append(x)
    return out


def severity_of(v):
    """`blocking` or `non-blocking`; anything else (missing, empty, a typo) is blocking."""
    s = _one_line(v).lower().replace("_", "-").replace(" ", "-")
    return NON_BLOCKING if s in ("non-blocking", "nonblocking") else BLOCKING


def normalise(raw):
    """The findings list as clean dicts. A non-list or a non-object item is a FindingsError."""
    if isinstance(raw, dict) and isinstance(raw.get("findings"), list):
        raw = raw["findings"]
    if not isinstance(raw, list):
        raise FindingsError('findings must be a JSON list (or {"findings": [...]})')
    out = []
    for i, f in enumerate(raw, 1):
        if not isinstance(f, dict):
            raise FindingsError(f"finding {i} is not a JSON object")
        files = _list(f.get("files"))
        lines = f.get("lines", 0)
        lines = lines if isinstance(lines, int) and not isinstance(lines, bool) and lines > 0 else 0
        out.append({
            "severity": severity_of(f.get("severity")),
            "title": _one_line(f.get("title")) or _one_line(f.get("actual")) or f"Untitled finding {i}",
            "files": files, "tests": _list(f.get("tests")),
            "repro": f.get("repro"), "expected": f.get("expected"), "actual": f.get("actual"), "detail": f.get("detail"),
            "lines": lines,
            "subsystems": _list(f.get("subsystem")) or sorted({s.split("/", 1)[0] if "/" in s else "." for s in files}),
        })
    return out


def _union(findings, key):
    seen, out = set(), []
    for f in findings:
        for x in f[key]:
            if x not in seen:
                seen.add(x)
                out.append(x)
    return out


def limits_crossed(cfg, findings):
    """The direct limits the non-blocking `findings` cross, as short phrases; empty when they fit one small session."""
    d = cfg["direct"]
    subs = _union([{"s": f["subsystems"]} for f in findings], "s")
    over = []
    if len(findings) > d["max_criteria"]:
        over.append(f"{len(findings)} findings (> {d['max_criteria']})")
    if len(_union(findings, "files")) > d["max_files"]:
        over.append(f"{len(_union(findings, 'files'))} files (> {d['max_files']})")
    if len(subs) > d["max_subsystems"]:
        over.append(f"{len(subs)} subsystems (> {d['max_subsystems']})")
    if sum(f["lines"] for f in findings) > d["max_changed_lines"]:
        over.append(f"~{sum(f['lines'] for f in findings)} changed lines (> {d['max_changed_lines']})")
    return over


def _item(f, box, cap=FIELD_MAX):
    """One finding as a markdown list item: `- [ ] **[severity] title** (files)` and its fields indented under it."""
    head = f"- {'[ ] ' if box else ''}**[{f['severity']}] {f['title']}**"
    if f["files"]:
        head += " (" + ", ".join(f["files"]) + ")"
    rows = [head]
    for label, key in (("Repro", "repro"), ("Expected", "expected"), ("Actual", "actual"), ("Detail", "detail")):
        ls = _lines(f[key], cap)
        if ls:
            rows.append(f"  - {label}: {ls[0]}")
            rows += ["    " + l for l in ls[1:]]
    if f["tests"]:
        rows.append("  - Tests: " + ", ".join(f["tests"]))
    return "\n".join(rows)


def build_body(findings, prd):
    blocking = [f for f in findings if f["severity"] == BLOCKING]
    rest = [f for f in findings if f["severity"] != BLOCKING]
    files, tests = _union(findings, "files"), _union(findings, "tests")
    def render(cap):
        return "\n".join(["Review findings for the PRD, to be worked in ONE lane. Tick each box when its fix is in; every box is part of this issue.",
                      "", "## Findings", ""] + [_item(f, True, cap) for f in blocking + rest])
    tail = "\n".join(["", "## Scope", "Files: " + (", ".join(files) or "none named: start from the findings above"),
                      "Tests: " + (", ".join(tests) or "none named: use rtdd Rounds 1+2 for the files you change"), "",
                      "## Blocked by", "None", "", "## Parent", f"#{prd}", "", f"Part of #{prd}"])
    room = BODY_MAX - len(tail) - 100   # the Scope and the trailer always fit; an over-long checklist is cut, and says so
    head = render(FIELD_MAX)
    for cap in (500, 100):   # a huge round shortens every field before it drops any finding
        if len(head) > room:
            head = render(cap)
    if len(head) > room:
        head = head[:room].rstrip() + f"\n\n(findings truncated: the issue body holds at most {BODY_MAX} characters)\n"
    return head + "\n" + tail


def _title(findings):
    first = next((f for f in findings if f["severity"] == BLOCKING), findings[0])["title"]
    first = first if len(first) <= 70 else first[:67].rstrip() + "..."
    extra = len(findings) - 1
    return f"Review findings: {first}" + (f" (+{extra} more)" if extra else "")


def plan(findings, prd, cfg=None):
    """The plan for one review round: {issue, title, notes, reason, counts}. `findings` is normalise()d input."""
    cfg = cfg or tier.load()
    blocking = [f for f in findings if f["severity"] == BLOCKING]
    rest = [f for f in findings if f["severity"] != BLOCKING]
    over = limits_crossed(cfg, rest) if rest else []
    counts = {"findings": len(findings), "blocking": len(blocking), "non_blocking": len(rest)}
    if not findings:
        return {"issue": None, "title": None, "notes": "", "reason": "no findings: nothing to file", "counts": counts}
    if blocking or over:
        in_issue = findings if over else blocking
        notes_for = [] if over else rest
        if blocking and over:
            reason = "blocking findings, and the non-blocking ones cross the direct limits (" + "; ".join(over) + "): all in one issue"
        elif blocking:
            reason = ("blocking findings file one issue" + ("; the non-blocking ones are within the direct limits, so they are notes"
                      if rest else ""))
        else:
            reason = "non-blocking findings cross the direct limits (" + "; ".join(over) + "): one issue"
        counts["in_issue"], counts["in_notes"] = len(in_issue), len(notes_for)
        return {"issue": build_body(in_issue, prd), "title": _title(in_issue), "notes": _notes(notes_for), "reason": reason, "counts": counts}
    counts["in_issue"], counts["in_notes"] = 0, len(rest)
    return {"issue": None, "title": None, "notes": _notes(rest), "counts": counts,
            "reason": "only non-blocking findings, within the direct limits: notes, no issue"}


def _notes(findings):
    if not findings:
        return ""
    return "Review notes (non-blocking, within the direct limits, so no issue was filed):\n" + "\n".join(_item(f, False) for f in findings)


def create(p, slug, label):
    """Run `gh issue create` for the plan's issue. Returns the URL gh printed; raises RuntimeError with gh's message."""
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as fh:
        fh.write(p["issue"])
        path = fh.name
    try:
        r = subprocess.run(["gh", "issue", "create", "-R", slug, "--title", p["title"], "--body-file", path, "--label", label],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    finally:
        os.unlink(path)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout or f"gh exited {r.returncode}").strip())
    return r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""


def _prd(v):
    try:
        n = int(v)
    except ValueError:
        n = 0
    if n < 1:
        raise argparse.ArgumentTypeError(f"{v!r} is not an issue number")
    return n


def main(argv=None):
    import stats
    ap = stats.arg_parser(prog="review_findings", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "file"):
        s = sub.add_parser(name)
        s.add_argument("--prd", type=_prd, required=True)
        s.add_argument("--input", default="-", help="the findings JSON file (default: stdin)")
        if name == "file":
            s.add_argument("-R", dest="repo", required=True)
            s.add_argument("--label", required=True)
    a = ap.parse_args(argv)
    try:
        text = sys.stdin.read() if a.input == "-" else open(a.input, encoding="utf-8-sig").read()
        try:
            raw = json.loads(text) if text.strip() else []
        except ValueError as e:
            raise FindingsError(f"the findings are not valid JSON: {e}")
        findings = normalise(raw)
        p = plan(findings, a.prd, tier.load())
    except (OSError, FindingsError, tier.TierConfigError) as e:
        print(stats.vis(f"review_findings: {e}"), file=sys.stderr)
        return 2
    if a.cmd == "file" and p["issue"]:
        try:
            p["url"] = create(p, a.repo, a.label)
        except (RuntimeError, OSError) as e:
            print(stats.vis(f"review_findings: could not create the issue: {e}"), file=sys.stderr)
            return 3
    print(json.dumps(p))
    return 0


if __name__ == "__main__":
    import pipesafe
    sys.exit(pipesafe.run(main))

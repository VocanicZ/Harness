#!/usr/bin/env python3
"""test_web_plan_docs.py — #222: PRD #192's Task 1 deliverable keeps its shape.

docs/plans/2026-10-24-web-dashboard.md must read like the hand-written plans in docs/superpowers/plans/:
a Goal / Architecture / Spec header, `## Global Constraints`, numbered `### Task N` sections each with
**Files** and **Interfaces** and a step 1 that is a literal failing test, and a closing
`## What this plan deliberately leaves undone`.

Its tasks line up with #192's other children (#223-#231), one task per child, and between them they
cover every part the PRD names. The PRD's hard limits (read-only, no GitHub call per page view, the
bind/port env vars and their 127.0.0.1:4637 default, no build step) are Global Constraints."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
PLAN = os.path.join(ROOT, "docs", "plans", "2026-10-24-web-dashboard.md")

CHILDREN = list(range(223, 232))
# Each part the PRD (#192) and #222 say the plan must cover, and a phrase that names it.
COVERS = {
    "server": r"`harness web`",
    "SSE": r"\bSSE\b",
    "fleet registry": r"HARNESS_FLEETS_DIR",
    "board cache": r"HARNESS_SNAPSHOTS_DIR",
    "event log": r"events\.jsonl",
    "tmux": r"\btmux\b",
    "supervisor rules": r"supervise_rules\.py",
    "rate-limit state": r"ghrate",
    "DAG port": r"status-page\.py",
    "design port": r"design-to-print",
    "systemd unit": r"harness web --install",
    "update redeploy": r"`harness update`",
    "harness-arc skill": r"skill/harness-arc/SKILL\.md",
    "critique rounds": r"docs/web/ROUNDS\.md",
}
CONSTRAINTS = {
    "read-only": r"[Rr]ead-only",
    "no per-request GitHub": r"\bgh\b.*(page|request)|(page|request).*\bgh\b",
    "bind var": r"HARNESS_WEB_BIND",
    "port var": r"HARNESS_WEB_PORT",
    "default bind": r"127\.0\.0\.1",
    "default port": r"\b4637\b",
    "no build step": r"[Nn]o build step",
}


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def sections(text, level):
    """[(heading, body)] for every heading of exactly `level` #s, body up to the next one at <= level.
    Fenced code is skipped, so a `# comment` inside a test listing is not a heading."""
    out, cur, buf, fence = [], None, [], False
    for line in text.splitlines():
        if line.startswith("```"):
            fence = not fence
        m = None if fence else re.match(r"^(#+) (.*)$", line)
        if m and len(m.group(1)) <= level:
            if cur is not None:
                out.append((cur, "\n".join(buf)))
            cur, buf = (m.group(2) if len(m.group(1)) == level else None), []
            continue
        buf.append(line)
    if cur is not None:
        out.append((cur, "\n".join(buf)))
    return [s for s in out if s[0] is not None]


def tasks():
    return [(h, b) for h, b in sections(read(PLAN), 3) if h.startswith("Task ")]


def test_plan_exists():
    assert os.path.isfile(PLAN), f"missing {PLAN}"


def test_plan_header():
    t = read(PLAN)
    for key in ("**Goal:**", "**Architecture:**", "**Spec:**"):
        assert re.search(r"^" + re.escape(key), t, re.M), f"plan header lacks {key}"
    assert re.search(r"^## Global Constraints$", t, re.M), "plan lacks ## Global Constraints"


def test_plan_tasks_numbered_with_files_interfaces_and_failing_test_first():
    ts = tasks()
    assert ts, "plan has no ### Task sections"
    nums = [int(re.match(r"Task (\d+)", h).group(1)) for h, _ in ts]
    assert nums == list(range(1, len(nums) + 1)), f"tasks not numbered 1..N: {nums}"
    for h, b in ts:
        assert "**Files:**" in b, f"{h}: no **Files:**"
        assert "**Interfaces:**" in b, f"{h}: no **Interfaces:**"
        steps = re.findall(r"^- \[ \] \*\*Step (\d+): ([^*]+)\*\*", b, re.M)
        assert steps, f"{h}: no checkboxed steps"
        assert steps[0][0] == "1" and "failing test" in steps[0][1].lower(), \
            f"{h}: step 1 is not a failing test: {steps[0]}"
        step1 = re.split(r"^- \[ \] \*\*Step 2", b, flags=re.M)[0]
        assert re.search(r"^```", step1, re.M), f"{h}: step 1 has no literal test code"


def test_plan_has_one_task_per_sibling_issue():
    heads = [h for h, _ in tasks()]
    for n in CHILDREN:
        mine = [h for h in heads if re.search(rf"\(#{n}\)", h)]
        assert len(mine) == 1, f"want exactly one task headed with (#{n}), got {mine}"


def test_plan_covers_every_part_the_prd_names():
    t = read(PLAN)
    for part, pat in COVERS.items():
        assert re.search(pat, t), f"plan never covers {part} ({pat})"


def test_global_constraints_hold_the_prd_limits():
    gc = dict(sections(read(PLAN), 2)).get("Global Constraints", "")
    assert gc, "no ## Global Constraints body"
    for what, pat in CONSTRAINTS.items():
        assert re.search(pat, gc), f"## Global Constraints lacks {what} ({pat})"


def test_plan_closes_with_what_it_leaves_undone():
    h2 = [h for h, _ in sections(read(PLAN), 2)]
    assert h2 and h2[-1] == "What this plan deliberately leaves undone", f"last ## is {h2[-1:]}"


if __name__ == "__main__":
    fails = 0
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except (AssertionError, OSError) as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

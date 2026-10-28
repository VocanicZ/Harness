#!/usr/bin/env python3
"""test_release_plan_docs.py — #276: PRD #274's Task 1 deliverable keeps its shape.

docs/plans/2026-10-28-release-updates.md must read like the hand-written plans in docs/plans/: a
Goal / Architecture / Spec header, `## Global Constraints`, numbered `### Task N` sections each with
**Files** and **Interfaces** and a step 1 that is a literal failing test, and a closing
`## What this plan deliberately leaves undone`.

Its tasks line up with #274's other children (#277-#284), one task per child, and between them they
cover every item of the PRD's "What to build" (1-6) and every acceptance criterion (1-8). The PRD's
hard limits (no GitHub Actions, no new runtime dependency, no destructive git op on a host, never
delete a live worker's release) are Global Constraints."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
PLAN = os.path.join(ROOT, "docs", "plans", "2026-10-28-release-updates.md")

CHILDREN = list(range(277, 285))
# Each part the PRD (#274) and #276 say the plan must cover, and a phrase that names it.
COVERS = {
    "VERSION file": r"`VERSION`",
    "--version": r"`harness --version`",
    "release command": r"`harness release`",
    "release gate": r"`test/run\.sh`",
    "Conventional Commits bump": r"Conventional Commits",
    "git archive tarball": r"`git archive`",
    "checksums": r"`SHA256SUMS`",
    "gh release --latest": r"gh release create[^\n]*--latest",
    "idempotency": r"[Ii]dempoten",
    "reviewed-PRD trigger": r"`close_prd`",
    "bug-fix throttle": r"one patch release per hour|at most one (patch release )?per hour",
    "gate failure files a bug": r"files? (one|a) `bug` issue",
    "releases/latest": r"releases/latest",
    "semver compare": r"semver",
    "rtdd message": r"is the latest release\.",
    "release dirs": r"\$HARNESS_HOME/releases/",
    "atomic symlink flip": r"mv -T",
    "keep 2 previous": r"previous 2",
    "rollback": r"`harness update --rollback`",
    "live worker check": r"/proc/\*/environ",
    "install.sh": r"`install\.sh`",
    "HARNESS_REF": r"HARNESS_REF",
    "git-checkout migration": r"releases/git-<sha>",
    "stable engine path": r"\$HARNESS_HOME/engine/bin/harness",
    "README": r"README",
    "rtdd selfupdate mirrored": r"internal/selfupdate",
    "rtdd installer mirrored": r"installer/",
}
CONSTRAINTS = {
    "no GitHub Actions": r"GitHub Actions.*#245|#245.*GitHub Actions",
    "no new runtime dependency": r"[Nn]o new runtime dependency",
    "no destructive git op": r"[Nn]o destructive git op",
    "live worker's release kept": r"[Nn]ever (delete|prune)[^\n]*live worker",
}
# PRD #274's "What to build" items and acceptance criteria, each mapped to the task(s) that deliver
# it in the plan's coverage table: rows `| <id> | ... | Task N[, Task M] |`.
PRD_ITEMS = [f"W{i}" for i in range(1, 7)] + [f"A{i}" for i in range(1, 9)]


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
    assert len(heads) == len(CHILDREN), f"want {len(CHILDREN)} tasks, got {len(heads)}"
    for n in CHILDREN:
        mine = [h for h in heads if re.search(rf"\(#{n}\)", h)]
        assert len(mine) == 1, f"want exactly one task headed with (#{n}), got {mine}"


def test_plan_covers_every_part_the_prd_names():
    t = read(PLAN)
    for part, pat in COVERS.items():
        assert re.search(pat, t), f"plan never covers {part} ({pat})"


def test_every_prd_item_maps_to_a_task():
    t = read(PLAN)
    n_tasks = len(tasks())
    for item in PRD_ITEMS:
        row = re.search(rf"^\| {item} \|.*\|([^|]*)\|\s*$", t, re.M)
        assert row, f"coverage table has no row for PRD #274 {item}"
        named = [int(n) for n in re.findall(r"Task (\d+)", row.group(1))]
        assert named, f"PRD #274 {item} maps to no task: {row.group(0)}"
        assert all(1 <= n <= n_tasks for n in named), f"PRD #274 {item} names a task that does not exist: {named}"


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

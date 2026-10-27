#!/usr/bin/env python3
"""test_cli_plan_docs.py — #220: PRD #189's Task 1 deliverables keep their shape.

docs/plans/2026-10-24-multi-cli.md must read like the hand-written plans in docs/superpowers/plans/:
a Goal / Architecture / Spec header, `## Global Constraints`, numbered `### Task N` sections each with
**Files** and **Interfaces** and a step 1 that is a literal failing test, one task per CLI after the
adapter (each recording real-CLI fixtures under test/fixtures/cli/<cli>/), and a closing
`## What this plan deliberately leaves undone`.

docs/cli-capabilities.md must hold, for each of the ten CLIs, every capability row the PRD lists, and
every row must cite a URL, a source file, or a local command. A MISSING capability names its
Harness-side substitute in the same row."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
PLAN = os.path.join(ROOT, "docs", "plans", "2026-10-24-multi-cli.md")
CAPS = os.path.join(ROOT, "docs", "cli-capabilities.md")

CLIS = ["claude", "agy", "codex", "gemini", "copilot", "cursor-agent", "opencode", "zcode", "hermes",
        "openclaw"]
# The CLIs the plan files a child task for: every one but the reference implementation, whose
# adapter is extracted in the adapter task (#188) together with agy's.
CHILD_CLIS = [c for c in CLIS if c not in ("claude", "agy")]
FIELDS = ["install", "version checked", "launch", "prompt passing", "session id", "model flag",
          "effort flag", "permission bypass", "workspace trust", "hooks / plugins / skills",
          "transcript location", "usage format", "idle string", "busy string", "limit string",
          "transient-error string"]
# A citation: a URL, a repo/source path (`scripts/lib.sh:836`, `codex-rs/tui/src/x.rs`), or a command
# observed on the host (`local: codex --help`).
CITE_RE = re.compile(r"https?://\S+|`[\w@.~/-]+/[\w@.~/-]*(:\d+(-\d+)?)?`|`[\w.-]+\.\w+(:\d+(-\d+)?)?`"
                     r"|local:\s*`[^`]+`")


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def sections(text, level):
    """[(heading, body)] for every heading of exactly `level` #s, body up to the next one at <= level."""
    out, cur, buf = [], None, []
    for line in text.splitlines():
        m = re.match(r"^(#+) (.*)$", line)
        if m and len(m.group(1)) <= level:
            if cur is not None:
                out.append((cur, "\n".join(buf)))
            cur, buf = (m.group(2) if len(m.group(1)) == level else None), []
            continue
        buf.append(line)
    if cur is not None:
        out.append((cur, "\n".join(buf)))
    return [s for s in out if s[0] is not None]


def table_rows(body):
    """{field: (value, source)} for every `| field | value | source |` data row in body."""
    rows = {}
    for line in body.splitlines():
        if not line.startswith("|") or re.match(r"^\|[\s:|-]+\|$", line):
            continue
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]
        if len(cells) < 3 or cells[0].lower() == "field":
            continue
        rows[cells[0].strip("*").lower()] = (" | ".join(cells[1:-1]), cells[-1])
    return rows


def test_plan_exists():
    assert os.path.isfile(PLAN), f"missing {PLAN}"


def test_plan_header():
    t = read(PLAN)
    for key in ("**Goal:**", "**Architecture:**", "**Spec:**"):
        assert re.search(r"^" + re.escape(key), t, re.M), f"plan header lacks {key}"
    assert re.search(r"^## Global Constraints$", t, re.M), "plan lacks ## Global Constraints"


def test_plan_tasks_numbered_with_files_interfaces_and_failing_test_first():
    tasks = [(h, b) for h, b in sections(read(PLAN), 3) if h.startswith("Task ")]
    assert tasks, "plan has no ### Task sections"
    nums = [int(re.match(r"Task (\d+)", h).group(1)) for h, _ in tasks]
    assert nums == list(range(1, len(nums) + 1)), f"tasks not numbered 1..N: {nums}"
    for h, b in tasks:
        assert "**Files:**" in b, f"{h}: no **Files:**"
        assert "**Interfaces:**" in b, f"{h}: no **Interfaces:**"
        steps = re.findall(r"^- \[ \] \*\*Step (\d+): ([^*]+)\*\*", b, re.M)
        assert steps, f"{h}: no checkboxed steps"
        assert steps[0][0] == "1" and "failing test" in steps[0][1].lower(), \
            f"{h}: step 1 is not a failing test: {steps[0]}"
        step1 = re.split(r"^- \[ \] \*\*Step 2", b, flags=re.M)[0]
        assert re.search(r"^```", step1, re.M), f"{h}: step 1 has no literal test code"


def test_plan_files_one_child_per_cli_with_real_fixtures():
    tasks = [(h, b) for h, b in sections(read(PLAN), 3) if h.startswith("Task ")]
    for cli in CHILD_CLIS:
        mine = [b for h, b in tasks if re.search(r"`" + re.escape(cli) + r"`", h)]
        assert len(mine) == 1, f"want exactly one task headed with `{cli}`, got {len(mine)}"
        assert f"test/fixtures/cli/{cli}/" in mine[0], f"`{cli}` task records no fixtures dir"


def test_plan_closes_with_what_it_leaves_undone():
    h2 = [h for h, _ in sections(read(PLAN), 2)]
    assert h2 and h2[-1] == "What this plan deliberately leaves undone", f"last ## is {h2[-1:]}"


def test_capabilities_doc_cites_every_field_for_every_cli():
    assert os.path.isfile(CAPS), f"missing {CAPS}"
    secs = {}
    for h, b in sections(read(CAPS), 2):
        m = re.match(r"`([\w-]+)`", h)
        if m:
            secs[m.group(1)] = b
    for cli in CLIS:
        assert cli in secs, f"no ## `{cli}` section"
        rows = table_rows(secs[cli])
        for field in FIELDS:
            assert field in rows, f"`{cli}`: no `{field}` row"
            value, source = rows[field]
            assert value, f"`{cli}` {field}: empty value"
            assert CITE_RE.search(source), f"`{cli}` {field}: source cites nothing: {source!r}"
            if value.startswith("MISSING"):
                assert "substitute" in value.lower(), f"`{cli}` {field}: MISSING names no substitute"


if __name__ == "__main__":
    fails = 0
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except (AssertionError, OSError) as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

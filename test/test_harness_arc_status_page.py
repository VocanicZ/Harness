#!/usr/bin/env python3
"""test_harness_arc_status_page.py — #181: skill/harness-arc/scripts/status-page.py moved into the repo
and must keep working (#192 replaces it later). Runs the real script end to end against stub `gh` and
`tmux` binaries on PATH serving a fixture arc: a fork, a closed PRD, a wayfinder map + ticket."""
import contextlib, importlib.util, io, json, os, runpy, shutil, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.normpath(os.path.join(HERE, "..", "skill", "harness-arc", "scripts", "status-page.py"))


def lbl(*names):
    return [{"name": n} for n in names]


PRDS = [
    {"number": 10, "title": "[AFK] PRD: Core — the base layer everything needs", "state": "CLOSED",
     "body": "Mentions ## Blocked by in prose.\n\n## Blocked by\nNone\n", "labels": lbl("prd"), "url": "u10"},
    {"number": 11, "title": "[AFK] PRD: Left — fork A", "state": "OPEN",
     "body": "## Blocked by\n#10\n", "labels": lbl("prd"), "url": "u11"},
    {"number": 12, "title": "[AFK] PRD: Right — fork B", "state": "OPEN",
     "body": "## Blocked by\n#10\n\n## Non-goals\n#99 is not a dep\n", "labels": lbl("prd"), "url": "u12"},
    {"number": 13, "title": "[AFK] PRD: Join — <needs> both", "state": "OPEN",
     "body": "## Blocked by\n#11, #12\n", "labels": lbl("prd"), "url": "u13"},
]
OTHERS = [
    {"number": 20, "title": "child", "state": "CLOSED", "body": "## Parent\n#11\n",
     "labels": lbl("ready-for-agent"), "url": "u20"},
    {"number": 21, "title": "child", "state": "OPEN", "body": "## Parent\n#11\n",
     "labels": lbl("ready-for-agent", "agent-working"), "url": "u21"},
    {"number": 30, "title": "Wayfinder map", "state": "OPEN", "body": "", "labels": lbl("wayfinder:map"), "url": "u30"},
    {"number": 31, "title": "Pick a threshold", "state": "OPEN", "body": "## Blocked by\n#13\n",
     "labels": lbl("wayfinder:decision"), "url": "u31"},
]


@contextlib.contextmanager
def stubs(prds=PRDS, others=OTHERS, gh_ok=True, tmux=True):
    d = tempfile.mkdtemp()
    data = os.path.join(d, "data.json")
    json.dump({"prds": prds, "all": prds + others}, open(data, "w"))
    os.makedirs(os.path.join(d, "bin"))
    if gh_ok:
        with open(os.path.join(d, "bin", "gh"), "w") as f:
            f.write(f"#!{sys.executable}\nimport json, sys\nd = json.load(open({data!r}))\na = sys.argv[1:]\n"
                    "if a[0] == 'api': print('repo')\n"
                    "elif '--label' in a: print(json.dumps(d['prds']))\n"
                    "else: print(json.dumps(d['all']))\n")
    else:
        with open(os.path.join(d, "bin", "gh"), "w") as f:
            f.write("#!/bin/sh\necho 'not json'\n")
    if tmux:
        with open(os.path.join(d, "bin", "tmux"), "w") as f:
            f.write("#!/bin/sh\necho 'hz-i21-arc: 1 windows'\necho 'other: 1 windows'\n")
    for b in os.listdir(os.path.join(d, "bin")):
        os.chmod(os.path.join(d, "bin", b), 0o755)
    saved = {k: os.environ.get(k) for k in ("PATH", "HARNESS_SLUG", "HARNESS_UNIT", "HARNESS_SESS_PREFIX")}
    os.environ["PATH"] = os.path.join(d, "bin") + (":/usr/bin:/bin" if tmux else ":/nonexistent")
    os.environ.update(HARNESS_SLUG="owner/arc", HARNESS_UNIT="arc", HARNESS_SESS_PREFIX="hz")
    try:
        yield d
    finally:
        for k, v in saved.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v
        shutil.rmtree(d, ignore_errors=True)


def run(argv):
    saved = sys.argv
    sys.argv = [SCRIPT] + argv
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(SCRIPT, run_name="__main__")
        return 0
    except SystemExit as e:
        return e.code
    finally:
        sys.argv = saved


def load():
    spec = importlib.util.spec_from_file_location("status_page", SCRIPT)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


def test_renders_the_arc_as_a_layered_dag():
    with stubs() as d:
        out = os.path.join(d, "arc.html")
        assert run(["-o", out, "--title", "Test Arc"]) in (0, None)
        page = open(out).read()
    assert "Test Arc" in page
    assert "<svg" in page and "PRD dependency graph" in page
    for n in (10, 11, 12, 13):
        assert f"#{n}" in page, n
    assert page.count("<path ") == 4, "two fork edges + two join edges"
    assert "Pick a threshold" in page and "u30" in page, "the wayfinder map and its ticket"
    assert "&lt;needs&gt;" in page, "titles are escaped"
    assert "hz-i21-arc" in page, "live sessions come from tmux"
    assert "1/2" in page, "PRD #11: one of two children closed"


def test_blocked_by_reads_the_last_header_and_stops_at_the_next_section():
    m = load()
    assert m.blocked_by(PRDS[0]["body"]) == []
    assert m.blocked_by(PRDS[2]["body"]) == [10]
    assert m.blocked_by(PRDS[3]["body"]) == [11, 12]
    assert m.blocked_by("") == [] and m.blocked_by("no header") == []
    assert m.parent_of("## Parent\n#11\n") == 11 and m.parent_of("") is None and m.parent_of("x") is None


def test_layers_survive_a_cycle():
    m = load()
    lay = m.layers({1, 2}, {1: [2], 2: [1]})
    assert set(lay) == {1, 2}


def test_an_edge_to_a_non_prd_is_not_drawn():
    m = load()
    svg = m.dag_svg([{"number": 1, "title": "One — x"}], {1: [77]}, lambda p: "waiting")
    assert "#1 One" in svg and "<path " not in svg, svg


def test_states():
    with stubs() as d:
        out = os.path.join(d, "arc.html")
        run(["-o", out])
        page = open(out).read()
    for pill in ("Closed", "In flight", "Claimable", "Blocked"):
        assert pill in page, pill


def test_refusals_and_a_broken_gh():
    with stubs():
        os.environ["HARNESS_SLUG"] = ""
        assert "HARNESS_SLUG" in str(run([]))
    with stubs(prds=[], others=[]):
        assert "no PRDs found" in str(run([]))
    with stubs(gh_ok=False):
        assert "no PRDs found" in str(run([])), "unparseable gh output reads as no issues"
    with stubs(tmux=False) as d:
        os.remove(os.path.join(d, "bin", "gh"))
        m = load()
        assert m.gh("api", "x") == "", "a missing gh reads as empty"


def test_no_tmux_means_no_live_sessions():
    with stubs(tmux=False) as d:
        out = os.path.join(d, "arc.html")
        assert run(["-o", out]) in (0, None)
        assert "hz-i21-arc" not in open(out).read()


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

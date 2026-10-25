#!/usr/bin/env python3
"""test_supervise_rules.py — #181: the harness-arc watchdog rules folded into `harness supervise`.
Pure-function cases on fixture facts (no gh, no tmux), plus the on-disk counters across a restart,
the gather seam with a gh outage, the unfiled-plan grep on a real git repo, and `--alarms`."""
import contextlib, importlib.util, io, json, os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "supervise_rules", os.path.normpath(os.path.join(HERE, "..", "scripts", "supervise_rules.py")))
sr = importlib.util.module_from_spec(spec); spec.loader.exec_module(sr)
il = sr.issuelib
SLUG = "owner/repo"


def issue(n, state="OPEN", labels=(), body=""):
    return il._normalize_issues([{"number": n, "state": state, "body": body,
                                  "labels": [{"name": l} for l in labels]}])[0]


def state(prds=(), open_children=0, unblocked=()):
    return {"prds": list(prds), "open_children": open_children, "unblocked": list(unblocked)}


def prd(n, open=True, eligible=True, children_exist=True, all_closed=False, reviewed=False):
    return {"number": n, "open": open, "eligible": eligible, "children_exist": children_exist,
            "children_all_closed": all_closed, "reviewed": reviewed, "unblocked": []}


def sess(name, issue_n="", kind="impl", slug=SLUG):
    return {"session": name, "slug": slug, "issue": str(issue_n), "kind": kind}


def facts(sessions=(), panes=None, st=None, issues=(), unfiled=None, mode="prd", repo=True):
    return {"sessions": list(sessions), "panes": panes or {}, "unfiled": unfiled, "mode": mode,
            "repos": {SLUG: {"state": st or state(), "issues": list(issues)} if repo else None}}


def passes(f, n, counters=None, **kw):
    """Run n supervisor passes over the same facts; -> every output line, per pass."""
    counters = {} if counters is None else counters
    out = []
    for _ in range(n):
        rules, fixes = sr.evaluate(f, counters, **kw)
        out.append(sr.apply(rules, fixes, counters))
    return out


def test_wedged_session_is_fixed_after_two_passes_not_one():
    f = facts([sess("hz-u-i7", 7)], panes={"hz-u-i7": "...\nSTOP_HOOK_BLOCK_CAP reached\n"},
              issues=[issue(7, labels=["agent-working"])])
    out = passes(f, 2)
    assert "FIX wedged hz-u-i7" not in out[0], out
    assert "FIX wedged hz-u-i7" in out[1], out


def test_healthy_pane_is_left_alone():
    f = facts([sess("hz-u-i7", 7)], panes={"hz-u-i7": "working (40%|12%)\n"},
              issues=[issue(7, labels=["agent-working"])])
    assert passes(f, 5) == [[]] * 5


def test_deep_context_alarms_once_then_resolves():
    c = {}
    f = facts([sess("hz-u-i7", 7)], panes={"hz-u-i7": "old (90%|1%)\n…\nnow (260%|30%)\n"},
              issues=[issue(7, labels=["agent-working"])])
    out = passes(f, 4, c)
    alarms = [l for p in out for l in p if l.startswith("ALARM deep-context:hz-u-i7")]
    assert len(alarms) == 1 and "260%" in alarms[0] and not out[0], out
    assert c["firing"] == ["deep-context:hz-u-i7"], c
    f["panes"]["hz-u-i7"] = "fresh (20%|1%)\n"
    assert passes(f, 1, c) == [["RESOLVED deep-context:hz-u-i7"]]
    assert c["firing"] == [], c


def test_zombie_session_fix_needs_three_passes():
    f = facts([sess("hz-u-i7", 7)], issues=[issue(7, state="CLOSED", labels=["agent-working"])])
    out = passes(f, 3)
    assert out[1] == [] and "FIX zombie hz-u-i7" in out[2], out
    assert not any("unlocked" in l for p in out for l in p), "a closed issue is a zombie, not unlocked"


def test_issue_missing_from_listing_is_unknown_not_zombie():
    f = facts([sess("hz-u-i7", 7)], issues=[])
    assert passes(f, 5) == [[]] * 5


def test_unlocked_work_is_relabelled_after_three_passes():
    f = facts([sess("hz-u-i7", 7)], issues=[issue(7)])
    out = passes(f, 3)
    assert out[2] == ["FIX unlocked owner/repo 7"], out
    f["repos"][SLUG]["issues"] = [issue(7, labels=["agent-working"])]
    assert passes(f, 3) == [[]] * 3
    for parked in ("agent-paused", "agent-blocked"):
        f["repos"][SLUG]["issues"] = [issue(7, labels=[parked])]
        assert passes(f, 3) == [[]] * 3, f"a {parked} issue dropped its lock on purpose"


def test_orch_and_bug_sessions_are_not_judged_on_the_lock():
    f = facts([sess("hz-u-p3", 3, kind="orch"), sess("hz-bug-x-4-fix", 4, kind="bug")],
              issues=[issue(3, state="CLOSED"), issue(4)])
    assert passes(f, 4) == [[]] * 4


def test_review_loop_counts_gate_rounds_and_survives_a_restart():
    d = tempfile.mkdtemp()
    try:
        path = os.path.join(d, "rules", "hz.json")
        gate = state([prd(5, all_closed=True)])
        reopened = state([prd(5, all_closed=False)])
        out = []
        for rnd in range(4):
            for st in (gate, gate, reopened):           # two passes at the gate, then a gap issue
                c = sr.load(path)                       # a supervisor restart every pass
                rules, fixes = sr.evaluate(facts(st=st), c)
                out += sr.apply(rules, fixes, c)
                sr.save(path, c)
        assert sr.load(path)["rounds"] == {"owner/repo#5": 4}, sr.load(path)
        loops = [l for l in out if l.startswith("ALARM review-loop:owner/repo#5")]
        assert len(loops) == 1 and "4x" in loops[0], out
        assert "RESOLVED review-loop:owner/repo#5" in out, out
    finally:
        shutil.rmtree(d)


def test_decompose_stalled_needs_three_quiet_passes_and_no_session():
    st = state([prd(5, children_exist=False)])
    out = passes(facts(st=st), 3)
    assert out[1] == [] and out[2][0].startswith("ALARM decompose:owner/repo DECOMPOSE STALLED"), out
    assert passes(facts([sess("hz-u-p5", 5, kind="orch")], st=st), 4) == [[]] * 4


def test_no_frontier():
    st = state(open_children=3, unblocked=[])
    out = passes(facts(st=st), 2)
    assert out[1] and out[1][0].startswith("ALARM frontier:owner/repo NO FRONTIER"), out
    assert passes(facts(st=state(open_children=3, unblocked=[9])), 3) == [[]] * 3


def test_missing_parent_only_outside_issue_only_mode_and_honours_exemptions():
    iss = [issue(8, labels=["ready-for-agent"], body="no trailer"),
           issue(9, labels=["ready-for-agent"], body="## Parent\n#5\n"),
           issue(5, labels=["prd", "ready-for-agent"])]
    st = state([prd(5)])
    out = passes(facts(st=st, issues=iss), 2)
    assert out[1] and out[1][0].startswith("ALARM no-parent:owner/repo NO PARENT owner/repo [8]"), out
    assert passes(facts(st=st, issues=iss, mode="issue-only"), 3) == [[]] * 3
    assert passes(facts(st=st, issues=iss), 3, exempt={8}) == [[]] * 3


def test_wayfinder_leak():
    iss = [issue(11, labels=["ready-for-agent", "wayfinder:decision"])]
    out = passes(facts(issues=iss, mode="issue-only"), 2)
    assert out[1] and out[1][0].startswith("ALARM wf-leak:owner/repo WAYFINDER LEAK owner/repo [11]"), out


def test_unfiled_plans_honour_the_reconciled_allowlist():
    out = passes(facts(unfiled=["docs/superpowers/plans/a.md"]), 2)
    assert out[1] and out[1][0].startswith("ALARM unfiled UNFILED TASKS"), out
    assert passes(facts(unfiled=["docs/superpowers/plans/a.md"]), 3,
                  reconciled={"docs/superpowers/plans/a.md"}) == [[]] * 3


def test_an_unreadable_repo_holds_its_strikes():
    c = {}
    st = state(open_children=3)
    passes(facts(st=st), 1, c)
    assert c["strikes"]["frontier:owner/repo"] == 1
    passes(facts(repo=False), 3, c)                     # gh outage: rule not evaluated
    assert c["strikes"]["frontier:owner/repo"] == 1, c
    assert passes(facts(st=st), 1, c)[0][0].startswith("ALARM frontier"), "the outage did not reset the count"


def test_strikes_of_an_ended_session_are_forgotten():
    c = {}
    passes(facts([sess("hz-u-i7", 7)], panes={"hz-u-i7": "STOP_HOOK_BLOCK_CAP"},
                 issues=[issue(7, labels=["agent-working"])]), 1, c)
    assert "wedged:hz-u-i7" in c["strikes"]
    passes(facts(), 1, c)
    assert "wedged:hz-u-i7" not in c["strikes"], c


def test_gather_reads_every_slug_and_holds_an_unreadable_one():
    saved = (il._list_issues, il.compute_state, sr.capture, sr.unfiled_plans)
    def lst(slug):
        if slug == "owner/down":
            raise il.GhError("boom")
        return [issue(1)]
    try:
        il._list_issues, il.compute_state = lst, lambda slug: state()
        sr.capture, sr.unfiled_plans = (lambda s: f"pane of {s}"), (lambda d: [])
        with contextlib.redirect_stderr(io.StringIO()) as err:
            f = sr.gather(["owner/repo", "owner/down"], [sess("hz-u-i1", 1)], "")
        assert f["repos"]["owner/down"] is None and f["repos"]["owner/repo"]["issues"][0]["number"] == 1, f
        assert f["panes"] == {"hz-u-i1": "pane of hz-u-i1"}, f
        assert "owner/down unreadable" in err.getvalue()
    finally:
        il._list_issues, il.compute_state, sr.capture, sr.unfiled_plans = saved


def test_unfiled_plans_greps_the_default_branch():
    d = tempfile.mkdtemp()
    try:
        g = lambda *a: subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *a],
                                      cwd=d, capture_output=True, text=True, check=True)
        os.makedirs(os.path.join(d, "src", "docs", "superpowers", "plans"))
        open(os.path.join(d, "src", "docs", "superpowers", "plans", "p1.md"), "w").write("Task 3: no issue filed yet\n")
        open(os.path.join(d, "src", "docs", "superpowers", "plans", "p2.md"), "w").write("Task 1: #12\n")
        g("init", "-q", "--bare", "-b", "main", "remote.git")
        g("-C", "src", "init", "-q", "-b", "main"); g("-C", "src", "add", "-A"); g("-C", "src", "commit", "-qm", "x")
        g("-C", "src", "remote", "add", "origin", os.path.join(d, "remote.git"))
        g("-C", "src", "push", "-q", "origin", "main")
        g("-C", "src", "fetch", "-q", "origin")
        assert sr.unfiled_plans(os.path.join(d, "src")) == ["docs/superpowers/plans/p1.md"]
        assert sr.unfiled_plans(os.path.join(d, "nope")) is None
    finally:
        shutil.rmtree(d)


def test_main_end_to_end_and_alarms_listing():
    d = tempfile.mkdtemp()
    saved = sr.gather
    try:
        sr.gather = lambda slugs, sessions, repo_dir: facts(
            sessions, panes={s["session"]: "STOP_HOOK_BLOCK_CAP" for s in sessions},
            st=state(open_children=2), issues=[issue(7, labels=["agent-working"])])
        rules_dir = os.path.join(d, "rules")
        argv = ["--counters", os.path.join(rules_dir, "hz.json"), "owner/repo"]
        for _ in range(2):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                sr.main(argv, stdin=io.StringIO("hz-u-i7\towner/repo\t7\timpl\n"))
        assert "FIX wedged hz-u-i7" in buf.getvalue(), buf.getvalue()
        assert "ALARM frontier:owner/repo" not in buf.getvalue(), "frontier needs no live session"
        sr.gather = lambda slugs, sessions, repo_dir: facts(st=state(open_children=2))
        for _ in range(2):
            with contextlib.redirect_stdout(io.StringIO()):
                sr.main(argv, stdin=io.StringIO(""))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            sr.main(["alarms", rules_dir])
        assert buf.getvalue().startswith("hz\tfrontier:owner/repo\tNO FRONTIER"), buf.getvalue()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            sr.main(["alarms", os.path.join(d, "none")])
        assert buf.getvalue() == "no arc alarms firing\n", buf.getvalue()
    finally:
        sr.gather = saved
        shutil.rmtree(d)


def test_sh_and_capture_never_raise():
    assert sr.sh(["/nonexistent/binary-xyz"]) == ""
    saved = os.environ.get("TMUX_TMPDIR")
    os.environ["TMUX_TMPDIR"] = tempfile.mkdtemp()       # a private, empty tmux server: nothing to capture
    try:
        assert sr.capture("no-such-session") == ""
    finally:
        shutil.rmtree(os.environ["TMUX_TMPDIR"], ignore_errors=True)
        if saved is None: os.environ.pop("TMUX_TMPDIR")
        else: os.environ["TMUX_TMPDIR"] = saved


def test_main_reads_the_reconciled_allowlist():
    d = tempfile.mkdtemp()
    saved = sr.gather
    try:
        sr.gather = lambda slugs, sessions, repo_dir: facts(unfiled=["docs/superpowers/plans/a.md"])
        rec = os.path.join(d, "reconciled-plans")
        open(rec, "w").write("docs/superpowers/plans/a.md\n\n")
        argv = ["--counters", os.path.join(d, "hz.json"), "--reconciled", rec, "owner/repo"]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            for _ in range(3): sr.main(argv, stdin=io.StringIO(""))
        assert buf.getvalue() == "", buf.getvalue()
        os.remove(rec)                                   # a missing allowlist is an empty one
        with contextlib.redirect_stdout(buf):
            for _ in range(2): sr.main(argv, stdin=io.StringIO(""))
        assert buf.getvalue().startswith("ALARM unfiled"), buf.getvalue()
    finally:
        sr.gather = saved
        shutil.rmtree(d)


def test_cli_entry_exits_with_mains_code():
    import runpy
    saved = sys.argv
    sys.argv = [spec.origin, "alarms", tempfile.gettempdir() + "/no-such-rules-dir"]
    try:
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            runpy.run_path(spec.origin, run_name="__main__")
        assert False, "no SystemExit"
    except SystemExit as e:
        assert e.code == 0 and buf.getvalue() == "no arc alarms firing\n", (e.code, buf.getvalue())
    finally:
        sys.argv = saved


def test_parse_sessions_skips_malformed_rows():
    assert sr.parse_sessions(["a\ts\t1\timpl\n", "junk\n", "\t\t\t\n"]) == [sess("a", 1, slug="s")]


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

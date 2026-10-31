"""test_fleetview.py — `harness status` outside a project: the host view of every fleet (#184).

Every external probe (tmux, ps, gh) goes through fv.run_cmd, so each test installs a fake that
answers from a table; the filesystem side (registry, run dirs, pid files, logs) is a real tmpdir.
"""
import contextlib, importlib.util, io, json, os, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
# normpath: an unnormalized `test/../scripts/…` filename is what the coverage tracer records, and it
# would credit these lines to a path that is not scripts/fleetview.py.
spec = importlib.util.spec_from_file_location("fleetview", os.path.normpath(os.path.join(HERE, "..", "scripts", "fleetview.py")))
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
_REAL_RUN_CMD = fv.run_cmd
NOW = 1_800_000_000


def dead_pid():
    p = subprocess.Popen(["true"]); p.wait()
    return p.pid


def fake_cmds(table):
    """run_cmd stand-in: the first table key that prefixes argv answers; anything else fails."""
    def run(argv, timeout=20):
        for key, ans in table.items():
            if tuple(argv[:len(key)]) == key:
                return ans(argv) if callable(ans) else ans
        return 1, ""
    return run


def issues_json(*specs):
    return json.dumps([{"number": n, "labels": [{"name": l} for l in labels]} for n, labels in specs])


def make_host():
    """A host root with two registered fleets: alpha (live worker, live session) and beta (gone)."""
    root = tempfile.mkdtemp()
    fleets = os.path.join(root, "fleets"); os.makedirs(fleets)
    alpha = os.path.join(root, "alpha", ".harness"); run = os.path.join(alpha, "run")
    os.makedirs(run)
    with open(os.path.join(alpha, "config"), "w") as fh:
        fh.write(': "${HARNESS_MODE:=prd}"\n: "${HARNESS_POOL:=2}"\nexport X=1\n')
    with open(os.path.join(run, "worker-1.pid"), "w") as fh:
        fh.write(str(os.getpid()))
    with open(os.path.join(run, "worker-1.log"), "w") as fh:
        fh.write("12:00:00 [worker-1] launched session al-web-i7\n")
    recs = {"alpha": {"prefix": "al", "project": alpha, "run_dir": run, "slugs": ["acme/web"]},
            "beta": {"prefix": "be", "project": os.path.join(root, "gone", ".harness"),
                     "run_dir": os.path.join(root, "gone", ".harness", "run"), "slugs": ["acme/api"]}}
    for name, rec in recs.items():
        with open(os.path.join(fleets, name + ".json"), "w") as fh:
            json.dump(rec, fh)
    with open(os.path.join(fleets, "broken.json"), "w") as fh:
        fh.write("{not json")
    return root, fleets, alpha, run


HOST_TABLE = {
    ("tmux", "ls"): (0, f"al-web-i7\t{NOW - 600}\nal-web-i9\t{NOW - 30}\nother-x\t{NOW}\n"),
    ("tmux", "list-panes"): (0, "al-web-i7\t100\nal-web-i9\t200\n"),
    ("ps",): (0, "  100     1 bash -lc launcher\n  101   100 claude --effort high --model opus go\n"
                 "  200     1 claude --model=sonnet\n"),
    ("gh", "api", "rate_limit"): (0, json.dumps({"resources": {
        "core": {"limit": 5000, "remaining": 4000, "reset": NOW + 1200},
        "graphql": {"limit": 5000, "remaining": 12, "reset": NOW + 60}}})),
    ("gh", "issue", "list"): (0, issues_json((7, ["agent-working"]), (8, ["agent-working"]),
                                             (9, ["ready-for-agent"]), (10, ["agent-blocked"]))),
}


def test_two_fleets_rendered_and_missing_project_is_not_a_crash():
    root, fleets, alpha, run = make_host()
    os.environ["HARNESS_FLEETS_DIR"] = fleets
    fv.run_cmd = fake_cmds(HOST_TABLE)
    try:
        out = "\n".join(fv.render(now=NOW))
    finally:
        fv.run_cmd = _REAL_RUN_CMD
    assert "fleets: 2" in out, out                          # broken.json skipped, not fatal
    assert "■ al" in out and "RUNNING" in out, out
    assert "mode: prd" in out and "workers: 1/2" in out, out
    assert "al-web-i7" in out and "#7" in out and "10m" in out and "opus" in out, out
    assert "sonnet" in out, out                              # --model=X form, read off the pane itself
    assert "other-x" not in out, out                         # another prefix's session stays out
    assert "open 4 · unblocked 3 · agent-working 2" in out, out
    assert "agent-working with no live session: #8" in out, out
    assert "launched session al-web-i7" in out, out
    assert "core 4000/5000" in out and "graphql 12/5000" in out, out
    assert "■ be" in out and "missing" in out and "project dir is gone" in out, out


def test_fleet_state_running_paused_dead_stopped():
    root, fleets, alpha, run = make_host()
    rec = {"project": alpha, "run_dir": run}
    assert fv.fleet_state(rec) == ("RUNNING", 1)
    open(os.path.join(run, "PAUSED"), "w").close()
    assert fv.fleet_state(rec)[0] == "PAUSED"
    os.remove(os.path.join(run, "PAUSED"))
    with open(os.path.join(run, "worker-1.pid"), "w") as fh:
        fh.write(str(dead_pid()))
    assert fv.fleet_state(rec) == ("DEAD", 0)               # pid file present, process gone
    os.remove(os.path.join(run, "worker-1.pid"))
    assert fv.fleet_state(rec) == ("STOPPED", 0)
    with open(os.path.join(run, "priority.pid"), "w") as fh:
        fh.write("1")                                        # pid 1: alive but not ours → EPERM
    assert fv.fleet_state(rec)[0] == "RUNNING"
    with open(os.path.join(run, "priority.pid"), "w") as fh:
        fh.write("garbage")
    assert fv.fleet_state(rec)[0] == "DEAD"


def test_complete_when_no_pending_work_and_counts_unavailable_degrades():
    root, fleets, alpha, run = make_host()
    rec = {"prefix": "al", "project": alpha, "run_dir": run, "slugs": ["acme/web"]}
    done = lambda slug, labels: {"open": 1, "unblocked": 1, "working": [], "pending": 0}
    out = "\n".join(fv.render_fleet(rec, {}, {}, NOW, done))
    assert "COMPLETE" in out and "sessions: none live" in out, out
    out = "\n".join(fv.render_fleet(rec, {}, {}, NOW, lambda s, l: None))
    assert "RUNNING" in out and "issue counts unavailable" in out, out
    os.remove(os.path.join(run, "worker-1.log"))
    out = "\n".join(fv.render_fleet(dict(rec, slug="acme/x", slugs=[]), {"al-x": None}, {}, NOW, done))
    assert "log: (none)" in out and "repos: acme/x" in out and "?" in out, out


def test_hold_streak_warns_with_reason():
    root, fleets, alpha, run = make_host()
    net = "issuelib: HOLD — transient gh failure on `dispatch a/b`: error connecting to api.github.com\n"
    rate = "issuelib: HOLD — transient gh failure on `dispatch a/b`: GraphQL: API rate limit already exceeded\n"
    with open(os.path.join(run, "worker-1.log"), "a") as fh:
        fh.write(net * 4)
    rec = {"prefix": "al", "project": alpha, "run_dir": run, "slugs": []}
    out = "\n".join(fv.render_fleet(rec, {}, {}, NOW, lambda s, l: None))
    assert "HOLD streak: transient gh failure ×4 (network)" in out, out
    with open(os.path.join(run, "priority.log"), "w") as fh:
        fh.write("ok line\n" + net + rate * 5)
    out = "\n".join(fv.render_fleet(rec, {}, {}, NOW, lambda s, l: None))
    assert "×6 (rate limit)" in out, out
    assert fv.hold_streak(["a", net]) == (1, "network")
    assert fv.hold_streak([net, "recovered"]) == (0, "network")


def test_session_issue_names():
    assert fv.session_issue("hz-web-i184") == "#184"
    assert fv.session_issue("hz-web-p24") == "PRD #24"
    assert fv.session_issue("hz-bug-acme_web-6-fix") == "bug #6 (fix)"
    assert fv.session_issue("hz-web") == "-"
    assert fv.session_number("hz-web-p24") == 24 and fv.session_number("hz-bug-a-6-fix") == 6
    assert fv.session_number("hz-web") is None


def test_probes_degrade_on_failure():
    fv.run_cmd = fake_cmds({("gh", "issue", "list"): (0, "not json"),
                            ("gh", "api", "rate_limit"): (0, "[]"),
                            ("tmux", "list-panes"): (0, "x\tnotapid\n")})
    try:
        assert fv.issue_counts("a/b", fv.fleet_labels({})) is None
        assert fv.gh_budget(NOW) is None
        assert fv.host_sessions() == {}
        assert fv.session_models() == {}
        fv.run_cmd = fake_cmds({("gh", "api", "rate_limit"): (0, json.dumps({"resources": {"core": {"x": 1}}})),
                                ("tmux", "ls"): (0, "a\t\nb\tnope\n\n")})
        assert fv.gh_budget(NOW) is None
        assert fv.host_sessions() == {"a": None, "b": None}
        assert fv.session_models() == {}                                 # list-panes failed
        assert fv._tail_lines(os.path.join(tempfile.mkdtemp(), "gone.log")) == []
        fv.run_cmd = fake_cmds({("gh", "api", "rate_limit"): (0, json.dumps({"resources": {
            "core": {"remaining": 1, "limit": 2}}}))})
        assert "core 1/2 (reset ?" in fv.gh_budget(NOW)
        assert fv.issue_counts("a/b", fv.fleet_labels({})) is None      # gh failed
    finally:
        fv.run_cmd = _REAL_RUN_CMD


def test_issue_counts_by_label():
    fv.run_cmd = fake_cmds({("gh", "issue", "list"): (0, issues_json(
        (1, ["agent-working"]), (2, ["ready-for-agent", "agent-blocked"]), (3, ["prd"]), (4, []),
        (5, ["doing"])))})
    try:
        c = fv.issue_counts("a/b", fv.fleet_labels({}))
        assert c == {"open": 5, "unblocked": 4, "working": [1], "pending": 3}, c
        c = fv.issue_counts("a/b", fv.fleet_labels({"HARNESS_LABEL_WORKING": "doing"}))
        assert c["working"] == [5] and c["pending"] == 3, c       # a fleet's own label names count
    finally:
        fv.run_cmd = _REAL_RUN_CMD


def test_session_models_walks_the_pane_tree():
    fv.run_cmd = fake_cmds({("tmux", "list-panes"): (0, "s\t10\ns\t10\nt\t30\n"),
                            ("ps",): (0, "10 1 bash\n11 10 node\n12 11 claude --model haiku\n"
                                         "13 10 other\nbad line\n30 1\n")})
    try:
        assert fv.session_models() == {"s": "haiku"}
    finally:
        fv.run_cmd = _REAL_RUN_CMD


def test_fmt_age_and_config_and_registry_dir():
    assert [fv.fmt_age(s) for s in (-5, 5, 600, 7200, 3 * 86400)] == ["0s", "5s", "10m", "2h", "3d"]
    assert fv.read_config("/nonexistent") == {}
    assert fv.load_registry("/nonexistent") == []
    saved = {k: os.environ.pop(k, None) for k in ("HARNESS_FLEETS_DIR", "HARNESS_HOME")}
    try:
        os.environ["HARNESS_HOME"] = "/h"
        assert fv.fleets_dir() == "/h/fleets"
        os.environ["HARNESS_FLEETS_DIR"] = "/f"
        assert fv.fleets_dir() == "/f"
    finally:
        for k, v in saved.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v


def test_run_cmd_real():
    assert _REAL_RUN_CMD(["true"]) == (0, "")
    assert _REAL_RUN_CMD(["/nonexistent/binary"]) == (1, "")


def test_main_once_watch_and_empty_registry():
    os.environ["HARNESS_FLEETS_DIR"] = tempfile.mkdtemp()
    fv.run_cmd = fake_cmds({})
    real_sleep = fv.time.sleep
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            assert fv.main([]) == 0
        assert "no fleets registered" in buf.getvalue() and "GitHub budget: unavailable" in buf.getvalue()

        def stop(_):
            raise KeyboardInterrupt
        fv.time.sleep = stop
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            assert fv.main(["--watch", "2"]) == 0
        assert "live every 2s" in buf.getvalue() and "stopped watching" in buf.getvalue()
    finally:
        fv.time.sleep = real_sleep
        fv.run_cmd = _REAL_RUN_CMD


def test_script_entrypoint_exits_zero():
    # Run as a script (what bin/harness execs): the exit code is main()'s, 0 even with no fleets and
    # no tmux/gh answering — a host view that fails a probe still renders.
    import runpy
    os.environ["HARNESS_FLEETS_DIR"] = tempfile.mkdtemp()
    real_argv, real_path = sys.argv, os.environ.get("PATH", "")
    sys.argv, os.environ["PATH"] = [fv.__file__], tempfile.mkdtemp()      # no tmux, no gh, no ps
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            try:
                runpy.run_path(fv.__file__, run_name="__main__")
                code = None
            except SystemExit as e:
                code = e.code
        assert code == 0, code
        assert "every fleet on this host" in buf.getvalue(), buf.getvalue()
    finally:
        sys.argv, os.environ["PATH"] = real_argv, real_path


def test_watch_reuses_gh_counts_within_ttl():
    root, fleets, alpha, run = make_host()
    os.environ["HARNESS_FLEETS_DIR"] = fleets
    calls = []
    table = dict(HOST_TABLE)
    table[("gh", "issue", "list")] = lambda argv: (calls.append(argv), (0, "[]"))[1]
    fv.run_cmd = fake_cmds(table)
    # The warm-up pool, run serially: the refresh it performs is the TTL logic under test, and the
    # coverage tracer is per-thread, so pool threads would leave that refresh unrecorded.
    real_pool = fv.ThreadPoolExecutor
    class SerialPool:
        def __init__(self, max_workers=None): pass
        def __enter__(self): return self
        def __exit__(self, *exc): return False
        def map(self, fn, items): return map(fn, items)
    fv.ThreadPoolExecutor = SerialPool
    try:
        cache = {}
        fv.render(now=NOW, counts_cache=cache)
        fv.render(now=NOW + 5, counts_cache=cache)
        assert len(calls) == 1, calls
        fv.render(now=NOW + fv.GH_TTL, counts_cache=cache)
        assert len(calls) == 2, calls
    finally:
        fv.run_cmd, fv.ThreadPoolExecutor = _REAL_RUN_CMD, real_pool


def test_headless_lanes_are_listed_with_model_and_state_beside_tmux_sessions():
    """#352: the host view asks every session backend — a headless lane (one bash probe into
    headless.sh's lane rows) is listed beside the tmux sessions, its model read off its runner's flags,
    its state shown on its row."""
    sb = fv.session_backend
    fv.run_cmd = fake_cmds({
        ("tmux", "ls"): (0, "alpha-main-i1\t%d\n" % (NOW - 60)),
        ("tmux", "list-panes"): (0, "alpha-main-i1\t10\n"),
        tuple(sb.list_created_argv("headless")): (0, "alpha-main-i2\t%d\n" % (NOW - 120)),
        tuple(sb.pane_pids_argv("headless")): (0, "alpha-main-i2\t40\n"),
        tuple(sb.states_argv("headless")): (0, "alpha-main-i2\tbusy\nbad-row\t\n"),
        ("ps",): (0, "10 1 claude --model opus\n40 1 python3 claude_headless.py run --flags=--x --model haiku\n")})
    try:
        assert fv.host_sessions() == {"alpha-main-i1": NOW - 60, "alpha-main-i2": NOW - 120}
        assert fv.session_models() == {"alpha-main-i1": "opus", "alpha-main-i2": "haiku"}
        assert fv.session_states() == {"alpha-main-i2": "busy"}
        assert sb.states_argv("tmux") is None, "a pane keeps no state of its own"
        assert sb.list_created_argv("nosuch") is None and sb.pane_pids_argv("nosuch") is None
        root, _, alpha, _ = make_host()
        rec = {"project": alpha, "prefix": "alpha", "run_dir": os.path.join(alpha, "run")}
        rows = "\n".join(fv.render_fleet(rec, fv.host_sessions(), fv.session_models(), NOW,
                                         lambda s, l: None, fv.session_states()))
        assert "alpha-main-i2" in rows and "haiku  [busy]" in rows, rows
        assert "opus  [" not in rows, rows   # the tmux session has no state to show
    finally:
        fv.run_cmd = _REAL_RUN_CMD


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

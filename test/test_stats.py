import contextlib, importlib.util, io, json, os, shutil, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("stats", os.path.normpath(os.path.join(HERE, "..", "scripts", "stats.py")))
st = importlib.util.module_from_spec(spec); spec.loader.exec_module(st)

# Recorded transcript fixture: a main session (a streamed message written twice under one id, a
# <synthetic> line, a torn line) plus one subagent transcript on another model.
FIXTURE_CFG = os.path.join(HERE, "fixtures", "stats", "claude")
FIXTURE_SID = "11111111-2222-3333-4444-555555555555"
WANT_USAGE = {
    "claude-opus-5-5":   {"input": 15, "output": 150, "cache_create": 1000, "cache_read": 30000},
    "claude-sonnet-5-5": {"input": 3,  "output": 10,  "cache_create": 300,  "cache_read": 1000},
}

@contextlib.contextmanager
def host():
    """A throwaway HARNESS_HOME with the fixture as the only Claude config dir."""
    d = tempfile.mkdtemp()
    saved = {k: os.environ.get(k) for k in ("HARNESS_HOME", "HARNESS_CLAUDE_CONFIG_DIRS", "HARNESS_FLEETS_DIR")}
    os.environ["HARNESS_HOME"] = d
    os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = FIXTURE_CFG
    os.environ.pop("HARNESS_FLEETS_DIR", None)
    try:
        yield d
    finally:
        for k, v in saved.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v
        shutil.rmtree(d, ignore_errors=True)

def events(d):
    with open(os.path.join(d, "events.jsonl")) as fh:
        return [json.loads(l) for l in fh]

def run(argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = st.main(argv)
    return rc, buf.getvalue()


def test_session_usage_sums_main_and_subagents_once_per_message():
    tr = st.find_transcript(FIXTURE_SID, [FIXTURE_CFG])
    assert tr and tr.endswith(FIXTURE_SID + ".jsonl"), tr
    usage, first, last = st.session_usage(tr)
    assert usage == WANT_USAGE, usage
    assert last - first == 630, (first, last)   # 00:00:00 → 00:10:30, across both transcripts

def test_launch_then_session_end_writes_usage_totals_including_subagents():
    with host() as d:
        ctx = os.path.join(d, "hz-main-i7.stats")
        wt = os.path.join(d, "wt"); os.makedirs(os.path.join(wt, ".claude"))
        with open(os.path.join(wt, ".claude", "ralph-loop.local.md"), "w") as fh:
            fh.write("---\nactive: true\niteration: 4\n---\n")
        assert st.main(["emit", "launch", "--write-ctx", ctx, "-c", "prefix=hz", "-c", "repo=acme/widget",
                        "-c", "unit=main", f"session={FIXTURE_SID}", "goal=ISSUE:7", "prd=5",
                        f"worktree={wt}", "flags=--dangerously-skip-permissions --effort high --model opus"]) == 0
        saved = json.load(open(ctx))
        assert saved["session"] == FIXTURE_SID and saved["issue"] == 7 and saved["prd"] == 5, saved
        assert saved["model"] == "opus" and saved["effort"] == "high" and saved["kind"] == "impl", saved
        assert st.main(["emit", "session_end", "--ctx", ctx, "-c", "unit=worker-1"]) == 0
        launch, end = events(d)
        assert launch["event"] == "launch" and "usage" not in launch, launch
        assert end["event"] == "session_end" and end["usage"] == WANT_USAGE, end
        # the session's own context beats the sweeping lane's common fields
        assert end["unit"] == "main" and end["issue"] == 7 and end["prd"] == 5 and end["repo"] == "acme/widget", end
        assert end["ralph_iter"] == 4 and isinstance(end["wall_s"], int), end
        assert "launched" not in end and "flags" not in end, end

def test_model_comes_from_worktree_settings_when_flags_name_none():
    d = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(d, ".claude"))
        with open(os.path.join(d, ".claude", "settings.local.json"), "w") as fh:
            json.dump({"model": "sonnet"}, fh)
        assert st.model_effort("--effort=max", d) == ("sonnet", "max")
        assert st.model_effort("--model=opus --effort high", d) == ("opus", "high")
        assert st.model_effort("", None) == (None, None)
    finally:
        shutil.rmtree(d)

def test_goal_fields():
    assert st.goal_fields("ISSUE:23") == {"kind": "impl", "issue": 23}
    assert st.goal_fields("BUG:9:fix") == {"kind": "bug-fix", "issue": 9}
    assert st.goal_fields("BUG:9:triage") == {"kind": "bug-triage", "issue": 9}
    assert st.goal_fields("REVIEW:5") == {"kind": "review", "prd": 5}
    assert st.goal_fields("DECOMPOSE:5") == {"kind": "orch", "prd": 5}
    assert st.goal_fields("PLAN") == {"kind": "orch"}
    assert st.goal_fields("INJECT") == {"kind": "inject"}
    assert st.goal_fields("") == {}

def test_emit_failure_returns_nonzero_and_never_raises():
    with host() as d:
        open(os.path.join(d, "blocker"), "w").close()
        os.environ["HARNESS_HOME"] = os.path.join(d, "blocker")   # a FILE: events.jsonl cannot be created
        assert st.main(["emit", "claim", "unit=main"]) == 1
        assert st.main(["emit"]) == 2
        assert st.append_event({"a": 1}, os.path.join(d, "blocker", "x.jsonl")) is False

def test_events_file_override_and_line_shape():
    with host() as d:
        alt = os.path.join(d, "alt", "ev.jsonl")
        os.environ["HARNESS_EVENTS_FILE"] = alt
        try:
            assert st.main(["emit", "usage_checkpoint", "account=acctA", "-c", "prefix=hz"]) == 0
        finally:
            os.environ.pop("HARNESS_EVENTS_FILE")
        line = open(alt).read()
        assert line.startswith('{"ts": "') and '"event": "usage_checkpoint", "prefix": "hz", "account": "acctA"' in line, line
        assert not os.path.exists(os.path.join(d, "events.jsonl"))

def test_emit_drops_event_when_lock_is_held():
    import fcntl
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        holder = open(p, "a"); fcntl.flock(holder, fcntl.LOCK_EX)
        real = st.LOCK_WAIT_S; st.LOCK_WAIT_S = 0.1
        try:
            assert st.append_event({"event": "x"}, p) is False
        finally:
            st.LOCK_WAIT_S = real; holder.close()
        assert st.append_event({"event": "y"}, p) is True

def _ev(event, **kw):
    kw.setdefault("ts", "2026-10-01T00:00:00Z"); kw.setdefault("prefix", "hz"); kw.setdefault("repo", "acme/widget")
    return dict(kw, event=event)

def _u(out, model="claude-opus-5-5"):
    return {model: {"input": 1, "output": out, "cache_create": 10, "cache_read": 100}}

PRD_EVENTS = [
    _ev("launch", session="s1", issue=11, prd=5, kind="impl", model="sonnet", effort="high", ts="2026-10-01T01:00:00Z"),
    _ev("watchdog_kill", session="s1", issue=11, prd=5, kind="impl"),
    _ev("session_end", session="s1", issue=11, prd=5, kind="impl", wall_s=600, usage=_u(100, "claude-sonnet-5-5")),
    _ev("launch", session="s2", issue=11, prd=5, kind="impl", model="sonnet", ts="2026-10-01T02:00:00Z"),
    _ev("session_end", session="s2", issue=11, prd=5, kind="impl", wall_s=300, usage=_u(40, "claude-sonnet-5-5")),
    _ev("launch", session="s3", issue=12, prd=5, kind="impl", model="opus"),
    _ev("session_end", session="s3", issue=12, prd=5, kind="impl", wall_s=100, usage=_u(7)),
    _ev("launch", session="s4", prd=5, kind="review", model="opus"),
    _ev("session_end", session="s4", prd=5, kind="review", wall_s=50, usage=_u(3)),
    # not PRD #5: another PRD's child, and the same number in another repo
    _ev("launch", session="s5", issue=13, prd=6, kind="impl"),
    _ev("session_end", session="s5", issue=13, prd=6, kind="impl", wall_s=999, usage=_u(999)),
    _ev("session_end", session="s6", issue=11, prd=5, kind="impl", repo="other/repo", wall_s=1, usage=_u(1)),
]

def test_prd_rollup_equals_sum_of_children_sessions():
    evs = st.filter_events(PRD_EVENTS, repo="acme/widget")
    r = st.prd_rollup(evs, 5)
    assert [c["issue"] for c in r["children"]] == [None, 11, 12], r["children"]
    child_sessions = [s for c in r["children"] for s in c["sessions"]]
    assert sorted(s["session"] for s in child_sessions) == ["s1", "s2", "s3", "s4"]
    want = {}
    for s in child_sessions: st.add_usage(want, s["usage"])
    assert r["total"]["tokens"] == want, (r["total"], want)
    assert r["total"]["sessions"] == len(child_sessions) == 4
    assert r["total"]["wall_s"] == sum(s["wall_s"] for s in child_sessions) == 1050
    i11 = next(c for c in r["children"] if c["issue"] == 11)
    assert i11["retries"] == 2 and r["total"]["retries"] == 2, i11   # 1 watchdog kill + 1 re-dispatch
    assert i11["sessions"][0]["model"] == "sonnet" and i11["sessions"][0]["effort"] == "high"
    only = st.prd_rollup(evs, 5, model="sonnet")
    assert set(only["total"]["tokens"]) == {"claude-sonnet-5-5"} and only["total"]["sessions"] == 2

def test_fleet_summary():
    evs = PRD_EVENTS + [
        _ev("merged", issue=11, kind="impl"), _ev("merged", issue=11, kind="impl"),
        _ev("prd_closed", prd=5, kind="orch"),
        _ev("hold", reason="rate_limit", secs=300), _ev("hold", reason="other", secs=60),
        _ev("launch", session="z1", prefix="bw", issue=1, kind="impl"),
    ]
    f = st.fleet_summary(evs)
    hz = f["hz"]
    assert hz["sessions"] == 6 and hz["issues_closed"] == 1 and hz["prds_closed"] == 1, hz
    assert hz["hold_minutes"] == 6.0 and hz["retries"] == 2, hz
    assert hz["tokens"]["claude-opus-5-5"]["output"] == 7 + 3 + 999 + 1, hz
    assert f["bw"]["sessions"] == 1
    assert st.fleet_summary(evs, model="sonnet")["hz"]["sessions"] == 2

def test_filters():
    evs = [_ev("claim", ts="2026-09-01T00:00:00Z"), _ev("claim", ts="2026-10-02T00:00:00Z", prefix="bw")]
    assert len(st.filter_events(evs, since=st.parse_since("2026-10-01"))) == 1
    assert len(st.filter_events(evs, fleet="bw")) == 1
    assert len(st.filter_events(evs, repo="ACME/Widget")) == 2
    assert st.parse_since("2d", now=1000000) == 1000000 - 2 * 86400
    assert st.parse_since("3h", now=100000) == 100000 - 3 * 3600
    try: st.parse_since("soon"); assert False, "bad --since accepted"
    except ValueError: pass

def test_report_cli_text_and_json():
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        for e in PRD_EVENTS + [_ev("hold", secs=120, reason="network")]:
            st.append_event(e, p)
        rc, out = run(["report", "--prd", "5", "-R", "acme/widget"])
        assert rc == 0 and "PRD #5: sessions 4" in out and "#11: sessions 2" in out and "(PRD orchestration)" in out, out
        rc, out = run(["report", "--prd", "5", "-R", "acme/widget", "--json"])
        assert json.loads(out)["total"]["sessions"] == 4
        rc, out = run(["report", "--issue", "11", "-R", "acme/widget"])
        assert rc == 0 and "issue #11: 2 session(s)" in out and "watchdog_kill" in out and "claude-sonnet-5-5" in out, out
        rc, out = run(["report", "--since", "2026-01-01"])
        assert rc == 0 and "fleet hz: sessions 6" in out and "HOLD 2.0m" in out, out
        rc, out = run(["report", "--since", "1d"])
        assert rc == 0 and "no events in range" in out, out
        rc, out = run(["--fleet", "nope", "--since", "2026-01-01", "--json"])
        assert rc == 0 and json.loads(out) == {}
        with contextlib.redirect_stderr(io.StringIO()):
            assert run(["report", "--since", "whenever"])[0] == 2

def test_backfill_attributes_transcripts_and_is_idempotent():
    with host() as d:
        fleets = os.path.join(d, "fleets"); os.makedirs(fleets)
        proj = os.path.join(d, "projstate")
        os.makedirs(proj)
        with open(os.path.join(proj, "targets.tsv"), "w") as fh:
            fh.write("# unit\trepo\nmain\twidget\t-\tthe widget\n")
        json.dump({"prefix": "hz", "project": "/tmp/proj/.harness", "slugs": ["acme/widget", "acme/other"]},
                  open(os.path.join(fleets, "a.json"), "w"))
        os.environ["HARNESS_FLEETS_DIR"] = fleets
        # the fleet's project is /tmp/proj; point its targets.tsv lookup at our temp copy
        real = st._unit_repo
        st._unit_repo = lambda _p, unit, slugs: real(proj, unit, slugs)
        try:
            rc, out = run(["backfill"])
            assert rc == 0 and "backfilled 1 session" in out, out
            (e,) = events(d)
            assert e["event"] == "session_end" and e["backfill"] is True and e["session"] == FIXTURE_SID, e
            assert e["usage"] == WANT_USAGE and e["wall_s"] == 630, e
            assert e["kind"] == "impl" and e["issue"] == 7 and e["unit"] == "main" and e["repo"] == "acme/widget", e
            assert e["prefix"] == "hz" and e["project"] == "/tmp/proj", e
            assert run(["backfill"])[1].startswith("backfilled 0"), "backfill is not idempotent"
        finally:
            st._unit_repo = real

def test_classify_dir():
    fl = [{"prefix": "hz", "project": "/home/u/proj/.harness", "slugs": ["Org/my-repo"]}]
    lead = "-home-u-proj--harness-worktrees-"
    assert st.classify_dir(lead + "orch-Org-my-repo-p24", fl) == \
        {"prefix": "hz", "project": "/home/u/proj", "kind": "orch", "prd": 24, "repo": "Org/my-repo"}
    assert st.classify_dir(lead + "bug-Org-my-repo-i3", fl)["kind"] == "bug-fix"
    assert st.classify_dir(lead + "triage-Org-my-repo-i3", fl)["kind"] == "bug-triage"
    r = st.classify_dir(lead + "core-i9", fl)
    assert r["kind"] == "impl" and r["issue"] == 9 and r["repo"] == "Org/my-repo", r   # the fleet's only slug
    assert st.classify_dir(lead + "weird", fl) == {"prefix": "hz", "project": "/home/u/proj"}
    assert st.classify_dir("-x--harness-worktrees-orch-a-b-p2", []) == {"kind": "orch", "prd": 2}
    assert st.classify_dir("-x--harness-worktrees-u-i4", []) == {"kind": "impl", "unit": "u", "issue": 4}
    assert st.classify_dir("-home-u-elsewhere", fl) is None

def test_parent_prd_cli():
    for body, want in (("x\n## Parent\n#5\n", "5"), ("Part of #8", "8"), ("## Parent\nother/repo#3\n", ""), ("", "")):
        real = sys.stdin; sys.stdin = io.StringIO(body)
        try:
            rc, out = run(["parent-prd", "acme/widget"])
        finally:
            sys.stdin = real
        assert rc == 0 and out.strip() == want, (body, out)

def test_edge_paths_degrade_quietly():
    d = tempfile.mkdtemp()
    try:
        assert st.parse_ts("") is None and st.parse_ts("nope") is None
        os.makedirs(os.path.join(d, ".claude"))
        with open(os.path.join(d, ".claude", "settings.json"), "w") as fh:
            json.dump({"model": "haiku"}, fh)
        assert st.model_effort("", d) == ("haiku", None)   # no settings.local.json → settings.json
        assert st.ralph_iter(os.path.join(d, "missing")) is None
        assert st.find_transcript("no-such-session", [FIXTURE_CFG]) is None
        acc, span = {}, [None, None]
        st._file_usage(os.path.join(d, "missing.jsonl"), acc, span)
        assert acc == {} and span == [None, None]
        assert st.read_ctx(os.path.join(d, "missing")) == {}
        st.write_ctx(os.path.join(d, "no", "such", "dir", "ctx"), {"a": 1})   # swallowed
        ev = os.path.join(d, "ev.jsonl")
        with open(ev, "w") as fh:
            fh.write('{"event":"a"}\ntorn\n[1]\n{"event":"b"}\n')
        assert [e["event"] for e in st.load_events(ev)] == ["a", "b"]
        both = {"claude-opus-5-5": {"input": 1, "output": 2, "cache_create": 3, "cache_read": 4},
                "claude-sonnet-5-5": {"input": 1, "output": 1, "cache_create": 1, "cache_read": 1}}
        assert list(st.add_usage({}, both, "sonnet")) == ["claude-sonnet-5-5"]
        s = st.sessions([_ev("launch", session="n"), _ev("nudge", session="n"), _ev("nudge", session="n")])
        assert s[0]["nudges"] == 2, s
        fl = os.path.join(d, "fleets"); os.makedirs(fl)
        open(os.path.join(fl, "bad.json"), "w").write("{not json")
        json.dump({"prefix": "hz", "project": "/tmp/proj/.harness", "slugs": ["acme/widget"]},
                  open(os.path.join(fl, "ok.json"), "w"))
        os.environ["HARNESS_FLEETS_DIR"] = fl
        try:
            assert [f["prefix"] for f in st._fleets()] == ["hz"]
        finally:
            os.environ.pop("HARNESS_FLEETS_DIR")
        # backfill skips a non-Harness project dir and a transcript with no usage
        cfg = os.path.join(d, "cfg", "projects")
        os.makedirs(os.path.join(cfg, "-home-u-random"))
        open(os.path.join(cfg, "-home-u-random", "x.jsonl"), "w").write("{}\n")
        os.makedirs(os.path.join(cfg, "-x--harness-worktrees-u-i1"))
        open(os.path.join(cfg, "-x--harness-worktrees-u-i1", "y.jsonl"), "w").write('{"type":"user"}\n')
        real = os.environ.get("HARNESS_CLAUDE_CONFIG_DIRS")
        os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = os.path.join(d, "cfg")
        try:
            assert st.backfill(ev) == 0
        finally:
            if real is None: os.environ.pop("HARNESS_CLAUDE_CONFIG_DIRS")
            else: os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = real
    finally:
        shutil.rmtree(d)

def test_emit_swallows_unexpected_errors_and_runs_as_a_script():
    real = st.build_event
    st.build_event = lambda *a, **k: 1 / 0
    try:
        assert st.main(["emit", "claim"]) == 1
    finally:
        st.build_event = real
    import runpy
    saved = sys.argv
    sys.argv = [st.__file__, "emit"]
    try:
        runpy.run_path(st.__file__, run_name="__main__")
        assert False, "no SystemExit"
    except SystemExit as e:
        assert e.code == 2
    finally:
        sys.argv = saved


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

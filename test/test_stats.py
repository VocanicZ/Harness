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
        s = st.sessions([_ev("launch", session="t"), _ev("turn_interrupted", session="t", turn_s=18003)])
        assert s[0]["turn_interrupts"] == 1, s   # #207
        out = st.render_text("issue", st.issue_timeline(
            [_ev("turn_interrupted", issue=9, turn_s=18003, queued_nudges=3)], 9))
        assert "turn_interrupted  turn_s=18003 queued_nudges=3" in out, out
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

# --- #186: rtdd events (VocanicZ/rtdd#503 v1 lines) -----------------------------
def _rt(cmd="which", session=None, ts="2026-10-01T02:00:00Z", ctx=None, **kw):
    c = dict(ctx or {})
    if session:
        c["HARNESS_SESSION"] = session
    return dict({"v": 1, "ts": ts, "cmd": cmd, "argv": [cmd], "exit": 0, "duration_ms": 400, "ctx": c}, **kw)

def _which(session, **kw):
    kw.setdefault("changed_nodes", 6); kw.setdefault("round1", 31); kw.setdefault("round2", 12)
    kw.setdefault("graph", {"source": "scanner", "built_at": "abc", "stale_files": 0, "nodes": 10, "edges": 20})
    return _rt("which", session, **kw)

def _write(path, lines):
    with open(path, "w") as fh:
        for l in lines:
            fh.write(json.dumps(l) + "\n")

def test_rtdd_event_joins_to_its_issue_and_session_in_issue_json():
    with host() as d:
        _write(os.path.join(d, "events.jsonl"), PRD_EVENTS)
        _write(os.path.join(d, "rtdd-events.jsonl"), [
            # the session's own launch record wins over a ctx that names another issue
            _which("s1", ctx={"HARNESS_ISSUE": "99", "HARNESS_REPO": "acme/widget"},
                   graph={"source": "graphify", "stale_files": 3}),
            _rt("init", "s2", duration_ms=1000),
            _which("s3", changed_nodes=100),                        # issue 12: not ours
            # a session the events log no longer has: attributed by its own ctx
            _which("gone", ctx={"HARNESS_ISSUE": "11", "HARNESS_REPO": "acme/widget", "HARNESS_PRD": "5"},
                   round1=0, round2=0),
            _which("s6", changed_nodes=1000),                       # issue 11, but other/repo
        ])
        rc, out = run(["report", "--issue", "11", "-R", "acme/widget", "--json"])
        assert rc == 0, out
        data = json.loads(out)
        r = data["rtdd"]
        assert r["calls"] == {"which": 2, "init": 1} and r["which"] == 2, r
        assert (r["changed_nodes"], r["round1"], r["round2"]) == (12, 31, 12), r
        assert r["stale_graph"] == 1 and r["graph_sources"] == {"graphify": 1, "scanner": 1}, r
        assert (r["selective"], r["full_suite"], r["wall_ms"]) == (1, 1, 1800), r
        by = {s["session"]: s["rtdd"] for s in data["sessions"]}
        assert by["s1"]["which"] == 1 and by["s1"]["changed_nodes"] == 6 and by["s1"]["stale_graph"] == 1, by
        assert by["s2"]["calls"] == {"init": 1} and by["s2"]["which"] == 0, by
        rc, out = run(["report", "--issue", "11", "-R", "acme/widget"])
        assert "rtdd  which 2  changed nodes 12  round1 31  round2 12  stale graph 1  selective 1/2  init 1  1.8s" in out, out
        rc, out = run(["report", "--prd", "5", "-R", "acme/widget", "--json"])
        p = json.loads(out)
        assert p["total"]["rtdd"]["calls"] == {"which": 3, "init": 1}, p["total"]   # #11 (2 + init) + #12 (1)
        i11 = next(c for c in p["children"] if c["issue"] == 11)
        assert i11["rtdd"]["which"] == 2 and next(c for c in p["children"] if c["issue"] == 12)["rtdd"]["which"] == 1, p
        assert next(c for c in p["children"] if c["issue"] is None)["rtdd"] == {}, p
        assert json.loads(run(["report", "--prd", "5", "-R", "acme/widget", "--model", "sonnet", "--json"])[1]) \
            ["total"]["rtdd"]["calls"] == {"which": 1, "init": 1}, "--model keeps only the kept sessions' rtdd calls"
        rc, out = run(["report", "--prd", "5", "-R", "acme/widget"])
        assert "#11: sessions 2" in out and "rtdd which 2" in out and "rtdd -" in out, out

def test_no_rtdd_events_still_render_with_empty_rtdd_columns():
    with host() as d:
        _write(os.path.join(d, "events.jsonl"), PRD_EVENTS)
        data = json.loads(run(["report", "--issue", "11", "-R", "acme/widget", "--json"])[1])
        assert data["rtdd"] == {} and all(s["rtdd"] == {} for s in data["sessions"]) and len(data["sessions"]) == 2, data
        rc, out = run(["report", "--issue", "11", "-R", "acme/widget"])
        assert rc == 0 and "issue #11: 2 session(s)" in out and "rtdd  -" in out, out
        p = json.loads(run(["report", "--prd", "5", "-R", "acme/widget", "--json"])[1])
        assert p["total"]["sessions"] == 4 and p["total"]["rtdd"] == {} and all(c["rtdd"] == {} for c in p["children"])
        f = json.loads(run(["report", "--since", "2026-01-01", "--json"])[1])
        assert f["hz"]["sessions"] == 6 and f["hz"]["rtdd"] == {}, f
        rc, out = run(["report", "--since", "2026-01-01"])
        assert "fleet hz: sessions 6" in out and "rtdd    -" in out, out

def test_fleet_rtdd_selective_share_and_rtdd_missing():
    rtdd = st.join_rtdd([
        _which("s1"), _which("s2"),
        _which("s3", round1=0, round2=0),                  # empty selection → the full-suite bar
        _which("s4", exit=2),                              # rtdd refused / failed
        _which("s5", tier="T2"),                           # rtdd chose the whole suite itself
        _which("s1", backfill=True, round1=None, round2=None),   # a transcript count: unclassified
        _rt("doctor", "s1"),
        _which("z1", ctx={"HARNESS_PREFIX": "bw"}, selection_fidelity="none"),
    ], PRD_EVENTS)
    evs = PRD_EVENTS + [_ev("rtdd_missing"), _ev("rtdd_missing")]
    f = st.fleet_summary(evs, rtdd=rtdd)
    r = f["hz"]["rtdd"]
    assert (r["selective"], r["full_suite"], r["selective_share"], r["missing"]) == (2, 3, 0.4, 2), r
    assert r["which"] == 6 and r["backfilled"] == 1 and r["calls"] == {"which": 6, "doctor": 1}, r
    assert f["bw"]["rtdd"]["full_suite"] == 1 and f["bw"]["rtdd"]["selective_share"] == 0.0 and f["bw"]["sessions"] == 0, f
    text = st.render_text("fleet", f)
    assert "40% selective" in text and "rtdd missing at 2 start(s)" in text and "backfilled 1" in text, text
    only_missing = st.fleet_summary([_ev("rtdd_missing")])
    assert only_missing["hz"]["rtdd"] == {"missing": 1}, only_missing
    assert st.render_text("fleet", only_missing).endswith("rtdd    rtdd missing at 1 start(s)")

def test_goal_env_matches_the_launch_parse():
    assert st.goal_env("ISSUE:7", "5") == ["KIND=impl", "ISSUE=7", "PRD=5"]
    assert st.goal_env("BUG:3:fix") == ["KIND=bug-fix", "ISSUE=3"]
    assert st.goal_env("REVIEW:9", "") == ["KIND=review", "PRD=9"]
    assert st.goal_env("", "") == []
    rc, out = run(["goal-env", "ISSUE:12"])
    assert rc == 0 and out == "KIND=impl\nISSUE=12\n", repr(out)

def test_backfill_rtdd_counts_bash_calls_once_and_is_idempotent():
    with host() as d:
        cfg = os.path.join(d, "cfg")
        pdir = os.path.join(cfg, "projects", "-x--harness-worktrees-main-i8")
        os.makedirs(os.path.join(pdir, "sid-8", "subagents"))
        def bash(i, cmd, name="Bash", ts="2026-09-01T00:00:00Z"):
            return {"type": "assistant", "timestamp": ts, "message": {"id": f"m{i}", "content": [
                {"type": "tool_use", "id": f"t{i}", "name": name, "input": {"command": cmd}}]}}
        _write(os.path.join(pdir, "sid-8.jsonl"), [
            bash(1, "rtdd which --base origin/main"),
            bash(1, "rtdd which --base origin/main"),         # the same block, streamed again
            bash(2, "cd x && rtdd run --base origin/main; rtdd seed"),
            bash(3, "echo rtdd which", name="Read"),          # not a Bash call
            bash(4, "grep -n rtdd README.md"),                # mentions rtdd, runs none of its commands
            {"type": "user", "message": {"content": "rtdd which"}},
        ])
        open(os.path.join(pdir, "sid-8.jsonl"), "a").write("torn\n")
        _write(os.path.join(pdir, "sid-8", "subagents", "agent-a.jsonl"), [bash(9, "rtdd init")])
        _write(os.path.join(pdir, "sid-live.jsonl"), [bash(1, "rtdd which")])   # already has live events
        rp = os.path.join(d, "rtdd-events.jsonl")
        _write(rp, [_which("sid-live")])
        os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = cfg
        assert st.backfill_rtdd() == 4
        lines = [json.loads(l) for l in open(rp)]
        got = [(l["cmd"], l["ctx"]["HARNESS_SESSION"]) for l in lines[1:]]
        assert sorted(got) == sorted([("which", "sid-8"), ("run", "sid-8"), ("seed", "sid-8"), ("init", "sid-8")]), got
        assert all(l["backfill"] is True and l["v"] == 1 for l in lines[1:])
        assert lines[1]["ctx"] == {"HARNESS_KIND": "impl", "HARNESS_ISSUE": "8", "HARNESS_SESSION": "sid-8"}, lines[1]
        assert st.backfill_rtdd() == 0, "rtdd backfill is not idempotent"
        rc, out = run(["backfill"])
        assert rc == 0 and out.strip() == "backfilled 0 session(s), 0 rtdd call(s)", out
        r = st.rtdd_summary(st.join_rtdd(st.load_events(rp), []))
        assert r["calls"] == {"which": 2, "run": 1, "seed": 1, "init": 1} and r["backfilled"] == 4, r
        assert r["selective"] == 1 and r["full_suite"] == 0, "a backfilled which is never classified"
        assert st.rtdd_calls(os.path.join(pdir, "missing.jsonl")) == []


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

import contextlib, importlib.util, io, json, os, shutil, subprocess, sys, tempfile
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
    # Pin the fleet registry under the throwaway home BEFORE moving HARNESS_HOME: an inherited one (every
    # fleet process exports it) would beat the HARNESS_HOME below and point stats at the real host (#541).
    os.environ["HARNESS_FLEETS_DIR"] = os.path.join(d, "fleets")
    os.environ["HARNESS_HOME"] = d
    os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = FIXTURE_CFG
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
                        f"worktree={wt}", "model=opus", "effort=high"]) == 0
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

def test_launch_model_and_effort_are_the_callers_never_parsed_from_flags():
    # #307: the CLI adapter reads them (cli_model_effort; test_cli_seam.sh, the matrix's
    # stats-launch-model-effort row). A claude-spelled flag line is not parsed here any more.
    with host() as d:
        assert st.main(["emit", "launch", "session=s1", "flags=--model opus --effort high"]) == 0
        assert st.main(["emit", "launch", "session=s2", "model=gpt-5.6-luna", "effort=low"]) == 0
        a, b = events(d)
        assert "model" not in a and "effort" not in a, a
        assert b["model"] == "gpt-5.6-luna" and b["effort"] == "low", b

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

def test_launch_failed_lane_is_not_a_session():
    # #596: a lane that was gone within seconds of its launch never ran; harness stats must not count it
    evs = [
        _ev("launch", session="ok1", prefix="hz", issue=1, kind="impl"),
        _ev("launch", session="dead1", prefix="hz", issue=2, kind="impl"),
        _ev("launch_failed", session="dead1", prefix="hz", issue=2, kind="impl", reason="session_gone"),
        _ev("session_end", session="dead1", prefix="hz", issue=2, kind="impl", wall_s=1),
        _ev("launch_failed", session="dead2", prefix="hz", issue=3, kind="impl", reason="start_failed"),
    ]
    assert [x["session"] for x in st.sessions(evs)] == ["ok1"]
    assert st.fleet_summary(evs)["hz"]["sessions"] == 1

def test_launch_failed_lane_that_reported_usage_is_still_a_session():
    # #720: a lane gone within 30s of its launch logs launch_failed before its session_end; when that
    # session_end reports usage the lane ran, and its spend stays in the stats
    real = _u(1_000_000)
    evs = [
        _ev("launch", session="short1", prefix="hz", issue=4, kind="impl"),
        _ev("launch_failed", session="short1", prefix="hz", issue=4, kind="impl", reason="session_gone"),
        _ev("session_end", session="short1", prefix="hz", issue=4, kind="impl", wall_s=9, usage=real),
        _ev("launch", session="dead3", prefix="hz", issue=5, kind="impl"),
        _ev("launch_failed", session="dead3", prefix="hz", issue=5, kind="impl", reason="session_gone"),
        _ev("session_end", session="dead3", prefix="hz", issue=5, kind="impl", wall_s=1, usage={}),
    ]
    out = st.sessions(evs)
    assert [x["session"] for x in out] == ["short1"], out
    assert out[0]["usage"]["claude-opus-5-5"]["output"] == 1_000_000, out
    assert st.fleet_summary(evs)["hz"]["sessions"] == 1
    assert st.fleet_summary(evs)["hz"]["tokens"]["claude-opus-5-5"]["output"] == 1_000_000

def test_launch_failed_after_the_sweeps_empty_session_end_is_still_not_a_session():
    # #743: another worker's sweep logs the empty session_end before the owner's launch_gone_check logs launch_failed
    real = _u(5)
    dead = [
        _ev("launch", session="u1", prefix="hz", issue=3, kind="impl"),
        _ev("session_end", session="u1", prefix="hz", issue=3, kind="impl", wall_s=1, usage={}),
        _ev("launch_failed", session="u1", prefix="hz", issue=3, kind="impl", reason="session_gone"),
    ]
    assert st.sessions(dead) == [] and st.fleet_summary(dead)["hz"]["sessions"] == 0
    # ...whichever order the two are logged in
    assert st.sessions([dead[0], dead[2], dead[1]]) == []
    # a real earlier run under the same id (#679) stays, with the failed relaunch dropped whichever order its events came in
    first = [_ev("launch", session="u2", prefix="hz", issue=4, kind="impl"),
             _ev("session_end", session="u2", prefix="hz", issue=4, kind="impl", wall_s=600, usage=real)]
    again = [_ev("launch", session="u2", prefix="hz", issue=4, kind="impl"),
             _ev("session_end", session="u2", prefix="hz", issue=4, kind="impl", wall_s=1, usage={}),
             _ev("launch_failed", session="u2", prefix="hz", issue=4, kind="impl", reason="session_gone")]
    out = st.sessions(first + again)
    assert len(out) == 1 and out[0]["wall_s"] == 600 and out[0]["usage"]["claude-opus-5-5"]["output"] == 5, out
    # a failed segment whose session_end reports usage (#720) is a session: here the launch_failed is a start_failed of
    # a later attempt, which is its own segment and drops alone
    ran = [first[0], first[1], _ev("launch_failed", session="u2", prefix="hz", issue=4, kind="impl", reason="start_failed")]
    assert len(st.sessions(ran)) == 1 and st.sessions(ran)[0]["usage"]["claude-opus-5-5"]["output"] == 5
    # a start_failed after an earlier real run with an empty session_end does not take that run with it
    quiet = [first[0], _ev("session_end", session="u2", prefix="hz", issue=4, kind="impl", wall_s=600, usage={}),
             _ev("launch_failed", session="u2", prefix="hz", issue=4, kind="impl", reason="start_failed")]
    assert [x["session"] for x in st.sessions(quiet)] == ["u2"]

def test_ran_command_reads_logged_usage():
    # #720: `stats.py ran <session>` is rc 0 only for a session whose logged session_end holds tokens
    # (no pytest fixtures: the file's own __main__ runner calls every test with no arguments, #744)
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        with open(p, "w") as fh:
            fh.write("\n".join(json.dumps(e) for e in [
                _ev("session_end", session="a", usage=_u(5)), _ev("session_end", session="b", usage={})]) + "\n")
        saved = os.environ.get("HARNESS_EVENTS_FILE")
        os.environ["HARNESS_EVENTS_FILE"] = p
        try:
            assert st.main(["ran", "a"]) == 0 and st.main(["ran", "b"]) == 1 and st.main(["ran", "zz"]) == 1
        finally:
            if saved is None: os.environ.pop("HARNESS_EVENTS_FILE", None)
            else: os.environ["HARNESS_EVENTS_FILE"] = saved

def test_ran_command_reads_events_like_load_events():
    # #752: `stats.py ran` shares load_events' line parser: a BOM or a raw form feed in a field still reads as ran
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        ff = json.dumps(_ev("session_end", session="ff", usage=_u(5), note="x@@y")).replace("@@", "\x0c")
        assert "\x0c" in ff
        bom = json.dumps(_ev("session_end", session="bom", usage=_u(5)))
        with open(p, "wb") as fh:
            fh.write(b"\xef\xbb\xbf" + bom.encode() + b"\r\n" + ff.encode() + b"\n")
        assert st.parse_event_line("\ufeff" + bom)["session"] == "bom" and st.parse_event_line(ff)["session"] == "ff"
        assert st.parse_event_line("{torn") is None and st.parse_event_line("[1]") is None and st.parse_event_line("\n") is None
        assert [e["session"] for e in st.load_events(p)] == ["bom", "ff"]
        saved = os.environ.get("HARNESS_EVENTS_FILE")
        os.environ["HARNESS_EVENTS_FILE"] = p
        try:
            assert st.main(["ran", "bom"]) == 0 and st.main(["ran", "ff"]) == 0 and st.main(["ran", "zz"]) == 1
        finally:
            if saved is None: os.environ.pop("HARNESS_EVENTS_FILE", None)
            else: os.environ["HARNESS_EVENTS_FILE"] = saved

MALFORMED_USAGES = [{"m": "x"}, [1, 2], "str", 7, None, {"m": None}, {"m": [1]}, {"m": {"output": "x"}},
                    {"m": {"output": [1], "input": {"a": 1}, "cache_read": True}}, {"m": {"output": -3}}]

def test_malformed_usage_gives_no_traceback_in_report_and_ran():
    # #753: a non-dict usage, a non-numeric token count, a list or a string usage is skipped: report and ran
    # exit cleanly, and the good session beside it still counts
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        evs = [_ev("session_end", session="good", usage=_u(5), kind="impl")]
        for i, bad in enumerate(MALFORMED_USAGES):
            evs += [_ev("session_end", session=f"bad{i}", usage=bad, kind="impl", resumed=bool(i % 2)),
                    _ev("session_end", session=f"bad{i}", usage=bad, kind="impl", resumed=True)]
        with open(p, "w") as fh:
            fh.write("\n".join(json.dumps(e) for e in evs) + "\n")
        for argv in (["report"], ["report", "--json"]):
            r = subprocess.run([sys.executable, os.path.join(HERE, "..", "scripts", "stats.py"), *argv,
                                "--events", p, "--since", "2026-09-01"], capture_output=True, text=True,
                               env=dict(os.environ, HARNESS_HOME=d))
            assert r.returncode == 0 and "Traceback" not in r.stderr, (argv, r.returncode, r.stderr)
        assert st.clean_usage(MALFORMED_USAGES[0]) == {} and st.clean_usage(_u(5)) == _u(5)
        saved = os.environ.get("HARNESS_EVENTS_FILE")
        os.environ["HARNESS_EVENTS_FILE"] = p
        try:
            assert st.main(["ran", "good"]) == 0
            for i in range(len(MALFORMED_USAGES)):
                assert st.main(["ran", f"bad{i}"]) == 1, i
        finally:
            if saved is None: os.environ.pop("HARNESS_EVENTS_FILE", None)
            else: os.environ["HARNESS_EVENTS_FILE"] = saved

def test_failed_relaunch_under_same_session_keeps_the_earlier_run():
    # #679: a relaunch under a session id that already ran, dead within 30s, drops only itself
    real = _u(5)
    evs = [
        _ev("launch", session="s1", prefix="hz", issue=7, kind="impl"),
        _ev("session_end", session="s1", prefix="hz", issue=7, kind="impl", wall_s=600, usage=real),
        _ev("launch", session="s1", prefix="hz", issue=7, kind="impl"),
        _ev("launch_failed", session="s1", prefix="hz", issue=7, kind="impl", reason="session_gone"),
        _ev("session_end", session="s1", prefix="hz", issue=7, kind="impl", wall_s=1),
    ]
    out = st.sessions(evs)
    assert [x["session"] for x in out] == ["s1"], out
    assert out[0]["wall_s"] == 600 and out[0]["usage"]["claude-opus-5-5"]["output"] == 5, out
    # a start_failed relaunch emits no launch event of its own: still only itself is dropped
    evs2 = evs[:2] + [_ev("launch_failed", session="s1", prefix="hz", issue=7, kind="impl", reason="start_failed")]
    out2 = st.sessions(evs2)
    assert len(out2) == 1 and out2[0]["usage"]["claude-opus-5-5"]["output"] == 5, out2
    assert st.fleet_summary(evs)["hz"]["sessions"] == 1

def test_fleet_summary_reads_old_unit_and_new_repo_worker_events():
    """#472: old claim/release events carry `unit`, new lane_* events carry `repo` + `worker`. The old
    totals do not move; the lanes block attributes a new claim by its repo and an old one by its repo
    when it has one, else by its unit."""
    old = [_ev("claim", unit="u1", worker="W1", repo=None), _ev("release", unit="u1", repo=None),
           _ev("claim", unit="main", worker="W2"),
           _ev("launch", session="o1", issue=11, prd=5, kind="impl"),
           _ev("merged", issue=11, kind="impl"), _ev("hold", reason="other", secs=120)]
    for e in old:
        if e.get("repo") is None: e.pop("repo")
    new = [_ev("lane_claim", repo="acme/other", worker="1", kind="impl", action="IMPL", payload="3"),
           _ev("lane_claim", repo="acme/other", worker="2", kind="impl", action="IMPL", payload="4"),
           _ev("lane_adopt", repo="acme/other", worker="1", lane="impl-3"),
           _ev("lane_release", repo="acme/other", worker="1", lane="impl-3")]
    before = st.fleet_summary(old)["hz"]
    both = st.fleet_summary(old + new)["hz"]
    for k in ("sessions", "tokens", "issues_closed", "prds_closed", "retries", "hold_minutes"):
        assert both[k] == before[k], (k, both[k], before[k])
    lanes = both["lanes"]
    assert lanes["acme/other"] == {"claims": 2, "workers": ["1", "2"]}, lanes
    assert lanes["u1"] == {"claims": 1, "workers": ["W1"]}, lanes          # old, no repo: by unit
    assert lanes["acme/widget"] == {"claims": 1, "workers": ["W2"]}, lanes  # old, has a repo: by repo
    assert "lanes" in before and "acme/other" not in before["lanes"], before["lanes"]
    assert "acme/other" in st.render_text("fleet", st.fleet_summary(old + new))


def test_filters():
    evs = [_ev("claim", ts="2026-09-01T00:00:00Z"), _ev("claim", ts="2026-10-02T00:00:00Z", prefix="bw")]
    assert len(st.filter_events(evs, since=st.parse_since("2026-10-01"))) == 1
    assert len(st.filter_events(evs, fleet="bw")) == 1
    assert len(st.filter_events(evs, repo="ACME/Widget")) == 2
    assert st.parse_since("2d", now=1000000) == 1000000 - 2 * 86400
    assert st.parse_since("3h", now=100000) == 100000 - 3 * 3600
    try: st.parse_since("soon"); assert False, "bad --since accepted"
    except ValueError: pass

def test_events_log_leading_bom_is_read_and_unparseable_lines_are_counted():
    """#672: a BOM-led first line lost its event with no word; now it is read, and a line that still fails is counted."""
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        lines = [_ev("launch", session="s1"), _ev("session_end", session="s1", usage=_u(1000)),
                 _ev("launch", session="s2"), _ev("session_end", session="s2", usage=_u(1000))]
        raw = "\r\n".join(json.dumps(e) for e in lines[:2]) + "\r\n" + "{torn\n[1]\n" + "\n".join(json.dumps(e) for e in lines[2:]) + "\n"
        with open(p, "wb") as fh:
            fh.write(b"\xef\xbb\xbf" + raw.encode())
        bad = [0]
        evs = st.load_events(p, bad)
        assert [e["event"] for e in evs] == ["launch", "session_end", "launch", "session_end"], evs
        assert bad == [2], bad       # "{torn" and the non-object "[1]"; the blank-free BOM line is NOT skipped
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc, out = run(["report", "--since", "2026-01-01", "--json"])
        assert rc == 0 and json.loads(out)["hz"]["tokens"]["claude-opus-5-5"]["output"] == 2000, out
        assert "skipped 2 event line(s)" in err.getvalue(), err.getvalue()
        with open(p, "w") as fh:
            fh.write("".join(json.dumps(e) + "\n" for e in lines))
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            run(["report", "--since", "2026-01-01"])
        assert err.getvalue() == "", err.getvalue()

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

def test_report_issue_below_one_is_a_usage_error():
    """#675: no issue is numbered 0 or below -> exit 2 with a message, not a report headed "issue #-5"."""
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        st.append_event(_ev("claim", issue=11), p)
        for bad in ("-5", "0", "-1"):
            for argv in (["report", "--issue", bad], ["report", f"--issue={bad}"]):
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    rc, out = run(argv)
                assert rc == 2 and out == "" and "--issue" in err.getvalue(), (argv, rc, out, err.getvalue())
        rc, out = run(["report", "--issue", "1", "-R", "acme/widget"])
        assert rc == 0 and "issue #1:" in out, out


def test_report_repo_must_be_owner_name_with_no_leading_dash():
    """#716: --repo=-x (and owner/-x, -x/name) -> exit 2, like forecast.py; not "no events in range", exit 0."""
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        st.append_event(_ev("claim", issue=11), p)
        for bad in ("-x", "owner/-x", "-x/name", "x", "", "a/", "/b", "a b/c", "a/b/c"):
            for argv in (["report", f"--repo={bad}"], ["report", "-R", bad], ["report", f"-R={bad}"]):
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    try:
                        rc, out = run(argv)
                    except SystemExit as e:   # argparse: a usage error ends the command with exit 2
                        rc, out = e.code, ""
                # `-R -x` (two words): argparse reads -x as a flag, so its own "expected one argument" fires
                assert rc == 2 and out == "" and ("expected owner/name" in err.getvalue() or argv[1:2] == ["-R"]), (argv, rc, out, err.getvalue())
        r = subprocess.run([sys.executable, os.path.join(HERE, "..", "scripts", "stats.py"), "report", "--repo=-x",
                            "--events", p], capture_output=True, text=True)
        assert r.returncode == 2 and r.stdout == "" and "expected owner/name" in r.stderr, (r.returncode, r.stdout, r.stderr)
        for ok in ("acme/widget", "a/b", "my-org/my.repo_1", "acme/.github", "a_b/c-d"):
            rc, out = run(["report", f"--repo={ok}"])
            assert rc == 0, (ok, rc, out)


def test_report_prd_below_one_is_a_usage_error():
    """#711: --prd 0 or below -> exit 2 with a message (like --issue), not "PRD #-5" or a silent 7d default."""
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        st.append_event(_ev("claim", issue=11), p)
        for bad in ("-5", "0", "-1"):
            for argv in (["report", "--prd", bad], ["report", f"--prd={bad}"], ["report", "--by-role", "--prd", bad]):
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    rc, out = run(argv)
                assert rc == 2 and out == "" and f"--prd must be 1 or greater, got {bad}" in err.getvalue(), (argv, rc, out, err.getvalue())
        rc, out = run(["report", "--prd", "1", "-R", "acme/widget"])
        assert rc == 0 and "PRD #1:" in out, out

def test_backfill_attributes_transcripts_and_is_idempotent():
    with host() as d:
        fleets = os.path.join(d, "fleets"); os.makedirs(fleets)
        proj = os.path.join(d, "projstate")
        os.makedirs(proj)
        with open(os.path.join(proj, "config"), "w") as fh:
            fh.write(': "${HARNESS_OWNER:=acme}"\n: "${HARNESS_REPO:=widget}"\n: "${HARNESS_UNIT:=main}"\n')
        json.dump({"prefix": "hz", "project": "/tmp/proj/.harness", "slugs": ["acme/widget", "acme/other"]},
                  open(os.path.join(fleets, "a.json"), "w"))
        os.environ["HARNESS_FLEETS_DIR"] = fleets
        # the fleet's project is /tmp/proj; point its config lookup at our temp copy
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

def test_events_log_raw_control_char_in_a_field_is_counted():
    """#673: a raw form feed / tab / VT inside a field value made strict json.loads drop the line with no word."""
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        with open(p, "wb") as fh:
            for ch in ("\x0c", "\t", "\x0b"):
                line = json.dumps(_ev("note", session="s" + str(ord(ch)), msg="a#b")).replace("a#b", "a" + ch + "b")
                assert ch in line
                fh.write(line.encode() + b"\n")
        bad = [0]
        evs = st.load_events(p, bad)
        assert [e["msg"] for e in evs] == ["a\x0cb", "a\tb", "a\x0bb"], evs
        assert bad == [0], bad

def test_edge_paths_degrade_quietly():
    d = tempfile.mkdtemp()
    try:
        assert st.parse_ts("") is None and st.parse_ts("nope") is None
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


def test_headless_lane_events_fold_result_model_usage_when_no_transcript():
    """#352: a headless lane's claude may keep no transcript; its events.jsonl is found by the session id
    its state.json names, and folded from each turn's stream-json `result` usage (the turn's own: #426,
    tool-use.jsonl's modelUsage is the session's running total — its model_usage_since_last_result is
    the turn's), the assistant events' partial usage ignored."""
    fix = os.path.join(HERE, "fixtures", "cli", "claude", "stream-json")
    with host() as d:
        os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = os.path.join(d, "none")
        lane = os.path.join(d, "lanes", "hz-main-i9"); os.makedirs(lane)
        sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        with open(os.path.join(lane, "state.json"), "w") as fh:
            json.dump({"session_id": sid, "state": "ended"}, fh)
        with open(os.path.join(lane, "events.jsonl"), "w") as out:
            for f in ("tool-use.jsonl", "normal.jsonl"):
                out.write(open(os.path.join(fix, f)).read())
        assert st.lane_events(sid) == os.path.join(lane, "events.jsonl")
        assert st.lane_events("no-such-session") is None
        assert st.find_transcript(sid) is None, "a lane's events are no transcript (forecast reads its path)"
        usage, _, _ = st.session_usage(st.lane_events(sid))
        assert usage == {"claude-haiku-5-5": {"input": 6, "output": 177, "cache_create": 43982, "cache_read": 63243}}, usage
        rec = st.build_event("session_end", {}, {"session": sid, "launched": 1}, {}, now=100)
        assert rec["usage"] == usage, rec
        # A turn cut off before its result (an interrupt, a kill) still counts what its messages carried;
        # a streamed message repeats its usage per block and is counted once.
        msg = {"type": "assistant", "message": {"id": "m1", "model": "claude-opus-5-5",
               "usage": {"input_tokens": 3, "output_tokens": 40, "cache_read_input_tokens": 7}}}
        with open(os.path.join(lane, "events.jsonl"), "a") as out:
            for ev in ({"type": "harness", "subtype": "turn_start", "turn": 3}, msg, msg,
                       {"type": "harness", "subtype": "turn_end", "turn": 3, "state": "idle"}):
                out.write(json.dumps(ev) + "\n")
        usage, _, _ = st.session_usage(st.lane_events(sid))
        assert usage["claude-opus-5-5"] == {"input": 3, "output": 40, "cache_create": 0, "cache_read": 7}, usage
        assert usage["claude-haiku-5-5"]["output"] == 177, usage   # the turns with a result: their totals only
        # #485: a lane of another CLI whose id is its session (openclaw) is no claude lane: its events hold no
        # stream-json result, and reading them as claude's would report empty usage over the adapter's own.
        with open(os.path.join(lane, "state.json"), "w") as fh:
            json.dump({"session_id": sid, "state": "ended", "adapter": "openclaw"}, fh)
        assert st.lane_events(sid) is None
        rec = st.build_event("session_end", {}, {"session": sid, "launched": 1},
                             {"usage_tsv": "claude-cli/claude-haiku-5-5\t4\t10\t41826\t41933\n"}, now=100)
        assert rec["usage"] == {"claude-cli/claude-haiku-5-5": {"input": 4, "output": 10, "cache_create": 41933,
                                                                  "cache_read": 41826}}, rec
        with open(os.path.join(lane, "state.json"), "w") as fh:
            json.dump({"session_id": sid, "state": "ended", "adapter": "claude"}, fh)
        assert st.lane_events(sid) == os.path.join(lane, "events.jsonl")
        os.environ["HARNESS_HEADLESS_DIR"] = os.path.join(d, "elsewhere")
        try:
            assert st.lane_events(sid) is None   # the lanes root is HARNESS_HEADLESS_DIR when set
        finally:
            os.environ.pop("HARNESS_HEADLESS_DIR")


# --- #426: no double count across --resume'd turns and resumed runs ----------------------------------
STREAM_FIX = os.path.join(HERE, "fixtures", "cli", "claude", "stream-json")
# normal.jsonl then tool-use.jsonl: two real turns of ONE claude session, the second `--resume`d. Its
# result's modelUsage is the session's running total (2+4 input, 5+172 output, 22305+21677 cache
# writes, 11382+51861 cache reads), so the two turns' real total is tool-use's modelUsage.
RESUMED_TOTAL = {"claude-haiku-5-5": {"input": 6, "output": 177, "cache_create": 43982, "cache_read": 63243}}

def _stream(path, strip_since=False):
    """normal.jsonl and tool-use.jsonl as one headless lane's events.jsonl, each turn behind the runner's
    turn_start marker; strip_since drops model_usage_since_last_result (a claude that prints none)."""
    with open(path, "w") as out:
        for n, f in enumerate(("normal.jsonl", "tool-use.jsonl"), 1):
            out.write(json.dumps({"type": "harness", "subtype": "turn_start", "turn": n}) + "\n")
            for l in open(os.path.join(STREAM_FIX, f)):
                r = json.loads(l)
                if strip_since:
                    r.pop("model_usage_since_last_result", None)
                out.write(json.dumps(r) + "\n")

def test_file_usage_over_resumed_turns_with_cumulative_model_usage_is_the_real_total():
    d = tempfile.mkdtemp()
    try:
        last = [json.loads(l) for l in open(os.path.join(STREAM_FIX, "tool-use.jsonl"))
                if json.loads(l).get("type") == "result"][-1]
        mu = last["modelUsage"]["claude-haiku-5-5"]
        assert (mu["inputTokens"], mu["outputTokens"]) == (6, 177), "the fixture's modelUsage is cumulative"
        for strip in (False, True):
            ev = os.path.join(d, f"events-{strip}.jsonl"); _stream(ev, strip)
            acc, span = {}, [None, None]
            st._file_usage(ev, acc, span)
            assert acc == RESUMED_TOTAL, (strip, acc)
        # A stream whose modelUsage is per turn (it falls below the previous result's) is summed as is.
        ev = os.path.join(d, "per-turn.jsonl")
        with open(ev, "w") as out:
            for o in (5, 3):
                out.write(json.dumps({"type": "result", "modelUsage": {"m": {"inputTokens": 1, "outputTokens": o}}}) + "\n")
        acc = {}; st._file_usage(ev, acc, [None, None])
        assert acc == {"m": {"input": 2, "output": 8, "cache_create": 0, "cache_read": 0}}, acc
    finally:
        shutil.rmtree(d, ignore_errors=True)

def _assistant(mid, out, ts):
    return {"type": "assistant", "timestamp": ts, "message": {"id": mid, "model": "claude-opus-5-5",
            "usage": {"input_tokens": 1, "output_tokens": out, "cache_read_input_tokens": 10 * out}}}

def test_checkpointed_and_resumed_lane_session_ends_sum_to_the_transcript_total():
    """A headless lane checkpointed, then relaunched on the same claude session: `claude -p --resume`
    appends to the same transcript, so the resumed run's session_end reports only what it added, and
    the two session_ends (and `harness stats`) sum to the transcript's total, never more."""
    sid = "99999999-8888-7777-6666-555555555555"
    with host() as d:
        cfg = os.path.join(d, "claude"); proj = os.path.join(cfg, "projects", "-wt"); os.makedirs(proj)
        os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = cfg
        tr = os.path.join(proj, f"{sid}.jsonl")
        ctx = os.path.join(d, "hz-main-i9.stats")
        launch = ["emit", "launch", "--write-ctx", ctx, "-c", "prefix=hz", "-c", "repo=acme/widget",
                  f"session={sid}", "goal=ISSUE:9", "model=opus"]
        def run_turns(*msgs):
            with open(tr, "a") as fh:
                for m in msgs:
                    fh.write(json.dumps(m) + "\n")
        assert st.main(launch) == 0                                   # the first run
        run_turns(_assistant("a1", 100, "2026-10-01T00:00:00Z"), _assistant("a2", 50, "2026-10-01T00:01:00Z"))
        assert st.main(["emit", "session_end", "--ctx", ctx]) == 0    # checkpointed: the lane ends
        assert st.main(launch) == 0                                   # relaunched, resuming the session
        run_turns(_assistant("b1", 30, "2026-10-01T01:00:00Z"))
        assert st.main(["emit", "session_end", "--ctx", ctx]) == 0
        ends = [e for e in events(d) if e["event"] == "session_end"]
        assert len(ends) == 2, ends
        assert ends[0]["usage"] == {"claude-opus-5-5": {"input": 2, "output": 150, "cache_create": 0, "cache_read": 1500}}, ends[0]
        assert "resumed" not in ends[0], ends[0]
        assert ends[1]["usage"] == {"claude-opus-5-5": {"input": 1, "output": 30, "cache_create": 0, "cache_read": 300}}, ends[1]
        assert ends[1]["resumed"] is True, ends[1]
        whole, _, _ = st.session_usage(tr)
        assert st.add_usage(st.add_usage({}, ends[0]["usage"]), ends[1]["usage"]) == whole, whole
        (s,) = st.sessions(st.load_events())
        assert s["usage"] == whole, s
        rc, out = run(["report", "--issue", "9", "--json"])
        assert rc == 0 and json.loads(out)["sessions"][0]["usage"]["claude-opus-5-5"]["output"] == 180, out
        # A third run that added nothing reports nothing new.
        assert st.main(launch) == 0 and st.main(["emit", "session_end", "--ctx", ctx]) == 0
        assert events(d)[-1]["usage"] == {} and events(d)[-1]["resumed"] is True, events(d)[-1]
        assert st.sessions(st.load_events())[0]["usage"] == whole

def test_session_end_without_resumed_replaces_and_a_tmux_lane_is_unchanged():
    """A session_end logged before #426 (no `resumed`) held the transcript's whole total: it replaces
    what came before, and a later resumed run subtracts it. One session_end per session (every tmux
    lane: it never resumes a session id) reads as before."""
    u = lambda o: {"m": {"input": 0, "output": o, "cache_create": 0, "cache_read": 0}}
    legacy = [_ev("session_end", session="s1", usage=u(10)), _ev("session_end", session="s1", usage=u(25))]
    (s,) = st.sessions(legacy)
    assert s["usage"] == u(25), s
    (s,) = st.sessions(legacy + [_ev("session_end", session="s1", usage=u(5), resumed=True, wall_s=7)])
    assert s["usage"] == u(30), s
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        for e in legacy:
            st.append_event(e, p)
        assert st.logged_session_usage("s1", p) == u(25)
        assert st.logged_session_usage("s2", p) is None
        assert st.usage_minus(u(40), u(25)) == u(15) and st.usage_minus(u(20), u(25)) == {}
    with host() as d:   # a fresh session (tmux, or a headless lane's first run): its whole transcript
        _launch_end(d, model="opus")
        end = [e for e in events(d) if e["event"] == "session_end"][0]
        assert end["usage"] == WANT_USAGE and "resumed" not in end, end


# --- #376: verify what ran -----------------------------------------------------------------------
def _launch_end(d, model=None, issue=7):
    """launch (model=<model>, or none) → session_end on the recorded fixture: claude-opus-5-5 dominant
    by output (150), plus a small sub-agent side call on claude-sonnet-5-5 (10)."""
    ctx = os.path.join(d, f"hz-main-i{issue}.stats")
    argv = ["emit", "launch", "--write-ctx", ctx, "-c", "prefix=hz", "-c", "repo=acme/widget",
            f"session={FIXTURE_SID}", f"goal=ISSUE:{issue}", "prd=5"] + ([f"model={model}"] if model else [])
    assert st.main(argv) == 0
    assert st.main(["emit", "session_end", "--ctx", ctx]) == 0
    return events(d)

def test_model_family_alias_vs_full_id():
    for a, b in (("sonnet", "claude-sonnet-5-5"), ("opus", "claude-opus-5-5"), ("opus[1m]", "claude-opus-5-5"),
                 ("claude-opus-5-5", "anthropic/claude-opus-5-5-20261001"), ("haiku", "claude-haiku-5-5"),
                 ("fable", "claude-fable-5-1"), ("claude-3-5-sonnet-20241022", "sonnet"),
                 ("gpt-5.6-luna", "openai/gpt-5.6-luna"), ("gpt-5.6", "gpt-5.6-codex")):
        assert st.same_family(a, b) and st.same_family(b, a), (a, b)
    for a, b in (("sonnet", "claude-opus-5-5"), ("opus", "claude-sonnet-5-5"), ("haiku", "claude-opus-5-5"),
                 ("gpt-5.6", "gpt-5.60"), ("gpt-5.6", "claude-sonnet-5-5"), ("sonnet", "o3")):
        assert not st.same_family(a, b), (a, b)
    assert st.model_family("claude-sonnet-5-5") == "sonnet" and st.model_family("") == ""

def test_dominant_model_is_by_output_tokens():
    u = {"claude-opus-5-5": {"input": 900000, "output": 5}, "claude-sonnet-5-5": {"input": 1, "output": 400},
         "claude-haiku-5-5": {"input": 3, "output": 20}}
    assert st.dominant_model(u) == "claude-sonnet-5-5", "input/cache must not decide — only output"
    assert st.dominant_model({}) is None and st.dominant_model(None) is None
    assert st.dominant_model({"m": {"output": 0}}) is None

def test_dominant_model_not_intended_emits_one_model_mismatch_event():
    with host() as d:
        evs = _launch_end(d, model="sonnet")
        assert [e["event"] for e in evs] == ["launch", "session_end", "model_mismatch"], evs
        mm = evs[2]
        assert (mm["intended"], mm["actual"], mm["session"], mm["issue"]) == \
            ("sonnet", "claude-opus-5-5", FIXTURE_SID, 7), mm
        assert mm["prd"] == 5 and mm["repo"] == "acme/widget" and mm["prefix"] == "hz" and "usage" not in mm, mm
        # flagged in `harness stats`: the fleet summary, the PRD rollup's session and the issue timeline
        rc, out = run(["report", "--since", "2026-01-01"])
        assert rc == 0 and f"MODEL MISMATCH acme/widget #7 session {FIXTURE_SID}: intended sonnet ran claude-opus-5-5" in out, out
        rc, out = run(["report", "--since", "2026-01-01", "--json"])
        assert [(m["intended"], m["actual"], m["issue"]) for m in json.loads(out)["hz"]["model_mismatches"]] == \
            [("sonnet", "claude-opus-5-5", 7)], out
        rc, out = run(["report", "--prd", "5"])
        assert rc == 0 and "⚠ MODEL MISMATCH: ran claude-opus-5-5" in out, out
        rc, out = run(["report", "--prd", "5", "--json"])
        row = json.loads(out)["children"][0]["sessions"][0]
        assert row["model_mismatch"] == {"intended": "sonnet", "actual": "claude-opus-5-5"}, row
        rc, out = run(["report", "--issue", "7"])
        assert rc == 0 and "model_mismatch  ⚠ kind=impl intended=sonnet actual=claude-opus-5-5" in out, out
        # and in `harness status` (stats.py mismatches), scoped to its fleet
        rc, out = run(["mismatches", "--fleet", "hz"])
        assert rc == 0 and out.count("MODEL MISMATCH") == 1 and "intended sonnet ran claude-opus-5-5" in out, out
        assert run(["mismatches", "--fleet", "bw"]) == (0, "")

def test_matching_dominant_model_with_a_side_call_emits_nothing():
    for model in ("opus", "claude-opus-5-5", "opus[1m]", None):   # alias, full id, context suffix, CLI default
        with host() as d:
            evs = _launch_end(d, model=model)
            assert [e["event"] for e in evs] == ["launch", "session_end"], (model, evs)
            assert "claude-sonnet-5-5" in evs[1]["usage"], "the fixture's side call is in the usage"
            rc, out = run(["report", "--since", "2026-01-01"])
            assert "MISMATCH" not in out and run(["mismatches"]) == (0, ""), out
    assert st.model_mismatch({"model": "sonnet", "usage": {}}) is None, "no usage → no check"


def _msg(i, model, out, side=False):
    return {"type": "assistant", **({"isSidechain": True} if side else {}), "timestamp": "2026-10-01T00:01:00.000Z",
            "message": {"id": f"msg_{i}", "model": model, "content": [{"type": "text"}],
                        "usage": {"input_tokens": 1, "output_tokens": out}}}

def _orchestrator_cfg(d, main, sub):
    """A Claude config dir holding one session: a main transcript of <main> [(model, output)] and one
    sub-agent transcript of <sub> — the shape of a lane that mostly orchestrates (#461)."""
    sid = "99999999-8888-7777-6666-555555555555"
    tdir = os.path.join(d, "cfg", "projects", "-p")
    os.makedirs(os.path.join(tdir, sid, "subagents"))
    _write(os.path.join(tdir, sid + ".jsonl"), [_msg(i, m, o) for i, (m, o) in enumerate(main)])
    _write(os.path.join(tdir, sid, "subagents", "agent-x.jsonl"), [_msg(f"s{i}", m, o, True) for i, (m, o) in enumerate(sub)])
    return os.path.join(d, "cfg"), sid

def test_subagents_on_another_family_never_trip_model_mismatch():   # #461
    with host() as d:
        cfg, sid = _orchestrator_cfg(d, [("claude-sonnet-5-5", 100)], [("claude-opus-5-5", 5000)])
        os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = cfg
        ctx = os.path.join(d, "hz-main-i7.stats")
        assert st.main(["emit", "launch", "--write-ctx", ctx, "-c", "prefix=hz", "-c", "repo=acme/widget",
                        f"session={sid}", "goal=ISSUE:7", "prd=5", "model=sonnet"]) == 0
        assert st.main(["emit", "session_end", "--ctx", ctx]) == 0
        evs = events(d)
        assert [e["event"] for e in evs] == ["launch", "session_end"], evs
        end = evs[1]
        assert end["main_model"] == "claude-sonnet-5-5", end
        assert end["usage"]["claude-opus-5-5"]["output"] == 5000, "token and cost totals keep the sub-agents"
        assert st.dominant_model(end["usage"]) == "claude-opus-5-5"
        assert run(["mismatches"]) == (0, "")

def test_main_transcript_on_another_family_still_trips_model_mismatch_despite_subagents():   # #461
    with host() as d:
        cfg, sid = _orchestrator_cfg(d, [("claude-opus-5-5", 100)], [("claude-sonnet-5-5", 5000)])
        os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = cfg
        ctx = os.path.join(d, "hz-main-i7.stats")
        assert st.main(["emit", "launch", "--write-ctx", ctx, "-c", "prefix=hz", f"session={sid}",
                        "goal=ISSUE:7", "model=sonnet"]) == 0
        assert st.main(["emit", "session_end", "--ctx", ctx]) == 0
        evs = events(d)
        assert [e["event"] for e in evs] == ["launch", "session_end", "model_mismatch"], evs
        assert (evs[2]["intended"], evs[2]["actual"]) == ("sonnet", "claude-opus-5-5"), evs[2]

def test_session_end_without_main_model_falls_back_to_merged_usage():   # #461: logged before the field existed
    end = {"model": "sonnet", "usage": {"claude-opus-5-5": {"output": 9}}}
    assert st.model_mismatch(end)["actual"] == "claude-opus-5-5"
    assert st.model_mismatch({**end, "main_model": "claude-sonnet-5-5"}) is None


# --- --by-role (#378) ---------------------------------------------------------------
def test_session_kind_to_role_for_every_kind():
    want = {"impl": "implementer", "bug-fix": "implementer", "orch": "manager", "review": "manager",
            "bug-triage": "manager", "inject": "manager"}
    for kind, role in want.items():
        assert st.session_role({"kind": kind}) == role, kind
    assert st.session_role({"kind": "gauntlet-xyz"}) == "other", "unknown kind → other"
    # no kind (an event log from before kinds): the worktree's name says
    W = "/p/.harness/worktrees/"
    names = {W + "main-i7": "implementer", W + "bug-acme_widget-i9": "implementer",
             W + "orch-acme_widget-p3": "manager", W + "orch-acme_widget-p0/": "manager",
             W + "triage-acme_widget-i9": "manager", "/p/checkout": "other", "": "other"}
    for wt, role in names.items():
        assert st.session_role({"worktree": wt}) == role, wt
    assert st.session_role({}) == "other"

M = 1_000_000
ROLE_EVENTS = [
    # implementers: an issue lane (sonnet) and a bug fix (sonnet)
    _ev("launch", session="r1", issue=21, prd=9, kind="impl", model="sonnet"),
    _ev("session_end", session="r1", issue=21, prd=9, kind="impl",
        usage={"claude-sonnet-5-5": {"input": M, "output": M, "cache_create": 0, "cache_read": 0}}),
    _ev("session_end", session="r2", issue=30, kind="bug-fix",
        usage={"claude-sonnet-5-5": {"input": 0, "output": M, "cache_create": 0, "cache_read": M}}),
    # managers: PRD orchestration, review, triage, injector (opus)
    _ev("session_end", session="r3", prd=9, kind="orch", usage=_u(M)),
    _ev("session_end", session="r4", prd=9, kind="review", usage=_u(M)),
    _ev("session_end", session="r5", issue=30, kind="bug-triage", usage=_u(M)),
    _ev("session_end", session="r6", kind="inject", usage=_u(M)),
    # history from before kinds: the worktree on its launch attributes it
    _ev("launch", session="r7", worktree="/p/.harness/worktrees/main-i22"),
    _ev("session_end", session="r7", usage={"claude-sonnet-5-5": {"input": 0, "output": M, "cache_create": 0, "cache_read": 0}}),
    # an unknown kind, and one nothing attributes: `other`, never dropped
    _ev("session_end", session="r8", kind="mystery", usage=_u(M)),
    _ev("session_end", session="r9", usage=_u(M)),
]

def test_role_rollup_tokens_and_list_price_per_role():
    r = st.role_rollup(ROLE_EVENTS)
    assert list(r["roles"]) == ["manager", "implementer", "other"], r["roles"]
    mgr, imp, oth = r["roles"]["manager"], r["roles"]["implementer"], r["roles"]["other"]
    assert (mgr["sessions"], imp["sessions"], oth["sessions"]) == (4, 3, 2), r
    assert imp["input"] == M and imp["output"] == 3 * M and imp["cache_read"] == M, imp
    assert mgr["input"] == 4 and mgr["output"] == 4 * M and mgr["cache_create"] == 40 and mgr["cache_read"] == 400, mgr
    # list price: sonnet $2 in / $10 out / $0.20 cache read per Mtok; opus $4 / $20 / $5 write / $0.20 read
    assert imp["usd"] == round(2 + 10 * 3 + 0.2, 4), imp["usd"]
    opus_one = (1 * 4 + M * 20 + 10 * 5 + 100 * 0.2) / M
    assert abs(mgr["usd"] - 4 * opus_one) < 1e-3 and abs(oth["usd"] - 2 * opus_one) < 1e-3, (mgr, oth)
    t = r["total"]
    assert t["sessions"] == 9 and t["output"] == 9 * M and abs(t["usd"] - (imp["usd"] + mgr["usd"] + oth["usd"])) < 1e-3, t
    assert set(imp["tokens"]) == {"claude-sonnet-5-5"} and set(mgr["tokens"]) == {"claude-opus-5-5"}

def test_role_rollup_respects_filters_and_omits_empty_other():
    r = st.role_rollup(ROLE_EVENTS, prd=9)
    assert "other" not in r["roles"], "no unattributed session → no other row"
    assert r["roles"]["manager"]["sessions"] == 2 and r["roles"]["implementer"]["sessions"] == 1, r
    r = st.role_rollup(ROLE_EVENTS, issue=30)
    assert r["roles"]["manager"]["sessions"] == 1 and r["roles"]["implementer"]["sessions"] == 1, r
    r = st.role_rollup(ROLE_EVENTS, model="sonnet")
    assert r["roles"]["manager"]["sessions"] == 0 and r["roles"]["implementer"]["sessions"] == 3, r
    assert r["roles"]["manager"]["usd"] == 0 and r["total"]["usd"] == r["roles"]["implementer"]["usd"]
    other_fleet = [dict(e, prefix="bw") for e in ROLE_EVENTS[:2]]
    assert st.role_rollup(st.filter_events(ROLE_EVENTS + other_fleet, fleet="bw"))["total"]["sessions"] == 1

def test_report_cli_by_role_text_and_json():
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        for e in ROLE_EVENTS:
            st.append_event(e, p)
        rc, out = run(["report", "--by-role", "--since", "2026-01-01"])
        assert rc == 0, out
        lines = {l.split()[0]: l for l in out.splitlines() if l and not l.startswith(" ")}
        assert set(lines) == {"manager", "implementer", "other", "total"}, out
        assert "sessions 3  in 1,000,000  out 3,000,000" in lines["implementer"] and "$32.20" in lines["implementer"], out
        assert "sessions 9" in lines["total"] and "claude-sonnet-5-5: out 3,000,000" in out, out
        rc, out = run(["report", "--by-role", "--since", "2026-01-01", "--json"])
        j = json.loads(out)
        assert j["roles"]["implementer"]["usd"] == 32.2 and j["roles"]["other"]["sessions"] == 2, j
        rc, out = run(["report", "--by-role", "--prd", "9", "--json"])
        assert rc == 0 and json.loads(out)["total"]["sessions"] == 3, out
        rc, out = run(["report", "--by-role", "--issue", "30", "--json"])
        assert rc == 0 and json.loads(out)["total"]["sessions"] == 2, out
        rc, out = run(["report", "--by-role", "--fleet", "nope", "--since", "2026-01-01", "--json"])
        assert json.loads(out)["total"] == {"sessions": 0, "input": 0, "output": 0, "cache_create": 0,
                                             "cache_read": 0, "usd": 0, "tokens": {}}, out


def test_report_marks_a_codex_lane_as_a_fallback_price_estimate():   # #750
    """A model with no price row (codex, agy, opencode) is priced at the dearest row for the budget gate, but
    a spend report says so instead of presenting $75 per Mtok of output as real spend."""
    evs = [_ev("session_end", session="c1", kind="impl", usage={"gpt-5-codex": {"input": 0, "output": M, "cache_create": 0, "cache_read": 0}}),
           _ev("session_end", session="c2", kind="impl", usage={"claude-sonnet-5-5": {"input": 0, "output": M, "cache_create": 0, "cache_read": 0}})]
    imp = st.role_rollup(evs)["roles"]["implementer"]
    assert imp["usd"] == 75 + 10 and imp["usd_estimated"] == 75 and imp["unpriced_models"] == ["gpt-5-codex"], imp
    assert "usd_estimated" not in st.role_rollup(ROLE_EVENTS)["roles"]["implementer"], "all-Claude: no estimate"
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        for e in evs:
            st.append_event(e, p)
        rc, out = run(["report", "--by-role", "--since", "2026-01-01"])
        assert rc == 0, out
        assert "estimate" in out and "$75.00" in out and "gpt-5-codex" in out and "dearest" in out, out
        rc, out = run(["report", "--by-role", "--since", "2026-01-01", "--json"])
        j = json.loads(out)["total"]
        assert j["usd_estimated"] == 75 and j["unpriced_models"] == ["gpt-5-codex"], j


# --- coding vs testing time (#379) ---------------------------------------------------
def _tx(path, *lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for l in lines:
            fh.write(json.dumps(l) + "\n")

def _use(t, tid, cmd, name="Bash"):
    return {"type": "assistant", "timestamp": f"2026-10-01T{t}.000Z",
            "message": {"id": "m" + tid, "model": "claude-opus-5-5", "usage": {"input_tokens": 1, "output_tokens": 1},
                        "content": [{"type": "tool_use", "id": tid, "name": name, "input": {"command": cmd}}]}}

def _res(t, tid):
    return {"type": "user", "timestamp": f"2026-10-01T{t}.000Z",
            "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": "ok"}]}}

def _timed_transcript(d, sid="aaaaaaaa-0000-0000-0000-000000000001"):
    """600s of session: test calls cover 120s (t2) + 120s (t3/t4 overlap, union) in the main transcript,
    and 60s more in a sub-agent's; everything else is coding."""
    main = os.path.join(d, "projects", "-wt", sid + ".jsonl")
    _tx(main,
        {"type": "user", "timestamp": "2026-10-01T00:00:00.000Z", "message": {"role": "user", "content": "go"}},
        _use("00:00:10", "t1", "git status"), _res("00:00:12", "t1"),                     # coding call
        _use("00:01:00", "t2", "cd web && bash test/run.sh"), _use("00:01:01", "t2", "cd web && bash test/run.sh"),
        _res("00:03:00", "t2"),                                                           # 120s test (streamed twice)
        _use("00:04:00", "t3", "pytest -q test/"), _use("00:04:30", "t4", "go test ./..."),
        _res("00:05:00", "t3"), _res("00:06:00", "t4"),                                   # overlap -> 120s union
        _use("00:07:00", "t5", 'echo "run pytest later"'), _res("00:07:05", "t5"),         # mentions, does not run
        _use("00:07:10", "t6", "pytest", name="Read"),                                    # not a Bash call
        _use("00:09:00", "t7", "npm test"),                                               # never answered: 0s
        {"type": "assistant", "timestamp": "2026-10-01T00:10:00.000Z",
         "message": {"id": "mz", "model": "claude-opus-5-5", "content": [{"type": "text"}]}})
    _tx(os.path.join(d, "projects", "-wt", sid, "subagents", "agent-a.jsonl"),
        _use("00:08:00", "s1", "python3 -m pytest"), _res("00:09:00", "s1"))              # 60s test, in a sub-agent
    return main

def test_time_split_exact_on_a_fixture_transcript():
    with host() as d:
        tr = _timed_transcript(d)
        r = st.time_split(tr)
        assert r == {"total_s": 600, "testing_s": 300, "coding_s": 300, "test_calls": 4}, r

def test_time_split_command_patterns():
    rx = st.test_command_re()
    for cmd in ("pytest", "python3 -m pytest -x", "bash test/run.sh", "./test/run.sh", "cd a && npm test",
                "npm run test", "go test ./...", "cargo test --all", "bats test/x.bats", "rtdd which --base origin/main",
                "FOO=1 pytest", "git add -A; pytest", "python3 test/test_stats.py", "bash test/test_stats.sh"):
        assert rx.search(cmd), cmd
    for cmd in ("git status", 'echo "run pytest"', "gh issue comment 1 -b 'npm test failed'", "cat test/run.sh",
                "ls test/", "rtddx foo", "grep -n pytest README"):
        assert not rx.search(cmd), cmd

def test_time_split_pattern_is_overridable_by_env_and_config():
    with host() as d:
        tr = _timed_transcript(d)
        os.environ["HARNESS_TEST_COMMAND_PATTERNS"] = r"git status"
        try:
            r = st.time_split(tr)
            assert r["testing_s"] == 2 and r["test_calls"] == 1, r   # only the pattern's own call is testing
        finally:
            del os.environ["HARNESS_TEST_COMMAND_PATTERNS"]
        cfg = os.path.join(d, "state"); os.makedirs(cfg)
        with open(os.path.join(cfg, "config"), "w") as fh:
            fh.write('HARNESS_TEST_COMMAND_PATTERNS="go test"\n')
        os.environ["STATE_DIR"] = cfg
        try:
            r = st.time_split(tr)
            assert r["testing_s"] == 90 and r["test_calls"] == 1, r
        finally:
            del os.environ["STATE_DIR"]
        assert st.time_split(tr)["testing_s"] == 300   # defaults again

def test_time_split_no_transcript_or_calls():
    with host() as d:
        assert st.time_split(os.path.join(d, "nope.jsonl")) is None
        empty = os.path.join(d, "e.jsonl"); open(empty, "w").close()
        assert st.time_split(empty) is None
        one = os.path.join(d, "one.jsonl")
        _tx(one, _use("00:00:00", "a", "ls"), _res("00:00:30", "a"))
        assert st.time_split(one) == {"total_s": 30, "testing_s": 0, "coding_s": 30, "test_calls": 0}

def test_time_split_reaches_prd_and_issue_reports():
    with host() as d:
        _timed_transcript(d)
        sid = "aaaaaaaa-0000-0000-0000-000000000001"
        p = os.path.join(d, "events.jsonl")
        for e in (_ev("launch", session=sid, issue=21, prd=8, kind="impl", ts="2026-10-01T00:00:00Z"),
                  _ev("session_end", session=sid, issue=21, prd=8, kind="impl", wall_s=600, usage=_u(5)),
                  _ev("launch", session="gone", issue=21, prd=8, kind="impl", ts="2026-10-01T05:00:00Z"),
                  _ev("session_end", session="gone", issue=21, prd=8, kind="impl", wall_s=60, usage=_u(1)),
                  _ev("launch", session="s9", issue=22, prd=8, kind="impl"),
                  _ev("session_end", session="s9", issue=22, prd=8, kind="impl", wall_s=10, usage=_u(1))):
            st.append_event(e, p)
        os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = d
        rc, out = run(["report", "--prd", "8", "-R", "acme/widget", "--json"])
        j = json.loads(out)
        c21 = next(c for c in j["children"] if c["issue"] == 21)
        assert (c21["coding_s"], c21["testing_s"]) == (300, 300), c21
        assert [(s["coding_s"], s["testing_s"]) for s in c21["sessions"]] == [(300, 300), (None, None)], c21
        c22 = next(c for c in j["children"] if c["issue"] == 22)
        assert (c22["coding_s"], c22["testing_s"]) == (0, 0), c22
        assert (j["total"]["coding_s"], j["total"]["testing_s"]) == (300, 300), j["total"]
        rc, out = run(["report", "--prd", "8", "-R", "acme/widget"])
        assert "#21:" in out and "coding 5m00s  testing 5m00s" in out, out
        rc, out = run(["report", "--issue", "21", "-R", "acme/widget", "--json"])
        j = json.loads(out)
        assert (j["coding_s"], j["testing_s"]) == (300, 300), j
        rc, out = run(["report", "--issue", "21", "-R", "acme/widget"])
        assert "coding 5m00s  testing 5m00s" in out, out

def test_time_split_cli_subcommand():
    with host() as d:
        tr = _timed_transcript(d)
        rc, out = run(["time-split", tr])
        assert rc == 0 and json.loads(out) == {"total_s": 600, "testing_s": 300, "coding_s": 300, "test_calls": 4}, out
        assert run(["time-split", os.path.join(d, "none.jsonl")])[0] == 1


def test_report_into_a_reader_that_stops_early_is_quiet():   # #671: `harness stats | head -1`
    import subprocess
    script = os.path.join(HERE, "..", "scripts", "stats.py")
    with host() as d:
        p = os.path.join(d, "events.jsonl")
        with open(p, "w") as fh:
            for i in range(3000):
                for e in (_ev("launch", session=f"f{i}-s", prefix=f"fleet{i}", issue=i, prd=1, kind="impl", model="sonnet"),
                          _ev("session_end", session=f"f{i}-s", prefix=f"fleet{i}", issue=i, prd=1, kind="impl",
                              usage=_u(100, "claude-sonnet-5-5"))):
                    fh.write(json.dumps(e) + "\n")
        for extra in ([], ["--json"]):
            argv = [sys.executable, script, "report", "--events", p, "--since", "2026-01-01"] + extra
            full = subprocess.run(argv, capture_output=True, text=True)
            assert full.returncode == 0 and len(full.stdout) > 200_000, (extra, len(full.stdout), full.stderr)
            proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            first = proc.stdout.readline()
            proc.stdout.close()                      # head -1 has read its line and exited
            err = proc.stderr.read().decode()
            rc = proc.wait()
            assert first and err == "" and rc in (0, 141), (extra, rc, err)


RUN_DIR = os.path.join(HERE, "..", "bench", "results", "run-20261106", "harness.logs")

def _run_20261106_events():
    """The run's committed events with each claude session_end's usage re-folded from its committed
    transcript (the events predate the 5m / 1h split, #710), plus the bench's recompute over the same
    transcripts: ([events], bench_usd_per_transcript_session)."""
    import glob
    sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
    import forecast as fc
    trs = {os.path.basename(p).split("-", 1)[1][:-len(".jsonl")]: p
           for p in glob.glob(os.path.join(RUN_DIR, "transcripts", "*.jsonl"))}
    evs = []
    for line in open(os.path.join(RUN_DIR, "events.jsonl")):
        e = json.loads(line)
        if e.get("event") == "session_end" and e.get("session") in trs and e.get("usage"):
            e["usage"] = st.session_usage(trs[e["session"]])[0]
        evs.append(e)
    bench = {}
    for sid, p in trs.items():
        seen = {}
        for f in st.transcript_files(p):
            for key, model, u, _, _ in fc._messages(f):
                seen[key] = (model, u)
        bench[sid] = sum(fc.raw_cost(u, m) for m, u in seen.values())
    return evs, bench

def test_session_usage_keeps_the_1h_cache_writes_apart_and_counts_subagents():
    """#710: the folded usage carries the 1h share of cache_create; a sub-agent's turns are in the session."""
    tr = os.path.join(RUN_DIR, "transcripts", "8-b19488a1-eb39-44f5-b974-1f09845540ac.jsonl")
    (u,) = st.session_usage(tr)[0].values()
    # the main transcript wrote 109,500 tokens at 1h; the sub-agent's 59,855 are 5m (no 1h in its usage)
    assert u["cache_create"] == 169355 and u["cache_create_1h"] == 109500, u
    only_main = {}
    st._file_usage(tr, only_main, [None, None])
    assert next(iter(only_main.values()))["cache_create"] == 109500, "the sub-agent's writes are on top"
    # no TTL split recorded -> no key: old transcripts and other CLIs price as 5m
    assert all("cache_create_1h" not in u for u in st.session_usage(
        st.find_transcript(FIXTURE_SID, [FIXTURE_CFG]))[0].values())

def test_add_and_minus_usage_carry_the_1h_share():
    a = st.add_usage({}, {"m": {"input": 1, "output": 1, "cache_create": 10, "cache_read": 1, "cache_create_1h": 4}})
    a = st.add_usage(a, {"m": {"input": 1, "output": 1, "cache_create": 5, "cache_read": 1}})
    assert a["m"]["cache_create"] == 15 and a["m"]["cache_create_1h"] == 4, a
    d = st.usage_minus(a, {"m": {"cache_create": 5, "cache_create_1h": 1}})
    assert d["m"]["cache_create"] == 10 and d["m"]["cache_create_1h"] == 3, d

def test_stats_cost_for_run_20261106_matches_the_bench_recompute():
    """#710: `harness stats` priced every cache write at 5m: $5.07 for run-20261106 against the bench's
    $6.86. Priced by TTL, its fleet sessions cost what the bench recomputes from their transcripts. The bench
    figure also holds the front-door session (transcript 0-…, $0.70), the operator's own claude outside the
    fleet: it has no launch / session_end, so no events and no stats."""
    evs, bench = _run_20261106_events()
    front = sum(v for k, v in bench.items() if k.startswith("78d74eb3"))
    fleet = sum(bench.values()) - front
    assert abs(sum(bench.values()) - 6.8559) < 1e-3 and abs(front - 0.699) < 2e-3, (bench, front)
    got = st.role_rollup(evs)["total"]["usd"]
    assert abs(got - fleet) / fleet < 0.01, (got, fleet)
    # the same events with the split dropped price at the 5m default: the old, low figure
    for e in evs:
        for u in (e.get("usage") or {}).values():
            u.pop("cache_create_1h", None)
    old = st.role_rollup(evs)["total"]["usd"]
    assert 5.0 < old < 5.3 and got - old > 0.8, (old, got)


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except Exception as e: print(f"  FAIL: {name} — {type(e).__name__}: {e}"); fails += 1   # any error is this test's, the run goes on (#744)
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

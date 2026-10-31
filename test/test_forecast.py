"""test_forecast.py — #363: `harness forecast <issue>` math on a fixture event log + fixture transcripts:
phase attribution, list-price cost, quantiles, size scaling, the PRD → unit → host fallback, and the
CLI's text / --json. No network, no live GitHub: issue bodies come from a fixture file."""
import contextlib, importlib.util, io, json, os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
spec = importlib.util.spec_from_file_location("forecast", os.path.join(ROOT, "scripts", "forecast.py"))
fc = importlib.util.module_from_spec(spec); spec.loader.exec_module(fc)

MTOK = 1_000_000
OPUS_OUT = 40_000   # output tokens that cost exactly $1.00 on Opus ($25/Mtok)


def msg(mid, *tools, out=OPUS_OUT, model="claude-opus-5-5", usage=None):
    """One assistant transcript line; tools are (name, input) pairs."""
    content = [{"type": "text", "text": "…"}] + [{"type": "tool_use", "id": f"{mid}-{i}", "name": n, "input": inp}
                                                for i, (n, inp) in enumerate(tools)]
    return {"type": "assistant", "timestamp": "2026-10-01T00:00:00Z", "requestId": f"req-{mid}",
            "message": {"id": mid, "model": model, "content": content,
                        "usage": usage or {"input_tokens": 0, "output_tokens": out}}}


READ = ("Read", {"file_path": "scripts/lib.sh"})
EDIT_TEST = ("Edit", {"file_path": "test/test_widget.py"})
EDIT_SRC = ("Edit", {"file_path": "scripts/widget.py"})
GATE = ("Bash", {"command": "bash test/run.sh"})
SHIP = ("Bash", {"command": "git push -u origin issue/7 && gh pr create --fill"})


def write_lines(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for ln in lines:
            fh.write((ln if isinstance(ln, str) else json.dumps(ln)) + "\n")


@contextlib.contextmanager
def tmp():
    d = tempfile.mkdtemp()
    try:
        yield d
    finally:
        shutil.rmtree(d, ignore_errors=True)


def lane_events(repo, issue, sid, prd=None, unit="main", usage=None, kind="impl"):
    base = {"prefix": "hz", "repo": repo, "unit": unit, "kind": kind, "issue": issue, "session": sid}
    if prd is not None:
        base["prd"] = prd
    end = dict(base, event="session_end", ts="2026-10-01T01:00:00Z")
    if usage:
        end["usage"] = usage
    return [dict(base, event="launch", ts="2026-10-01T00:00:00Z"), end]


def transcript(cfg, sid, lines, subagents=()):
    pdir = os.path.join(cfg, "projects", "-tmp-proj--harness-worktrees-main-i1")
    write_lines(os.path.join(pdir, f"{sid}.jsonl"), lines)
    for i, sub in enumerate(subagents):
        write_lines(os.path.join(pdir, sid, "subagents", f"agent-{i}.jsonl"), sub)


# --- cost --------------------------------------------------------------------
def test_list_price_per_model_and_cache_split():
    assert fc.raw_cost({"output_tokens": MTOK}, "claude-opus-5-5") == 25
    assert fc.raw_cost({"input_tokens": MTOK, "output_tokens": MTOK}, "claude-sonnet-5-5") == 18
    assert fc.raw_cost({"cache_read_input_tokens": MTOK}, "claude-haiku-5-5") == 0.1
    # cache writes: 5-minute at 1.25x input, 1-hour at 2x; the total with no split is all 5-minute
    assert fc.raw_cost({"cache_creation_input_tokens": 2 * MTOK,
                        "cache_creation": {"ephemeral_1h_input_tokens": MTOK}}, "opus") == 6.25 + 10
    assert fc.raw_cost({"cache_creation_input_tokens": MTOK}, "opus") == 6.25
    assert fc.raw_cost({"output_tokens": MTOK}, "gpt-5-codex") == 25, "an unknown model prices as Opus"
    # the folded usage stats.py / a CLI adapter's usage_tsv writes (#188)
    assert fc.usage_cost({"claude-sonnet-5-5": {"input": MTOK, "output": MTOK, "cache_create": MTOK,
                                                "cache_read": MTOK}}) == 3 + 15 + 3.75 + 0.3


# --- phase attribution -------------------------------------------------------
def test_phase_attribution_dedupes_streamed_messages_and_includes_subagents():
    with tmp() as d:
        sid = "s-attr"
        transcript(d, sid, [
            msg("m1", READ),                       # explore: before the first edit
            msg("m2"), msg("m2", EDIT_TEST),       # streamed twice under one id → test, $1 once
            msg("m3", EDIT_SRC),                   # impl
            msg("m4", READ),                       # still impl: a read after an edit keeps the phase
            msg("m5", GATE),                       # gate
            msg("m6", READ, out=2 * OPUS_OUT),     # still gate ($2)
            msg("m7", SHIP),                       # ship
            {"type": "assistant", "message": {"id": "syn", "model": "<synthetic>", "usage": {"output_tokens": MTOK}}},
            "{torn line",
        ], subagents=[[
            msg("a1", READ),                       # a sub-agent starts in explore
            msg("a2", ("Bash", {"command": "pytest -q"})),   # gate before any edit …
            msg("a3", READ),                       # … and back to explore: nothing edited yet
            msg("a4", ("Write", {"file_path": "src/feature.py"})),   # impl
            msg("m7", SHIP),                       # the main session's message again: counted once
        ]])
        files = fc.st.transcript_files(os.path.join(d, "projects", "-tmp-proj--harness-worktrees-main-i1", f"{sid}.jsonl"))
        assert len(files) == 2, files
        assert fc.transcript_phases(files) == {"explore": 3.0, "test": 1.0, "impl": 3.0, "gate": 4.0, "ship": 1.0}


def test_phase_rules():
    p = lambda b, cur="impl", edited=True: fc.phase_of({"name": b[0], "input": b[1]}, cur, edited)
    for path in ("test/test_x.sh", "tests/unit/a.py", "spec/a_spec.rb", "pkg/foo_test.go", "web/a.test.ts",
                 "test_widget.py", "t/x.bats"):
        assert p(("Edit", {"file_path": path})) == "test", path
    for path in ("scripts/stats.py", "docs/reference.md", "src/contest.py"):
        assert p(("Write", {"file_path": path})) == "impl", path
    for cmd in ("bash test/run.sh", "scripts/ci-local.sh", "rtdd which --base origin/main", "python3 -m pytest",
                "bash swarm-suite.sh . x", "python3 test/test_forecast.py", "bash test_stats.sh", "go test ./...",
                "npm test", "npm run test"):
        assert p(("Bash", {"command": cmd}), "explore", False) == "gate", cmd
    for cmd in ("git push --force-with-lease", "gh pr merge --squash 9", "gh issue comment 9 -b x",
                "gh issue close 9", "gh issue edit 9 --add-label x"):
        assert p(("Bash", {"command": cmd})) == "ship", cmd
    assert p(("Bash", {"command": "gh issue view 9"}), "gate") == "gate", "a read-only gh call keeps the phase"
    assert p(("Bash", {"command": "ls"}), "gate", False) == "explore"


# --- distribution ------------------------------------------------------------
def test_quantiles_are_nearest_rank():
    v = [5, 1, 4, 2, 3, 10, 6, 7, 9, 8]
    assert [fc.quantile(v, q) for q in (0.5, 0.8, 0.95)] == [6, 9, 10]
    assert fc.quantile([3.0], 0.95) == 3.0 and fc.quantile([], 0.5) == 0.0


def test_size_scale_is_clamped_and_neutral_when_unknown():
    assert fc.size_scale(1500, [1000, 0, 3000, 1000]) == (1.5, 1000)        # median of the non-empty bodies
    assert fc.size_scale(1500, [1000, 2000]) == (1.0, 1500.0)
    assert fc.size_scale(3000, [1000, 2000]) == (2.0, 1500.0)
    assert fc.size_scale(6000, [1000, 2000]) == (2.0, 1500.0), "clamped at 2.0"
    assert fc.size_scale(100, [1000, 2000]) == (0.6, 1500.0), "clamped at 0.6"
    assert fc.size_scale(None, [1000]) == (1.0, 1000) and fc.size_scale(500, []) == (1.0, None)


def test_lane_without_transcript_is_spread_by_the_pool_phase_mix():
    a = {"phases": {"explore": 1.0, "test": 0.0, "impl": 3.0, "gate": 0.0, "ship": 0.0}, "unattributed": 0.0}
    b = {"phases": {"explore": 3.0, "test": 0.0, "impl": 1.0, "gate": 0.0, "ship": 0.0}, "unattributed": 0.0}
    c = {"phases": None, "unattributed": 8.0}   # another CLI's lane: only its folded usage
    assert fc.spread([a, b, c])[2] == {"explore": 4.0, "test": 0.0, "impl": 4.0, "gate": 0.0, "ship": 0.0}
    assert fc.spread([c])[0] == {p: 1.6 for p in fc.PHASES}, "no transcript anywhere: an even split"


def _lane(repo, issue, total, prd=None):
    return {"repo": repo, "issue": issue, "prd": prd, "unit": "main", "total": total}


def test_pool_falls_back_prd_then_unit_then_host_and_skips_turn1_lanes():
    W, O = "acme/widget", "acme/other"
    sib = [_lane(W, n, 5.0, prd=5) for n in (1, 2, 3)]
    unit = [_lane(W, n, 5.0) for n in (10, 11)]
    host = [_lane(O, n, 5.0) for n in (20, 21)]
    dead = [_lane(W, 30, 0.2, prd=5)]                 # died at turn 1
    own = [_lane(W, 7, 9.0, prd=5)]                   # the forecast issue's own lane: never its pool
    tier, pool, notes = fc.choose_pool(sib + unit + host + dead + own, W, 7, 5)
    assert (tier, len(pool), notes) == ("prd", 3, []), (tier, pool, notes)
    tier, pool, notes = fc.choose_pool(sib[:2] + unit + host + dead + own, W, 7, 5)
    assert (tier, len(pool)) == ("unit", 4) and notes == ["PRD #5 has 2 past lane(s), need 3"], notes
    tier, pool, notes = fc.choose_pool(sib[:1] + unit[:1] + host + own, W, 7, 5)
    assert (tier, len(pool)) == ("host", 4), (tier, pool)
    assert notes == ["PRD #5 has 1 past lane(s), need 3", "unit acme/widget has 2 past lane(s), need 3"], notes
    tier, _, notes = fc.choose_pool(unit + sib, W, 7, None)
    assert tier == "unit" and notes == ["#7 names no parent PRD"], notes
    assert fc.choose_pool(own + dead, W, 7, 5)[0] == "none"


# --- end to end on a fixture event log + transcripts --------------------------
W = "acme/widget"


def fixture(d):
    """Unit acme/widget: four lanes with transcripts ($4, $8, $12, $20 — explore $1 + test $1, the rest
    impl/gate/ship), one non-claude lane (folded usage only, $10), one lane that died at turn 1, and
    one lane on another repo. None is under PRD #9, the forecast issue's parent; #50 has no history."""
    cfg = os.path.join(d, "claude")
    evs = []
    for n, total in ((1, 4), (2, 8), (3, 12), (4, 20)):
        sid = f"s{n}"
        rest = total - 2
        transcript(cfg, sid, [msg(f"{sid}e", READ), msg(f"{sid}t", EDIT_TEST),
                              msg(f"{sid}i", EDIT_SRC, out=OPUS_OUT * rest // 2),
                              msg(f"{sid}g", GATE, out=OPUS_OUT * (rest - rest // 2 - 1)), msg(f"{sid}s", SHIP)])
        evs += lane_events(W, n, sid, prd=3)
    evs += lane_events(W, 5, "codex-5", usage={"gpt-5-codex": {"input": 0, "output": 400_000, "cache_create": 0,
                                                                "cache_read": 0}})
    evs += lane_events(W, 6, "s6")
    transcript(cfg, "s6", [msg("s6e", READ, out=400)])   # $0.01: died at turn 1
    evs += lane_events("acme/other", 1, "o1", unit="other")
    transcript(cfg, "o1", [msg("o1e", READ, out=OPUS_OUT * 100)])
    evs.append({"ts": "2026-10-01T00:00:00Z", "event": "claim", "prefix": "hz", "unit": "main"})
    events = os.path.join(d, "events.jsonl")
    write_lines(events, evs)
    bodies = os.path.join(d, "bodies.json")
    with open(bodies, "w") as fh:   # issue bodies, shaped like `gh issue list --json number,body`
        json.dump([{"number": n, "body": "x" * 1000} for n in (1, 2, 3, 4, 5, 6)]
                  + [{"number": 50, "body": "y" * 1486 + "\n## Parent\n#9\n"}], fh)
    return cfg, events, bodies


def run_cli(argv, cfg):
    saved = os.environ.get("HARNESS_CLAUDE_CONFIG_DIRS")
    os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = cfg
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = fc.main(argv)
    finally:
        if saved is None: os.environ.pop("HARNESS_CLAUDE_CONFIG_DIRS", None)
        else: os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = saved
    return rc, out.getvalue(), err.getvalue()


def test_forecast_without_history_falls_back_to_unit_and_says_so():
    with tmp() as d:
        cfg, events, bodies = fixture(d)
        rc, js, _ = run_cli(["50", "-R", W, "--events", events, "--bodies", bodies, "--json"], cfg)
        assert rc == 0, rc
        f = json.loads(js)
        assert (f["prd"], f["unit"]) == (9, "main"), f
        b = f["basis"]
        assert (b["tier"], b["lanes"], b["fallback"], b["no_transcript"]) == ("unit", 5, True, 1), b
        assert b["notes"] == ["#50 has no history", "PRD #9 has 0 past lane(s), need 3"], b["notes"]
        # body 1500 vs the pool's median 1000 → x1.5; totals 4, 8, 10, 12, 20
        assert f["size"] == {"body": 1500, "median_body": 1000, "scale": 1.5, "clamp": [0.6, 2.0]}, f["size"]
        assert f["total"] == {"p50": 15.0, "p80": 30.0, "p95": 30.0}, f["total"]
        # explore: $1 per claude lane, the codex lane's $10 spread by the mix → per-lane 1,1,1,1,x
        assert f["phases"]["explore"]["p50"] == 1.5, f["phases"]
        assert f["phases"]["test"]["p50"] == 1.5 and f["phases"]["ship"]["p50"] == 1.5, f["phases"]
        assert f["pct"] is None and f["spent"] == {"sessions": 0, "usd": 0}, f
        rc, text, _ = run_cli(["50", "-R", W, "--events", events, "--bodies", bodies], cfg)
        assert rc == 0
        assert "FALLBACK to unit main: #50 has no history; PRD #9 has 0 past lane(s), need 3" in text, text
        assert "body 1500 chars vs median 1000 → scale x1.50" in text, text
        assert "  TOTAL       15.00    30.00    30.00   n/a" in text, text
        assert "n/a until a $-per-% calibration exists" in text, text


def test_forecast_uses_prd_siblings_reports_spend_and_resolves_the_repo():
    with tmp() as d:
        cfg, events, bodies = fixture(d)
        with open(events, "a") as fh:   # #4 was resumed once already: its own spend, outside its pool
            for e in lane_events(W, 4, "s4b", prd=3):
                fh.write(json.dumps(e) + "\n")
        # no -R: the issue's own lanes name its repo
        rc, js, _ = run_cli(["4", "--events", events, "--bodies", bodies, "--json"], cfg)
        f = json.loads(js)
        assert rc == 0 and f["repo"] == W and f["prd"] == 3, f
        assert (f["basis"]["tier"], f["basis"]["lanes"], f["basis"]["fallback"]) == ("prd", 3, False), f["basis"]
        assert f["spent"] == {"sessions": 2, "usd": 20.0}, f["spent"]
        assert f["total"] == {"p50": 8.0, "p80": 12.0, "p95": 12.0}, f["total"]
        rc, text, _ = run_cli(["4", "--events", events, "--bodies", bodies], cfg)
        assert "basis: PRD #3 siblings — 3 past lane(s)" in text and "FALLBACK" not in text, text
        assert "already spent on #4: $20.00 over 2 session(s)" in text, text


def test_forecast_host_fallback_and_no_history_at_all():
    with tmp() as d:
        cfg, events, bodies = fixture(d)
        rc, js, _ = run_cli(["8", "-R", "acme/new", "--events", events, "--bodies", bodies, "--json"], cfg)
        f = json.loads(js)
        assert rc == 0 and f["basis"]["tier"] == "host" and f["basis"]["lanes"] == 6, f["basis"]
        assert f["basis"]["notes"][-1] == "unit acme/new has 0 past lane(s), need 3", f["basis"]
        empty = os.path.join(d, "empty.jsonl"); open(empty, "w").close()
        rc, js, err = run_cli(["8", "-R", W, "--events", empty, "--bodies", bodies, "--json"], cfg)
        assert rc == 1 and json.loads(js)["basis"]["tier"] == "none" and "no past lanes" in err, (rc, err)


def test_repo_resolution_from_the_project():
    with tmp() as d:
        sd = os.path.join(d, ".harness"); os.makedirs(sd)
        with open(os.path.join(sd, "config"), "w") as fh:
            fh.write(': "${HARNESS_TOPOLOGY:=multi}"\n: "${HARNESS_OWNER:=acme}"\n')
        with open(os.path.join(sd, "targets.tsv"), "w") as fh:
            fh.write("# id\trepo\tdeps\tdesc\nmain\twidget\t-\tw\n")
        assert fc.resolve_repo(50, None, None, [], sd) == ("acme/widget", "main"), "the only unit"
        assert fc.resolve_repo(50, "acme/widget", None, [], sd) == ("acme/widget", "main")
        with open(os.path.join(sd, "targets.tsv"), "a") as fh:
            fh.write("gadget\tacme/gadget\t-\tg\n")
        assert fc.resolve_repo(50, None, "gadget", [], sd) == ("acme/gadget", "gadget")
        for bad in ((50, None, None), (50, None, "nope")):
            try:
                fc.resolve_repo(*bad, [], sd)
                assert False, bad
            except ValueError:
                pass
        mine = lane_events("acme/gadget", 50, "x")
        assert fc.resolve_repo(50, None, None, mine, sd) == ("acme/gadget", "gadget"), "the issue's own lane"
        with open(os.path.join(sd, "config"), "w") as fh:
            fh.write(': "${HARNESS_TOPOLOGY:=single}"\n: "${HARNESS_REPO:=acme/solo}"\n')
        assert fc.resolve_repo(50, None, None, [], sd) == ("acme/solo", "main")


def test_harness_forecast_cli_dispatch():
    with tmp() as d:
        cfg, events, bodies = fixture(d)
        env = dict(os.environ, HARNESS_CLAUDE_CONFIG_DIRS=cfg, STATE_DIR=os.path.join(d, "none"))
        r = subprocess.run(["bash", os.path.join(ROOT, "bin", "harness"), "forecast", "50", "-R", W,
                            "--events", events, "--bodies", bodies, "--json"], capture_output=True, text=True, env=env)
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout)["total"]["p50"] == 15.0
        r = subprocess.run(["bash", os.path.join(ROOT, "bin", "harness"), "help"], capture_output=True, text=True, env=env)
        assert "\n  forecast <issue>" in r.stdout, r.stdout


# --- usage calibration (#364) --------------------------------------------------
def at(hhmm):
    return f"2026-10-02T{hhmm}:00Z"


def timed(mid, hhmm, usd):
    m = msg(mid, out=int(OPUS_OUT * usd))
    m["timestamp"] = at(hhmm)
    return m


def reading(acct, win, hhmm, pct, reset):
    return {"ts": at(hhmm), "event": "usage_reading", "prefix": "hz", "account": acct, "window": win,
            "pct": pct, "resets_at": reset}


def calibration_fixture(d):
    """Account `main`: lane #1's session spends $10 @01:00, $20 @02:00, $5 @03:00, $40 @05:00, $30 @06:00.
    Its seven_day readings: 10% @00:30 (seen again @01:30 and by a second fleet @02:40 — one reading),
    11% @02:30, 11.5 @03:30, then the window resets (2% @04:30, a new resets_at) and 3% @06:30. Its
    five_hour window has a single reading. Account `other`: lane #2 spends $100 @02:00 — never main's —
    and has no readings at all. Lane #3 is another CLI's (no transcript, so no account)."""
    main, other = os.path.join(d, "main"), os.path.join(d, "other")
    R1, R2 = 1_800_000_000, 1_800_600_000
    transcript(main, "sA", [timed("a1", "01:00", 10), timed("a2", "02:00", 20), timed("a3", "03:00", 5),
                            timed("a4", "05:00", 40), timed("a5", "06:00", 30)])
    transcript(other, "sB", [timed("b1", "02:00", 100)])
    evs = []
    for n, sid in ((1, "sA"), (2, "sB"), (3, "codex-3")):
        for e in lane_events(W, n, sid, usage={"gpt-5-codex": {"input": 0, "output": 40_000, "cache_create": 0,
                                                              "cache_read": 0}} if n == 3 else None):
            e["ts"] = at("00:00" if e["event"] == "launch" else "07:00")
            evs.append(e)
    evs += [reading("main", "seven_day", "00:30", 10, R1), reading("main", "seven_day", "01:30", 10, R1),
            reading("main", "seven_day", "02:30", 11, R1), reading("main", "seven_day", "02:40", 11, R1),
            reading("main", "seven_day", "03:30", "11.5", R1), reading("main", "seven_day", "04:30", 2, R2),
            reading("main", "seven_day", "06:30", 3, R2), reading("main", "five_hour", "01:00", 40, R1),
            {"ts": at("01:00"), "event": "usage_reading", "account": "main", "window": "seven_day", "pct": "n/a"}]
    events = os.path.join(d, "events.jsonl")
    write_lines(events, evs)
    return os.pathsep.join((main, other)), events


def test_calibration_fits_usd_per_pct_skips_reset_pairs_and_lists_accounts_without_readings():
    with tmp() as d:
        cfgs, events = calibration_fixture(d)
        saved = os.environ.get("HARNESS_CLAUDE_CONFIG_DIRS")
        os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = cfgs
        try:
            evs = fc.st.load_events(events)
            r = fc.readings(evs)
            assert [x[1] for x in r[("main", "seven_day")]] == [10, 11, 11.5, 2, 3], r
            cal = fc.calibrate(evs, {"main", "other"})
        finally:
            if saved is None: os.environ.pop("HARNESS_CLAUDE_CONFIG_DIRS", None)
            else: os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = saved
        # pairs: 10→11 $30 (30/1%), 11→11.5 $5 (10/1%), [reset: skipped], 2→3 $70 (70/1%); other's $100 never counts
        assert cal == [
            {"account": "main", "window": "five_hour", "pairs": 0, "skipped_reset": 0, "central": None, "bound": None},
            {"account": "main", "window": "seven_day", "pairs": 3, "skipped_reset": 1, "central": 42.0, "bound": 10.0},
            {"account": "other", "window": None, "pairs": 0, "skipped_reset": 0, "central": None, "bound": None},
        ], cal
        assert fc.transcript_account("/x/.claude/projects/p/s.jsonl") == "default", "~/.claude is the default account"


def test_forecast_prints_pct_of_each_window_from_the_bound_or_the_fallback():
    with tmp() as d:
        cfgs, events = calibration_fixture(d)
        bodies = os.path.join(d, "bodies.json")
        with open(bodies, "w") as fh:
            json.dump([], fh)
        saved = os.environ.pop(fc.FALLBACK_SETTING, None)
        try:
            os.environ[fc.FALLBACK_SETTING] = "50"
            rc, js, _ = run_cli(["50", "-R", W, "--events", events, "--bodies", bodies, "--json"], cfgs)
            rc2, text, _ = run_cli(["50", "-R", W, "--events", events, "--bodies", bodies], cfgs)
            os.environ.pop(fc.FALLBACK_SETTING)
            _, js_none, _ = run_cli(["50", "-R", W, "--events", events, "--bodies", bodies, "--json"], cfgs)
            _, text_none, _ = run_cli(["50", "-R", W, "--events", events, "--bodies", bodies], cfgs)
        finally:
            os.environ.pop(fc.FALLBACK_SETTING, None)
            if saved is not None: os.environ[fc.FALLBACK_SETTING] = saved
        assert rc == 0 and rc2 == 0, (rc, rc2)
        f = json.loads(js)
        # pool totals $1 (codex: 40k gpt output, priced as Opus), $100, $105 → p50 $100, p80/p95 $105
        assert f["total"] == {"p50": 100.0, "p80": 105.0, "p95": 105.0}, f["total"]
        pct = {(w["account"], w["window"]): w for w in f["pct"]}
        assert pct[("main", "seven_day")]["source"] == "fit" and pct[("main", "seven_day")]["usd_per_pct"] == 10.0
        assert pct[("main", "seven_day")]["total"] == {"p50": 10.0, "p80": 10.5, "p95": 10.5}, pct
        for k in (("main", "five_hour"), ("other", None)):
            assert pct[k]["source"] == "fallback" and pct[k]["total"] == {"p50": 2.0, "p80": 2.1, "p95": 2.1}, pct[k]
        assert pct[("main", "seven_day")]["phases"]["explore"]["p95"] == round(f["phases"]["explore"]["p95"] / 10, 2)
        assert "calibration main seven_day: 3 pair(s), fit $42.00/1%, bound $10.00/1% (1 pair(s) skipped: window reset)" \
            in text, text
        assert "calibration main five_hour: no usable reading pair — FALLBACK HARNESS_ONE_USD_PER_PCT=$50.00/1%" in text, text
        assert "calibration other: no usage readings — FALLBACK HARNESS_ONE_USD_PER_PCT=$50.00/1%" in text, text
        assert "main seven_day" in text and "10.00/10.50/10.50" in text and "2.00/2.10/2.10" in text, text
        assert "% of window" in text and "n/a until" not in text, text
        # no fallback set: the fitted window still shows, the others say n/a
        fn = json.loads(js_none)
        assert [(w["account"], w["window"], w["source"]) for w in fn["pct"]] == \
            [("main", "five_hour", "none"), ("main", "seven_day", "fit"), ("other", None, "none")], fn["pct"]
        assert fn["pct"][0]["total"] is None and fn["calibration"]["fallback"] is None
        assert "calibration other: no usage readings and HARNESS_ONE_USD_PER_PCT unset — n/a" in text_none, text_none


def test_fallback_alone_and_the_setting_from_config():
    w = fc.window_pct([], {p: {"p50": 1.0, "p80": 2.0, "p95": 4.0} for p in fc.PHASES},
                      {"p50": 5.0, "p80": 10.0, "p95": 20.0}, 40.0)
    assert len(w) == 1 and (w[0]["account"], w[0]["source"]) == (None, "fallback"), w
    assert w[0]["total"] == {"p50": 0.12, "p80": 0.25, "p95": 0.5}, w
    assert fc.window_pct([], {}, {}, None) == []
    with tmp() as d:
        with open(os.path.join(d, "config"), "w") as fh:
            fh.write(': "${HARNESS_TOPOLOGY:=single}"\n: "${HARNESS_ONE_USD_PER_PCT:=43}"\n')
        saved = os.environ.pop(fc.FALLBACK_SETTING, None)
        try:
            assert fc.usd_per_pct_setting(d) == 43.0, "read from the project config"
            os.environ[fc.FALLBACK_SETTING] = "55.5"
            assert fc.usd_per_pct_setting(d) == 55.5, "the environment wins"
            os.environ[fc.FALLBACK_SETTING] = "nope"
            assert fc.usd_per_pct_setting(None) is None
        finally:
            os.environ.pop(fc.FALLBACK_SETTING, None)
            if saved is not None: os.environ[fc.FALLBACK_SETTING] = saved


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

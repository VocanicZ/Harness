"""test_one.py — #365: the /harness-one gate thresholds. APPROVE iff now% + p80% + reserve <= stop for
every window — exactly at the boundary approves, just above denies — honouring the stop % and the
reserve; a stale reading is padded; a window with no p80 %, no reading, or no history denies. Then
the one.py CLI on a forecast forecast.py itself built. #366: the per-phase re-check — the forecast
left from a phase on (remaining), FITS at the stop % and CHECKPOINT just above it.""" 
import importlib.util, json, os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
spec = importlib.util.spec_from_file_location("one", os.path.join(ROOT, "scripts", "one.py"))
one = importlib.util.module_from_spec(spec); spec.loader.exec_module(one)
spec = importlib.util.spec_from_file_location("forecast", os.path.join(ROOT, "scripts", "forecast.py"))
fc_mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(fc_mod)


def fc(p80=6.0, account="main", window="seven_day", fallback=None, tier="prd", usd_p80=30.0):
    """A forecast dict shaped like forecast.py's: one % row (p80 = `p80` % of the window)."""
    rows = [] if p80 is None else [{"account": account, "window": window, "source": "fit", "usd_per_pct": 5.0,
                                    "phases": {}, "total": {"p50": p80 / 2, "p80": p80, "p95": p80 * 2}}]
    return {"issue": 7, "repo": "acme/widget", "basis": {"tier": tier}, "total": {"p50": 1, "p80": usd_p80, "p95": 60},
            "pct": rows or None, "calibration": {"fallback": fallback}}


def rd(pct, account="main", window="seven_day", age=60):
    return {"account": account, "window": window, "pct": pct, "resets_at": 0, "age": age}


def test_approve_exactly_at_the_boundary_deny_just_above():
    # 90 + 6 + 2 = 98: at the stop % → APPROVE
    g = one.gate(fc(6.0), [rd(90.0)], stop=98, reserve=2)
    assert g["verdict"] == "APPROVE", g
    assert g["windows"][0]["need"] == 98.0 and g["windows"][0]["ok"], g
    # 90.01 + 6 + 2 = 98.01: just above → DENY, naming the window
    g = one.gate(fc(6.0), [rd(90.01)], stop=98, reserve=2)
    assert g["verdict"] == "DENY" and "main seven_day: 98.01% > 98%" in g["reasons"], g
    # float noise at the boundary still approves (95.1 + 0.9 + 2 is 98.00000000000001 unrounded)
    assert one.gate(fc(0.9), [rd(95.1)], stop=98, reserve=2)["verdict"] == "APPROVE"


def test_stop_pct_and_reserve_are_honoured():
    assert one.gate(fc(6.0), [rd(90.0)], stop=97, reserve=2)["verdict"] == "DENY", "a lower stop %"
    assert one.gate(fc(6.0), [rd(90.0)], stop=98, reserve=3)["verdict"] == "DENY", "a bigger reserve"
    assert one.gate(fc(6.0), [rd(90.0)], stop=98, reserve=0)["verdict"] == "APPROVE"
    assert one.gate(fc(6.0), [rd(91.0)], stop=99, reserve=2)["verdict"] == "APPROVE", "a higher stop %"


def test_every_window_must_fit():
    f = fc(6.0)
    f["pct"].append({"account": "main", "window": "five_hour", "source": "fit", "total": {"p80": 30.0}})
    g = one.gate(f, [rd(10.0), rd(70.0, window="five_hour")], stop=98, reserve=2)
    assert g["verdict"] == "DENY" and g["reasons"] == ["main five_hour: 102% > 98%"], g
    assert g["windows"][0]["ok"] and not g["windows"][1]["ok"], g


def test_stale_reading_is_padded():
    fresh = one.gate(fc(6.0), [rd(88.0, age=60)], stop=98, reserve=2, stale_min=30, stale_pad=3)
    assert fresh["verdict"] == "APPROVE" and fresh["windows"][0]["pad"] == 0, fresh
    stale = one.gate(fc(6.0), [rd(88.0, age=31 * 60)], stop=98, reserve=2, stale_min=30, stale_pad=3)
    assert stale["verdict"] == "DENY" and stale["windows"][0]["need"] == 99.0, stale
    unknown = one.gate(fc(6.0), [rd(88.0, age=None)], stop=98, reserve=2, stale_min=30, stale_pad=3)
    assert unknown["windows"][0]["pad"] == 3, "an unknown age is stale"


def test_p80_row_matching_and_fallback():
    # the account's own row, whatever the window, before the account-less one
    f = fc(6.0, window=None)
    assert one.p80_pct(f, "main", "five_hour") == (6.0, "fit")
    f = fc(4.0, account=None, window=None)
    assert one.p80_pct(f, "default", "seven_day")[0] == 4.0
    # "default" and ".claude" name the same account (forecast.py's norm_account)
    assert one.p80_pct(fc(5.0, account="default"), ".claude", "seven_day")[0] == 5.0
    # no row for the account: the forecast's p80 $ over HARNESS_ONE_USD_PER_PCT
    assert one.p80_pct(fc(6.0, fallback=10.0, usd_p80=30.0), "other", "seven_day") == (3.0, "fallback")
    # neither: no p80 % → DENY
    g = one.gate(fc(None), [rd(10.0)])
    assert g["verdict"] == "DENY" and g["windows"][0]["need"] is None, g


def test_no_reading_or_no_history_denies():
    g = one.gate(fc(1.0), [])
    assert g["verdict"] == "DENY" and any("no usage reading" in r for r in g["reasons"]), g
    g = one.gate(fc(1.0, tier="none"), [rd(10.0)])
    assert g["verdict"] == "DENY" and any("no past lanes" in r for r in g["reasons"]), g


def test_parse_readings_skips_malformed_lines():
    got = one.parse_readings("main\tseven_day\t40\t123\t75\nmain\tfive_hour\tn/a\t0\t\nbad\nx\tfive_hour\t12.5\t9\t\n")
    assert [(r["account"], r["window"], r["pct"], r["age"]) for r in got] == \
        [("main", "seven_day", 40.0, 75.0), ("x", "five_hour", 12.5, None)], got


def test_cli_on_a_real_forecast_prints_the_arithmetic():
    # a forecast.py forecast with no history but a $-per-% fallback: p80 % = its p80 $ / 10
    f = fc_mod.forecast([], "acme/widget", 7, fallback=10.0)
    p80 = round(f["total"]["p80"] / 10.0, 2)
    with tempfile.TemporaryDirectory() as d:
        fp, rp = os.path.join(d, "f.json"), os.path.join(d, "r.tsv")
        with open(fp, "w") as fh: json.dump(f, fh)
        with open(rp, "w") as fh: fh.write("main\tseven_day\t40\t0\t60\n")
        cmd = [sys.executable, os.path.join(ROOT, "scripts", "one.py"), "gate", "--forecast", fp, "--readings", rp]
        r = subprocess.run(cmd, capture_output=True, text=True)
        assert r.returncode == 1, "no history on the host: DENY"
        assert "forecast #7" in r.stdout and "RECOMMEND: DENY" in r.stdout, r.stdout
        assert f"now 40% + p80 {p80:g}% (fallback) + reserve 2%" in r.stdout, r.stdout
        assert "approve / pick another issue / stop" in r.stdout, r.stdout
        r = subprocess.run(cmd + ["--json"], capture_output=True, text=True)
        g = json.loads(r.stdout)
        assert g["verdict"] == "DENY" and g["forecast"]["issue"] == 7, g


def fc_split(per_phase=2.0, total=8.0, account="main", window="seven_day"):
    """A forecast with a per-phase split: each of the 5 phases p80 = `per_phase` % of the window, the
    whole issue's p80 = `total` % (under the 10 % the five sum to); $ likewise at 5 $ per 1 %."""
    split = {p: {"p50": per_phase / 2, "p80": per_phase, "p95": per_phase * 2} for p in fc_mod.PHASES}
    usd = {p: {q: v * 5 for q, v in r.items()} for p, r in split.items()}
    return {"issue": 7, "repo": "acme/widget", "basis": {"tier": "prd"},
            "phases": usd, "total": {"p50": total * 2.5, "p80": total * 5, "p95": total * 10},
            "pct": [{"account": account, "window": window, "source": "fit", "usd_per_pct": 5.0,
                     "phases": split, "total": {"p50": total / 2, "p80": total, "p95": total * 2}}],
            "calibration": {"fallback": None}}


def test_remaining_is_the_forecast_left_from_the_phase_on():
    f = fc_split(per_phase=2.0, total=8.0)
    # from explore on: 5 × 2 = 10, capped at the whole issue's own p80 of 8
    assert one.remaining(f, "explore")["pct"][0]["total"]["p80"] == 8.0
    # from gate on: gate + ship = 4
    r = one.remaining(f, "gate")
    assert r["pct"][0]["total"]["p80"] == 4.0 and r["total"]["p80"] == 20.0, r
    assert one.remaining(f, "ship")["pct"][0]["total"]["p80"] == 2.0
    assert f["pct"][0]["total"]["p80"] == 8.0, "the forecast itself is untouched"
    # a row with no per-phase split keeps its whole total
    g = fc(6.0)
    assert one.remaining(g, "ship")["pct"][0]["total"]["p80"] == 6.0


def test_phase_check_fits_or_checkpoints():
    f = fc_split(per_phase=2.0, total=8.0)
    # before gate: 92 + 4 left + 2 reserve = 98 = the stop → FITS
    c = one.phase_check(f, [rd(92.0)], "gate", stop=98, reserve=2)
    assert c["verdict"] == "FITS" and c["windows"][0]["need"] == 98.0, c
    # just above → CHECKPOINT, naming the window
    c = one.phase_check(f, [rd(92.5)], "gate", stop=98, reserve=2)
    assert c["verdict"] == "CHECKPOINT" and c["reasons"] == ["main seven_day: 98.5% > 98%"], c
    # the same reading fits later on, with less left: 92.5 + 2 (ship) + 2 = 96.5
    assert one.phase_check(f, [rd(92.5)], "ship", stop=98, reserve=2)["verdict"] == "FITS"
    # any one window over is a checkpoint
    f2 = fc_split(per_phase=2.0, total=8.0)
    f2["pct"].append(dict(fc_split(per_phase=1.0, total=4.0, window="five_hour")["pct"][0]))
    c = one.phase_check(f2, [rd(10.0), rd(95.5, window="five_hour")], "ship", stop=98, reserve=2)
    assert c["verdict"] == "CHECKPOINT" and c["reasons"] == ["main five_hour: 98.5% > 98%"], c
    # a window with no p80 % whose now% + reserve alone is over the stop: CHECKPOINT all the same
    c = one.phase_check(f, [rd(10.0), rd(97.0, window="five_hour")], "ship", stop=98, reserve=2)
    assert c["verdict"] == "CHECKPOINT" and "before any work" in c["reasons"][0], c
    # a stale reading is padded here too: 90 + 3 + 4 + 2 = 99
    c = one.phase_check(f, [rd(90.0, age=None)], "gate", stop=98, reserve=2, stale_pad=3)
    assert c["verdict"] == "CHECKPOINT" and c["windows"][0]["pad"] == 3, c


def test_phase_check_does_not_stop_on_what_it_cannot_measure():
    # no reading, or a window with no p80 %: the gate's DENY, which the human overrode — not a stop
    c = one.phase_check(fc_split(), [], "explore")
    assert c["verdict"] == "FITS" and c["unchecked"], c
    c = one.phase_check(fc(None), [rd(90.0)], "impl")
    assert c["verdict"] == "FITS" and any("no p80" in r for r in c["unchecked"]), c


def test_cli_phase_prints_fits_or_checkpoint():
    with tempfile.TemporaryDirectory() as d:
        fp, rp = os.path.join(d, "f.json"), os.path.join(d, "r.tsv")
        with open(fp, "w") as fh: json.dump(fc_split(), fh)
        cmd = [sys.executable, os.path.join(ROOT, "scripts", "one.py"), "phase", "--phase", "gate",
               "--forecast", fp, "--readings", rp]
        with open(rp, "w") as fh: fh.write("main\tseven_day\t92\t0\t60\n")
        r = subprocess.run(cmd, capture_output=True, text=True)
        assert r.returncode == 0 and "FITS — go on with gate." in r.stdout, r.stdout
        assert "now 92% + p80 4% (fit) + reserve 2% = 98% <= 98%" in r.stdout, r.stdout
        with open(rp, "w") as fh: fh.write("main\tseven_day\t93\t0\t60\n")
        r = subprocess.run(cmd, capture_output=True, text=True)
        assert r.returncode == 1 and "CHECKPOINT — main seven_day: 99% > 98%" in r.stdout, r.stdout
        r = subprocess.run(cmd[:2] + ["phase", "--forecast", fp, "--readings", rp], capture_output=True, text=True)
        assert r.returncode == 2, "phase without --phase is a usage error"


# ── #445: the session's own spend since each reading, and a frozen or dropped reading ──────────────
NOW = 1_800_000_000.0


def frozen(pct=80.0, age=600.0, **kw):
    return dict(rd(pct, age=age), **kw)


def test_phase_check_counts_the_spend_since_a_frozen_reading():
    # A reading frozen at 80% since before the start; per phase 2% left (capped at the 8% total).
    # The re-check must rise with what the account spent since the reading was taken, at $5 per 1%.
    f, spent = fc_split(per_phase=2.0, total=8.0), {"usd": 0.0}
    asked = []
    def spend(account, t0):
        asked.append((account, t0)); return spent["usd"]
    start = {"at": NOW - 300, "readings": [frozen()]}
    check = lambda ph: one.phase_check(f, [frozen()], ph, stop=98, reserve=2, spend=spend, start=start, now=NOW)
    c = check("explore")   # 80 + 0 spent + 8 + 2 = 90
    assert c["verdict"] == "FITS" and c["windows"][0]["need"] == 90.0, c
    assert asked[-1] == ("main", NOW - 600), "spend is counted from the reading's own time"
    spent["usd"] = 30.0     # $30 = 6%: 80 + 6 + 8 (test on: 4 × 2, capped at 8) + 2 = 96
    c = check("test")
    assert c["verdict"] == "FITS" and c["windows"][0]["need"] == 96.0, c
    assert c["windows"][0]["read"] == 80.0 and c["windows"][0]["spent_pct"] == 6.0, c
    spent["usd"] = 55.0     # 11%: 80 + 11 + 4 (gate on) + 2 = 97 — still fits with less left
    assert check("gate")["verdict"] == "FITS"
    spent["usd"] = 72.5     # 14.5%: 80 + 14.5 + 2 (ship) + 2 = 98.5 > 98
    c = check("ship")
    assert c["verdict"] == "CHECKPOINT" and c["reasons"] == ["main seven_day: 98.5% > 98%"], c
    assert "read 80% + 14.5% spent since: $72.5 in transcripts" in one.render_phase(c), one.render_phase(c)
    # the frozen reading alone (no spend counting) would have said FITS — the #445 bug
    assert one.phase_check(f, [frozen()], "ship", stop=98, reserve=2)["verdict"] == "FITS"


def test_phase_check_puts_back_a_window_dropped_after_its_reset():
    # Read at start (90%, resetting at NOW-100); gone from the readings since: it is 0% at its reset
    # plus the spend since then — never an unchecked window.
    f = fc_split(per_phase=2.0, total=8.0)
    start = {"at": NOW - 3600, "readings": [rd(90.0, age=60) | {"resets_at": int(NOW - 100)}]}
    asked = []
    def spend(account, t0):
        asked.append(t0); return 20.0   # 4%
    c = one.phase_check(f, [], "ship", stop=98, reserve=2, spend=spend, start=start, now=NOW)
    w = c["windows"][0]
    assert c["verdict"] == "FITS" and w["restored"] == "reset" and w["now"] == 4.0 and w["need"] == 8.0, c
    assert asked == [NOW - 100], "counted from the reset"
    assert "read 0% at reset + 4% spent since" in one.render_phase(c), one.render_phase(c)
    # a window read at start and gone without a reset is put back as it was read
    start = {"at": NOW - 300, "readings": [rd(95.0, age=60) | {"resets_at": int(NOW + 9999)}]}
    c = one.phase_check(f, [], "ship", stop=98, reserve=2, spend=lambda a, t0: 0.0, start=start, now=NOW)
    assert c["verdict"] == "CHECKPOINT" and c["windows"][0]["now"] == 95.0, c
    # without the snapshot the window is simply unchecked and FITS — what #445 forbids
    assert one.phase_check(f, [], "ship", stop=98, reserve=2)["verdict"] == "FITS"


def test_phase_check_fails_closed_when_spend_cannot_be_counted():
    f = fc_split(per_phase=2.0, total=8.0)
    no_spend = lambda account, t0: None   # no config dir for the account
    start = {"at": NOW - 300, "readings": [frozen(10.0)]}
    # a reading from before the start, its spend uncountable: CHECKPOINT however low it is
    c = one.phase_check(f, [frozen(10.0)], "ship", spend=no_spend, start=start, now=NOW)
    assert c["verdict"] == "CHECKPOINT" and "usage stale" in c["reasons"][0], c
    assert "taken before this session started" in c["reasons"][0], c
    # stale likewise, with no snapshot too; of unknown age when there is a start to measure from
    c = one.phase_check(f, [frozen(10.0, age=31 * 60)], "ship", spend=no_spend, now=NOW)
    assert c["verdict"] == "CHECKPOINT" and "usage stale" in c["reasons"][0], c
    c = one.phase_check(f, [frozen(10.0, age=None)], "ship", spend=no_spend, start=start, now=NOW)
    assert c["verdict"] == "CHECKPOINT" and "of unknown age" in c["reasons"][0], c
    # a HARNESS_ONE_AUTO lane (#392): no snapshot, its lane readings of unknown age — padded, not stopped
    c = one.phase_check(f, [frozen(10.0, age=None)], "ship", spend=no_spend, now=NOW, stale_pad=3)
    assert c["verdict"] == "FITS" and c["windows"][0]["pad"] == 3, c
    # a window dropped after its reset whose spend since cannot be counted: CHECKPOINT, not 0%
    start = {"at": NOW - 3600, "readings": [rd(90.0, age=60) | {"resets_at": int(NOW - 100)}]}
    c = one.phase_check(f, [], "ship", spend=no_spend, start=start, now=NOW)
    assert c["verdict"] == "CHECKPOINT" and "gone since its window reset" in c["reasons"][0], c
    # a fresh reading taken since the start stands on its own
    c = one.phase_check(f, [frozen(10.0, age=60)], "ship", spend=no_spend, start=start, now=NOW)
    assert c["verdict"] == "FITS", c


def _msg(mid, ts, output, model="claude-opus-5-5"):
    return json.dumps({"type": "assistant", "timestamp": ts, "requestId": "r" + mid,
                       "message": {"id": mid, "model": model, "usage": {"output_tokens": output}}}) + "\n"


def test_account_spend_since_reads_the_accounts_transcripts():
    import time as _t
    with tempfile.TemporaryDirectory() as d:
        main, other = os.path.join(d, "accounts", "main"), os.path.join(d, "accounts", "alt")
        proj = os.path.join(main, "projects", "-work")
        os.makedirs(os.path.join(proj, "s1", "subagents")); os.makedirs(os.path.join(other, "projects", "-w"))
        t0 = _t.time() - 600
        iso = lambda t: _t.strftime("%Y-%m-%dT%H:%M:%SZ", _t.gmtime(t))
        with open(os.path.join(proj, "s1.jsonl"), "w") as fh:
            fh.write(_msg("old", iso(t0 - 60), 4_000_000))   # before t0: not counted
            fh.write(_msg("m1", iso(t0 + 60), 400_000))      # $10 at opus output $25/Mtok
            fh.write(_msg("m1", iso(t0 + 60), 400_000))      # the same message streamed again: once
        with open(os.path.join(proj, "s1", "subagents", "agent-a.jsonl"), "w") as fh:
            fh.write(_msg("m2", iso(t0 + 120), 200_000))     # a sub-agent's: $5
        with open(os.path.join(other, "projects", "-w", "s2.jsonl"), "w") as fh:
            fh.write(_msg("m3", iso(t0 + 60), 4_000_000))    # another account's
        old = os.environ.get("HARNESS_CLAUDE_CONFIG_DIRS")
        os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = os.pathsep.join([main, other])
        try:
            assert round(one.account_spend_since("main", t0), 2) == 15.0
            assert one.account_spend_since("nobody", t0) is None, "no config dir: not countable"
            assert one.account_spend_since("main", _t.time() + 60) == 0.0
        finally:
            if old is None: os.environ.pop("HARNESS_CLAUDE_CONFIG_DIRS")
            else: os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = old


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

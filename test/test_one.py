"""test_one.py — #365: the /harness-one gate thresholds. APPROVE iff now% + p80% + reserve <= stop for
every window — exactly at the boundary approves, just above denies — honouring the stop % and the
reserve; a stale reading is padded; a window with no p80 %, no reading, or no history denies. Then
the one.py CLI on a forecast forecast.py itself built."""
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


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

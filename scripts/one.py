#!/usr/bin/env python3
"""one.py — `harness one gate`: the /harness-one budget gate (#365, PRD #362).

Given the issue's forecast (`harness forecast --json`, #363/#364) and the freshest usage readings
(`cli_limit_usage`, one per account/window, with the reading's age when known), recommend

    APPROVE  iff, for every window read:  now% + p80% + reserve% <= stop%
    DENY     otherwise

now% is the reading, padded by `stale_pad` percentage points when it is older than `stale_min`
minutes or its age is unknown (a stale reading under-states what the window has used since).
p80% is the forecast's p80 total as % of that window: its account/window row, else the account's
row, else the account-less row, else the forecast's p80 $ over HARNESS_ONE_USD_PER_PCT. A window
with no p80%, no readings at all, or a forecast with no history is a DENY: the gate cannot show
the work fits. The recommendation is only that — the human decides (skill/harness-one).

    one.py gate --forecast F.json --readings R.tsv [--stop 98] [--reserve 2]
                [--stale-min 30] [--stale-pad 3] [--json]
    one.py phase --phase <explore|test|impl|gate|ship> --forecast F.json --readings R.tsv […]

`phase` (#366) is the re-check before each phase of an approved issue: the same arithmetic on the
forecast LEFT from that phase on (remaining), FITS (exit 0) or CHECKPOINT (exit 1) — see phase_check.

R.tsv lines: `<account>\t<window>\t<pct>\t<resets_at>\t<age seconds, empty = unknown>`.
Text output is the forecast, then the arithmetic; --json is the gate dict with the forecast under
"forecast". Exit status: 0 APPROVE, 1 DENY, 2 bad input.
"""
import importlib.util, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _forecast():
    spec = importlib.util.spec_from_file_location("forecast", os.path.join(HERE, "forecast.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def parse_readings(text):
    """[{account, window, pct, resets_at, age}] from the readings TSV; malformed lines are skipped."""
    out = []
    for line in (text or "").splitlines():
        cols = line.split("\t")
        if len(cols) < 3 or not cols[0] or _num(cols[2]) is None:
            continue
        age = _num(cols[4]) if len(cols) > 4 and cols[4] != "" else None
        out.append({"account": cols[0], "window": cols[1], "pct": _num(cols[2]),
                    "resets_at": int(_num(cols[3]) or 0) if len(cols) > 3 else 0, "age": age})
    return out


def _norm(a):
    """forecast.py names an account after its Claude config dir — "default" when none is set."""
    a = str(a or "")
    return "default" if a in ("", ".claude") else a


def p80_pct(fc, account, window):
    """(p80 % of this window, where it came from) from the forecast, or (None, why)."""
    rows = fc.get("pct") or []
    acct = _norm(account)
    for want in ((acct, window), (acct, None), (None, None)):
        for r in rows:
            key = (None if r.get("account") is None else _norm(r["account"]), r.get("window"))
            if key == want and (r.get("total") or {}).get("p80") is not None:
                src = "fit" if r.get("source") == "fit" else "fallback"
                return float(r["total"]["p80"]), src
    usd = ((fc.get("calibration") or {}).get("fallback"))
    p80 = (fc.get("total") or {}).get("p80")
    if usd and p80 is not None:
        return round(float(p80) / float(usd), 2), "fallback"
    return None, "no $-per-% calibration and HARNESS_ONE_USD_PER_PCT unset"


def gate(fc, readings, stop=98.0, reserve=2.0, stale_min=30.0, stale_pad=3.0):
    """The recommendation dict: {verdict, stop, reserve, windows [{account, window, now, age, pad,
    p80, p80_source, need, ok}], reasons}. `need` is rounded to 2 places before it is compared, so
    a sum that lands on the stop % is exactly at the boundary (APPROVE)."""
    windows, reasons = [], []
    tier = (fc.get("basis") or {}).get("tier")
    if tier == "none":
        reasons.append("no past lanes on this host to forecast from")
    if not readings:
        reasons.append("no usage reading (cli_limit_usage reports none)")
    for r in readings:
        stale = r["age"] is None or r["age"] > stale_min * 60
        pad = stale_pad if stale else 0.0
        p80, src = p80_pct(fc, r["account"], r["window"])
        need = None if p80 is None else round(r["pct"] + pad + p80 + reserve, 2)
        ok = need is not None and need <= stop
        windows.append({"account": r["account"], "window": r["window"], "now": r["pct"], "age": r["age"],
                        "pad": pad, "p80": p80, "p80_source": src, "need": need, "ok": ok})
        name = f"{r['account']} {r['window']}".strip()
        if need is None:
            reasons.append(f"{name}: no p80 % ({src})")
        elif not ok:
            reasons.append(f"{name}: {need:g}% > {stop:g}%")
    verdict = "APPROVE" if windows and not reasons else "DENY"
    return {"issue": fc.get("issue"), "repo": fc.get("repo"), "verdict": verdict, "stop": stop,
            "reserve": reserve, "stale_min": stale_min, "stale_pad": stale_pad, "windows": windows,
            "reasons": reasons}


def remaining(fc, phase):
    """`fc` cut to the work left from `phase` on (#366): every total — the $ one and each window's %
    row — becomes, per quantile, the sum of that quantile over `phase` .. ship, never above the
    whole issue's own (a sum of per-phase p80s over-states the p80 of their sum). A row with no
    per-phase split keeps its whole total, the conservative answer."""
    phases = _forecast().PHASES
    rest = phases[phases.index(phase):]

    def cut(split, total):
        if not total or not split or any(not split.get(p) for p in rest):
            return total
        return {q: round(min(sum(split[p][q] for p in rest), v), 2) for q, v in total.items()}

    out = dict(fc, total=cut(fc.get("phases"), fc.get("total")), phase=phase)
    if fc.get("pct"):
        out["pct"] = [dict(r, total=cut(r.get("phases"), r.get("total"))) for r in fc["pct"]]
    return out


def phase_check(fc, readings, phase, stop=98.0, reserve=2.0, stale_min=30.0, stale_pad=3.0):
    """The per-phase re-check before `phase` (#366): the gate's arithmetic on the forecast LEFT
    (remaining) — now% + remaining p80% + reserve vs stop — for every window read. The verdict is
    CHECKPOINT iff some window's sum is over the stop %, else FITS. What the check cannot price
    (no reading, a window with no p80 %) does not stop the work on its own — the gate recommended
    DENY on that and the human approved anyway — but a window whose now% + reserve alone is over the
    stop % is a CHECKPOINT whatever the work left would cost."""
    g = gate(remaining(fc, phase), readings, stop, reserve, stale_min, stale_pad)
    over, unchecked = [], []
    for w in g["windows"]:
        name = f"{w['account']} {w['window']}".strip()
        if w["need"] is None:
            floor = round(w["now"] + w["pad"] + reserve, 2)
            if floor > stop:
                over.append(f"{name}: {floor:g}% > {stop:g}% before any work (no p80 %)")
            else:
                unchecked.append(f"{name}: no p80 % ({w['p80_source']})")
        elif not w["ok"]:
            over.append(f"{name}: {w['need']:g}% > {stop:g}%")
    unchecked += [r for r in g["reasons"] if not r.startswith(tuple(
        f"{w['account']} {w['window']}".strip() + ":" for w in g["windows"]))]
    return dict(g, phase=phase, verdict="CHECKPOINT" if over else "FITS", reasons=over, unchecked=unchecked)


def _age(s):
    if s is None:
        return "age unknown"
    return f"{int(s // 60)}m old"


def render(g):
    """The arithmetic, one line per window, then the recommendation."""
    out = [f"gate #{g['issue']}: APPROVE iff now% + p80% + reserve {g['reserve']:g}% <= "
           f"stop {g['stop']:g}% (HARNESS_ONE_STOP_PCT / HARNESS_ONE_RESERVE_PCT), for every window"]
    for w in g["windows"]:
        name = f"{w['account']} {w['window']}".strip()
        now = f"{w['now']:g}%"
        if w["pad"]:
            now += f" + {w['pad']:g} stale pad ({_age(w['age'])}, > {g['stale_min']:g}m)"
        if w["need"] is None:
            out.append(f"  {name}: now {now} + p80 n/a ({w['p80_source']}) — cannot show it fits")
            continue
        mark = "<=" if w["ok"] else ">"
        out.append(f"  {name}: now {now} + p80 {w['p80']:g}% ({w['p80_source']}) + reserve {g['reserve']:g}%"
                   f" = {w['need']:g}% {mark} {g['stop']:g}%  {'ok' if w['ok'] else 'OVER'}")
    if not g["windows"]:
        out.append("  no usage window to check")
    line = f"RECOMMEND: {g['verdict']}"
    if g["reasons"]:
        line += " — " + "; ".join(g["reasons"])
    out.append(line)
    out.append("The human decides: approve / pick another issue / stop. Nothing runs until approved.")
    return "\n".join(out)


def render_phase(g):
    """The re-check before one phase: the arithmetic on what is left, then FITS or CHECKPOINT."""
    lines = render(dict(g, reasons=[])).splitlines()[1:-2]   # the per-window lines only
    out = [f"phase {g['phase']} of #{g['issue']}: CHECKPOINT iff now% + remaining p80% (from {g['phase']} on)"
           f" + reserve {g['reserve']:g}% > stop {g['stop']:g}% in any window"] + lines
    for r in g["unchecked"]:
        out.append(f"  unchecked: {r}")
    if g["verdict"] == "FITS":
        out.append(f"FITS — go on with {g['phase']}.")
    else:
        out.append("CHECKPOINT — " + "; ".join(g["reasons"]))
    return "\n".join(out)


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(prog="harness one gate", description="the /harness-one budget gate (#365)")
    ap.add_argument("cmd", choices=["gate", "phase"])
    ap.add_argument("--phase", choices=_forecast().PHASES, help="phase: the phase about to start")
    ap.add_argument("--forecast", required=True, help="harness forecast --json output")
    ap.add_argument("--readings", required=True, help="usage readings TSV")
    ap.add_argument("--stop", type=float, default=98.0)
    ap.add_argument("--reserve", type=float, default=2.0)
    ap.add_argument("--stale-min", type=float, default=30.0)
    ap.add_argument("--stale-pad", type=float, default=3.0)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        with open(a.forecast) as fh:
            fc = json.load(fh)
        with open(a.readings) as fh:
            readings = parse_readings(fh.read())
    except (OSError, ValueError) as e:
        print(f"harness one: cannot read the forecast or the readings: {e}", file=sys.stderr)
        return 2
    if a.cmd == "phase":
        if not a.phase:
            print("harness one phase: --phase is required", file=sys.stderr)
            return 2
        g = phase_check(fc, readings, a.phase, a.stop, a.reserve, a.stale_min, a.stale_pad)
        print(json.dumps(g, indent=2) if a.json else render_phase(g))
        return 0 if g["verdict"] == "FITS" else 1
    g = gate(fc, readings, a.stop, a.reserve, a.stale_min, a.stale_pad)
    if a.json:
        print(json.dumps(dict(g, forecast=fc), indent=2))
    else:   # the forecast first, then the arithmetic on it
        print(_forecast().render(fc) + "\n" + render(g))
    return 0 if g["verdict"] == "APPROVE" else 1


if __name__ == "__main__":
    sys.exit(main())

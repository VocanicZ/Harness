import re, sys, json
logs = json.load(open(sys.argv[1]))     # {"SUP":..., "OPS":..., "INJ":..., "LIVE":..., "TOOL":..., "LIFE":..., "SUITE":..., "CLI_*": ...}
p = "docs/reference.md"
s = open(p, encoding="utf-8").read()
def L(k): return "`test/smoke/logs/%s`" % logs[k]
rows = {
 "harness release": "✓ (`harness release --dry-run` in a checkout, `test/test_release.sh`; winsma run: %s)" % L("OPS"),
 "harness poll": "✓ (`harness poll --once` and `--status`, `test/test_poller.sh`; winsma run: %s)" % L("OPS"),
 "harness stats": "✓ (text, `--json`, `--issue`; `test/test_stats.py`; winsma run: %s, and on the real lane of the live smoke: %s)" % (L("OPS"), L("LIVE")),
 "harness forecast": "✓ (`test/test_forecast.py`; winsma run on fixture lanes with transcripts: %s, and on the live lane: %s)" % (L("OPS"), L("LIVE")),
 "harness supervise": "✓ (a killed worker is restarted by the supervisor; `test/test_supervise_headless.sh`; winsma run: %s)" % L("SUP"),
 "harness web": "✓ (the dashboard answers on a private port, `/`, `/api/host`, a 404; `test/test_web.py`; winsma run: %s)" % L("OPS"),
 "harness status": "✓ (`status` and `status --all`; `test/test_status.sh`; winsma run: %s, and the live smoke: %s)" % (L("OPS"), L("LIVE")),
 "harness one": "✓ (`one check` refuses a running fleet and passes a paused one, `one gate` prints its verdict; `test/test_one.sh`; winsma run: %s)" % L("OPS"),
 "harness setup": "✓ (`test/test_setup.sh`; winsma runs: the live smoke %s, which runs `harness setup`, and `test/smoke/logs/windows-installer-windows-20261104T041438Z.log`)" % L("LIVE"),
 "harness migrate": "✓ (`test/test_migrate.sh`; winsma run: %s)" % L("OPS"),
 "harness plan": "✓ (`harness plan` launches the injector lane; `test/test_inject.sh`; winsma run: %s)" % L("OPS"),
 "harness prd": "✓ (`harness prd` launches the injector lane; `test/test_inject.sh`; winsma run: %s)" % L("OPS"),
 "harness issue": "✓ (`harness issue` launches the injector lane; `test/test_inject.sh`; winsma run: %s)" % L("OPS"),
 "/harness-arc": "✓ (linked into the Windows skills dir; `test/test_operator_skills.sh`; winsma run: %s)" % L("TOOL"),
 "/harness-issue": "✓ (linked into the Windows skills dir; `test/test_operator_skills.sh`; winsma run: %s)" % L("TOOL"),
 "/harness-one": "✓ (linked into the Windows skills dir; `test/test_operator_skills.sh`; winsma run: %s)" % L("TOOL"),
 "/harness-plan": "✓ (linked into the Windows skills dir; `test/test_operator_skills.sh`; winsma run: %s)" % L("TOOL"),
 "/harness-prd": "✓ (linked into the Windows skills dir; `test/test_operator_skills.sh`; winsma run: %s)" % L("TOOL"),
 "/harness-status": "✓ (linked into the Windows skills dir; `test/test_operator_skills.sh`; winsma run: %s)" % L("TOOL"),
 "harness-one": "✓ (the `one` verbs above; `test/test_one_run.sh`; winsma run: %s)" % L("OPS"),
 "inject": "✓ (`plan`, `prd` and `issue` each launch the injector lane on a stand-in `claude`; `test/test_inject.sh`; winsma run: %s)" % L("OPS"),
}
for name, val in rows.items():
    pat = re.compile(r"^(\| `%s` \| ✓ \| )✓ target \(#475 task [0-9]+\) \|$" % re.escape(name), re.M)
    s, n = pat.subn(lambda m: m.group(1) + val + " |", s)
    if n != 1: sys.exit("row not flipped exactly once: %s (%d)" % (name, n))
open(p, "w", encoding="utf-8").write(s)
print("flipped", len(rows))

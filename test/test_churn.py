"""test_churn.py — #545: the crash-loop guard's detection, evidence and status over a fixture event log.
No network, no live gh, no tmux: events are built in memory, transcripts are fixture files found
through HARNESS_CLAUDE_CONFIG_DIRS."""
import importlib.util, json, os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
CHURN_PY = os.path.join(ROOT, "scripts", "churn.py")
spec = importlib.util.spec_from_file_location("churn", CHURN_PY)
ch = importlib.util.module_from_spec(spec); spec.loader.exec_module(ch)

FAILS = []
RUN = 0


def check(cond, msg):
    global RUN
    RUN += 1
    if cond:
        print(f"  ok: {msg}")
    else:
        print(f"  FAIL: {msg}")
        FAILS.append(msg)


def iso(t):
    return ch.stats.now_iso(t)


T0 = 1_793_000_000   # 2026-10-27 — only the spacing matters


def end(i, at_min, wall=300, unit="harness", kind="bug-fix", issue=541, repo="acme/widget", **kw):
    """A session_end that finished at_min minutes after T0."""
    e = {"ts": iso(T0 + at_min * 60), "event": "session_end", "prefix": "hz", "repo": repo, "unit": unit,
         "issue": issue, "kind": kind, "session": f"sess-{issue}-{i}", "wall_s": wall}
    e.update(kw)
    return e


def trips(events, **kw):
    return [(t[2], t[3]) for t in ch.replay(events, **kw)]


print("=== detection ===")
three = [end(1, 0, unit="harness"), end(2, 20, unit="priority-P1"), end(3, 40, unit="harness")]
check(trips(three) == [(541, "bug-fix")], "3 short sessions across pool + priority lanes trip once")
check(len(ch.find_churn(three, "acme/widget", 541, "bug-fix", "sess-541-3")) == 3, "find_churn returns all three")
check(ch.find_churn(three, "ACME/Widget", 541, "bug-fix") != [], "repo match ignores case")

print("=== no false trips ===")
check(trips(three[:2]) == [], "2 short sessions do not trip")
check(trips([end(1, 0), end(2, 100), end(3, 200)]) == [], "3 short sessions spread over more than the window do not trip")
check(trips([end(1, 0), end(2, 20), end(3, 40, wall=900)]) == [], "wall_s equal to the max is not short")
check(trips([end(1, 0), end(2, 20, wall=5000), end(3, 40)]) == [], "a long session in the middle is not counted")
check(trips([end(1, 0, kind="bug-triage"), end(2, 20), end(3, 40)]) == [], "a short triage is not counted towards fix sessions")
check(trips([end(1, 0), end(2, 20), end(3, 40, issue=7)]) == [], "another issue does not count")
check(trips([end(1, 0), end(2, 20), end(3, 40, repo="acme/other")]) == [], "another repo does not count")
check(trips([end(1, 0), end(2, 20), end(3, 40, checkpointed=1)]) == [], "a checkpointed session does not count")
for ev in ("watchdog_kill", "checkpoint", "paused"):
    log = three + [{"ts": iso(T0 + 19 * 60), "event": ev, "session": "sess-541-2", "issue": 541}]
    check(trips(log) == [], f"a session with a {ev} event does not count")
check(trips([end(1, 0, wall=None), end(2, 20), end(3, 40)]) == [], "a session_end without wall_s does not count")
check(trips(three, count=0) == [], "COUNT=0 never trips")
check(trips(three, count=4) == [], "COUNT=4 needs four")
check(trips(three, max_wall=200) == [], "a lower MAX_WALL_S excludes the 300s sessions")
check(trips([end(1, 0), end(2, 20), end(3, 40)], window_min=30) == [], "a shorter window excludes spread sessions")
check(ch.find_churn(three, "acme/widget", 541, "bug-fix", "sess-541-9") == [], "the check must include the session being reaped")

print("=== env knobs ===")
os.environ["HARNESS_CHURN_COUNT"] = "2"
check(trips(three[:2]) == [(541, "bug-fix")], "HARNESS_CHURN_COUNT=2 trips on two")
os.environ["HARNESS_CHURN_COUNT"] = "0"
check(trips(three) == [], "HARNESS_CHURN_COUNT=0 is off")
del os.environ["HARNESS_CHURN_COUNT"]

print("=== counter reset ===")
log = three + [{"ts": iso(T0 + 41 * 60), "event": "churn", "repo": "acme/widget", "issue": 541, "kind": "bug-fix"}]
check(ch.find_churn(log + [end(4, 60)], "acme/widget", 541, "bug-fix", "sess-541-4") == [],
      "after a park the first short session does not re-trip")
log2 = log + [end(4, 60), end(5, 70), end(6, 80)]
check(len(ch.find_churn(log2, "acme/widget", 541, "bug-fix", "sess-541-6")) == 3, "three new short sessions trip again")
# a session launched before the trip but ending after it does not count
late = end(7, 50, wall=3000 // 10)   # started at min 45 (ts - wall), after the trip at 41 — counts
early = end(8, 45, wall=290)         # started at min 40.2, before the trip — does not
check(ch.find_churn(log + [early], "acme/widget", 541, "bug-fix") == [], "a session launched before the trip is not counted after it")

print("=== replay of the 11-05 shape ===")
inc = []
for i, (m, wall, unit) in enumerate([(24, 216, "harness"), (51, 608, "priority-P1"), (70, 792, "harness"),
                                     (93, 300, "priority-P1")]):
    inc.append(end(i, m, wall=wall, unit=unit, issue=541, repo="VocanicZ/Harness"))
for i, (m, wall, unit) in enumerate([(0, 279, "harness"), (24, 255, "priority-P1"), (51, 653, "harness")]):
    inc.append(end(i, m, wall=wall, unit=unit, issue=543, repo="VocanicZ/Harness"))
inc.append(end(1, 0, issue=99, repo="VocanicZ/Harness", wall=4000))
got = sorted(ch.replay(inc), key=lambda t: t[2])
check([(g[2], g[3]) for g in got] == [(541, "bug-fix"), (543, "bug-fix")], "replay trips #541 and #543 only")
check(len(ch.replay(inc)) == 2, "replay trips each once, then resets")
fine = [end(1, 0, issue=1), end(2, 300, issue=1), end(3, 600, issue=1), end(4, 0, issue=2, wall=2000),
        end(5, 5, issue=2, wall=2000), end(6, 10, issue=2, wall=2000)]
check(ch.replay(fine) == [], "a log of only passing cases trips nothing")

print("=== evidence ===")
tmp = tempfile.mkdtemp()
cfg = os.path.join(tmp, "cfg"); proj = os.path.join(cfg, "projects", "p"); os.makedirs(proj)
os.environ["HARNESS_CLAUDE_CONFIG_DIRS"] = cfg
os.environ["HARNESS_HEADLESS_DIR"] = os.path.join(tmp, "lanes")


def tool(i, name, inp):
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": f"t{i}", "name": name, "input": inp}]}}


def result(i, text):
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": f"t{i}", "content": text}]}}


with open(os.path.join(proj, "sess-541-1.jsonl"), "w") as f:
    lines = []
    for i in range(8):
        lines.append(tool(i, "Bash", {"command": f"echo step{i}"}))
        lines.append(result(i, f"out{i}"))
    lines.append(tool(8, "Bash", {"command": "GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789 bash test/test_hermetic.sh"}))
    lines.append(result(8, "Exit code 137\nHOME=/home/x\nSECRET_KEY=hunter2hunter2\nAuthorization: Bearer abcdefghijklmnop12345"))
    f.write("\n".join(json.dumps(x) for x in lines) + "\n")
with open(os.path.join(proj, "sess-541-2.jsonl"), "w") as f:
    f.write(json.dumps(tool(0, "Read", {"file_path": "scripts/lib.sh"})) + "\n" + json.dumps(result(0, "ok")) + "\n")
body = ch.evidence(three, "acme/widget", 541, "bug-fix", ["sess-541-1", "sess-541-2", "sess-541-3"])
check(body.startswith("<!-- harness-churn issue=541 -->\n"), "the comment starts with the marker line")
check("| 300 | harness |" in body and "| 300 | priority-P1 |" in body, "each counted session has its wall_s and lane row")
check("Exit code 137" in body and "SIGKILL (137)" in body, "Exit code 137 is called out as SIGKILL")
check("echo step7" in body and "echo step4" in body and "echo step3" not in body, "only the last five tool calls are shown")
check("ghp_abcdef" not in body and "hunter2" not in body and "abcdefghijklmnop12345" not in body, "tokens and secrets are redacted")
check("HOME=/home/x" not in body, "env lines are redacted")
check("no transcript" in body, "a session without a transcript still gets its row, marked no transcript")
check("sess-541-2" not in body.split("### session")[-1] or "scripts/lib.sh" in body, "a second transcript is read too")
check("SIGKILL (137)" not in ch.evidence(three, "acme/widget", 541, "bug-fix", ["sess-541-2"]), "no 137 → no SIGKILL note")
check(ch.redact("x GITHUB_TOKEN=abc123 y") == "x GITHUB_TOKEN=[REDACTED] y", "redact keeps the name, drops the value")

print("=== cli ===")
evf = os.path.join(tmp, "events.jsonl")
with open(evf, "w") as f:
    f.write("\n".join(json.dumps(x) for x in three) + "\n")
base = [sys.executable, "-I", CHURN_PY]
r = subprocess.run(base + ["check", "--repo", "acme/widget", "--issue", "541", "--kind", "bug-fix", "--session", "sess-541-3", "--events", evf],
                   capture_output=True, text=True)
check(r.returncode == 0 and json.loads(r.stdout)["sessions"] == ["sess-541-1", "sess-541-2", "sess-541-3"], "check prints the counted sessions and exits 0")
r = subprocess.run(base + ["check", "--repo", "acme/widget", "--issue", "541", "--kind", "bug-fix", "--session", "sess-541-2", "--events", evf],
                   capture_output=True, text=True)
check(r.returncode == 0, "the newest qualifying session anchors the window")
r = subprocess.run(base + ["check", "--repo", "acme/widget", "--issue", "9", "--kind", "bug-fix", "--session", "x", "--events", evf],
                   capture_output=True, text=True)
check(r.returncode == 1 and r.stdout == "", "no trip exits 1 with nothing on stdout")
env = dict(os.environ, HARNESS_CHURN_COUNT="0")
r = subprocess.run(base + ["check", "--repo", "acme/widget", "--issue", "541", "--kind", "bug-fix", "--session", "sess-541-3", "--events", evf],
                   capture_output=True, text=True, env=env)
check(r.returncode == 1, "COUNT=0 in the environment turns the cli off")
r = subprocess.run(base + ["replay", "--events", evf], capture_output=True, text=True)
check("acme/widget#541" in r.stdout, "replay names the tripped issue")

print("=== status rows ===")
st = three + [{"ts": iso(T0 + 41 * 60), "event": "churn", "prefix": "hz", "repo": "acme/widget", "issue": 541,
               "kind": "bug-fix", "count": 3, "window_min": 180, "sessions": "a,b,c"}]
rows = ch.parked_rows(st, "hz")
check([(r["repo"], r["issue"]) for r in rows] == [("acme/widget", 541)], "a churn-parked issue of the fleet is listed")
check(ch.parked_rows(st, "other") == [], "another fleet's park is not listed")
check("acme/widget#541" in ch.row_line(rows[0]) and "parked" in ch.row_line(rows[0]), "the line names the issue")
check(ch.parked_rows(st + [{"ts": iso(T0 + 90 * 60), "event": "launch", "prefix": "hz", "repo": "acme/widget", "issue": 541,
                            "kind": "bug-fix"}], "hz") == [], "a relaunch after the park lifts clears the row")

print("=== dashboard ===")
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import web_data, web_render  # noqa: E402
check(web_data.churn_parked(st, "hz") == rows, "web_data lists the same churn-parked issues as status")
banner = web_render._churn_banner(rows)
check('data-churn-banner="1"' in banner and "acme/widget#541" in banner, "the fleet page shows a banner naming the issue")
check(web_render._churn_banner([]) == "" and web_render._churn_banner(None) == "", "no banner without a parked issue")

shutil.rmtree(tmp, ignore_errors=True)
print(f"── {RUN - len(FAILS)}/{RUN} passed")
sys.exit(1 if FAILS else 0)

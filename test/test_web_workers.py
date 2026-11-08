#!/usr/bin/env python3
"""test_web_workers.py — #472: the fleet page lists the fleet's workers and the issue each one runs
(`worker-N → #<issue> <session> <state>`, or idle) — no unit layer. POOL=3, two live claimed lanes,
one idle worker."""
import json, os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf


def _sleeper():
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    wf.live_pid(p.pid)      # on Windows MSYS must know the pid the fleet records for it (pidfix.py)
    return p


def _workers_fleet(host, procs):
    """Fleet `wk`: POOL=3, three live worker pids, worker 1 on issue 7 and worker 2 on PRD action 41."""
    state = host.add_fleet("wk", ["o/arc"], ': "${HARNESS_POOL:=3}"\n', alive=False)
    run = os.path.join(state, "run")
    os.makedirs(os.path.join(run, "claims"), exist_ok=True)
    for n, p in enumerate(procs, 1):
        with open(os.path.join(run, f"worker-{n}.pid"), "w") as fh:
            fh.write(str(p.pid))
    for key, line in (("impl-7", f"1 {procs[0].pid} IMPL:7 wk-main-i7 -\n"),
                      ("orch-41", f"2 {procs[1].pid} DECOMPOSE:41 wk-main-p41 -\n")):
        with open(os.path.join(run, "claims", key + ".claim"), "w") as fh:
            fh.write(line)


def test_fleet_page_lists_workers_with_their_issues():
    procs = [_sleeper() for _ in range(3)]
    try:
        with wf.serving(tmux_ls="wk-main-i7 1799999000\nwk-main-p41 1799999100\n") as (base, host):
            _workers_fleet(host, procs)
            view = host.model.fleet_page("wk")
            ws = view["workers"]
            assert [w["worker"] for w in ws] == [1, 2, 3], ws
            assert [(w["issue"], w["session"]) for w in ws] == [(7, "wk-main-i7"), (41, "wk-main-p41"), (None, None)], ws
            assert [w["up"] for w in ws] == [True, True, True], ws
            code, html = wf.get(base + "/fleet/wk")
            assert code == 200
            rows = re.findall(r'<li[^>]*data-worker="(\d+)"[^>]*>(.*?)</li>', html, re.S)
            text = {n: re.sub(r"<[^>]+>", " ", body) for n, body in rows}
            text = {n: re.sub(r"\s+", " ", t).strip() for n, t in text.items()}
            assert sorted(text) == ["1", "2", "3"], text
            assert re.search(r"worker-1 → #7 wk-main-i7 \S+", text["1"]), text
            assert re.search(r"worker-2 → #41 wk-main-p41 \S+", text["2"]), text
            assert text["3"].endswith("idle"), text
            assert sum("idle" in t for t in text.values()) == 1, text
            assert "units:" not in html and "driving unit" not in html
    finally:
        for p in procs:
            p.kill(); p.wait()


def test_dead_claim_is_not_a_worker_assignment():
    """A claim whose pid is gone is a stale lock (web_data.stale_locks), not what the worker is running."""
    dead = wf.dead_pid()
    with wf.serving() as (base, host):
        state = host.add_fleet("wk", ["o/arc"], ': "${HARNESS_POOL:=1}"\n', alive=True)
        run = os.path.join(state, "run")
        os.makedirs(os.path.join(run, "claims"), exist_ok=True)
        with open(os.path.join(run, "claims", "impl-9.claim"), "w") as fh:
            fh.write(f"1 {dead} IMPL:9 wk-main-i9 -\n")
        ws = host.model.fleet_page("wk")["workers"]
        assert len(ws) == 1 and ws[0]["issue"] is None, ws


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

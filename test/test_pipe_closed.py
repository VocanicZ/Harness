"""test_pipe_closed.py — #713: forecast.py, tier.py and bench/run.py end quietly when the reader closes stdout
early (`cmd | true`): no "Exception ignored on flushing sys.stdout: BrokenPipeError" on stderr, exit 0 (or 141).
The reader's end is closed before the child starts, so its first write or its exit-time flush has no reader —
the same as `| true`, without the race. scripts/pipesafe.py is the shared helper; stats.py's own is #671."""
import importlib.util, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)


def _load(name):
    spec = importlib.util.spec_from_file_location("t_" + name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod


def into_true(argv, env=None):
    """Run argv with its stdout pipe already closed on the reader's side; (returncode, stderr)."""
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    p.stdout.close()
    err = p.stderr.read().decode()
    return p.wait(), err


def quiet(argv, env=None):
    rc, err = into_true(argv, env)
    assert err == "" and rc in (0, 141), (argv, rc, err)


def test_forecast_text_and_json_into_a_closed_pipe_are_quiet():
    tf = _load("test_forecast")
    with tf.tmp() as d:
        cfg, events, bodies = tf.fixture(d)
        env = dict(os.environ, HARNESS_CLAUDE_CONFIG_DIRS=cfg, STATE_DIR=os.path.join(d, "none"))
        base = ["50", "-R", tf.W, "--events", events, "--bodies", bodies]
        for extra in ([], ["--json"]):
            quiet([sys.executable, os.path.join(ROOT, "scripts", "forecast.py")] + base + extra, env)
            quiet(["bash", os.path.join(ROOT, "bin", "harness"), "forecast"] + base + extra, env)


def test_tier_decide_and_thresholds_into_a_closed_pipe_are_quiet():
    tier = os.path.join(ROOT, "scripts", "tier.py")
    decide = ["decide", "--criteria", "3", "--lines", "80", "--files", "3", "--subsystems", "1"]
    for args in (decide, decide + ["--json"], ["thresholds"]):
        quiet([sys.executable, tier] + args)
    quiet(["bash", os.path.join(ROOT, "bin", "harness"), "tier"] + decide)


def test_bench_dry_run_into_a_closed_pipe_is_quiet():
    tb = _load("test_bench_run")
    e = tb.Env()
    try:
        argv = [sys.executable, tb.RUN, "stub", "--dry-run", "--results-dir", e.results, "--run-dir", e.rundir,
                "--events", os.path.join(e.d, "no-events.jsonl"), "--runs", "1"]
        quiet(argv, e.env)
    finally:
        e.close()


def test_help_into_a_closed_pipe_is_quiet_and_exits_0():
    """#783: argparse prints --help and exits inside parse_args, before pipesafe's flush guard used to see it."""
    py = sys.executable
    cmds = [[py, os.path.join(ROOT, "scripts", "stats.py"), "--help"],
            [py, os.path.join(ROOT, "scripts", "stats.py"), "report", "--help"],
            [py, os.path.join(ROOT, "scripts", "forecast.py"), "--help"],
            [py, os.path.join(ROOT, "scripts", "tier.py"), "--help"],
            [py, os.path.join(ROOT, "scripts", "tier.py"), "decide", "--help"],
            [py, os.path.join(ROOT, "bench", "run.py"), "--help"],
            ["bash", os.path.join(ROOT, "bin", "harness"), "stats", "--help"],
            ["bash", os.path.join(ROOT, "bin", "harness"), "tier", "decide", "--help"]]
    for argv in cmds:
        rc, err = into_true(argv)
        assert err == "" and rc == 0, (argv, rc, err)


def closed_stdout(argv, env=None):
    """Run argv with standard output CLOSED (`>&-`), so sys.stdout is None; (returncode, stderr)."""
    r = subprocess.run(["bash", "-c", '"$@" >&-', "_"] + argv, stdin=subprocess.DEVNULL,
                       stderr=subprocess.PIPE, env=env)
    return r.returncode, r.stderr.decode()


def test_closed_stdout_is_quiet_for_stats_tier_and_forecast():
    """#806: `>&-` leaves sys.stdout None; flush() raised AttributeError and a traceback, exit 1. Now: no
    traceback, the status main returned (0)."""
    import tempfile
    py = sys.executable
    with tempfile.TemporaryDirectory() as d:
        events = os.path.join(d, "events.jsonl")
        open(events, "w").close()
        decide = ["decide", "--criteria", "3", "--lines", "80", "--files", "3", "--subsystems", "1"]
        cmds = [[py, os.path.join(ROOT, "scripts", "stats.py"), "report", "--events", events],
                [py, os.path.join(ROOT, "scripts", "stats.py"), "report", "--events", events, "--json"],
                [py, os.path.join(ROOT, "scripts", "tier.py"), "thresholds"],
                [py, os.path.join(ROOT, "scripts", "tier.py")] + decide,
                ["bash", os.path.join(ROOT, "bin", "harness"), "tier", "thresholds"]]
        for argv in cmds:
            rc, err = closed_stdout(argv)
            assert err == "" and rc == 0, (argv, rc, err)
        tf = _load("test_forecast")
        with tf.tmp() as fd:
            cfg, fevents, bodies = tf.fixture(fd)
            env = dict(os.environ, HARNESS_CLAUDE_CONFIG_DIRS=cfg, STATE_DIR=os.path.join(fd, "none"))
            base = ["50", "-R", tf.W, "--events", fevents, "--bodies", bodies]
            for extra in ([], ["--json"]):
                argv = [py, os.path.join(ROOT, "scripts", "forecast.py")] + base + extra
                rc, err = closed_stdout(argv, env)
                assert err == "" and rc == 0, (argv, rc, err)


def test_help_with_a_closed_stdout_prints_nothing_on_stderr():
    """#837: argparse falls back to stderr when sys.stdout is None; the help is dropped like any other output."""
    py = sys.executable
    cmds = [[py, os.path.join(ROOT, "scripts", "stats.py"), "--help"],
            [py, os.path.join(ROOT, "scripts", "stats.py"), "report", "--help"],
            [py, os.path.join(ROOT, "scripts", "forecast.py"), "--help"],
            [py, os.path.join(ROOT, "scripts", "tier.py"), "--help"],
            [py, os.path.join(ROOT, "scripts", "tier.py"), "decide", "--help"],
            [py, os.path.join(ROOT, "bench", "run.py"), "--help"],
            ["bash", os.path.join(ROOT, "bin", "harness"), "stats", "--help"],
            ["bash", os.path.join(ROOT, "bin", "harness"), "tier", "decide", "--help"]]
    for argv in cmds:
        rc, err = closed_stdout(argv)
        assert err == "" and rc == 0, (argv, rc, err)


def test_a_full_disk_on_stdout_is_one_stderr_line_and_exit_1():
    """#882: ENOSPC on stdout (/dev/full) escaped as an OSError traceback, "Exception ignored", exit 120. Now: one
    `harness <cmd>: cannot write output: ...` line on stderr, exit 1."""
    if not os.path.exists("/dev/full"):
        print("  skip: no /dev/full")
        return
    py = sys.executable
    cmds = [("stats", [py, os.path.join(ROOT, "scripts", "stats.py"), "report"]),
            ("stats", [py, os.path.join(ROOT, "scripts", "stats.py"), "--help"]),
            ("forecast", [py, os.path.join(ROOT, "scripts", "forecast.py"), "--help"]),
            ("tier", [py, os.path.join(ROOT, "scripts", "tier.py"), "decide", "--criteria", "3", "--lines", "10",
                      "--files", "1", "--subsystems", "1"]),
            ("tier", [py, os.path.join(ROOT, "scripts", "tier.py"), "thresholds"]),
            ("bench", [py, os.path.join(ROOT, "bench", "run.py"), "--help"])]
    for name, argv in cmds:
        with open("/dev/full", "wb") as full:
            r = subprocess.run(argv, stdout=full, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)
        err = r.stderr.decode()
        assert r.returncode == 1, (argv, r.returncode, err)
        assert err == f"harness {name}: cannot write output: No space left on device\n", (argv, err)


def closed_stderr(argv, env=None):
    """Run argv with standard error CLOSED (`2>&-`); (returncode, stdout). Under `bin/harness` bash itself then
    opens its script on fd 2, so python inherits a read-only stderr rather than none."""
    r = subprocess.run(["bash", "-c", '"$@" 2>&-', "_"] + argv, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, env=env)
    return r.returncode, r.stdout.decode()


def test_a_usage_error_with_stderr_closed_still_exits_2():
    """#896: `harness stats -x 2>&-` exited 120: bash opens the script on the closed fd 2, the usage message could not
    be written, and the flush of stderr at shutdown turned the status into 120. Now: 2, as with stderr open."""
    py = sys.executable
    harness = ["bash", os.path.join(ROOT, "bin", "harness")]
    cmds = [harness + ["stats", "-x"], harness + ["forecast", "-x"], harness + ["tier", "-x"],
            [py, os.path.join(ROOT, "scripts", "stats.py"), "report", "-x"],
            [py, os.path.join(ROOT, "scripts", "forecast.py"), "-x"],
            [py, os.path.join(ROOT, "scripts", "tier.py"), "-x"],
            [py, os.path.join(ROOT, "bench", "run.py"), "-x"]]
    for argv in cmds:
        rc, out = closed_stderr(argv)
        assert rc == 2, (argv, rc, out)
        with open(os.devnull, "rb") as ro:   # the same fd state without bash: stderr open for reading only
            r = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=ro)
        assert r.returncode == 2, (argv, r.returncode)


def test_a_successful_run_with_stderr_closed_still_exits_0():
    harness = ["bash", os.path.join(ROOT, "bin", "harness")]
    for argv in (harness + ["tier", "thresholds"], [sys.executable, os.path.join(ROOT, "scripts", "tier.py"), "thresholds"]):
        rc, out = closed_stderr(argv)
        assert rc == 0 and out, (argv, rc, out)


def test_help_still_prints_and_a_usage_error_still_exits_2():
    tier = [sys.executable, os.path.join(ROOT, "scripts", "tier.py")]
    r = subprocess.run(tier + ["decide", "--help"], capture_output=True, text=True)
    assert r.returncode == 0 and "usage:" in r.stdout and r.stderr == "", r
    r = subprocess.run(tier + ["decide", "--bogus"], capture_output=True, text=True)
    assert r.returncode == 2 and "usage:" in r.stderr, r


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

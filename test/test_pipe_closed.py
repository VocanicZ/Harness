"""test_pipe_closed.py — #713: forecast.py, tier.py and bench/run.py end quietly when the reader closes stdout
early (`cmd | true`): no "Exception ignored on flushing sys.stdout: BrokenPipeError" on stderr, exit 0 (or 141).
The reader's end is closed before the child starts, so its first write or its exit-time flush has no reader —
the same as `| true`, without the race. scripts/pipesafe.py is the shared helper; stats.py's own is #671."""
import importlib.util, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import portable  # bash_exe: a bare "bash" is WSL's launcher on Windows, not Git's (#605, #609)
BASH = portable.bash_exe()


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
            quiet([BASH, os.path.join(ROOT, "bin", "harness"), "forecast"] + base + extra, env)


def test_tier_decide_and_thresholds_into_a_closed_pipe_are_quiet():
    tier = os.path.join(ROOT, "scripts", "tier.py")
    decide = ["decide", "--criteria", "3", "--lines", "80", "--files", "3", "--subsystems", "1"]
    for args in (decide, decide + ["--json"], ["thresholds"]):
        quiet([sys.executable, tier] + args)
    quiet([BASH, os.path.join(ROOT, "bin", "harness"), "tier"] + decide)


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
            [BASH, os.path.join(ROOT, "bin", "harness"), "stats", "--help"],
            [BASH, os.path.join(ROOT, "bin", "harness"), "tier", "decide", "--help"]]
    for argv in cmds:
        rc, err = into_true(argv)
        assert err == "" and rc == 0, (argv, rc, err)


def closed_stdout(argv, env=None):
    """Run argv with standard output CLOSED (`>&-`), so sys.stdout is None; (returncode, stderr)."""
    r = subprocess.run([BASH, "-c", '"$@" >&-', "_"] + argv, stdin=subprocess.DEVNULL,
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
                [BASH, os.path.join(ROOT, "bin", "harness"), "tier", "thresholds"]]
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
            [BASH, os.path.join(ROOT, "bin", "harness"), "stats", "--help"],
            [BASH, os.path.join(ROOT, "bin", "harness"), "tier", "decide", "--help"]]
    for argv in cmds:
        rc, err = closed_stdout(argv)
        assert err == "" and rc == 0, (argv, rc, err)


def test_harness_help_with_a_closed_stdout_or_pipe_is_quiet_and_exits_0():
    """#984: usage() used `cat`, which printed 'cat: standard output: Bad file descriptor' and exited 1 under `>&-`."""
    h = [BASH, os.path.join(ROOT, "bin", "harness")]
    for argv in (h + ["--help"], h + ["help"], h + ["-h"], h):
        rc, err = closed_stdout(argv)
        assert err == "" and rc == 0, (argv, rc, err)
        rc, err = into_true(argv)
        assert err == "" and rc in (0, 141), (argv, rc, err)
    out = subprocess.run(h + ["--help"], capture_output=True, text=True)
    assert out.returncode == 0 and out.stdout.startswith("usage: harness") and out.stderr == ""


def early_exit_reader(argv, reader):
    """Run `argv | <reader>` under bash with default SIGPIPE handling; (PIPESTATUS[0], stderr)."""
    r = subprocess.run([BASH, "-c", '"$@" | ' + reader + '; echo "${PIPESTATUS[0]}" >&2', "_"] + argv,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    lines = r.stderr.decode().splitlines()
    return int(lines[-1]), "\n".join(lines[:-1])


def test_harness_version_into_an_early_exit_reader_exits_0():
    """#993: `harness --version | head -0` exited 141 (echo died of SIGPIPE); with --verbose `| head -1` did in ~1 of 5 runs."""
    h = [BASH, os.path.join(ROOT, "bin", "harness")]
    for argv in (h + ["--version"], h + ["--version", "--verbose"], h + ["version"]):
        for reader in ("head -0", "head -1"):
            for _ in range(10 if reader == "head -1" else 1):
                rc, err = early_exit_reader(argv, reader)
                assert rc == 0 and err == "", (argv, reader, rc, err)
        rc, err = closed_stdout(argv)
        assert rc == 0 and err == "", (argv, rc, err)
    out = subprocess.run(h + ["--version", "--verbose"], capture_output=True, text=True)
    assert out.returncode == 0 and out.stdout.startswith("harness ") and "engine: " in out.stdout and "stable: " in out.stdout


def test_a_full_disk_on_stdout_is_one_stderr_line_and_exit_1():
    """#882: ENOSPC on stdout (/dev/full) escaped as an OSError traceback, "Exception ignored", exit 120. Now: one
    `<cmd>: cannot write output: ...` line on stderr, exit 1 (#900: `bench/run.py` says `bench:` like its other messages)."""
    if not os.path.exists("/dev/full"):
        print("  skip: no /dev/full")
        return
    py = sys.executable
    cmds = [("harness stats", [py, os.path.join(ROOT, "scripts", "stats.py"), "report"]),
            ("harness stats", [py, os.path.join(ROOT, "scripts", "stats.py"), "--help"]),
            ("harness forecast", [py, os.path.join(ROOT, "scripts", "forecast.py"), "--help"]),
            ("harness tier", [py, os.path.join(ROOT, "scripts", "tier.py"), "decide", "--criteria", "3", "--lines", "10",
                      "--files", "1", "--subsystems", "1"]),
            ("harness tier", [py, os.path.join(ROOT, "scripts", "tier.py"), "thresholds"]),
            ("bench", [py, os.path.join(ROOT, "bench", "run.py"), "--help"])]
    for name, argv in cmds:
        with open("/dev/full", "wb") as full:
            r = subprocess.run(argv, stdout=full, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)
        err = r.stderr.decode()
        assert r.returncode == 1, (argv, r.returncode, err)
        assert err == f"{name}: cannot write output: No space left on device\n", (argv, err)


def closed_stderr(argv, env=None):
    """Run argv with standard error CLOSED (`2>&-`); (returncode, stdout). Under `bin/harness` bash itself then
    opens its script on fd 2, so python inherits a read-only stderr rather than none."""
    r = subprocess.run([BASH, "-c", '"$@" 2>&-', "_"] + argv, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, env=env)
    return r.returncode, r.stdout.decode()


def test_a_usage_error_with_stderr_closed_still_exits_2():
    """#896: `harness stats -x 2>&-` exited 120: bash opens the script on the closed fd 2, the usage message could not
    be written, and the flush of stderr at shutdown turned the status into 120. Now: 2, as with stderr open."""
    py = sys.executable
    harness = [BASH, os.path.join(ROOT, "bin", "harness")]
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


def test_a_hand_written_usage_error_with_stderr_closed_or_full_still_exits_2():
    """#910: `harness stats --since=-x 2>&-` and `stats.py --prd 0 2>/dev/full` exited 1: the tool's own
    `print(msg, file=sys.stderr)` raised EBADF/ENOSPC, and pipesafe took any file-less OSError for a failed stdout write.
    A stderr that cannot be written never changes the status: 2, as with stderr open."""
    py = sys.executable
    harness = [BASH, os.path.join(ROOT, "bin", "harness")]
    stats, forecast = os.path.join(ROOT, "scripts", "stats.py"), os.path.join(ROOT, "scripts", "forecast.py")
    tier, bench = os.path.join(ROOT, "scripts", "tier.py"), os.path.join(ROOT, "bench", "run.py")
    cases = [(harness + ["stats", "--since=-x"], {}), ([py, stats, "--prd", "0"], {}),
             (harness + ["stats", "--events", "nope"], {}),
             (harness + ["forecast", "3", "--events", "nope"], {}),
             (harness + ["forecast", "3", "-R", "a/b", "--bodies", "nope"], {}),
             ([py, forecast, "3", "--events", "nope"], {}),
             (harness + ["tier", "overlap", "--files", ",", "-R", "a/b"], {}),
             ([py, tier, "overlap", "--files", ",", "-R", "a/b"], {}),
             (harness + ["tier", "thresholds"], {"HARNESS_TIER_TOML": "nope"}),
             ([py, tier, "thresholds"], {"HARNESS_TIER_TOML": "nope"}),
             ([py, bench, "x", "--runs", "0"], {}), ([py, bench, "x", "--workers", "0"], {})]
    for argv, extra in cases:
        env = dict(os.environ, **extra)
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, env=env)
        assert r.returncode == 2 and r.stderr, ("stderr open", argv, r.returncode, r.stderr)
        rc, out = closed_stderr(argv, env)
        assert rc == 2, ("stderr closed", argv, rc, out)
        if os.path.exists("/dev/full"):
            with open("/dev/full", "wb") as full:
                r = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=full, env=env)
            assert r.returncode == 2, ("stderr full", argv, r.returncode)


def direct_closed_stderr(argv, env=None):
    """Run argv under python3 DIRECTLY with fd 2 closed (`exec 2>&-` then exec: no bash script on fd 2, so
    sys.stderr is None); (returncode, stdout)."""
    r = subprocess.run([BASH, "-c", 'exec 2>&-; exec "$@"', "_"] + argv, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, env=env)
    return r.returncode, r.stdout.decode()


def test_diagnostics_and_usage_are_dropped_not_sent_to_stdout_when_stderr_is_closed():
    """#930: with fd 2 closed sys.stderr is None, so print(file=sys.stderr) and argparse's usage fell back to stdout:
    `forecast.py --json 2>&-` printed "skipped 1 event line(s)" before the JSON (invalid), exit 0."""
    import tempfile
    py = sys.executable
    stats, forecast = os.path.join(ROOT, "scripts", "stats.py"), os.path.join(ROOT, "scripts", "forecast.py")
    tier, bench = os.path.join(ROOT, "scripts", "tier.py"), os.path.join(ROOT, "bench", "run.py")
    with tempfile.TemporaryDirectory() as d:
        events, bodies = os.path.join(d, "events.jsonl"), os.path.join(d, "bodies.json")
        with open(events, "w") as f: f.write("not json\n")
        with open(bodies, "w") as f: f.write("[]")
        for argv in ([py, forecast, "1", "-R", "a/b", "--json", "--events", events, "--bodies", bodies],
                     [py, stats, "report", "--events", events, "--prd", "3", "--json"]):
            want = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True).returncode
            rc, out = direct_closed_stderr(argv)
            assert rc == want, (argv, rc, want)   # the exit status is the one stderr-open gives
            try: json.loads(out)   # stdout is only the JSON
            except ValueError: raise AssertionError(("stdout is not only JSON", argv, out))
        rc, out = direct_closed_stderr([py, stats, "report", "--events", os.path.join(d, "missing")])
        assert out == "", (rc, out)
        rc, out = direct_closed_stderr([py, bench, "--dry-run", "stub"], dict(os.environ, HARNESS_USAGE_CMD="true"))
        assert out == "", (rc, out)
    for argv, want in (([py, tier, "decide", "--criteria", "x"], 2), ([py, bench, "--runs", "x", "stub"], 2),
                       ([py, forecast, "x"], 2), ([py, tier, "-x"], 2), ([py, forecast, "-x"], 2)):
        rc, out = direct_closed_stderr(argv)
        assert rc == want and out == "", (argv, rc, out)


def test_a_successful_run_with_stderr_closed_still_exits_0():
    harness = [BASH, os.path.join(ROOT, "bin", "harness")]
    for argv in (harness + ["tier", "thresholds"], [sys.executable, os.path.join(ROOT, "scripts", "tier.py"), "thresholds"]):
        rc, out = closed_stderr(argv)
        assert rc == 0 and out, (argv, rc, out)


def test_help_still_prints_and_a_usage_error_still_exits_2():
    tier = [sys.executable, os.path.join(ROOT, "scripts", "tier.py")]
    r = subprocess.run(tier + ["decide", "--help"], capture_output=True, text=True)
    assert r.returncode == 0 and "usage:" in r.stdout and r.stderr == "", r
    r = subprocess.run(tier + ["decide", "--bogus"], capture_output=True, text=True)
    assert r.returncode == 2 and "usage:" in r.stderr, r

def test_windows_einval_on_a_closed_pipe_is_a_closed_pipe_not_a_write_failure():
    """#1110: native Windows' CRT write() maps a pipe whose reader closed to EINVAL ("Invalid argument"), raised as a plain
    OSError. Unfixed that was `harness forecast: cannot write output: Invalid argument`, exit 1. Run on every OS by pinning
    sys.platform; a named path's EINVAL (an open() of a bad name) and a non-Windows EINVAL are still failures."""
    import errno
    pipesafe = _load("../scripts/pipesafe")
    real, saved_out = sys.platform, sys.stdout
    def einval(*_):
        raise OSError(errno.EINVAL, "Invalid argument")
    try:
        sys.platform = "win32"
        assert pipesafe.broken_pipe(OSError(errno.EINVAL, "Invalid argument"))
        assert pipesafe.broken_pipe(BrokenPipeError())
        assert not pipesafe.broken_pipe(OSError(errno.ENOSPC, "No space left on device"))
        assert not pipesafe.broken_pipe(OSError(errno.EINVAL, "Invalid argument", "x.json"))
        sys.stdout = open(os.devnull, "w")
        assert pipesafe.run(einval) == 0, "a write into a closed pipe ends the command quietly"
        sys.platform = "linux"
        assert not pipesafe.broken_pipe(OSError(errno.EINVAL, "Invalid argument"))
    finally:
        sys.platform = real
        sys.stdout.close() if sys.stdout is not saved_out else None
        sys.stdout = saved_out


# ── #1130: a reader that closes the pipe must not kill a destructive subcommand half way ──────────────────────────
import shutil, tempfile


def _host(d):
    """A throwaway host under d: HOME, HARNESS_HOME with two releases (engine -> v0.2.0), a PATH link, a project; (env, paths)."""
    home, hh, binlink = os.path.join(d, "home"), os.path.join(d, "host"), os.path.join(d, "localbin")
    proj = os.path.join(d, "proj")
    for t in ("v0.1.0", "v0.2.0"):
        st = os.path.join(hh, "releases", t)
        os.makedirs(st)
        for name in ("bin", "scripts", "prompts", "skill", "plugins"):
            shutil.copytree(os.path.join(ROOT, name), os.path.join(st, name), symlinks=True)
        for name in ("install.sh", "update.sh"):
            shutil.copy(os.path.join(ROOT, name), os.path.join(st, name))
        with open(os.path.join(st, "VERSION"), "w") as f: f.write(t + "\n" + "0" * 40 + "\n")
    with open(os.path.join(hh, "releases", ".installed"), "w") as f: f.write("v0.1.0\nv0.2.0\n")
    os.symlink("releases/v0.2.0", os.path.join(hh, "engine"))
    os.makedirs(binlink); os.symlink(os.path.join(hh, "engine", "bin", "harness"), os.path.join(binlink, "harness"))
    os.makedirs(os.path.join(proj, ".harness", "run")); os.makedirs(home)
    with open(os.path.join(proj, ".harness", "config"), "w") as f:
        f.write(': "${HARNESS_MODE:=issue-only}"\n: "${HARNESS_TOPOLOGY:=single}"\n')
    env = {k: v for k, v in os.environ.items() if k not in ("ENGINE_DIR", "STATE_DIR", "HARNESS_ENGINE_LINK", "TMUX", "TMUX_PANE")}
    env.update(HARNESS_FLEETS_DIR=os.path.join(d, "fleets"))   # pinned first: the host registry is never the real one (test_hermetic)
    env.update(HOME=home, HARNESS_HOME=hh, HARNESS_BIN_DIR=binlink, HARNESS_USER_SKILLS=os.path.join(home, "skills"),
               HARNESS_SKIP_RTDD="1", HARNESS_UNINSTALL_WORKER_PIDS="",
               HARNESS_POLLER_DIR=os.path.join(d, "poller"), HARNESS_SNAPSHOTS_DIR=os.path.join(d, "snapshots"),
               XDG_CONFIG_HOME=os.path.join(d, "config"), TMUX_TMPDIR=os.path.join(d, "tmux"),
               HARNESS_SUPERVISE_UNIT_DIR=os.path.join(d, "units"), HARNESS_WEB_UNIT_DIR=os.path.join(d, "units"),
               HARNESS_SUPERVISE_SYSTEMCTL="false", HARNESS_SUPERVISE_LOGINCTL="false",
               HARNESS_WEB_SYSTEMCTL="false", HARNESS_WEB_LOGINCTL="false")
    return env, hh, binlink, proj


def _into_head0(argv, env, cwd):
    """`harness ... | head -0` (the reader exits at once, the pipe closes); (PIPESTATUS[0], stderr)."""
    r = subprocess.run(["bash", "-c", '"$@" | head -0; echo "${PIPESTATUS[0]}" >&2', "_"] + argv, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, cwd=cwd)
    lines = r.stderr.decode().splitlines()
    return int(lines[-1]), "\n".join(lines[:-1])


def test_uninstall_force_into_a_closed_pipe_still_removes_everything():
    """#1130: `harness uninstall --force | head -1` exited 141 after removing the engine link, leaving a dangling
    bin/harness, releases/ and the project's .harness/. Now it runs to the end: same result as with a terminal."""
    with tempfile.TemporaryDirectory() as d:
        env, hh, binlink, proj = _host(d)
        harness = os.path.join(hh, "releases", "v0.2.0", "bin", "harness")
        rc, err = _into_head0(["bash", harness, "uninstall", "--force"], env, proj)
        assert rc == 0, (rc, err)
        assert not os.path.lexists(os.path.join(hh, "engine")), "engine link left"
        assert not os.path.lexists(os.path.join(binlink, "harness")), "dangling bin/harness left"
        assert not os.path.exists(os.path.join(hh, "releases")), "releases/ left"
        assert not os.path.exists(os.path.join(proj, ".harness")), "project .harness/ left"


def test_update_rollback_into_a_closed_pipe_flips_and_redeploys():
    """#1130: `harness update --rollback | head -1` flipped the engine, then the redeploy died of SIGPIPE (141)."""
    with tempfile.TemporaryDirectory() as d:
        env, hh, binlink, proj = _host(d)
        harness = os.path.join(hh, "releases", "v0.2.0", "bin", "harness")
        ref = subprocess.run(["bash", harness, "update", "--rollback"], capture_output=True, text=True, env=env, cwd=proj, stdin=subprocess.DEVNULL)
        assert ref.returncode == 0 and "rolled back Harness v0.2.0 -> v0.1.0" in ref.stdout + ref.stderr, ref
        os.unlink(os.path.join(hh, "engine")); os.symlink("releases/v0.2.0", os.path.join(hh, "engine"))
        with open(os.path.join(hh, "releases", ".installed"), "w") as f: f.write("v0.1.0\nv0.2.0\n")
        rc, err = _into_head0(["bash", harness, "update", "--rollback"], env, proj)
        assert rc == 0, (rc, err)
        assert os.readlink(os.path.join(hh, "engine")) == "releases/v0.1.0"
        assert open(os.path.join(hh, "releases", ".installed")).read().split()[-1] == "v0.1.0", "the rollback was not recorded"


def test_read_only_commands_exit_0_into_a_closed_pipe():
    """#1130: doctor and status (in a project) exited 141 into `| head -0`; the python commands already exit 0.
    A bare `attach` is a usage error since #1122 (exit 2): into the closed pipe it keeps that status, not 0 and not 141."""
    with tempfile.TemporaryDirectory() as d:
        env, hh, binlink, proj = _host(d)
        harness = ["bash", os.path.join(hh, "releases", "v0.2.0", "bin", "harness")]
        for args in (["doctor"], ["status"], ["status", "--all"], ["stats"], ["version"], ["help"]):
            rc, err = _into_head0(harness + args, env, proj)
            assert rc == 0 and "Broken pipe" not in err and "write error" not in err, (args, rc, err)
        rc, err = _into_head0(harness + ["attach"], env, proj)
        assert rc == 2 and "Broken pipe" not in err and "write error" not in err and "usage: harness attach" in err, (["attach"], rc, err)
        # a failing command keeps its own status through the relay: a pipe is not a reason to report success
        bad = harness + ["attach", "no-such-unit"]
        direct = subprocess.run(bad, capture_output=True, env=env, cwd=proj, stdin=subprocess.DEVNULL)
        piped = subprocess.run(["bash", "-c", '"$@" | cat; echo "${PIPESTATUS[0]}" >&2', "_"] + bad, capture_output=True, env=env, cwd=proj, stdin=subprocess.DEVNULL)
        assert direct.returncode != 0, direct
        assert piped.stderr.decode().splitlines()[-1] == str(direct.returncode) and piped.stdout == direct.stdout, (piped, direct)


# ── #1205: the relay's fd and a detached worker must not hold a caller's pipe open ─────────────────────────────────
import time

_PORTABLE = os.path.join(ROOT, "scripts", "portable.sh")


def _pipe_safe_exec_src():
    """The pipe_safe_exec function text out of bin/harness (the dispatch around it needs a project)."""
    src = open(os.path.join(ROOT, "bin", "harness")).read()
    m = re.search(r"^pipe_safe_exec\(\)\{\n.*?^\}\n", src, re.S | re.M)
    assert m, "pipe_safe_exec not found in bin/harness"
    return m.group(0)


def _alive(pid):
    try: os.kill(pid, 0)
    except OSError: return False
    return True


def _kill(pid):
    if isinstance(pid, int) and pid > 1:
        try: os.kill(pid, 9)
        except OSError: pass


def _wait_pidfile(path, secs=10):
    end = time.time() + secs
    while time.time() < end:
        try:
            v = open(path).read().strip()
            if v.isdigit(): return int(v)
        except OSError: pass
        time.sleep(0.05)
    raise AssertionError("no pid in " + path)


def _launcher(d, sleep_s):
    """A subcommand script that spawns a long-lived child through detach_launch and exits at once."""
    child = os.path.join(d, "child.sh")
    with open(child, "w") as f:
        f.write('source "%s"\ndetach_launch "%s/child.pid" "%s/child.log" sleep %d\necho done\n' % (_PORTABLE, d, d, sleep_s))
    top = os.path.join(d, "top.sh")
    with open(top, "w") as f:
        f.write(_pipe_safe_exec_src() + '\npipe_safe_exec bash "$@"\n')
    return top, child


def test_a_detached_child_does_not_hold_a_pipe_safe_exec_reader_open():
    """#1205: the relay's input stayed open as an extra fd in the subcommand (fd 63), and detach_launch's child
    inherited it, so `harness update | tail` waited for the workers to exit. A reader gets EOF at once."""
    if not os.path.isdir("/proc/self/fd"):
        print("  skip: no /proc"); return
    with tempfile.TemporaryDirectory() as d:
        top, child = _launcher(d, 30)
        pid = None
        try:
            t0 = time.time()
            try:
                r = subprocess.run(["bash", top, child], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=12)
            except subprocess.TimeoutExpired:
                raise AssertionError("the reader never got EOF while the detached child ran")
            took = time.time() - t0
            pid = _wait_pidfile(os.path.join(d, "child.pid"))
            assert r.stdout == b"done\n" and r.returncode == 0, r
            assert took < 5, "the reader waited %.1fs for EOF while the detached child ran" % took
            assert _alive(pid), "the detached child must outlive the subcommand"
            # command substitution: bash waits for EOF on the substitution's pipe too
            t0 = time.time()
            try:
                r = subprocess.run(["bash", "-c", 'out=$(bash "$@"); echo "got:$out"', "_", top, child],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=12)
            except subprocess.TimeoutExpired:
                raise AssertionError("out=$(...) never returned while the detached child ran")
            assert r.stdout == b"got:done\n" and time.time() - t0 < 5, (r, time.time() - t0)
        finally:
            _kill(pid)
            try: _kill(int(open(os.path.join(d, "child.pid")).read().strip()))
            except (OSError, ValueError): pass


def test_pipe_safe_exec_leaves_the_subcommand_only_the_relay_on_fd_1():
    """#1205: no extra fd in the subcommand points at the relay's pipe; fd 1 is the relay's input."""
    if not os.path.isdir("/proc/self/fd"):
        print("  skip: no /proc"); return
    with tempfile.TemporaryDirectory() as d:
        top = os.path.join(d, "top.sh")
        with open(top, "w") as f:
            f.write(_pipe_safe_exec_src() + '\npipe_safe_exec bash "$@"\n')
        probe = os.path.join(d, "probe.sh")
        with open(probe, "w") as f:
            f.write('for f in /proc/$$/fd/*; do n=${f##*/}; [ -e "$f" ] && echo "$n $(readlink "$f")"; done\n')
        r = subprocess.run(["bash", top, probe], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=15)
        fds = dict(l.split(" ", 1) for l in r.stdout.decode().splitlines())
        pipes = {n: t for n, t in fds.items() if t.startswith("pipe:")}
        assert "1" in pipes, fds
        extra = {n: t for n, t in pipes.items() if n != "1" and t == pipes["1"]}
        assert not extra, ("an extra fd holds the relay's pipe", extra)


def test_detach_launch_child_has_devnull_stdin_the_log_and_no_other_fds():
    """#1205: a detached POSIX child gets /dev/null on fd 0, the log on fds 1 and 2, and nothing else it inherited."""
    if not os.path.isdir("/proc/self/fd"):
        print("  skip: no /proc"); return
    with tempfile.TemporaryDirectory() as d:
        log = os.path.join(d, "w.log")
        script = ('source "%s"\nexec 7>"%s/seven" 8</dev/null 9>"%s/nine" 20>"%s/twenty"\n'
                  'detach_launch "%s/w.pid" "%s" sleep 30\n' % (_PORTABLE, d, d, d, d, log))
        pid = None
        try:
            r = subprocess.run(["bash", "-c", script], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=15)
            assert r.returncode == 0, r
            pid = _wait_pidfile(os.path.join(d, "w.pid"))
            end = time.time() + 10   # the pid exists before the exec of the real command settles
            cmd = b""
            while time.time() < end:
                try: cmd = open("/proc/%d/cmdline" % pid, "rb").read()
                except OSError: cmd = b""
                if cmd.startswith(b"sleep"): break
                time.sleep(0.05)
            assert cmd.startswith(b"sleep"), cmd
            fds = {}
            for n in os.listdir("/proc/%d/fd" % pid):
                fds[int(n)] = os.path.realpath("/proc/%d/fd/%s" % (pid, n))
            assert set(fds) == {0, 1, 2}, fds
            assert fds[0] == os.path.realpath("/dev/null"), fds
            assert fds[1] == fds[2] == os.path.realpath(log), fds
        finally:
            _kill(pid)


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

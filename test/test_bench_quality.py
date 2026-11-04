#!/usr/bin/env python3
"""test_bench_quality.py — #387 (PRD #345): bench/quality.py, the optional SonarQube Community scan.
Covered: with a (fake) docker and a fake SonarQube web API the scan writes bugs / vulnerabilities /
code smells / maintainability rating / duplication / coverage into the arm's results and removes its
container and network; without docker, with an unreachable daemon, a server that never comes up, a
failing scanner or a failed analysis it records `quality: skipped (<reason>)` and exits 0, never failing;
bench/figures.py shows the quality column. A REAL SonarQube run on a fixture repo is opt-in
(BENCH_QUALITY_REAL=1, needs a working docker and pulls ~1 GB of images) and says so when it is skipped."""
import http.server, json, os, shutil, stat, subprocess, sys, tempfile, threading

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
QUALITY = os.path.join(ROOT, "bench", "quality.py")
FIGURES = os.path.join(ROOT, "bench", "figures.py")
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(ROOT, "bench"))
import quality as bench_quality                      # noqa: E402

# A fake `docker`: records every call, answers the few the scan makes. FAKE_DOCKER_MODE picks the failure.
FAKE_DOCKER = r'''#!PYTHON
import os, sys
home, mode, a = os.environ["FAKE_DOCKER_HOME"], os.environ.get("FAKE_DOCKER_MODE", ""), sys.argv[1:]
open(os.path.join(home, "calls.log"), "a").write(" ".join(a) + "\n")
if a[0] == "info":
    if mode == "no-daemon":
        print("Cannot connect to the Docker daemon", file=sys.stderr); sys.exit(1)
    print("29.0.0")
elif a[0] == "port":
    print("127.0.0.1:" + os.environ["FAKE_SONAR_PORT"])
elif a[0] == "inspect":
    print("false" if mode == "server-exits" else "true")
elif a[0] == "logs":
    print("max virtual memory areas vm.max_map_count [65530] is too low")
elif a[0] == "run" and "-d" in a:
    if mode == "pull-fails":
        print("pull access denied", file=sys.stderr); sys.exit(125)
    print("abc123")
elif a[0] == "run":                      # the scanner
    open(os.path.join(home, "scanner.args"), "w").write("\n".join(a))
    if mode == "scanner-fails":
        print("ERROR: Not authorized", file=sys.stderr); sys.exit(2)
    if mode != "no-task":
        print("INFO: More about the report processing at http://x:9000/api/ce/task?id=AYtask-1")
# network create / network rm / rm -f: nothing to do
'''

MEASURES = [{"metric": "bugs", "value": "2"}, {"metric": "vulnerabilities", "value": "0"},
            {"metric": "code_smells", "value": "7"}, {"metric": "sqale_rating", "value": "1.0"},
            {"metric": "duplicated_lines_density", "value": "3.5"}]    # no coverage: nothing ran the tests


class Sonar(http.server.BaseHTTPRequestHandler):
    status, task = "UP", "SUCCESS"

    def log_message(self, *a):
        pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/system/status":
            return self._send({"status": Sonar.status})
        if self.path.startswith("/api/ce/task?id=AYtask-1"):
            return self._send({"task": {"status": Sonar.task}})
        if self.path.startswith("/api/measures/component?component=bench&metricKeys="):
            return self._send({"component": {"key": "bench", "measures": MEASURES}})
        self._send({"errors": [{"msg": self.path}]}, 404)

    def do_POST(self):
        if self.path.startswith("/api/user_tokens/generate"):
            return self._send({"token": "squ_fake"})
        self._send({}, 404)


class Env:
    def __init__(self, mode="", with_docker=True, status="UP", task="SUCCESS"):
        self.d = tempfile.mkdtemp(prefix="bench-quality-")
        self.bin = os.path.join(self.d, "bin"); os.makedirs(self.bin)
        self.repo = os.path.join(self.d, "repo"); os.makedirs(self.repo)
        with open(os.path.join(self.repo, "app.py"), "w") as fh:
            fh.write("def f(x):\n    return x\n")
        if with_docker:
            p = os.path.join(self.bin, "docker")
            with open(p, "w") as fh:
                fh.write(FAKE_DOCKER.replace('#!PYTHON', '#!' + sys.executable, 1))
            os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        Sonar.status, Sonar.task = status, task
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sonar)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        # PATH is the fake docker's dir alone: never the host's real docker (with_docker=False: no docker at all)
        self.env = {"PATH": self.bin, "FAKE_DOCKER_HOME": self.d,
                    "FAKE_DOCKER_MODE": mode, "FAKE_SONAR_PORT": str(self.srv.server_address[1]),
                    "PYTHONDONTWRITEBYTECODE": "1", "HOME": self.d}

    def run(self, *args):
        return subprocess.run([sys.executable, "-I", QUALITY, self.repo, "--startup-secs", "3",
                               "--analysis-secs", "3"] + list(args), env=self.env, capture_output=True,
                              text=True, timeout=120)

    def calls(self):
        p = os.path.join(self.d, "calls.log")
        return open(p).read().splitlines() if os.path.exists(p) else []

    def close(self):
        self.srv.shutdown(); self.srv.server_close()
        shutil.rmtree(self.d, ignore_errors=True)


def with_env(**kw):
    def deco(fn):
        def wrapped():
            e = Env(**kw)
            try:
                fn(e)
            finally:
                e.close()
        wrapped.__name__ = fn.__name__
        return wrapped
    return deco


def frag(p):
    assert p.returncode == 0, (p.returncode, p.stdout, p.stderr)
    return json.loads(p.stdout)


@with_env()
def test_a_scan_writes_the_quality_fields_and_cleans_up(e):
    arm = os.path.join(e.d, "plain.json")
    with open(arm, "w") as fh:
        json.dump({"arm": "plain", "status": "ok", "sonarqube": {"bugs": 99}}, fh)     # a stale object is replaced
    f = frag(e.run("--arm-json", arm))
    s = f["sonarqube"]
    assert f["quality"] == "ok", f
    assert (s["bugs"], s["vulnerabilities"], s["code_smells"]) == (2, 0, 7), s
    assert s["maintainability_rating"] == "A" and s["duplicated_lines_density"] == 3.5 and s["coverage"] is None, s
    assert json.load(open(arm)) == {"arm": "plain", "status": "ok", "quality": "ok", "sonarqube": s}
    calls = e.calls()
    assert any(c.startswith("run -d ") and "sonarqube:community" in c for c in calls), calls
    scanner = open(os.path.join(e.d, "scanner.args")).read().split("\n")
    assert any(x.endswith(":/usr/src:ro") and x.startswith(e.repo) for x in scanner), scanner     # repo read-only
    assert "SONAR_TOKEN=squ_fake" in scanner and "-Dsonar.projectKey=bench" in scanner, scanner
    # the container and the network it made are removed again
    names = [c.split()[-1] for c in calls if c.startswith("network create")]
    assert len(names) == 1 and f"rm -f {names[0]}" in calls and f"network rm {names[0]}" in calls, calls


@with_env(with_docker=False)
def test_without_docker_the_scan_is_skipped_and_exits_0(e):
    arm = os.path.join(e.d, "plain.json")
    with open(arm, "w") as fh:
        json.dump({"arm": "plain"}, fh)
    f = frag(e.run("--arm-json", arm))
    assert f == {"quality": "skipped (docker is not installed)"}, f
    assert json.load(open(arm)) == {"arm": "plain", "quality": "skipped (docker is not installed)"}


@with_env(mode="no-daemon")
def test_an_unreachable_docker_daemon_is_skipped(e):
    f = frag(e.run())
    assert f["quality"].startswith("skipped (docker daemon not reachable") and "sonarqube" not in f, f
    assert not any(c.startswith("network create") for c in e.calls()), e.calls()


@with_env(mode="pull-fails")
def test_a_server_image_that_cannot_start_is_skipped_and_the_network_removed(e):
    f = frag(e.run())
    assert f["quality"].startswith("skipped (docker run failed: pull access denied"), f
    calls = e.calls()
    net = [c.split()[-1] for c in calls if c.startswith("network create")][0]
    assert f"network rm {net}" in calls, calls


@with_env(mode="server-exits")
def test_a_server_that_exits_is_skipped_with_its_log(e):
    f = frag(e.run())
    assert f["quality"].startswith("skipped (the SonarQube container exited") and "max_map_count" in f["quality"], f
    assert any(c.startswith("rm -f bench-sonar-") for c in e.calls()), e.calls()


@with_env(status="STARTING")
def test_a_server_that_never_comes_up_is_skipped(e):
    f = frag(e.run())
    assert f["quality"] == "skipped (SonarQube not ready after 3s)", f
    assert any(c.startswith("rm -f bench-sonar-") for c in e.calls()), e.calls()


@with_env(mode="scanner-fails")
def test_a_failing_scanner_is_skipped(e):
    f = frag(e.run())
    assert f["quality"].startswith("skipped (the scanner failed") and "Not authorized" in f["quality"], f


@with_env(mode="no-task")
def test_a_scanner_that_names_no_task_is_skipped(e):
    assert frag(e.run())["quality"] == "skipped (the scanner named no analysis task)"


@with_env(task="FAILED")
def test_a_failed_analysis_is_skipped(e):
    assert frag(e.run())["quality"] == "skipped (the analysis failed)"


@with_env()
def test_a_missing_repo_is_skipped_not_an_error(e):
    shutil.rmtree(e.repo)
    assert frag(e.run())["quality"].startswith("skipped (no repo to scan")


def test_measures_maps_ratings_and_missing_values():
    m = bench_quality.measures([{"metric": "sqale_rating", "value": "3.0"}, {"metric": "bugs", "value": "4"},
                                {"metric": "coverage", "value": "81.5"}])
    assert m == {"bugs": 4, "vulnerabilities": None, "code_smells": None, "maintainability_rating": "C",
                 "duplicated_lines_density": None, "coverage": 81.5}, m
    assert bench_quality.measures(None)["maintainability_rating"] is None


def test_figures_show_the_quality_column_and_a_skip():
    d = tempfile.mkdtemp(prefix="bench-quality-fig-")
    try:
        run = os.path.join(d, "results", "r1"); os.makedirs(run)
        base = {"schema": 1, "status": "ok", "wall_s": 60, "cost_usd": 1.0}
        with open(os.path.join(run, "plain.json"), "w") as fh:
            json.dump(dict(base, arm="plain", quality="ok", sonarqube={
                "bugs": 2, "vulnerabilities": 0, "code_smells": 7, "maintainability_rating": "A",
                "duplicated_lines_density": 3.5, "coverage": None}), fh)
        with open(os.path.join(run, "harness.json"), "w") as fh:
            json.dump(dict(base, arm="harness", quality="skipped (docker is not installed)"), fh)
        readme = os.path.join(d, "README.md")
        with open(readme, "w") as fh:
            fh.write("# T\n\n<!-- bench:begin — x -->\nOLD\n<!-- bench:end -->\n")
        p = subprocess.run([sys.executable, "-I", FIGURES, "--results-dir", os.path.join(d, "results"),
                            "--readme", readme], capture_output=True, text=True)
        assert p.returncode == 0, p.stderr
        text = open(readme).read()
        assert "| SonarQube |" in text, text
        assert "bugs 2, vulns 0, smells 7, maint. A, dup 3.5%" in text and "cov" not in text.split("bugs 2")[1].split("\n")[0], text
        assert "skipped (docker is not installed)" in text, text
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_a_real_sonarqube_scan_on_a_fixture_repo():
    # Opt-in: a first run pulls ~1 GB of images and SonarQube needs ~2 GB of RAM and a minute or two.
    if os.environ.get("BENCH_QUALITY_REAL") != "1":
        print("  skip: test_a_real_sonarqube_scan_on_a_fixture_repo — set BENCH_QUALITY_REAL=1 to run it")
        return
    if not shutil.which("docker") or subprocess.run(["docker", "info"], capture_output=True).returncode != 0:
        print("  skip: test_a_real_sonarqube_scan_on_a_fixture_repo — docker is absent or its daemon is down")
        return
    d = tempfile.mkdtemp(prefix="bench-quality-real-")
    try:
        with open(os.path.join(d, "app.py"), "w") as fh:
            fh.write("import os\n\n\ndef f(x):\n    if x == x:\n        return 1\n    return 2\n")
        p = subprocess.run([sys.executable, "-I", QUALITY, d, "--startup-secs", "900", "--analysis-secs", "900"],
                           capture_output=True, text=True, timeout=3000)
        f = json.loads(p.stdout)
        assert p.returncode == 0 and f["quality"] == "ok", (p.stdout, p.stderr)
        s = f["sonarqube"]
        assert set(s) == {"bugs", "vulnerabilities", "code_smells", "maintainability_rating",
                          "duplicated_lines_density", "coverage"}, s
        assert isinstance(s["bugs"], int) and s["maintainability_rating"] in "ABCDE", s
    finally:
        shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)

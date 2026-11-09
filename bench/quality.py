#!/usr/bin/env python3
"""quality.py — optional code quality for one benchmark arm (#387, PRD #345). NEVER blocking.

    bench/quality.py <repo-dir> [--arm-json FILE] [--startup-secs 600] [--analysis-secs 900]

Runs SonarQube Community Edition in Docker, locally (no account, no token of yours: the server is a
throwaway container and its admin token is generated inside it), against <repo-dir> — an arm's final
default branch — and prints a results fragment as JSON:

    {"quality": "ok", "sonarqube": {"bugs": 0, "vulnerabilities": 0, "code_smells": 3,
                                    "maintainability_rating": "A", "duplicated_lines_density": 0.0,
                                    "coverage": null}}
    {"quality": "skipped (docker is not installed)"}

With --arm-json the fragment is also merged into that arm's results file (bench/run.py does the same
through this module). Docker missing or unreachable, an image that cannot be pulled, a server that does
not come up, a scan that fails or times out: `quality: skipped (<reason>)` and exit 0. The bench never
fails because of this. Exit 2 is bad arguments only.

The scan: a user-defined docker network, `sonarqube:community` on it (published on a random loopback
port, its data directory on a tmpfs so a nearly full host disk cannot stop it), `sonarsource/sonar-scanner-cli` run with the repo mounted read-only, the analysis task polled to
SUCCESS, the measures read over the web API. The container and network are removed afterwards, also on
failure. Override the images with BENCH_SONAR_IMAGE / BENCH_SONAR_SCANNER_IMAGE. Stdlib only.
"""
import argparse, base64, json, os, re, shutil, subprocess, sys, time, urllib.error, urllib.request, uuid

sys.dont_write_bytecode = True
SERVER_IMAGE = "sonarqube:community"
SCANNER_IMAGE = "sonarsource/sonar-scanner-cli"
DATA_TMPFS_SIZE = "6g"               # SonarQube's data dir lives on a tmpfs of this size (#588), see tmpfs_size()
ADMIN = ("admin", "admin")           # the fresh container's own default; nothing outside it uses it
METRICS = ["bugs", "vulnerabilities", "code_smells", "sqale_rating", "duplicated_lines_density", "coverage"]
RATINGS = {1: "A", 2: "B", 3: "C", 4: "D", 5: "E"}
TASK_RE = re.compile(r"api/ce/task\?id=([A-Za-z0-9_-]+)")
STAMP_RE = re.compile(r"^\d{4}[.-]\d\d[.-]\d\d[ T]\d\d:\d\d:\d\d(?:[.,]\d+)?\s+")
LEVEL_RE = re.compile(r"^ERROR\s+(?:\S*\[[^\]]*\]\S*\s+)?")      # "ERROR es[][o.s.x.Y] " before the message
FAIL_RE = re.compile(r"\bERROR\b|MessageException")


class Skip(Exception):
    """A reason the scan cannot be done. Never an error of the bench."""


def tmpfs_size():
    """The size of the tmpfs mounted over /opt/sonarqube/data: BENCH_SONAR_DATA_SIZE, else DATA_TMPFS_SIZE."""
    return os.environ.get("BENCH_SONAR_DATA_SIZE") or DATA_TMPFS_SIZE


def failure_reason(log):
    """Why a SonarQube container exited, from its log (#588): the first `ERROR` / `MessageException` line
    (its exception message when it has one, else the line without its timestamp and level), not the log
    tail, which only says the server stopped. The last 200 characters when no line says ERROR."""
    for line in (log or "").splitlines():
        if FAIL_RE.search(line):
            m = re.search(r"MessageException:\s*(.+)", line)
            if m:
                return m.group(1).strip()
            return LEVEL_RE.sub("", STAMP_RE.sub("", line.strip(), count=1), count=1).strip()
    return (log or "").strip()[-200:]


def skipped(reason):
    return {"quality": "skipped (" + " ".join(str(reason).split())[:300] + ")"}


def _resolve(argv):
    """#686: on native Windows a fake `docker` script first on PATH is run under its shebang, not skipped for the real docker.exe."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("bench_portable", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts", "portable.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.resolve_argv(list(argv))


def _docker(args, timeout, check=True):
    try:
        p = subprocess.run(_resolve(["docker"] + args), capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Skip(f"docker {args[0]} timed out after {timeout:g}s")
    except OSError as e:
        raise Skip(f"docker cannot be run: {e}")
    if check and p.returncode != 0:
        raise Skip(f"docker {args[0]} failed: {(p.stderr or p.stdout).strip()[-200:]}")
    return p


def _api(base, path, method="GET", timeout=20):
    req = urllib.request.Request(base + path, method=method, data=b"" if method == "POST" else None)
    req.add_header("Authorization", "Basic " + base64.b64encode(":".join(ADMIN).encode()).decode())
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _wait(what, secs, probe, interval=2.0):
    """probe() -> a truthy value when ready; connection errors count as not yet."""
    end = time.time() + secs
    while True:
        try:
            v = probe()
            if v:
                return v
        except (OSError, ValueError, urllib.error.URLError):
            pass
        if time.time() >= end:
            raise Skip(f"{what} not ready after {secs:g}s")
        time.sleep(interval)


def measures(raw):
    """The sonarqube object from the /api/measures/component measures list."""
    got = {m.get("metric"): m.get("value") for m in raw or []}

    def n(key):
        try:
            return float(got[key])
        except (KeyError, TypeError, ValueError):
            return None

    def whole(key):
        v = n(key)
        return None if v is None else int(v)

    rating = n("sqale_rating")
    return {"bugs": whole("bugs"), "vulnerabilities": whole("vulnerabilities"), "code_smells": whole("code_smells"),
            "maintainability_rating": RATINGS.get(int(rating)) if rating is not None else None,
            "duplicated_lines_density": n("duplicated_lines_density"), "coverage": n("coverage")}


def scan(repo_dir, startup_secs=600.0, analysis_secs=900.0, log=lambda m: None):
    """The sonarqube object for repo_dir; raises Skip with the reason when it cannot be had."""
    if not os.path.isdir(repo_dir):
        raise Skip(f"no repo to scan at {repo_dir}")
    if not shutil.which("docker") and _resolve(["docker"]) == ["docker"]:
        raise Skip("docker is not installed")
    p = _docker(["info", "--format", "{{.ServerVersion}}"], 30, check=False)
    if p.returncode != 0:
        raise Skip("docker daemon not reachable: " + (p.stderr or p.stdout).strip()[-150:])
    server_image = os.environ.get("BENCH_SONAR_IMAGE") or SERVER_IMAGE
    scanner_image = os.environ.get("BENCH_SONAR_SCANNER_IMAGE") or SCANNER_IMAGE
    tag = "bench-sonar-" + uuid.uuid4().hex[:10]
    key = "bench"
    made_net = made_srv = False
    try:
        _docker(["network", "create", tag], 60)
        made_net = True
        # Elasticsearch refuses to start when its data dir's filesystem has under 10% free, and a bench host's
        # disk is often fuller than that; the data dir is throwaway, so it goes on a tmpfs (#588).
        _docker(["run", "-d", "--name", tag, "--network", tag, "-p", "127.0.0.1::9000",
                 "--tmpfs", f"/opt/sonarqube/data:size={tmpfs_size()}",
                 "-e", "SONAR_SEARCH_JAVAADDITIONALOPTS=-Dnode.store.allow_mmap=false",
                 server_image], 1800)       # a first run pulls the image
        made_srv = True
        port = _docker(["port", tag, "9000/tcp"], 30).stdout.strip().splitlines()
        m = re.search(r":(\d+)\s*$", port[0]) if port else None
        if not m:
            raise Skip("could not find the SonarQube port")
        base = f"http://127.0.0.1:{m.group(1)}"
        log(f"sonarqube {tag} on {base}")

        def up():
            if _docker(["inspect", "-f", "{{.State.Running}}", tag], 30, check=False).stdout.strip() == "false":
                lg = _docker(["logs", tag], 30, check=False)
                raise Skip("the SonarQube container exited: " + failure_reason(lg.stdout + "\n" + lg.stderr))
            return _api(base, "/api/system/status").get("status") == "UP"
        _wait("SonarQube", startup_secs, up)
        token = _api(base, "/api/user_tokens/generate?name=bench", "POST").get("token")
        if not token:
            raise Skip("SonarQube gave no analysis token")

        sc = _docker(["run", "--rm", "--network", tag, "-e", f"SONAR_HOST_URL=http://{tag}:9000",
                      "-e", f"SONAR_TOKEN={token}", "-v", f"{os.path.abspath(repo_dir)}:/usr/src:ro",
                      scanner_image, f"-Dsonar.projectKey={key}", "-Dsonar.sources=.",
                      "-Dsonar.exclusions=**/.git/**", "-Dsonar.scm.disabled=true",
                      "-Dsonar.working.directory=/tmp/scannerwork"], analysis_secs, check=False)
        out = sc.stdout + "\n" + sc.stderr
        if sc.returncode != 0:
            raise Skip("the scanner failed: " + " ".join(out.strip().splitlines()[-1:])[-200:])
        t = TASK_RE.search(out)
        if not t:
            raise Skip("the scanner named no analysis task")

        def done():
            st = _api(base, "/api/ce/task?id=" + t.group(1)).get("task", {}).get("status")
            if st in ("FAILED", "CANCELED"):
                raise Skip(f"the analysis {st.lower()}")
            return st == "SUCCESS"
        _wait("the analysis", analysis_secs, done)
        comp = _api(base, f"/api/measures/component?component={key}&metricKeys={','.join(METRICS)}")
        return measures(comp.get("component", {}).get("measures"))
    except urllib.error.HTTPError as e:
        raise Skip(f"SonarQube answered {e.code} {e.reason}")
    finally:
        if made_srv:
            # -v: the image declares anonymous volumes, which would otherwise pile up on the host after every scan (#588)
            _docker(["rm", "-f", "-v", tag], 120, check=False)
        if made_net:
            _docker(["network", "rm", tag], 60, check=False)


def fragment(repo_dir, **kw):
    """{"quality": ..., ["sonarqube": {...}]} — never raises."""
    try:
        return {"quality": "ok", "sonarqube": scan(repo_dir, **kw)}
    except Skip as e:
        return skipped(e)
    except Exception as e:   # anything unforeseen is still a skip: this must not fail a bench run
        return skipped(f"unexpected {type(e).__name__}: {e}")


def merge_into(path, frag):
    """Write frag into the arm results file, dropping a stale sonarqube object on a skip."""
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    doc.pop("sonarqube", None)
    doc.update(frag)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Optional SonarQube Community scan of an arm's final default branch.")
    ap.add_argument("repo_dir")
    ap.add_argument("--arm-json", help="merge the fragment into this arm results file")
    ap.add_argument("--startup-secs", type=float, default=600.0)
    ap.add_argument("--analysis-secs", type=float, default=900.0)
    a = ap.parse_args(argv)
    frag = fragment(a.repo_dir, startup_secs=a.startup_secs, analysis_secs=a.analysis_secs,
                    log=lambda m: print("quality.py: " + m, file=sys.stderr))
    if a.arm_json:
        try:
            merge_into(a.arm_json, frag)
        except (OSError, ValueError) as e:
            print(f"quality.py: could not update {a.arm_json}: {e}", file=sys.stderr)
    print(json.dumps(frag))
    return 0


if __name__ == "__main__":
    sys.exit(main())

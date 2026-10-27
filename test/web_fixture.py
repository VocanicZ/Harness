#!/usr/bin/env python3
"""web_fixture.py — the shared rig for every `harness web` test (#223 onwards).

serving() builds a throwaway HARNESS_HOME from test/fixtures/web/ (the fleet registry, the board
snapshots, one project dir per fleet holding its fixture config), puts a bin dir first on PATH whose
`gh` only records that it was called and whose `tmux` prints $WEB_TMUX_LS, and serves web.Model on
127.0.0.1:0 in a daemon thread. Nothing here reads the real ~/.harness.

Registry records in the fixtures carry @PROJECT_<prefix>@ / @RUN_<prefix>@ placeholders; serving()
rewrites them to the temp project dirs. Fleet `hz` gets worker-1.pid = this process (alive, so
RUNNING), a dead.pid (a reaped child's pid) and the launch context of hz-arc-i11 (#225); `dp` gets
no pid file (STOPPED). The supervisor's state (supervise/, supervise.log, supervise.conf) and the
rate-limit files (ghrate/) are copied into the host, pane files stamped as written at NOW.
"""
import contextlib, http.client, importlib.util, json, os, shutil, subprocess, sys, tempfile, threading, time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
FIX = os.path.join(HERE, "fixtures", "web")
NOW = 1_800_000_000
_ENV_KEYS = ("HARNESS_HOME", "HARNESS_FLEETS_DIR", "HARNESS_SNAPSHOTS_DIR", "HARNESS_POLLER_DIR",
             "HARNESS_SUPERVISE_STATE", "HARNESS_SUPERVISE_LOG", "HARNESS_SUPERVISE_CONF",
             "HARNESS_GH_RATE_DIR", "PATH", "WEB_GH_CALLED", "WEB_TMUX_LS")


def load(name):
    """scripts/<name>.py as a module. normpath: coverage records the filename it is given, and an
    unnormalized `test/../scripts/…` would credit these lines to a path that is not scripts/<name>.py."""
    if name in sys.modules:
        return sys.modules[name]
    path = os.path.join(ROOT, "scripts", name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def dead_pid():
    """A pid that was alive a moment ago and is not now: a reaped child's."""
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


class Host:
    """The temp host: .home (HARNESS_HOME), .fleets, .snapshots, .projects {prefix: state dir},
    .gh_called (the marker the stub gh touches — it must never exist)."""

    def __init__(self, root):
        self.root = root
        self.home = os.path.join(root, "host")
        self.fleets = os.path.join(self.home, "fleets")
        self.snapshots = os.path.join(self.home, "snapshots")
        self.bin = os.path.join(root, "bin")
        self.gh_called = os.path.join(root, "gh-called")
        self.projects = {}

    def add_fleet(self, prefix, slugs, config="", alive=False, rec_extra=None):
        """Register one more fleet: a project dir with <config> and, if alive, a live worker pid."""
        state = os.path.join(self.root, "projects", prefix, ".harness")
        run = os.path.join(state, "run")
        os.makedirs(run, exist_ok=True)
        with open(os.path.join(state, "config"), "w") as fh:
            fh.write(config)
        if alive:
            with open(os.path.join(run, "worker-1.pid"), "w") as fh:
                fh.write(str(os.getpid()))
        rec = {"prefix": prefix, "project": state, "run_dir": run, "slugs": list(slugs),
               "started_at": NOW - 3600}
        rec.update(rec_extra or {})
        with open(os.path.join(self.fleets, prefix + ".json"), "w") as fh:
            json.dump(rec, fh)
        self.projects[prefix] = state
        return state

    def write_json(self, path, data):
        with open(path, "w") as fh:
            json.dump(data, fh)

    def write_snapshot(self, slug, snap):
        with open(os.path.join(self.snapshots, slug.replace("/", "__") + ".json"), "w") as fh:
            json.dump(snap, fh)


def build_host(root):
    host = Host(root)
    os.makedirs(host.fleets)
    shutil.copytree(os.path.join(FIX, "snapshots"), host.snapshots)
    for name in sorted(os.listdir(os.path.join(FIX, "fleets"))):
        prefix = name[:-len(".json")]
        with open(os.path.join(FIX, "fleets", name)) as fh:
            rec = json.load(fh)
        with open(os.path.join(FIX, "config." + prefix)) as fh:
            config = fh.read()
        host.add_fleet(prefix, rec["slugs"], config, alive=(prefix == "hz"),
                       rec_extra={"started_at": rec["started_at"]})
    for name in ("supervise", "ghrate"):
        shutil.copytree(os.path.join(FIX, name), os.path.join(host.home, name))
    for name in ("supervise.log", "supervise.conf"):
        shutil.copy(os.path.join(FIX, name), host.home)
    panes = os.path.join(host.home, "supervise", "panes")
    for name in os.listdir(panes):
        os.utime(os.path.join(panes, name), (NOW, NOW))     # the supervisor's last pass was just now
    hz_run = os.path.join(host.projects["hz"], "run")
    with open(os.path.join(hz_run, "dead.pid"), "w") as fh:
        fh.write(str(dead_pid()))
    host.write_json(os.path.join(hz_run, "hz-arc-i11.stats"),
                    {"prefix": "hz", "repo": "o/arc", "issue": 11, "kind": "impl",
                     "model": "claude-opus-5-5", "launched": NOW - 600})
    os.makedirs(host.bin)
    stubs = {"gh": '#!/bin/sh\ntouch "$WEB_GH_CALLED"\nexit 1\n',
             "tmux": '#!/bin/sh\nprintf "%s" "$WEB_TMUX_LS"\n'}
    for name, body in stubs.items():
        path = os.path.join(host.bin, name)
        with open(path, "w") as fh:
            fh.write(body)
        os.chmod(path, 0o755)
    return host


@contextlib.contextmanager
def serving(tmux_ls="", now=None, tick=None, events="events.jsonl"):
    """(base_url, host) for a web server over a fresh fixture host. `now` pins the model's clock;
    `tick` and `events` are for the later tasks' collector and event log (unused before #227)."""
    web = load("web")
    root = tempfile.mkdtemp(prefix="harness-web-")
    saved = {k: os.environ.get(k) for k in _ENV_KEYS}
    srv = None
    try:
        host = build_host(root)
        os.environ.update({
            "HARNESS_HOME": host.home, "HARNESS_FLEETS_DIR": host.fleets,
            "HARNESS_SNAPSHOTS_DIR": host.snapshots, "HARNESS_POLLER_DIR": os.path.join(host.home, "poller"),
            "HARNESS_SUPERVISE_STATE": os.path.join(host.home, "supervise"),
            "HARNESS_SUPERVISE_LOG": os.path.join(host.home, "supervise.log"),
            "HARNESS_SUPERVISE_CONF": os.path.join(host.home, "supervise.conf"),
            "HARNESS_GH_RATE_DIR": os.path.join(host.home, "ghrate"),
            "PATH": host.bin + os.pathsep + (saved["PATH"] or ""),
            "WEB_GH_CALLED": host.gh_called, "WEB_TMUX_LS": tmux_ls,
        })
        clock = (lambda: now) if now is not None else (lambda: NOW + 30)
        srv = web.make_server("127.0.0.1", 0, web.Model(clock=clock))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        yield f"http://127.0.0.1:{srv.server_address[1]}", host
    finally:
        if srv is not None:
            srv.shutdown()
            srv.server_close()
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(root, ignore_errors=True)


def request(method, url, body=None):
    """(status, body text) — raw http.client, so the path reaches the server exactly as written
    (no client-side `..` folding) and a 4xx/5xx is a result, not an exception."""
    u = urllib.parse.urlsplit(url)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
    try:
        conn.request(method, u.path + (("?" + u.query) if u.query else ""), body=body)
        resp = conn.getresponse()
        return resp.status, resp.read().decode("utf-8", "replace")
    finally:
        conn.close()


def get(url):
    return request("GET", url)


def get_json(url):
    code, body = get(url)
    assert code == 200, f"GET {url} -> {code}"
    return json.loads(body)


def headers(url, method="GET"):
    u = urllib.parse.urlsplit(url)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
    try:
        conn.request(method, u.path)
        resp = conn.getresponse()
        resp.read()
        return dict(resp.getheaders())
    finally:
        conn.close()


def run_tests(ns):
    """Run every test_* callable in <ns>; 1 if any failed."""
    fails = 0
    for name, fn in list(ns.items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn(); print(f"  ok: {name}")
            except (AssertionError, OSError) as e:
                print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails) + ' FAILED'}")
    return 1 if fails else 0

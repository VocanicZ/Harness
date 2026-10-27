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
rate-limit files (ghrate/) are copied into the host, pane files stamped as written at NOW. The
recorded event log (events.jsonl, #228's session timelines) becomes the host's.
"""
import contextlib, http.client, importlib.util, json, os, shutil, subprocess, sys, tempfile, threading, time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
FIX = os.path.join(HERE, "fixtures", "web")
NOW = 1_800_000_000
_ENV_KEYS = ("HARNESS_HOME", "HARNESS_FLEETS_DIR", "HARNESS_SNAPSHOTS_DIR", "HARNESS_POLLER_DIR",
             "HARNESS_SUPERVISE_STATE", "HARNESS_SUPERVISE_LOG", "HARNESS_SUPERVISE_CONF",
             "HARNESS_GH_RATE_DIR", "HARNESS_EVENTS_FILE", "HARNESS_RTDD_EVENTS_FILE", "PATH", "WEB_GH_CALLED",
             "WEB_TMUX_LS")


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
    """A pid that was alive a moment ago and is not now: a reaped child's. sys.executable, not `true`:
    inside serving() PATH is the stub bin dir + whatever the runner had, which may be nothing."""
    p = subprocess.Popen([sys.executable, "-c", ""])
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

    def write_board(self, name, issues, generated_at):
        """Replace <name>.json's issues and generated_at, atomically, as the poller writes it."""
        path = os.path.join(self.snapshots, name + ".json")
        with open(path) as fh:
            snap = json.load(fh)
        snap.update(issues=issues, generated_at=generated_at)
        with open(path + ".tmp", "w") as fh:
            json.dump(snap, fh)
        os.replace(path + ".tmp", path)

    def set_tmux(self, ls):
        """What the stub `tmux ls` prints from now on (it reads $WEB_TMUX_LS on every call)."""
        os.environ["WEB_TMUX_LS"] = ls

    def drop_streams(self):
        """Close every open SSE stream, the way a server restart would (#227)."""
        self.model.close_streams()


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
    `tick` is the SSE collector's period (#227); `events` names the fixture event log the host gets
    (None: no event log at all)."""
    web = load("web")
    root = tempfile.mkdtemp(prefix="harness-web-")
    saved = {k: os.environ.get(k) for k in _ENV_KEYS}
    srv = model = None
    try:
        host = build_host(root)
        events_file = os.path.join(host.home, "events.jsonl")
        if events:
            shutil.copy(os.path.join(FIX, events), events_file)
        os.environ.update({
            "HARNESS_HOME": host.home, "HARNESS_FLEETS_DIR": host.fleets,
            "HARNESS_SNAPSHOTS_DIR": host.snapshots, "HARNESS_POLLER_DIR": os.path.join(host.home, "poller"),
            "HARNESS_SUPERVISE_STATE": os.path.join(host.home, "supervise"),
            "HARNESS_SUPERVISE_LOG": os.path.join(host.home, "supervise.log"),
            "HARNESS_SUPERVISE_CONF": os.path.join(host.home, "supervise.conf"),
            "HARNESS_GH_RATE_DIR": os.path.join(host.home, "ghrate"),
            "HARNESS_EVENTS_FILE": events_file,
            "HARNESS_RTDD_EVENTS_FILE": os.path.join(host.home, "rtdd-events.jsonl"),
            "PATH": host.bin + os.pathsep + (saved["PATH"] or ""),
            "WEB_GH_CALLED": host.gh_called, "WEB_TMUX_LS": tmux_ls,
        })
        clock = (lambda: now) if now is not None else (lambda: NOW + 30)
        model = host.model = web.Model(clock=clock, tick=tick)
        srv = web.make_server("127.0.0.1", 0, model)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        yield f"http://127.0.0.1:{srv.server_address[1]}", host
    finally:
        if model is not None:
            model.stop()
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
        conn.request(method, u.path + (("?" + u.query) if u.query else ""))
        resp = conn.getresponse()
        resp.read()
        return dict(resp.getheaders())
    finally:
        conn.close()


class SSE:
    """One open `text/event-stream` response, read frame by frame. .last_id is the last `id:` seen."""

    def __init__(self, sock, resp):
        self.sock, self.resp, self.last_id = sock, resp, None

    def frame(self, timeout):
        """{field: value} of the next frame (a ":" comment is {"comment": …}); None at end of stream.
        Raises TimeoutError when nothing completes a frame within <timeout> seconds."""
        self.sock.settimeout(timeout)
        out = {}
        while True:
            try:
                line = self.resp.fp.readline()
            except (TimeoutError, OSError) as e:
                raise TimeoutError("no SSE frame in %ss" % timeout) from e
            if not line:
                return None
            line = line.decode("utf-8").rstrip("\r\n")
            if not line:
                if out:
                    if "id" in out:
                        self.last_id = out["id"]
                    return out
                continue
            field, _, value = line.partition(":")
            out[field or "comment"] = value[1:] if value.startswith(" ") else value

    def first_retry(self):
        f = self.frame(5)
        assert f and "retry" in f, f"first frame is not retry: {f}"
        return int(f["retry"])

    def next_event(self, name, timeout=5, missing_ok=False):
        """The data (parsed JSON) of the next `event: <name>` frame within <timeout> seconds."""
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            try:
                f = self.frame(max(left, 0.01)) if left > 0 else None
            except TimeoutError:
                f = None
            if f is None:
                if missing_ok:
                    return None
                raise AssertionError(f"no `event: {name}` within {timeout}s")
            if f.get("event") == name:
                return json.loads(f["data"])

    def closed(self, timeout=5):
        """True once the server ends the stream (pings in between are skipped)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if self.frame(max(deadline - time.monotonic(), 0.01)) is None:
                    return True
            except TimeoutError:
                return False
        return False


@contextlib.contextmanager
def sse(url, last_event_id=None):
    """An SSE stream on <url>, as an EventSource would open it (Last-Event-ID on a reconnect)."""
    u = urllib.parse.urlsplit(url)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
    try:
        hdrs = {"Accept": "text/event-stream"}
        if last_event_id:
            hdrs["Last-Event-ID"] = last_event_id
        conn.request("GET", u.path + (("?" + u.query) if u.query else ""), headers=hdrs)
        sock = conn.sock          # a `Connection: close` response detaches it from conn
        resp = conn.getresponse()
        assert resp.status == 200, f"GET {url} -> {resp.status}"
        assert resp.getheader("Content-Type", "").startswith("text/event-stream"), resp.getheaders()
        yield SSE(sock, resp)
    finally:
        conn.close()
        if "resp" in locals():
            resp.close()


class Page:
    """A page open in headless Chrome, driven through test/web_cdp.mjs one JSON line at a time."""

    def __init__(self, proc):
        self.proc = proc

    def _call(self, msg):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise AssertionError("web_cdp.mjs exited: " + self.proc.stderr.read())
        r = json.loads(line)
        if not r.get("ok"):
            raise AssertionError(f"{msg.get('op')} {msg.get('expr')!r}: {r.get('error')}")
        return r.get("value")

    def eval(self, expr):
        return self._call({"op": "eval", "expr": expr})

    def wait(self, expr, timeout):
        """Poll <expr> in the page until it is truthy; fails after <timeout> seconds."""
        return self._call({"op": "wait", "expr": expr, "timeout": timeout})

    def key(self, name, shift=False):
        """Press and release one real key (Enter, Escape, Tab) — trusted input, not a synthetic event."""
        return self._call({"op": "key", "key": name, "shift": shift})

    def viewport(self, width, height=800):
        """Resize the page's viewport to <width> x <height> CSS px (#228's 400 px check)."""
        return self._call({"op": "viewport", "width": width, "height": height})


@contextlib.contextmanager
def cdp(browser, url):
    """<url> loaded in headless <browser>; yields a Page. The browser dies with the context."""
    proc = subprocess.Popen(["node", os.path.join(HERE, "web_cdp.mjs"), browser, url], text=True,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        ready = proc.stdout.readline()
        if not ready or not json.loads(ready).get("ok"):
            raise AssertionError(f"browser did not open {url}: {ready} {proc.stderr.read() if not ready else ''}")
        yield Page(proc)
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill(); proc.wait()


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

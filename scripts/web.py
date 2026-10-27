#!/usr/bin/env python3
"""web.py — `harness web`: the local, read-only dashboard server (#223, PRD #192).

A Python-stdlib ThreadingHTTPServer on HARNESS_WEB_BIND (default 127.0.0.1) : HARNESS_WEB_PORT
(default 4637). `/` is the host overview: every fleet registered under $HARNESS_FLEETS_DIR with its
state, the view `harness status` gives outside a project (#184), each linking to /fleet/<prefix>:
that fleet's PRD → issue map as a layered DAG per repo (#224).

Read-only is the safety boundary — the page has no auth. Every route answers GET and HEAD only;
POST/PUT/PATCH/DELETE/OPTIONS get 405 on every path, known or not. Pages read only local snapshots
(web_data.py) and never run `gh`. Static files come from an allow-list of web/static/ taken at start,
so no request path can reach outside it.

Live updates (#227): `GET /events?view=<page path>` is a Server-Sent Events stream. A collector thread
(started by the first stream) compares web_data.signature() every HARNESS_WEB_TICK seconds (default 2)
and, when it moves, re-renders every page a stream has asked for; each stream then sends the regions
whose HTML changed since it last sent them. It watches local files only, like every other route.
"""
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import web_data    # noqa: E402
import web_render  # noqa: E402

DEFAULT_BIND, DEFAULT_PORT = "127.0.0.1", 4637
STATIC_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "web", "static")
CSP = "default-src 'self'; style-src 'self'; script-src 'self'"
TYPES = {".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".woff2": "font/woff2", ".svg": "image/svg+xml", ".png": "image/png"}
PREFIX_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
RETRY_MS = 3000   # how long a dropped EventSource waits before it reconnects
PING_S = 15       # an idle stream sends a `: ping` comment this often, so a dead client is noticed
USAGE = "usage: harness web   (serves on $HARNESS_WEB_BIND:$HARNESS_WEB_PORT, default 127.0.0.1:4637)"


def bind_addr(env):
    """(host, port) from HARNESS_WEB_BIND / HARNESS_WEB_PORT — the one place either is read.
    An empty value means unset; a port that is not an integer raises ValueError."""
    host = env.get("HARNESS_WEB_BIND") or DEFAULT_BIND
    port = env.get("HARNESS_WEB_PORT") or ""
    return host, (int(port) if port.strip() else DEFAULT_PORT)


class Model:
    """The views the server hands out. Each page call reads the local state afresh; the live renderings
    the SSE streams share are cached per page path and refreshed by the collector."""

    def __init__(self, clock=time.time, tick=None):
        self.clock = clock
        self.tick = float(tick if tick is not None else (os.environ.get("HARNESS_WEB_TICK") or 2))
        self.max_streams = int(os.environ.get("HARNESS_WEB_MAX_STREAMS") or 32)
        self._cond = threading.Condition()
        self._live = {}          # page path -> {"version", "regions", "asof"}
        self._streams = 0
        self._epoch = 0          # close_streams() bumps it: every stream opened before then ends
        self._stopped = False
        self._collector = None
        self._sig = None

    def now(self):
        return int(self.clock())

    def host(self, now=None):
        return web_data.host_view(self.now() if now is None else now)

    def fleet(self, prefix, now=None):
        for f in self.host(now)["fleets"]:
            if f["prefix"] == prefix:
                return f
        return None

    def fleet_page(self, prefix, now=None):
        """The /fleet/<prefix> view (web_data.fleet_view), or None for an unknown prefix."""
        return web_data.fleet_view(prefix, self.now() if now is None else now)

    # --- live updates (#227) -------------------------------------------------------------------
    def view(self, path, now=None):
        """The view dict behind the page at <path> ("/" or "/fleet/<prefix>"), else None."""
        if path == "/":
            return self.host(now)
        m = re.match(r"^/fleet/([^/]+)$", path)
        return self.fleet_page(m.group(1), now) if m and PREFIX_RE.match(m.group(1)) else None

    def render(self, path):
        """{"version", "regions", "asof"} for the page at <path> as it reads now, or None."""
        now = self.now()
        v = self.view(path, now)
        if v is None:
            return None
        regs = web_render.regions(path, v, now)
        return {"version": web_render.version(regs), "regions": regs, "asof": v["asof"]}

    def live(self, path):
        """The shared live rendering of <path> (None for no such page); the first one starts the collector."""
        with self._cond:
            entry = self._live.get(path)
        if entry is None:
            entry = self.render(path)
            if entry is None:
                return None
            with self._cond:
                entry = self._live.setdefault(path, entry)
        self._start()
        return entry

    def version(self, path):
        entry = self.live(path)
        return entry and entry["version"]

    @property
    def epoch(self):
        return self._epoch

    def wait(self, path, version, timeout, epoch=None):
        """Block until <path>'s version is not <version> or <timeout> passes; the version then. None
        means end the stream: the server is stopping, or close_streams() ran since <epoch>."""
        def done():
            return self._stopped or (epoch is not None and self._epoch != epoch) or \
                (self._live.get(path) or {}).get("version") != version
        with self._cond:
            self._cond.wait_for(done, timeout)
            if self._stopped or (epoch is not None and self._epoch != epoch):
                return None
            entry = self._live.get(path)
            return entry["version"] if entry else ""

    def open_stream(self):
        """Take one of HARNESS_WEB_MAX_STREAMS stream slots; False when all are in use."""
        with self._cond:
            if self._streams >= self.max_streams:
                return False
            self._streams += 1
            return True

    def close_stream(self):
        with self._cond:
            self._streams -= 1

    def close_streams(self):
        """End every open stream, as a server restart would (clients reconnect after RETRY_MS)."""
        with self._cond:
            self._epoch += 1
            self._cond.notify_all()

    def stop(self):
        with self._cond:
            self._stopped = True
            self._cond.notify_all()
        if self._collector is not None:
            self._collector.join(timeout=5)

    def _start(self):
        with self._cond:
            if self._collector is not None or self._stopped:
                return
            self._collector = threading.Thread(target=self._collect, name="harness-web-collector", daemon=True)
            self._collector.start()

    def _collect(self):
        """Every tick: when web_data.signature() (or the minute, which ages every relative time on
        the page) has moved, re-render each live page and wake the streams."""
        while True:
            with self._cond:
                if self._cond.wait_for(lambda: self._stopped, self.tick):
                    return
                paths = list(self._live)
            try:
                sig = (web_data.signature(), self.now() // 60)
                if sig == self._sig:
                    continue
                fresh = {p: self.render(p) for p in paths}
            except Exception as e:   # a bad tick must not end live updates for good
                print(f"harness web: collector: {e!r}", file=sys.stderr, flush=True)
                continue
            self._sig = sig
            with self._cond:
                for p, entry in fresh.items():
                    if entry is None:
                        self._live.pop(p, None)   # the fleet left the registry: its streams end
                    else:
                        self._live[p] = entry
                self._cond.notify_all()


def static_files():
    try:
        return frozenset(n for n in os.listdir(STATIC_DIR) if os.path.isfile(os.path.join(STATIC_DIR, n)))
    except OSError:
        return frozenset()


def make_server(bind, port, model):
    allowed = static_files()

    class Handler(BaseHTTPRequestHandler):
        server_version = "harness-web"
        sys_version = ""

        def log_message(self, fmt, *args):   # quiet: the dashboard is polled, its access log is noise
            pass

        def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", cache="no-store", extra=()):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Security-Policy", CSP)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Cache-Control", cache)
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _reject(self):
            # A write method never reaches a route. Close the connection: its body is never read.
            self.close_connection = True
            self._send(405, b"read-only: GET and HEAD only\n", extra=(("Allow", "GET, HEAD"), ("Connection", "close")))

        do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = _reject

        def _html(self, text):
            self._send(200, text.encode("utf-8"), "text/html; charset=utf-8")

        def _json(self, obj):
            self._send(200, (json.dumps(obj, indent=1) + "\n").encode("utf-8"), "application/json")

        def _not_found(self):
            self._send(404, b"not found\n")

        def _frame(self, text):
            self.wfile.write(text.encode("utf-8"))
            self.wfile.flush()

        def _events(self, query):
            """`GET /events?view=<path>`: `retry:`, then `event: patch` frames carrying {"asof", "regions":
            {id: html}} for the regions that changed, each with `id: <version>`. A client that names an
            older version (Last-Event-ID on a reconnect, or `since=` from the page it loaded) first
            gets every region; one that names none, or the current one, gets only later changes."""
            q = parse_qs(query)
            path = (q.get("view") or [""])[0]
            entry = model.live(path) if path else None
            if entry is None:
                return self._not_found()
            if not model.open_stream():
                return self._send(503, b"too many live streams\n", extra=(("Retry-After", "30"),))
            try:
                self.close_connection = True
                self.send_response(200)
                for k, v in (("Content-Type", "text/event-stream; charset=utf-8"), ("Cache-Control", "no-store"),
                             ("Content-Security-Policy", CSP), ("X-Content-Type-Options", "nosniff"),
                             ("Connection", "close")):
                    self.send_header(k, v)
                self.end_headers()
                if self.command == "HEAD":
                    return
                epoch = model.epoch
                last = self.headers.get("Last-Event-ID") or (q.get("since") or [""])[0]
                if not last:
                    last = entry["version"]
                sent = entry["regions"] if last == entry["version"] else {}
                self._frame(f"retry: {RETRY_MS}\n\n")
                while True:
                    if entry["version"] != last:
                        changed = {k: v for k, v in entry["regions"].items() if sent.get(k) != v}
                        data = json.dumps({"asof": entry["asof"], "regions": changed})
                        self._frame(f"id: {entry['version']}\nevent: patch\ndata: {data}\n\n")
                        sent, last = entry["regions"], entry["version"]
                    v = model.wait(path, last, PING_S, epoch)
                    if v is None:
                        return
                    if v == last:
                        self._frame(": ping\n\n")
                        continue
                    entry = model.live(path)
                    if entry is None:
                        return
            except OSError:   # the client went away
                return
            finally:
                model.close_stream()

        def do_GET(self):
            url = urlsplit(self.path)
            path = url.path
            if path == "/events":
                return self._events(url.query)
            now = model.now()
            if path == "/":
                return self._html(web_render.overview(model.host(now), now))
            if path == "/api/host":
                return self._json(model.host(now))
            m = re.match(r"^/(api/)?fleet/([^/]+)$", path)
            if m and PREFIX_RE.match(m.group(2)):
                f = model.fleet(m.group(2), now) if m.group(1) else model.fleet_page(m.group(2), now)
                if f is None:
                    return self._not_found()
                return self._json(f) if m.group(1) else self._html(web_render.fleet(f, now))
            if path.startswith("/static/"):
                name = path[len("/static/"):]
                if name in allowed:
                    try:
                        with open(os.path.join(STATIC_DIR, name), "rb") as fh:
                            data = fh.read()
                    except OSError:
                        return self._not_found()
                    ctype = TYPES.get(os.path.splitext(name)[1], "application/octet-stream")
                    return self._send(200, data, ctype, cache="max-age=60")
            return self._not_found()

        do_HEAD = do_GET

    return ThreadingHTTPServer((bind, port), Handler)


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(USAGE)
        return 0
    if argv:
        print(f"harness web: unknown argument: {argv[0]}\n{USAGE}", file=sys.stderr)
        return 2
    try:
        bind, port = bind_addr(os.environ)
    except ValueError:
        print(f"harness web: HARNESS_WEB_PORT is not a port: {os.environ.get('HARNESS_WEB_PORT')!r}", file=sys.stderr)
        return 2
    model = Model()
    try:
        srv = make_server(bind, port, model)
    except OSError as e:
        print(f"harness web: cannot listen on {bind}:{port}: {e}", file=sys.stderr)
        return 1
    print(f"harness web: serving http://{bind}:{srv.server_address[1]}/", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        model.stop()
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

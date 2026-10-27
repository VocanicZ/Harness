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
"""
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import web_data    # noqa: E402
import web_render  # noqa: E402

DEFAULT_BIND, DEFAULT_PORT = "127.0.0.1", 4637
STATIC_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "web", "static")
CSP = "default-src 'self'; style-src 'self'; script-src 'self'"
TYPES = {".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".woff2": "font/woff2", ".svg": "image/svg+xml", ".png": "image/png"}
PREFIX_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
USAGE = "usage: harness web   (serves on $HARNESS_WEB_BIND:$HARNESS_WEB_PORT, default 127.0.0.1:4637)"


def bind_addr(env):
    """(host, port) from HARNESS_WEB_BIND / HARNESS_WEB_PORT — the one place either is read.
    An empty value means unset; a port that is not an integer raises ValueError."""
    host = env.get("HARNESS_WEB_BIND") or DEFAULT_BIND
    port = env.get("HARNESS_WEB_PORT") or ""
    return host, (int(port) if port.strip() else DEFAULT_PORT)


class Model:
    """The views the server hands out. Each call reads the local state afresh."""

    def __init__(self, clock=time.time):
        self.clock = clock

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

        def do_GET(self):
            path = urlsplit(self.path).path
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
    try:
        srv = make_server(bind, port, Model())
    except OSError as e:
        print(f"harness web: cannot listen on {bind}:{port}: {e}", file=sys.stderr)
        return 1
    print(f"harness web: serving http://{bind}:{srv.server_address[1]}/", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

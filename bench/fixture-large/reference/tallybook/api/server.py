"""The HTTP server: sockets, request framing, the announce line and a clean stop on SIGINT / SIGTERM.

Every request runs in its own thread and opens its own Store (one connection per request), so requests never
share a database connection."""
import signal
import sys
import threading
from datetime import date
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .. import __version__
from ..export import to_json
from ..storage import Store
from .handlers import Reply
from .router import MAX_BODY, HttpError, Request, dispatch, error_response, split_target

_DRAIN_LIMIT = 8 * MAX_BODY
_JSON_TYPE = "application/json; charset=utf-8"


class ApiServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def __init__(self, address, db_path, today):
        super().__init__(address, Handler)
        self.db_path = db_path
        self.today = today


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"       # one request per connection
    timeout = 30

    def version_string(self):
        return "tallybook/" + __version__

    def log_message(self, format, *args):       # no access log: the only thing on stdout is the announce line
        pass

    # ---- reading

    def _read_body(self):
        """(body, error): the declared body, or an error when its length is unusable or over the limit. A body that
        is refused is still read off the socket (up to a bound) so that the client can read the answer."""
        declared = self.headers.get("Content-Length")
        if declared is None:
            return b"", None
        try:
            length = int(declared)
            if length < 0:
                raise ValueError(declared)
        except ValueError:
            return b"", HttpError(400, "bad_request", "invalid Content-Length: %s" % declared)
        if length <= MAX_BODY:
            return self.rfile.read(length), None
        left = min(length, _DRAIN_LIMIT)
        while left > 0:
            chunk = self.rfile.read(min(left, 65536))
            if not chunk:
                break
            left -= len(chunk)
        self.close_connection = True
        return b"", HttpError(413, "too_large", "the body is over %d bytes" % MAX_BODY)

    def _request(self):
        path, segments, params = split_target(self.path)
        body, body_error = self._read_body()
        return Request(method=self.command, path=path, segments=segments, params=params, body=body,
                       content_type=self.headers.get("Content-Type", ""), today=self.server.today or date.today(),
                       body_error=body_error)

    # ---- answering

    def _serve(self):
        try:
            req = self._request()
        except OSError:
            self.close_connection = True        # the client went away or stalled: nothing to answer
            return
        try:
            reply = dispatch(req, self.server.db_path)
        except Exception as exc:                # every failure is an answer, never a traceback
            status, body, headers = error_response(exc)
            if status == 500:
                print("tallybook: internal error: %r" % (exc,), file=sys.stderr, flush=True)
            self._send(status, to_json(body), _JSON_TYPE, headers)
        else:
            self._send_reply(reply)

    def _send_reply(self, reply):
        if reply.text is not None:
            self._send(reply.status, reply.text, reply.content_type)
        else:
            self._send(reply.status, to_json(reply.data), _JSON_TYPE)

    def _send(self, status, text, content_type, headers=None):
        payload = text.encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        except OSError:
            self.close_connection = True

    def send_error(self, code, message=None, explain=None):
        """Errors of the HTTP layer itself (a garbled request line, a line that is too long) get the same JSON
        error answer as everything else."""
        self.close_connection = True
        status, body, headers = error_response(HttpError(code, "bad_request", message or HTTPStatus(code).phrase))
        self._send(status, to_json(body), _JSON_TYPE, headers)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _serve


def serve(db_path, host="127.0.0.1", port=0, today=None):
    """Serve the book at `db_path` until SIGINT or SIGTERM; returns 0. The book must exist and be at the current
    schema version (the storage errors are raised before anything is printed). `today` (a date) is what "today"
    means to the requests that need it; None is the real date. Port 0 picks a free port; the first line printed,
    flushed, is `tallybook listening on http://HOST:PORT`."""
    with Store.open(db_path) as store:
        store.info()                    # refuses a book that needs `db migrate`
    httpd = ApiServer((host, port), db_path, today)
    print("tallybook listening on http://%s:%d" % httpd.server_address[:2], flush=True)

    def stop(signum, frame):
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    previous = {}
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous[sig] = signal.signal(sig, stop)
    try:
        httpd.serve_forever(poll_interval=0.05)
    finally:
        httpd.server_close()
        for sig, old in previous.items():
            signal.signal(sig, old)
    return 0

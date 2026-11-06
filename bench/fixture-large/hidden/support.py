"""Shared helpers of the large fixture's hidden tests: the library, the CLI and the HTTP API, black box.

The grader (bench/grade.py) puts the built package on PYTHONPATH and exports TALLYBOOK_CMD, a JSON argv list
that runs the CLI. Nothing here knows how a solution is laid out inside.
"""
import contextlib
import importlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request


def lib(name=None):
    """`import tallybook` (or tallybook.<name>)."""
    return importlib.import_module("tallybook" + ("." + name if name else ""))


def cli_argv():
    raw = os.environ.get("TALLYBOOK_CMD")
    return json.loads(raw) if raw else [sys.executable, "-m", "tallybook"]


def phase(name):
    """Tag a test (or a TestCase class) as valid only before (`pre`) or only after (`post`) the mid-run change."""
    assert name in ("pre", "post")

    def mark(obj):
        obj._phase = name
        return obj
    return mark


class Result:
    def __init__(self, rc, out, err):
        self.rc, self.out, self.err = rc, out, err

    def __iter__(self):
        return iter((self.rc, self.out, self.err))

    @property
    def json(self):
        return json.loads(self.out)

    @property
    def lines(self):
        return self.out.splitlines()


class Base(unittest.TestCase):
    """A scratch directory per test; `self.db` is a database path inside it that does not exist yet."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="tallybook-hidden-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.db = os.path.join(self.tmp, "book.db")

    def path(self, name):
        return os.path.join(self.tmp, name)

    def write(self, name, text, newline=None):
        p = self.path(name)
        with open(p, "w", encoding="utf-8", newline=newline) as fh:
            fh.write(text)
        return p

    def read(self, name):
        with open(self.path(name), encoding="utf-8", newline="") as fh:
            return fh.read()

    def tb(self, *args, stdin=None, db=True, cwd=None, timeout=60):
        """Run the CLI; `--db <self.db>` is put first unless db=False. Returns Result(rc, stdout, stderr)."""
        argv = cli_argv() + (["--db", self.db] if db else []) + [str(a) for a in args]
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True, encoding="utf-8",
                           cwd=cwd or self.tmp, timeout=timeout)
        return Result(p.returncode, p.stdout, p.stderr)

    def tb_ok(self, *args, **kw):
        r = self.tb(*args, **kw)
        self.assertEqual(r.rc, 0, "tallybook %s -> %s\n%s" % (" ".join(map(str, args)), r.rc, r.err))
        return r

    def init(self, *chart):
        """`tallybook init` plus accounts given as 'Assets:Bank' or ('Assets:Bank', 'USD')."""
        self.tb_ok("init")
        for acct in chart:
            self.tb_ok("account", "add", *([acct] if isinstance(acct, str) else list(acct)))


STANDARD_CHART = ["Assets:Bank:Checking", "Assets:Cash", "Liabilities:Card", "Equity:Opening",
                  "Income:Salary", "Expenses:Food", "Expenses:Rent", "Expenses:Fun"]


class Server:
    """`tallybook serve` in a subprocess on an ephemeral port; `.call(method, path, body=None)` -> (status, json|text)."""

    def __init__(self, db, extra=()):
        argv = cli_argv() + ["--db", db, "serve", "--port", "0"] + list(extra)
        self.proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.base = None
        line = ""
        timer = threading.Timer(20, self.proc.kill)
        timer.start()
        try:
            while True:
                line = self.proc.stdout.readline()
                if not line:
                    break
                m = re.search(r"http://127\.0\.0\.1:(\d+)", line)
                if m:
                    self.base = "http://127.0.0.1:%s" % m.group(1)
                    break
        finally:
            timer.cancel()
        if not self.base:
            self.close()
            raise AssertionError("tallybook serve did not announce its address: %r" % line)

    def call(self, method, path, body=None, headers=None, raw=None):
        data = raw if raw is not None else (None if body is None else json.dumps(body).encode("utf-8"))
        req = urllib.request.Request(self.base + path, data=data, method=method)
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        if data is not None and "Content-Type" not in (headers or {}):
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                status, ctype, payload = resp.status, resp.headers.get("Content-Type", ""), resp.read()
        except urllib.error.HTTPError as e:
            status, ctype, payload = e.code, e.headers.get("Content-Type", ""), e.read()
        text = payload.decode("utf-8")
        if "json" in ctype:
            return status, json.loads(text)
        return status, text

    def get(self, path, **kw):
        return self.call("GET", path, **kw)

    def post(self, path, body=None, **kw):
        return self.call("POST", path, body, **kw)

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        for stream in (self.proc.stdout, self.proc.stderr):
            with contextlib.suppress(Exception):
                stream.close()


class ApiBase(Base):
    """A server over a fresh, initialised database holding STANDARD_CHART."""

    def setUp(self):
        super().setUp()
        self.init(*STANDARD_CHART)
        self.srv = Server(self.db)
        self.addCleanup(self.srv.close)

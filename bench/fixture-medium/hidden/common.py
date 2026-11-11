"""Shared helpers for the hidden Stockroom tests (not a test module itself).

Black box: the library through `import stockroom`, the CLI through the command line. The grader exports
STOCKROOM_CMD, a JSON argv list that runs the CLI.
"""
import importlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import re
from decimal import Decimal as D

CATALOG = """\
# SKU   | name            | price | reorder | tax
AB-100 | Garden gnome     | 12.50 | 5       | standard
cd-205 | Seed packet, mix | 1.99  | 40      | reduced
EF-310 | Gift voucher     | 25.00 | 0
"""

MOVES = """\
2024-03-01 AB-100 +20 first delivery
2024-03-04 ab-100 -3 order SO-1001
2024-03-05 CD-205 40
"""

ORDERS = """\
SO-1001 2024-03-03 acme AB-100*12,CD-205*3
SO-1002 2024-03-09 Bea ab-100*2
"""

QUOTE_1001 = [
    "SO-1001 2024-03-03 acme",
    "AB-100 12 12.50 150.00 -7.50 142.50",
    "CD-205 3 1.99 5.97 0.00 5.97",
    "subtotal 148.47",
    "order discount 0.00",
    "tax 28.80",
    "total 177.27",
]


def lib():
    return importlib.import_module("stockroom")


def cli_argv():
    raw = os.environ.get("STOCKROOM_CMD")
    return json.loads(raw) if raw else [sys.executable, "-m", "stockroom"]


def cli_env():
    env = dict(os.environ)
    env["PYTHONIOENCODING"] = "utf-8"
    return env


def parse_catalog(text):
    return lib().parse_catalog(text)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="stockroom-hidden-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.seed()

    def seed(self):
        """Per-class starting state of the temp folder (override)."""

    def parts(self, *parts):
        """Run several independent scenarios as one test, each on a freshly seeded folder."""
        for part in parts:
            for entry in os.listdir(self.tmp):
                full = os.path.join(self.tmp, entry)
                shutil.rmtree(full) if os.path.isdir(full) and not os.path.islink(full) else os.remove(full)
            self.seed()
            with self.subTest(part=part.__name__):
                part()

    # ---- files -------------------------------------------------------------------------------
    def path(self, name):
        return os.path.join(self.tmp, name)

    def put(self, name, content):
        """Write `content` (str as UTF-8, or bytes) exactly as given, no newline translation."""
        data = content if isinstance(content, bytes) else content.encode("utf-8")
        with open(self.path(name), "wb") as fh:
            fh.write(data)

    def read(self, name):
        try:
            with open(self.path(name), "rb") as fh:
                return fh.read()
        except FileNotFoundError:
            return None

    def files(self, catalog=CATALOG, movements=MOVES, orders=ORDERS):
        """Write the three files; None means the file does not exist."""
        for name, content in (("catalog.txt", catalog), ("movements.txt", movements), ("orders.txt", orders)):
            if content is not None:
                self.put(name, content)
            elif os.path.exists(self.path(name)):
                os.remove(self.path(name))

    # ---- running the command ----------------------------------------------------------------
    def run_cli(self, *args, cwd=None, stdin=None):
        p = subprocess.run(cli_argv() + list(args), input=stdin, capture_output=True, cwd=cwd or self.tmp,
                           timeout=60, env=cli_env())
        return p.returncode, p.stdout.decode("utf-8"), p.stderr.decode("utf-8", "replace")

    def ok(self, *args):
        rc, out, err = self.run_cli(*args)
        self.assertEqual(rc, 0, "exit %s, stderr: %s" % (rc, err))
        return out

    def lines(self, *args):
        out = self.ok(*args)
        if out == "":
            return []
        self.assertTrue(out.endswith("\n"), "output does not end in a newline: %r" % out)
        return out[:-1].split("\n")

    def js(self, *args):
        return json.loads(self.ok(*args))

    def fails(self, *args, code=1, mentions=()):
        """The command must exit `code` with nothing on stdout and a message on stderr; returns the message."""
        rc, out, err = self.run_cli(*args)
        self.assertEqual((rc, out), (code, ""), "stderr: %s" % err)
        self.assertTrue(err.strip(), "no message on stderr")
        for word in mentions:
            self.assertIn(word, err)
        return err

    def assertParseError(self, func, *args, line):
        p = lib()
        with self.assertRaises(p.ParseError) as ctx:
            func(*args)
        exc = ctx.exception
        self.assertIsInstance(exc, ValueError)
        self.assertEqual(exc.line, line)
        self.assertTrue(re.search(r"line %d\b" % line, str(exc)), "message %r does not mention line %d" % (str(exc), line))

    def assertMoney(self, value, text):
        self.assertIsInstance(value, D)
        self.assertEqual(value, D(text))
        self.assertEqual(value.as_tuple().exponent, -2, "%r is not a two-decimal value" % (value,))


def delta_of(value):
    """A history delta as an int, whether the JSON spells it as a number or as a signed string."""
    return int(value)

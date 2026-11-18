"""Shared helpers for the hidden Tabula tests (not a test module itself). Black box: the command line only, plus `import tabula`.
The grader exports TABULA_CMD, a JSON argv list that runs the CLI."""
import json
import os
import subprocess
import sys
import tempfile
import unittest


def cli_argv():
    raw = os.environ.get("TABULA_CMD")
    return json.loads(raw) if raw else [sys.executable, "-m", "tabula"]


def run_cli(argv, files=None):
    """(exit status, stdout, stderr, the folder's files afterwards) of one command line run in a fresh folder."""
    with tempfile.TemporaryDirectory() as folder:
        for name, data in (files or {}).items():
            with open(os.path.join(folder, name), "wb") as fh:
                fh.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        p = subprocess.run(cli_argv() + list(argv), cwd=folder, env=env, capture_output=True, timeout=60)
        after = {n: open(os.path.join(folder, n), "rb").read() for n in sorted(os.listdir(folder))}
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"), after


def case_test(case):
    """A test method for one row of a table: (name, files, argv, status, stdout or substrings of stderr)."""
    _, files, argv, status, want = case

    def test(self):
        rc, out, err, after = run_cli(argv, files)
        self.assertEqual(rc, status, "exit status; stderr: %s" % err.strip()[:200])
        if status == 0:
            self.assertEqual(out, want)
            self.assertEqual(err, "", "standard error stays empty")
        else:
            self.assertEqual(out, "", "nothing on standard output after a mistake")
            self.assertTrue(err.strip(), "a message on standard error")
            for piece in want:
                self.assertIn(piece, err)
        for name, data in (files or {}).items():
            raw = data if isinstance(data, bytes) else data.encode("utf-8")
            self.assertEqual(after.get(name), raw, "%s is left as it was" % name)
    return test


def make_class(name, cases):
    """A TestCase named `name` with one test per case row."""
    body = {"test_" + c[0]: case_test(c) for c in cases}
    return type(name, (unittest.TestCase,), body)

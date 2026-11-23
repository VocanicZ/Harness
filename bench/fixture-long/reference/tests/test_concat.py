"""Tests for `tabula concat`: the command function and the command line."""
import contextlib, io, os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from tabula import engine


class ConcatTests(unittest.TestCase):
    def run_cli(self, *argv, files=None):
        """(exit status, standard output, standard error) of `tabula ARGV...` run in a directory holding FILES."""
        out, err, here = io.StringIO(), io.StringIO(), os.getcwd()
        with tempfile.TemporaryDirectory() as d:
            for name, text in (files or {}).items():
                with open(os.path.join(d, name), "w", encoding="utf-8", newline="") as fh:
                    fh.write(text)
            os.chdir(d)
            try:
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    rc = engine.main(list(argv))
            finally:
                os.chdir(here)
        return rc, out.getvalue(), err.getvalue()

    def check(self, argv, rc, out, files, message=None):
        got = self.run_cli(*argv, files=files)
        self.assertEqual(got[:2], (rc, out))
        if rc == 0:
            self.assertEqual(got[2], "")
        elif message is None:
            self.assertTrue(got[2].startswith("tabula: ") and got[2].endswith("\n"), got[2])
        else:
            self.assertEqual(got[2], "tabula: %s\n" % message)

    F = {"a.csv": "x,y\n1,2\n3,4\n", "b.csv": "y,x\n6,5\n", "c.csv": "x,y\n", "bad.csv": "x,z\n1,2\n", "wide.csv": "x,y,z\n1,2,3\n"}

    def test_rows_follow_the_files_in_order(self):
        self.check(["--format=csv", "concat", "a.csv", "c.csv", "a.csv"], 0, "x,y\n1,2\n3,4\n1,2\n3,4\n", self.F)

    def test_columns_match_by_name_in_any_order(self):
        self.check(["--format=csv", "concat", "a.csv", "b.csv"], 0, "x,y\n1,2\n3,4\n5,6\n", self.F)

    def test_first_file_sets_the_column_order(self):
        self.check(["--format=csv", "concat", "b.csv", "a.csv"], 0, "y,x\n6,5\n2,1\n4,3\n", self.F)

    def test_json(self):
        self.check(["concat", "a.csv", "b.csv", "--format", "json"], 0,
                   '[{"x": "1", "y": "2"}, {"x": "3", "y": "4"}, {"x": "5", "y": "6"}]\n', self.F)

    def test_usage_errors(self):
        for argv in (["concat"], ["concat", "a.csv"]):
            with self.subTest(argv):
                self.check(argv, 2, "", self.F)

    def test_other_columns_name_the_file(self):
        for name in ("bad.csv", "wide.csv"):
            with self.subTest(name):
                got = self.run_cli("concat", "a.csv", name, files=self.F)
                self.assertEqual(got[:2], (1, ""))
                self.assertTrue(got[2].startswith("tabula: %s:" % name), got[2])

    def test_mistakes_in_a_file(self):
        self.check(["concat", "a.csv", "missing.csv"], 1, "", self.F)
        self.check(["concat", "a.csv", "oops.csv"], 1, "", dict(self.F, **{"oops.csv": "x,y\n1\n"}), "oops.csv: line 2: expected 2 fields, found 1")


if __name__ == "__main__":
    unittest.main()

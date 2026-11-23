"""Tests for `tabula select`: the command function and the command line."""
import contextlib, io, os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from tabula import engine


class SelectTests(unittest.TestCase):
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

    F = {"t.csv": "name,price,qty,!x\na,1.5,3,p\nb,2,4,q\n"}

    def test_keep_in_the_order_named(self):
        self.check(["--format=csv", "select", "t.csv", "qty", "name"], 0, "qty,name\n3,a\n4,b\n", self.F)

    def test_drop_keeps_the_order_of_the_file(self):
        self.check(["--format=csv", "select", "t.csv", "!price", "!name"], 0, "qty,!x\n3,p\n4,q\n", self.F)

    def test_double_bang_drops_a_column_that_starts_with_one(self):
        self.check(["--format=csv", "select", "t.csv", "!!x"], 0, "name,price,qty\na,1.5,3\nb,2,4\n", self.F)

    def test_a_column_starting_with_bang_is_never_kept_by_name(self):
        self.check(["select", "t.csv", "!x"], 1, "", self.F, "t.csv: no column 'x' (columns: name, price, qty, !x)")

    def test_options_work_after_the_command_and_with_equals(self):
        self.check(["select", "t.csv", "name", "--format=json", "--window", "2"], 0, '[{"name": "a"}, {"name": "b"}]\n', self.F)

    def test_usage_errors(self):
        for argv in (["select", "t.csv"], ["select", "t.csv", "name", "!price"], ["select", "t.csv", "name", "name"],
                     ["select", "t.csv", "!price", "!price"], ["select", "t.csv", "price", "!price"], ["select"]):
            with self.subTest(argv):
                self.check(argv, 2, "", self.F)

    def test_mistakes(self):
        self.check(["select", "t.csv", "nope"], 1, "", self.F, "t.csv: no column 'nope' (columns: name, price, qty, !x)")
        self.check(["select", "t.csv", "!nope"], 1, "", self.F)
        self.check(["select", "t.csv", "!name", "!price", "!qty", "!!x"], 1, "", self.F, "t.csv: nothing left to print")
        self.check(["select", "missing.csv", "name"], 1, "", self.F)

    def test_the_command_function_returns_a_table(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "f.csv")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("a,b\n1,2\n")
            t = engine.COMMANDS["select"][0]([path, "!a"], {})
        self.assertEqual((t.columns, t.rows), (["b"], [["2"]]))


if __name__ == "__main__":
    unittest.main()

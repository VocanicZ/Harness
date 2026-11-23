"""Tests for `tabula melt`: the command function and the command line."""
import contextlib, io, os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from tabula import engine


class MeltTests(unittest.TestCase):
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

    F = {"t.csv": "id,a,b,c\n1,x,,z\n2, ,y,w\n", "v.csv": "variable,a\n1,2\n"}

    def test_one_row_per_column_in_the_order_named(self):
        self.check(["--format=csv", "melt", "t.csv", "id", "c", "a"], 0,
                   "id,variable,value\n1,c,z\n1,a,x\n2,c,w\n", self.F)

    def test_empty_and_blank_cells_give_no_row(self):
        self.check(["--format=csv", "melt", "t.csv", "id", "a", "b"], 0, "id,variable,value\n1,a,x\n2,b,y\n", self.F)

    def test_all_empty_leaves_the_header(self):
        self.check(["--format=csv", "melt", "e.csv", "id", "a"], 0, "id,variable,value\n", {"e.csv": "id,a\n1,\n2, \n"})

    def test_the_id_may_be_any_column(self):
        self.check(["--format=csv", "melt", "t.csv", "c", "id"], 0, "c,variable,value\nz,id,1\nw,id,2\n", self.F)

    def test_usage_errors(self):
        for argv in (["melt", "t.csv", "id"], ["melt", "t.csv"], ["melt", "t.csv", "id", "id"], ["melt", "t.csv", "id", "a", "a"], ["melt"]):
            with self.subTest(argv):
                self.check(argv, 2, "", self.F)

    def test_mistakes(self):
        self.check(["melt", "t.csv", "nope", "a"], 1, "", self.F, "t.csv: no column 'nope' (columns: id, a, b, c)")
        self.check(["melt", "t.csv", "id", "nope"], 1, "", self.F)
        self.check(["melt", "v.csv", "variable", "a"], 1, "", self.F, "melt: the result would have the column name 'variable' twice")


if __name__ == "__main__":
    unittest.main()

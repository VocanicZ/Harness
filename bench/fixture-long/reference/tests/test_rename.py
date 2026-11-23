"""Tests for `tabula rename`: the command function and the command line."""
import contextlib, io, os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from tabula import engine


class RenameTests(unittest.TestCase):
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

    F = {"t.csv": "a,b,c\n1,2,3\n"}

    def test_rename_prints_the_whole_table(self):
        self.check(["--format=csv", "rename", "t.csv", "a=x"], 0, "x,b,c\n1,2,3\n", self.F)

    def test_renames_apply_at_once_so_a_swap_works(self):
        self.check(["--format=csv", "rename", "t.csv", "a=b", "b=a"], 0, "b,a,c\n1,2,3\n", self.F)

    def test_renaming_to_its_own_name_is_fine(self):
        self.check(["--format=csv", "rename", "t.csv", "a=a", "c=d"], 0, "a,b,d\n1,2,3\n", self.F)

    def test_split_at_the_first_equals_sign(self):
        self.check(["--format=csv", "rename", "t.csv", "a=x=y"], 0, "x=y,b,c\n1,2,3\n", self.F)

    def test_usage_errors(self):
        for argv in (["rename", "t.csv"], ["rename", "t.csv", "a"], ["rename", "t.csv", "=x"], ["rename", "t.csv", "a="],
                     ["rename", "t.csv", "a=x", "a=y"], ["rename"]):
            with self.subTest(argv):
                self.check(argv, 2, "", self.F)

    def test_unknown_old_is_a_mistake(self):
        self.check(["rename", "t.csv", "z=x"], 1, "", self.F, "t.csv: no column 'z' (columns: a, b, c)")

    def test_duplicate_result_names_are_a_mistake(self):
        for argv in (["rename", "t.csv", "a=x", "b=x"], ["rename", "t.csv", "a=c"], ["rename", "t.csv", "a=b"]):
            with self.subTest(argv):
                self.check(argv, 1, "", self.F, "rename: the result would have a column name twice")


if __name__ == "__main__":
    unittest.main()

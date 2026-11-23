"""Tests for `tabula rank`: the command function and the command line."""
import contextlib, io, os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from tabula import engine


class RankTests(unittest.TestCase):
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

    F = {"t.csv": "n,v\na,10\nb,2\nc,10\nd,1.0\ne,1\nf,x\n", "u.csv": "n,v\na,10\nb,2\nc,10\nd,1.0\ne,1\n",
         "r.csv": "rank,v\n1,2\n"}

    def test_ties_share_the_first_rank_and_skip(self):
        self.check(["--format=csv", "rank", "u.csv", "v:num"], 0, "n,v,rank\na,10,4\nb,2,3\nc,10,4\nd,1.0,1\ne,1,1\n", self.F)

    def test_desc(self):
        self.check(["--format=csv", "rank", "u.csv", "v:desc:num"], 0, "n,v,rank\na,10,1\nb,2,3\nc,10,1\nd,1.0,4\ne,1,4\n", self.F)

    def test_text_keys_compare_as_text(self):
        self.check(["--format=csv", "rank", "u.csv", "v"], 0, "n,v,rank\na,10,3\nb,2,5\nc,10,3\nd,1.0,2\ne,1,1\n", self.F)

    def test_text_desc_keeps_the_file_order_for_ties(self):
        self.check(["--format=csv", "rank", "u.csv", "n:desc"], 0, "n,v,rank\na,10,5\nb,2,4\nc,10,3\nd,1.0,2\ne,1,1\n", self.F)

    def test_a_table_with_no_rows_keeps_its_header(self):
        self.check(["--format=csv", "rank", "e.csv", "v"], 0, "n,v,rank\n", {"e.csv": "n,v\n"})

    def test_usage_errors(self):
        for argv in (["rank", "u.csv"], ["rank", "u.csv", "v", "n"], ["rank", "u.csv", "v:desc:desc"], ["rank"]):
            with self.subTest(argv):
                self.check(argv, 2, "", self.F)

    def test_mistakes(self):
        self.check(["rank", "t.csv", "v:num"], 1, "", self.F, "t.csv: row 6: column 'v': 'x' is not a number")
        self.check(["rank", "u.csv", "nope"], 1, "", self.F, "u.csv: no column 'nope' (columns: n, v)")
        self.check(["rank", "r.csv", "v"], 1, "", self.F)


if __name__ == "__main__":
    unittest.main()

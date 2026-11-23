"""Tests for `tabula window`: the command function and the command line."""
import contextlib, io, os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from tabula import engine


class WindowTests(unittest.TestCase):
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

    F = {"t.csv": "n,q\na,3\nb,\nc,7\nd,10\ne,1\n", "bad.csv": "n,q\na,3\nb,x\n", "has.csv": "q,q_avg\n1,2\n",
         "r.csv": "q\n1\n2\n2.5\n"}

    def test_default_window_is_three_rows(self):
        self.check(["--format=csv", "window", "t.csv", "q"], 0, "n,q,q_avg\na,3,3.00\nb,,3.00\nc,7,5.00\nd,10,8.50\ne,1,6.00\n", self.F)

    def test_window_of_one_is_the_cell_itself(self):
        self.check(["--format=csv", "window", "t.csv", "q", "--window", "1"], 0, "n,q,q_avg\na,3,3.00\nb,,\nc,7,7.00\nd,10,10.00\ne,1,1.00\n", self.F)

    def test_window_with_equals_before_the_command(self):
        self.check(["--format=csv", "--window=2", "window", "t.csv", "q"], 0, "n,q,q_avg\na,3,3.00\nb,,3.00\nc,7,7.00\nd,10,8.50\ne,1,5.50\n", self.F)

    def test_mean_rounds_half_up(self):
        self.check(["--format=csv", "window", "r.csv", "q", "--window=2"], 0, "q,q_avg\n1,1.00\n2,1.50\n2.5,2.25\n", self.F)
        self.check(["--format=csv", "window", "r.csv", "q", "--window", "9"], 0, "q,q_avg\n1,1.00\n2,1.50\n2.5,1.83\n", self.F)

    def test_window_is_counted_in_rows_not_numbers(self):
        self.check(["--format=csv", "window", "e.csv", "q", "--window", "2"], 0, "n,q,q_avg\na,4,4.00\nb,,4.00\nc, ,\n",
                   {"e.csv": "n,q\na,4\nb,\nc, \n"})

    def test_usage_errors(self):
        for argv in (["window", "t.csv"], ["window", "t.csv", "q", "n"], ["window", "t.csv", "q", "--window", "0"],
                     ["window", "t.csv", "q", "--window=-1"], ["window", "t.csv", "q", "--window=two"], ["window", "t.csv", "q", "--window"],
                     ["window", "t.csv", "q", "--window="], ["window", "t.csv", "q", "--window", "1.5"]):
            with self.subTest(argv):
                self.check(argv, 2, "", self.F)

    def test_mistakes(self):
        self.check(["window", "bad.csv", "q"], 1, "", self.F, "bad.csv: row 2: column 'q': 'x' is not a number")
        self.check(["window", "has.csv", "q"], 1, "", self.F)
        self.check(["window", "t.csv", "nope"], 1, "", self.F, "t.csv: no column 'nope' (columns: n, q)")


if __name__ == "__main__":
    unittest.main()

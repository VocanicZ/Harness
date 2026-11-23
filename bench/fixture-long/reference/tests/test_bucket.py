"""Tests for `tabula bucket`: the command function and the command line."""
import contextlib, io, os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from tabula import engine


class BucketTests(unittest.TestCase):
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

    F = {"t.csv": "v\n-0.5\n1.25\n", "bad.csv": "v\n1\nabc\n", "has.csv": "v,bucket\n1,2\n"}

    def bucket(self, width, *cells):
        files = {"t.csv": "v\n" + "".join(c + "\n" for c in cells)}
        got = self.run_cli("--format=csv", "bucket", "t.csv", "v", width, files=files)
        self.assertEqual(got[0], 0, got)
        return [line.split(",")[1] if "," in line else "" for line in got[1].splitlines()[1:]]

    def test_width_one_rounds_down_not_towards_zero(self):
        self.assertEqual(self.bucket("1", "-0.5", "0.5", "-1", "2.9"), ["-1", "0", "-1", "2"])

    def test_decimals_follow_the_width_as_written(self):
        self.assertEqual(self.bucket("0.50", "1.25", "0.1", "-0.1"), ["1.00", "0.00", "-0.50"])
        self.assertEqual(self.bucket("0.5", "1.25"), ["1.0"])
        self.assertEqual(self.bucket("5", "7", "3", "-3", "10"), ["5", "0", "-5", "10"])

    def test_never_negative_zero(self):
        self.assertEqual(self.bucket("5", "3", "0", "-0", "-0.0"), ["0", "0", "0", "0"])
        self.assertEqual(self.bucket("0.50", "0.4", "-0.0"), ["0.00", "0.00"])

    def test_exact_with_a_width_that_is_not_binary(self):
        self.assertEqual(self.bucket("0.1", "0.3", "0.29999"), ["0.3", "0.2"])
        self.assertEqual(self.bucket("0.001", "123456789012345678901234567890.0019"), ["123456789012345678901234567890.001"])

    def test_empty_cells_give_an_empty_bucket(self):
        got = self.run_cli("--format=csv", "bucket", "t.csv", "v", "1", files={"t.csv": "v,w\n,1\n  ,2\n5,3\n"})
        self.assertEqual(got[:2], (0, "v,w,bucket\n,1,\n  ,2,\n5,3,5\n"))

    def test_usage_errors(self):
        for argv in (["bucket", "t.csv", "v"], ["bucket", "t.csv", "v", "0"], ["bucket", "t.csv", "v", "0.00"], ["bucket", "t.csv", "v", "-1"],
                     ["bucket", "t.csv", "v", "x"], ["bucket", "t.csv", "v", "1", "2"], ["bucket"]):
            with self.subTest(argv):
                self.check(argv, 2, "", self.F)

    def test_mistakes(self):
        self.check(["bucket", "bad.csv", "v", "1"], 1, "", self.F, "bad.csv: row 2: column 'v': 'abc' is not a number")
        self.check(["bucket", "has.csv", "v", "1"], 1, "", self.F)
        self.check(["bucket", "t.csv", "nope", "1"], 1, "", self.F, "t.csv: no column 'nope' (columns: v)")


if __name__ == "__main__":
    unittest.main()

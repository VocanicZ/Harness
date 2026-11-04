"""Run the hidden tests and write one JSON result file (the tests' own output never mixes with it).

    run_hidden.py --list OUT.json     ids of every hidden test, without running any
    run_hidden.py --run  OUT.json     run them; [{"id", "status": "passed"|"failed", "message"}]
"""
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item


def test_id(test):
    return type(test).__name__ + "." + test._testMethodName


class Collect(unittest.TestResult):
    def __init__(self):
        super().__init__()
        self.outcome = {}

    def addSuccess(self, test):
        self.outcome.setdefault(test_id(test), ("passed", ""))

    def _bad(self, test, err):
        text = self._exc_info_to_string(err, test).strip().splitlines()
        self.outcome[test_id(test)] = ("failed", " | ".join(text[-3:])[:300])

    addFailure = addError = lambda self, test, err: self._bad(test, err)

    def addSubTest(self, test, subtest, err):
        if err is not None:
            self._bad(test, err)

    def addSkip(self, test, reason):
        self.outcome[test_id(test)] = ("failed", "skipped: %s" % reason)

    addExpectedFailure = addSkip

    def addUnexpectedSuccess(self, test):
        self.outcome[test_id(test)] = ("failed", "unexpected success")


def main():
    mode, out = sys.argv[1], sys.argv[2]
    sys.path.insert(0, HERE)
    tests = list(flatten(unittest.TestLoader().discover(HERE, pattern="test_*.py", top_level_dir=HERE)))
    if mode == "--list":
        result = sorted(test_id(t) for t in tests)
    else:
        collected = Collect()
        for t in tests:
            t.run(collected)
        result = [{"id": i, "status": s, "message": m} for i, (s, m) in sorted(collected.outcome.items())]
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(result, fh)


main()

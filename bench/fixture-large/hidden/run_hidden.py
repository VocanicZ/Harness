"""Run the large fixture's hidden tests and write one JSON result file (the tests' own output never mixes with it).

    run_hidden.py --list OUT.json [--phase P]   ids of the tests that apply in phase P, without running any
    run_hidden.py --run  OUT.json [--phase P]   run them; [{"id", "status": "passed"|"failed", "message"}]

A test is tagged with the phase(s) it is valid in (support.phase): untagged tests hold before and after the
mid-run requirement change, `@phase("pre")` only before it, `@phase("post")` only after. `--phase pre` runs the
untagged and the pre tests, `--phase post` (the default, and the final grade) the untagged and the post tests.
Test ids are `<ClassName>.<method>`; the class name starts with the module's key (`M07Query...`, see MODULES.json).
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


def phase_of(test):
    fn = getattr(test, test._testMethodName, None)
    return getattr(fn, "_phase", None) or getattr(type(test), "_phase", None)


class _Anything:
    """Stands in for anything a hidden test module imports from the library while the tests are only being LISTED:
    callable, subscriptable, subclassable. The ids must not depend on whether the solution under test imports."""

    def __init__(self, *a, **k):
        pass

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return _Anything()

    def __call__(self, *a, **k):
        return _Anything()

    def __mro_entries__(self, bases):
        return (object,)

    def __getitem__(self, key):
        return _Anything()

    def __iter__(self):
        return iter(())


class _StubFinder:
    """While listing, `tallybook` and every submodule import as `_Anything` modules."""

    def find_spec(self, name, path=None, target=None):
        if name == "tallybook" or name.startswith("tallybook."):
            import importlib.machinery
            return importlib.machinery.ModuleSpec(name, self, is_package=True)
        return None

    def create_module(self, spec):
        import types
        mod = types.ModuleType(spec.name)
        mod.__path__ = []
        mod.__getattr__ = lambda attr: _Anything()
        return mod

    def exec_module(self, module):
        pass


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
    args = sys.argv[1:]
    phase = "post"
    if "--phase" in args:
        at = args.index("--phase")
        phase = args[at + 1]
        args = args[:at] + args[at + 2:]
    if phase not in ("pre", "post"):
        sys.exit("run_hidden.py: --phase is pre or post")
    mode, out = args[0], args[1]
    sys.path.insert(0, HERE)
    if mode == "--list":
        sys.modules.pop("tallybook", None)
        sys.meta_path.insert(0, _StubFinder())
    tests = [t for t in flatten(unittest.TestLoader().discover(HERE, pattern="test_*.py", top_level_dir=HERE))
             if phase_of(t) in (None, phase)]
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

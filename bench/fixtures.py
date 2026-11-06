#!/usr/bin/env python3
"""bench/fixtures.py — which fixture a benchmark run uses (#592, PRD #345). Stdlib only.

A fixture is a brief, hidden tests, a reference implementation and a fuzz generator under one directory:

    pennywise   bench/fixture/        a 4.7 KB brief, about 400 lines of code; fits one session (the original)
    large       bench/fixture-large/  a 20-page brief, a 6-10k line reference, a mid-run requirement change

`bench/run.py <arm> --fixture NAME` picks one (default `pennywise`). The large fixture describes itself in
`bench/fixture-large/fixture.json`; `pennywise` has no manifest and gets the defaults below.

    load(name)   -> Fixture
    names()      -> ["pennywise", "large"]

Fixture attributes: name, dir, brief (path), hidden (dir), runner (hidden/run_hidden.py), reference (dir), package,
cmd_env (the env var the hidden tests read the CLI argv from), fuzz (path of the fuzz module, whose run(argv, env,
cases, cap_s) the grader calls), phases (the hidden tests have pre/post-change variants), change (the written
mid-run change request's text, or None), change_at (progress, 0..1, at which it is injected), milestones (the
runner grades the repo during the run), plain_max_replies (the plain arm's continue-reply cap), modules
({"01": "money", ...} for the per-module scores).
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT = "pennywise"
DIRS = {"pennywise": "fixture", "large": "fixture-large"}
PLAIN_MAX_REPLIES = 20


class Fixture:
    def __init__(self, name, root, manifest):
        self.name, self.dir = name, root
        m = manifest
        self.brief = os.path.join(root, "brief.md")
        self.hidden = os.path.join(root, "hidden")
        self.runner = os.path.join(self.hidden, "run_hidden.py")
        self.reference = os.path.join(root, "reference")
        self.package = m.get("package", "pennywise")
        self.cmd_env = m.get("cmd_env", "PENNYWISE_CMD")
        self.fuzz = os.path.join(root, m["fuzz"]) if m.get("fuzz") else os.path.join(HERE, "fuzz.py")
        self.phases = bool(m.get("phases", False))
        self.change_file = os.path.join(root, m["change"]) if m.get("change") else None
        self.change_at = float(m.get("change_at", 0.5))
        self.milestones = bool(m.get("milestones", False))
        self.plain_max_replies = int(m.get("plain_max_replies", PLAIN_MAX_REPLIES))
        self.modules = dict(m.get("modules") or {})

    @property
    def change(self):
        """The change request's text (what every arm is handed, verbatim), or None."""
        if not self.change_file:
            return None
        with open(self.change_file, encoding="utf-8") as fh:
            return fh.read().rstrip("\n") + "\n"

    def module_of(self, test_id):
        """The module key of a hidden test id: `M07QueryTerms.test_x` -> `07`; None when it has none."""
        if len(test_id) > 3 and test_id[0] == "M" and test_id[1:3].isdigit():
            return test_id[1:3]
        return None


def names():
    return list(DIRS)


def load(name=None):
    name = name or DEFAULT
    if name not in DIRS:
        raise ValueError("unknown fixture %r (want one of: %s)" % (name, ", ".join(DIRS)))
    root = os.path.join(HERE, DIRS[name])
    manifest = {}
    path = os.path.join(root, "fixture.json")
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            manifest = json.load(fh)
    return Fixture(name, root, manifest)

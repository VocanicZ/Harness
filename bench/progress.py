#!/usr/bin/env python3
"""bench/progress.py — grade the repo while an arm works, and inject the mid-run requirement change (#592, PRD #345).

The large fixture exists for work that outlasts one context window, so a run is watched, not only graded at the end:

  * every `--progress-poll-secs` (default 300) the runner clones the run repo's default branch and runs the hidden tests
    on it: a MILESTONE (`phase` pre-change until the change is out, post-change after). Nothing of this reaches the arm.
  * the change request (bench/fixture-large/change.md) is injected once, when the pre-change hidden tests pass at
    `change_at` (50%) or more. The text and the trigger are the same for every arm. An arm that finishes before that
    is handed it when it would have stopped (`trigger: "arm-done"`): no arm skips the change.
  * from the milestones come the measures the plain end-of-run grade cannot give: the REGRESSIONS (a test that passed at
    one milestone and fails at a later one, the final grade included), and the wall time of the FIRST FULL PASS (the
    first post-change milestone at which every hidden test passes). Resolution is the poll interval.

An arm reads the change through `ctx.next_change(done=False)` (bench/run.py's Ctx): the text once it is due and has not yet been
taken, else None. `done=True` says the arm is about to stop; if the change has not fired yet it fires now. Stdlib only.

    regressions(milestones)        [test id] that passed at a milestone and failed at a later one, in id order
    first_full_pass(milestones)    wall seconds of the first post-change milestone where every test passed, or None
    summarize(milestones, change)  the results-JSON fields
"""
import json
import os
import shutil
import subprocess
import sys
import threading
import time

POLL_S = 300.0
GRADE_TIMEOUT_S = 1200


class Change:
    """The mid-run change request: one text, delivered once, fired by progress (or by an arm that is done)."""

    def __init__(self, text, at=0.5, t0=None):
        self.text, self.at = text, at
        self.t0 = time.time() if t0 is None else t0
        self.fired = threading.Event()
        self.trigger = self.fired_s = self.progress_pct = self.delivered_s = None
        self._lock = threading.Lock()

    def _since(self):
        return round(time.time() - self.t0, 3)

    def fire(self, trigger, progress_pct=None):
        with self._lock:
            if self.fired.is_set():
                return False
            self.trigger, self.fired_s, self.progress_pct = trigger, self._since(), progress_pct
            self.fired.set()
            return True

    def due(self):
        """Fired and not yet taken."""
        return self.fired.is_set() and self.delivered_s is None

    def take(self, done=False):
        """The text, once, when it is due; None otherwise. `done`: the arm would stop now, so fire if it has not."""
        if done and not self.fired.is_set():
            self.fire("arm-done")
        with self._lock:
            if not self.fired.is_set() or self.delivered_s is not None:
                return None
            self.delivered_s = self._since()
            return self.text

    def record(self):
        return {"fired": self.fired.is_set(), "trigger": self.trigger, "at_s": self.fired_s,
                "progress_pct": self.progress_pct, "delivered": self.delivered_s is not None,
                "delivered_s": self.delivered_s, "threshold_pct": round(self.at * 100, 1)}


def regressions(milestones):
    """[test id] that passed at a milestone and did not pass at a later one in which it ran."""
    seen_pass, bad = set(), set()
    for m in milestones:
        for tid, ok in m["tests"].items():
            if ok:
                seen_pass.add(tid)
            elif tid in seen_pass:
                bad.add(tid)
    return sorted(bad)


def first_full_pass(milestones):
    for m in milestones:
        if m["phase"] == "post" and m["tests"] and all(m["tests"].values()):
            return m["t_s"]
    return None


def summarize(milestones, change):
    """The results-JSON fields: milestones (compact), change, regressions, first_full_pass_s."""
    reg = regressions(milestones)
    return {"change": change.record() if change else None,
            "milestones": [{"t_s": m["t_s"], "phase": m["phase"], "passed": sum(1 for v in m["tests"].values() if v),
                            "total": len(m["tests"])} for m in milestones],
            "regressions": len(reg), "regressed_tests": reg[:20], "first_full_pass_s": first_full_pass(milestones)}


def milestone_of(frag, t_s, phase):
    """A milestone from the grader's fragment: {t_s, phase, tests: {id: passed}}; None when it did not grade."""
    tests = ((frag or {}).get("details") or {}).get("tests")
    if not isinstance(tests, list) or not tests:
        return None
    return {"t_s": round(t_s, 3), "phase": phase, "tests": {t["id"]: t.get("status") == "passed" for t in tests}}


class Watcher:
    """Grades the repo every poll_secs in a background thread, fires the change, keeps the milestones."""

    def __init__(self, fixture, repo, work, gh, log, grader, change, t0, poll_secs=POLL_S, stop=None):
        self.fixture, self.repo, self.work, self.gh, self.log = fixture, repo, work, gh, log
        self.grader, self.change, self.t0, self.poll_secs = grader, change, t0, poll_secs
        self.stop = stop or threading.Event()
        self.milestones = []
        self._thread = None
        self._n = 0

    def start(self):
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def finish(self):
        """Stop watching; wait for a grade in flight (it is bounded by GRADE_TIMEOUT_S)."""
        self.stop.set()
        if self._thread is not None:
            self._thread.join(GRADE_TIMEOUT_S + 60)

    def phase(self):
        return "post" if self.change is not None and self.change.fired.is_set() else "pre"

    def grade_once(self):
        """One milestone; the tests-only fragment of a fresh clone of the default branch."""
        self._n += 1
        phase, dest = self.phase(), os.path.join(self.work, "milestone-%03d" % self._n)
        try:
            self.gh.clone(self.repo, dest)
            argv = [sys.executable, self.grader, dest, "--fixture", self.fixture.name, "--tests-only"]
            if self.fixture.phases:
                argv += ["--phase", phase]
            p = subprocess.run(argv, capture_output=True, text=True, timeout=GRADE_TIMEOUT_S, stdin=subprocess.DEVNULL)
            if p.returncode != 0:
                raise RuntimeError((p.stderr or p.stdout).strip()[:200])
            ms = milestone_of(json.loads(p.stdout), time.time() - self.t0, phase)
        except Exception as e:   # a repo with nothing on it yet, a clone that failed: no milestone, the watch goes on
            self.log("milestone %d: %s" % (self._n, str(e)[:200] or type(e).__name__))
            return None
        finally:
            shutil.rmtree(dest, ignore_errors=True)
        if ms is None:
            return None
        self.milestones.append(ms)
        passed, total = sum(ms["tests"].values()), len(ms["tests"])
        self.log("milestone %d (%s, %.0fs): %d / %d hidden tests pass" % (self._n, phase, ms["t_s"], passed, total))
        if self.change is not None and phase == "pre" and total and passed / total >= self.change.at:
            if self.change.fire("progress", round(100.0 * passed / total, 1)):
                self.log("the change request fires at %.1f%%" % (100.0 * passed / total))
        return ms

    def _loop(self):
        while not self.stop.wait(self.poll_secs):
            self.grade_once()

    def add_final(self, frag, t_s):
        """The end-of-run grade is the last milestone."""
        ms = milestone_of(frag, t_s, "post" if self.fixture.phases else "pre")
        if ms is not None:
            self.milestones.append(ms)

    def dump(self, path):
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.milestones, fh, indent=1, sort_keys=True)
            fh.write("\n")

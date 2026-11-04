#!/usr/bin/env python3
"""fake_headless.py — the smallest adapter that satisfies the headless adapter contract (docs/reference.md),
for fake_cli.py. test_headless_core.py runs headless_core's runner through it, so what it proves about the
core (turn start, resume id, event parse, usage, limit, transient retry, interrupt, stop) holds without
claude. A real adapter is scripts/cli/<cli>_headless.py; this one lives in the tests."""
import os, sys

CLI_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts", "cli")
sys.path.insert(0, os.path.normpath(CLI_DIR))
import headless_core as core


class FakeTurn:
    def __init__(self):
        self.session_id = self.final = self.quota = self.rate_limit = self.retry = None
        self.no_conversation = False

    def feed(self, ev):
        k = ev.get("ev") if isinstance(ev, dict) else None
        if k == "hello":
            self.session_id = ev.get("sid")
        elif k == "usage":
            self.rate_limit = {"window": ev.get("window"), "used_pct": ev.get("used_pct")}
        elif k == "retrying":
            self.retry = {"attempt": ev.get("attempt")}
        elif k == "final":
            self.final = ev.get("text")
        elif k == "quota":
            self.quota = ev

    def outcome(self, rc, stderr_tail=""):
        if self.final is not None:
            return "idle", self.final, None, None
        if self.quota is not None:
            return "limit", None, self.quota.get("text"), self.quota.get("resets_at")
        return "transient", None, f"fake-cli exited {rc} with no final event", None


class FakeAdapter:
    name = "fake"
    default_bin = "fake-cli"

    def account(self):
        return "fake-account"

    def argv(self, bin_, session_id, session_started, model, effort, flags):
        a = list(bin_) + ["run"]
        a += ["--resume", session_id] if session_started else ["--new"] + ([session_id] if session_id else [])
        return a + (["--model", model] if model else []) + list(flags)

    def new_turn(self):
        return FakeTurn()

    @staticmethod
    def watch_line(ev):
        return ev.get("text") if ev.get("ev") == "final" else None


ADAPTER = FakeAdapter()

if __name__ == "__main__":
    sys.exit(core.main(adapter=ADAPTER, prog="fake_headless.py"))

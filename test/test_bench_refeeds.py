#!/usr/bin/env python3
"""test_bench_refeeds.py — #616 (PRD #587): the bench reports, per run, how often the goal loop's Stop hook sent a
session back to work and how many tokens those re-feeds were (armlib.refeeds -> `refeeds` / `refeed_tokens`), and the
engine-owned hook's short nudge is far smaller than the whole-task re-feed run-20261106 recorded."""
import importlib.util, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
sys.dont_write_bytecode = True


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, rel))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


armlib, st, aggregate = load("armlib", "bench/armlib.py"), load("stats", "scripts/stats.py"), load("aggregate", "bench/aggregate.py")
BASELINE = os.path.join(ROOT, "bench", "results", "run-20261106", "harness.logs", "transcripts")


def feed(text, meta=True):
    return {"type": "user", "isMeta": meta, "message": {"role": "user", "content": text}}


def write(path, rows):
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def test_run_20261106_had_15_refeeds_of_about_40k_tokens():
    trs = sorted(os.path.join(BASELINE, f) for f in os.listdir(BASELINE) if f.endswith(".jsonl"))
    got = armlib.refeeds(st, trs)
    assert got["count"] == 15, got
    assert 38000 <= got["tokens"] <= 41000, got


def test_only_meta_stop_hook_feedback_entries_count():
    with tempfile.TemporaryDirectory() as d:
        tr = os.path.join(d, "t.jsonl")
        task = "x" * 4000
        write(tr, [feed("Stop hook feedback:\n" + task),
                   feed("Stop hook feedback:\nNot done: y", meta=True),
                   {"type": "user", "isMeta": True, "message": {"content": [{"type": "text", "text": "Stop hook feedback:\nlisted " + "z" * 100}]}},
                   feed("Stop hook feedback:\nreal user text", meta=False),               # a user's own message
                   feed("Base directory for this skill: ..."),                              # another meta entry
                   {"type": "api-request-blob", "message": {"role": "user", "content": "Stop hook feedback:\nblob"}},
                   {"type": "assistant", "message": {"role": "assistant", "content": "Stop hook feedback:"}}])
        sub = os.path.join(d, "t", "subagents"); os.makedirs(sub)
        write(os.path.join(sub, "agent-1.jsonl"), [feed("Stop hook feedback:\nin a sub-agent")])
        got = armlib.refeeds(st, [tr])
        assert got["count"] == 4, got
        assert got["tokens"] == round((len("Stop hook feedback:\n" + task) + len("Stop hook feedback:\nNot done: y")
                                       + len("Stop hook feedback:\nlisted " + "z" * 100) + len("Stop hook feedback:\nin a sub-agent")) / 4)
        assert armlib.refeeds(st, [os.path.join(d, "nope.jsonl")]) == {"count": 0, "tokens": 0}


def test_the_engine_hooks_nudge_is_a_fraction_of_the_whole_task_refeed():
    # The same lane (the baseline's implementer task, 11.3k chars) re-fed with the hook's short nudge.
    task = open(os.path.join(ROOT, "prompts", "impl.md"), encoding="utf-8").read()
    with tempfile.TemporaryDirectory() as d:
        wd = os.path.join(d, "wd"); os.makedirs(os.path.join(wd, ".claude"))
        with open(os.path.join(wd, ".claude", "ralph-loop.local.md"), "w") as f:
            f.write(f'---\nactive: true\niteration: 1\nmax_iterations: 0\ncompletion_promise: "ISSUE 1 DONE"\n---\n\nGOAL: do it.\n{task}')
        tr = os.path.join(d, "t.jsonl"); write(tr, [{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "hm"}]}}])
        out = subprocess.run([sys.executable, os.path.join(ROOT, "plugins", "claude", "harness-ralph", "hooks", "stop-hook.py")],
                             input=json.dumps({"cwd": wd, "transcript_path": tr}), capture_output=True, text=True,
                             env=dict(os.environ, HARNESS_RALPH_FLUSH_MS="0"))
        reason = json.loads(out.stdout)["reason"]
        write(tr, [feed("Stop hook feedback:\n" + reason)] * 15)
        short = armlib.refeeds(st, [tr])
        assert short["count"] == 15 and short["tokens"] < 2000, short      # 15 whole-task re-feeds were ~39.6k


def test_the_aggregate_reports_refeeds_per_run():
    agg = aggregate.aggregate([{"status": "ok", "capped": None, "refeeds": 15, "refeed_tokens": 39572},
                               {"status": "ok", "capped": None, "refeeds": 3, "refeed_tokens": 400}])
    assert agg["metrics"]["refeeds"]["max"] == 15 and agg["metrics"]["refeeds"]["min"] == 3
    assert agg["metrics"]["refeed_tokens"]["median"] == (39572 + 400) / 2

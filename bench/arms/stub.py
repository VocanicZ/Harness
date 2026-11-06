"""stub arm — exercises the runner core without an agent (#381). Options (--arm-opt K=V):

    cost=USD     write a transcript whose list price is about USD (default 0.01); a comma list, `1,3,2`, gives
                 run 1, 2, 3 of a `--runs N` batch their own price (it repeats from the start when N is longer) (#591)
    sleep=SECS   keep "working" this long, or until the runner stops it (default 0)
    subagents=1  also write a sub-agent transcript beside the session's (priced at `cost` again)
    effort=E     record effort E on the session's messages (default: none), as Claude Code does (#590)
    fail=1       raise, to exercise the error path
"""
import json, os, time


def write_transcript(path, usd, mid="m1", effort=None):
    """One Opus message priced at `usd`: output tokens at $25 per Mtok."""
    t0 = time.time() - 3
    lines = [
        {"type": "assistant", "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0)),
         "message": {"id": mid, "model": "claude-opus-4-1", "usage": {"input_tokens": 10, "output_tokens": int(usd / 25 * 1e6)},
                     "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "pytest -q"}}]}},
        {"type": "user", "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0 + 1)),
         "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}},
        {"type": "user", "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0 + 3)), "message": {"content": "done"}},
    ]
    if effort:
        lines[0]["effort"] = effort
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("".join(json.dumps(r) + "\n" for r in lines))


def run_cost(ctx):
    costs = [float(c) for c in ctx.opts.get("cost", "0.01").split(",")]
    return costs[((ctx.run or 1) - 1) % len(costs)]


def run(ctx):
    if ctx.opts.get("fail"):
        raise RuntimeError("stub arm told to fail")
    tr = os.path.join(ctx.logs, "stub-session.jsonl")
    write_transcript(tr, run_cost(ctx), effort=ctx.opts.get("effort"))
    if ctx.opts.get("subagents"):
        sdir = os.path.join(ctx.logs, "stub-session", "subagents")
        os.makedirs(sdir)
        write_transcript(os.path.join(sdir, "agent-a1.jsonl"), run_cost(ctx), mid="sub1")
    ctx.add_transcripts(tr)
    ctx.count("commits", 1)
    ctx.stop.wait(float(ctx.opts.get("sleep", "0")))
    return {"counts": {"stub": 1}}

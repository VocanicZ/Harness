#!/usr/bin/env python3
# stop-hook.py — the engine-owned goal-loop Stop hook for Claude Code lanes (#616, PRD #587).
#
# Replaces the user-scope `ralph-loop` plugin's hook, which re-sent the whole task file at every Stop
# (run-20261106: 15 re-feeds, ~45k tokens) and misjudged three cases this hook handles:
#   * the promise-flush race: Stop fires before the final message is flushed to the transcript, so the
#     promise was missed and the task re-sent. Before nudging, the transcript is re-read for up to
#     HARNESS_RALPH_FLUSH_MS (default 1500) and the hook's own `last_assistant_message`, when Claude Code
#     sends one, counts too.
#   * a lane waiting on its own background sub-agent was re-fed every time it said "still waiting". A Stop
#     with a sub-agent running (launched async, no completed `<task-notification>` yet) gets no nudge: the
#     notification starts the next turn, and its Stop is judged then. A sub-agent whose transcript has not
#     moved for HARNESS_RALPH_AGENT_STALE_S (default 1800) is taken for lost and no longer holds the nudge.
#   * the full task was the nudge. Now it is a short reminder naming the goal; the whole task is re-sent only
#     after a context compaction (a `compact_boundary` / `isCompactSummary` entry the hook has not yet
#     answered), when the lane may have lost it.
#
# State file: <cwd>/.claude/ralph-loop.local.md (lib.sh write_state), the same contract goal_loop.py keeps for
# the other CLIs: frontmatter iteration / max_iterations / completion_promise / session_id, then the task. The hook
# adds one key, `compactions_fed`, to remember how many compactions it has re-sent the task for.
# Input: the Stop hook JSON on stdin. Output: nothing (allow the stop), or {"decision":"block","reason":…}.
import json, os, re, sys, time

STATE_REL = os.path.join(".claude", "ralph-loop.local.md")


def env_num(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return float(default)


def read_rows(path):
    rows = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    return rows


def text_blocks(row):
    """The text of one assistant transcript row (Claude Code writes each content block as its own row)."""
    if row.get("type") != "assistant" and (row.get("message") or {}).get("role") != "assistant":
        return []
    c = (row.get("message") or {}).get("content")
    if isinstance(c, str):
        return [c]
    return [b.get("text", "") for b in c or [] if isinstance(b, dict) and b.get("type") == "text"]


def last_text(rows):
    last = ""
    for r in rows:
        t = text_blocks(r)
        if t:
            last = t[-1]
    return last


def promise_in(text, promise):
    """True when the first <promise> tag of `text` says `promise` (whitespace-normalised) — ralph-loop's rule."""
    m = re.search(r"<promise>(.*?)</promise>", text or "", re.S)
    return bool(m) and " ".join(m.group(1).split()) == promise


def tool_result_texts(row):
    c = (row.get("message") or {}).get("content")
    if not isinstance(c, list):
        return
    for b in c:
        if isinstance(b, dict) and b.get("type") == "tool_result":
            inner = b.get("content")
            if isinstance(inner, list):
                inner = " ".join(x.get("text", "") for x in inner if isinstance(x, dict))
            yield str(inner or "")


def running_agents(rows):
    """{agent id: launch timestamp} of the async sub-agents launched and not yet reported done."""
    live = {}
    for r in rows:
        res = r.get("toolUseResult")
        if isinstance(res, dict) and res.get("isAsync") and res.get("status") == "async_launched" and res.get("agentId"):
            live[str(res["agentId"])] = r.get("timestamp")
        elif r.get("type") == "user":
            for t in tool_result_texts(r):
                m = re.match(r"\s*Async agent launched successfully.*?agentId:\s*(\w+)", t, re.S)
                if m:
                    live.setdefault(m.group(1), r.get("timestamp"))
        att = r.get("attachment")
        prompt = att.get("prompt") if isinstance(att, dict) and att.get("type") == "queued_command" else None
        if isinstance(prompt, str) and "<task-notification>" in prompt:
            m = re.search(r"<task-id>\s*(\w+)\s*</task-id>", prompt)
            st = re.search(r"<status>\s*(\w+)\s*</status>", prompt)
            if m and (not st or st.group(1) != "running"):
                live.pop(m.group(1), None)
    return live


def parse_ts(ts):
    try:
        from datetime import datetime
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return None


def agent_is_live(transcript, aid, launched, stale_s):
    """A launched agent holds the nudge while its own transcript (or, lacking one, its launch) is fresh."""
    sub = os.path.join(transcript[:-6] if transcript.endswith(".jsonl") else transcript, "subagents", f"agent-{aid}.jsonl")
    try:
        seen = os.path.getmtime(sub)
    except OSError:
        seen = parse_ts(launched)
    return seen is None or time.time() - seen < stale_s


def compactions(rows):
    """One compaction writes a `compact_boundary` entry and an `isCompactSummary` one: count the larger tally."""
    boundaries = sum(1 for r in rows if r.get("subtype") == "compact_boundary")
    summaries = sum(1 for r in rows if r.get("isCompactSummary") and r.get("type") == "user")
    return max(boundaries, summaries)


def goal_of(task):
    for line in task.splitlines():
        if line.startswith("GOAL:"):
            return line[5:].strip()[:300]
    for line in task.splitlines():
        if line.strip():
            return line.strip()[:300]
    return "the task in .harness-task.md"


def write_state(path, fm, body):
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("---" + fm + "---" + body)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def end_loop(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if not isinstance(data, dict):
        return
    cwd = data.get("cwd") or os.getcwd()
    state = os.path.join(cwd, STATE_REL)
    try:
        with open(state, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return                                   # no loop here
    parts = content.split("---", 2)
    if len(parts) < 3:
        return
    fm, body = parts[1], parts[2]

    def field(name, default=""):
        m = re.search(rf"^{name}:[ \t]*(.*)$", fm, re.M)
        return m.group(1).strip().strip('"') if m else default

    # Session isolation: the Stop hook fires in every session of the project; only the loop's own is judged.
    owner = field("session_id")
    if owner and owner != (data.get("session_id") or ""):
        return
    try:
        iteration = int(field("iteration", "1"))
        max_iter = int(field("max_iterations", "0") or 0)
        fed = int(field("compactions_fed", "0") or 0)
    except ValueError:
        end_loop(state)                          # corrupted: stop looping rather than loop blindly
        return
    promise = " ".join(field("completion_promise").split())
    if promise == "null":
        promise = ""
    if max_iter > 0 and iteration >= max_iter:
        end_loop(state)
        return

    transcript = data.get("transcript_path") or ""
    last_msg = data.get("last_assistant_message") or ""

    def done(rows):
        return bool(promise) and (promise_in(last_text(rows), promise) or promise_in(last_msg, promise))

    rows = read_rows(transcript)
    if done(rows):
        end_loop(state)
        return

    # A sub-agent still running: no nudge. Its notification starts the next turn, whose Stop is judged then.
    stale_s = env_num("HARNESS_RALPH_AGENT_STALE_S", 1800)
    if any(agent_is_live(transcript, a, ts, stale_s) for a, ts in running_agents(rows).items()):
        return

    # The flush race: Stop can fire before the final message reaches the transcript. Look again, briefly.
    deadline = time.time() + env_num("HARNESS_RALPH_FLUSH_MS", 1500) / 1000.0
    while time.time() < deadline:
        time.sleep(0.05)
        rows = read_rows(transcript)
        if done(rows):
            end_loop(state)
            return

    nxt = iteration + 1
    seen = compactions(rows)
    full = seen > fed
    if full:
        fm = re.sub(r"^compactions_fed:.*\n", "", fm, flags=re.M)
        fm = fm.rstrip("\n") + f"\ncompactions_fed: {seen}\n"
    fm = re.sub(r"^iteration:[ \t]*\d+", f"iteration: {nxt}", fm, flags=re.M)
    write_state(state, fm, body)

    done_line = (f"print <promise>{promise}</promise> (ONLY when it is TRUE, never to escape the loop)"
                 if promise else "the loop runs until the limit")
    if full:
        reason = body.strip()                    # the context was compacted: the lane may have lost the task
    else:
        reason = (f"Not done: {goal_of(body)}\nContinue the task, or {done_line}. "
                  f".harness-task.md in this directory holds the whole task if you need it.")
    msg = (f"🔄 Ralph iteration {nxt} | To stop: output <promise>{promise}</promise> "
           f"(ONLY when statement is TRUE - do not lie to exit!)" if promise else
           f"🔄 Ralph iteration {nxt} | No completion promise set - loop runs infinitely")
    print(json.dumps({"decision": "block", "reason": reason, "systemMessage": msg}))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# stop-hook.py — the goal loop for a Codex lane (#257): ralph-loop's contract as a Codex Stop hook.
# Codex runs it at the end of every turn in the session's cwd, handing it {cwd, session_id,
# transcript_path, last_assistant_message, stop_hook_active, …} on stdin
# (test/fixtures/cli/codex/hook-input.json). While <cwd>/.claude/ralph-loop.local.md (write_state)
# exists and the turn's last reply does not carry its <promise>, it answers
# {"decision":"block","reason":<task>}: Codex takes `reason` as the next prompt. On the promise, or
# at max_iterations, it removes the state file (the done signal cli_done reads) and lets the turn end.
# Any other session — no state file — is left alone.
import json, os, re, sys


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    cwd = data.get("cwd") or os.getcwd()
    state = os.path.join(cwd, ".claude", "ralph-loop.local.md")
    try:
        with open(state, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return
    parts = content.split("---", 2)
    if len(parts) < 3:
        return
    fm, body = parts[1], parts[2]
    it = re.search(r"^iteration:\s*(\d+)", fm, re.M)
    mx = re.search(r"^max_iterations:\s*(\d+)", fm, re.M)
    pr = re.search(r'^completion_promise:\s*"?([^"\n]*)"?', fm, re.M)
    iteration = int(it.group(1)) if it else 1
    max_iter = int(mx.group(1)) if mx else 0
    promise = " ".join(pr.group(1).split()) if pr else ""

    # Only the model's own reply counts: the task text it read names the promise too.
    reply = data.get("last_assistant_message") or ""
    found = [" ".join(m.split()) for m in re.findall(r"<promise>(.*?)</promise>", reply, re.S)]
    if (promise and promise in found) or (max_iter > 0 and iteration >= max_iter):
        try:
            os.unlink(state)
        except OSError:
            pass
        return

    nxt = iteration + 1
    tmp = f"{state}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("---" + re.sub(r"^iteration:\s*\d+", f"iteration: {nxt}", fm, flags=re.M) + "---" + body)
        os.replace(tmp, state)
    except OSError:
        if os.path.exists(tmp):
            os.unlink(tmp)
    msg = f"🔄 Ralph iteration {nxt} | To stop: output <promise>{promise}</promise> (ONLY when statement is TRUE - do not lie to exit!)"
    print(json.dumps({"decision": "block", "reason": f"{msg}\n\n{body.strip()}"}))


if __name__ == "__main__":
    main()

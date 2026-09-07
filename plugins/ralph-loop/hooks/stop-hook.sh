#!/usr/bin/env python3
import sys, json, os, re

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        print(json.dumps({"decision": "allow"}))
        return

    # 1. Resolve workspace path
    ws_paths = data.get("workspacePaths", [])
    ws = ws_paths[0] if ws_paths else "."

    # Check for state file (.claude/ralph-loop.local.md or .harness/ralph-loop.local.md)
    state_file = os.path.join(ws, ".claude", "ralph-loop.local.md")
    if not os.path.exists(state_file):
        alt = os.path.join(ws, ".harness", "ralph-loop.local.md")
        if os.path.exists(alt):
            state_file = alt
        else:
            print(json.dumps({"decision": "allow"}))
            return

    try:
        with open(state_file, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception:
        print(json.dumps({"decision": "allow"}))
        return

    parts = content.split("---", 2)
    if len(parts) < 3:
        print(json.dumps({"decision": "allow"}))
        return

    frontmatter = parts[1]
    prompt_text = parts[2].strip()

    iter_m = re.search(r"^iteration:\s*(\d+)", frontmatter, re.M | re.I)
    max_m = re.search(r"^(?:max_iterations|maxIterations):\s*(\d+)", frontmatter, re.M | re.I)
    prom_m = re.search(r"^(?:completion_promise|completionPromise):\s*\"?([^\"]*)\"?", frontmatter, re.M | re.I)

    iteration = int(iter_m.group(1)) if iter_m else 1
    max_iterations = int(max_m.group(1)) if max_m else 0
    promise = prom_m.group(1).strip() if prom_m else ""

    # Check transcript for completion promise
    transcript_path = data.get("transcriptPath")
    promise_found = False
    if transcript_path and os.path.exists(transcript_path) and promise:
        try:
            with open(transcript_path, "r", encoding="utf-8") as f:
                for line in f:
                    c = ""
                    try:
                        row = json.loads(line)
                        if row.get("source") == "MODEL" or row.get("role") == "assistant":
                            c = row.get("content", "")
                            if isinstance(c, list):
                                c = " ".join([b.get("text", "") for b in c if isinstance(b, dict)])
                        elif "content" in row:
                            c = row.get("content", "")
                    except Exception:
                        c = line
                    if not c:
                        continue
                    m = re.search(r"<promise>(.*?)</promise>", str(c), re.DOTALL)
                    if m:
                        found = " ".join(m.group(1).split())
                        target = " ".join(promise.split())
                        if found == target:
                            promise_found = True
                            break
        except Exception:
            pass

    if promise_found:
        try:
            os.unlink(state_file)
        except Exception:
            pass
        print(json.dumps({"decision": "allow"}))
        return

    if max_iterations > 0 and iteration >= max_iterations:
        try:
            os.unlink(state_file)
        except Exception:
            pass
        print(json.dumps({"decision": "allow"}))
        return

    # Increment iteration for next turn
    next_iter = iteration + 1
    new_fm = re.sub(r"^iteration:\s*\d+", f"iteration: {next_iter}", frontmatter, flags=re.M)
    tmp_file = f"{state_file}.tmp.{os.getpid()}"
    try:
        with open(tmp_file, "w", encoding="utf-8") as f:
            f.write(f"---{new_fm}---" + parts[2])
        os.replace(tmp_file, state_file)
    except Exception:
        if os.path.exists(tmp_file):
            try: os.unlink(tmp_file)
            except Exception: pass

    sys_msg = f"🔄 Ralph iteration {next_iter} | To stop: output <promise>{promise}</promise> (ONLY when statement is TRUE - do not lie to exit!)"
    print(json.dumps({
        "decision": "continue",
        "reason": f"{sys_msg}\n\n{prompt_text}"
    }))

if __name__ == "__main__":
    main()

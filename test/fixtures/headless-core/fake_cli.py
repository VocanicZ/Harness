#!/usr/bin/env python3
"""fake_cli — a made-up agent CLI for test_headless_core.py, deliberately NOT claude: its own argv
(`run --new [ID]` / `run --resume ID`), its own wire format (`{"ev": ...}` lines), no stream-json.

Per call it reads the next line of $FAKE_CLI_DIR/plan (`ok <reply>`, `quota`, `flaky`, `crash`, `hang`; past
the end: `ok done`), appends {argv, prompt, pid} to $FAKE_CLI_DIR/calls.jsonl and prints:
  {"ev":"hello","sid":"<id>"}                 first line: the session, the CLI picks `fake-<n>` when none is named
  {"ev":"usage","window":"5h","used_pct":N}   what a turn used
  {"ev":"final","text":<reply>}               ok — exit 0
  {"ev":"quota","text":...,"resets_at":N}     quota — exit 1: the account's limit
  {"ev":"retrying","attempt":1}               flaky — then exit 1 with no final: a transient failure
  crash: exit 7 with nothing on stdout; hang: hello, then a `sleep` grandchild and wait forever.
While $FAKE_CLI_DIR/hold exists it waits after `hello`."""
import json, os, subprocess, sys, time

d = os.environ["FAKE_CLI_DIR"]
argv = sys.argv[1:]
prompt = sys.stdin.read()
with open(os.path.join(d, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"argv": argv, "prompt": prompt, "pid": os.getpid()}) + "\n")
n = sum(1 for _ in open(os.path.join(d, "calls.jsonl")))
plan = [l.strip() for l in open(os.path.join(d, "plan")) if l.strip()]
name, _, reply = (plan[n - 1] if n <= len(plan) else "ok done").partition(" ")
sid = argv[argv.index("--resume") + 1] if "--resume" in argv else \
    (argv[argv.index("--new") + 1] if "--new" in argv and argv.index("--new") + 1 < len(argv) and not argv[argv.index("--new") + 1].startswith("-") else f"fake-{n}")


def out(**kw):
    print(json.dumps(kw), flush=True)


if name == "crash":
    sys.exit(7)
out(ev="hello", sid=sid)
while os.path.exists(os.path.join(d, "hold")):
    time.sleep(0.05)
if name == "hang":
    g = subprocess.Popen(["sleep", "600"])
    with open(os.path.join(d, "pids"), "w") as f:
        f.write(f"{os.getpid()} {g.pid}\n")
    time.sleep(600)
out(ev="usage", window="5h", used_pct=40 + n)
if name == "quota":
    out(ev="quota", text="quota exhausted, back at the reset", resets_at=1893456000)
    sys.exit(1)
if name == "flaky":
    out(ev="retrying", attempt=1)
    sys.exit(1)
out(ev="final", text=reply or "done")

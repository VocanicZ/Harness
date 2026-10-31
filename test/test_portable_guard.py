#!/usr/bin/env python3
"""test_portable_guard.py — #355 / ADR 0001: the engine's process and locking primitives stay behind
scripts/portable.sh and scripts/portable.py.

Native Windows (Git Bash + native CPython) has no `flock`, `setsid`, `pgrep`, `pkill`, `uuidgen`,
procps `ps -o`, kernel uuid, `fcntl`, and a `/proc` that lists only MSYS processes; `os.kill(pid, 0)`
there sends CTRL_C_EVENT. Each of those therefore goes through one helper with a Windows branch
(lock_acquire/lock_try/lock_release/lock_holders/lock_free, proc_find/proc_env/proc_cmdline/
proc_alive/proc_ident/proc_args/proc_kill_tree, detach_prefix, new_uuid; pid_alive/lock_nb/unlock).

This scans the engine (bin/harness, scripts/, install.sh, update.sh) for a raw use outside the
helpers. Comments do not count. A use that is right where it is sits in ALLOW with its reason; an
ALLOW entry that no longer matches anything fails too, so the list never goes stale.

GNU-only coreutils flags (`stat -c`, `date -d`, `readlink -f`, `sort -V`, `mv -T`, …) are not
guarded: Git Bash ships GNU coreutils and the ADR's probe found every one of them working there.
procps' `ps -o`/`ps -eo` is the GNU-only flag set Git Bash lacks (MSYS `ps` has no `-o`)."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
ENGINE = ["bin/harness", "scripts", "install.sh", "update.sh"]
HELPERS = {"scripts/portable.sh", "scripts/portable.py"}

# primitive -> (language, regex over a code line with its comment stripped)
SHELL = {
    "flock": r"\bflock\b",
    "/proc": r"/proc\b",
    "pgrep/pkill": r"\b(pgrep|pkill)\b",
    "setsid": r"\bsetsid\b",
    "uuidgen": r"\buuidgen\b",
    "ps -o": r"(^|[^\w.-])ps (-[a-zA-Z]*\s+)*-[a-zA-Z]*o\b",
    "process-group kill": r"\bkill\b[^;|&]*\s--\s+\"?-\$",
}
PYTHON = {
    "fcntl": r"\bfcntl\b",
    "os.kill": r"\bos\.kill(pg)?\(",
    "os.setsid": r"\bos\.setsid\(",
    "/proc": r"[\"']/proc\b",
    "ps -o": r"[\"']ps[\"'],\s*[\"']-[a-zA-Z]*o|[\"']-e[\"'],\s*[\"']-o[\"']",
    "argv primitive": r"[\"'](pgrep|pkill|flock|setsid|uuidgen|lsof|fuser)[\"']",
}
# A shell file may embed Python (a `python3 - <<EOF` heredoc): these Python rules apply to it too.
EMBEDDED_PY = ("fcntl", "os.kill", "os.setsid")

# (file, primitive) -> why the raw use is right where it is.
ALLOW = {
    ("install.sh", "/proc"):
        "install.sh runs before any engine exists (`curl | bash`, npx), so it cannot source "
        "scripts/portable.sh; its rel_in_use scan reads ENGINE_DIR from /proc/<pid>/environ, which "
        "MSYS exposes for the bash workers it looks for (ADR inventory row, kept as is)",
    ("scripts/cli/claude_headless.py", "os.kill"):
        "the lane runner is a self-contained stdlib script by design (#347, ADR §4): os.kill/killpg "
        "sit in the POSIX branch of kill_tree and the `stop` command, both behind `if WINDOWS` whose "
        "other branch is `taskkill /T /F`",
    ("scripts/cli/claude_headless.py", "os.setsid"):
        "the runner's own new session on POSIX, guarded by `if not WINDOWS` (#347)",
    ("scripts/cli/claude_headless.py", "ps -o"):
        "POSIX branch of kill_tree's descendant scan (`ps -e -o pid=,ppid=`), never reached on Windows",
    ("scripts/supervise.sh", "ps -o"):
        "sup_tree_cpu reads a tmux pane's process tree; headless lanes (the only Windows lanes) report "
        "liveness through runner state/events instead (#351, ADR §4)",
    ("scripts/cli/openclaw.sh", "ps -o"): "openclaw is a tmux-only CLI (no headless lane, n/a on Windows)",
    ("scripts/cli/openclaw-loop.sh", "ps -o"): "openclaw is a tmux-only CLI (no headless lane, n/a on Windows)",
    ("scripts/fleetview.py", "ps -o"):
        "session_models reads each lane's `--model` off its process tree (`ps -eo`); where ps has no "
        "-o (Git Bash) it returns non-zero and the status model column is simply empty — a cosmetic "
        "column, no liveness or lock decision rides on it",
    ("scripts/cli/hermes.sh", "py os.kill"):
        "hermes is a tmux-only CLI (no headless lane, n/a on Windows); its lease check runs inside "
        "hermes's own python, against hermes's own recorded pids",
}

fails = 0
def check(ok, msg):
    global fails
    print(("  ok: " if ok else "  FAIL: ") + msg)
    fails += 0 if ok else 1

def engine_files():
    for p in ENGINE:
        full = os.path.join(ROOT, p)
        if os.path.isfile(full):
            yield p
        for d, _, names in os.walk(full):
            for n in sorted(names):
                if n.endswith((".sh", ".py")):
                    yield os.path.relpath(os.path.join(d, n), ROOT)

def is_python(rel):
    return rel.endswith(".py")

def code_lines(rel):
    """(lineno, code) for each line, comments dropped: full-line `#` comments, a trailing ` # …`,
    and (Python) docstrings / string-only lines."""
    with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    py = is_python(rel)
    in_doc = None
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if py:
            if in_doc:
                if in_doc in s:
                    in_doc = None
                continue
            m = re.match(r'^[rubf]*("""|\'\'\')', s)
            if m:
                q = m.group(1)
                if s.count(q) == 1:
                    in_doc = q
                continue
        if s.startswith("#"):
            continue
        yield n, re.sub(r"\s#\s.*$", "", line)

def main():
    for h in sorted(HELPERS):
        check(os.path.isfile(os.path.join(ROOT, h)), f"{h} exists")
    used = set()
    for rel in engine_files():
        if rel in HELPERS:
            continue
        rules = PYTHON if is_python(rel) else {**SHELL, **{"py " + k: PYTHON[k] for k in EMBEDDED_PY}}
        for n, code in code_lines(rel):
            for name, rx in rules.items():
                if not re.search(rx, code):
                    continue
                if (rel, name) in ALLOW:
                    used.add((rel, name))
                    continue
                check(False, f"{rel}:{n} uses raw {name} — go through scripts/portable.{'py' if is_python(rel) else 'sh'}: {code.strip()}")
    for key, why in ALLOW.items():
        check(key in used, f"allowlisted {key[1]} in {key[0]} is still used ({why[:60]}…)")
        check(len(why) > 40, f"allowlisted {key[1]} in {key[0]} gives a reason")
    # The helpers themselves must carry the primitives (or the guard guards nothing).
    sh = open(os.path.join(ROOT, "scripts/portable.sh"), encoding="utf-8").read()
    for name in ("lock_acquire", "lock_try", "lock_release", "lock_holders", "lock_free", "proc_find",
                 "proc_env", "proc_alive", "proc_ident", "proc_kill_tree", "detach_prefix", "new_uuid",
                 "native_path", "export_native_paths"):
        check(re.search(r"^" + name + r"\(\)", sh, re.M) is not None, f"portable.sh defines {name}")
    py = open(os.path.join(ROOT, "scripts/portable.py"), encoding="utf-8").read()
    for name in ("pid_alive", "lock_nb", "unlock"):
        check(re.search(r"^def " + name + r"\(", py, re.M) is not None, f"portable.py defines {name}")
    print(f"── {'FAILED' if fails else 'passed'} ({fails} failure(s))")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())

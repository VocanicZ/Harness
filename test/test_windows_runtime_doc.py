#!/usr/bin/env python3
"""test_windows_runtime_doc.py — #348 / PRD #344: the native-Windows runtime decision stays complete.

docs/adr/0001-native-windows-runtime.md records the decision, the alternatives weighed (Git Bash
with targeted replacements vs porting the dispatch loop to Node or Python, on effort, risk and the
"no new Linux runtime dependency" constraint, with MorphEdit/Hx as prior art), a dependency
inventory and the follow-up work.

The inventory is checked against the engine itself: every Linux-only primitive below that the
engine (bin/harness, scripts/, install.sh, update.sh) still uses must have a row naming it, with a
Windows replacement and an issue (or `none`). A new raw use of a listed primitive in a file the
row's `where` does not cover is fine; a primitive dropped from the table while the engine uses it
is not."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
DOC = os.path.join(ROOT, "docs", "adr", "0001-native-windows-runtime.md")
ENGINE = ["bin/harness", "scripts", "install.sh", "update.sh"]
# PRD #344's children: every issue the doc routes work to must be one of them.
SIBLINGS = {346, 347, 349, 350, 351, 352, 353, 354, 355, 356, 357, 358}

# Linux-only primitive -> (regex over engine source, regex the inventory row's first cell matches).
PRIMITIVES = {
    "tmux": (r"\btmux\b", r"`tmux`"),
    "/proc environ/cmdline": (r"/proc/[^ ]*/(environ|cmdline)", r"`/proc/<pid>/environ`"),
    "/proc fd scan": (r"/proc/(\[0-9\]\*|\*)/fd", r"`/proc/\*/fd`"),
    "kernel uuid": (r"/proc/sys/kernel/random/uuid", r"`/proc/sys/kernel/random/uuid`"),
    "flock (shell)": (r"\bflock (-[nu] )?(\"?\$|9)", r"`flock` \(shell\)"),
    "fcntl.flock": (r"fcntl\.flock", r"`fcntl\.flock`"),
    "pgrep": (r"\bpgrep\b", r"`pgrep`"),
    "ps -o": (r"\bps -e ?-?o", r"`ps -eo`"),
    "setsid": (r"\bsetsid\b", r"`setsid`"),
    "kill -0": (r"\bkill -0\b", r"`kill -0`"),
    "os.kill": (r"os\.kill\(", r"`os\.kill\(pid, 0\)`"),
    "trap TERM": (r"trap .*\bTERM\b", r"`trap … TERM`"),
    "nohup": (r"\bnohup\b", r"`nohup … &`"),
    "systemctl": (r"\b(systemctl|loginctl)\b", r"`systemctl --user`"),
    "stat -c": (r"\bstat -c\b", r"`stat -c`"),
    "date -d": (r"\bdate -d\b", r"`date -d`"),
    "readlink -f": (r"readlink -f|realpath -m", r"`readlink -f`"),
    "mv -T": (r"\bmv -T\b", r"`mv -T`"),
    "ln -s": (r"\bln -sf?n? ", r"`ln -s`"),
    "other coreutils": (r"sort -V|base64 -w|\btac\b|sha256sum|md5sum|xargs -r|cp -al", r"`sort -V`"),
    "chmod +x": (r"chmod (\+x|755)", r"`chmod \+x`"),
    "python3": (r"\bpython3\b", r"^`python3`$"),
    "bash": (r"#!/usr/bin/env bash", r"^`bash`$"),
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
            yield full
        for d, _, names in os.walk(full):
            for n in names:
                if n.endswith((".sh", ".py", ".js")):
                    yield os.path.join(d, n)

def engine_uses(rx):
    r = re.compile(rx)
    for f in engine_files():
        with open(f, encoding="utf-8", errors="replace") as fh:
            if r.search(fh.read()):
                return True
    return False

def section(text, title):
    m = re.search(r"^## " + re.escape(title) + r"\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    return m.group(1) if m else ""

def rows(body):
    out = []
    for line in body.splitlines():
        if not line.startswith("| ") or re.match(r"^\|[-| ]+\|$", line):
            continue
        out.append([c.strip() for c in line.strip().strip("|").split(" | ")])
    return out[1:]   # drop the header row

def main():
    check(os.path.isfile(DOC), "docs/adr/0001-native-windows-runtime.md exists")
    if not os.path.isfile(DOC):
        print("── FAILED: no decision doc"); return 1
    text = open(DOC, encoding="utf-8").read()

    for title in ("Context", "Decision", "Alternatives weighed", "Dependency inventory", "Follow-up work"):
        check(bool(section(text, title).strip()), f"has a non-empty `## {title}` section")

    alt = section(text, "Alternatives weighed")
    for name, rx in {"Git Bash/MSYS": r"Git Bash", "Node port": r"Node", "Python port": r"Python",
                     "full MSYS2": r"MSYS2"}.items():
        check(bool(re.search(rx, alt)), f"alternatives weigh {name}")
    for axis in ("Effort", "Risk", "No new Linux runtime dependency"):
        check(bool(re.search(r"^\| " + axis + r" \|", alt, re.M)), f"alternatives compare on {axis}")
    check("**chosen**" in alt, "alternatives mark the chosen path")
    check("https://github.com/MorphEdit/Hx" in text, "references MorphEdit/Hx as prior art")
    check(bool(re.search(r"^\*\*Run the engine as it is under Git Bash", section(text, "Decision"), re.M)),
          "the decision states the chosen path in bold")

    inv = rows(section(text, "Dependency inventory"))
    check(len(inv) >= len(PRIMITIVES), f"inventory has a row per primitive ({len(inv)} rows)")
    for r in inv:
        check(len(r) == 5 and all(r), f"inventory row {r[0] if r else '?'} has all 5 cells filled")
        if len(r) == 5:
            issues = {int(n) for n in re.findall(r"#(\d+)", r[4])}
            check(r[4] == "none" or (issues and issues <= SIBLINGS),
                  f"inventory row {r[0]} routes to #344's children or `none` ({r[4]})")
    for name, (eng_rx, doc_rx) in PRIMITIVES.items():
        if not engine_uses(eng_rx):
            print(f"  skip: engine no longer uses {name}")
            continue
        hit = [r for r in inv if re.search(doc_rx, r[0])]
        check(bool(hit), f"engine uses {name}: the inventory has its row")

    fu = section(text, "Follow-up work")
    for n in (355, 356, 357, 358):
        check(f"#{n}" in fu, f"follow-up work names #{n}")
    check(bool(re.search(r"comment on #344", fu)), "follow-up work says amendments go to #344")

    print(f"── {'FAILED' if fails else 'passed'} ({fails} failure(s))")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())

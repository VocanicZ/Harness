#!/usr/bin/env bash
# usage-statusline.sh <usage-dir> — Claude Code status line for Harness worktrees (#194).
# Claude Code pipes the status-line JSON on stdin; its `rate_limits` block carries the 5-hour and
# weekly windows (`used_percentage`, `resets_at`). Drop it into <usage-dir>/<account>.json for
# usage.sh's claude adapter, record which account this worktree runs on, and print a short line.
# The account is the claude-acc config dir the pane picked (CLAUDE_CONFIG_DIR), else "default".
set -uo pipefail
dir="${1:?usage: usage-statusline.sh <usage-dir>}"
mkdir -p "$dir/cwd" 2>/dev/null
ACCT="$(basename "${CLAUDE_CONFIG_DIR:-default}")" DIR="$dir" python3 -c '
import json, os, sys, tempfile, time
d, acct = os.environ["DIR"], os.environ["ACCT"]
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
key = lambda s: "".join(c if c.isalnum() or c in "._-" else "_" for c in s)
cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or ""
if cwd:
    with open(os.path.join(d, "cwd", key(cwd)), "w") as fh:
        fh.write(acct)
rl = data.get("rate_limits") or {}
if rl:
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".usage.")
    with os.fdopen(fd, "w") as fh:
        json.dump({"account": acct, "at": int(time.time()), "rate_limits": rl}, fh)
    os.replace(tmp, os.path.join(d, key(acct) + ".json"))
names = {"five_hour": "5h", "seven_day": "7d"}
parts = ["%s %d%%" % (names.get(k, k), round(w.get("used_percentage"))) for k, w in sorted(rl.items())
         if isinstance(w, dict) and w.get("used_percentage") is not None]
print("harness · " + (" · ".join(parts) if parts else "usage n/a"))
'

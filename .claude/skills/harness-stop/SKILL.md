---
name: harness-stop
description: Stop the Harness worker pool. Trigger on /harness-stop or "stop the fleet".
---

# /harness-stop — stop the worker pool

Thin wrapper around `.harness/bin/harness stop`.

**`stop` halts the pool; `stop --clean` ALSO removes worktrees (discards uncommitted work in them) — confirm before running, and never `--clean` while sessions are live unless the user wants their worktrees gone.**

1. Confirm with the user. Ask whether they want `--clean` (default: no).
2. Run: `.harness/bin/harness stop`   (or `.harness/bin/harness stop --clean`)
3. Report what stopped.

To pause without killing in-flight work, prefer `/harness-pause`. For operate guidance use `/harness`.

---
name: harness-resume
description: Resume a paused Harness fleet — clears the pause and continues here or via crash-recovery sweep. Trigger on /harness-resume or "resume the agents".
---

# /harness-resume — resume the fleet

Thin wrapper around `.harness/bin/harness resume`.

**Confirm before running** (it may relaunch the pool and re-dispatch paused work).

`resume` clears the local pause. If no pool is running here it runs `start --recover`, so it works on any
machine: open `agent-paused` issues are re-dispatched and continued from their pushed branch + handoff comment.
So you can `pause --force` on a laptop and `resume` on a server — the work continues.

1. Confirm with the user.
2. Run: `.harness/bin/harness resume`
3. Report. Watch with `/harness-status`.

---
name: harness-pause
description: Pause the Harness fleet — drain (stop claiming new work) or checkpoint each agent to GitHub. Trigger on /harness-pause or "pause the agents".
---

# /harness-pause — pause the fleet

Thin wrapper around `.harness/bin/harness pause`.

**Confirm before running.** Two modes:
- `pause` — soft drain: workers stop claiming new work; in-flight agents finish naturally. Local to this machine.
- `pause --force` — tells each live agent to commit + push its branch, post `/handoff` context as a
  GitHub issue comment, and label the issue `agent-paused`, then idle. All state in GitHub → resumable on any machine.

1. Confirm with the user. Ask soft drain vs `--force` checkpoint (default: soft).
2. Run: `.harness/bin/harness pause`   (or `.harness/bin/harness pause --force`)
3. Report. Resume later with `/harness-resume` (works on any machine after `--force`).

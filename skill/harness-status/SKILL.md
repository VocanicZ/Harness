---
name: harness-status
description: Show the Harness fleet dashboard — per-unit state, what's running, complete vs stuck. Trigger on /harness-status or "what's the harness doing".
---

# /harness-status — show the dashboard

Thin wrapper around `.harness/bin/harness status`. Read-only — run it immediately, no confirm needed.

Run: `.harness/bin/harness status`

For a live view, the user should run it themselves (it blocks until Ctrl-C):
`! .harness/bin/harness status --watch`

## Reading it
Per unit: `mode=… PRD#… plan=… children=… open=… unblocked=… paused=… reviewed=… complete=…`.
- `FLEET: PAUSED` ⇒ drained; `/harness-resume` to continue.
- `complete=Y` and idle ⇒ DONE, not stuck.
- `open>0 unblocked=0` with no live session ⇒ likely a mis-pointed `## Blocked by` — investigate (use `/harness` to unstick).

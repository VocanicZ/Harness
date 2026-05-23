---
name: harness-start
description: Launch the Harness worker pool for this project. Trigger on /harness-start or "start the fleet".
---

# /harness-start — launch the worker pool

Thin wrapper around `.harness/bin/harness start`. Don't do a unit's PLAN/PRD/IMPL by hand — the pool dispatches it.

**Starting spawns background workers + tmux sessions — confirm before running.**

1. Confirm with the user.
2. Run: `.harness/bin/harness start`
   - Crash / new-host recovery sweep: `.harness/bin/harness start --recover`
3. Report that the pool launched. Watch with `/harness-status`; stop with `/harness-stop`.

Needs `.harness/config` to exist first — if missing, run `/harness-init`. For operate+unstick use `/harness`.

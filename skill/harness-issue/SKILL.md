---
name: harness-issue
description: Inject a discrete implementation issue (or a few) into a LIVE Harness fleet — grill the requirement, confirm a crystallized brief, then launch the headless injector. Trigger on /harness-issue or "add a task to the running fleet".
---

# /harness-issue — inject implementation issue(s) into a live fleet

Thin wrapper around `.harness/bin/harness issue "<brief>"`. The altitude here is **one unit of
work**: a discrete `[AFK]` implementation issue the running pool can claim on its next poll — no
fleet restart. The actual mutation happens in a headless injector; your job here is to **grill the
requirement, then gate it behind an explicit human confirmation**. Mutate NOTHING while grilling.

## 1. Grill first (no mutation)
Interview the user (reuse the `grill-me` pattern) until the new task is fully pinned down. Cover:
- **Outcome** — what should exist when this issue is done?
- **Acceptance criteria** — testable, concrete.
- **Ordering** — what existing issues must it wait on (depends-on), and which idle issues should now
  wait on it (must-precede)? Use same-repo `#N` references only.
- **What it must NOT break** — in-flight work is read-only; the injector only adds.

Do not edit issues, labels, or files during this phase.

## 2. Confirm the brief (the human safety gate)
Replay a single crystallized brief — outcome + acceptance criteria + ordering — and ask the user to
**confirm** it verbatim. No confirmation, no run. This confirmation is the safety gate; the headless
injector does not re-grill.

## 3. Run the injector
- Default unit: `.harness/bin/harness issue "<confirmed brief>"`
- Multi-topology — target one unit: `.harness/bin/harness issue --unit <id> "<confirmed brief>"`

This launches a headless session `hz-inject-<unit>`; it reconciles the brief against live GitHub
state and creates the issue(s) additively, with correct `## Blocked by` ordering.

## 4. Report
Tell the user the `hz-inject-<unit>` session launched and the live pool will claim the new
`ready-for-agent` work within one poll — no restart. Watch progress with `/harness-status`.

## Retired-fleet fallback
"No restart" only holds while the fleet is live. If `/harness-status` shows the pool retired (all
units complete, workers exited), the new issue won't be picked up until you relaunch:
`.harness/bin/harness start --recover` (or `/harness-start --recover`). The injector refuses to run
while a live `REVIEW` session exists for the unit — wait for it to finish, then retry.

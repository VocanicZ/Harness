---
name: harness-prd
description: Extend a LIVE Harness fleet's PRD scope and create the delta issues — grill the new scope, confirm a crystallized brief, then launch the headless injector. Trigger on /harness-prd or "grow the PRD scope".
---

# /harness-prd — extend PRD scope + create delta issues

Thin wrapper around `.harness/bin/harness prd "<brief>"`. The altitude here is **a scope /
milestone**: reopen the PRD (clearing `reviewed` if set), append the new scope to its body, and
create ONLY the **delta** child issues — never duplicating existing children. The mutation happens
in a headless injector; your job here is to **grill the new scope, then gate it behind an explicit
human confirmation**. Mutate NOTHING while grilling.

## 1. Grill first (no mutation)
Interview the user (reuse the `grill-me` pattern) until the scope expansion is fully pinned down:
- **Milestone outcome** — what does the grown PRD now promise that it didn't before?
- **Acceptance criteria** — per new capability, testable.
- **Delta vs. existing** — which existing children already cover part of this? The injector adds
  only the genuinely new tasks; help name what is NOT already represented.
- **Ordering** — how the new work depends on / must precede existing idle issues (same-repo `#N`).
- **What it must NOT break** — in-flight work and done work are untouched; this is purely additive.

Do not reopen the PRD, edit the body, or create issues during this phase.

## 2. Confirm the brief (the human safety gate)
Replay a single crystallized brief — new scope + acceptance criteria + the delta tasks + ordering —
and ask the user to **confirm** it verbatim. No confirmation, no run. The headless injector does not
re-grill; this confirmation is the safety gate.

## 3. Run the injector
- Default unit: `.harness/bin/harness prd "<confirmed brief>"`
- Multi-topology — target one unit: `.harness/bin/harness prd --unit <id> "<confirmed brief>"`

This launches a headless session `hz-inject-<unit>` that reopens + grows the PRD and creates the
delta issues additively, re-engaging the unit so dispatch re-includes it.

## 4. Report
Tell the user the `hz-inject-<unit>` session launched; the PRD is reopened and the new
`ready-for-agent` delta issues will be claimed by the live pool within one poll — no restart. Watch
with `/harness-status`.

## Retired-fleet fallback
"No restart" only holds while the fleet is live. If `/harness-status` shows the pool retired (all
units complete, workers exited), relaunch to pick up the grown scope:
`.harness/bin/harness start --recover` (or `/harness-start --recover`). The injector refuses to run
while a live `REVIEW` session exists for the unit (a REVIEW could close the PRD out from under the
injection) — wait for it to finish, then retry.

---
name: harness-plan
description: Inject a structural plan change into a LIVE Harness fleet — edit PLAN.md and cascade it into the PRD and delta issues. Grill the change, confirm a crystallized brief, then launch the headless injector. Trigger on /harness-plan or "change the plan".
---

# /harness-plan — inject a plan change

Thin wrapper around `harness plan "<brief>"`. The altitude here is **structural**: edit
the umbrella `PLAN.md` (milestone order, scope, dependency edges between issues), cascading down into
the PRD body + delta issues. The fleet is one repo; work in a submodule is an issue in that repo with a
`## Code location` section, not a separate fleet. The
mutation happens in a headless injector; your job here is to **grill the change, then gate it behind
an explicit human confirmation**. Mutate NOTHING while grilling.

## 1. Grill first (no mutation)
Interview the user (reuse the `grill-me` pattern) until the structural change is fully pinned down:
- **What changes structurally** — a new dependency edge between issues? a reshaped `PLAN.md`
  milestone ordering? new scope in a submodule (its `## Code location`)?
- **Cascade** — how the change flows down into the PRD and the delta issues.
- **Ordering** — same-repo `#N` edges only on idle issues; no cycles.
- **What it must NOT break** — in-flight issues are untouched; existing edges stay valid.

Do not edit `PLAN.md` or create issues during this phase.

## 2. Confirm the brief (the human safety gate)
Replay a single crystallized brief — the structural change + new edges + cascade + ordering
— and ask the user to **confirm** it verbatim. No confirmation, no run. The headless injector does
not re-grill; this confirmation is the safety gate.

## 3. Run the injector
Run: `harness plan "<confirmed brief>"`

This launches a headless session `hz-inject-<unit>` that edits `PLAN.md` (commit + push) and
cascades into the PRD + delta issues additively.

## 4. Report
Tell the user the `hz-inject-<unit>` session launched; the plan change is committed, so the live
pool claims the new work within one poll — no restart. Watch with
`/harness-status`.

## Retired-fleet fallback
"No restart" only holds while the fleet is live. If `/harness-status` shows the pool retired (all
issues complete, workers exited), relaunch to pick up the changed plan:
`harness start --recover` (or `/harness-start --recover`). The injector refuses to run
while a live `REVIEW` session exists — wait for it to finish, then retry.

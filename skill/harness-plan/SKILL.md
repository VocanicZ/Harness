---
name: harness-plan
description: Inject a structural / topology change into a LIVE Harness fleet — edit PLAN.md / targets.tsv (incl. seeding a new target repo). Grill the change, confirm a crystallized brief, then launch the headless injector. Trigger on /harness-plan or "change the fleet topology".
---

# /harness-plan — inject a plan / topology change

Thin wrapper around `.harness/bin/harness plan "<brief>"`. The altitude here is **structural**: edit
the umbrella `PLAN.md` and/or the multi-target `targets.tsv` (add a unit, change a dependency edge),
cascading down into the PRD body + delta issues, and — for a brand-new target unit — seed it
(`seed.sh <unit>`: clone + labels + CI) so the pool can claim it once its deps complete. The
mutation happens in a headless injector; your job here is to **grill the change, then gate it behind
an explicit human confirmation**. Mutate NOTHING while grilling.

## 1. Grill first (no mutation)
Interview the user (reuse the `grill-me` pattern) until the structural change is fully pinned down:
- **What changes structurally** — a new target repo? a new dependency edge between units? a reshaped
  `PLAN.md` milestone ordering?
- **For a new target** — repo slug, what it delivers, and which existing units it depends on / which
  depend on it.
- **Cascade** — how the change flows down into the PRD and the delta issues.
- **Ordering** — same-repo `#N` edges only on idle issues; no cycles.
- **What it must NOT break** — in-flight units are untouched; existing edges stay valid.

Do not edit `PLAN.md` / `targets.tsv`, seed repos, or create issues during this phase.

## 2. Confirm the brief (the human safety gate)
Replay a single crystallized brief — the structural change + new targets/edges + cascade + ordering
— and ask the user to **confirm** it verbatim. No confirmation, no run. The headless injector does
not re-grill; this confirmation is the safety gate.

## 3. Run the injector
- Default unit: `.harness/bin/harness plan "<confirmed brief>"`
- Multi-topology — target one unit: `.harness/bin/harness plan --unit <id> "<confirmed brief>"`

This launches a headless session `hz-inject-<unit>` that edits `PLAN.md`/`targets.tsv` (commit +
push), seeds any new target, and cascades into the PRD + delta issues additively.

## 4. Report
Tell the user the `hz-inject-<unit>` session launched; the plan/topology change is committed and any
new unit is seeded, so the live pool claims the new work within one poll — no restart. Watch with
`/harness-status`.

## Retired-fleet fallback
"No restart" only holds while the fleet is live. If `/harness-status` shows the pool retired (all
units complete, workers exited), relaunch to pick up the changed topology:
`.harness/bin/harness start --recover` (or `/harness-start --recover`). The injector refuses to run
while a live `REVIEW` session exists for the unit — wait for it to finish, then retry.

---
name: subagent-task-tree
description: Execute a multi-task implementation plan as a chained subagent tree — you are the parent controller; you spawn one manager per task; each manager spawns a planner, a plan-auditor, one implementer per subtask, per-subtask auditors, and a final drift-auditor. Use when the user wants to "implement each task using subagents", asks for chained/nested subagents, a manager-per-task build, or subagent-driven execution of a plan/spec with audit gates at every level.
---
<!-- harness-skill: vendored by Harness from VocanicZ/vocanicz-ai-tools@e66b6c5 (skill/subagent-task-tree) -->

# Subagent Task Tree

A deep, audited version of subagent-driven development. **You** stay the parent controller and never write
production code; every level of real work is delegated, and **every artifact is audited before it advances.**
This preserves your context for coordination and forces quality gates at the plan, subtask, and task levels.

## The tree (who spawns whom)

```
PARENT (you, the controller)
└─ per task, in dependency order:  MANAGER  (one Agent call per task)
   ├─ PLANNER            → decompose the task into ordered, shippable SUBTASKS
   ├─ PLAN-AUDITOR       → audit the plan vs the spec; loop til PASS
   ├─ per subtask, IN SEQUENCE (never parallel on shared files):
   │    IMPLEMENTER      → TDD: failing test first, then code, self-review, commit
   │    ├─ SPEC-COMPLIANCE AUDITOR   → does it match the spec? (over/under-build?)
   │    ├─ CODE-QUALITY AUDITOR      → is it well-built?
   │    └─ DOMAIN AUDITOR (optional) → invariant/adversarial check on risky changes
   │    (loop implementer↔auditors til all ✅, then next subtask)
   └─ DRIFT-AUDITOR      → diff the whole task vs the spec; gaps = labeled debt or loop-fix
   → MANAGER reports to PARENT; PARENT integrates (push/track) and starts the next task
```

Managers spawn their own subagents, so they need an agent type with the Agent tool (e.g. `general-purpose`).

## Parent (you) workflow

1. **Read the plan + the authoritative docs yourself once.** Identify every task and its dependencies.
2. **Create a task list** (one entry per task) and wire the dependency chain. Tasks that touch the same
   files run **sequentially**, never in parallel.
3. **Configure the project contract** (see "Project contract" below) — you will paste it verbatim into
   every manager brief.
4. **Dispatch ONE manager per task**, in dependency order. Mark the task in-progress; hand the manager its
   verbatim task text + the contract + the engine/repo facts. Wait for its report.
5. **On the manager's report:** integrate (commit/push per the contract), mark the task done, handle any
   escalation (see below), then dispatch the next manager.
6. **Escalations are yours (or the user's).** A manager escalates a genuine fork (a design decision, an
   off-spec mechanism that seems required, a spec contradiction). Resolve it or surface it to the user with
   a recommendation — never let a manager silently pick.

Do not write production code, and do not run the work yourself — delegate. Keep your context for the map.

## Manager brief (what every manager must do)

Give each manager the full **[MANAGER-BRIEF-TEMPLATE.md](MANAGER-BRIEF-TEMPLATE.md)** filled in. It must:
read the authoritative docs first → spawn planner → spawn plan-auditor (loop) → run subtasks sequentially
each with its three audits (loop) → spawn drift-auditor → report back with SHAs, verbatim test output,
invariant numbers, the drift verdict, and any escalation. Auditor prompt skeletons are in
**[AUDIT-PROMPTS.md](AUDIT-PROMPTS.md)**.

## Project contract (fill these in, paste into EVERY brief)

The discipline lives in a small contract copied verbatim into every manager AND every sub-subagent brief:

- **Test policy** — the exact allowed commands and any ban (e.g. "targeted single tests only, never the full
  suite"). State it as a hard rule; sub-subagents inherit it.
- **Evidence policy (differential rule)** — a failing test is CAUSED BY THIS WORK by default. Any dismissal
  ("pre-existing", "flaky", "unrelated", "stale golden", "ULP noise") is REJECTED unless accompanied by
  VERBATIM output of the same test run at the task's BASE commit showing the identical failure there. Report
  tests as raw runner output (counts + failing-case lines), never prose. Goldens regenerate only after the
  diff is shown + explained. State this as a hard rule; sub-subagents inherit it.
- **Source of truth** — "the spec is truth, the code is the bug." Name the authoritative docs + a fixed
  **read order**. Forbid reverse-engineering the design from existing code.
- **Invariants** — the non-negotiables to check every task (conservation laws, security properties, no-X
  rules). The DOMAIN auditor enforces these.
- **Commit/push policy** — who commits (implementers, on which branch) and who integrates (the parent
  pushes between tasks; never on a protected branch without consent).
- **Communication tone** (optional) — any house style for user-facing replies (the *parent's*, not the
  subagents' internal reports).

## Rules that make it work (hard-won)

- **Sequential subtasks on shared files.** Parallel implementers editing the same files corrupt each other.
  Parallelize only genuinely independent tasks.
- **Audit gates are not optional.** Spec-compliance BEFORE code-quality. Loop until ✅; never advance with
  open findings. A domain/adversarial audit is mandatory on anything touching the invariants.
- **Drift audit per task**, comparing the *whole* task diff to the spec — catches scope creep and silent
  gaps the per-subtask audits miss.
- **Escalate, don't absorb.** A manager that hits a real fork stops and reports; it does not guess. Pre-name
  the likely escalation triggers in the brief.
- **Timebox defects** (~3 honest attempts), then land a green-and-coherent partial with a labeled
  `// <TASK>-OPEN:` skip + owner and report `DONE_WITH_CONCERNS` — don't loop forever.
- **Mind the test policy's blind spots.** If you ban full test runs, *no one* sees aggregate/integration
  failures — the integration seam (where modules meet) is exactly where gaps hide. Plan a deliberate
  targeted sweep of integration tests, or expect the user's first full build to surface them.
- **A failing test is YOURS until proven otherwise (differential-evidence rule).** Subagents rationalize
  under pressure to report `DONE` — the tell is an unfalsifiable excuse ("pre-existing", "flaky", "stale
  golden"). Make a false done structurally impossible: any such dismissal is rejected without VERBATIM output
  of the same test at the BASE commit showing the identical failure. The PARENT independently re-runs the
  gate (and the differential) before integrating — a subagent's `DONE` is a claim to disprove, not a fact.
  Trust nothing that isn't reproduced. (This rule was added after a manager twice mislabeled real regressions
  as pre-existing; the parent's base-commit re-run caught both.)
- **Statuses:** managers report `DONE` / `DONE_WITH_CONCERNS` / `NEEDS_CONTEXT` / `BLOCKED`. Give context
  and re-dispatch on the last two; never re-run an identical brief and hope.

## When to use vs not

Use for a written multi-task plan/spec with mostly-independent tasks where you want maximum quality gates
and to stay in one session. For a single small task, just do it (or one implementer + review). For tightly
coupled tasks that can't be decomposed, do them manually or re-plan first.

See [MANAGER-BRIEF-TEMPLATE.md](MANAGER-BRIEF-TEMPLATE.md) and [AUDIT-PROMPTS.md](AUDIT-PROMPTS.md).

# Route Harness impl workers through `subagent-task-tree`

**Date:** 2026-06-16
**Status:** Approved (design)

## Problem

Each Harness implementation worker (`prompts/impl.md`) is told to dispatch
parallel sub-agents via the `subagent-driven-development` skill for sizeable
work. The user has an improved skill, `subagent-task-tree`, that adds an audit
layer and a chained subagent tree (planner → plan-auditor → per-subtask
implementer + spec/quality/domain audits → drift-auditor). We want Harness
workers to use that skill instead, the skill published to
`VocanicZ/vocanicz-ai-tools`, and Harness's install path to fetch it.

## Decisions

- **Gate it.** Use `subagent-task-tree` only for sizeable / multi-subtask
  issues. Small issues keep the light path ("just do it" / single implementer +
  review), honoring the skill's own guidance and controlling token cost (workers
  run in parallel sharing a rate-limited GitHub token + token budgets).
- **Both install paths** fetch the skill: Harness `install.sh` and the
  `vocanicz-ai-tools` Node installer.
- **Publish layout:** a new top-level `skills/subagent-task-tree/` directory in
  the `vocanicz-ai-tools` repo, via a **branch + PR** against `master` (not a
  direct push).
- **Component-D wording is "apply the discipline," not "invoke verbatim"** — see
  Risk 1.

## Components

### A. Publish (vocanicz-ai-tools repo)
Add `skills/subagent-task-tree/` holding the 3 files copied verbatim from
`~/.claude/skills/subagent-task-tree/`: `SKILL.md`, `MANAGER-BRIEF-TEMPLATE.md`,
`AUDIT-PROMPTS.md`. Land via a feature branch + PR against `master`.

### B. vat Node installer — `src/modules/harness.js → setupClaudeIntegration`
After the existing skill installs, **recursively** copy the package's own
`skills/subagent-task-tree/` into `~/.claude/skills/subagent-task-tree/`,
guarded by an `existsSync` check so it never clobbers a user's same-named skill
(mirrors the to-prd/to-issues guard). The current internal-skill copy uses flat
`fs.copyFile` and cannot handle directory-skills, so add a small recursive copy
helper for this rather than rely on it. Best-effort: failures warn, never throw.

### C. Harness installer — `install.sh → ensure_skills()`
Add a `VOCANICZ_TOOLS_URL` var (default `https://github.com/VocanicZ/vocanicz-ai-tools.git`)
and a block mirroring the existing matt-pocock pattern:
- skip if `~/.claude/skills/subagent-task-tree` already exists;
- else shallow-clone the vat repo to a tempdir, locate
  `*/subagent-task-tree/SKILL.md`, `cp -r` its parent dir into
  `~/.claude/skills/`, then `rm -rf` the tempdir;
- a clone/copy failure prints a warning and returns 0 (never fails install).

### D. Harness prompt wiring — `prompts/impl.md` (the `subagent-driven-development` line)
Replace the single sub-agent line with a **gated** instruction:
> For sizeable / multi-subtask work, apply the audited `subagent-task-tree`
> discipline (planner → plan-auditor → per-subtask implementer + spec/quality/
> domain audits → drift-auditor). For small issues a single implementer + review
> (or `subagent-driven-development`) is fine — just do it. Stay in THIS repo.

The worker still drives its single issue to merged + closed exactly as today.
Scope is `impl.md` only; `bug-fix.md` does not reference subagents and is
untouched.

### E. Tests
- **vat:** extend `test/harness.test.js` (vitest) to assert
  `setupClaudeIntegration` copies the skill dir recursively and does not
  overwrite an existing same-named skill.
- **Harness:** add coverage for the new `ensure_skills` branch in the existing
  `test/` framework (confirm framework during planning).

## Risks

1. **Single-issue vs. multi-task mismatch.** `subagent-task-tree` is written for
   a multi-*task* plan with a manager-per-task. A Harness worker handles ONE
   issue, so the gated wording maps the issue's *subtasks* onto the tree (the
   worker acts as the manager/parent applying planner → auditors → implementers →
   drift-auditor) rather than literally spawning a manager-per-task. Hence
   "apply the discipline," not "invoke verbatim."
2. **Nested-subagent permissions.** Sub-agents do not inherit
   `--dangerously-skip-permissions`; mitigated host-wide via `settings.json`
   `permissions.defaultMode: bypassPermissions`. The deeper tree relies on that
   setting being present on every fleet host (see memory
   `subagents-dont-inherit-skip-permissions`).

## Out of scope
- Changing `bug-fix.md` or other prompts.
- Fixing the pre-existing flat-copy limitation in vat's internal-skill copy
  beyond what Component B needs.

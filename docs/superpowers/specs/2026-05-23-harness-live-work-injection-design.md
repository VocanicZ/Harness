# Spec: Live work injection — `/harness-plan`, `/harness-prd`, `/harness-issue`

**Date:** 2026-05-23
**Status:** Approved (brainstorming) — serves as the umbrella `HARNESS_SPEC` for planned-mode self-hosting.
**Repo:** `VocanicZ/Harness` (Harness improving Harness).

## Problem

Once a Harness fleet is running, there is no first-class way to **add new work** — a new
implementation issue, an expansion of the PRD scope, or a structural/topology change — *without*
stopping and restarting the fleet and hand-authoring issues with correct dependency ordering.
Operators need to inject work into a **live** fleet such that:

- the new work is reconciled against what is already **done / in-flight / not-started**;
- it slots into the dependency order **without colliding with in-flight layers**;
- the running pool **picks it up automatically** on its next poll (no restart);
- issue **ordering** (blocked-by) is set correctly when the new work has prerequisites or must
  precede existing idle work.

This is a **prompt-driven** capability ("Claude skill only"), not a script-heavy one: thin shell,
smart prompts.

## Goals

1. Three sibling Claude skills, one per altitude of injection:
   - `/harness-plan` — edit the umbrella plan (`PLAN.md`) and/or topology (`targets.tsv`).
   - `/harness-prd` — extend the PRD scope and create the resulting delta issues.
   - `/harness-issue` — create discrete implementation issue(s).
2. Each skill **grills the user** (relentless interview) until the requirement is fully understood
   **before** anything is mutated. Claude grills the user; the user's confirmation of the
   crystallized brief is the human safety gate.
3. The actual mutation runs in a **headless** one-shot Claude "injector" session that reconciles
   the brief against live GitHub state and injects the work safely.
4. The live pool selects the injected work automatically — **no fleet restart** while the fleet is
   running.
5. Topology editing is in scope for v1 (`targets.tsv` rewrites, new target repos, dep-edge changes).

## Non-goals

- Removing or cancelling already-dispatched work (this spec only *adds*).
- A GUI; everything is CLI/skill + GitHub state.
- Changing the core invariant: **no database, no daemon** — all state stays in GitHub issues,
  labels, pushed commits, and the local run directory.

## Architecture (Approach ①: reuse the pipeline)

The injector reuses the engine's **conventions** (`## Blocked by`, `[AFK]` titles, `Part of #<prd>`,
the `to-issues`/`to-prd`/`writing-plans` skills) and its **auto-dispatch pickup** (label →
`issuelib.dispatch` recomputes state every poll). It does **not** re-fire the `DECOMPOSE` stage
(the engine only decomposes when `prd != None AND not children_exist`, so it never re-decomposes);
instead the injector creates the **delta** child issues itself.

### Components (all ship in-repo; deployed by `install.sh`, redeployed by `harness update`)

| New / changed file | Responsibility |
|---|---|
| `skill/harness-plan/SKILL.md`, `skill/harness-prd/SKILL.md`, `skill/harness-issue/SKILL.md` | Thin skills. Grill the user (reuse `grill-me` pattern) → confirm brief → run `.harness/bin/harness <plan\|prd\|issue> "<brief>"`. |
| `bin/harness` | New cases `plan) prd) issue)` → `exec bash inject.sh <altitude> "$@"`; add to `usage`. |
| `inject.sh` (new) | Thin: resolve unit/slug, gather live context, render `prompts/inject.md`, launch headless session `hz-inject-<unit>` via `launch_claude`, exit. |
| `prompts/inject.md` (new) | Injector instructions parameterized by `{{ALTITUDE}}`, `{{BRIEF}}`, `{{SLUG}}`, `{{SPEC}}`, label vars. Holds the reconciliation algorithm + safety rules. |
| `prompts/decompose.md` (edit) | Defensive idempotency — read existing children first, only create missing tasks. |
| `test/test_inject.sh` (new) + additions to `test_cli.sh`, `test_skill.sh`, `test_subskills.sh` | See Testing. |

### Grill phase (inline, user's session)
No mutation until intent is locked. Interview covers: the outcome wanted; testable acceptance
criteria; **ordering** (depends-on / must-precede existing work); and **what it must not break**.
Altitude-specific framing (issue = one unit of work; prd = a scope/milestone; plan = structural /
topology change). Ends by replaying a crystallized brief for explicit confirmation.

### Headless injector — reconciliation algorithm (`prompts/inject.md`)
1. **Read live state:** PRD, children (state + labels), `PLAN.md`, `targets.tsv`. Classify children:
   `closed` (done) · `agent-working` (in-flight — **read-only**) · open & idle (reorderable) · blocked.
2. **Locate the fit:** what the brief depends on; which idle work should depend on it.
3. **Act by altitude:**
   - `issue` → create issue(s) directly: `[AFK]` title, `ready-for-agent`, `## Blocked by` with
     same-repo `#N` prerequisites (in-flight refs are allowed — the work simply waits),
     `Part of #<prd>`.
   - `prd` → reopen PRD + remove `reviewed` if needed; append new scope to PRD body; create the
     **delta** child issues itself (additive — never duplicate existing).
   - `plan` → edit `PLAN.md` (commit+push) and/or `targets.tsv` (add row / change deps); cascade to
     PRD + delta issues; for a **new multi target**, run `seed.sh <unit>` (clone + labels + CI) so
     the pool can claim it.
4. **Ordering:** only set/adjust `## Blocked by` on **idle** issues; never edit `agent-working`
   issues; guard against cycles; same-repo `#N` refs only.
5. **Re-engage:** ensure the unit is no longer COMPLETE (PRD reopened, `reviewed` cleared) so
   dispatch re-includes it; REVIEW re-fires later (children all closed + PRD open).
6. **Summarize:** post a comment (issue links, ordering graph, what was deliberately left
   untouched) and write a run-log line.

### Safety invariants ("don't crash other layers")
- Never modify an `agent-working` issue.
- Refuse to run while a live `REVIEW` session (`hz-<unit>`) exists for the unit; wait or abort with
  a clear message (otherwise REVIEW could close the PRD out from under the injection).
- Injector session is named `hz-inject-<unit>` so it never matches the `team_sessions`
  `^hz-<unit>($|-i)` pattern — never consumes a CAP or orchestration slot.
- No dependency cycles.

### Live-pickup vs restart
While the fleet is live, the next poll (≤ `HARNESS_POLL`s) picks up the new work — **no restart**.
If pidfiles show the pool retired (all units COMPLETE → workers exited), the skill reports this and
offers `harness start --recover`.

## Acceptance criteria

- [ ] `harness plan|prd|issue "<brief>"` exist as CLI subcommands and appear in `harness help`.
- [ ] `/harness-plan`, `/harness-prd`, `/harness-issue` install (via `install.sh`) and are
      recognized as skills; each grills the user before mutating.
- [ ] `/harness-issue` against a live single-topology fleet creates a `ready-for-agent` issue with a
      correct `## Blocked by` section and the pool dispatches it within one poll, **without restart**.
- [ ] `/harness-prd` reopens a completed PRD, clears `reviewed`, appends scope, and creates only the
      **delta** issues (no duplicates of existing children).
- [ ] `/harness-plan` can add a row to `targets.tsv`, seed the new repo, and the multi-pool claims
      the new unit once its deps are complete.
- [ ] The injector never edits an `agent-working` issue and aborts/waits if a `REVIEW` session is
      live for the unit.
- [ ] The injector session name does not collide with `team_sessions` (verified by test).
- [ ] No dependency cycle can be introduced (verified by test).
- [ ] `test/test_inject.sh` passes; `test_cli.sh`, `test_skill.sh`, `test_subskills.sh` updated and
      passing.

## Testing

Shell tests in the existing `test/` style (`test/helpers.sh`): subcommand routing; prompt-render
variable substitution; session-name non-collision with the `team_sessions` regex; additive-delta
(no duplicate issues); `targets.tsv` rewrite + new-unit seeding path; cycle rejection; and that the
three skills install and are recognized.

## Open risks

- **REVIEW race:** mitigated by the live-session guard, but a REVIEW that starts *immediately* after
  the guard check is a narrow window; the injector reopening the PRD with open children prevents the
  *next* REVIEW from completing prematurely.
- **Retired fleet:** "no restart" holds only for a live fleet; documented + surfaced by the skill.

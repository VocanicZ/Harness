# Multi-PRD support in `prd` mode

**Date:** 2026-08-12
**Status:** Design approved, pending implementation plan

## Problem

The engine is hard-wired to exactly one PRD per unit. Drop a second PRD issue into a repo and it
is silently invisible — no error, no log line, no work. Four sites assume the singular:

| Site | Assumption |
|---|---|
| `issuelib.py:380` | `prd = next(...)` — takes the **first** match, discards the rest |
| `issuelib.py:385` | `children` = *every* ready-labelled issue in the repo, not scoped to a PRD |
| `issuelib.py:457` | `DECOMPOSE` fires only when `not children_exist` — repo-global |
| `issuelib.py:483` | `is_complete` keys on *that one* PRD closing |

Consequences, in order of how quickly they bite: PRD #2 is never decomposed once PRD #1 has any
children; PRD #2's children (if hand-filed) are pooled into PRD #1's `children_all_closed`, so
PRD #1's REVIEW is gated on unrelated work; and the unit reports COMPLETE when PRD #1 closes,
leaving PRD #2 untouched while the resident worker idles.

Multiple PRDs must be a general engine capability, reachable from all three sources: queued
upfront by a human, injected into a live fleet, or emitted as a set by the PLAN agent.

## Approach

**`## Blocked by` is the only ordering mechanism.** A PRD with no blockers is eligible
immediately; a PRD carrying `## Blocked by #41` waits until #41 closes. Parallel execution is not
a separate feature — it is the degenerate case of the same rule. This yields one code path
instead of two, reuses `parse_blocked_by` verbatim (including its cross-repo `owner/repo#N`
support), keeps GitHub as the sole source of truth, and adds no configuration knob. Ordering is
chosen per-PRD at authoring time rather than globally.

Two alternatives were rejected. A global `HARNESS_PRD_ORDER=parallel|serial` knob cannot express
"PRDs 3 and 4 are independent, but 5 needs 3". A `prds.tsv` dependency file alongside
`targets.tsv` would put ordering in local state that drifts from GitHub, breaking the engine's
stated invariant, and would make the ordering invisible to anyone reading the issues.

## State model

`compute_state` returns a list ordered by issue number ascending, replacing the scalar `prd`:

```python
prds = [{"number", "open", "reviewed", "eligible",
         "children", "children_all_closed", "unblocked"}]
```

### Attribution

A child is attributed to its parent PRD by a body trailer, parsed by a new `parse_parent(body,
self_repo)` built on the existing `_BLOCKED_BY_HEADING` / `_NEXT_HEADING` / `_ISSUE_REF`
machinery. It reads a `## Parent` section; the first ref wins.

**Back-compat:** when no `## Parent` section is present, `parse_parent` falls back to the bare
`Part of #N` trailer that `decompose.md` emits today. Children already filed by live fleets keep
their attribution across the upgrade with no migration.

Attribution is by body text rather than per-PRD labels, GitHub sub-issues, or milestones: it
costs no extra `gh` calls, needs no GraphQL, is already present in the snapshot payload the host
poller writes, and stays human-readable in the issue body. Body content is already
trust-restricted by `_author_filter`, which runs before any parsing.

### Buckets

Children partition by parent. Ready-labelled issues with **no** parent — typically
`/harness-issue` injections — form an **unparented bucket**.

The unparented bucket is dispatched first, preserving today's "an injected issue goes now"
behaviour. It does **not** gate any PRD's REVIEW. This fixes a latent bug: today an injected
issue is pooled into the flat `children` list, so it silently blocks `children_all_closed` and
stalls review of an unrelated PRD.

## Dispatch

`dispatch()` walks buckets in order — unparented first, then eligible PRDs by ascending number —
filling `free_slots` from each in turn and spilling into the next bucket only when the current
one has no unblocked children left.

Slots are allocated in strict PRD order rather than round-robin so that one PRD finishes and
reaches REVIEW promptly, instead of several sitting half-done with review delayed for all of
them. Spill means idle capacity is never wasted.

Orchestration is emitted per-PRD and independently: PRD #41 may be in REVIEW while PRD #42 is in
DECOMPOSE. Gates change from repo-global to PRD-scoped:

- `DECOMPOSE`: `not prd["children"]` (was `not s["children_exist"]`)
- `REVIEW` / `CLOSE_PRD`: that PRD's own `children_all_closed` and `open`

`PLAN` and `PRD` remain unit-level and keep their existing guards. The `PRD` action still fires
exactly once, when zero PRDs exist.

### Completion

```
is_complete  ⟺  at least one PRD exists
             ∧  every PRD is closed
             ∧  no open unparented ready children
```

The third clause is an in-scope bug fix. Today, an injected issue arriving after the PRD closes
is never worked: `drive_unit`'s loop has already exited on `unit_complete`, so the resident
worker idles past it. The unparented bucket makes this condition expressible for the first time.

`issue-only` mode's completion path is unchanged.

## Concurrency isolation

Three races surface the moment two PRDs run at once.

### Session-name collision

`sess_orch(){ echo "$HARNESS_SESS_PREFIX-$1"; }` (`lib.sh:414`) is unit-scoped, so DECOMPOSE #42
and REVIEW #41 would contend for one tmux name.

`sess_orch <unit> <prd>` → `$PREFIX-$unit-p<prd>`, using `-p0` for the unit-level PLAN/PRD
actions that carry no PRD number.

`team_sessions` (`lib.sh:424`) widens from `^$PREFIX-$1($|-i)` to `^$PREFIX-$1($|-i|-p)`. The
bare `$` alternative is retained so an orch session already in flight when the engine upgrades is
still counted and reaped rather than orphaned. `fleet_session_re` is already broad (`^prefix-.+$`,
deliberately so per #90) and needs no change.

### Shared-checkout clobber

`spawn_orch` writes `$CHECKOUT/.harness-task.md` and runs `git reset --hard origin/$base` in the
shared checkout. Two concurrent orch sessions would overwrite each other's prompt file and reset
each other's working tree mid-run.

`spawn_orch` splits by action:

- **`DECOMPOSE` / `REVIEW`** — per-PRD worktree at `$WORKTREES_DIR/$UNIT-p<prd>`, added
  `--detach` at `origin/$base`. Both sessions are read-only plus `gh` calls, so detached HEAD is
  safe. The `-p` namespace cannot be mis-parsed by `reap_team`'s `${wd##*-i}` glob.
- **`PLAN` / `PRD`** — stay in `$CHECKOUT` unchanged. They cannot race (both gated on zero PRDs
  existing plus unit-wide `allow_orch`), and `PLAN` needs a real branch to commit `PLAN.md`.

This leaves two spawn paths inside `spawn_orch`. The alternative — a worktree for every orch
action — is a larger diff and would require giving PLAN a branch it can commit and push from, for
no behavioural gain.

A `reap_orch` mirrors `reap_team` over the `-p*` glob; `finalize_unit`'s sweep gains the same.

### `allow_orch` narrowing

`drive.sh` currently sets `allow_orch=1` only when `count_team_sessions "$UNIT" == 0`. Left
as-is, PRD #2's DECOMPOSE could never fire while PRD #1 had a single impl session running — which
silently re-creates serial behaviour even for PRDs explicitly authored as parallel.

The guard splits:

- `PLAN` / `PRD` keep the unit-wide `active == 0` guard.
- `DECOMPOSE` / `REVIEW` gate per-PRD on *no live orch session for that PRD*.

`drive.sh` derives the busy set directly from `-p<n>` session names and passes it as a 4th
positional argument to `dispatch_actions`. No new state is introduced. REVIEW needs no additional
impl-session check: its `children_all_closed` gate already implies none are running.

The 4th argument is optional with an empty default, so the existing
`issuelib.py dispatch <repo> <free>` call shape (`test_poller.sh:105`) keeps working.

### Goal strings

`spawn_orch` sets `GOAL="$action"`, and `issuelib check` resolves goals `PRD` / `DECOMPOSE` /
`REVIEW` / `CLOSE_PRD` against the singular PRD. Goals become PRD-qualified (`DECOMPOSE:123`)
and `check` resolves each against the named PRD, so `reap_done_sessions` advances the right
session. Unqualified legacy goals continue to resolve against the lowest-numbered PRD.

## Prompt changes

**`decompose.md`** — step 2a's idempotency check lists every ready issue in the repo, so PRD #2's
decompose would see PRD #1's issues and skip genuine work as "already exists". Scope it to bodies
containing `Part of #{{PRD}}`. The issue-creation template gains an explicit `## Parent` section
alongside the existing human-readable `Part of #{{PRD}}` trailer.

**`prd.md`** — changes from "create ONE PRD tracking issue" to one PRD per independent workstream
in `PLAN.md`, each carrying its own `## Blocked by` section (`None`, or `#<earlier PRD>` to force
a sequence). This is what makes PLAN-generated PRD sets usable. The dispatch guard is unchanged.

**`review.md`** — no change; it already takes `#{{PRD}}` explicitly.

## Testing

`test_issuelib.py`:

- `parse_parent` grammar: `## Parent` section, `None` section, cross-repo `owner/repo#N`, and the
  bare `Part of #N` fallback
- bucket partitioning, including an unparented issue
- PRD eligibility across a 3-PRD `## Blocked by` chain and an independent parallel pair
- dispatch ordering, including spill when the first bucket runs dry
- per-PRD isolation of DECOMPOSE / REVIEW / CLOSE_PRD
- `is_complete` blocked by an open unparented child
- **back-compat regression guard**: a fixture repo with exactly one PRD and today's issue bodies
  produces dispatch output identical to the current engine. This is the test protecting the live
  fleets.

Shell tests, following existing patterns:

- `test_spawn.sh` — `sess_orch` naming; the `-p<prd>` detached worktree for DECOMPOSE/REVIEW;
  PLAN/PRD still spawning in `$CHECKOUT`
- `test_drive.sh` — `team_sessions` counting both old and new session forms; `reap_orch`;
  the busy-PRD set reaching `dispatch_actions`

## Rollout

All fleets share `~/.harness/engine` and pick this up on the next `harness update`, so
back-compat is mandatory rather than optional. Three properties make the upgrade a no-op for
existing state:

1. Children carrying only the legacy `Part of #N` trailer still attribute correctly via the
   `parse_parent` fallback.
2. A PRD with no `## Blocked by` section is eligible immediately, so a single-PRD repo behaves
   exactly as it does today.
3. The widened `team_sessions` regex still matches orch sessions launched by the old engine.

No migration step, no config change, no new knob.

## Out of scope

- Cross-repo PRD dependencies. `parse_blocked_by` supports `owner/repo#N` and it will resolve, but
  ordering across units remains the job of `targets.tsv` deps; this design does not extend
  unit-level scheduling.
- Cycle detection among PRDs. Matching the existing decompose scope guard, a pathological cycle
  is left to `agent-blocked` escalation — a cyclic set simply never becomes eligible.
- Per-PRD capacity limits. Strict-order-with-spill was chosen precisely to avoid a
  `HARNESS_PRD_CONCURRENCY` knob.

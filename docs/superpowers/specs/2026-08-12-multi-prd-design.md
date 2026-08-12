# Multi-PRD support in `prd` mode

**Date:** 2026-08-12
**Status:** Design approved, pending implementation plan

## Problem

The engine is hard-wired to exactly one PRD per unit. Drop a second PRD issue into a repo and it
is silently invisible — no error, no log line, no work. Four sites assume the singular:

| Site | Assumption |
|---|---|
| `issuelib.py:398` | `prd = next(...)` — takes the **first** match, discards the rest |
| `issuelib.py:403` | `children` = *every* ready-labelled issue in the repo, not scoped to a PRD |
| `issuelib.py:527` | `DECOMPOSE` fires only when `not children_exist` — repo-global |
| `issuelib.py:546` | `is_complete` keys on *that one* PRD closing |

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

`compute_state` gains a list ordered by issue number ascending:

```python
prds = [{"number", "open", "reviewed", "eligible",
         "children_exist", "children_all_closed", "unblocked"}]
```

plus `unparented_unblocked` and `open_unparented` for the unparented bucket.

**The legacy scalar keys are kept, derived from the lowest-numbered PRD**: `prd`, `prd_open`,
`prd_reviewed`, `children_exist`, `children_all_closed`, `unblocked`, `open_children`,
`total_children`, `paused`. Only `dispatch` and `is_complete` read the new `prds` list. This keeps
the `status` and `check` CLI output, every other `compute_state` consumer, and roughly a thousand
lines of existing `test_issuelib.py` working unchanged, and confines the behavioural change to two
functions instead of spreading it across the module.

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

- `DECOMPOSE`: `not prd["children_exist"]` (was `not s["children_exist"]`)
- `REVIEW` / `CLOSE_PRD`: that PRD's own `children_all_closed` and `open`

REVIEW's outer guard also changes from `not out` to `len(out) < slots`. `not out` was a proxy for
"there is capacity and nothing better to do"; with several PRDs it would let PRD #42's impl work
suppress PRD #41's review indefinitely, re-serializing the very thing this design parallelizes.
Capacity is the real constraint, so it becomes the explicit one.

For a single PRD this is equivalent — `children_all_closed` implies no open children, hence no
unblocked ones, hence no IMPL from that PRD — *unless* there are open unparented children. In
that one case behaviour deliberately changes: an injected issue no longer suppresses review of an
unrelated PRD. That is the latent bug named above, not a regression.

Action payloads stay in the existing `(action, payload, promise)` shape and the promise strings
are unchanged (`DECOMPOSE DONE`, `REVIEW DONE`, `PRD CLOSED`) — the PRD number already travels in
the payload field, which is what `drive.sh` consumes.

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

`sess_orch(){ echo "$HARNESS_SESS_PREFIX-$1"; }` (`lib.sh:504`) is unit-scoped, so DECOMPOSE #42
and REVIEW #41 would contend for one tmux name.

`sess_orch <unit> <prd>` → `$PREFIX-$unit-p<prd>`, using `-p0` for the unit-level PLAN/PRD
actions that carry no PRD number.

`team_sessions` (`lib.sh:514`) widens from `^$PREFIX-$1($|-i)` to `^$PREFIX-$1($|-i|-p)`. The
bare `$` alternative is retained so an orch session already in flight when the engine upgrades is
still counted and reaped rather than orphaned. `fleet_session_re` is already broad (`^prefix-.+$`,
deliberately so per #90) and needs no change.

Two existing callers assume the single orch name and must be updated with it:

- **`inject.sh:43`** refuses to inject while a REVIEW session is live, by reading the `.goal` of
  the one `sess_orch "$UNIT"` session. Left as-is it would check only the `-p0` name (PLAN/PRD),
  silently losing the guard — an injection could then land while a REVIEW is live and that REVIEW
  could close the PRD out from under it, which is precisely the race the check exists to prevent.
  It becomes a scan of every live `-p*` session for the unit, refusing if any `.goal` names REVIEW.
  (Its own `$CHECKOUT/.harness-task.md` write also stops racing DECOMPOSE/REVIEW once those move
  to worktrees — an incidental improvement.)
- **`attach.sh:17`** attaches to `sess_orch "$UNIT"`. It gains selection among the unit's live
  `-p*` sessions, attaching directly when exactly one is live and listing them otherwise.

### Shared-checkout clobber

`spawn_orch` writes `$CHECKOUT/.harness-task.md` and runs `git reset --hard origin/$base` in the
shared checkout. Two concurrent orch sessions would overwrite each other's prompt file and reset
each other's working tree mid-run.

This failure mode is already documented and already fixed once elsewhere: `drive.sh:221` records
that bug-**triage** used to run in the shared `$CHECKOUT`, where "a concurrent `spawn_orch`
`render > $CHECKOUT/.harness-task.md` (brief clobber) + `git reset --hard origin/<base>`
(working-tree yank) corrupted the in-flight triage", and #5/#109 fixed it by giving triage its own
worktree. Multi-PRD makes `spawn_orch` race *itself*, so it takes the same remedy, following that
established pattern rather than inventing a new one.

`spawn_orch` splits by action:

- **`DECOMPOSE` / `REVIEW`** — per-PRD worktree from a new `orch_worktree <slug> <prd>` helper
  (`$WORKTREES_DIR/orch-<slug-with-/-as-_>-p<prd>`), on a throwaway branch `agent/orch-<prd>`,
  exactly mirroring `triage_worktree` (`lib.sh:402`) and its `agent/bug-triage-<n>` branch. The
  spawn sequence copies the triage path verbatim: `remove_worktree` defensive pre-add reap →
  `git worktree add -B` with an `origin/$base` fallback → `ensure_safe` → `run_worktree_hook`.
  Both sessions are read-only plus `gh` calls, so the branch is throwaway and never pushed.
- **`PLAN` / `PRD`** — stay in `$CHECKOUT` unchanged. They cannot race (both gated on zero PRDs
  existing plus unit-wide `allow_orch`), and `PLAN` needs a real branch to commit `PLAN.md`.

The `orch-` path prefix, like `triage-`, sits at the `$WORKTREES_DIR` root rather than under
`$UNIT-`, so it can never be caught by `reap_team` / `finalize_unit`'s `"$WORKTREES_DIR/$UNIT"-i*`
glob or mis-parsed by their `${wd##*-i}` extraction.

A `reap_orch` mirrors `reap_team` over the `orch-<slug>-p*` glob; `finalize_unit`'s sweep gains
the same. Crash recovery gets an `sweep_orphan_orch_worktrees`, the direct analogue of
`sweep_orphan_bug_worktrees` (`lib.sh:421`), for orch worktrees left by a killed engine.

### `allow_orch` narrowing

`drive.sh` currently sets `allow_orch=1` only when `count_team_sessions "$UNIT" == 0`. Left
as-is, PRD #2's DECOMPOSE could never fire while PRD #1 had a single impl session running — which
silently re-creates serial behaviour even for PRDs explicitly authored as parallel.

The guard splits:

- `PLAN` / `PRD` keep the unit-wide `active == 0` guard.
- `DECOMPOSE` / `REVIEW` gate per-PRD on *no live orch session for that PRD*.

`drive.sh` derives the busy set directly from `-p<n>` session names and passes it to
`dispatch_actions`. No new state is introduced. REVIEW needs no additional impl-session check: its
`children_all_closed` gate already implies none are running.

`dispatch_actions` (`lib.sh:473`) is currently
`python3 "$ISSUELIB" dispatch "$1" "$2" --allow-orchestration "$3"`, so the busy set is passed as
a matching **named flag**, `--busy-prds "41,42"`, parsed the same way `--allow-orchestration`
already is (`issuelib.py:580`). Flag-shaped rather than positional means the existing
`issuelib.py dispatch <repo> <free>` call shape (`test_poller.sh:105`) keeps working untouched,
and an absent flag defaults to the empty set.

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
- **back-compat regression guard**: a fixture repo with exactly one PRD, today's issue bodies, and
  no unparented children produces dispatch output — action, payload and promise — identical to the
  current engine across the PLAN → PRD → DECOMPOSE → IMPL → REVIEW → CLOSE_PRD sequence. This is
  the test protecting the live fleets. The no-unparented-children qualifier is load-bearing: with
  one present, the REVIEW capacity gate is *intended* to differ.

Shell tests, following existing patterns:

- `test_spawn.sh` — `sess_orch` naming; the `orch_worktree` path and `agent/orch-<prd>` branch for
  DECOMPOSE/REVIEW; PLAN/PRD still spawning in `$CHECKOUT`
- `test_drive.sh` — `team_sessions` counting both old and new session forms; `reap_orch`;
  the busy-PRD set reaching `dispatch_actions`
- `test_recover.sh` — `sweep_orphan_orch_worktrees` reaping an orch worktree whose session is dead,
  and leaving a live one alone

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

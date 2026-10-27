# Reference

## The engine's multi-PRD model (verified in `issuelib.py`)

- `_prd_list` returns **every** PRD (the `prd` label OR an `[AFK] PRD:` title prefix), ascending.
- Children are attributed **per PRD** by `parse_parent` reading `## Parent`. So `children_exist` /
  `children_all_closed` are per-PRD, not a repo-wide scan.
- `eligible` = that PRD's own `## Blocked by` is satisfied. **This is how you sequence PRDs.**
  No section = eligible immediately, which is what makes independent PRDs run in parallel.
- `DECOMPOSE` / `REVIEW` / `CLOSE_PRD` gate **per PRD** via `--busy-prds`, not unit-wide. `dispatch`
  returns one DECOMPOSE per call; the next tick dispatches the next PRD once the first is busy.
- `is_complete` = **every** PRD closed AND no open unparented child. A PRD sequenced behind another
  keeps the unit incomplete, so **the pool cannot retire mid-queue**. This is the whole automation
  guarantee.
- The engine closes a PRD only once every one of its `ready-for-agent` children is CLOSED — so a
  follow-up filed alongside a sign-off correctly holds the PRD open instead of being stranded.
- `_is_unblocked` **exempts a child's reference to its own PRD**, which absorbs the very common
  `Part of #<prd>` trailer leaking into the `## Blocked by` section. Load-bearing: DECOMPOSE
  formatting drifts between sessions and this leak appears often. Any *other* stray number is a
  real, unsatisfiable blocker.

## PRD body template

```md
<one-paragraph statement of what this PRD makes true>

**Spec:** `<path>` §<sections>
**Plan:** `<path>` — already written, follow it.   ← omit if using plan-doc-first

## Task 1 — write the plan document        ← only when no plan exists yet
**First child issue; nothing else starts before it merges.** Write `<path>` at the fidelity of
`<an existing hand-written plan>` — read that file and match its shape exactly: Goal / Architecture
/ Tech Stack / Spec header, a `## Global Constraints` block, numbered `### Task N` sections each
with **Files**, **Interfaces**, and checkboxed steps where step 1 is complete, literal, failing
test source and step 2 names the command and the failure expected. Close with
`## What this plan deliberately leaves undone`. State which task covers which spec section.

## Acceptance criteria
1. <literal quantities from the design — names, counts, constants, hashes>
...
N. <the repo's real gate> exits 0.

## Non-goals
<what belongs to a sibling PRD, named with its number, so nobody does it twice>

## Quality bar          ← ONLY if a real rival exists; omit to switch the gauntlet off
Beat: <named artifact + URL>
Judged on:
- <dimension decidable by running something>

## Blocked by
#<predecessor>   or   None
```

Child issues (yours and the fleet's) must end with **all three**:
```
## Blocked by
<#N or the literal word None>

## Parent
#<prd>

Part of #<prd>
```
`None` must be the literal word. Prose ("Nothing", "N/A") fails the none-pattern, and a stray `#N`
in that prose becomes a phantom blocker. Missing `## Parent` scores the issue against the
lowest-numbered PRD in the repo. Either mistake deadlocks the fleet silently.

## Supervisor rules, and the failure each was written for

These were the arc watchdog's (`watch.py`); `harness supervise` now runs them on every fleet, in
`scripts/supervise.sh` (rules 1-3, 6) and `scripts/supervise_rules.py`.

| rule | action | catches |
|---|---|---|
| **wedged session** | checkpoint + kill | `STOP_HOOK_BLOCK_CAP` in a live pane — the ralph loop's re-prompt hook gives up, the turn ends, the issue stays locked forever. Alive, so stale-lock never sees it. |
| **zombie session** | kill (checkpoint first if it holds unpushed work) | a live session whose issue is already closed — still holds a worktree, can still push. |
| **unlocked work** | re-add `agent-working` | a live session on an issue with no `agent-working` — a second worker can claim it. |
| **stale lock** | remove `agent-working` | `agent-working` with no live session, older than `LOCK_GRACE`. |
| **dead worker** | `harness start` | a pool/priority pid file whose process is gone. |
| **deep context** | alarm | a pane past 250% — deep-context agents degrade; expect a wedge or a dropped cleanup step. Early warning for the above. |
| **unfiled plan tasks** | alarm | a merged plan naming tasks with no issue. Match a *family* of phrasings, not one sentence — authors word it differently and a narrow grep misses it. Plans already topped up go in `.harness/reconciled-plans`, since the phrase survives in the merged doc. |
| **decompose stalled** | alarm | an eligible, open PRD with no children and no session. Invisible to every other rule, because a childless PRD contributes no claimable work. |
| **review loop** | alarm | a PRD reaching the criteria gate 4+ times. The gauntlet has a round cap; **the criteria gate has none**. Ask: still finding *new* defects (working) or re-litigating (needs narrowing / a human)? |
| **no frontier** | alarm | open children, zero unblocked, no session — a mis-pointed `## Blocked by`. |
| **missing `## Parent`** | alarm | the silent-deadlock shape, on every `ready-for-agent` issue (not in `issue-only` mode, where unparented is normal; `UNPARENTED_OK=8,9` in `supervise.conf` exempts issues). |
| **wayfinder leak** | alarm | a `wayfinder:*` ticket that picked up `ready-for-agent`. |

Every rule has a strike threshold of 2+ passes (3 for zombie, unlocked, decompose stalled) —
claim/release races are constant and a single-pass alarm is noise. The strikes and the per-PRD
criteria-gate round counters persist in `~/.harness/supervise/rules/<prefix>.json`, so restarting
the supervisor neither resets the review-loop count nor re-fires an alarm already raised.

## Hazards worth knowing before you start

- **Count worker *slots*, not processes.** `pgrep -fc pool-worker.sh` counts children; one slot can
  show three. Read the configured pool size instead.
- **A green gate may be a coin flip.** Allocation/timing assertions that pass alone can fail when a
  whole solution runs. Before trusting "CI green" as evidence, check the gate is deterministic —
  verify merges by *content* where it matters.
- **Verify a quantity, not a checkbox.** Grep the design's literal numbers; a task can satisfy every
  clause of a criterion with the wrong value.
- **Absence and already-done look identical in a final diff.** If a criterion says "regenerate X",
  check X's git history rather than the closing commit's diff.
- **Read a whole section before concluding.** A `## Blocked by` with two entries looks like one if
  you capture only the first line.

## Dashboard (`http://<host>:4637/fleet/<prefix>`)

Served by `harness web`; the DAG is `scripts/web_dag.py`, its inputs `scripts/web_data.py`. It
reads only local state — the poller's board snapshots, never `gh` per page view.

| Reads | From |
|---|---|
| PRDs, state | the `prd` label in the unit's board snapshot |
| Dependency edges | the **last** `## Blocked by` header per body — never the first |
| Child counts | `## Parent` on every non-PRD, non-wayfinder issue |
| Decisions | `wayfinder:*` labels; the map is `wayfinder:map` — the "Awaiting you" panel |
| In-flight | `agent-working` label + live tmux sessions matched on the fleet prefix |

State is derived, not stored: `done` = closed; `waiting` = any dep still open; `running` = has
children or an `agent-working` label; `ready` = eligible with nothing started. A node that stays
`ready` across two cache refreshes is the **decompose stalled** signal from the supervisor table,
visible here as a box that never turns amber.

Layering is longest-path with a cycle guard, so a mis-wired self-referential `## Blocked by`
renders instead of hanging. `test/test_web_dag.py` pins all of it to a frozen golden,
`test/fixtures/web/arc-golden.json`.

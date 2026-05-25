# Spec: Shared host poller + per-project snapshot reads

Status: implemented (brainstormed 2026-05-25; landed via #69, slices #70–#74)
Scope: **PRD-B** of the two-PRD arc. Builds on PRD-A (shared-install model, #52), which
established the `~/.harness/` host root with reserved `poller/` + `snapshots/` dirs. PRD-A is
DONE and deployed. See `docs/superpowers/specs/2026-05-24-shared-install-model-design.md`.

## Problem

Three fleets share one host and **one 5k/hr GitHub token**. Today every poll cycle hits GitHub
independently and redundantly:
- Each of `HARNESS_POOL` pool workers calls `issuelib dispatch` (→ `compute_state`: a full
  `gh issue list` + two `gh api contents` + per-dep `gh issue view`) every `HARNESS_POLL`.
- The priority bug lane calls `issuelib bugs` + `working-bugs` (two more full lists) every
  `HARNESS_PRIORITY_POLL` (60s), plus per-bug `gh issue view`.

So GitHub reads scale with **workers × repos × fleets**. Under load a worker gets rate-limited
and can't verify/dispatch, so the fleet appears "stuck" until the token resets (see memory
`shared-github-token-ratelimit`). The reads are also almost entirely **redundant**: the
expensive, cacheable datum is the per-repo issue list, and every consumer recomputes from it.

## Goals

- **G1 — One poll per repo.** A single host-level poller refreshes each registered repo once per
  cycle; all workers/lanes in all fleets read the result. GitHub read volume becomes a flat
  function of *repos*, independent of worker count and fleet count.
- **G2 — Per-project identity preserved.** Each project keeps its own session namespace
  (`HARNESS_SESS_PREFIX`), mode, topology, label set, and author allowlist. The poller
  centralizes *polling/snapshotting only*; *dispatch + sessions* stay per-project.
- **G3 — Self-healing, no new daemon to manage.** No operator-facing lifecycle command for the
  poller: `harness start` ensures it is alive and every worker tick re-checks and relaunches it.
- **G4 — Safe staged rollout.** Behavior-preserving by default; cut the 3 live fleets over one at
  a time behind a flag, with trivial rollback.
- **G5 — Harden the multi-fleet host.** Prevent session-prefix collisions across fleets using the
  new host registry (the documented `hz`/`hzli` cross-kill does not reproduce — see Risks).

## Non-goals

- **Changing dispatch/claim/drive logic.** Decisions stay in `issuelib`; the poller only replaces
  the GitHub round-trip behind `_list_issues` + `_has_plan`/`_plan_marker`.
- **A direct-`gh` fallback when a snapshot is stale.** A stale snapshot *holds* dispatch and
  restarts the poller; workers never fall back to polling GitHub themselves (that would
  reintroduce the stampede this PRD removes). Locked decision.
- **Merging projects into one queue.** Pools and sessions stay separated per project (G2).
- **Caching GitHub *writes*** (claims-as-labels, PR ops). Only the *read* polling is consolidated.

## Architecture

The poller replaces exactly one thing: the GitHub read behind the issue list + plan files. It
writes a **raw** snapshot per repo; each project's workers compute dispatch **locally** from that
raw snapshot using their own env, so no project-specific interpretation is baked in centrally.

```
~/.harness/                              ← host root (from PRD-A)
├── engine/                              shared install
├── poller/
│   ├── registry/<owner__repo>__<project>.json one per (repo, registrant): {slug, cadence, prefix, project}
│   └── poller.pid                              the poller: a nohup background process — NOT a tmux session
└── snapshots/<owner__repo>.json         {schema_version, generated_at, slug, issues[], has_plan, plan_marker, self_login}

<project>/.harness/config                adds: HARNESS_USE_POLLER (flag, default off)
```

### The snapshot (raw, versioned)
`issuelib snapshot <repo>` performs the 3 GitHub reads and emits JSON:
- `schema_version` — integer; workers reject an unknown/newer schema (hold, like staleness).
- `generated_at` — epoch seconds, for staleness.
- `slug` — owner-qualified repo.
- `issues[]` — the raw `_list_issues(slug)` payload (`number,title,state,labels,body,author`),
  exactly what `gh issue list --state all --limit 200 --json …` returns. **No** author filtering,
  **no** label interpretation — that stays per-project.
- `has_plan` — bool (PLAN.md present at repo root).
- `plan_marker` — the decoded plan-completion marker dict, or null.
- `self_login` — the bot's `gh api user` login (shared across fleets on one token), so workers
  skip that call too.

### The read seam
`issuelib` gains a snapshot-read mode keyed by `HARNESS_SNAPSHOT_FILE`:
- `_list_issues(slug)` → loads `issues[]` from the snapshot instead of calling `gh`.
- `_has_plan`/`_plan_marker` → read `has_plan`/`plan_marker` from the snapshot.
- `_is_unblocked` dep-state → resolved from the snapshot's own `issues[]`; a **cross-repo** dep
  resolves from that repo's **sibling** snapshot (the poller snapshots every registered repo). A
  dep whose repo is not snapshotted is treated conservatively as **not closed** (blocked) and
  logged — never a `gh` call.

Everything downstream (`_author_filter` with the project's allowlist, the configurable label
names, `MODE`/`AUTONOMOUS`, the `HARNESS_SPEC` hash for `plan_marker_matches`) stays on the worker
side, unchanged. With `HARNESS_SNAPSHOT_FILE` unset, `issuelib` behaves exactly as today.

### Supervision (workers self-heal the poller)
- `ensure_poller` (lib.sh): if `poller.pid` is dead/absent, `nohup` the poller loop and write the
  pid. Idempotent and lock-guarded so two concurrent ticks don't double-spawn.
- `harness start` calls `ensure_poller` after registering. Every `worker_tick`/`bug_tick` calls it
  again before reading a snapshot, so a crashed poller self-heals within one tick.
- The poller is a background process, **not** a tmux session, so `harness stop` (which kills
  `^<prefix>-` tmux sessions) never touches it — correct, since other fleets may still need it.

### Registry (drop-a-file, refcounted)
- `harness start` writes `~/.harness/poller/registry/<owner__repo>__<project>.json` for each repo
  the project serves (single: `HARNESS_REPO`; multi: every row in `targets.tsv`), recording
  `slug`, `cadence` (the project's `HARNESS_PRIORITY_POLL`), `prefix` (`HARNESS_SESS_PREFIX`), and
  `project` (the STATE_DIR path, the refcount key).
- The poller scans the registry, dedupes by slug, and refreshes each unique slug at the **fastest**
  registrant cadence for it (default 60s).
- `harness stop` removes this project's registry files. A slug stays polled while any project
  references it (refcount). When the registry empties, the poller has nothing to do (it exits, or
  idles until the next `ensure_poller`).

### Staleness / hold
- A worker checks `now - generated_at <= 3 × refresh-interval` (one missed cycle tolerated; a dead
  poller trips it). An unknown/newer `schema_version` is treated the same as stale.
- Stale/missing/unreadable snapshot → **hold dispatch**: claim no *new* work, leave in-flight
  sessions running, call `ensure_poller`, and log a `_IDLE_LOGGED`-deduped "snapshot stale —
  holding, restarting poller" banner. Fresh again → normal dispatch resumes.

## Components

| Piece | Today | After |
|---|---|---|
| `issuelib snapshot <repo>` | — | emits the raw versioned snapshot JSON (3 gh reads) |
| `issuelib` read path | always `gh` | reads `HARNESS_SNAPSHOT_FILE` when set; else `gh` (unchanged) |
| poller loop (engine-level) | — | scans registry, writes atomic per-repo snapshots at min cadence |
| `harness poll [--once|--status]` | — | debug/test entry to the poller (normal path is `ensure_poller`) |
| `ensure_poller` / registry helpers (lib.sh) | — | launch-if-dead; refcounted register/deregister |
| `worker_tick`/`bug_tick` | call `issuelib` (gh) | gate on snapshot freshness; hold + relaunch on stale |
| `harness start`/`stop` | launch/kill pool | also register/`ensure_poller` / deregister (flag-gated) |
| `stop.sh`/`status.sh` match | `^<prefix>-` | full session grammar (defense-in-depth, slice 4) |
| `HARNESS_USE_POLLER` | — | per-project flag; default off = today's direct polling |

## Slices (tracer-bullet ordered, flag-gated)

1. **Snapshot read seam — behavior-preserving (flag OFF).** Add `issuelib snapshot <repo>` (emits
   raw JSON) and teach `_list_issues`/`_has_plan`/`_plan_marker`/dep-state to read
   `HARNESS_SNAPSHOT_FILE` when set. With the flag off and no snapshot file, `issuelib` output is
   byte-for-byte today's. Regression gate: full suite green. New test: generate a snapshot from a
   fixture, then assert `dispatch`/`complete`/`bugs`/`working-bugs` against the snapshot equal the
   direct-`gh` results.
2. **Poller process + registry.** Refcounted register/deregister helpers + the poller loop writing
   **atomic** (`tmp` + `rename`), **versioned** snapshots for N registered repos at min cadence;
   pidfile; `harness poll [--once|--status]`. Tests: register/deregister refcount; one poller
   serves multiple repos; snapshot is atomic + carries `schema_version`/`generated_at`.
3. **Wire workers behind `HARNESS_USE_POLLER`.** When set: `harness start` registers the project's
   repos + `ensure_poller`; `worker_tick`/`bug_tick` gate on `ensure_snapshot_fresh <repo>` (stale
   → hold + `ensure_poller`, deduped banner) and run `issuelib` with `HARNESS_SNAPSHOT_FILE`;
   `harness stop` deregisters. Flag off = today's path. Tests: stale snapshot holds dispatch; fresh
   snapshot serves dispatch identical to direct; dead poller pid → next tick relaunches; stop
   deregisters (refcount drops, slug stays while another project references it).
4. **Prefix-collision guard + full-grammar stop/status.** Record each fleet's prefix in its
   registry entry; `harness start` refuses (or warns, configurable) when another *active* fleet's
   prefix collides — equal, or one is a dash-prefix of another's session space. Tighten
   `stop.sh`/`status.sh` to match the full session grammar rather than the bare `^<prefix>-`.
   Tests: colliding prefix detected; `hz`/`hzli`/`boto` all coexist cleanly; stop kills only its
   own grammar.
5. **Staged cutover + docs.** Flip the 3 fleets one at a time (see Migration). Update README;
   flip the shared-install spec's "reserved for PRD-B" note to "implemented".

## Acceptance criteria

- With `HARNESS_USE_POLLER` unset, behavior and `test/` results are identical to today (slice 1
  regression gate).
- With one poller running and `HARNESS_USE_POLLER=1`, a fleet completes a full PLAN→PRD→DECOMPOSE
  →IMPL→REVIEW (or issue-only) cycle with **its workers making zero GitHub dispatch reads** — all
  served from `~/.harness/snapshots/`.
- One poller serves N≥2 repos; snapshots are written atomically and carry `schema_version` +
  `generated_at`; cross-repo `Blocked by` resolves from sibling snapshots.
- Killing the poller pid causes the next worker/bug-lane tick to relaunch it; a stale snapshot
  holds new dispatch (no new claims) while leaving in-flight sessions running, with no `gh` read.
- `harness stop` removes only the stopping project's registry entries and never kills the poller;
  a slug shared by two fleets stays polled until both deregister.
- Two fleets with colliding `HARNESS_SESS_PREFIX` are detected at `start`; `hz`/`hzli`/`boto`
  coexist; `harness stop` kills only sessions matching its own fleet's full grammar.
- The full `test/` suite passes, including the new snapshot/poller/registry/prefix-guard tests.

## Testing

Extend `test/run.sh` with the sourced-function override-seam pattern already used across `test/`:
- `test_snapshot.sh` — round-trip: `issuelib snapshot` from a stubbed `gh` fixture → snapshot
  JSON; reading it back yields identical `dispatch`/`complete`/`bugs`/`working-bugs`; schema/
  staleness handling; cross-repo dep resolution from sibling snapshots; unresolvable dep → blocked.
- `test_poller.sh` — registry refcount add/remove; poller writes atomic versioned snapshots for
  multiple repos; min-cadence selection; empty registry → poller idles/exits.
- `test_worker.sh`/`test_priority.sh` additions — freshness gate holds dispatch on stale; fresh
  serves; `ensure_poller` relaunches a dead pid; in-flight sessions untouched while holding.
- `test_prefix_guard.sh` — collision detection; distinct prefixes coexist; full-grammar
  stop/status match.
Reuse the temp-repo harness and the `gh`/`tmux` stub seams (e.g. the `HARNESS_CLAUDE_CONFIG`-style
overridable seams added in #68); add a `HARNESS_SNAPSHOT_FILE`/`HARNESS_POLLER_DIR` seam so tests
point at a temp host root.

## Migration (live fleets, staged)

The new engine ships with snapshot-reads **off** (`HARNESS_USE_POLLER` unset = today's direct
polling — slice 1 is behavior-preserving). Cut over one fleet at a time:
1. `harness update` — deploy the new shared engine to `~/.harness/engine` (all projects pick it up;
   none change behavior yet).
2. For one fleet: set `HARNESS_USE_POLLER=1` in its `.harness/config`, then
   `harness stop && harness start --recover`. On start it registers its repos and `ensure_poller`
   brings the poller up; the bug lane + pool become snapshot-served.
3. Validate: that fleet's worker logs show snapshot reads (no `gh issue list` for dispatch); the
   poller is writing `~/.harness/snapshots/<slug>.json`; dispatch still completes work.
4. Repeat for the next fleet. Rollback at any point: unset the flag + restart that fleet.
Snapshots are ephemeral (regenerated), so there is **no migration state** to carry — unlike PRD-A,
no `migrate`-style command is needed; staging is purely the flag + restart.

## Deployment / sequencing

Sequence after PRD-A is live (it is). Self-host workflow: write + commit this spec, then inject
PRD-B + tracer-bullet child issues onto `VocanicZ/Harness` and let the fleet implement
(TDD → PR → merge → close). Deploy via `harness update`; merge PRs with `gh pr merge --squash`
directly when CLEAN (repo forbids `--auto`; see memory `repo-automerge-disabled`).

## Open risks

- **Stale-snapshot wedge.** A persistently failing poller would hold all dispatch indefinitely.
  Mitigation: `ensure_poller` relaunches every tick; the hold is *safe* (no bad dispatch, in-flight
  work continues); the deduped banner surfaces it in logs and `harness status`.
- **Cross-repo dep visibility.** A `Blocked by` whose repo isn't registered resolves conservatively
  as blocked (won't dispatch). Acceptable: it errs toward *not* dispatching; logged. Register the
  dep's repo to resolve it.
- **Prefix hazard is by convention, not (currently) a live cross-kill.** Tested:
  `^hz-` does **not** match `hzli-orch` (the trailing dash anchors it), so the documented
  "stopping Bonsai kills Harness sessions" does not reproduce — the `hzli` rename already fixed it
  (memories `harness-stop-prefix-kill-hazard`, `host-runs-multiple-fleets`). The residual risk is
  an operator picking a genuinely colliding prefix; slice 4 *prevents* that via the registry rather
  than re-anchoring an already-anchored regex.
- **Registry leak on crash.** A fleet that dies without `harness stop` leaves stale registry
  entries (poller keeps polling a dead fleet's repo). Mitigation: `harness start --recover` and/or
  the poller pruning entries whose `project` STATE_DIR has no live pool — cheap, low-stakes (an
  extra repo polled wastes a few calls, well within budget).
```

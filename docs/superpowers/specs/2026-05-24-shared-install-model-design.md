# Spec: Shared-install model — install Harness once, run per project

Status: implemented (brainstormed 2026-05-24; landed via #52)
Scope: **PRD-A** of a two-PRD arc. PRD-B (host-level snapshot poller) builds on this and is
specced separately; it is **out of scope here** beyond establishing the `~/.harness/` host root.
PRD-B is now **implemented** — the `poller/` + `snapshots/` subdirs this spec reserves are live;
see `docs/superpowers/specs/2026-05-25-shared-host-poller-design.md`.

## Problem

Today `install.sh:68` **clones the entire engine into every project's `.harness/`** — a
gitignored "runtime clone". Consequences we hit repeatedly:
- **Redeploy friction:** every engine change must be re-pulled into each project's clone before
  it takes effect (`harness update` per project).
- **Version skew:** different projects run different engine commits; a shared host-level
  component (e.g. the planned poller) can't assume one format.
- **Bootstrap confusion:** the fleet edits engine *source* but runs an *older clone*, so changes
  don't go live until a manual resync.

The root cause: a single `HARNESS_DIR` (`bin/harness:3`) conflates two distinct things —
**engine code/assets** and **per-project runtime state** — and `lib.sh` hangs both off it.

## Goals

- **G1 — Install once.** `harness install` places the engine at a single host location
  (`~/.harness/engine/`) and puts `harness` on `PATH`. No per-project engine copy.
- **G2 — Per-project state only.** A project's `.harness/` holds config + runtime state
  (`run/`, `claims/`, `worktrees/`, `targets.tsv`, `PLAN.md`) — never engine code.
- **G3 — One-place updates.** `harness update` ff-pulls only the shared install; every project
  picks it up immediately. No version skew.
- **G4 — Clean migration.** The 3 live fleets (Harness `hzli`, Bonsai `hz`, BOTOnline `boto`)
  move to the shared model without losing config or in-flight state.
- **G5 — Establish the host root.** `~/.harness/` exists as the home for shared host-level
  components (poller, snapshots, registry land in PRD-B).

## Non-goals

- The **host-level poller / snapshots** themselves — PRD-B. Here we only create the `~/.harness/`
  root and reserved subdirs.
- Any change to dispatch/claim/drive **logic** — this is a structural/deployment refactor only.
- Supporting **multiple engine versions** concurrently on one host — single shared version is the
  point (a feature, not a limitation).

## Architecture — split `HARNESS_DIR` into `ENGINE_DIR` + `STATE_DIR`

```
~/.harness/                       ← `harness install` ONCE; `harness update` updates here only
├── engine/                       (all code/assets: *.sh, issuelib.py, prompts/, bin/harness)
├── poller/   (implemented in PRD-B: registry/ + poller.pid)
└── snapshots/ (implemented in PRD-B: <owner__repo>.json)
   PATH: harness → ~/.harness/engine/bin/harness   (symlink; resolved via realpath)

<project>/.harness/               ← `harness init`; config + state only, NO code
├── config · run/ · claims/ · worktrees/ · targets.tsv · PLAN.md
```

- **`ENGINE_DIR`** — the shared install, resolved from the entrypoint's own location via
  `realpath` (so a `PATH` symlink resolves to the real engine). Source of all code assets:
  `issuelib.py`, `prompts/`, sub-scripts.
- **`STATE_DIR`** — the project's `.harness/`, discovered by walking **up from `cwd`** for a
  `.harness/config` (like `git` finds `.git`). Source/sink of all runtime state + config. Clear
  error when not inside a Harness project.

`bin/harness` exports both and execs the subcommand script from `ENGINE_DIR`. `lib.sh` is the
single chokepoint: asset paths (`PROMPTS_DIR`, the `issuelib.py` path) resolve under `ENGINE_DIR`;
state paths (`RUN_DIR`, `CLAIMS_DIR`, `WORKTREES_DIR`, `POOL_LOCK`, config, `TARGETS_TSV`,
`PROJECT_ROOT`) resolve under `STATE_DIR`.

## Components

| Command | Today | After |
|---|---|---|
| `harness install` | clones engine into each `./.harness/` | installs engine **once** to `~/.harness/engine/`, puts `harness` on `PATH`, installs Claude skills to user scope (`~/.claude/skills`) |
| `harness init` | writes config inside the clone | creates `./.harness/{config,run,claims,worktrees}` — state only, no code |
| `harness update` | per-project `git -C .harness pull` | ff-pulls `~/.harness/engine` once |
| `harness migrate` | — | converts a vendored `.harness/` to state-only pointing at the shared engine |
| path model | single `HARNESS_DIR` = clone | `ENGINE_DIR` (assets) + `STATE_DIR` (state) |

## Slices (tracer-bullet ordered)

1. **Path split (behavior-preserving).** Introduce `ENGINE_DIR`/`STATE_DIR` in `bin/harness` and
   `lib.sh`; assets read from `ENGINE_DIR`, state from `STATE_DIR`. **Both default to the current
   `.harness/`** when not separated, so vendored installs and the running fleets keep working and
   the full `test/` suite stays green. No deployment change yet.
2. **`harness install` once + PATH entrypoint.** Engine installed to `~/.harness/engine`;
   `harness` symlinked onto `PATH` with `realpath` resolution; `update` ff-pulls only the shared
   install.
3. **`harness init` state-only + cwd discovery.** `init` creates the project state dir without
   cloning; `STATE_DIR` discovered by walking up from `cwd`; helpful error when not in a project.
4. **`harness migrate` + cut over the 3 live fleets.** With each fleet drained/stopped: strip the
   vendored engine code from its `.harness/`, keep `config` + state, re-point at the shared engine,
   and verify `harness start` works. Migration carries #23's merged engine changes for free.
5. **Skills → user scope + host root + docs.** Consolidate skill install to `~/.claude/skills`;
   create the `~/.harness/` root with reserved `poller/` + `snapshots/` (for PRD-B); update README.

## Acceptance criteria

- After `harness install`, `which harness` resolves (via symlink → realpath) to
  `~/.harness/engine/bin/harness`; no engine code exists under any project's `.harness/`.
- `harness init` in a fresh repo creates `./.harness/config` + state dirs and no code; running any
  `harness` subcommand from a subdirectory resolves the project via upward `.harness/config`
  discovery, and errors clearly outside a project.
- `harness update` changes only `~/.harness/engine`; a second project immediately sees the new
  engine with no per-project action.
- All three live fleets run `harness start`/`status`/`stop` against the shared engine after
  migration, with their prior config and in-flight worktrees/claims intact.
- Slice 1 alone leaves the existing vendored layout fully working (regression gate).
- The full `test/` suite passes, including new tests for `ENGINE_DIR`/`STATE_DIR` resolution,
  cwd-based `STATE_DIR` discovery, and `install`/`migrate`.

## Testing

Extend `test/run.sh`. New/updated: `test_install.sh` (single-location install, PATH symlink,
realpath), `test_setup.sh`/`test_init.sh` (state-only init, upward discovery, not-in-project
error), a path-resolution test (assets→ENGINE_DIR, state→STATE_DIR, backward-compat default),
`test_update.sh` (touches only the shared install), and a new `test_migrate.sh` (vendored →
state-only preserving config + claims + worktrees). Reuse the existing temp-repo harness.

## Migration (live fleets)

Per fleet, while drained (`harness pause`) or stopped: `harness install` (once, host-wide) →
`harness migrate` in each project (preserve `config`, `run/`, `claims/`, `worktrees/`; remove the
vendored engine clone/`.git`) → `harness start --recover`. Order the three so at most one is down
at a time. Because the shared engine = latest source, this also deploys all merged #23 work
(resident pool + bug lane) in the same step.

## Deployment / sequencing

Sequence **after PRD #23 fully lands** (don't disturb in-flight #27/#28). PRD-A repackages the
then-current engine source; PRD-B (poller) follows and uses the `~/.harness/` root this PRD
establishes. This is the change that *ends* the engine-source-vs-runtime-clone friction for good.

## Open risks

- **Path model is pervasive.** `ENGINE_DIR`/`STATE_DIR` touches every script's assumptions.
  Mitigation: slice 1 is behavior-preserving with both defaulting to `.harness/`, gated by the
  full test suite before any deployment change.
- **Migration of running fleets.** A botched cutover could orphan in-flight work. Mitigation:
  drain/stop first, migrate one at a time, `--recover` after, keep state dirs untouched.
- **PATH/entrypoint portability.** Symlink + `realpath` must work on the target shell/OS;
  `install` should fall back to printing explicit `PATH` instructions if it can't write the symlink.

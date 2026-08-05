<p align="center">
  <img src="docs/logo.svg" alt="Harness logo" width="128" height="128">
</p>

<h1 align="center">Harness</h1>

<p align="center"><em>One orchestrator, a pool of autonomous agents, all state in GitHub.</em></p>

A project-agnostic agent orchestrator that drives a fixed pool of autonomous Claude Code sessions against a GitHub-issues board. A fixed pool of workers claims dependency-ready units, drives each through a GitHub-issue state machine to COMPLETE. All state lives 100% in GitHub (issues, labels, pushed commits) plus a small local run directory — no database, no daemon. Stateless and resumable from any host.

## Install

Install the engine **once per host**, then drive any number of projects with it:

```sh
curl -fsSL https://raw.githubusercontent.com/VocanicZ/Harness/main/install.sh | bash
```

`install.sh` checks all prerequisites, provisions the required Claude plugins (`superpowers` and `ralph-loop` from the `anthropics/claude-plugins-official` marketplace) and the matt-pocock skills (`to-prd`, `to-issues` from `https://github.com/mattpocock/skills`) into your Claude install, places the engine at the single host location `~/.harness/engine/`, installs the `/harness` operator skills **once** to your user scope (`~/.claude/skills/`, not vendored per project), creates the `~/.harness/` host root, and symlinks `harness` onto your `PATH` (`~/.local/bin/harness` → `~/.harness/engine/bin/harness`). If `~/.local/bin` isn't writable it prints the exact `PATH` line to add instead. No engine copy and no skills are cloned into your project.

The `~/.harness/` host root also carries two subdirs created at install time — `poller/` and `snapshots/`. These back the optional **host poller** (one poll per repo, shared across every fleet on the host): `poller/` holds the refcounted registry + the poller pidfile, and `snapshots/` holds the per-repo snapshot JSON workers read from. They are **opt-in per fleet** behind `HARNESS_USE_POLLER` (default off — the engine writes nothing into them until a fleet enables the flag). See [Host poller](#host-poller).

Then, from the root of each project you want to drive:

```sh
harness init     # writes that project's config + state under .harness/
```

`HARNESS_HOME` (default `~/.harness`) and `HARNESS_BIN_DIR` (default `~/.local/bin`) override the install location and the symlink directory.

## Prerequisites

| Tool | Notes |
|------|-------|
| `git` | standard |
| `tmux` | session multiplexer used by the worker pool |
| `python3` | runs `issuelib.py` (state machine) |
| `gh` | GitHub CLI — must be **authenticated** (`gh auth login`) |
| `claude` | Claude Code CLI — must be installed with a working model configured |

## Pipeline modes

`HARNESS_MODE` selects which orchestration actions the dispatch engine may emit:

| Mode | Entry stage | Orchestration allowed | PRD authored by | COMPLETE when |
|------|-------------|----------------------|-----------------|---------------|
| `issue-only` | IMPL | none (IMPL only) | — | all `ready-for-agent` issues closed and none in-flight |
| `prd` | DECOMPOSE | DECOMPOSE, REVIEW | human (creates one `prd`-labelled issue) | PRD issue closed and labelled `reviewed` |
| `planned` | PLAN | PLAN, PRD, DECOMPOSE, REVIEW | agent (from `HARNESS_SPEC`) | PRD issue closed and labelled `reviewed` |

The full pipeline is: `PLAN → PRD → DECOMPOSE → IMPL (parallel) → REVIEW → COMPLETE`.
`HARNESS_MODE` gates which stages are active; all modes share the same state machine.

## Topologies

| Topology | Description |
|----------|-------------|
| `single` | One target repo (`HARNESS_REPO`). The pool drives that one unit; up to `HARNESS_CAP` concurrent impl sessions run inside it. Default. |
| `multi` | Multiple repos in a dependency DAG described by `targets.tsv` (`id → repo → deps → desc`). A target unblocks its dependents when it reaches COMPLETE. Peak concurrency = `POOL × CAP`. |

## Configuration

Harness reads `.harness/config` (a sourceable `KEY=VALUE` file). Any key can be overridden inline: `HARNESS_POOL=5 harness start`. Already-set environment variables take precedence over the file.

| Key | Default | Meaning |
|-----|---------|---------|
| `HARNESS_MODE` | `issue-only` | Pipeline mode: `issue-only`, `prd`, or `planned` |
| `HARNESS_TOPOLOGY` | `single` | `single` or `multi` |
| `HARNESS_OWNER` | _(empty)_ | GitHub owner/org (used to expand bare repo names) |
| `HARNESS_REPO` | _(empty)_ | Target repo for single topology (`owner/repo`) |
| `HARNESS_SPEC` | _(empty)_ | Path to the umbrella spec; `planned` mode only |
| `HARNESS_AUTONOMOUS` | `true` | `true` = agents never park; `false` = agents may apply `agent-blocked` for human help |
| `HARNESS_POOL` | `3` | Number of pool workers (unit-concurrency cap) |
| `HARNESS_CAP` | `3` | Max concurrent claude sessions per unit |
| `HARNESS_POLL` | `300` | Resident-pool poll interval in seconds (idle/steady-state cadence) |
| `HARNESS_PRIORITY_POLL` | `60` | Fast poll interval for the priority bug lane |
| `HARNESS_SESS_PREFIX` | `hz` | tmux session name prefix |
| `HARNESS_LABEL_READY` | `ready-for-agent` | Label that marks an issue dispatchable |
| `HARNESS_LABEL_PRD` | `prd` | Label that marks the PRD tracking issue |
| `HARNESS_LABEL_WORKING` | `agent-working` | Label applied while a session owns an issue |
| `HARNESS_LABEL_BLOCKED` | `agent-blocked` | Label applied to issues parked for human help (autonomous=false) |
| `HARNESS_LABEL_REVIEWED` | `reviewed` | Label applied to the PRD issue after review passes |
| `HARNESS_LABEL_COORD` | `coordination` | Optional, human-facing tracking label only. Cross-unit deps are filed as real cross-repo `owner/repo#N` refs in `## Blocked by` (see `prompts/decompose.md`); this label is **not** the work path. |
| `HARNESS_AUTHOR_ALLOWLIST` | _(empty)_ | Comma-separated GitHub logins permitted to author claimable issues. Empty = self-only (secure default); `*` = allow any author. See [Issue-author allowlist](#issue-author-allowlist) |
| `HARNESS_USE_POLLER` | _(empty)_ | Host-poller opt-in. Empty = today's direct-`gh` polling (default off); set (e.g. `1`) = this fleet reads shared host snapshots instead of polling GitHub itself. Staged-rollout flag — see [Host poller](#host-poller) |
| `HARNESS_WORKTREE_HOOK` | _(empty)_ | Path to a project script run once in every freshly created worktree (and every multi-topology clone), with `cwd` = that worktree and its path as `$1`. Absolute, or relative to the project root. Empty = no-op. See [Provisioning a fresh worktree](#provisioning-a-fresh-worktree) |

### Issue-author allowlist

By default the dispatch engine **only claims issues authored by the authenticated GitHub user** (the login behind `gh api user` — the account the bot commits as, not `HARNESS_OWNER`, which may be an org). This is secure-by-default: it closes a defense-in-depth gap where auto-labeling actions/templates, an over-permissioned or compromised collaborator, or a label-name collision could otherwise inject a `ready-for-agent` issue that the fleet would pick up and act on.

- **Empty (default) — self-only.** Only the bot's own issues (its PRD, decompose, and cross-repo issues included) are claimed.
- **`HARNESS_AUTHOR_ALLOWLIST="alice,bob"`** — additionally trust those logins. The set is *additive to self*: the bot is always allowed, so its own work is never filtered out.
- **`HARNESS_AUTHOR_ALLOWLIST="*"`** — allow any author (community-fleet opt-in), restoring the pre-allowlist behavior.

The check applies to both PRD selection and the implementation claimable filter. Issues from non-allowed authors are **silently ignored** — never claimed, commented, or labelled — with only a local debug line on stderr (no GitHub-visible signal to a prober).

### Provisioning a fresh worktree

Every impl / bug-fix / triage session runs in its own `git worktree`, and a worktree is a **bare checkout of the tracked tree**. Submodules come up as empty directories (`worktree add` never inits them), and anything your main checkout carries untracked — toolchain symlinks, prebuilt engine or SDK binaries, build outputs, import/index caches — is simply absent. For a plain clone-and-go repo that's fine. For anything heavier, the agent starts in a tree that cannot build.

`HARNESS_WORKTREE_HOOK` is the seam. Point it at a script; it runs once per fresh worktree with `cwd` set to that worktree and its path as `$1`:

```sh
# .harness/config
HARNESS_WORKTREE_HOOK=.harness/worktree-hook.sh
```

```sh
#!/usr/bin/env bash
# .harness/worktree-hook.sh — runs inside each new worktree
set -euo pipefail
git submodule update --init --recursive
ln -sfn "$HOME/toolchains/sdk" ./sdk     # symlink big untracked deps, never copy
./scripts/warm-cache.sh
```

Keep it **idempotent** — it may run against a reused path. Failures are logged and swallowed: the session still launches, because a hard failure here would strand the issue under `agent-working` with no session to work it. Empty (the default) is a true no-op.

### Parallel-lane merge safety

Workers branch off the default branch independently and merge back independently, so by the time a lane is ready its base has usually moved. A suite that went green on a lane's branch only proves that change against the base it *started* from, and a conflict-free text merge can still be semantically broken — another lane edited the same function, moved a helper's contract, or rebuilt an artifact the tests load.

The impl / bug-fix / resume prompts therefore require a **rebase onto the current base plus a re-run** immediately before merging, repeated until the rebase is a no-op. On a repo with **no required status checks this is the only guard**: `gh pr merge --auto` has nothing to wait for and merges on mergeable-state alone. If your repo has checks that build and test the *merge result*, they enforce the same property server-side — recommended for any fleet running more than one or two lanes against a shared codebase.

The same prompts hold lanes to **no new failures against a baseline** captured before the first edit, rather than a globally green suite. Most real repos carry some pre-existing reds; an autonomous agent told "all green required" will either chase them forever or edit tests until they pass.

## Commands

`harness` is on your `PATH` after install; run it from inside any project you've `harness init`'d:

```
harness <command>
```

| Command | Description |
|---------|-------------|
| `init` | Interactive setup wizard — writes `.harness/config`, creates missing GitHub labels, seeds the target repo(s) |
| `start [--recover]` | Launch the worker pool. `--recover` sweeps stale pidfiles, claims, and orphaned `agent-working` labels before launch |
| `stop [--clean]` | Stop the pool. `--clean` also removes worktrees |
| `status [--watch [secs]]` | One-shot or live dashboard: pool state, per-unit progress, live sessions, gated units |
| `doctor [--fix]` | Diagnose what strands a pool — who holds `start.lock`/`pool.lock` (via a dependency-free `/proc` scan, so it works without `fuser`/`lsof`), orphaned lock-holders (a killed worker's leaked poll-`sleep`), and stale pidfiles. Report-only by default; `--fix` clears stale pidfiles and reaps **this project's** orphans (never touches a co-resident sibling fleet) |
| `attach <unit> [issue]` | tmux-attach to a running session |
| `migrate` | Convert a project's **vendored** `.harness/` (the pre-shared-engine layout) to state-only and re-point it at the shared engine. Idempotent; refuses if no shared engine is installed |
| `poll [--once\|--status]` | Host-level debug entry to the shared snapshot poller. `--once` refreshes every registered repo once; `--status` reports the poller pid + registered slugs/cadences. Normal operation needs no manual `poll` — workers self-heal it (see [Host poller](#host-poller)) |
| `plan "<brief>"` | Inject a plan/topology change (PLAN.md / `targets.tsv`, incl. seeding a new target repo) into a **live** fleet. Grill via [`/harness-plan`](#per-command-shortcuts) |
| `prd "<brief>"` | Extend a **live** fleet's PRD scope and create the delta issues. Grill via [`/harness-prd`](#per-command-shortcuts) |
| `issue "<brief>"` | Inject a discrete implementation issue (or a few) into a **live** fleet. Grill via [`/harness-issue`](#per-command-shortcuts) |

## Pause / resume / update

```bash
harness pause           # soft drain — stop claiming; live agents finish (local)
harness pause --force   # checkpoint every agent to GitHub, then idle
harness resume          # clear pause; resume here, or start --recover elsewhere
harness update          # ff-pull the one shared engine install (every project picks it up)
harness setup           # verify prereqs + seed labels on all units (no start)
```

**Cross-machine pause/resume.** `pause --force` tells each running agent to commit + push its WIP
branch, post its `/handoff` context as a GitHub issue comment, and label the issue `agent-paused`.
Because all of that lives in GitHub, you can `resume` on a *different* machine: it runs
`start --recover`, re-dispatches the `agent-paused` issues, and each agent fetches its branch, reads
the handoff comment, and finishes the work.

**`update` never touches your config.** It runs `git pull --ff-only` on the single shared engine
install (`~/.harness/engine`) and nothing else — no project `.harness/` is touched, and it never
runs a destructive git op. Because every project shares that one install, one `update` updates them
all at once (no per-project re-pull, no version skew). Live workers keep the old engine logic until
you relaunch (`pause` → drain → `stop` → `start --recover`).

New config keys: `HARNESS_LABEL_PAUSED` (default `agent-paused`), `HARNESS_PAUSE_GRACE` (default `300`s).

## Host poller

When several fleets share one host and **one GitHub token**, the dispatch reads stack up: every
pool worker and the priority bug lane each run a full `gh issue list` (+ plan-file reads) every
poll, so GitHub read volume scales with **workers × repos × fleets**. The reads are largely
redundant — everyone recomputes from the same per-repo issue list — and under load a worker gets
rate-limited and can't dispatch, so the fleet looks "stuck" until the token resets.

The **host poller** consolidates that into **one poll per repo**. A single host-level process
refreshes a raw, versioned snapshot per registered repo into `~/.harness/snapshots/`, and workers
read the snapshot instead of polling GitHub. GitHub read volume becomes a flat function of *repos*,
independent of worker and fleet count. Crucially, only the *polling* is centralized: each project
still computes dispatch **locally with its own env**, so it keeps its own session prefix, mode,
topology, label set, and author allowlist.

**Opt-in, default off.** The poller is gated per fleet behind `HARNESS_USE_POLLER` (empty = today's
direct-`gh` polling). A fresh install and any fleet without the flag are completely unaffected.

**Layout** (under the `~/.harness/` host root):

```
~/.harness/
├── poller/
│   ├── registry/<owner__repo>__<project>.json   one per (repo, fleet): slug, cadence, prefix, project
│   └── poller.pid                                the poller — a background process, NOT a tmux session
└── snapshots/<owner__repo>.json                  {schema_version, generated_at, slug, issues[], has_plan, …}
```

**Self-healing — no daemon to manage.** There is no operator-facing poller lifecycle command:
`harness start` brings it up, and every worker/bug-lane tick re-checks and relaunches it, so a
crashed poller self-heals within one tick. Because it is a plain background process (not a tmux
session), `harness stop` never kills it — correct, since other fleets on the host may still need
it. `harness stop` only removes *this* fleet's registry entries; a repo stays polled until every
referencing fleet has deregistered (refcount).

**Stale → hold, never fall back to `gh`.** A worker treats a snapshot as fresh only within
`3 × refresh-interval`. A stale/missing snapshot **holds new dispatch** (claims no new work) while
leaving in-flight sessions running, logs a deduped banner, and relaunches the poller — it never
falls back to polling GitHub directly (that would reintroduce the stampede). Dispatch resumes
automatically once the snapshot is fresh again.

`harness poll --status` reports whether the poller is alive plus the registered slugs and their
cadences; `harness poll --once` forces a single refresh pass (debug/test). Normal operation needs
neither — the workers manage the poller for you.

### Staged rollout / rollback

The new engine ships with the poller **off**, so deploying it changes nothing until you flip the
flag. Cut fleets over one at a time:

1. `harness update` — ff-pull the shared engine (every fleet picks it up; none change behavior yet).
2. For one fleet: set `HARNESS_USE_POLLER=1` in its `.harness/config`, then
   `harness stop && harness start --recover`. On start it registers its repos and brings the poller
   up; the pool and bug lane become snapshot-served.
3. **Validate:** that fleet's worker logs show snapshot reads (no `gh issue list` for dispatch), the
   poller is writing `~/.harness/snapshots/<slug>.json`, and dispatch still completes work
   (`harness poll --status` shows the slug registered).
4. Repeat for the next fleet.

**Rollback** at any point is trivial and per-fleet: unset `HARNESS_USE_POLLER` (or remove the line
from `.harness/config`) and `harness stop && harness start --recover`. That fleet returns to
direct-`gh` polling immediately. Snapshots are ephemeral (regenerated), so there is no migration
state to undo.

## Migrating an old vendored project

Early Harness projects **vendored** the engine: a full clone (engine code + its own `.git`) lived
inside the project's `.harness/` alongside its config and runtime state. The engine is now installed
**once per host** at `~/.harness/engine` and shared by every project (see [Install](#install)), so a
vendored `.harness/` no longer needs — and shouldn't carry — its own engine copy.

`harness migrate` converts a vendored `.harness/` to **state-only** in place:

```bash
harness install          # once per host — places the shared engine + the 'harness' PATH symlink
cd your-project
harness migrate          # strip the vendored engine clone + .git; keep config + runtime state
harness start --recover  # relaunch off the shared engine
```

It **preserves** all per-project state — `config`, `targets.tsv`, `run/` (including `claims/`),
`worktrees/`, `checkouts/`, and any `prompts/*.local.md` overrides — and **removes** the vendored
engine code and its `.git`. In-flight worktrees survive: single-topology worktrees belong to the
project repo (the parent of `.harness/`), and multi-topology worktrees to `checkouts/*/.git`, so
deleting the vendored `.harness/.git` never corrupts one. It is **idempotent** (re-running on an
already state-only `.harness/` is a no-op) and **refuses** if no shared engine is installed.

## The `/harness` skill

Ships in the engine at `~/.harness/engine/skill/SKILL.md` and installs **once** to your user scope at `~/.claude/skills/harness/SKILL.md` (available in every project — not vendored per repo). `harness update --with-skills` re-deploys it from the freshly pulled engine.

Invoke `/harness` (or say "start the fleet", "what's the harness doing") inside any Claude session in your project. The skill wraps the CLI so you can operate the fleet conversationally — start, stop, watch the dashboard, read per-unit state, distinguish COMPLETE from stuck, and apply safe unstick moves (free a stale `agent-working` label, fix a `## Blocked by` section, run `--recover`). Read-mostly posture: operate and observe; never hand-do a unit's PLAN/PRD/IMPL work.

### Per-command shortcuts

For one-shot ops without the state-detection dance, thin sibling skills map 1:1 to a CLI subcommand. Each ships in the engine at `~/.harness/engine/skill/<name>/SKILL.md` and installs once to your user scope at `~/.claude/skills/<name>/`:

| Skill | Runs | Notes |
|-------|------|-------|
| `/harness-init`   | `harness init`   | setup wizard (interactive — prefer `! harness init`) |
| `/harness-start`  | `harness start`  | confirms first; `--recover` for crash/new-host |
| `/harness-stop`   | `harness stop`   | confirms first; asks before `--clean` |
| `/harness-pause`  | `harness pause`  | confirms first; soft drain vs `--force` checkpoint |
| `/harness-resume` | `harness resume` | confirms first; works across machines |
| `/harness-status` | `harness status` | read-only, runs immediately |
| `/harness-plan`   | `harness plan`   | inject a topology/PLAN change into a live fleet; grills + replays a crystallized brief for confirmation (the human safety gate) before mutating; supports `--unit <id>` (multi-topology) and the `--recover` retired-fleet fallback |
| `/harness-prd`    | `harness prd`    | grow PRD scope → delta issues on a live fleet; grills + replays a crystallized brief for confirmation before mutating; supports `--unit <id>` (multi-topology) and the `--recover` retired-fleet fallback |
| `/harness-issue`  | `harness issue`  | inject a discrete implementation issue into a live fleet; grills + replays a crystallized brief for confirmation before mutating; supports `--unit <id>` (multi-topology) and the `--recover` retired-fleet fallback |

Use `/harness` when you want the full set-up-aware operator (detect state, observe, unstick); use the shortcuts when you already know the action you want.

## Autonomy

| Setting | Behaviour |
|---------|-----------|
| `HARNESS_AUTONOMOUS=true` (default) | Agents are instructed never to apply `agent-blocked`. Every obstacle is resolved by the agent. Stale `agent-working` labels are reaped automatically. |
| `HARNESS_AUTONOMOUS=false` | Agents may apply `agent-blocked` to park work that genuinely requires human input. Blocked issues are excluded from dispatch until the label is removed. |

## Usage note — `issue-only` mode

In `issue-only` mode the fleet considers a unit COMPLETE only once it has seen `ready-for-agent` issues that are now all closed. A freshly started unit with zero `ready-for-agent` issues has nothing to dispatch and will keep polling. Label at least one issue `ready-for-agent` before or while the pool is running, otherwise the pool idles.

## Contributing

Contributions welcome. To get started:

1. **Fork & branch** — fork the repo, then branch from `main` (`git checkout -b feat/your-change`).
2. **Develop against the dev checkout** — Harness drives itself; clone and run `./install.sh` in a throwaway target repo to exercise the engine end-to-end.
3. **Keep state in GitHub** — the core invariant is *no database, no daemon*. New features must persist their state in issues, labels, or the local run directory only.
4. **Run the tests** — exercise `test/` (e.g. `bash test/test_subskills.sh`) before opening a PR.
5. **Open a PR** — describe the change, link any related issue, and keep the diff scoped. One concern per PR.

Bug reports and feature requests go in [GitHub Issues](https://github.com/VocanicZ/Harness/issues). For substantial changes, open an issue first to discuss direction.

## License

[MIT](LICENSE) © VocanicZ

## Star History

<a href="https://star-history.com/#VocanicZ/Harness&Date">
  <img src="https://api.star-history.com/svg?repos=VocanicZ/Harness&type=Date" alt="Star History Chart" width="600">
</a>

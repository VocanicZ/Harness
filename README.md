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

`install.sh` checks all prerequisites, provisions the required Claude plugins (`superpowers` and `ralph-loop` from the `anthropics/claude-plugins-official` marketplace) and the matt-pocock skills (`to-prd`, `to-issues` from `https://github.com/mattpocock/skills`) into your Claude install, places the engine at the single host location `~/.harness/engine/`, and symlinks `harness` onto your `PATH` (`~/.local/bin/harness` → `~/.harness/engine/bin/harness`). If `~/.local/bin` isn't writable it prints the exact `PATH` line to add instead. No engine copy is cloned into your project.

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

### Issue-author allowlist

By default the dispatch engine **only claims issues authored by the authenticated GitHub user** (the login behind `gh api user` — the account the bot commits as, not `HARNESS_OWNER`, which may be an org). This is secure-by-default: it closes a defense-in-depth gap where auto-labeling actions/templates, an over-permissioned or compromised collaborator, or a label-name collision could otherwise inject a `ready-for-agent` issue that the fleet would pick up and act on.

- **Empty (default) — self-only.** Only the bot's own issues (its PRD, decompose, and cross-repo issues included) are claimed.
- **`HARNESS_AUTHOR_ALLOWLIST="alice,bob"`** — additionally trust those logins. The set is *additive to self*: the bot is always allowed, so its own work is never filtered out.
- **`HARNESS_AUTHOR_ALLOWLIST="*"`** — allow any author (community-fleet opt-in), restoring the pre-allowlist behavior.

The check applies to both PRD selection and the implementation claimable filter. Issues from non-allowed authors are **silently ignored** — never claimed, commented, or labelled — with only a local debug line on stderr (no GitHub-visible signal to a prober).

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
| `attach <unit> [issue]` | tmux-attach to a running session |
| `migrate` | Convert a project's **vendored** `.harness/` (the pre-shared-engine layout) to state-only and re-point it at the shared engine. Idempotent; refuses if no shared engine is installed |

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

Ships in the engine at `~/.harness/engine/skill/SKILL.md` and deploys into your project's `.claude/skills/harness/SKILL.md`.

Invoke `/harness` (or say "start the fleet", "what's the harness doing") inside any Claude session in your project. The skill wraps the CLI so you can operate the fleet conversationally — start, stop, watch the dashboard, read per-unit state, distinguish COMPLETE from stuck, and apply safe unstick moves (free a stale `agent-working` label, fix a `## Blocked by` section, run `--recover`). Read-mostly posture: operate and observe; never hand-do a unit's PLAN/PRD/IMPL work.

### Per-command shortcuts

For one-shot ops without the state-detection dance, thin sibling skills map 1:1 to a CLI subcommand. Each ships in the engine at `~/.harness/engine/skill/<name>/SKILL.md` and deploys to your project's `.claude/skills/<name>/`:

| Skill | Runs | Notes |
|-------|------|-------|
| `/harness-init`   | `harness init`   | setup wizard (interactive — prefer `! harness init`) |
| `/harness-start`  | `harness start`  | confirms first; `--recover` for crash/new-host |
| `/harness-stop`   | `harness stop`   | confirms first; asks before `--clean` |
| `/harness-pause`  | `harness pause`  | confirms first; soft drain vs `--force` checkpoint |
| `/harness-resume` | `harness resume` | confirms first; works across machines |
| `/harness-status` | `harness status` | read-only, runs immediately |

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

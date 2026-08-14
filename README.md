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
| `prd` | DECOMPOSE | DECOMPOSE, REVIEW | human (creates one or more `prd`-labelled issues) | every PRD issue closed and labelled `reviewed`, **and** no `ready-for-agent` issue still open |
| `planned` | PLAN | PLAN, PRD, DECOMPOSE, REVIEW | agent (from `HARNESS_SPEC`) | every PRD issue closed and labelled `reviewed`, **and** no `ready-for-agent` issue still open |

The full pipeline is: `PLAN → PRD → DECOMPOSE → IMPL (parallel) → REVIEW → COMPLETE`.
`HARNESS_MODE` gates which stages are active; all modes share the same state machine.

The "no open `ready-for-agent` issue" half of the `prd` / `planned` condition matters because a
closed PRD is not proof the work is done. `CLOSE_PRD` — the engine's own close — is gated on every
ready child being closed, but nothing else that can close a PRD is: a reviewer's own `gh issue
close`, a human, an injected session. Without that half, a PRD closed while one ready issue is
still open makes the unit COMPLETE, and a complete unit is dropped from dispatch **before** the
engine ever asks what work is outstanding — so the issue stays open forever while the fleet
reports success. `issue-only` has always required it; the other two modes were the outliers.

The cost is deliberate: an open ready issue that no lane can claim — blocked by an unclosed
`## Blocked by` ref, or `agent-blocked` on a non-autonomous fleet — now holds its unit incomplete,
and in `multi` topology holds every dependent unit behind it. That is the honest state rather than
a false COMPLETE, and it is not silent: the unit logs one banner naming the outstanding count and
the remedy, deduped so a genuinely stuck unit says it once rather than every poll.

### Several PRDs per unit

A unit may hold several PRD issues at once. PRDs with no `## Blocked by` section run in
**parallel** — their children are dispatched as capacity allows, lowest PRD number first, spilling
into the next PRD when one runs dry. A PRD that declares

```
## Blocked by
#41
```

is held until #41 closes, giving you a strict **one-by-one** sequence. Mix freely: sequence only
what genuinely depends on something else.

Children are attributed to their PRD by a `## Parent` section in the issue body (the decompose
agent writes this; the legacy `Part of #N` trailer is also honoured). A ready-labelled issue with
no parent — an injected task, say — is dispatched first and does not gate any PRD's review. The
unit is COMPLETE only when every PRD is closed and no unparented issue is still open.

Each eligible PRD gets its own orchestration lane: DECOMPOSE, REVIEW and the engine's own
`CLOSE_PRD` are gated per PRD rather than unit-wide, so two PRDs can orchestrate at once. Their
sessions carry a `-p<n>` suffix and run in per-PRD worktrees, which is what keeps two concurrent
orch agents off each other's checkout.

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
| `HARNESS_SESS_PREFIX` | derived from the project dir at `init` (`hz` for pre-existing configs) | tmux session name prefix — **must be unique per fleet on a host**; a shared prefix makes `harness stop` in one project kill another's agents |
| `HARNESS_PREFIX_COLLISION` | `refuse` | `refuse` \| `warn` — what `harness start` does when another fleet already owns this session prefix |
| `HARNESS_LABEL_READY` | `ready-for-agent` | Label that marks an issue dispatchable |
| `HARNESS_LABEL_PRD` | `prd` | Label that marks the PRD tracking issue |
| `HARNESS_LABEL_WORKING` | `agent-working` | Label applied while a session owns an issue |
| `HARNESS_LABEL_BLOCKED` | `agent-blocked` | Label applied to issues parked for human help (autonomous=false) |
| `HARNESS_LABEL_REVIEWED` | `reviewed` | Label applied to the PRD issue after review passes |
| `HARNESS_LABEL_COORD` | `coordination` | Optional, human-facing tracking label only. Cross-unit deps are filed as real cross-repo `owner/repo#N` refs in `## Blocked by` (see `prompts/decompose.md`); this label is **not** the work path. |
| `HARNESS_AUTHOR_ALLOWLIST` | _(empty)_ | Comma-separated GitHub logins permitted to author claimable issues. Empty = self-only (secure default); `*` = allow any author. See [Issue-author allowlist](#issue-author-allowlist) |
| `HARNESS_USE_POLLER` | _(empty)_ | Host-poller opt-in. Empty = today's direct-`gh` polling (default off); set (e.g. `1`) = this fleet reads shared host snapshots instead of polling GitHub itself. Staged-rollout flag — see [Host poller](#host-poller) |
| `HARNESS_WORKTREE_HOOK` | _(empty)_ | Path to a project script run once in every freshly created worktree (and every multi-topology clone), with `cwd` = that worktree and its path as `$1`. Absolute, or relative to the project root. Empty = no-op. See [Provisioning a fresh worktree](#provisioning-a-fresh-worktree) |
| `HARNESS_GAUNTLET_ROUNDS` | `3` | Gauntlet review: rounds allowed before the reviewer concedes and signs off. Only applies to a PRD carrying a `## Quality bar` — see [Gauntlet review](#gauntlet-review) |
| `HARNESS_CI_GATE` | `1` | `1` = hold new dispatch while the default branch's own CI is red (live sessions drain; the bug lane is never gated); `0` = off. Fail-open — no Actions, an in-flight run, or a `gh` outage all dispatch normally. See [Never merging red](#never-merging-red) |

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

The impl / bug-fix / resume prompts therefore require a **rebase onto the current base plus a re-run** immediately before merging, repeated until the rebase is a no-op. If your repo has checks that build and test the *merge result*, they enforce the same property server-side — recommended for any fleet running more than one or two lanes against a shared codebase.

The same prompts hold lanes to **no new failures against a baseline** captured before the first edit, rather than a globally green suite. Most real repos carry some pre-existing reds; an autonomous agent told "all green required" will either chase them forever or edit tests until they pass.

### Never merging red

A rebase-and-re-run is blind to any failure that only reproduces on the runner — a different SDK image, a missing secret, a platform gap. Left alone, the fleet's merge decision read **mergeable-state only and never the check result**, which on a repo with no *required* status check is not a guard at all: `gh pr merge --auto` has nothing to wait for and merges a red PR happily. A private repo on a free plan cannot configure one — branch protection and rulesets both return `403` — so this is the default situation for most fleets, not an edge case.

Two halves close it, and neither is sufficient alone:

| Half | Where | What it does |
|---|---|---|
| Read the result before merging | `prompts/impl.md`, `prompts/bug-fix.md` | `gh pr checks --watch --fail-fast` immediately before the merge step. Red → fix and retry up to 3 times, then leave the PR **open**, comment the failing workflow and run URL on the issue, and end **without** the completion promise. Explicitly overrides "never park": that means never wait on a human, not merge anyway. |
| Stop claiming while the base is red | `HARNESS_CI_GATE` | Before each poll's dispatch the pool checks the default branch's own CI. Red → no new sessions spawn; live ones drain untouched, and the next poll resumes automatically once it is green. Caps the blast radius when the first half is somehow bypassed. |

The gate is **fail-open** on purpose — a fleet that halts on uncertainty is worse than one that merges a bad commit. Only a positively-failed *most recent completed* run of some workflow counts as red; no Actions at all, nothing completed yet, an unrecognised conclusion, or a `gh` outage all dispatch normally. A stale red behind a newer green does not gate, and `cancelled` is never treated as a failure.

The **priority bug lane is deliberately not gated**, because it is the remedy: filing a `bug` issue is how a fleet digs a red default branch back out. Set `HARNESS_CI_GATE=0` to turn the whole thing off.

### Gauntlet review

Review normally grades the build against the PRD's own `## Acceptance criteria`. That bar is
self-referential — the same fleet wrote the PRD, decomposed it, and implemented it — so a pass
means "it meets the spec we wrote", never "it is any good".

A PRD may opt in to a harder gate by carrying one extra section:

```markdown
## Quality bar
Beat: ripgrep — https://github.com/BurntSushi/ripgrep
Judged on:
- time to first result on a 1M-line tree
- output legibility for a multi-file match
```

When it is present and every acceptance criterion already passes, the reviewer runs a **gauntlet
round**: it provisions the named reference, runs one fixed task list against both artifacts,
writes the two results into unlabelled `A/` and `B/` directories under
`.harness/gauntlet/<unit>/r<round>/`, and hands only those two paths to a **fresh-context critic
sub-agent**, which returns a binary winner plus the single largest gap. No scores — numeric
scoring drifts upward every round.

If ours wins, the PRD is signed off. If it loses, the reviewer files **one** `ready-for-agent`
issue for that one gap and leaves a `<!-- harness-gauntlet round=N -->` comment on the PRD; the
pool implements it and review runs again at round N+1. The loop is the ordinary
REVIEW → IMPL → REVIEW path — no new pipeline stage.

The bar must be **named** (a specific artifact, not a category), **fetchable** (the reviewer can
clone, install, run, or open it), and **comparable** (both can sit side by side and a judge can
pick one). A PRD with no `## Quality bar` reviews exactly as it always has, so this is off unless
a PRD asks for it.

**Rounds are capped** by `HARNESS_GAUNTLET_ROUNDS` (default `3`). At the cap the reviewer concedes:
it comments the standing gap and signs off. A bar can be honestly unbeatable, and an autonomous
fleet has nobody to call the loop off — without a cap one PRD would burn the budget forever and,
in `multi` topology, block every dependent target behind it. A reference that cannot be
provisioned (paywalled, no public build) is treated the same way: comment why, sign off on the
criteria alone. The reviewer never parks a quality gate behind `agent-blocked`.

**Blindness here is prompt discipline, not a sandbox.** The reviewer wrote the side mapping, so it
knows it; only the critic sub-agent is blind, via fresh context plus an explicit instruction not to
read outside the two directories. A determined agent could peek — the same trust model as the rest
of the engine.

Credit: the pattern is Matt Shumer's [Gauntlet Loop](https://github.com/robonuggets/gauntlet-loop).

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

## Fleet prefixes

Every tmux session a fleet creates is named `<prefix>-…`, and `harness stop` kills everything
matching `^<prefix>-`. Two fleets sharing a prefix on one host therefore cross-kill: stopping one
tears down the other's live agents mid-edit.

`harness init` derives a distinct prefix from the project directory name (`~/proj/Harness` →
`harness`) and writes it to `.harness/config`, so this is handled for you. Projects initialised
before this existed have no prefix line and keep the historical `hz` default — set
`HARNESS_SESS_PREFIX` in their `.harness/config` if more than one fleet runs on the host.

`harness start` refuses to start on a prefix another fleet already owns, naming the project that
holds it and the retry command. It detects this two ways: live tmux sessions in the prefix space
(attributed to their project by each session's working directory, so it works even against a fleet
running an older engine), and the host-wide registry at `~/.harness/fleets/` — one JSON per live
fleet, written by `harness start` and removed by `harness stop`. The registry also reserves the
prefix of a fleet that is registered but currently idle.

A fleet killed with `kill -9` never deregisters. Its entry is pruned automatically once it has no
live sessions and no live worker pids, or on demand with `harness doctor --fix`.
`HARNESS_PREFIX_COLLISION=warn` downgrades the refusal to a warning.

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

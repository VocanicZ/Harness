# Harness — Standalone Project-Agnostic Agent Orchestrator

**Date:** 2026-05-23
**Status:** Design (approved for planning)
**Origin:** Extracted and generalized from the Bonsai 2.0 in-repo `harness/`.

## Goal

Ship `Harness`: a standalone, public, project-agnostic delivery orchestrator that drives a
pool of autonomous Claude Code sessions against a GitHub-issues board. Installed into any
project with a single `curl | bash` line; configured by an interactive setup wizard; supports
three pipeline modes and both single-repo and multi-repo (dependency-DAG) topologies.

## Non-goals

- Replacing Bonsai's existing in-repo `harness/`. **Bonsai keeps its local version unchanged.**
  This new repo is a generalized fork, not a rewire of Bonsai.
- Supporting agent runners other than Claude Code. The runner binary/flags are configurable,
  but the design assumes a `claude`-compatible CLI.
- A web dashboard, daemon, or database. State stays 100% in GitHub (issues + labels + pushed
  commits) + a small local run dir, so the tool is stateless and resumable — same as today.

## Naming

- Project / repo: **`Harness`** (public, assumed `RainBowCreation/Harness` — adjust at review).
- Command: **`harness`**.
- Env-var prefix: **`HARNESS_*`**.
- Per-project install dir: **`.harness/`** (a checkout of the public repo).

## Distribution & install

One-liner, run from a target project's root:

```sh
curl -fsSL https://raw.githubusercontent.com/RainBowCreation/Harness/main/install.sh | bash
```

`install.sh` (fails fast with remediation guidance on any unmet prerequisite):
1. **Prerequisites** — verify; refuse to continue if any is missing:
   - `git`, `tmux`, `python3` present.
   - `gh` installed **and authenticated** (`gh auth status` succeeds).
   - `claude` installed **and a model usable** (CLI present + a configured/working model — the
     pool launches `claude` sessions, so a no-model install is a hard fail).
2. **Required Claude skills / hooks** — ensure all are installed into the user's Claude.
   Idempotent: skip any already present. Both are hard requirements; a missing one is a hard fail
   after attempted install.
   - **superpowers plugin** — the prompts invoke `writing-plans`, `to-prd`, `to-issues`,
     `subagent-driven-development`, `test-driven-development`. Installed from its source
     (user-provided: `https://github.com/mattpocock/skills` — confirm repo + mechanism at
     review; see Open assumptions).
   - **ralph-loop** — the engine's session driver. `write_state` builds `.claude/ralph-loop.local.md`
     which the ralph-loop **Stop-hook** consumes to re-feed the scoped prompt each iteration until
     the deliverable exists. Without it, sessions run once and never loop, so the whole drive
     model breaks. install.sh installs/enables the ralph-loop skill+hook.
   - The contract is the named skills/hooks being available regardless of source URL.
3. Clones `RainBowCreation/Harness` into `./.harness/` (or `git -C .harness pull` if present).
4. **Installs the `/harness` management skill** into the target project's
   `.claude/skills/harness/SKILL.md` (copy/symlink from `.harness/skill/SKILL.md`) so Claude can
   operate the fleet conversationally (see Claude management skill below). Idempotent.
5. Adds `.harness/` to the **target project's** `.gitignore` (tooling, not committed).
6. Runs `harness init` — the interactive wizard (see Config).
7. Prints next steps (`harness start`, `harness status`, or just ask Claude `/harness`).

`harness` command resolution: `.harness/bin/harness` is the entrypoint; install can optionally
symlink it onto `PATH`, but the documented invocation is `.harness/bin/harness <cmd>` so a
project needs no global state.

### Update model

`.harness/` is a clone, so `git -C .harness pull` updates the engine. The Harness repo's own
`.gitignore` excludes the per-project local state — `config`, `targets.tsv`, `prompts/` overrides,
and the run/worktree dirs — so pulls never clobber local config and never leave a dirty tree.

## Project layout (inside a target project)

```
.harness/                  # checkout of the public Harness repo (gitignored by the project)
├── bin/harness            # CLI dispatcher: init|start|status|attach|stop
├── lib.sh                 # shared config loader + helpers (engine)
├── issuelib.py            # GitHub-issue state machine + dispatch decision engine
├── drive.sh               # drive_unit: take one unit to COMPLETE
├── pool.sh, pool-worker.sh# fixed worker pool (claim→drive→release→repeat)
├── seed.sh                # idempotent repo bootstrap: labels, CI, auto-merge
├── prompts/               # shipped generic templates (plan/prd/decompose/impl/review)
├── skill/SKILL.md         # the /harness management skill (installed into project .claude/skills/)
├── test/                  # plain-bash assertion rig
├── config                 # ← written by `harness init` (gitignored by Harness repo)
├── targets.tsv            # ← multi-repo topology only (gitignored)
└── prompts/*.local.md     # ← optional per-project prompt overrides (gitignored)
```

The engine reads a project-local prompt override (`prompts/<name>.local.md`) in preference to
the shipped `prompts/<name>.md` when present.

## Config (`.harness/config`)

A sourceable shell `KEY=VALUE` file — no parse dependency. `lib.sh` sources it; `issuelib.py`
reads the same values from `os.environ` after `lib.sh` exports them. Already-set environment
overrides the file (`: "${HARNESS_X:=...}"`), so a one-off run can override any key inline.

```sh
# --- topology & mode ---
HARNESS_MODE=issue-only            # issue-only | prd | planned
HARNESS_TOPOLOGY=single            # single | multi
HARNESS_OWNER=acme                 # GitHub owner/org
HARNESS_REPO=acme/widget           # single topology: the one target repo
                                   # multi topology: ignored; see targets.tsv
HARNESS_SPEC=                      # planned mode only: path to the umbrella spec the PLAN/PRD prompts read

# --- autonomy ---
HARNESS_AUTONOMOUS=true            # true  ⇒ no human-park; agents resolve every obstacle, never apply agent-blocked
                                   # false ⇒ agents may apply HARNESS_LABEL_BLOCKED to park work for a human

# --- concurrency / cadence ---
HARNESS_POOL=3                     # number of pool workers (global unit-concurrency cap)
HARNESS_CAP=3                      # max concurrent claude sessions per driven unit
HARNESS_POLL=60                    # worker poll interval (s)
HARNESS_IMPL_MAXITER=30            # ralph-loop backstop for an impl session
HARNESS_ORCH_MAXITER=8             # ralph-loop backstop for an orchestration session

# --- agent runner ---
HARNESS_CLAUDE_BIN=claude
HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions --effort high"

# --- label vocabulary (auto-created if missing; rename freely) ---
HARNESS_LABEL_READY=ready-for-agent
HARNESS_LABEL_PRD=prd
HARNESS_LABEL_WORKING=agent-working
HARNESS_LABEL_BLOCKED=agent-blocked
HARNESS_LABEL_REVIEWED=reviewed
HARNESS_LABEL_COORD=coordination
```

### `harness init` wizard

Interactive terminal prompts (each with a sensible default shown in `[brackets]`):
- mode (issue-only / prd / planned), topology (single / multi)
- owner; for single topology: target repo; for planned mode: spec path
- autonomous? (Y/n)
- pool size, cap, poll
- accept default label names or customize

On finish it: writes `.harness/config`; runs `seed.sh` against the target repo(s) to
**create any missing labels**, add the language-autodetect CI workflow, and enable auto-merge;
for multi topology, scaffolds a `targets.tsv` skeleton and tells the user to fill in deps.

## Modes — one state machine, configurable entry stage

```
PLAN ─▶ PRD ─▶ DECOMPOSE ─▶ IMPL (parallel, worktree-isolated) ─▶ REVIEW ─▶ COMPLETE
```

`HARNESS_MODE` gates which orchestration actions `issuelib.dispatch()` may emit:

| Mode | Entry | Allowed orchestration | PRD authored by | COMPLETE when |
|------|-------|----------------------|-----------------|---------------|
| `issue-only` | IMPL | none (IMPL only) | — (no PRD) | no open dispatchable issues remain (and none in-flight) |
| `prd` | DECOMPOSE | DECOMPOSE, REVIEW | **human** (creates issue labelled `prd`) | PRD issue closed **and** labelled `reviewed` |
| `planned` | PLAN | PLAN, PRD, DECOMPOSE, REVIEW | **agent** (from `HARNESS_SPEC`) | PRD issue closed **and** labelled `reviewed` |

- `issue-only`: workers just pick up dispatchable issues and close them. No PRD/plan concept.
- `prd`: a human writes one PRD issue (`prd` label); the agent decomposes it into impl issues,
  implements them, then reviews. Closes the loop without the agent inventing scope.
- `planned`: greenfield — the agent authors PLAN.md then the PRD from a spec, then proceeds.

## Strategy seam — single vs multi topology

The pool is unchanged in spirit (claim a ready unit → drive to COMPLETE → release → repeat;
flock-atomic claims; GitHub = source of truth; retire when all units COMPLETE). Topology and
mode vary only behind three functions:

| | `claimable_units()` | `drive_unit(u)` | `unit_complete(u)` |
|---|---|---|---|
| **single** | the one repo, if not COMPLETE & unclaimed | run the mode's pipeline, ≤CAP impl sessions | per mode (issues empty / PRD reviewed) |
| **multi** | dependency-ready targets in `targets.tsv` plan order, unclaimed | same pipeline per target | per mode, per target |

- **single** topology = a unit set of exactly one (the repo from `HARNESS_REPO`); no deps. With
  `HARNESS_POOL>1` only one worker drives the repo, but that worker runs up to `HARNESS_CAP`
  concurrent impl sessions, so issue-level parallelism is preserved.
- **multi** topology = today's Bonsai model generalized: `targets.tsv` rows
  (`id ⟶ repo ⟶ depends_on(comma|-) ⟶ description`) with a dependency DAG; a target is
  COMPLETE per its mode, and that unblocks dependents. Peak concurrency = `POOL × CAP`.

This is the existing `lib.sh` registry + `drive.sh` loop, with the registry source and the
`unit_complete` predicate selected by config.

## Labels & dispatchable semantics

`seed.sh` creates any missing label (idempotent) using the configured names. An issue is
**dispatchable** (a worker may claim/IMPL it) when:
- it is open, and
- it carries `HARNESS_LABEL_READY`, and
- it does **not** carry `HARNESS_LABEL_PRD` (the PRD tracking issue is driven by orchestration,
  not picked up as impl work), and
- it does **not** carry `HARNESS_LABEL_WORKING` (a live session already owns it), and
- its `## Blocked by` section (if any) references only closed issues.

So: label an issue `ready-for-agent` and a worker picks it up — the `prd` label is required
only to mark the PRD tracking issue in `prd`/`planned` modes; in `issue-only` mode it is never
needed.

**Autonomy:** when `HARNESS_AUTONOMOUS=true`, `HARNESS_LABEL_BLOCKED` is **not** a dispatch
gate — agents are instructed never to apply it and to resolve every obstacle themselves; the
reaper frees stale `WORKING` labels on any still-open issue for retry. When `false`, a
`BLOCKED`-labelled issue is excluded from dispatch (parked for a human) and the impl prompt is
allowed to park work it genuinely cannot resolve.

## Commands

| Command | Behavior |
|---|---|
| `harness init` | interactive wizard → write config, create labels, seed repo(s), scaffold `targets.tsv` (multi) |
| `harness start [--recover]` | launch the worker pool; `--recover` = crash/new-host sweep (drop stale pidfiles/claims, free orphaned `WORKING` labels) before launch |
| `harness status [--watch [secs]]` | one-shot or live dashboard: pool up/down, per-unit state, live sessions, open PRs, gated units |
| `harness attach <unit> [issue]` | tmux-attach to a session to watch it work |
| `harness stop [--clean]` | stop the pool; `--clean` also removes worktrees |

## Claude management skill (`/harness`)

Ships at `.harness/skill/SKILL.md`, installed by install.sh into the target project's
`.claude/skills/harness/SKILL.md`. Lets Claude operate the fleet conversationally instead of the
user remembering CLI invocations — a generalized version of Bonsai's `/kanban` skill.

- Triggers on `/harness` (and natural requests like "start the fleet", "what's the harness doing").
- Wraps the CLI: `harness start [--recover]`, `stop [--clean]`, `status [--watch]`,
  `attach <unit> [issue]`, and `init`.
- Teaches Claude to read the dashboard (pool up/down, per-unit state, live sessions, gated units),
  distinguish COMPLETE-vs-stuck, and the safe unstick moves (free a stale `WORKING` label, fix a
  `## Blocked by`, `--recover`).
- Read-mostly posture: operate + observe + unstick, never hand-do a unit's PLAN/PRD/IMPL work.

The plain `harness start` / `harness stop` CLI stays the simple path; the skill is the
conversational alternative. Both call the same scripts.

## Prompts

Shipped generic, de-Bonsai'd, templated. Substitution keys generalized from the current set:
`{{PROJECT}}` (display name of the unit/project), `{{DESC}}`, `{{SLUG}}` (owner/repo),
`{{OWNER}}`, `{{SPEC}}` (planned mode), `{{PRD}}`, `{{ISSUE}}`, `{{BRANCH}}`, `{{PROMISE}}`.

- `plan.md`, `prd.md` — planned mode only.
- `decompose.md` — prd + planned modes; cross-target deps use a coordination issue on a
  configured umbrella repo only in multi topology (otherwise same-repo `#N` refs only).
- `impl.md` — all modes; branches on `HARNESS_AUTONOMOUS` (autonomous = the current
  "never park, provision runtimes yourself, make the call" guidance; non-autonomous = may park
  `BLOCKED` with a documented reason).
- `review.md` — prd + planned modes.

A project overrides any prompt by dropping `prompts/<name>.local.md` in its `.harness/`.

## De-Bonsai'ing the engine

Changes to the copied-from-Bonsai code:
- `issuelib.py`: drop the `bonsai-` prefix strip (use a configurable display name derived from
  the unit id/repo); read label names + mode from env; add the `issue-only` / `prd` dispatch
  gating; `unit_complete` predicate selected by mode (issues-empty vs PRD-reviewed).
- `lib.sh`: `HARNESS_*` env; registry source selected by topology (single = synthesized
  one-row; multi = `targets.tsv`); drop hardcoded `RainBowCreation`, submodule-only assumptions,
  and the hardcoded Bonsai spec path; `seed.sh` uses configured labels.
- `seed.sh` (was `seed-repo.sh`): generalized; for single topology it seeds `HARNESS_REPO`
  in place (no submodule add); submodule wiring is multi-topology-only and opt-in.
- prompts: remove "Bonsai 2.0 sub-project", umbrella-submodule phrasing, hardcoded spec.

## Relationship to Bonsai

Bonsai's in-repo `harness/` is the origin and **stays as-is** (its own `BONSAI_*` env,
`modules.tsv`, submodule model). It does not gain a `.harness/` and does not consume the public
repo. The public `Harness` repo is developed separately (built by copying Bonsai's `harness/`
then generalizing) so it can serve any project.

## Testing

Keep the plain-bash assertion rig (`test/run.sh` + `test_*.sh`), no bats. New/ported coverage:
- claim/flock atomicity (ported).
- single-topology issue-claim drive (issue-only): dispatchable filtering, reap, complete-when-empty.
- multi-topology DAG drive (planned): dependency gating, complete-when-PRD-reviewed (ported).
- mode gating: `issue-only` emits only IMPL; `prd` emits DECOMPOSE/IMPL/REVIEW not PLAN/PRD;
  `planned` emits all.
- label auto-create is idempotent; dispatchable semantics (ready∧¬prd∧¬working∧unblocked).
- autonomy on/off: dispatch excludes `BLOCKED` only when `HARNESS_AUTONOMOUS=false`; impl prompt
  renders the correct branch.
- `harness init` writes a config that round-trips (source → expected vars).
- `install.sh` prerequisite gate: stubbed-missing `gh`/`claude`/`tmux`/`python3` each fail fast
  with guidance; unauthenticated `gh` fails; skill provisioning (superpowers + ralph-loop) is
  idempotent (no-op when present); `/harness` skill lands at `.claude/skills/harness/SKILL.md`
  and re-running install is a no-op.

GitHub is stubbed by overriding `unit_complete` / the `gh` shim, as today.

## Build location

Develop in a sibling working dir `../Harness`, `git init`, push to the public GitHub repo.
Seed it by copying Bonsai's `harness/*` as the starting point, then apply the de-Bonsai changes.

## Open assumptions (confirm at review)

1. Public repo owner/name `RainBowCreation/Harness` and the raw install URL above.
2. `claude`-only agent runner (configurable bin/flags, no other runners).
3. `.harness/` is a git clone the project gitignores (vs. a submodule) — chosen for simplest
   `git pull` updates without entangling the project's submodule config.
4. Superpowers plugin source + install mechanism. User gave `https://github.com/mattpocock/skills`;
   confirm that repo provides the required skills (`writing-plans`, `to-prd`, `to-issues`,
   `subagent-driven-development`, `test-driven-development`) and how install.sh installs it into
   Claude (plugin marketplace command vs. clone into `~/.claude/plugins`). If the named skills
   live in a different repo, that repo is the real prerequisite — the URL is a pointer, the
   skills are the contract.
5. ralph-loop source + install/enable mechanism (skill + Stop-hook). Confirm where install.sh
   gets it and how the Stop-hook is registered in the user's Claude config.

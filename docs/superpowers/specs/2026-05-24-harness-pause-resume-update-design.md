# Harness — Pause / Resume / Update / Setup Design

**Date:** 2026-05-24
**Status:** Approved (brainstorm), pending implementation plan
**Builds on:** `docs/superpowers/specs/2026-05-23-harness-standalone-extraction-design.md` (the base orchestrator, now live at `github.com/VocanicZ/Harness`).

## Goal

Add five operator capabilities to the Harness fleet, each reachable from BOTH the `bin/harness` CLI (script) and the `/harness` Claude skill:

1. **`pause`** — drain: stop claiming/dispatching new work; let in-flight agent sessions finish naturally; workers stay alive idling.
2. **`pause --force`** — graceful checkpoint: tell each live agent to commit + push its WIP branch, post its `/handoff` context as a GitHub issue comment, label the issue `agent-paused`, and exit. Resumable from ANY machine.
3. **`resume`** — clear the pause and pick work back up; if no local pool is alive (e.g. a different machine), fall back to `start --recover`. Force-paused issues are continued from their GitHub state.
4. **`update`** — fast-forward the `.harness` engine + redeploy the `/harness` skill WITHOUT re-running the wizard or re-cloning; never auto-kills a running pool.
5. **`setup`** + **setup-aware `/harness`** — a config-driven bring-up: verify prereqs, seed configured labels on all units, then start; the `/harness` skill detects state and walks the user through it.

## Core principle: portable state lives in GitHub, never on local disk

The fleet is already "stateless and resumable" — state is in GitHub + a small local run dir. These features preserve that:

- The only LOCAL state added is `$RUN_DIR/PAUSED`, a per-machine **idle signal** for that machine's worker pool. It is NEVER the cross-machine source of truth.
- All **portable** pause state lives in GitHub:
  - *Which issues are force-paused* → the `agent-paused` label (`gh issue list --label agent-paused`).
  - *The saved context* → a marked `gh issue comment` on that issue.
  - *The WIP code* → the pushed issue branch (deterministic name; also noted in the comment).
- Therefore `resume` on a different machine needs zero local state: it reads GitHub.

## Feature designs

### 1. `pause` (soft / drain)

- `pause.sh` + `bin/harness pause` → `touch "$RUN_DIR/PAUSED"`; print `FLEET: PAUSED (draining)`.
- `lib.sh`: add `PAUSE_FLAG="$RUN_DIR/PAUSED"` and `is_paused(){ [[ -f "$PAUSE_FLAG" ]]; }`.
- `pool-worker.sh::worker_tick`: check `is_paused` BEFORE `claim_next`; if paused, claim nothing and return a new rc `3` (paused-idle). `main` loop: rc `3` → `sleep "$POLL"`, stay alive (do not retire).
- `drive.sh::drive_unit`: inside the `while ! unit_complete` loop, after the reapers, `if is_paused; then log "$UNIT paused — draining (no new dispatch)"; break; fi`. This stops dispatching NEW sessions, does **not** kill live ones, and lets the worker release the claim + idle. Effective within one `POLL`.

### 2. `pause --force` (graceful checkpoint to GitHub)

`pause.sh --force`:

1. Enumerate live impl sessions across all units: `team_sessions <unit>` → names `hz-<unit>-i<issue>`; derive `<issue>` + `<repo/slug>`.
2. For each, `tmux send-keys` a **checkpoint instruction** (a fixed prompt the running agent executes):
   > Stop now. Commit ALL work-in-progress on your branch. Push the branch to origin. Run `/handoff` to capture your context, then post it as a comment on issue #N using `gh issue comment N -R <slug>`, with the FIRST line exactly `<!-- harness-handoff issue=N branch=<branch> -->`. Then `gh issue edit N -R <slug> --remove-label <WORKING> --add-label <PAUSED>`. Then output your completion promise / exit. Do NOT merge or close the issue.
3. Poll GitHub: for each in-flight issue, wait for the `$HARNESS_LABEL_PAUSED` label, up to `HARNESS_PAUSE_GRACE` seconds (default 300). The label appearing is proof the agent committed + pushed + posted the comment.
4. When all confirm → `touch "$RUN_DIR/PAUSED"`; workers idle. Print a summary (confirmed vs pending).
5. **Straggler past grace** → leave its session running, WARN, list it as pending. NEVER kill (killing would destroy the unsaved work `--force` exists to save).

### 3. `resume`

`resume.sh` + `bin/harness resume`:

- `rm -f "$RUN_DIR/PAUSED"` (clears the local idle signal; no-op on a machine that never paused).
- If any `$RUN_DIR/worker-*.pid` is alive → workers resume claiming on their next tick (they will re-dispatch the open `agent-paused` issues through the normal loop).
- Else (no local pool — e.g. a different machine) → `exec start.sh --recover`.
- Cross-machine continuation is automatic because the paused state is entirely in GitHub.

**Continuation path (how a paused issue is finished):**

- `issuelib.py` keeps `agent-paused` issues **dispatchable** (it does not filter them out of `unblocked`; they are open issues without `agent-working`). Normal dispatch emits `IMPL` for them.
- `drive.sh::spawn_impl` **detects resume**: if the issue carries `agent-paused` OR `git ls-remote --heads origin "<branch>"` returns the branch → render the new `prompts/resume.md` (continue prompt) instead of `prompts/impl.md`, passing `HANDOFF`/`BRANCH`/`ISSUE`/label keys.
- `prompts/resume.md` instructs the agent to: fetch + checkout the existing branch, read the handoff from the issue's marked comment (`gh issue view N -R <slug> --comments`), swap labels (`--remove-label <PAUSED> --add-label <WORKING>`), then continue to completion exactly like `impl.md` (TDD → PR → auto-merge → close → promise).

### 4. `update` (no reinstall)

`update.sh` + `bin/harness update [--with-skills]`:

- `git -C "$HARNESS_DIR" pull --ff-only` — fast-forward only; if diverged/dirty, abort and report (don't clobber local edits).
- Redeploy the operator skill: `mkdir -p "$PROJECT_ROOT/.claude/skills/harness" && cp "$HARNESS_DIR/skill/SKILL.md" "$PROJECT_ROOT/.claude/skills/harness/SKILL.md"`.
- `--with-skills` → re-run `ensure_skills` (sourced from `install.sh` with `HARNESS_INSTALL_NOMAIN=1`) to refresh the superpowers/ralph-loop plugins + matt-pocock skills.
- If the pool is running, WARN: a live worker already sourced the old `lib.sh`/`drive.sh`, so new engine logic applies only after a relaunch — suggest the safe sequence `pause` → wait for drain → `stop` → `start --recover`. Never auto-kills.

**`update` MUST NOT remove or alter user config — explicit guarantee (hard requirement):**

User-owned, per-project state that `update` must preserve byte-for-byte: `config`, `targets.tsv`, `prompts/*.local.md`, and the runtime dirs `run/`, `worktrees/`, `checkouts/`. These are all gitignored by the engine repo, so a clean `pull --ff-only` already leaves them untouched — but `update.sh` makes this a guarantee rather than an assumption:

1. **Snapshot before:** copy the existing `config` + `targets.tsv` (if present) to a temp backup (e.g. `mktemp -d`).
2. **Pull:** `git -C "$HARNESS_DIR" pull --ff-only` ONLY. `update.sh` NEVER runs `git clean`, `git reset --hard`, `git checkout -f`, or `git stash drop` — no command that can discard untracked/ignored files. If the pull fails (diverged, or an incoming tracked file would clobber the untracked `config`), abort with a clear message and leave everything as-is.
3. **Verify/restore after:** if `config` or `targets.tsv` is missing or changed after the pull, restore it from the snapshot and warn. On success, confirm "config preserved".
4. The temp snapshot is removed at the end (only after a successful verify).

This means even a misbehaving upstream (e.g. a future engine commit that accidentally tracks a `config`) cannot destroy the user's settings: git would refuse to overwrite the untracked file (pull aborts), and if anything did change it, the snapshot restores it.

### 5. `setup` + setup-aware `/harness`

`setup.sh` + `bin/harness setup` (deterministic, idempotent, no start):

- Verify prereqs: `command -v tmux`, `command -v gh` + `gh auth status`, `command -v claude`.
- Seed configured labels on ALL units: loop `all_units` → `seed_if_needed <unit>` (single = `HARNESS_REPO`; multi = each `targets.tsv` row).

`skill/SKILL.md` rewritten **setup-aware** (single entry point):

- On `/harness`: if `.harness/config` is missing → run `harness init`. Then, reading config: run `harness setup` (verify prereqs + seed), confirm with the user, then `harness start`. If already running → operate / show the dashboard. Prompt the user before each network/start action.
- Add `pause`, `pause --force`, `resume`, `update` to the command reference, plus a short "Pausing & resuming (incl. across machines)" section.

## New configuration (in `lib.sh` defaults + `init.sh` write-block where user-relevant)

| Key | Default | Meaning |
|---|---|---|
| `HARNESS_LABEL_PAUSED` | `agent-paused` | Marks an issue force-paused (checkpointed to GitHub, awaiting resume). |
| `HARNESS_PAUSE_GRACE` | `300` | Seconds `pause --force` waits for each agent to confirm its checkpoint. |

(No `HARNESS_HANDOFF_DIR` — context goes in an issue comment, not a committed file.)

## Complete file-impact table (so nothing is missed)

**New files:**

| File | Purpose |
|---|---|
| `pause.sh` | soft pause + `--force` checkpoint orchestration |
| `resume.sh` | clear pause; resume or `start --recover` |
| `update.sh` | ff-pull engine + redeploy skill (+ `--with-skills`) |
| `setup.sh` | verify prereqs + seed all units' labels |
| `prompts/resume.md` | continue-a-paused-issue prompt |
| `test/test_pause.sh` | soft drain gates claim; force path injects checkpoint, polls label, never kills straggler (stub tmux+gh) |
| `test/test_update.sh` | ff-pull + redeploy mechanics; **a pre-existing `config` + `targets.tsv` with custom values are byte-identical after update** (the config-safety guarantee); diverged/dirty aborts without touching config; `update.sh` contains no `git clean`/`reset --hard`/`checkout -f` (assert by grep) (stub git) |
| `test/test_setup.sh` | seeds all units idempotently (stub gh) |
| `test/test_resume.sh` | `spawn_impl` resume-detection renders `resume.md` for an `agent-paused`/existing-branch issue (stub git+gh) |

**Modified files:**

| File | Change |
|---|---|
| `lib.sh` | add `PAUSE_FLAG`, `is_paused`; add `HARNESS_LABEL_PAUSED`, `HARNESS_PAUSE_GRACE` defaults + export `HARNESS_LABEL_PAUSED`. |
| `pool-worker.sh` | `worker_tick` checks `is_paused` → rc `3`; `main` handles rc `3` (idle, stay alive). |
| `drive.sh` | `drive_unit` drain-break on `is_paused`; `spawn_impl` resume-detection → render `resume.md` with `HANDOFF`/branch/label keys; pass `LABEL_PAUSED`/`LABEL_WORKING` render keys. |
| `issuelib.py` | ensure `agent-paused` issues stay dispatchable (don't exclude from `unblocked`); `status` line shows paused count. |
| `seed.sh` | create the `agent-paused` label. |
| `status.sh` | render `FLEET: PAUSED` when the flag is present; show count of `agent-paused` issues per unit. |
| `start.sh` | clear `$RUN_DIR/PAUSED` on launch (starting ≠ paused). |
| `stop.sh` | clear `$RUN_DIR/PAUSED` on stop. |
| `bin/harness` | add subcommands `pause` (passes `--force`), `resume`, `update`, `setup`; update usage. |
| `init.sh` | write `HARNESS_LABEL_PAUSED` (+ optionally `HARNESS_PAUSE_GRACE`) into config so it round-trips and is overridable. |
| `install.sh` | `ensure_skills` unchanged; ensure `update.sh`'s `--with-skills` can source it (`HARNESS_INSTALL_NOMAIN=1`); no behavior change to first install. |
| `skill/SKILL.md` | rewrite setup-aware; document `pause`/`pause --force`/`resume`/`update`/`setup` + cross-machine resume. |
| `README.md` | document the 5 new commands, the `agent-paused`/grace config, and the cross-machine pause/resume workflow. |
| `prompts/impl.md` | add a one-line "if a checkpoint is requested, commit+push+`/handoff`-comment+label `agent-paused`, then stop" note so a fresh agent knows the checkpoint protocol. |
| `test/test_cli.sh` | assert the new subcommands are dispatched/usage lists them. |
| `test/test_status.sh` | assert PAUSED rendering when the flag exists. |
| `test/test_seed.sh` | assert the `agent-paused` label is created. |
| `test/run.sh` | no change (auto-discovers new `test_*.sh`/`test_*.py`). |

## Edge cases & decisions (locked)

- **Straggler on `pause --force`:** never killed; left running + warned. The pool is "paused" for claiming even if one session is still draining.
- **`.harness/` is gitignored in the user project** → handoff context must NOT be a committed file under `.harness/`; it lives in a GitHub issue comment. (This is why the earlier committed-file approach was dropped.)
- **Branch naming is deterministic** (drive.sh's existing `{{BRANCH}}` scheme per issue), so resume reconstructs it without parsing; the comment also records it for humans.
- **Double-dispatch safety:** during `pause --force` the original session still holds `agent-working` until it swaps to `agent-paused`; the grace-poll waits for that swap, so the issue is never dispatched twice. After resume, exactly one worker re-dispatches it via the normal claim/dispatch path.
- **`pause --force` then plain `resume`:** works; the open `agent-paused` issues are re-dispatched and continued via `resume.md`.
- **`stop` after `pause --force`:** allowed; `stop` kills any still-draining sessions and clears the flag. Their GitHub checkpoint (if completed) still lets a later `start --recover` continue them.
- **Soft `pause` is per-machine** (local idle flag); `pause --force` is global/portable (GitHub). A machine that only ran soft `pause` has nothing for another machine to resume — that's intended (soft pause keeps sessions local and running).
- **`update` never destroys user config:** hard requirement (see Feature 4). `update.sh` snapshots `config`/`targets.tsv` before the pull, runs `pull --ff-only` only (never `clean`/`reset --hard`/`checkout -f`), and restores from the snapshot if anything changed. A diverged or clobbering pull aborts cleanly, leaving config intact. Covered by an explicit byte-identical assertion in `test/test_update.sh`.

## Testing strategy

All tests stay offline (stub `gh`, `git`, `tmux`). Follow TDD. Full `bash test/run.sh` green after every task, run from the real (space-containing) repo path with no symlink. Reuse the existing `helpers.sh` rig and the space-safe quoting conventions.

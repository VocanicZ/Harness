# Harness reference

Full reference for operators. Start with the [README](../README.md).

## Agent CLIs

### Supported agent CLIs

Pick one with `HARNESS_CLI`. A CLI is listed only when every row below passes for it
(`test/test_cli_matrix.sh`, against captures from the real CLI). Per-CLI facts and sources:
[cli-capabilities.md](cli-capabilities.md).

| feature | what it proves | `claude` | `agy` | `codex` | `copilot` | `opencode` | `hermes` | `openclaw` |
|---|---|---|---|---|---|---|---|---|
| verified on | `<cli> --version` of the captured fixtures | 2.1.311 (Claude Code), 2026-10-27 | 1.4.8, 2026-10-27 | codex-cli 0.154.0, 2026-10-27 | GitHub Copilot CLI 1.0.105, 2026-10-28 | 1.19.5, 2026-10-28 | Hermes Agent v0.22.5 (2026.9.24) · stable · local bf0203a794a0, 2026-10-28 | OpenClaw 2026.10.8 (dc2523e), 2026-10-28 |
| `fixtures-recorded` | Panes, transcript and usage samples captured from the real CLI (`test/fixtures/cli/<cli>/`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `launch-bootstrap-prompt` | The launch line carries the fixed bootstrap prompt | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `launch-no-task-text` | The task text stays out of argv (#213) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `launch-model` | A lane's model, pinned by the worktree hook (`.harness-lane`), reaches the launch `launch_agent` types | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `launch-effort-once` | That lane's effort replaces the configured one in the typed launch, once | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `session-id` | The session id Harness resolves after a launch finds the transcript the CLI wrote (claude: set at launch by `--session-id`; agy: read from `cache/last_conversations.json`, counted only when that conversation started since the launch; codex: the `session_meta` id of the newest rollout started in the worktree since the launch; copilot: set at launch by `--session-id=`; opencode: the newest top-level session of the worktree in `opencode.db` since the launch; hermes: the session titled by `-c <uuid> --create-if-missing` in the lane profile's `state.db`, the first of its compression chain; openclaw: the launch's own id, naming the lane's `runs/<id>.jsonl` of `agent exec` envelopes) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `idle-is-prompt` | An idle pane is read as the input prompt | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `idle-is-not-busy` | An idle pane is not read as a running turn | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `busy-is-busy` | Every captured running turn is read as busy (claude: the spinner, which Harness's status line leaves without `esc to interrupt`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `trust-dialog-is-not-prompt` | The workspace-trust dialog is never mistaken for the prompt | ✓ | ✓ | ✓ | ✓ | n/a: OpenCode 1.x has no workspace-trust gate: it loads a project config and its plugins without asking | n/a: Hermes has no workspace-trust gate on running a folder: only the skills a worktree carries are gated, by skills.trusted_project_dirs, which cli_trust writes into the lane config (skill-project.txt) | n/a: `agent exec` has no workspace-trust gate: the worktree is the --cwd of each turn, which scopes its file tools |
| `transient-stalls` | A transient API error at the prompt is a #115 stall | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `idle-never-stalls` | A healthy idle pane is never a stall | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `busy-never-stalls` | A running turn is never a stall | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `limit-parks` | A usage-limit message at the prompt parks the lane (#120) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `transient-is-not-limit` | A transient error is not a limit park | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `trust-pre-accepted` | Workspace trust is pre-accepted (claude: `.claude.json` of every account; agy: `trustedWorkspaces` in `settings.json`; codex: `[projects."<dir>"]` in `config.toml`; copilot: `trustedFolders` in `config.json`; hermes: no gate on running, the worktree's own skills trusted in `skills.trusted_project_dirs` of the lane's config). A fresh worktree reads as untrusted until `cli_trust`; a CLI with no gate, whose `cli_trusted` holds before it, is n/a | ✓ | ✓ | ✓ | ✓ | n/a: OpenCode 1.x has no workspace-trust gate: it loads a project config and its plugins without asking | ✓ | n/a: `agent exec` has no workspace-trust gate: the worktree is the --cwd of each turn, which scopes its file tools |
| `bypass-covers-subagents` | After a launch the session reads as bypassed on the line typed, and the real CLI's capture of a sub-agent run under that bypass shows the sub-agent's shell call ran with no approval prompt (agy: `--dangerously-skip-permissions`, `test/fixtures/cli/agy/bypass-subagent.jsonl`, against `permission.txt` without it; codex: `--dangerously-bypass-approvals-and-sandbox`, `test/fixtures/cli/codex/bypass-subagent.jsonl`; copilot: `--yolo`, `test/fixtures/cli/copilot/bypass-subagent.jsonl`; opencode: `--auto`, which answers a sub-agent's asks too, `test/fixtures/cli/opencode/bypass-subagent.db`, against `busy-permission.txt` without it, plus `question: deny` in the lane's inline config; hermes: `--yolo` and `approvals.mode: off` in the lane profile's config, which a `delegate_task` child runs under, `test/fixtures/cli/hermes/bypass-subagent.db`, plus the clarify toolset off). claude: no capture; the cell checks only `permissions.defaultMode=bypassPermissions` in the worktree's `settings.local.json`, and that sub-agents inherit the parent's `bypassPermissions` is Claude Code's documented behavior (https://code.claude.com/docs/en/sub-agents#permission-modes: "When the main conversation is in `bypassPermissions` … the subagent runs in that same mode") | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | n/a: `agent exec` turns run no sub-agents: `sessions_spawn` needs the Gateway, and both spawns a lane tried failed `published reply runtime missing for main` (bypass-subagent.txt) |
| `done-signal` | The goal loop's end is seen (the loop state file is gone) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `loop-mode` | The goal loop runs: the CLI's Stop hook (`ralph-loop` / `harness-ralph`, a plugin on agy and on codex) re-feeds the task until the turn outputs the promise, then ends the loop (copilot: Harness drives it — the watchdog reads the reply from the transcript once the pane is idle and types the next iteration, since `agentStop` gives up after 8 blocks; opencode: the `opencode-ralph.js` plugin each lane loads re-prompts on `session.idle`; hermes: Harness drives it, reading the reply from the lane's `state.db`, which has no Stop hook Harness can block) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `transcripts-found` | The session's transcripts are found (agy: `conversations/<id>.db`; codex: the session's rollout and its sub-agents'; copilot: `session-state/<id>/events.jsonl`; opencode: the session and its sub-agents' child sessions in `opencode.db`; hermes: the session and its `delegate_task` children in the lane's `state.db`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `usage-from-transcript` | Per-model token usage is read from them (agy: protobuf rows, decoded; codex: `token_count` events; copilot: `session.usage_record` events; opencode: assistant messages' `tokens`; hermes: `session_model_usage` rows) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `stats-launch-model-effort` | `harness stats` launch events carry the lane's model and effort, read by the CLI's adapter off its own launch line and lane config (`cli_model_effort`; codex: `-m`, `-c model_reasoning_effort=`; opencode: `-m`, the inline config's build `variant`; hermes: the lane profile's `config.yaml`; openclaw: `--model`, `--thinking`) (#307) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `stats-session-end-usage` | `harness stats` session_end events carry that usage (#185) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `usage-windows` | Usage windows are read for #194 checkpoints (claude: status line; agy: `agy -p /usage`; codex: the newest rollout's `rate_limits`; copilot: the newest session's `quotaSnapshots`; hermes: `hermes usage --json`; openclaw: `openclaw status --usage --json`) | ✓ | ✓ | ✓ | ✓ | n/a: OpenCode 1.x has no quota meter: a limit shows only as its error text at the prompt, which parks the lane (limit-parks) | ✓ | ✓ |
| `checkpoint-skill` | `pause --force` types the checkpoint into a live lane, naming the handoff skill as the CLI invokes skills (`/handoff`; codex: `$handoff`; opencode, hermes and openclaw: `handoff`, loaded by the skill tool), and the lane's prompt (`{{skill:handoff}}`) names it the same way | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `handoff-skill-installed` | Harness ships that handoff skill (`skill/handoff`): `harness setup` reports it missing, and `--install` and `install.sh` put it where the CLI loads user skills from (claude, opencode, hermes, openclaw: `~/.claude/skills`, an external skill dir in a hermes or openclaw lane's config; codex: `~/.agents/skills`; agy: `~/.gemini/config/skills`; copilot: `~/.copilot/skills`), never over the operator's own | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `prompt-skills-installed` | Every skill a lane prompt names — each `{{skill:<name>}}` in `prompts/*.md` (`to-prd`, `to-issues`, `writing-plans`, `caveman`, `subagent-task-tree`, `handoff`, `rtdd`), the only way a prompt names one — renders as the CLI invokes skills, and `harness setup` lists it for the CLI: missing until `--install` or `install.sh` puts Harness's `skill/<name>` (its own, or vendored from upstream with its `LICENSE`) where the CLI loads user skills from, never over the operator's own; rtdd's skill is rtdd's own (`rtdd skill install`), a warning when absent | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `pause-force-resume-other-host` | That checkpoint, then another host with none of the first one's local state resumes the issue from GitHub (label, pushed branch, handoff comment) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `inject-sessions` | `/harness-issue`, `/harness-prd` and `/harness-plan` (`inject.sh`) launch their injector through the CLI | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `bug-lane-triage-fix` | The bug lane launches its triage and then its fix session through the CLI | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `review-gauntlet` | The PRD review, with its gauntlet round, launches through the CLI, and its prompt starts the review sub-agent and the fresh-context gauntlet critic with a mechanism the CLI can run (`cli_subagent`): the CLI's own sub-agent tool where `bypass-covers-subagents` shows its sub-agents run; openclaw, which cannot spawn one, gets Harness's substitute — a separate `openclaw agent exec` run on the lane config with a cwd of the critic's dir, a new empty `--state-dir` and the brief from a file, a fresh session that sees none of the lane's context — and the cell runs that exact command, grounded in a real lane's critic run and answer (`test/fixtures/cli/openclaw/subagent-critic.txt`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `supervisor-frozen-session` | `harness supervise` (#180) nudges the CLI's quiet idle pane and leaves its limit pane parked | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `supervisor-skips-trust-dialog` | `harness supervise` (#180) nudges the CLI's quiet idle pane and never types into its quiet trust dialog | ✓ | ✓ | ✓ | ✓ | n/a: OpenCode 1.x has no workspace-trust gate: it loads a project config and its plugins without asking | n/a: Hermes has no workspace-trust gate on running a folder: only the skills a worktree carries are gated, by skills.trusted_project_dirs, which cli_trust writes into the lane config (skill-project.txt) | n/a: `agent exec` has no workspace-trust gate: the worktree is the --cwd of each turn, which scopes its file tools |
| `rtdd-event-context` | `rtdd` run from a lane's turn gets the session's context through the CLI, and `harness stats` joins the call to the session (#186) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `send-and-kill` | Nudges and checkpoints are delivered; a session is ended | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `prereqs-named` | `harness setup` names the missing binary and plugins the CLI needs, and `--install` installs them: the binary by the command it named, the vendor's non-interactive install (an npm package or a curl release script), and the plugins through the binary (copilot needs only its binary; opencode its 1.x binary; hermes its binary) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `init-wizard-choice` | `harness init` writes the CLI chosen, and a fleet loading that config drives it | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Per-CLI setup (`harness setup --install` handles what it can):

- **`claude`** — default. Needs the `superpowers` and `ralph-loop` plugins (`install.sh` adds them).
- **`agy`** — needs the `harness-ralph` plugin (`plugins/ralph-loop`) for its goal loop; without it a
  lane runs one turn and stops.
- **`codex`** — needs `harness-ralph@harness` from the local marketplace `plugins/codex`.
- **`copilot`** — `npm install -g @github/copilot`, signed in (`copilot login`, `GH_TOKEN`, or the
  GitHub CLI's login). Harness drives its goal loop itself.
- **`opencode`** — OpenCode 1.x only (`npm install -g opencode-ai@1`); runs on OpenCode Zen's free
  models with no account. Its goal loop is the `scripts/cli/opencode-ralph.js` plugin, loaded inline.
- **`hermes`** — Hermes Agent's installer, with a login and model set in `~/.hermes`
  (`HARNESS_HERMES_HOME`). Each lane gets its own profile seeded from it. Harness drives its goal loop.
- **`openclaw`** — `npm install -g openclaw@latest --allow-scripts=openclaw` (Node ≥ 24.22.1), signed in
  with a default model (`HARNESS_OPENCLAW_CONFIG`). Each lane runs headless `openclaw agent exec` turns
  through `scripts/cli/openclaw-loop.sh`; a turn may run `HARNESS_OPENCLAW_TIMEOUT` seconds (default 14400).

## Pipeline modes

`HARNESS_MODE` picks which stages run. Full pipeline: `PLAN → PRD → DECOMPOSE → IMPL (parallel) → REVIEW → COMPLETE`.

| Mode | Entry stage | Orchestration allowed | PRD authored by | COMPLETE when |
|------|-------------|----------------------|-----------------|---------------|
| `issue-only` | IMPL | none (IMPL only) | — | all `ready-for-agent` issues closed and none in-flight |
| `prd` | DECOMPOSE | DECOMPOSE, REVIEW | human (creates one or more `prd`-labelled issues) | every PRD issue closed and labelled `reviewed`, **and** no `ready-for-agent` issue still open |
| `planned` | PLAN | PLAN, PRD, DECOMPOSE, REVIEW | agent (from `HARNESS_SPEC`) | every PRD issue closed and labelled `reviewed`, **and** no `ready-for-agent` issue still open |

A closed PRD is not enough: any open `ready-for-agent` issue keeps the unit incomplete, even one no
lane can claim (an unclosed `## Blocked by`, or `agent-blocked` on a non-autonomous fleet). The unit
logs one banner naming what is outstanding. In `multi` topology it also holds every dependent unit.

In `issue-only` mode a unit with no `ready-for-agent` issue has nothing to dispatch and idles: label at
least one.

### Several PRDs per unit

A unit may hold several PRD issues at once. PRDs with no `## Blocked by` section run in
**parallel**: their children are dispatched as capacity allows, lowest PRD number first, spilling
into the next PRD when one runs dry. To sequence PRDs, declare in the later one:

```
## Blocked by
#41
```

- **Parent attribution.** Children belong to their PRD through a `## Parent` section (also `## Parent #N`,
  `Parent: #N`, and the legacy `Part of #N`). An open child holds its PRD's review and close whatever its
  labels; an unlabelled one is labelled `ready-for-agent`.
- **Unparented issues** (an injected task, say) dispatch first and gate no PRD's review.
- **Claim order** within each bucket: resumable first (a remote `issue/<n>` branch exists, or
  `agent-paused`), then oldest first.
- Each PRD gets its own orchestration lane (`-p<n>` session suffix, own worktree), so two PRDs can
  decompose or review at once.

The unit is COMPLETE only when every PRD is closed and no unparented issue is still open.

## Topologies

| Topology | Description |
|----------|-------------|
| `single` | One target repo (`HARNESS_REPO`). The pool drives that one unit; up to `HARNESS_CAP` concurrent impl sessions run inside it. Default. |
| `multi` | Multiple repos in a dependency DAG described by `targets.tsv` (`id → repo → deps → desc`). A target unblocks its dependents when it reaches COMPLETE. Peak concurrency = `POOL × CAP`. |

## Configuration

Harness reads `.harness/config` (sourceable `KEY=VALUE`). Environment variables win over the file:
`HARNESS_POOL=5 harness start`.

| Key | Default | Meaning |
|-----|---------|---------|
| `HARNESS_MODE` | `issue-only` | Pipeline mode: `issue-only`, `prd`, or `planned` |
| `HARNESS_TOPOLOGY` | `single` | `single` or `multi` |
| `HARNESS_OWNER` | _(empty)_ | GitHub owner/org (used to expand bare repo names) |
| `HARNESS_REPO` | _(empty)_ | Target repo for single topology (`owner/repo`) |
| `HARNESS_SPEC` | _(empty)_ | Path to the umbrella spec; `planned` mode only |
| `HARNESS_AUTONOMOUS` | `true` | `true` = agents never park; `false` = agents may apply `agent-blocked` for human help |
| `HARNESS_SESSION_BACKEND` | `tmux` | What each lane's agent session runs in: `tmux` = a detached tmux session per lane on the host's tmux server (attach with `harness attach`); `headless` = plain background processes, no multiplexer — accepted, but it starts no lane until the headless backend lands. Any other value is refused by `harness init` and `harness start`, and `harness doctor` reports it. `harness init` writes it; one backend per file under `scripts/session/`, and every session operation the engine performs goes through that seam |
| `HARNESS_CLI` | `claude` | Agent CLI to drive: any CLI in [Supported agent CLIs](#supported-agent-clis), one adapter per CLI under `scripts/cli/` |
| `HARNESS_CLAUDE_BIN` | `claude` | Command line that runs `claude` when `HARNESS_CLI=claude`: an executable name or path, or a command line such as `env CLAUDE_CONFIG_DIR=~/.claude-switch/accounts/main claude` (pins the account even when tmux drops `CLAUDE_CONFIG_DIR`). The launch runs it whole; only its executable (the first word that is not `env`, an `env` option or a `NAME=value`) is checked for on PATH. Words split on whitespace, so a value containing a space is not supported |
| `HARNESS_AGY_BIN` | `agy` | Executable path for `agy` when `HARNESS_CLI=agy`; a command line like `HARNESS_CLAUDE_BIN`'s |
| `HARNESS_AGY_FLAGS` | `--dangerously-skip-permissions --effort high` | Flags passed to `agy` CLI on launch |
| `HARNESS_CLAUDE_FLAGS` | `--dangerously-skip-permissions --effort high` | Flags passed to `claude` on launch; a lane's own model and effort (`.harness-lane`) replace the ones they carry |
| `HARNESS_AGY_HOME` | `~/.gemini/antigravity-cli` | agy's state dir: its `settings.json` (workspace trust), conversations and session map |
| `HARNESS_AGY_USAGE_TTL` | `120` | Seconds one `agy -p /usage` answer is reused by every worker |
| `HARNESS_AGY_USER_SKILLS` | `~/.gemini/config/skills` | Where agy loads user skills from: `harness setup --install` and `install.sh` put the lane prompts' skills there |
| `HARNESS_CODEX_BIN` | `codex` | Executable path for `codex` when `HARNESS_CLI=codex`; a command line like `HARNESS_CLAUDE_BIN`'s |
| `HARNESS_CODEX_FLAGS` | `--no-alt-screen --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -c model_reasoning_effort=high` | Flags passed to `codex` on launch |
| `HARNESS_CODEX_USER_SKILLS` | `~/.agents/skills` | Where codex loads user skills from (as `HARNESS_AGY_USER_SKILLS`) |
| `HARNESS_COPILOT_BIN` | `copilot` | Executable path for `copilot` when `HARNESS_CLI=copilot`; a command line like `HARNESS_CLAUDE_BIN`'s |
| `HARNESS_COPILOT_FLAGS` | `--yolo --no-ask-user --no-auto-update` | Flags passed to `copilot` on launch |
| `HARNESS_COPILOT_USER_SKILLS` | `$COPILOT_HOME/skills` (`~/.copilot/skills`) | Where copilot loads user skills from (as `HARNESS_AGY_USER_SKILLS`) |
| `HARNESS_OPENCODE_BIN` | `opencode` | Executable path for `opencode` (OpenCode 1.x) when `HARNESS_CLI=opencode`; a command line like `HARNESS_CLAUDE_BIN`'s |
| `HARNESS_OPENCODE_FLAGS` | `--auto` | Flags passed to `opencode` on launch |
| `HARNESS_HERMES_BIN` | `hermes` | Executable path for `hermes` when `HARNESS_CLI=hermes`; a command line like `HARNESS_CLAUDE_BIN`'s |
| `HARNESS_HERMES_HOME` | `~/.hermes` | The operator's Hermes home (login, `config.yaml`, skills) each lane's own profile is seeded from |
| `HARNESS_HERMES_USAGE_TTL` | `120` | Seconds one `hermes usage --json` answer is reused by every worker |
| `HARNESS_OPENCLAW_BIN` | `openclaw` | Executable path for `openclaw` when `HARNESS_CLI=openclaw`; a command line like `HARNESS_CLAUDE_BIN`'s |
| `HARNESS_OPENCLAW_CONFIG` | `$OPENCLAW_CONFIG_PATH`, else `${OPENCLAW_STATE_DIR:-~/.openclaw}/openclaw.json` | The operator's OpenClaw config (login, default model) each lane's own config includes |
| `HARNESS_OPENCLAW_TIMEOUT` | `14400` | Seconds one `openclaw agent exec` turn of a lane may run |
| `HARNESS_OPENCLAW_SUBAGENT_TIMEOUT` | `3600` | Seconds one review or gauntlet sub-agent run (a fresh `openclaw agent exec`) may take |
| `HARNESS_OPENCLAW_USAGE_TTL` | `120` | Seconds one `openclaw status --usage --json` answer is reused by every worker |
| `HARNESS_OPENCLAW_AGENTS_SKILLS` | `~/.agents/skills` | A user skill dir an openclaw lane's config adds as an extra skill dir, after `HARNESS_USER_SKILLS` |
| `HARNESS_USER_SKILLS` | `~/.claude/skills` | Where Harness installs user skills for claude and opencode, and the skill dir a hermes or openclaw lane gets as an external one |
| `HARNESS_MARKETPLACE` / `HARNESS_MARKETPLACE_NAME` | `anthropics/claude-plugins-official` / `claude-plugins-official` | The plugin marketplace `harness setup --install` adds to `claude`, and its name, for the `ralph-loop` and `superpowers` plugins |
| `HARNESS_INSTALL_CLI_BIN` | `1` | `1` = `harness setup --install` installs a missing agent CLI binary by its vendor's non-interactive install (an npm package or a curl release script) when `npm` / `curl` is on `PATH`; signing in stays yours. `0` = only name the command |
| `HARNESS_POOL` | `3` | Number of pool workers (unit-concurrency cap) |
| `HARNESS_CAP` | `3` | Max concurrent agent sessions per unit |
| `HARNESS_POLL` | `300` | Resident-pool poll interval in seconds (idle/steady-state cadence) |
| `HARNESS_PRIORITY_POLL` | `60` | Fast poll interval for the priority bug lane |
| `HARNESS_POOL_TAKES_BUGS` | `1` | `1` = a pool worker with no dispatchable impl work takes the oldest open `bug`/`bug-triaged` issue in its unit's repo while the priority lane is busy (or not running), through the lane's own triage→fix flow; the lane keeps first pick whenever it is free, and the shared bug claim means the two never take the same bug. `0` = bugs wait for the priority lane |
| `HARNESS_SESS_PREFIX` | derived from the project dir at `init` (`hz` for pre-existing configs) | tmux session name prefix — **must be unique per fleet on a host**; a shared prefix makes `harness stop` in one project kill another's agents. See [Fleet prefixes](#fleet-prefixes) |
| `HARNESS_PREFIX_COLLISION` | `refuse` | `refuse` \| `warn` — what `harness start` does when another fleet already owns this session prefix: `refuse` (default) dies, `warn` prints and continues |
| `HARNESS_LABEL_READY` | `ready-for-agent` | Label that marks an issue dispatchable |
| `HARNESS_LABEL_PRD` | `prd` | Label that marks the PRD tracking issue |
| `HARNESS_LABEL_WORKING` | `agent-working` | Label applied while a session owns an issue |
| `HARNESS_LABEL_BLOCKED` | `agent-blocked` | Label applied to issues parked for human help (autonomous=false) |
| `HARNESS_LABEL_REVIEWED` | `reviewed` | Label applied to the PRD issue after review passes |
| `HARNESS_LABEL_COORD` | `coordination` | Optional, human-facing tracking label only. Cross-unit deps are filed as real cross-repo `owner/repo#N` refs in `## Blocked by` (see `prompts/decompose.md`); this label is **not** the work path. |
| `HARNESS_AUTHOR_ALLOWLIST` | _(empty)_ | Comma-separated GitHub logins permitted to author claimable issues. Empty = self-only (secure default); `*` = allow any author. See [Issue-author allowlist](#issue-author-allowlist) |
| `HARNESS_USE_POLLER` | `1` | Host poller, **on by default** (#182): this fleet reads shared host snapshots instead of polling GitHub itself. Empty also means on (configs written before #182 carry an empty value); `0` = direct-`gh` polling. See [Host poller](#host-poller) |
| `HARNESS_WORKTREE_HOOK` | _(empty)_ | Path to a project script run once in every freshly created worktree (and every multi-topology clone), with `cwd` = that worktree and its path as `$1`. Absolute, or relative to the project root. Empty = no-op. See [Provisioning a fresh worktree](#provisioning-a-fresh-worktree) |
| `HARNESS_GAUNTLET_ROUNDS` | `3` | Gauntlet review: rounds allowed before the reviewer concedes and signs off. Only applies to a PRD carrying a `## Quality bar` — see [Gauntlet review](#gauntlet-review) |
| `HARNESS_SECURITY_AUDIT` | `0` | `1` = every PRD review (`prd`/`planned` modes) runs a security audit after the acceptance criteria pass; findings of medium severity or above are filed as gap issues and hold the sign-off. `0` = off. See [Security audit review](#security-audit-review) |
| `HARNESS_SECURITY_AUDIT_ROUNDS` | `2` | Security audit: rounds with filed findings allowed before the reviewer concedes and moves on |
| `HARNESS_CI_GATE` | `0` | Off by default — Harness projects run [no GitHub CI](#no-github-ci--the-gate-is-local). `1` = hold new dispatch while the default branch's own GitHub CI is red (live sessions drain; the bug lane is never gated), for a project that opted back into Actions. Fail-open — no Actions, an in-flight run, or a `gh` outage all dispatch normally |
| `HARNESS_SWARM` | `auto` | `auto` = when [swarm](https://github.com/VocanicZ/swarm) is on `PATH`, lanes run their full-suite verification (the FULL-SUITE BAR baseline + final run, review's suite run) as a swarm job; `off` = always local. No swarm installed → exactly the local behaviour. See [Offloading tests to swarm](#offloading-tests-to-swarm) |
| `HARNESS_SEED_CI` | `0` | `1` = when seeding a `multi`-topology unit repo, commit a language-autodetect `.github/workflows/ci.yml` and set best-effort branch protection requiring its `test` check. `0` = neither — the engine never adds a workflow to your repos unless asked (labels and auto-merge are still set). `1` is an explicit opt-in to GitHub CI, so it also skips `HARNESS_DISABLE_CI` |
| `HARNESS_DISABLE_CI` | `1` | When `harness init` / `harness setup` seed a repo, `gh workflow disable` its existing GitHub Actions and log each one. `1` = test-CI only — a workflow whose name or file says `release`, `deploy`, `publish`, `pages` or `cd` keeps running; `all` = release and deploy too; `0` = touch nothing (the opt-out). See [No GitHub CI](#no-github-ci--the-gate-is-local) |
| `HARNESS_USAGE_CHECKPOINT_PCT` | `90` | At this % of any usage window (Claude Code's 5-hour and weekly limits), checkpoint every live session to GitHub and hold new claims until the window resets. See [Usage-limit checkpoints](#usage-limit-checkpoints) |
| `HARNESS_ONE_USD_PER_PCT` | _(empty)_ | `harness forecast`'s fallback $ per 1% of a usage window, for an account/window with no calibration yet (no usable `usage_reading` pair). Read from the environment, else this config. Empty = `n/a`. See [Cost forecast](#cost-forecast) |
| `HARNESS_ONE_STOP_PCT` | `98` | `/harness-one`'s gate: recommend APPROVE only when every usage window's `now% + p80% + HARNESS_ONE_RESERVE_PCT` stays at or under this %. See [One issue at a time](#one-issue-at-a-time-harness-one) |
| `HARNESS_ONE_RESERVE_PCT` | `2` | % of a window the gate holds back for the checkpoint (commit, push, handoff) when the budget runs out |
| `HARNESS_ONE_STALE_MIN` | `30` | A usage reading older than this many minutes, or of unknown age, is stale… |
| `HARNESS_ONE_STALE_PAD_PCT` | `3` | …and the gate adds this many points to it |
| `HARNESS_ONE_LEASE_MIN` | `240` | Minutes a `/harness-one` claim keeps the pool's reapers and lock sweeps off its issue after the last `harness one start`/`phase`; past it the session counts as dead and the pool reaps the issue like a dead lane |
| `HARNESS_USAGE_CMD` | _(empty)_ | Your own usage source, for any CLI: a command printing `<account>\t<window>\t<pct>\t<resets_at epoch>` lines. Overrides the CLI adapter |
| `HARNESS_GH_RATE_GUARD` | `1` | `1` = on a GitHub rate limit, sleep the dispatchers until the token's reset instead of retrying every poll, and stop claiming new work when the budget runs low. `0` = off. See [GitHub rate limits](#github-rate-limits) |
| `HARNESS_GH_BUDGET_PCT` | `20` | Below this % of the token's `core` or `graphql` budget, claim nothing new and poll at half rate until the reset, leaving the rest to live agents |
| `HARNESS_GH_RATE_TTL` | `60` | Seconds one `gh api rate_limit` probe is reused by every worker on the host |
| `HARNESS_ORPHAN_LOCK_MIN` | `20` | Minutes an open `agent-working` issue may sit with no live session (impl, orch, or bug lane) and no worktree before the pool worker unlocks it with a comment. A reap whose unlock `gh` refused (an outage) is queued instead and retried every poll until it lands |
| `HARNESS_BLOCKED_BACKOFF_MIN` | `0` | An autonomous fleet ends a lane that labels its issue `agent-blocked` and parks the issue: it is not re-dispatched until someone comments on it or edits its labels. This many minutes after the park it is retried even unchanged; `0` = only on a change. A non-autonomous fleet never dispatches `agent-blocked` work |
| `HARNESS_USAGE_STATUSLINE` | `1` | `1` = set the status line of each Harness-owned Claude Code worktree to `scripts/usage-statusline.sh`, which reports the usage windows (an existing `statusLine` there is kept). `0` = off; Claude usage is then unavailable unless `HARNESS_USAGE_CMD` is set |
| `HARNESS_LABEL_PAUSED` | `agent-paused` | Label on an issue checkpointed by `pause --force` or a usage-limit checkpoint |
| `HARNESS_PAUSE_GRACE` | `300` | Seconds `pause --force` waits for agents to checkpoint |

### Autonomy

| Setting | Behaviour |
|---------|-----------|
| `HARNESS_AUTONOMOUS=true` (default) | Agents are instructed never to apply `agent-blocked`. Every obstacle is resolved by the agent. Stale `agent-working` labels are reaped automatically. If a lane applies `agent-blocked` anyway, its session is ended and the issue is parked: it is not re-dispatched until it changes (a comment or a label edit) or `HARNESS_BLOCKED_BACKOFF_MIN` passes. `harness status` lists it as `PARKED`. |
| `HARNESS_AUTONOMOUS=false` | Agents may apply `agent-blocked` to park work that genuinely requires human input. Blocked issues are excluded from dispatch until the label is removed. |

### Issue-author allowlist

The engine only claims issues authored by the authenticated GitHub user (`gh api user`), so a
stray `ready-for-agent` label from someone else never puts the fleet to work.

- **Empty (default)** — self-only.
- **`HARNESS_AUTHOR_ALLOWLIST="alice,bob"`** — also trust those logins (always in addition to self).
- **`HARNESS_AUTHOR_ALLOWLIST="*"`** — any author.

Applies to PRD selection and impl claims. Other authors' issues are silently ignored.

### Provisioning a fresh worktree

Every session runs in its own `git worktree`: tracked files only, submodules empty, no untracked
toolchains or caches. If your repo needs more to build, set `HARNESS_WORKTREE_HOOK` to a script; it
runs once per fresh worktree with `cwd` = the worktree and its path as `$1`:

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

Keep it idempotent. Failures are logged and the session still launches.

The hook can also set the lane's model and effort, on every CLI, by writing `.harness-lane` (kept
out of the lane's commits):

```sh
printf 'model=sonnet\neffort=medium\n' > .harness-lane
```

### Parallel-lane merge safety

Lanes branch and merge independently, so a lane's base has usually moved by merge time. The lane
prompts require a **rebase onto the current base plus a re-run** right before merging, repeated
until the rebase is a no-op, and hold lanes to **no new failures against a baseline** taken before
the first edit (not a globally green suite).

### Test selection (rtdd)

Lanes use [rtdd](https://github.com/VocanicZ/rtdd) v0.3 to pick tests instead of running the full
suite on every edit. rtdd names the tests a change needs in rounds; it runs none of them — every
round runs with the project's own test command. The steps (`prompts/_rtdd.md`, shared by the impl,
bug-fix and resume prompts):

1. **rtdd never blocks a lane.** Missing, older than v0.3 (no "Round 1" in its output), or erroring →
   the full-suite bar: the suite before the first edit and at the end, no new failures.
2. **`rtdd which --base origin/<default-branch>`** after every edit names Round 1, Round 2 and
   `untested`.
3. With no `.rtdd/config.yaml` the lane runs `rtdd init` once and commits only `.rtdd/config.yaml`
   and `.rtdd/.gitignore`.
4. **Round 1** (tests of the changed code) until green, then **Round 2** (tests of its callers and
   callees). Both empty → the full-suite bar. **`untested`** code gets new tests.
5. **Round 3**: the full suite, once, at the end, before the PR (on [swarm](#offloading-tests-to-swarm)
   when available), bar **no new failures**. A failure is re-run against the base first; red there
   too is pre-existing and left alone.

At least one new test must fail without the change. A lane never weakens or edits a test to pass.
The merge gate still runs the full suite on the rebased head (or the repo's `scripts/ci-local.sh`).

`harness stats` reports rtdd use per issue and PRD (which calls, round sizes, selective vs
full-suite share). Lanes log to `~/.harness/rtdd-events.jsonl` (`HARNESS_RTDD_EVENTS_FILE`).

### No GitHub CI — the gate is local

Harness projects do not use GitHub Actions as a gate. The merge gate is `scripts/ci-local.sh`
when the repo ships one, otherwise the **full suite run locally on the rebased head** — or
[on swarm](#offloading-tests-to-swarm). `gh pr checks` and mergeable-state are never the gate.
A red gate is retried up to 3 times, then the PR is left open with the failing step commented.

- `HARNESS_DISABLE_CI` (default `1`): `harness init` / `setup` run `gh workflow disable` on test-CI
  workflows. Release/deploy workflows (`release`, `deploy`, `publish`, `pages`, `cd`) keep running
  unless `all`; `0` touches nothing.
- `HARNESS_SEED_CI` (default `0`): seeding adds no workflow and no CI branch protection.

#### Opting back in: the default-branch CI gate

With `HARNESS_CI_GATE=1`, no new sessions spawn while the default branch's latest completed CI run
is red; live sessions continue. It is fail-open (no Actions, no completed run, or a `gh` outage all
dispatch), and the bug lane is never gated, since filing a `bug` is how a red branch gets fixed.

### Gauntlet review

Normal review checks the PRD's own `## Acceptance criteria`. A PRD can opt in to a harder bar:

```markdown
## Quality bar
Beat: ripgrep — https://github.com/BurntSushi/ripgrep
Judged on:
- time to first result on a 1M-line tree
- output legibility for a multi-file match
```

Once the criteria pass, the reviewer runs a **gauntlet round**: it runs one task list against ours
and the reference, writes both into unlabelled `A/` and `B/` under
`.harness/gauntlet/<unit>/r<round>/`, and a **fresh-context critic sub-agent** picks a winner and
names the largest gap. A loss files one `ready-for-agent` issue for that gap and review runs again.

- The bar must be named, fetchable and comparable. A reference that cannot be provisioned → sign
  off on the criteria alone.
- Rounds are capped by `HARNESS_GAUNTLET_ROUNDS` (default `3`); at the cap the reviewer signs off
  and comments the standing gap.
- Blindness is prompt discipline, not a sandbox: only the critic is blind.
- On openclaw (no sub-agents) the critic is a separate `openclaw agent exec` session (`cli_subagent`).

Credit: Matt Shumer's [Gauntlet Loop](https://github.com/robonuggets/gauntlet-loop).

### Security audit review

Off by default. With `HARNESS_SECURITY_AUDIT=1`, every PRD review runs the vendored
`vendor/security-audit/` skill (`quick` profile, scoped to the PRD's changed files) after the
acceptance criteria pass.

- Confirmed findings of medium severity or above become `ready-for-agent` gap issues and hold
  sign-off. Lower findings are listed in a PRD comment.
- Rounds are capped by `HARNESS_SECURITY_AUDIT_ROUNDS` (default `2`).
- Source review and sandboxed local checks only; never a deployed service or a real credential.

Gauntlet and audit round markers only count when written by the fleet's own GitHub login.

## Offloading tests to swarm

With `HARNESS_SWARM=auto` (default) and [swarm](https://github.com/VocanicZ/swarm) on `PATH`,
a lane's full-suite runs go out as a swarm job:

```bash
scripts/swarm-suite.sh <worktree> <job-name> [test files...]
```

| Exit | Meaning | The lane then… |
|---|---|---|
| `0` | every test file passed | treats the run as green |
| `1` | red — each failing file is printed with its shard's `output.log` dir | compares the failures against the baseline, as for a local run |
| `3` | not run on swarm: no `swarm` on `PATH`, `HARNESS_SWARM=off`, the job timed out (it is cancelled), or the job failed with no failing file listed | runs the suite locally, exactly as today |

- One shard per test file (default: every tracked `test_*` / `*_test` `.sh`/`.py`). Each runs with
  `bash`, `python3` or `pytest`, or `HARNESS_SWARM_TEST_CMD` (`{file}`, optional `{junit}`), and
  writes `status`, `output.log` and `junit.xml`.
- Only files git sees are packed (tracked + untracked-not-ignored); `.swarmignore` trims more,
  `HARNESS_SWARM_PACK=all` packs everything. The job tarball is deleted when the job ends.
- `HARNESS_SWARM_TIMEOUT` (default `1800`) is the wait budget in seconds.

## Commands

Run from inside any `harness init`'d project:

| Command | Description |
|---------|-------------|
| `init` | Interactive setup wizard — writes `.harness/config`, creates missing GitHub labels, seeds the target repo(s) |
| `start [--recover]` | Launch the worker pool. `--recover` sweeps stale pidfiles, claims, and orphaned `agent-working` labels before launch |
| `stop [--clean]` | Stop the pool. `--clean` also removes worktrees |
| `status [--watch [secs]] [--all]` | One-shot or live dashboard: pool state, per-unit progress, live sessions, gated units. Outside any project (or with `--all`) it shows **every fleet on the host** from `~/.harness/fleets`: state (RUNNING / PAUSED / STOPPED / COMPLETE / DEAD / missing), live sessions with issue, age and model, open / unblocked / agent-working counts with orphaned locks flagged, last log line, HOLD streaks, and the GitHub budget |
| `stats [--prd N\|--issue N] [-R owner/repo]` | Host-wide event log report (`~/.harness/events.jsonl`, every project): per fleet over the last 7 days — sessions, tokens by model, issues/PRDs closed, retries, HOLD minutes. `--prd` rolls each child issue's sessions (model/effort, tokens, wall time, retries) up to the PRD; `--issue` is a per-session timeline. Filters `--since 7d\|24h\|YYYY-MM-DD`, `--fleet <prefix>`, `--model <substr>`; `--json` for machines; `--backfill` rebuilds `session_end` usage for past sessions from their Claude transcripts, and counts the `rtdd` calls of sessions that predate the rtdd event log. Every level also reports rtdd activity — see [Test selection (rtdd)](#test-selection-rtdd) |
| `forecast <issue> [-R owner/repo] [--unit U] [--json]` | Per-phase cost forecast for one issue — explore / test / impl / gate / ship at p50 / p80 / p95 $ and in total, scaled by the issue's size — from the past lanes in the same event log. Says which history it used and when it fell back. See [Cost forecast](#cost-forecast) |
| `one check` · `one gate <issue> [-R owner/repo] [--unit U] [--json]` | The `/harness-one` budget gate. `check`: exit 0 when the fleet is PAUSED or usage-HELD, else refuses (exit 1). `gate`: the check, the issue's forecast, the arithmetic for every window and `RECOMMEND: APPROVE` (exit 0) or `DENY` (exit 1); exit 3 = refused. See [One issue at a time](#one-issue-at-a-time-harness-one) |
| `one start <issue>` · `one phase <issue> <phase> [--json]` · `one release <issue> [--force]` | `/harness-one` execution, in the invoking session. `start`: the check again, then claim + worktree + `impl.md`/`resume.md` as dispatch does (exit 3 refused, 4 not claimable). `phase`: FITS (exit 0) or CHECKPOINT (exit 1, printing the `pause --force` checkpoint). `release`: drop the worktree, branch and lease (exit 4 = unpushed work) |
| `doctor [--fix]` | Diagnose what strands a pool — who holds `start.lock`/`pool.lock` (via a dependency-free `/proc` scan, so it works without `fuser`/`lsof`), orphaned lock-holders (a killed worker's leaked poll-`sleep`), and stale pidfiles. Report-only by default; `--fix` clears stale pidfiles and reaps **this project's** orphans (never touches a co-resident sibling fleet) |
| `attach <unit> [issue]` | tmux-attach to a running session |
| `migrate` | Convert a project's **vendored** `.harness/` (the pre-shared-engine layout) to state-only and re-point it at the shared engine. Idempotent; refuses if no shared engine is installed |
| `poll [--once\|--status]` | Host-level debug entry to the shared snapshot poller. `--once` refreshes every registered repo once; `--status` reports the poller pid + registered slugs/cadences. Normal operation needs no manual `poll` — workers self-heal it (see [Host poller](#host-poller)) |
| `supervise [--once] [--dry-run]` | Host-level supervisor for **every fleet on the host**: restarts dead pool/priority workers, clears orphaned `agent-working` locks, nudges — then checkpoints to GitHub and kills — sessions frozen at their prompt, and runs the arc stall rules. `--alarms` lists the alarms still firing; `--install` / `--uninstall` manage its systemd user unit. See [Host supervisor](#host-supervisor) |
| `web` | Read-only **dashboard** of every fleet on the host, served in the foreground on `http://127.0.0.1:4637/`: each registered fleet with its state and a link to its page, from local snapshots only. `--install` / `--uninstall` manage its systemd user unit. See [Dashboard](#dashboard) |
| `plan "<brief>"` | Inject a plan/topology change (PLAN.md / `targets.tsv`, incl. seeding a new target repo) into a **live** fleet. Grill via [`/harness-plan`](#per-command-shortcuts) |
| `prd "<brief>"` | Extend a **live** fleet's PRD scope and create the delta issues. Grill via [`/harness-prd`](#per-command-shortcuts) |
| `issue "<brief>"` | Inject a discrete implementation issue (or a few) into a **live** fleet. Grill via [`/harness-issue`](#per-command-shortcuts) |

### Which project a command acts on

Commands find the project by walking up from the current directory for `.harness/config`, like
`git`. An **inherited** `STATE_DIR` that points at a different project is refused, so a session
launched inside one fleet cannot stop another by accident:

| Situation | Behaviour |
|-----------|-----------|
| No `STATE_DIR` set | Discovered from the current directory (the normal path) |
| Inherited `STATE_DIR`, agrees with discovery — or cwd is inside that state dir (a worker's worktree) | Allowed, silently |
| Inherited `STATE_DIR`, nothing discoverable from cwd | Allowed — the out-of-tree / vendored case |
| Inherited `STATE_DIR`, disagrees with discovery | **Refused**, non-zero, naming both paths |
| `harness --state-dir <path> <cmd>` (or `<cmd> --state-dir <path>`) | Always allowed — deliberate, not inherited |
| `HARNESS_STATE_DIR_OK=1` | Always allowed — waives the check for a whole shell |

## Pause / resume / update

```bash
harness pause           # soft drain — stop claiming; live agents finish (local)
harness pause --force   # checkpoint every agent to GitHub, then idle
harness resume          # clear pause; resume here, or start --recover elsewhere
harness update          # install the latest release (verified); --rollback flips back
harness setup           # verify prereqs + seed labels on all units (no start)
```

**Cross-machine resume.** `pause --force` makes each agent push its WIP branch, post a `/handoff`
comment and label the issue `agent-paused`. `resume` on any host runs `start --recover` and picks
them up from GitHub.

**Update.** One engine per host, so one `harness update` moves every project. It never touches a
project's `.harness/` and never runs a destructive git op.

```bash
harness update                     # install the latest release, if it is newer
harness update --rollback          # flip back to the release you ran before
HARNESS_REF=v0.2.0 harness update  # install exactly this release, newer or older
harness update --with-skills       # also refresh the Claude plugins + skills
```

| Outcome | Prints | Exit |
|---------|--------|------|
| Already current | `Harness v0.3.1 is the latest release.` (or, with `HARNESS_REF`, `Harness v0.2.0 is already installed.`) | `0` |
| Newer release installed | `updated Harness v0.3.1 -> v0.4.0 at ~/.harness/releases/v0.4.0` | `0` |
| Nothing published | `harness update: … named no release; if a release exists it may still be an unpublished draft` | `0` |

Other failures leave the engine unchanged: exit `2` for a non-semver running version (name one with
`HARNESS_REF=<tag>`), exit `3` for a failed download, checksum mismatch or full disk.

- Downloads `harness-<tag>.tar.gz` and checks it against `SHA256SUMS`, extracts to
  `~/.harness/releases/<tag>/`, then repoints `~/.harness/engine` atomically. Keeps the current
  release and the previous 2.
- Restarts installed `harness supervise` / `harness web` units from the new release.
- Running workers keep their release until relaunched: `harness pause` → drain → `harness stop` →
  `harness start --recover`.

**`harness update --rollback`** flips back to the previous installed release; a second
`--rollback` goes forward again.

**Migrating a git-checkout engine.** An engine installed before releases is a git clone. Its old
updater knows nothing of releases, so it reaches one in **two `harness update` runs**: the first
fast-forwards to the release-aware updater, the second installs the latest release and moves the
old checkout to `~/.harness/releases/git-<sha>/` (rollback can return to it). With no release
published yet, it prints `harness update: … named no release` and stays a checkout. Afterwards
relaunch the pool with `harness start --recover`.

### Releases

Releases are [GitHub releases](https://github.com/VocanicZ/Harness/releases) with semver tags;
each carries notes, `harness-vX.Y.Z.tar.gz` and `SHA256SUMS`. `harness --version` shows what a host runs.

They are cut on a fleet host with `harness release` from a checkout of this repo:

```bash
harness release              # cut the next release from HEAD
harness release --dry-run    # print the next version and its notes; no gate, tag or publish
harness release --ref <rev>  # release <rev> instead of HEAD
```

It gates on `test/run.sh` against a `git archive` of the shipped tree, takes the version from
[Conventional Commits](https://www.conventionalcommits.org/), tags, builds and publishes. Exit codes:
`0` released, `2` configuration, `3` environment, `4` gate failed.

**The fleet cuts releases itself** when it drives `HARNESS_RELEASE_REPO` (default `VocanicZ/Harness`):
once per reviewed PRD close, and at most one patch release per `HARNESS_RELEASE_THROTTLE` seconds
(default `3600`) for merged bug fixes. A red gate files one `bug` issue. With no tag yet, the fleet
cuts `v0.1.0` itself as a bootstrap release. Tags are never made by hand. Hosts only move when
their operator runs `harness update`.

### Usage-limit checkpoints

When any usage window reaches `HARNESS_USAGE_CHECKPOINT_PCT` (default 90%), Harness checkpoints every
live session on that account like `pause --force` and claims nothing new until the window resets,
then resumes by itself. A session already frozen at a limit gets a mechanical checkpoint (its
worktree committed and pushed, a handoff comment with the last screen).

| CLI | Usage source |
|-----|--------------|
| `claude` | The status-line `rate_limits` data (`five_hour`, `seven_day`), wired per worktree by `HARNESS_USAGE_STATUSLINE`. The account is the `CLAUDE_CONFIG_DIR` the pane runs under |
| `agy` | `agy -p "/usage" --output-format json` (runs no turn): each model group's `5h` and `weekly` buckets, reported as used = 100 − remaining. The account is the model group (`Gemini Models`, `Claude and GPT models`). Cached `HARNESS_AGY_USAGE_TTL` seconds (120) |
| `codex` | The newest rollout's `rate_limits` (`primary`, `secondary`): each window's `used_percent`, read off the last `token_count` event of the newest rollout under `$CODEX_HOME/sessions` that has one. The account is the window's `limit_id` (`codex`). Read from disk each poll, so no cache |
| `copilot` | The newest session's `quotaSnapshots`: each quota's used = 100 − `remainingPercentage`, read off the last `model.model_call_success` event of the newest `$COPILOT_HOME/session-state/<id>/events.jsonl` that has one (not `completions`, the editors' quota, nor an unlimited one). The account is `copilot`. Read from disk each poll, so no cache |
| `hermes` | `hermes usage --json`, run in the newest lane's profile: the configured provider's windows (`openai-codex`, `anthropic` OAuth, `openrouter`; none for `copilot`). The account is the provider. Cached `HARNESS_HERMES_USAGE_TTL` seconds (120) |
| `openclaw` | `openclaw status --usage --json`: the windows of every provider the operator's config holds auth for (none for `claude-cli`). The account is the provider. Cached `HARNESS_OPENCLAW_USAGE_TTL` seconds (120) |
| `opencode` | None: OpenCode 1.x has no quota meter. A limit shows only as its error text at the prompt, which parks the lane (`limit-parks`) and gets the mechanical checkpoint above |

`harness status` shows every window, with `HOLD` on an account being waited out. Every new reading
(one per account and window, only when it changed since the last one logged) goes to the event log
as a `usage_reading` event (`account`, `window`, `pct`, `resets_at`), whatever the CLI; the
[cost forecast](#cost-forecast) calibrates $ per 1% from them.

### Cost forecast

`harness forecast <issue>` predicts what one issue will cost before a lane works it, from the past
issue lanes (impl and bug-fix sessions) in the [event log](#commands) — the groundwork for working
one issue at a time while the fleet is paused or HELD (#362).

- **Phases.** Each past lane's spend is split from its Claude transcripts, sub-agents included:
  everything before the first edit is `explore`; an edit on a test path is `test`, any other edit
  `impl`; a test or gate runner (`test/run.sh`, `ci-local`, `swarm-suite`, `rtdd which`, `pytest`, …)
  is `gate`; `gh pr`, `git push` and `gh issue close|edit|comment` are `ship`. A message counts once,
  in the phase its own tool calls leave the lane in.
- **Cost** is list price per model (Opus, Sonnet, Haiku; any other model is priced as Opus, the
  conservative end). A lane with no Claude transcript — another CLI, whose adapter folded its usage
  into `session_end` — adds its priced total, spread over the phases by the other lanes' mix. A lane
  that spent under $0.50 died at its first turn and is skipped.
- **History.** The forecast uses the issue's PRD siblings in the same repo; with fewer than 3 past
  lanes there it falls back to every lane of the unit, then to every lane on the host, and prints
  `FALLBACK` with the reason (`#N has no history`, `PRD #P has 1 past lane(s), need 3`). The issue's
  own past sessions are never part of its forecast; their spend is shown as `already spent`.
- **Size.** Every figure is scaled by the issue's body length over the median body of the history's
  issues, clamped to 0.6–2.0. The output prints the scale it applied.
- **% of a usage window.** Each figure is also shown as % of each account's usage windows, at a
  calibrated $ per 1%. For every account and window, two consecutive `usage_reading`s inside the same
  window (a pair across a reset is skipped) give the % it rose by and the $ the event log's sessions
  on that account spent in between (their transcripts' messages, by timestamp; a session's account is
  its Claude config dir). The fit is Σ$ / Σ%; the forecast divides by its conservative bound — the
  20th percentile of the per-pair $/1%, never above the fit — so the % it shows errs high. Each window
  prints its fit (`n pair(s)`, fit, bound). A window with no usable pair, or an account with no
  readings at all, uses `HARNESS_ONE_USD_PER_PCT` and prints `FALLBACK`; without that setting it is
  `n/a`.

The repo is `-R`, else the one the issue's own lanes ran in, else the current project's unit
(`--unit` picks one in a multi-unit project). Issue bodies come from `gh`. `--json` prints the same
numbers (`phases`, `total`, `size`, `basis`, `spent`, `pct`, `calibration`) for scripts; the exit status is 1 when the host
has no past lanes at all.

### One issue at a time (`/harness-one`)

While the fleet is paused, or every claim is usage-HELD by the checkpoint above, `/harness-one` lets
the operator keep going one issue at a time in their own session, with a budget gate before each.

- **Precondition** — `harness one check`. The fleet must be PAUSED (`harness pause`) or usage-HELD.
  Anything else is refused: a running, un-held pool would race the session for the claim (a stopped
  fleet too — pause it first, so a `harness start` cannot).
- **Gate** — `harness one gate <issue>` prints the issue's [cost forecast](#cost-forecast), then for
  every usage window `cli_limit_usage` reports: `now% + p80% + HARNESS_ONE_RESERVE_PCT`, against
  `HARNESS_ONE_STOP_PCT`. It recommends **APPROVE** only when every window is at or under the stop
  (exactly at it approves), else **DENY**, naming each window over it. `p80%` is the forecast's p80
  total as % of that window (its calibrated fit, else `HARNESS_ONE_USD_PER_PCT`). A reading older
  than `HARNESS_ONE_STALE_MIN` minutes — its status-line drop's age, or the adapter's usage cache's —
  or of unknown age gets `HARNESS_ONE_STALE_PAD_PCT` points added. No reading, no p80% for a window,
  or no past lanes at all is a DENY: the gate cannot show the work fits.
- **Decision** — the skill shows all of that and asks: approve / pick another issue / stop. It never
  approves by itself; a DENY is a recommendation the human may overrule.
- **Start** — on approval, `harness one start <issue>` re-checks the precondition immediately before
  the claim, then claims and sets the issue up exactly as dispatch does (`agent-working`, its worktree
  on `issue/<n>`, `prompts/impl.md` rendered into `.harness-task.md` — `resume.md` for an
  `agent-paused` issue, from its pushed branch and handoff). No lane, no tmux pane: the invoking
  session works the task. A lease (`HARNESS_ONE_LEASE_MIN`, default 240 minutes since the last
  `start`/`phase`) stands in for the lane session the pool's reapers and lock sweeps look for.
- **Per phase** — before each of explore / test / impl / gate / ship the session runs
  `harness one phase <issue> <phase>`: fresh usage against the forecast *left* from that phase on (the
  sum of the phases' p80, never above the whole issue's p80), `now% + remaining p80% + reserve` vs
  `HARNESS_ONE_STOP_PCT`. **FITS** (exit 0) goes on; **CHECKPOINT** (exit 1) prints the very
  `HARNESS CHECKPOINT` message `pause --force` sends a lane — commit + push, handoff comment,
  `agent-working` → `agent-paused`. A window it cannot price (no reading, no p80%) does not stop the
  work on its own — the gate already said so — unless its `now% + reserve` alone is over the stop.
- **Release** — after the checkpoint, or once merged, `harness one release <issue>` drops the
  worktree, local branch and lease (it refuses while work is unpushed, short of `--force`) and clears
  an `agent-working` that was never checkpointed. Nothing of the session's is left, so the pool
  resumes an `agent-paused` issue through `resume.md` after the reset, like any checkpointed lane.
- **Done → next** — once merged, `harness one done <issue>` runs the goal check `reap_done_sessions`
  runs (`issuelib.py check <repo> ISSUE:<n>`); until it reports DONE (exit 4) nothing is offered. Then
  it picks the next claimable issue exactly as a one-slot dispatch would (`issuelib.py next`: open,
  ready, not `agent-working`, every `## Blocked by` closed; resumable — `agent-paused` or a pushed
  branch — first, then oldest) and runs a fresh forecast + gate for it (exit 0 APPROVE / 1 DENY / 3
  refused). The human decides again: approve / pick another / stop. None claimable is exit 5.

### GitHub rate limits

Every fleet on a host shares one GitHub token's budget.

- **On a rate limit** the dispatchers and poller sleep until the reset read from `gh api rate_limit`;
  live sessions keep running.
- **Budget guard:** below `HARNESS_GH_BUDGET_PCT` (default 20%) of `core` or `graphql`, no new claims
  and half-rate polling until the reset.
- `harness status` shows each token's remaining budget (env tokens by hash, never by value).

For org repos, a GitHub App installation token has its own budget. Harness does not mint App
tokens: put a `gh` wrapper on the fleet's `PATH` that mints, caches and refreshes the token, then runs
the real `gh` with `GH_TOKEN` set.

## Host supervisor

`harness supervise` watches every fleet on the host from outside (skipping paused or stopped ones).
Each pass, every `INTERVAL` seconds:

1. **Dead workers** → `harness start` for that fleet.
2. **Orphan locks** — `agent-working` with no live session for `LOCK_GRACE` → label removed.
3. **Frozen sessions** — no screen change, timer movement or CPU use for `NUDGE_MIN` → one nudge;
   still quiet at `KILL_MIN` → WIP committed and pushed (to `<branch>-checkpoint-<ts>` if diverged,
   never force-pushed), a handoff comment posted, session killed and re-dispatched. If nothing can be
   pushed, it is not killed. Panes showing a dialog or a limit message are never typed into. A turn
   over `HARNESS_TURN_MAX` (default 4 h) with queued input is interrupted so the input lands.
4. **Other agent panes** matching `EXTRA_RE` — nudged only.
5. **Offline host** — everything held while `ONLINE_URL` is unreachable.
6. **Arc stall rules** (2+ consecutive passes). Auto-fixed: wedged sessions, zombie sessions on
   closed issues, live sessions missing `agent-working`. Alarm only: review loop, no frontier,
   decompose stalled, unfiled plan tasks, missing `## Parent`, wayfinder leak, deep context.
   `harness supervise --alarms` lists them.

Log: `~/.harness/supervise.log`. Preview a pass with `harness supervise --once --dry-run`. Knobs go in
`~/.harness/supervise.conf`:

| Knob | Default | |
|------|---------|-|
| `INTERVAL` | `300` | seconds between passes |
| `LOCK_GRACE` | `1200` | seconds an orphaned `agent-working` label must age before it is cleared |
| `NUDGE_MIN` / `KILL_MIN` | `45` / `120` | quiet minutes before the nudge / the checkpoint-and-kill |
| `RENUDGE_S` | `10800` | at most one nudge per pane in this many seconds |
| `CPU_ACTIVE_S` | `10` | CPU seconds per pass that count as activity |
| `EXTRA_RE` / `EXTRA_MIN` | empty / `60` | tmux session regex for non-Harness agent panes, e.g. `'^hg2(-loops)?$'` |
| `ONLINE_URL` | `https://api.anthropic.com` | reachability probe for the offline hold |
| `UNPARENTED_OK` | empty | comma-separated issue numbers exempt from the missing-`## Parent` alarm |

`harness supervise --install` installs and starts the `harness-supervise.service` systemd user unit
(with linger); `--uninstall` removes it.

## Dashboard

`harness web` serves a read-only dashboard at `http://127.0.0.1:4637/`: every fleet on the host, a
page per fleet (`/fleet/<prefix>`) with its issue DAG, sessions and an issue drawer (PR, CI,
blockers, timeline). Pages update live. JSON at `/api/host` and `/api/fleet/<prefix>`. It reads local
state only, so it spends no GitHub budget.

| Variable | Default | Meaning |
|---|---|---|
| `HARNESS_WEB_BIND` | `127.0.0.1` | address the server listens on |
| `HARNESS_WEB_PORT` | `4637` | port the server listens on |
| `HARNESS_WEB_TICK` | `2` | seconds between the live-update checks of local state |
| `HARNESS_WEB_MAX_STREAMS` | `32` | open live-update streams allowed; the next one gets `503` |

```bash
harness web --install                              # systemd user unit, 127.0.0.1:4637
HARNESS_WEB_BIND=0.0.0.0 harness web --install     # reachable from the LAN
```

There is no login: read-only is its only protection. Never expose the port to the Internet.

## Host poller

One host-level process polls each repo once and writes snapshots to `~/.harness/snapshots/`; every
fleet's workers read those instead of calling GitHub, so read volume scales with repos, not workers.
Each fleet still computes its own dispatch.

- On by default; `HARNESS_USE_POLLER=0` opts a fleet out (restart it to apply).
- Refreshes are incremental (`since` + ETag; an unchanged board costs no rate limit), with a full
  resync every `HARNESS_FULL_RESYNC` seconds (default `3600`). External `## Blocked by` refs are
  cached `HARNESS_DEP_TTL` seconds (default `600`).
- No lifecycle to manage: `harness start` brings it up and workers relaunch it if it dies.
  `harness stop` never kills it (other fleets may use it).
- A stale snapshot holds new dispatch until fresh; it never falls back to direct `gh` polling.
- Debug: `harness poll --status`, `harness poll --once`.

## Fleet prefixes

A fleet owns every tmux session named `<prefix>-*`, so two fleets with the same
`HARNESS_SESS_PREFIX` kill each other's agents. `harness init` derives a unique prefix from the
project directory; older configs default to `hz` — set one explicitly if several fleets share a host.

`harness start` refuses a prefix another fleet already owns (live sessions, live workers, or the
`~/.harness/fleets` registry), naming that project. A registry entry left by a killed fleet is pruned
automatically or with `harness doctor --fix`. `HARNESS_PREFIX_COLLISION=warn` downgrades the refusal.

## Migrating an old vendored project

Early projects carried a full engine clone inside `.harness/`. Convert one to state-only:

```bash
harness install          # once per host — places the shared engine + the 'harness' PATH symlink
cd your-project
harness migrate          # strip the vendored engine clone + .git; keep config + runtime state
harness start --recover  # relaunch off the shared engine
```

Config, `targets.tsv`, `run/`, worktrees, checkouts and `prompts/*.local.md` are kept. Idempotent.

## The `/harness` skill

Installed once to `~/.claude/skills/harness/`. Run `/harness` (or "start the fleet", "what's the
harness doing") in any session to operate the fleet conversationally: start, stop, watch, and safe
unstick moves. It never does a unit's work by hand.

### Per-command shortcuts

| Skill | Runs | Notes |
|-------|------|-------|
| `/harness-init`   | `harness init`   | setup wizard (interactive — prefer `! harness init`) |
| `/harness-start`  | `harness start`  | confirms first; `--recover` for crash/new-host |
| `/harness-stop`   | `harness stop`   | confirms first; asks before `--clean` |
| `/harness-pause`  | `harness pause`  | confirms first; soft drain vs `--force` checkpoint |
| `/harness-resume` | `harness resume` | confirms first; works across machines |
| `/harness-status` | `harness status` | read-only, runs immediately |
| `/harness-one`    | `harness one`    | refuses unless the fleet is PAUSED or usage-HELD; shows the forecast and the APPROVE/DENY arithmetic, then the human picks approve / another issue / stop — never auto-approves. See [One issue at a time](#one-issue-at-a-time-harness-one) |
| `/harness-plan`   | `harness plan`   | inject a topology/PLAN change into a live fleet; grills + replays a crystallized brief for confirmation (the human safety gate) before mutating; supports `--unit <id>` (multi-topology) and the `--recover` retired-fleet fallback |
| `/harness-prd`    | `harness prd`    | grow PRD scope → delta issues on a live fleet; grills + replays a crystallized brief for confirmation before mutating; supports `--unit <id>` (multi-topology) and the `--recover` retired-fleet fallback |
| `/harness-issue`  | `harness issue`  | inject a discrete implementation issue into a live fleet; grills + replays a crystallized brief for confirmation before mutating; supports `--unit <id>` (multi-topology) and the `--recover` retired-fleet fallback |

`/harness-arc` deploys a design too big for one PRD as a chain of PRDs plus a wayfinder map of
decisions the fleet cannot make. Its stall rules run in the [host supervisor](#host-supervisor).

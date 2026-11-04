# Harness reference

Full reference for operators. Start with the [README](../README.md).

## Agent CLIs

### Supported agent CLIs

Pick one with `HARNESS_CLI`. A CLI is listed only when every row below passes for it
(`test/test_cli_matrix.sh`, against captures from the real CLI). The `headless-*` rows are the same
features on the [headless session backend](#headless-lanes) (`HARNESS_SESSION_BACKEND=headless`): only a
CLI with a headless lane runner (`cli_headless_list`) runs there, so every other CLI is tmux-only there. Per-CLI facts and sources:
[cli-capabilities.md](cli-capabilities.md).

| feature | what it proves | `claude` | `agy` | `codex` | `copilot` | `opencode` | `hermes` | `openclaw` |
|---|---|---|---|---|---|---|---|---|
| verified on | `<cli> --version` of the captured fixtures | 2.1.311 (Claude Code), 2026-10-27 | 1.4.8, 2026-10-27 | codex-cli 0.154.0, 2026-10-27 | GitHub Copilot CLI 1.0.105, 2026-10-28 | 1.19.5, 2026-10-28 | Hermes Agent v0.22.5 (2026.9.24) · stable · local bf0203a794a0, 2026-10-28 | OpenClaw 2026.10.8 (dc2523e), 2026-10-28 |
| `fixtures-recorded` | Panes, transcript and usage samples captured from the real CLI (`test/fixtures/cli/<cli>/`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `launch-bootstrap-prompt` | The launch line carries the fixed bootstrap prompt | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `launch-no-task-text` | The task text stays out of argv (#213) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `launch-model` | A lane's model, pinned by the worktree hook (`.harness-lane`), reaches the launch `launch_agent` types | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `launch-effort-once` | That lane's effort replaces the configured one in the typed launch, once | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `launch-role-model` | A lane with no `.harness-lane` launches with its role's model and effort (`HARNESS_MODEL_IMPLEMENTER`/`HARNESS_EFFORT_IMPLEMENTER` for an issue lane, `_MANAGER` for an orchestration lane), as its launch event reads them off the CLI's own line and lane config (#375) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
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
| `handoff-skill-installed` | Harness ships that handoff skill (`skill/handoff`): `harness setup` reports it missing, and `--install` and `install.sh` put it where the CLI loads user skills from (claude, opencode: `~/.claude/skills`; hermes: `~/.hermes/skills`, and openclaw: `~/.agents/skills`, each an external skill dir in that CLI's lane config; codex: `~/.agents/skills`; agy: `~/.gemini/config/skills`; copilot: `~/.copilot/skills`), never over the operator's own | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `prompt-skills-installed` | Every skill a lane prompt names — each `{{skill:<name>}}` in `prompts/*.md` (`to-prd`, `to-issues`, `writing-plans`, `caveman`, `subagent-task-tree`, `handoff`, `rtdd`), the only way a prompt names one — renders as the CLI invokes skills, and `harness setup` lists it for the CLI: missing until `--install` or `install.sh` puts Harness's `skill/<name>` (its own, or vendored from upstream with its `LICENSE`) where the CLI loads user skills from, never over the operator's own; rtdd's skill is rtdd's own (`rtdd skill install`), a warning when absent | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `operator-skills` | With the CLI installed (its binary on PATH), `install.sh` and every `harness update` (no flags, already current included), `harness setup` and `harness start` link every engine skill — `harness/SKILL.md` and each `skill/<name>` — into the dir the operator's own CLI reads user skills from (`cli_user_skills_dir`: claude, opencode: `~/.claude/skills`; hermes: `~/.hermes/skills`; openclaw, codex: `~/.agents/skills`; agy: `~/.gemini/config/skills`; copilot: `~/.copilot/skills`), each a symlink into the engine through `~/.harness/engine`, so an update refreshes every CLI; a removed link is back on the next run (#439) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
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
| `headless-launch` | On `HARNESS_SESSION_BACKEND=headless` (#349) `launch_agent` prepares the worktree as for a pane (trusted, bypassed, the goal loop armed) and starts the CLI's headless lane runner, a detached process, not a typed launch line: the lane is live and listed, its first turn's prompt is the bootstrap on stdin under the loop's session id, and no argv carries the task. Every `headless-*` row runs on the runner (`scripts/cli/claude_headless.py`) with a fake CLI replaying the stream-json the real one printed (`test/fixtures/cli/claude/stream-json/`); a CLI with no runner is refused on that backend (`cli_backend_check`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-send` | `cli_send` mid-turn waits in the lane's inbox (drawn in its input box) and is the next turn, carrying on the same session (claude: `--resume <id>`; codex: `exec resume <thread id>`, the thread the first turn reported; agy: `--conversation <id>`, the conversation the first turn reported) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-busy-idle` | A running turn reads busy and never a stall; once it ends the lane reads as the idle prompt, not busy, not a stall, not a limit (`state.json`: `busy`, `idle`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-limit-parks` | A turn the usage limit ends (claude: stream-json `rate_limit_event` `rejected`, `api_error: usage_limit_reached`; codex: a `turn.failed` saying "You've hit your usage limit … try again at <date>", the date its reset time) parks the lane with the CLI's reset time, not a stall; the watchdog handles it as a limit park and its nudge is the next turn | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-transient-stalls` | A turn a transient API error ends (claude: `api_retry` events, then an error `result`; codex: `Reconnecting… n/5` `error` events, then `turn.failed`) is the #115 wedge, not a limit; the watchdog nudges it and the nudge runs a healthy turn | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-loop-mode` | The goal loop is the driven one: the watchdog reads the lane's last reply (`cli_last_reply`, off `state.json`) and re-prompts a turn without the promise once — the promise and the bootstrap, never the task — and the turn that outputs it ends the loop | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-interrupt` | `turn_interrupt` ends a running turn's whole process tree; the runner lives on and the message queued behind the turn runs next | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-checkpoint` | `pause --force` sends an impl lane the checkpoint (naming the handoff skill and marker), which waits behind its running turn, then waits on the lane's state for that turn and ends the lane (#350) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-resume` | That checkpointed lane, re-dispatched as an `agent-paused` issue with its handoff, relaunches in its worktree on the resume prompt and carries on the same agent session: its first turn is `--resume <id>` (codex: `exec resume <thread id>`; agy: `--conversation <id>`), no new session (#350) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-supervisor-frozen-session` | `harness supervise` nudges a quiet idle lane through its inbox (the nudge is its next turn) and leaves a limit-parked lane alone (#351) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-usage-windows` | With no status line, the usage windows are read off what a turn left (claude: the `rate_limit_event` it printed, kept in `state.json`: each window's utilization as a percent, under the lane's account (#352); codex: the `rate_limits` in the rollout every `codex exec` writes, as for a pane) | ✓ | ✓ | ✓ | ✓ | n/a: OpenCode 1.x has no quota meter: a limit shows only as its error text at the prompt, which parks the lane (limit-parks) | ✓ | ✓ |
| `headless-stats-session-end-usage` | Once the lane's runner has exited the stats sweep emits its `session_end` once, its usage the sum of its turns' own (claude: stream-json `result` usage, `model_usage_since_last_result` (#352, #426); codex: the rollout's `last_token_usage` per turn — a resumed turn's `turn.completed.usage` is the thread's running total, so the stream is not summed) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-stop` | `harness stop` ends a lane mid-turn: the runner, the CLI's turn and that turn's own child are gone, nothing is listed, the lane's state reads `ended` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `headless-sweep-detached-jobs` | A lane whose turn ended normally with detached background jobs behind it (`cmd &`, `setsid`): `sess_kill`, and the stats sweep for a lane that ended on its own, leave no process carrying its `HARNESS_SESSION`; a live lane's jobs and another uuid's are left alone (#427) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

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
logs one banner naming what is outstanding. 

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

## One fleet, one repo

A fleet drives exactly one repo, `HARNESS_REPO`, as one unit named `HARNESS_UNIT` (default `main`) cloned at
`HARNESS_CHECKOUT` (default `$PROJECT_ROOT`). Up to `HARNESS_POOL` lanes run at once, one per pool worker
([The pool worker](#the-pool-worker-step-loop)). There is no topology setting and no unit dependency graph (#473): a fleet
that used to cover several repos is split into one fleet per repo by
[Fleet migration](#fleet-migration-one-fleet--one-repo-467), the only place that still reads the old files.
Submodules are part of the one repo ([Submodules](#submodules)).

### The pool worker (step loop)

A pool worker claims **one lane** — one issue (`IMPL`), one bug, or one PRD action (`PLAN`, `PRD`,
`DECOMPOSE`, `REVIEW`) — runs it, reaps it, releases it and claims the next. **`HARNESS_POOL` is the most
lanes that can run at once**: `POOL=3` with three ready issues runs three lanes, one per worker, not one
worker driving the unit while two sit idle. The priority bug worker is on top of `POOL` and not counted in
it. `POOL` is the only parallelism knob (#469). A cap setting left over from an older release is ignored, with
one warning per `harness start`: "CAP is gone; POOL is the number of parallel issues" (details in
[Fleet migration](#fleet-migration-one-fleet--one-repo-467)).

A worker never blocks inside a lane. It runs one **step** per tick (every `HARNESS_POLL`, and at once after
a claim):

1. **Preamble** — `roots_check`, `gc_orphan_goals`, `gh_rate_wait`, `snapshot_gate`, `usage_watch`.
2. **Chores** — one worker per tick wins `run/chores.lock`; the others skip this step. The winner reaps
   and watchdogs the *ownerless* lanes (a lane whose claim a live worker holds is its owner's to tend, so
   nothing runs twice), runs the injector reaper, `one_auto_tend`, the release tick, the stale-lock sweeps,
   **adopts** ownerless live lanes, and runs every *slotless* dispatch action this tick (`LABEL_READY`,
   `CLOSE_PRD`). On a COMPLETE repo it archives `PLAN.md` once and does nothing else: it never kills a
   lane, and a new PRD or ready issue makes the repo incomplete again. While usage is held it also ticks
   the [auto harness-one lane](#auto-harness-one-lane-harness_one_auto).
3. **Own lanes** — one tend step per lane this worker holds a claim on: the goal check, the stall
   watchdog (which advances a driven goal loop) and the self-park check. A lane whose session has ended is
   reaped and its claim released.
4. **Claim** — only when the worker owns no lane, is not paused, usage is not held, the GitHub budget is
   fine and the default branch is not red. Under `run/pool.lock`: when live lanes + live claims is below
   `POOL`, it takes the first slot-taking item `dispatch` returns and writes its claim; the lane is spawned
   after the lock is released (the claim covers the window).

**No double claims.** The PRDs and issues dispatch is told are busy are those with a live session or
worktree *plus* those held by a live claim; bugs are filtered the same way, and `PLAN` / `PRD` are offered
only when no lane and no claim is live in the fleet. All of it is read inside `pool.lock`.

**Claims.** `run/claims/<key>.claim` holds `<worker-id> <worker-pid> <token> <session> <pane-pid>`. The key
is `impl-<n>`, `orch-<prd>` (`orch-0` for `PLAN` / `PRD`) or `bug-<repo>-<n>`; the token names the action
(`IMPL:12`, `DECOMPOSE:41`). A bug a pool worker takes is claimed as `pool-<worker-id>`, so the priority
lane never mistakes it for its own and never claims it too. A claim is live while its worker's pid is.

**Adoption.** A live session of the fleet's unit (`<prefix>-<unit>-i<N>`, `-p<N>`, `-p0`) that no live worker
holds a claim on is adopted by the chores winner, which writes the claim for itself and tends the lane from
then on. It is read from sessions, not claim files, so it survives `harness start --recover` (which clears
dead claims), picks up what a worker roll left running ([#467](#fleet-migration-one-fleet--one-repo-467)),
and lets a killed worker's lane be reaped and merged once. A dead lane's worktree is still reaped by the
chores, so an issue is never held "owned" by a lane that is gone. Adoption adds no lane, so it cannot push a
fleet past `POOL`.

**Pause.** No new claim. Running lanes keep running and keep being tended, a driven goal loop included.
Workers stay alive and idle.

New lane events (`lane_claim`, `lane_release`, `lane_adopt`) carry `repo` and `worker`; the older events keep
`unit`. `harness stats` reads both shapes (#472); `harness status` and the web fleet page show one row per worker with the issue it runs.

## Configuration

Harness reads `.harness/config` (sourceable `KEY=VALUE`). Environment variables win over the file:
`HARNESS_POOL=5 harness start`.

| Key | Default | Meaning |
|-----|---------|---------|
| `HARNESS_MODE` | `issue-only` | Pipeline mode: `issue-only`, `prd`, or `planned` |
| `HARNESS_OWNER` | _(empty)_ | GitHub owner/org (used to expand bare repo names) |
| `HARNESS_REPO` | _(empty)_ | The fleet's target repo (`owner/repo`) |
| `HARNESS_UNIT` | _(empty)_ → `main`; `harness init` writes the lowercased repo short name (`Acme/Widget` → `widget`) | The fleet's one unit: its name in session and worktree names (`<prefix>-<HARNESS_UNIT>-i<N>`), the default `--unit` of `harness inject` and `harness one`, and the unit `forecast` and `stats` attribute lanes to. Empty = `main`. The repo always comes from `HARNESS_REPO` |
| `HARNESS_CHECKOUT` | _(empty)_ → `$PROJECT_ROOT` | Where the fleet's repo clone lives (the lanes' and the bug lanes' checkout; a submodule lives inside it, [Submodules](#submodules)); `harness update` / `harness start` write both keys when they migrate a fleet ([Fleet migration](#fleet-migration-one-fleet--one-repo-467)) |
| `HARNESS_SPEC` | _(empty)_ | Path to the umbrella spec; `planned` mode only |
| `HARNESS_AUTONOMOUS` | `true` | `true` = agents never park; `false` = agents may apply `agent-blocked` for human help |
| `HARNESS_SESSION_BACKEND` | `tmux` | What each lane's agent session runs in: `tmux` = a detached tmux session per lane on the host's tmux server (attach with `harness attach`); `headless` = each lane a detached headless runner process, no multiplexer — for a CLI with a headless lane runner only (`cli_headless_list`, [Headless lanes](#headless-lanes)); any other CLI is refused as tmux-only. Any other value is refused by `harness init` and `harness start`, and `harness doctor` reports it. `harness init` writes it; one backend per file under `scripts/session/`, and every session operation the engine performs goes through that seam |
| `HARNESS_CLI` | `claude` | Agent CLI to drive: any CLI in [Supported agent CLIs](#supported-agent-clis), one adapter per CLI under `scripts/cli/` |
| `HARNESS_MODEL_MANAGER` | `opus` on `claude`; _(empty)_ elsewhere | Model of every **Manager** lane: orchestration (`-p*`: PLAN, PRD, DECOMPOSE, REVIEW and its gauntlet auditor/critic), bug triage, the injector. Empty = the CLI's own default. See [Roles](#roles-model-and-effort-per-lane) |
| `HARNESS_EFFORT_MANAGER` | `high` on `claude`; _(empty)_ elsewhere | Effort of every Manager lane; empty = the CLI's own default |
| `HARNESS_MODEL_IMPLEMENTER` | `sonnet` on `claude`; _(empty)_ elsewhere | Model of every **Implementer** lane: issue lanes (`-i*`, also resuming from `resume.md`) and bug fixes. Empty = the CLI's own default |
| `HARNESS_EFFORT_IMPLEMENTER` | `high` on `claude`; _(empty)_ elsewhere | Effort of every Implementer lane; empty = the CLI's own default |
| `HARNESS_CLAUDE_BIN` | `claude` | Command line that runs `claude` when `HARNESS_CLI=claude`: an executable name or path, or a command line such as `env CLAUDE_CONFIG_DIR=~/.claude-switch/accounts/main claude` (pins the account even when tmux drops `CLAUDE_CONFIG_DIR`). The launch runs it whole; only its executable (the first word that is not `env`, an `env` option or a `NAME=value`) is checked for on PATH. Words split on whitespace, so a value containing a space is not supported |
| `HARNESS_AGY_BIN` | `agy` | Executable path for `agy` when `HARNESS_CLI=agy`; a command line like `HARNESS_CLAUDE_BIN`'s |
| `HARNESS_AGY_FLAGS` | `--dangerously-skip-permissions --effort high` | Flags passed to `agy` CLI on launch |
| `HARNESS_CLAUDE_FLAGS` | `--dangerously-skip-permissions --effort high` | Flags passed to `claude` on launch; a lane's own model and effort (`.harness-lane`), else its role's (`HARNESS_MODEL_*` / `HARNESS_EFFORT_*`), replace the ones they carry |
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
| `HARNESS_HERMES_HOME` | `~/.hermes` | The operator's Hermes home (login, `config.yaml`, skills) each lane's own profile is seeded from; Harness links its skills into its `skills/` |
| `HARNESS_HERMES_USAGE_TTL` | `120` | Seconds one `hermes usage --json` answer is reused by every worker |
| `HARNESS_OPENCLAW_BIN` | `openclaw` | Executable path for `openclaw` when `HARNESS_CLI=openclaw`; a command line like `HARNESS_CLAUDE_BIN`'s |
| `HARNESS_OPENCLAW_CONFIG` | `$OPENCLAW_CONFIG_PATH`, else `${OPENCLAW_STATE_DIR:-~/.openclaw}/openclaw.json` | The operator's OpenClaw config (login, default model) each lane's own config includes |
| `HARNESS_OPENCLAW_TIMEOUT` | `14400` | Seconds one `openclaw agent exec` turn of a lane may run |
| `HARNESS_OPENCLAW_SUBAGENT_TIMEOUT` | `3600` | Seconds one review or gauntlet sub-agent run (a fresh `openclaw agent exec`) may take |
| `HARNESS_OPENCLAW_USAGE_TTL` | `120` | Seconds one `openclaw status --usage --json` answer is reused by every worker |
| `HARNESS_OPENCLAW_AGENTS_SKILLS` | `~/.agents/skills` | The user skill dir the operator's own openclaw reads, where Harness links its skills; an openclaw lane's config adds it as an extra skill dir, after `HARNESS_USER_SKILLS` |
| `HARNESS_HOME` | `~/.harness` | The host root: the shared engine (`engine`, a link into `releases/<tag>/`), whose `skill/` every CLI's skill links name (#439), and the host's poller, fleet and lane state |
| `HARNESS_USER_SKILLS` | `~/.claude/skills` | Where Harness links user skills for claude and opencode, and a skill dir a hermes or openclaw lane gets as an external one. Set, it is a sandbox: no other CLI's dir under `HOME` is touched |
| `HARNESS_MARKETPLACE` / `HARNESS_MARKETPLACE_NAME` | `anthropics/claude-plugins-official` / `claude-plugins-official` | The plugin marketplace `harness setup --install` adds to `claude`, and its name, for the `ralph-loop` and `superpowers` plugins |
| `HARNESS_INIT_SEED` | `1` | A non-interactive `harness init` (no terminal — an agent's shell, `/harness <idea>`) seeds the harness labels on `HARNESS_REPO` when `gh` is signed in, so the `prd` issue filed next finds its label; signed out, it says to run `harness setup`. Labels only — disabling the repo's Actions stays with `harness setup`. The interactive wizard always seeds. `0` = skip it |
| `HARNESS_INSTALL_CLI_BIN` | `1` | `1` = `harness setup --install` installs a missing agent CLI binary by its vendor's non-interactive install (an npm package or a curl release script) when `npm` / `curl` is on `PATH`; signing in stays yours. `0` = only name the command |
| `HARNESS_POOL` | `3` | The number of parallel issues: pool workers, one lane each, so also the most lanes (impl issues, PRD actions, pool-taken bugs) that run at once, fleet-wide. The only parallelism knob (#469): a cap setting left over from an older release is ignored with a warning and dropped from the config by [fleet migration](#fleet-migration-one-fleet--one-repo-467) ([The pool worker](#the-pool-worker-step-loop)) |
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
| `HARNESS_LABEL_HITL` | `hitl` | Human-in-the-loop task (#360): decompose files a slice no lane can do with this label and a `[HITL] …` title. No lane ever claims it (even if it also carries the ready label), the engine never labels it ready, and while open it holds its PRD's review and close; `harness status` reports it as `WAITING ON HUMAN`, not `STUCK`. An unlabelled issue titled `[HITL]` is treated the same |
| `HARNESS_LABEL_COORD` | `coordination` | Optional, human-facing tracking label only. Cross-unit deps are filed as real cross-repo `owner/repo#N` refs in `## Blocked by` (see `prompts/decompose.md`); this label is **not** the work path. |
| `HARNESS_AUTHOR_ALLOWLIST` | _(empty)_ | Comma-separated GitHub logins permitted to author claimable issues. Empty = self-only (secure default); `*` = allow any author. See [Issue-author allowlist](#issue-author-allowlist) |
| `HARNESS_USE_POLLER` | `1` | Host poller, **on by default** (#182): this fleet reads shared host snapshots instead of polling GitHub itself. Empty also means on (configs written before #182 carry an empty value); `0` = direct-`gh` polling. See [Host poller](#host-poller) |
| `HARNESS_WORKTREE_HOOK` | _(empty)_ | Path to a project script run once in every freshly created worktree, with `cwd` = that worktree and its path as `$1`. Absolute, or relative to the project root. Empty = no-op. See [Provisioning a fresh worktree](#provisioning-a-fresh-worktree) |
| `HARNESS_GAUNTLET_ROUNDS` | `3` | Gauntlet review: rounds allowed before the reviewer concedes and signs off. Only applies to a PRD carrying a `## Quality bar` — see [Gauntlet review](#gauntlet-review) |
| `HARNESS_SECURITY_AUDIT` | `0` | `1` = every PRD review (`prd`/`planned` modes) runs a security audit after the acceptance criteria pass; findings of medium severity or above are filed as gap issues and hold the sign-off. `0` = off. See [Security audit review](#security-audit-review) |
| `HARNESS_SECURITY_AUDIT_ROUNDS` | `2` | Security audit: rounds with filed findings allowed before the reviewer concedes and moves on |
| `HARNESS_CI_GATE` | `0` | Off by default — Harness projects run [no GitHub CI](#no-github-ci--the-gate-is-local). `1` = hold new dispatch while the default branch's own GitHub CI is red (live sessions drain; the bug lane is never gated), for a project that opted back into Actions. Fail-open — no Actions, an in-flight run, or a `gh` outage all dispatch normally |
| `HARNESS_SWARM` | `auto` | `auto` = when [swarm](https://github.com/VocanicZ/swarm) is on `PATH`, PRD review's full-suite run (the only one in the pipeline — lanes never run the full suite) goes out as a swarm job; `off` = always local. No swarm installed → exactly the local behaviour. See [Offloading tests to swarm](#offloading-tests-to-swarm) |
| `HARNESS_WINDOWS_HOST` | _(empty)_ | The ssh alias of a Windows check host (the owner's Windows desktop, `winsma` in PRD #475). Set, lanes and the PRD review can verify Windows behaviour there with the helpers in `test/smoke/winsma/` ([Windows smoke guide](windows-smoke.md#checking-on-a-shared-windows-host-testsmokewinsma)); empty = no Windows host, and nothing reaches for one. Read like every other key: `.harness/config` or the environment |
| `HARNESS_SEED_CI` | `0` | `1` = when fully seeding a unit repo (`seed.sh <unit>`), commit a language-autodetect `.github/workflows/ci.yml` and set best-effort branch protection requiring its `test` check. `0` = neither — the engine never adds a workflow to your repos unless asked (labels and auto-merge are still set). `1` is an explicit opt-in to GitHub CI, so it also skips `HARNESS_DISABLE_CI` |
| `HARNESS_DISABLE_CI` | `1` | When `harness init` / `harness setup` seed a repo, `gh workflow disable` its existing GitHub Actions and log each one. `1` = test-CI only — a workflow whose name or file says `release`, `deploy`, `publish`, `pages` or `cd` keeps running; `all` = release and deploy too; `0` = touch nothing (the opt-out). See [No GitHub CI](#no-github-ci--the-gate-is-local) |
| `HARNESS_USAGE_CHECKPOINT_PCT` | `90` | At this % of any usage window (Claude Code's 5-hour and weekly limits), checkpoint every live session to GitHub and hold new claims until the window resets. See [Usage-limit checkpoints](#usage-limit-checkpoints) |
| `HARNESS_ONE_USD_PER_PCT` | _(empty)_ | `harness forecast`'s fallback $ per 1% of a usage window, for an account/window with no calibration yet (no usable `usage_reading` pair). Read from the environment, else this config. Empty = `n/a`. See [Cost forecast](#cost-forecast) |
| `HARNESS_ONE_STOP_PCT` | `98` | `/harness-one`'s gate: recommend APPROVE only when every usage window's `now% + p80% + HARNESS_ONE_RESERVE_PCT` stays at or under this %. See [One issue at a time](#one-issue-at-a-time-harness-one) |
| `HARNESS_ONE_RESERVE_PCT` | `2` | % of a window the gate holds back for the checkpoint (commit, push, handoff) when the budget runs out |
| `HARNESS_ONE_STALE_MIN` | `30` | A usage reading older than this many minutes, or of unknown age, is stale… |
| `HARNESS_ONE_STALE_PAD_PCT` | `3` | …and the gate adds this many points to it |
| `HARNESS_ONE_LEASE_MIN` | `240` | Minutes a `/harness-one` claim keeps the pool's reapers and lock sweeps off its issue after the last `harness one start`/`phase`; past it the session counts as dead and the pool reaps the issue like a dead lane |
| `HARNESS_ONE_AUTO` | `0` | `1` = when a usage hold engages (`HARNESS_USAGE_CHECKPOINT_PCT`), the engine starts ONE harness-one lane per account by itself, gated against `HARNESS_ONE_STOP_PCT` like `/harness-one` but with no human prompt. `0` = a hold leaves the fleet idle until the window resets. See [Auto harness-one lane](#auto-harness-one-lane-harness_one_auto) |
| `HARNESS_USAGE_CMD` | _(empty)_ | Your own usage source, for any CLI: a command printing `<account>\t<window>\t<pct>\t<resets_at epoch>` lines. Overrides the CLI adapter |
| `HARNESS_GH_RATE_GUARD` | `1` | `1` = on a GitHub rate limit, sleep the dispatchers until the token's reset instead of retrying every poll, and stop claiming new work when the budget runs low. `0` = off. See [GitHub rate limits](#github-rate-limits) |
| `HARNESS_GH_BUDGET_PCT` | `20` | Below this % of the token's `core` or `graphql` budget, claim nothing new and poll at half rate until the reset, leaving the rest to live agents |
| `HARNESS_GH_RATE_TTL` | `60` | Seconds one `gh api rate_limit` probe is reused by every worker on the host |
| `HARNESS_ORPHAN_LOCK_MIN` | `20` | Minutes an open `agent-working` issue may sit with no live session (impl, orch, or bug lane) and no worktree before the pool worker unlocks it with a comment. A reap whose unlock `gh` refused (an outage) is queued instead and retried every poll until it lands |
| `HARNESS_BLOCKED_BACKOFF_MIN` | `0` | An autonomous fleet ends a lane that labels its issue `agent-blocked` and parks the issue: it is not re-dispatched until someone comments on it or edits its labels. This many minutes after the park it is retried even unchanged; `0` = only on a change. A non-autonomous fleet never dispatches `agent-blocked` work |
| `HARNESS_SELFPARK_GRACE_MIN` | `30` | An autonomous fleet's impl lane may label its issue `agent-paused` only when a `HARNESS CHECKPOINT` was sent to it (`pause --force`, the usage checkpoint, `harness one`; each records `run/<session>.checkpoint`). One that parks itself (`agent-paused`, no `agent-working`, no checkpoint sent) gets one nudge to decide and continue; still parked this many minutes later, it is checkpointed (branch pushed, `harness-handoff` comment) and ended, and the issue is resumed from `resume.md`. A non-autonomous fleet never checks |
| `HARNESS_USAGE_STATUSLINE` | `1` | `1` = set the status line of each Harness-owned Claude Code worktree to `scripts/usage-statusline.sh`, which reports the usage windows (an existing `statusLine` there is kept). `0` = off; Claude usage is then unavailable unless `HARNESS_USAGE_CMD` is set |
| `HARNESS_LABEL_PAUSED` | `agent-paused` | Label on an issue checkpointed by `pause --force` or a usage-limit checkpoint |
| `HARNESS_PAUSE_GRACE` | `300` | Seconds `pause --force` waits for agents to checkpoint |

### Headless lanes

With `HARNESS_SESSION_BACKEND=headless` a lane is not a tmux session but a detached background process: the
CLI's headless lane runner: one shared core (`scripts/cli/headless_core.py`) plus a small per-CLI adapter
(`scripts/cli/<cli>_headless.py`, [the adapter contract](#headless-adapter-contract)). Six exist so far:
`scripts/cli/claude_headless.py` (also claude's entry point), `scripts/cli/codex_headless.py` (#481: one `codex exec --json`
per turn, `exec resume <thread id>` after the first), `scripts/cli/opencode_headless.py` (#482),
`scripts/cli/hermes_headless.py` (#484), `scripts/cli/copilot_headless.py` (#483) `scripts/cli/openclaw_headless.py` (#485) and `scripts/cli/agy_headless.py` (#486); with any other CLI
`harness init`, `harness doctor` and `harness start` refuse the pair, naming the CLI as tmux-only. The list
of headless CLIs is the adapter files present: dropping a `<cli>_headless.py` beside `<cli>.sh` enables that CLI
on the headless backend, with no edit to the refusal.

**How a lane runs.** `launch_agent` prepares the worktree as it does for a pane (trust, bypass, the goal
loop's state file), then starts the runner in the worktree (under `setsid`, so the worker that started it
can exit). The runner runs one `claude -p --output-format stream-json --verbose` per message, the
bootstrap first; every later turn passes `--resume <session id>`, so the lane is one claude session. There
is no launch line typed into a shell and no terminal: `cli_send` (a watchdog nudge, a supervisor's, the
goal loop's next prompt) appends a message to the lane's inbox, and a message that arrives mid-turn waits
for the next turn. The goal loop is the driven one (`goal_loop_tick`): a turn that ends without the
promise is re-prompted from the lane's last reply; where ralph-loop's Stop hook runs inside `claude -p`
too, it holds the turn open until the promise and the driven loop finds the loop already over.

**An `opencode` lane** (#482) runs one `opencode run --format json` per message, the message on stdin. OpenCode
names its own sessions (`ses_…`): the first turn passes none, the id is read off its first event, and every
later turn (or a relaunched lane's first) passes `--session <id>`. A session OpenCode no longer has ends in
`Error: Session not found` and no JSON; the runner starts it afresh, as for claude. Each turn runs with
`OPENCODE_CONFIG_CONTENT={"permission":{"question":"deny"}}` (an unanswerable question would hold the turn
forever) and the configured flags (`--auto` by default), the lane's model as `-m` and its effort as `--variant`.
The loop is Harness's driven one, not the `opencode-ralph.js` plugin's, which only a pane loads. The turn's
state comes from its events: a `step_finish` with `reason: stop` and exit 0 is `idle`; an `error` event
that is a quota (`insufficient_quota`, `usage limit reached`, `Free usage exceeded`) is `limit` (the reset
time is the provider's "reset in N unit" when it prints one); any other error, or an exit with no finished
step, is `transient`. OpenCode has no quota meter, so `state.json`'s `rate_limit` stays empty and the
usage-windows row is n/a; the session's tokens and models are read from its `opencode.db` by the same
`opencode_usage` a pane's session uses, which is what the stats sweep folds.

**A `hermes` lane** (#484) runs one `hermes chat --format stream-json --yolo --accept-hooks -c <session>
--create-if-missing --query-file -` per message, the message on stdin, in the lane's own Hermes profile
(`HERMES_HOME=<operator home>/profiles/harness<sha1 of the worktree>`, the profile a tmux hermes lane has: seeded
from the operator's home with approvals off, the lane's model and effort, its trusted dirs and variables, since Hermes
refuses `-m` and `--reasoning` beside `-c`). `-c` takes the lane's id as the session's title on the first turn and finds
it again on every later one, so all of a lane's turns are one Hermes session; the id the first `result` reports
(`local-…`) is what the lane then keeps, and what a relaunched lane (`--resume`) passes. The state of a turn comes from
its `result`: `exit_code` 0 and no `error` is `idle` (the reply is its `text`); an `error` that is a quota (a usage
limit, exhausted credits, a Nous account's rate limit) is `limit`, its reset the text's `(in 2h 00m)`; any other error
(a 503, a plain 429 with no reset), or an exit with no `result`, is `transient`. Usage windows are not in the stream
(`state.json`'s `rate_limit` stays empty): `hermes usage --json` reads the provider's, as for a pane, and the session's
tokens and models come from the profile's `state.db` by the same `hermes_usage` a pane's session uses. Hermes runs a
turn's commands in its host gateway, so killing a turn's process ends the client and not the command: on a stop or an
interrupt the runner also stops the lane's gateway (`hermes gateway stop -y`) and lifts the park that leaves on the
profile, without which the next turn fails after 60 s. The loop is Harness's driven one (`hermes_loop`).

**A copilot lane** runs one `copilot --output-format json --session-id=<id> <the configured flags>` per message, the
message on stdin (`--yolo --no-ask-user --no-auto-update` by default, `HARNESS_COPILOT_FLAGS`; the lane's model and
effort replace theirs, and `--effort` rides only with a model named, because `-p` refuses it with Auto). Copilot
creates the session under `--session-id` when it is new and resumes it when it exists, so every turn, a relaunch
after a checkpoint and a session the CLI lost all name the same id: the lane is one copilot session, with no
separate resume flag. The turn's JSONL ends with a `result` record (`exitCode`, `sessionId`, `usage`); an exit
other than 0 whose error text (a `session.error` event, or stderr when copilot could not start the turn) is one of
its quota messages (`You've hit your rate limit`, `You've reached your weekly rate limit`, `You've run out of your
included AI credits`, …) is a `limit`, which names no reset time; any other failed turn is `transient`. The lane's
last reply is its last non-empty `assistant.message`. Sign-in is copilot's own (`COPILOT_GITHUB_TOKEN` / `GH_TOKEN`,
`copilot login`, or the GitHub CLI's login); `COPILOT_HOME` moves its state. A pane of copilot draws no turn timer, but a headless lane's drawn screen has one, so the stuck-turn interrupt (`HARNESS_TURN_MAX`, #207) reaches a lane whose checkpoint is queued behind a long turn.

**An `openclaw` lane** (#485) runs one `openclaw agent exec --json --message-file -` per message, the message on
stdin, on the lane's own config (`<worktree>/.harness-openclaw/openclaw.json`, written at launch as a tmux lane's is:
the operator's config included, `tools.exec.mode` full, the user skill dirs) with `--cwd <worktree>`,
`--state-dir <worktree>/.harness-openclaw`, `--timeout` and the lane's `--model` / `--thinking`. `agent exec` has no
resume id: every turn is its own isolated OpenClaw session, so the lane stays the Harness one: its id (the launch's, or
the one a relaunched lane carries on) never changes, and each turn's envelope is appended to
`.harness-openclaw/runs/<lane id>.jsonl`, the transcript `openclaw_transcripts` and `openclaw_usage` read for the stats
sweep, as for a pane. OpenClaw prints no stream: one pretty-printed JSON envelope when the turn ends (`ok`, `status`,
`final`, `usage`, `sessionId`, and `error` on a failure), which the core reads whole (the adapter's `json_documents`). An
envelope with `ok` true is `idle` (the reply is `final`); a failed one whose error is a quota or billing message (a
provider's usage limit, OpenClaw's `The AI service needs a short break` once its 429 retries give up) is `limit`, its
reset the message's `Retry-After: 7200 seconds` when it has one; any other error, or an exit with no envelope, is
`transient`. Usage windows are not in the envelope (`state.json`'s `rate_limit` stays empty): `openclaw status --usage
--json` reads the providers', as for a pane. The loop is Harness's driven one (`openclaw_loop`).

**Where a lane lives.** `$HARNESS_HOME/lanes/<session name>/` (`HARNESS_HEADLESS_DIR` overrides the root),
host-wide like the tmux server:

| file | what |
|---|---|
| `inbox.jsonl` | messages for the lane, one JSON object per line, delivered in order as turns |
| `events.jsonl` | every stream-json event claude printed, plus the runner's `turn_start` / `turn_end` markers |
| `state.json` | `idle` / `busy` / `limit` / `transient` / `ended`, read from stream-json events (never screen text), plus the session id, turn count, the running turn's start, the last reply, the limit's reset |
| `stderr.log`, `runner.log` | claude's stderr per turn; the runner's own output |
| `pid`, `dir`, `created` | the runner's process id, start directory and start time |
| `stop`, `interrupt` | requests: end the lane (the runner ends its turn's whole process tree and exits) / end only the running turn |

A lane is live while its runner's pid is alive and its state is not `ended`. The engine reads it the way
it reads a pane: `sess_capture` draws `state.json` and the undelivered inbox in the claude TUI's shapes
(the spinner while busy, `You've hit your usage limit · resets …` or `API Error: …` above the prompt
after such a turn, queued messages in the input box), so the usage-limit watchdog parks a `limit` lane and
nudges it on reset, the #115 watchdog nudges then kills a `transient` one, and a turn stuck with nudges
queued behind it is interrupted (`interrupt`), exactly as on tmux. `harness stop` stops every lane (stop
request + SIGTERM, then SIGKILL of the runner's and claude's process groups) and `harness status` counts
them.

**Checkpoint and resume.** `harness pause --force` sends a headless lane the same checkpoint message as
a pane (it waits in the inbox behind a running turn), then waits for both the `agent-paused` label and the
lane's own state: once the checkpoint turn has ended (`state.json` past that turn, nothing queued) the lane
is ended — a pane is left running, a lane has nothing left to do. The lane directory stays, its
`state.json` naming the claude session it ran. When the issue is dispatched again — `harness resume`'s
workers picking up the `agent-paused` issue, or the pool re-claiming one the crash-recovery sweep
(`harness start --recover`) freed from a lane whose runner died with the box — `launch_agent` relaunches
the lane in the same worktree and carries on that session: the runner starts with `--resume`, its first
turn the bootstrap (now the resume prompt) under `claude -p --resume <session id>`, and the goal loop's
state names the same id. Only issue lanes (impl, bug triage/fix) carry on; an orch or inject session starts
fresh, and a pane always does. Should claude no longer have the session (`No conversation found`), the
runner runs that first message again as a new session under the same id.

**The host supervisor.** `harness supervise` applies every rule it has for panes to a headless fleet's
lanes, with no tmux on the host: a lane quiet for `NUDGE_MIN` is nudged through its inbox, one still quiet
at `KILL_MIN` after that nudge is checkpointed to GitHub and then stopped, a turn stuck past
`HARNESS_TURN_MAX` with a nudge queued behind it is interrupted (the nudge then runs as the next turn), a
`limit` lane is left parked, and the arc rules read the lane's drawn screen. Activity is the drawn screen
(the busy spinner's timer ticks), the CPU of the runner's process tree (claude's turn included), and the
lane's own activity mark (`sess_activity`: its turn count and the size of `events.jsonl`) — the drawn
screen holds no reply text, so a turn that ran and ended between two passes changes only the mark. Each
fleet's own `HARNESS_SESSION_BACKEND` decides how its sessions are read, so one supervisor watches tmux and
headless fleets side by side; its systemd unit's `PATH` takes every backend's binaries the host has and
requires none of them.

**Usage, stats and status.** A headless claude runs no status line, so the usage watch reads a lane's
windows off the `rate_limit_event`s claude prints: the runner keeps the latest in `state.json`
(`rate_limit`, `rate_limit_at`) with the account the lane runs on (`account`: its `CLAUDE_CONFIG_DIR`'s
name, `default` without one — the status line's rule), and the claude adapter reports each account window
from the newest reading of this fleet's lanes (`<prefix>-…`) or status-line drops (utilization × 100, a
window past its reset skipped) — a sibling fleet's account never holds this fleet's claims. At `HARNESS_USAGE_CHECKPOINT_PCT` every live lane on that account (or of unknown
account) is sent the checkpoint message, which waits behind a running turn, and claims are held, as on
tmux; once the lane's checkpoint turn has ended with its issue `agent-paused`, the next usage pass ends the
lane (`usage: lane parked after its checkpoint`) and the resume carries on its claude session. A lane
frozen at the limit gets the mechanical checkpoint, as a pane does. `session_end` is emitted by the
usual sweep once the lane's runner has exited; its tokens come from claude's transcript when there is one,
else from the lane's `events.jsonl` — the sum of each turn's own stream-json `result` usage (a turn
cut off before its result counts its assistant messages' usage), found by the session id `state.json`
names. A `--resume`d turn's `modelUsage` is the session's running total, so a turn's own is its
`model_usage_since_last_result`, or its `modelUsage` less the previous turn's when claude prints none
(#426). A lane relaunched on its claude session (after a checkpoint, a crash or a usage park) appends to
the same transcript: its `session_end` reports only what that run added — the transcript's total less
what the session's earlier `session_end`s reported — flagged `resumed: true`, and `harness stats` adds
it to the session's earlier runs. A tmux lane never resumes a session id, so it is unchanged. A headless **copilot** lane's tokens and windows are copilot's own files, read as for a copilot pane: `copilot -p` writes `session.usage_record` events to `$COPILOT_HOME/session-state/<id>/events.jsonl` (the stats sweep folds them through the adapter, `inputTokens` less the cache reads and writes, and a resumed run reports only what it added) and the account's `quotaSnapshots` there too when the CLI prints them (`cli_limit_usage`; the 1.0.105 print mode printed none on the Free plan, so its windows are the newest a copilot session on the host has). `harness status` shows each lane's state beside its session row
(`headless: busy`); fleetview and `harness web` list every live lane on the host — tmux sessions and
headless lanes alike, whichever backend the viewer runs on — with its model (off its runner's flags) and
state.

**Attaching to a lane.** `harness attach <unit> [issue]` (or `harness attach <session>`) follows the lane
live — each turn, its tool calls and its reply as they land in `events.jsonl` — and drives it, on every OS:
a line you type goes to the lane's inbox through `cli_send` and runs as the next turn, queued behind a turn
that is still running (attach says `queued behind the running turn` or `sent`; blank lines send nothing).
Ctrl-C **detaches**: it ends the attach and its watch, and never the lane — the runner is not signalled, its
state is unchanged, and `harness attach` reattaches. With stdin closed or not a terminal it is the read-only
watch. `python3 scripts/cli/headless_core.py state --lane <dir>` (or `claude_headless.py state`, the
same command) prints its `state.json`;
`tail -F <dir>/events.jsonl` is the raw stream. (A tmux lane attaches with tmux itself; detach with Ctrl-b d.)

**Smoke run.** `SMOKE_BACKEND=headless bash test/smoke/fleet_smoke.sh claude` runs one real fleet on
the headless backend through a trivial issue in a sandbox repo: claim → lane → PR → merge → close. Midway
it checkpoints and resumes the lane (`SMOKE_CHECKPOINT`, on by default on headless): once the lane has run
`SMOKE_CHECKPOINT_AFTER` seconds (90), `harness pause --force` checkpoints it to GitHub and ends it, and
`harness resume` re-dispatches the `agent-paused` issue, which the resumed lane then finishes. The
sandbox's `HARNESS_TURN_MAX` is lowered (`SMOKE_TURN_MAX`, 120) so the stuck-turn interrupt lets the
queued checkpoint into a long turn. The run fails if the issue closed before the checkpoint, or if the
checkpoint was never confirmed. Recorded runs are committed under `test/smoke/logs/`. On native
Windows (#357) the smoke defaults to the headless backend, refuses tmux and every CLI without a headless runner, logs
`harness doctor` after setup and names its log `claude-headless-windows-<stamp>.log`;
`test\smoke\fleet_smoke.cmd claude` runs it from cmd, PowerShell or ssh through Git's `bash.exe`. See
[the Windows runbook](windows-smoke.md).

### Headless adapter contract

`scripts/cli/headless_core.py` is the one runner every headless lane runs; a CLI adds
`scripts/cli/<cli>_headless.py` and nothing else of the runner. **The core owns** the lane's files (the
inbox, `events.jsonl`, `stderr.log`, `state.json`, the `stop` and `interrupt` requests), the `busy` /
`idle` / `limit` / `transient` / `ended` states, delivery of one inbox message per turn, interrupt (ends
the running turn's process tree, the lane stays up), stop (ends the turn and the lane), a runner restarted
on the same lane directory, the `pane` the watchdog reads (the lane drawn in the shapes claude's TUI
prints, so one set of pane regexes reads every CLI's lane) and `watch`. The usage watch reads the
core's `state.json` (`rate_limit`, `rate_limit_at`, `account`); the stats sweep (`scripts/stats.py`) folds the
lane's `events.jsonl` when the lane is claude's (`state.json`'s `adapter`), whose per-turn usage it reads off claude's
stream-json `result` events; another CLI's lane is folded by that CLI's own adapter: a CLI whose stream differs has the
sweep read the CLI's own transcripts (`cli_transcripts`, `cli_usage`), as codex and openclaw do. **The adapter
owns** what differs per CLI: starting one turn, reading its stream, and saying what usage and limits it
reported.

An adapter module defines `ADAPTER` (an object with the members below) and an entry point,
`sys.exit(core.main(adapter=ADAPTER, prog="<cli>_headless.py"))` after `sys.path.insert`ing its own
directory and `import headless_core as core` (see `claude_headless.py`). Every member is
required unless marked optional:

| member | contract |
|---|---|
| `name` | the CLI's name (`claude`); written to `state.json` as `adapter`, which is how `watch` finds the adapter again |
| `default_bin` | the command that runs the CLI, used when `run` gets no `--bin` |
| `account()` | the account the lane runs on (claude: the config dir's name), written as `account` for the usage watch |
| `argv(bin, session_id, session_started, model, effort, flags)` | one turn's command as a list. `bin` and `flags` are lists already split. The message is **not** in it: the core writes it to the process's stdin and closes it. `session_started` is false until the CLI has reported its session: pass the id as the new session's id (or none, if the CLI picks its own), and when true, the CLI's resume option with it, so the lane is one session across turns |
| `new_turn()` | a fresh per-turn reader, below |
| `watch_line(ev)` | one `events.jsonl` event as `harness attach` prints it, or `None` to leave it out |
| `env(cwd)` _(optional)_ | variables set on top of the runner's own for every turn's process (`<cwd>` is the lane's worktree): opencode's question-deny config, hermes's lane profile (`HERMES_HOME`) |
| `json_documents` _(optional)_ | `True` for a CLI that prints one JSON document per turn rather than one event per line (openclaw's pretty-printed envelope): the core then reads stdout as whole documents, each one an event, with the same `stdout` marker for output that is not JSON (#485) |
| `stdin_payload(text)` _(optional)_ | what a turn's process is sent on stdin for a message, when that is not the text itself (default: the text): agy reads a prompt as one stream-json line, `{"event":"user","message":{"content":<text>}}` (#486) |
| `abort_turn(bin, cwd)` _(optional)_ | called after the runner killed a turn's process tree on a stop or an interrupt, for a CLI whose turn outlives its client: hermes runs a turn's commands in its host gateway, so it stops the lane's gateway there (#484). Errors are swallowed |

A **turn reader** folds one turn's events. The core feeds it every stdout line that parsed as JSON
(`{"type":"harness","subtype":"stdout","line":…}` is recorded for one that did not, and is fed too), in
order, from a reader thread, then asks for the outcome once the process exited:

| member | contract |
|---|---|
| `feed(ev)` | take one event (a dict). Never raise on an event it does not know |
| `session_id` | the CLI's session id once an event shows it, else `None`. The core saves it and passes it as the resume id on every later turn |
| `rate_limit` | the latest usage / limit info the CLI reported (any JSON-able dict), else `None`; saved as `rate_limit` and stamped `rate_limit_at` when it changes |
| `retry` | the CLI's own in-turn retry (`{"attempt": …, "max_retries": …}`), else `None`; the `pane` draws a `busy` lane as `Retrying (attempt a/m)` |
| `no_conversation` | true when the CLI had no session to resume. The core then starts that message again as a new session under the same id (#350) |
| `outcome(rc, stderr_tail)` | `(state, reply, error, limit_resets_at)` once the process exited `rc`: `("idle", reply, None, None)` for a turn that ended well; `("limit", reply, error, resets_at)` when the account's quota is out (`resets_at` epoch seconds or `None`); `("transient", reply, error, None)` for any other failed turn, including an exit with no final event. State comes from events and the exit code, **never** from screen text. A `limit` lane waits for the reset (the watchdog, `usage.sh`), a `transient` one is nudged and retried |

**A CLI that names its own session** (`codex`: the `thread_id` of `thread.started`) is run the same way: the
adapter's `argv` gets Harness's id for a new session and ignores it, the turn reader's `session_id` is the
CLI's own, and the core saves that as the lane's session and passes it back on every later turn. Anything
that needs the session's id before the first turn ends has none; after it, `cli_session_id` reads it off the
lane (`headless_lane_session`), not off the CLI's own files. **The screen is claude's**: a headless lane is drawn in the shapes claude's TUI prints whichever CLI it runs, so an
adapter's `<cli>.sh` answers its pane regexes (`<cli>_idle_re`, `_busy_re`, `_limit_re`, `_transient_re`,
`_interrupted_re`, `_turn_secs`) with claude's shapes while `sess_backend` is `headless` (see `codex.sh`).
**Usage** comes from wherever the CLI keeps
it: a CLI whose stream carries no rate-limit windows keeps reporting them from its own files (codex: the
rollout every `exec` turn writes, read by `codex_limit_usage` and `codex_usage` exactly as for a pane).

`cli_headless_list` is the adapter files present, so adding `<cli>_headless.py` beside `<cli>.sh` is all it takes
for `cli_backend_check` to stop refusing that CLI. Its `<cli>_headless` function in `<cli>.sh` (the runner's
argv, one word per line: see `claude_headless` in `claude.sh`) is optional: without one, `cli_headless`
starts `python3 <cli>_headless.py run --cwd … --session-id … --message …` and the adapter's `default_bin`
runs. `test/test_headless_core.py` runs the core through a fake CLI and a fake adapter
(`test/fixtures/headless-core/`) and is the executable form of this section: a new adapter's own test
should show the same seven behaviours against its CLI's captured output — turn start, resume id, event
parse, usage, limit → `limit`, transient retry, interrupt and stop.

### Portable process and lock primitives

The engine's process and locking primitives live in `scripts/portable.sh` and `scripts/portable.py`
(#355, [ADR 0001](adr/0001-native-windows-runtime.md)), so the same engine runs under Git Bash on native
Windows. On Linux each helper runs what the engine ran before; under Git Bash (`uname -s` MINGW/MSYS)
it takes the Windows path:

| Helper | Linux | Windows (Git Bash) |
|---|---|---|
| `lock_acquire` / `lock_try` / `lock_release` | `flock` on an fd | atomic `mkdir <lock>.d` + an `owner` file (`pid`, `winpid`, cmdline); a dead owner's lock is stolen (`HARNESS_LOCK_STALE_S`, 30, for one with no owner yet) |
| `lock_holders` / `lock_free` | `/proc/*/fd` scan / `flock -n` | the lock's live `owner` |
| `proc_find <regex>` | bash scan of `/proc/[0-9]*/cmdline` (no `pgrep`) | the same (MSYS `/proc`) |
| `proc_alive` / `proc_ident` / `proc_args` | `kill -0` + procps `ps -o` | `kill -0`, `/proc/<pid>/winpid` + cmdline |
| `proc_kill_tree` | process-group `kill -KILL` | `taskkill //T //F //PID <winpid>` |
| `detach_prefix` | `setsid` | none |
| `new_uuid` | `uuidgen`, else the kernel's | `python3 -c 'import uuid…'` |
| `export_native_paths` | no-op | exported path variables (`STATE_DIR`, `HARNESS_HOME`, …) in `cygpath -m` form |
| `portable.pid_alive` (Python) | `os.kill(pid, 0)` | `OpenProcess` + `GetExitCodeProcess` on the winpid |
| `portable.lock_nb` / `unlock` (Python) | `fcntl.flock` | `msvcrt.locking` on byte 0 |

| `detach_launch [-a] <pidfile> <log> <cmd…>` | `nohup … &` and `$!` (fd 9 closed) | `Win32_Process.Create` through `powershell Invoke-CimMethod`: the process is WMI's child, so it outlives the ssh session; a launcher beside the pid file restores the caller's environment and directory and records the MSYS pid |
| `win_task_install` / `win_task_uninstall` | not used (systemd user units) | a Task Scheduler task `Harness\<name>` running Git's `bash.exe` on a launcher script under `$HARNESS_HOME/tasks` |

`HARNESS_PLATFORM=windows` forces the Windows paths (the suite runs them on Linux: `test/test_portable.sh`,
`test/test_portable.py`), and `test/test_portable_guard.py` fails on a raw `flock`, `/proc`, `pgrep`,
`setsid`, `uuidgen`, procps `ps -o`, `fcntl` or `os.kill` anywhere else in the engine, except the uses it
allowlists with their reasons (tmux-only CLIs, the self-contained lane runner's POSIX branch, `install.sh`).

### Native Windows

Harness runs on native Windows under Git for Windows' bash with a native Python 3, on the headless
session backend only ([ADR 0001](adr/0001-native-windows-runtime.md), #356). Linux is unchanged.
[The Windows runbook](windows-smoke.md) sets up a host step by step and runs the fleet smoke on it.

- **Install:** run `install.sh` from Git Bash. It needs Git for Windows (git, curl, sha256sum, tar), a
  Python 3 that runs, `gh` and `claude`; tmux is not needed. It offers each missing one through winget
  (`Git.Git`, `Python.Python.3.13`, `GitHub.cli`, `Anthropic.ClaudeCode`, and `OpenJS.NodeJS.LTS` for
  rtdd's installer), one question each; `HARNESS_INSTALL_PREREQS=1` accepts without asking, `0`
  declines, and `HARNESS_WINGET` names the winget binary. The Microsoft Store `python3` stub counts as
  missing. It checks Developer Mode (the registry; off is only a problem when this shell cannot make a
  symlink either) and the git identity, and prints the exact fix for each. Harness sets
  `core.longpaths=true`, `core.autocrlf=false` and `core.eol=lf` per repo (`git -C <worktree> config`
  on its checkout and every lane worktree), never `--global` or `--system`. It makes every link it creates a real
  symlink (`MSYS=winsymlinks:nativestrict`; enable Developer Mode or run as an administrator), writes
  a `python3` shim in `$HARNESS_HOME/bin` (the `python3` on a stock host's PATH is the Microsoft Store
  stub) that runs `HARNESS_PYTHON` (default: the first of `python3`, `python`, `py -3` that runs), and
  a `harness.cmd` next to the `harness` link that runs it through Git's `bash.exe` by path (the
  `bash.exe` on the cmd PATH is WSL's). `harness update` rewrites the shim. `.gitattributes` keeps a
  git-checkout engine LF under Git's default `core.autocrlf=true`.
- **Fleet:** set `HARNESS_SESSION_BACKEND=headless`; `harness start` refuses any other backend there.
  `harness start` launches the workers, the priority lane and the host poller with `detach_launch`,
  so they keep running after the ssh session that started them ends. `harness stop` stops them by
  their pid files, as on Linux.
- **Services:** `harness supervise --install` and `harness web --install` register Task Scheduler
  tasks in place of the systemd user units. The task runs `$HARNESS_HOME/tasks/<name>.sh`, which reruns
  the command after each exit (60s for supervise, 5s for web). It starts at logon only, in your
  session, never at boot, so registering it needs no administrator and a reboot does not start a
  test install's task. It has no run-time limit. The task names are unique per `HARNESS_HOME`: the
  default `~/.harness` keeps `Harness\harness-supervise` and `Harness\harness-web`, and any other home
  appends the first 8 hex digits of a SHA-256 of its path (`Harness\harness-supervise-1a2b3c4d`), so a
  test install never collides with a real one. `--uninstall`, `harness update` and `uninstall.sh` act
  on the current home's task as they do on the unit, and leave other homes' tasks alone. An install
  made before this change registered the same names with a boot trigger; re-running
  `harness supervise --install` / `harness web --install` (which `harness update` does) re-registers
  them logon-only.
- **Install entry points:** both lines work from Git Bash, `npx -y github:VocanicZ/Harness` and
  `curl -fsSL https://raw.githubusercontent.com/VocanicZ/Harness/main/install.sh | bash`. The npx entry runs
  `install.sh` under Git's `bash.exe` by path (`HARNESS_BASH_EXE`, else Git for Windows' root from `EXEPATH` or
  `git --exec-path`, else the usual install dirs; only a bash that answers MINGW/MSYS counts), never npx's plain
  `bash`, which is WSL's. `HARNESS_REF=<tag>` pins the release as on Linux. Re-running either line over an install
  changes nothing: same engine link, same `releases/`, same bin dir.
- **Update and rollback:** `harness update` is the Linux lifecycle on Windows: it downloads the release, verifies
  SHA256SUMS, flips the `engine` link (a real symlink) with one rename, prunes to the current release plus the previous 2,
  hands off to the new release's `update.sh --post-flip`, which rewrites the python3 shim, ensures rtdd, re-registers the
  supervise and web tasks (their launchers run the engine through its link, so they follow it) and re-links the skills
  (`--with-skills` adds the plugins). `harness update --rollback` flips back and redeploys; a second one goes forward again.
  Two Windows rules shape it. **A directory cannot be renamed while any file in it is open**, and a git-checkout engine's
  own `update.sh` is such a file, so on Windows that update runs from a temp copy of itself before the checkout is moved
  aside to `releases/git-<sha>` (#281); if something else still has a file open there (a running fleet, a shell whose
  folder is inside the engine) the move fails with a message to `harness stop` and leave the folder. **A release older than
  the Windows lifecycle (#356, v0.1.1 and every release before it) copies instead of linking**, so after a rollback onto
  one `harness update --rollback` prints how to come forward again (`MSYS=winsymlinks:nativestrict harness update
  --rollback`). Upgrading from a v0.1.1 git checkout: its own `harness update` fast-forwards the checkout to current code
  (or fails if it is on a detached HEAD); the next `harness update`, or the install line, migrates it onto releases.
- **`harness doctor`** adds a `windows:` section that checks the headless backend, that the shell and
  the tasks' `bash.exe` are Git's (`uname -s` MINGW/MSYS, not WSL), that a Python 3 runs, that a
  symlink can be made, that the engine is LF, and that `schtasks`, `powershell` and `taskkill` are
  present; and the installer's own prerequisites: `gh`, an agent CLI, Developer Mode, the git identity
  and the checkout's per-repo git settings (`harness doctor --fix` writes those), with rtdd/Node as a
  note. It also checks the engine: a real link into `releases/` (a plain folder means Git Bash copied instead of linking; a dangling link names the reinstall), no leftover `engine.flip.*` or `.staging-*`, `harness` on PATH a link, and each task's launcher running the engine through its link; a **rolled-back** engine (a newer release kept beside it) is reported with the command that goes forward. Each failure names its fix, with the winget command where there is one. When the engine is gone
  but Harness left something on the host (a task of this home or its launcher, the python3 shim,
  `harness.cmd`, the poller, the fleet registry), the section lists each and names the one command that
  removes them: `bash <a Harness checkout>/scripts/uninstall.sh --force --force-engine`.
- **`harness uninstall [--force] [--force-engine]`** removes everything Harness put on the host, not
  just the engine and the `harness` link: this home's Task Scheduler tasks (one per launcher under
  `$HARNESS_HOME/tasks`, by the per-home name above, so another home's tasks stay) with their launchers,
  `harness.cmd` and the python3 shim, the `/harness*` skill links in every CLI's skills dir, the running
  poller (by the pid in its pidfile, and only while that pid is still a `poller.sh`), the poller's
  registry, the fleet registry, snapshots, event logs, supervisor state and log, and `HARNESS_HOME`
  itself once that leaves it empty. It removes only what Harness wrote: `harness.cmd` and the shim only
  when they carry Harness's own text, nothing else in the bin dir or `HARNESS_HOME` (a `supervise.conf`
  you wrote stays). Because a running worker holds its scripts open on Windows, **`--force-engine` is
  refused while another fleet still uses the engine** (a live worker of another project, or another
  project registered active): nothing is removed, and the message says to stop that fleet first. On
  Linux `--force-engine` still overrides that guard. `test/test_windows_uninstall.sh` records what an
  install creates (with the real installer functions and `supervise` / `web --install`) and asserts
  uninstall leaves none of it, leaves a user's file beside it, and leaves a second home's tasks alone.

Knobs (the suite fakes each Windows tool with them): `HARNESS_PYTHON`, `HARNESS_BASH_EXE` (Git's
`bash.exe`), `HARNESS_WINGET`, `HARNESS_REG` (`reg.exe`, for Developer Mode), `HARNESS_SCHTASKS`, `HARNESS_POWERSHELL`, `HARNESS_DETACH_WAIT` (seconds `detach_launch`
waits for the pid, 30). `test/test_windows_lifecycle.sh` covers the lifecycle with
`HARNESS_PLATFORM=windows` on Linux; `test/test_windows_installer.sh` covers the winget offers, the
Developer Mode and git identity checks, the per-repo git settings and the doctor lines;
`test/test_windows_uninstall.sh` covers uninstall and the doctor's leftover check.

### Windows parity matrix

What works on native Windows (Git Bash, headless session backend) next to Linux, one row per `harness`
subcommand, `/harness*` skill, agent CLI and lifecycle feature (PRD #475). It is the contract the Windows
work is built and tested against; `test/test_windows_parity_doc.sh` keeps it complete and honest.

How to read a cell:

- `✓` — works there today. On Windows that means it has run on a real host (the winsma smoke, #358) or is part of a path that did.
- `✓ target (#475 task N)` — not yet shown working on Windows, and **still a target**, not a gap we accept. Task `N` of PRD #475 flips it to `✓`.
  "Not verified on winsma" is never a reason to write `n/a`.
- `n/a: <reason> ([source](https://…))` — Windows physically cannot do it. Allowed only for an external Linux-only service (HTCondor swarm submission)
  or an agent CLI whose vendor ships no Windows build or no non-interactive mode, and always with a link to the vendor or project page.
  No row is `n/a` on Windows today: every supported CLI ships a Windows build and a non-interactive mode (see the research below).

The PRD #475 tasks: 1 this matrix · 2 shared headless runner and per-CLI turn code · 3 `attach` send and detach · 4 Windows installer ·
5 lifecycle (install, update, rollback, uninstall) · 6 test suite on Windows · 7 lane tooling and skills · 8 end-to-end verification on winsma.

| feature | Linux | Windows |
|---|---|---|
| `harness install` | ✓ | ✓ |
| `harness version` | ✓ | ✓ |
| `harness update` | ✓ | ✓ target (#475 task 5) |
| `harness release` | ✓ | ✓ target (#475 task 8) |
| `harness poll` | ✓ | ✓ target (#475 task 8) |
| `harness stats` | ✓ | ✓ target (#475 task 8) |
| `harness forecast` | ✓ | ✓ target (#475 task 8) |
| `harness supervise` | ✓ | ✓ target (#475 task 8) |
| `harness web` | ✓ | ✓ target (#475 task 8) |
| `harness init` | ✓ | ✓ |
| `harness start` | ✓ | ✓ |
| `harness stop` | ✓ | ✓ |
| `harness status` | ✓ | ✓ target (#475 task 8) |
| `harness one` | ✓ | ✓ target (#475 task 8) |
| `harness doctor` | ✓ | ✓ |
| `harness attach` | ✓ | ✓ (headless lane: watch, typed lines, Ctrl-C detach) |
| `harness pause` | ✓ | ✓ |
| `harness setup` | ✓ | ✓ target (#475 task 8) |
| `harness migrate` | ✓ | ✓ target (#475 task 8) |
| `harness uninstall` | ✓ | ✓ |
| `harness plan` | ✓ | ✓ target (#475 task 8) |
| `harness prd` | ✓ | ✓ target (#475 task 8) |
| `harness issue` | ✓ | ✓ target (#475 task 8) |
| `harness resume` | ✓ | ✓ |
| `/harness` | ✓ | ✓ target (#475 task 7) |
| `/harness-arc` | ✓ | ✓ target (#475 task 8) |
| `/harness-init` | ✓ | ✓ target (#475 task 7) |
| `/harness-issue` | ✓ | ✓ target (#475 task 8) |
| `/harness-one` | ✓ | ✓ target (#475 task 8) |
| `/harness-pause` | ✓ | ✓ target (#475 task 7) |
| `/harness-plan` | ✓ | ✓ target (#475 task 8) |
| `/harness-prd` | ✓ | ✓ target (#475 task 8) |
| `/harness-resume` | ✓ | ✓ target (#475 task 7) |
| `/harness-start` | ✓ | ✓ target (#475 task 7) |
| `/harness-status` | ✓ | ✓ target (#475 task 8) |
| `/harness-stop` | ✓ | ✓ target (#475 task 7) |
| `/harness-uninstall` | ✓ | ✓ |
| `cli claude` | ✓ | ✓ (headless runner `scripts/cli/claude_headless.py`) |
| `cli agy` | ✓ | ✓ (headless runner `scripts/cli/agy_headless.py`; its `headless-*` rows pass from fixture replay under `HARNESS_PLATFORM=windows` but `headless-checkpoint` and `headless-resume`, which are red there for `claude` too; a winsma run is still #475 task 8) |
| `cli codex` | ✓ | ✓ (headless runner `scripts/cli/codex_headless.py`, `codex exec --json`; its `headless-*` rows pass from fixture replay on Linux, a winsma run is still #475 task 8) |
| `cli copilot` | ✓ | ✓ (headless runner `scripts/cli/copilot_headless.py`; its `headless-*` rows pass from fixture replay under `HARNESS_PLATFORM=windows`, a winsma run is still #475 task 8) |
| `cli opencode` | ✓ | ✓ (headless runner `scripts/cli/opencode_headless.py`) |
| `cli hermes` | ✓ | ✓ (headless runner `scripts/cli/hermes_headless.py`) |
| `cli openclaw` | ✓ | ✓ target (#475 task 2) |
| `rtdd` | ✓ | ✓ target (#475 task 7) |
| `supervise --install` | ✓ (systemd user unit) | ✓ (Task Scheduler task, #356) |
| `web --install` | ✓ (systemd user unit) | ✓ (Task Scheduler task, #356) |
| `harness-one` | ✓ | ✓ target (#475 task 8) |
| `inject` | ✓ | ✓ target (#475 task 8) |
| `pause --force and resume` | ✓ | ✓ |
| `headless attach: typed lines and Ctrl-C detach` | ✓ | ✓ (`test/test_headless_attach.sh`; winsma run: `test/smoke/logs/headless-attach-windows-20261104T033325Z.log`) |
| `install via npx` | ✓ | ✓ target (#475 task 5) |
| `install via curl` | ✓ | ✓ target (#475 task 5) |
| `install prerequisite offers` | ✓ (apt-get, dnf, pacman, zypper, apk or brew) | ✓ (winget: `Git.Git`, `Python.Python.3.13`, `GitHub.cli`, `Anthropic.ClaudeCode`, `OpenJS.NodeJS.LTS`) |
| `update --rollback` | ✓ | ✓ target (#475 task 5) |
| `swarm submission` | ✓ | n/a: swarm is a Linux-only HTCondor service ("Linux with systemd + cgroup v2", [VocanicZ/swarm README](https://github.com/VocanicZ/swarm#readme)); a Windows lane runs rtdd locally |

#### Non-interactive mode per agent CLI

What the per-CLI turn code of PRD #475 task 2 builds on. Each row is the exact command a headless turn runs, what it prints,
how the next turn resumes the session, how usage and rate limits come back, and the vendor's own Windows page.
Facts marked *(fixture)* were captured from the real CLI on the fleet host and are in
[cli-capabilities.md](cli-capabilities.md); the rest is cited. Researched 2026-11-04.

| cli | non-interactive command | output | resume | usage and limits | Windows build | sources |
|---|---|---|---|---|---|---|
| `claude` | `claude -p "<prompt>" --output-format stream-json --verbose`, prompt on stdin | NDJSON events; the last line is a `result` message | `--session-id <uuid>` on the first turn, `--resume <uuid>` after; `--continue` for the latest | the `result` carries `total_cost_usd` and `modelUsage.<model>` token counts; windows in `rate_limit_event`; a limit ends in an error `result` *(fixture)*; exit 0 on success | native: `irm https://claude.ai/install.ps1 \| iex` or `winget install Anthropic.ClaudeCode`; Git for Windows optional | [headless](https://code.claude.com/docs/en/headless), [setup](https://code.claude.com/docs/en/setup) |
| `codex` | `codex exec --json "<task>"` (stdin when the prompt is omitted or `-`) | JSONL: `thread.started`, `turn.started`, `item.*`, `turn.completed`, `turn.failed`, `error` | `codex exec resume <SESSION_ID>` or `codex exec resume --last "<prompt>"` | `turn.completed.usage` has `input_tokens`, `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens`; the docs do not say how a rate limit surfaces; the rollout's `token_count.rate_limits` carries windows *(fixture)* | native on Windows (PowerShell sandbox, no WSL needed); Windows 11 recommended, Windows 10 1809+ best effort | [exec](https://learn.chatgpt.com/docs/non-interactive-mode), [Windows](https://learn.chatgpt.com/docs/windows/windows-sandbox) |
| `copilot` | `copilot --output-format json --session-id=<uuid> --yolo --no-ask-user --no-auto-update`, prompt on stdin (`-p "<prompt>" --allow-all-tools` also works; piped stdin needs no `-p`) | JSONL session events, one per line, ending in a `result` record `{sessionId, exitCode, usage}` *(fixture)* | `--session-id=<uuid>` creates the session when new and resumes it when it exists, so every turn names it; `--resume=<id>` errors on an unknown id (`No session, task, or name matched`) *(fixture)* | `session.usage_record` events in `$COPILOT_HOME/session-state/<id>/events.jsonl` and, when the CLI prints them, `quotaSnapshots` on `model.model_call_success` *(fixture)*; `session.usage_checkpoint` in the stream has the session's running token totals; limit strings start `You've hit your rate limit` *(fixture)*; a failed turn exits 1 | `winget install GitHub.Copilot` (npm needs Node.js 22+) | [programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference), [getting started](https://docs.github.com/en/copilot/how-tos/copilot-cli/cli-getting-started) |
| `opencode` | `opencode run --format json`, message on stdin (a positional `"<message>"` also works) | `--format json` prints raw JSON events (default: formatted text): `step_start`, `tool_use`, `text`, `step_finish` (`reason`, `tokens`), `error`, each with `sessionID` *(fixture, `test/fixtures/cli/opencode/run-json/`)* | the first turn names no session, `ses_…` is generated and on every event; `--session <id>` continues it, `--continue` the last *(fixture)* | `step_finish.tokens` per step and tokens per message in its SQLite database; `opencode stats` summarises; no quota meter, a limit is an `error` event and exit 1 *(fixture)* | runs directly on Windows (`OPENCODE_GIT_BASH_PATH` names Git Bash); the vendor recommends WSL | [CLI](https://opencode.ai/docs/cli/), [Windows](https://opencode.ai/docs/windows-wsl/) |
| `hermes` | `hermes chat -q "<prompt>"` or `hermes chat --query-file -` (off a TTY, or with `--oneshot`/`-Q`, it answers and exits); `--format stream-json` prints events, `--format text`, the default, only the final reply. The headless lane runner (#484) runs `hermes chat --format stream-json -c <session> --create-if-missing --query-file -`, the message on stdin | `--format stream-json` prints NDJSON events: `system`/`init`, `text` deltas, `tool_use`, `tool_result`, and last a `result` (`session_id`, `exit_code`, `text` the final reply, `tokens`, `error`) *(fixture, `test/fixtures/cli/hermes/stream-json/`)* | `-c "<title>" --create-if-missing` (deterministic thread, a `local-…` id works in its place), `--resume <session_id>` | `hermes usage --json` gives account windows; the `result`'s `tokens` per turn, the session's in its SQLite `state.db`; a 429 ends in a `result` with `exit_code` 1, `error` `HTTP 429: …` and, for a quota, the `Limit resets at …` text *(fixture)* | native: `iex (irm https://hermes-agent.nousresearch.com/install.ps1)`; "CLI, gateway, TUI, and tools all work natively" | [README](https://github.com/NousResearch/hermes-agent), [CLI guide](https://hermes-agent.nousresearch.com/docs/user-guide/cli) |
| `openclaw` | `openclaw agent exec --json --cwd <dir> --message-file -`; the headless lane runner (#485) adds `--config <lane config> --state-dir <wt>/.harness-openclaw --timeout <s>` | one JSON envelope on stdout: `ok`, `status`, `final`, `usage`, `costUsd`, `sessionId` | no caller-set id; `--state-dir <dir>` keeps sessions and each run's `sessionId` is in its envelope | `usage` and `costUsd` in the envelope; `openclaw status --usage --json` for windows; exit 0 ok, 1 error, 2 timeout, 130 SIGINT, 143 SIGTERM | PowerShell installer `iwr -useb https://openclaw.ai/install.ps1 \| iex`; native Windows CLI and Gateway supported, WSL2 "most Linux-compatible" | [agent exec](https://docs.openclaw.ai/cli/agent), [Windows](https://docs.openclaw.ai/platforms/windows) |
| `agy` | `agy -p "<prompt>" --output-format json` (or `stream-json`) | `text`, `json` or `stream-json` *(fixture)* | `--conversation <id>`; the id is found after the first turn *(fixture)* | `agy -p "/usage" --output-format json` returns 5-hour and weekly buckets *(fixture)*; `/usage` shows credits and quota | PowerShell: `irm https://antigravity.google/cli/install.ps1 \| iex` (CMD script also); binary in `%LOCALAPPDATA%\agy\bin` | [getting started](https://antigravity.google/docs/getting-started?tab=cli), [cli-capabilities.md](cli-capabilities.md) |

Every supported CLI has a Windows build and a non-interactive mode, so none of them is `n/a` on Windows and no ConPTY pane backend
follow-up is needed (PRD #475, Solution 2). A per-CLI turn may encode only what a row here, or the matching
[cli-capabilities.md](cli-capabilities.md) row, cites.

### Autonomy

| Setting | Behaviour |
|---------|-----------|
| `HARNESS_AUTONOMOUS=true` (default) | Agents are instructed never to apply `agent-blocked`. Every obstacle is resolved by the agent. Stale `agent-working` labels are reaped automatically. If a lane applies `agent-blocked` anyway, its session is ended and the issue is parked: it is not re-dispatched until it changes (a comment or a label edit) or `HARNESS_BLOCKED_BACKOFF_MIN` passes. `harness status` lists it as `PARKED`. A lane that labels its issue `agent-paused` with no `HARNESS CHECKPOINT` sent to it is nudged, then checkpointed and ended after `HARNESS_SELFPARK_GRACE_MIN`. |
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

Both beat the lane's [role](#roles-model-and-effort-per-lane) keys. Pin a claude lane's model here, not in `.claude/settings.local.json`: in a linked worktree Claude Code
also reads the main checkout's `settings.local.json`, and that one wins (#374). A worktree's own
`settings.local.json` model is still honoured — the claude adapter puts it on the launch line as
`--model` when `.harness-lane` names none.

### Submodules

**A submodule is not a fleet.** One fleet drives one repo, and a submodule is part of that repo. A
submodule that has its own fleet folder (for example `~/ORGE/ORGE-ENGINE/.harness`, with no workers of
its own) is no longer a supported setup: delete that folder and file its issues in the main repo with a
`## Code location` section ([Submodule issues, end to end](#submodule-issues-end-to-end)).

A repo with submodules works in a lane the same as one without. Issues for submodule code are filed in
the main repo; the lane merges the submodule change on that submodule's own base branch first, then
bumps the gitlink in the main repo. The engine provides three pieces of plumbing for this (the
lane-facing rules that use them are in the lane prompts):

- **Init.** After `git worktree add`, every fresh lane worktree (and every clone) runs
  `git submodule update --init --recursive` **before** `HARNESS_WORKTREE_HOOK`, so the hook and the lane
  find each submodule checked out at the gitlink. A hook that already runs `git submodule update` keeps
  working (it is then a no-op). A failed init is logged and never stops the lane from launching. A repo
  without a `.gitmodules` is untouched.
- **Base branch.** A submodule's base branch is `submodule.<name>.branch` in `.gitmodules`. When that is
  unset it is the `origin` branch of the submodule that contains the commit the main repo currently pins;
  when several do, the submodule's default branch wins. It is never just the default branch, so a fleet
  that works on `rebuild` with no `branch =` set resolves to `rebuild`. Scripts and lanes get it from
  `submodule_base_branch <repo> <path> [ref]` (`scripts/submodule.sh`, sourced by `lib.sh`).
- **Gitlink guard.** `scripts/gitlink-guard.sh [--repo DIR] [--base REF] [--head REF]` refuses a
  main-repo merge unless every gitlink the change touches points at a commit that is reachable from the
  submodule's `origin/<base branch>` **and** descends from the gitlink the base ref pins. Every offender
  is printed; exit 1 = refused, 2 = could not decide (an uninitialised submodule, no base ref — it fails
  closed), 0 = allowed. A change with no gitlink change, or a repo with no submodules, passes untouched.
  Lanes cannot bypass it: a lane in a repo with submodules gets `scripts/lane-bin/gh` first on its `PATH`, a
  `gh` that runs the guard before `gh pr merge` and passes every other command through to the real `gh`. A
  repo without submodules gets no change to its lane environment.

#### Submodule issues, end to end

An issue for submodule code is filed in the **main** repo, never in the submodule's own repo (lanes do not
claim issues there). The writers of the issue — `decompose.md`, `bug-triage.md` and the inject prompt —
add a `## Code location` section naming the submodule path (for example `ORGE-ENGINE/src/...`). The lane
prompts (`impl.md`, `bug-fix.md`, `resume.md`, via the shared `prompts/_submodule.md`; `_rtdd.md` points
at it) then tell the lane to:

1. work inside the submodule on `issue/<unit>-<n>` (`<unit>` is `HARNESS_UNIT`, so the name cannot clash
   with a branch a former submodule fleet left) and run `rtdd which` there as well as in the main repo;
2. rebase, test with Rounds 1+2, push, and merge it into the submodule's base branch;
3. set the main repo's gitlink to the **merged** commit on `origin/<base>` (a squash merge changes the SHA);
4. commit the bump in the main repo, run Rounds 1+2 on the rebased HEAD, and merge (the gitlink guard checks it).

**Resume.** Dispatch decides between `impl.md` and `resume.md` by the `agent-paused` label or a pushed
`issue/<n>` branch in the main repo, **or** a pushed `issue/<unit>-<n>` in any submodule
(`submodule_branch_pushed <worktree> <branch>`, `scripts/submodule.sh`). A lane that died after pushing
only the submodule branch is therefore resumed, not restarted. This applies to issues and to bug fixes.

### Roles: model and effort per lane

Every lane plays one of two roles, read from its session kind (the session name says it):

| role | session kinds |
|---|---|
| **Manager** | orchestration `<prefix>-<unit>-p<n>` (PLAN, PRD, DECOMPOSE, REVIEW and its gauntlet auditor/critic), bug triage `<prefix>-bug-…-triage`, the injector `<prefix>-inject-<unit>` |
| **Implementer** | issue lanes `<prefix>-<unit>-i<n>` (also when they resume from `resume.md`), bug fixes `<prefix>-bug-…-fix` |

A lane launches with its role's `HARNESS_MODEL_MANAGER` / `HARNESS_EFFORT_MANAGER` or
`HARNESS_MODEL_IMPLEMENTER` / `HARNESS_EFFORT_IMPLEMENTER`. On `claude` they default to `opus`/`high`
(Manager) and `sonnet`/`high` (Implementer) — aliases, never full model ids, so a new Opus or Sonnet
arrives with the CLI update. On every other CLI they default to empty, which is the CLI's own default:
set them to the ids that CLI takes (copilot and others need full ids; Harness never guesses one).
`harness init` asks for both roles and shows them.

Precedence, highest first, for the model and the effort separately:

1. the worktree hook's `.harness-lane` (on `claude`, also a model the hook pinned in the worktree's
   `.claude/settings.local.json`);
2. the role keys;
3. a `--model` / `--effort` in `HARNESS_<CLI>_FLAGS`, else the CLI's default.

Whichever wins reaches the CLI's launch through its adapter (`cli_launch`, or the headless runner's
flags), replacing the flags' own, and the `launch` event in `harness stats` logs it.

A fleet that pinned `--model opus` in `HARNESS_CLAUDE_FLAGS` gets **Sonnet implementers** after this
(#375): the Implementer role's `sonnet` now beats the flags. Set `HARNESS_MODEL_IMPLEMENTER=opus` in
`.harness/config` to keep every lane on Opus.

**Verifying what ran (#376).** At `session_end` the stats sweep takes the model with the most
**output** tokens in the session's **own** transcript (`<session>.jsonl`; its sub-agents' transcripts are
left out, #461) and compares it with the model the `launch` event logged, **by family**: `sonnet` and `claude-sonnet-5-5` match, as do
`opus[1m]` and `claude-opus-5-5`; a non-Claude id matches itself without a provider prefix or date
stamp, or a `-`-suffixed variant of itself (`gpt-5.6` / `gpt-5.6-codex`). A different family appends a
`model_mismatch` event (`intended`, `actual`, `session`, `issue`) to the event log, and it is flagged
in `harness status` (this fleet's, last 7 days), `harness stats` (the fleet summary, the `--prd`
session row, the `--issue` timeline) and the web dashboard (the issue's DAG node, its PRD's node and
header, the drawer timeline; a session with no issue or PRD — a PLAN / PRD or injector session — is
listed in a banner in the fleet page's header with its kind, intended and actual model, same 7 days as
`harness status`, #462). Only the lane's own dominant model counts, so a side call or a sub-agent
on another model never trips it, however many tokens it writes — the `session_end` keeps the merged
`usage` (sub-agents included) for token and cost totals and records the lane's own model as
`main_model`; a `session_end` without one (logged before #461, or a lane with no transcript) falls back
to the dominant model of its merged usage. A lane with no intended model (the CLI's own default) is not
checked.

**Measuring the saving (#378).** `harness stats --by-role` reports, per role, the sessions, input /
output / cache-write / cache-read tokens (by model too) and their list-price $ (the `forecast.py` price
table: Opus $5 / $25, Sonnet $3 / $15, Haiku $1 / $5 per Mtok in / out; cache writes at the 5-minute
rate, reads at a tenth of input), plus the total. A session's role is read from the `kind` its
`launch` logged — `impl` and `bug-fix` are Implementer; `orch` (PLAN / PRD / DECOMPOSE), `review` (and
its gauntlet), `bug-triage` and `inject` are Manager — or, for an event from before kinds, from its
worktree's name (`<unit>-i<n>` and `bug-…-i<n>` Implementer, `orch-…-p<n>` and `triage-…-i<n>` Manager). Anything else is `other`, shown, never dropped. It reads the
whole event log, so history from before roles existed is priced the same way: compare a `--since`
window before #375 with one after. The usual filters apply — `--since`, `--fleet`, `-R`, `--model`,
`--prd N` / `--issue N` (that PRD's or issue's sessions only) — and `--json`.

### Lane output style (caveman)

Every session prompt (`prompts/*.md` other than the `_*.md` partials, which render inside one)
includes `prompts/_caveman.md`, so every lane invokes the `caveman` skill at session start (#377).
Its scope:

- **Caveman:** the session's own output and agent-to-agent comments — handoffs, review findings,
  checkpoint notes. No human reads those live.
- **Plain prose:** human-facing artifacts — PRD and issue bodies, PR titles and descriptions, docs,
  README, CHANGELOG, commit messages.
- **Never compressed:** exact strings — code, commands, errors, file paths, test names, label names,
  issue and PR refs, `<!-- harness-… -->` marker lines, the completion promise.

`harness setup`'s `prompt-skills-installed` check covers `caveman` for every CLI, like any skill a
prompt names. `test/test_prompt_caveman.sh` enumerates the prompts, so a new one without the partial
fails.

### Parallel-lane merge safety

Lanes branch and merge independently, so a lane's base has usually moved by merge time. The lane
prompts require a **rebase onto the current base plus a re-run** of rtdd Rounds 1 and 2 right
before merging, repeated until the rebase is a no-op, and hold lanes to **no new failures** (not a
globally green suite): a red test is re-run on the base, and red there too is pre-existing.

### Test selection (rtdd)

Lanes use [rtdd](https://github.com/VocanicZ/rtdd) v0.3 to pick tests and **test with Rounds 1 and
2 only — never the full suite**. The full suite runs once, at PRD review, before the PRD closes
(`prompts/review.md`). rtdd names the tests a change needs in rounds; it runs none of them — every
round runs with the project's own test command. The steps (`prompts/_rtdd.md`, shared by the impl,
bug-fix and resume prompts):

1. **`rtdd which --base origin/<default-branch>`** after every edit names Round 1, Round 2 and
   `untested`.
2. With no `.rtdd/config.yaml` the lane runs `rtdd init` once and commits only `.rtdd/config.yaml`
   and `.rtdd/.gitignore`.
3. **Round 1** (tests of the changed code) until green, then **Round 2** (tests of its callers and
   callees). **`untested`** code gets new tests.
4. **rtdd never blocks a lane.** Missing, older than v0.3 (no "Round 1" in its output), erroring, or
   both rounds empty → the lane runs the closest test files by hand (named after, or sourcing, the
   changed files), notes it in an issue comment and files one rtdd bug if rtdd misbehaved — never
   the full suite.
5. **No new failures**: a failing test is re-run against the base first; red there too is
   pre-existing and left alone.

At least one new test must fail without the change. A lane never weakens or edits a test to pass.
The merge gate is the repo's `scripts/ci-local.sh` when it ships one, otherwise rtdd Rounds 1 and 2
re-selected on the rebased head plus the lane's own new tests — never the full suite.

`harness stats` reports rtdd use per issue and PRD (which calls, round sizes, selective vs
full-suite share). Lanes log to `~/.harness/rtdd-events.jsonl` (`HARNESS_RTDD_EVENTS_FILE`).

### No GitHub CI — the gate is local

Harness projects do not use GitHub Actions as a gate. The merge gate is `scripts/ci-local.sh`
when the repo ships one, otherwise **rtdd Rounds 1+2 on the rebased head** plus the lane's own
new tests ([Test selection](#test-selection-rtdd)) — never the full suite, which runs once, at PRD
review. `gh pr checks` and mergeable-state are never the gate.
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
PRD review's full-suite run — the only full-suite run in the pipeline; lanes never run it — goes
out as a swarm job:

```bash
scripts/swarm-suite.sh <worktree> <job-name> [test files...]
```

| Exit | Meaning | Review then… |
|---|---|---|
| `0` | every test file passed | treats the run as green |
| `1` | red — each failing file is printed with its shard's `output.log` dir | reads the failures, as for a local run |
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
| `status [--watch [secs]] [--all]` | One-shot or live dashboard: pool state, then one row per worker — `worker-N → #<issue> <session> <state>` for a worker running a lane (`#<PRD>` for a PRD action), or `idle` — live sessions, and the priority bug lane. There is no unit line: a worker is one lane (#472). Outside any project (or with `--all`) it shows **every fleet on the host** from `~/.harness/fleets`: state (RUNNING / PAUSED / STOPPED / COMPLETE / DEAD / missing), live sessions with issue, age and model, open / unblocked / agent-working counts with orphaned locks flagged, last log line, HOLD streaks, and the GitHub budget |
| `stats [--prd N\|--issue N] [--by-role] [-R owner/repo]` | Host-wide event log report (`~/.harness/events.jsonl`, every project): per fleet over the last 7 days — sessions, tokens by model, issues/PRDs closed, retries, HOLD minutes, lane claims per repo and the workers that made them (`lanes`: the new `lane_claim` events attribute by `repo`+`worker`, the older `claim` events by `repo` when they carry one, else by their `unit`; both shapes aggregate, #472), and any `model_mismatch` (a session whose dominant-by-output model is another family than it was launched with, #376). `--prd` rolls each child issue's sessions (model/effort, tokens, wall time, retries) up to the PRD; `--issue` is a per-session timeline. Filters `--since 7d\|24h\|YYYY-MM-DD`, `--fleet <prefix>`, `--model <substr>`; `--by-role` totals tokens and list-price $ per role (Manager / Implementer / `other`, see [Roles](#roles-model-and-effort-per-lane)), combinable with every filter and `--prd`/`--issue` (#378); `--json` for machines; `--backfill` rebuilds `session_end` usage for past sessions from their Claude transcripts, and counts the `rtdd` calls of sessions that predate the rtdd event log. Every level also reports rtdd activity — see [Test selection (rtdd)](#test-selection-rtdd) |
| `forecast <issue> [-R owner/repo] [--unit U] [--json]` | Per-phase cost forecast for one issue — explore / test / impl / gate / ship at p50 / p80 / p95 $ and in total, scaled by the issue's size — from the past lanes in the same event log. Says which history it used and when it fell back. See [Cost forecast](#cost-forecast) |
| `one check` · `one gate <issue> [-R owner/repo] [--unit U] [--json]` | The `/harness-one` budget gate. `check`: exit 0 when the fleet is PAUSED or usage-HELD, else refuses (exit 1). `gate`: the check, the issue's forecast, the arithmetic for every window and `RECOMMEND: APPROVE` (exit 0) or `DENY` (exit 1); exit 3 = refused. See [One issue at a time](#one-issue-at-a-time-harness-one) |
| `one start <issue>` · `one phase <issue> <phase> [--json]` · `one release <issue> [--force]` | `/harness-one` execution, in the invoking session. `start`: the check again, then claim + worktree + `impl.md`/`resume.md` as dispatch does (exit 3 refused, 4 not claimable). `phase`: FITS (exit 0) or CHECKPOINT (exit 1, printing the `pause --force` checkpoint). `release`: drop the worktree, branch and lease (exit 4 = unpushed work) |
| `doctor [--fix]` | Diagnose what strands a pool — who holds `start.lock`/`pool.lock` (via a dependency-free `/proc` scan, so it works without `fuser`/`lsof`), orphaned lock-holders (a killed worker's leaked poll-`sleep`), and stale pidfiles. Report-only by default; `--fix` clears stale pidfiles and reaps **this project's** orphans (never touches a co-resident sibling fleet) |
| `attach <unit> [issue]` | tmux-attach to a running session |
| `migrate` | Convert a project's **vendored** `.harness/` (the pre-shared-engine layout) to state-only and re-point it at the shared engine. Idempotent; refuses if no shared engine is installed |
| `poll [--once\|--status]` | Host-level debug entry to the shared snapshot poller. `--once` refreshes every registered repo once; `--status` reports the poller pid + registered slugs/cadences. Normal operation needs no manual `poll` — workers self-heal it (see [Host poller](#host-poller)) |
| `supervise [--once] [--dry-run]` | Host-level supervisor for **every fleet on the host**: restarts dead pool/priority workers, clears orphaned `agent-working` locks, nudges — then checkpoints to GitHub and kills — sessions frozen at their prompt, and runs the arc stall rules. `--alarms` lists the alarms still firing; `--install` / `--uninstall` manage its systemd user unit. See [Host supervisor](#host-supervisor) |
| `web` | Read-only **dashboard** of every fleet on the host, served in the foreground on `http://127.0.0.1:4637/`: each registered fleet with its state and a link to its page, from local snapshots only. `--install` / `--uninstall` manage its systemd user unit. See [Dashboard](#dashboard) |
| `plan "<brief>"` | Inject a plan change (`PLAN.md`, cascaded into the PRD and delta issues) into a **live** fleet. Grill via [`/harness-plan`](#per-command-shortcuts) |
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

Every update — already current included — also links the engine's skills (`/harness`,
`/harness-*`, and the skills the lane prompts name) into the user-skills dir of every supported CLI
installed on the host: `~/.claude/skills` (claude, opencode), `~/.hermes/skills`, `~/.agents/skills`
(codex, openclaw), `~/.gemini/config/skills` (agy), `~/.copilot/skills`. Each is a symlink into
`~/.harness/engine/skill/`, so the next update refreshes them all at once. A missing, dangling or
old-release link, or an old Harness copy, is relinked; a same-named skill of your own is kept, and the
update names it. `harness setup` and `harness start` do the same, quietly; `harness uninstall`
removes only Harness's links (#439).

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
- Migrates every registered fleet to the one-repo config and rolls its workers (below). Other running
  workers keep their release until relaunched. A host running `harness supervise` rolls them itself after
  installing a release ([Host supervisor](#host-supervisor), rule 7); otherwise `harness pause` → drain →
  `harness stop` → `harness start --recover`.

### Fleet migration: one fleet = one repo (#467)

`scripts/fleet-migrate.sh` moves a fleet from `multi` topology + `targets.tsv` (or a `single` fleet with
no unit keys) to the one-repo config, and restarts its workers on the engine that runs it. No operator
step:

- `harness update` runs it for **every fleet registered in `$HARNESS_HOME/fleets/*.json`**, not only the
  current folder's. A folder you update from that is not registered is migrated too, and rolled only if it
  has worker pid files. It runs from the *new* release, so a git-checkout engine (whose `git pull` still runs
  the old `update.sh`) leaves it to the next `harness start`.
- `harness start` runs it for its own fleet, before it reads the config. `HARNESS_FLEET_MIGRATE=0` opts out.

A fleet whose config has no `HARNESS_TOPOLOGY` line and has `HARNESS_UNIT` is left alone, so running it
twice changes nothing (no second backup, no second event). Per fleet that needs it, in order:

1. Back up the config as `config.bak-<YYYYMMDD>`.
2. Migrate the config. Both line forms are read and written in place — `: "${KEY:=val}"` and plain
   `KEY=val` — with comments and every other key kept.
   - `multi`: keep the `targets.tsv` row whose repo is `HARNESS_REPO`, else the only row, else the first.
     `HARNESS_REPO` becomes that row's repo (the target wins: ImPrint's `VocanicZ/ImPrint` becomes
     `VocanicZ/Imprinted`), `HARNESS_UNIT` its id, and `HARNESS_CHECKOUT` the clone that exists under
     `.harness/checkouts/` (the one named after the repo, else the one whose `origin` is the repo). The
     other rows move to `targets.tsv.migrated` and a `fleet_migrated` event is logged (it names them in
     `dropped`). There is no refusal and no manual gate.
   - `single`: `HARNESS_UNIT=main`, `HARNESS_CHECKOUT=` the project root.
   - `HARNESS_TOPOLOGY` is removed. `HARNESS_POOL` becomes `max(POOL, CAP)` so no fleet loses
     parallelism, and the `HARNESS_CAP` line is dropped (#469; #467 kept it): the pool worker runs `POOL` lanes at once ([#468](#the-pool-worker-step-loop)).
   - A config that #467 already migrated and that still has a `HARNESS_CAP` line only loses that line (backed
     up first); its `POOL` is kept and its workers are not restarted. Running it twice changes nothing.
   - A `HARNESS_CAP` still in the environment or the config when `harness start` runs is ignored, with one
     warning: "CAP is gone; POOL is the number of parallel issues".
3. Kill only that fleet's `run/worker-*.pid` and `run/priority.pid` processes. It never runs
   `harness stop`, which kills every fleet's sessions: live lane sessions keep running.
4. `fleet_roll` (`scripts/roll.sh`, shared with the supervisor's auto-update, #477) runs
   `harness start --state-dir <fleet>` (no `--recover`) to relaunch the workers on the new engine, from an
   environment scrubbed of any other fleet's `HARNESS_*` keys. A **paused** fleet comes back paused; a
   fleet with no worker pid files was stopped on purpose and is migrated but not started.

The config migration and the worker roll go together on purpose: a migrated config under old workers
would leave them reading a missing `targets.tsv` and idling as "all complete".

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

The repo is `-R`, else the one the issue's own lanes ran in, else the current project's repo. Issue bodies come from `gh`. `--json` prints the same
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
  No status line reports the invoking session's own spend (it was started elsewhere, and a paused or
  held fleet renders none), so `now%` is the reading **plus what its account spent since it was
  taken**: every message of the Claude transcripts in the config dir named after the account
  (`~/.claude` for `default`, `~/.claude-switch/accounts/<name>`, `$CLAUDE_CONFIG_DIR`), priced at
  list price and divided by the window's $ per 1% (the #364 bound, else `HARNESS_ONE_USD_PER_PCT`).
  `start` keeps the readings it saw (`run/one/<unit>-i<n>.start`), so a window that resets mid-issue —
  `claude_limit_usage` drops a reading past its `resets_at` — is still checked, from 0% at the reset
  plus the spend since. A reading that is not current (from before `start`, older than
  `HARNESS_ONE_STALE_MIN`, of unknown age, or gone since `start`) and whose spend cannot be counted (no
  config dir for its account, no $ per 1%) is a CHECKPOINT (`usage stale`), never a silent FITS (#445).
  That rule is for the claude adapter's readings, which freeze once the fleet pauses. A live query's
  reading — `HARNESS_USAGE_CMD`, or the codex, copilot, hermes, agy or openclaw adapter — is as
  current as the query: of unknown age it gets `HARNESS_ONE_STALE_PAD_PCT` points, as at the gate
  (#451). Only while the query answers: when it fails or comes back empty mid-issue (auth expiry, an
  outage, a cached fetch that failed), the reading put back from `start` is frozen like any other —
  gone since `start`, so a CHECKPOINT unless its spend since can be counted (#457). A window the
  adapter leaves out because its `resets_at` has passed (codex, copilot) while the same account's
  query still answers other windows is not that: the query is current, so the window is 0% plus the
  stale pad (#459).
  A window of the session's own account (the basename of `CLAUDE_CONFIG_DIR`, `default` for none)
  that no reading holds — the readings cover only another account, or its 5h window reset before
  `start` — is checked from 0% at `start` plus that account's spend since; with no snapshot or no
  countable spend it is listed `unchecked` with a WARNING, never silently left out (#452).
- **Release** — after the checkpoint, or once merged, `harness one release <issue>` drops the
  worktree, local branch and lease (it refuses while work is unpushed, short of `--force`) and clears
  an `agent-working` that was never checkpointed. Nothing of the session's is left, so the pool
  resumes an `agent-paused` issue through `resume.md` after the reset, like any checkpointed lane.
- **Done → next** — once merged, `harness one done <issue>` runs the goal check `reap_done_sessions`
  runs (`issuelib.py check <repo> ISSUE:<n>`); until it reports DONE (exit 4) nothing is offered. Then
  it picks the next claimable issue exactly as a one-slot dispatch would (`issuelib.py next`: open,
  ready, not `agent-working`, every `## Blocked by` closed; resumable — `agent-paused` or a pushed
  branch — first, then oldest), skipping any issue a live lane still owns — its worktree or session
  present, the set dispatch skips (`busy_issues_for`, #446) — and runs a fresh forecast + gate for it (exit 0 APPROVE / 1 DENY / 3
  refused). The human decides again: approve / pick another / stop. None claimable is exit 5.

### Auto harness-one lane (`HARNESS_ONE_AUTO`)

With `HARNESS_ONE_AUTO=1`, a [usage hold](#usage-limit-checkpoints) no longer leaves the fleet idle:
the engine runs `/harness-one` itself, one issue at a time, until the next issue will not fit.

- **Trigger** — every poll of a usage-HELD unit (`drive_unit`) of a fleet with `HARNESS_ONE_AUTO=1`.
  No operator step, no approval prompt. Default `0`: the hold behaves exactly as before.
- **One lane per account, host-wide** — usage is per account, so at most one auto lane runs per
  account across every fleet on the host: `$HARNESS_HOME/one-auto/<account>.lane`, taken under
  `<account>.lock`. The fleet that owns it refreshes it every poll; a record nobody refreshed for
  three polls (at least 15 minutes) is a dead fleet's and is free again. Fleets held on the same
  account take turns: a free lane goes to the next opted-in fleet unit (with a claimable issue) after
  the one served last.
- **Gate** — the next claimable issue (`issuelib.py next`, as `harness one done` picks it) goes
  through `harness one gate`: it starts only if `now% + p80% + HARNESS_ONE_RESERVE_PCT <=
  HARNESS_ONE_STOP_PCT` in every window. A DENY starts nothing, logs the forecast and the reason, and
  stops the account's chain until the held window resets.
- **Execution** — the issue is claimed and rendered as dispatch does it (`impl.md`, `resume.md` for
  an `agent-paused` issue) and runs as an ordinary impl lane of the fleet, its task ending with the
  per-phase re-check (`harness one phase`). A phase that will not fit checkpoints exactly as
  `pause --force` does: branch pushed, handoff comment, `agent-paused`; the engine then ends the
  lane, and the pool resumes the issue after the reset.
- **Chaining** — once the lane's issue is closed (the goal check), the next poll picks the next
  claimable issue with a fresh forecast. An issue still open after its lane is gone (checkpointed or
  failed) stops the chain.
- **Hand-back** — when the hold clears no new issue is started; the running lane finishes or
  checkpoints as a normal session (its issue stays `agent-working`, so the pool never races it).
- **Visibility** — `harness status` and the web dashboard show the lane, its issue and forecast, or
  why the chain stopped; every start and stop is a stats event (`one_auto_start`, `one_auto_stop`,
  `one_auto_done`).

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
   Headless lanes get the same rules ([Headless lanes](#headless-lanes)).
4. **Other agent panes** matching `EXTRA_RE` — nudged only.
5. **Offline host** — everything held while `ONLINE_URL` is unreachable.
6. **Arc stall rules** (2+ consecutive passes). Auto-fixed: wedged sessions, zombie sessions on
   closed issues, live sessions missing `agent-working`. Alarm only: review loop, no frontier,
   decompose stalled, unfiled plan tasks, missing `## Parent`, wayfinder leak, deep context.
   `harness supervise --alarms` lists them.
7. **Auto-update** (#477) — a published release is installed by the host and rolled onto the workers
   without an operator. At most once per `HARNESS_AUTO_UPDATE_EVERY` it checks the latest release; if
   it is newer than the installed one it runs `harness update`, then rolls the workers of every
   registered fleet: only `worker-*.pid` / `priority.pid` processes whose `ENGINE_DIR` is not the new
   release are killed, each under the fleet's `run/pool.lock`, and `harness start` relaunches them.
   Lane sessions are never touched (the new worker adopts them), a worker holding a `bug-*.claim` is
   left until the claim is released, and a paused fleet comes back paused. `HARNESS_AUTO_UPDATE_HEALTH_S`
   after the roll, a dead worker or priority pid runs `harness update --rollback`, rolls the workers
   back, records the tag in `~/.harness/supervise/auto-update.skip` (never retried; a newer tag still
   installs) and files one `bug` on `VocanicZ/Harness`. The phase is kept in
   `~/.harness/supervise/auto-update.json`, so the supervisor the update restarts resumes the roll and
   the health check. Events: `engine_updated`, `workers_rolled`, `engine_rolled_back`. It never runs
   with `HARNESS_AUTO_UPDATE=0`, under a `HARNESS_REF` pin, on a git-checkout engine, or from a
   supervisor that is not a release of this host (a dev clone); an older or equal tag, or one that is
   not `[v]MAJOR.MINOR.PATCH`, installs nothing. The roll is `fleet_roll` in `scripts/roll.sh`, the one
   kill-and-relaunch implementation `harness update` shares.

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
| `HARNESS_AUTO_UPDATE` | `1` | `0` turns the auto-update off (also settable in the environment) |
| `HARNESS_AUTO_UPDATE_EVERY` | `600` | seconds between release checks |
| `HARNESS_AUTO_UPDATE_HEALTH_S` | `120` | seconds after the roll before the health check that can roll back |
| `UNPARENTED_OK` | empty | comma-separated issue numbers exempt from the missing-`## Parent` alarm |

`harness supervise --install` installs and starts the `harness-supervise.service` systemd user unit
(with linger); `--uninstall` removes it. On native Windows it registers the Task Scheduler task
`Harness\harness-supervise` (with a hash of `HARNESS_HOME` appended for any home but `~/.harness`) instead
([Native Windows](#native-windows)).

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
harness web --install                              # systemd user unit (Windows: a scheduled task), 127.0.0.1:4637
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

Config, `run/`, worktrees, checkouts and `prompts/*.local.md` are kept. Idempotent.

## The `/harness` skill

Linked once per host into every installed CLI's user-skills dir (`~/.claude/skills/harness/`, `~/.hermes/skills/harness/`, …; see **Update**). Run `/harness` (or "start the fleet", "what's the
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
| `/harness-plan`   | `harness plan`   | inject a `PLAN.md` change into a live fleet; grills + replays a crystallized brief for confirmation (the human safety gate) before mutating; supports the `--recover` retired-fleet fallback |
| `/harness-prd`    | `harness prd`    | grow PRD scope → delta issues on a live fleet; grills + replays a crystallized brief for confirmation before mutating; supports the `--recover` retired-fleet fallback |
| `/harness-issue`  | `harness issue`  | inject a discrete implementation issue into a live fleet; grills + replays a crystallized brief for confirmation before mutating; supports the `--recover` retired-fleet fallback |

`/harness-arc` deploys a design too big for one PRD as a chain of PRDs plus a wayfinder map of
decisions the fleet cannot make. Its stall rules run in the [host supervisor](#host-supervisor).

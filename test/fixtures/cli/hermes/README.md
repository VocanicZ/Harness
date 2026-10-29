# `hermes` fixtures

Captured 2026-10-28 (UTC) on the fleet host from Hermes Agent `v0.22.5` (stable, installed by its
installer with `--skip-setup --skip-browser --skip-computer-use`), signed in with the host's GitHub CLI
login on Hermes's Copilot provider (`hermes auth list`: `copilot … gh auth token`; Copilot Free, model
`gpt-4.1`: `mai-code-1.1-flash`, `claude-haiku-4.5` and `gpt-5.6-luna` were refused, `HTTP 400: The
requested model is not supported`). The operator home `~/.hermes` was set to `model.provider: copilot`,
`model.default: gpt-4.1` (`hermes config set`). Each capture ran in a throwaway git repo. Each `.txt` is
`tmux capture-pane -p` of the pane. Unless a row says otherwise the pane is a lane launched by
`launch_agent` from `scripts/lib.sh` with `HARNESS_CLI=hermes` — tmux's default 80x24, the line
`exec env HERMES_HOME=<home> hermes chat -c <uuid> --create-if-missing --yolo --accept-hooks -q
"<bootstrap>"`, the lane's home seeded by `hermes_launch`. `idle.txt` and `busy.txt` (and the smoke
run) ran on the shipped home, a profile `~/.hermes/profiles/harness<hash>`; the other panes on the
first adapter's home, `<wt>/.harness-hermes` with the root's `installs/` and `tools/` linked in —
the same TUI, but for the idle composer's profile prefix (`harness<hash> ❯`). That home was dropped:
Hermes repointed the host's `hermes` launcher at its linked `tools/` (the review caught it; a
`hermes` run with the root home put it back).

The plan's launch line (`-m <model> --reasoning <e>` beside `-c <uuid> --create-if-missing`) was tried
first and refused on every title, new or not: `Error: Resume retains gateway session policy; creation
overrides are unsupported on resume. -m/--model, --reasoning differ from this session's launch`. `-c
<title> --create-if-missing` alone, and `-m … --reasoning …` without `-c`, both ran. A home other than
the one Hermes was installed into re-installed its runtime on the first launch (and failed on the
host's missing `libatomic`); linking `installs/` and `tools/` into the lane's home ran it at once.

An Enter sent by `tmux send-keys` right after the text (`send-keys -l "<text>"`, then `send-keys
Enter`) landed in the composer as a newline, three times out of three: the text stayed in the box and
the next line typed was appended under it. With 0.2 s or 0.5 s between them the prompt was submitted.

| file | how |
|---|---|
| `busy-start.txt` | A lane 2 s into its first turn: the top rule `── ⠋ ( ͡° ͜ʖ ͡°) deliberating... · 2s ───── <uuid> ─`, the composer `☤ ❯ type to redirect this turn · Tab queues it for after`, the status bar's `⏱ 2s`. The `-q` bootstrap is echoed above as `❯ <prompt>` between 40-dash rules. |
| `busy.txt` | A profile lane while the agent's foreground `sleep 30` ran: `── ⠹ 💻 sleep 30 · 10s · ↓ 16 tok ──`. |
| `idle.txt` | A profile lane once its turn ended (`─ 1m01s · read 1 file · ran 1 command · 12:18 PM`): the title rule `───── <uuid> ─`, the composer `harness<hash> ❯ <rotating placeholder>`, the status bar. |
| `busy-typed.txt` | `Please continue — redirect test: reply only REDIRECT-SEEN` typed during a turn (`sleep 50`), before its Enter: it sits in the busy composer after `☤ ❯ `. |
| `steer.txt` | That line Entered: the turn is redirected (`Your correction redirected the current run without discarding completed work`), the running `sleep 50` moved to the background (`Processes · 1 running`), the composer empty again. The turn then answered `REDIRECT-SEEN`. |
| `interrupted.txt` | Escape during a turn changed nothing; Ctrl-C (the footer's `ctrl+c stop`) ended it: `✗ $ sleep 60  13.5s [exit 130]`, then the turn line and the idle prompt. Its assistant message in `state.db` is empty, `display_kind` `hidden`. |
| `busy-retrying.txt` | A lane whose operator home pointed `model.provider: custom` at a local OpenAI-compatible server answering every chat call `503 {"error": {"message": "Service Unavailable"}}`: Hermes retrying in cycles (`⏳ Provider temporarily unavailable — retrying automatically in 31s (cycle 2/5)`); the top rule's activity truncates its turn time, the status bar keeps `⏱`. |
| `transient.txt` | The same lane once Hermes gave up, about 5 minutes in: `❌ API failed after 3 retries — HTTP 503: Service Unavailable`, the assistant's `custom reported it was overloaded on all 3 attempts …`, the idle prompt. Its assistant message has `display_kind` `failed_turn`. |
| `limit.txt` | The same setup, the server answering `429` with `{"error": {"message": "You have reached your usage limit for this period.", "type": "usage_limit_reached", "resets_in_seconds": 7200}}`: three `⏱️ Rate limited. Resets in ~1h 59m.` retries, `❌ Rate limited after 3 retries — … (resets in ~1h 59m)`, and `Limit resets at 13:01 (in 2h 00m).` at column 0. A live quota could not be exhausted on demand. |
| `bypass-subagent.txt` | A lane told to `mkdir -p junk-dir && touch junk-dir/x` itself, then to have a `delegate_task` sub-agent run `rm -r junk-dir` (a command Hermes flags as a recursive delete). The delegation runs in the background (`↩ Background task running — I'll resume when it finishes`, `Subagents · 1 live`); `junk-dir` was removed. |
| `bypass-subagent.db` | That run's rows of the lane's `$HERMES_HOME/state.db`: `sessions` (the lane's, titled with its uuid, and the sub-agent's, `parent_session_id` = the lane's), `messages`, `session_model_usage`, `async_delegations`, `session_turn_leases` (empty), every other table dropped, `system_prompt`, `model_config` and `origin_json` cleared, the cwd replaced by `@CWD@`. The sub-agent's tool result has no `approval` field: the command ran unchecked. |
| `no-bypass-subagent.txt` | The same task in a home without `--yolo` or `approvals.mode: off` (a plain `hermes chat -c perm-test --create-if-missing -q …`): its sub-agent's `rm -r` result reads `"approval": "Command was flagged (recursive delete) and auto-approved by smart approval."`. |
| `transcript.db` | `bypass-subagent.db` without the sub-agent's session: the lane's prompt, its tool calls, the injected `[ASYNC DELEGATION BATCH COMPLETE — deleg_…]` message and the final `<promise>CAP DONE</promise>`. |
| `usage.expected` | What `hermes_usage` folds `transcript.db` to: its one `session_model_usage` row (`gpt-4.1`: 13165 input, 142 output, 47360 cache reads, no cache writes). |
| `skill.txt` | A skill `echo-proof` in `HARNESS_USER_SKILLS` (the lane's `skills.external_dirs`), the task `Run the echo-proof skill.`: the agent loaded it with its skill tool (`📚 echo-proof`) and replied as it said. |
| `skill-project.txt` | A project skill `.agents/skills/echo-proof/SKILL.md` in a lane whose worktree `cli_trust` had written into `skills.trusted_project_dirs`: typed as `/echo-proof`, `⚡ Loading skill: echo-proof`. |
| `handoff.txt` | `/handoff` typed into a lane: Hermes's own command, `/handoff is not available on the shared gateway yet` — a skill named `handoff` cannot be reached by its slash. |
| `loop.txt` | The goal loop on the real CLI: a lane whose `.harness-task.md` asked for `STILL WORKING` unless the prompt named a Ralph iteration, and the promise `CAP DONE` otherwise, tended by `watchdog_session` every 8 s. Turn 1 replied `STILL WORKING`; the watchdog typed `🔄 Ralph iteration 2 \| To stop: output <promise>CAP DONE</promise> …` with the bootstrap; turn 2 replied `<promise>CAP DONE</promise>` and the state file was removed. |
| `env-no-passthrough.txt` | Captured 2026-10-29, before #313, on the anthropic provider (`model.provider: anthropic`, `model.default: claude-haiku-4-5` set in the lane's config after seeding; the host's copilot quota was spent). A lane started with tmux `-e RTDD_EVENT_LOG=<dir>/cap-before2/rtdd-events.jsonl -e HARNESS_SESSION=cap-313-session -e HARNESS_ISSUE=313`, its task `printenv RTDD_EVENT_LOG HARNESS_SESSION HARNESS_ISSUE`, its profile with no `terminal.client_env_passthrough`: the command printed `<dir>/cap-before/rtdd-events.jsonl` — the log of the lane that had started the host gateway a few minutes before (its `/proc/<pid>/environ` held that lane's `RTDD_EVENT_LOG` and `HARNESS_SESSION`), not this lane's own. |
| `env-passthrough.txt` | The same, after #313: a lane seeded with every lane variable in `terminal.client_env_passthrough`, started with `-e RTDD_EVENT_LOG=<dir>/cap-after/rtdd-events.jsonl -e HARNESS_SESSION=lane-after-313 -e HARNESS_ISSUE=313`, while that host gateway still held the other lane's: its command printed its own `<dir>/cap-after/rtdd-events.jsonl`, `lane-after-313`, `313`. `VERSION`'s Hermes. |
| `session` | `transcript.db`'s lane session title: the uuid its launch passed to `-c`. |
| `model` | The model the captures ran: `gpt-4.1`. |
| `effort-flag` | How a lane's effort reaches Hermes: `agent.reasoning_effort=`, the lane setting `hermes_launch` writes into the lane's `config.yaml` (and `cli_lane_settings` reports). |
| `handoff-skill` | How a prompt names the handoff skill: `handoff`, loaded by the agent's skill tool (`skill.txt`, `handoff.txt`). |
| `trust.na` | Why the `trust-dialog-is-not-prompt` row is n/a: there is no trust dialog. |
| `usage-windows.json` | Captured 2026-10-29: `hermes usage --json --provider anthropic` on the fleet host — Hermes's Anthropic OAuth fetch, on the host's Claude Code login (`~/.claude/.credentials.json` under `CLAUDE_CONFIG_DIR`). The host's lanes run on `copilot`, which has no usage endpoint (`usage-none.txt`); this is the same command on a provider that reports windows. Schema: `website/docs/reference/cli-commands.md` (`hermes usage`) and `hermes_cli/subcommands/usage.py` in the Hermes checkout (`bf0203a794`). |
| `usage-windows.expected` | What `hermes_limit_usage` reads from `usage-windows.json` (`<provider> <label> <pct used>`; the matrix moves each `resets_at` into the future first). |
| `usage-none.txt` | `hermes usage --json` on this host's `copilot` provider: nothing on stdout, this line on stderr, exit 1 — so `hermes_limit_usage` returns rc 1. |
| `VERSION` | `hermes --version`'s first line, then the capture date and host. |
| `fake-cli` | Stands in for `hermes` when the matrix runs a typed launch line: it writes `transcript.db` as `$HERMES_HOME/state.db`, its lane session titled as `-c` named it, its cwd the pane's and its start time now; then runs the turn's command with only the `RTDD_*`/`HARNESS_*` names the lane's `terminal.client_env_passthrough` lists (`env-passthrough.txt`). |
| `turn-end` | One prompt's turn ending as Hermes records it: a user message, then an assistant message with `finish_reason` `stop`, appended to the lane's `state.db`. |

Also seen, not kept as files: two profile lanes each running `sleep 50 && touch <x>.txt`; `cli_kill`
of one (pane, then `HERMES_HOME=<its profile> hermes gateway stop -y`) left no `a.txt`, the other
wrote `b.txt`, and the root's host gateway, which serves every profile, stayed up. Killing a lane's pane while its foreground `sleep 45 && touch
proof-after-kill.txt` ran interrupted the turn (`Operation interrupted: waiting for model response`;
no `proof-after-kill.txt`), and the lane's gateway (`$HERMES_HOME/gateway.pid`) stayed up. `hermes
gateway stop -y` with that `HERMES_HOME` stopped it (`✓ Stopped gateway for this profile`). Stopping the
gateway BEFORE killing the pane let the still-running TUI start a new one; pane first, then gateway,
left none.

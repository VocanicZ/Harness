# `opencode` fixtures

Captured 2026-10-28 (UTC) on the fleet host from OpenCode `1.19.5` (npm `opencode-ai@1`, no account:
the built-in OpenCode Zen free model `opencode/big-pickle`), in throwaway git repos. Each `.txt` is
`tmux capture-pane -p` of the pane. Unless a row says otherwise the pane is a lane launched by
`launch_agent` from `scripts/lib.sh` with `HARNESS_CLI=opencode` — tmux's default 80x24, the line
`OPENCODE_DISABLE_AUTOUPDATE=1 exec opencode --auto -m opencode/big-pickle --prompt "<bootstrap>"`
(the first captures carried the lane's config in a merged `<wt>/opencode.json` plus a copied
`.opencode/plugins/harness-ralph.js`; `loop-interrupt.txt` and the smoke run carry it the way the
adapter ships, inline: `OPENCODE_CONFIG_CONTENT='{"plugin":["file://…/scripts/cli/opencode-ralph.js"],
"permission":{"question":"deny"},…}' OPENCODE_HARNESS_LOOP=<GOAL_LOOP_PY>` in front, with nothing
written into the worktree). `--prompt` submits the bootstrap as the session's first message; nothing
is pre-filled. `OPENCODE_CONFIG_CONTENT` merges above the project's `opencode.json`: with a project
file setting `question: allow` and `variant: high`, `opencode debug config` resolved `question: deny`,
`variant: low` from the inline config and kept the project's other keys.

| file | how |
|---|---|
| `busy-start.txt` | A lane a few seconds into its first turn: the footer `■⬝⬝⬝⬝⬝⬝⬝  esc interrupt`. The input box (`┃` lines ending in the agent line `┃  Build auto · Big Pickle OpenCode`; `auto` is `--auto`) stays drawn under a running turn; the submitted prompt is echoed behind the same bar. |
| `busy.txt` | While the agent's foreground `sleep 25` ran: the tool call `┃  ⠇ sleep 25` and the footer `esc interrupt` with the context count `19.3K (10%)`. |
| `idle.txt` | After that turn ended (`▣  Build · Big Pickle · 1m 1s`): the agent line, and the footer the working directory and the context count, no `esc interrupt`. The loop had ended on the promise, so the plugin sent nothing. |
| `steer.txt` | `Please continue — queued test` typed and Entered while a turn ran: OpenCode queues it as its own message in the scrollback (`┃   QUEUED`) and leaves the input box empty. |
| `interrupted.txt` | Escape pressed twice during that turn (one Escape turns the hint into `esc again to interrupt`): the shell tool reports `User aborted the command`, the turn's line reads `▣  Build · Big Pickle · interrupted`. The queued message stayed unsent. |
| `busy-permission.txt` | `opencode -m opencode/big-pickle --prompt "Run the shell command: touch perm-proof2.txt"` with NO `--auto`, in a repo whose `opencode.json` set `"permission": {"bash": "ask"}` (OpenCode 1.x allows bash by default): the `△ Permission required` panel replaces the input box while the turn waits on it. |
| `bypass-subagent.txt` | The same `"bash": "ask"` config, launched as a lane (`--auto`): `Use your task tool to spawn a sub-agent, and have the sub-agent (not you) run the shell command touch subagent-proof.txt`. No permission panel; the sub-agent (`✓ General Task — bypass capture`) ran it and `subagent-proof.txt` was created. |
| `bypass-subagent.db` | That run's rows of `~/.local/share/opencode/opencode.db` (`opencode db path`): its `session` rows — the lane's and the sub-agent's child session (`parent_id` = the lane's) — and their `message` rows, every other table dropped, each `message.data` cut to `role`, `time`, `parentID`, `modelID`, `providerID`, `mode`, `agent`, `tokens`, `finish`, `error`, the cwd replaced by `@CWD@`. The child session's `part` rows (dropped) held its `bash` call `touch subagent-proof.txt`, `completed`. |
| `transcript.db` | `bypass-subagent.db` without the child session: the lane's own two prompts (the bypass task, then `Run the echo-proof skill.`) and its five assistant messages. |
| `usage.expected` | What `opencode_usage` folds `transcript.db` to: per `providerID/modelID`, `tokens.input` (cache reads are counted apart: `total` = input + output + reasoning + cache.read on every row), `tokens.output` + `tokens.reasoning`, `tokens.cache.read`, `tokens.cache.write`: 17690+229+110+12+162 = 18203 input, (81+9)+(65+146)+(10+0)+(21+97)+(11+0) = 440 output, 70+17762+17990+18110+18124 = 72056 cache reads, no cache writes. |
| `skill.txt` | A project skill `.opencode/skills/echo-proof/SKILL.md`. Typed as `/echo`, the slash menu offered only `/review`: skills are not slash commands. `Run the echo-proof skill.` made the agent call its skill tool (`→ Skill "echo-proof"`) and reply as the skill said. OpenCode also reads `~/.claude/skills/` and `~/.agents/skills/` (its log lists them at start). |
| `loop.txt` | The goal loop on the real CLI: `launch_agent` in a repo whose `.harness-task.md` asked for `STILL WORKING` unless the prompt named a Ralph iteration, and the promise `CAP DONE` otherwise. Turn 1 replied `STILL WORKING`; on `session.idle` the plugin sent `🔄 Ralph iteration 2 \| To stop: output <promise>CAP DONE</promise> …` with the task; turn 2 replied `<promise>CAP DONE</promise>` and the plugin removed `.claude/ralph-loop.local.md`, sending nothing more. |
| `loop-interrupt.txt` | The shipped launch (inline config, model `opencode/deepseek-v4.1-flash-free`), a task that runs `sleep 90` on iteration 2: turn 1 `STILL WORKING`, the plugin sent iteration 2 (as `deepseek-v4.1-flash-free`, the model the lane ran), Escape twice during the sleep (`· interrupted`; the message holds `MessageAbortedError`) and the plugin sent nothing; a prompt typed by hand then ran, and on its idle the plugin sent iteration 3, whose promise ended the loop. |
| `busy-retrying.txt` | A lane whose `opencode.json` added a provider `fake` (`@ai-sdk/openai-compatible`, `baseURL` a local HTTP server answering every chat call `503 {"error": {"message": "Service Unavailable"}}`), launched with `-m fake/m1`: OpenCode retrying, the footer replaced by `Service Unavailable: … [retrying in 10s attempt #4]` (no `esc interrupt`). |
| `transient.txt` | The same lane once OpenCode gave up after 5 retries: the error drawn behind the bar at the prompt, and its toast box. The plugin sent nothing (it saw `session.error` first). |
| `busy-limit-retrying.txt` | The same setup, the server answering `429` with a `GoUsageLimitError` body (`metadata.limitName` `5-hour`) and `retry-after: 2`: OpenCode's own retry text `5-hour usage limit reached. It will reset in 1 minute. To continue using thi…` (`… [retrying in 2s attempt #1]`), from `retry.ts`'s handling of that body. |
| `limit.txt` | The same setup, the server answering `429` with OpenAI's `insufficient_quota` body (`You exceeded your current quota, please check your plan and billing details.`): after 5 retries OpenCode draws the provider's message at the prompt. A live quota could not be exhausted on demand; the 1.19.5 binary's own limit wordings (`Free usage exceeded, subscribe to Go`, `<limitName> usage limit reached. It will reset in …`, `Quota exceeded. Check your plan and billing details.`) were read from it as data. |
| `session` | `bypass-subagent.db`'s lane session id (`ses_…`, generated by OpenCode). |
| `model` | The model the captures ran: `opencode/big-pickle` (`opencode models`). |
| `effort-flag` | How a lane's effort reaches OpenCode: `"variant":"`, the build agent's variant in the lane's inline config on the launch line, the v1 TUI having no effort flag. |
| `handoff-skill` | How a prompt names the handoff skill: `handoff`, loaded by the agent's skill tool (`skill.txt`). |
| `installs-nothing` | Why `harness setup` needs only the binary: the loop plugin is per worktree. |
| `trust.na` | Why the `trust-dialog-is-not-prompt` row is n/a: there is no trust dialog. |
| `usage-windows.na` | Why the `usage-windows` row is n/a: OpenCode 1.x has no quota meter. |
| `VERSION` | `opencode --version`, then the capture date and host. |
| `fake-cli` | Stands in for `opencode` when the matrix runs a typed launch line: it writes `transcript.db`'s sessions into `$XDG_DATA_HOME/opencode/opencode.db`, under fresh ids, their directory the pane's cwd and their creation time now. |
| `stop-hook` | One end of turn as the plugin takes it on `session.idle`: the script `OPENCODE_HARNESS_LOOP` names, handed the reply. `test/test_cli_opencode.sh` drives the plugin itself under node where node is installed. |

There is no `trust.txt`: OpenCode 1.x has no workspace-trust gate (it loaded the capture repos'
`opencode.json` and plugins with no dialog).

## `run-json/` — the headless turn (#482)

What the headless lane runner (`scripts/cli/opencode_headless.py`) reads: the stdout of
`opencode run --format json [--auto] [-m <model>] [--session <id>]`, the message on stdin, one JSON event per
line. Captured 2026-11-04 (UTC) on the fleet host from OpenCode `1.19.5`, model `opencode/big-pickle` (the
free Zen model, no account), `OPENCODE_DISABLE_AUTOUPDATE=1`, in a throwaway git repo. Each capture is the run's
stdout unchanged; the limit and transient ones come from a local stand-in endpoint (below), so their URL is
`127.0.0.1`.

| file | how |
|---|---|
| `normal.jsonl` | The first turn of a new session, no `--session`: `Reply with exactly the word PONG and nothing else.` `step_start`, a `text` part (`PONG`), `step_finish` with `reason: "stop"` and `tokens`. Every event carries the `sessionID` OpenCode generated (`ses_…`). Exit 0. |
| `tool-use.jsonl` | The next turn of that session, `--session <id>`: `Use your bash tool to run the shell command: echo hi > proof.txt — then reply with exactly DONE.` A `step_start`, a `tool_use` (the finished `bash` call, `state.input.command`, `state.output`), a `step_finish` with `reason: "tool-calls"`, then a second step: `text` (`DONE`) and a `step_finish` with `reason: "stop"`. Exit 0. Same `sessionID`: `--session` carries the session. `proof.txt` was created. |
| `limit.jsonl` | NOT triggerable on demand (the free model has no quota to exhaust), so OpenCode was pointed at a local stand-in endpoint: an `@ai-sdk/openai-compatible` provider `fake` in `OPENCODE_CONFIG_CONTENT`, `-m fake/m1`, whose server answered every call `429` with OpenCode Zen's `GoUsageLimitError` body (`metadata.limitName` `5-hour`) and `retry-after: 60`. OpenCode retried five times, about five minutes, then printed ONE `error` event (`error.name` `APIError`, `data.message` `Go usage limit reached`, `statusCode` 429, `responseHeaders`, `responseBody`) and exited 1. No `step_finish`. |
| `limit-quota.jsonl` | The same endpoint answering OpenAI's `insufficient_quota` body (`You exceeded your current quota, please check your plan and billing details.`, `retry-after: 1`). The same single `error` event, exit 1. |
| `transient.jsonl` | The same endpoint answering `503` `{"error": {"message": "Service Unavailable"}}`, `retry-after: 1`: the `error` event is `APIError`, `statusCode` 503, `isRetryable: true`; exit 1. A bad model name (`-m nosuch/model`) is also an `error` event (`UnknownError`, `Unexpected server error`), exit 1: the runner reads both as transient. |
| `no-conversation.jsonl`, `no-conversation.stderr` | `opencode run --format json --session ses_doesnotexist000`, a session OpenCode does not have: NO JSON on stdout (the empty file), `Error: Session not found` on stderr (ANSI-coloured, the `.stderr` file), exit 1. The runner then starts the session afresh. |
| `fake-opencode` | Stands in for `opencode` in `test/test_opencode_headless.py` and the matrix's `headless-*` rows (`test/test_cli_matrix.sh`, #482): each run replays the fixture `$FAKE_CLAUDE_DIR/plan` names next (text after the name replaces its reply), with every `sessionID` set to the session its argv continues (`--session`) or a new `ses_…` it also writes into `$XDG_DATA_HOME/opencode/opencode.db` (the rows of `transcript.db`, so the session id and usage Harness reads from there are found), records its argv and stdin prompt, can hold mid-turn, has a `hang` turn that starts a grandchild for the stop test, and runs an executable `turn-hook` with each prompt (#350). Its header says how. |

What the runner reads from them (`Turn.outcome`): a `step_finish` with `reason: "stop"` and exit 0 → `idle` (the
reply is the text of the turn's last message); an `error` event whose name, message or body is a quota
(`insufficient_quota`, `usage limit reached`, `Free usage exceeded`, `GoUsageLimitError`) → `limit`, its reset
the message's "reset in N unit" or the `retry-after` header; any other `error` event, or an exit with no
finished step → `transient`; `Session not found` on stderr → the session is gone (`no_conversation`).
OpenCode has no quota meter, so no `rate_limit` is ever read (`usage-windows.na`).

# `codex` fixtures

Captured 2026-10-27 (UTC) on the fleet host from Codex CLI `0.154.0` (ChatGPT account, free plan), in
throwaway git repos, model `gpt-5.6-luna` at effort `low`, launched as Harness does:
`codex --no-alt-screen -m <m> -c model_reasoning_effort=<e> --dangerously-bypass-approvals-and-sandbox
--dangerously-bypass-hook-trust "<prompt>"`. The pane is 160x45; each `.txt` is `tmux capture-pane -p`
of it. (`gpt-5.5`, in the host's model catalog, was refused by the server for a ChatGPT account:
`The 'gpt-5.5' model is not supported when using Codex with a ChatGPT account.`)

| file | how |
|---|---|
| `trust.txt` | `codex` in a repo not yet trusted: the workspace-trust dialog. It shows even with the bypass flag, and its selected option, `› 1. Yes, continue`, is at column 0 like the composer. |
| `busy-start.txt` | Mid-turn, 4s in: the status row `• Working (4s • esc to interrupt)` above the composer. |
| `busy.txt` | Mid-turn while the agent's `sleep 20` ran: `• Working (13s • esc to interrupt) · 1 background terminal running · …`. The submitted prompt is echoed at column 0 as `› …` above it. |
| `idle.txt` | After that turn ended: the composer `› Ask Codex to do anything` with no status row. Its scrollback carries the account's `You have 1 usage limit reset available` notice, which is not a limit. |
| `interrupted.txt` | Escape pressed during a turn: `■ Conversation interrupted - tell the model what to do differently.`, then the composer. No Stop hook runs for an interrupted turn. |
| `limit.txt` | NOT triggerable on demand. `idle.txt` with `■ You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again later.` inserted above the composer, from the 0.154.0 binary's strings (`You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus),` and its ` or try again later.` tail; byte search of the binary). `■` is the glyph Codex draws an error cell with (`error400.txt`). |
| `transient.txt` | NOT triggerable on demand. `idle.txt` with `■ exceeded retry limit, last status: 503 Service Unavailable` inserted the same way: the binary's `exceeded retry limit, last status: ` (Codex's give-up after its own retries) with an HTTP status. |
| `error400.txt` | A real error cell: the turn `gpt-5.5` was refused on (`■ {"type":"error","status":400,…}`), then the composer. A 400 is no transient error and no limit. |
| `hook-loop.txt` | A goal-loop run with the harness-ralph plugin installed from `plugins/codex` (`codex plugin marketplace add`, `codex plugin add harness-ralph@harness`) and a state file naming `CAP DONE` as the promise: turn 1 replied `STILL WORKING`, the Stop hook answered `Blocked by hook` with the task as the next prompt (`iteration: 2`), turn 2 replied `<promise>CAP DONE</promise>`, the hook removed the state file and the session went idle. |
| `hook-input.json` | What Codex handed the Stop hook on stdin after turn 1 of that run (a dump hook beside it), with the cwd replaced by `@CWD@` and the Codex home by `@CODEX_HOME@`. |
| `transcript.jsonl` | That run's rollout (`~/.codex/sessions/2026/10/27/rollout-2026-10-27T22-47-16-<session>.jsonl`), cut to the lines the adapter reads — `session_meta` (its `cwd`, `id`, `timestamp`), `turn_context` (`model`), `token_count` / `token_usage_record`, the user and assistant messages — with the cwd replaced by `@CWD@`. Instructions, environment context, reasoning and tool calls dropped. |
| `usage.expected` | What `codex_usage` folds it to: per `turn_context` model, the five `token_count` events' `last_token_usage`, with `cached_input_tokens` reported as cache reads and taken out of `input_tokens`. Checked by hand against the five `token_usage_record` lines (one per response, the same numbers): input 66036 = 14196 uncached + 51840 cached, output 427. |
| `usage-windows.expected` | `<limit_id>\t<window>\t<pct used>` from the same `token_count` lines' `rate_limits`: the free plan's one `primary` window, `window_minutes` 43200 (30d), 51% used. |
| `bypass-subagent.txt` | In a linked git worktree that only `codex_trust <worktree>` had trusted (no trust dialog showed): `Spawn a sub-agent and have the sub-agent (not you) run the shell command: touch subagent-proof.txt …`, after the turn. No approval prompt; `subagent-proof.txt` was created. |
| `bypass-subagent.jsonl` | The two rollouts of that run, each row tagged `conversation: parent\|subagent`, cut to `session_meta`, tool calls and their output, and assistant messages: the parent spawned the sub-agent, and the sub-agent's `exec_command` ran the `touch`. The sub-agent's `session_meta` carries its own `id`, the parent's `session_id` and `parent_thread_id`, and the same `cwd`. |
| `session` | The capture session's thread id (`session_meta.id`). |
| `model` | The model the capture ran. |
| `effort-flag` | How the launch line spells the effort: the config override `-c model_reasoning_effort=` (Codex has no effort flag; `codex --help`). |
| `handoff-skill` | How a prompt invokes the handoff skill: Codex invokes skills as `$<name>` (cli-capabilities § `codex`, hooks / plugins / skills row). |
| `VERSION` | `codex --version`, then the capture date and host. |
| `fake-cli` | Stands in for `codex` when the matrix runs a typed launch line: it writes `transcript.jsonl` as the rollout of `session` under `$CODEX_HOME/sessions/<today>/`, its `session_meta` stamped with the pane's cwd and the time now, as the capture did. |
| `stop-hook` | One end of turn as Codex runs it: the harness-ralph Stop hook (`plugins/codex/harness-ralph/hooks/stop-hook.py`, which `codex_prereqs` installs) handed `hook-input.json` for the given worktree, session and reply. |

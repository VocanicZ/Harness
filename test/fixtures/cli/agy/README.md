# `agy` fixtures

Captured 2026-10-27 (UTC) on the fleet host from Antigravity CLI `1.4.8` (Google AI Pro account), in a
throwaway git repo, model `gemini-3.8-flash-low`, launched as Harness does:
`agy --dangerously-skip-permissions --model <m> -i "<prompt>"`. The pane is 160x45; each `.txt` is
`tmux capture-pane -p` of it.

| file | how |
|---|---|
| `trust.txt` | `agy` in the repo before it was trusted: the workspace-trust dialog. Its selected option, `> Yes, I trust this folder`, is at column 0 like the input prompt. |
| `busy.txt` | Mid-turn, before the first token: braille spinner + `Loading...`. |
| `busy-generating.txt` | Mid-turn while the reply streamed: braille spinner + `Generating...`. |
| `idle.txt` | After the turn ended: `>` alone at column 0 between two rules. (A background shell command still running leaves the pane like this too: the turn is over.) |
| `limit.txt` | NOT triggerable on demand. `idle.txt` with `You have exhausted your quota on this model.` inserted above the input box; that string is in the 1.4.8 binary (byte search of `~/.local/bin/agy`). |
| `transient.txt` | NOT triggerable on demand. `idle.txt` with `Agent execution terminated due to error.` (agy's give-up after its own retries) inserted the same way, from the same binary search. |
| `transient-retrying.txt` | NOT triggerable on demand. `busy.txt` with its spinner label replaced by `Model unavailable (attempt 2/10), retrying in 12s`, agy's in-progress status while it retries an unavailable model (the 1.4.8 binary's changelog: "show what the agent is waiting on, such as … retrying an unavailable model (for example `Model unavailable (attempt 2/10), retrying in 12s` with a live countdown)"). The `>` input box shows below it, so it must read as busy and never as a transient give-up.
| `bypass-subagent.txt` | #256, in a throwaway git repo `agy_trust` had pre-accepted: `agy --dangerously-skip-permissions --model gemini-3.8-flash-low -i "Spawn a sub-agent and have the sub-agent (not you) run the shell command: touch subagent-proof.txt …"`, after the turn. No trust dialog, no permission prompt; `subagent-proof.txt` was created. |
| `bypass-subagent.jsonl` | The two transcripts of that run (`brain/<id>/.system_generated/logs/transcript.jsonl`), each row tagged `conversation: parent\|subagent`, cut to the fields shown and system messages dropped: the parent created the sub-agent, and the sub-agent's shell step (`Command exited with code 0.`) ran the `touch`. |
| `permission.txt` | The control for it: the same agy WITHOUT `--dangerously-skip-permissions`, asked to `touch main-proof.txt`, stopped on `Requesting permission for:` / `Run this command?`, its `> 1. Yes, run command` at column 0. |
| `trust-child-of-trusted.txt` | agy launched in `<dir>/child` after `agy_trust <dir>`: the trust dialog still shows, so a trusted parent does not cover the directories under it. |
| `transcript.db` | `~/.gemini/antigravity-cli/conversations/<session>.db` of the capture session, reduced to its `gen_metadata` table and, in each row, to the two fields the usage reader decodes (1.4 usage, 1.19 model id); everything else (request bodies, ids) dropped. |
| `usage.expected` | What `agy_usage.py` folds it to. The field numbers were checked against agy's own report: `agy -p … --output-format json` said `input_tokens 19156, output_tokens 36` for a two-call conversation, and decoding that conversation's db gave 19156 / 36. This capture's totals also equal the sum of the per-step `input_tokens`/`output_tokens` in its `brain/<session>/.system_generated/logs/transcript.jsonl`. |
| `last_conversations.json` | The capture's entry of `~/.gemini/antigravity-cli/cache/last_conversations.json` (workspace → conversation id), with the workspace path replaced by `@WD@`. This is how the adapter learns the session id agy picked. |
| `session` | That conversation id. |
| `hook-transcript.jsonl` | `brain/<id>/.system_generated/logs/transcript.jsonl` of a goal-loop run whose task file names the promise. The agent read that file, and the read's output (logged `source: MODEL`, `type: GENERIC`) carries `<promise>ZEBRA DONE</promise>`; the model's own replies (`PLANNER_RESPONSE`) do not. The harness-ralph Stop hook must keep looping on it. |
| `model` | The model the capture ran. |
| `VERSION` | `agy --version`, then the capture date and host. |
| `fake-cli` | Stands in for `agy` when the matrix runs a typed launch line: it records `session` for the workspace in `cache/last_conversations.json`, puts `transcript.db` at `conversations/<id>.db`, and starts `brain/<id>/.system_generated/logs/transcript.jsonl` with a step stamped `created_at` now, as the capture did. |
| `stop-hook` | One end of turn as agy runs it: the harness-ralph Stop hook (`plugins/ralph-loop`, which `agy_prereqs` installs), handed `{conversationId, workspacePaths, transcriptPath}`, over `hook-transcript.jsonl` plus one model reply (`PLANNER_RESPONSE`). |
| `handoff-skill` | How a prompt invokes the handoff skill: agy expands skills as slash commands, `/<name>` (local: `agy --help`, `--disable-slash-commands  Disable slash command and skill expansion`). |
| `usage-windows.json` | `agy -p "/usage" --output-format json`, run on the host the same day (runs no turn). |
| `usage-windows.expected` | `<group>\t<window>\t<pct used>` it reports: `100 - remaining_fraction*100`. |

## `stream-json/` — the headless turn (#486)

What the headless lane runner (`scripts/cli/agy_headless.py`) reads: the stdout of
`agy --dangerously-skip-permissions [--model <m>] [--conversation <id>] --input-format stream-json --output-format stream-json -p=`,
the message on stdin as one `{"event":"user","message":{"content":"<text>"}}` line, one JSON object per line out.
Captured 2026-11-04 (UTC) on the fleet host from Antigravity CLI `1.4.12` (Google AI Pro account), model
`claude-sonnet-4-6` (the Gemini model group's quota was out for days, which is also how the limit capture came about),
in a throwaway git repo; each capture is the run's stdout unchanged but for the `init` event's `cwd`
(`/work/repo`).

| file | how |
|---|---|
| `normal.jsonl` | The first turn of a new conversation, no `--conversation`: `Reply with exactly the word PONG and nothing else.` `init` (the conversation id agy generated, the tools, the model), `step_update`s (`user_input`; `agent_response` streaming `text_delta` `PONG`, then DONE with `usage`) and `result` `SUCCESS` (`response` `PONG\n`, `usage`). Exit 0. |
| `tool-use.jsonl` | The next turn of that conversation, `--conversation <id>`: `Use your shell tool to run the command: echo hi > proof.txt — then reply with exactly DONE.` Same `conversation_id`: `--conversation` carries it. An `agent_response` (the tool call's model turn, no text), a `tool` step (`run_command`, ACTIVE then DONE with `tool_info.parameters.CommandLine` and `output`), a second `agent_response` (`DONE`) and the `result` (`num_turns` 2, `usage` summed over the turn's model calls). Exit 0; `proof.txt` was created. |
| `limit.jsonl`, `limit.stderr` | The default Gemini model, whose weekly quota was out (`agy -p /usage` showed `remaining_fraction` 0): a `user_input` step, an `error_message` step and a `result` `ERROR` with `error` `Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 93h37m49s.`, `finished_reason` `error`, zero usage. Exit 3; stderr carries `error: …` and `AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): …"}`. |
| `no-conversation.jsonl`, `no-conversation.stderr` | `--conversation 00000000-0000-4000-8000-000000000000`, a conversation agy does not have: stderr `warning: conversation "…" not found`, and the message ran in a NEW conversation (its own `conversation_id` on every event), `SUCCESS`, exit 0. The runner adopts the new id. |
| `transient.jsonl`, `transient.stderr` | NOT triggerable on demand: `limit.jsonl` with the `result`'s `error` replaced by `Agent execution terminated due to error.` (agy's give-up after its own retries, a string of the 1.4.8 binary, `agy_transient_re`) and a stderr in the shape of the limit capture, its `AGY_ERROR` a 503 `UNAVAILABLE`. Synthetic, as `../transient.txt` is. Exit 3. |
| `fake-agy` | Stands in for `agy` in `test/test_agy_headless.py` and the matrix's `headless-*` rows (`test/test_cli_matrix.sh`, #486): each run replays the fixture `$FAKE_CLAUDE_DIR/plan` names next (text after the name replaces its reply), with every `conversation_id` set to the conversation its argv continues (`--conversation`) or a new one it also records as agy does (`conversations/<id>.db` from `../transcript.db`, the workspace in `cache/last_conversations.json`, a `brain/<id>` transcript), records its argv and the stdin prompt, can hold mid-turn, has a `hang` turn that starts a grandchild for the stop test, answers `-p /usage` with `../usage-windows.json`, and runs an executable `turn-hook` with each prompt (#350). Its header says how. |

What the runner reads from them (`Turn.outcome`): a `result` `SUCCESS` and exit 0 → `idle` (the reply is `response`); an
`ERROR` whose message is a quota (`Individual quota reached`, `exhausted your quota`, `Quota exhausted`,
`AI credits balance is too low`) → `limit`, its reset the message's "Resets in 93h37m49s" from now; any other `ERROR`,
or an exit with no `result`, → `transient`. agy has no quota meter in the stream, so no `rate_limit` window is read
off a turn: `agy -p /usage` (`usage-windows.json`) is the usage-windows row's, as on a pane. The Stop hook of the
`harness-ralph` plugin runs inside `agy -p` too (seen on the host with 1.4.12: with a `.claude/ralph-loop.local.md` naming a
promise the agent never said, one turn ran a `system_message` step and answered a second time before the hook let it end,
and `result.response` held both answers, `PONG\nPONG\n`), so the driven loop finds a looping lane's work already done, and
the reply it reads is the last `agent_response` step's text, not `response`.

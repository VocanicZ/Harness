# `claude` stream-json fixtures

What the headless lane runner (`scripts/cli/claude_headless.py`, #347) reads: the stdout of
`claude -p --output-format stream-json --verbose`, one JSON event per line. Captured 2026-10-31 (UTC)
on the fleet host from Claude Code `2.1.316`, `--model haiku --dangerously-skip-permissions`, in a
throwaway git repo, the prompt on stdin (`claude -p` waits 3s for stdin otherwise, and warns).

| file | how |
|---|---|
| `normal.jsonl` | `claude -p … --session-id <uuid>`, prompt `Reply with exactly the word PONG and nothing else.`, against the real API on the host's subscription. The user's SessionStart hook shows as `hook_started`/`hook_response`, then `system/init`, the `assistant` reply, a `rate_limit_event` (`status: allowed`) and the `result` (`subtype: success`, `is_error: false`, `result: "PONG"`). Exit 0. |
| `tool-use.jsonl` | The next turn of the same session: `claude -p … --resume <uuid>`, prompt `Use your Bash tool to run the shell command: echo hi > proof.txt — then reply with exactly DONE.` `system/thinking_tokens`, an `assistant` `tool_use` (Bash), a `rate_limit_event` (`allowed_warning`, the 7-day window at 94%), the `user` `tool_result`, the `assistant` text and the `result` (`DONE`). `proof.txt` was created. Exit 0. Same `session_id` as `normal.jsonl`: `--resume` carries the session. |
| `limit.jsonl` | NOT triggerable on demand against the real API, so claude was pointed at a local stand-in endpoint: `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>`, a fake `CLAUDE_CODE_OAUTH_TOKEN` (so claude takes the subscription path and reads the unified rate-limit headers) and a throwaway `CLAUDE_CONFIG_DIR`. The endpoint answered every request `429` with `anthropic-ratelimit-unified-status: rejected`, `…-representative-claim: five_hour` and a reset 3h ahead. Claude printed `system/init`, a `rate_limit_event` with `status: rejected` (`resetsAt`, `rateLimitType: five_hour`), a synthetic `assistant` message and a `result` with `is_error: true`, `api_error_status: 429`, `api_error: "usage_limit_reached"`, `result: "You've hit your 5-hour limit · resets 12:11pm (UTC)"`. Exit 1. With an API key in place of the OAuth token, the same 429 gives no `rate_limit_event` and no `api_error`, only `API Error: Request rejected (429) …`: the runner reads that as transient. |
| `transient.jsonl` | NOT triggerable on demand either: the same stand-in endpoint answering every request `529` `overloaded_error` (`ANTHROPIC_API_KEY` fake). Claude retried ten times, one `system/api_retry` event each (`attempt`, `max_retries: 10`, `error_status: 529`, `retry_delay_ms`), about 3 minutes in all, then printed a synthetic `assistant` message and a `result` with `is_error: true`, `api_error_status: 529`, `terminal_reason: api_error`, `result: "API Error: 529 Overloaded. … check your inference gateway (127.0.0.1:18529)."` (the gateway clause is there because of the stand-in endpoint). Exit 1. |
| `fake-claude` | Stands in for `claude` in `test/test_claude_headless.py`: each run replays the fixture `$FAKE_CLAUDE_DIR/plan` names next, with every `session_id` set to the one its argv passes (`--session-id`/`--resume`), records its argv and stdin prompt, can hold mid-turn, and has a `hang` turn that starts a grandchild for the stop test. Its header says how. |

Each capture is the run's stdout unchanged except: the lists in `system/init` (`tools`, `mcp_servers`,
`slash_commands`, `terminal_slash_commands`, `skills`, `plugins`, `agents`) are cut to
`["(trimmed)"]`; hook `output`/`stdout`, thinking `signature`s and the messaging socket path are
`(trimmed)`/`@SOCKET@`; the working directory is `@WD@` and the config dir's project path
`@CONFIG@/projects/@PROJECT@`. Ids, timestamps, usage and costs are as printed.

What the runner reads from them (`Turn.outcome`): a `result` with `is_error: false` → `idle`; an error
`result` after a `rate_limit_event` with `status: rejected`, or with `api_error: usage_limit_reached`
→ `limit` (its `resetsAt` kept); any other error `result`, or a process that exits with no `result`
→ `transient`. `api_retry` events keep the turn `busy` (the retry is in `state.json`'s `retry`).

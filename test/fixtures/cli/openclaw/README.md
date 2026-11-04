# `openclaw` fixtures

Captured 2026-10-28 (UTC) on the fleet host from OpenClaw `2026.10.8` (`dc2523e`; npm
`openclaw@latest --allow-scripts=openclaw`, run on its own node `v24.22.1` because the host's `v24.21.0`
is below the package's engine floor), signed in through OpenClaw's `claude-cli` provider: the host's
Claude Code login, model `claude-cli/claude-haiku-5-5` (`openclaw models set claude-cli/claude-haiku-5-5`
in the operator config `~/.openclaw/openclaw.json`). Each capture ran in a throwaway git repo. Each `.txt`
is `tmux capture-pane -p` of the pane. Unless a row says otherwise the pane is a lane launched by
`launch_agent` from `scripts/lib.sh` with `HARNESS_CLI=openclaw` on a private tmux server — tmux's
default 80x24, the line `exec env OPENCLAW_INCLUDE_ROOTS=~/.openclaw bash scripts/cli/openclaw-loop.sh
--bin openclaw --cwd <wt> --run <uuid> --config <wt>/.harness-openclaw/openclaw.json [--model
claude-cli/claude-haiku-5-5 --thinking low] --timeout 14400 "<bootstrap>"`, so every turn is a real
`openclaw agent exec --json` run in the worktree.

| file | how |
|---|---|
| `idle.txt` | A lane once its turn ended: the task ran `sleep 30` and replied `SLEPT`; the reply, then the prompt `harness-openclaw ❯ `. |
| `busy.txt` | A lane 25 s into a turn whose task ran `sleep 40`: the busy line alone on the screen. |
| `busy-typed.txt` | `Please continue — typed while busy: reply only TYPED-SEEN` typed and Entered (tmux `send-keys -l`, then `Enter`) during that turn: the terminal echoes it under the busy line. When the turn ended, the loop read it as the next turn's message (a second `busy · started …` at once). |
| `loop.txt` | The goal loop on the real CLI: a lane whose `.harness-task.md` asked for `STILL WORKING` unless the message starts with `🔄 Ralph iteration`, the promise `CAP DONE` otherwise, tended by `watchdog_session` (lib.sh). Turn 1 replied `STILL WORKING`; the watchdog typed `🔄 Ralph iteration 2 \| To stop: output <promise>CAP DONE</promise> … Read .harness-task.md …`; turn 2 replied the promise and the next poll ended the loop (state file removed). |
| `transcript.jsonl` | That lane's `<wt>/.harness-openclaw/runs/<uuid>.jsonl`: the two turns' `agent exec --json` envelopes as the loop recorded them (each with its `harness` key). `session` is its uuid. |
| `usage.expected` | What `openclaw_usage` folds `transcript.jsonl` to, per `<provider>/<model>`: input 2+2, output 5+8, cacheRead 41590+41652, cacheWrite 176+186. |
| `usage-windows.json` | Captured 2026-10-29: the `usage` key of `openclaw status --usage --json` with windows, from a live provider. This host's `claude-cli` provider reports none (`usage-none.json`), so the document was made by OpenClaw's own code on the live endpoint: `loadProviderUsageSummary` (`dist/provider-usage.load-C2l9sesb.mjs` in `openclaw@2026.10.8`, commit `dc2523e` — the function `status --usage` calls; snapshot type `ProviderUsageSnapshot` in `dist/config-contracts-DhkndZxE.d.ts`), handed the `anthropic` provider with the host's Claude Code OAuth token and run against `api.anthropic.com/api/oauth/usage` through `fetchClaudeUsage` (`dist/provider-usage.fetch.claude-DIE0ZSbx.mjs`). One change: the request's `User-Agent` was `claude-code/2.1.0`, not `openclaw`, because the endpoint answered `HTTP 429: Rate limited` to `openclaw` on every try. Wrapped as `{"usage": <summary>}`, the place `status --json` puts it. |
| `usage-windows.expected` | What `openclaw_limit_usage` reads from `usage-windows.json` (`<provider> <label> <pct used>`; the matrix moves each `resetAt` into the future first). |
| `usage-none.json` | The `usage` key of `openclaw status --usage --json` on this host (`claude-cli`; the text form prints `Usage: no provider usage available`), the rest of the status document dropped: `providers: []`, so `openclaw_limit_usage` returns rc 1. |
| `transient.txt`, `transient-runs.jsonl` | A lane whose operator config (`HARNESS_OPENCLAW_CONFIG`) pointed `agents.defaults.model.primary` at `vllm/fake`, a local OpenAI-compatible server answering every chat call `503 {"error": {"message": "Service Unavailable"}}`: after 7 calls (about 90 s) the turn failed with `The AI service is temporarily overloaded. Please try again in a moment.`; the pane and the recorded envelope. |
| `limit.txt`, `limit-runs.jsonl` | The same setup, the server answering `429` with `{"error": {"message": "You have reached your usage limit for this period.", "type": "usage_limit_reached", "resets_in_seconds": 7200}}` and `retry-after: 7200`: one call, then `⚠️ You have reached your usage limit for this period.; Retry-After: 7200 seconds`. A live quota could not be exhausted on demand. |
| `limit-short-break.txt` | The server answering a plain `429 {"error": {"message": "Rate limit reached for requests", "code": "rate_limit_exceeded"}}`: 10 calls over about 3 minutes, then OpenClaw's own copy `⚠️ The AI service needs a short break. Please try again in a few minutes.` |
| `no-bypass.json` | `openclaw agent exec` run by hand (no lane config) with an operator config of `~/.openclaw/openclaw.json` plus `tools.exec.mode: deny`, asked to run `touch exec-proof.txt` itself: the envelope (trimmed to its result fields) — the exec was refused, no file. |
| `bypass.txt` | The same task and the same `deny` operator config, as a lane: the lane config's `tools.exec.mode: full` over the included `deny`, the command ran and `exec-proof.txt` was created. |
| `bypass-subagent.txt` | A lane asked to have a sub-agent (`sessions_spawn`) run `touch subagent-proof.txt`: both spawns failed `published reply runtime missing for main`; no child ran, no file. Sub-agents need the Gateway; an `agent exec` turn has none. |
| `subagent-task.md`, `subagent-critic.txt`, `subagent-lane.jsonl`, `subagent-critic.jsonl`, `subagent-critic.out` | The sub-agent substitute (#314). A lane (launched from `openclaw_launch`'s line on a private tmux server, model `claude-cli/claude-haiku-5-5`, effort `low`) whose `.harness-task.md` (`subagent-task.md`) was review.md's 5d JUDGE step with `cli_subagent`'s substitute as its "to start it": a gauntlet round dir `<scratch>/gauntlet/r1/{A,B}` with transcripts and timings of two toy CLIs, and `.mapping` beside them. The lane's file tool refused to write the brief outside its worktree, so it wrote it with a shell heredoc, ran the command and replied `critic said:` with the critic's two lines (`subagent-critic.txt`, the pane; `subagent-lane.jsonl`, the lane turn's `transcript_events` from `<wt>/.harness-openclaw/agents/main/agent/openclaw-agent.sqlite`). `subagent-critic.jsonl`: the critic's own `transcript_events`, from the `openclaw-agent.sqlite` under the `mktemp -d` state dir the command made: its own session, its cwd the round dir, its one user message the brief, its answer `winner: B` / `gap: …`. `subagent-critic.out`: the same command run by hand on that round dir and a brief of the same shape, its stdout — the reply alone, which the matrix's fake prints for a run without `--json`. Paths are shown as `<scratch>` and `~`. |
| `skill.txt` | A lane with a project skill `.agents/skills/echo-proof/SKILL.md`, asked to run it and say whether a `handoff` skill is available: it ran echo-proof, and found `handoff` at `~/.claude/skills/handoff/SKILL.md` through the lane config's `skills.load.extraDirs`. Before the adapter listed `~/.claude/skills`'s skill dirs one by one, `handoff` was not available: that dir has a `SKILL.md` of its own, which OpenClaw reads as one skill (`openclaw skills list --json` on a dir with a root `SKILL.md` and a sub-skill listed only the root one). |
| `smoke.log` | The smoke run (see the PR): a lane on a linked worktree through `launch_agent`, tended by `watchdog_session` every 8 s, model `claude-cli/claude-haiku-5-5`, effort `low`, the task to write `hello.txt`, then commit it and print the promise. Paths are shown as `<scratch>` and `~`. |
| `session` | `transcript.jsonl`'s run id: the `<uuid>` its lane's launch passed to `--run`, the file's name under `runs/`. |
| `model` | The model the captures ran, as a lane's `--model` names it: `claude-cli/claude-haiku-5-5`. |
| `effort-flag` | How a lane's effort reaches OpenClaw: `--thinking `, the loop's flag that `openclaw_launch` puts before the effort and passes to each `agent exec` turn. |
| `handoff-skill` | How a prompt names the handoff skill: `handoff`, found through the lane config's `skills.load.extraDirs` (`skill.txt`). |
| `fake-cli` | Not a capture: what the matrix runs as `openclaw` — it prints `transcript.jsonl`'s first envelope under a new session id; without `--json` (a sub-agent run), `subagent-critic.out`. |
| `turn-end` | Not a capture: one turn's envelope appended the way the loop records it, for the matrix's driven-loop row. |

Not captured: a pane killed by `tmux kill-session` mid-turn left `agent exec`, the `claude` process the
`claude-cli` provider started and its `sleep 120` running until the loop learned to stop the turn's
process tree on its hangup; after that change the same kill left no process in the worktree. Escape does
nothing to a running turn (the loop is not a TUI), so there is no `interrupted.txt`.

## `agent-json/` — the headless turn (#485)

What the headless lane runner (`scripts/cli/openclaw_headless.py`) reads: the stdout of
`openclaw agent exec --json --message-file - --config <lane config> --cwd <wt> --state-dir <state> --timeout <s>`, the
message on stdin. Unlike the other CLIs' captures this is not a stream: `--json` prints ONE pretty-printed JSON document
(the stable agent-exec envelope) when the turn ends, and nothing before it (the `[agent/cli-backend]` progress lines
are on stderr), which the core reads whole (`json_documents`). Captured 2026-11-04 (UTC) on the fleet host from OpenClaw
`2026.10.8` (`dc2523e`), in a throwaway git repo and a throwaway state dir, the host's operator config
(`claude-cli/claude-haiku-5-5`); `normal.json` and `tool-use.json` are the runs' stdout unchanged.

| file | how |
|---|---|
| `normal.json` | `Reply with exactly the word PONG and nothing else.` Exit 0, 48 s (the `claude-cli` backend starts a `claude` process): `ok` true, `status` `ok`, `final` `PONG`, `usage` `{input: 2, output: 5, cacheWrite: 41805}` (no `cacheRead` key when there were none), `toolSummary.calls` 0, `model` `claude-haiku-5-5`, `provider` `claude-cli`, `sessionId`. |
| `tool-use.json` | The next turn in the same `--state-dir`: `Use your shell tool to run the command: echo hi > proof.txt -- then reply with exactly DONE.` `final` `DONE`, `toolSummary` `{calls: 1, tools: ["mcp__openclaw__exec"], failures: 0}`, `usage` `{input: 2, output: 5, cacheRead: 41826, cacheWrite: 128}`. A new `sessionId`: the second run did not continue the first (the stderr line read `useResume=false session=none`), so a turn is its own session. `proof.txt` was created. Exit 0. |
| `limit.json` | NOT triggerable on demand (a live quota cannot be exhausted); the envelope of the stand-in-endpoint run in `limit-runs.jsonl` / `limit.txt` (a local OpenAI-compatible server answering `429` with `usage_limit_reached` and `retry-after: 7200`), minus the `harness` key the pane's loop added and re-serialised with `indent=2` as `--json` prints. `ok` false, `status` `error`, `final` empty, `error.message` `⚠️ You have reached your usage limit for this period.; Retry-After: 7200 seconds`. The process exited 1. |
| `transient.json` | The same, from `transient-runs.jsonl` / `transient.txt`: the server answering `503`; after 7 calls (about 90 s) `error.message` `The AI service is temporarily overloaded. Please try again in a moment.` Exit 1. |
| `usage.expected` | What `openclaw_usage` folds the lane's `runs/<id>.jsonl` to once the lane ran `tool-use.json` then `normal.json` (the matrix's `headless-stats-session-end-usage` row): `claude-cli/claude-haiku-5-5`, input 2+2, output 5+5, cacheRead 41826+0, cacheWrite 128+41805. |
| `fake-openclaw` | Stands in for `openclaw` in `test/test_openclaw_headless.py` and the matrix's `headless-*` rows (`test/test_cli_matrix.sh`, #485): each `agent exec` run replays the fixture `$FAKE_CLAUDE_DIR/plan` names next (text after the name replaces its reply) as the pretty-printed document, under a new `sessionId`, records its argv, stdin prompt and cwd, can hold before printing, has a `hang` turn that starts a grandchild for the stop test, runs an executable `turn-hook` with each prompt (#350), and answers `status --usage --json` (`../usage-windows.json`, resets an hour ahead). Its header says how. |

What the runner reads from them (`Turn.outcome`): `ok` true and `status` `ok` → `idle` (the reply is `final`); a failed
envelope whose `error.message` is a quota or billing message (`usage limit`, `quota`, `The AI service needs a short
break`, the billing copy) → `limit`, its reset the `Retry-After: 7200 seconds` when it has one; any other failed
envelope, or a process that exits with no envelope → `transient`. Usage windows are not in the envelope;
`openclaw status --usage --json` (`usage-windows.json`) is how they are read, as for a pane.

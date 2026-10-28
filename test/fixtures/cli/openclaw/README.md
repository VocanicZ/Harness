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
| `transient.txt`, `transient-runs.jsonl` | A lane whose operator config (`HARNESS_OPENCLAW_CONFIG`) pointed `agents.defaults.model.primary` at `vllm/fake`, a local OpenAI-compatible server answering every chat call `503 {"error": {"message": "Service Unavailable"}}`: after 7 calls (about 90 s) the turn failed with `The AI service is temporarily overloaded. Please try again in a moment.`; the pane and the recorded envelope. |
| `limit.txt`, `limit-runs.jsonl` | The same setup, the server answering `429` with `{"error": {"message": "You have reached your usage limit for this period.", "type": "usage_limit_reached", "resets_in_seconds": 7200}}` and `retry-after: 7200`: one call, then `⚠️ You have reached your usage limit for this period.; Retry-After: 7200 seconds`. A live quota could not be exhausted on demand. |
| `limit-short-break.txt` | The server answering a plain `429 {"error": {"message": "Rate limit reached for requests", "code": "rate_limit_exceeded"}}`: 10 calls over about 3 minutes, then OpenClaw's own copy `⚠️ The AI service needs a short break. Please try again in a few minutes.` |
| `no-bypass.json` | `openclaw agent exec` run by hand (no lane config) with an operator config of `~/.openclaw/openclaw.json` plus `tools.exec.mode: deny`, asked to run `touch exec-proof.txt` itself: the envelope (trimmed to its result fields) — the exec was refused, no file. |
| `bypass.txt` | The same task and the same `deny` operator config, as a lane: the lane config's `tools.exec.mode: full` over the included `deny`, the command ran and `exec-proof.txt` was created. |
| `bypass-subagent.txt` | A lane asked to have a sub-agent (`sessions_spawn`) run `touch subagent-proof.txt`: both spawns failed `published reply runtime missing for main`; no child ran, no file. Sub-agents need the Gateway; an `agent exec` turn has none. |
| `skill.txt` | A lane with a project skill `.agents/skills/echo-proof/SKILL.md`, asked to run it and say whether a `handoff` skill is available: it ran echo-proof, and found `handoff` at `~/.claude/skills/handoff/SKILL.md` through the lane config's `skills.load.extraDirs`. Before the adapter listed `~/.claude/skills`'s skill dirs one by one, `handoff` was not available: that dir has a `SKILL.md` of its own, which OpenClaw reads as one skill (`openclaw skills list --json` on a dir with a root `SKILL.md` and a sub-skill listed only the root one). |
| `smoke.log` | The smoke run (see the PR): a lane on a linked worktree through `launch_agent`, tended by `watchdog_session` every 8 s, model `claude-cli/claude-haiku-5-5`, effort `low`, the task to write `hello.txt`, then commit it and print the promise. Paths are shown as `<scratch>` and `~`. |
| `session` | `transcript.jsonl`'s run id: the `<uuid>` its lane's launch passed to `--run`, the file's name under `runs/`. |
| `model` | The model the captures ran, as a lane's `--model` names it: `claude-cli/claude-haiku-5-5`. |
| `effort-flag` | How a lane's effort reaches OpenClaw: `--thinking `, the loop's flag that `openclaw_launch` puts before the effort and passes to each `agent exec` turn. |
| `handoff-skill` | How a prompt names the handoff skill: `handoff`, found through the lane config's `skills.load.extraDirs` (`skill.txt`). |
| `fake-cli` | Not a capture: what the matrix runs as `openclaw` — it prints `transcript.jsonl`'s first envelope under a new session id. |
| `turn-end` | Not a capture: one turn's envelope appended the way the loop records it, for the matrix's driven-loop row. |

Not captured: a pane killed by `tmux kill-session` mid-turn left `agent exec`, the `claude` process the
`claude-cli` provider started and its `sleep 120` running until the loop learned to stop the turn's
process tree on its hangup; after that change the same kill left no process in the worktree. Escape does
nothing to a running turn (the loop is not a TUI), so there is no `interrupted.txt`.

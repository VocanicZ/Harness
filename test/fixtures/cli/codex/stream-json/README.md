# `codex` exec --json fixtures

What the headless lane runner (`scripts/cli/codex_headless.py`, #481) reads: the stdout of
`codex exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -m gpt-5.6-luna -` (the
prompt on stdin), one JSON event per line. Captured 2026-11-04 (UTC) on the fleet host from Codex CLI `0.154.0`,
in a throwaway git repo.

| file | how |
|---|---|
| `normal.jsonl` | `codex exec --json …`, prompt `Reply with exactly the word PONG and nothing else.`, against the stand-in endpoint below with a throwaway `CODEX_HOME` (the host's account is out of quota until 2026-11-18). `thread.started` (the thread id), `turn.started`, `item.completed` (`agent_message` `PONG`), `turn.completed` with `usage`. Exit 0. |
| `tool-use.jsonl` | The next turn of that thread: `codex exec resume --json … <thread id> -`, prompt `Now reply with exactly the word DONE and nothing else.` Same `thread_id`: `exec resume` carries the thread. Its `turn.completed.usage` is the thread's RUNNING TOTAL (`input_tokens` 243 = 121 + 122): the turn's own usage is the rollout's `last_token_usage` (`token-count.jsonl`). The stand-in cannot make codex run a tool (this codex gives the model one `exec` tool that evaluates JavaScript, and it prints no `command_execution` item for it), so the file is a second plain turn, named for the claude fixture it stands for. |
| `limit.jsonl` | REAL, not a stand-in: the host's own ChatGPT account, whose quota is exhausted. `codex exec --json …` printed `thread.started`, `turn.started`, an `error` event and `turn.failed`, both with `You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at Nov 18th, 2026 3:21 PM.` Exit 1. The reset time is local time, in that shape. |
| `transient.jsonl` | The stand-in answering every request `503`: `thread.started`, `turn.started`, five `error` events `Reconnecting... n/5 (unexpected status 503 Service Unavailable: overloaded, url: http://127.0.0.1:<port>/v1/responses)` (about 25s in all), one final `error`, `turn.failed` with `unexpected status 503 Service Unavailable: overloaded, …`. Exit 1. (The stand-in's address is in the messages.) |
| `no-conversation.stderr` | `codex exec resume --json … 00000000-1111-7222-8333-444444444444 -` of a thread codex does not have: nothing on stdout, this line on stderr, exit 1. The runner reads it as "no thread to resume" (#350). |
| `token-count.jsonl` | The two `token_count` lines of that thread's rollout (`$CODEX_HOME/sessions/…/rollout-<ts>-<id>.jsonl`, which `codex exec` writes like the TUI does): `info.last_token_usage` per response and `rate_limits` (the stand-in's `x-codex-*` headers: `primary` 300 min 7%, `secondary` 10080 min 51%). `fake-codex` appends them to the rollouts it writes. |
| `stats.expected` | What the stats row (`headless-stats-session-end-usage`) expects a lane's two turns to fold to, in `usage.expected`'s columns (`model\tinput\toutput\tcache_read\tcache_write`): the two `token-count.jsonl` lines' `last_token_usage` summed, `cached_input_tokens` taken out of `input_tokens` (71 + 72 = 143 uncached, 18 out, 50 + 50 = 100 cached). |
| `usage-windows.expected` | `<limit_id>\t<window>\t<pct used>` that `codex_limit_usage` reads off those rollouts for a lane. |
| `standin_server.py` | The stand-in for the Responses endpoint, so the real binary can be run without quota: `python3 standin_server.py <port> [normal\|5xx]`; its header says how to point codex at it. `test/smoke/codex_headless_smoke.sh` uses it. |
| `fake-codex` | Stands in for `codex` in `test/test_codex_headless.py` and the matrix's `headless-*` rows (`test/test_cli_matrix.sh`): each run replays the fixture `$FAKE_CLAUDE_DIR (the fakes share claude's name for it)/plan` names next (`normal`, `tool-use`, `limit`, `transient`, `no-conversation`, `hang`; text after the name replaces the reply), with every `thread_id` set to the thread its argv resumes (or a new one), records its argv and prompt, can hold mid-turn, and writes the rollout a `CODEX_HOME` would hold. Its header says how. |

Each capture is the run's stdout unchanged. What the runner reads from them (`Turn.outcome`): `turn.completed`
→ `idle`; `turn.failed` whose message says `hit your usage limit` → `limit` (the `try again at` time kept);
any other `turn.failed`, or an exit with no `turn.completed` → `transient`; `Reconnecting... n/m` `error` events
keep the turn `busy` (the retry is in `state.json`'s `retry`).

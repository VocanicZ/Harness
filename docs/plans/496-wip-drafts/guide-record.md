### The end-to-end record of PRD #475 (#496)

Every claim in the [parity matrix](reference.md#windows-parity-matrix) names the log that shows it. The runs of the last task, each under the rules
above (lock, isolation, guard before and after, credential scan, cleanup; every log opens with the host, the commit and its Claude token usage):

| What | Script | Log |
|---|---|---|
| The live `claude` smoke: claim → lane → PR → merge → close, `pause --force` and resume, then the lane's token usage from `harness stats` and `harness forecast` (the only run with the real Claude sign-in) | `winsma.sh run <n> base`, `e2e.sh` stage `live` | `test/smoke/logs/@LIVE@` |
| Install by `npx` and by `curl`, re-install, update from v0.1.1 and from the previous release, rollback and forward, `uninstall --force --force-engine` | `lifecycle.sh` | `test/smoke/logs/@LIFE@` |
| `update --with-skills` into the sandbox `CLAUDE_CONFIG_DIR`, every `/harness*` skill linked, a lane-shaped shell | `tooling.sh` | `test/smoke/logs/@TOOL@` |
| `supervise --install`, a killed worker restarted by the supervisor, `supervise --uninstall` | `e2e.sh` stage `supervise` | `test/smoke/logs/@SUP@` |
| the dashboard (foreground and its task), `stats`, `forecast`, `one`, `status`, `poll`, `migrate`, `tier`, `release --dry-run`; `plan`, `prd` and `issue` | `e2e.sh` stages `ops`, `inject` | `test/smoke/logs/@OPS@` |
| the fixture-replay `headless-*` rows of every CLI, on Windows | `suite.sh` with `HX_TESTS="test_cli_matrix.sh"` | `test/smoke/logs/@SUITE@` |
| the other CLIs, live and headless, on the claude host | `fleet_smoke.sh <cli>` with `SMOKE_BACKEND=headless`; `codex_headless_smoke.sh` | `test/smoke/logs/<cli>-headless-20261108T*.log` |

Three things those runs showed that the guide above would not tell you:

- **Task Scheduler needs a logged-on user for these tasks.** `supervise --install` and `web --install` register `InteractiveToken` tasks that
  start at the task user's logon and run in that user's session (no administrator, nothing at boot). On winsma the ssh session is an administrator
  but the task user, `pc`, has no interactive session (`quser` lists another user on the console), so `schtasks /Run` queues the task and it never
  starts: `Last Result` stays `267011`, "the task has not yet run". The record therefore starts the task's own command line (`bash.exe` and the
  launcher script it names, exactly the task's `<Exec>`) detached, and says so. On a desktop where the owner is logged on the task runs itself, and
  a task that cannot start shows in `schtasks /Query /TN <name> /V /FO LIST`.
- **A supervisor pass is slow on Windows.** Every `gh`, `python3` and `git` call is a process spawn, so one pass over a fleet takes minutes, and a
  worker killed just after a pass began is restarted by the pass after it. The record allows 15 minutes.
- **A native Windows Python writes CRLF into a pipe.** Any `python3 … | while read` in the engine sees a trailing `\r`; the supervisor strips it
  (#496), and new code that reads Python's output in bash must do the same.

**Checkpoint on a fast lane.** The headless smokes ran with the checkpoint step on where the lane took long enough to be caught mid-task
(`opencode`), and off where a lane finished its one-file task before the pause could land (`copilot`: 100 s from launch to merge, so `pause --force`
waited out its 15 minutes for a lane that no longer existed, #662). `agy` ran on its Gemini model because its Claude-and-GPT bucket was at 100% until
Wed 08:01 UTC.

### Native Windows verified end to end on winsma, the Windows guide rewritten, and the supervisor finds fleets on Windows (#496)

The last task of PRD #475: everything the earlier tasks built, run for real on the owner's Windows 10 desktop (`winsma`) under the PRD's rules
(`C:\hx-496\` isolation, the `C:\hx-lock` lock, the before/after guard, no credential written, logs committed), plus the other CLIs' live headless
smokes on the claude host. Every parity-matrix row is now `✓` (with the test and the log that show it) or a sourced `n/a` (only `swarm submission`).

- **Live `claude` smoke on winsma** (the only run with the real Claude sign-in): claim → headless lane → PR → merge → close, a `pause --force`
  checkpoint mid-lane and the resume, then `harness stats` for the lane's Claude token usage: `test/smoke/logs/@LIVE@`.
- **Lifecycle once more on the final commit:** install by the `npx` and the `curl` line and again over it, update from v0.1.1 and from the previous
  release, `update --rollback` and forward, `uninstall --force --force-engine` leaving `HARNESS_HOME`, `HARNESS_BIN_DIR` and `HARNESS_USER_SKILLS`
  empty: `test/smoke/logs/@LIFE@`. `update --with-skills` into the sandbox `CLAUDE_CONFIG_DIR`, and every `/harness*` skill linked:
  `test/smoke/logs/@TOOL@`.
- **Operations:** `supervise --install` registers the per-home, logon-only task and a killed worker is restarted by the supervisor
  (`test/smoke/logs/@SUP@`); the web dashboard answers on a private port, from the foreground and from its task, and is gone after `web --uninstall`;
  `stats` (text, `--json`, `--issue`), `forecast`, `one check|gate`, `status`, `poll`, `migrate`, `tier` and `release --dry-run` run; `plan`, `prd` and
  `issue` each launch the injector lane: `test/smoke/logs/@OPS@`.
- **The other CLIs, live and headless on the claude host:** `opencode`, `copilot`, `hermes`, `openclaw`, `agy` (`test/smoke/logs/<cli>-headless-*.log`;
  copilot, hermes, openclaw and agy ran with the checkpoint step off, see the guide) and `codex` (`codex-headless-*.log`: its account is at its usage
  limit until 2026-11-18, so part A reports `limit`, as designed, and part B runs the real binary against the stand-in endpoint).
- **Fixed: the supervisor found no fleet on Windows.** A native Windows Python writes CRLF into a pipe, so the fleet path `sup_fleets` read ended in
  `\r`, `-f $d/config` never matched, and a killed worker was never restarted; the rules output and the auto-update phase (`sup_au_get`) had the same
  trailing CR. All three now strip it. `test/test_supervise.sh` runs them under a `python3` that ends every line with CRLF.
- **Fixed: a winsma run could not tell that its command had killed its own shell.** A `kill -9 ""` in a first draft of the end-to-end script took the
  remote shell down, ssh still exited 0, and the run reported OK. The remote shell now ends with `WS-EXIT <status>`; a run without it fails.
  The end-of-run process sweep also matches the run folder in the `C:/hx-N/` and `/c/hx-N/` spellings, not only `C:\hx-N\` (a dashboard server started
  by a script was left running); the end-to-end script signals a process only through `kill_pid`, which refuses an empty, 0, 1 or negative pid.
- **Fixed: `harness uninstall` left `HARNESS_HOME` behind on Windows.** Python compiles the LF-stdio `sitecustomize.py` the `python3` shim puts on
  `PYTHONPATH` on its first run, and the `__pycache__` beside it kept `bin/pylf` (and so the home) alive after the uninstall. It is removed with the
  file; `test/test_windows_uninstall.sh` plants one. Found by the lifecycle run on winsma.
- **Fixed: the winsma guard failed a clean live run.** Claude Code itself re-stamps a marketplace's `lastUpdated` in the owner's
  `~/.claude/plugins/known_marketplaces.json` when a session starts under the real sign-in. The guard hashes that file with the stamp blanked (any other
  change, a moved source or a new marketplace, still fails; `test/test_winsma.sh` pins both sides), the way it already reads `~/.claude.json`.
- Two checks of the winsma scripts had gone stale and are fixed: `lifecycle.sh` tested "an old `update.sh` fails cleanly" against `origin/main`, which has
  carried the fix since #491 (it now uses `1467c2d^`), and `tooling.sh` looked for the retired `ralph-loop` registration instead of the engine's own
  `harness-ralph` plugin.
- `test/smoke/winsma/e2e.sh` (stages `supervise`, `ops`, `inject`, `supdiag`, `live`) is the script those runs send; `fleet_smoke.sh` takes
  `SMOKE_KEEP_ENV` so a run on a shared host keeps its `HARNESS_HOME` instead of the smoke's own default (the real `~/.harness`).
- **A finding, not a fix:** Task Scheduler does not start the supervise or web task on winsma over ssh: both are `InteractiveToken` tasks, they
  start at the task user's logon, and `pc` has no interactive session there (Last Result `267011`, "has not yet run"). The runs start the task's own
  command line by hand, which is what the task executes; the guide says how to see the difference.
- **Docs:** `docs/windows-smoke.md` is now the Windows guide (first-class host, the CLI table, daily use, setup, the smoke, the shared check host,
  troubleshooting); README "native Windows" no longer says reduced mode (all seven CLIs, WSL2 optional); the parity matrix has no `✓ target` left and
  `test/test_windows_parity_doc.sh` fails if one comes back.
- Filed: #662 (`pause --force` waits out `HARNESS_PAUSE_GRACE` for a headless lane that finished before its checkpoint turn).

# Changelog

Notable changes to Harness. Releases and their full notes: [GitHub Releases](https://github.com/VocanicZ/Harness/releases).

## Unreleased

### `harness stats`: coding vs testing time per issue (#379)

- `harness stats --prd N` and `--issue N` split each session's wall time into **testing** (the time inside test-command
  Bash tool calls, from the call to its result) and **coding** (the rest), per session, per issue and in the PRD total;
  `--json` carries `coding_s` / `testing_s`. The split is a reusable function (`stats.time_split(transcript)`, also
  `scripts/stats.py time-split <transcript>`), so the benchmark can run it on any transcript.
- Which commands count as tests is a documented default pattern, replaceable with `HARNESS_TEST_COMMAND_PATTERNS`
  (environment or `.harness/config`); see [Coding vs testing time](docs/reference.md#coding-vs-testing-time-379).

### Headless turn adapter for `agy` (#486)

- `agy` runs on the headless session backend: `scripts/cli/agy_headless.py` is its adapter on the shared core (#480),
  and `agy` stops being refused as tmux-only. Each turn is one
  `agy --input-format stream-json --output-format stream-json -p=` in the lane's worktree with the message on stdin as a
  stream-json user line (so it never rides argv; the bare `-p=` only switches print mode on, because agy refuses a prompt
  on the command line beside that input format). agy names its own conversations: the first turn passes none and every
  later turn (or a relaunched lane's first) passes `--conversation <id>`, read off the stream. A `result` with `SUCCESS`
  and exit 0 is `idle`; an error that is a quota (`Individual quota reached. … Resets in 93h41m3s`, and the strings
  the tmux adapter already knew) is `limit` with the time it lifts; any other error, or an exit with no `result`, is
  `transient`. A conversation agy no longer has is no error: agy runs the message in a new one and the lane adopts its id.
- The core gained an optional adapter `stdin_payload(text)`, what a turn's process is sent on stdin for a message (agy
  reads one JSON line, not raw text). A lane's reply is the last `agent_response` step's text: the `harness-ralph` Stop
  hook runs inside `agy -p` too and its re-fed answers are joined in the stream's `response`.
- `test/test_agy_headless.py` runs the adapter against captures of the real CLI (`test/fixtures/cli/agy/stream-json/`,
  Antigravity CLI 1.4.12; the transient one is synthetic, as the pane fixture is), and the matrix's `headless-*` rows now
  pass for `agy` from fixture replay on Linux. Under `HARNESS_PLATFORM=windows` on the Linux fleet host all of them pass
  but `headless-checkpoint` and `headless-resume`, which fail the same way there for `claude` on `main`. The parity matrix
  in `docs/reference.md` and the per-CLI facts in `docs/cli-capabilities.md` are updated.
- A live headless smoke on the fleet host (Antigravity CLI 1.4.12, `claude-sonnet-4-6`) did NOT pass:
  `test/smoke/logs/agy-headless-20261104T081918Z.log`. The lane ran on agy, `harness pause --force` checkpointed it
  (`agent-paused`, handoff comment) and `harness resume` put the issue back, but the resumed lane then ran a single turn
  for about 15 minutes polling a `sleep 240` and used up the account's Claude-and-GPT model group weekly quota (the Gemini
  group's was already out: `agy -p /usage` reads 0 remaining for both). The lane parked as `limit` with agy's own reset
  time, as designed, and the run was stopped by hand (result `rc 130`). The account's quota lifts about 2026-11-11; the
  matrix's `headless-*` fixture rows are the proof until the smoke is re-run.
- Caveat: `--effort` is refused for `claude-sonnet-4-6` (`--effort is not supported for model`), so an operator who
  pins a Claude-group model in `HARNESS_AGY_FLAGS` drops the default `--effort high` there.

### A Windows lane's environment no longer carries a stray CR (#509)

- `session_env` strips the carriage return from each line of the `goal-env` output it reads. A native Windows python
  ends its lines with CRLF, so an empty `GOAL` used to give the lane an `-e HARNESS_\r` pair (the headless backend then
  failed with `env: 'HARNESS_\r': No such file or directory`) and a set goal gave values ending in a CR, such as
  `HARNESS_KIND=issue\r`. No env pair a lane gets carries a CR now.

### Install, update and rollback on Windows (#491)

- The `npx -y github:VocanicZ/Harness` line now works from Git Bash. The npx entry used to refuse native Windows;
  it now runs `install.sh` under Git for Windows' `bash.exe` by path (never npx's plain `bash`, which is WSL's) and
  still refuses, pointing at Git for Windows and WSL2, when no Git bash is found. Both install lines, `HARNESS_REF=<tag>`
  pinning and re-running the installer over an install are covered by `HARNESS_PLATFORM=windows` tests and a logged run
  on a real Windows host.
- `harness update` migrates a git-checkout engine on Windows. A directory cannot be renamed while a file in it is open,
  and the running `update.sh` is a file of that checkout, so the update now runs from a temp copy of itself first; the
  checkout (uncommitted edits and all) moves to `releases/git-<sha>` as on Linux. If something else still holds the
  engine open, the failure says to `harness stop` and leave the folder.
- After `harness update --rollback` onto a release that predates native Windows support (v0.1.1 and earlier), the
  rollback prints the one command that comes forward again (`MSYS=winsymlinks:nativestrict harness update --rollback`),
  because that release's own `update.sh` copies instead of linking.
- Fixed: the python3 shim could be written pointing at itself, so the first `harness update` of a home whose
  `HARNESS_HOME` is written `C:/x` (not `/c/x`) hung forever in the post-flip redeploy. The probe now recognises the shim
  by its own text, not its path.
- `harness doctor` checks the engine on Windows: a real link into `releases/`, no dangling link, no plain-folder copy,
  no leftover `engine.flip.*` or `.staging-*`, `harness` on PATH a link, each task's launcher running the engine through
  its link, and the rolled-back state (a newer release kept beside the engine) with the command that goes forward.
- New `test/test_windows_update.sh`: task re-install after the flip, prune keeps 3, git-checkout migration under
  Windows' open-file rule, rollback and forward again, idempotent re-install, the python3 shim, and the doctor states.

### Complete `harness uninstall` on Windows (#490)

- `harness uninstall --force --force-engine` leaves nothing Harness put on a Windows host. Besides the engine, the
  `harness` link and the skill links it now removes this `HARNESS_HOME`'s Task Scheduler tasks (every launcher under
  `$HARNESS_HOME/tasks`, by its per-home name, so another home's tasks are untouched) and the launchers, `harness.cmd`,
  the python3 shim, the running poller (by its pidfile) and its registry, the fleet registry, snapshots, event logs,
  the supervisor's state and log, and `HARNESS_HOME` itself when that leaves it empty. It removes only files carrying
  Harness's own text and names it owns: a user's file in the bin dir or in `HARNESS_HOME` survives. The same host
  cleanup now runs on Linux whenever uninstall removes the engine.
- On Windows `--force-engine` is refused while another fleet still uses the shared engine: nothing is removed, and
  the message says to stop that fleet. (A running worker holds its scripts open there.) Linux keeps `--force-engine`
  as an override.
- `harness doctor`'s `windows:` section checks the uninstalled state: with no engine under `HARNESS_HOME` it lists
  what is left (a task or launcher, the shim, `harness.cmd`, the poller, the fleet registry) and names the fix,
  `bash <a Harness checkout>/scripts/uninstall.sh --force --force-engine`.

### Per-`HARNESS_HOME`, logon-only Task Scheduler tasks on Windows (#489)

- The `supervise --install` and `web --install` tasks are named per `HARNESS_HOME`. The default `~/.harness` keeps
  `Harness\harness-supervise` and `Harness\harness-web`, so existing installs are unchanged. Any other home appends
  the first 8 hex digits of a hash of its path, e.g. `Harness\harness-supervise-1a2b3c4d`, so two homes on one
  machine (a test install beside a real one) get distinct tasks, and uninstalling one leaves the other's alone.
- The tasks are registered with a logon trigger only, never a boot trigger. They always use the interactive logon
  type, so installing no longer needs an administrator and no longer prints the "could not register to start at
  boot" warning. An existing install keeps its boot trigger until `harness supervise --install` /
  `harness web --install` (or `harness update`) re-registers it.

### Headless turn adapter for `openclaw` (#485)

- `openclaw` runs on the headless session backend: `scripts/cli/openclaw_headless.py` is its adapter on the shared
  core (#480), and `openclaw` stops being refused as tmux-only. Each turn is one
  `openclaw agent exec --json --message-file -` (the message on stdin) on the lane's own config, in the worktree, with
  the lane's `.harness-openclaw` as its state dir: the config and state a tmux lane's loop runs on. `agent exec` has no
  resume id (every turn is its own OpenClaw session), so the lane stays the Harness one: its id never changes, and each
  turn's envelope is appended to `.harness-openclaw/runs/<lane id>.jsonl`, the transcript the stats sweep reads. An
  envelope with `ok` true is `idle`; a failed one whose error is a quota or billing message (a provider's usage limit,
  OpenClaw's `The AI service needs a short break`) is `limit`, with the `Retry-After` it names; any other error, or an
  exit with no envelope, is `transient`.
- `agent exec --json` prints one pretty-printed JSON document when the turn ends, not a stream, so the core can now read
  stdout as whole documents: an adapter sets `json_documents = True` and each document is one event.
- `scripts/stats.py` read any headless lane whose `state.json` named the session as a claude lane, and folded its
  `events.jsonl` as claude's stream-json. It now does so only for a claude lane (`state.json`'s `adapter`); another
  CLI's usage comes from its own adapter. Nothing changes for `claude`, `opencode` or `hermes`, whose lane sessions are
  not the Harness lane id.
- `test/test_openclaw_headless.py` runs the adapter against captures of the real CLI
  (`test/fixtures/cli/openclaw/agent-json/`), and the matrix's `headless-*` rows now pass for `openclaw` from fixture
  replay on Linux. Under `HARNESS_PLATFORM=windows` on the Linux fleet host all of them pass but
  `headless-checkpoint`, `headless-resume` and `headless-stats-session-end-usage`, which fail the same way there for
  `claude` on `main`. The parity matrix and the per-CLI non-interactive table in `docs/reference.md` are updated.
- A live headless smoke on the fleet host (OpenClaw 2026.10.8 on its `claude-cli` provider, `claude-haiku-5-5`) passes:
  the sandbox issue was claimed, run by an `openclaw` headless lane and merged,
  `test/smoke/logs/openclaw-headless-20261104T081207Z.log` (`SMOKE_CHECKPOINT=0`).

### Headless turn adapter for `hermes` (#484)

- `hermes` runs on the headless session backend: `scripts/cli/hermes_headless.py` is its adapter on the shared
  core (#480), and `hermes` stops being refused as tmux-only. Each turn is one
  `hermes chat --format stream-json --yolo --accept-hooks -c <session> --create-if-missing --query-file -` (the
  message on stdin) in the lane's own Hermes profile, seeded exactly as a tmux lane's is. `-c` titles the lane's
  session on the first turn and finds it on every later one, so a lane is one Hermes session. A `result` with
  `exit_code` 0 is `idle`; an error that is a quota (usage limit, exhausted credits, a Nous account's rate limit)
  is `limit` with its reset time; any other error, or an exit with no `result`, is `transient`.
- Hermes runs a turn's commands in its host gateway, so killing a turn's process left its command running. The core
  gained an optional adapter `abort_turn(bin, cwd)`, called after a stop or an interrupt kills a turn; hermes stops
  the lane's gateway there and lifts the park that leaves on the profile (a parked profile's next turn fails after
  60 s). The core's optional adapter `env()` now receives the lane's worktree.
- `test/test_hermes_headless.py` runs the adapter against captures of the real CLI
  (`test/fixtures/cli/hermes/stream-json/`), and the matrix's `headless-*` rows now pass for `hermes` from fixture
  replay on Linux. Under `HARNESS_PLATFORM=windows` on the Linux fleet host all of them pass but
  `headless-checkpoint`, `headless-resume` and `headless-stats-session-end-usage`, which fail the same way there for
  `claude` and `opencode` on `main`. The parity matrix and the per-CLI non-interactive table in `docs/reference.md`
  are updated.
- A live headless smoke on the fleet host (Hermes 0.22.5 on the Copilot provider, `gpt-4.1`) passes: the sandbox
  issue was claimed, run by a `hermes` headless lane and merged, `test/smoke/logs/hermes-headless-20261104T065612Z.log`
  (`SMOKE_CHECKPOINT=0`). The checkpoint-and-resume run did not confirm on this host: the lane ran the checkpoint
  turn and pushed its branch, but the agent stopped before the handoff: the `caveman` skill it was told to load
  exists in both `~/.hermes/skills` and `~/.claude/skills` on this host, and `skill_view` refused the ambiguous name,
  so no `agent-paused` label followed. The matrix's `headless-checkpoint` and `headless-resume` rows cover the mechanics from fixtures.

### Headless turn adapter for `opencode` (#482)

- `opencode` runs on the headless session backend: `scripts/cli/opencode_headless.py` is its adapter on the shared
  core (#480). Each turn is one `opencode run --format json` (the message on stdin); OpenCode names its own
  session, so the first turn passes none and every later turn (or a relaunched lane's first) passes
  `--session <id>`, read off the stream. A quota error becomes the `limit` state with its reset time, any other
  error or a missing final step `transient`, a session OpenCode lost is started afresh. `cli_headless_list` now
  lists `opencode` and the tmux-only refusal no longer names it.
- `opencode` has no quota meter, so its `headless-usage-windows` row is `n/a` with that reason; a limit parks the
  lane from its error. Usage reaches the stats sweep through the same `opencode.db` fold a pane's session uses.
- The goal loop on an `opencode` headless lane is Harness's driven one (`opencode_loop`, `opencode_last_reply`);
  `claude`'s `last_reply` reader moved to `_cli_headless_last_reply` in `dispatch.sh`, shared by both. The core
  gained an optional adapter `env()` for variables a turn's process needs.
- `test/test_opencode_headless.py` runs the adapter against captures of the real CLI
  (`test/fixtures/cli/opencode/run-json/`), and the matrix's `headless-*` rows now pass for `opencode` from fixture
  replay, on Linux and under `HARNESS_PLATFORM=windows`. The parity matrix and the per-CLI non-interactive table in
  `docs/reference.md` are updated.
- A live headless smoke on the fleet host (OpenCode 1.19.5, the free `opencode/big-pickle` model, no account)
  passes, checkpoint and resume included: `test/smoke/logs/opencode-headless-20261104T051434Z.log`.

### Headless lanes for `copilot` (#483)

- `copilot` runs on the headless session backend: `scripts/cli/copilot_headless.py` is its adapter on the shared
  runner core (#480). Each turn is one `copilot --output-format json --session-id=<id>` with the message on stdin;
  copilot creates the session under that id when it is new and resumes it when it exists, so a lane is one copilot
  session across turns and relaunches. The turn's JSONL is folded into the lane's states: exit 0 is `idle` with the last
  `assistant.message` as the reply, a quota error (`You've hit your rate limit`, `You've reached your weekly rate
  limit`, `You've run out of your included AI credits`, …) is `limit`, any other failure `transient`. `cli_headless_list`
  now lists `copilot`, and the tmux-only refusal no longer names it on `HARNESS_SESSION_BACKEND=headless`.
- Usage and limits feed the same places as for a pane: the stats sweep's `session_end` takes the lane's tokens from
  copilot's `session-state/<id>/events.jsonl` (a headless lane whose events fold has no usage now falls back to the
  CLI adapter's own, and a resumed run reports only what it added), `cli_limit_usage` reads the account's quota windows
  from the same file, and the watchdog and supervisor read the lane's drawn screen with the shared headless pane
  patterns on that backend. The lane's last reply for the driven goal loop is its own `state.json`, as claude's.
  A headless copilot lane's drawn screen carries a turn timer (a pane's copilot draws none), so the stuck-turn interrupt
  can free a checkpoint queued behind a long turn — the live smoke's first run showed a 7-minute turn holding it.
- Fixtures captured on Linux from copilot 1.0.105 in `test/fixtures/cli/copilot/stream-json/` (a normal turn, a tool-use
  turn resumed by id; the limit and transient turns are built from
  the runtime's own strings, as the pane captures are) and a `fake-copilot` that replays them. All 14 `headless-*`
  rows pass for `copilot` in `test/test_cli_matrix.sh` from fixture replay, with no network and no `copilot` binary;
  `HARNESS_MATRIX_ROWS` / `HARNESS_MATRIX_HEADLESS_PLATFORM=windows` run the headless rows alone on the Windows code paths
  (a flock-backed msvcrt stands in for the real one), where 12 of the 14 pass for `copilot` and `claude` alike — checkpoint and
  resume wait for the winsma run; `test/test_copilot_headless.py` runs the adapter through the runner.
  `docs/reference.md` (parity matrices, adapter and headless sections) and `docs/cli-capabilities.md` are updated.
- Live: `SMOKE_BACKEND=headless bash test/smoke/fleet_smoke.sh copilot` on the fleet host (Copilot CLI 1.0.105, Free plan,
  Auto) closed a sandbox issue through a merged PR, with the lane checkpointed mid-task and resumed on its session:
  `test/smoke/logs/copilot-headless-20261104T054622Z.log`. The run on native Windows (winsma) is still #475 task 8.

### `harness attach` drives headless lanes (#487)

- `harness attach <lane>` on a headless lane keeps the live watch and adds input: each line you type goes to the
  lane's inbox through `cli_send` and runs as the next turn, queued behind a turn that is still running.
- Ctrl-C (or a TERM) detaches: the attach and its watch end, the lane keeps running with its state unchanged.
  Only the inbox / `cli_send` contract is used, so it keeps working on any runner that honours it.
- `test/test_headless_attach.sh` covers both against a fake headless lane, on Linux and on native Windows (winsma, in
  `C:\hx-487\`: `test/smoke/logs/headless-attach-windows-20261104T033325Z.log`); `docs/reference.md` documents the attach and flips its parity-matrix rows to `✓`.

### Headless turn adapter for `codex` (#481)

- `codex` now runs on the headless session backend: `scripts/cli/codex_headless.py` is its adapter on the shared
  core, one `codex exec --json` per turn and `codex exec resume <thread id>` after the first (codex names its
  own thread; the lane keeps the id the first turn reports). `cli_headless_list` includes it and `codex` is no
  longer refused as tmux-only. Limits (`You've hit your usage limit … try again at <date>`) park the lane with
  the parsed reset time, `Reconnecting… n/5` shows as a retry, and a thread codex lost is started afresh.
- The goal loop on a headless codex lane is the driven one (as claude's), and the usage windows and the stats
  sweep read the rollout `codex exec` writes, as they do for a pane. Headless lanes are drawn in claude's pane
  shapes whichever CLI they run, so on that backend the pane-reading `cli_*` regexes resolve to claude's.
- The `headless-*` rows of `test/test_cli_matrix.sh` now run for `codex` too, from fixture replay: captures of the
  real `codex exec --json` in `test/fixtures/cli/codex/stream-json/` (the account's own usage-limit reply, and a
  local stand-in endpoint for the rest) and a `fake-codex` replaying them. `test/test_codex_headless.py` shows
  the adapter contract's behaviours on codex's stream. `test/smoke/codex_headless_smoke.sh` runs the real
  binary behind the runner; its log is under `test/smoke/logs/`.
- Parity matrix: `cli codex` is ✓ on Windows (the headless runner), and the `headless-*` rows are ✓ for codex.

### Shared headless runner core, with `claude` as its first adapter (#480)

- `scripts/cli/claude_headless.py` is split into `scripts/cli/headless_core.py` (the inbox, `state.json`,
  the busy / idle / limit / transient / ended states, interrupt, stop, the pane the watchdog reads, `watch`)
  and a per-CLI adapter that starts one turn with its resume id, parses its stream and reports usage and
  limits. `claude_headless.py` stays the claude entry point and is now just that adapter; claude's lanes
  behave exactly as before and every existing headless test passes unchanged.
- `cli_headless_list` and the tmux-only refusal derive from the adapters present
  (`scripts/cli/<cli>_headless.py`): a new adapter enables its CLI on the headless backend without editing
  the refusal.
- The adapter contract is documented in `docs/reference.md` ("Headless adapter contract") and proved by
  `test/test_headless_core.py` through a tiny fake CLI and adapter, independent of claude.

### Windows installer: winget prerequisite offers, Developer Mode and git identity checks, per-repo git settings, doctor (#488)

- On Git Bash, `install.sh` offers each missing prerequisite through **winget**, one question per package:
  Git for Windows (`Git.Git`), Python 3 (`Python.Python.3.13`; the Microsoft Store `python3` stub counts as
  missing), the GitHub CLI (`GitHub.cli`), Claude Code (`Anthropic.ClaudeCode`) and Node for rtdd
  (`OpenJS.NodeJS.LTS`). `HARNESS_INSTALL_PREREQS=1` accepts without asking, `0` declines and prints the
  commands, and `HARNESS_WINGET` names the winget binary (the tests point it at a stub; no test runs a real
  `winget install`). Linux is unchanged.
- `install.sh` checks Developer Mode (off in the registry is only a stop when the shell cannot make a
  symlink either, as an administrator can) and the git identity, and prints the exact fix for each.
- Harness sets `core.longpaths=true`, `core.autocrlf=false` and `core.eol=lf` on its checkout and on every
  lane worktree it adds, with `git -C <repo> config` (never `--global` or `--system`), on Windows only.
- `harness doctor` on Windows adds `gh`, an agent CLI, rtdd/Node, Developer Mode, the git identity and the
  per-repo settings, each failure naming its fix (`harness doctor --fix` writes the per-repo settings).
- Fixed: `install.sh` could not extract a release when `TMPDIR` was a mixed-form Windows path (`C:/…`):
  GNU tar read `C:` as a remote host. The archive is now read from stdin.
- Fixed: on Windows `detach_launch` left every exported variable, `GH_TOKEN` included, in
  `.harness/run/<name>.pid.env` for as long as the fleet ran. The launcher now deletes that file as soon as it
  has restored the environment, and a failed launch removes it too (#510).
- The winsma isolation (`test/smoke/winsma/`) also sets `GIT_CONFIG_GLOBAL` under `C:\hx-<issue>\`: a fleet's
  `ensure_safe` writes `safe.directory` entries to the global git config, which the guard rightly flagged.
- A recorded winsma run (`test/smoke/logs/windows-installer-windows-20261104T041438Z.log`): `install.sh` with a
  stubbed winget, `harness init`, `harness start` claiming an issue, per-repo git settings on the lane's
  worktree, `harness doctor` green, the guard and the credential scan clean, winsma clean after.
- README, `docs/windows-smoke.md` and the `docs/reference.md` parity matrix describe the installer; WSL2 stays
  documented as an optional alternative.

### `HARNESS_WINDOWS_HOST` and the winsma helpers in `test/smoke/winsma/` (#479)

- New config key `HARNESS_WINDOWS_HOST`: the ssh alias of a Windows check host. Read like every other key
  (`.harness/config` or the environment), empty by default, documented in `docs/reference.md`. Empty means no
  Windows host, and the helpers refuse to run.
- `test/smoke/winsma/winsma.sh` and its helpers let a lane check Harness on a shared Windows desktop without leaving a
  trace: the `C:\hx-lock` lock (atomic `mkdir`, owner, a detached 5-minute heartbeat loop; a live holder is waited
  for, a stale one broken only when its heartbeat is over 30 minutes old **and** its lane is gone), the
  `C:\hx-<issue>\` isolation (base, install and full-suite environments, a python venv, logon-only per-run tasks),
  the before/after guard (machine-file checksums, the `Harness\*` task list, `~/.claude.json` outside the run's
  folder), the `GH_TOKEN`-on-stdin credential rules with an end-of-run leak scan, and cleanup that never names
  `C:\hx-smoke\`. `test/test_winsma.sh` covers them on Linux with a fake ssh and fake Windows paths.
- `docs/windows-smoke.md` documents the helpers and the winsma rules; a recorded run is committed under
  `test/smoke/logs/`.

### Windows parity matrix in `docs/reference.md`, with per-CLI non-interactive mode research (#478)

- `docs/reference.md` gains a "Windows parity matrix": one row for every `harness` subcommand, every
  `/harness*` skill, every agent CLI (claude, agy, codex, copilot, opencode, hermes, openclaw) and the
  lifecycle features (rtdd, supervise, web, inject, pause/resume, install, update, rollback, uninstall,
  swarm). Each row has a Linux and a Windows value: `✓`, `✓ target (#475 task N)` for a feature planned but
  not yet shown working on Windows, or `n/a` with a source link. The only `n/a` today is swarm submission,
  a Linux-only HTCondor service.
- A second table records, for each agent CLI, the exact non-interactive command, its output format, how it
  resumes a session, how it reports usage and rate limits, and the vendor's Windows install page. Every
  supported CLI ships a Windows build and a non-interactive mode, so none is `n/a` on Windows. The per-CLI
  headless runners of PRD #475 build on it.
- `test/test_windows_parity_doc.sh` fails when a row has no Linux or Windows value, an `n/a` has no source,
  a Windows `n/a` sits on a feature Windows can do, a subcommand, skill or CLI has no row, or a CLI has no
  sourced research row. Fixture cases (the real doc with one defect each) prove each failure.

### `init`, `/harness-plan`, skills and docs describe a one-repo fleet with one issue per worker (#474)

- `harness init` writes `HARNESS_REPO`, `HARNESS_UNIT` (the lowercased repo short name, so `Acme/Widget`
  gives `widget`; a `HARNESS_UNIT` you set wins) and `HARNESS_POOL`. It writes no `HARNESS_TOPOLOGY`,
  `HARNESS_CAP` or `targets.tsv`.
- `/harness-plan`, `prompts/inject.md` and `prompts/decompose.md` no longer edit or read `targets.tsv` or talk
  about topology: `/harness-plan` changes `PLAN.md` and cascades it into the PRD and delta issues.
  `/harness-prd`, `/harness-issue` and `/harness-one` lose their `--unit` text.
- The `/harness*` skills, `README.md`, `CONTRIBUTING.md` and `docs/reference.md` say what `HARNESS_POOL` means
  (the number of parallel issues), and `docs/reference.md` retires separate submodule fleets: a submodule with
  its own fleet folder is no longer supported; its issues go in the main repo with a `## Code location`
  section (#471).

### Delete the multi-topology code paths: `targets.tsv`, `HARNESS_TOPOLOGY`, unit deps, `HARNESS_MAIN_REPO` (#473)

- With one fleet = one repo (#464), the engine no longer has a second mode. `unit_deps`, `deps_complete`,
  `_tgt_field` / `_tgt_row`, `ensure_checkout`, the old whole-unit worker loop and every `HARNESS_TOPOLOGY`
  branch are gone from `lib.sh`, `drive.sh`, `pool-worker.sh`, `init.sh`, `seed.sh`, `setup.sh`,
  `forecast.py` and `stats.py`. `harness init` no longer asks for a topology and always asks for the repo.
- A config with no `HARNESS_UNIT` now just takes the defaults: unit `main`, checkout `$PROJECT_ROOT`. A stray
  `HARNESS_TOPOLOGY` line or `targets.tsv` beside it is ignored, not read. The migration (#467) has already
  written `HARNESS_UNIT` / `HARNESS_CHECKOUT` for every registered fleet.
- `HARNESS_MAIN_REPO` and the umbrella-repo code path that read it are removed.
- `scripts/fleet-migrate.sh` and `fleet_migrate.py` are the only code that still reads `targets.tsv` /
  `HARNESS_TOPOLOGY`, so a not-yet-migrated fleet is still converted by `harness start` / `harness update`.
- `docs/reference.md` updated. Tests that fed a multi-unit registry through `targets.tsv` now use a
  test-only fixture registry in `test/helpers.sh`; `test_registry.sh` and `test_one_repo.sh` pin the one-repo
  behaviour and that a leftover `targets.tsv` / topology key is not read.

### Status, web dashboard and stats show workers and their issues instead of units (#472)

- `harness status` prints one row per worker: `worker-N → #<issue> <session> <state>` for a worker running a
  lane, or `idle`. The "units: x/y complete" line, the "driving unit" line and the unit frontier are gone;
  the priority bug lane keeps its own row.
- The web fleet page (`/fleet/<prefix>`) has a Workers section with the same rows, and `/api/fleet/<prefix>`
  carries a `workers` list. A claim whose worker pid is gone is not shown as the worker's assignment.
- `harness stats` adds `lanes` to each fleet: lane claims per repo with the workers behind them. The new
  `lane_claim` events (`repo`, `worker`) and the older `claim` events (`unit`) both count; old events keep
  their totals, and one with no `repo` is attributed by its `unit`.
- `docs/reference.md` updated; new `test_web_workers.py`, plus cases in `test_status.sh` and `test_stats.py`.

### Remove CAP: `POOL` is the number of parallel issues; the migration drops the kept `HARNESS_CAP` line (#469)

- With one lane per worker (#468) the per-unit `CAP` had no meaning left, so `HARNESS_CAP` is gone from
  `drive.sh`, `pool.sh`, `pool-worker.sh`, `start.sh`, `inject.sh`, `status.sh`, `init.sh` and `lib.sh`.
  `HARNESS_POOL` (default `3`) is the only parallelism knob; `harness init` no longer asks for sessions
  per unit and `harness status` no longer prints `cap=`. The gauntlet and security-audit round caps in
  `prompts/review.md` are a different thing and are unchanged.
- `scripts/fleet-migrate.sh` now drops the `HARNESS_CAP=<old CAP>` line it used to keep. `HARNESS_POOL` was
  already `max(old POOL, old CAP)`, so no fleet loses parallelism. A config #467 already migrated that still
  carries the line loses just that line (backed up as `config.bak-<date>`, workers not restarted). Running
  it twice changes nothing.
- A `HARNESS_CAP` still set in the environment or the config is ignored, with one warning per
  `harness start`: "CAP is gone; POOL is the number of parallel issues".
- `docs/reference.md`: `CAP` removed from the config table, the `POOL` meaning updated; new
  `test_cap_removed.sh`, and `test_fleet_migrate.sh` covers the dropped line, idempotence and the warning.

### Submodule issues end to end: `## Code location`, lane prompt rules, resume across submodules (#471)

- An issue for code inside a submodule is filed in the main repo. `decompose.md`, `bug-triage.md` and the
  inject prompt now tell their writer to add a `## Code location` section with the submodule path (for
  example `ORGE-ENGINE/src/...`); lanes never claim issues from a submodule's own repo.
- `impl.md`, `bug-fix.md` and `resume.md` share a new `prompts/_submodule.md` (and `_rtdd.md` points at
  it): work in the submodule on `issue/<unit>-<n>` and run `rtdd which` there too, merge into the
  submodule's base branch first, point the gitlink at the merged commit on `origin/<base>`, then commit
  and merge the bump in the main repo. The prompts now take a `UNIT` key.
- Resume detection checks the issue branch in the main repo and in every submodule
  (`submodule_branch_pushed`), so a lane that died after pushing only `issue/<unit>-<n>` in a submodule is
  resumed, not restarted. This covers `prepare_impl` and the bug fix lane.
- `test_submodule.sh` covers the submodule-first merge then bump, the submodule-only resume, and the
  prompt text; `docs/reference.md` Submodules section extended.

### Step-based pool worker: one worker claims one lane, capped by `POOL` fleet-wide (#468)

- A pool worker used to claim the whole unit and drive it, so `POOL=3` with three ready issues ran three
  sessions inside one worker while the other two sat idle. A worker now claims **one lane** (one issue, one
  bug, or one PRD action), runs it, reaps it, releases it and claims the next. `HARNESS_POOL` is the most
  lanes that run at once; the new loop no longer reads `HARNESS_CAP`.
- The worker is step-based (`worker_step` per tick) and never blocks inside a lane: it runs the preamble,
  the fleet-wide chores (one winner per tick under `run/chores.lock`: reapers and watchdog for ownerless
  lanes, adoption, `LABEL_READY` / `CLOSE_PRD`, `PLAN.md` archival on completion), tends the lanes it
  owns, and only then claims. Chores keep running while every worker is busy, and a pause stops claims
  without stopping the tending of running lanes (driven goal loops included).
- No double claims: a claim is written under `pool.lock` after dispatch is told the PRDs and issues held by
  live sessions, worktrees and live claims; `PLAN` / `PRD` are offered only with no lane live. A bug a pool
  worker takes is claimed as `pool-<worker-id>`, and `dispatch` no longer offers a bug a claim holds.
- Lanes are adopted from their sessions, not from claim files, so a killed worker's lane, a lane left by a
  worker roll (#467) and the lanes live across `harness start --recover` are picked up, tended and reaped
  once.
- Fix: `pool_bug_claims` read the claim's token as the rest of the line, which would have broken once a
  claim carries the session and pane pid after it.
- `test_pool_lanes.sh` covers all of it (one-repo fixture fleet, real `dispatch` over a snapshot);
  `docs/reference.md` has a new [pool worker section](docs/reference.md#the-pool-worker-step-loop). A
  config still on `targets.tsv` runs the old unit loop until `harness start` migrates it (#467).

### Submodule lane plumbing: init in every worktree, base-branch resolver, gitlink merge guard (#470)

- A lane worktree made by `git worktree add` had every submodule as an empty directory unless the
  project's `HARNESS_WORKTREE_HOOK` initialised them. `run_worktree_hook` now runs
  `git submodule update --init --recursive` first, so the hook and the lane see each submodule checked
  out at the gitlink. A repo without a `.gitmodules` is unaffected, and ORGE's existing hook stays
  compatible.
- `submodule_base_branch` (`scripts/submodule.sh`) resolves a submodule's base branch: `.gitmodules`
  `branch =` when set, otherwise the remote branch that contains the main repo's current gitlink
  (the default branch when several do), so a fleet on `rebuild` with no `branch =` resolves to `rebuild`.
- `scripts/gitlink-guard.sh` refuses a main-repo merge whose changed gitlink is not reachable from the
  submodule's `origin/<base>` or does not descend from the current gitlink. A lane in a repo with
  submodules gets a `gh` first on its `PATH` (`scripts/lane-bin/gh`) that runs it before `gh pr merge`, so
  it cannot be skipped; a repo without submodules sees no change.
- `test_submodule.sh` covers all three on a real fixture repo with a submodule; `docs/reference.md` has a
  new Submodules section.

### `harness supervise` installs a published release and rolls every fleet's workers onto it (#477)

- A release the fleet published never reached the fleets: nothing on the host installed it, and
  `harness update` flips `~/.harness/engine` but every running worker keeps the release directory it
  started on (on 2026-11-03 every worker on all 7 fleets was still on `releases/v0.2.0` after v0.4.0
  through v0.4.4 had been installed). It took an operator running `harness update` and then a rolling
  restart by hand.
- Each `harness supervise` pass now checks the latest release at most once per
  `HARNESS_AUTO_UPDATE_EVERY` (600 s) and, when it is newer, runs `harness update` and rolls the
  workers of every registered fleet. Off with `HARNESS_AUTO_UPDATE=0`; never on a `HARNESS_REF` pin, a
  git-checkout engine or a dev clone's supervisor; never a downgrade, a re-install, or an unparseable tag.
- The roll (`fleet_roll`, new `scripts/roll.sh`, the one implementation `harness update` of #467 shares)
  kills only the worker and priority processes not already on the new release, each under the fleet's
  `pool.lock`, never one holding a `bug-*.claim` (rolled on a later pass) and never a lane session, then
  runs `harness start` (no `--recover`). A paused fleet is rolled and stays paused (`start.sh` honours
  `HARNESS_START_KEEP_PAUSE`).
- `HARNESS_AUTO_UPDATE_HEALTH_S` (120 s) after the roll, a dead worker or priority pid runs
  `harness update --rollback`, rolls the workers back, records the tag in `supervise/auto-update.skip`
  and files one `bug` on `VocanicZ/Harness`. The update's phase is kept in `supervise/auto-update.json`,
  so the supervisor the update restarts resumes the roll and the health check.
- Events `engine_updated`, `workers_rolled` and `engine_rolled_back`; every action in `supervise.log`;
  `--dry-run` only logs.
- test_supervise_autoupdate.sh: install and roll of two fleets on a file:// release fixture with lane
  sessions left alone, bug-claim deferral, a paused fleet, a stopped fleet, every opt-out, the throttle,
  offline, `--dry-run`, rollback with exactly one bug and no retry (a newer tag still installs), and a
  supervisor killed by the update's own restart (fails without the change).

### `scripts/fleet-migrate.sh`: `harness update` migrates every registered fleet to one repo and rolls its workers (#467)

- Second step of one fleet = one repo (#464). `harness update` runs the new `scripts/fleet-migrate.sh`
  for **every fleet registered in `$HARNESS_HOME/fleets/*.json`**, not only the current folder's, and
  `harness start` runs it for its own fleet before it reads the config. No operator step; session
  names, unit names and parallelism are kept.
- Per fleet that still needs it: back up the config as `config.bak-<date>`; write `HARNESS_REPO`
  (the target's repo wins, so ImPrint becomes Imprinted), `HARNESS_UNIT` and `HARNESS_CHECKOUT` (the
  clone that exists under `.harness/checkouts/`; `single`: `main` and the project root), move the other
  `targets.tsv` rows to `targets.tsv.migrated` with a `fleet_migrated` event (harness-dev keeps `harness`
  and drops `rtdd`), remove `HARNESS_TOPOLOGY`, set `HARNESS_POOL` to `max(POOL, CAP)` and keep
  `HARNESS_CAP` (dropped since #469); then kill only that fleet's `run/worker-*.pid` and `run/priority.pid` processes (never
  `harness stop`) and relaunch the workers through `fleet_roll` (`scripts/roll.sh`, #477), which runs
  `harness start --state-dir <fleet>`. Live lanes keep running.
- Both config line forms (`: "${KEY:=val}"` and plain `KEY=val`) are read and written in place, comments
  kept. Running it twice changes nothing. A paused fleet is migrated and comes back paused; a fleet
  with no worker pid files was stopped on purpose and is migrated, not started.
- The config migration and the worker roll ship together: a migrated config under old workers would
  leave them reading a missing `targets.tsv` and idling as "all complete".
- test_fleet_migrate.sh: fixtures of all seven host configs give the expected unit, repo, pool and an
  existing checkout, a second run changes nothing, and a fixture update with two registered fleets and
  live old-loop workers kills only their pids and relaunches them (fails without the change).

### `HARNESS_UNIT` and `HARNESS_CHECKOUT`: every reader takes the fleet's one repo from config (#466)

- First step of one fleet = one repo (#464). Two new config keys: `HARNESS_UNIT`, the unit's name in
  session and worktree names (`<prefix>-<HARNESS_UNIT>-i<N>`, default `main`), and `HARNESS_CHECKOUT`,
  where the repo clone lives (default `$PROJECT_ROOT`). `HARNESS_REPO` is unchanged.
- `unit_repo`, `unit_slug`, `unit_checkout`, `unit_desc`, `all_units`, `bug_checkout` and `_bug_repos`
  in `scripts/lib.sh`, `stats.py`'s `_unit_repo` and `forecast.py` all read those keys, so a config with
  `HARNESS_REPO`, `HARNESS_UNIT` and `HARNESS_CHECKOUT` and no `targets.tsv` resolves everywhere. A
  single fleet with neither key behaves exactly as before (`hzbw-main-i<N>`, `$PROJECT_ROOT`).
- `forecast.py` read only `: "${KEY:=val}"` config lines, so a plain `KEY=val` config (bangwa's) gave it
  no project; it now parses both forms.
- `--unit` on `harness inject` and `harness one` is optional and defaults to `HARNESS_UNIT`.
- Transitional: a config with no `HARNESS_UNIT` that is `multi` still resolves through `targets.tsv`, so
  this can ship before the migration; the dead-code step of #464 removes that fallback.
- test_one_repo.sh: every reader on a config with no `targets.tsv`, the defaults, an un-migrated `multi`
  config, `inject` / `one` without `--unit`, and `forecast.py` / `stats.py` on both config forms (fails
  without the change).

### The web dashboard flags a `model_mismatch` on PLAN/PRD and injector sessions (#462)

- The dashboard rolls up only sessions that carry an `issue` or a `prd`, so a `model_mismatch` on a
  Manager session with neither (the PLAN or PRD session, an injector) showed in `harness status` and
  `harness stats` but nowhere on the web dashboard.
- The fleet page's header now carries a banner listing each such session, its kind, and the intended and
  actual model, over the same 7-day window as `harness status`. A mismatch on an issue's session still
  flags that issue's node and its PRD, and no banner shows without one.
- test_web_awaiting.py: a fixture with a `model_mismatch` on a PLAN session and on an injector session is
  flagged on the page, while an older one, another fleet's, and an issue's own are not (fails without the fix).

### `model_mismatch` decides on the lane's own transcript, not its sub-agents (#461)

- The check (#376) took the dominant-by-output model of the session's merged usage, which folds in
  every `subagents/*.jsonl`. A lane on the intended model that mostly orchestrated while sub-agents on
  another family (an explicit `model: opus`, a built-in agent on another model) wrote most of the
  output was flagged as a launch-routing failure that never happened.
- `session_end` now records `main_model`, the dominant model of the session's own `<id>.jsonl`, and
  `model_mismatch` compares that with the launched model. The merged `usage` is unchanged, so token
  and cost totals still count the sub-agents. A `session_end` without `main_model` (logged earlier, or a
  lane with no transcript) falls back to the dominant model of its merged usage.
- test_stats.py: a sonnet main transcript plus an opus sub-agent that out-writes it gives no
  `model_mismatch`; an opus main transcript on a sonnet launch still gives one (fails without the fix).

### `harness one phase` no longer checkpoints when a live codex/copilot window resets mid-issue (#459)

- Since #457 a live window that reset partway through an issue was put back from the start snapshot
  at 0% as "gone since its window reset" and, with no Claude config dir to count the spend since,
  CHECKPOINTed — although the query had answered. The codex and copilot adapters leave a window out
  once its `resets_at` has passed, so every 5h reset forced a `/harness-one` session to checkpoint.
- `live_readings` marks a reset window `answered` when its account's live query still answers; `_stale`
  exempts it, so it is 0% plus the stale pad as before #457. A query that failed or came back empty
  (nothing answered for the account) still CHECKPOINTs, and a window that did not reset is still frozen.
- test_one_run.sh: codex 5h read at 91% at start, reset mid-issue while the query answers only 7d →
  FITS; the query going dark → CHECKPOINT (the FITS case fails without the fix); test_one.py covers
  `_stale` and `phase_check` for the answered, empty, claude and other-account cases.

### `harness one phase` stops on a live source's reading put back from the start snapshot (#457)

- Since #451 a live query's reading (`HARNESS_USAGE_CMD`, codex, copilot, hermes, agy, openclaw) was
  padded, never `usage stale` — even when the query had stopped answering and `live_readings` had put
  the start snapshot's reading back. That value is frozen: a source that went dark mid-issue (auth
  expiry, an outage, a cached fetch that failed) left every phase FITS on the start % whatever the
  session spent, so the stop % was never reached.
- `_stale` exempts only a live reading that was not put back. A `restored` one is "gone since this
  session started" / "gone since its window reset" and CHECKPOINTs unless its spend since can be
  counted. A live query that answers still pads and FITS at 10% (#451).
- test_one_run.sh: start on a live `HARNESS_USAGE_CMD` codex 10%, then the query fails (`exit 1`) or
  prints nothing → CHECKPOINT (fails without the fix); test_one.py covers `_stale` and `phase_check`
  for a `live` + `restored` reading.

### `harness one phase` checks the session's own account when no reading holds it (#452)

- After #445 each reading counted the session's transcript spend, but a window of the session's own
  Claude account that no reading held was never checked. On a multi-account host the readings may
  cover only `sub` while the `/harness-one` session runs on `main`: `phase` checked `sub` (zero spend)
  and said FITS with nothing unchecked. And a 5h window that reset before `harness one start` (a fleet
  paused overnight) is dropped by `claude_limit_usage`, so neither the readings nor start's snapshot
  held it — only `seven_day` was checked, and the session could hit the 5h limit mid-phase.
- `harness one phase` passes the session's account (`--session`, the basename of `CLAUDE_CONFIG_DIR`,
  `default` for none — the status line's name for it). Each of its `five_hour` / `seven_day` windows
  no reading holds is checked from 0% at `start` plus the account's spend since: a lower bound, sound
  while the fleet is paused or held. With no snapshot, no config dir for the account or no $ per 1%,
  the window is listed under `unchecked` with a WARNING — never left out silently.
- test_one_run.sh: only account `sub` read, the session on `main` spends 96% → CHECKPOINT; a 5h
  window reset before `start` reaches CHECKPOINT on the spend since (both fail without the fix).
  test_one.py: `session_readings` / `phase_check(session=…)`, the warnings, and the `--session` CLI.

### test_one_run.sh's reset-window case no longer races the wall clock (#454)

- The #445 reset-window block dropped a reading whose `resets_at` was 2s ahead, ran
  `harness one start`, then `sleep 3`. On a loaded node start could take longer than the 2s, so the
  window had already reset when start took its snapshot; the snapshot held no reading, `phase` had
  nothing to check, FITS, and three asserts failed at random.
- The lead now doubles (2s up to 128s) until start's snapshot holds the window — asserted — and the
  test waits until the reset has passed instead of a fixed sleep, so the spend is logged after it.
  Under a 3s-slow `git worktree add` the old block fails all three asserts and the new one passes;
  50/50 runs pinned to one CPU, ten at a time. No assertion is weakened.

### `harness one phase` works on codex, copilot and `HARNESS_USAGE_CMD` usage (#451)

- Since #445 a reading of unknown age whose spend could not be counted was a CHECKPOINT once
  `harness one start` had taken its snapshot. Only the claude adapter's status-line drops give a
  reading an age, and spend is counted only for a Claude config dir, so on a fleet whose usage came
  from codex, copilot or an operator's `HARNESS_USAGE_CMD`, every `harness one phase` CHECKPOINTed
  before the first phase ("usage stale — the reading is of unknown age").
- `one_readings` now marks a live query's readings `live` (a sixth column): `HARNESS_USAGE_CMD`, or
  any adapter but claude's. `one.py` pads those as before #445 (`HARNESS_ONE_STALE_PAD_PCT`), so they
  FIT under the stop % and CHECKPOINT over it on the arithmetic. A claude reading frozen since the
  fleet paused still CHECKPOINTs when its spend since cannot be counted.
- test_one_run.sh: `harness one start` then `phase` with a codex reading from `HARNESS_USAGE_CMD`
  and from the codex adapter, no claude drop — FITS at 10%, CHECKPOINT at 92% / 93% (fails without
  the fix). test_one.py: a `live` reading of unknown age is padded, put back padded, and the same
  reading without the mark still fails closed; `parse_readings` reads the mark.
### Lanes test with rtdd Rounds 1+2 only; the full suite runs once, at PRD review (#449)

- The impl, bug-fix and resume prompts ran the full suite up to three times per issue — a `baseline`
  before the first edit, a `final` at the end (`THE FULL-SUITE BAR` + `ON SWARM`, #204), rtdd's
  `Round 3` (#218) and step 6b's "the full suite IS the gate" (#246) — 15–22 min each on swarm, about
  17h of 37.5h across the last 30 impl lanes. The rule #172 set is back: lanes never run it.
- `prompts/_rtdd.md`: no Round 3 and no `→ FULL-SUITE BAR`. When rtdd is missing, older than v0.3,
  erroring, or both rounds are empty, the lane runs the closest test files by hand, notes it in an
  issue comment and files one rtdd bug if rtdd misbehaved — never the full suite. A failing test is
  still re-run on `origin/<default-branch>` first; red there too is pre-existing.
- `impl.md` / `bug-fix.md` / `resume.md`: the baseline/final suite runs (and resume's `hz-baseline`
  worktree) are gone. Without a repo CI entrypoint (`scripts/ci-local.sh`, still the gate when
  present) the step-6b gate is rtdd Rounds 1+2 re-selected on the rebased HEAD plus the lane's own
  new tests.
- `prompts/review.md` keeps its `{{SWARM_SUITE}} … -prd<N>-review` run and says it is the only
  full-suite run in the pipeline. `docs/reference.md`, `README.md` and `CONTRIBUTING.md` describe the
  new rule. `test/test_prompt_no_full_suite.sh` pins it on every lane prompt, raw and as `drive.sh`
  renders it; `test_swarm.sh`, `test_rtdd.sh`, `test_ci_gate.sh` and `test_readme_docs.sh` follow.

### `harness one done` and HARNESS_ONE_AUTO skip an issue a live lane still owns (#446)

- `issuelib next` skipped only `--exclude`, while dispatch also skips the issues a live lane still owns
  (`busy_issues_for`, #416). A checkpointed lane keeps its worktree after it drops `agent-working`, and
  `next` puts `agent-paused` issues first, so under a hold it often offered that very issue:
  `harness one start` then failed ("worktree add failed … claim released"), and `one_auto_tick` picked
  it every poll, failed to spawn it and never moved on.
- `harness one done` and `one_auto_tick` now pass `busy_issues_for` through `issuelib next --exclude`:
  they offer / start the next claimable issue nobody owns, or none. test_one_run.sh, test_one_auto.sh.

### `harness one phase` sees the interactive session's own spend (#445)

- On the claude adapter the per-phase re-check read only status-line drops and this fleet's headless
  lanes. The interactive `/harness-one` session runs no Harness status line, and a paused or held fleet
  renders none, so `now%` stayed frozen while the forecast left shrank: the checked value fell phase by
  phase and the stop % was never reached mid-issue. A reading past its `resets_at` was dropped, leaving
  the window unchecked.
- `harness one phase` now adds what the reading's account spent since the reading was taken — its
  Claude transcripts (main and sub-agents, each message once), priced at list price, over the window's
  $ per 1% (the #364 bound, else `HARNESS_ONE_USD_PER_PCT`). `harness one start` keeps the readings it
  saw (`run/one/<unit>-i<n>.start`, removed by `release` and the reaper), so a window that reset since
  is checked from 0% at the reset plus the spend since, and one gone without a reset as it was read.
- It fails closed: a reading that is not current (from before `start`, stale, of unknown age, or gone
  since `start`) whose spend cannot be counted is a CHECKPOINT (`usage stale`), never a silent FITS.
- `test/test_one_run.sh`: with no usage stub, a frozen status-line drop and the session's spend written
  as Claude Code transcripts, `phase` goes FITS → FITS → CHECKPOINT without the drop being touched; a
  window reset since `start` is checked from 0%; both CHECKPOINT when the spend is uncountable.
  `test/test_one.py`: the spend arithmetic, the restored windows, the fail-closed cases, and
  `account_spend_since` on a fixture config dir.

### `test_hermetic.sh`'s update.sh scan no longer misses tests at random (#441)

- `runs_update` piped `grep -v` into `grep -q` under `set -o pipefail`. `grep -q` quits at its first
  match; when `grep -v` still had a write pending (non-comment text over one pipe write), that write
  took SIGPIPE, `grep -v` exited 141, and the scan read false. On one CPU it missed
  `test_web_install.sh` (8/300) and `test_supervise.sh` (5/300): the suite went red at random
  (`FAIL: the update.sh scan finds test_web_install.sh`), and a missed test outside the must-find list
  silently ran without its decoy home and curl tripwire (#434).
- The reader now drains its input (`grep -E … >/dev/null`), so the pipeline's status is the match.
  Both files are found 300/300 under `taskset -c 0`.
- `test/test_hermetic.sh`: a fixture whose match sits in the first 4 KiB of >8 KiB of non-comment text
  is found 300/300 (pinned to one CPU where `taskset` exists), and the scan has no `| grep -q`.

### The README names `git` for the `npx` install line (#440)

- The README said `node` ≥ 18 was the only prerequisite for `npx -y github:VocanicZ/Harness`, and that
  the installer offers `git`. But npm fetches a `github:` package by running `git`, so on a host
  without it (a fresh Ubuntu/Debian with node from apt) `npx` failed with an npm error
  (`spawn git`, "An unknown git error occurred") before `install.sh` ran, and nothing offered `git`.
- The README's prerequisite table now lists `git` for the `npx` line, the agent note sends a host
  without `git` to the `curl` line (which offers to install it), and `/harness <idea>` step 1 says the
  same.
- `test/test_install_npx.sh`: on a PATH with `node` and `npm` but no `git` (throwaway HOME and npm
  cache, offline), npm cannot fetch `github:VocanicZ/Harness` and fails spawning `git`; the README
  names `git` for the `npx` line, and the agent note and skill send a git-less host to `curl`.

### The `/harness` skills reach every installed CLI, Hermes included, as links (#439)

- A host with Hermes got no `/harness*` skills in Hermes: `install.sh` copied them into
  `~/.claude/skills` and the agy, codex and copilot dirs only, and the operator's Hermes reads
  `~/.hermes/skills`. Every adapter now names the dir its CLI reads user skills from
  (`cli_user_skills_dir`; hermes: `~/.hermes/skills`, openclaw: `~/.agents/skills`), and every
  supported CLI installed on the host (binary on PATH, or its config dir present) gets every engine
  skill there.
- Each skill is a symlink to the one copy in the engine, named through `~/.harness/engine/skill/`, so
  an update refreshes every CLI at once; `harness/` is a dir holding a `SKILL.md` link. Hermes follows
  them (`test/fixtures/cli/hermes/skills-symlink.txt`: listed and loaded by the real Hermes).
- Every `harness update` — no flags, already current included, run from the new release after a
  flip — and `harness setup` / `harness start` re-link: a missing, dangling or old-release link, or an
  old Harness copy, is relinked. A same-named skill of the operator's own is kept, and the update
  names it. `harness uninstall` removes only Harness's links, dangling ones too (it now reads the CLIs'
  dirs before it removes the engine).
- `test/test_operator_skills.sh`: a fake HOME with every CLI on PATH and an old install (copies in
  `~/.claude/skills` only) gets links in every CLI's dir from a plain `harness update`; an operator's
  own `~/.hermes/skills/harness` is untouched; a removed link comes back; setup/start heal; uninstall.
  Matrix row `operator-skills`. `test/test_hermetic.sh`: no update test links into the inherited HOME.

### The update tests no longer touch the host's real engine (#434)

- `test/test_update.sh` and `test/test_web_install.sh` set no `HARNESS_HOME`, so `update.sh` read the
  host's real `~/.harness/engine`. Every host installed since releases (#279) has a release symlink
  there, so both tests failed on such a host and queried the real GitHub releases API. With a newer
  release published, `test_web_install.sh` would have installed it over the live engine. Both tests
  now set a throwaway `HOME` and `HARNESS_HOME` and a local releases URL, and pass with or without a
  `~/.harness`.
- `test/test_hermetic.sh` finds every suite test that runs `update.sh` or `harness update`. It runs
  each one against a decoy home whose engine is a release symlink, with a curl tripwire on PATH.
  Each test must pass, leave the decoy's `.harness` unchanged, and never reach github.com.

### The `/harness-*` skills run `harness` off PATH (#433)

- `/harness-prd` (where `/harness <idea>` goes on a live fleet) and the other per-command skills
  (`/harness-init`, `-issue`, `-one`, `-pause`, `-plan`, `-resume`, `-start`, `-status`, `-stop`,
  `-uninstall`) still ran `.harness/bin/harness`, which nothing creates any more, so the agent ran a
  missing path and the idea never reached the fleet. They now run `harness <cmd>`, the command
  `install.sh` puts on PATH, with the same arguments (#343 had fixed only `/harness`).

### `/harness <idea>` files its PRD on a fresh repo (#432)

- A non-interactive `harness init` (the agent's shell, which has no terminal) wrote the config and
  seeded no labels, so `/harness <idea>` step 3's `gh issue create --label prd` failed
  `could not add label: 'prd' not found`. Non-interactive init now seeds the harness labels on a
  single-topology repo when `gh` is signed in (labels only; `harness setup` still disables the
  repo's Actions); signed out, it prints a NOTE naming `harness setup`. `HARNESS_INIT_SEED=0` skips it.
- `/harness` step 2: the `prd` label must exist before the PRD is filed — init seeds it, else
  `harness setup` runs before step 3.

### Claude Code installed by the prerequisite offer is found in `~/.local/bin` (#431)

- Accepting install.sh's "install Claude Code?" offer on a fresh Linux host still ended in
  `MISSING: an agent CLI`: Claude Code's native installer puts `claude` in `~/.local/bin`, which a
  fresh session's PATH often lacks. install.sh now puts `~/.local/bin` on PATH for the rest of the
  install when it exists (before it offers or checks an agent CLI), and `_cli_bin_ensure` does the
  same after a vendor installer lands the binary there, so the check passes and a re-run does not
  offer the install again.
- When the agent CLI or the `harness` link sits only in a directory the user's own PATH lacks, the
  installer prints the exact `export PATH=...` line and says to re-open the shell; it does not fail.
- `/harness` step 1: after installing, a `harness` still off PATH is run as `~/.local/bin/harness`
  and the user is told the PATH line.

### Ending a headless lane ends its detached background jobs (#427)

- #418's guarantee did not hold on `HARNESS_SESSION_BACKEND=headless`: a turn that ended normally
  left its background jobs (`sleep 777 &`, a `setsid`'d server) running, re-parented, and neither
  `sess_kill` on the idle lane nor the stats sweep of a lane that exited on its own reached them.
  The lane now records the `HARNESS_SESSION` uuid it started with, and both end every process whose
  environment carries it exactly (`proc_sweep_session`: SIGTERM, then SIGKILL after
  `HARNESS_SWEEP_GRACE`; never the caller, its ancestors or a tracked worker; by pid only).
- A lane relaunched on its claude session keeps its uuid: nothing is swept while a live lane carries it.
- On Windows a process still up after the grace is also `taskkill /F`'d by its winpid.

### Dispatch never re-claims an issue its live lane still owns (#416)

- Dispatch decided an issue was claimable from its labels alone, so a live lane that dropped
  `agent-working` (it checkpointed, or parked itself `agent-paused`) had its issue re-claimed every
  pool pass: `agent-working` flapped, `worktree add failed #<n>` repeated, the stuck issue took the
  free slot ahead of real work (resumable-first, #210), and the re-stamp reset a self-parked lane's
  grace timer, so #417's checkpoint never fired. The pool now passes the issues a lane still owns —
  an impl/bug/triage worktree, a live impl or bug session, a fresh `harness one` lease — to
  `issuelib.py dispatch --busy-issues`, which drops them before slots are counted. A dead lane's
  issue (no session, no worktree) still resumes as before.
- `prepare_impl` stamps `agent-working` only after `git worktree add` succeeds (as `spawn_bug` has
  since #34), so a failed add no longer leaves the label behind.

### `harness stats` no longer double-counts a headless lane's tokens (#426)

- A headless lane relaunched on its claude session (after a checkpoint, a crash or a usage park)
  appends to the same transcript; its `session_end` re-counted the earlier run. It now reports only
  what that run added, flagged `resumed: true`, and `harness stats` adds it to the session's earlier
  runs — the two `session_end`s sum to the session's real usage. Earlier logs read as before.
- A lane with no transcript summed every turn's stream-json `modelUsage`, which on a `--resume`d
  turn is the session's running total. Each turn now counts its own usage
  (`model_usage_since_last_result`, or `modelUsage` less the previous turn's).
- tmux lanes are unchanged.

### `harness stats --by-role` (#378)

- Tokens (input, output, cache) and list-price $ per role — Manager, Implementer, and `other` for a
  session whose kind says neither — so the per-role model saving is measurable before and after.
  Works on history from before roles (by session kind, or the worktree name), and takes the usual
  filters (`--since`, `--fleet`, `-R`, `--model`, `--prd`, `--issue`) and `--json`.

### A lane that parks itself `agent-paused` no longer holds its slot (#417)

- On an autonomous fleet, an impl lane that swaps its issue to `agent-paused` without a
  `HARNESS CHECKPOINT` (to wait for a human decision) used to idle at its prompt forever: the reap,
  the stall watchdog and the supervisor's nudges all let it be. The pool's poll now sees it
  (`issuelib.py check ISSUE:<n>` reads `PAUSED`: open, `agent-paused`, no `agent-working`), sends it
  one nudge to decide and continue, and, if it is still parked after `HARNESS_SELFPARK_GRACE_MIN`
  minutes (new, default 30), checkpoints it mechanically (WIP pushed, `harness-handoff` comment) and
  ends it; the issue then resumes from `resume.md`. Work that cannot be pushed is never killed.
- Every checkpoint the engine sends (`pause --force`, the usage checkpoint, `harness one`) now records
  `run/<session>.checkpoint`, so a requested pause is never mistaken for a self-park.
- `impl.md`, `resume.md` and `bug-fix.md` reserve `agent-paused` for a received `HARNESS CHECKPOINT`;
  `resume.md` tells an autonomous lane to settle a handoff's open decision itself and document it.

### A tmux lane's background jobs end with it (#418)

- Killing a tmux lane (`sess_kill`: reapers, `harness supervise`, adapters) now also ends what it left
  running. `tmux kill-session` only reached the pane's own process group, so a detached background job
  the agent started (a test server, `tail -F`, a watcher) outlived the lane forever, holding ports and
  RAM. The kill now reads the session's `HARNESS_SESSION` and its panes' process trees first, then
  SIGTERMs every process whose environment carries that uuid exactly, plus the pane tree, and
  SIGKILLs what is still up after `HARNESS_SWEEP_GRACE` seconds (default 3).
- A lane that exits on its own (Ralph promise, inject loop end) is swept the same way by
  `stats_sweep_ended` when it claims the session's stats context (new seam function `sess_sweep`;
  a no-op on the headless backend, whose runner already ends a turn's tree).
- By pid only, never by pattern: a near-miss uuid, an argv naming the uuid, the caller and its
  ancestors, the tmux server and the fleet's tracked workers are never touched.

### Verify what ran: `model_mismatch` (#376)

- At `session_end`, the model with the most output tokens in the session is compared with the model
  its launch logged, by family (`sonnet` = `claude-sonnet-5-5`). A different family emits a
  `model_mismatch` event (intended, actual, session, issue), flagged in `harness status`,
  `harness stats` and the web dashboard. Side calls on another model never trip it; a lane on the
  CLI's default model is not checked.

### Caveman in every lane (#377)

- Every session prompt — plan, prd, decompose, review, bug-triage, bug-fix, impl, resume, inject —
  invokes the `caveman` skill at session start through one shared partial, `prompts/_caveman.md`.
  Before, only impl and bug-fix did.
- Scoped: caveman for the session's own output and agent-to-agent comments (handoffs, review
  findings, checkpoint notes); human-facing artifacts (PRD and issue bodies, PR descriptions, docs,
  README, commit messages) stay plain prose; exact strings (code, commands, errors, labels, issue
  refs) are never compressed.

See [docs/reference.md § Lane output style](docs/reference.md#lane-output-style-caveman).

### Workers and headless lanes exit when their home is deleted (#419)

- `pool-worker.sh` and `priority-worker.sh` exit 0 (logging the missing path) once the `STATE_DIR` or
  `HARNESS_HOME` they serve is deleted or replaced. The check runs first in every poll, before any
  `mkdir -p` could re-create the root, so a leaked worker no longer calls `gh` from a dead home or
  re-creates `$HARNESS_HOME/poller` on every tick.
- `claude_headless.py run` stops itself when its lane dir is deleted (whose `stop` file can then
  never be written): idle, it exits 0; mid-turn, it kills the claude child's process tree first. It
  writes nothing more and does not re-create the lane.
- Tests: `tmp_cleanup` (`test/helpers.sh`) now stops this user's processes whose cwd, or
  `STATE_DIR` / `HARNESS_HOME` / `HARNESS_LANE_DIR`, is inside a tracked dir before removing it — by
  path, never by command-line pattern. A no-op without `/proc`.

### Roles: model and effort per lane (#375)

- Every lane is a **Manager** (orchestration `-p*`: PLAN, PRD, DECOMPOSE, REVIEW/gauntlet; bug triage;
  the injector) or an **Implementer** (issue lanes `-i*`, incl. `resume.md`; bug fixes), and launches
  with its role's model and effort: `HARNESS_MODEL_MANAGER`, `HARNESS_EFFORT_MANAGER`,
  `HARNESS_MODEL_IMPLEMENTER`, `HARNESS_EFFORT_IMPLEMENTER`.
- Defaults on `claude`: `opus`/`high` (Manager), `sonnet`/`high` (Implementer). Every other CLI: empty =
  the CLI's own default unless configured.
- Precedence: a worktree hook's `.harness-lane` > the role keys > a `--model`/`--effort` in
  `HARNESS_*_FLAGS`. `harness init` asks for and shows both roles.
- **Behaviour change:** a fleet pinning `--model opus` in `HARNESS_CLAUDE_FLAGS` (harness-dev, ORGE,
  bangwa) gets Sonnet implementers after this. Set `HARNESS_MODEL_IMPLEMENTER=opus` in
  `.harness/config` to keep the old behaviour.

See [docs/reference.md § Roles](docs/reference.md#roles-model-and-effort-per-lane).

# Benchmark runner

`bench/run.py <arm>` runs one benchmark arm end to end and records one results file for it (PRD #345).
The arms themselves (plain Claude Code, Harness with 1 worker, …) are separate tasks that plug in as
modules; this is the core they all go through. [The plain arm](#plain-arm) is the first;
[the Harness arm](#harness-arm) is the second.

```
bench/run.py stub                       # run an arm
bench/run.py stub --dry-run             # print the guard decision; create and spend nothing
bench/run.py plain --runs 5             # --runs N (default 5): N runs per arm, each in its own repo, plus an aggregate
bench/run.py plain --runs 1             # one run, shown as n=1: it supports no claim
bench/run.py plain --arm-opt K=V        # options passed to the arm
bench/run.py harness --workers 3        # --workers N: the fleet's pool size, for an arm that runs one
bench/run.py hx --optional              # an optional arm: a guard refusal is recorded as `skipped: budget`, exit 0
bench/run.py harness-opus --optional    # the matched arm: Harness with every role on Opus at plain's effort
```

## One run

1. **Guard** (below). Refused: exit 3, nothing created, nothing recorded.
2. Create a fresh **private** GitHub repo `<gh login>/bench-<run-id>-<arm>`, GitHub Actions disabled,
   seeded with the project brief and nothing else (never the hidden tests or the reference solution).
3. Clone it into a throwaway directory and run the arm there, under the caps.
4. Grade a fresh clone of the repo's final default branch with `bench/grade.py`: the hidden tests, then the
   [differential fuzz](#differential-fuzz) against the reference implementation.
5. Measure the arm's transcripts and write `bench/results/<run-id>/<arm>.json`.
6. **Delete the repo**, whatever happened: arm error, cap hit, grading failure. If `gh repo delete`
   fails (the gh token needs the `delete_repo` scope) the results say `repo_deleted: false`, the repo is
   named on stderr, and the exit status is 4. The guard checks this up front: a gh token whose
   `X-OAuth-Scopes` are known and lack `delete_repo` is refused (exit 3, or `skipped: no-delete-repo` for an
   `--optional` arm) before any repo is created; run `gh auth refresh -s delete_repo`. A fine-grained token has no
   scope header and is not refused on that alone. `bench/figures.py` lists any run repo left undeleted in the README.

Exit status: 0 recorded (`ok` or `capped`), 1 the arm failed (recorded as `error`), 2 bad arguments or
unknown arm, 3 guard refused, 4 recorded but the repo could not be deleted.

## Repeated runs: `--runs N`

Every published number used to be one run (n=1), and agent wall time and cost typically vary 20–40% between
runs, so one run cannot support a claim. With 3 runs against 3 a Mann-Whitney test cannot get below p≈0.1; with
4 against 4 it can reach p≈0.029. `--runs N` (default **5**) runs the arm N times, one after the other, each as
a [run above](#one-run): its own private repo (`bench-<run-id>-<arm>-r01`, `-r02`, …), the same caps, and the
[guard](#guard) **again before each run**, on the usage the earlier runs left behind.

```
bench/results/<run-id>/
  <arm>.json              the aggregate (status "aggregate")
  <arm>.runs/run-01.json  run 1's results, the schema below plus "run": 1
  <arm>.runs/run-01.logs/ run 1's raw logs
  <arm>.runs/run-02.json  …
```

The aggregate is rewritten after every run, so a batch that is killed keeps what it had. It holds
`runs_requested`, `runs_completed` (runs that finished `ok` or `capped`; a capped run counts at what it spent
before its cap), `runs` (`run`, `file`, `status`, `capped` of each run started) and
`aggregate: {n, metrics}`: per metric `{n, median, min, max}` for `wall_s`, `coding_s`, `testing_s`,
`test_calls`, `cost_usd`, `weekly_window_pct`, `tokens` (and `tokens_input`, `tokens_output`,
`tokens_cache_read`, `tokens_cache_write`), `hidden_passed`, `hidden_total`, `fuzz_divergences`, `fuzz_cases`,
`coverage` (SonarQube), `sonar_bugs`, `sonar_vulnerabilities`, `sonar_code_smells`,
`sonar_duplicated_lines_density` and the `counts` `issues_closed`, `prs_merged`, `commits`,
`continue_replies`. A metric no run produced is left out; an ungraded run has no `hidden_passed`. An errored
run is listed in `runs` but not counted. The code is `bench/aggregate.py`.

**A batch that stops early says so.** `stopped` is `null` when all N runs completed; otherwise
`{reason, detail}`, and `runs_completed` is how many finished:

| `reason` | when |
|---|---|
| `guard` | the guard refused a later run (the budget ran out, an account got usage-HELD, the disk filled): `causes` are the guard's (`budget`, `held`, …) and `detail` its numbers. Nothing is created or spent for the refused run |
| `arm-error` | a run's arm failed (it is recorded as `status: error`); more runs would most likely fail the same way |
| `repo-not-deleted` | a run's repo could not be deleted (exit 4, named on stderr); no further repo is created |

A refusal before the **first** run is unchanged: exit 3 (or `skipped: <cause>` with `--optional`), nothing recorded.
Exit status of a batch: 0 when the aggregate is recorded (also when it stopped early on the guard), 1 when it
stopped on an arm failure, 4 when it stopped on a repo that could not be deleted.

`--runs 1` writes the single-run layout (`<arm>.json` is the run's own results, `<arm>.logs/`), which
`bench/figures.py` labels `n=1`, as it does every result written before `--runs` existed.

## Guard

A run refuses to start when:

- any account is usage-HELD: a `*.hold` file in `<run dir>/usage-holds/` (`--run-dir`, else `$RUN_DIR`,
  else `$STATE_DIR/run`, else `./.harness/run`), the files the fleet's usage watch writes; or
- the host disk is short (#386): under `BENCH_MIN_FREE_GB` (default 4) free on the temp dir's filesystem, where
  a run clones repos and builds worktrees (the run clone, Hx's and the fleet's state dir and worktrees). Only
  the filesystems a run writes to are measured (#577): the checkout is read, not written (the results JSON is a
  few KB), so a full checkout filesystem does not refuse a run; or
- the headroom is short, as `harness one gate` computes it: for every weekly window the usage seam reads
  (`HARNESS_USAGE_CMD`, else the CLI adapter's `cli_limit_usage`),
  `now% + expected% + reserve% <= HARNESS_ONE_STOP_PCT` (default 98) must hold, with the reserve
  `HARNESS_ONE_RESERVE_PCT` (default 2). `expected%` is the expected spend over the account's $ per 1%
  of the window: the calibration `forecast.py` fits from the host event log (#364), else
  `HARNESS_ONE_USD_PER_PCT`. The expected spend defaults to the $ cap, the most an arm can spend;
  `--expected-usd` overrides it; or
- there is no weekly reading, or no $ per 1% at all: the guard cannot show the run fits.

`--dry-run` prints the same decision (exit 0 OK, 3 refused) and does nothing else.

## Caps

Per arm, enforced while it runs: **6 h** wall clock (`--wall-cap-secs`) and **$80** at list price
(`--cost-cap-usd`), the $ measured on the transcripts the arm has registered so far. At a cap the runner
sets `ctx.stop`, terminates every process the arm started through `ctx.spawn`, gives the arm
`--grace-secs` to return, and records `status: "capped"` with `capped: "wall"` or `"cost"`. A capped arm is
reported, not dropped.

## Arm interface

An arm is `bench/arms/<arm>.py` defining `run(ctx)`. It works in `ctx.clone` (the cloned run repo, the brief
at `ctx.brief`) and pushes to `ctx.repo`, and may return `{"counts": {...}, "transcripts": [...]}`.

| `ctx` | |
|---|---|
| `repo`, `clone`, `brief`, `logs` | the run repo `owner/name`, its checkout, the brief inside it, the arm's log directory (kept with the results) |
| `stop` | a `threading.Event`: set at a cap. Return promptly when it is set |
| `opts` | the `--arm-opt K=V` pairs, a dict of strings |
| `caps` | `{"wall_s", "cost_usd"}` |
| `spawn(argv, **kw)` | `subprocess.Popen`, tracked so a cap can terminate it |
| `add_transcripts(*paths)` | Claude-format session transcripts (a session's sub-agent transcripts beside it count too). The $ cap and every token, model and time figure are measured on these |
| `count(name, n=1)` | an arm-specific count (issues closed, PRs merged, commits, continue replies, …) |
| `log(msg)` | a line in the run log |

An exception from `run` is recorded as `status: "error"` and the run continues to grading and cleanup.
`bench/arms/stub.py` is a minimal arm with no agent, for tests and for checking the plumbing.

## Results

`bench/results/<run-id>/<arm>.json` (`--results-dir` moves the tree), with the raw logs beside it in
`<arm>.logs/` (with `--runs N` above 1, `<arm>.json` is the [aggregate](#repeated-runs---runs-n) and each run's
results and logs are in `<arm>.runs/`, same contents): `run.log` (what the runner did, with the gh calls), `grade.json`, `transcripts/` (copies of
the registered transcripts: `<i>-<name>.jsonl`, with its sub-agent transcripts in `<i>-<name>/subagents/*.jsonl`,
where `scripts/stats.py` reads them, so re-measuring the copies gives the numbers in the results JSON), and
whatever the arm wrote to `ctx.logs`.

| field | type | meaning |
|---|---|---|
| `schema` | int | `1` |
| `run_id`, `arm` | string | |
| `repo` | string | the run repo, `owner/name` |
| `status` | string | `ok`, `capped` or `error` |
| `capped` | string or null | `wall` or `cost` when `status` is `capped`, else null |
| `error` | string or null | the failure when `status` is `error` |
| `started_at`, `ended_at` | string | UTC ISO-8601 |
| `wall_s` | number | wall clock of the arm itself |
| `coding_s`, `testing_s`, `test_calls` | number or null | time in test-command tool calls vs everything else, from the transcripts (`stats.time_split`, #379); null with no transcript |
| `tokens` | object | `input`, `output`, `cache_read`, `cache_write` token counts |
| `cost_usd` | number | list price of those tokens |
| `usd_per_pct`, `usd_per_pct_source` | number or null, string | the $ per 1% of the weekly window used for the guard and `weekly_window_pct`; `fit` (#364 calibration), `fallback` (`HARNESS_ONE_USD_PER_PCT`) or `none` |
| `weekly_window_pct` | number or null | `cost_usd` as a % of the weekly usage window |
| `models` | object | per model that actually ran, from the transcripts: `messages`, `input`, `output`, `cache_read`, `cache_write`, `cost_usd` |
| `hidden_tests` | object | `bench/grade.py`'s fragment: `passed`, `failed`, `total`, `details` (`failed` and `total` are null, `details.error` set, when grading failed) |
| `fuzz_cases`, `fuzz_divergences` | int | [differential fuzz](#differential-fuzz) (#589): cases run, and cases where the arm and the reference disagree. Absent in results written before #589 and backfilled for `run-20261106` |
| `fuzz_examples` | list | up to 10 of those divergences: `case`, `argv`, `ledger`, `ledger_from`, `closed_stdout`, `reference` and `arm` (`exit`, `stdout`, `stderr_empty`, `file`), `arm_stderr` |
| `fuzz_seed`, `fuzz_hash` | int, string | the frozen generator's seed and the SHA-256 of its 1000 planned cases |
| `fuzz_error` | string | only when the fuzz could not run; it never fails a run |
| `effort` | object | optional (#590): messages per effort level as the transcripts record it (each entry's `effort` field, sub-agents included), e.g. `{"medium": 42}`; `bench/figures.py --check` re-reads it from the kept transcripts |
| `configured` | object | optional (#590): `{model, effort}` the arm asked for, `null` meaning the out-of-the-box default (plain and `harness`: both null; `harness-opus`: `opus` / `medium`). What actually ran is `models` and `effort` |
| `provenance` | object | optional (#590): `engine_commit` (the checkout's git commit, `-dirty` with uncommitted changes), `skill_version` (`sha256:` of the engine's `skill/` files, the `/harness` skill the Harness arms install), `cli_version` (`claude --version`); each a string or null when it could not be read |
| `claude_config` | object | optional: `{source, skills, plugins, mcp_servers}` counts from the first session init (plain: from its isolation proof; the Harness arms: the front door's, #584) |
| `isolation` | object | optional, Harness arms (#590): `{config: "isolated", engine_skills, engine_plugins}` the names installed into the isolated config |
| `counts` | object | the arm's own counts (`ctx.count`, the returned `counts`) |
| `caps` | object | `wall_s`, `cost_usd` in force |
| `repo_deleted` | bool or null | whether the run repo was deleted afterwards |
| `logs` | string | the logs directory next to the file |
| `run` | int | optional (#591): the 1-based index of this run in a `--runs N` batch; absent for `--runs 1` |

`run.validate(doc)` in `bench/run.py` returns the problems with a results document (empty when valid).

## Differential fuzz

The 80 hidden tests are the same for every arm and both arms scored 80 / 80, so they cannot tell the arms apart:
a blind review found five user-facing bugs in the Harness arm that no hidden test exercises (`add … -5 -refund`
exits 2; `add … -abc` exits 2 where the brief says 1; `list | head -1` gives a BrokenPipe traceback; a UTF-8
byte order mark is rejected; a form feed or U+2028 in a note gives the wrong error line). Adding exactly those
cases would tune the tests to one arm, so `bench/fuzz.py` (#589) grades the same way for every arm instead:

```
bench/fuzz.py --self                  # the reference against itself: 0 divergences
bench/fuzz.py --cmd '["pennywise"]'   # an arm's command line as a JSON argv (default: $PENNYWISE_CMD)
bench/grade.py REPO_DIR --fuzz-only --arm-json bench/results/<run-id>/<arm>.json   # backfill a graded run
```

- **What runs.** 1000 cases (`--cases`, capped at 300 s, `--cap`) of random argv and ledger files go through the
  arm's `pennywise` and through the reference implementation (the benchmark's reference solution, which the hidden tests
  prove against the brief), each in its own empty directory. The generator covers the commands and their options,
  dash-led arguments and `--`, a byte order mark and invalid UTF-8, LF / CRLF / lone CR / mixed line endings, a
  form feed, vertical tab, NEL, U+2028 or U+2029 inside a note, a ledger from a file or from `-` (stdin), a missing
  file or a directory, bad options, and a closed standard-output pipe (`pennywise list | head -1`).
- **A divergence** is a case where the two differ in standard output, in whether standard error is empty, in the
  exit status, or in the ledger `add` leaves behind (as lines). Where the brief leaves room it is not a difference:
  how many spaces `summary` puts between the name and the total, and JSON formatting (compared as data). With a closed
  output pipe only "standard error stays empty" and the ledger are compared: the brief gives no status for it.
- **Frozen.** The generator has its own PRNG (no `random` module), seed `589`, and the SHA-256 of its case list is
  pinned (`FROZEN_HASH`, and in `test/test_bench_fuzz.py`): `bench/fuzz.py` refuses to run when they disagree. A
  changed generator is a different measurement: update the seed and hash on purpose and re-grade the runs you compare.
  The hash is recorded in every result (`fuzz_hash`). A prefix of the cases is the same cases (`--cases 200`).
- **The reference** is held to the brief on exactly these shapes (`test/test_bench_reference.py`): `add` takes
  every argument as typed (a dash-led amount or note is not an option; `-abc` is a bad amount, exit 1), a UTF-8 byte
  order mark is dropped, a line ends at LF, CRLF or a lone CR and nowhere else, and a reader that went away ends the
  output quietly (no traceback, status 0).
- **Where it runs.** `bench/grade.py` runs it after the hidden tests on the same build and adds a `fuzz` object to its
  fragment; `bench/run.py` lifts that into the `fuzz_*` fields. A fuzz that cannot run is `fuzz_error`; the grade and the
  run are unaffected. `BENCH_FUZZ_CASES` / `BENCH_FUZZ_CAP_S` shorten it for tests.

## Isolated Claude config (#590)

The arms are compared on what they do, so they start from the same Claude setup. Run `run-20261106` did not: the Harness
arm loaded the operator's own 186 skills, user plugins, 4 MCP servers and hooks, the plain arm none. Now every session of
every arm runs with `CLAUDE_CONFIG_DIR` set to a throwaway `claude-config` directory in the run's work dir
(`bench/armlib.py`):

- **What it holds.** The login, `.credentials.json`, as a symlink to the host's file (never a copied directory; a login that
  lives in the environment passes as before), and a `.claude.json` that marks onboarding done. No user skills, plugins,
  MCP servers, hooks or settings of the host user's. The run log names the directory and the login it linked.
- **Plain arm.** Runs on exactly that, with its existing flags and its existing isolation proof.
- **Harness arms.** Add only what the Harness engine installs for any user: its own skills, linked from this checkout's
  `skill/` the way `install.sh` links them (the umbrella `skill/SKILL.md` as `harness`, and each `skill/<name>/`), and the
  plugins its lanes need, `ralph-loop` and `superpowers`, through `claude plugin install … --scope user` into that
  directory. The fleet sees the same directory (`CLAUDE_CONFIG_DIR`, `HARNESS_USER_SKILLS`, the transcript search list).
  A plugin that will not install fails the arm: a fleet without them is a different measurement.
- **The check.** The front door's init event is kept in `<arm>.logs/init.json` (`view` = the names it listed) and checked
  before any work: an MCP server, or a plugin that is not the engine's, stops the arm (`status: error`, "isolation check
  failed"). Skills are not checked by name, because the CLI bundles some of its own. `test/test_bench_plain.py` runs both
  arms against a host config that has a skill, a plugin, an MCP server and a login of its own and asserts the two inits
  match apart from the engine's skills and plugins.

## Plain arm

`bench/run.py plain` (`bench/arms/plain.py`, #382): what a new user gets. ONE `claude` session in the run
repo's clone (no CLAUDE.md), on the CLI login already on the host: never `--bare` (API-key only), no API key
(`ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are removed from its environment), no copied credentials dir.
Each turn is `claude -p --output-format stream-json --verbose --disable-slash-commands --strict-mcp-config
--setting-sources project,local --dangerously-skip-permissions`, `--resume <session>` after the first, with
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`. No `--model`: the account's default model and effort run, and the models
that actually ran come from the transcript like every other arm's. `--arm-opt claude=CMD` swaps the binary
(tests use a fake). The exact command lines are in `<arm>.logs/launch.txt`.

- **Isolation proof.** The first `system/init` event is kept in `plain.logs/init.json` with the counts it
  was judged on. Every turn's init must list 0 skills, 0 plugins and 0 MCP servers, else the session is
  killed before it does any work and the run is recorded as `status: error` ("isolation check failed: …").
  Plugins that ship inside the claude binary (`path: "builtin"`, e.g. `cc-plugin-telemetry`) are not
  installed plugins and are not counted; the proof lists how many there were.
- **Input.** The brief (bench/fixture/brief.md) is the first message, followed by one fixed line saying the folder is a
  clone of the run repo and the work belongs on `main` (the grader reads the repo's `main`, and the brief
  itself says nothing about git).
- **Continue replies.** `claude -p` ends a turn when the session stops. It is DONE when the final message
  does not end in a question and the work is delivered (clean clone, HEAD on `origin/main`, a commit past the
  brief). Otherwise `keep going, decide for yourself` goes in, at most 20 times; at the cap the arm stops and
  the run is graded as it stands. A turn that errors (a usage limit, an API failure) fails the arm.
- **Counts** in the results: `continue_replies` and `commits` (commits on `main` past the brief).

## Harness arm

`bench/run.py harness [--workers N]` (`bench/arms/harness.py`, #383): the same brief through `/harness <idea>`
-> PRD -> decompose -> lanes, fully autonomous. `--workers N` (or `--arm-opt workers=N`) is the fleet's pool
size, `HARNESS_POOL`: how many issues run in parallel. It defaults to 1; the optional 3-worker run is
`bench/run.py harness-3` (the same module with `workers` defaulting to 3, results under `harness-3.json`).
Other options: `harness=CMD` (default: this checkout's `bin/harness`, so the engine measured is the one the
benchmark ships with), `claude=CMD` (the front door's binary), `poll=SECS` (how often the arm looks at the
fleet, default 30); the last two are for tests.

- **Front door.** ONE `claude -p` session in the run repo's clone is handed `/harness ` + the brief
  (bench/fixture/brief.md) and one fixed line saying nobody is there to answer (every Confirm is a yes, the
  session settles its own questions). The /harness skill then does what it does for any user: `harness init`,
  the PRD, `harness start`. A front door that stops before a fleet is up gets `keep going, decide for
  yourself`, at most 5 times (`counts.continue_replies`); a fleet that is still not up after that fails the arm.
- **Out-of-the-box defaults.** (The matched arm below is the exception.) No `--model` or `--effort` for the front door and no `HARNESS_MODEL_*` /
  `HARNESS_EFFORT_*` in the fleet's environment, so Harness runs its role defaults (#373, #375). The models
  that ran come from the transcripts: the front door's, and every session in the run fleet's `events.jsonl`.
  The pool runs with `HARNESS_USE_POLLER=0`: the host poller is a host-level process that nothing here would stop.
- **Isolation.** The run fleet has its own `HARNESS_HOME` (event log, fleet registry, snapshots), its own state
  dir inside the clone (`<clone>/.harness`), a session prefix made from the run repo's name (`bn` + 5 hex) and a
  scrubbed environment: every `HARNESS_*` and `STATE_DIR` / `RUN_DIR` of the host's fleets is dropped (only
  `HARNESS_USAGE_CMD` and `HARNESS_CLAUDE_CONFIG_DIRS` pass through) and no API key reaches it.
  The Claude config is the [isolated one](#isolated-claude-config-590) the plain arm runs on, plus the engine's own skills and
  plugins (#590); before that (run-20261106) the sessions loaded the host user's own, which is why the arm records what the
  front door's init event listed, `claude_config` = `{source, skills, plugins, mcp_servers}` (`plugins` leaves out the CLI's
  built-ins; the skills count includes the CLI's bundled ones), and `bench/figures.py` states it under the README table.
- **Stopping.** Never by pattern. The arm runs `harness stop --state-dir <clone>/.harness`, the engine's own
  stop for exactly that state dir, and the front door it spawned is terminated through `ctx.spawn`. This
  happens however the arm ends: done, error or a cap. `<arm>.logs/fleet.json` names the state dir and the
  stop command, for a run whose runner was killed.
- **Done** = every PRD issue of the run repo is closed. A fleet whose workers are all gone before that is
  restarted with `harness start --recover`, at most 3 times (`counts.fleet_restarts`), then the arm fails.
  `counts.fleet_restarts` also counts the restarts the front-door session made by hand: each `harness start`
  its Bash calls ran after the first (the engine logs no start/stop events; the stream is the record).
- **Results.** `counts`: `issues_closed` (closed issues that are not PRDs), `prs_merged`, `workers`,
  `continue_replies`, `fleet_restarts`; top level: `claude_config`, and an optional free-text `note` that
  `bench/figures.py` prints under the table (use it for anything done by hand during a run). Beside them in `<arm>.logs/`: `events.jsonl` (the fleet's event log),
  `stats.json` (`harness stats --json` on it), `fleet.config` (the config the fleet ran with), the front-door
  stream per turn and `launch.txt`. Tokens, $ and the coding / testing split are measured on the transcripts
  like every arm's; the $ cap counts the lanes' transcripts as they appear.

## Harness all-Opus arm

`bench/run.py harness-opus [--optional]` (`bench/arms/harness-opus.py`, #590): the matched arm. The headline `harness` arm
keeps Harness's out-of-the-box defaults, so its models (Opus manages, Sonnet implements) and effort (`high`) differ from the
plain arm's. This arm is the same module with `model=opus` and `effort=medium` set (override with `--arm-opt model=…` /
`effort=…`): the front door gets `--model opus --effort medium`, and the fleet gets `HARNESS_MODEL_MANAGER`,
`HARNESS_MODEL_IMPLEMENTER` = `opus` and `HARNESS_EFFORT_MANAGER`, `HARNESS_EFFORT_IMPLEMENTER` = `medium`, so model and effort
are matched together. `medium` is the effort the plain arm ran at in `run-20261106` (its transcripts' `effort` field).
Everything else is the Harness arm: one worker, the same isolated config, the same brief. Results are `harness-opus.json`
with `configured: {model: "opus", effort: "medium"}`; what ran is in `models` and `effort`.

It is optional and never blocking: with `--optional` a guard refusal is recorded as `skipped: <cause>` (below), and
`bench/figures.py` shows `skipped: not run` for a run with no record of it.

## Hx arm

`bench/run.py hx [--optional]` (`bench/arms/hx.py`, #386): [Hx](https://github.com/MorphEdit/Hx) (`MorphEdit/Hx`)
on the same brief with its default config. One of the two optional arms, the other is `harness-3`.

- **Install.** Hx is cloned at the pinned commit `HX_COMMIT` (in `bench/arms/hx.py`) into a throwaway
  directory and run as `node bin/hx.mjs` (Hx needs node 23.6 or newer and has nothing else to install). The
  clone must land on exactly the pin or the arm fails. `<arm>.logs/hx.json` records the commit and the node
  version. A newer Hx is a different measurement: change the pin on purpose. Options (`--arm-opt K=V`):
  `hx_src=DIR` (use this checkout), `node=CMD`, `poll=SECS`; the first two are for tests.
- **What runs.** In the fresh run repo: `hx init --yes`, then `hx prd brief.md --title "PRD: <heading>"`, then
  `hx run --watch`: Hx's own gauntlet, decompose, impl, audit, gate, review and security pass. Hx's
  interview commands (`hx start`, `hx grill`) need a human in an interactive session, which an unattended run
  has none of, so the brief is filed as the PRD as written, the way Hx's own project benchmark does.
- **Default config.** `.hx/config.json` stays what `hx init` wrote (workers 2 with auto-scaling, model, effort,
  rounds, gates) except `worktreeRoot`, which Hx defaults to a directory at the filesystem root a Linux user
  cannot create; the arm points it into the run's throwaway directory. The models that ran come from the
  transcripts (every session id in Hx's `usage.jsonl`), like every arm's.
- **Isolation.** A scrubbed environment: no `HARNESS_*`, `STATE_DIR`, `RUN_DIR` or API key reaches Hx.
- **Stopping.** Never by pattern. The `hx run --watch` the arm spawned gets SIGINT (Hx's own Ctrl+C: sessions
  commit, push and hand off), through a small forwarder that also turns the runner's SIGTERM at a cap into that
  SIGINT; then `ctx.terminate` if it has not exited. Done, error or cap.
- **Done** = the PRD issue is closed. An `hx run` that exits first is started again (Hx's only state is
  GitHub), at most 3 times (`counts.fleet_restarts`), then the arm fails.
- **Results.** `counts`: `issues_closed`, `prs_merged`, `workers` (Hx's configured ceiling), `fleet_restarts`.
  Beside them in `<arm>.logs/`: `usage.jsonl`, `config.json`, `run.out`, `hx.json`.

## Optional arms and `skipped: <cause>`

The optional arms (`harness-opus`, `harness-3`, `hx`) are never blocking. `bench/run.py <arm> --optional` runs the arm when
the guard passes, exactly as without the flag. When the guard refuses, nothing is created or spent and
`bench/results/<run-id>/<arm>.json` records the outcome instead, exit 0:

```json
{"schema": 1, "run_id": "…", "arm": "hx", "status": "skipped", "reason": "budget", "skipped_at": "…",
 "guard": {"reasons": [...], "causes": ["budget"], "held": [...], "expected_usd": 80, "stop_pct": 98, "reserve_pct": 2,
           "min_free_gb": 4, "disk": [{"path": "/", "free_gb": 2.4, "fits": false}],
           "usd_per_pct": 4.15, "usd_per_pct_source": "fit", "windows": [{"account": "…", "window": "seven_day",
           "now_pct": 96, "need_pct": 19.28, "total_pct": 117.28, "fits": false}]}}
```

`reason` is never hardcoded: it is the guard's own refusal cause(s), comma-joined in a fixed order when
several apply (`guard.causes` holds the same list; `guard.reasons` keeps the human-readable sentences):

| `reason` | the guard refused because |
| --- | --- |
| `disk` | the temp dir's filesystem has less than `BENCH_MIN_FREE_GB` free |
| `held` | an account is usage-HELD |
| `no-usage-reading` | no weekly usage reading |
| `no-calibration` | no $ per 1%, so the expected spend cannot become a % of the window |
| `budget` | `now% + expected% + reserve%` is over the stop % for a weekly window |

A disk-only refusal on a host whose usage fits is `disk`, a usage refusal is `budget`, and both is
`disk,budget`. `bench/figures.py` renders a `status: skipped` record as a `skipped: <reason>` row (a
`skipped.json` map still works for a reason that is not the guard's). `--dry-run` never records.

## Figures and the README Benchmark section

`bench/figures.py` writes the README **Benchmark** section (the table and a pointer to the figure) and the
figure `bench/results/benchmark.svg` from `bench/results/`, and nothing else; the section sits between the
`<!-- bench:begin … -->` and `<!-- bench:end -->` markers and is never edited by hand.

```
bench/figures.py                 # the latest run under bench/results/
bench/figures.py --run-id ID     # a specific run
bench/figures.py --check         # write nothing; exit 1 when the README section or figure is stale, or an arm's
                                 # committed logs, re-measured, do not reproduce its results JSON (#579)
```

Output is deterministic (no timestamps, fixed fonts, colours and rounding), so the same results give the same
bytes and re-running reproduces the committed files exactly. The table has one row per `<arm>.json`: `n`, the
number of runs behind the row (`n=1` for a single run and for every result written before `--runs`; `n=3 of 5`
for a batch that [stopped early](#repeated-runs---runs-n), told under the table with its reason), cap
status, wall time with the coding and testing split, tokens (total and input / output / cache read / cache
write), list-price $ and % of the weekly window, hidden tests passed, fuzz divergences (`fuzz_divergences` / `fuzz_cases`, #589), issues / PRs (`counts.issues_closed`,
`counts.prs_merged`) or commits (`counts.commits`), continue replies (`counts.continue_replies`) and the
models that ran. Under the table, a **Run settings** line per arm that recorded them (#590) gives the models that ran, the effort by message,
what the arm asked for, the engine commit, the `/harness` skill version and the Claude Code CLI version. The **SonarQube** column (`bugs`, `vulnerabilities`, `code_smells`, `maintainability_rating`,
`duplicated_lines_density` from the result's `sonarqube` object) and the **Coverage (own tests)** column (total,
line and branch %, from its `coverage` object) are **always** there: a scan or coverage run that did not produce
numbers renders as `n/a (<reason>)`, and a result that never tried as `n/a (not measured)`.  **A run in which any arm's quality scan did not run is invalid**: the section opens
with `INVALID RUN: rerun.` and names the arm and the reason, because a host problem must not count against an
arm (`bench/run.py` says so on stderr too). Rerun the whole run; `--check` still passes on an invalid run once
its README is written, since the README then says it is invalid.
For an arm with several runs every number is the **median**, with the **range** after it (`$20.00 ($10.00–$30.00)`),
and the figure draws the median as the bar with min–max whiskers; a **Runs** line under the table says so. `--check`
also fails when an aggregate differs from the aggregate of its runs' results JSON or names a run file that cannot be
read, and re-measures each run's logs. Anything a result lacks renders as `n/a`. The optional arms (`harness-opus`, `harness-3`, `hx`) get a `skipped: <reason>` row
when they have no results; the reason is read from `bench/results/<run-id>/skipped.json`,
`{"<arm>": "<reason>"}`, or a `status: skipped` `<arm>.json` (above), else `not run`.

## Code quality (optional)

`bench/quality.py <repo-dir>` (#387) scores an arm's final default branch with **SonarQube Community Edition in
Docker, locally**: no account and no token of yours (the server is a throwaway `sonarqube:community` container
and its admin token is generated inside it; `sonarsource/sonar-scanner-cli` scans the repo mounted read-only).
`bench/run.py` runs it on the same fresh clone the hidden tests grade, after grading, and the container and
network are removed afterwards. The first run pulls about 4 GB of images and SonarQube needs a couple of GB of
RAM, so it takes minutes. `BENCH_SONAR_IMAGE` / `BENCH_SONAR_SCANNER_IMAGE` pick other images.

SonarQube's data directory (`/opt/sonarqube/data`) is mounted as a **tmpfs** (`BENCH_SONAR_DATA_SIZE`, default
`6g`, RAM-backed). Without it, Elasticsearch refuses to start when that filesystem has under 10% free
(`Not enough free disk space for Elasticsearch data directory`), and the bench host's disk is often fuller than
that. When the server does exit, the skip reason is the log's first `ERROR` / `MessageException` line, not its tail.

It is **never blocking**. Docker not installed, its daemon down, an image that cannot be pulled, a server that
does not come up, a scan that fails or times out: the arm's results say `quality: "skipped (<reason>)"`, the run's
other results are untouched and the exit status is still 0.

```
bench/quality.py DIR                       # prints the fragment as JSON
bench/quality.py DIR --arm-json X.json     # also merges it into an arm's results file
```

| field | type | meaning |
|---|---|---|
| `quality` | string | `ok`, or `skipped (<reason>)`, which makes the run **invalid: rerun** (see above). Absent in results written before #387 |
| `sonarqube` | object | only with `quality: ok`: `bugs`, `vulnerabilities`, `code_smells` (counts), `maintainability_rating` (`A` to `E`), `duplicated_lines_density` (%), `coverage` (%, null when no test coverage was imported, as here) |

The SonarQube `coverage` is null here (no coverage report is imported); the arm's coverage is measured separately:

### Test coverage

`bench/testcov.py <repo-dir>` (#588) runs the arm's **own** test suite (`python -m unittest discover -s tests`, or
pytest for a suite that does not use unittest) on a throwaway copy of the graded clone, under coverage.py with
branch measurement, and `bench/run.py` records the result as `coverage` beside `quality`. **Subprocesses count**:
the CLI tests run `python -m <pkg>` in child processes, so the run sets `parallel = True` and
`COVERAGE_PROCESS_START` and puts a `sitecustomize` calling `coverage.process_startup()` on `PYTHONPATH`; the
children's data files are combined before reporting. The measured source is the repo's `src/` (else the repo
root minus `tests/`). Like quality it never blocks: coverage.py missing (`pip install coverage`), no `tests/`
directory or tests that wrote no data are `coverage: "skipped (<reason>)"`.

| field | type | meaning |
|---|---|---|
| `coverage` | object or string | `{"line_pct", "branch_pct", "total_pct", "tests"}` (%, `tests` is `unittest` or `pytest`; `total_pct` is coverage.py's branch-aware total, what `coverage report` prints), or `skipped (<reason>)`. Absent in results written before #588 |

```
bench/testcov.py DIR                       # prints the fragment as JSON
bench/testcov.py DIR --arm-json X.json     # also merges it into an arm's results file
```

The tests drive the scan with a fake `docker` and a fake SonarQube API; a real scan on a
small sample repo is opt-in (`BENCH_QUALITY_REAL=1 python3 test/test_bench_quality.py`) and says so when it is skipped.

A standing audit of the **public Harness repo itself** (SonarQube Cloud, Codacy or DeepSource, free for public
repos) is a separate, owner-side choice: see [docs/online-code-audit.md](../docs/online-code-audit.md). It is not a
gate, and nothing in the fleet depends on it.

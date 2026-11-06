# Benchmark runner

`bench/run.py <arm>` runs one benchmark arm end to end and records one results file for it (PRD #345).
The arms themselves (plain Claude Code, Harness with 1 worker, …) are separate tasks that plug in as
modules; this is the core they all go through. [The plain arm](#plain-arm) is the first;
[the Harness arm](#harness-arm) is the second.

```
bench/run.py stub                       # run an arm
bench/run.py stub --dry-run             # print the guard decision; create and spend nothing
bench/run.py plain --arm-opt K=V        # options passed to the arm
bench/run.py harness --workers 3        # --workers N: the fleet's pool size, for an arm that runs one
bench/run.py hx --optional              # an optional arm: a guard refusal is recorded as `skipped: budget`, exit 0
```

## One run

1. **Guard** (below). Refused: exit 3, nothing created, nothing recorded.
2. Create a fresh **private** GitHub repo `<gh login>/bench-<run-id>-<arm>`, GitHub Actions disabled,
   seeded with the project brief and nothing else (never the hidden tests or the reference solution).
3. Clone it into a throwaway directory and run the arm there, under the caps.
4. Grade a fresh clone of the repo's final default branch with `bench/grade.py` (the hidden tests).
5. Measure the arm's transcripts and write `bench/results/<run-id>/<arm>.json`.
6. **Delete the repo**, whatever happened: arm error, cap hit, grading failure. If `gh repo delete`
   fails (the gh token needs the `delete_repo` scope) the results say `repo_deleted: false`, the repo is
   named on stderr, and the exit status is 4. The guard checks this up front: a gh token whose
   `X-OAuth-Scopes` are known and lack `delete_repo` is refused (exit 3, or `skipped: no-delete-repo` for an
   `--optional` arm) before any repo is created; run `gh auth refresh -s delete_repo`. A fine-grained token has no
   scope header and is not refused on that alone. `bench/figures.py` lists any run repo left undeleted in the README.

Exit status: 0 recorded (`ok` or `capped`), 1 the arm failed (recorded as `error`), 2 bad arguments or
unknown arm, 3 guard refused, 4 recorded but the repo could not be deleted.

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
`<arm>.logs/`: `run.log` (what the runner did, with the gh calls), `grade.json`, `transcripts/` (copies of
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
| `counts` | object | the arm's own counts (`ctx.count`, the returned `counts`) |
| `caps` | object | `wall_s`, `cost_usd` in force |
| `repo_deleted` | bool or null | whether the run repo was deleted afterwards |
| `logs` | string | the logs directory next to the file |

`run.validate(doc)` in `bench/run.py` returns the problems with a results document (empty when valid).

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
- **Out-of-the-box defaults.** No `--model` or `--effort` for the front door and no `HARNESS_MODEL_*` /
  `HARNESS_EFFORT_*` in the fleet's environment, so Harness runs its role defaults (#373, #375). The models
  that ran come from the transcripts: the front door's, and every session in the run fleet's `events.jsonl`.
  The pool runs with `HARNESS_USE_POLLER=0`: the host poller is a host-level process that nothing here would stop.
- **Isolation.** The run fleet has its own `HARNESS_HOME` (event log, fleet registry, snapshots), its own state
  dir inside the clone (`<clone>/.harness`), a session prefix made from the run repo's name (`bn` + 5 hex) and a
  scrubbed environment: every `HARNESS_*` and `STATE_DIR` / `RUN_DIR` of the host's fleets is dropped (only
  `HARNESS_USAGE_CMD` and `HARNESS_CLAUDE_CONFIG_DIRS` pass through) and no API key reaches it.
- **Stopping.** Never by pattern. The arm runs `harness stop --state-dir <clone>/.harness`, the engine's own
  stop for exactly that state dir, and the front door it spawned is terminated through `ctx.spawn`. This
  happens however the arm ends: done, error or a cap. `<arm>.logs/fleet.json` names the state dir and the
  stop command, for a run whose runner was killed.
- **Done** = every PRD issue of the run repo is closed. A fleet whose workers are all gone before that is
  restarted with `harness start --recover`, at most 3 times (`counts.fleet_restarts`), then the arm fails.
- **Results.** `counts`: `issues_closed` (closed issues that are not PRDs), `prs_merged`, `workers`,
  `continue_replies`, `fleet_restarts`. Beside them in `<arm>.logs/`: `events.jsonl` (the fleet's event log),
  `stats.json` (`harness stats --json` on it), `fleet.config` (the config the fleet ran with), the front-door
  stream per turn and `launch.txt`. Tokens, $ and the coding / testing split are measured on the transcripts
  like every arm's; the $ cap counts the lanes' transcripts as they appear.

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

The optional arms (`harness-3`, `hx`) are never blocking. `bench/run.py <arm> --optional` runs the arm when
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
bytes and re-running reproduces the committed files exactly. The table has one row per `<arm>.json`: cap
status, wall time with the coding and testing split, tokens (total and input / output / cache read / cache
write), list-price $ and % of the weekly window, hidden tests passed, issues / PRs (`counts.issues_closed`,
`counts.prs_merged`) or commits (`counts.commits`), continue replies (`counts.continue_replies`) and the
models that ran. A **SonarQube** column appears only when some result carries a `sonarqube` object
(`bugs`, `vulnerabilities`, `code_smells`, `maintainability_rating`, `duplicated_lines_density`, `coverage`).
Anything a result lacks renders as `n/a`. The optional arms (`harness-3`, `hx`) get a `skipped: <reason>` row
when they have no results; the reason is read from `bench/results/<run-id>/skipped.json`,
`{"<arm>": "<reason>"}`, or a `status: skipped` `<arm>.json` (above), else `not run`.

## Code quality (optional)

`bench/quality.py <repo-dir>` (#387) scores an arm's final default branch with **SonarQube Community Edition in
Docker, locally**: no account and no token of yours (the server is a throwaway `sonarqube:community` container
and its admin token is generated inside it; `sonarsource/sonar-scanner-cli` scans the repo mounted read-only).
`bench/run.py` runs it on the same fresh clone the hidden tests grade, after grading, and the container and
network are removed afterwards. The first run pulls about 4 GB of images and SonarQube needs a couple of GB of
RAM, so it takes minutes. `BENCH_SONAR_IMAGE` / `BENCH_SONAR_SCANNER_IMAGE` pick other images.

It is **never blocking**. Docker not installed, its daemon down, an image that cannot be pulled, a server that
does not come up, a scan that fails or times out: the arm's results say `quality: "skipped (<reason>)"`, the run's
other results are untouched and the exit status is still 0.

```
bench/quality.py DIR                       # prints the fragment as JSON
bench/quality.py DIR --arm-json X.json     # also merges it into an arm's results file
```

| field | type | meaning |
|---|---|---|
| `quality` | string | `ok`, or `skipped (<reason>)`. Absent in results written before #387 |
| `sonarqube` | object | only with `quality: ok`: `bugs`, `vulnerabilities`, `code_smells` (counts), `maintainability_rating` (`A` to `E`), `duplicated_lines_density` (%), `coverage` (%, null when no test coverage was imported, as here) |

`bench/figures.py` adds a **SonarQube** column when some result carries `sonarqube`, and shows `skipped (<reason>)`
for an arm that has none. The tests drive the scan with a fake `docker` and a fake SonarQube API; a real scan on a
small sample repo is opt-in (`BENCH_QUALITY_REAL=1 python3 test/test_bench_quality.py`) and says so when it is skipped.

A standing audit of the **public Harness repo itself** (SonarQube Cloud, Codacy or DeepSource, free for public
repos) is a separate, owner-side choice: see [docs/online-code-audit.md](../docs/online-code-audit.md). It is not a
gate, and nothing in the fleet depends on it.

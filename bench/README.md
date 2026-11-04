# Benchmark runner

`bench/run.py <arm>` runs one benchmark arm end to end and records one results file for it (PRD #345).
The arms themselves (plain Claude Code, Harness with 1 worker, …) are separate tasks that plug in as
modules; this is the core they all go through. [The plain arm](#plain-arm) is the first.

```
bench/run.py stub                       # run an arm
bench/run.py stub --dry-run             # print the guard decision; create and spend nothing
bench/run.py plain --arm-opt K=V        # options passed to the arm
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
   named on stderr, and the exit status is 4.

Exit status: 0 recorded (`ok` or `capped`), 1 the arm failed (recorded as `error`), 2 bad arguments or
unknown arm, 3 guard refused, 4 recorded but the repo could not be deleted.

## Guard

A run refuses to start when:

- any account is usage-HELD: a `*.hold` file in `<run dir>/usage-holds/` (`--run-dir`, else `$RUN_DIR`,
  else `$STATE_DIR/run`, else `./.harness/run`), the files the fleet's usage watch writes; or
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
the registered transcripts), and whatever the arm wrote to `ctx.logs`.

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

## Figures and the README Benchmark section

`bench/figures.py` writes the README **Benchmark** section (the table and a pointer to the figure) and the
figure `bench/results/benchmark.svg` from `bench/results/`, and nothing else; the section sits between the
`<!-- bench:begin … -->` and `<!-- bench:end -->` markers and is never edited by hand.

```
bench/figures.py                 # the latest run under bench/results/
bench/figures.py --run-id ID     # a specific run
bench/figures.py --check         # write nothing; exit 1 when the README section or figure is stale
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
`{"<arm>": "<reason>"}`, else `not run`.

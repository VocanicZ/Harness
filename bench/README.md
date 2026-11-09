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
bench/run.py plain --fixture large      # the large fixture (below): a 20-page brief and a mid-run requirement change
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

The guard fails closed on numbers it cannot trust (#709). `--expected-usd` and `--cost-cap-usd` take only a finite
number of zero or more: a negative, `nan`, `inf` or a word is a usage error (exit 2). `HARNESS_ONE_STOP_PCT` and
`HARNESS_ONE_RESERVE_PCT` must be a finite percentage from 0 to 100 and `BENCH_MIN_FREE_GB` a finite number of zero or
more; a set but bad value refuses the run (exit 3, or `skipped: bad-setting` for an `--optional` arm). A `nan` or `inf`
usage reading or `$ per 1%` counts as no reading, and a usage reading below 0 or above 100 is refused with its value named (#757).

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
`sonar_duplicated_lines_density`, the arm's own-test coverage `cov_line_pct`, `cov_branch_pct`, `cov_total_pct` (#588) and the `counts` `issues_closed`, `prs_merged`, `commits`,
`continue_replies`, and for the [large fixture](#large-fixture-592) `regressions`, `first_full_pass_s`, `usd_per_passed_test` and
`compactions`, and for the [prompt-cache TTL](#prompt-cache-ttl-615) `cache_write_5m`, `cache_write_1h`, `cache_cost_usd`, `gap_p90_s`, `gaps_over_5m`, and, for every run, the goal loop's `refeeds` and `refeed_tokens` (#616). A metric no run produced is left out; an ungraded run has no `hidden_passed`. An errored
run is listed in `runs` but not counted. `aggregate.cap_hits` is how often the runs hit a cap: `{runs, of, wall, cost}` (#592). The code is `bench/aggregate.py`.

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
| `fuzz_classes`, `fuzz_class_counts` | int, object | optional (#620): the divergences grouped into root-cause [classes](#fuzz-root-cause-classes): their number, and `{"<feature> x <difference>": raw divergences}` per class (the counts add up to `fuzz_divergences`). Absent in results graded before #620 |
| `fuzz_seed`, `fuzz_hash` | int, string | the frozen generator's seed and the SHA-256 of its 1000 planned cases |
| `fuzz_error` | string | only when the fuzz could not run; it never fails a run |
| `review_score`, `review` | number, object | optional (#620): the arm's [scripted blind review](#scripted-blind-review) score out of 10 (mean of the verdicts) and its detail: `rubric`, `rubric_sha`, `brief_sha`, `model`, `seed`, `judges`, `verdicts`, `failed`, per-`criteria` means, the verdict totals in `scores`, `versus` (the other arm) and `mean_gap`. Written by `bench/review.py --write`, never by a run |
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
| `fixture` | string | `pennywise` or `large` (#592); absent in results written before it, which are `pennywise` |
| `usd_per_passed_test` | number | optional (#592): `cost_usd` over the hidden tests that passed; absent when none passed |
| `compactions` | int | optional (#592): how many times a session's context was compacted, from the transcripts (an `isCompactSummary` entry or a `compact_boundary` event); work that outgrew one context window |
| `cache_ttl`, `cache_write_5m`, `cache_write_1h`, `cache_cost_usd`, `turn_gaps` | | optional (#615), see [Prompt-cache TTL](#prompt-cache-ttl-615): the TTL the lanes ran with (`5m` or `1h`), the cache-write tokens at each TTL (`cache_write` is their sum), what the cache cost at list price (writes at their TTL's price plus reads), and `{turns, p50_s, p90_s, max_s, over_5m, over_1h}` of the gaps between one model turn and the next (null with fewer than two turns) |
| `refeeds`, `refeed_tokens` | int | optional (#616): how many times the goal loop's Stop hook sent a session back to work (a `Stop hook feedback:` entry in the transcripts) and the size of those entries in tokens (characters over 4). Run `run-20261106`, whose lanes re-sent the whole task each time, had 15 re-feeds and about 39.6k tokens; the engine-owned hook sends a short reminder, the task only after a compaction, so both fall |
| `change`, `milestones`, `regressions`, `regressed_tests`, `first_full_pass_s` | | the [large fixture's](#large-fixture-592) measures, only for a fixture with milestones |
| `speedup_1_to_3` | object | only `harness-3.json`, and only when the run also holds `harness.json` (#592): `{x, wall_1_s, wall_3_s, capped}`, x = wall time of one worker over three; `capped` when a side hit a cap, so x is not a clean ratio |

`run.validate(doc)` in `bench/run.py` returns the problems with a results document (empty when valid).

## Differential fuzz

The 80 hidden tests are the same for every arm and both arms scored 80 / 80, so they cannot tell the arms apart.
`bench/fuzz.py` (#589) grades the same way for every arm instead: the same random command lines and ledger files go
through the arm and through the reference implementation and the disagreements are counted.

```
bench/fuzz.py --self                  # the reference against itself: 0 divergences
bench/fuzz.py --cmd '["pennywise"]'   # an arm's command line as a JSON argv (default: $PENNYWISE_CMD)
bench/fuzz.py --fixture large --self  # the other fixture's fuzz (#592)
bench/grade.py REPO_DIR --fuzz-only --arm-json bench/results/<run-id>/<arm>.json   # backfill a graded run
```

- **What runs.** 1000 cases (`--cases`, capped at 300 s, `--cap`) go through the arm's `pennywise` and through the
  reference implementation (the benchmark's reference solution, which the hidden tests prove against the brief), each in
  its own empty directory. The cases come from `bench/fixture/fuzzgen.py` (below): every command and option the brief
  describes with good and bad dates, amounts, categories, notes and separators; the exit statuses; `add` refusing and
  creating; ledgers with LF / CRLF / lone CR line endings, no final newline, empty, non-ASCII, a byte order mark or invalid
  UTF-8; a ledger from a file or from `-` (stdin), a missing file or a directory, and a closed standard-output pipe
  (`pennywise list | head -1`).
- **A divergence** is a case where the two differ in standard output, in whether standard error is empty, in the
  exit status, or in the ledger `add` leaves behind (as lines). Where the brief leaves room it is not a difference:
  how many spaces `summary` puts between the name and the total, JSON formatting (compared as data) and whether `export`
  ends its CSV lines in LF or CRLF. With a closed output pipe only "standard error stays empty" and the ledger are
  compared: the brief gives no status for it.
- **Frozen.** The generator has its own PRNG (no `random` module), seed `620`, and the SHA-256 of its case list is
  pinned (`FROZEN_HASH`, and in `test/test_bench_fuzz.py`): `bench/fuzz.py` refuses to run when they disagree. A
  changed generator is a different measurement: update the seed and hash on purpose and re-grade the runs you compare.
  The hash is recorded in every result (`fuzz_hash`). A prefix of the cases is the same cases (`--cases 200`).
- **The reference** is held to the brief on the shapes the brief pins (`test/test_bench_reference.py`): `add` takes
  every argument as typed (a dash-led amount or note is not an option; `-abc` is a bad amount, exit 1), a UTF-8 byte
  order mark is dropped, a line ends at LF, CRLF or a lone CR and nowhere else, and a reader that went away ends the
  output quietly (no traceback, status 0).
- **Where it runs.** `bench/grade.py` runs it after the hidden tests on the same build and adds a `fuzz` object to its
  fragment; `bench/run.py` lifts that into the `fuzz_*` fields. A fuzz that cannot run is `fuzz_error`; the grade and the
  run are unaffected. `BENCH_FUZZ_CASES` / `BENCH_FUZZ_CAP_S` shorten it for tests.

### Blind generators (#620)

A fuzz that was written after seeing an arm's bugs measures that arm's bugs: a fleet tuned to the checklist would score
well without being better. The first generator (#589) was exactly that (its cases were chosen after a review found five bugs
in the Harness arm), so it is gone. **Every fixture's fuzz generator is blind**: it is written from the fixture's brief and
reference implementation only, before any arm's output on that fixture is seen, and says so where it lives:

| fixture | generator | provenance |
|---|---|---|
| `pennywise` | `bench/fixture/fuzzgen.py`, driven by `bench/fuzz.py` | rewritten for #620 by an author given only the brief and the reference, with no access to the old generator, the results or any arm's repo; the file's docstring says so and lists what it deliberately leaves out because the brief does not pin it (form feed or U+2028 as a line end, leading whitespace, `.5` or `1e3` as amounts, `add --`, …) |
| `large` | `bench/fixture-large/fuzz.py` | written for #592 from the brief and the reference, committed before any arm had run on the fixture; `PROVENANCE` in the file |

`test/test_bench_fuzz.py` holds the pennywise generator to this: it imports nothing but `datetime`, reads no file, results or
earlier generator, and states how it was written. **A new fixture's generator must be written the same way**, and its note
committed with it; never add a case because an arm got something wrong, add it because the brief says something the
generator does not yet reach (that is a new frozen hash, so re-grade the runs you compare).

The price of blindness is that a bug the brief does not pin is not found: with the brief alone, a form feed in a note is
not a line end the generator tries. That is the point of the measurement, not a gap in it.

### Fuzz root-cause classes (#620)

Raw divergences mislead: one root cause (a lone CR in the ledger) can make a hundred cases diverge and swamp another that
diverges once. `bench/rootcause.py` groups every divergence into a *class*: one per distinct pair of
**input feature** (what is odd about the case: a lone CR, a byte order mark, a dash-led argument, a closed output pipe,
non-ASCII text, stdin, …) and **observed difference** (the first of exit status, standard output, standard error, the ledger
file, that differed), labelled `"<feature> x <difference>"`. The grouping is a greedy set cover: the pair that explains the most
unexplained divergences becomes a class and takes them, then the next, so a feature that merely co-occurs with the real cause
(a byte order mark that sits in half the lone-CR cases) does not open a second class. A case with no odd feature is labelled by its
command (`command:balance x stdout`). The large fixture's features are the case kind and the command or HTTP route of the step that
differed, plus the same odd bytes in its files and standard input.

The result carries `fuzz_classes` and `fuzz_class_counts` next to the raw count, and the README table shows the class count per
arm. `test/test_bench_rootcause.py` plants two bugs in a copy of the reference, makes 100 cases diverge, and expects 2 classes
(and 100 raw divergences).

## Scripted blind review (#620)

A review by hand cannot be reproduced, so it is not evidence; the blind review is a script, `bench/review.py`.

```
bench/review.py --repo harness=DIR --repo plain=DIR                      # JSON on stdout
bench/review.py --repo harness=DIR --repo plain=DIR --write bench/results/run-ID   # also merge into run-ID/<arm>.json
```

- **Inputs.** A fixed rubric (`bench/review/rubric.json`: conformance to the brief, edge cases and error handling, design and code
  quality, tests, delivery; each 0, 1 or 2, so a score is out of 10), the fixture's brief, and the two final repos. The repos are
  copied without git history and without the files that name the tool that made them (`.git`, `.harness*`, `.claude`, `AGENTS.md`,
  `CLAUDE.md`, build output) and labelled `A` and `B`. Stylistic tells (a long README, many small tests) stay; the judges are told to
  judge what is there, not how much.
- **Judges.** `N = 3` fresh `claude -p` sessions on Opus (`claude-opus-5-5`), on a throwaway isolated config with no skills, plugins
  or MCP servers and only the Read, Glob and Grep tools. Each judge reviews the pair twice, once as A / B and once swapped (the
  order swap cancels a preference for whichever it reads first): 6 verdicts. A verdict that cannot be read is asked for again once;
  fewer than N readable verdicts fails the review and writes nothing.
- **Score.** A repo's score is the mean over its verdicts of the criteria's sum (one decimal), with per-criterion means. It goes into
  the arm's results JSON as `review_score` and `review`, and into the README table. A review that is not in the results JSON is not
  quoted in the README.
- **Seeded.** `--seed` (default 620) fixes which repo is A first and the order of the six passes, so a re-run on the same repos builds
  byte-identical review folders and prompts (`test/test_bench_review.py`). The model's own sampling is not seeded, so the claim is a
  tolerance: re-running the review on the same repos gives scores within ±0.5. `--judge-cmd` (or `$BENCH_REVIEW_CMD`) swaps the
  judge command; the tests use a stub.

## Ship rule (#620)

Cost and time cuts are only wins if quality holds. A fleet change (a prompt, a model mix, a pipeline stage cut) **ships only if,
over at least 5 runs of it against at least 5 runs of the baseline fleet:**

1. the median `fuzz_classes` is **no higher** than the baseline's;
2. **no new class** appears: no label in the change's `fuzz_class_counts` that no baseline run showed;
3. the mean `review_score` has **not dropped by more than 0.5**.

`bench/shiprule.py --baseline DIR... --candidate DIR... [--arm harness]` applies it to the runs' results JSON and exits 0 only when
the change may ship. Fewer than 5 runs on either side, or runs with no fuzz classes or no review, cannot ship: the rule cannot be
applied without them. The root-cause class count, not the raw divergence count, is what is compared, because raw counts swing with
whichever bug the generator reaches most often.

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
  `HARNESS_USAGE_CMD`, `HARNESS_CLAUDE_CONFIG_DIRS` and `HARNESS_CACHE_TTL` pass through) and no API key reaches it.
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

## Large fixture (#592)

The first fixture, `pennywise` (a 4.7 KB brief, about 400 lines of code), fits one session in under 3 minutes. That is exactly the
case where Harness cannot win: its per-issue overhead dominates, and nothing it is for (work bigger than one context window,
recovery, parallel workers) is tested. `bench/fixture-large/` is the case Harness is built for:

```
bench/run.py plain --fixture large                  # every arm takes --fixture; the default is pennywise
bench/run.py harness --fixture large --runs 3
bench/run.py harness-3 --fixture large --optional
bench/grade.py REPO_DIR --fixture large [--phase pre|post] [--tests-only]
bench/fuzz.py --fixture large --self                # the reference against itself: 0 divergences
```

| | |
|---|---|
| **The product** | `tallybook`: double-entry household bookkeeping. A library (money, currencies and rates, dates and periods, a chart of accounts, a ledger of balanced transactions, a plain-text journal format, a query language, categorisation rules, bank-CSV import, budgets, recurring entries, five reports, export), SQLite storage with four schema versions and migrations, a command line, and a small HTTP API. |
| **The brief** | `bench/fixture-large/brief.md`: about 26,000 words (the issue sketched about 20 pages; precise enough to grade exact behaviour, it is longer, around 50 pages) in the voice of a user, a preamble of shared conventions and 16 sections, one per module; it names every class, function, format and error a hidden test relies on. The only thing an arm is given besides the mid-run change below. |
| **The reference** | `bench/fixture-large/reference/`: 6,500 lines (library, storage, command line and API) of stdlib-only Python 3.9. It scores 100% of the hidden tests and 0 fuzz divergences against itself (`test/test_bench_fixture.sh`, `test/test_bench_large_fuzz.py`). |
| **Hidden tests** | `bench/fixture-large/hidden/`: 981 black-box tests (952 before the change request) in 16 modules (`M01` money … `M16` api; the class name starts with the module number). Per-module scores are in `hidden_tests.modules`. |
| **Shape** | `bench/fixture-large/shape.json` (never given to an arm) is the decomposition a planner reaches: 36 issues, 10 deep, up to 8 independent at one depth, so 3 workers can all be busy. `test/test_bench_large.py` keeps it at 30-40 issues, acyclic, at least 4 wide in at least two places, and covering every module. |
| **Fuzz** | `bench/fixture-large/fuzz.py`: 1,000 random cases (see below), frozen like pennywise's: its own PRNG, seed and the SHA-256 of its case list. |

**The mid-run change.** `bench/fixture-large/change.md` is a written change request with three parts: round half to even instead of
half up; a lock date that freezes a period; and a new error body (and status) for the HTTP API. Each touches code that already exists
(a rounding function used by four modules, every mutating path, every error response), which is the point: it costs more
to absorb in a half-built system. The hidden tests exist in two phases: untagged tests hold before and after, `@phase("pre")` tests
only before the change, `@phase("post")` only after. The reference answers both (`TALLYBOOK_PHASE=pre` gives the original behaviour) and is
tested against both. The final grade is post-change: `bench/grade.py --phase post`, the default.

**Milestones and injection (`bench/progress.py`).** While an arm works, every `--progress-poll-secs` (default 300) the runner clones the run
repo's default branch and runs the hidden tests on it (no fuzz): a *milestone*. The change is injected once, when the pre-change tests pass at
50% or more, with the same text for every arm; an arm that is about to stop before that gets it then (`change.trigger: "arm-done"`), so no arm
skips it. How it reaches an arm is how a user would tell it:

- **plain**: typed into the running session. The turn is interrupted when the change is due and the session is resumed with
  `I have changed my mind about some of what I asked for. Here is the change, in writing: …`. Not counted as a continue reply.
- **harness / harness-3**: the front door's session is resumed with `/harness-prd <change>`, the fleet's own door for extending a live PRD.
- **hx**: filed as a second PRD, `hx prd change.md --title "PRD: change request"`, the way the brief was.

**Measures** (in the results JSON, the aggregate and the README table):

| measure | field | how |
|---|---|---|
| wall time to the first full pass | `first_full_pass_s` | the first post-change milestone at which every hidden test passes; the poll interval is its resolution; absent when none did |
| $ per passed hidden test | `usd_per_passed_test` | `cost_usd` over `hidden_tests.passed` |
| regressions | `regressions`, `regressed_tests` | tests that passed at one milestone (the end-of-run grade counts as one) and fail at a later one; counted once each |
| compactions | `compactions` | context compactions in the transcripts (`isCompactSummary` / `compact_boundary`), sub-agents included |
| continue replies | `counts.continue_replies` | the plain arm's reply cap is **50** for this fixture (20 for pennywise); `--arm-opt max_replies=N` overrides |
| 1 to 3 worker speed-up | `speedup_1_to_3` in `harness-3.json` | wall time of `harness` over `harness-3` of the same run id, medians for an aggregate |
| how often an arm hits a cap | `capped`, `aggregate.cap_hits` | the 6 h / $80 caps are unchanged |
| the change | `change` | `{fired, trigger: progress|arm-done, at_s, progress_pct, delivered, delivered_s}` |
| milestones | `milestones`, `<arm>.logs/milestones.json` | `[{t_s, phase, passed, total}]`; the log has every test's outcome |

**Fuzz for the large fixture.** `bench/fixture-large/fuzz.py` (`bench/fuzz.py --fixture large`; blind, see [Blind generators](#blind-generators-620)) runs 1000 frozen cases (seed 592, the case list's
SHA-256 pinned, the same discipline as pennywise's) through the arm and the reference, each in its own directory: 650 offline
`tallybook calc ...` command lines (money, dates, schedules, queries, journals, reports, budgets, rules, bank CSV), 200 scripts of commands
on a fresh book (about 1,700 steps; includes a period lock and a refused operation) and 150 HTTP sessions (about 1,600 requests, good and
bad). Compared: exit status, standard output, whether standard error is empty; for HTTP the status, Content-Type, Allow and the body as
data. Not compared, because the brief leaves it open: the wording of error messages, the text `lock set` / `lock clear` print, the body of
`PUT /lock`. The results carry the same `fuzz_*` fields as pennywise's. Running the reference against itself takes about 5 minutes
(`BENCH_FUZZ_CASES` / `BENCH_FUZZ_CAP_S` shorten it), and the 600 s cap stops it starting new cases after that. `test/test_bench_large_fuzz.py` injects
four realistic bugs into a copy of the reference (half-up rounding, a month-end off by one, 400 for 422, a lock that excludes its own day) and
checks that each is found.

A large run's results live in their own run directory: the default run id is `<UTC timestamp>-large`, so its `plain.json` never overwrites a
pennywise run's. `bench/figures.py` writes a **Large fixture (tallybook)** table of its own under the pennywise one (the latest run of each
fixture; `--run-id` picks one for its fixture) with columns for the measures above and a line for the 1 to 3 worker speed-up.

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
write), list-price $ and % of the weekly window, hidden tests passed, fuzz divergences (`fuzz_divergences` / `fuzz_cases`, #589), fuzz root-cause classes (`fuzz_classes`, #620), the scripted blind review (`review_score`, out of 10, #620), issues / PRs (`counts.issues_closed`,
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
that. The container is removed with its anonymous volumes (`docker rm -f -v`); the images (about 4 GB) stay, so on a
host short of disk run `docker rmi sonarqube:community sonarsource/sonar-scanner-cli` after the run. When the server does exit, the skip reason is the log's first `ERROR` / `MessageException` line, not its tail.

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

## Prompt-cache TTL (#615)

Fleet lanes write their prompt cache with the 5-minute TTL (1.25× the input price) rather than Claude Code's 1-hour one (2×): `FORCE_PROMPT_CACHING_5M=1` in the lane environment (`HARNESS_CACHE_TTL=5m|1h`, default `5m`; `docs/reference.md`). The risk is a gap of over five minutes between two turns, which writes the cache again. A run measures it instead of assuming:

- `cache_write_5m` / `cache_write_1h` split `tokens.cache_write` by the TTL each usage block records, and `cache_cost_usd` is what the cache cost (writes at their TTL's price, plus reads).
- `turn_gaps` is the distribution of the gaps between one model turn and the next in each main session: `p50_s`, `p90_s`, `max_s`, and how many gaps a 5-minute (`over_5m`) and a 1-hour (`over_1h`) cache would not have bridged. `over_5m` is the number of cache re-writes the 5m TTL can cost.
- `cache_ttl` records the setting the run had.

To compare the arms, run the same fixture twice, `HARNESS_CACHE_TTL=5m` and `HARNESS_CACHE_TTL=1h` (it passes through the scrubbed environment), and read `cache_cost_usd`, `cache_write_5m` / `cache_write_1h` and `turn_gaps` of the two results files. `--reproduce` recomputes the split and the cost from the kept transcripts.

### Result of the 5m vs 1h comparison (#637)

Both arms ran the Harness arm on the small fixture (`pennywise`, one run each, 2026-11-08, back to back, same host and account): `HARNESS_CACHE_TTL=5m` in `bench/results/ttl-ab-5m/ttl-ab-5m/harness.json` and `HARNESS_CACHE_TTL=1h` in `bench/results/ttl-ab-1h/ttl-ab-1h/harness.json`. Both are `status: ok`, pass all 80 hidden tests, and their kept transcripts reproduce the committed numbers (`verify_logs`: no mismatch).

| | `5m` | `1h` |
|---|---|---|
| `cache_cost_usd` | **$4.1217** | $4.6114 |
| `cost_usd` (list price, whole run) | $5.7885 | $6.3951 |
| `cache_write_5m` | 656,287 | 208,945 |
| `cache_write_1h` | 0 | 395,719 |
| `tokens.cache_read` | 7,471,658 | 8,526,638 |
| `turn_gaps.turns` | 160 | 189 |
| `turn_gaps.p50_s` / `p90_s` / `max_s` | 7.5 / 21.6 / 610.0 | 7.3 / 18.8 / 3264.1 |
| `turn_gaps.over_5m` | **5** | 3 |
| `turn_gaps.over_1h` | 0 | 0 |
| issues closed / PRs merged by the fleet | 9 / 9 | 12 / 12 |
| wall time | 3532 s | 4390 s |

- **5m is the cheaper setting.** Its cache cost is $0.49 (10.6%) lower, and the whole run $0.61 (9.5%) lower. The default `HARNESS_CACHE_TTL=5m` stays; nothing in this change revisits it.
- **Gaps over five minutes cost little.** The 5m run had 5 gaps over five minutes out of 160 turns, so at most 5 cache re-writes; its longest gap was 610 s (about ten minutes), and nothing came near an hour. A 1h write is priced at 2× the input price against 1.25× for a 5m write, and the 5m run still came out cheaper in total.
- **The 1h run still wrote 208,945 tokens at the 5m TTL**, because not every block in a session carries the forced TTL; only 395,719 of its 604,664 written tokens were 1h writes. So the 1h setting did not price all its writes at 2×, and the gap in `cache_cost_usd` understates what a pure 1h cache would cost.
- **The two runs are not the same workload, so the comparison is a single sample.** The fleet's own planning split the work differently: 12 issues in the 1h run against 9 in the 5m run, which is 189 turns against 160 and 14% more cache reads. Per turn, the cache cost is $0.0258 (5m) against $0.0244 (1h), so the 1h run was 5% cheaper per turn. The $0.49 total difference is therefore partly the larger 1h run. What the data does show is that 5m cost less in total than 1h with at most 5 gap re-writes; it does not show 5m to be cheaper at equal work. Repeating the pair with `--runs` would narrow that.


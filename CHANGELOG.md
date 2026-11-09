# Changelog

Notable changes to Harness. Releases and their full notes: [GitHub Releases](https://github.com/VocanicZ/Harness/releases).

## Unreleased

### `harness stats --since` takes ASCII digits only (#804)

- `parse_since` matched `7d` / `24h` / `30m` with `\d`, which also matches full-width and Arabic-Indic digits, so `--since ７d` and `--since ٣h` were read as 7 days
  and 3 hours and exited 0 (#784 covered the integer options only). They now exit 2 with `bad --since: '７d' (use ASCII digits only)`.
  `test_stats.py` covers both, through `parse_since` and through `harness stats report`.

### `HARNESS_SWARM_LOCAL_MAX_SECS` and `HARNESS_SWARM_SECS_PER_FILE` with a leading zero are read as decimal (#801)

- `scripts/swarm-suite.sh` used both knobs in bash arithmetic without `10#`, so `HARNESS_SWARM_LOCAL_MAX_SECS=08` or `09` printed `value too great for base`,
  skipped the small-suite check and submitted to swarm anyway, `HARNESS_SWARM_SECS_PER_FILE=09` ended with `est: unbound variable` and exit 1, and `060` was read
  as 48. Both are now read as decimal, and a value that is not a non-negative integer (or has more than 6 significant digits) falls back to the default
  (60 and 2) with a one-time warning naming the knob, like the launch knobs. `test_swarm.sh` covers `08`, `09`, `060`, `070`, a negative and an oversized value.

### `harness tier overlap` reads a PR's file name whole when it holds U+2028, U+0085 or a form feed (#802)

- `harness tier overlap` read the files an open PR changes from `gh pr diff --name-only` with `str.splitlines()`, which also breaks a line at U+2028, U+0085
  and form feed, so a PR changing `docs/a<U+2028>b.md` was recorded as `docs/a` and `b.md` and the real name reported the direct path as clear (#781 fixed the
  git side only). The `gh` output is now split on newline only. `test_tier.sh` covers a name with each of the three characters, and that its fragments stay clear.

### An oversized launch or idle-tick knob no longer wraps around and inverts the setting (#800)

- `HARNESS_LAUNCH_BACKOFF`, `HARNESS_LAUNCH_BACKOFF_MAX`, `HARNESS_LAUNCH_FAIL_SECS` and `HARNESS_TEND_IDLE_TICKS` accepted any string of digits and read it with
  `$((10#v))`, so a value of 2^63 or more (`9223372036854775808`, `99999999999999999999`) wrapped to a negative number or 0: a launch that failed a second ago
  was not held back, no launch counted as failed, and the decompose idle guard (#594) was off. A value above 86400 (one day) or with more than 6 significant
  digits now falls back to the default (60, 900, 30, 3) with the same one-time warning as a non-numeric value, so the backoff shift cannot overflow either.
  `test_launch_failed.sh` and `test_lane_tend_tick.sh` cover an oversized value for each knob.

### swarm-suite shards can no longer reach the host's tmux server (#793)

- `scripts/swarm-suite.sh` shards ran `bash test/test_x.sh` as the submitting user with no `TMUX_TMPDIR`, no `unset TMUX`, no `bwrap`: on a fleet host they
  shared its `/tmp/tmux-$UID` server, and on 2026-11-09 the PRD #587 review's shards took the shared tmux server down (the #649 failure, back through the swarm
  path). Each shard now makes a private `TMUX_TMPDIR` (under the condor scratch dir, removed with its tmux server afterwards), unsets `TMUX` / `TMUX_PANE`, and
  runs the test under `bwrap --unshare-pid` with a tmpfs over `/tmp/tmux-<uid>` when the worker has a working `bwrap` (trial run first, otherwise unwrapped with the
  private dir). `HARNESS_SWARM_SANDBOX=off` skips `bwrap`. `test/test_swarm.sh` runs a test that `tmux kill-server`s against a sentinel server standing in for the host's.

### Number arguments take ASCII digits only: `1_1`, `+5` and full-width digits are refused (#784)

- `harness forecast`, `harness stats --issue/--prd`, `harness tier decide` (every count) and `bench/run.py --runs/--workers` parsed numbers with Python's
  `int()`, so `forecast 1_1` forecast issue #11 and `tier decide --criteria ２０` read 20 criteria. A typo became a different number instead of an error.
  Each now exits 2 with `invalid int value: '1_1' (use ASCII digits only)` naming the option. `test_forecast.py`, `test_stats.py`, `test_tier.sh` and
  `test_bench_run.py` cover the three forms.

### A `HARNESS_TEND_TICK` or `HARNESS_TEND_IDLE_TICKS` that is not a number no longer kills the pool worker (#782)

- Both knobs feed bash arithmetic unchecked: `HARNESS_TEND_TICK=abc` stopped the worker on its first step (`abc: unbound variable`), `15s` left the tick
  undefined. A value that is not a non-negative integer (`abc`, `15s`, `-5`, empty) now falls back to the default (15 and 3) with one warning naming
  the knob and value, as `HARNESS_LAUNCH_BACKOFF` does (#759). `0` keeps its meaning. `test/test_lane_tend_tick.sh` covers both knobs.

### `--help` into a closed pipe ends quietly (#783)

- `{ sleep 0.3; harness stats --help; } | true` (also `forecast`, `tier`, `tier decide`, `bench/run.py`) printed `Exception ignored on flushing sys.stdout:
  BrokenPipeError` and exited 120: argparse prints the help and exits inside `parse_args`, before the closed-pipe guard saw it. `pipesafe.run` now catches that
  exit, flushes inside the guard and returns its status, and `stats.py` runs through `pipesafe.run` like the others. Help still prints, a usage error still exits 2.

### The #609 test fixes are confirmed on winsma, and a native Windows Python now finds a fake `gh` (#686)

- The first winsma run of the fake-`gh` / poller / prompt / bench tests found 17 of 20 files red. Causes fixed: a Python `subprocess.run(["gh", …])`
  never started a script first on PATH, so the real `gh.exe` answered (`portable.resolve_argv`, now used by `issuelib.py`, `forecast.py` and every `bench/`
  call of `gh`, `git`, `claude`, `harness` and `docker`; it runs a bash/python script by its shebang and finds `.cmd` shims in PATH order); `render` no longer
  lets Git Bash rewrite a `KEY=/path` value into `KEY=C:\path`; `bench/armlib.py` `engine_skills` kept a trailing backslash on Windows (so only `harness` was
  found); a Windows command line is split without eating its backslashes. The suite stage downloads `jq` (pinned by sha256) for the tests that run a `gh -q` filter.
- Test-side only: LF fixtures (`test_bench_figures`, `test_one_run` pins `core.autocrlf=false`), POSIX-only calls (`os.killpg`, `flock`, `grep $'\r'`) and
  path spellings in `test_python_lf`, `test_stats`, `test_drive`, `test_bench_*`.

### The bench usage guard refuses a usage reading outside 0-100 (#757)

- A usage command reporting `-5`% was accepted and the guard did its arithmetic with it (`-5% + 16% ...`), as it would
  with `140`%. A weekly reading below 0 or above 100 is now refused like an unparseable one (exit 3, or
  `skipped: no-usage-reading` for an `--optional` arm), and the guard names it: `usage reading -5 for acct seven_day is
  outside 0-100%`. `test/test_bench_run.py` covers a negative and an over-100 reading.

### `harness stats` and the bench usage guard escape line separators and control characters in names (#756)

- A U+2028 (or U+2029, U+0085, a form feed or another control character) inside a fleet prefix, a repo name or an account
  name was printed raw, so a terminal or log viewer showed one record on two lines (`fleet bn4e<U+2028>53c: ...`). The
  `harness stats` text output (fleet, PRD, role and issue views, and `stats mismatches`) and the `bench/run.py` guard
  message now write them as `\u2028`, `\u000c` and so on, as `--json` already did.

### `HARNESS_LAUNCH_BACKOFF` and `HARNESS_LAUNCH_BACKOFF_MAX` are checked to be numbers (#759)

- A value such as `30s`, `abc`, `-1` or `1.5` gave a bash arithmetic error or a wrong backoff after a failed launch. Each knob
  must now be a non-negative integer; anything else falls back to its default (60 and 900) with a one-time warning in the
  log, and the backoff still applies.

### Claude 3 Haiku and 3.5 Haiku are priced at their own list prices (#751)

- `price()` skipped the legacy split for Haiku, so `claude-3-5-haiku-20241022` and `claude-3-haiku` were priced at the
  current Haiku row ($1 / $5), overstating their spend in `harness stats` and the forecast. Claude 3.5 Haiku now has its
  own row ($0.80 / $4) and Claude 3 Haiku too ($0.25 / $1.25); Haiku 4.x and later keep the current row. Cache writes and
  reads follow the table's usual 1.25x / 2x / 0.1x multipliers of the input price.

### `tier.toml` thresholds are checked: a string no longer gives a traceback, and nan, inf, negative and zero values are errors (#749)

- `max_criteria = "8"` printed a `TypeError` traceback, while `nan` silently turned that check off and `-5`, `inf` or
  `max_subsystems = 0` were accepted without a word. Every `tier.toml` threshold must now be a finite number: the limits
  in `[direct]` and `[fleet]` whole numbers of 1 or more, the time and price figures in `[estimate]` 0 or more. A string,
  a boolean, `nan`, `inf`, a negative, a fraction for a count, a zero limit and a section that is not a table each give one
  line naming the file and the key (`tier.toml: direct.max_criteria = nan is not a finite number`) and exit 2, like the
  existing parse errors, for `decide` and `thresholds` alike.

### `HARNESS_ONE_USD_PER_PCT=inf` (or a tiny value) no longer makes the forecast read 0% and the one gate approve (#746)

- `inf` priced every window at 0.00%, put `Infinity` (not valid JSON) in `harness forecast --json` and let `harness one gate`
  approve with "p80 0% (fallback)". The setting must now be a finite number of at least `0.01` $ per 1%; `inf`, `nan`, `0`,
  a negative, a tiny value such as `1e-300` and non-numeric text are all invalid. An invalid value is ignored, warned about on
  stderr by `harness forecast`, recorded as `calibration.invalid` in its JSON, and named as `HARNESS_ONE_USD_PER_PCT=<value>
  invalid` by the forecast text, the one gate and the `bench/run.py` guard, which used to call a bad value "unset".

### An idle lane whose goal stays pending no longer calls gh every 15s (#721)

- Since #594 the short tend tick made one live `gh issue view` per idle lane per tick while the goal stayed pending
  (self-park grace, an auto-merge waiting, a usage-limit menu): about 240 calls an hour per lane, enough for several lanes
  on one account to hit the GitHub rate limit. The first check after the pane goes idle is still on the first idle tick, so
  `goal_satisfied` still lands within 30s. Each check that finds the goal pending now doubles the wait before the next one,
  up to `HARNESS_POLL`: about 6 calls in the first 10 idle minutes instead of 40. A busy pane resets the backoff.

### A lane that ran but ended within 30s of launch keeps its spend in `harness stats` (#720)

- The reap logged `launch_failed` for any lane gone under 30s after launch, before the session's `session_end` was
  written, and `harness stats` then dropped the whole session, tokens included. A lane that reports usage ran, whatever its
  age: stats keeps it with its tokens and cost, and the reap no longer logs `launch_failed` or backs the lane off for it. A
  launch that really failed (no session, no usage) is still logged as `launch_failed`, backed off and left out of the count.

### The pool no longer re-claims an issue that just closed, and a goal met at launch is not a failed launch (#730)

- After a lane's PR merged and closed its issue, dispatch (which reads the lagging board snapshot) could claim the closed issue
  again, build or reuse a worktree, stamp `agent-working` and launch a session that the first goal check killed 2-3 s later. The reap
  logged `launch_failed, backing off`, and each such session raised a false CHURN alert. `prepare_impl` now makes its one
  `gh issue view` first (it asks for `state` too, so there is still one call per lane switch) and, when the issue is closed, adds no
  worktree, no label and no session: it drops any pre-built worktree (`prebuilt_dropped`), emits `launch_skipped reason=issue_closed`
  and releases the claim. A closed issue is then held out of `claim_lane` and the pre-build for `HARNESS_CLOSED_LIVE_SECS`
  (default `HARNESS_PRIORITY_POLL` + 600) so the next tick does not read it again, and the pre-build checks the live state before it
  builds. A failed read keeps the old behaviour. The reap of a closed issue also removes its stale `ready-for-agent` / `agent-working`.
- A session ended by a `DONE` goal check is marked, so its quick reap logs no `launch_failed` and arms no backoff, and its
  `session_end` carries `goal_met=1`. `churn.py` treats `goal_met` and `goal_satisfied` sessions as ended on purpose.

### `bench/run.py --run-id` accepts only one short, safe path component (#717)

- `--run-id=.` wrote the results into the `--results-dir` root itself, and `--run-id=-x`, `--run-id=--flag` and a 5000-character
  id exited 0. A run id now matches `[A-Za-z0-9._-]`, is at most 128 characters, does not start with a dash and is not `.` or
  `..` (nor contains `..`, as since #674). Anything else is a usage error, exit 2. Ids such as `run-20261106` work as before.

### `harness stats` and `forecast.py` validate `-R` / `--repo` the same way (#716)

- `harness stats --repo=-x` exited 0 with "no events in range", and `forecast.py -R owner/-x` was accepted. Both now share
  one check (`stats.repo_arg`): each half of `owner/name` must be a valid GitHub name, which cannot start with a dash. Anything
  else is a usage error, exit 2. `tier.py overlap -R` uses the same pattern.

### `forecast.py`, `tier.py` and `bench/run.py` end quietly when the reader closes the pipe (#713)

- `harness forecast … | true`, `harness tier decide … | true`, `tier.py thresholds | true` and `bench/run.py … --dry-run | true`
  printed `Exception ignored on flushing sys.stdout: BrokenPipeError` on stderr and exited 120 (`| head -1` only passed
  because the output fit in the pipe buffer). All three now run through one shared helper, `scripts/pipesafe.py`, the same
  way `harness stats` already did (#671): a closed stdout ends the command with no message and the status `main` returned.

### `harness stats` prices 1-hour cache writes at the 1-hour rate (#710)

- `usage_cost` priced every folded `cache_create` token at the 5-minute write rate (1.25× input), so a session that wrote
  at the 1-hour TTL (2× input) came out low: `harness stats --by-role --since 2020-01-01` showed about $5.07 for
  `run-20261106` while the bench recompute of the same transcripts gave $6.86. The folded usage now carries
  `cache_create_1h`, the 1-hour part of `cache_create` (sub-agent transcripts included), and `usage_cost` prices it at the
  1-hour rate and the rest at the 5-minute rate. An event without the key (logged before this, a headless lane's `result`
  usage, another CLI) still prices all its cache writes at the 5-minute rate. Fleet sessions of `run-20261106` now price
  within 1% of the bench recompute; the rest of the bench's $6.86 (about $0.70) is the front-door session, the operator's own
  claude outside the fleet, which never logged a launch or session_end. `test/test_stats.py` pins it.

### The bench usage guard refuses negative, `nan` and `inf` budgets instead of passing them (#709)

- The guard only refused when `total > stop`, which is never true for `nan`, and a negative estimate lowers the total, so
  `--expected-usd -50`, `--expected-usd nan`, `--cost-cap-usd nan` (the cost cap then never fired) and
  `HARNESS_ONE_STOP_PCT=nan` all passed with exit 0 at a 97% window. Now `--expected-usd` and `--cost-cap-usd` accept only a
  finite number of zero or more (anything else is a usage error, exit 2), and a set but non-finite or out-of-range
  `HARNESS_ONE_STOP_PCT`, `HARNESS_ONE_RESERVE_PCT` or `BENCH_MIN_FREE_GB` refuses the run with a message naming it
  (cause `bad-setting`). A `nan`/`inf` usage reading or `$ per 1%` no longer counts.

### `harness tier overlap` no longer says "the direct path is clear" when it could not check (#708)

- A rate limit, an auth failure, a network error or a bad `-R` made every `gh` and `git` call in `overlap` look like "no
  files", so it printed the "clear" message with exit 0 (`--json`: `"overlap": false`) at exactly the moment it could not
  look. Now a failing `gh pr list`, `gh issue list`, `gh pr diff`, `git worktree list`, `git diff` or `git status` makes
  `overlap` print `could not check for overlap` and the failed command on stderr and exit 3 (not 0 for clear, not 1 for an
  overlap); `--json` prints `{"overlap": null, "hits": [], "error": …}`. An `agent-working` issue whose branch does not exist
  yet still owns no files. A `-R` value that is not `owner/name` (`-x`, `=-x`, `a/`, …) is a usage error, exit 2.
  `test/test_tier.sh` covers each failing call, in text and `--json`, with a stub `gh` that fails.

### `harness stats` no longer drops an events.jsonl line that starts with a UTF-8 BOM (#672)

- An event log saved with a leading BOM lost its first event without a word: the report showed 1000 output tokens instead of
  2000. The reader now strips a BOM (as it already folded CRLF and a lone CR), and a line that still cannot be parsed is
  counted: `harness stats` prints `skipped N event line(s) that could not be parsed; totals exclude them` on stderr, so the
  report on stdout is unchanged. `test/test_stats.py` covers both.

### Every call of the tmux backend targets the server the lane was created on (#670)

- #596 dropped the caller's `TMUX` for `tmux_sess_start` only. A worker holding a live `TMUX` on a server other than the
  default one under `TMUX_TMPDIR` (`tmux -L` / `-S`, or a different `TMUX_TMPDIR`) therefore created its lane on the default
  server and then looked for, typed into and killed it on its own: the lane was treated as dead, logged `launch_failed`, and
  its session was left running. Now every call in `scripts/session/tmux.sh` (find, list, type, capture, pane pid, kill, sweep,
  attach) runs with `TMUX` dropped, so the server is always the default one under `TMUX_TMPDIR`. A stale `TMUX` is ignored the
  same way; a start that leaves no session still fails loudly and logs `launch_failed`. `test/test_tmux_one_server.sh` covers
  it with two private tmux servers.

### Lean PLAN lanes can resolve every skill `writing-plans` requires (#669)

- `skill/writing-plans` named `superpowers:using-git-worktrees`, `superpowers:subagent-driven-development` and
  `superpowers:executing-plans`. A lean lane launches with `--setting-sources project,local`, so the user-scope
  superpowers plugin never loaded and those names dangled. The skill now names only `subagent-task-tree`, which the
  engine supplies, or no skill. `test/test_cli_lean.sh` walks every skill the prompts name and the skills those
  require, and fails on a name a lean lane cannot resolve. `claude_prereqs` (`harness setup --install`) no longer
  installs the `superpowers` plugin, since no lane can see it and nothing the prompts name needs it.

### With the poller off, `goal_satisfied` no longer waits for the 300s full step (#668)

- In `bench/results/ttl-ab-5m` (no poller) every `goal_satisfied` landed on the 300s full-step grid, 120–221s after the
  lane's last message, and the short tick never ended a lane early. Cause: the short tick read an idle pane as busy because
  its footer says `← 1 agent`. Claude Code draws that on every pane, a fresh session with nothing typed included, whether a
  sub-agent runs or not (real captures: `test/fixtures/cli/claude/idle.txt`, `idle-subagent-running.txt`,
  `idle-subagent-done.txt`), so the busy check always matched. The test hid it by deleting that line from `idle.txt`. A
  running sub-agent is now read from the `✻ Waiting for N background agent to finish` line above the input box, or the `◯`
  agent row under the footer; a finished agent's old `Waiting` line in the scrollback does not count.
- `<session>.idleticks` is removed when a lane is reaped, ended on its goal, found dead by the watchdog, or launched, so a
  later session with the same name no longer inherits the idle count and passes the `DECOMPOSE` idle guard early.

### Two takers of one lock no longer both get it on a Windows host, so two pool workers no longer take the same issue (#684)

- On Git Bash the lock is a `mkdir`'d directory (`scripts/portable.sh`). A taker whose `mkdir` failed asked `_mlock_stale` about the
  holder's lock, but if the holder had released in the meantime the directory was gone, and a missing directory counted as stale.
  The taker then "stole" it: it moved aside whatever lock stood there, which by then was the next taker's brand-new one (no owner
  file yet, so indistinguishable from the one judged stale), deleted it and took its place. Two takers were inside `pool.lock`
  together, both claimed the same issue, and the second claim file overwrote the first (`test_pool_lanes.sh` § 1c failed about 1
  run in 14 on winsma). A lock that is gone is now simply taken by `mkdir`; a lock moved aside for a steal is judged stale again
  and put back unless it is; and a taker whose owner file cannot be written (its directory was moved away) no longer believes it
  holds the lock. The liveness checks (`is_claimed`'s `kill -0`, the owner's `proc_alive`) were not at fault.
  `test/test_portable.sh` covers both races.
- `start_lane` also rewrote a lane's claim file (to add the pane pid) without `pool.lock`. A rename over an existing file is not
  atomic on Windows (a reader polling `[[ -f ]]` saw it missing in 6 of 1730 reads on winsma), so a claimer could read the gap as
  "no claim". The rewrite now holds `pool.lock`, as `claim_lane` and `adopt_lanes` already did (`test_pool_lanes.sh` § 1c2).

### The short tend tick no longer waits for the poller's snapshot to see a closed issue (#667)

- On a fleet with the poller on, the #594 short tick checked an issue lane's goal against the poller's snapshot, which is
  refreshed only every `HARNESS_PRIORITY_POLL` (60s by default, 600s on some fleets), so `goal_satisfied` still lagged a closed
  issue by up to that long (+637s and +781s in the field). The gated short-tick check now reads that one issue from `gh`
  (`issuelib check … --live`: a single `gh issue view`). It still runs only while the pane is idle, so a busy lane costs no `gh`
  call; the full tend keeps reading the snapshot. `test/test_lane_tend_tick.sh` § 7 drives the real `check_session_goal` and
  `issuelib check` over a stale snapshot.

### A stale usage reading is no longer taken for the current one, and the fleets on a host share their readings (#658)

- A usage reading older than `HARNESS_USAGE_STALE_MIN` minutes (default `HARNESS_ONE_STALE_MIN`, 30; `0` = never) is stale. Below
  `HARNESS_USAGE_CHECKPOINT_PCT` it opens no hold: `usage_watch` logs `usage: <account> <window> reading is stale (…)` once per stale
  episode and records a `usage_stale` event, and the limit-message checkpoint is unchanged. At or above the threshold it still holds,
  and a reading gone stale never releases a hold: only the reset, or a fresh reading of the held window below the threshold, does.
  `harness status` marks it `STALE <age> old`.
- The claude adapter now also reads the status-line drops of every fleet in `$HARNESS_FLEETS_DIR` (`<run_dir>/usage/*.json`), the newest
  `at` per account window winning, so a fleet whose own panes stopped drawing the status line (hzhn held on a 30-hour-old 70% while a
  sibling fleet read 91% of the same account) still sees the account's usage. `harness one` reports the age of the reading that won.

### A lean Claude lane no longer stops at the Bypass Permissions and CLAUDE.md-imports dialogs, and a supervisor-visible dialog is a stuck lane (#660)

- Since lean lanes (#595) a Claude lane on the tmux backend could launch into two dialogs nothing answered. `--setting-sources project,local`
  hides the user `settings.json` that holds `skipDangerousModePermissionPrompt`, so every launch asked "Bypass Permissions mode" (default
  `No, exit`). And the operator's global `CLAUDE.md` is then a project memory file whose `@` import lies outside the repository, so the first
  launch into a repository with no recorded answer asked "Allow external CLAUDE.md file imports?".
- `claude_bypass` now also writes `skipDangerousModePermissionPrompt: true` into the worktree's `.claude/settings.local.json`
  (`claude_bypassed` checks for it). The workspace pre-accept sets `hasClaudeMdExternalIncludesWarningShown` next to
  `hasTrustDialogAccepted`, for the lane directory and, for a linked worktree, for its main checkout, where Claude Code keeps the answer.
  `hasClaudeMdExternalIncludesApproved` is never set true (imports stay disabled) and an answer already recorded is kept.
- `harness supervise` no longer ignores a pane a dialog owns. Once it is quiet past the nudge threshold it logs `dialog: <session> has sat
  on a CLI dialog …` and records a `dialog_stuck` event, never types into the pane, and at the kill threshold checkpoints and ends the
  session through the frozen-session path so the pool re-dispatches it.
- The self-park nudge (#417) sends nothing into a dialog-owned pane, and ignores a lane launched less than `HARNESS_SELFPARK_LAUNCH_GRACE_S`
  (600) ago: a resumed paused issue still carries `agent-paused` until its lane removes it.

### A stale usage reading no longer releases a usage hold, keeps one from opening, or lets `harness one gate` approve what `phase` checkpoints (#659)

- The claude adapter's readings are status-line drops, and they stop updating once every session on the account is checkpointed. `usage_watch`
  released a hold on any below-threshold reading, so a 27-hour-old 70% reading deleted a correct hold (the real value was 91%) and the pool
  resumed claims in a window that had not reset; the same reading also kept a hold from opening. `cli_limit_usage` lines now carry an optional
  5th column, the epoch the reading was taken (absent = a live query), and a hold is released only when its window's `resets_at` has passed
  or a reading of the held window taken after the hold opened is below `HARNESS_USAGE_CHECKPOINT_PCT`. A stale claude reading below the
  threshold is brought up by the account's transcript spend since it (cached, `HARNESS_USAGE_SPEND_TTL`) before it is compared.
- `harness one gate` now counts the spend since each reading, as `harness one phase` does, so the two no longer answer differently on the same
  data (the incident: gate APPROVE, phase CHECKPOINT after $523 of spend). Where the spend cannot be counted, the stale pad still applies.

### The fake-`gh`, poller, prompt and bench tests run green on native Windows: Python writes LF, git's `C:/` paths are read, Python finds Git's bash (#609)

- The first full-suite run on the Windows check host (#492) had 96 red files; the class this fixes is a tool whose output the engine
  or a test reads and gets wrong. Three of the causes were Harness bugs, the rest were Linux-only assumptions in tests.
- **A native Windows Python writes `\n` as CRLF**, so every `$(python3 …)` in the engine read a stray CR and `render` produced lane
  prompts with CRLF line endings (a multi-line phrase of a prompt no longer matched). The `python3` shim `install.sh` writes now puts a
  `sitecustomize.py` (new `pylf/` directory beside it, written by `python_lf_dir` and removed by `harness uninstall`) on `PYTHONPATH` that
  sets stdout and stderr to LF. `harness update` rewrites it with the shim. The Windows suite stage does the same for its venv python.
- **`git.exe` answers `C:/…`, bash compares `/c/…`.** `remove_session_worktrees` never matched a worktree git listed, so a session's
  `worktree-*` branch stayed; `sweep_orphan_bug_worktrees` read `--git-common-dir` as a relative path and removed the dead lane's
  worktree without its local `issue/<n>` branch. The new `posix_path` (portable.sh, `cygpath -u`; the identity on Linux) fixes both.
- **A bare `bash` from native Python is WSL's.** `CreateProcess` looks in `System32` before `PATH`, so `bench/run.py` (the usage
  reading its guard needs: `bench guard: REFUSED: no weekly usage reading`) and `session_backend.lane_rows_argv` ran WSL's launcher. They
  use `portable.bash_exe()` now (`HARNESS_BASH`, else the first `bash` on `PATH`, as `portable.winpid_of` already did).
- Tests: the `jq` that a fake `gh` runs ends its lines CRLF where `gh -q` does not (`test_gauntlet.sh`, `test_security_audit.sh`,
  `test_handoff.sh` strip it); `test_stats.sh`'s CRLF python no longer starts through `env -i`, which a native Windows python will not
  survive; `test_fleet_smoke.sh` pins `SMOKE_PLATFORM=posix` for its tmux flows. The suite stage installs `setuptools` into its venv
  (the bench grader's `pip install --no-build-isolation` needs it). New: `test_python_lf.sh`.
  `test_bench_harness.py`'s MCP-isolation case no longer races the arm: the fake front door waits to be terminated at its init
  instead of running `harness init` first (it failed about one run in two on a loaded host, on main too).

### The Windows test suite no longer asserts POSIX-only mechanisms on a Windows host (#607)

- The first full-suite run on winsma (#492) left 96 of 168 test files red. The ones in this change asserted how Linux does something
  — a `flock` fd inherited by a child, a systemd unit, an `apt-get` hint, procps `ps -o`, a tmux pane — where Windows has a counterpart that
  another test covers, or read a Windows path or pid wrongly. Each now runs the branch the host runs, or is fixed where the code was wrong.
- `fleetview.run_cmd` resolves the program through `PATH` and `PATHEXT` on native Windows. `CreateProcess` searched System32 first, so the
  bare `bash` of the headless session probe was WSL's, and it appended only `.exe`, so a `gh.cmd` or `tmux.cmd` shim was never found.
- Lock tests take their locks through `lock_try` / `lock_acquire` (`flock` on Linux, the owned `mkdir` lock on Windows); the cells that
  prove the POSIX implementation itself (`flock` fd inheritance, `fcntl`, `os.kill(pid, 0)`) skip on a real Windows host through
  `skip_posix_branch` and still run on Linux. The package-manager offers and the systemd unit run with the POSIX branch forced
  (`test_install_prereqs.sh`, `test_web_install.sh`); `test_web_install.sh` gains a Windows section for the scheduled task.
- Python tests record pids through `test/pidfix.py` (a fake `/proc` that maps a native pid to itself), so a fleet reads a live process as live.
  The portable-use guard keys its allowlist on forward slashes on every OS.
- `fleet_slugs_of` compares an owner directory and a registered project in their native spelling (the registry holds `C:/x` where a session
  names `/c/x`), and the registry and poller readers in `lib.sh` write `\n`, not the `\r\n` a native Windows Python defaults to, so a
  carriage return no longer ends up inside the last field a `read` gets (`harness status` printed `(acme/gadget\r)`).
- `test/run.sh` takes `# harness-test-timeout-windows: <seconds>` in a test file: on a Windows host with a cap set, that is its cap when
  longer. `test_pool_lanes.sh` takes about two minutes on Linux and sixteen under Git Bash.
- The release fixture serves `file:///C:/...` to a native `curl`; `test_windows_update.sh` runs with real symlinks and the engine's
  `C:/` spelling on a Windows host, and `test_doctor.sh`, `test_install.sh`, `test_status*.sh`, `test_prefix_guard.sh`, `test_portable.*`
  and the web tests give a Windows host the fixtures it needs (`.cmd` shims for their `tmux` / `gh` stubs, native registry paths, the
  headless backend).

### Windows suite: the headless runner tests start their runner with the real interpreter, so they reach its first state (#606)

- Cause: on winsma `python3` is a venv `python.exe`, and a Windows venv's `python.exe` is a launcher that starts the base interpreter as a
  child. The runner tests waited for `runner_pid == Popen.pid`, but the runner's own `os.getpid()` is the child's, so the first state
  never matched and every `test_*_headless.py` timed out ("timed out waiting for the runner's first state"). A `proc.kill()` ended only
  the launcher, which also left the runner behind.
- The tests now start a runner with `test/hlproc.py`'s `RUNNER_PY` (the base interpreter on Windows, `sys.executable` elsewhere), probe a
  process with `OpenProcess` instead of `os.kill(pid, 0)` (which ends a process on Windows), and end one with `taskkill /T /F`. The
  SIGTERM test uses the stop file on Windows, where no signal reaches a process from outside.

### While a lane runs, the pool builds the next claimable issue's worktree ahead, so a lane switch skips the `worktree add` and the hook (#644)

- The last item of #618: a lane switch still paid `git worktree add`, the worktree hook and the `ensure_*` setup after the claim, about 10 s
  of the 10-15 s switch in run-20261106. While a lane runs, the chores now build the worktree of the next claimable issue
  (`prebuild_tick`, once per full step, one worktree at a time); when that issue is claimed, `prepare_impl` reuses it, moves its branch to
  today's `origin/<default branch>` and only renders the task file.
- The issue is not labelled `agent-working` while its worktree is pre-built, and holds no claim: the label is still stamped when the lane
  starts (#416). A marker file in `run/prebuilt/` says whose the worktree is. `reap_team` keeps off a worktree that has one, and
  `busy_issues_for` does not count it, so the issue stays claimable. The marker is `building` while the add runs, which holds the issue
  back from every claim.
- The worktree is removed (with its local branch and marker) as soon as its issue is no longer claimable: claimed by someone else
  (`agent-working`), closed, blocked, or backed off after a failed launch. The check-then-remove runs under `run/pool.lock`, where claims
  are written, so a claim that lands first keeps the worktree. A dead builder's marker, or a marker whose worktree is gone, is swept. A
  failed add is not retried for `HARNESS_PREBUILD_RETRY_SECS` (600). `HARNESS_PREBUILD=0` turns it off.

### Test runs can no longer reach the host's shared tmux server; a roll starts a fleet with its own configured CLI binary (#649)

- Three times on 2026-11-07 a lane's test run killed the host's default tmux server (`/tmp/tmux-$UID/default`) and took every other lane
  with it. tmux does not fail when `$TMUX_TMPDIR` names a directory that no longer exists: it silently uses `/tmp/tmux-$UID/`. A test that
  wiped the private home it had pinned (`test_supervise_autoupdate.sh`'s `fresh_host` removed `$HOME_PIN/tmux`) then ran its `tmux
  kill-server` at the host's server, and still passed.
- The suite now puts a fail-closed `tmux` guard (`test/guard/tmux`) first on `PATH` (`run.sh`, and `pin_host_home` for a direct `bash
  test_foo.sh`). It refuses any tmux call, with exit 97 and a stderr line naming the test, while `TMUX_TMPDIR` is unset, empty, missing or
  `/tmp`, or `TMUX` names a socket outside it; otherwise it runs the next `tmux` on `PATH`. `test_supervise_autoupdate.sh` and
  `test_fleet_migrate.sh` keep their private tmux dir outside the host root they wipe. `test_tmux_fallback_guard.sh` covers the guard and a
  planted wiping test that must fail under `run.sh`.
- `fleet_roll` (and so `harness update`, `harness start`'s roll and supervise's auto-update) starts a fleet with the fleet config that
  `lib.sh` and the CLI adapters export dropped from the environment. Config lines are `: "${VAR:=…}"`, so an inherited `HARNESS_CLAUDE_BIN=claude`
  beat the fleet's own configured wrapper: every priority and bug lane on the host launched bare `claude`, outside the host's lane sandbox. Path
  seams (`*_DIR`, `*_HOME`, `*_FILE`) and `HARNESS_START_*` still pass. `test_fleet_roll_env.sh` covers every adapter's `_BIN`/`_FLAGS`/`_TIMEOUT`,
  `HARNESS_CLI` and `HARNESS_SESSION_BACKEND`.
- `tmp_kill_rooted` (the sweep behind every test's `tmp_cleanup`) now ignores a tracked root that is shallow, is `$HOME`, or contains `$HOME` or
  the host's `~/.harness`, so a stray broad root can never stop a user's live workers and lanes. `test_tmp_kill_rooted_scope.sh` covers it.

### `start`, `start --recover`, `fleet_roll` and `status` look at the process table, not only the pid files: no second worker beside a live one (#647)

- A fleet ran 27 pool/priority workers instead of 3 for about 40 hours: 24 orphan v0.5.0 workers (8 full sets) beside the 3 official v0.9.0
  ones. A lane running a test had written stand-in pid files into the live `run/`; the manager's `start --recover` then cleared the pid
  files as stale and `pool.sh` / `priority.sh`, seeing no live pid, launched a full new set while the real workers kept running, named by
  nothing. Neither `start`, `fleet_roll` (whose "all live workers current" read only `run/*.pid`) nor `harness status` ever looked at the
  workers themselves again, and the extra claimers and reapers are a likely cause of races such as #643.
- `harness start` (also `--recover`, `harness resume` and the `fleet_roll` relaunch) now scans for live top-level `pool-worker.sh` /
  `priority-worker.sh` processes of its own `STATE_DIR` (by realpath) before it launches a slot. One that no pid file names is adopted into
  the slot's pid file when it is on the current engine, otherwise stopped with TERM; the choice is printed with the pid. A worker holding a
  bug claim is never killed: its slot is not launched and the pid is printed. A worker in a slot the pool does not launch is stopped, so a
  start leaves at most `POOL` + 1 workers.
- `fleet_roll` finds such untracked workers too and stops them under `run/pool.lock`, deferring any with a bug claim, logging `ACT roll:
  stopped untracked …`; a dry run only logs. `harness status` prints a `⚠ duplicate workers` warning listing the pids and slots when more
  workers are running than the pid files name, or a slot has two.
- A worker's own `$(…)` and background subshell forks (same command line and environment), another fleet's workers and a `grep
  pool-worker.sh` are never counted, adopted or killed. Without a `/proc` (macOS) nothing is found and behaviour is as before.

### A reap can no longer delete a lane's worktree 5 s before its session starts; adoption validates the lane; a leftover old-loop worker is stopped (#643)

- On a fleet running two engine versions, a v0.5.0 worker left over from before a roll launched impl lanes without a lane
  claim. A v0.9.0 worker's reap deleted the worktree of #618 between the old loop's `git worktree add` and its launch, and the
  session started in an empty directory, sat idle for 2.5 h holding a pool slot, and was then adopted. Four changes close it:
  the reap spares a claimless worktree younger than the launch grace (`HARNESS_LAUNCH_FAIL_SECS`, 30 s) that never had a
  session, and re-checks the claim under `run/pool.lock` before it removes anything; `spawn_impl` no longer launches into a
  worktree that is not a git worktree or has no task file; adoption kills (and logs, as a `lane_adopt_rejected` event) a live
  impl session whose worktree is not on `issue/<N>` with its `.harness-task.md`, so the issue is re-dispatched; and
  `fleet_roll` (so `harness start`, `harness update` and supervise auto-update) stops a live worker of the retired unit-claim
  loop that no pid file names, logging a `WARN` instead when it cannot verify the process. The worker log warns once per pid
  while such a worker is alive.

### Every agent commit credits Harness: a `Co-authored-by` trailer from a `lane-bin/git` wrapper (#642)

- A commit a Harness agent session makes now ends with `Co-authored-by: Harness <353635118+vocanicz-harness[bot]@users.noreply.github.com>`
  (the `vocanicz-harness[bot]` GitHub App), the way Claude Code credits Claude. GitHub shows the Harness avatar on those commits and lists it
  under the repo's contributors; a squash merge keeps the trailer in the default message. `scripts/lane-bin/git` adds `--trailer` to
  `git commit` (skipping global options such as `-C <dir>` and `-c k=v` to find the subcommand) and passes every other command through
  untouched; an amend or a message that already ends with the trailer does not get it twice. It works for every CLI the fleet runs and does
  not depend on prompt wording; Claude Code's own `Co-Authored-By: Claude` line stays beside it.
- `scripts/lane-bin` is now first on the `PATH` of **every** lane (impl, bug-fix, resume, plan, inject), not only a submodule repo's;
  `lane-bin/gh` still runs the gitlink guard only where there is a `.gitmodules`, so `gh` behaves as before elsewhere.
- Opt out with `HARNESS_COAUTHOR=` (empty) in `.harness/config` or the environment; any other value replaces the trailer.
  Covered by `test/test_lane_git.sh`.

### Fewer serial waits: review sub-agent beside the suite, small suites local, no-op rebase skipped, fewer `gh` calls per lane switch (#618)

- Review: `prompts/review.md` starts the review sub-agent first and runs the suite while it works (it used to start after about 80 s of
  serial checks). `scripts/swarm-suite.sh` exits `3` ("run it locally") for a small suite: files × `HARNESS_SWARM_SECS_PER_FILE`
  (default 2) under `HARNESS_SWARM_LOCAL_MAX_SECS` (default 60; `0` = always swarm). In run-20261106 the swarm job took 61 s and gave
  a false red where a local run takes about 2 s.
- Implementer: `prompts/impl.md` skips the rebase and the re-gate when `git rev-list HEAD..origin/<default-branch>` is empty, and
  merges with one direct `gh pr merge --squash --delete-branch`; the promise is printed once it exits 0 (the engine's `merged` check
  confirms it). `--auto` is only the retry for a merge that failed. `bug-fix.md` and `resume.md` are unchanged.
- Lane switch: `default_branch` asks GitHub once per fleet (kept in `RUN_DIR` for an hour; a gh failure is never kept). Spawning an
  impl lane makes one `gh issue view` for its issue: the labels, the issue text and the parent PRD for stats attribution all come off
  that answer (the parent PRD's own `## Original request` still costs its own view). The fixed `sleep 1.5` after a tmux session
  starts is gone. `test/test_lane_switch.sh`, `test/test_prompt_fast_ship.sh` and `test/test_swarm.sh` cover them.

### The engine files one child itself for a small PRD or POOL=1: no decompose session (#614)

- In bench run-20261106 the decompose session cost $1.29 and split a 4.7 KB brief into 6 issues, which 6 implementer sessions
  then ran one after another, each paying a ~35k-token start. `dispatch()` now has a `FILE_CHILD` action that takes no slot
  and no session: the pool's chores run `file_child`, which files one `[AFK] Implement PRD #N` issue with a single
  `gh issue create`, labelled ready. Its body carries the PRD's `## Acceptance criteria` section word for word, `## Blocked by`
  `None`, and the `## Parent` / `Part of #N` attribution. It fires for a PRD with no child yet when `HARNESS_POOL=1`, or when
  the PRD lists 1 to K acceptance criteria (`HARNESS_ENGINE_CHILD_MAX`, default 15). A larger PRD with `HARNESS_POOL` above 1,
  a PRD with no criteria section, and a PRD with a `## Task 1` plan-first section still go through decompose. The PRD session
  in front and the REVIEW after the child closes are unchanged. `file_child` checks for an existing child by title and leaves a
  marker, so a snapshot that lags a poll behind cannot file two.

### "When to use Harness": a tier check (direct / single lane / fleet) before setup or new work (#619)

- In bench run-20261106 a 3-minute single-session job took Harness 59 minutes and about $7.58, against $0.64 done in the
  session. `/harness <idea>` now runs a tier check as its step 0, before the install and `harness init`; `/harness-prd`,
  `/harness-issue` and `/harness-arc` run it first too. The session grills just enough to estimate, then
  `harness tier decide` names the tier (direct: do it in the session on a branch with a PR; single lane: PRD, one child,
  review; fleet: the full flow), the reason, and a rough time and cost for direct and fleet. The user can override either way
  (`--prefer`). The thresholds live in one file, `scripts/tier.toml`, marked provisional until #621 recalibrates them.
- On a live fleet a direct fix first runs `harness tier overlap --files …`: it refuses (exit 1) and routes to `/harness-issue`
  when an open `agent-working` issue's branch or worktree, or an open PR, touches any of the files. A direct fix records
  `Direct fix: fits one session` in its PR body. The `/harness` rule "don't do a unit's work by hand" now allows such a fix.
  `test/test_tier.sh` covers the three tiers, the override, and the overlap check against a stubbed `gh` and real worktrees.

### The engine owns the Claude goal-loop Stop hook: a short nudge, no re-feed while a sub-agent runs, no lost promise (#616)

- In bench run-20261106 the user-scope `ralph-loop` plugin's hook re-sent the whole task prompt 15 times (about 39.6k tokens,
  $1.87 of turns after the first re-feed, about 85 s): the decompose lane printed `<promise>DECOMPOSE DONE</promise>` and was
  re-fed three more times, and the reviewer was re-fed four times while it waited on its own background sub-agent. The engine now
  ships the hook (`plugins/claude/harness-ralph`) and every `claude` lane launch loads it with `--plugin-dir`, lean or full.
  A lean launch no longer needs a `ralph-loop` plugin on the host; a full-config launch switches an installed `ralph-loop` off for
  the lane so the two hooks do not both re-feed.
- Before nudging, the hook re-checks the transcript for the promise for up to `HARNESS_RALPH_FLUSH_MS` (1500 ms), so a final
  message flushed just after Stop fires ends the loop. A Stop while a background sub-agent runs gets no nudge (and a sub-agent
  whose transcript has not moved for `HARNESS_RALPH_AGENT_STALE_S`, 1800 s, no longer holds it). The nudge is
  `Not done: <goal>` plus a line to continue or print the promise; the whole task is re-sent only after a context compaction.
- The bench records `refeeds` and `refeed_tokens` per run (and in the aggregate); run-20261106 measures 15 and about 39.6k.
  `test/test_ralph_stop_hook.py`, `test/test_bench_refeeds.py` and `test/test_cli_lean.sh` pin the behaviour.

### The task file carries the issue, the caveman rules and the user's original request, and no prompt can hit the `gh issue view` error (#617)

- In bench run-20261106 every plain `gh issue view N` failed with the "Projects (classic) is being deprecated" error and
  lanes retried with `--json`, a wasted turn in 8 of 9 sessions. Every prompt's `gh issue view` now passes
  `--json title,body,labels,comments`, and `test/test_task_context.sh` greps the prompts for the bare form.
- `.harness-task.md` now holds the issue title, body and comments (the one `gh issue view` call `prepare_impl` already made
  for the labels is widened, no extra call). The parent PRD is inlined only when the issue is its sole child.
- The caveman rules are inlined in `prompts/_caveman.md`; no lane invokes the `caveman` skill, saving a turn per session.
- PRDs carry an `## Original request` section with the user's words verbatim (`/harness`, `prompts/prd.md`). Implementer and
  reviewer task files put it at the top with the rule that it outranks the PRD, which outranks the issue.
- `scripts/taskctx.py lint` flags a function or library an issue names that is in neither the original request nor the repo at the
  base commit (run-20261106's issue #2 named `str.splitlines()`); the implementer's task file lists such names as its own call.

### The PRD review judges against the brief and files every user-visible I/O finding (#600)

- In bench run-20261106 the review's probe sub-agent found the UTF-8 byte-order-mark bug but filed it as a minor observation
  "consistent with 'read as UTF-8'"; the review judged against the PRD, never read `brief.md`, and signed off with no
  follow-up issue. `prompts/review.md` now tells the reviewer to find the original brief or spec in the repo (`brief.md`,
  `HARNESS_SPEC`, ...) and judge against it as well as the PRD, with the brief winning a disagreement. Every finding about
  user-visible input or output, of any severity, becomes a `ready-for-agent` follow-up issue before sign-off. The probe
  sub-agent always runs a fixed robustness checklist: for a CLI, dash-leading values (positional and option), output piped
  into `head -1`, a UTF-8 BOM, CRLF and lone-CR line endings, and a form feed or U+2028 inside a field; for any other
  interface it writes the equivalent checklist first. `test/test_prompt_review_probe.sh` pins each rule.

### Running fleets pick up the tend tick, launch check and lean lane context through the engine roll, with no manual step (#602)

- The engine roll (`fleet_roll`, run by `harness update`, `harness start` and `harness supervise`) restarted a worker only when its
  `ENGINE_DIR` differed from the new engine's. A git-checkout engine that `update` fast-forwards in place keeps the same
  directory, so its running workers stayed on the old loop, without the 15 s lane tend tick (#594) and the launch check (#596).
  `pool.sh` and `priority.sh` now export `HARNESS_ENGINE_STAMP` (`engine_stamp` in `scripts/portable.sh`, a checksum of the engine's
  scripts) to the worker they launch, and `fleet_roll` also rolls a worker whose stamp differs from the engine's current one.
  A worker that predates the stamp on a git checkout is rolled once: that one-time migration is the roll's own. Lane sessions keep
  running and the relaunched worker adopts them. A worker on a release directory is unchanged: the release never changes under it.
- Lanes launch from the worker's engine, so a lane launched after the roll carries the lean-context flags (#595) with no further step.
- `harness update` no longer prints "pause, drain, stop, start --recover". It prints a note only for a worker the roll deferred
  because it holds a bug claim, which the next roll moves on its own. `test/test_engine_roll.sh` covers the roll.

### The implementer treats a known gap as a failed gate (#599)

- In bench run-20261106 the implementer of issue #5 wrote "Known gap: An AMOUNT like `-abc` exits 2 instead of 1" only in its
  chat output, merged anyway and output the done promise. `prompts/impl.md` now carries a KNOWN-GAP GATE in its closing promise paragraph: a known gap against the
  issue's acceptance criteria or the brief is a failed gate. The implementer fixes it, or files it as a follow-up under the
  `_followup.md` rules and links it in the PR body, and never outputs the done promise over a gap that is neither fixed nor
  filed. `test/test_prompt_known_gap.sh` pins the rule.

### A small PRD stays small: decompose splits only when it pays, the PRD stops prescribing primitives (#598)

- In bench run-20261106 a 4.7 KB brief became 6 issues, 6 implementer sessions and 6 PRs, one of them a final
  sweep/README issue that repeated what review Phase 1 already does. `prompts/decompose.md` now carries a slicing rule that
  explicitly overrides the vendored `to-issues` skill's "prefer many thin slices": with `POOL` 1 it files one issue (unless
  the PRD has more than ~15 acceptance criteria or unrelated subsystems); with `POOL` above 1 it splits only when the
  dependency graph is at least 2 wide at its top; it never files a final sweep, README or acceptance-check issue (docs go
  into the slices). The engine passes `POOL` into the decompose render (`scripts/drive.sh`) as an upper bound on parallelism.
- Neither `prompts/prd.md` nor `prompts/decompose.md` may add an implementation primitive the brief does not require.
  In the bench run the PRD prescribed `str.splitlines()` and "read as UTF-8", and decompose copied it into an issue; that
  caused the byte-order-mark and form-feed / U+2028 bugs. They state the behaviour instead. `test/test_prompt_decompose.sh`
  pins both rules and the `POOL` render.

### Cost figures use current list prices (#597)

- `scripts/forecast.py` still priced Opus at $5 / $25 and Sonnet at $3 / $15 per Mtok (cache read $0.50 / $0.30), the 4.x
  prices, so every reported dollar figure ran about 1.5× high. `PRICE` now carries the 5.x list prices: Opus $4 / $20,
  Sonnet $2 / $10, cache reads $0.20 for both, cache writes at 1.25× (5 minutes) and 2× (1 hour) input. Opus and Sonnet
  4.x and older (`claude-opus-4-1`, `claude-3-5-sonnet`, ...) keep the old rows. The `harness one` budget gate, `harness
  stats` and `bench/run.py` read the same table.
- Run `run-20261106` is re-costed from its committed logs: $6.86 for Harness (was $10.28) and $0.64 for plain Claude
  Code (was $0.92).

### A tmux launch counts only if the session exists; an instantly dead lane backs off (#596)

- A stale inherited `TMUX=` (its socket directory gone) made `tmux new-session` print `error creating …` but exit 0, so
  the launch was logged as a success and the worker re-claimed at once with no backoff: in a benchmark run the first
  3.7 minutes were 13 DECOMPOSE launches that died in 0-1s, and `harness stats` counted 21 sessions where 9 ran.
  `tmux_sess_start` now confirms the session with `has-session` and fails when it is missing, and no longer passes the
  caller's `TMUX` through; a pool worker started with a stale `TMUX` drops it at start.
- A lane that is gone within 30s of its launch (`HARNESS_LAUNCH_FAIL_SECS`) logs a `launch_failed` event, and the worker
  holds that issue or PRD action back for `HARNESS_LAUNCH_BACKOFF` seconds (60, doubling per consecutive failure up to
  `HARNESS_LAUNCH_BACKOFF_MAX`, 900) before claiming it again; other ready work is claimed meanwhile.
- `harness stats` does not count a `launch_failed` lane as a session.

### Lean lane context: Claude lanes start without the operator's user-scope config (#595)

- Every lane inherited the operator's whole personal Claude Code config (186 skills, user plugins, MCP servers and
  hooks): about 13k tokens of fixed context, re-cached with the 1h TTL in every session. A `claude` lane now launches
  with `--setting-sources project,local --strict-mcp-config` and `--disallowedTools` for the tools no lane used
  (`Workflow`, `ScheduleWakeup`, `ReportFindings`, `ListAgents`, and `AskUserQuestion` on an autonomous fleet). In 12
  local runs the first-turn cache write fell from 32.5k to 3.85k tokens. The Skill tool stays (`--disable-slash-commands`
  would remove it), and no custom `--tools` list is used (it misses the shared prompt cache).
- The engine supplies what a lane uses. Each skill a prompt names is linked into the worktree's `.claude/skills` from the
  engine's `skill/<name>` (rtdd's own from the user skills dir), git-excluded so `git add -A` never commits it; a skill the
  project ships itself is left alone. The goal loop's Stop hook, the `ralph-loop` plugin, is loaded with `--plugin-dir`.
- `HARNESS_CLAUDE_LEAN=0` launches with the full config as before. A `--setting-sources` in `HARNESS_CLAUDE_FLAGS`, or a
  host with no `ralph-loop` plugin to load, does too, so the goal loop never breaks silently. The other CLI backends cannot
  drop user config without dropping what a lane needs; each is listed with the reason in `docs/cli-capabilities.md`
  (§ Lean lane). `test/test_cli_lean.sh` pins the flags, the skills and the engine-supplies-every-prompt-skill check.

### A worker tends its own lane on a ~15s tick (#594)

- In bench run-20261106 every lane sat idle about 5.5 minutes after its work finished, because the worker only checked
  the lane's goal on its `POLL`-spaced tick. A worker that owns a live lane now ticks every `HARNESS_TEND_TICK` (15s) and
  runs only that lane's tend step; the next claim happens at once after a reap. Fleet-wide chores and the stall watchdog
  stay on `POLL`.
- The goal check runs only while the lane's pane is idle, so `gh` is not hit every 15s while the agent works. A pane whose
  sub-agent is still running (`← 1 agent`) counts as busy, so a review lane waiting on its sub-agent is not reaped. A
  `DECOMPOSE` lane is not reaped partway through filing children: it waits for its completion promise, or
  `HARNESS_TEND_IDLE_TICKS` idle ticks with no `gh` process running.

### Bench quality gate: fuzz root-cause classes, blind fuzz generators, a scripted blind review and a ship rule (#620)

- The bench could not show "same or better quality": the hidden tests and SonarQube score both arms alike, coverage points the
  wrong way, the fuzz counts raw cases (one lone CR swamps it) from one fixture, one seed and a generator written after the
  Harness arm's bugs were known, and the blind review was done by hand so nobody can reproduce it.
- **Root-cause classes.** `bench/rootcause.py` groups fuzz divergences by (input feature, what differed); results carry
  `fuzz_classes` and `fuzz_class_counts` and the README table shows the class count. Two planted bugs that make 100 cases
  diverge are 2 classes.
- **Blind fuzz per fixture.** The pennywise generator is rewritten from the brief and the reference alone
  (`bench/fixture/fuzzgen.py`, seed 620); the large fixture's carries a provenance note. Both say how they were written; results
  of the old pennywise fuzz (seed 589) are not comparable with the new ones.
- **Scripted blind review.** `bench/review.py` takes a fixed rubric, the brief and two anonymised repos; three Opus judges each
  review in both orders; the mean score (out of 10) goes into the results JSON as `review_score` / `review`.
- **Ship rule.** A fleet change ships only if, over at least 5 runs against 5 of the baseline, the median class count is no
  higher, no new class appears and the review mean has not dropped by more than 0.5. `bench/shiprule.py` applies it.

### Bench: a large fixture, `tallybook`, with a mid-run requirement change (#592)

- The only fixture, `pennywise` (a 4.7 KB brief, about 400 lines), fits one session in under 3 minutes: the case where
  Harness cannot win, and nothing it is for is tested. `bench/fixture-large/` is a second fixture, picked with
  `bench/run.py <arm> --fixture large`: a long brief for a double-entry bookkeeping library, SQLite storage with four
  schema versions and migrations, a command line and a small HTTP API; a stdlib-only reference implementation; about a
  thousand black-box hidden tests in 16 modules; a frozen differential fuzz against the reference (`bench/fuzz.py
  --fixture large`); and `shape.json`, the 36-issue decomposition a planner reaches (never given to an arm).
- **A change halfway.** `bench/progress.py` grades the repo every few minutes while an arm works (milestones) and, when half
  of the pre-change hidden tests pass, hands every arm the same written change (`change.md`: round half to even, a lock
  date, a new API error body). A plain session is interrupted and resumed with it, Harness gets `/harness-prd <change>`,
  Hx a second PRD; an arm that finishes first gets it then. The hidden tests exist in pre- and post-change variants.
- **New measures** in the results JSON and a table of their own in the README: wall time to the first full pass,
  $ per passed hidden test, regressions (a test that passed at one milestone and fails later), context compactions,
  continue replies (the plain arm's cap is 50 here), the 1 to 3 worker speed-up, how often an arm hits a cap, and the
  hidden tests per module.

### Lane prompts and review.md use `HARNESS_WINDOWS_HOST` for rtdd rounds and the PRD-review full suite (#494)

- With `HARNESS_WINDOWS_HOST` set, a lane whose diff touches Windows-relevant code (`scripts/portable.*`, `install.sh`,
  `update.sh`, `scripts/uninstall.sh`, `scripts/doctor.sh`, `scripts/session/headless.sh`, `scripts/cli/*`,
  `scripts/supervise.sh`, `scripts/web.sh`, `scripts/attach.sh`, `test/smoke/winsma/*`) also runs its rtdd Rounds 1 and 2 (never
  the full suite) on that host, through the winsma lock, isolation and guard helpers. The new `scripts/windows-relevant.sh` answers
  "does this diff touch that list?" for the lane.
- `prompts/review.md`: the PRD review's single full suite also runs on the Windows host, in the full-suite isolation with the guard.
  The bar is no Windows failure that Linux does not also have at the same commit, and every Windows skip names an `n/a` row.
- With the key unset the rendered prompts are byte-for-byte what they were. The Windows paragraphs live in
  `prompts/_windows_rtdd.md` and `prompts/_windows_suite.md` and are rendered in only when the key is set.
  `docs/reference.md` documents it ("Windows host checks"); `test/test_windows_prompts.sh` covers it.

### Bench: SonarQube on a tmpfs, a skipped scan invalidates the run, branch coverage (#588)

- `bench/quality.py` mounts SonarQube's data directory as a tmpfs, so a host with under 10% free disk no longer
  stops Elasticsearch from starting (both the bench host and the owner's desktop were about 95% full, so the
  first run measured no quality at all). A server that exits now reports the log's first `ERROR` /
  `MessageException` line instead of the log tail, and its container is removed with its anonymous volumes.
- A run in which any arm's quality scan did not run is **invalid: rerun**. The README Benchmark section opens
  with `INVALID RUN: rerun.` naming the arm and the reason, and `bench/run.py` says so on stderr, so a host
  problem is not published as a footnote or counted against an arm.
- New `bench/testcov.py` runs each arm's own tests under coverage.py with branch measurement, counting the
  subprocess CLI calls, and `bench/run.py` records it as `coverage` (line, branch and total %, aggregated over
  `--runs N`). The README table always shows the SonarQube and Coverage columns, `n/a (<reason>)` when missing.
- `run-20261106` is backfilled: both arms scan `ok` (0 bugs, 0 vulnerabilities, 0 code smells, rating A), and own-test
  coverage is 94% for plain and 98.6% for Harness.

### The fleet cleans up after its lanes: test temp dirs, `run/*.wd`, and closed PRDs' gauntlet dirs (#610)

- Every lane session now runs with its own `TMPDIR` (`<tmp root>/hzt-<n>`), removed together with the lane's worktree
  by the same reap, so the `mktemp -d` dirs a test in the lane never deleted (about 3,800 of them, 1.5 GB of tmpfs
  on one host) are gone even after a crash. `test_hermetic.sh` and `test_vocanicz_skill.sh` also put their own temp
  dirs in one private dir, so a run from a plain shell leaves `/tmp` as it found it.
- The goal check that ends a session removes `run/<sess>.wd` along with `.goal`, and `gc_orphan_goals` sweeps any
  `.wd` / `.loop` left without a `.goal` once its session is not live (it never touches a live session's).
- `CLOSE_PRD` removes `gauntlet/<unit>/p<prd>`, and `harness start --recover` removes the gauntlet dirs of PRDs that
  are already closed (open PRDs' dirs and any it cannot read are kept).

### Bench: `--runs N` per arm, median and range, `n=1` labelled (#591)

- Every number in the benchmark was one run, and agent wall time and cost vary 20–40% between runs. `bench/run.py
  --runs N` (default 5) now runs an arm N times, each in its own private repo, under the same caps and with the
  held-usage and headroom guard checked again before every run. Each run's results and logs are kept in
  `<arm>.runs/` and `<arm>.json` is the aggregate: median and min–max of wall time, cost, tokens, hidden tests,
  fuzz divergences and coverage. A batch that cannot finish (the budget ran out, a run failed, a repo could not be
  deleted) stops early and records how many runs completed and why. `--runs 1` keeps the old single-run files.
- `bench/figures.py` adds an `n` column, shows median and range in the table and median bars with range whiskers
  in the figure, labels every single run `n=1` (including the committed `run-20261106`), and `--check` also fails
  when an aggregate does not match its runs.

### Bench arm parity: one isolated Claude config, a matched Opus arm, and the provenance of every run (#590)

- In `run-20261106` the arms differed in more than "plain vs Harness": the Harness arm ran on the operator's own Claude
  setup (186 skills, user plugins, 4 MCP servers and hooks), Harness lanes ran at effort `high` against plain's
  `medium`, Harness implementers ran on Sonnet against plain's Opus, and neither the engine commit nor the `/harness`
  skill version was recorded. Now both arms run on a throwaway `CLAUDE_CONFIG_DIR` (`bench/armlib.py`) that holds only
  the login (symlinked) and, for the Harness arms, only what the engine itself installs: its own skills (`skill/`) and
  the ralph-loop and superpowers plugins. The Harness front door's init is checked and the arm stops before doing any
  work if it lists an MCP server or a plugin that is not the engine's; the plain arm's existing check is unchanged.
- A matched arm, `bench/run.py harness-opus [--optional]`: Harness with the front door and every manager and
  implementer lane on Opus at effort `medium`, the plain arm's. `harness` stays the headline arm at Harness's
  out-of-the-box defaults. `harness-opus` is optional and records `skipped: <cause>` when the guard refuses.
- Every arm's results JSON now records `effort` (messages per effort, from the transcripts, re-checked by
  `bench/figures.py --check`), `configured` (the model and effort the arm asked for; null is the default),
  `provenance` (`engine_commit`, `skill_version`, `cli_version`) and, for Harness arms, `isolation`. The README
  Benchmark section prints a **Run settings** line per arm with them.

### Bench grading: a differential fuzz of every arm against the reference implementation (#589)

- The 80 hidden tests cannot tell the arms apart (both scored 80 / 80, while a blind review found five bugs they never
  exercise). `bench/fuzz.py` now feeds 1000 random argv and ledger files (dash-led arguments and `--`, a byte order
  mark, invalid UTF-8, LF / CRLF / lone CR line endings, form feeds and U+2028 in notes, stdin or a file, a closed
  output pipe) from a frozen seed and generator through the arm's `pennywise` and the reference, and counts where
  standard output, "standard error is empty" or the exit status differ. `bench/grade.py` runs it after the hidden
  tests; results carry `fuzz_cases`, `fuzz_divergences`, up to 10 `fuzz_examples`, `fuzz_seed` and `fuzz_hash`, and the
  README table has a **Fuzz divergences** column. `grade.py REPO --fuzz-only --arm-json FILE` backfills a graded run:
  `run-20261106` shows Harness 387 / 1000 and Plain 234 / 1000 divergences.
- The reference implementation is fixed on those shapes first: `add` takes a dash-led amount or note as typed, a byte
  order mark is dropped, a line ends only at LF, CRLF or a lone CR, a closed output pipe ends quietly, `-0` prints as
  `0.00`, and `add` refuses a category or note that would corrupt the ledger.

### Bench: an arm's committed raw logs reproduce its results JSON, sub-agent transcripts included (#579)

- `bench/run.py` copied only the main `.jsonl` of each registered transcript into `<arm>.logs/transcripts/`, while the
  measurement also counts each one's `subagents/*.jsonl`; the Harness arm's committed logs re-measured to $9.32, not
  the recorded $10.28. It now keeps `<i>-<name>/subagents/` beside `<i>-<name>.jsonl`, the layout `stats.transcript_files`
  reads, and `bench/figures.py --check` fails when re-measuring an arm's logs (tokens, $, coding / testing split, test
  calls) does not reproduce its results JSON. `run-20261106`'s Harness arm is backfilled with its one sub-agent transcript.

### Bench arm: Harness (`--workers N`) — the same brief through `/harness <idea>` in an isolated run fleet (#383)

- `bench/run.py harness` (and `harness-3`) hands the benchmark brief to one `claude -p` session as `/harness <brief>`,
  unattended, and lets the /harness skill take it to a PRD, lanes and a running fleet, on Harness's out-of-the-box
  role defaults. `--workers N` (new on `bench/run.py`, also `--arm-opt workers=N`) is passed through as
  `HARNESS_POOL`. The run fleet is isolated (own `HARNESS_HOME`, own state dir in the run clone, a run-named session
  prefix, the host's `HARNESS_*` and `STATE_DIR` scrubbed, no host poller) and is stopped only with
  `harness stop --state-dir <its own>`, however the arm ends. Results carry `issues_closed`, `prs_merged`, the models
  that ran, and the fleet's own event log. `test/test_bench_harness.py` drives it with a fake front door, engine and gh.

### Every test that draws tmux panes has a headless twin that runs on Windows (#493)

- Windows has no tmux, so the nine shell tests that start a tmux pane or gate on the binary (`test_supervise.sh`,
  `test_watchdog.sh`, `test_sess_sweep.sh`, `test_tmux_env_leak.sh`, `test_unit_tmux_safe.sh`,
  `test_bug_session_tmux_safe.sh`, `test_supervise_autoupdate.sh`, `test_fleet_migrate.sh` and the frozen-pane cells of
  `test_cli_matrix.sh`) were silent gaps there. Each now has a twin on the headless session backend that asserts the same
  behaviour on real headless lanes with the fake CLI: `test_supervise_headless.sh` (existing), and the new
  `test_watchdog_headless.sh`, `test_sess_sweep_headless.sh`, `test_env_leak_headless.sh`,
  `test_session_names_headless.sh`, `test_supervise_autoupdate_headless.sh` and `test_fleet_migrate_headless.sh`.
- `test/tmux_twins.tsv` pairs every tmux test with its twin, and `test/test_tmux_twins.sh` is the grep check that lists
  what is left over: a tmux test with no twin, a stale line, and a twin that is missing, needs tmux itself, skips instead
  of asserting, or is not on the headless backend all fail. The detector is `tmux_needing_tests` in `test/helpers.sh`.
  A twin may also be a skip through `windows_skip` on a matrix row that is `n/a` on Windows; no tmux test needs that today,
  because only `swarm submission` is `n/a`.
- On a host with no tmux the `supervisor-frozen-session` and `supervisor-skips-trust-dialog` cells of `test_cli_matrix.sh`
  run the CLI's headless supervisor cell instead of failing; with tmux they draw panes as before.
- `test/run.sh` accepts test file names (`bash test/run.sh test_a.sh test_b.sh`), and the winsma suite stage takes
  `HX_TESTS` to run just those files in the full-suite isolation.
- Running the twins on winsma found why headless lanes with a fake agent never ran a turn there (the cause behind most of
  #606): the native Python lane runner was handed `python3 /c/.../fake-claude` and read it as `C:\c\...`, and the fake
  claude's `turn-hook` is a shebang script CreateProcess cannot run. `native_path` in `test/helpers.sh` passes the fake's
  path in native form, and the fake runs its hook through bash on Windows. With those, on winsma
  (`test/smoke/logs/suite-windows-20261106T225957Z.log`, guard clean, no credential written, winsma clean)
  `test_watchdog_headless.sh` (57/57), `test_env_leak_headless.sh` (46/46) and `test_session_names_headless.sh` (76/76) pass;
  `test_sess_sweep_headless.sh` has one red assertion. The earlier runs are `suite-windows-20261106T193904Z.log` (before the
  fixes: 1 of 8 twins), `T211737Z`, `T222737Z` and `T224844Z`. The twins still red on Windows (`test_fleet_migrate_headless.sh`,
  `test_supervise_headless.sh`, `test_supervise_autoupdate_headless.sh`, and the sweep assertion) fail on Windows behaviour of the
  code under test that their tmux counterparts share; they are tracked in #627.

### The test suite runs in Git Bash on Windows, and a Windows skip must name an `n/a` matrix row (#492)

- `test/helpers.sh` gains `windows_skip <matrix row> <why>` (and `windows_skip_file`, which ends the file): the one way a test
  skips itself on Windows. It reads the Windows column of the parity matrix in `docs/reference.md`. An `n/a` row skips on Windows
  and names the row in the `SKIP` line; a `✓` or `✓ target` row, or a row the matrix does not have, is a failure on every OS,
  so a wrong skip shows on Linux first. `test/test_swarm.sh` takes the one real skip (`swarm submission`).
  `test/test_windows_skip.sh` covers the helper.
- `test/windows_coverage.tsv` names, for every row that is `✓` on Windows, a test that actually runs there.
  `test/test_windows_parity_doc.sh` now fails on a `✓` row with no running test (no line, a missing file, or a test that skips
  itself without tmux) and on a line for a row that is `n/a` or not in the matrix.
- `test/run.sh` takes `HARNESS_TEST_TIMEOUT=<seconds>` (a hung test ends as `TIMEOUT` instead of stalling the run) and ends with
  `== run.sh: N/M test files passed ==` plus one `FAILED: <file>` line per red file; `test/test_run_summary.sh` covers both. On a Windows host `run.sh` also points
  `HARNESS_SCHTASKS` and `HARNESS_WINGET` at recording stubs: the first full run on winsma registered five real
  `Harness\harness-*` Task Scheduler tasks from tests and tripped the before/after guard.
- `test/smoke/winsma/suite.sh` runs the whole suite on the Windows check host in the full-suite isolation (`HOME` and
  `USERPROFILE` under `C:\hx-<issue>\home`), see `docs/windows-smoke.md`. It ends the processes tests leak (they held the ssh
  session open) and the logs are committed under `test/smoke/logs/`: the first complete run on winsma passes 72 of 168 test
  files with the guard clean; the Windows-only failures are filed as #605 to #609.

### `harness start` replaces a fleet's old-engine workers instead of leaving them on the default cap (#566)

- `harness start` migrates the fleet's config with `--no-start`, which for an already-migrated fleet only dropped a
  leftover `HARNESS_CAP` line and killed nothing; `pool.sh` then saw each old worker pid alive and skipped it. Those
  workers, on a release with #467 but not the step loop (#468), kept the unit-claim loop and fell back to that
  release's default `HARNESS_CAP=3`, running more lanes than the fleet ever had until a manual stop and start. The
  migration now also stops every worker and priority pid whose `ENGINE_DIR` is not the current engine (the same
  comparison `fleet_roll` makes, through a new stop-only mode, so there is no nested `harness start`), and
  `pool.sh` relaunches them. Workers already on this engine are left alone, so a second `harness start` kills
  nothing; a worker holding a bug claim waits for a later pass; lane sessions keep running and the new workers
  adopt them. `test/test_fleet_migrate.sh` covers old, current and bug-claim workers through `start.sh`.

### A repo name with a dot no longer gives tmux-unsafe bug-lane session names (#557)

- `sess_bug` built `<prefix>-bug-<repo>-<n>-<phase>` from the repo slug with only `/` mapped to `_`, so
  `vercel/next.js` gave `hz-bug-vercel_next.js-7-fix`. tmux creates that session as `hz-bug-vercel_next_js-7-fix` but
  `has-session -t` on the dotted name fails, so `bug_session_live` was always false and the fleet never saw its own bug
  lanes. One helper, `slug_safe`, now maps every character outside `[A-Za-z0-9_-]` to `_`, and `sess_bug`, the bug
  claim key (`_bug_claim_key`) and the bug-session prefix in `fleet_bug_numbers` all use it, so they keep agreeing.
  A repo without such characters keeps its session and claim names. `test/test_bug_session_tmux_safe.sh` starts a bug
  lane for a dotted repo on a private tmux server and checks `bug_session_live` sees it.

### A repo name with a dot no longer gives a tmux-unsafe `HARNESS_UNIT` (#554)

- `harness init` wrote the lowercased repo short name as `HARNESS_UNIT` and nothing else, so `vercel/next.js` gave
  `next.js`. tmux reads `.` and `:` in a session name as a window/pane separator (it creates `hz-next_js-i5` but
  `has-session -t hz-next.js-i5` says "can't find pane"), so `session_live` was always false for that fleet's lanes:
  every lane looked dead right after it spawned. `init.sh` and `fleet_migrate.py` now map every character outside
  `[A-Za-z0-9_-]` to `_` (`next_js`), and `fleet_unit` applies the same rule (`unit_safe`) to a `HARNESS_UNIT` set
  by hand, so no reader uses a raw unsafe unit. A unit that is already safe is returned unchanged, so the session
  names of existing fleets do not move. `test/test_unit_tmux_safe.sh` spawns a dotted-repo lane on a private tmux
  server and checks `session_live` sees it.

### `start --recover` no longer orphans a live pool-taken bug lane (#540)

- `clear_stale_claims` drops the `bug-*.claim` of a killed pool worker, and nothing adopted the bug session
  afterwards: it got no watchdog, was never torn down or reaped, and did not count toward POOL. The chores winner
  now adopts every live `<prefix>-bug-<repo>-<n>-triage|fix` session of the fleet repo that has no claim file
  (`adopt_bug_sessions`), writing a `pool-<wid>` bug claim so the owner tends it and reaps its worktrees and
  claim once it ends. A claimless live bug session counts toward POOL (`pool_lane_keys`), and `claim_lane` will
  not dispatch a bug whose session still lives. Any existing claim file is left alone, so a priority-lane bug
  claim is never taken over. `test/test_pool_lanes.sh` section 6b covers it.

### `harness update` rolls fleets that were already migrated onto the new worker loop (#537)

- `scripts/fleet-migrate.sh` returned before rolling anything when a fleet's config was already one repo (exit 10)
  or only had its leftover `HARNESS_CAP` line dropped (exit 11), on the assumption that its workers already ran the
  new loop. A fleet migrated by a release that has #467 but not the step loop (#468) has the new config under
  workers still on the old unit-claim loop, and `harness update` left them there. It now calls `fleet_roll` for
  every registered fleet whatever the config step did. `fleet_roll` kills only a worker whose `ENGINE_DIR` is not
  the target engine, so a worker already current is left running and a second update kills nothing; lane sessions
  survive and the relaunched worker adopts them. Only a freshly migrated config still kills all of the fleet's
  workers. `HARNESS_FLEET_MIGRATE=0` now also skips the migration and roll in `harness update`.
- `test/test_fleet_migrate.sh` unsets the inherited `STATE_DIR` (a lane's own fleet is the "folder update ran in"
  fallback) and `test/test_hermetic.sh` runs it against a decoy fleet to prove it.

### The lane spawn that creates the tmux server no longer leaks its fleet's env into it (#547)

- tmux copies the environment of the client that creates the server into the server's global environment, so a
  pool worker's `STATE_DIR`, `HARNESS_REPO`, `HARNESS_SESS_PREFIX`, `RTDD_EVENT_LOG` and every other exported
  `HARNESS_*` reached every later session on that server: other fleets' lanes and the operator's own shells.
  Observed 2026-11-05, when a re-created operator session failed `harness status` in 5 of 6 fleets with
  "STATE_DIR is set to … (inherited from the environment)". `tmux_sess_start` now runs `tmux new-session` from a
  subshell that unsets those variables, so a server it creates starts clean; the lane still gets its own values
  from the `-e` pairs, and `TMUX_TMPDIR`, `PATH` and `HOME` are untouched. `test/test_tmux_env_leak.sh` covers it
  on a real tmux with a private socket.

### Crash-loop guard: an issue whose every session dies young is parked, not relaunched forever (#545)

- When every session on an issue died a few minutes after launch (the #541 / #543 incident: a test run SIGKILLed
  the live tmux server, over and over, for about 6 hours), the reaper freed the issue and the next dispatch
  relaunched it with no limit and no signal. Now `HARNESS_CHURN_COUNT` (3) sessions of one kind on one issue that
  each ended in under `HARNESS_CHURN_MAX_WALL_S` (900) seconds within `HARNESS_CHURN_WINDOW_MIN` (180) minutes,
  across the pool and the priority lane together, make the engine strip `agent-working`, add `agent-blocked`,
  post an evidence comment (end time, wall time and lane of each session, its last tool calls, `Exit code 137`
  called out as SIGKILL, secrets redacted) and park the issue with the #271 mechanism. `scripts/churn.py` holds
  the detection; `lib.sh` `churn_check` runs from every reaper's `stats_sweep_ended`, before the issue is unlocked.
- Checkpointed, paused, watchdog-killed and goal-met sessions never count; after a park lifts only sessions
  launched afterwards do. `HARNESS_CHURN_COUNT=0` turns the guard off.
- The next lane's prompt (`{{CHURN}}` in `impl.md`, `bug-fix.md`, `bug-triage.md`, `resume.md`) carries the
  evidence and an instruction to find out what killed the earlier sessions before repeating their steps. A trip
  logs one `churn` event; `harness status` and `harness web` list each churn-parked issue.

### A lane cleanup can no longer kill the user manager, and `supervise --install` says how to revive it (#543)

- A lane's `pgrep -P ${p:-0}` with a missing pidfile listed PID 1's children and killed `systemd --user`, taking
  every fleet down for 10.5 h. All six lane prompts now require a PID to be non-empty, all digits and greater than
  1 before `kill` / `pgrep -P`, and name that anti-pattern. `proc_kill_tree` refuses an empty, non-numeric, `0` or `1` pid.
- `harness supervise --install` (Linux) prints a `NOTE` with root commands for a system `harness-user-revive.timer`
  that starts `user@<uid>.service` when inactive (linger does not restart an exited manager); it is skipped when
  that timer is already enabled. See "Surviving the user manager" in `docs/reference.md`.

### Pool worker: a failed spawn sleeps, and a missing checkout is cloned (#539)

- A pool worker whose lane failed to spawn used to count it as a claim and re-claim the same item with no sleep,
  burning GitHub API budget. `worker_tick` now returns rc 6 for a failed spawn and `worker_step` sleeps `POLL`.
- `ensure_checkout` is back (deleted with the multi-topology code): before it claims, the worker clones
  `HARNESS_REPO` into a missing `HARNESS_CHECKOUT`, or holds with one logged line per cause when it cannot.

### Benchmark: optional code quality, and an online-audit guide (#387)

- `bench/quality.py` scans an arm's final default branch with SonarQube Community in local Docker (no account, no
  token) and records bugs, vulnerabilities, code smells, maintainability rating, duplication and coverage in the
  arm's results; `bench/run.py` runs it after grading. It never blocks: Docker absent or a failing scan is recorded
  as `quality: skipped (<reason>)` and the run still exits 0. `bench/figures.py` shows the quality column.
- [docs/online-code-audit.md](docs/online-code-audit.md): the one-time GitHub sign-in steps for a free online
  audit of the public Harness repo (SonarQube Cloud, Codacy or DeepSource). Not a gate; nothing depends on it.

### Benchmark arm: plain Claude Code (#382)

- `bench/run.py plain` runs one `claude` session in the fresh run repo, on the host's existing CLI login: never
  `--bare`, no API key, no copied credentials dir. It starts from `--disable-slash-commands --strict-mcp-config
  --setting-sources project,local` with auto-memory off, and the account's default model and effort.
- Isolation is proven from the session's init, kept in the run's logs: the arm fails, before any work, unless the init
  lists 0 skills, 0 plugins and 0 MCP servers (plugins built into the claude binary do not count).
- The brief is the first message. When the session stops before the work is delivered to `main`, the scripted reply
  `keep going, decide for yourself` is sent, at most 20 times; the count and the commits on `main` are recorded in the
  results JSON next to the core's tokens, models, $, coding/testing time and hidden-test result.

### Benchmark runner core: `bench/run.py` (#381)

- `bench/run.py <arm>` runs one benchmark arm through a pluggable arm interface (`bench/arms/<arm>.py`, with a `stub`
  arm for plumbing checks): a fresh private GitHub repo per run, seeded with the brief only and deleted after the
  results are recorded, also when the arm fails or hits a cap.
- A guard refuses to start while any account is usage-HELD or when forecast-style headroom against the weekly window
  is short; `--dry-run` prints the decision and spends nothing.
- Each arm is capped at 6 h wall clock and $80 at list price; an arm that hits a cap is stopped and recorded as
  `capped: wall|cost`.
- One `bench/results/<run-id>/<arm>.json` per arm (schema in `bench/README.md`: wall, coding/testing, tokens, list-price
  $, % of the weekly window, models that ran, hidden-test result, counts, cap status) with raw logs beside it.

### The retired unit-claim loop is deleted (#529, PRD #464)

- `drive_unit`, `finalize_unit`, `spawn_pool_bug`, `count_pool_bugs`, `reap_pool_bugs` (`scripts/drive.sh`) and
  `claim_next`, `claimable_units`, `worker_unit` (`scripts/lib.sh`) are gone: the step-based pool worker replaced the
  loop and nothing called them. The tests that only drove them went too; the ones that used `drive_unit` as a harness
  for a live behaviour (usage hold, GitHub budget, CI gate, self-park, stall banner, release tick) now run through the
  pool worker's `worker_tick` / `worker_chores`.
- Stale comments and the `prompts/review.md` sentence that still described the old unit loop or a multi topology are
  updated.
- A leftover `claims/<unit>.claim` whose worker pid is dead (written by an old-loop worker before a roll) is now removed
  by the pool chores' stale-claim sweep, without `start --recover`.

### Pool chores: LABEL_READY and CLOSE_PRD no longer wait behind a DECOMPOSE (#527)

- The pool's chores pass now asks `issuelib.py slotless` (`slotless_actions`) for its slotless actions instead of
  reusing the claim-path `dispatch`, which returns a lone `DECOMPOSE` before it reaches LABEL_READY or CLOSE_PRD. While
  any PRD waited to be decomposed and every worker was busy, no unlabelled child was labelled ready and no reviewed PRD
  was closed. The claim path is unchanged: DECOMPOSE still comes before IMPL.

### A finished lane is reaped once (#528)

- `reap_team` and `reap_orch` skip a worktree that is gone once its claim check passes. Before, a lane the owning worker finished
  between the chores' worktree listing and their claim check was reaped a second time: a duplicate `reap` event, a second
  `gh issue view`, and a second `merged` event (and release queue entry for a bug fix) or a second unlock.

### `harness stats`: coding vs testing time per issue (#379)

- `harness stats --prd N` and `--issue N` split each session's wall time into **testing** (the time inside test-command
  Bash tool calls, from the call to its result) and **coding** (the rest), per session, per issue and in the PRD total;
  `--json` carries `coding_s` / `testing_s`. The split is a reusable function (`stats.time_split(transcript)`, also
  `scripts/stats.py time-split <transcript>`), so the benchmark can run it on any transcript.
- Which commands count as tests is a documented default pattern, replaceable with `HARNESS_TEST_COMMAND_PATTERNS`
  (environment or `.harness/config`); see [Coding vs testing time](docs/reference.md#coding-vs-testing-time-379).

### Lane tooling and skills on Windows (#495)

- `rtdd` resolves to `rtdd.exe` on Windows: `rtdd_exe` (`scripts/portable.sh`, and `inst_rtdd` in `install.sh`, which runs before any
  engine exists) looks for `rtdd.exe` by that name first, so `install.sh`/`harness update` count it as installed instead of running
  `npx` again, `harness doctor` prints `rtdd: ✓ (<path>/rtdd.exe)`, `harness setup` installs the rtdd skill through it, and the
  supervise task's `PATH` holds its directory.
- Fixed: `install.sh --with-skills` / `harness update --with-skills` copied `to-prd`, `to-issues` and `subagent-task-tree` into
  `$HOME/.claude/skills` even when `HARNESS_USER_SKILLS` pinned the skills dir, so a sandboxed host (a winsma lane: `HOME` is the real
  one) wrote outside its sandbox. They now go where the engine's own skills go. The two upstream clones also run with
  `core.autocrlf=false` and `core.longpaths=true`, so Git for Windows' default CRLF conversion no longer reaches a skill.
- Fixed: the `python3` shim baked its interpreter as `p="${HARNESS_PYTHON:-C:\ Program\ Files\ …}"`; the backslashes survive in
  double quotes, so an interpreter under a path with a space (`C:\Program Files\Python313\python.exe`, or a user name with a space)
  was reported "not found". The default is now its own assignment.
- `test/test_windows_lane_tooling.sh` (forced `HARNESS_PLATFORM=windows`, everything under a root whose name holds a space): the
  `{{skill:…}}` check finds, installs and re-finds every prompt-named skill in the Windows skills dir; `--with-skills` installs the same
  plugin calls and skills set as on Linux, into the pinned dir only; rtdd resolves to `rtdd.exe`; a lane-shaped shell in a worktree path
  with spaces runs git, gh, `rtdd.exe`, python3 (the shim), grep and sed with a short `TMPDIR`. On winsma `test/smoke/winsma/tooling.sh`
  does the same for real in `C:\hx-495` (sandbox `CLAUDE_CONFIG_DIR`), log
  `test/smoke/logs/tooling-windows-20261104T141533Z.log`. The parity rows for `rtdd` and the `/harness*` skills that were targets of this task are now `✓`.

### Benchmark fixture: end-user brief, hidden tests, `bench/grade.py` (#380)

- `bench/fixture/brief.md` is the one project brief every benchmark arm gets (PRD #345), written the way an end user
  would: a small Python library + `pennywise` command for a plain-text money ledger, with examples of the expected
  behaviour and no file layout or test hints.
- `bench/fixture/hidden/` holds the hidden acceptance tests (black box: the command line and the library's documented
  surface) and `bench/fixture/reference/` a reference solution that passes all of them. Neither is referenced by the
  brief or copied by any run script; `test/test_bench_fixture.sh` checks that.
- `bench/grade.py REPO_DIR` copies a checked-out final default branch into a throwaway directory, builds it with
  `pip install --target` (falling back to the copy on `PYTHONPATH`), runs the hidden tests and prints
  `{passed, failed, total, details}`. The reference scores 100%; an empty repo scores 0 without crashing the grader.

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

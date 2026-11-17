# Staged bench results for #1035

Raw logs and transcripts of the #1035 face-to-face matrix runs collected so far. They sit under `staged-1035/` on purpose: `bench/figures.py` shows the latest run id per size, and these runs are one arm each, so listing them as run directories would replace the table of the full run beside them.

| Run id | Arm | Size | Runs |
|---|---|---|---|
| run-20261115-medium-harness | harness (POOL=1) | medium | 5 |
| run-20261115-medium-harness-3 | harness-3 | medium | 5 |
| run-20261115-medium-harness-opus | harness-opus | medium | 5 |
| run-20261115-small-harness | harness | small | 2 (replaces the missing run 5 of #1031's run-20261115 harness arm) |
| run-20261116-large-plain | plain | large | 3 |
| run-20261116-small-harness | harness (POOL=1) | small | 3 (#1213, engine 603f4b3, after #1183) |
| run-20261116-medium-harness | harness (POOL=1) | medium | 3 (#1213, engine 603f4b3, after #1183) |
| run-20261117-small-harness-v3 | harness (POOL=1) | small | 3 (#1239, engine 9ca3ebd) |
| run-20261117-medium-harness-v3 | harness (POOL=1) | medium | 3 (#1239, engine 9ca3ebd) |
| run-20261117-small-harness-v4 | harness (POOL=1) | small | 3 (#1244, engine 639670a; run 3 has 7 fuzz divergences, kept as the story below) |
| run-20261117-medium-harness-v4 | harness (POOL=1) | medium | 3 (#1244, engine 639670a) |
| run-20261117-small-harness-v5 | harness (POOL=1) | small | 3 (#1244, engine 8c81b5a, the final figures) |
| run-20261117-medium-harness-v5 | harness (POOL=1) | medium | 3 (#1244, engine 8c81b5a, the final figures) |
| run-20261117-medium-harness-v2 | harness (POOL=1) | medium | 3 (#1239, engine 7631846, an earlier prompt; kept because its run 3 is a failure counted in the story below) |

`run-20261116-large-plain/peak-context/` holds each run's peak context tokens and compaction count, computed from its transcripts by `peak-context.py` (main session 214k, 278k and 220k tokens, subagents up to 191k; 0 compactions in all three runs).

The Harness arms of every size, the large harness-3, and the crossover/tier step wait for #1180 (the engine changes make Harness-arm runs on the current engine stale). Then these directories move back to `bench/results/<run-id>/` and `bench/results/crossover.inputs.json` names them.

## Re-bench after #1183 (#1213)

`run-20261116-small-harness` and `run-20261116-medium-harness` are the first part of the Harness-arm runs of #1035: 3 runs each, one engine commit (603f4b3, main after #1183), no run failed. #1035 tops them up to 5 runs on the same engine commit and reruns them only if the engine changed in between. Small run 3's SonarQube scan failed on the host (the runner marks it `INVALID RUN`, `quality: skipped`); its time, cost and grading are unaffected, and the top-up run replaces it for the quality figures.

| | small (target) | small (measured) | medium (target) | medium (measured) |
|---|---|---|---|---|
| wall, median of 3 | <= 20 min | 20.7 min (20.4, 41.2, 20.7) | <= 25 min | 26.1 min (26.1, 26.1, 29.2) |
| cost, median of 3 | <= $3 | $3.61 (3.38, 4.20, 3.61) | <= $4 | $5.14 (5.18, 4.92, 5.14) |
| hidden tests | 100% | 80/80 in all runs | 100% | 114/114 in all runs |
| fuzz divergences | no worse than run-20261115 | 0, 0, 0 | | 0, 0, 0 |

Before #1183: small 84.9 min / $7.03 (run-20261115, n=4), medium 47.8 min / $5.34 (n=5). Both time targets and both cost targets are missed, narrowly on time and by 20-28% on cost.

Where the time and money go, in every one of the 6 runs: three lanes one after another, `impl #2` (Sonnet), the review lane (Opus), then the review follow-up `impl #4` (Sonnet), after about 2-3 min of front door. The lanes are not idle: the gaps between one lane's release and the next launch add up to about 1.5 min a run. Small: impl #2 3-5 min (25 min in run 2), review 6-8 min, follow-up 4-6 min. Medium: impl #2 9-11 min, review 8-10 min, follow-up 2-4 min. Opus (front door and review) is 72% of small spend ($2.45 of $3.38 in run 1) and 65% of medium; cache reads are 5-9M tokens a run, cache writes 0.3-0.5M. The one small outlier (run 2, 41 min, $4.20) is a single 25-min first impl lane with 33 test calls.

## Re-bench after #1239 (review probe in the implementer lane, inline review)

**Cause, from the transcripts of `run-20261116-{small,medium}-harness`** (small run 2 left out, as the comment on #1239 says: it sat on the trust dialog, #1237). The two things left after #1183 were the review lane and the follow-up lane it files:

- The review lane's Opus probe sub-agent was 60% of the review's dollars ($0.7-1.7 of $1.4-2.9 small/medium) and about 5 of its 6-10 minutes: the main session started it, then waited for it while the suite (seconds long) had already finished. It re-read the whole project to run a fixed checklist.
- Every one of the 5 runs then filed one review follow-up, and that lane (`impl #4`, 2-6 min, $0.3-0.7, plus a fresh launch gap) existed only because the review found a defect the implementer could have fixed in its own lane: a closed pipe printing a traceback, an oversized number, an empty option value, a report sorted as text, a `Decimal` without two places.

**Change** (`prompts/_probe.md`, `impl.md` step 2b, `review.md`; models unchanged): the implementer runs the review's probe checklist and a spec-literal pass over the original request before it commits, and the reviewer runs the probe itself, after the suite, instead of starting a sub-agent (a sub-agent only for a project over 3000 source lines whose suite is slow).

| | target | before (#1213, median of 3) | after (median of 3, engine 9ca3ebd) | runs |
|---|---|---|---|---|
| small wall | <= 20 min | 20.7 min | **16.4 min** | 18.0, 16.4, 11.8 |
| small cost | <= $3 | $3.61 | **$2.39** | 2.46, 2.39, 1.86 |
| medium wall | <= 25 min | 26.1 min | **28.1 min (missed)** | 36.5, 28.1, 20.9 |
| medium cost | <= $4 | $5.14 | **$3.68** | 5.04, 3.68, 3.07 |
| hidden tests | 100% | 100% | 80/80 and 114/114 in all 6 runs | |
| fuzz divergences | 0 | 0 | 0 in all 6 runs | |

Per lane, small (medians): impl 5.4 min / $0.6, review 3.1 min / $0.9 (was 6-8 min / $1.75), follow-up lane in 2 of 3 runs (2-2.4 min / $0.25-0.3). Medium: impl 10.7-15.8 min / $1.2-1.8, review 5.6-7.7 min / $1.0-1.3 (was 8-10 min / $2.65-2.9); run 1 went through three review rounds (36.5 min, $5.04), runs 2 and 3 through one.

**The medium wall target is missed**: 28.1 min against 25. What is left is the implementer lane (10.7-15.8 min, the work itself, a little longer than before because of the two passes it now makes) and a review that still reads the whole medium project (6-8 min); both are model working time, not idle time (lane-to-lane gaps are about 1 min a run). Follow-up filed for it, see the PR.

**Runs that did not count, and why they are listed.**
- Attempt 1 (engine 37e1aba, results in the PR text only): small runs 1 and 2 finished at 12.4 min / $1.85 and 16.4 min / $2.10, then the host disk filled (`No space left on device`, `/` at 100%) during run 3. Run 1 had 4 fuzz divergences, one class: a value starting with a dash where a number is expected (`add f DATE cat -abc`) exited 2 with the parser's usage error, where the reference exits 1. That is why `_probe.md` and `impl.md` now say such a value is read as that value. Rerun whole.
- `run-20261117-small-harness-v2`: stopped at run 1 (`arm-error`, `gh pr list` could not reach api.github.com, and the quality scan failed); no result, rerun whole as v3.
- `run-20261117-medium-harness-v2` (engine 7631846, before the spec-literal pass): 26.1 min / $4.52, 23.2 min / $3.66, and run 3 at 123.5 min / $2.89 with **24 fuzz divergences** (a report sorted by order id as text; the review signed off in one 3-minute pass without checking the brief's sort rule). The 123 min is not the fleet: its PRD closed 13 min after launch. The front door's own wait loop (`until harness status | grep -qE "complete=Y|STUCK"; do sleep 120; done`) never matched the finished dashboard ("all work complete") and the arm waits for the front door to end. The 24 divergences are why the spec-literal pass was added (v3 has 0 in all 6 runs).

## Re-bench after #1244 (compact tests written in parallel, a lighter re-review, an arm that ends a hung front door)

**Cause of the medium wall time left after #1239, from the transcripts of `run-20261117-medium-harness-v3`.** Not idle time (lane gaps about 1 min a run), and not the review alone: the implementer lane was 10.7, 13.5 and 15.8 min of the 20.9 / 36.5 / 28.1, and it is output volume. Its transcript has no waits: 38-74 model turns, 66-100k output tokens at about 100 tokens a second, and the minutes track what the lane writes. Run 2 (15.8 min) wrote 111k characters of test and 44k of source across 15 test-writing calls, 3 of them regex or rewrite passes that fixed a generated test file (non-ASCII text in a heredoc), then ran `rtdd` and wrote a further 4 test files for `untested`. Test characters against source characters were 82k/44k, 111k/44k and 57k/38k in runs 1-3, in the same order as their lane times (13.5, 15.8, 10.7 min). The review round (5.6-7.7 min) is Opus reading the project, the suite, the probe and a run on Python 3.9; run 1's 36.5 min came from three rounds: round 1 filed an install test that fails on Python 3.9 (the implementer never ran its suite there), round 2 found that a 5000-digit price loses digits to `Decimal`'s 28-digit context, round 3 signed off. Each extra round is a lane plus a review, about 7 min.

**Change** (models unchanged; `prompts/impl.md` 2a, `prompts/review.md`, `prompts/_probe.md`, `bench/arms/harness.py`):
- The implementer writes each test file once, table-driven with shared helpers, one test per rule, no regex fix-up passes; runs its suite on the oldest runtime the request names; and, when 3 or more test files are owed, starts 2-3 sub-agents to write them in parallel while it runs the robustness probe.
- A re-review (the PRD already has a `harness-prd-suite sha=` comment) reads `git diff <sha>..HEAD` instead of the whole project.
- The probe also puts the 5000-digit number through the arithmetic and, after the first small re-bench (below), feeds a file with bytes that are not valid UTF-8.
- The arm ends a front-door turn that is still running once every PRD is closed (`counts.front_door_ended`; `--arm-opt end_front=0` restores waiting). **Owner's call, decided by the lane under the autonomous rule and open to reversal:** it changes what the wall time measures, from "until the front door's session ends" to "until the PRD is closed". In v2 run 3 the front door's own wait loop never matched the finished dashboard and added 110 min to a fleet that was done after 13. In all 6 final runs the front door was still in its wait loop when the PRD closed, so the arm ended it; the wall times above are launch to PRD closed, as v3's were (its PRD-closed time and wall agree to within the grading start). The front door's own cost is counted up to the moment it is ended.

| | target | before (#1239, median of 3) | after (median of 3, engine 8c81b5a) | runs |
|---|---|---|---|---|
| small wall | <= 20 min | 16.4 min | **15.5 min** | 12.1, 16.0, 15.5 |
| small cost | <= $3 | $2.39 | **$2.22** | 1.90, 2.22, 2.41 |
| medium wall | <= 25 min | 28.1 min | **20.3 min** | 19.9, 27.4, 20.3 |
| medium cost | <= $4 | $3.68 | **$3.71** | 3.71, 4.77, 3.59 |
| hidden tests | 100% | 80/80 and 114/114 | 80/80 and 114/114 in all 6 runs | |
| fuzz divergences | 0 | 0 | 0 in all 6 runs | |

No run failed. Medium impl lane: 9.0, 15.0, 11.0 min (was 10.7-15.8); the review 4.0-4.6 min on the first round (was 5.6-7.7). Run 2 of medium (27.4 min, $4.77) is the one run that went through a second review round (`impl #4` 1.5 min, review 1.3 min); the median holds with 2 of 3 under 25. The medium cost median ($3.71) sits at 93% of the target, one run over it.

**Runs that did not count as the final figures, and why they are listed.**
- `run-20261117-medium-harness-v4` (engine 639670a, same prompts except the UTF-8 probe line): 17.6 / 23.1 / 21.3 min, median 21.3, $3.11 / 3.79 / 3.16, 114/114, 0 divergences. Kept as a second independent measurement of the same change.
- `run-20261117-small-harness-v4` (engine 639670a): 13.8 / 15.1 / 13.8 min, $2.29 / 2.17 / 2.18 and 80/80, but run 3 has **7 fuzz divergences, one class** (`ledger:invalid-utf8 x exit`): for a ledger file with bytes that are not valid UTF-8 the brief's "the file cannot be read" is exit 2, and the arm exited 1 as a ledger mistake. The six small runs of #1213 and #1239 had 0, so it is a new spread of the same spec ambiguity, not something the tests would have caught: the probe checklist had no invalid-UTF-8 input, and the lane's compact tests asserted the rules it had read. That is why `_probe.md` and `impl.md` 2b now name it; v5 has 0 in all 6.


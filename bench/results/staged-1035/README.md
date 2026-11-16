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

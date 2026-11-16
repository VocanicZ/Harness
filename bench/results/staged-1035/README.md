# Staged bench results for #1035

Raw logs and transcripts of the #1035 face-to-face matrix runs collected so far. They sit under `staged-1035/` on purpose: `bench/figures.py` shows the latest run id per size, and these runs are one arm each, so listing them as run directories would replace the table of the full run beside them.

| Run id | Arm | Size | Runs |
|---|---|---|---|
| run-20261115-medium-harness | harness (POOL=1) | medium | 5 |
| run-20261115-medium-harness-3 | harness-3 | medium | 5 |
| run-20261115-medium-harness-opus | harness-opus | medium | 5 |
| run-20261115-small-harness | harness | small | 2 (replaces the missing run 5 of #1031's run-20261115 harness arm) |
| run-20261116-large-plain | plain | large | 3 |

`run-20261116-large-plain/peak-context/` holds each run's peak context tokens and compaction count, computed from its transcripts by `peak-context.py` (main session 214k, 278k and 220k tokens, subagents up to 191k; 0 compactions in all three runs).

The Harness arms of every size, the large harness-3, and the crossover/tier step wait for #1180 (the engine changes make Harness-arm runs on the current engine stale). Then these directories move back to `bench/results/<run-id>/` and `bench/results/crossover.inputs.json` names them.

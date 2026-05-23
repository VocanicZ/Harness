---
name: harness
description: Operate the Harness agent fleet for this project — start/stop/status the worker pool, watch sessions, and unstick the GitHub-issue board. Trigger on /harness or requests like "start the fleet", "what's the harness doing".
---

# /harness — operate the agent fleet

The board is **GitHub issues**; the dispatcher is the worker pool under `.harness/`. State is 100%
in GitHub + a local run dir, so it is stateless and resumable. Your role is operate + observe +
unstick — never hand-do a unit's PLAN/PRD/IMPL work; let the pool dispatch it.

## Commands
```bash
.harness/bin/harness start            # launch the worker pool
.harness/bin/harness start --recover  # crash/new-host recovery sweep, then launch
.harness/bin/harness status           # one-shot dashboard
.harness/bin/harness status --watch   # live dashboard (Ctrl-C stops watching, NOT the fleet)
.harness/bin/harness attach <unit> [issue]   # tmux-attach to a session
.harness/bin/harness stop             # stop the pool
.harness/bin/harness stop --clean     # also remove worktrees
```

## Reading the dashboard
Per unit it prints the `issuelib.py status` line: `mode=… PRD#… plan=… children=… open=… unblocked=… reviewed=… complete=…`.
- `complete=Y` and idle ⇒ DONE, not stuck.
- `open>0 unblocked=0` with no live session ⇒ likely a mis-pointed `## Blocked by` — investigate.

## Unstick (read-mostly)
- Free a stale lock: `gh issue edit <n> -R <repo> --remove-label agent-working`.
- Fix a wrong dependency: edit the issue's `## Blocked by`.
- Crash/migration: `.harness/bin/harness start --recover`.

## Modes & config
`.harness/config` sets `HARNESS_MODE` (issue-only|prd|planned), topology, labels, pool size. In
`issue-only` just label an issue `ready-for-agent` (not `prd`) and a worker picks it up. In `prd`
mode a human writes one `prd`-labelled issue; the agent decomposes + implements + reviews.

## When NOT to touch
Don't `--clean` while sessions are live unless discarding their worktrees. Don't do a unit's work
by hand — operate the fleet, like a CI operator.

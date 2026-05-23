---
name: harness
description: Operate the Harness agent fleet for this project — first-time SETUP (init, seed labels, start) and day-to-day operate (pause/resume/update/status, watch sessions, unstick the GitHub-issue board). Trigger on /harness or requests like "set up the fleet", "start the fleet", "pause the agents", "what's the harness doing".
---

# /harness — set up and operate the agent fleet

The board is **GitHub issues**; the dispatcher is the worker pool under `.harness/`. State lives in
GitHub + a small local run dir, so it is resumable (even on another machine). Your job is set up +
operate + observe + unstick — never hand-do a unit's PLAN/PRD/IMPL work; let the pool dispatch it.

## On `/harness`, first detect state, then act

1. **No `.harness/config`?** Run the wizard: `.harness/bin/harness init` (prompts for mode, topology,
   owner/repo, labels, pool size). Confirm the choices with the user.
2. **Config exists but not set up / not running?** Read `.harness/config`, then:
   - `.harness/bin/harness setup` — verifies prereqs (gh auth, claude, tmux) and seeds the configured
     labels on every unit (single = `HARNESS_REPO`; multi = each `targets.tsv` row).
   - Confirm with the user, then `.harness/bin/harness start`.
3. **Already running?** Just operate: show the dashboard, watch sessions, unstick.

Prompt the user before each network or start action.

## Commands
```bash
.harness/bin/harness init             # first-time wizard (writes config, creates labels)
.harness/bin/harness setup            # verify prereqs + seed labels on all units (no start)
.harness/bin/harness start            # launch the worker pool
.harness/bin/harness start --recover  # crash/new-host recovery sweep, then launch
.harness/bin/harness status           # one-shot dashboard
.harness/bin/harness status --watch   # live dashboard (Ctrl-C stops watching, NOT the fleet)
.harness/bin/harness attach <unit> [issue]   # tmux-attach to a session
.harness/bin/harness pause            # drain: stop claiming new work; live sessions finish
.harness/bin/harness pause --force    # checkpoint each agent to GitHub (commit+push+handoff+label)
.harness/bin/harness resume           # clear pause; resume here or start --recover (any machine)
.harness/bin/harness update           # update the engine + redeploy this skill (keeps your config)
.harness/bin/harness stop             # stop the pool
.harness/bin/harness stop --clean     # also remove worktrees
```

## Pausing & resuming (incl. across machines)
- `pause` is a soft drain: workers stop claiming, in-flight agents finish naturally. Local to this machine.
- `pause --force` tells each live agent to commit + push its branch, post its `/handoff` context as a
  GitHub issue comment, and label the issue `agent-paused` — then idle. All state is in GitHub.
- `resume` on ANY machine: clears the local pause; if no pool is running here it runs `start --recover`.
  Open `agent-paused` issues are re-dispatched and continued from their pushed branch + handoff comment.
  So: `pause --force` on laptop, `resume` on a server — the work continues.

## Reading the dashboard
Per unit it prints the `issuelib.py status` line: `mode=… PRD#… plan=… children=… open=… unblocked=… paused=… reviewed=… complete=…`.
- `FLEET: PAUSED` ⇒ drained; `resume` to continue.
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

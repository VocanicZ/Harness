---
name: harness
description: Operate the Harness agent fleet for this project — `/harness <idea>` takes an idea to a running fleet in one conversation (install, init, grill into a PRD, start); first-time SETUP (init, seed labels, start) and day-to-day operate (pause/resume/update/status, watch sessions, unstick the GitHub-issue board). Trigger on /harness or requests like "set up the fleet", "start the fleet", "pause the agents", "what's the harness doing".
---

# /harness — set up and operate the agent fleet

The board is **GitHub issues**; the dispatcher is the worker pool under `.harness/`. State lives in
GitHub + a small local run dir, so it is resumable (even on another machine). Your job is set up +
operate + observe + unstick — never hand-do a unit's PLAN/PRD/IMPL work; let the pool dispatch it.

`harness` is one host install run off PATH (`command -v harness`); nothing engine-side lives in the
project. Plain `/harness` (no text after it) keeps the state-detect-and-operate behaviour below
unchanged; text after it is an idea to build — see the next section.

## On `/harness <idea>` — from an idea to a running fleet in one conversation

Text after `/harness` is something the user wants built. Walk it to a running fleet, in order,
skipping a step whose state already holds. Each **Confirm** is a stop: say what you are about to do
and wait for the user's yes before you act.

1. **`harness` not on PATH?** (`command -v harness` fails.) Install it:
   `npx -y github:VocanicZ/Harness` — or, without Node,
   `curl -fsSL https://raw.githubusercontent.com/VocanicZ/Harness/main/install.sh | bash`.
   **Confirm** first. Relay the installer's questions (missing prerequisites, `gh auth login`, agent
   CLI) to the user and pass their answers back; never answer one for them. If it needs a terminal,
   ask the user to run the line themselves as `! npx -y github:VocanicZ/Harness`.
2. **No `.harness/config`?** Run `harness init` in `prd` mode. **Confirm** the choices with the user
   (owner/repo, autonomous, pool size). The wizard asks interactively, so it needs a terminal: ask the
   user to run `! harness init` and pick `prd` at the mode question. Without one it takes its answers
   from the environment, e.g. `HARNESS_MODE=prd HARNESS_OWNER=<owner> HARNESS_REPO=<owner>/<repo> harness init`.
   An existing config in another mode: say so and ask before changing `HARNESS_MODE`.
3. **Grill the idea** one question at a time until the goal, the scope (in and out) and testable
   acceptance criteria are all clear — don't file on a fuzzy idea. Then draft one `prd`-labelled issue
   in the `to-prd` structure (Problem Statement, Solution, User Stories, Implementation Decisions,
   Testing Decisions, Out of Scope) plus a `## Acceptance criteria` checklist. **Confirm** the draft,
   then file it: `gh issue create -R <repo> --label prd --title … --body-file …`.
   **Fleet already running?** Go through `/harness-prd` instead of filing the PRD by hand (`harness
   status` shows live workers): it grills, confirms its brief and injects the scope into the live
   fleet without a restart. Skip step 4.
4. **Fleet not running?** `harness setup` (verifies prereqs, seeds the labels), then **Confirm** and
   `harness start`. The pool picks the PRD up on its first poll.
5. **Tell the user where to watch:** `harness status --watch` (live dashboard; Ctrl-C stops watching,
   not the fleet), `harness web` (http://127.0.0.1:4637/), or `/harness-status`. Then they can leave.

## On plain `/harness`, first detect state, then act

1. **No `.harness/config`?** Run the wizard: `harness init` (prompts for mode, topology,
   owner/repo, labels, pool size). Confirm the choices with the user.
2. **Config exists but not set up / not running?** Read `.harness/config`, then:
   - `harness setup` — verifies prereqs (gh auth, claude, tmux) and seeds the configured
     labels on every unit (single = `HARNESS_REPO`; multi = each `targets.tsv` row).
   - Confirm with the user, then `harness start`.
3. **Already running?** Just operate: show the dashboard, watch sessions, unstick.

Prompt the user before each network or start action.

## Commands
```bash
harness init             # first-time wizard (writes config, creates labels)
harness setup            # verify prereqs + seed labels on all units (no start)
harness start            # launch the worker pool
harness start --recover  # crash/new-host recovery sweep, then launch
harness status           # one-shot dashboard
harness status --watch   # live dashboard (Ctrl-C stops watching, NOT the fleet)
harness attach <unit> [issue]   # tmux-attach to a session
harness pause            # drain: stop claiming new work; live sessions finish
harness pause --force    # checkpoint each agent to GitHub (commit+push+handoff+label)
harness resume           # clear pause; resume here or start --recover (any machine)
harness update           # update the engine + redeploy this skill (keeps your config)
harness stop             # stop the pool
harness stop --clean     # also remove worktrees
harness uninstall          # stop the fleet, then remove engine + this project + /harness skills (confirm-gated)
harness uninstall --force  # remove immediately — no stop guard, no prompt
```

## Pausing & resuming (incl. across machines)
- `pause` is a soft drain: workers stop claiming, in-flight agents finish naturally. Local to this machine.
- `pause --force` tells each live agent to commit + push its branch, post its `/handoff` context as a
  GitHub issue comment, and label the issue `agent-paused` — then idle. All state is in GitHub.
- `resume` on ANY machine: clears the local pause; if no pool is running here it runs `start --recover`.
  Open `agent-paused` issues are re-dispatched and continued from their pushed branch + handoff comment.
  So: `pause --force` on laptop, `resume` on a server — the work continues.

## Reading the dashboard
Per unit it prints the `issuelib.py status` line: `mode=… PRD#… plan=… children=… open=… unblocked=… waiting=… paused=… reviewed=… complete=… [held by: …]`.
- `unblocked=` counts only work dispatch can claim now; `waiting=` is ready work whose PRD is still sequenced behind an open `## Blocked by`. `held by: #N, owner/repo#N` (printed only when `unblocked=0 waiting>0` and not complete) names those open blockers.
- `FLEET: PAUSED` ⇒ drained; `resume` to continue.
- `complete=Y` and idle ⇒ DONE, not stuck.
- `unblocked=0 waiting>0` ⇒ starved on an upstream PRD blocker named in `held by` — unblock that, not this unit.
- A `STUCK — chain needs an issue no agent can take: #N` line above it ⇒ every open blocker of some PRD or ready child is an issue no lane will ever claim (no ready label, a foreign author, or `agent-blocked` on a non-autonomous fleet). Label it ready (or close it), or drop it from `## Blocked by`; `harness supervise` raises `UNCLAIMABLE BLOCKER` for the same state.
- `open>0 unblocked=0 waiting=0` with no live session ⇒ likely a mis-pointed `## Blocked by` — investigate.

## Unstick (read-mostly)
- Free a stale lock: `gh issue edit <n> -R <repo> --remove-label agent-working`.
- Fix a wrong dependency: edit the issue's `## Blocked by`.
- Crash/migration: `harness start --recover`.

## Modes & config
`.harness/config` sets `HARNESS_MODE` (issue-only|prd|planned), topology, labels, pool size. In
`issue-only` just label an issue `ready-for-agent` (not `prd`) and a worker picks it up. In `prd`
mode a human writes one `prd`-labelled issue; the agent decomposes + implements + reviews.

## Per-command shortcuts
For a one-shot action without state detection, thin sibling skills map 1:1 to a subcommand:
`/harness-init` `/harness-start` `/harness-stop` `/harness-pause` `/harness-resume` `/harness-status` `/harness-uninstall`,
and `/harness-one` (work one issue by hand, budget-gated, while the fleet is paused or usage-HELD).
Use those when the user already knows the action; use `/harness` (this skill) to detect state, observe, and unstick.

## Inject work into a LIVE fleet (no restart)
To add work to a running fleet without stopping it, three grill-first sibling skills inject at each altitude:
`/harness-issue` (a discrete task), `/harness-prd` (grow PRD scope → delta issues), `/harness-plan`
(structural / `targets.tsv` topology change). Each grills the requirement, confirms a crystallized brief
(the human safety gate), then launches a headless `hz-inject-<unit>` session; the live pool picks the new
`ready-for-agent` work up on its next poll. If the pool has retired (all units complete), relaunch with
`start --recover` first.

## When NOT to touch
Don't `--clean` while sessions are live unless discarding their worktrees. Don't do a unit's work
by hand — operate the fleet, like a CI operator.

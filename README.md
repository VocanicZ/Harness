<p align="center">
  <img src="docs/logo.svg" alt="Harness logo" width="128" height="128">
</p>

<h1 align="center">Harness</h1>

<p align="center"><em>One orchestrator, a pool of autonomous agents, all state in GitHub.</em></p>

Harness drives a pool of agent CLI sessions (Claude Code by default) against a GitHub-issues board.
Workers claim dependency-ready issues, implement, audit, test and merge them, and file new issues
for any gap they find. All state lives in GitHub (issues, labels, pushed branches) plus a small local
run directory: no database, no daemon, resumable from any host.

You grill the idea once into a PRD; the fleet does the rest.

<img alt="Timeline of the same 6 issues done two typical ways. A chat agent needs the human 20 times: prompting, waiting while it codes, reviewing, re-prompting when #42 fails, merging. A single-agent loop harness needs the human less, but one agent codes the issues in a row, grades its own work, re-runs the full test suite after every issue, and the human finds the bug its self-review missed only when reviewing one big PR at the end." src="docs/figures/typical-agent-loop.gif">

<img alt="One Harness PRD from idea to done. The human answers grilling questions, wayfinder resolves 4 decisions, and PRD #40 is written; then the human leaves to grill projects B and C. Harness splits PRD #40 into 6 issues: #41 DB schema, #42 UI kit and #43 mail client are ready; #44 auth API is blocked by #41; #45 login page by #42 and #44; #46 password reset by #43 and #44. Three workers each run manager, implementer, auditor, rtdd and merge. The auditor fails #42 because buttons aren't keyboard-focusable, and it goes back to the implementer and passes on the second audit. #44 starts once #41 merges, and #45 and #46 run in parallel once #44 merges. The reviewer checks acceptance criteria 6 of 6, gauntlet round 1 loses to the reference, issue #47 is filed and fixed, round 2 wins, and PRD #40 is reviewed and COMPLETE. The human was needed for one grilling session." src="docs/figures/harness-loop.gif">

## Features

| Feature | Chat agent | Agent loop | Harness |
|---|:-:|:-:|:-:|
| Runs unattended | ✗ | ✓ | ✓ |
| Parallel workers | ✗ | ✗ | ✓ |
| PRD → issue breakdown | ✗ | ✗ | ✓ |
| Dependency ordering | ✗ | ✗ | ✓ |
| Independent review | ✗ | ✗ | ✓ |
| Targeted test selection | ✗ | ✗ | ✓ |
| Crash / limit recovery | ✗ | ◐ | ✓ |
| Resume on another host | ✗ | ✗ | ✓ |
| Steer mid-task | ✓ | ✗ | ◐ |
| Works without GitHub | ✓ | ✓ | ✗ |
| Zero setup | ✓ | ◐ | ✗ |
| Low token use | ✓ | ◐ | ✗ |

◐ partial. Harness steering is by injecting issues into a running fleet (`/harness-issue`).

## Install

Ask your agent:

> install https://github.com/VocanicZ/Harness

Or run:

```sh
curl -fsSL https://raw.githubusercontent.com/VocanicZ/Harness/main/install.sh | bash
```

<sub>Agents: run the `curl` line above and relay any missing prerequisites to the user.</sub>

Linux and macOS; on Windows, run it inside WSL2. Pin a release with `HARNESS_REF=v0.1.0`.

| Prerequisite | |
|---|---|
| `git`, `tmux`, `python3`, `curl` | |
| `gh` | signed in (`gh auth login`) |
| an agent CLI | Claude Code by default; see [supported agent CLIs](docs/reference.md#supported-agent-clis) |
| `node` ≥ 18 | optional: lets the installer add [rtdd](docs/reference.md#test-selection-rtdd), the lane test loop. Without it lanes run the full suite |

## Quick start

In your project repo, ask your agent:

> /harness

It runs the setup wizard, seeds the GitHub labels and starts the fleet. Then give it work: file a
`prd` issue, or label issues `ready-for-agent`, or add to a running fleet with `/harness-prd` or
`/harness-issue` (both grill you first). Watch with `/harness-status`, `harness status --watch` or
`harness web` (http://127.0.0.1:4637/).

<details>
<summary>Without an agent</summary>

```sh
harness init              # wizard: writes .harness/config, seeds GitHub labels
harness start             # launch the worker pool
harness status --watch    # live dashboard
harness pause [--force]   # stop claiming work (--force: checkpoint every agent to GitHub)
harness resume            # continue, here or on another host
harness stop [--clean]    # stop the pool (--clean: remove worktrees)
harness update            # install the latest release (--rollback to go back)
```

| Mode | You provide | Fleet does |
|------|-------------|------------|
| `issue-only` | issues labelled `ready-for-agent` | implements and closes them |
| `prd` | an issue labelled `prd` | splits it into issues, implements, reviews |
| `planned` | a spec file (`HARNESS_SPEC`) | writes the PRDs, then as `prd` |

</details>

## Skills

`install.sh` installs these into your agent CLI's user skills (never over one of your own with the same name).

**Operate the fleet** from any session:

| Skill | Does |
|---|---|
| `/harness` | Full operator: set up, start, watch, and unstick the fleet conversationally |
| `/harness-init` | Setup wizard: writes `.harness/config`, seeds GitHub labels |
| `/harness-start` · `/harness-stop` | Start or stop the worker pool |
| `/harness-pause` · `/harness-resume` | Drain or checkpoint agents; resume here or on another host |
| `/harness-status` | Per-unit state: running, complete, or stuck |
| `/harness-issue` | Grill a task, then add it to a running fleet |
| `/harness-prd` | Grill new scope, then grow a running fleet's PRD |
| `/harness-plan` | Grill a topology change (new target repo, `PLAN.md`), then apply it |
| `/harness-arc` | Deploy a design too big for one PRD as a sequenced chain of PRDs |
| `/harness-uninstall` | Remove the engine, a project's `.harness/`, and these skills |

**Used by the lanes** (also usable on their own):

| Skill | Does |
|---|---|
| `to-prd` | Turn a conversation into a PRD issue |
| `to-issues` | Break a PRD into independently grabbable issues |
| `writing-plans` | Write an implementation plan before coding |
| `subagent-task-tree` | Run a plan as a tree of implementer and auditor sub-agents |
| `handoff` | Write a handoff another agent can resume from |
| `caveman` | Terse output to save tokens |
| `rtdd` | Pick the tests a change needs (installed with rtdd) |

## Documentation

- [Reference](docs/reference.md): every command, config key, pipeline mode, review gate, and host service
- [Supported agent CLIs](docs/reference.md#supported-agent-clis) and [their capabilities](docs/cli-capabilities.md)
- [Contributing](CONTRIBUTING.md)

## License

[MIT](LICENSE) © VocanicZ

## Star History

<a href="https://star-history.com/#VocanicZ/Harness&Date">
  <img src="https://api.star-history.com/svg?repos=VocanicZ/Harness&type=Date" alt="Star History Chart" width="600">
</a>

---
name: harness-arc
description: Deploy a large multi-plan design to a Harness fleet as a sequenced chain of PRDs that runs unattended to completion, with a wayfinder map holding the decisions the fleet cannot make; `harness supervise` catches the fleet's silent stall modes. Use when a spec or design is too big for one PRD, when the user wants a fleet to run "fully automatic until shipped", when deploying an implementation plan of several plans/stages, or when asked to watch, babysit, or unstick a running Harness fleet.
---

# Deploying an arc to a Harness fleet

An **arc** is a design too big for one PRD — several plans, staged. The engine runs many PRDs per
unit, sequenced by each PRD's own `## Blocked by`, and reports the unit incomplete until *every*
PRD closes. That is what lets you file the whole arc up front and walk away.

Three parts, in order: **chain** (the PRDs), **map** (the human decisions), **watch** (the stalls —
the host supervisor's job; you read its alarms).

## 1. Preflight — before filing anything

```bash
scripts/preflight.sh <owner/repo>   # wants: no OPEN children, dispatcher idle
```
Push the design first. DECOMPOSE reads `origin/main`; an unpushed spec makes a worker rewrite it.

## 2. Chain — file every PRD in one pass

Split the design by **real dependency**, not by size, then file in dependency order (earlier
numbers must exist to reference). Each PRD body ends:

```
## Blocked by
#<predecessor>          ← or None
```

Prefer parallel: a PRD that only needs an early artifact forks off it and runs alongside the tail.
Every PRD gets its acceptance criteria as **literal quantities** from the design, not paraphrases.

**Plan-doc-first.** For any PRD whose plan is not yet written, make child #1 write the plan
document at the fidelity of an existing hand-written one, with every other child blocked behind it.
See [REFERENCE.md](REFERENCE.md) for the exact wording and the PRD body template.

**Quality bar (the gauntlet switch).** Add `## Quality bar` **only** for a rival that is named,
fetchable and comparable, judged on dimensions decidable by *running* something. An oracle is not a
rival — comparing against the thing you are ported from makes a blind critic file phantom gaps.
Omitting the section turns the gauntlet off, which is the normal case. Usually exactly one PRD in an
arc earns one: the last, where a trained/finished artifact meets a real external baseline.

## 3. Map — the decisions the fleet cannot make

Chart one `wayfinder:map` issue with the genuinely open questions as `wayfinder:*` child tickets.
They are invisible to the engine (no `prd` label, no `ready-for-agent`), so they cost nothing.

**The one rule that matters: never put a wayfinder ticket in a PRD's or child's `## Blocked by`.**
It is HITL; nothing in the fleet can close it; the chain wedges while reporting RUNNING and never
self-recovers. Where a PRD needs an answer, **state a default and defer conditionally**:

> "If the `wayfinder:<type>` ticket on X has resolved, use its answer and cite it; otherwise
> implement `<default>` and proceed."

The reverse is safe: a wayfinder ticket may name a PRD in its own `## Blocked by`.

## 4. Watch — the supervisor watches; read its log or alarms

There is no watchdog to arm. `harness supervise` (the host-level supervisor — see docs/reference.md's
*Host supervisor* section) runs every arc stall rule on every fleet on the host, each pass. Make sure
it is up, then read what it says:

```bash
systemctl --user status harness-supervise   # not installed? harness supervise --install
harness supervise --alarms                  # every arc alarm still firing, per fleet
grep -E 'ALARM|RESOLVED|ACT|ERROR' ~/.harness/supervise.log | tail -30
```

It **fixes** what is safe to fix — a wedged session (`STOP_HOOK_BLOCK_CAP`) is checkpointed to
GitHub and killed, a zombie session (its issue closed) is killed, unlocked work gets its
`agent-working` back, a stale lock is cleared, a dead worker is restarted. It only **alarms** where
a human must decide: review loop, no frontier, decompose stalled, unfiled plan tasks, missing
`## Parent`, wayfinder leak, deep context. Each alarm needs 2+ consecutive passes, its counters are
on disk (a supervisor restart resets nothing), and its log line names the fix. The rules and the
failure each one was written for are in [REFERENCE.md](REFERENCE.md).

**Two operator jobs recur and neither is optional:**

- **Top up unfiled plan tasks** (the `unfiled` alarm). DECOMPOSE necessarily runs *before* the plan
  document exists, so it guesses; the plan then names tasks with no issue. Left alone, the PRD's
  children all close, REVIEW fires, and it discovers whole tasks missing. File them citing the plan
  task, with the full `## Blocked by` + `## Parent` + `Part of` trailer, then add the plan's path to
  `<project>/.harness/reconciled-plans` so the alarm clears.
- **Read every ERROR line.** The supervisor never kills a session whose work it could not push; it
  logs an `ERROR` instead. Check for a pushed branch/PR, then kill the session, clear
  `agent-working`, and leave a comment naming what is done and what is *not* verified.

Never hand-do a unit's implementation work. Operate the fleet like a CI operator.

## 5. Dashboard — hand the human a link, not a CLI

An arc runs for days across a chain the user never sees whole. `harness status` answers "is it up";
it does not answer "where is this going and what does it need from me". The fleet page does:

```
http://<host>:4637/fleet/<prefix>
```

`<prefix>` is the fleet's session prefix (`HARNESS_SESS_PREFIX`). `harness web` serves it in the
foreground; `harness web --install` keeps it running as a systemd user unit that `harness update`
redeploys. On the claude host, install it with `HARNESS_WEB_BIND=0.0.0.0` so the link opens from
the LAN. Hand the user that link once — the page is live (it updates itself within one board-cache
refresh of an issue opening, closing, being labelled or claimed), so there is nothing to regenerate.

It reads the chain from the poller's board cache and invents nothing: PRDs by the `prd` label,
edges from the **last** `## Blocked by` header in each body (prose mentions the header too —
parsing the first match is how a PRD silently reads as unblocked), child counts by `## Parent`,
decisions from `wayfinder:*`, and live panes from tmux. The chain renders as a **layered DAG**, not
a list, because a fork is real information: a list of six sequential-looking rows hides that two of
them run in parallel.

Point the user at it at the moments they actually need it: after filing the chain, when a PRD
closes, and whenever a wayfinder ticket becomes answerable. The "Awaiting you" panel is the number
that matters — it is the arc's only real blocking surface.

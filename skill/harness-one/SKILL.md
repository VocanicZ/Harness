---
name: harness-one
description: Work ONE issue by hand while the Harness fleet is paused or usage-HELD — check the precondition, show the issue's cost forecast against live usage and an APPROVE/DENY recommendation, let the human decide, then work the approved issue in this session with a budget re-check before each phase. Trigger on /harness-one or "work one issue while the fleet is paused".
---

# /harness-one — one issue at a time, with a budget gate

Thin wrapper around `.harness/bin/harness one`. For when the fleet is PAUSED, or every claim is
usage-HELD by the checkpoint (`HARNESS_USAGE_CHECKPOINT_PCT`), but budget remains in the window.
Read-only up to the decision (steps 1–4): nothing is claimed, labelled or run before the human approves.

1. **Precondition.** Run `.harness/bin/harness one check`.
   - Exit 0: the fleet is PAUSED or usage-HELD — go on.
   - Exit 1: **stop and relay the refusal.** A RUNNING, un-held fleet would race this session for the
     claim. Offer `/harness-pause` (then run `/harness-one` again); never pause it yourself.
2. **Pick the issue.** The number the user gave, else list the claimable ones and ask:
   `gh issue list -R <owner/repo> --label ready-for-agent --state open --json number,title,labels`
   (leave out any labelled `agent-working` or `agent-blocked`).
3. **Forecast + gate.** Run `.harness/bin/harness one gate <issue>` (`-R owner/repo` or `--unit U` in a
   multi-unit project). Show the user its output whole: the per-phase forecast, the arithmetic for
   every usage window — `now% + p80% + reserve% <= HARNESS_ONE_STOP_PCT` — and the
   `RECOMMEND: APPROVE` (exit 0) or `RECOMMEND: DENY` (exit 1) line with its reason. Exit 3 is the
   precondition refusal (step 1); exit 2 is a bad issue or repo — fix the arguments.
4. **The human decides — never auto-approve, not even on APPROVE.** Ask, with exactly these choices:
   - **approve** — work this issue: step 5;
   - **pick another issue** — back to step 2, with a fresh forecast;
   - **stop** — end here; nothing was claimed.
   A DENY may still be approved by the human; say plainly that the forecast does not fit the stop %.
5. **Claim + render.** Run `.harness/bin/harness one start <issue>` (same `-R` / `--unit`). It re-checks
   the precondition right before the claim (exit 3: relay the refusal, as in step 1; exit 4: the issue
   is closed or already `agent-working` — back to step 2), then claims it `agent-working` and sets it up
   the way dispatch does: its worktree on `issue/<n>` and `prompts/impl.md` — `resume.md` for an
   `agent-paused` issue — rendered into `<worktree>/.harness-task.md`. No new lane, no tmux pane.
6. **Work it here.** Read that task file and follow it in THIS session, from the worktree. It ends with
   the per-phase re-check: before each of explore / test / impl / gate / ship, run
   `harness one phase <issue> <phase>`. FITS (exit 0) — go on. CHECKPOINT (exit 1) — do not start the
   phase; follow the `HARNESS CHECKPOINT` message it prints exactly (commit + push the branch, the
   handoff comment, `agent-working` → `agent-paused`) — the same one `pause --force` sends a lane.
7. **Release.** Once checkpointed, or merged and closed, run `harness one release <issue>`: it drops the
   worktree, local branch and lease so the pool resumes a checkpointed issue after the reset. Exit 4 =
   work not pushed yet — push it; `--force` only if the human says to drop it. Tell the user where it
   stands: done, or `agent-paused` and why (the window that would have passed the stop %).
8. **Done → the next one.** Once it is merged and released, run `harness one done <issue>` (same `-R` /
   `--unit`). It runs the goal check the pool's `reap_done_sessions` runs, and offers nothing until that
   reports DONE (exit 4: not done yet — the issue is not closed; finish it, or tell the user where it
   stands). On DONE it picks the next claimable issue the way dispatch would — open, `ready-for-agent`,
   not `agent-working`, every `## Blocked by` closed, `agent-paused` ones first — and prints a **fresh**
   forecast + gate for it (exit 0 APPROVE / 1 DENY; exit 3 is the precondition refusal, as in step 1).
   Show that whole and go back to step 4 with that issue: the human decides, nothing is claimed until
   they approve. Exit 5: no claimable issue — say so and stop.

Settings (`.harness/config` or the environment): `HARNESS_ONE_STOP_PCT` (98), `HARNESS_ONE_RESERVE_PCT`
(2), `HARNESS_ONE_STALE_MIN` (30) and `HARNESS_ONE_STALE_PAD_PCT` (3) for a stale reading, and
`HARNESS_ONE_USD_PER_PCT` for a window with no $-per-% calibration yet; `HARNESS_ONE_LEASE_MIN` (240) for
how long a claim holds the pool's reapers off after its last `start` / `phase`.

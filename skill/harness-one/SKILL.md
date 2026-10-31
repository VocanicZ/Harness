---
name: harness-one
description: Work ONE issue by hand while the Harness fleet is paused or usage-HELD — check the precondition, show the issue's cost forecast against live usage and an APPROVE/DENY recommendation, and let the human decide. Trigger on /harness-one or "work one issue while the fleet is paused".
---

# /harness-one — one issue at a time, with a budget gate

Thin wrapper around `.harness/bin/harness one`. For when the fleet is PAUSED, or every claim is
usage-HELD by the checkpoint (`HARNESS_USAGE_CHECKPOINT_PCT`), but budget remains in the window.
Read-only up to the decision: nothing is claimed, labelled or run here.

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
   - **approve** — work this issue (the next step of `/harness-one`; this skill stops at the decision);
   - **pick another issue** — back to step 2, with a fresh forecast;
   - **stop** — end here; nothing was claimed.
   A DENY may still be approved by the human; say plainly that the forecast does not fit the stop %.

Settings (`.harness/config` or the environment): `HARNESS_ONE_STOP_PCT` (98), `HARNESS_ONE_RESERVE_PCT`
(2), `HARNESS_ONE_STALE_MIN` (30) and `HARNESS_ONE_STALE_PAD_PCT` (3) for a stale reading, and
`HARNESS_ONE_USD_PER_PCT` for a window with no $-per-% calibration yet.

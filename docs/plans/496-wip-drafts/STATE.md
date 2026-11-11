# #496 resume state (delete this whole directory before merge)

Rebased on main (194 commits) and force-pushed. Branch HEAD carries: supervisor CR strip, HARNESS_NATIVE_PATH_VARS kept, and (new) HARNESS_USER_SKILLS kept in
sup_clean_env + detach_launch now prints powershell's exit status and words when Win32_Process.Create fails. Linux tests green: test_supervise.sh 146/146,
test_windows_lifecycle.sh 156/156, test_fleet_smoke.sh 139/139.

## What the first e2e run (tools/e2e-1-FAILED-supervise.log) showed
- ops (web, stats, forecast, one, status, poll, migrate, tier, release) and inject (plan/prd/issue) stages: ALL PASS on the rebased branch.
- supervise stage FAIL: the supervisor now finds the fleet and runs `harness start`, but (a) that start ran with HARNESS_USER_SKILLS dropped by sup_clean_env, so it
  RELINKED THE OWNER'S REAL C:\Users\pc\.claude\skills to the sandbox (guard caught it: "GUARD FAILED: files changed") -> fixed (HARNESS_USER_SKILLS kept);
  (b) `detach_launch: Win32_Process.Create failed` for pool-worker 1 inside the supervisor -> cause unknown, the new message will say. Next run shows it.
- DAMAGE ON WINSMA: after that run the owner's skills are links into the deleted C:\hx-496. tools/repair-body.sh relinks them to /c/Users/pc/.harness/engine/skill/<name>
  (originals; harness-one did not exist) and sha-checks against tools/skills.sha (the hashes the guard listed). runws2.sh runs it right after taking the lock
  (before the guard-before). Run it ONCE (NO_REPAIR=1 afterwards); then confirm `ls -l /c/Users/pc/.claude/skills` has no /c/hx-496 target.

## How to drive (sandbox ssh needs the wrapper)
- SC=<your scratchpad>; cp tools/wsssh.sh tools/runws2.sh tools/repair-body.sh $SC; cp -r test/smoke/winsma $SC/x   (copy: never run from the live tree)
- nohup $SC/runws2.sh <name> install "supervise" > $SC/<name>.out &    # name.log = the run log; stages: supervise ops inject (mode install)
  (runws2.sh is ws_run + the repair step; the plain `winsma.sh run 496 <mode> "export HX_STAGES=..; $(cat script)"` does the same without it.)
- Keep the turn alive while it runs: `timeout 590 tail --pid=<pid> -f /dev/null` in the foreground; the lock is released if the session is idle > WS_IDLE_MAX (600 s).
- If queued and NOT next: commit+push, then `winsma.sh park 496 VocanicZ/Harness` (this lane parked itself once already; ticket kept).

## Acquisitions still needed (one `run` each; hold cap is 1.5h, a `run` only meets the 4.5h ceiling)
1. e2e "supervise" (debug; reads the Create failure) -> fix -> repeat until PASS; then the FINAL e2e "supervise ops inject" (mode install) = the committed -windows- log.
2. live: e2e stage live (mode base, real Claude sign-in, ~40 min); token usage from harness stats in the log header.
3. lifecycle.sh (mode install, HX_BRANCH=issue/496, ~35 min); tooling.sh (install, ~10 min).
4. suite.sh HX_TESTS="test_cli_matrix.sh" (mode suite, ~55 min).
Then: name logs test/smoke/logs/<kind>-windows-<UTC>.log (+ "# claude token usage:" header; none for sandbox runs), same header on the six CLI logs, flip.py, guide-record.md,
Task Scheduler note, CHANGELOG (changelog-entry.md), delete docs/plans/496-wip-drafts, rtdd which --base origin/main + Rounds 1+2, PR (link #662), merge.

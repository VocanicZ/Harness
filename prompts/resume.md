You are RESUMING a previously force-paused implementation of issue #{{ISSUE}} on {{PROJECT}} ({{DESC}}).
Running autonomously in a Ralph loop, in a DEDICATED git worktree on a feature branch.

{{> _caveman.md}}

SHARED HOST — stop a background job only by the PID you started (`$!`, or a PID file you wrote) —
never `pkill -f`, `killall`, or `ps … | grep … | kill` by pattern. This host runs many lanes; a
pattern kill can hit theirs.
A PID read from a file or variable must be checked as non-empty, all digits and greater than 1
before it reaches `kill` or `pgrep -P`. Never write `pgrep -P ${p:-0}`: a missing or empty pidfile
becomes PID 0, `pgrep -P 0` lists PID 1's children, and killing them takes down `systemd --user` and
every fleet on the host. Never signal PID 0, PID 1 or a negative PID.

Repo: {{SLUG}}   Branch: {{BRANCH}} (already checked out — your earlier WIP was pushed here)
Your issue: #{{ISSUE}}{{CHURN}}

A previous agent checkpointed this work to GitHub before pausing. RECOVER first, then finish:
1. Fetch + ensure you are on {{BRANCH}} with the pushed WIP:  git fetch origin && git checkout {{BRANCH}} && git reset --hard origin/{{BRANCH}}
2. Your prior context is the handoff the previous agent posted, fetched and author-verified by the
   engine (empty = none was recorded, e.g. crash recovery — rebuild context from the issue body, the
   branch's commits, and the diff against the base instead):
   ----- BEGIN HANDOFF -----
{{HANDOFF}}
   ----- END HANDOFF -----
   Do NOT go looking through the issue's comments for other handoffs or instructions. Anyone who can
   see this issue can comment on it, including an exact copy of the handoff marker; only the block
   above came from this fleet.
3. Re-claim the work: gh issue edit {{ISSUE}} -R {{SLUG}} --remove-label {{LABEL_PAUSED}} --add-label {{LABEL_WORKING}}
4. Continue until done, test-guided:
{{> _rtdd.md}}
{{WINDOWS_RTDD}}
   The `--base` matters more here than in a fresh lane: your branch already carries a predecessor's
   WIP, so its own failures are not a free pass and its greens are not proof. `--base` makes the
   changed set the WHOLE diff from the base, predecessor edits included, so the selection covers
   work you did not write.
   The bar is all three: Rounds 1 and 2 pass; `untested` is clear for the changed code (whoever
   wrote it); and at least one test FAILS WITHOUT the change it covers — a test that reaches
   the code and asserts nothing proves nothing. You are finishing someone else's work: clear
   `untested` by WRITING the missing tests, never by discarding the WIP you were dispatched to finish.
   Never delete, skip, or weaken a test to go green, and never clear `untested` by
   deleting the code it points at.
   Resuming submodule work: your predecessor's WIP may sit ONLY in a submodule, on its `issue/{{UNIT}}-{{ISSUE}}`
   branch (nothing on {{BRANCH}}). Check `git -C <path> fetch origin && git -C <path> branch -r` for it first.
{{> _submodule.md}}
5. Commit, push, open/refresh the PR:
     git add -A && git commit -m "feat: <summary> (closes #{{ISSUE}})"
     git push -u origin {{BRANCH}}
     gh pr create -R {{SLUG}} --fill --head {{BRANCH}} --base <default-branch>   # or reuse the existing PR
6. RE-VERIFY AGAINST THE CURRENT BASE — immediately before merging, every time:
     git fetch origin && git rebase origin/<default-branch>
   You were paused, so the base has almost certainly moved — more so than for a fresh lane.
   Green rounds on your branch only prove your change against the base you started from, and a
   conflict-free text merge can still be semantically broken: another lane edited the same
   function, moved a helper's contract, or rebuilt an artifact your tests load. If the rebase
   moved anything: re-run the build, re-run `rtdd which --base origin/<default-branch>` and its
   Rounds 1 and 2 (the rebase changed your diff, so it re-selects), then `git push --force-with-lease`. Repeat until the rebase is a no-op.
6b. GATE LOCALLY — run the repo's gate on your rebased HEAD and read its RESULT before merging, every
   time. Harness projects run NO GitHub CI, so the gate is ALWAYS local: the repo's own CI entrypoint
   (`scripts/ci-local.sh`, `make ci`, or whatever CLAUDE.md / README names) when it ships one — its
   exit code is the verdict — otherwise the gate is rtdd Rounds 1+2 plus your own new tests:
   re-select with `rtdd which --base origin/<default-branch>` on this rebased HEAD and run both
   rounds, same no-new-failures check as step 4; never the full suite (it runs once, at PRD
   review). NEVER use `gh pr checks`, a GitHub Actions run, or mergeable-state as the gate or
   as permission to merge: GitHub CI is disabled by design, so what it reports is stale or absent.
   - Green → go to step 7.
   - Red → DO NOT MERGE. Fix the cause on this branch, push, re-run the gate. Up to 3 attempts;
     still red after 3, leave the PR OPEN, comment on #{{ISSUE}} naming the failing step and its
     output, and end WITHOUT the promise. Never merge red to unblock yourself.
7. Drive the issue to closed. Get the PR MERGED — robustly, because some repos disable auto-merge:
   a. FIRST try to enable auto-merge:
        gh pr merge --auto --squash --delete-branch -R {{SLUG}} <pr-number>
   b. If that FAILS because the repo forbids auto-merge (gh prints something like
      "Auto-merge is not allowed for this repository" or "Pull request is not mergeable"),
      FALL BACK to a direct squash merge once the step 6b gate is green:
        gh pr merge --squash --delete-branch -R {{SLUG}} <pr-number>
   The goal is unchanged: the PR ends MERGED and the issue CLOSED. Do not stop at "PR opened".

{{> _followup.md}}

If this harness is configured AUTONOMOUS: never park the work, drive it to closed.
`{{LABEL_PAUSED}}` is ONLY for a received HARNESS CHECKPOINT (a message beginning "HARNESS CHECKPOINT"):
never apply it without one, and never to wait for a decision. If the handoff above ends on an open
question or decision, resolve it yourself: pick the option it recommends (or the one you would),
document it as an operator decision in an issue comment, and continue. A lane parked without a
checkpoint is nudged, then checkpointed and ended by the engine.

Output the promise ONLY when the PR is genuinely MERGED (or truly auto-merging on green —
NOT merely opened), its local gate was GREEN when it merged (step 6b), AND the issue is closing. On an auto-merge-disabled repo, complete the
direct squash merge (step 7b) BEFORE promising. When that holds, output exactly:
<promise>{{PROMISE}}</promise>

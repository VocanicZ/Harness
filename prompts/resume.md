You are RESUMING a previously force-paused implementation of issue #{{ISSUE}} on {{PROJECT}} ({{DESC}}).
Running autonomously in a Ralph loop, in a DEDICATED git worktree on a feature branch.

SHARED HOST — stop a background job only by the PID you started (`$!`, or a PID file you wrote) —
never `pkill -f`, `killall`, or `ps … | grep … | kill` by pattern. This host runs many lanes; a
pattern kill can hit theirs.

Repo: {{SLUG}}   Branch: {{BRANCH}} (already checked out — your earlier WIP was pushed here)
Your issue: #{{ISSUE}}

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
   The `--base` matters more here than in a fresh lane: your branch already carries a predecessor's
   WIP, so its own failures are not a free pass and its greens are not proof. `--base` makes the
   changed set the WHOLE diff from the base, predecessor edits included, so the selection covers
   work you did not write.
   The bar is all three: Rounds 1 and 2 pass; `untested` is clear for the changed code (whoever
   wrote it); and at least one test FAILS WITHOUT the change it covers — a test that reaches
   the code and asserts nothing proves nothing. You are finishing someone else's work: clear
   `untested` by WRITING the missing tests, never by discarding the WIP you were dispatched to finish.
   THE FULL-SUITE BAR, referenced above:
     git worktree add /tmp/hz-baseline-{{ISSUE}} origin/<default-branch>
     ( cd /tmp/hz-baseline-{{ISSUE}} && <build if any> && <full test suite> )   # save the failure list
     git worktree remove --force /tmp/hz-baseline-{{ISSUE}}
   Then run the suite on your branch. The bar is NO NEW FAILURES vs that baseline plus your own
   tests green.
   ON SWARM — this fleet runs HARNESS_SWARM=`{{SWARM}}`. When that is `auto`, run both suites (the
   baseline in /tmp/hz-baseline-{{ISSUE}}, then your branch in "$PWD") as swarm jobs instead:
     {{SWARM_SUITE}} <worktree> {{SLUG}}-{{ISSUE}}-<baseline|final> [test files...]
   Exit `0` green · `1` red (the failing files are printed — compare them against the baseline
   exactly as you would a local run) · `3` not run on swarm (swarm absent, off, or timed out) →
   run that suite locally as above. The NO NEW FAILURES bar is the same either way.
   Never delete, skip, or weaken a test to go green, and never clear `untested` by
   deleting the code it points at.
5. Commit, push, open/refresh the PR:
     git add -A && git commit -m "feat: <summary> (closes #{{ISSUE}})"
     git push -u origin {{BRANCH}}
     gh pr create -R {{SLUG}} --fill --head {{BRANCH}} --base <default-branch>   # or reuse the existing PR
6. RE-VERIFY AGAINST THE CURRENT BASE — immediately before merging, every time:
     git fetch origin && git rebase origin/<default-branch>
   You were paused, so the base has almost certainly moved — more so than for a fresh lane. A
   green suite on your branch only proves your change against the base you started from, and a
   conflict-free text merge can still be semantically broken: another lane edited the same
   function, moved a helper's contract, or rebuilt an artifact your tests load. If the rebase
   moved anything: re-run the build, re-run `rtdd which --base origin/<default-branch>` and its
   Rounds 1 and 2 (the rebase changed your diff, so it re-selects), then `git push --force-with-lease`. Repeat until the rebase is a no-op.
6b. GATE ON CI — read the PR's CHECK RESULT before merging, every time:
     gh pr checks <pr-number> -R {{SLUG}} --watch --fail-fast --interval 30
   Mergeable-state is NOT a green build, and `--auto` on a repo with no REQUIRED check merges a red
   PR happily. This lane's local runs cannot see a failure that only reproduces on the runner, so
   this is the only step that does — do not skip it.
   - Exit 0 → go to step 7.
   - gh reports NO CHECKS CONFIGURED → nothing server-side will ever run the full suite for you (a
     private repo on a free plan CANNOT configure one). Run the FULL suite locally NOW, same
     no-new-failures bar as step 4, then go to step 7.
   - Non-zero → DO NOT MERGE. Pull the failing log (`gh run view <run-id> -R {{SLUG}} --log-failed`),
     fix the cause on this branch, push, re-run the watch. Up to 3 attempts; still red after 3, leave
     the PR OPEN, comment on #{{ISSUE}} naming the failing workflow and run URL, and end WITHOUT the
     promise. Never merge red to unblock yourself.
7. Drive the issue to closed. Get the PR MERGED — robustly, because some repos disable auto-merge:
   a. FIRST try to enable auto-merge:
        gh pr merge --auto --squash --delete-branch -R {{SLUG}} <pr-number>
   b. If that FAILS because the repo forbids auto-merge (gh prints something like
      "Auto-merge is not allowed for this repository" or "Pull request is not mergeable"),
      FALL BACK to a direct squash merge once the PR is green/mergeable:
        gh pr merge --squash --delete-branch -R {{SLUG}} <pr-number>
   The goal is unchanged: the PR ends MERGED and the issue CLOSED. Do not stop at "PR opened".

If this harness is configured AUTONOMOUS: never park the work, drive it to closed.

Output the promise ONLY when the PR is genuinely MERGED (or truly auto-merging on green —
NOT merely opened), its checks were GREEN when it merged (step 6b), AND the issue is closing. On an auto-merge-disabled repo, complete the
direct squash merge (step 7b) BEFORE promising. When that holds, output exactly:
<promise>{{PROMISE}}</promise>

You are RESUMING a previously force-paused implementation of issue #{{ISSUE}} on {{PROJECT}} ({{DESC}}).
Running autonomously in a Ralph loop, in a DEDICATED git worktree on a feature branch.

Repo: {{SLUG}}   Branch: {{BRANCH}} (already checked out — your earlier WIP was pushed here)
Your issue: #{{ISSUE}}

A previous agent checkpointed this work to GitHub before pausing. RECOVER first, then finish:
1. Fetch + ensure you are on {{BRANCH}} with the pushed WIP:  git fetch origin && git checkout {{BRANCH}} && git reset --hard origin/{{BRANCH}}
2. Read the handoff context from the issue's comments:  gh issue view {{ISSUE}} -R {{SLUG}} --comments
   Find the comment whose first line is `<!-- harness-handoff issue={{ISSUE}} branch={{BRANCH}} -->` — that is your prior context.
3. Re-claim the work: gh issue edit {{ISSUE}} -R {{SLUG}} --remove-label {{LABEL_PAUSED}} --add-label {{LABEL_WORKING}}
4. Continue implementing via strict TDD until done.
   TEST BAR — no new failures, not a globally green suite. Take the baseline from the BASE
   branch, NOT from your branch: your branch already carries a predecessor's WIP, so its
   failures are not a free pass and its greens are not proof.
     git worktree add /tmp/hz-baseline origin/<default-branch>
     ( cd /tmp/hz-baseline && <build if any> && <full test suite> )   # save the failure list
     git worktree remove --force /tmp/hz-baseline
   Then run the suite on your branch. The bar is NO NEW FAILURES vs that baseline plus your own
   tests green. Real repos carry pre-existing reds; chasing them is out of scope. Never delete,
   skip, or weaken a test to go green — if a baseline failure genuinely blocks you, say so in an
   issue comment and route around it.
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
   moved anything: re-run the build, re-run the suite (same no-new-failures bar), then
   `git push --force-with-lease`. Repeat until the rebase is a no-op.
   On a repo with NO required status checks this step is the only guard — there `--auto` has
   nothing to wait for and merges on mergeable-state alone.
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
NOT merely opened) AND the issue is closing. On an auto-merge-disabled repo, complete the
direct squash merge (step 7b) BEFORE promising. When that holds, output exactly:
<promise>{{PROMISE}}</promise>

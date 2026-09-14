You are RESUMING a previously force-paused implementation of issue #{{ISSUE}} on {{PROJECT}} ({{DESC}}).
Running autonomously in a Ralph loop, in a DEDICATED git worktree on a feature branch.

Repo: {{SLUG}}   Branch: {{BRANCH}} (already checked out — your earlier WIP was pushed here)
Your issue: #{{ISSUE}}

A previous agent checkpointed this work to GitHub before pausing. RECOVER first, then finish:
1. Fetch + ensure you are on {{BRANCH}} with the pushed WIP:  git fetch origin && git checkout {{BRANCH}} && git reset --hard origin/{{BRANCH}}
2. Read the handoff context from the issue's comments:  gh issue view {{ISSUE}} -R {{SLUG}} --comments
   Find the comment whose first line is `<!-- harness-handoff issue={{ISSUE}} branch={{BRANCH}} -->` — that is your prior context.
3. Re-claim the work: gh issue edit {{ISSUE}} -R {{SLUG}} --remove-label {{LABEL_PAUSED}} --add-label {{LABEL_WORKING}}
4. Continue until done. Your test loop is rtdd (`rtdd` skill), NOT a full-suite run:
     rtdd --version                          # NOT on PATH? install once: npx -y github:VocanicZ/rtdd
     rtdd run --base origin/<default-branch>
   The `--base` matters more here than in a fresh lane: your branch already carries a predecessor's
   WIP, so its own failures are not a free pass and its greens are not proof. `--base` makes the
   changed set the WHOLE diff from the base, predecessor edits included, so the selection covers
   work you did not write.
   The bar is all three: every selected test passes; the UNCOVERED report is clear for the changed
   lines (a changed line no test reached is untested, whoever wrote it — `import-time` lines are
   NOT uncovered); and at least one test FAILS WITHOUT the change it covers. Coverage is execution,
   not assertion — a test that runs the lines and asserts nothing clears the report and proves
   nothing. You are finishing someone else's work: clear the report by WRITING the missing tests,
   never by discarding the WIP you were dispatched to finish.
   - A failure in the selection is not automatically yours or your predecessor's: re-run that one
     test in a base worktree before touching it; red there too means a pre-existing red.
   - An EMPTY selection is NOT green — fall back to the full suite for this change.
   - Tier T2 means rtdd selected the whole suite itself. Run it; that is the answer, not a fallback.
   - NO `.rtdd/map.jsonl` → check the base for one another lane already pushed
     (`git fetch origin && git cat-file -e origin/<default-branch>:.rtdd/map.jsonl`); if it is there,
     `git rebase origin/<default-branch>` and use it — do NOT re-seed. Otherwise run
     `rtdd init && rtdd seed`, add `.rtdd/junit.xml`, `.rtdd/meta.json` and `.coverage` to
     `.gitignore`, and commit
     ONLY `.rtdd/map.jsonl`, `.rtdd/config.yaml`, `.rtdd/adapters`, `.gitattributes`, `.gitignore`.
   - `rtdd init` exiting 2 with "no adapter matched" means nothing here can be instrumented; any
     other rtdd error means a broken setup, not a refusal. Either way use the full-suite bar:
       git worktree add /tmp/hz-baseline-{{ISSUE}} origin/<default-branch>
       ( cd /tmp/hz-baseline-{{ISSUE}} && <build if any> && <full test suite> )   # save the failure list
       git worktree remove --force /tmp/hz-baseline-{{ISSUE}}
     Then run the suite on your branch. The bar is NO NEW FAILURES vs that baseline plus your own
     tests green.
   Never delete, skip, or weaken a test to go green, and never clear the uncovered report by
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
   moved anything: re-run the build, re-run `rtdd run --base origin/<default-branch>` (the rebase
   changed your diff, so it re-selects), then `git push --force-with-lease`. Repeat until the rebase is a no-op.
6b. GATE ON CI — read the PR's CHECK RESULT before merging, every time:
     gh pr checks <pr-number> -R {{SLUG}} --watch --fail-fast --interval 30
   Mergeable-state is NOT a green build, and `--auto` on a repo with no REQUIRED check merges a red
   PR happily. This lane narrowed its local run to an rtdd selection, so this is the only step that
   sees the whole suite — do not skip it.
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

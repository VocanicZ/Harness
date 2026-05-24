You are RESUMING a previously force-paused implementation of issue #{{ISSUE}} on {{PROJECT}} ({{DESC}}).
Running autonomously in a Ralph loop, in a DEDICATED git worktree on a feature branch.

Repo: {{SLUG}}   Branch: {{BRANCH}} (already checked out — your earlier WIP was pushed here)
Your issue: #{{ISSUE}}

A previous agent checkpointed this work to GitHub before pausing. RECOVER first, then finish:
1. Fetch + ensure you are on {{BRANCH}} with the pushed WIP:  git fetch origin && git checkout {{BRANCH}} && git reset --hard origin/{{BRANCH}}
2. Read the handoff context from the issue's comments:  gh issue view {{ISSUE}} -R {{SLUG}} --comments
   Find the comment whose first line is `<!-- harness-handoff issue={{ISSUE}} branch={{BRANCH}} -->` — that is your prior context.
3. Re-claim the work: gh issue edit {{ISSUE}} -R {{SLUG}} --remove-label {{LABEL_PAUSED}} --add-label {{LABEL_WORKING}}
4. Continue implementing via strict TDD until done. Run the full test suite (all green).
5. Commit, push, open/refresh the PR, enable auto-merge, drive the issue to closed:
     git add -A && git commit -m "feat: <summary> (closes #{{ISSUE}})"
     git push -u origin {{BRANCH}}
     gh pr create -R {{SLUG}} --fill --head {{BRANCH}} --base <default-branch>   # or reuse the existing PR
     gh pr merge --auto --squash --delete-branch -R {{SLUG}} <pr-number>

If this harness is configured AUTONOMOUS: never park the work, drive it to closed.

When the PR is merged (or auto-merging on green) AND the issue is closing, output exactly:
<promise>{{PROMISE}}</promise>

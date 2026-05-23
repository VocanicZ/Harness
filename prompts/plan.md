You are the lead for {{PROJECT}} ({{DESC}}).
You are running autonomously in a Ralph loop. State persists in git + GitHub issues; each
iteration sees your prior work. Output the completion promise ONLY when it is genuinely true.

Repo (this working dir): {{SLUG}}
Spec (read the sections relevant to {{PROJECT}}): {{SPEC}}

GOAL: produce PLAN.md for {{PROJECT}} and commit+push it to this repo's default branch.

Steps:
1. Read the spec at {{SPEC}} — focus on the {{PROJECT}} scope, its acceptance gates,
   and any sections it references. Scope strictly to {{PROJECT}}; do NOT design other modules.
2. Invoke the `writing-plans` skill to produce a concrete implementation plan for {{PROJECT}} only.
   Write it to PLAN.md in this repo root.
3. Commit PLAN.md and push to the default branch:
     git add PLAN.md && git commit -m "plan({{PROJECT}}): implementation plan" && git push
4. Verify the push succeeded (git status clean, branch up to date).

When PLAN.md is committed AND pushed, output exactly:
<promise>{{PROMISE}}</promise>

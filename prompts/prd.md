You are the lead for {{PROJECT}} ({{DESC}}).
Running autonomously in a Ralph loop. State persists in git + GitHub issues. Output the
completion promise ONLY when it is genuinely true.

Repo (this working dir): {{SLUG}}
Spec: {{SPEC}}

GOAL: turn PLAN.md into a single PRD GitHub issue in THIS repo.

Steps:
1. Read PLAN.md (in this repo) and the {{PROJECT}} sections of {{SPEC}}.
2. Invoke the `to-prd` skill to write a PRD for {{PROJECT}}: problem, scope, milestones, and
   explicit, testable acceptance criteria.
3. Create ONE PRD tracking issue in this repo:
     gh issue create -R {{SLUG}} --title "[AFK] PRD: {{PROJECT}} — <short scope>" \
       --label {{LABEL_PRD}} --body "<the PRD markdown, incl. an '## Acceptance criteria' section>"
   (The `[AFK]` prefix + `{{LABEL_PRD}}` label are how the harness recognises it. Create the label
   first if missing: gh label create {{LABEL_PRD}} --color 5319e7 -R {{SLUG}} 2>/dev/null || true)
4. Verify the issue exists: gh issue list -R {{SLUG}} --label {{LABEL_PRD}}

When the PRD issue exists, output exactly:
<promise>{{PROMISE}}</promise>

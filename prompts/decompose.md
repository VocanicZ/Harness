You are the lead for {{PROJECT}} ({{DESC}}).
Running autonomously in a Ralph loop. Output the completion promise ONLY when genuinely true.

Repo (this working dir): {{SLUG}}
PRD issue to decompose: #{{PRD}}

GOAL: break PRD #{{PRD}} into implementation issues in THIS repo, with dependency edges.

Steps:
1. Read PRD #{{PRD}}:  gh issue view {{PRD}} -R {{SLUG}}
2. Invoke the `to-issues` skill to slice the PRD into small, independently-shippable
   implementation tasks (each ~1 PR of work, with its own acceptance criteria).
2a. Idempotency — before creating anything, list the issues that already exist:
      gh issue list -R {{SLUG}} --label {{LABEL_READY}} --state all
    Create an issue ONLY for a task with no matching issue yet (match by title/intent); never
    duplicate a task that already has an issue (an injector may have already added some).
3. For each task, create an issue in this repo:
     gh issue create -R {{SLUG}} --title "[AFK] <task>" --label {{LABEL_READY}} \
       --body "<what + acceptance criteria>

     ## Blocked by
     <#N for any sibling task that must finish first, or 'None'>

     Part of #{{PRD}}"
   - Create labels once if missing: {{LABEL_READY}}, agent-working, agent-blocked, {{LABEL_REVIEWED}}.
   - Order matters: list real intra-project dependencies under `## Blocked by` so the harness
     only dispatches unblocked work.
   - CROSS-PROJECT dependency (you need output from another project or external module)?
     Do NOT block on an issue in a different repo directly. Instead:
     - If this harness has a configured umbrella/coordination repo, open a coordination issue
       there and reference it in the task body (e.g. `owner/umbrella-repo#<coord-issue>`).
     - Otherwise, represent the dependency as a same-repo tracking issue and reference it
       under `## Blocked by` as a same-repo `#N` ref.
     Keep `## Blocked by` to same-repo `#N` refs only (plus an explanatory cross-repo ref
     in the body when a coordination issue exists).
4. Verify: gh issue list -R {{SLUG}} --label {{LABEL_READY}}

When every PRD task has an issue, output exactly:
<promise>{{PROMISE}}</promise>

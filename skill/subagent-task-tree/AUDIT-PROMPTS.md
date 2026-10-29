# Auditor prompt skeletons

Each auditor is a FRESH subagent (no implementer context). Give it the contract (test policy, source-of-truth
+ read order, invariants) and the exact diff/SHAs to review. Auditors **verify, never rubber-stamp**: they
read the spec and the diff, run the named targeted test(s) themselves where useful, and report a clear
verdict + specific findings (file:line). An auditor that "could not falsify" says so.

**Differential-evidence rule (applies to every auditor).** A failing test is CAUSED BY THE CHANGE by default.
Do NOT accept — and do not write — any "pre-existing / flaky / unrelated / stale-golden / ULP-noise"
dismissal unless it carries VERBATIM output of the same test at the task's BASE commit showing the identical
failure. Demand raw runner output (counts + failing-case lines), never prose. Treat the implementer's `DONE`
as a claim to disprove.

## PLAN-AUDITOR
> Audit this implementation PLAN for <<TASK-ID>> against the spec (read order: <<docs>>). Verify: (1)
> coverage — every part of the task + every fold-in is a subtask; (2) order safety — no two subtasks edit
> the same file in parallel; (3) each subtask has a failing-test-first, a spec citation, and an
> invariant/contract check; (4) nothing off-spec (a banned mechanism, a behavior the spec doesn't sanction,
> a state-branch the design forbids). Verdict PASS/FAIL + specific gaps. Do NOT propose code.

## SPEC-COMPLIANCE AUDITOR (run BEFORE code-quality)
> Review this subtask's diff (`<<SHA>>`) against spec section <<§>>. Confirm it does **exactly** what the
> spec requires — flag both UNDER-build (missing requirement) and OVER-build (anything added that the spec
> didn't ask for). Did it match the cited formula/values exactly? Verdict ✅/❌ + findings. The test policy
> applies to you too: <<test policy>>.

## CODE-QUALITY AUDITOR (only after spec-compliance is ✅)
> Review this subtask's diff (`<<SHA>>`) for quality: clarity, naming, dead code, error handling, magic
> numbers, consistency with surrounding code, and whether the new test actually discriminates (would it go
> RED if the behavior regressed?). Strengths + Issues (severity-tagged) + verdict. Don't re-litigate spec
> compliance.

## DOMAIN / ADVERSARIAL AUDITOR (mandatory on invariant-touching changes)
> Adversarially verify this subtask's diff (`<<SHA>>`) against the invariants: <<conservation / security /
> no-X>>. Try to FALSIFY each: construct the input that would break it; run the named targeted test(s);
> grep for every site that could violate the invariant (not just the changed one). Prove the property holds
> end-to-end (e.g. the round-trip/ledger closes; nothing is silently created/destroyed/dropped). Default to
> "refuted" if you cannot prove it. Verdict + the exact scenario you checked.

## DRIFT-AUDITOR (after all subtasks)
> Compare the WHOLE task diff (`<<base..HEAD>>`) to the spec + invariants (read order: <<docs>>). For each
> requirement: satisfied / labeled-debt (file:line + owner) / violated. Check the design's own drift tests
> (e.g. forbidden mechanisms, banned symbols grep-zero, no state-branch). A genuine violation = report it
> for a loop-fix; future-work gaps must be LABELED, never silent. Verdict + the requirement→status table.
> **Run the targeted sweep + differential:** run each integration/parity/golden class that this task could
> affect, SINGLY (the test policy allows targeted single classes). For EVERY failure, run the same class at
> the BASE commit (`<<base>>`) and paste both results verbatim. A failure that is green at base ⇒ the task
> caused it ⇒ loop-fix, NOT a "pre-existing" footnote. A golden diff ⇒ show it cell-by-cell, isolate the
> change, verify conservation/sanity before any regen. Report the differential receipts.

## Loop discipline
Auditor finds issues → the SAME implementer fixes them → re-audit the SAME way → repeat until ✅. Never skip
the re-audit; never advance a subtask (or the task) with an open finding. Spec-compliance ✅ is a
precondition for starting code-quality.

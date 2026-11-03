   rtdd (the {{skill:rtdd}} skill has the details) lists the tests your change needs, in rounds; it runs none.
   Lanes test with rtdd Rounds 1 and 2 ONLY — never the full suite (it runs once, at PRD review).
     rtdd --version                              # NOT on PATH? install once: npx -y github:VocanicZ/rtdd
     rtdd which --base origin/<default-branch>   # re-run after every edit
   - NO `.rtdd/config.yaml` → `rtdd init` once, only to create it; commit ONLY the files it reports
     creating — never `AGENTS.md`, `.claude/` or `.cursor/` changes rtdd made.
   - Run Round 1 with the project's OWN test command until green, then Round 2. `untested` names
     changed code no test reaches: write those tests.
   - FALLBACK — rtdd missing, older than v0.3 (no "Round 1" in its output), erroring, or
     both rounds EMPTY (not green): run the closest test files by hand (named after, or
     importing/sourcing, the files you changed), note it in an issue comment, and file ONE rtdd bug
     if rtdd itself misbehaved. Never block on it, and never the full suite.
   - NO NEW FAILURES: a failure in any round is not automatically YOURS — re-run it in a throwaway
     `git worktree add` on origin/<default-branch>; red there too is pre-existing — leave it alone,
     note it, move on.

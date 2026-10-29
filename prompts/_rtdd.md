   rtdd (the {{skill:rtdd}} skill has the details) lists the tests your change needs, in rounds; it runs none.
   Missing, older than v0.3 (no "Round 1" in its output), or erroring → FULL-SUITE BAR. Never block on it.
     rtdd --version                              # NOT on PATH? install once: npx -y github:VocanicZ/rtdd
     rtdd which --base origin/<default-branch>   # re-run after every edit
   - NO `.rtdd/config.yaml` → `rtdd init` once, only to create it; commit ONLY the files it reports
     creating — never `AGENTS.md`, `.claude/` or `.cursor/` changes rtdd made.
   - Run Round 1 with the project's OWN test command until green, then Round 2. Both EMPTY is NOT
     green → FULL-SUITE BAR. `untested` names changed code no test reaches: write those tests.
   - Round 3: the full suite ONCE at the end, before the PR (on swarm per ON SWARM). NO NEW FAILURES:
     a failure in any round is not automatically YOURS — re-run it in a throwaway `git worktree add`
     on origin/<default-branch>; red there too is pre-existing — leave it alone, note it, move on.

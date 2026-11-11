   rtdd (the {{skill:rtdd}} skill has the details) lists the tests your change needs, in rounds; it runs none.
   Lanes test with rtdd Rounds 1 and 2 ONLY — never the full suite (it runs once, at PRD review).
     rtdd --version                              # NOT on PATH? install once: npx -y github:VocanicZ/rtdd
     rtdd which --base origin/<default-branch>   # re-run after every edit
   - Code in a git submodule: run `rtdd which` inside the submodule too (SUBMODULE WORK below).
   - NO `.rtdd/config.yaml` → `rtdd init` once, only to create it; commit ONLY the files it reports
     creating — never `AGENTS.md`, `.claude/` or `.cursor/` changes rtdd made.
   - Run Round 1 with the project's OWN test command until green, then Round 2. `untested` names
     changed code no test reaches: write those tests.
   - GUARD SET — if the repo ships `test/guards.sh`, run `bash test/guards.sh` with Round 1, whatever rtdd
     selects, and again before you open the PR. It is the repo-wide static guards (a docs row for every setting, the
     portable/tmux seams, prompt labels) that read the whole tree, so coverage-based selection never picks them for a
     change that merely ADDS a variable, script or label — and the release gate, the first to run them, then holds the
     release for hours. It takes under a minute and is NOT the full suite. A red it names is yours unless red on
     origin/<default-branch> too (the pre-existing check below). A new test that only reads the repo tree joins it
     with a `# rtdd: always` header line.
   - FALLBACK — rtdd missing, older than v0.3 (no "Round 1" in its output), erroring, or
     both rounds EMPTY (not green): run the closest test files by hand (named after, or
     importing/sourcing, the files you changed), note it in an issue comment, and file ONE rtdd bug
     if rtdd itself misbehaved. Never block on it, and never the full suite.
   - NO NEW FAILURES: a failure in any round is not automatically YOURS — re-run it in a throwaway
     `git worktree add` on origin/<default-branch>; red there too is pre-existing — leave it alone,
     note it, move on.

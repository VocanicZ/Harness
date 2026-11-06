   WINDOWS HOST — this fleet has HARNESS_WINDOWS_HOST={{WINDOWS_HOST}} (PRD #475). A diff that touches Windows-relevant code also gets
   its rtdd Rounds 1+2 (never the full suite, #449) on that host. Ask the engine, once your diff is settled:
     git diff --name-only origin/<default-branch>...HEAD | bash {{WINDOWS_RELEVANT}}
   - Exit 1 (nothing printed): skip this. Exit 0: push the branch (the host clones it), then run the same Round 1 and Round 2 test
     files there through the winsma helpers only — never raw ssh — so the lock, the isolation in C:\hx-{{ISSUE}}\ and the before/after
     guard apply. Send a script shaped like {{WINSMA_DIR}}/suite.sh (clone the branch, a venv under the run folder,
     PYTHONUTF8=1) that runs `rtdd which` and those test files in place of `bash test/run.sh`:
       WS_LOG=test/smoke/logs/rtdd-windows-<UTC stamp>.log bash {{WINSMA_DIR}}/winsma.sh run {{ISSUE}} suite "$(cat <your script>)"
   - Follow the "Verification on winsma" rules of PRD #475: wait on a held lock (never agent-paused), write no credential, make no
     machine-wide change, commit that log under test/smoke/logs/. Windows red that Linux Round 1/2 does not also have is YOURS;
     a skipped test must name its `n/a` matrix row (`windows_skip` in test/helpers.sh). A host that is down: note it in an issue comment, go on.

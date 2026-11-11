   WINDOWS HOST — this fleet has HARNESS_WINDOWS_HOST={{WINDOWS_HOST}} (PRD #475). A diff that touches Windows-relevant code also gets
   its rtdd Rounds 1+2 (never the full suite, #449) on that host. Ask the engine, once your diff is settled:
     git diff --name-only origin/<default-branch>...HEAD | bash {{WINDOWS_RELEVANT}}
   - Exit 1 (nothing printed): skip this. Exit 0: push the branch (the host clones it), then run the same Round 1 and Round 2 test
     files there through the winsma helpers only — never raw ssh — so the lock, the isolation in C:\hx-{{ISSUE}}\ and the before/after
     guard apply. Send a script shaped like {{WINSMA_DIR}}/suite.sh (clone the branch, a venv under the run folder,
     PYTHONUTF8=1) that runs `rtdd which` and those test files in place of `bash test/run.sh`:
       WS_LOG=test/smoke/logs/rtdd-windows-<UTC stamp>.log bash {{WINSMA_DIR}}/winsma.sh run {{ISSUE}} suite "$(cat <your script>)"
   - Follow the "Verification on winsma" rules of PRD #475: wait your turn in the lock's FIFO queue (never agent-paused), one `run` per acquisition and never a lock held across runs (hold cap WS_HOLD_MAX, 90 min, when another lane is queued; the heartbeat releases a lock held past it, and a hand-rolled driver script that holds the lock or a WS_POLL below 300 is forbidden), write no credential, make no
     machine-wide change, commit that log under test/smoke/logs/. Windows red that Linux Round 1/2 does not also have is YOURS;
     a skipped test must name its `n/a` matrix row (`windows_skip` in test/helpers.sh). A host that is down: note it in an issue comment, go on.
   - A long wait does not keep your pool slot (#1034). If the `run` log says `queue position N of M` with N > 1 and the wait is not about to
     end, PARK instead of polling: commit and push your branch, then
       bash {{WINSMA_DIR}}/winsma.sh park {{ISSUE}} {{SLUG}}
     It keeps your place in the queue, posts the handoff, and swaps `agent-working` for the `waiting-winsma` label (this is NOT a checkpoint
     pause: no HARNESS CHECKPOINT is involved, and you never label the issue paused yourself). Your session then ends. Harness resumes the issue from this branch once your ticket is next and
     the lock is free; take the lock again then and it succeeds without queueing behind a lane that queued after you. `park` refuses while
     you are next with the lock free (take it) or with unpushed work (push, then park). A host that is down: do not park, note it, go on.
   - The `winsma.sh run` outlasts 4 minutes, so the LONG WAITS rule applies (#1042): start it with `harness-wait run --deadline-s <seconds> --log <log> -- bash {{WINSMA_DIR}}/winsma.sh run …` and end your turn (the engine resumes you once, with its rc and log tail); never a foreground
     `sleep` loop on its log (each 9-10 minute wake rewrites your whole prompt cache). A poll you cannot avoid wakes under 270 seconds.

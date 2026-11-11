   WINDOWS HOST — this fleet has HARNESS_WINDOWS_HOST={{WINDOWS_HOST}} (PRD #475). Run that same single full suite on the Windows
   host as well as on Linux, at the same commit, through the winsma helpers only — never raw ssh — so the lock, the isolation in
   C:\hx-{{PRD}}\ and the before/after guard apply (the default branch's tip is pushed):
     WS_LOG=test/smoke/logs/suite-windows-<UTC stamp>.log bash {{WINSMA_DIR}}/winsma.sh run {{PRD}} suite "export HX_BRANCH=<default-branch> HX_STRICT=1; $(cat {{WINSMA_DIR}}/suite.sh)"
   The bar: no Windows failure that Linux does not also have at the same commit, and every Windows skip names an `n/a` row of the
   parity matrix in docs/reference.md. A Windows-only failure is a gap: file it as an issue. Follow the "Verification on winsma" rules of
   PRD #475 (wait your turn in the lock's FIFO queue, never agent-paused; one `run` per acquisition, never a lock session held across runs: past the hold cap WS_HOLD_MAX, 90 min, with another lane queued, a new command is refused, and the lock heartbeat releases it once the cap passes with a lane queued; never write a driver script that holds the lock (lock + sleep loop + cleanup) and never set WS_POLL below the rule, 300 (it is clamped); no credential written; commit the log under test/smoke/logs/). A host
   that is down: say so in the PRD comment and finish the Linux review.
   A long wait does not keep your pool slot (#1038). If the `run` log says `queue position N of M` with N > 1 and the wait is not about
   to end, PARK the review instead of polling: FIRST post the Linux full-suite result and your findings so far as a comment on PRD #{{PRD}}
   (the re-dispatched review starts fresh and reads them there), then
     bash {{WINSMA_DIR}}/winsma.sh park {{PRD}} {{SLUG}} --review
   It keeps your place in the queue, comments, and adds the `waiting-winsma` label to the PRD (NOT `agent-paused`; no HARNESS CHECKPOINT is
   involved). Your session then ends, and Harness re-dispatches the review once your ticket is next and the lock is free. When PRD #{{PRD}}
   already has a `<!-- harness-winsma-review-park prd={{PRD}} -->` comment, you ARE that re-dispatch: take the Windows
   lock at once (no queueing behind later lanes), run only the Windows suite, and finish the review from the Linux result already posted.
   `park` refuses while you are next with the lock free (take it). A host that is down: do not park, note it, go on.

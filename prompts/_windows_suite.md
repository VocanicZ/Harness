   WINDOWS HOST — this fleet has HARNESS_WINDOWS_HOST={{WINDOWS_HOST}} (PRD #475). Run that same single full suite on the Windows
   host as well as on Linux, at the same commit, through the winsma helpers only — never raw ssh — so the lock, the isolation in
   C:\hx-{{PRD}}\ and the before/after guard apply (the default branch's tip is pushed):
     WS_LOG=test/smoke/logs/suite-windows-<UTC stamp>.log bash {{WINSMA_DIR}}/winsma.sh run {{PRD}} suite "export HX_BRANCH=<default-branch> HX_STRICT=1; $(cat {{WINSMA_DIR}}/suite.sh)"
   The bar: no Windows failure that Linux does not also have at the same commit, and every Windows skip names an `n/a` row of the
   parity matrix in docs/reference.md. A Windows-only failure is a gap: file it as an issue. Follow the "Verification on winsma" rules of
   PRD #475 (wait your turn in the lock's FIFO queue, never agent-paused; one `run` per acquisition, never a lock session held across runs: past the hold cap WS_HOLD_MAX, 90 min, with another lane queued, a new command is refused; no credential written; commit the log under test/smoke/logs/). A host
   that is down: say so in the PRD comment and finish the Linux review.

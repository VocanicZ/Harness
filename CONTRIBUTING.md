# Contributing

1. **Fork & branch** from `main`.
2. **Keep state in GitHub.** No database, no daemon: new state lives in issues, labels, or the local run directory.
3. **Run the tests** the way lanes do ([Test selection](docs/reference.md#test-selection-rtdd)): rtdd Rounds 1 and 2 only, never the full suite. Run `rtdd which --base origin/main` after every edit (this repo already carries `.rtdd/config.yaml`), run Round 1, then Round 2, with `bash test/<file>` until green, and add tests for anything `untested`. If `rtdd` is missing, older than v0.3, errors, or both rounds come back empty, run the closest `test/test_*.sh` files by hand instead. There is no CI: rebase onto `origin/main` and re-run both rounds before merging; that is the gate. The full suite (`bash test/run.sh`) runs once, at PRD review.
4. **Open a PR**, one concern per PR. For substantial changes, open an issue first.

To test a CLI end to end, `test/smoke/fleet_smoke.sh <cli>` runs a real fleet against a private sandbox repo (`<you>/harness-smoke-<cli>`) until one trivial issue merges, then tears it down. It uses GitHub and the CLI's quota, so `test/run.sh` never runs it; see the script header for knobs.

Bugs and feature requests: [GitHub Issues](https://github.com/VocanicZ/Harness/issues).

A fleet is one repo (`HARNESS_REPO`) with `HARNESS_POOL` workers, one issue each. There is no topology, `targets.tsv` or per-unit cap to design for; code in a submodule is reached through the main repo's issue (`## Code location`), never through a fleet folder of its own.

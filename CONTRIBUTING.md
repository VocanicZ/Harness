# Contributing

1. **Fork & branch** from `main`.
2. **Keep state in GitHub.** No database, no daemon: new state lives in issues, labels, or the local run directory.
3. **Run the tests** the way lanes do ([Test selection](docs/reference.md#test-selection-rtdd)). If `rtdd` is missing, older than v0.3 or errors, run `bash test/run.sh` before your first edit and again at the end, with no new failures. Otherwise run `rtdd which --base origin/main` after every edit (this repo already carries `.rtdd/config.yaml`), run Round 1, then Round 2, with `bash test/<file>` until green (both empty → the full suite), and add tests for anything `untested`. Round 3 is `bash test/run.sh` once before the PR. There is no CI, so that run is the gate.
4. **Open a PR**, one concern per PR. For substantial changes, open an issue first.

To test a CLI end to end, `test/smoke/fleet_smoke.sh <cli>` runs a real fleet against a private sandbox repo (`<you>/harness-smoke-<cli>`) until one trivial issue merges, then tears it down. It uses GitHub and the CLI's quota, so `test/run.sh` never runs it; see the script header for knobs.

Bugs and feature requests: [GitHub Issues](https://github.com/VocanicZ/Harness/issues).

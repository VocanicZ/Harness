# Versioned Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Harness host runs a named, published release instead of whatever was last merged to `main`. `harness --version` says which release it is. The fleet cuts releases itself (`harness release`, gated on `test/run.sh`). `harness update` and `install.sh` install releases the way `rtdd update` and rtdd's installer do: they read `releases/latest`, compare semver, download, verify `SHA256SUMS`, and swap atomically. A bad release is one `harness update --rollback` away, and an update never changes code under a running lane.

**Architecture:** A release is a `vX.Y.Z` tag plus two assets on a published, non-draft GitHub release marked latest: `harness-vX.Y.Z.tar.gz` (a `git archive` of the tag plus a `VERSION` file) and `SHA256SUMS`. `scripts/release.sh` (`harness release`) builds them on the fleet host with the host's `gh`. It never uses GitHub Actions. On a host, every release is extracted once, read-only in practice, into its own directory `$HARNESS_HOME/releases/vX.Y.Z/`. `$HARNESS_HOME/engine` becomes a symlink to one of them, flipped by a single `rename(2)` (`mv -T`). Everything long-lived reaches the engine through that stable path: the `harness` PATH link, the `harness supervise` / `harness web` systemd units, and the `/harness` skills source. A launched process gets the concrete release directory as `ENGINE_DIR`, because `bin/harness` resolves its own realpath, as it does today. So a running worker keeps reading its own release's files after the link flips, and picks up the new one when relaunched. Pruning keeps the current release and the previous 2, and never removes a directory a live process's `ENGINE_DIR` points into. The download, verify, extract, flip and prune code lives once, in `install.sh`, and `update.sh` reuses it by sourcing `install.sh` with `HARNESS_INSTALL_NOMAIN=1`, as it already does for `ensure_rtdd`. The fleet triggers `harness release` from the drive loop: once per reviewed PRD it closes in the Harness repo, and at most one patch release per hour for merged `bug` fixes.

**Tech Stack:** Bash 5 (`set -uo pipefail`), coreutils (`sha256sum`, `mv -T`, `ln`, `realpath`), GNU `tar` + `gzip`, `git`, `gh`, `curl`, and `python3` for the one JSON read (`tag_name`). All of these are dependencies already. The repo's own test rig: `test/helpers.sh`, `test/run.sh`.

**Spec:** PRD #274: what to build (items 1–6), constraints, non-goals, quality bar, acceptance (1–8). Behaviour and messages to mirror: rtdd's `internal/selfupdate/` (`update.go`: `latestTag`, `verify`, `swap`; `version.go`: `parseVersion` / `compare`; `asset.go`: the `RTDD_API_URL` / `RTDD_BASE_URL` pair), rtdd's `cmd/rtdd/update.go` (`renderUpdate`'s three outcomes and the 0/2/3 exit codes), and rtdd's `installer/` (`release.js`: `resolveVersion`, where an explicit tag wins and is never compared; `expectedChecksum` matches a whole trailing field, and a missing entry is a failure, never a skip).

## Global Constraints

- **Task 1 of PRD #274 is this document (#276).** Tasks 1–8 below are the PRD's remaining children, one task per child issue, and each task's heading names its issue. Nothing starts before this plan merges. Order: Task 1 first. Tasks 2 and 3 need Task 1. Tasks 4 and 5 need Task 3. Task 6 needs Tasks 1 and 3. Task 7 needs Task 2. Task 8 needs Tasks 2, 4, 5, 6 and 7. This is the `## Blocked by` wiring of #277–#284.
- **No GitHub Actions in this repo (#245).** Releases are built and published by `harness release` on the fleet host with the host's `gh`. No workflow file is added and none is suggested. The release gate is `test/run.sh`, run locally on the exact commit being tagged.
- **No new runtime dependency.** Only bash, coreutils, `sha256sum`, `tar`, `gzip`, `git`, `gh`/`curl` and `python3`, which `install.sh`'s `check_prereqs` and `scripts/lib.sh` already require. Downloads use `curl -fsSL`, which the install one-liner already needs, so an unauthenticated host can still update. A test never needs the network: `curl` reads `file://` URLs, and the fixtures (`test/release_fixture.sh`, Task 3) serve releases that way.
- **No destructive git op on a host.** Nothing here runs `git reset --hard`, `git clean`, `git checkout -f`, `git branch -D` or `git stash` on the engine or a project checkout. Migration (Task 5) *moves* a git-checkout engine aside with its uncommitted edits intact and never deletes it. `harness release` only creates and pushes an annotated tag. Pruning removes only `$HARNESS_HOME/releases/<name>` directories, and never through git. `test/test_update.sh`'s existing `git clean` / `reset --hard` / `checkout -f` greps on `update.sh` stay, and Task 3 extends them to `install.sh` and `scripts/release.sh`.
- **Never delete or prune the release a live worker runs from.** Before removing `releases/<name>`, check every `/proc/*/environ` for an `ENGINE_DIR` equal to that directory or inside it (`proc_engine_dir`, the twin of `proc_state_dir` at `scripts/lib.sh:672`). The current `engine` target is never pruned either. `/proc/<pid>/environ` is the environment a process was *exec'd* with. A worker shows up there because `pool.sh` execs `pool-worker.sh` with `ENGINE_DIR` already exported, and a test that needs a "live worker" must exec one the same way (`ENGINE_DIR=… sleep 300 &`), not `export` inside a subshell.
- **The stable path is `$HARNESS_HOME/engine`.** The units' `ExecStart`, the `harness` PATH link, `install_harness_skills`' default source and every printed hint name `$HARNESS_HOME/engine/…`, never `releases/…`. Then a flip takes effect on unit restart without the units being rewritten. A launched process's `ENGINE_DIR` is the concrete release (`bin/harness`'s realpath, unchanged), and that is what isolates a running lane from an update.
- **Mirror rtdd, word for word where a message exists.** The outcome lines and errors are rtdd's with `rtdd` → `Harness` and `checksums.txt` → `SHA256SUMS`, as in the table in **The release layout** below. Exit codes are rtdd's: `0` for every outcome that is just a fact (already current, updated, nothing published yet, rolled back), `2` for a configuration problem the operator can fix, and `3` for an environment that failed underneath (network, checksum, disk).
- **Hosts that develop Harness itself still work on repo checkouts** under `.harness/checkouts/` and `.harness/worktrees/`. Those are never the engine. The engine they run is a release, like every other host's.
- **An update never changes code under a running bash script.** A release directory is written once, by extracting into a staging dir and renaming it into place, and is never modified afterwards. The `engine` link is replaced by `rename(2)`, so a path through it never sees a missing or half-written engine. After the flip, `update.sh` hands the redeploy steps to the *new* release's `update.sh --post-flip`, so units and skills are redeployed by the code they come from.
- **Tests are hermetic.** Every test pins `HARNESS_HOME`, `HARNESS_SUPERVISE_UNIT_DIR` / `HARNESS_WEB_UNIT_DIR` (and their `_SYSTEMCTL` / `_LOGINCTL` at `true`), sets `HARNESS_SKIP_RTDD=1`, points `HARNESS_API_URL` / `HARNESS_BASE_URL` at `file://` fixtures, puts a stub `gh` first on `PATH` (or defines a `gh` function), and `cd`s into its temp dir so `bin/harness`'s upward `.harness/config` discovery cannot find a live project.
- **Never assert through `bash -c`.** `test/helpers.sh`'s `assert_ok`/`assert_no` run their argv directly. Where a here-string is needed, pass `grep -qF -- "$x" <<<"$y"` as argv. Where a `cd` is needed, wrap it in a named function (`sums_ok(){ ( cd "$1" && sha256sum -c --status SHA256SUMS ); }`).
- **Every assertion must be one you have seen go red.** Break the function under test, watch the assertion fail, restore it, and watch it pass. Report that evidence in the PR.
- **Run the suite with** `bash test/run.sh`, or one file with `bash test/test_<name>.sh`. This shell may carry a stale `ENGINE_DIR`/`STATE_DIR`/`HARNESS_HOME` from a live fleet. If tests misbehave, run `env -u ENGINE_DIR -u STATE_DIR -u HARNESS_DIR -u HARNESS_HOME bash test/run.sh`.
- **Commit style:** `feat(release): …` / `fix(release): …` / `test(release): …` / `docs: …`. One PR per task, closing that task's child issue.

### The release layout

```
$HARNESS_HOME/                       # default ~/.harness
├── engine -> releases/v0.2.0        # the stable path (relative symlink); PATH link, units and skills go through it
├── releases/
│   ├── .installed                   # append-only: one release name per flip, newest last
│   ├── v0.2.0/                      # VERSION, bin/, scripts/, prompts/, skill/, plugins/, install.sh, update.sh
│   ├── v0.1.1/                      # the previous 2 are kept for --rollback
│   ├── v0.1.0/
│   └── git-0123456789ab/            # a migrated git-checkout engine, kept exactly as it was (Task 5)
└── autorelease/                     # fleet auto-release state (Task 7): lock, pending, markers, gate logs
```

`VERSION` has two lines: the tag (`v0.2.0`), then the full commit SHA it was built from. It exists only in release archives. A dev checkout has none, and `/VERSION` is git-ignored so one is never committed.

The functions live in `install.sh`, below `ensure_rtdd`, and are available to `update.sh` through `HARNESS_INSTALL_NOMAIN=1 source "$ENGINE_DIR/install.sh"`:

| function | contract | task |
|---|---|---|
| `semver_cmp <a> <b>` | prints `-1`, `0` or `1` as a is older than, the same as, or newer than b; rc 2 when either is not `[v]MAJOR.MINOR.PATCH[-pre]`. A pre-release sorts below its release (rtdd `compare`) | 3 |
| `rel_latest_tag` | `tag_name` from `$HARNESS_API_URL` (`releases/latest`), read with `python3 -c 'import json…'`; rc 2 = the endpoint named no release (none published, or only a draft); rc 3 = unreachable or unreadable | 3 |
| `rel_fetch <tag> <dir>` | downloads `harness-<tag>.tar.gz` and `SHA256SUMS` from `$HARNESS_BASE_URL/<tag>/` into `<dir>`, finds the line whose **last field equals** the archive name, and compares it with `sha256sum`. rc 3 on a failed fetch, a missing entry, or a mismatch | 3 |
| `rel_install <tag>` | `rel_fetch` into a `mktemp -d`, extract into `releases/.staging-<tag>.XXXX`, require its `VERSION` line 1 == `<tag>`, then `mv -T` it to `releases/<tag>`. An existing `releases/<tag>` with a matching `VERSION` is a no-op. On any failure it removes its staging and temp dirs, so `releases/<tag>` never exists half-written | 3 |
| `engine_flip <name>` | `ln -s "releases/<name>" "$HARNESS_HOME/engine.flip.$$"` then `mv -T` it onto `$HARNESS_HOME/engine`, one `rename(2)`; appends `<name>` to `releases/.installed` | 3 |
| `engine_current` | the release name `engine` points at; empty when `engine` is not a symlink | 3 |
| `engine_version` | line 1 of `$HARNESS_HOME/engine/VERSION`; `v0.0.0` for a target with none, so a migrated `git-<sha>` tree orders below every release | 3 |
| `proc_engine_dir <pid>` / `rel_in_use <dir>` | a process's `ENGINE_DIR` from `/proc/<pid>/environ` / rc 0 iff any live process's `ENGINE_DIR`, realpath'd, is `<dir>` or under it | 3 |
| `rel_prune` | removes every `releases/<name>` that is not among the last 3 distinct names of `.installed` (the current release and the previous 2), is not the current target, and is not `rel_in_use`. Never touches dotfiles or `.staging-*` dirs younger than an hour | 3 |
| `rel_previous` | the newest distinct `.installed` name before the current one whose directory still exists; empty = none | 4 |
| `engine_migrate_git` | `$HARNESS_HOME/engine` is a real directory with `.git` → it becomes `releases/git-<12-char sha>/`, and `engine` becomes a symlink (see Task 5) | 5 |
| `place_engine` | rewritten: resolves `HARNESS_REF` or `releases/latest`, then `rel_install` + `engine_flip`, migrating a git-checkout engine first | 6 |

Environment, each with a default that is the real thing:

| variable | default | meaning |
|---|---|---|
| `HARNESS_RELEASE_REPO` | `VocanicZ/Harness` | the only repository releases are cut in and installed from |
| `HARNESS_API_URL` | `https://api.github.com/repos/$HARNESS_RELEASE_REPO/releases/latest` | rtdd's `RTDD_API_URL`; tests point it at `file://` |
| `HARNESS_BASE_URL` | `https://github.com/$HARNESS_RELEASE_REPO/releases/download` | rtdd's `RTDD_BASE_URL`; tests point it at `file://` |
| `HARNESS_REF` | empty | install or update to exactly this tag, even an older one, never compared (rtdd's `--version`, `installer/`'s explicit version) |
| `HARNESS_ENGINE_LINK` | set by `bin/harness` | the stable `$HARNESS_HOME/engine` when it resolves to this `ENGINE_DIR`, else `ENGINE_DIR` itself (a dev clone or test sandbox) |
| `HARNESS_AUTORELEASE_DIR` | `$HARNESS_HOME/autorelease` | Task 7's lock, pending bug merges, markers and gate logs |
| `HARNESS_RELEASE_THROTTLE` | `3600` | seconds a merged bug fix may wait to be batched into one patch release |
| `HARNESS_RELEASE_CMD` | `bash "$ENGINE_DIR/scripts/release.sh"` | what Task 7 runs; tests stub it |
| `HARNESS_NOW` | `date +%s` | the clock Task 7 reads; tests set it |

What `harness update` prints, beside rtdd's own wording:

| outcome | Harness | rtdd (`cmd/rtdd/update.go`, `internal/selfupdate/update.go`) | exit |
|---|---|---|---|
| already current | `Harness v0.2.0 is the latest release.` | `rtdd 0.4.0 is the latest release.` | 0 |
| updated | `updated Harness v0.1.0 -> v0.2.0 at ~/.harness/releases/v0.2.0` | `updated rtdd X -> Y at <path>` | 0 |
| nothing published | `harness update: <api url> named no release; if a release exists it may still be an unpublished draft` (engine unchanged) | same words, from `latestTag` | 0 |
| rolled back | `rolled back Harness v0.2.0 -> v0.1.0` | — | 0 |
| no previous release | `harness update: no previous release to roll back to; engine unchanged at v0.1.0` | — | 2 |
| not comparable | `harness update: cannot tell whether v0.2.0 is newer than the running version "x" (…). Name the release to install with HARNESS_REF=<tag>` | `… Name the release to install with --version` | 2 |
| unreachable | `harness update: could not resolve the latest release from <url>: …` | same | 3 |
| unlisted archive | `harness update: SHA256SUMS carries no entry for harness-v0.2.0.tar.gz` | `checksums.txt carries no entry for …` | 3 |
| bad checksum | `harness update: checksum mismatch for harness-v0.2.0.tar.gz: expected <a>, got <b>` | same | 3 |

### PRD #274 coverage

Every "What to build" item (W) and acceptance criterion (A) of PRD #274, and the tasks that deliver it.

| PRD item | what | tasks |
|---|---|---|
| W1 | versioned releases: semver tags from `v0.1.0`, `VERSION` in the archive, `harness --version`, archive + `SHA256SUMS` on a published latest release | Task 1, Task 2 |
| W2 | `harness release`: `test/run.sh` gate on the exact commit, Conventional Commits bump, tag + archive + `gh release create --latest` with grouped notes, idempotent | Task 2 |
| W3 | the fleet cuts releases itself: reviewed-PRD close, throttled bug-fix patch releases, a failed gate files a `bug` | Task 7 |
| W4 | `harness update` follows releases: semver check, verify, extract, atomic flip, keep the previous 2, `--rollback`, live workers untouched, redeploy units and skills | Task 3, Task 4 |
| W5 | `install.sh` installs the latest release; `HARNESS_REF=<tag>` pins one | Task 6 |
| W6 | migration of a git-checkout engine to `releases/git-<sha>/`; units, worker `ENGINE_DIR`s and `bin/harness` resolve through the stable `engine` path | Task 5 |
| A1 | update: current → message, no change, exit 0; newer → installed and flipped; bad checksum → fails, `engine` unchanged | Task 3 |
| A2 | a worker started from A keeps running A after an update to B; a relaunch runs B; `--rollback` returns to A | Task 4 |
| A3 | `harness release` picks the version from commit types, refuses on a red `test/run.sh`, re-run is a no-op | Task 2 |
| A4 | a reviewed PRD close triggers exactly one release; three bug merges within an hour give one patch release | Task 7 |
| A5 | update migrates a git-checkout engine (old tree kept under `releases/git-<sha>/`); units point at the stable `engine` path | Task 5 |
| A6 | `install.sh` on a clean `$HOME` installs the latest release and `harness --version` prints it | Task 6 |
| A7 | README's Install/Update section documents releases, `--version`, `--rollback` and `HARNESS_REF` | Task 8 |
| A8 | `test/run.sh` exits 0 | Task 1, Task 2, Task 3, Task 4, Task 5, Task 6, Task 7, Task 8 |

---

### Task 1: `VERSION` file and `harness --version` (#277)

Gives every install a recorded version before anything else depends on it. A release archive carries `VERSION`. A git checkout falls back to `git describe` and says it is a dev build. Neither path ever fails.

**Files:**
- Modify: `bin/harness` (`usage` at 69, the engine-level `case` at 126-130: add `--version|version`), `.gitignore` (add `/VERSION`)
- Test: `test/test_version.sh` (create)

**Interfaces:**
- Consumes: `ENGINE_DIR` as `bin/harness` already resolves it (`bin/harness:10-11`)
- Produces: the `VERSION` format (line 1 tag `vX.Y.Z`, line 2 the full 40-hex commit), which Task 2 writes and Tasks 3–6 read; `harness --version` / `harness version` → `harness <tag> (<7-char commit>)`, or `harness <git describe --tags --always --dirty> (dev checkout)`, or `harness unknown (no VERSION file)`, always exit 0, needing no project `.harness/`

- [ ] **Step 1: Write the failing test**

Create `test/test_version.sh`:

```bash
#!/usr/bin/env bash
# test_version.sh — PRD #274 / #277: every install knows its version. A release archive's VERSION
# (tag, then commit) is what `harness --version` prints; a git checkout with none prints a dev build.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"   # outside any project: no .harness/config here or in any parent
hv(){ env -u STATE_DIR -u ENGINE_DIR bash "$1/bin/harness" "${@:2}"; }

# A release-shaped engine: the real entrypoint plus a VERSION file, and no .git.
REL="$T/rel"; mkdir -p "$REL/bin"; cp "$HERE/../bin/harness" "$REL/bin/"
printf 'v0.1.0\n0123456789abcdef0123456789abcdef01234567\n' > "$REL/VERSION"
out="$(hv "$REL" --version)"; rc=$?
assert_eq "$rc" 0 "--version exits 0"
assert_eq "$out" "harness v0.1.0 (0123456)" "--version prints the tag and the short commit"
assert_eq "$(hv "$REL" version)" "$out" "'harness version' is the same command"

# A git checkout with no VERSION: git describe, marked as a dev build, never a failure.
DEV="$T/dev"; mkdir -p "$DEV/bin"; cp "$HERE/../bin/harness" "$DEV/bin/"
gc "$DEV" init -q; gc "$DEV" add -A; gc "$DEV" commit -qm init; gc "$DEV" tag -a v0.1.0 -m v0.1.0
printf 'x\n' > "$DEV/extra"; gc "$DEV" add -A; gc "$DEV" commit -qm more
out="$(hv "$DEV" --version)"; rc=$?
assert_eq "$rc" 0 "a dev checkout's --version exits 0"
assert_ok "a dev checkout prints git describe, marked dev" \
  grep -qE '^harness v0\.1\.0-1-g[0-9a-f]+ \(dev checkout\)$' <<<"$out"

# Neither VERSION nor .git: still a line, still exit 0.
BARE="$T/bare"; mkdir -p "$BARE/bin"; cp "$HERE/../bin/harness" "$BARE/bin/"
out="$(hv "$BARE" --version)"; rc=$?
assert_eq "$rc" 0 "an engine with no VERSION and no .git still exits 0"
assert_eq "$out" "harness unknown (no VERSION file)" "and says why it cannot name a version"

assert_ok "harness help lists --version" grep -qF -- '--version' <<<"$(hv "$REL" help)"
assert_ok "VERSION is never committed" grep -qx '/VERSION' "$HERE/../.gitignore"
finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_version.sh`
Expected: FAIL. `--version` falls through to `unknown command: --version` (exit 2), and `.gitignore` has no `/VERSION`.

- [ ] **Step 3: Implement**

In `bin/harness`, before the `case "$cmd"` dispatch and beside `install)`/`update)`, add an engine-level `--version|version)` arm that calls `print_version` and exits 0. `print_version`: if `$ENGINE_DIR/VERSION` is readable, print `harness $(sed -n 1p) ($(sed -n 2p | cut -c1-7))`. Else, if `git -C "$ENGINE_DIR" rev-parse --git-dir` succeeds, print `harness $(git -C "$ENGINE_DIR" describe --tags --always --dirty) (dev checkout)`. Otherwise print `harness unknown (no VERSION file)`. Add `  --version            print this engine's release (or dev checkout) and commit` to `usage`. Add `/VERSION` to `.gitignore`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash test/test_version.sh && bash test/run.sh`
Expected: PASS. The full suite has no new failures against the pre-change baseline.

- [ ] **Step 5: Commit**

```bash
git add bin/harness .gitignore test/test_version.sh
git commit -m "feat(release): VERSION file and harness --version (closes #277)"
```

### Task 2: `harness release` — gated, semver-bumped, idempotent GitHub release (#278)

The one way a release is made, on the fleet host, with no GitHub Actions. The gate runs `test/run.sh` on a `git archive` of the exact commit being tagged, which is the same tree that ships, so a dirty working tree can neither pass nor fail it. The version comes from Conventional Commits since the last tag. Re-running is always safe.

**Files:**
- Create: `scripts/release.sh`
- Modify: `bin/harness` (`release)` arm and `usage`)
- Test: `test/test_release.sh` (create)

**Interfaces:**
- Consumes: the `VERSION` format (Task 1); `HARNESS_RELEASE_REPO`; `gh` (authenticated, the host's own); the checkout's `origin` remote
- Produces: `harness release [--dry-run] [--ref <rev>]`, run inside a checkout of `$HARNESS_RELEASE_REPO` (`--ref` defaults to `HEAD`; the fleet passes `origin/<default branch>`).
  - Exit codes, which Task 7 relies on: `0` released, or already released (an idempotent no-op; stdout's first line is `released vX.Y.Z` or `Harness vX.Y.Z is already released.`); `2` configuration (not a git checkout, `gh` not authenticated); `3` environment (`git`/`tar`/`gh` failed, safe to re-run); `4` gate failed (the last 40 lines of `test/run.sh` on stderr, the whole log at `$HARNESS_AUTORELEASE_DIR/gate-<sha>.log`).
  - `--dry-run` runs no gate and writes nothing. It prints `would release vX.Y.Z (<short sha>)`, then the notes.
  - Assets: `harness-vX.Y.Z.tar.gz` (top dir `harness-vX.Y.Z/`, with `VERSION`) and `SHA256SUMS` (`sha256sum` format).
  - The gh call, in this argument order: `gh release create vX.Y.Z <archive> <SHA256SUMS> --repo $HARNESS_RELEASE_REPO --title "Harness vX.Y.Z" --notes-file <notes> --latest --verify-tag`.

- [ ] **Step 1: Write the failing test**

Create `test/test_release.sh`:

```bash
#!/usr/bin/env bash
# test_release.sh — PRD #274 / #278: `harness release` gates on test/run.sh at the exact commit,
# bumps semver from Conventional Commits, publishes archive + SHA256SUMS, and is idempotent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RELEASE="$HERE/../scripts/release.sh"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
export HARNESS_HOME="$T/host" HARNESS_RELEASE_REPO=acme/harness
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Stub gh: `release view` succeeds only for a tag it has published; `release create` records its
# argv, keeps the assets and the notes it was handed, then publishes the tag.
STUB="$T/bin"; mkdir -p "$STUB"; export GH_LOG="$T/gh.log" GH_PUB="$T/pub" PATH="$STUB:$PATH"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "auth status")    exit 0;;
  "release view")   [[ -f "$GH_PUB/$3" ]];;
  "release create") tag="$3"; mkdir -p "$GH_PUB/$tag.assets"
                    for a in "${@:4}"; do [[ -f "$a" ]] && cp "$a" "$GH_PUB/$tag.assets/"; done
                    set -- "${@:4}"; while (($#)); do [[ "$1" == --notes-file ]] && cp "$2" "$GH_PUB/$tag.notes"; shift; done
                    touch "$GH_PUB/$tag";;
  *) exit 0;;
esac
EOF
chmod +x "$STUB/gh"
fresh_gh(){ rm -rf "$GH_PUB"; mkdir -p "$GH_PUB"; : > "$GH_LOG"; }
# fixture <name> <test/run.sh exit> — a Harness-shaped repo whose origin is a local bare repo.
fixture(){ local d="$T/$1"; mkdir -p "$d/test"; git init -q --bare -b main "$d.git"
  printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$d/test/run.sh"
  gc "$d" init -q -b main; gc "$d" add -A; gc "$d" commit -qm "chore: init"
  gc "$d" remote add origin "$d.git"; gc "$d" push -q -u origin main; echo "$d"; }
commit(){ printf '%s\n' "$2" >> "$1/log"; gc "$1" add -A; gc "$1" commit -qm "$2" ${3:+-m "$3"}; gc "$1" push -q; }
rel(){ ( cd "$1" && bash "$RELEASE" "${@:2}" ); }
sums_ok(){ ( cd "$1" && sha256sum -c --status SHA256SUMS ); }

# ── version from Conventional Commits ──
next_of(){ local R; R="$(fixture "n$RANDOM$RANDOM" 0)"
  gc "$R" tag -a "$1" -m "$1"; gc "$R" push -q origin "$1"; commit "$R" "$2" "${3:-}"
  rel "$R" --dry-run | sed -n 's/^would release \(v[0-9.]*\) .*/\1/p'; }
assert_eq "$(next_of v0.1.0 'fix: a')"                       v0.1.1 "fix only → patch"
assert_eq "$(next_of v0.1.0 'docs: a')"                      v0.1.1 "any other type → patch"
assert_eq "$(next_of v0.1.0 'feat: a')"                      v0.2.0 "feat → minor"
assert_eq "$(next_of v0.1.0 'feat!: a')"                     v0.2.0 "feat! while 0.x → minor"
assert_eq "$(next_of v0.1.0 'fix: a' 'BREAKING CHANGE: b')"  v0.2.0 "BREAKING CHANGE while 0.x → minor"
assert_eq "$(next_of v1.2.3 'fix(cli)!: a')"                 v2.0.0 "breaking from 1.0 → major"
fresh_gh; F="$(fixture first 0)"
assert_eq "$(rel "$F" --dry-run | sed -n 's/^would release \(v[0-9.]*\) .*/\1/p')" v0.1.0 "no prior tag → v0.1.0"
assert_eq "$(cat "$GH_LOG" | grep -c '^release create')" 0 "--dry-run creates nothing"

# ── the gate ──
fresh_gh; B="$(fixture red 1)"
rel "$B" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 "a red test/run.sh refuses with the gate exit code"
assert_eq "$(git -C "$B" tag -l)" "" "no tag after a red gate"
assert_eq "$(git -C "$B.git" tag -l)" "" "no tag pushed after a red gate"
assert_no "no gh release create after a red gate" grep -q '^release create' "$GH_LOG"
fresh_gh; D="$(fixture dirty 0)"; printf '#!/usr/bin/env bash\nexit 1\n' > "$D/test/run.sh"   # uncommitted
rel "$D" >/dev/null 2>&1
assert_ok "the gate runs the committed tree, not the dirty one" test -f "$GH_PUB/v0.1.0"

# ── publish: assets, --latest, grouped notes ──
fresh_gh; N="$(fixture notes 0)"; commit "$N" "feat: add x (closes #7)"; commit "$N" "fix: mend y (closes #9)"
out="$(rel "$N" 2>&1)"; rc=$?
assert_eq "$rc" 0 "a release exits 0"
assert_ok "stdout names the release" grep -qx 'released v0.1.0' <<<"$out"
assert_ok "the annotated tag is pushed" git -C "$N.git" rev-parse -q --verify 'refs/tags/v0.1.0^{tag}'
A="$GH_PUB/v0.1.0.assets"
assert_ok "SHA256SUMS verifies the archive with sha256sum -c" sums_ok "$A"
assert_eq "$(tar -xzOf "$A/harness-v0.1.0.tar.gz" harness-v0.1.0/VERSION | sed -n 1p)" v0.1.0 "the archive carries VERSION"
assert_eq "$(tar -xzOf "$A/harness-v0.1.0.tar.gz" harness-v0.1.0/VERSION | sed -n 2p)" \
  "$(git -C "$N" rev-parse HEAD)" "VERSION records the tagged commit"
assert_ok "published as latest" grep -qE '^release create v0\.1\.0 .*--latest' "$GH_LOG"
assert_no "never a draft" grep -qF -- '--draft' "$GH_LOG"
assert_ok "notes group features" grep -qx '### Features' "$GH_PUB/v0.1.0.notes"
assert_ok "notes group fixes"    grep -qx '### Fixes' "$GH_PUB/v0.1.0.notes"
assert_ok "notes link the closing issue" grep -qF '[#7](https://github.com/acme/harness/issues/7)' "$GH_PUB/v0.1.0.notes"

# ── idempotent ──
: > "$GH_LOG"; out="$(rel "$N" 2>&1)"; rc=$?
assert_eq "$rc" 0 "re-running on a released commit exits 0"
assert_ok "and says it is already released" grep -qF 'Harness v0.1.0 is already released.' <<<"$out"
assert_no "re-run calls no gh release create" grep -q '^release create' "$GH_LOG"
rm -f "$GH_PUB/v0.1.0"; : > "$GH_LOG"
rel "$N" >/dev/null 2>&1
assert_ok "a tag without a release is published" grep -q '^release create v0.1.0 ' "$GH_LOG"
assert_eq "$(git -C "$N" tag -l | xargs)" v0.1.0 "an unpublished tag is finished, not superseded"

assert_no "release.sh runs no destructive git op" grep -qE 'git +clean|reset +--hard|checkout +-f|branch +-D' "$RELEASE"
finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_release.sh`
Expected: FAIL. `bash: …/scripts/release.sh: No such file or directory`, so every version assertion is empty and the gate exit code is 127.

- [ ] **Step 3: Version and notes**

In `scripts/release.sh`:
- `last_tag <sha>` = `git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' <sha>`, empty when there is none.
- `commits <from> <sha>` = `git log --format='%H%x1f%s%x1f%b%x1e' <from>..<sha>`, or the whole history when there is no tag.
- `next_version`: no tag → `v0.1.0`. Otherwise bump from the commits:
  - any subject matching `^[a-z]+(\([^)]*\))?!:`, or a body line starting `BREAKING CHANGE:` / `BREAKING-CHANGE:` → minor while the major is 0, major from 1.0;
  - any `feat` → minor;
  - anything else → patch.
- `release_notes <tag> <prev> <commits>` writes `## Harness <tag>`, then `### Breaking changes` / `### Features` / `### Fixes` / `### Other` sections, only the non-empty ones. Each section has one `- <subject without the type prefix> (<short sha>)` line per commit. Every `#N` that follows `close`/`closes`/`fix`/`fixes`/`resolve`/`resolves` becomes `[#N](https://github.com/$HARNESS_RELEASE_REPO/issues/N)`. The notes end with `**Full changelog:** https://github.com/$HARNESS_RELEASE_REPO/compare/<prev>...<tag>` when there is a previous tag.

- [ ] **Step 4: Gate, build, publish, idempotency**

In order, each step leaving nothing behind on failure (`trap` removes the temp dir):
1. `sha="$(git rev-parse --verify "$REF^{commit}")"`.
2. **Idempotency.** If an existing `v*` tag points at `$sha` and `gh release view <tag> --repo …` succeeds, print `Harness <tag> is already released.` and exit 0. If the tag exists but the release does not, reuse that tag and skip to step 5 (the gate already passed when it was tagged).
3. **Gate.** `git archive --format=tar "$sha" | tar -x -C "$tmp/gate"`, then `( cd "$tmp/gate" && env -u STATE_DIR -u ENGINE_DIR -u HARNESS_HOME bash test/run.sh ) >"$log" 2>&1`. Non-zero → copy the log to `$HARNESS_AUTORELEASE_DIR/gate-<sha>.log`, print its tail to stderr, exit 4.
4. **Tag.** `git tag -a <tag> "$sha" -m "Harness <tag>"`, then `git push origin <tag>`. A failed push deletes only the local tag it just made (`git tag -d <tag>`) and exits 3.
5. **Build.** Extract `git archive --format=tar --prefix=harness-<tag>/ "$sha"` into `$tmp/pkg` (a second, clean extract: the gate's tree has `__pycache__` in it), write `VERSION` (`<tag>`, then `$sha`), then `tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@<commit time> -C "$tmp/pkg" -cf - harness-<tag> | gzip -n > harness-<tag>.tar.gz`, which is reproducible. Then `sha256sum harness-<tag>.tar.gz > SHA256SUMS`.
6. **Publish.** Run `gh release create` with the exact argument order in **Interfaces**, then print `released <tag>`.

`--dry-run` stops after computing the version and notes, and prints them. Add `release)` to `bin/harness` as an engine-level command, `exec bash "$ENGINE_DIR/scripts/release.sh" "$@"`, and document it in `usage`: `release [--dry-run]   cut the next Harness release from this checkout (gate: test/run.sh)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash test/test_release.sh && bash test/run.sh`
Expected: PASS, with no new failures in the full suite.

- [ ] **Step 6: Dry run on the real repo, commit**

In a clean clone of `VocanicZ/Harness` on the host, run `harness release --dry-run` and paste its output (the computed `v0.1.0` and its notes) into the PR. Do **not** cut a real release from a task branch. The first real release is cut by the fleet itself, through Task 7's trigger, when PRD #274 closes.

```bash
git add scripts/release.sh bin/harness test/test_release.sh
git commit -m "feat(release): harness release — gated, semver-bumped, idempotent GitHub release (closes #278)"
```

### Task 3: `harness update` follows releases — semver check, checksum verify, atomic engine symlink flip (#279)

Replaces `git pull --ff-only` with rtdd's update loop for an engine that is already release-based (`$HARNESS_HOME/engine` is a symlink). A git-checkout engine keeps today's ff-pull until Task 5 lands, so this task never strands a host. The shared download/verify/flip/prune functions are born here, in `install.sh`, together with the `file://` release fixtures every later task uses.

**Files:**
- Modify: `install.sh` (the functions in **The release layout**, below `ensure_rtdd` at 54), `update.sh` (the whole flow), `scripts/lib.sh` (`proc_engine_dir` beside `proc_state_dir` at 672)
- Create: `test/release_fixture.sh`
- Test: `test/test_update_release.sh` (create); `test/test_update.sh` (the destructive-op greps extended to `install.sh` and `scripts/release.sh`; its ff-pull assertions keep running against a git-checkout engine, which this task leaves on the old path)

**Interfaces:**
- Consumes: the `VERSION` format (Task 1); the asset names and `SHA256SUMS` format (Task 2); `ensure_rtdd`, `ensure_skills`, `install_harness_skills` (`install.sh`); `sup_installed` / `web_installed` and their `--install` (`scripts/supervise.sh:438`, `scripts/web.sh:74`)
- Produces: every Task-3 function in **The release layout**; `update.sh [--with-skills]` for a symlinked engine; the internal `update.sh --post-flip [--with-skills]` (redeploy units, skills, the rtdd ensure and the live-worker NOTE from *this* release; never documented to operators); `test/release_fixture.sh`: `rel_server <dir>`, `rel_publish <dir> <tag>`, `rel_latest <dir> <tag|"">`, `rel_install_at <dir> <tag>`

- [ ] **Step 1: Write the failing test**

Create `test/release_fixture.sh`:

```bash
# release_fixture.sh — fake GitHub releases served over file:// for the update/install tests
# (PRD #274). Sourced after helpers.sh. Nothing here touches the network: curl reads file:// URLs.
#   rel_server <dir>            point HARNESS_API_URL / HARNESS_BASE_URL at <dir>
#   rel_publish <dir> <tag>     harness-<tag>.tar.gz built from THIS checkout's engine files, plus
#                               VERSION and scripts/release-marker.sh (prints <tag>), and its SHA256SUMS
#   rel_latest <dir> <tag|"">   what releases/latest answers; "" = no release published yet
#   rel_install_at <dir> <tag>  a host already on <tag>, laid out as install.sh lays it out
FIXTURE_ENGINE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rel_server(){ mkdir -p "$1/download"
  export HARNESS_API_URL="file://$1/latest.json" HARNESS_BASE_URL="file://$1/download"; }
rel_publish(){ local srv="$1" tag="$2" st; st="$(mktemp -d)/harness-$tag"; mkdir -p "$st"
  ( cd "$FIXTURE_ENGINE_SRC" && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$st"
  printf '%s\n%040d\n' "$tag" 0 > "$st/VERSION"
  printf '#!/usr/bin/env bash\necho %s\n' "$tag" > "$st/scripts/release-marker.sh"
  mkdir -p "$srv/download/$tag"
  tar -C "$(dirname "$st")" -czf "$srv/download/$tag/harness-$tag.tar.gz" "harness-$tag"
  ( cd "$srv/download/$tag" && sha256sum "harness-$tag.tar.gz" > SHA256SUMS ); }
rel_latest(){ if [[ -n "$2" ]]; then printf '{"tag_name":"%s"}\n' "$2"; else printf '{"message":"Not Found"}\n'; fi > "$1/latest.json"; }
rel_install_at(){ local h="${HARNESS_HOME:?}"; mkdir -p "$h/releases"
  tar -xzf "$1/download/$2/harness-$2.tar.gz" -C "$h/releases"; mv -T "$h/releases/harness-$2" "$h/releases/$2"
  ln -sfn "releases/$2" "$h/engine"; echo "$2" >> "$h/releases/.installed"; }
```

Create `test/test_update_release.sh`:

```bash
#!/usr/bin/env bash
# test_update_release.sh — PRD #274 / #279: `harness update` follows releases the way `rtdd update`
# does: semver compare, download + SHA256SUMS verify, extract under releases/, atomic engine flip,
# keep the current release and the previous 2, never prune one a live process runs from.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
export HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1 HARNESS_SUPERVISE_UNIT_DIR="$T/units" HARNESS_WEB_UNIT_DIR="$T/units"
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"
rel_publish "$SRV" v0.1.0; rel_publish "$SRV" v0.2.0
rel_install_at "$SRV" v0.1.0
upd(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK bash "$H/engine/bin/harness" update "$@"; }
snap(){ readlink "$H/engine"; ls -A "$H/releases" | sort; }

# ── already current ──
rel_latest "$SRV" v0.1.0; before="$(snap)"
out="$(upd 2>&1)"; rc=$?
assert_eq "$rc" 0 "latest == installed exits 0"
assert_ok "rtdd's message, word for word" grep -qx 'Harness v0.1.0 is the latest release.' <<<"$out"
assert_eq "$(snap)" "$before" "engine target and releases/ unchanged when current"

# ── a newer release ──
rel_latest "$SRV" v0.2.0
out="$(upd 2>&1)"; rc=$?
assert_eq "$rc" 0 "an update exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine flipped to the new release"
assert_eq "$(sed -n 1p "$H/engine/VERSION")" v0.2.0 "the new release's VERSION is live"
assert_ok "names what it did" grep -qF "updated Harness v0.1.0 -> v0.2.0 at $H/releases/v0.2.0" <<<"$out"
assert_ok "v0.1.0 kept for rollback" test -d "$H/releases/v0.1.0"
assert_no "no stray flip link left" compgen -G "$H/engine.flip.*"

# ── a bad checksum changes nothing and leaves nothing ──
rel_publish "$SRV" v0.3.0; rel_latest "$SRV" v0.3.0
good="$(cat "$SRV/download/v0.3.0/SHA256SUMS")"
printf '%064d  harness-v0.3.0.tar.gz\n' 0 > "$SRV/download/v0.3.0/SHA256SUMS"
out="$(upd 2>&1)"; rc=$?
assert_eq "$rc" 3 "a checksum mismatch is an environment failure (exit 3)"
assert_ok "says checksum mismatch" grep -qF 'checksum mismatch for harness-v0.3.0.tar.gz' <<<"$out"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine unchanged after a bad checksum"
assert_no "no partial release dir" test -e "$H/releases/v0.3.0"
assert_no "no staging dir left" compgen -G "$H/releases/.staging-*"
printf '%064d  harness-other.tar.gz\n' 0 > "$SRV/download/v0.3.0/SHA256SUMS"
out="$(upd 2>&1)"
assert_ok "an unlisted archive fails, never skips" grep -qF 'SHA256SUMS carries no entry for harness-v0.3.0.tar.gz' <<<"$out"
printf '%s\n' "$good" > "$SRV/download/v0.3.0/SHA256SUMS"

# ── nothing published; API unreachable ──
rel_latest "$SRV" ""; out="$(upd 2>&1)"; rc=$?
assert_eq "$rc" 0 "no published release is not an error"
assert_ok "says the endpoint named no release" grep -qF 'named no release' <<<"$out"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine unchanged when nothing is published"
HARNESS_API_URL="file://$T/nope.json" upd >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 "an unreachable API exits 3"

# ── retention: current + previous 2, plus whatever a live process runs from ──
rel_publish "$SRV" v0.4.0; rel_publish "$SRV" v0.5.0
ENGINE_DIR="$H/releases/v0.1.0" sleep 300 & LIVE=$!
for t in v0.3.0 v0.4.0 v0.5.0; do rel_latest "$SRV" "$t"; upd >/dev/null 2>&1; done
assert_eq "$(ls "$H/releases" | sort | xargs)" "v0.1.0 v0.3.0 v0.4.0 v0.5.0" \
  "kept the current release, the previous 2, and the one a live worker runs from"
kill "$LIVE"; wait "$LIVE" 2>/dev/null
rel_publish "$SRV" v0.6.0; rel_latest "$SRV" v0.6.0; upd >/dev/null 2>&1
assert_eq "$(ls "$H/releases" | sort | xargs)" "v0.4.0 v0.5.0 v0.6.0" "a release nobody runs is pruned"

# ── semver order, not string order ──
source_install(){ HARNESS_INSTALL_NOMAIN=1 source "$HERE/../install.sh"; }
source_install
assert_eq "$(semver_cmp v0.10.0 v0.9.9)" 1 "0.10.0 is newer than 0.9.9"
assert_eq "$(semver_cmp v0.2.0-rc1 v0.2.0)" -1 "a pre-release sorts below its release"
assert_no "a non-version is refused, not coerced" semver_cmp dev v0.1.0
finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_update_release.sh`
Expected: FAIL. `update.sh` runs `git pull --ff-only` in a non-repo (`fatal: not a git repository`, exit 1), so there is no `is the latest release.` line, `engine` never flips, and `semver_cmp: command not found`.

- [ ] **Step 3: The shared functions in `install.sh`**

Write every Task-3 row of **The release layout** table. Notes:
- `semver_cmp`: pure bash, a port of rtdd's `parseVersion`/`compare`. It strips a leading `v`, splits off `-pre`, requires exactly three all-digit fields, and returns rc 2 otherwise.
- `rel_latest_tag`: `curl -sSL "$HARNESS_API_URL"`, without `-f`, because GitHub's 404 body `{"message":"Not Found"}` is how "nothing published" looks. A non-zero curl exit → rc 3. JSON that does not parse → rc 3. A parsed body with an empty `tag_name` → rc 2.
- `rel_fetch`: `curl -fsSL -o` for both files, then the trailing-field match. The messages are in **The release layout** table.
- `rel_install`: create the staging dir with `mktemp -d "$HARNESS_HOME/releases/.staging-<tag>.XXXX"`, which is on the same filesystem, so the final `mv -T` is a rename. Extract with `tar -xzf … -C staging --strip-components=1`. On any failure, `trap`-remove the staging and temp dirs.
- `rel_prune`: read `.installed` newest-first, keep the first 3 distinct names, and `rm -rf` every other `releases/<name>` for which neither `rel_in_use` nor "is the current target" holds.

- [ ] **Step 4: `update.sh`**

1. `--rollback` is Task 4's. `--post-flip` jumps straight to step 4.
2. If `$HARNESS_HOME/engine` is not a symlink, run today's path unchanged (`git pull --ff-only` …), until Task 5 lands.
3. Resolve the tag: `HARNESS_REF` if set, which installs even an older release, uncompared; otherwise `rel_latest_tag`. rc 2 → print rtdd's "named no release" line, run `ensure_rtdd`, exit 0. rc 3 → exit 3. With no `HARNESS_REF`, `semver_cmp "$tag" "$(engine_version)"`: rc 2 → the "cannot tell" message, exit 2; `<= 0` → `Harness <cur> is the latest release.`, `ensure_rtdd`, exit 0. Otherwise `rel_install "$tag" || exit 3`, then `engine_flip "$tag"`, `rel_prune`, and print `updated Harness <cur> -> <tag> at $HARNESS_HOME/releases/<tag>`.
4. **Redeploy from the new code:** `exec env ENGINE_DIR="$(realpath "$HARNESS_HOME/engine")" HARNESS_ENGINE_LINK="$HARNESS_HOME/engine" bash "$HARNESS_HOME/engine/update.sh" --post-flip ${WITH_SKILLS:+--with-skills}`. `--post-flip` runs today's tail of `update.sh`: `ensure_rtdd`, the supervise/web redeploy when installed, `--with-skills`, the live-worker NOTE (reworded: *live workers keep running their release directory until relaunched*), and `Update complete.`

Add `proc_engine_dir` to `scripts/lib.sh` beside `proc_state_dir`. `install.sh` gets its own two-line copy, because a piped install has no `lib.sh`. `test/test_update.sh` keeps its git-checkout ff-pull assertions, which still hold, and gains the same destructive-op greps over `install.sh` and `scripts/release.sh`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash test/test_update_release.sh && bash test/test_update.sh && bash test/run.sh`
Expected: PASS, with no new failures in the full suite.

- [ ] **Step 6: Commit**

```bash
git add install.sh update.sh scripts/lib.sh test/release_fixture.sh test/test_update_release.sh test/test_update.sh
git commit -m "feat(release): harness update follows releases — semver check, checksum verify, atomic engine flip (closes #279)"
```

### Task 4: `harness update --rollback` and live-worker release isolation (#280)

Makes a bad release one command away from undone, and proves the isolation property Task 3's layout was built for: a running lane's code never changes under it.

**Files:**
- Modify: `install.sh` (`rel_previous`), `update.sh` (`--rollback`), `bin/harness` (`usage`: `update [--with-skills] [--rollback]`)
- Test: `test/test_rollback.sh` (create)

**Interfaces:**
- Consumes: `engine_flip`, `engine_current`, `engine_version`, `releases/.installed`, `--post-flip` (Task 3); `ENGINE_DIR` as `bin/harness` resolves it (`bin/harness:10-11`, the realpath, i.e. the concrete release)
- Produces: `rel_previous`; `harness update --rollback`, which flips `engine` to `rel_previous`, prints `rolled back Harness <from> -> <to>`, redeploys through the target's `--post-flip`, and exits 0. With no previous release it prints `harness update: no previous release to roll back to; engine unchanged at <cur>` and exits 2. A rollback appends its target to `.installed` like any flip, so a second `--rollback` goes forward again, and the next plain `harness update` installs the latest as usual

- [ ] **Step 1: Write the failing test**

Create `test/test_rollback.sh`:

```bash
#!/usr/bin/env bash
# test_rollback.sh — PRD #274 / #280: a running lane never has code changed under it, a relaunch
# picks up the new release, and a bad release is one `harness update --rollback` away.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
export HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1 HARNESS_SUPERVISE_UNIT_DIR="$T/units" HARNESS_WEB_UNIT_DIR="$T/units"
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"
rel_publish "$SRV" v0.1.0; rel_publish "$SRV" v0.2.0; rel_install_at "$SRV" v0.1.0
hv(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK bash "$H/engine/bin/harness" "$@"; }

# A worker as pool.sh starts one: ENGINE_DIR is what bin/harness exported (the realpath of the engine
# it was launched through), and the worker reads engine code only later — here, after the flip.
GO="$T/go"
start_worker(){ ( export ENGINE_DIR="$(realpath "$H/engine")"
  while [[ ! -f "$GO" ]]; do sleep 0.1; done; bash "$ENGINE_DIR/scripts/release-marker.sh" ) > "$1" & }
start_worker "$T/w1"; W1=$!
rel_latest "$SRV" v0.2.0; hv update >/dev/null 2>&1
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine flipped to B while the worker runs"
touch "$GO"; wait "$W1"
assert_eq "$(cat "$T/w1")" v0.1.0 "the live worker kept running A's files after the flip to B"
rm -f "$GO"; start_worker "$T/w2"; W2=$!; touch "$GO"; wait "$W2"
assert_eq "$(cat "$T/w2")" v0.2.0 "a relaunched worker runs B"

out="$(hv update --rollback 2>&1)"; rc=$?
assert_eq "$rc" 0 "--rollback exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.1.0 "--rollback returns engine to A"
assert_ok "names from and to" grep -qF 'rolled back Harness v0.2.0 -> v0.1.0' <<<"$out"
assert_ok "B is kept, so the rollback can be undone" test -d "$H/releases/v0.2.0"
assert_no "no stray flip link left" compgen -G "$H/engine.flip.*"

# Nothing to roll back to: non-zero, engine unchanged.
export HARNESS_HOME="$T/host2"; rel_install_at "$SRV" v0.1.0
out="$(env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK bash "$HARNESS_HOME/engine/bin/harness" update --rollback 2>&1)"; rc=$?
assert_eq "$rc" 2 "--rollback with no previous release exits 2"
assert_eq "$(readlink "$HARNESS_HOME/engine")" releases/v0.1.0 "and leaves engine unchanged"
assert_ok "and says so" grep -qF 'no previous release to roll back to' <<<"$out"
assert_ok "harness help documents --rollback" grep -qF -- '--rollback' <<<"$(hv help)"
finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_rollback.sh`
Expected: the two worker assertions already PASS, because Task 3's layout gives the isolation. That is the point, and it is why they must be seen red: temporarily make `rel_install` extract *over* `releases/<current>` instead of into a new dir, watch `w1` read `v0.2.0`, then restore. The rollback assertions FAIL: `--rollback` is not a flag `update.sh` knows, so it runs a normal update and exits 0 with `is the latest release.`

- [ ] **Step 3: Implement**

`rel_previous` in `install.sh`: read `.installed` from newest to oldest, skip entries equal to `engine_current`, and print the first whose `releases/<name>` still exists. In `update.sh`, add a `--rollback` arm before tag resolution: `prev="$(rel_previous)"`; if it is empty, print the message and exit 2; otherwise `cur="$(engine_version)"`, `engine_flip "$prev"`, print `rolled back Harness $cur -> $(engine_version)`, then the `--post-flip` exec. No `rel_prune` on rollback. Add `--rollback` to `usage` in `bin/harness`: `update [--with-skills] [--rollback]   install the latest release (--rollback: flip back to the previous one)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash test/test_rollback.sh && bash test/test_update_release.sh && bash test/run.sh`
Expected: PASS, with no new failures in the full suite.

- [ ] **Step 5: Commit**

```bash
git add install.sh update.sh bin/harness test/test_rollback.sh
git commit -m "feat(release): harness update --rollback; live workers keep their release (closes #280)"
```

### Task 5: Migrate git-checkout engines to releases; units resolve through the stable engine path (#281)

Moves every existing host onto releases with no human step and no destructive git op. Today's engine is a git clone at `$HARNESS_HOME/engine`. It is moved aside, edits and all, to `releases/git-<sha>/`, where it counts as a release for retention and rollback. The units, the PATH link and `bin/harness` are made to agree on the one stable path.

**Files:**
- Modify: `install.sh` (`engine_migrate_git`), `update.sh` (a git-checkout engine migrates instead of ff-pulling, once a release exists), `bin/harness` (export `HARNESS_ENGINE_LINK`; `--version --verbose`), `scripts/supervise.sh` (`SUP_HARNESS` at 54), `scripts/web.sh` (`WEB_HARNESS` at 12), `scripts/uninstall.sh` (`remove_engine` at 47: also `releases/`)
- Test: `test/test_migrate_release.sh` (create); `test/test_supervise.sh` and `test/test_web_install.sh` (any `ExecStart` expectation the new default changes is updated, not deleted)

**Interfaces:**
- Consumes: `rel_latest_tag`, `rel_install`, `engine_flip`, `--post-flip` (Task 3); `rel_previous` (Task 4); `sup_install` / `sup_installed` (`scripts/supervise.sh:397`, `:438`), `web_install` / `web_installed` (`scripts/web.sh:36`, `:74`)
- Produces:
  - `engine_migrate_git`: a no-op unless `$HARNESS_HOME/engine` is a real directory with `.git`. It installs the target release *first* (`rel_install`; a failure leaves the git engine exactly where it was). Then it runs `ln -s releases/<tag> engine.flip.$$`, `mv -T engine releases/git-<12-char sha>` (suffixed `-2`, `-3` … if taken) and `mv -T engine.flip.$$ engine` back to back, and appends `git-<sha>` and then `<tag>` to `.installed`.
  - `HARNESS_ENGINE_LINK`, exported by `bin/harness`: `$HARNESS_HOME/engine` when `realpath` of it equals `ENGINE_DIR`, else `ENGINE_DIR`.
  - `SUP_HARNESS` / `WEB_HARNESS` default to `${HARNESS_ENGINE_LINK:-<engine dir>}/bin/harness`.
  - `harness --version --verbose` adds `engine: <ENGINE_DIR>` and `stable: <HARNESS_ENGINE_LINK>` lines.

- [ ] **Step 1: Write the failing test**

Create `test/test_migrate_release.sh`:

```bash
#!/usr/bin/env bash
# test_migrate_release.sh — PRD #274 / #281: `harness update` moves a git-checkout engine aside
# (local edits kept, no destructive git op) and onto releases; units and the PATH link resolve
# through the stable $HARNESS_HOME/engine path, and a launched worker gets the concrete release.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
export HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1 HARNESS_SUPERVISE_UNIT_DIR="$T/units" HARNESS_WEB_UNIT_DIR="$T/units" \
  HARNESS_SUPERVISE_SYSTEMCTL=true HARNESS_SUPERVISE_LOGINCTL=true HARNESS_WEB_SYSTEMCTL=true HARNESS_WEB_LOGINCTL=true
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"; rel_publish "$SRV" v0.2.0; rel_latest "$SRV" v0.2.0
clean(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK "$@"; }

# Today's host: $HARNESS_HOME/engine is a git checkout of this engine, with an uncommitted local edit,
# and units installed from it.
mkdir -p "$H/engine"
( cd "$HERE/.." && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$H/engine"
gc "$H/engine" init -q; gc "$H/engine" add -A; gc "$H/engine" commit -qm engine
sha="$(git -C "$H/engine" rev-parse --short=12 HEAD)"
printf '# local edit\n' >> "$H/engine/scripts/lib.sh"
clean bash "$H/engine/bin/harness" supervise --install >/dev/null 2>&1
clean bash "$H/engine/bin/harness" web --install >/dev/null 2>&1

out="$(clean bash "$H/engine/bin/harness" update 2>&1)"; rc=$?
assert_eq "$rc" 0 "the migrating update exits 0"
assert_ok "engine is now a symlink" test -L "$H/engine"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine points at the latest release"
assert_ok "the old tree is kept under releases/git-<sha>" test -d "$H/releases/git-$sha/.git"
assert_ok "its local edit is kept, not discarded" grep -qx '# local edit' "$H/releases/git-$sha/scripts/lib.sh"
assert_eq "$(git -C "$H/releases/git-$sha" status --porcelain | xargs)" "M scripts/lib.sh" "the old tree's git state is untouched"
for u in harness-supervise.service harness-web.service; do
  assert_ok "$u runs the stable engine path" grep -qE "^ExecStart=$H/engine/bin/harness " "$T/units/$u"
  assert_no "$u pins no versioned dir" grep -qF "$H/releases/" "$T/units/$u"
done

# bin/harness through a PATH link: units get the stable path, a launched worker the concrete release.
ln -s "$H/engine/bin/harness" "$T/harness"
v="$(clean bash "$T/harness" --version --verbose)"
assert_ok "a launched worker's ENGINE_DIR is the concrete release" grep -qx "engine: $H/releases/v0.2.0" <<<"$v"
assert_ok "units resolve through the stable engine path" grep -qx "stable: $H/engine" <<<"$v"
clean bash "$T/harness" supervise --install >/dev/null 2>&1
assert_ok "a unit installed from a release still names the stable path" \
  grep -qx "ExecStart=$H/engine/bin/harness supervise" "$T/units/harness-supervise.service"

clean bash "$H/engine/bin/harness" update --rollback >/dev/null 2>&1
assert_eq "$(readlink "$H/engine")" "releases/git-$sha" "--rollback right after migration returns to the old tree"

# No release published yet: a git engine is left exactly where it is.
export HARNESS_HOME="$T/host2"; mkdir -p "$HARNESS_HOME"; cp -a "$H/releases/git-$sha" "$HARNESS_HOME/engine"
rel_latest "$SRV" ""; clean bash "$HARNESS_HOME/engine/bin/harness" update >/dev/null 2>&1
assert_ok "with nothing published, the git engine stays a directory" test -d "$HARNESS_HOME/engine/.git"
assert_no "and no releases/ dir appears" test -e "$HARNESS_HOME/releases"
finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_migrate_release.sh`
Expected: FAIL. On a git-checkout engine `update.sh` still ff-pulls (no remote: `fatal: … no tracking information`, exit 1), so `engine` stays a directory. `--version --verbose` prints no `engine:` line. After a release install, `SUP_HARNESS` would name `releases/v0.2.0/bin/harness`.

- [ ] **Step 3: Implement the migration**

`engine_migrate_git` in `install.sh` as in **Interfaces**. In `update.sh`, a non-symlink engine with `.git` first resolves the tag (`HARNESS_REF` or `rel_latest_tag`). rc 2 (nothing published) → keep today's `git pull --ff-only` path, with its existing error on local edits, and print the "named no release" line. Otherwise → `engine_migrate_git "$tag" || exit 3`, print `migrated the git-checkout engine to $HARNESS_HOME/releases/git-<sha>; updated Harness -> <tag>`, then the `--post-flip` exec. The `update.sh` that runs this is the git checkout's own. Bash keeps reading it through its open file descriptor after the directory is renamed, and the `exec` into the new release's `update.sh` happens straight after. So set `ENGINE_DIR` to the new location before anything else is sourced. Hosts reach this code with one ordinary `harness update`: the ff-pull that brings this commit replaces `update.sh` by a new inode, the running copy finishes on its old text, and the *next* `harness update` migrates.

- [ ] **Step 4: The stable path everywhere**

In `bin/harness`, after `ENGINE_DIR` is resolved: `_link="${HARNESS_HOME:-$HOME/.harness}/engine"; if [[ "$(realpath "$_link" 2>/dev/null)" == "$ENGINE_DIR" ]]; then HARNESS_ENGINE_LINK="$_link"; else HARNESS_ENGINE_LINK="$ENGINE_DIR"; fi; export HARNESS_ENGINE_LINK`. A dev clone or test sandbox keeps naming itself, which preserves `sup_installed`'s "runs THIS engine" guard. `scripts/supervise.sh:54` becomes `SUP_HARNESS="${HARNESS_SUPERVISE_HARNESS:-${HARNESS_ENGINE_LINK:-$SUP_ENGINE_DIR}/bin/harness}"`, and `scripts/web.sh:12` the same for `WEB_HARNESS`. `install.sh`'s `link_path` and `install_harness_skills` already use `$HARNESS_HOME/engine/…`, and stay that way. In `scripts/uninstall.sh`, `remove_engine` removes the `engine` link and then every `releases/<name>` that is not `rel_in_use`. If any is in use, it keeps those, says which, and leaves `releases/` in place. Update the `ExecStart` expectations in `test/test_supervise.sh` and `test/test_web_install.sh`. Do not delete them.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash test/test_migrate_release.sh && bash test/test_supervise.sh && bash test/test_web_install.sh && bash test/test_update.sh && bash test/run.sh`
Expected: PASS, with no new failures in the full suite.

- [ ] **Step 6: Migrate this host, commit**

After a release exists, run `harness update` on the fleet host and paste its output, `ls -l ~/.harness ~/.harness/releases` and `systemctl --user cat harness-supervise.service | grep ExecStart` into the PR. If no release exists yet, say so in the PR. The host then migrates on its first `harness update` after Task 7's trigger cuts v0.1.0.

```bash
git add install.sh update.sh bin/harness scripts/supervise.sh scripts/web.sh scripts/uninstall.sh test/test_migrate_release.sh test/test_supervise.sh test/test_web_install.sh
git commit -m "feat(release): migrate git-checkout engines to releases; units resolve through the stable engine path (closes #281)"
```

### Task 6: `install.sh` installs the latest release (`HARNESS_REF=<tag>` pins) (#282)

The curl one-liner stays byte-for-byte the same. It now installs a published release, like rtdd's `installer/`, instead of cloning `main`. It runs the same `rel_install` + `engine_flip` code as `harness update`, so the two paths cannot drift apart.

**Files:**
- Modify: `install.sh` (`place_engine` at 152, `check_prereqs` at 34: `curl`, `sha256sum`, `tar` named; `main` at 252: the closing message names the installed version), `README.md`'s install line only if its URL changes (it does not)
- Test: `test/test_install_release.sh` (create); `test/test_install.sh` (expectations that assumed a `git clone` of `HARNESS_REPO_URL` move to the fixture server, updated, not deleted)

**Interfaces:**
- Consumes: `rel_latest_tag`, `rel_install`, `engine_flip` (Task 3); `engine_migrate_git` (Task 5, when present: an install over a git-checkout engine migrates it the same way); `HARNESS_REF`
- Produces: `place_engine`. The tag is `HARNESS_REF` if set (never compared; a missing one fails with `harness install: no Harness release <tag> at <url>`), else `rel_latest_tag` (rc 2 → `harness install: <api url> named no release; …`, exit 1, nothing written). Then `rel_install "$tag"` and `engine_flip "$tag"`, after which the existing steps run unchanged (`ensure_skills`, `ensure_rtdd`, `create_host_root`, `install_harness_skills`, `link_path`). An already-installed same tag is a no-op flip. `main`'s final message names `Harness <tag>`.

- [ ] **Step 1: Write the failing test**

Create `test/test_install_release.sh`:

```bash
#!/usr/bin/env bash
# test_install_release.sh — PRD #274 / #282: install.sh installs the latest release (or HARNESS_REF's)
# through the same verify-then-flip path as `harness update`, and leaves nothing half-installed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
SRV="$T/srv"; rel_server "$SRV"; rel_publish "$SRV" v0.1.0; rel_publish "$SRV" v0.2.0; rel_latest "$SRV" v0.2.0
fresh(){ export HOME="$T/home$1" HARNESS_HOME="$T/home$1/.harness" HARNESS_BIN_DIR="$T/home$1/.local/bin"; mkdir -p "$HOME"; }
inst(){ ( HARNESS_INSTALL_NOMAIN=1 source "$HERE/../install.sh" && place_engine && link_path ); }

fresh 1; inst >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "a clean install exits 0"
assert_eq "$(readlink "$HARNESS_HOME/engine")" releases/v0.2.0 "the latest release is installed"
assert_ok "the PATH link goes through the stable engine path" \
  test "$(readlink "$HARNESS_BIN_DIR/harness")" == "$HARNESS_HOME/engine/bin/harness"
assert_ok "harness --version prints it" \
  grep -q '^harness v0.2.0 ' <<<"$(env -u ENGINE_DIR -u STATE_DIR bash "$HARNESS_BIN_DIR/harness" --version)"

fresh 2; HARNESS_REF=v0.1.0 inst >/dev/null 2>&1
assert_eq "$(readlink "$HARNESS_HOME/engine")" releases/v0.1.0 "HARNESS_REF installs that release even when a newer one is latest"

fresh 3; good="$(cat "$SRV/download/v0.2.0/SHA256SUMS")"
printf '%064d  harness-v0.2.0.tar.gz\n' 0 > "$SRV/download/v0.2.0/SHA256SUMS"
out="$(inst 2>&1)"; rc=$?
assert_no "a bad checksum fails" test "$rc" -eq 0
assert_ok "and names the mismatch" grep -qF 'checksum mismatch for harness-v0.2.0.tar.gz' <<<"$out"
assert_no "no engine symlink is left" test -e "$HARNESS_HOME/engine"
assert_no "no partial release dir is left" test -e "$HARNESS_HOME/releases/v0.2.0"
printf '%s\n' "$good" > "$SRV/download/v0.2.0/SHA256SUMS"

fresh 4; out="$(HARNESS_REF=v9.9.9 inst 2>&1)"; rc=$?
assert_no "an unknown HARNESS_REF fails" test "$rc" -eq 0
assert_ok "and names the missing release" grep -qF 'no Harness release v9.9.9' <<<"$out"
assert_no "nothing is installed" test -e "$HARNESS_HOME/engine"

fresh 5; rel_latest "$SRV" ""; out="$(inst 2>&1)"; rc=$?
assert_no "with nothing published, install fails rather than cloning main" test "$rc" -eq 0
assert_no "and clones nothing" test -e "$HARNESS_HOME/engine"
assert_no "install.sh never clones the engine" grep -qE 'git clone.*HARNESS_REPO_URL' "$HERE/../install.sh"
finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_install_release.sh`
Expected: FAIL. `place_engine` runs `git clone "$HARNESS_REPO_URL"` from GitHub (or fails offline), so `engine` is a directory, not `releases/v0.2.0`, and the `git clone` grep matches.

- [ ] **Step 3: Implement**

Rewrite `place_engine` as in **Interfaces**. If `$HARNESS_HOME/engine` is a git-checkout directory, call `engine_migrate_git`. Drop `HARNESS_REPO_URL`'s clone, and keep the variable only if another caller still reads it (`grep -rn HARNESS_REPO_URL`). `check_prereqs` adds `curl`, `sha256sum` and `tar` to its `need` loop. A piped install has no checkout, so every function `place_engine` calls must be defined in `install.sh` itself. They are, since Task 3 put them there.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash test/test_install_release.sh && bash test/test_install.sh && bash test/run.sh`
Expected: PASS, with no new failures in the full suite.

- [ ] **Step 5: Commit**

```bash
git add install.sh test/test_install_release.sh test/test_install.sh
git commit -m "feat(release): install.sh installs the latest release; HARNESS_REF pins one (closes #282)"
```

### Task 7: Fleet auto-release — reviewed PRD close and throttled bug-fix patch releases (#283)

The fleet cuts its own releases with no human step. It releases once for each reviewed PRD it closes in the Harness repo, and once per hour at most for merged `bug` fixes. A red gate files one `bug` and does not loop.

**Files:**
- Create: `scripts/autorelease.sh` (sourced by `scripts/drive.sh` and `scripts/priority-worker.sh`)
- Modify: `scripts/drive.sh` (`close_prd` at 160: after a successful close; the impl reap at 87: a merged issue carrying `$HARNESS_LABEL_BUG`; `drive_unit` at 398: `release_tick` once per poll), `scripts/priority-worker.sh` (`drive_bug` at 19, and `reap_pool_bugs` in `drive.sh`: a `fix`-phase bug whose goal is done)
- Test: `test/test_auto_release.sh` (create)

**Interfaces:**
- Consumes: `harness release` and its exit codes (Task 2); `close_prd` (`scripts/drive.sh:160`); `bug_goal_done` (`scripts/drive.sh:332`); `harness_event` (`scripts/lib.sh:1347`); `default_branch`, `CHECKOUT`, `SLUG`; `$HARNESS_LABEL_BUG`
- Produces:
  - `release_repo_is_engine <slug>`: rc 0 iff `<slug>` is `$HARNESS_RELEASE_REPO`, compared case-insensitively.
  - `release_on_prd_close <prd>`: only when the repo is the engine's, and only the first time for that PRD (marker `$HARNESS_AUTORELEASE_DIR/prd-<n>`). It calls `release_kick prd:<n>`.
  - `release_on_bug_merge <n>`: only when the repo is the engine's. It appends `<epoch>\t<n>` to `$HARNESS_AUTORELEASE_DIR/pending` once per issue.
  - `release_tick`: when the oldest pending entry is at least `$HARNESS_RELEASE_THROTTLE` seconds old, `release_kick bug:<n,n,…>`.
  - `release_kick <reason>`: `release_run` as a background job, which tests replace with a synchronous call.
  - `release_head`: `git fetch` + `rev-parse origin/<default>` in `$CHECKOUT`.
  - `release_run <reason>`: under `flock -n $HARNESS_AUTORELEASE_DIR/lock`, it skips a commit with a `gate-failed-<sha>` marker. Otherwise it runs `HARNESS_RELEASE_REASON=<reason> $HARNESS_RELEASE_CMD --ref <sha>` in `$CHECKOUT`. rc 0 → clears the pending entries older than the run's start, then `harness_event release_published reason=… sha=…`. rc 4 → writes the marker, files one `bug` issue, then `harness_event release_gate_failed sha=… issue=…`.
  - Events: `release_triggered` (reason), `release_published`, `release_gate_failed`.

- [ ] **Step 1: Write the failing test**

Create `test/test_auto_release.sh`:

```bash
#!/usr/bin/env bash
# test_auto_release.sh — PRD #274 / #283: the fleet cuts Harness releases itself — once per reviewed
# PRD close in the Harness repo, at most one patch release per hour for bug fixes, and a red release
# gate files one bug issue instead of looping.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
make_env
export HARNESS_RELEASE_REPO=acme/harness HARNESS_AUTORELEASE_DIR="$RUN_DIR/autorelease"
RLOG="$RUN_DIR/release.log"; GH_LOG="$RUN_DIR/gh.log"; EV="$RUN_DIR/events"; : > "$RLOG"; : > "$GH_LOG"; : > "$EV"
# Stub release command: logs the reason it was run for, exits $STUB_RC (4 = the gate failed).
printf '#!/usr/bin/env bash\necho "$HARNESS_RELEASE_REASON" >> %q\nexit "${STUB_RC:-0}"\n' "$RLOG" > "$RUN_DIR/release"
chmod +x "$RUN_DIR/release"; export HARNESS_RELEASE_CMD="$RUN_DIR/release"
gh(){ echo "$*" >> "$GH_LOG"
  case "$1 $2" in
    "issue list")   cat "$RUN_DIR/open-bugs" 2>/dev/null || echo '[]';;
    "issue create") echo '[{"number":99}]' > "$RUN_DIR/open-bugs"; echo "https://github.com/acme/harness/issues/99";;
  esac; return 0; }
harness_event(){ echo "$*" >> "$EV"; }
release_kick(){ release_run "$@"; }               # a background job in production; synchronous here
release_head(){ cat "$RUN_DIR/head"; }; echo aaaaaaa1 > "$RUN_DIR/head"
CHECKOUT="$RUN_DIR"

# ── a reviewed PRD close in the Harness repo: exactly one release ──
SLUG=acme/harness
close_prd 274; close_prd 274   # dispatch re-emits CLOSE_PRD every poll until the board sees it closed
assert_eq "$(grep -c . "$RLOG")" 1 "a reviewed PRD close triggers exactly one harness release"
assert_ok "for that PRD" grep -qx 'prd:274' "$RLOG"
: > "$RLOG"; SLUG=acme/widget; close_prd 12
assert_eq "$(grep -c . "$RLOG")" 0 "a PRD close in another target repo triggers no release"

# ── bug merges: at most one patch release per hour, covering every fix ──
SLUG=acme/harness; : > "$RLOG"; t0=1800000000
HARNESS_NOW=$t0          release_on_bug_merge 31; HARNESS_NOW=$t0          release_tick
HARNESS_NOW=$((t0+600))  release_on_bug_merge 32; HARNESS_NOW=$((t0+600))  release_tick
HARNESS_NOW=$((t0+3000)) release_on_bug_merge 33; HARNESS_NOW=$((t0+3599)) release_tick
assert_eq "$(grep -c . "$RLOG")" 0 "no patch release inside the hour"
HARNESS_NOW=$((t0+3600)) release_tick; HARNESS_NOW=$((t0+3700)) release_tick
assert_eq "$(grep -c . "$RLOG")" 1 "three bug merges within an hour → exactly one patch release"
assert_ok "and it covers all three" grep -qx 'bug:31,32,33' "$RLOG"
: > "$RLOG"; SLUG=acme/widget; HARNESS_NOW=$t0 release_on_bug_merge 5; HARNESS_NOW=$((t0+7200)) release_tick
assert_eq "$(grep -c . "$RLOG")" 0 "a bug fix in another repo never triggers a Harness release"

# ── a red gate: one bug issue, no retry loop on the same commit ──
SLUG=acme/harness; : > "$RLOG"; : > "$GH_LOG"; echo bbbbbbb2 > "$RUN_DIR/head"
STUB_RC=4 release_run prd:275
STUB_RC=4 release_run prd:275          # the next poll, same commit
assert_eq "$(grep -c . "$RLOG")" 1 "a red gate is not retried on the same commit"
assert_eq "$(grep -c '^issue create' "$GH_LOG")" 1 "a red gate files one bug issue"
assert_ok "labelled bug" grep -qE '^issue create .*--label bug' "$GH_LOG"
assert_ok "the gate failure is an event" grep -q '^release_gate_failed ' "$EV"
echo ccccccc3 > "$RUN_DIR/head"; STUB_RC=0 release_run prd:275
assert_eq "$(grep -c . "$RLOG")" 2 "a new commit (the fix) is released"
assert_ok "the release is an event" grep -q '^release_published ' "$EV"
finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_auto_release.sh`
Expected: FAIL. `close_prd` closes the PRD but never releases (0 lines in the release log), and `release_on_bug_merge: command not found`.

- [ ] **Step 3: Implement `scripts/autorelease.sh`**

The functions are as in **Interfaces**. `release_now` is `${HARNESS_NOW:-$(date +%s)}`. The pending file is rewritten with `mktemp` + `mv`, under the same lock. The bug issue's dedupe check is `gh issue list -R "$SLUG" --label "$HARNESS_LABEL_BUG" --state open --search "release gate failed at <short sha> in:title" --json number`, and a non-empty list means no new issue. The issue is `gh issue create -R "$SLUG" --label "$HARNESS_LABEL_BUG" --title "release gate failed at <short sha>" --body-file <file>`. The body names the reason, the commit, the last 80 lines of `gate-<sha>.log` in a fenced block, and the log's host path. `release_kick` runs `( release_run "$@" ) >>"$HARNESS_AUTORELEASE_DIR/release.log" 2>&1 &` with `9>&-` (the drive loop's lock fd must not leak into a job that runs the whole suite). Its `$!` goes into `$HARNESS_AUTORELEASE_DIR/release.pid`, so it can be stopped by PID, never by pattern.

- [ ] **Step 4: Wire the triggers**

- `close_prd`: after `harness_event prd_closed`, add `release_on_prd_close "$prd"`.
- The impl reap (`drive.sh:85-87`): when the closed issue's `state` JSON carries `"name":"$HARNESS_LABEL_BUG"`, add `release_on_bug_merge "$issue"`.
- `drive_bug` and `reap_pool_bugs`: when `bug_goal_done "$n" fix` holds, add `release_on_bug_merge "$n"`. A triage-phase close is a dismissal, not a merge, and never counts.
- `drive_unit`'s poll loop: add `release_tick` beside `usage_watch`. Every function returns at once unless `release_repo_is_engine "$SLUG"` holds.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash test/test_auto_release.sh && bash test/test_drive.sh && bash test/test_pool_bugs.sh && bash test/test_bug_flow.sh && bash test/run.sh`
Expected: PASS, with no new failures in the full suite.

- [ ] **Step 6: Commit**

```bash
git add scripts/autorelease.sh scripts/drive.sh scripts/priority-worker.sh test/test_auto_release.sh
git commit -m "feat(release): fleet auto-release on reviewed PRD close and throttled bug-fix merges (closes #283)"
```

### Task 8: README Install/Update documents releases, `--version`, `--rollback`, `HARNESS_REF` (#284)

Lets an operator answer "what version is this host on, and what changed?" from the README alone. Written last, against the shipped behaviour.

**Files:**
- Modify: `README.md` (`## Install` at 21, `## Pause / resume / update` at 497), `bin/harness` (`usage`: no `ff-pull` wording left)
- Test: `test/test_release_readme.sh` (create)

**Interfaces:**
- Consumes: the shipped behaviour and messages of Tasks 1–7
- Produces: README sections that explain:
  - releases: semver tags, the GitHub release notes, and the fleet cutting releases itself with `harness release` and its two triggers;
  - `harness --version`;
  - `harness update`, which follows releases: the `is the latest release.` line, checksum verification against `SHA256SUMS`, `~/.harness/releases/` and the `engine` symlink, the previous 2 kept, and live workers moving on relaunch;
  - `harness update --rollback`;
  - `HARNESS_REF=<tag>` for install and update;
  - the one-time migration of a git-checkout engine.

- [ ] **Step 1: Write the failing test**

Create `test/test_release_readme.sh`:

```bash
#!/usr/bin/env bash
# test_release_readme.sh — PRD #274 / #284: README's Install/Update sections document releases,
# --version, --rollback and HARNESS_REF, and nothing still says update ff-pulls main.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
README="$HERE/../README.md"
sec="$(sed -n '/^## Install$/,/^## Prerequisites$/p; /^## Pause \/ resume \/ update$/,/^### Usage-limit checkpoints$/p' "$README")"
for term in 'harness release' 'harness --version' 'harness update --rollback' 'HARNESS_REF=' \
            'is the latest release.' 'SHA256SUMS' '~/.harness/releases/' 'releases/git-'; do
  assert_ok "Install/Update documents $term" grep -qF -- "$term" <<<"$sec"
done
help="$(cd "$(mktemp -d)" && env -u STATE_DIR -u ENGINE_DIR bash "$HERE/../bin/harness" help)"
assert_no "README no longer says update ff-pulls the engine" grep -qiE 'ff-pull|pull --ff-only' "$README"
assert_no "harness help no longer says update ff-pulls"      grep -qiE 'ff-pull' <<<"$help"
assert_ok "harness help documents --version"  grep -qF -- '--version' <<<"$help"
assert_ok "harness help documents --rollback" grep -qF -- '--rollback' <<<"$help"
assert_ok "harness help documents release"    grep -qE '^  release ' <<<"$help"
finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_release_readme.sh`
Expected: FAIL. The README's update section still says `git pull --ff-only` (`README.md:513`) and `ff-pull the one shared engine install` (`README.md:503`), and none of the release terms appear.

- [ ] **Step 3: Rewrite the sections**

Under `## Install`, keep the curl one-liner. Say that it installs the latest *release* into `~/.harness/releases/vX.Y.Z/` behind the `~/.harness/engine` symlink, document `HARNESS_REF=v0.1.0` pinning, and say how to check what is installed (`harness --version`). Under `## Pause / resume / update`, the command block's `update` line becomes `harness update          # install the latest release (verified); --rollback flips back`. Replace the "**`update` never touches your config.**" paragraph with the release model. Cover the three outcomes and their lines, the checksum discipline, the previous 2 being kept, `--rollback`, live workers keeping their release until relaunched, and the one-time `releases/git-<sha>/` migration with its local edits kept. Then add a short "**Releases**" paragraph: semver from Conventional Commits, `harness release` gated on `test/run.sh`, cut by the fleet when it closes a reviewed PRD here and at most once an hour for bug fixes, notes on the GitHub release page. Remove the remaining ff-pull wording from `bin/harness`'s `usage`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash test/test_release_readme.sh && bash test/test_readme_docs.sh && bash test/run.sh`
Expected: PASS, with no new failures in the full suite.

- [ ] **Step 5: Commit**

```bash
git add README.md bin/harness test/test_release_readme.sh
git commit -m "docs: README Install/Update documents releases, --version, --rollback, HARNESS_REF (closes #284)"
```

## What this plan deliberately leaves undone

- **Release channels.** There is no beta or nightly channel (PRD #274 non-goal). `HARNESS_REF=<tag>` covers pinning for install and update. A host that must stay on an older release simply does not run `harness update`. Nothing updates a host by itself.
- **Signing releases.** Checksums only, like rtdd. `SHA256SUMS` comes from the same release as the archive, so it guards against corruption and a substituted mirror, not a compromised GitHub account.
- **Changing rtdd's pipeline.** rtdd keeps GoReleaser and its own `rtdd update`. `harness update` still re-runs the rtdd ensure on every outcome, as today.
- **`harness update --check`.** rtdd's report-only mode is not ported. `harness --version` plus the release page answer the same question.
- **Offloading the release gate to swarm.** `harness release` runs `test/run.sh` locally on the fleet host, as the PRD says. A swarm-backed gate (`scripts/swarm-suite.sh`) is a later change, and would also need the swarm runner to accept an archive instead of a worktree.
- **Deleting old GitHub releases or tags.** Hosts prune their own `releases/` dirs, but every published release stays on GitHub, so `HARNESS_REF` can always reach it.
- **Patch releases on an older minor.** Releases are cut from the default branch only. There is no backport branch.
- **Non-Linux hosts.** `mv -T`, `/proc/*/environ` and GNU `tar --sort` are Linux/GNU. That matches every host the fleet runs on today, and macOS is not handled.
- **Live workers across the one-time migration.** A worker launched *before* migration has `ENGINE_DIR=$HARNESS_HOME/engine` (the old real directory's path). After the flip, that path resolves to the new release, so the migration hop behaves like today's `git pull`: such a worker reads new code on its next script invocation. The existing NOTE (pause → drain → stop → start --recover) still applies to that one update. Every later update isolates live workers fully.

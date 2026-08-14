# Host-wide fleet prefix registry + collision guard

**Date:** 2026-08-14
**Status:** Design approved, pending implementation plan

## Problem

`HARNESS_SESS_PREFIX` is the ownership boundary for every tmux session a fleet creates
(`lib.sh:531-543`), and `harness stop` kills everything matching `fleet_session_re` — `^<prefix>-.+`
(`lib.sh:761`, `stop.sh:25`). When two projects on one host share a prefix, `stop` in project A kills
project B's live agents, `status` reports a merged fleet, and `team_sessions` miscounts against `CAP`.

Nothing today makes a shared prefix unlikely, and nothing catches it when it happens.

| Site | Problem |
|---|---|
| `lib.sh:44` | `: "${HARNESS_SESS_PREFIX:=hz}"` — *every* project defaults to the same literal `hz` |
| `init.sh:17-30` | never prompts for the prefix |
| `init.sh:41-49` | never writes it to `.harness/config`, so there is nothing to edit afterwards |
| `README.md:115` | the only place it is documented — one row in a table of 30+ env vars |
| `start.sh:72` | `check_prefix_collision` runs, but reads a registry that is almost always empty |

The guard is the subtle failure. `check_prefix_collision` (`lib.sh:807`) and its `prefixes_collide`
predicate (`lib.sh:770`) are correct and tested (`test/test_prefix_guard.sh`) — including the
`hz` vs `hz-bug` overlap and the `hz`/`hzli`/`boto` coexistence case. But its only discovery source
is `poller_registry_prefixes`, reading `$HARNESS_HOME/poller/registry`, and that registry is
populated only by `poller_register_project`, called only when `HARNESS_USE_POLLER` is set
(`start.sh:104-106`). That flag is off by default (`lib.sh:59`) and was never cut over. So the
guard reads an empty directory and unconditionally passes. It is a live guard with no data behind it.

Consequence, in the order it bites: two `harness init` runs on one host produce two `hz` fleets;
the first `harness stop` cross-kills the other project's agents mid-edit; and the guard that exists
to prevent exactly this stays silent throughout.

## Approach

Three independent changes, each useful alone:

1. **Derive a distinct prefix at `init`** so collisions are rare by construction.
2. **A dedicated host-wide fleet registry**, written unconditionally, so the guard has data.
3. **Enforce on tmux, attribute via the registry**, so the guard is correct even against fleets
   that never registered and is not fooled by a crashed fleet's stale entry.

**The registry is deliberately not the poller registry.** Reusing it — making
`poller_register_project` unconditional — is the smallest diff and `check_prefix_collision` already
reads it, but those files are the poller's *work list*: `poller.sh` refreshes a GitHub snapshot for
every registered slug at the fastest registrant cadence (`lib.sh:864-870`). Registering there
unconditionally would enroll fleets that never opted into snapshot polling, spending the host's
shared GitHub token budget on their behalf. "This fleet exists" and "poll these repos for me" are
different facts and get different files.

**tmux is the enforcement signal, not the registry.** Every fleet session is created as
`tmux new-session -d -s "$sess" -c "$wd"` (`lib.sh:850`), where `$wd` is a worktree under *that
project's* `WORKTREES_DIR`. So `tmux ls -F '#{session_name}\t#{session_path}'` attributes any live
session to the project that owns it, with no registry involved. This is what makes the guard work
against a sibling fleet running an older engine, one started with a hand-set env var, or a session
created by hand — none of which appear in any registry. It also has no staleness: tmux liveness is
the fact we actually care about.

A registry is still needed for two things tmux cannot supply: **reservation** (an idle fleet's
prefix must not be claimed by a starting one) and **attribution detail** (repo slugs and start time
for the error message).

Rejected alternatives: auto-suffixing a taken prefix (`hz` → `hz2`) removes the friction but
desynchronises the running sessions from `.harness/config`, so a later `stop`/`status`/`attach`
targets the wrong namespace; a single `~/.harness/fleets.json` needs cross-fleet locking on every
start/stop, which per-file entries avoid entirely; a heartbeat TTL adds a writer to the worker loop
and makes a legitimately paused fleet look dead.

## Component 1 — prefix derivation

New in `lib.sh`:

```
derive_prefix [dir]   # dir defaults to the project dir (parent of STATE_DIR)
```

basename → lowercase → strip everything outside `[a-z0-9_]` → truncate to 10 characters. If the
result is empty (a non-ASCII or punctuation-only directory name), fall back to `hz` plus the first
4 hex characters of a digest of the absolute `STATE_DIR`. The character class is chosen to be safe
as a tmux session-name segment and to keep `prefixes_collide`'s dash grammar meaningful.

```
~/proj/Harness      -> harness
~/proj/bonsai-api   -> bonsaiapi
~/proj/my.app       -> myapp
~/proj/<non-ascii>  -> hz3f9c
```

`init.sh` gains one prompt in the existing `ask` sequence and adds `HARNESS_SESS_PREFIX` to the
`for v in …` list that writes `.harness/config` — it is currently missing from both. Before
proposing the derived value, `init` runs the same collision check `start` uses; if the derived
prefix is already taken by a live or registered fleet, it proposes the hash fallback instead and
prints why. `init` only *warns* — it starts nothing, so it never refuses.

**`lib.sh:44` keeps its `hz` default.** Existing projects have no `HARNESS_SESS_PREFIX` line in
their config and must keep resolving exactly as they do today. Only newly-initialized projects get
a derived prefix. There is no migration.

## Component 2 — the fleet registry

`$HARNESS_HOME/fleets/`, alongside `poller/` and `snapshots/`, with a `HARNESS_FLEETS_DIR` env seam
so tests can point it at a temp root (matching `lib.sh:84-92`).

One file per fleet, named from the sanitised `STATE_DIR` exactly as `_poller_reg_file` does
(`lib.sh:875`), holding:

```json
{"prefix": "harness", "project": "/home/u/Harness/.harness",
 "run_dir": "/home/u/Harness/.harness/run", "slugs": ["owner/repo"],
 "started_at": 1755100000}
```

`project` (the `STATE_DIR`) is the identity key, read back on deregister so the operation is robust
to filename sanitisation — the same discipline as `poller_deregister` (`lib.sh:899`). Writes are
atomic (mkstemp + `os.replace`) via the same python idiom as `poller_register`.

- `fleet_register` — called unconditionally by `start.sh`, after the guard passes and before workers
  spawn.
- `fleet_deregister <project>` — called unconditionally by `stop.sh`, removing only this project's
  file.

Both are **best-effort**: an unwritable or absent `$HARNESS_HOME` prints one warning and returns 0.
The registry is an aid, never a gate; a host where it cannot be written must still start fleets.

## Component 3 — the guard

`check_prefix_collision` is rewritten to combine two signals. `prefixes_collide` is reused verbatim.

**Signal 1 — live tmux sessions (enforcement).** Read `tmux ls -F '#{session_name}\t#{session_path}'`.
For each session, take the name's leading dash-delimited segment as its prefix and test
`prefixes_collide` against ours. That segment is only a lower bound on the owner's real prefix when
the owner's prefix itself contains a dash (`my-app-main-i1` → `my`), but this is sound rather than
approximate: a shorter prefix collides with strictly more of the namespace, so every genuine
collision is still caught and no false one is introduced — if `my` collides with ours, so does
`my-app`, and if it does not, `my-app-…` sessions lie outside our space anyway.

For each hit, attribute it by `session_path`:

- path under our own `STATE_DIR` root → **ours**. This is the `harness start --recover` path, which
  is a documented re-run against a live fleet, and it proceeds.
- any other path → **refuse**, naming the owning project (the registry entry whose `run_dir`/
  `project` contains that path, or the path itself when no entry matches).

**Signal 2 — the registry (reservation + detail).** Any other project's entry whose prefix collides
refuses the start even with zero live sessions, so two idle fleets cannot race into one namespace.
An entry is treated as **stale** — pruned, and the start allowed — when it has no live sessions
under its prefix *and* no live pid in its recorded `run_dir` (the `pool_live` predicate at
`lib.sh:358`, evaluated against that fleet's `run_dir` rather than our own). The poller registry is
still read alongside the fleet registry, so a poller-enabled fleet on an older engine is still seen.

`refuse` remains the default and `HARNESS_PREFIX_COLLISION=warn` still downgrades it to a stderr
warning (`lib.sh:815`). The message names the culprit and gives the retry line:

```
harness start: session prefix 'hz' is in use by another fleet
  owner:    /home/claude/Bonsai (repo acme/bonsai)
  prefix:   hz  — 4 live tmux sessions
  yours:    /home/claude/Harness
retry with a distinct prefix, e.g.:
  HARNESS_SESS_PREFIX=harness harness start
or set HARNESS_SESS_PREFIX in /home/claude/Harness/.harness/config
(HARNESS_PREFIX_COLLISION=warn overrides)
```

The engine never edits `.harness/config` itself and never silently picks a different prefix than the
one configured.

## Component 4 — surfacing

- `harness status` prints this fleet's prefix and any sibling fleets registered on the host.
- `harness doctor` lists the registry and flags stale entries; `doctor --fix` prunes them. This is
  the escape hatch when a hard-killed fleet leaves a reservation behind and the operator wants it
  gone without waiting for the guard's own staleness check.

## Testing

`test/test_prefix_guard.sh` already provides both seams needed — a `tmux` shell-function stub and a
temp `HARNESS_HOME` exported before `lib.sh` is sourced. Extend it:

- own live sessions + live worker pids → recover proceeds
- sibling-owned sessions (`session_path` under another project) → refuse, message names that project
- unregistered sibling detected from `session_path` alone, with an empty registry
- registered sibling with zero sessions → refuse (reservation holds)
- registered sibling with no sessions and no live pids → entry pruned, start proceeds
- `hz` / `hzli` / `boto` still coexist end-to-end (existing assertions must not regress)
- absent or unwritable `$HARNESS_HOME` → clean no-op, start proceeds, one warning
- `fleet_register` / `fleet_deregister` round-trip; deregister removes only the caller's file

New `derive_prefix` unit tests: the sanitize cases above, truncation at 10, and the empty-result
hash fallback.

## Out of scope

- Auto-suffixing or any engine-initiated write to `.harness/config`.
- Changing `lib.sh:44`'s `hz` default, or migrating existing projects.
- Cutting `HARNESS_USE_POLLER` over. The fleet registry is independent of it by design; the poller
  rollout stays a separate decision.
- Cross-user or cross-tmux-server detection. Sessions on another user's tmux server are invisible to
  `tmux ls` and out of scope; the registry still records them if that user shares `$HOME`.

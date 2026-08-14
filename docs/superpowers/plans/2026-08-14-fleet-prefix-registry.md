# Fleet Prefix Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop two Harness fleets on one host from sharing a tmux session prefix — derive a distinct prefix at `harness init`, record every live fleet in a host-wide registry, and make `harness start` refuse a genuine collision with a message that names the culprit.

**Architecture:** Three independent layers. `derive_prefix` gives each newly-initialized project its own prefix so collisions are rare by construction. A dedicated `~/.harness/fleets/` registry — deliberately *not* the poller's work list — records each live fleet, written unconditionally by `start` and removed by `stop`. The rewritten `check_prefix_collision` enforces on live `tmux` sessions (attributed to their owning project by `session_path`, so it works even against fleets that never registered) and uses the registry only for reservation and for naming the owner.

**Tech Stack:** Bash 5 (`set -uo pipefail`), `python3` for JSON reads/writes (already a hard dependency throughout `scripts/lib.sh`), `tmux`, the repo's own test rig (`test/helpers.sh`).

**Spec:** `docs/superpowers/specs/2026-08-14-fleet-prefix-registry-design.md`

## Global Constraints

- **No new dependencies.** Bash + `python3` + `tmux` only. No `jq`, no `lsof`/`fuser` (this host has neither — see `scripts/doctor.sh:9`).
- **`lib.sh:44` keeps `: "${HARNESS_SESS_PREFIX:=hz}"`.** Existing projects have no prefix line in `.harness/config` and must resolve exactly as they do today. No migration, no change to running fleets.
- **The registry is an aid, never a gate.** Every registry write is best-effort: an unwritable or absent `$HARNESS_HOME` prints one warning to stderr and returns 0. A fleet must always be startable.
- **Never write to the poller registry.** `$POLLER_REGISTRY_DIR` is `poller.sh`'s work list; adding entries there enrolls a fleet into shared-token GitHub polling it did not opt into. The fleet registry is a separate directory with separate functions.
- **The engine never edits `.harness/config`** and never silently starts under a different prefix than the configured one.
- **`HARNESS_PREFIX_COLLISION`** keeps its `refuse` default (`lib.sh:60`); `warn` downgrades any refusal to a stderr warning and returns 0.
- **Test isolation:** every test sets `HARNESS_HOME` to a temp dir *before* sourcing `lib.sh` (see `test/test_prefix_guard.sh:8-9`). Never let a test touch a real `~/.harness` — a stray fixture entry there aborts a real `harness start`.
- **Run the suite with** `bash test/run.sh`; a single file with `bash test/test_<name>.sh`.
- **Commit style:** `feat(prefix): …` / `test(prefix): …` / `docs: …`, one commit per task.

---

### Task 1: `derive_prefix` + `harness init` prompts and persists the prefix

This is the change that fixes the reported failure on its own: `harness init` currently never asks for `HARNESS_SESS_PREFIX` and never writes it, so every project on a host inherits the literal `hz`.

**Files:**
- Modify: `scripts/lib.sh` (add `derive_prefix` immediately above the `# --- PRD-B slice 4: prefix-collision guard (#73) ---` banner at line 764)
- Modify: `scripts/init.sh:22` (add the `ask`), `scripts/init.sh:44-46` (add the var to the persisted list)
- Test: `test/test_prefix_guard.sh` (new group, appended before `finish`), `test/test_init.sh` (new group, appended before its final assertions)

**Interfaces:**
- Consumes: `PROJECT_ROOT` (`lib.sh:17` — the parent of `STATE_DIR`)
- Produces: `derive_prefix [dir] -> stdout` — a non-empty prefix matching `^[a-z0-9_]+$`, at most 10 characters. Tasks 5 and 6 call it to suggest a replacement prefix.

- [ ] **Step 1: Write the failing tests for `derive_prefix`**

Append to `test/test_prefix_guard.sh`, immediately before the final `finish` line:

```bash
echo "== derive_prefix: a distinct default prefix per project =="
assert_eq "$(derive_prefix /home/u/Harness)"     "harness"    "basename, lowercased"
assert_eq "$(derive_prefix /home/u/bonsai-api)"  "bonsaiapi"  "dashes stripped (they are the grammar separator)"
assert_eq "$(derive_prefix /home/u/my.app)"      "myapp"      "dots stripped (illegal in tmux session names)"
assert_eq "$(derive_prefix /home/u/Web_API_2)"   "web_api_2"  "underscores and digits kept"
assert_eq "$(derive_prefix /home/u/a_very_long_project_name)" "a_very_lon" "truncated to 10 chars"
# A name that sanitises to nothing falls back to hz<4 hex of the path digest: non-empty, tmux-safe,
# deterministic across runs, and distinct per path.
NA1="$(derive_prefix /home/u/中文)"; NA2="$(derive_prefix /home/u/中文)"; NB="$(derive_prefix /srv/中文)"
assert_ok "non-ascii name falls back to hz<hex>" bash -c "[[ '$NA1' =~ ^hz[0-9a-f]{4}$ ]]"
assert_eq "$NA1" "$NA2" "fallback is deterministic for the same path"
assert_no "different paths get different fallbacks" bash -c "[[ '$NA1' == '$NB' ]]"
# The result is always usable as a tmux session-name segment.
assert_ok "result never contains a dash" bash -c "[[ ! '$(derive_prefix /home/u/bonsai-api)' == *-* ]]"
# Run this IN-PROCESS, not under `bash -c`: the helper rig's assert_* run their argv directly, so
# lib.sh's functions are in scope. A `bash -c '! prefixes_collide …'` subshell never sourced lib.sh,
# so both functions would be "command not found" (127) and the leading `!` would negate that into a
# pass — an assertion that stays green even if the functions are deleted.
assert_no "derived prefixes of two sibling projects do not collide" \
  prefixes_collide "$(derive_prefix /home/u/Harness)" "$(derive_prefix /home/u/Bonsai)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash test/test_prefix_guard.sh`
Expected: FAIL — `derive_prefix: command not found` on every new assertion (the pre-existing assertions still pass).

- [ ] **Step 3: Implement `derive_prefix`**

In `scripts/lib.sh`, insert immediately **above** the line `# --- PRD-B slice 4: prefix-collision guard (#73) -----------------------------` (line 764):

```bash
# derive_prefix [dir] — the DEFAULT tmux session prefix for a project: its directory basename,
# lowercased and reduced to [a-z0-9_], truncated to 10 chars. Dashes are stripped because a dash is
# the session-name grammar separator (sess_orch/sess_impl) and prefixes_collide reads it as such;
# dots and colons are illegal in tmux session names. When the name sanitises to EMPTY (a non-ASCII or
# punctuation-only directory) fall back to `hz` + 4 hex of the path digest, so the result is always a
# non-empty, tmux-safe segment that is deterministic per path and distinct between paths.
#
# `harness init` offers this as the prefix default so two projects on one host do not both land on
# lib.sh's `hz` and cross-kill each other's sessions via stop.sh's ^<prefix>- sweep. lib.sh's own
# HARNESS_SESS_PREFIX default (line 44) deliberately STAYS `hz`: projects initialised before this
# change have no prefix line in their config and must resolve exactly as they always did.
derive_prefix(){
  local dir="${1:-$PROJECT_ROOT}" p
  p="$(basename "$dir" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_' | cut -c1-10)"
  [[ -n "$p" ]] || p="hz$(printf '%s' "$dir" | python3 -c \
    'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:4])')"
  printf '%s\n' "$p"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash test/test_prefix_guard.sh`
Expected: PASS, all assertions including the pre-existing ones.

- [ ] **Step 5: Write the failing test for `init`**

Append to `test/test_init.sh`, immediately before its final `echo`/exit lines:

```bash
# --- session prefix (#: fleet prefix registry) ------------------------------------------------
# init must PROMPT for and PERSIST HARNESS_SESS_PREFIX. Before this, the key was absent from the
# config entirely, so every project on a host silently inherited lib.sh's `hz` and two fleets shared
# one tmux namespace — `harness stop` in one killed the other's live agents.
assert "session prefix key written" "grep -q 'HARNESS_SESS_PREFIX:=' '$CFG'"
( source "$CFG"; [[ "${HARNESS_SESS_PREFIX:-}" =~ ^[a-z0-9_]{1,10}$ ]] ) \
  && echo "  ok: prefix round-trips as a tmux-safe segment" || { echo "  FAIL: prefix round-trip"; exit 1; }

# The default is DERIVED from the project directory name, not the literal `hz`.
PDIR="$TMP/Widget"; mkdir -p "$PDIR/.harness"
cp -r "$HERE/../scripts" "$PDIR/.harness/scripts" 2>/dev/null || true
( export STATE_DIR="$PDIR/.harness" HARNESS_DIR="$PDIR/.harness"
  HARNESS_INIT_NONINTERACTIVE=1 HARNESS_TOPOLOGY=single HARNESS_OWNER=acme HARNESS_REPO=acme/widget \
    bash "$HERE/../scripts/init.sh" >/dev/null 2>&1 )
assert "derived prefix written for project dir 'Widget'" "grep -q 'HARNESS_SESS_PREFIX:=widget' '$PDIR/.harness/config'"

# A pre-set env var still wins (non-interactive `ask` honours ${!var}).
PDIR2="$TMP/Widget2"; mkdir -p "$PDIR2/.harness"
( export STATE_DIR="$PDIR2/.harness" HARNESS_DIR="$PDIR2/.harness"
  HARNESS_INIT_NONINTERACTIVE=1 HARNESS_SESS_PREFIX=custom HARNESS_TOPOLOGY=single HARNESS_OWNER=acme \
    HARNESS_REPO=acme/widget bash "$HERE/../scripts/init.sh" >/dev/null 2>&1 )
assert "explicit HARNESS_SESS_PREFIX overrides the derived default" \
  "grep -q 'HARNESS_SESS_PREFIX:=custom' '$PDIR2/.harness/config'"
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bash test/test_init.sh`
Expected: FAIL — `FAIL: session prefix key written` (the key is not in the config).

- [ ] **Step 7: Implement the `init` prompt and persistence**

In `scripts/init.sh`, add this helper immediately **after** the `ask()` definition (after line 16):

```bash
# The prefix default is DERIVED from the project directory (derive_prefix) so two projects on one
# host don't both take lib.sh's `hz`. derive_prefix lives in lib.sh — one definition, also used by
# the start-time guard and `harness status` — but init.sh deliberately does NOT source lib.sh at the
# top: lib.sh fills every HARNESS_* with its default at source time, which would defeat the `ask`
# fallbacks below (and, for the prefix specifically, would hand back `hz`). Read the one function out
# of a throwaway subshell instead, with the var unset so lib.sh's default can't leak into the answer.
default_prefix(){ ( unset HARNESS_SESS_PREFIX
  source "$ENGINE_DIR/scripts/lib.sh" >/dev/null 2>&1
  derive_prefix "$PROJECT_ROOT" ); }
```

Then add the prompt immediately **after** the `HARNESS_AUTONOMOUS` line (line 22):

```bash
ask HARNESS_SESS_PREFIX "tmux session prefix (must be unique per fleet on this host)" "${HARNESS_SESS_PREFIX:-$(default_prefix)}"
```

Then add `HARNESS_SESS_PREFIX` to the persisted list — in the `for v in …` at lines 44-46, append it to the first line so it reads:

```bash
  for v in HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC HARNESS_AUTONOMOUS \
           HARNESS_SESS_PREFIX \
           HARNESS_POOL HARNESS_CAP HARNESS_POLL HARNESS_PRIORITY_POLL HARNESS_LABEL_READY HARNESS_LABEL_PRD \
```

- [ ] **Step 8: Run both tests to verify they pass**

Run: `bash test/test_init.sh && bash test/test_prefix_guard.sh`
Expected: PASS for both.

- [ ] **Step 9: Run the full suite (nothing else may regress)**

Run: `bash test/run.sh`
Expected: every test file passes. `test_config.sh` and `test_hermetic.sh` are the ones most likely to notice a change here — if either fails, the cause is in this task, not a flake.

- [ ] **Step 10: Commit**

```bash
git add scripts/lib.sh scripts/init.sh test/test_prefix_guard.sh test/test_init.sh
git commit -m "feat(prefix): derive a distinct session prefix at init

harness init never prompted for HARNESS_SESS_PREFIX nor wrote it to
.harness/config, so every project on a host inherited lib.sh's literal
hz and two fleets shared one tmux namespace — stop.sh's ^<prefix>- sweep
in one project killed the other's live agents.

derive_prefix sanitises the project dir name (Harness -> harness) with an
hz<hex> fallback for names that sanitise to empty. lib.sh's hz default is
unchanged, so existing projects resolve exactly as before."
```

---

### Task 2: Fleet registry primitives

**Files:**
- Modify: `scripts/lib.sh` (add `HARNESS_FLEETS_DIR` beside the other host paths at lines 84-92; add the registry functions after `poller_deregister`, which ends around line 917)
- Test: Create `test/test_fleet_registry.sh`

**Interfaces:**
- Consumes: `HARNESS_HOME` (`lib.sh:87`), `STATE_DIR`, `RUN_DIR`, `HARNESS_SESS_PREFIX`, `snapshot_slugs` (`lib.sh:1023`)
- Produces:
  - `HARNESS_FLEETS_DIR` — exported path, defaults to `$HARNESS_HOME/fleets`
  - `fleet_register` — writes this fleet's entry; always returns 0
  - `fleet_deregister <project>` — removes entries whose JSON `project` equals `<project>`; always returns 0
  - `fleet_registry_entries <self-project>` — one `<prefix>\t<project>\t<run_dir>\t<slugs-space-separated>` line per *other* registered fleet

- [ ] **Step 1: Write the failing test**

Create `test/test_fleet_registry.sh`:

```bash
#!/usr/bin/env bash
# test_fleet_registry.sh — the host-wide fleet registry under $HARNESS_HOME/fleets: one file per
# LIVE fleet, keyed on STATE_DIR, feeding the start-time prefix-collision guard. Deliberately
# separate from the poller registry, whose files are poller.sh's GitHub WORK LIST — registering
# there unconditionally would enroll every fleet into shared-token polling it never opted into.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pin the host root BEFORE sourcing lib.sh so HARNESS_FLEETS_DIR derives into a throwaway and we
# never touch a real ~/.harness (a stray fixture entry there aborts a real `harness start`).
export HARNESS_HOME="$(mktemp -d)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env

echo "== the registry dir is separate from the poller's =="
assert_ok "HARNESS_FLEETS_DIR is under HARNESS_HOME" bash -c '[[ "$HARNESS_FLEETS_DIR" == "$HARNESS_HOME/fleets" ]]'
assert_no "it is NOT the poller registry"            bash -c '[[ "$HARNESS_FLEETS_DIR" == "$POLLER_REGISTRY_DIR" ]]'

echo "== register / read back / deregister =="
rm -rf "$HARNESS_FLEETS_DIR"
( STATE_DIR=/proj/a RUN_DIR=/proj/a/run HARNESS_SESS_PREFIX=alpha fleet_register )
( STATE_DIR=/proj/b RUN_DIR=/proj/b/run HARNESS_SESS_PREFIX=beta  fleet_register )
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json 2>/dev/null | wc -l)" "2" "one file per fleet"

# entries EXCLUDE the caller's own fleet (self must never trip the guard).
OUT="$(fleet_registry_entries /proj/a)"
assert_eq "$(printf '%s\n' "$OUT" | grep -c .)" "1" "self-project excluded from entries"
assert_ok "the other fleet's prefix is reported"  bash -c "grep -q '^beta	/proj/b	/proj/b/run' <<<\"\$OUT\"" 
assert_no "our own prefix is not reported"        bash -c "grep -q '^alpha' <<<\"\$OUT\""

# re-registering the same project overwrites in place (idempotent, not additive).
( STATE_DIR=/proj/a RUN_DIR=/proj/a/run HARNESS_SESS_PREFIX=alpha2 fleet_register )
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "2" "re-register is idempotent"
assert_ok "re-register updates the prefix" bash -c "grep -q '^alpha2	' <<<\"\$(fleet_registry_entries /proj/b)\""

# deregister removes ONLY the calling project's entry, matched on the JSON field not the filename.
fleet_deregister /proj/a
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "1" "deregister removes only its own entry"
assert_ok "the sibling survives" bash -c "grep -q '^beta	' <<<\"\$(fleet_registry_entries /proj/a)\""

echo "== best-effort: the registry is an aid, never a gate =="
# No registry dir at all -> no entries, no error (the single-fleet no-op).
rm -rf "$HARNESS_FLEETS_DIR"
assert_eq "$(fleet_registry_entries /proj/a | grep -c . || true)" "0" "absent registry yields no entries"
assert_ok "absent registry is not an error" fleet_registry_entries /proj/a
# An UNWRITABLE host root must warn and still return 0 — a fleet must always be startable.
RO="$(mktemp -d)"; chmod 500 "$RO"
( HARNESS_FLEETS_DIR="$RO/fleets" STATE_DIR=/proj/c RUN_DIR=/proj/c/run HARNESS_SESS_PREFIX=gamma fleet_register ) 2>/dev/null
assert_eq "$?" "0" "unwritable registry still returns 0"
assert_ok "unwritable registry warns on stderr" bash -c \
  "( HARNESS_FLEETS_DIR='$RO/fleets' STATE_DIR=/proj/c RUN_DIR=/proj/c/run HARNESS_SESS_PREFIX=gamma fleet_register ) 2>&1 >/dev/null | grep -qi 'warning'"
chmod 700 "$RO"

echo "== a malformed entry never breaks the reader =="
mkdir -p "$HARNESS_FLEETS_DIR"; echo 'not json' > "$HARNESS_FLEETS_DIR/junk.json"
( STATE_DIR=/proj/d RUN_DIR=/proj/d/run HARNESS_SESS_PREFIX=delta fleet_register )
assert_ok "malformed entries are skipped, valid ones still read" \
  bash -c "grep -q '^delta	' <<<\"\$(fleet_registry_entries /proj/z)\""

finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_fleet_registry.sh`
Expected: FAIL — unbound variable `HARNESS_FLEETS_DIR`, then `fleet_register: command not found`.

- [ ] **Step 3: Add the path seam**

In `scripts/lib.sh`, after the `POLLER_LOCK=` line (line 92), add:

```bash
# Host-wide fleet registry (prefix-collision guard). Its own directory, NOT poller/registry: those
# files are poller.sh's GitHub work list, so registering there unconditionally would enroll a fleet
# into shared-token polling it never opted into. Same env-seam discipline as the poller paths above
# so tests can point it at a temp root; exported so sub-scripts inherit it.
HARNESS_FLEETS_DIR="${HARNESS_FLEETS_DIR:-$HARNESS_HOME/fleets}"
export HARNESS_FLEETS_DIR
```

- [ ] **Step 4: Implement the registry functions**

In `scripts/lib.sh`, after the closing `}` of `poller_deregister` (around line 917), add:

```bash
# --- host-wide fleet registry ------------------------------------------------
# One file per LIVE fleet under $HARNESS_FLEETS_DIR, named from the sanitised STATE_DIR and holding
# {prefix, project, run_dir, slugs, started_at}. `project` (the STATE_DIR) is the identity key and is
# read back on deregister, so the operation survives filename sanitisation — the same discipline as
# poller_deregister. `harness start` writes an entry unconditionally and `harness stop` removes it;
# the start-time prefix guard reads them for RESERVATION (an idle fleet's prefix stays claimed) and
# for naming the owner in its refusal. tmux, not this file, is the guard's enforcement signal.
#
# Every write is BEST-EFFORT: an unwritable or absent $HARNESS_HOME warns once and returns 0. The
# registry is an aid to collision detection, never a gate on starting a fleet.
_fleet_reg_file(){ printf '%s/%s.json' "$HARNESS_FLEETS_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_')"; }

# fleet_register — record THIS fleet. Idempotent: same project -> same file -> overwritten in place.
fleet_register(){
  if ! mkdir -p "$HARNESS_FLEETS_DIR" 2>/dev/null; then
    printf 'WARNING: cannot create fleet registry at %s — prefix-collision detection degraded\n' \
      "$HARNESS_FLEETS_DIR" >&2; return 0
  fi
  if ! PFX="$HARNESS_SESS_PREFIX" PRJ="$STATE_DIR" RD="$RUN_DIR" \
       SLUGS="$(snapshot_slugs 2>/dev/null | tr '\n' ' ')" \
       python3 - "$(_fleet_reg_file "$STATE_DIR")" <<'PY' 2>/dev/null
import json, os, sys, tempfile, time
f = sys.argv[1]
rec = {"prefix": os.environ["PFX"], "project": os.environ["PRJ"], "run_dir": os.environ["RD"],
       "slugs": os.environ["SLUGS"].split(), "started_at": int(time.time())}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), prefix=".fleet.")
with os.fdopen(fd, "w") as fh:
    json.dump(rec, fh)
os.replace(tmp, f)
PY
  then
    printf 'WARNING: fleet registry write failed (%s) — prefix-collision detection degraded\n' \
      "$HARNESS_FLEETS_DIR" >&2
  fi
  return 0
}

# fleet_deregister <project> — remove the entry this project owns, matched on the JSON `project`
# field rather than the filename. No-op when the registry dir is absent.
fleet_deregister(){
  [[ -d "$HARNESS_FLEETS_DIR" ]] || return 0
  PRJ="$1" python3 - "$HARNESS_FLEETS_DIR" <<'PY' 2>/dev/null
import json, os, sys
d, prj = sys.argv[1], os.environ["PRJ"]
for name in os.listdir(d):
    if not name.endswith(".json"):
        continue
    p = os.path.join(d, name)
    try:
        rec = json.load(open(p))
    except (OSError, ValueError):
        continue
    if rec.get("project") == prj:
        try: os.remove(p)
        except OSError: pass
PY
  return 0
}

# fleet_registry_entries <self-project> — every OTHER registered fleet, one
# `<prefix>\t<project>\t<run_dir>\t<slugs space-separated>` line each. Reads BOTH the fleet registry
# and the poller registry (deduped by project, the fleet entry winning) so a poller-enabled fleet
# running an older engine — which registers only in poller/registry — is still seen. A malformed or
# unreadable file is skipped, never fatal.
fleet_registry_entries(){
  SELF="$1" python3 - "$HARNESS_FLEETS_DIR" "$POLLER_REGISTRY_DIR" <<'PY' 2>/dev/null
import json, os, sys
self_prj = os.environ["SELF"]
seen = {}
for d in sys.argv[1:]:                      # fleet registry first: it wins on conflict
    if not os.path.isdir(d):
        continue
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        try:
            rec = json.load(open(os.path.join(d, name)))
        except (OSError, ValueError):
            continue
        prj = rec.get("project")
        if not prj or prj == self_prj or prj in seen:
            continue
        slugs = rec.get("slugs") or ([rec["slug"]] if rec.get("slug") else [])
        seen[prj] = (rec.get("prefix") or "", rec.get("run_dir") or "", " ".join(slugs))
for prj, (pfx, rd, slugs) in seen.items():
    print(f"{pfx}\t{prj}\t{rd}\t{slugs}")
PY
  return 0
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/test_fleet_registry.sh`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `bash test/run.sh`
Expected: all pass. `test_registry.sh` (the poller registry) and `test_poller.sh` must be unaffected — this task adds a separate directory and touches none of their functions.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib.sh test/test_fleet_registry.sh
git commit -m "feat(prefix): host-wide fleet registry under ~/.harness/fleets

One best-effort JSON per live fleet, keyed on STATE_DIR, recording the
session prefix so the start-time guard has data to read. Kept separate
from poller/registry, whose files are poller.sh's GitHub work list —
registering there unconditionally would enroll fleets into shared-token
polling they never opted into.

fleet_registry_entries reads both directories so a poller-enabled fleet
on an older engine is still visible."
```

---

### Task 3: Wire `start` and `stop` to the registry

**Files:**
- Modify: `scripts/start.sh` (insert before the `if [[ -n "${HARNESS_USE_POLLER:-}" ]]` block at line 104)
- Modify: `scripts/stop.sh` (insert before the `if [[ -n "${HARNESS_USE_POLLER:-}" ]]` block at line 35)
- Test: `test/test_fleet_registry.sh` (new group appended before `finish`)

**Interfaces:**
- Consumes: `fleet_register`, `fleet_deregister` (Task 2)
- Produces: nothing new — this task only wires existing functions

**Note on test seams:** `start.sh` cannot run end-to-end in this harness (it needs tmux, claude, and gh) — see the seam note at `test/test_start_lock.sh:8-10`. Follow the established pattern there: assert `start.sh`'s wiring with static source-order checks, and assert `stop.sh` behaviourally, since it *does* run under the `tmux` function stub already used in `test_prefix_guard.sh:69-75`.

- [ ] **Step 1: Write the failing test**

Append to `test/test_fleet_registry.sh`, immediately before `finish`:

```bash
echo "== start.sh registers UNCONDITIONALLY (static: it can't run in this harness) =="
START="$HERE/../scripts/start.sh"
assert_ok "start.sh calls fleet_register" grep -q '^fleet_register' "$START"
# It must NOT sit inside the HARNESS_USE_POLLER block — that flag is off by default, which is exactly
# why the old guard read an empty registry and never fired.
reg_ln="$(grep -n '^fleet_register' "$START" | head -1 | cut -d: -f1)"
poll_ln="$(grep -n 'if \[\[ -n "\${HARNESS_USE_POLLER:-}" \]\]' "$START" | head -1 | cut -d: -f1)"
guard_ln="$(grep -n '^check_prefix_collision' "$START" | head -1 | cut -d: -f1)"
assert_ok "found the fleet_register line"        test -n "$reg_ln"
assert_ok "found the HARNESS_USE_POLLER block"   test -n "$poll_ln"
assert_ok "found the check_prefix_collision line" test -n "$guard_ln"
assert_ok "registration precedes the poller block (not nested inside it)" test "$reg_ln" -lt "$poll_ln"
assert_ok "registration happens AFTER the collision guard passes"          test "$guard_ln" -lt "$reg_ln"

echo "== stop.sh deregisters unconditionally (behavioural) =="
SRUN="$(mktemp -d)"
tmux(){ case "$1" in ls) return 0;; *) return 0;; esac; }
export -f tmux
rm -rf "$HARNESS_FLEETS_DIR"
( STATE_DIR="$SRUN" RUN_DIR="$SRUN" HARNESS_SESS_PREFIX=zeta fleet_register )
( STATE_DIR=/other/proj RUN_DIR=/other/proj/run HARNESS_SESS_PREFIX=other fleet_register )
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "2" "two fleets registered before stop"
HARNESS_SESS_PREFIX=zeta RUN_DIR="$SRUN" STATE_DIR="$SRUN" bash "$HERE/../scripts/stop.sh" >/dev/null 2>&1
unset -f tmux
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "1" "stop removed exactly one entry"
assert_ok "the sibling fleet's entry survives stop" \
  bash -c "grep -q '^other	' <<<\"\$(fleet_registry_entries /nobody)\""
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_fleet_registry.sh`
Expected: FAIL — `FAIL: start.sh calls fleet_register`, and the stop group leaves 2 entries.

- [ ] **Step 3: Wire `start.sh`**

In `scripts/start.sh`, insert immediately **before** the line `# PRD-B slice 3 (#72): when HARNESS_USE_POLLER is set, register this project's repos with the host` (line 100):

```bash
# Record this fleet in the host-wide registry so a sibling project's `harness start` can see that
# our session prefix is taken. UNCONDITIONAL — deliberately not behind HARNESS_USE_POLLER, which is
# off by default and is exactly why the collision guard used to read an empty registry and never
# fire. Best-effort: an unwritable $HARNESS_HOME warns and start continues. Runs AFTER
# check_prefix_collision so our own entry can't be mistaken for a sibling's by our own guard.
fleet_register
```

- [ ] **Step 4: Wire `stop.sh`**

In `scripts/stop.sh`, insert immediately **before** the line `# PRD-B slice 3 (#72): deregister this project's repos from the host poller` (line 30):

```bash
# Release this fleet's prefix reservation in the host-wide registry. Unconditional, matching
# start.sh's unconditional fleet_register, and scoped to THIS project's STATE_DIR so a co-resident
# sibling's entry is never removed. A fleet killed uncleanly (kill -9, host crash) never reaches
# this line; the start-time guard prunes such entries once they have no live sessions and no live
# pids, and `harness doctor --fix` clears them on demand.
fleet_deregister "$STATE_DIR"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/test_fleet_registry.sh`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `bash test/run.sh`
Expected: all pass. Watch `test_prefix_guard.sh` in particular — it runs `stop.sh` under a tmux stub and now also exercises the new deregister line.

- [ ] **Step 7: Commit**

```bash
git add scripts/start.sh scripts/stop.sh test/test_fleet_registry.sh
git commit -m "feat(prefix): register/deregister the fleet on start and stop

Unconditional, not behind HARNESS_USE_POLLER — that flag is off by
default, which is why check_prefix_collision has been reading an empty
registry and never firing since it shipped."
```

---

### Task 4: Attribute live tmux sessions to their owning project

**Files:**
- Modify: `scripts/lib.sh` (add after `prefixes_collide`, around line 774)
- Test: `test/test_prefix_guard.sh` (new group appended before `finish`)

**Interfaces:**
- Consumes: `prefixes_collide` (`lib.sh:770`), `STATE_DIR`, `HARNESS_SESS_PREFIX`
- Produces:
  - `colliding_sessions` — one `<session>\t<session_path>\t<mine|theirs>` line per live session whose prefix collides with ours
  - `fleet_owner_of <session_path>` — the owning project directory for a session path

**Why tmux and not the registry:** `spawn_impl` creates every session as `tmux new-session -d -s "$sess" -c "$wd"` (`lib.sh:850`), where `$wd` is a worktree under the owning project's `STATE_DIR/worktrees/`. So `session_path` attributes a session to its project with no registry involved — which is what makes the guard work against a sibling fleet on an older engine, one started with a hand-set env var, or a session created by hand.

- [ ] **Step 1: Write the failing test**

Append to `test/test_prefix_guard.sh`, immediately before `finish`:

```bash
echo "== colliding_sessions: tmux is the enforcement signal, session_path the attribution =="
# tmux stub emitting `<name>\t<path>` — the format colliding_sessions requests. Sessions are created
# in a worktree under the OWNING project's STATE_DIR (lib.sh:850), so the path names the owner.
OURS="/home/u/Harness/.harness"; THEIRS="/home/u/Bonsai/.harness"
tmux(){ printf '%s\t%s\n' \
  "hz-main-i1"        "$THEIRS/worktrees/main-i1" \
  "hz-bug-a_b-5-fix"  "$THEIRS/worktrees/bug-a_b-5" \
  "hzli-main-i1"      "/home/u/Other/.harness/worktrees/main-i1" \
  "boto-x"            "/home/u/Third/.harness/worktrees/x"; }
export -f tmux

# Our prefix is hz and the live hz-* sessions belong to ANOTHER project -> both reported as theirs.
OUT="$(HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" colliding_sessions)"
assert_eq "$(grep -c 'theirs$' <<<"$OUT")" "2" "both hz-* sessions attributed to the sibling"
assert_no "hzli is not in our prefix space" bash -c "grep -q 'hzli' <<<\"\$OUT\""
assert_no "boto is not in our prefix space" bash -c "grep -q 'boto' <<<\"\$OUT\""

# Same sessions, but they are OURS (paths under our STATE_DIR) -> mine, not theirs. This is the
# `harness start --recover` path: a documented re-run against a live fleet, which must proceed.
OUT="$(HARNESS_SESS_PREFIX=hz STATE_DIR="$THEIRS" colliding_sessions)"
assert_eq "$(grep -c 'mine$' <<<"$OUT")"   "2" "sessions under our own STATE_DIR are ours"
assert_eq "$(grep -c 'theirs$' <<<"$OUT")" "0" "and none are attributed to a sibling"

# A prefix that owns a superset of the namespace still collides (hz- swallows hz-bug-…).
OUT="$(HARNESS_SESS_PREFIX=hz-bug STATE_DIR="$OURS" colliding_sessions)"
assert_ok "hz-bug sees the overlapping hz-* sessions" bash -c "[[ -n \"\$(grep 'theirs$' <<<\"\$OUT\")\" ]]"

# A non-colliding prefix sees nothing at all — the single-fleet no-op.
OUT="$(HARNESS_SESS_PREFIX=widget STATE_DIR="$OURS" colliding_sessions)"
assert_eq "$(grep -c . <<<"$OUT" || true)" "0" "a distinct prefix sees no collisions"
unset -f tmux

# No tmux server at all (nothing running) must be a clean empty result, not an error. Call it
# IN-PROCESS — under `bash -c` the subshell never sourced lib.sh, so colliding_sessions would be
# "command not found" and the assertion would test nothing about this function.
tmux(){ return 1; }; export -f tmux
HARNESS_SESS_PREFIX=hz colliding_sessions >/dev/null
assert_eq "$?" "0" "no tmux server is a clean empty result, not an error"
unset -f tmux

echo "== fleet_owner_of: session path -> owning project dir =="
assert_eq "$(fleet_owner_of /home/u/Bonsai/.harness/worktrees/main-i1)" "/home/u/Bonsai" "cuts at /worktrees/"
assert_eq "$(fleet_owner_of /home/u/Bonsai/.harness/worktrees/bug-a_b-5/nested)" "/home/u/Bonsai" "nested path still resolves"
assert_eq "$(fleet_owner_of /some/unrecognised/path)" "/some/unrecognised/path" "unrecognised path falls back to itself"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_prefix_guard.sh`
Expected: FAIL — `colliding_sessions: command not found`.

- [ ] **Step 3: Implement both functions**

In `scripts/lib.sh`, insert immediately **after** the closing `}` of `prefixes_collide` (line 774):

```bash
# colliding_sessions — every LIVE tmux session whose prefix space overlaps ours, one
# `<session>\t<session_path>\t<mine|theirs>` line each. This is the guard's ENFORCEMENT signal: tmux
# is the namespace actually at stake, it cannot go stale, and it sees sibling fleets that appear in
# NO registry (an older engine, a hand-set HARNESS_SESS_PREFIX, a session made by hand).
#
# Attribution comes from `session_path`: spawn_impl creates every session as
# `tmux new-session -d -s "$sess" -c "$wd"` with $wd a worktree under the OWNING project's
# STATE_DIR/worktrees/, so the path names the owner. `mine` is the `harness start --recover` case —
# a documented re-run against a live fleet, which must be allowed to proceed.
#
# A session's prefix is read as its leading dash-delimited segment. That UNDER-reads an owner whose
# own prefix contains a dash (`my-app-main-i1` -> `my`), but the under-read is sound rather than
# approximate: a shorter prefix owns strictly MORE of the namespace, so if `my` collides with ours so
# does `my-app`, and if it does not then `my-app-…` lies outside our space anyway. No genuine
# collision is missed and no false one is introduced.
colliding_sessions(){
  local name path seg
  while IFS=$'\t' read -r name path; do
    [[ -n "$name" ]] || continue
    seg="${name%%-*}"
    prefixes_collide "$HARNESS_SESS_PREFIX" "$seg" || continue
    if [[ "$path" == "$STATE_DIR" || "$path" == "$STATE_DIR"/* ]]; then
      printf '%s\t%s\tmine\n' "$name" "$path"
    else
      printf '%s\t%s\ttheirs\n' "$name" "$path"
    fi
  done < <(tmux ls -F '#{session_name}'$'\t''#{session_path}' 2>/dev/null || true)
}

# fleet_owner_of <session_path> — the project directory owning a fleet session. Sessions live in a
# worktree under <owner STATE_DIR>/worktrees/, so cutting at /worktrees/ yields that STATE_DIR and
# its parent is the project dir. A path that doesn't match (a hand-made session, an unusual layout)
# falls back to itself, so the refusal message still says something true and actionable.
fleet_owner_of(){ local p="$1"
  if [[ "$p" == */worktrees/* ]]; then dirname "${p%%/worktrees/*}"; else printf '%s\n' "$p"; fi; }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/test_prefix_guard.sh`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `bash test/run.sh`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib.sh test/test_prefix_guard.sh
git commit -m "feat(prefix): attribute live tmux sessions to their owning project

Sessions are created with -c <worktree> under the owner's STATE_DIR
(lib.sh:850), so session_path identifies the owning project with no
registry involved — which is what lets the guard catch a sibling fleet
running an older engine or started with a hand-set prefix."
```

---

### Task 5: Rewrite `check_prefix_collision`

**Files:**
- Modify: `scripts/lib.sh:803-818` (replace the body of `check_prefix_collision`; add `fleet_stale` and `_prefix_collision_report` above it)
- Modify: `scripts/init.sh` (warn when the derived prefix is already taken)
- Test: `test/test_prefix_guard.sh` (replace the existing `== start-time guard reads slice-2's registry ==` group; append an init-warning group)

**Interfaces:**
- Consumes: `colliding_sessions`, `fleet_owner_of` (Task 4); `fleet_registry_entries`, `fleet_deregister` (Task 2); `derive_prefix` (Task 1); `prefixes_collide`, `die`
- Produces:
  - `fleet_stale <prefix> <run_dir>` — 0 when that fleet has no live sessions and no live pids
  - `check_prefix_collision` — unchanged name and call site (`start.sh:72`); returns 0 or dies

- [ ] **Step 1: Write the failing test**

In `test/test_prefix_guard.sh`, **replace** the whole group headed `== start-time guard reads slice-2's registry (poller_register records the prefix) ==` (through the line ending `"empty/absent registry never refuses (single-fleet no-op)"`) with:

```bash
echo "== the guard: tmux enforces, the registry reserves and attributes =="
REG="$HARNESS_HOME/poller/registry"
FREG="$HARNESS_HOME/fleets"
reset_reg(){ rm -rf "$REG" "$FREG"; mkdir -p "$REG" "$FREG"; }
OURS="/home/u/Harness/.harness"; THEIRS="/home/u/Bonsai/.harness"
no_tmux(){ tmux(){ return 1; }; export -f tmux; }
their_sessions(){ tmux(){ printf '%s\t%s\n' "hz-main-i1" "/home/u/Bonsai/.harness/worktrees/main-i1"; }; export -f tmux; }
our_sessions(){ tmux(){ printf '%s\t%s\n' "hz-main-i1" "/home/u/Harness/.harness/worktrees/main-i1"; }; export -f tmux; }

# 1. A sibling's LIVE sessions in our prefix space -> refuse, even with an EMPTY registry. This is
#    the case the old guard could never see: it read only the poller registry, which is written
#    behind HARNESS_USE_POLLER (off by default), so it always passed.
reset_reg; their_sessions
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "live sibling sessions REFUSE the start with no registry at all"

# 2. The refusal names the owner, our project, the live count, and a concrete retry line.
MSG="$( ( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" check_prefix_collision ) 2>&1 >/dev/null )"
assert_ok "message names the owning project"  bash -c "grep -q '/home/u/Bonsai' <<<\"\$MSG\""
assert_ok "message names our project"         bash -c "grep -q '/home/u/Harness' <<<\"\$MSG\""
assert_ok "message reports the live count"    bash -c "grep -qE '1 live tmux session' <<<\"\$MSG\""
assert_ok "message offers a retry command"    bash -c "grep -q 'HARNESS_SESS_PREFIX=' <<<\"\$MSG\""
assert_ok "message points at the config file" bash -c "grep -q '$OURS/config' <<<\"\$MSG\""

# 3. warn mode still downgrades to a stderr warning and proceeds.
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=warn check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "warn mode proceeds despite a real collision"

# 4. The SAME sessions, owned by US -> proceed. This is `harness start --recover` against a live
#    fleet, which is a documented, supported re-run.
our_sessions
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "our own live sessions never refuse (the --recover path)"

# 5. RESERVATION: a registered sibling with NO live sessions still refuses, so two idle fleets can't
#    race into one namespace. Its run_dir holds a live pid, so it is not stale.
reset_reg; no_tmux
LIVE_RD="$(mktemp -d)"; sleep 300 & LIVE_PID=$!; echo "$LIVE_PID" > "$LIVE_RD/worker-1.pid"
( STATE_DIR="$THEIRS" RUN_DIR="$LIVE_RD" HARNESS_SESS_PREFIX=hz fleet_register )
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "a registered, live-but-idle sibling reserves its prefix"

# 6. STALENESS: no live sessions AND no live pids -> the entry is pruned and the start proceeds. A
#    fleet killed with -9 never deregisters; its reservation must not block a restart forever.
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "a crashed sibling's stale reservation does not refuse"
assert_eq "$(ls "$FREG"/*.json 2>/dev/null | wc -l)" "0" "and the stale entry is pruned"

# 7. A poller-registry-only sibling (older engine) is still seen — fleet_registry_entries reads both.
reset_reg; no_tmux
POLL_RD="$(mktemp -d)"; sleep 300 & POLL_PID=$!; echo "$POLL_PID" > "$POLL_RD/priority.pid"
poller_register acme/widget 60 hz "$THEIRS"
python3 - "$REG" "$POLL_RD" <<'PY'
import json, os, sys
d, rd = sys.argv[1], sys.argv[2]
for n in os.listdir(d):
    p = os.path.join(d, n); rec = json.load(open(p)); rec["run_dir"] = rd
    json.dump(rec, open(p, "w"))
PY
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "1" "a poller-registry-only sibling still refuses"
kill "$POLL_PID" 2>/dev/null; wait "$POLL_PID" 2>/dev/null

# 8. Non-colliding neighbours coexist: hz / hzli / boto, the live three-fleet arrangement.
reset_reg; no_tmux
( STATE_DIR=/p/one RUN_DIR=/p/one/run HARNESS_SESS_PREFIX=hzli fleet_register )
( STATE_DIR=/p/two RUN_DIR=/p/two/run HARNESS_SESS_PREFIX=boto fleet_register )
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "hz coexists with sibling hzli + boto"

# 9. Our OWN registry entry never trips the guard (self-exclusion on STATE_DIR).
reset_reg; no_tmux
( STATE_DIR="$OURS" RUN_DIR=/p/us/run HARNESS_SESS_PREFIX=hz fleet_register )
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "our own registry entry does not self-collide"

# 10. No registry and no tmux server -> the single-fleet no-op, unchanged behaviour.
rm -rf "$REG" "$FREG"
( HARNESS_SESS_PREFIX=hz STATE_DIR="$OURS" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) 2>/dev/null
assert_eq "$?" "0" "absent registry + no tmux never refuses"
unset -f tmux
```

Then append this group, immediately before `finish`:

```bash
echo "== fleet_stale: a crashed fleet's reservation must not block a restart forever =="
STALE_RD="$(mktemp -d)"
tmux(){ printf '%s\t%s\n' "alpha-main-i1" "/p/alpha/.harness/worktrees/main-i1"; }; export -f tmux
assert_no "a fleet with live sessions is NOT stale" fleet_stale alpha "$STALE_RD"
assert_ok "a fleet with neither sessions nor pids IS stale" fleet_stale beta "$STALE_RD"
sleep 300 & SP=$!; echo "$SP" > "$STALE_RD/worker-1.pid"
assert_no "a fleet with a live pid is NOT stale" fleet_stale beta "$STALE_RD"
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
assert_ok "a dead pidfile does not keep a fleet alive" fleet_stale beta "$STALE_RD"
unset -f tmux
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_prefix_guard.sh`
Expected: FAIL — `fleet_stale: command not found`, and assertion 1 returns 0 instead of 1 (the old guard reads only the poller registry, which is empty here).

- [ ] **Step 3: Implement `fleet_stale` and the message helper**

In `scripts/lib.sh`, insert immediately **above** `check_prefix_collision` (line 803, under its comment banner):

```bash
# fleet_stale <prefix> <run_dir> — is a REGISTERED fleet actually dead? True when no live tmux
# session sits under `<prefix>-` AND no pid recorded in its run_dir is alive. A fleet killed with -9
# or lost to a host crash never reaches stop.sh's fleet_deregister, and its leftover reservation must
# not refuse a legitimate restart forever. Both signals are checked because either can outlive the
# other: sessions can survive a dead worker pool (status.sh calls that DEGRADED), and a worker can be
# alive between session spawns.
fleet_stale(){ local pfx="$1" rd="$2" name p
  while IFS=$'\t' read -r name _; do
    [[ "$name" == "$pfx-"* ]] && return 1
  done < <(tmux ls -F '#{session_name}'$'\t''#{session_path}' 2>/dev/null || true)
  for p in "$rd"/*.pid; do
    [[ -e "$p" ]] || continue
    kill -0 "$(cat "$p" 2>/dev/null)" 2>/dev/null && return 1
  done
  return 0; }

# _prefix_collision_report <owner-dir> <owner-slugs> <live-session-count> — the refusal. Names the
# owner, our own project, and a concrete retry, because the operator's next question is always
# "which project has it, and what do I type instead". Honours HARNESS_PREFIX_COLLISION: `refuse`
# (default) dies, `warn` prints to stderr and returns 0. The engine NEVER edits .harness/config
# itself and never starts under a prefix other than the configured one.
_prefix_collision_report(){ local owner="$1" slugs="$2" n="$3" sugg msg
  sugg="$(derive_prefix "$PROJECT_ROOT")"
  [[ "$sugg" != "$HARNESS_SESS_PREFIX" ]] || sugg="${sugg}2"
  msg="$(printf 'session prefix %s is in use by another fleet\n  owner:    %s%s\n  prefix:   %s — %s live tmux session(s)\n  yours:    %s\nretry with a distinct prefix, e.g.:\n  HARNESS_SESS_PREFIX=%s harness start\nor set HARNESS_SESS_PREFIX in %s/config\n(HARNESS_PREFIX_COLLISION=warn overrides)' \
    "$HARNESS_SESS_PREFIX" "$owner" "${slugs:+ (repo $slugs)}" "$HARNESS_SESS_PREFIX" "$n" \
    "$PROJECT_ROOT" "$sugg" "$STATE_DIR")"
  case "${HARNESS_PREFIX_COLLISION:-refuse}" in
    warn) printf 'WARNING: %s\n' "$msg" >&2; return 0;;
    *)    die "$msg";;
  esac
}
```

- [ ] **Step 4: Replace `check_prefix_collision`**

In `scripts/lib.sh`, replace the entire existing `check_prefix_collision(){ … }` body (lines 807-818) with:

```bash
check_prefix_collision(){
  local name path who hit_path="" n=0
  # 1) LIVE tmux sessions — the enforcement signal. Sessions attributed to another project mean the
  #    namespace is genuinely shared right now: our stop.sh would kill their agents mid-edit.
  while IFS=$'\t' read -r name path who; do
    [[ "$who" == theirs ]] || continue
    n=$((n+1)); [[ -n "$hit_path" ]] || hit_path="$path"
  done < <(colliding_sessions)
  if (( n > 0 )); then
    local owner; owner="$(fleet_owner_of "$hit_path")"
    # In `refuse` mode the report dies (exits); in `warn` mode it returns 0 and we proceed. Pass its
    # status straight through — do NOT add a `return 1` after this call, which would defeat warn mode.
    _prefix_collision_report "$owner" "$(fleet_slugs_of "$owner")" "$n"
    return $?
  fi
  # 2) The registry — RESERVATION. A registered sibling with no sessions yet still owns its prefix,
  #    so two idle fleets can't race into one namespace. A STALE entry (no sessions, no live pids —
  #    a fleet that died before stop.sh could deregister) is pruned instead of refusing forever.
  local pfx prj rd slugs
  while IFS=$'\t' read -r pfx prj rd slugs; do
    [[ -n "$pfx" ]] || continue
    prefixes_collide "$HARNESS_SESS_PREFIX" "$pfx" || continue
    if fleet_stale "$pfx" "$rd"; then fleet_deregister "$prj"; continue; fi
    _prefix_collision_report "$(dirname "$prj")" "$slugs" 0
    return $?
  done < <(fleet_registry_entries "$STATE_DIR")
  return 0
}

# fleet_slugs_of <project-dir> — the repo slugs a registered fleet serves, for the refusal message.
# Empty when that fleet isn't registered (an older engine, a hand-made session): the message still
# names the owning directory, which is the part the operator acts on.
fleet_slugs_of(){ local dir="$1" pfx prj rd slugs
  while IFS=$'\t' read -r pfx prj rd slugs; do
    [[ "$(dirname "$prj")" == "$dir" ]] && { printf '%s\n' "$slugs"; return 0; }
  done < <(fleet_registry_entries "")
  printf '\n'; }
```

Note on the return convention: `_prefix_collision_report` never returns in `refuse` mode (`die` exits the process) and returns 0 in `warn` mode. `check_prefix_collision` therefore passes its status straight through with `return $?`. Do not add a trailing `return 1` after either call — it would fire on the warn path and refuse the start anyway, defeating `HARNESS_PREFIX_COLLISION=warn`. The refusal's non-zero exit comes from `die`, not from this function.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/test_prefix_guard.sh`
Expected: PASS, including the pre-existing `prefixes_collide`, session-grammar, and `stop.sh` groups.

- [ ] **Step 6: Write the failing test for the `init` warning**

Append to `test/test_init.sh`, before its final lines:

```bash
# init WARNS (never refuses — it starts nothing) when the derived prefix is already claimed, and
# offers the hash fallback instead so the operator isn't left to invent one.
PDIR3="$TMP/Widget3"; mkdir -p "$PDIR3/.harness"
export HARNESS_HOME="$TMP/host3"; mkdir -p "$HARNESS_HOME/fleets"
python3 - "$HARNESS_HOME/fleets/sibling.json" "$PDIR3" <<'PY'
import json, sys
json.dump({"prefix": "widget3", "project": "/elsewhere/.harness",
           "run_dir": "/elsewhere/.harness/run", "slugs": ["acme/other"],
           "started_at": 0}, open(sys.argv[1], "w"))
PY
OUT="$( ( export STATE_DIR="$PDIR3/.harness" HARNESS_DIR="$PDIR3/.harness"
  HARNESS_INIT_NONINTERACTIVE=1 HARNESS_TOPOLOGY=single HARNESS_OWNER=acme HARNESS_REPO=acme/widget \
    bash "$HERE/../scripts/init.sh" ) 2>&1 )"
assert "init warns that the derived prefix is taken" "grep -qi 'in use\|taken\|collide' <<<\"\$OUT\""
assert "init still writes a config"                  "[[ -f '$PDIR3/.harness/config' ]]"
( source "$PDIR3/.harness/config"; [[ "${HARNESS_SESS_PREFIX:-}" != "widget3" ]] ) \
  && echo "  ok: init proposed a different prefix" || { echo "  FAIL: init reused the taken prefix"; exit 1; }
```

- [ ] **Step 7: Run it to verify it fails**

Run: `bash test/test_init.sh`
Expected: FAIL — `FAIL: init warns that the derived prefix is taken`.

- [ ] **Step 8: Implement the `init` warning**

In `scripts/init.sh`, replace the `default_prefix()` helper added in Task 1 with:

```bash
# The prefix default is DERIVED from the project directory (derive_prefix) so two projects on one
# host don't both take lib.sh's `hz`. derive_prefix lives in lib.sh — one definition, also used by
# the start-time guard and `harness status` — but init.sh deliberately does NOT source lib.sh at the
# top: lib.sh fills every HARNESS_* with its default at source time, which would defeat the `ask`
# fallbacks below (and, for the prefix specifically, would hand back `hz`). Read it out of a
# throwaway subshell instead, with the var unset so lib.sh's default can't leak into the answer.
#
# If the derived name is already claimed by a live or registered fleet, fall back to the hash form
# and say so. init only WARNS — it starts nothing, so there is nothing to refuse; `harness start` is
# where a genuine collision is enforced.
default_prefix(){ ( unset HARNESS_SESS_PREFIX
  source "$ENGINE_DIR/scripts/lib.sh" >/dev/null 2>&1
  local p; p="$(derive_prefix "$PROJECT_ROOT")"
  if ( HARNESS_SESS_PREFIX="$p" HARNESS_PREFIX_COLLISION=refuse check_prefix_collision ) >/dev/null 2>&1; then
    printf '%s\n' "$p"
  else
    printf 'NOTE: session prefix %s is already in use by another fleet on this host — proposing %s instead\n' \
      "$p" "hz$(printf '%s' "$PROJECT_ROOT" | python3 -c \
        'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:4])')" >&2
    printf 'hz%s\n' "$(printf '%s' "$PROJECT_ROOT" | python3 -c \
      'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:4])')"
  fi ); }
```

- [ ] **Step 9: Run both tests to verify they pass**

Run: `bash test/test_init.sh && bash test/test_prefix_guard.sh`
Expected: PASS for both.

- [ ] **Step 10: Run the full suite**

Run: `bash test/run.sh`
Expected: all pass.

- [ ] **Step 11: Commit**

```bash
git add scripts/lib.sh scripts/init.sh test/test_prefix_guard.sh test/test_init.sh
git commit -m "feat(prefix): enforce collisions on live tmux, reserve via the registry

check_prefix_collision now refuses when a session in our prefix space is
attributed to another project, so it fires with an empty registry and
against fleets running an older engine. The registry adds reservation for
idle fleets and names the owner in the refusal; entries with no sessions
and no live pids are pruned rather than blocking a restart forever.

harness init warns and proposes the hash fallback when the prefix it
derived is already claimed."
```

---

### Task 6: Surface the prefix in `status`, `doctor`, and the README

**Files:**
- Modify: `scripts/status.sh` (in `render_once`, after the `sess_total=` line at line 45)
- Modify: `scripts/doctor.sh` (add `doctor_fleets`; call it from `main` alongside `doctor_locks`)
- Modify: `README.md` (the `HARNESS_SESS_PREFIX` row at line 115; a new "Fleet prefixes" section)
- Test: `test/test_status.sh`, `test/test_doctor.sh`, `test/test_readme_docs.sh`

**Interfaces:**
- Consumes: `fleet_registry_entries`, `fleet_stale`, `fleet_deregister` (Tasks 2 and 5), `HARNESS_SESS_PREFIX`
- Produces: `doctor_fleets` — prints findings, echoes nothing reassuring when clean, returns the problem count (matching `doctor_locks`' contract at `scripts/doctor.sh:21`)

- [ ] **Step 1: Write the failing tests**

Append to `test/test_status.sh`, before its `finish`:

```bash
echo "== status names this fleet's prefix and any siblings on the host =="
export HARNESS_HOME="$(mktemp -d)"; export HARNESS_FLEETS_DIR="$HARNESS_HOME/fleets"
( STATE_DIR=/p/sib RUN_DIR=/p/sib/run HARNESS_SESS_PREFIX=sibling fleet_register )
tmux(){ return 1; }; export -f tmux
OUT="$(HARNESS_SESS_PREFIX=mine bash "$HERE/../scripts/status.sh" 2>&1 || true)"
unset -f tmux
assert_ok "status prints our prefix"          bash -c "grep -q 'mine' <<<\"\$OUT\""
assert_ok "status lists the sibling fleet"    bash -c "grep -q 'sibling' <<<\"\$OUT\""
assert_ok "status names the sibling's project" bash -c "grep -q '/p/sib' <<<\"\$OUT\""
```

Append to `test/test_doctor.sh`, before its `finish`:

```bash
echo "== doctor reports and --fix prunes stale fleet-registry entries =="
export HARNESS_HOME="$(mktemp -d)"; export HARNESS_FLEETS_DIR="$HARNESS_HOME/fleets"
tmux(){ return 1; }; export -f tmux
# A dead fleet: no sessions, no live pids. Its reservation would otherwise sit there forever.
DEAD_RD="$(mktemp -d)"; echo 999999 > "$DEAD_RD/worker-1.pid"
( STATE_DIR=/p/dead RUN_DIR="$DEAD_RD" HARNESS_SESS_PREFIX=dead fleet_register )
OUT="$(doctor_fleets)"; PROBLEMS=$?
assert_ok "doctor reports the stale entry"  bash -c "grep -qi 'stale' <<<\"\$OUT\""
assert_ok "doctor names the dead fleet"     bash -c "grep -q '/p/dead' <<<\"\$OUT\""
assert_ok "doctor counts it as a problem"   test "$PROBLEMS" -gt 0
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "1" "report-only leaves the entry in place"
DOCTOR_FIX=1 doctor_fleets >/dev/null
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json 2>/dev/null | wc -l)" "0" "--fix prunes the stale entry"

# A LIVE fleet must never be pruned or flagged.
sleep 300 & LP=$!; LIVE_RD="$(mktemp -d)"; echo "$LP" > "$LIVE_RD/worker-1.pid"
( STATE_DIR=/p/live RUN_DIR="$LIVE_RD" HARNESS_SESS_PREFIX=live fleet_register )
DOCTOR_FIX=1 doctor_fleets >/dev/null
assert_eq "$(ls "$HARNESS_FLEETS_DIR"/*.json | wc -l)" "1" "--fix never prunes a live fleet"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
unset -f tmux
```

Append to `test/test_readme_docs.sh`, before its final lines:

```bash
# 6. Fleet prefixes — the config row explains uniqueness-per-host, and a section explains the
#    registry, the refusal, and the doctor escape hatch.
assert "config table row for HARNESS_SESS_PREFIX mentions per-host uniqueness" \
  "grep -E '^\| \`HARNESS_SESS_PREFIX\`' '$README' | grep -qi 'uniqu\|per fleet\|per project'"
assert "README has a Fleet prefixes section" "grep -qiE '^#+ .*[Ff]leet prefix' '$README'"
assert "README documents the fleets registry path" "grep -q '~/.harness/fleets' '$README'"
assert "README documents HARNESS_PREFIX_COLLISION" \
  "grep -qE '^\| \`HARNESS_PREFIX_COLLISION\`' '$README'"
assert "README documents the doctor escape hatch for stale entries" \
  "grep -qi 'doctor --fix' '$README'"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash test/test_status.sh; bash test/test_doctor.sh; bash test/test_readme_docs.sh`
Expected: FAIL in each — status prints no prefix line, `doctor_fleets: command not found`, README assertions fail.

- [ ] **Step 3: Implement the `status` line**

In `scripts/status.sh`, in `render_once`, insert immediately after the `sess_total="$(tmux ls …)"` line:

```bash
  # Which tmux namespace this fleet owns, and who else is on the host. A shared prefix is what makes
  # `harness stop` here kill another project's agents, so it belongs in the at-a-glance view.
  echo "prefix: $HARNESS_SESS_PREFIX"
  local _p _prj _rd _slugs _sibs=0
  while IFS=$'\t' read -r _p _prj _rd _slugs; do
    [[ -n "$_p" ]] || continue
    (( _sibs++ )); printf '  sibling fleet: %-12s %s%s\n' "$_p" "$(dirname "$_prj")" "${_slugs:+ ($_slugs)}"
  done < <(fleet_registry_entries "$STATE_DIR")
  (( _sibs == 0 )) && echo "  (no other fleets registered on this host)"
```

- [ ] **Step 4: Implement `doctor_fleets`**

In `scripts/doctor.sh`, add after `doctor_locks`' closing `}`:

```bash
# doctor_fleets — stale entries in the host-wide fleet registry. A fleet killed with -9 or lost to a
# host crash never reaches stop.sh's fleet_deregister, so its prefix reservation lingers. The start
# guard prunes such entries on its own, but an operator who wants the host clean now needs a lever —
# this is it. Report-only by default; --fix prunes. A LIVE fleet is never touched. Returns the
# problem count, matching doctor_locks.
doctor_fleets(){
  local problems=0 pfx prj rd slugs
  [[ -d "$HARNESS_FLEETS_DIR" ]] || { echo "  fleet registry: absent (never created — fine)"; return 0; }
  while IFS=$'\t' read -r pfx prj rd slugs; do
    [[ -n "$pfx" ]] || continue
    if fleet_stale "$pfx" "$rd"; then
      problems=$((problems+1))
      echo "  fleet registry: STALE entry — prefix '$pfx' reserved by $prj (no live sessions, no live pids)"
      if (( DOCTOR_FIX )); then
        fleet_deregister "$prj"; echo "    → pruned"
      else
        echo "    → prune with: harness doctor --fix"
      fi
    fi
  done < <(fleet_registry_entries "")
  return $problems
}
```

Then call it from `doctor.sh`'s `main` wherever `doctor_locks` is invoked, adding its return value to the same problem tally. Read the existing `main` first and follow its exact accumulation idiom.

- [ ] **Step 5: Update the README**

Change the `HARNESS_SESS_PREFIX` row (line 115) to:

```
| `HARNESS_SESS_PREFIX` | derived from the project dir at `init` (`hz` for pre-existing configs) | tmux session name prefix — **must be unique per fleet on a host**; a shared prefix makes `harness stop` in one project kill another's agents |
```

Add a `HARNESS_PREFIX_COLLISION` row to the same table:

```
| `HARNESS_PREFIX_COLLISION` | `refuse` | `refuse` \| `warn` — what `harness start` does when another fleet already owns this session prefix |
```

Add a section (place it beside the "Host poller" section):

```markdown
### Fleet prefixes

Every tmux session a fleet creates is named `<prefix>-…`, and `harness stop` kills everything
matching `^<prefix>-`. Two fleets sharing a prefix on one host therefore cross-kill: stopping one
tears down the other's live agents mid-edit.

`harness init` derives a distinct prefix from the project directory name (`~/proj/Harness` →
`harness`) and writes it to `.harness/config`, so this is handled for you. Projects initialised
before this existed have no prefix line and keep the historical `hz` default — set
`HARNESS_SESS_PREFIX` in their `.harness/config` if more than one fleet runs on the host.

`harness start` refuses to start on a prefix another fleet already owns, naming the project that
holds it and the retry command. It detects this two ways: live tmux sessions in the prefix space
(attributed to their project by each session's working directory, so it works even against a fleet
running an older engine), and the host-wide registry at `~/.harness/fleets/` — one JSON per live
fleet, written by `harness start` and removed by `harness stop`. The registry also reserves the
prefix of a fleet that is registered but currently idle.

A fleet killed with `kill -9` never deregisters. Its entry is pruned automatically once it has no
live sessions and no live worker pids, or on demand with `harness doctor --fix`.
`HARNESS_PREFIX_COLLISION=warn` downgrades the refusal to a warning.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash test/test_status.sh && bash test/test_doctor.sh && bash test/test_readme_docs.sh`
Expected: PASS for all three.

- [ ] **Step 7: Run the full suite**

Run: `bash test/run.sh`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add scripts/status.sh scripts/doctor.sh README.md test/test_status.sh test/test_doctor.sh test/test_readme_docs.sh
git commit -m "feat(prefix): surface prefixes in status and doctor, document them

status names this fleet's tmux namespace and any siblings on the host.
doctor reports stale registry entries left by a fleet that died before it
could deregister; --fix prunes them, never touching a live fleet."
```

---

## Self-Review

**Spec coverage:** Component 1 → Task 1 (derivation, prompt, persistence, `hz` default preserved) and Task 5 Steps 6-9 (`init`'s collision warning). Component 2 → Tasks 2 and 3 (registry primitives, `start`/`stop` wiring, best-effort writes, separation from the poller registry). Component 3 → Tasks 4 and 5 (tmux enforcement with `session_path` attribution, registry reservation, staleness pruning, refusal message, `warn` mode). Component 4 → Task 6 (`status`, `doctor --fix`, README). Testing section → covered across Tasks 1-6; every listed case has an assertion. Out-of-scope items are respected: no auto-suffixing, no engine writes to `.harness/config`, `lib.sh:44` unchanged, `HARNESS_USE_POLLER` untouched.

**Placeholder scan:** No TBDs. Every code step carries the actual code. Task 6 Step 4's final instruction ("follow `main`'s exact accumulation idiom") is the one place the implementer must read surrounding code rather than paste — deliberate, because `doctor.sh`'s `main` was not read in full while planning and inventing its shape would be worse than pointing at it.

**Type consistency:** `derive_prefix` (Task 1) is called by `_prefix_collision_report` and `init.sh` (Task 5) — same signature. `fleet_register`/`fleet_deregister`/`fleet_registry_entries` (Task 2) are called with matching argument counts in Tasks 3, 5, and 6. `fleet_registry_entries` emits four tab-separated fields everywhere it is read (`check_prefix_collision`, `fleet_slugs_of`, `status.sh`, `doctor_fleets`). `colliding_sessions` emits three fields and is read as three in `check_prefix_collision`. `fleet_stale <prefix> <run_dir>` is called with that argument order in both `check_prefix_collision` and `doctor_fleets`. `HARNESS_FLEETS_DIR` is the single name used throughout.

**Known risk to verify during Task 5:** `check_prefix_collision` gained a forward reference — it calls `fleet_slugs_of`, which the plan places *after* it in `lib.sh`. Bash resolves function calls at call time, not parse time, so this works, but keep both definitions inside `lib.sh` and do not move either into a script that sources selectively.

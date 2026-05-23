# Harness Pause / Resume / Update / Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `pause` / `pause --force` / `resume` / `update` / `setup` to the Harness fleet — reachable from both `bin/harness` and the `/harness` skill — with force-pause checkpoints stored 100% in GitHub so a fleet paused on one machine resumes on another, and an `update` that never destroys user config.

**Architecture:** A local flag file `$RUN_DIR/PAUSED` is the per-machine idle signal (soft pause). `pause --force` nudges each live agent via `tmux send-keys` to commit+push its branch, post its `/handoff` context as a GitHub issue comment, and label the issue `agent-paused`; the label is the portable, queryable source of truth. `resume` re-dispatches `agent-paused` issues through the normal loop into a `resume.md` continue-prompt. `update` fast-forwards `.harness` and redeploys the skill while snapshotting/restoring user config.

**Tech Stack:** Bash, Python 3 stdlib, `gh`, `tmux`, the existing plain-bash assertion rig (`test/helpers.sh`, `test/run.sh`).

**Spec:** `docs/superpowers/specs/2026-05-24-harness-pause-resume-update-design.md`.

**Conventions carried from the base build (do not violate):**
- Repo path contains a space → in tests, quote interpolated paths inside `eval`'d strings; run `bash test/run.sh` from the real path (no symlink).
- `set -uo pipefail` everywhere; no `set -e`. Guard array expansions (`"${arr[@]:-}"`), default unset vars (`${x:-}`).
- Tests are offline: stub `gh`, `git`, `tmux`. Reuse `make_env` from `test/helpers.sh`.
- After every task: `bash test/run.sh` green, then commit.

---

## File Structure

**New files:**
- `pause.sh` — soft pause + `--force` checkpoint orchestration.
- `resume.sh` — clear pause; resume locally or `start --recover`.
- `update.sh` — config-safe ff-pull + skill redeploy.
- `setup.sh` — verify prereqs + seed all units.
- `prompts/resume.md` — continue-a-paused-issue prompt.
- `test/test_pause.sh`, `test/test_update.sh`, `test/test_setup.sh`, `test/test_resume.sh`.

**Modified:** `lib.sh`, `pool-worker.sh`, `drive.sh`, `issuelib.py`, `seed.sh`, `status.sh`, `start.sh`, `stop.sh`, `bin/harness`, `init.sh`, `prompts/impl.md`, `skill/SKILL.md`, `README.md`, `test/helpers.sh`, `test/test_cli.sh`, `test/test_status.sh`, `test/test_seed.sh`.

---

### Task 1: `lib.sh` + `helpers.sh` + `init.sh` — pause flag, `is_paused`, paused-label config

**Files:**
- Modify: `lib.sh`
- Modify: `test/helpers.sh`
- Modify: `init.sh`
- Test: `test/test_pause.sh`

- [ ] **Step 1: Write the failing test** `test/test_pause.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/helpers.sh"; make_env
assert_no "not paused initially" is_paused
touch "$PAUSE_FLAG"
assert_ok "paused after flag created" is_paused
rm -f "$PAUSE_FLAG"
assert_no "not paused after flag removed" is_paused
# config default present
assert_eq "$HARNESS_LABEL_PAUSED" "agent-paused" "default paused label"
finish
```

- [ ] **Step 2: Run it** — `bash test/test_pause.sh` — Expected: FAIL (`is_paused`/`PAUSE_FLAG` undefined).

- [ ] **Step 3: Add config defaults to `lib.sh`.** After the line `: "${HARNESS_LABEL_COORD:=coordination}"` (currently line 37) add:

```bash
: "${HARNESS_LABEL_PAUSED:=agent-paused}"   # force-paused: checkpointed to GitHub, resumable
: "${HARNESS_PAUSE_GRACE:=300}"             # seconds pause --force waits for each agent to confirm
```

- [ ] **Step 4: Export the paused label.** In `lib.sh`, change the export block (currently lines 40-42) to add `HARNESS_LABEL_PAUSED`:

```bash
export HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC HARNESS_AUTONOMOUS \
  HARNESS_LABEL_READY HARNESS_LABEL_PRD HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED \
  HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD HARNESS_LABEL_PAUSED HARNESS_MAIN_REPO
```

- [ ] **Step 5: Add `PAUSE_FLAG` + `is_paused` to `lib.sh`.** After the line `POOL_LOCK="${POOL_LOCK:-$RUN_DIR/pool.lock}"` (currently line 49) add:

```bash
PAUSE_FLAG="${PAUSE_FLAG:-$RUN_DIR/PAUSED}"
```

Then after the `ensure_safe` function definition (currently line 54) add:

```bash
is_paused(){ [[ -f "$PAUSE_FLAG" ]]; }
```

- [ ] **Step 6: Make the test rig pause-aware.** In `test/helpers.sh`, inside `make_env`, the line that sets `POOL_LOCK` currently reads:

```bash
  RUN_DIR="$(mktemp -d)"; CLAIMS_DIR="$RUN_DIR/claims"; POOL_LOCK="$RUN_DIR/pool.lock"; mkdir -p "$CLAIMS_DIR"
```

Replace it with (adds `PAUSE_FLAG` pointing at the fresh temp `RUN_DIR`):

```bash
  RUN_DIR="$(mktemp -d)"; CLAIMS_DIR="$RUN_DIR/claims"; POOL_LOCK="$RUN_DIR/pool.lock"; PAUSE_FLAG="$RUN_DIR/PAUSED"; mkdir -p "$CLAIMS_DIR"
```

- [ ] **Step 7: Plumb the paused label through `init.sh`.** In `init.sh`, after the line `: "${HARNESS_LABEL_COORD:=coordination}"` (currently line 25) add:

```bash
: "${HARNESS_LABEL_PAUSED:=agent-paused}"
```

Then in the config-write `for v in …` loop (currently lines 29-31) append `HARNESS_LABEL_PAUSED` to the variable list so it reads:

```bash
  for v in HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC HARNESS_AUTONOMOUS \
           HARNESS_POOL HARNESS_CAP HARNESS_POLL HARNESS_LABEL_READY HARNESS_LABEL_PRD \
           HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD \
           HARNESS_LABEL_PAUSED; do
```

- [ ] **Step 8: Run it** — `bash test/test_pause.sh` — Expected: all `ok`.
- [ ] **Step 9: Full suite** — `bash test/run.sh` — Expected: green (test_init still passes — extra config line is harmless).
- [ ] **Step 10: Commit** — `git add -A && git commit -m "feat: lib.sh pause flag + is_paused + agent-paused label config"`

---

### Task 2: `pool-worker.sh` + `drive.sh` — drain on pause

**Files:**
- Modify: `pool-worker.sh`
- Modify: `drive.sh`
- Test: `test/test_pause.sh` (extend)

- [ ] **Step 1: Add the failing tests** — append to `test/test_pause.sh` BEFORE the final `finish` line:

```bash
# --- worker_tick idles (rc 3) when paused, without claiming -------------------
source "$HERE/../drive.sh" 2>/dev/null || true
source "$HERE/../pool-worker.sh" 2>/dev/null || true
HARNESS_TOPOLOGY=multi
write_targets <<'EOF'
a	acme/a	-	root
EOF
set_complete
claimed=""
claim_next(){ claimed=yes; echo a; }   # if called, we'd see claimed=yes
touch "$PAUSE_FLAG"
worker_tick W1; rc=$?
assert_eq "$rc" "3" "worker_tick returns 3 when paused"
assert_eq "$claimed" "" "worker_tick did NOT claim while paused"
rm -f "$PAUSE_FLAG"

# --- drive_unit drains (breaks) when paused, without dispatching --------------
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; CAP=2; POLL=0
dispatched=""
reap_done_sessions(){ :; }; reap_team(){ :; }; count_team_sessions(){ echo 0; }
dispatch_actions(){ dispatched=yes; printf 'IMPL\t5\tISSUE 5 DONE\n'; }
spawn_impl(){ dispatched=spawned; }
unit_complete(){ return 1; }   # never complete on its own
touch "$PAUSE_FLAG"
drive_unit main
assert_eq "$dispatched" "" "drive_unit did NOT dispatch while paused (drained immediately)"
rm -f "$PAUSE_FLAG"
```

> Note: the drain test relies on `drive_unit` checking `is_paused` BEFORE the dispatch block and breaking, so `dispatch_actions`/`spawn_impl` are never reached. `POLL=0` keeps it instant.

- [ ] **Step 2: Run it** — `bash test/test_pause.sh` — Expected: FAIL (worker_tick returns 1/2 not 3; drive_unit dispatches).

- [ ] **Step 3: Make `drive_unit` drain.** In `drive.sh`, the `drive_unit` loop body (currently lines 91-104) starts with `reap_done_sessions; reap_team`. Insert the pause check immediately after the reapers. Replace:

```bash
  while ! unit_complete "$UNIT"; do
    reap_done_sessions; reap_team
    local active free allow_orch action payload promise
```

with:

```bash
  while ! unit_complete "$UNIT"; do
    reap_done_sessions; reap_team
    if is_paused; then log "$UNIT paused — draining (no new dispatch); live sessions keep running"; break; fi
    local active free allow_orch action payload promise
```

- [ ] **Step 4: Make the worker idle when paused.** In `pool-worker.sh`, replace `worker_tick` (currently lines 6-8):

```bash
worker_tick(){ local wid="$1" u; u="$(claim_next "$wid")"
  if [[ -z "$u" ]]; then all_complete && return 2; return 1; fi
  log "worker $wid claimed $u"; seed_if_needed "$u"; drive_unit "$u"; release_claim "$u"; log "worker $wid released $u"; return 0; }
```

with (check pause BEFORE claiming):

```bash
worker_tick(){ local wid="$1" u
  if is_paused; then return 3; fi
  u="$(claim_next "$wid")"
  if [[ -z "$u" ]]; then all_complete && return 2; return 1; fi
  log "worker $wid claimed $u"; seed_if_needed "$u"; drive_unit "$u"; release_claim "$u"; log "worker $wid released $u"; return 0; }
```

And in `main` (currently lines 9-13), handle rc `3` (idle, stay alive). Replace the `case` line:

```bash
    case "$rc" in 0) ;; 2) log "all COMPLETE — worker $wid retiring"; exit 0;; *) sleep "$POLL";; esac
```

with:

```bash
    case "$rc" in 0) ;; 2) log "all COMPLETE — worker $wid retiring"; exit 0;; 3) sleep "$POLL";; *) sleep "$POLL";; esac
```

> (rc 3 and the default both `sleep "$POLL"`; keeping 3 explicit documents the paused-idle state and lets future code branch on it.)

- [ ] **Step 5: Run it** — `bash test/test_pause.sh` — Expected: all `ok`.
- [ ] **Step 6: Full suite** — `bash test/run.sh` — Expected: green (test_worker still passes — it never sets PAUSE_FLAG, so `is_paused` is false and worker_tick behaves as before).
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: drain workers + drive_unit on pause"`

---

### Task 3: `pause.sh` (soft) + `bin/harness pause` + start/stop clear the flag

**Files:**
- Create: `pause.sh`
- Modify: `bin/harness`, `start.sh`, `stop.sh`
- Test: `test/test_pause.sh` (extend), `test/test_cli.sh` (extend)

- [ ] **Step 1: Add the failing test** — append to `test/test_pause.sh` before `finish`:

```bash
# --- pause.sh (soft) creates the flag -----------------------------------------
RUN_DIR2="$(mktemp -d)"
RUN_DIR="$RUN_DIR2" bash "$HERE/../pause.sh" >/dev/null 2>&1
assert_ok "soft pause.sh created PAUSED flag" bash -c "[[ -f '$RUN_DIR2/PAUSED' ]]"
rm -rf "$RUN_DIR2"
```

- [ ] **Step 2: Run it** — `bash test/test_pause.sh` — Expected: FAIL (pause.sh missing).

- [ ] **Step 3: Create `pause.sh`** (soft path only; `--force` lands in Task 4):

```bash
#!/usr/bin/env bash
# pause.sh [--force] — pause the fleet.
#   (soft)   stop claiming/dispatching new work; workers idle; live sessions finish naturally.
#   --force  tell each live agent to checkpoint to GitHub (commit+push+/handoff comment+label),
#            then idle. Resumable from ANY machine. (implemented in a later step)
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1

if (( FORCE )); then
  force_pause   # defined below (Task 4)
else
  touch "$PAUSE_FLAG"
  echo "FLEET: PAUSED (draining) — workers stop claiming; live sessions finish. Resume: harness/resume.sh"
fi
```

> Task 4 adds the `force_pause` function ABOVE this dispatch block. For now, define a stub so the soft path works and `--force` doesn't error:

Add this stub function ABOVE the `FORCE=0` line:

```bash
force_pause(){ echo "force pause not yet implemented"; touch "$PAUSE_FLAG"; }
```

- [ ] **Step 4: Wire `bin/harness`.** In `bin/harness`, add a `pause` case after the `attach)` line (currently line 19):

```bash
  pause)  exec bash "$HARNESS_DIR/pause.sh" "$@";;
```

And add to the `usage()` heredoc, after the `attach` line:

```bash
  pause [--force]      pause the fleet (--force = checkpoint each agent to GitHub)
```

- [ ] **Step 5: Clear the flag in `start.sh`.** In `start.sh`, after `source …/lib.sh` (currently line 13), add:

```bash
rm -f "$PAUSE_FLAG"   # starting un-pauses this machine's pool
```

- [ ] **Step 6: Clear the flag in `stop.sh`.** In `stop.sh`, after `source …/lib.sh` (currently line 5), add:

```bash
rm -f "$PAUSE_FLAG"   # a stopped fleet is not "paused"
```

- [ ] **Step 7: Extend `test/test_cli.sh`.** After the existing `assert "help lists start/stop/status" …` line, add:

```bash
assert "help lists pause"  "\"$CLI\" help 2>&1 | grep -q pause"
```

- [ ] **Step 8: Run the tests** — `bash test/test_pause.sh` and `bash test/test_cli.sh` — Expected: all `ok`.
- [ ] **Step 9: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 10: Commit** — `git add -A && git commit -m "feat: pause.sh soft pause + harness pause; start/stop clear flag"`

---

### Task 4: `pause.sh --force` — checkpoint each agent to GitHub + grace poll

**Files:**
- Modify: `pause.sh`
- Test: `test/test_pause.sh` (extend)

- [ ] **Step 1: Add the failing tests** — append to `test/test_pause.sh` before `finish`:

```bash
# --- pause --force: injects checkpoint, confirms via label, never kills -------
RUN_DIR3="$(mktemp -d)"; CALLS="$RUN_DIR3/calls"; : > "$CALLS"
export HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme HARNESS_PAUSE_GRACE=2
# one live impl session for unit "main", issue 5
tmux(){ echo "tmux $*" >> "$CALLS"
  case "$1" in
    ls) echo "hz-main-i5";;
    send-keys) : ;;
    kill-session) : ;;   # if ever called, recorded above
  esac; }
# gh: issue already carries the paused label -> confirms immediately
gh(){ echo "gh $*" >> "$CALLS"
  case "$1 $2" in
    "issue view") echo '{"labels":[{"name":"agent-paused"}]}';;
  esac; return 0; }
export -f tmux gh
RUN_DIR="$RUN_DIR3" bash "$HERE/../pause.sh" --force >/dev/null 2>&1
assert_ok "force: PAUSED flag set"            bash -c "[[ -f '$RUN_DIR3/PAUSED' ]]"
assert_ok "force: checkpoint sent to session" bash -c "grep -q 'send-keys' '$CALLS'"
assert_no "force: never killed the session"   bash -c "grep -q 'kill-session' '$CALLS'"
rm -rf "$RUN_DIR3"
```

> The stub `gh issue view` returns the `agent-paused` label, so the grace poll confirms on the first check and `pause --force` returns fast. `kill-session` must never appear.

- [ ] **Step 2: Run it** — `bash test/test_pause.sh` — Expected: FAIL (force_pause is the stub).

- [ ] **Step 3: Replace the `force_pause` stub in `pause.sh`** with the real implementation. Remove the stub line `force_pause(){ echo "force pause not yet implemented"; touch "$PAUSE_FLAG"; }` and insert this function in its place (ABOVE the `FORCE=0` line):

```bash
# Build the one-line checkpoint instruction sent to a live agent. Single-quoted printf
# format keeps the literal backticks/markers from being command-substituted by THIS shell.
_checkpoint_msg(){  # <issue> <slug> <branch> <working-label> <paused-label>
  printf 'HARNESS CHECKPOINT — pause requested. Stop now. Commit ALL work in progress and push your branch to origin. Then run the /handoff skill and post the handoff as a GitHub issue comment: gh issue comment %s -R %s --body-file <file>, whose FIRST line is exactly `<!-- harness-handoff issue=%s branch=%s -->`. Then swap labels: gh issue edit %s -R %s --remove-label %s --add-label %s. Do NOT merge or close the issue. Then output your completion promise and exit.' \
    "$1" "$2" "$1" "$3" "$1" "$2" "$4" "$5"
}

force_pause(){
  command -v tmux >/dev/null || die "tmux not found"
  command -v gh   >/dev/null || die "gh not found"
  local sessions sess unit issue slug branch msg
  sessions="$(tmux ls -F '#S' 2>/dev/null | grep -E "^$HARNESS_SESS_PREFIX-.*-i[0-9]+$" || true)"
  if [[ -z "$sessions" ]]; then
    echo "No live impl sessions — nothing to checkpoint. Marking paused."
    touch "$PAUSE_FLAG"; return 0
  fi
  # 1) inject the checkpoint instruction into every live impl session
  local -a pending=()
  while read -r sess; do
    [[ -z "$sess" ]] && continue
    issue="${sess##*-i}"                       # hz-<unit>-i<issue> -> <issue>
    unit="${sess#"$HARNESS_SESS_PREFIX"-}"; unit="${unit%-i$issue}"   # -> <unit>
    slug="$(unit_slug "$unit")"; branch="issue/$issue"
    msg="$(_checkpoint_msg "$issue" "$slug" "$branch" "$HARNESS_LABEL_WORKING" "$HARNESS_LABEL_PAUSED")"
    tmux send-keys -t "$sess" -l -- "$msg" 2>/dev/null || true
    tmux send-keys -t "$sess" Enter 2>/dev/null || true
    pending+=("$unit:$issue:$slug")
    echo "  checkpoint requested: $sess (issue #$issue on $slug)"
  done <<< "$sessions"
  # 2) poll GitHub for the paused label = proof the agent committed+pushed+labeled
  local deadline=$(( $(date +%s) + HARNESS_PAUSE_GRACE )) item u i sl labels
  while (( ${#pending[@]} > 0 )) && (( $(date +%s) < deadline )); do
    local -a still=()
    for item in "${pending[@]}"; do
      IFS=: read -r u i sl <<< "$item"
      labels="$(gh issue view "$i" -R "$sl" --json labels -q '[.labels[].name]' 2>/dev/null || echo '')"
      if [[ "$labels" == *"$HARNESS_LABEL_PAUSED"* ]]; then
        echo "  confirmed paused: $sl#$i"
      else
        still+=("$item")
      fi
    done
    pending=( ${still[@]+"${still[@]}"} )
    (( ${#pending[@]} > 0 )) && sleep 3
  done
  # 3) mark the machine paused (workers idle). NEVER kill — stragglers keep running.
  touch "$PAUSE_FLAG"
  if (( ${#pending[@]} > 0 )); then
    echo "FLEET: PAUSED — WARNING: ${#pending[@]} session(s) did not confirm within ${HARNESS_PAUSE_GRACE}s; left running (NOT killed):"
    for item in "${pending[@]}"; do IFS=: read -r u i sl <<< "$item"; echo "    pending: $sl#$i"; done
    echo "  (they will get the agent-paused label when they finish checkpointing; resume picks them up)"
  else
    echo "FLEET: PAUSED — all in-flight agents checkpointed to GitHub. Resume anywhere: harness/resume.sh"
  fi
}
```

- [ ] **Step 4: Run it** — `bash test/test_pause.sh` — Expected: all `ok`.
- [ ] **Step 5: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: pause --force — GitHub checkpoint + grace poll, never kills"`

---

### Task 5: `seed.sh` — create the `agent-paused` label

**Files:**
- Modify: `seed.sh`
- Test: `test/test_seed.sh` (extend)

- [ ] **Step 1: Add the failing assertion.** `test/test_seed.sh` sets custom labels and asserts `gh label create` calls. Add a custom paused label near the top where the others are set (it currently sets `HARNESS_LABEL_READY=go HARNESS_LABEL_PRD=spec`); change that line to also set the paused label:

```bash
HARNESS_LABEL_READY=go HARNESS_LABEL_PRD=spec HARNESS_LABEL_PAUSED=zzz   # custom names
```

Then after the existing `assert_ok "created custom prd label" …` line, add:

```bash
assert_ok "created custom paused label" bash -c "grep -q 'label create zzz' '$CALLS'"
```

- [ ] **Step 2: Run it** — `bash test/test_seed.sh` — Expected: FAIL (paused label not created).

- [ ] **Step 3: Add the label to `seed.sh`.** In `_seed_labels` (currently lines 41-48), after the `_seed_add_label "$HARNESS_LABEL_COORD" …` line add:

```bash
  _seed_add_label "$HARNESS_LABEL_PAUSED"   c2e0c6 "Force-paused mid-work; checkpointed to GitHub, resumable"
```

- [ ] **Step 4: Run it** — `bash test/test_seed.sh` — Expected: all `ok`.
- [ ] **Step 5: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: seed.sh creates the agent-paused label"`

---

### Task 6: `issuelib.py` — keep `agent-paused` dispatchable + surface paused count

**Files:**
- Modify: `issuelib.py`
- Test: `test/test_issuelib.py` (extend)

Context: a force-paused issue keeps its `ready-for-agent` label and is OPEN with `agent-working` removed, so `compute_state` already counts it as an unblocked child → it is re-dispatched on resume. This task LOCKS that with a test and adds a `paused` count to state + the `status` line for visibility.

- [ ] **Step 1: Add the failing test** — in `test/test_issuelib.py`, add a new test function before the `if __name__` block:

```python
def test_agent_paused_issue_is_dispatchable():
    # a force-paused issue: ready label kept, agent-working removed, agent-paused added, OPEN
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "a", "state": "OPEN", "body": "",
         "_labels": {"ready-for-agent", "agent-paused"}},
    ]
    il._has_plan = lambda slug: False
    s = il.compute_state("acme/widget")
    assert 5 in s["unblocked"], s
    assert s["paused"] == 1, s
```

> This stubs `_list_issues`/`_has_plan` directly (the module-level functions) so no real `gh` runs.

- [ ] **Step 2: Run it** — `python3 test/test_issuelib.py` — Expected: FAIL (`s["paused"]` KeyError).

- [ ] **Step 3: Add `paused` to `compute_state`.** In `issuelib.py`, the `compute_state` return dict (currently lines 116-122) — add a `paused` count. Also add the `L_PAUSED` accessor near the other label lambdas (after `L_REVIEWED`, line 12):

```python
L_PAUSED   = lambda: os.environ.get("HARNESS_LABEL_PAUSED", "agent-paused")
```

Then in `compute_state`, change the `return {…}` to include `paused` (count of open children carrying the paused label):

```python
    return {"slug": slug, "has_plan": _has_plan(slug),
            "prd": prd_num, "prd_open": bool(prd) and prd["state"].lower() == "open",
            "prd_reviewed": bool(prd) and L_REVIEWED() in prd["_labels"],
            "children_exist": children_exist, "children_all_closed": children_all_closed,
            "unblocked": unblocked,
            "paused": sum(1 for i in children if i["state"].lower() == "open" and L_PAUSED() in i["_labels"]),
            "open_children": sum(1 for i in children if i["state"].lower() == "open"),
            "total_children": len(children)}
```

> Note: the existing `unblocked` filter already includes paused issues (it only excludes `L_WORKING` and, when non-autonomous, `L_BLOCKED`). Do NOT add `L_PAUSED` to any exclusion — paused issues MUST stay dispatchable so resume continues them.

- [ ] **Step 4: Surface it in the `status` line.** In `main`, the `status` branch (currently lines 151-156), add `paused=` to the printed line:

```python
        print(f"{repo}: mode={MODE()} {prd} plan={'Y' if s['has_plan'] else 'N'} "
              f"children={s['total_children']} open={s['open_children']} unblocked={len(s['unblocked'])} "
              f"paused={s['paused']} reviewed={'Y' if s['prd_reviewed'] else 'N'} complete={'Y' if is_complete(s) else 'N'}")
```

- [ ] **Step 5: Run it** — `python3 test/test_issuelib.py` — Expected: all `ok`.
- [ ] **Step 6: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: issuelib keeps agent-paused dispatchable + paused count in status"`

---

### Task 7: `prompts/resume.md` + `drive.sh` resume-detection in `spawn_impl`

**Files:**
- Create: `prompts/resume.md`
- Modify: `drive.sh`
- Test: `test/test_resume.sh`

- [ ] **Step 1: Write `prompts/resume.md`**:

```markdown
You are RESUMING a previously force-paused implementation of issue #{{ISSUE}} on {{PROJECT}} ({{DESC}}).
Running autonomously in a Ralph loop, in a DEDICATED git worktree on a feature branch.

Repo: {{SLUG}}   Branch: {{BRANCH}} (already checked out — your earlier WIP was pushed here)
Your issue: #{{ISSUE}}

A previous agent checkpointed this work to GitHub before pausing. RECOVER first, then finish:
1. Fetch + ensure you are on {{BRANCH}} with the pushed WIP:  git fetch origin && git checkout {{BRANCH}} && git reset --hard origin/{{BRANCH}}
2. Read the handoff context from the issue's comments:  gh issue view {{ISSUE}} -R {{SLUG}} --comments
   Find the comment whose first line is `<!-- harness-handoff issue={{ISSUE}} branch={{BRANCH}} -->` — that is your prior context.
3. Re-claim the work: gh issue edit {{ISSUE}} -R {{SLUG}} --remove-label {{LABEL_PAUSED}} --add-label {{LABEL_WORKING}}
4. Continue implementing via strict TDD until done. Run the full test suite (all green).
5. Commit, push, open/refresh the PR, enable auto-merge, drive the issue to closed:
     git add -A && git commit -m "feat: <summary> (closes #{{ISSUE}})"
     git push -u origin {{BRANCH}}
     gh pr create -R {{SLUG}} --fill --head {{BRANCH}} --base <default-branch>   # or reuse the existing PR
     gh pr merge --auto --squash -R {{SLUG}} <pr-number>

If this harness is configured AUTONOMOUS: never park the work, drive it to closed.

When the PR is merged (or auto-merging on green) AND the issue is closing, output exactly:
<promise>{{PROMISE}}</promise>
```

- [ ] **Step 2: Write the failing test** `test/test_resume.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/../drive.sh"; source "$HERE/helpers.sh"; make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme
RENDERED="$RUN_DIR/rendered"; : > "$RENDERED"
# stubs: record which template render() was asked for; no real tmux/git/gh
render(){ echo "$1" >> "$RENDERED"; : ; }
launch_claude(){ :; }
ensure_checkout(){ return 0; }
default_branch(){ echo main; }
gh(){ case "$1 $2" in "issue view") echo '{"labels":[{"name":"agent-paused"}]}';; *) : ;; esac; return 0; }
git(){ case "$*" in *"ls-remote"*) echo "abc123	refs/heads/issue/5";; *) : ;; esac; return 0; }
export -f gh git
# spawn_impl writes the rendered task into $wd/.harness-task.md, so $wd must exist.
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR/main-i5" "$WORKTREES_DIR/main-i6"
# drive_unit sets the dynamic-scope vars; call spawn_impl directly inside that scope:
UNIT=main REPO=acme/widget SLUG=acme/widget PROJECT=main DESC=widget CHECKOUT="$PROJECT_ROOT"
spawn_impl 5 "ISSUE 5 DONE"
assert_ok "resume issue rendered resume.md" bash -c "grep -q 'resume.md' '$RENDERED'"
assert_no "resume issue did NOT render impl.md" bash -c "grep -q 'impl.md' '$RENDERED'"
# a fresh (non-paused, no remote branch) issue renders impl.md
: > "$RENDERED"
gh(){ case "$1 $2" in "issue view") echo '{"labels":[{"name":"ready-for-agent"}]}';; *) : ;; esac; return 0; }
git(){ case "$*" in *"ls-remote"*) echo "";; *) : ;; esac; return 0; }
export -f gh git
spawn_impl 6 "ISSUE 6 DONE"
assert_ok "fresh issue rendered impl.md" bash -c "grep -q 'impl.md' '$RENDERED'"
finish
```

- [ ] **Step 3: Run it** — `bash test/test_resume.sh` — Expected: FAIL (spawn_impl always renders impl.md).

- [ ] **Step 4: Add resume-detection to `spawn_impl`.** In `drive.sh`, `spawn_impl` (currently lines 69-83). After the `ensure_safe "$wd"` line and before the `render …` call, add a detection that picks the template + extra keys; then make the render use them. Replace the block:

```bash
  ensure_safe "$wd"
  render "$PROMPTS_DIR/impl.md" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" OWNER="$HARNESS_OWNER" \
    SPEC="$HARNESS_SPEC" PRD="" ISSUE="$issue" BRANCH="$branch" PROMISE="$PROMISE" \
    LABEL_READY="$HARNESS_LABEL_READY" LABEL_PRD="$HARNESS_LABEL_PRD" LABEL_REVIEWED="$HARNESS_LABEL_REVIEWED" > "$wd/.harness-task.md"
  launch_claude "$(sess_impl "$UNIT" "$issue")" "$wd"
```

with:

```bash
  ensure_safe "$wd"
  # Resume detection: a force-paused issue (agent-paused label) OR an existing remote branch
  # means a prior agent checkpointed WIP to GitHub — continue it instead of starting fresh.
  local tmpl="impl.md" labels
  labels="$(gh issue view "$issue" -R "$SLUG" --json labels -q '[.labels[].name]' 2>/dev/null || echo '')"
  if [[ "$labels" == *"$HARNESS_LABEL_PAUSED"* ]] || git -C "$CHECKOUT" ls-remote --heads origin "$branch" 2>/dev/null | grep -q .; then
    tmpl="resume.md"; log "resuming paused issue #$issue from origin/$branch"
  fi
  render "$PROMPTS_DIR/$tmpl" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" OWNER="$HARNESS_OWNER" \
    SPEC="$HARNESS_SPEC" PRD="" ISSUE="$issue" BRANCH="$branch" PROMISE="$PROMISE" \
    LABEL_READY="$HARNESS_LABEL_READY" LABEL_PRD="$HARNESS_LABEL_PRD" LABEL_REVIEWED="$HARNESS_LABEL_REVIEWED" \
    LABEL_WORKING="$HARNESS_LABEL_WORKING" LABEL_PAUSED="$HARNESS_LABEL_PAUSED" > "$wd/.harness-task.md"
  launch_claude "$(sess_impl "$UNIT" "$issue")" "$wd"
```

> The two new render keys (`LABEL_WORKING`, `LABEL_PAUSED`) are harmless for `impl.md` (it doesn't reference them) and required by `resume.md`.

- [ ] **Step 5: Run it** — `bash test/test_resume.sh` — Expected: all `ok`.
- [ ] **Step 6: Full suite** — `bash test/run.sh` — Expected: green (test_spawn still passes — its stubbed `gh` returns success and `git ls-remote` returns nothing → impl.md path; verify, and if test_spawn stubs don't define `ls-remote`, the real `git` runs against a fake checkout and returns nonzero/empty → impl.md, still fine).
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: resume.md + spawn_impl resume-detection for paused issues"`

---

### Task 8: `update.sh` + `bin/harness update` — config-safe engine update

**Files:**
- Create: `update.sh`
- Modify: `bin/harness`
- Test: `test/test_update.sh`

- [ ] **Step 1: Write the failing test** `test/test_update.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fake .harness checkout with user config + a git stub that no-ops the pull
TMP="$(mktemp -d)"; HD="$TMP/.harness"; mkdir -p "$HD/skill" "$TMP/.claude"
cp "$HERE/../update.sh" "$HD/update.sh"
cp "$HERE/../lib.sh" "$HD/lib.sh"
printf 'name: harness\ndescription: x\n' > "$HD/skill/SKILL.md"
# user config with a CUSTOM value that MUST survive
printf ': "${HARNESS_MODE:=prd}"\n: "${HARNESS_REPO:=acme/widget}"\n' > "$HD/config"
printf 'a\tacme/a\t-\troot\n' > "$HD/targets.tsv"
cfg_before="$(cat "$HD/config")"; tsv_before="$(cat "$HD/targets.tsv")"
# git stub: pull --ff-only succeeds (no-op); anything else no-ops
git(){ case "$*" in *"pull --ff-only"*) return 0;; *) return 0;; esac; }
export -f git
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
( cd "$TMP" && HARNESS_DIR="$HD" bash "$HD/update.sh" >/dev/null 2>&1 )
assert "config byte-identical after update"   "[[ \"\$(cat '$HD/config')\" == \"$cfg_before\" ]]"
assert "targets.tsv byte-identical after update" "[[ \"\$(cat '$HD/targets.tsv')\" == \"$tsv_before\" ]]"
assert "skill redeployed"                      "[[ -f '$TMP/.claude/skills/harness/SKILL.md' ]]"
assert "update.sh has no git clean"            "! grep -qE 'git +clean' '$HD/update.sh'"
assert "update.sh has no git reset --hard"     "! grep -qE 'reset +--hard' '$HD/update.sh'"
assert "update.sh has no git checkout -f"      "! grep -qE 'checkout +-f' '$HD/update.sh'"
rm -rf "$TMP"
echo "── update ok"
```

- [ ] **Step 2: Run it** — `bash test/test_update.sh` — Expected: FAIL (update.sh missing).

- [ ] **Step 3: Create `update.sh`**:

```bash
#!/usr/bin/env bash
# update.sh [--with-skills] — fast-forward the .harness engine + redeploy the /harness skill,
# WITHOUT re-running the wizard or re-cloning. NEVER removes or alters user config.
#   --with-skills  also refresh the superpowers/ralph-loop plugins + matt-pocock skills.
set -uo pipefail
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"
WITH_SKILLS=0; [[ "${1:-}" == "--with-skills" ]] && WITH_SKILLS=1

# 1) snapshot user-owned state BEFORE touching git (hard guarantee: config survives).
SNAP="$(mktemp -d)"
for f in config targets.tsv; do
  [[ -f "$HARNESS_DIR/$f" ]] && cp -p "$HARNESS_DIR/$f" "$SNAP/$f"
done

# 2) fast-forward ONLY. Never clean/reset --hard/checkout -f — nothing that discards
#    untracked/ignored files (config/targets.tsv/run/worktrees/checkouts are gitignored).
if ! git -C "$HARNESS_DIR" pull --ff-only; then
  echo "ERROR: 'git pull --ff-only' failed (diverged or local engine edits)." >&2
  echo "       Resolve in $HARNESS_DIR manually; your config was NOT touched." >&2
  rm -rf "$SNAP"; exit 1
fi

# 3) verify/restore user config (defends against a misbehaving upstream that tracks a config).
for f in config targets.tsv; do
  if [[ -f "$SNAP/$f" ]]; then
    if [[ ! -f "$HARNESS_DIR/$f" ]] || ! cmp -s "$SNAP/$f" "$HARNESS_DIR/$f"; then
      cp -p "$SNAP/$f" "$HARNESS_DIR/$f"
      echo "  restored user $f (upstream tried to change it)"
    fi
  fi
done
echo "  config preserved"
rm -rf "$SNAP"

# 4) redeploy the /harness operator skill.
mkdir -p "$PROJECT_ROOT/.claude/skills/harness"
cp "$HARNESS_DIR/skill/SKILL.md" "$PROJECT_ROOT/.claude/skills/harness/SKILL.md"
echo "  redeployed .claude/skills/harness/SKILL.md"

# 5) optional plugin/skill refresh (reuse install.sh's ensure_skills).
if (( WITH_SKILLS )); then
  HARNESS_INSTALL_NOMAIN=1 source "$HARNESS_DIR/install.sh"
  ensure_skills
fi

# 6) if a pool is running, new engine logic only applies after a relaunch.
if compgen -G "$HARNESS_DIR/run/worker-*.pid" >/dev/null 2>&1; then
  for pf in "$HARNESS_DIR"/run/worker-*.pid; do
    kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null && {
      echo "NOTE: a worker pool is running. Live workers keep the OLD engine logic until relaunched."
      echo "      To apply this update safely: harness pause  →  let sessions drain  →  harness stop  →  harness start --recover"
      break
    }
  done
fi
echo "Update complete."
```

- [ ] **Step 4: Wire `bin/harness`.** Add after the `pause)` case:

```bash
  update) exec bash "$HARNESS_DIR/update.sh" "$@";;
```

And in `usage()`, after the `pause` line:

```bash
  update [--with-skills]   ff-pull engine + redeploy skill (keeps your config)
```

- [ ] **Step 5: Run it** — `bash test/test_update.sh` — Expected: all `ok`.
- [ ] **Step 6: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: update.sh — config-safe ff-pull + skill redeploy"`

---

### Task 9: `setup.sh` + `bin/harness setup` — verify prereqs + seed all units

**Files:**
- Create: `setup.sh`
- Modify: `bin/harness`
- Test: `test/test_setup.sh`

- [ ] **Step 1: Write the failing test** `test/test_setup.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLS="$(mktemp)"; : > "$CALLS"
# stub the tools setup checks + seeds; single topology, one unit "main"
export HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme
gh(){ echo "gh $*" >> "$CALLS"; case "$1 $2" in "auth status") return 0;; "label create") return 0;; esac; return 0; }
export -f gh
# fake claude/tmux on PATH so prereq checks pass
BIN="$(mktemp -d)"; for t in tmux claude; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$t"; chmod +x "$BIN/$t"; done
export PATH="$BIN:$PATH"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
bash "$HERE/../setup.sh" >/dev/null 2>&1
assert "setup seeded labels (gh label create called)" "grep -q 'label create' '$CALLS'"
# idempotent: second run also succeeds
bash "$HERE/../setup.sh" >/dev/null 2>&1; assert "setup rerun ok" "true"
rm -rf "$BIN" "$CALLS"
echo "── setup ok"
```

- [ ] **Step 2: Run it** — `bash test/test_setup.sh` — Expected: FAIL (setup.sh missing).

- [ ] **Step 3: Create `setup.sh`**:

```bash
#!/usr/bin/env bash
# setup.sh — config-driven bring-up: verify prerequisites, then seed the configured labels
# on every unit (single = HARNESS_REPO; multi = each targets.tsv row). Idempotent. Does NOT start.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo "── Harness setup (mode=$HARNESS_MODE topology=$HARNESS_TOPOLOGY) ──"
command -v tmux   >/dev/null || die "tmux not found — install tmux"
command -v claude >/dev/null || die "claude not found — install Claude Code CLI"
command -v gh     >/dev/null || die "gh not found — install the GitHub CLI"
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"

if [[ "$HARNESS_TOPOLOGY" == single && -z "$HARNESS_REPO" ]]; then
  die "HARNESS_REPO is empty — run 'harness init' first"
fi

n=0
for u in $(all_units); do
  echo "  seeding labels for unit '$u' ($(unit_slug "$u"))"
  seed_if_needed "$u"
  n=$((n+1))
done
echo "── setup done: verified prereqs + seeded $n unit(s). Start the fleet: harness/start.sh ──"
```

- [ ] **Step 4: Wire `bin/harness`.** Add after the `update)` case:

```bash
  setup)  exec bash "$HARNESS_DIR/setup.sh" "$@";;
```

And in `usage()`, after the `update` line:

```bash
  setup                verify prereqs + seed configured labels on all units (no start)
```

- [ ] **Step 5: Run it** — `bash test/test_setup.sh` — Expected: all `ok`.
- [ ] **Step 6: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: setup.sh — verify prereqs + seed all units"`

---

### Task 10: `resume.sh` + `bin/harness resume`

**Files:**
- Create: `resume.sh`
- Modify: `bin/harness`
- Test: `test/test_pause.sh` (extend), `test/test_cli.sh` (extend)

- [ ] **Step 1: Add the failing test** — append to `test/test_pause.sh` before `finish`:

```bash
# --- resume.sh clears the flag (alive-worker branch: does NOT exec start) -----
RUN_DIR4="$(mktemp -d)"; touch "$RUN_DIR4/PAUSED"
# a live worker pidfile (use this shell's pid so kill -0 succeeds)
printf '%s\n' "$$" > "$RUN_DIR4/worker-1.pid"
RUN_DIR="$RUN_DIR4" bash "$HERE/../resume.sh" >/dev/null 2>&1
assert_ok "resume removed PAUSED flag" bash -c "[[ ! -f '$RUN_DIR4/PAUSED' ]]"
rm -rf "$RUN_DIR4"
```

- [ ] **Step 2: Run it** — Expected: FAIL (resume.sh missing).

- [ ] **Step 3: Create `resume.sh`**:

```bash
#!/usr/bin/env bash
# resume.sh — clear the pause and pick work back up.
#   - removes the local PAUSED idle-flag;
#   - if a worker pool is alive here, workers resume claiming on their next tick
#     (they re-dispatch open agent-paused issues through the normal loop → resume.md);
#   - if NO pool is alive (e.g. a different machine), runs `start --recover` to launch one.
# Cross-machine resume needs no local state: paused work is tracked in GitHub (agent-paused label).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

rm -f "$PAUSE_FLAG"

alive=0
shopt -s nullglob
for pf in "$RUN_DIR"/worker-*.pid; do
  kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null && { alive=1; break; }
done
shopt -u nullglob

if (( alive )); then
  echo "RESUMED — workers will pick up claiming (incl. any agent-paused issues) on the next poll."
else
  echo "No live pool here — launching with recovery (continues any GitHub-checkpointed work):"
  exec bash "$HARNESS_DIR/start.sh" --recover
fi
```

- [ ] **Step 4: Wire `bin/harness`.** Add after the `setup)` case:

```bash
  resume) exec bash "$HARNESS_DIR/resume.sh" "$@";;
```

And in `usage()`, after the `pause` line (group it with pause):

```bash
  resume               clear pause; resume here or start --recover (works across machines)
```

- [ ] **Step 5: Extend `test/test_cli.sh`** — after the `pause` assertion add:

```bash
assert "help lists resume" "\"$CLI\" help 2>&1 | grep -q resume"
assert "help lists update" "\"$CLI\" help 2>&1 | grep -q update"
assert "help lists setup"  "\"$CLI\" help 2>&1 | grep -q setup"
```

- [ ] **Step 6: Run the tests** — `bash test/test_pause.sh` and `bash test/test_cli.sh` — Expected: all `ok`.
- [ ] **Step 7: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 8: Commit** — `git add -A && git commit -m "feat: resume.sh + harness resume (cross-machine via GitHub state)"`

---

### Task 11: `status.sh` — render `FLEET: PAUSED`

**Files:**
- Modify: `status.sh`
- Test: `test/test_status.sh` (extend)

- [ ] **Step 1: Add the failing test** — `test/test_status.sh` currently runs status once and greps for "worker". Append a paused-state check at the end (before any final echo):

```bash
# paused state renders "PAUSED": create the flag in the SAME RUN_DIR the status run uses
mkdir -p "$RUN_DIR"; touch "$RUN_DIR/PAUSED"
out3="$(HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget RUN_DIR="$RUN_DIR" bash "$HERE/../status.sh" 2>&1 || true)"
echo "$out3" | grep -qi paused && echo "  ok: status shows PAUSED when flag set" || { echo "  FAIL: no PAUSED"; exit 1; }
```

> The existing test sets `export RUN_DIR="$(mktemp -d)"` at the top; reuse that `$RUN_DIR` so the flag and the status run share a dir.

- [ ] **Step 2: Run it** — `bash test/test_status.sh` — Expected: FAIL (no "paused" in output).

- [ ] **Step 3: Render PAUSED in `status.sh`.** In `render_once` (currently lines 13-29), after the two `verdict=` lines (currently lines 22-23), add a paused override:

```bash
  is_paused && verdict="PAUSED   (drained — workers idle; resume: harness/resume.sh)"
```

So the block reads:

```bash
  local verdict="STOPPED  (pool not running — start with: harness/start.sh)"
  (( up > 0 )) && verdict="RUNNING  ($up/$total workers up, $sess_total claude session(s) live)"
  is_paused && verdict="PAUSED   (drained — workers idle; resume: harness/resume.sh)"
```

- [ ] **Step 4: Run it** — `bash test/test_status.sh` — Expected: all `ok`.
- [ ] **Step 5: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: status.sh renders PAUSED state"`

---

### Task 12: `prompts/impl.md` checkpoint note + `skill/SKILL.md` setup-aware + `README.md`

**Files:**
- Modify: `prompts/impl.md`, `skill/SKILL.md`, `README.md`
- Test: `test/test_skill.sh` (extend)

- [ ] **Step 1: Add a checkpoint-protocol note to `prompts/impl.md`.** The file ends with the `<promise>{{PROMISE}}</promise>` block. Immediately BEFORE the final "When the PR is merged …" paragraph, insert:

```markdown
CHECKPOINT PROTOCOL — if you receive a message beginning "HARNESS CHECKPOINT": stop, commit ALL
WIP and push your branch, run /handoff and post it as a GitHub issue comment whose first line is
`<!-- harness-handoff issue={{ISSUE}} branch={{BRANCH}} -->`, then `gh issue edit {{ISSUE}} -R {{SLUG}}
--remove-label {{LABEL_WORKING}} --add-label {{LABEL_PAUSED}}`, and exit without merging.
```

> This adds two new `{{LABEL_WORKING}}`/`{{LABEL_PAUSED}}` tokens to `impl.md`. Task 7 already made `spawn_impl` pass `LABEL_WORKING`/`LABEL_PAUSED` to the render for BOTH templates, so these resolve. Verify with the render check in Step 4.

- [ ] **Step 2: Add a failing test** — append to `test/test_skill.sh` before its final `echo`:

```bash
assert "documents pause"  "grep -q 'harness pause' '$S'"
assert "documents resume" "grep -q 'harness resume' '$S'"
assert "documents update" "grep -q 'harness update' '$S'"
assert "documents setup"  "grep -qi 'setup' '$S'"
```

- [ ] **Step 3: Run it** — `bash test/test_skill.sh` — Expected: FAIL.

- [ ] **Step 4: Rewrite `skill/SKILL.md`** setup-aware (keep the frontmatter `name: harness`). Full new content:

```markdown
---
name: harness
description: Operate the Harness agent fleet for this project — first-time SETUP (init, seed labels, start) and day-to-day operate (pause/resume/update/status, watch sessions, unstick the GitHub-issue board). Trigger on /harness or requests like "set up the fleet", "start the fleet", "pause the agents", "what's the harness doing".
---

# /harness — set up and operate the agent fleet

The board is **GitHub issues**; the dispatcher is the worker pool under `.harness/`. State lives in
GitHub + a small local run dir, so it is resumable (even on another machine). Your job is set up +
operate + observe + unstick — never hand-do a unit's PLAN/PRD/IMPL work; let the pool dispatch it.

## On `/harness`, first detect state, then act

1. **No `.harness/config`?** Run the wizard: `.harness/bin/harness init` (prompts for mode, topology,
   owner/repo, labels, pool size). Confirm the choices with the user.
2. **Config exists but not set up / not running?** Read `.harness/config`, then:
   - `.harness/bin/harness setup` — verifies prereqs (gh auth, claude, tmux) and seeds the configured
     labels on every unit (single = `HARNESS_REPO`; multi = each `targets.tsv` row).
   - Confirm with the user, then `.harness/bin/harness start`.
3. **Already running?** Just operate: show the dashboard, watch sessions, unstick.

Prompt the user before each network or start action.

## Commands
```bash
.harness/bin/harness init             # first-time wizard (writes config, creates labels)
.harness/bin/harness setup            # verify prereqs + seed labels on all units (no start)
.harness/bin/harness start            # launch the worker pool
.harness/bin/harness start --recover  # crash/new-host recovery sweep, then launch
.harness/bin/harness status           # one-shot dashboard
.harness/bin/harness status --watch   # live dashboard (Ctrl-C stops watching, NOT the fleet)
.harness/bin/harness attach <unit> [issue]   # tmux-attach to a session
.harness/bin/harness pause            # drain: stop claiming new work; live sessions finish
.harness/bin/harness pause --force    # checkpoint each agent to GitHub (commit+push+handoff+label)
.harness/bin/harness resume           # clear pause; resume here or start --recover (any machine)
.harness/bin/harness update           # update the engine + redeploy this skill (keeps your config)
.harness/bin/harness stop             # stop the pool
.harness/bin/harness stop --clean     # also remove worktrees
```

## Pausing & resuming (incl. across machines)
- `pause` is a soft drain: workers stop claiming, in-flight agents finish naturally. Local to this machine.
- `pause --force` tells each live agent to commit + push its branch, post its `/handoff` context as a
  GitHub issue comment, and label the issue `agent-paused` — then idle. All state is in GitHub.
- `resume` on ANY machine: clears the local pause; if no pool is running here it runs `start --recover`.
  Open `agent-paused` issues are re-dispatched and continued from their pushed branch + handoff comment.
  So: `pause --force` on laptop, `resume` on a server — the work continues.

## Reading the dashboard
Per unit it prints the `issuelib.py status` line: `mode=… PRD#… plan=… children=… open=… unblocked=… paused=… reviewed=… complete=…`.
- `FLEET: PAUSED` ⇒ drained; `resume` to continue.
- `complete=Y` and idle ⇒ DONE, not stuck.
- `open>0 unblocked=0` with no live session ⇒ likely a mis-pointed `## Blocked by` — investigate.

## Unstick (read-mostly)
- Free a stale lock: `gh issue edit <n> -R <repo> --remove-label agent-working`.
- Fix a wrong dependency: edit the issue's `## Blocked by`.
- Crash/migration: `.harness/bin/harness start --recover`.

## Modes & config
`.harness/config` sets `HARNESS_MODE` (issue-only|prd|planned), topology, labels, pool size. In
`issue-only` just label an issue `ready-for-agent` (not `prd`) and a worker picks it up. In `prd`
mode a human writes one `prd`-labelled issue; the agent decomposes + implements + reviews.

## When NOT to touch
Don't `--clean` while sessions are live unless discarding their worktrees. Don't do a unit's work
by hand — operate the fleet, like a CI operator.
```

- [ ] **Step 5: Update `README.md`.** Append a new section documenting the five commands + cross-machine workflow. Add after the existing commands section:

```markdown
## Pause / resume / update

```bash
.harness/bin/harness pause           # soft drain — stop claiming; live agents finish (local)
.harness/bin/harness pause --force   # checkpoint every agent to GitHub, then idle
.harness/bin/harness resume          # clear pause; resume here, or start --recover elsewhere
.harness/bin/harness update          # ff-pull the engine + redeploy the /harness skill (keeps config)
.harness/bin/harness setup           # verify prereqs + seed labels on all units (no start)
```

**Cross-machine pause/resume.** `pause --force` tells each running agent to commit + push its WIP
branch, post its `/handoff` context as a GitHub issue comment, and label the issue `agent-paused`.
Because all of that lives in GitHub, you can `resume` on a *different* machine: it runs
`start --recover`, re-dispatches the `agent-paused` issues, and each agent fetches its branch, reads
the handoff comment, and finishes the work.

**`update` never touches your config.** It runs `git pull --ff-only` on `.harness`, redeploys the
`/harness` skill, and snapshots/restores `config` + `targets.tsv` — it never runs a destructive git
op. Live workers keep the old engine logic until you relaunch (`pause` → drain → `stop` →
`start --recover`).

New config keys: `HARNESS_LABEL_PAUSED` (default `agent-paused`), `HARNESS_PAUSE_GRACE` (default `300`s).
```

- [ ] **Step 6: Verify prompt rendering** — confirm `impl.md` resolves with the new keys and no stray tokens for the keys spawn_impl passes:

```bash
cd "/media/nathanielsong/Sata Programming/VSCode/Harness"
source lib.sh
render prompts/impl.md PROJECT=w DESC=d SLUG=acme/widget OWNER=acme SPEC= PRD= ISSUE=5 BRANCH=issue/5 PROMISE="ISSUE 5 DONE" LABEL_READY=ready-for-agent LABEL_PRD=prd LABEL_REVIEWED=reviewed LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused | grep -q 'issue #5' && echo OK
# no leftover label tokens:
render prompts/resume.md PROJECT=w DESC=d SLUG=acme/widget OWNER=acme SPEC= PRD= ISSUE=5 BRANCH=issue/5 PROMISE="X" LABEL_READY=r LABEL_PRD=p LABEL_REVIEWED=rv LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused | grep -q '{{' && echo "LEAK" || echo "no-leak"
```

Expected: `OK` then `no-leak`.

- [ ] **Step 7: Run the tests** — `bash test/test_skill.sh`, `bash test/test_prompt_labels.sh` — Expected: all `ok`.
- [ ] **Step 8: Full suite** — `bash test/run.sh` — Expected: ALL green.
- [ ] **Step 9: Commit** — `git add -A && git commit -m "docs: setup-aware /harness skill + README pause/resume/update; impl.md checkpoint note"`

---

### Task 13: Final integration smoke + push

**Files:** none new.

- [ ] **Step 1: Full suite from the real path** — `cd "/media/nathanielsong/Sata Programming/VSCode/Harness" && bash test/run.sh` — Expected: ALL green (no symlink).

- [ ] **Step 2: CLI surface check** — verify every new subcommand dispatches:

```bash
for c in pause resume update setup; do bin/harness help 2>&1 | grep -q "$c" && echo "$c ok" || echo "$c MISSING"; done
bin/harness bogus >/dev/null 2>&1; echo "unknown exit=$?"   # expect non-zero
```

Expected: `pause ok`, `resume ok`, `update ok`, `setup ok`, `unknown exit=2`.

- [ ] **Step 3: Push** — `git push origin main` (the repo is already published at `VocanicZ/Harness`).

- [ ] **Step 4: Confirm** — `git status -sb` shows `## main...origin/main` with nothing to push.

---

## Notes for the executor

- Each task is failing-test-first. Run `bash test/run.sh` green before committing.
- Stub `gh`/`git`/`tmux` in tests; never hit the network. Quote interpolated paths in `eval`'d asserts (repo path has a space).
- `pause --force`'s real `tmux send-keys`/`gh` behavior can't be fully unit-tested; the test verifies the orchestration (checkpoint sent, label-confirm loop, never kills) with stubs. The agent-side checkpoint compliance lives in the prompt protocol (impl.md + the injected instruction).
- Do not modify `issuelib.py`'s `unblocked` filter to exclude `agent-paused` — paused issues MUST stay dispatchable so resume continues them.

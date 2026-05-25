# Live Work Injection (`/harness-plan`, `/harness-prd`, `/harness-issue`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a prompt-driven capability to inject new work (an issue, a PRD scope expansion, or a plan/topology change) into a **live** Harness fleet — reconciled against GitHub state, correctly ordered, and picked up on the next poll with **no restart**.

**Architecture:** Three thin sibling skills (`/harness-plan`, `/harness-prd`, `/harness-issue`) grill the user inline, confirm a crystallized brief, then call `harness <altitude> "<brief>"`. The CLI routes to a new thin `inject.sh`, which resolves the unit, refuses to run while a `REVIEW` session is live, renders `prompts/inject.md`, and launches a headless one-shot Ralph session named `hz-inject-<unit>` via the existing `launch_claude`. That session reconciles the brief against live GitHub state and injects the delta additively. The engine's existing auto-dispatch (`issuelib.dispatch`) picks the work up — no new dispatcher code, no daemon, no database. State stays in GitHub + the local run dir.

**Tech Stack:** Bash (engine + thin scripts), Python 3 (`issuelib.py` state machine — unchanged here), `tmux` (session naming), `gh` CLI (GitHub state), Claude Code + ralph-loop (the injector session), Markdown (skills + prompt templates). Tests are shell + the existing `test/helpers.sh` rig.

---

## Scope note

This is a **single-topology** repo (`HARNESS_TOPOLOGY=single`, unit `main`, repo `VocanicZ/Harness`). "main" here is the one unit, so this plan covers the **entire** spec for this repo. Multi-topology paths (`--unit`, `targets.tsv` rewrites, `seed.sh <unit>`) are implemented and wired but their end-to-end exercise belongs to a live multi fleet; the unit-testable surface (routing, naming, prompt content) is covered below.

## Key facts about the existing code (read before starting)

- `lib.sh` provides: config defaults (`: "${KEY:=val}"` form), `render <tmpl> KEY=VAL…` (substitutes `{{KEY}}`), `launch_claude <sess> <wd>` (writes `<wd>/.harness-task.md`-derived ralph state, opens a tmux session, records `$RUN_DIR/<sess>.goal` from `$GOAL`, uses globals `$PROMISE`/`$MAXITER`/`$GOAL`), `session_live <sess>` (= `tmux has-session`), `sess_orch <unit>` → `hz-<unit>`, `sess_impl <unit> <n>` → `hz-<unit>-i<n>`, `team_sessions <unit>` (greps tmux sessions matching `^$HARNESS_SESS_PREFIX-<unit>($|-i)`), and the `unit_*` resolvers (`unit_slug`, `unit_desc`, `unit_checkout` — for single, `unit_checkout` is `$PROJECT_ROOT`).
- `drive.sh::spawn_orch` is the model for "render a prompt and launch a session". `inject.sh` is a trimmed sibling of it.
- `issuelib.py` needs **no change**: reopening a closed PRD and clearing the `reviewed` label makes `is_complete()` false, so `dispatch()` re-includes the unit and picks up new `ready-for-agent` issues on the next poll. The injector creates delta children itself; `DECOMPOSE` never re-fires (it only fires when `prd != None AND not children_exist`).
- `install.sh` / `update.sh` deploy **every** `skill/*/SKILL.md` via a glob, so new skill dirs are auto-deployed — **no install/update edits needed**.
- Session-name safety: `team_sessions main` greps `^hz-main($|-i)`. `hz-inject-main` does **not** match (it starts `hz-inject`, not `hz-main`), so the injector never consumes a CAP/orchestration slot.
- The test rig (`test/helpers.sh`) gives `assert_eq`, `assert_ok`, `assert_no`, `finish`, `make_env` (temp `RUN_DIR`/`CLAIMS_DIR`/`TARGETS_TSV`). `test/run.sh` runs every `test_*.sh`/`test_*.py`. Run one with `bash test/test_<name>.sh`.

## File structure (what changes)

| File | New/Edit | Responsibility |
|---|---|---|
| `lib.sh` | Edit | Add `HARNESS_INJECT_MAXITER` default + `sess_inject <unit>` → `hz-inject-<unit>`. |
| `bin/harness` | Edit | Route `plan\|prd\|issue` → `inject.sh`; add to `usage`. |
| `inject.sh` | **New** | Thin launcher: resolve unit, REVIEW-guard, render `prompts/inject.md`, `launch_claude hz-inject-<unit>`. |
| `prompts/inject.md` | **New** | The injector's reconciliation algorithm + safety invariants, parameterized by `{{ALTITUDE}}`/`{{BRIEF}}`/etc. |
| `prompts/decompose.md` | Edit | Defensive idempotency — list existing children, only create missing tasks. |
| `skill/harness-plan/SKILL.md` | **New** | Grill → confirm → `harness plan "<brief>"`. |
| `skill/harness-prd/SKILL.md` | **New** | Grill → confirm → `harness prd "<brief>"`. |
| `skill/harness-issue/SKILL.md` | **New** | Grill → confirm → `harness issue "<brief>"`. |
| `skill/SKILL.md` | Edit | Document the live-injection shortcuts. |
| `README.md` | Edit | Add injection subcommands + skill-shortcut rows. |
| `test/test_inject.sh` | **New** | `sess_inject` naming/non-collision; `inject.sh` REVIEW-guard + launch. |
| `test/test_prompt_labels.sh` | Edit | `inject.md` render/substitution/rule-presence; `decompose.md` idempotency. |
| `test/test_cli.sh` | Edit | `harness help` lists `plan`/`prd`/`issue`. |
| `test/test_subskills.sh` | Edit | The three new thin skills exist, are well-formed, deploy. |
| `test/test_skill.sh` | Edit | Umbrella skill documents the injection shortcuts. |

---

## Task 1: `lib.sh` — `sess_inject` helper + inject max-iterations

**Files:**
- Modify: `lib.sh` (defaults block ~line 27; session helpers ~line 108)
- Test: `test/test_inject.sh` (Create)

- [ ] **Step 1: Write the failing test**

Create `test/test_inject.sh`:

```bash
#!/usr/bin/env bash
# test_inject.sh — live-work-injection: session naming/non-collision + inject.sh launcher.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/helpers.sh"; make_env
HARNESS_SESS_PREFIX=hz

# ── §1 sess_inject naming + non-collision with team_sessions ──────────────────
assert_eq "$(sess_inject main)" "hz-inject-main" "sess_inject names hz-inject-<unit>"

# team_sessions greps tmux output; stub tmux to emit both an injector and an impl session.
tmux(){ printf '%s\n' "hz-inject-main" "hz-main-i7"; }
assert_eq "$(team_sessions main)" "hz-main-i7" "team_sessions excludes hz-inject-main (no CAP collision)"
assert_no "injector session never matches team_sessions" \
  bash -c "printf '%s\n' hz-inject-main | grep -qE '^hz-main(\$|-i)'"
unset -f tmux

finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_inject.sh`
Expected: FAIL — `sess_inject: command not found` (function undefined).

- [ ] **Step 3: Add the config default**

In `lib.sh`, after the `HARNESS_ORCH_MAXITER` line:

```bash
: "${HARNESS_ORCH_MAXITER:=8}"
: "${HARNESS_INJECT_MAXITER:=15}"
```

- [ ] **Step 4: Add the `sess_inject` helper**

In `lib.sh`, immediately after the `sess_impl` definition:

```bash
sess_orch(){ echo "$HARNESS_SESS_PREFIX-$1"; }
sess_impl(){ echo "$HARNESS_SESS_PREFIX-$1-i$2"; }
sess_inject(){ echo "$HARNESS_SESS_PREFIX-inject-$1"; }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/test_inject.sh`
Expected: PASS — `3/3 passed`.

- [ ] **Step 6: Commit**

```bash
git add lib.sh test/test_inject.sh
git commit -m "feat(inject): sess_inject helper + HARNESS_INJECT_MAXITER (non-colliding session name)"
```

---

## Task 2: `bin/harness` — route `plan`/`prd`/`issue` to the injector

**Files:**
- Modify: `bin/harness` (`usage` heredoc + `case`)
- Test: `test/test_cli.sh`

- [ ] **Step 1: Add the failing assertions**

In `test/test_cli.sh`, after the `assert "help lists setup" …` line:

```bash
assert "help lists setup"  "\"$CLI\" help 2>&1 | grep -q setup"
assert "help lists plan"   "\"$CLI\" help 2>&1 | grep -q plan"
assert "help lists prd"    "\"$CLI\" help 2>&1 | grep -q prd"
assert "help lists issue"  "\"$CLI\" help 2>&1 | grep -q issue"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_cli.sh`
Expected: FAIL at `help lists plan` (usage has no `plan`/`prd`/`issue` lines yet).

- [ ] **Step 3: Add the usage lines**

In `bin/harness`, inside the `usage()` heredoc, after the `setup` line and before `EOF`:

```bash
  setup                verify prereqs + seed configured labels on all units (no start)
  plan  "<brief>"      inject a plan/topology change into a live fleet (grill via /harness-plan)
  prd   "<brief>"      extend PRD scope + create delta issues (grill via /harness-prd)
  issue "<brief>"      inject implementation issue(s) into a live fleet (grill via /harness-issue)
EOF
```

- [ ] **Step 4: Add the routing case**

In `bin/harness`, in the `case "$cmd"` block, after the `setup)` line:

```bash
  setup)  exec bash "$HARNESS_DIR/setup.sh" "$@";;
  plan|prd|issue) exec bash "$HARNESS_DIR/inject.sh" "$cmd" "$@";;
```

(`$cmd` holds `plan`/`prd`/`issue`; the brief and any `--unit` flag flow through `$@`.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/test_cli.sh`
Expected: PASS — ends with `── cli ok`.

- [ ] **Step 6: Commit**

```bash
git add bin/harness test/test_cli.sh
git commit -m "feat(inject): route harness plan|prd|issue to inject.sh + document in help"
```

---

## Task 3: `prompts/inject.md` — the injector's reconciliation algorithm

**Files:**
- Create: `prompts/inject.md`
- Test: `test/test_prompt_labels.sh`

- [ ] **Step 1: Add the failing render assertions**

In `test/test_prompt_labels.sh`, after the `out_prd="$(render …)"` block (before the `# ── review.md assertions ──` line), add the render call:

```bash
out_inj="$(render "$HERE/../prompts/inject.md" \
  ALTITUDE=issue BRIEF='add a rate limiter' PROJECT=main DESC=widget SLUG=acme/widget \
  OWNER=acme SPEC=docs/spec.md PROMISE='INJECT DONE' \
  LABEL_READY=go LABEL_PRD=spec LABEL_WORKING=busy LABEL_BLOCKED=stuck LABEL_REVIEWED=verified)"
```

Then, just before the final `# ── summary ──` block, add:

```bash
# ── inject.md assertions ─────────────────────────────────────────────────────
assert "inject.md: no unrendered {{ token" \
  "! grep -q '{{' <<<\"\$out_inj\""
assert "inject.md: brief substituted" \
  "grep -q 'add a rate limiter' <<<\"\$out_inj\""
assert "inject.md: altitude substituted" \
  "grep -q 'issue' <<<\"\$out_inj\""
assert "inject.md: custom ready label used" \
  "grep -q '\\-\\-label go' <<<\"\$out_inj\""
assert "inject.md: in-flight rule names the working label" \
  "grep -q 'busy' <<<\"\$out_inj\""
assert "inject.md: cycle guard present" \
  "grep -qi 'cycle' <<<\"\$out_inj\""
assert "inject.md: additive / no-duplicate rule present" \
  "grep -qi 'additive' <<<\"\$out_inj\" && grep -qi 'duplicate' <<<\"\$out_inj\""
assert "inject.md: topology path mentions targets.tsv + seed.sh" \
  "grep -q 'targets.tsv' <<<\"\$out_inj\" && grep -q 'seed.sh' <<<\"\$out_inj\""
assert "inject.md: same-repo Blocked by ordering" \
  "grep -q 'Blocked by' <<<\"\$out_inj\""
assert "inject.md: emits the completion promise" \
  "grep -q 'INJECT DONE' <<<\"\$out_inj\""
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_prompt_labels.sh`
Expected: FAIL — `render` reads a missing `prompts/inject.md`, assertions fail.

- [ ] **Step 3: Create `prompts/inject.md`**

```markdown
You are the work-injector for {{PROJECT}} ({{DESC}}).
You run as a headless one-shot Ralph session. Output the completion promise ONLY when the
injection is genuinely complete. Do NOT implement the work yourself — you only inject it so the
LIVE worker pool picks it up on its next poll (no fleet restart).

Repo (this working dir): {{SLUG}}
Umbrella spec (read the sections relevant to {{PROJECT}}): {{SPEC}}

Injection altitude: {{ALTITUDE}}
  (issue = one shippable unit of work · prd = a scope/milestone · plan = structural/topology change)

Operator brief (already grilled + confirmed by a human — this is the locked intent):
{{BRIEF}}

GOAL: reconcile the brief against live GitHub state and inject the new work ADDITIVELY, ordered
correctly, WITHOUT disturbing in-flight work and WITHOUT restarting the fleet.

## 1. Read live state (source of truth = GitHub + this repo)
- PRD:      gh issue list -R {{SLUG}} --label {{LABEL_PRD}} --state all --json number,state,labels,body
- Children: gh issue list -R {{SLUG}} --label {{LABEL_READY}} --state all --json number,title,state,labels,body
- Read PLAN.md and (for topology) .harness/targets.tsv if present.
Classify every child issue:
  - closed                                 → DONE — leave it alone.
  - open + {{LABEL_WORKING}}               → IN-FLIGHT — READ-ONLY, never edit it.
  - open, no {{LABEL_WORKING}}             → IDLE — reorderable.
  - open + unmet `## Blocked by`           → BLOCKED — waiting on a prerequisite.

## 2. Locate the fit
Decide what the brief depends on (must finish first) and which IDLE work should now depend on it.

## 3. Act by altitude
- **issue** → create the issue(s) directly:
    gh issue create -R {{SLUG}} --title "[AFK] <task>" --label {{LABEL_READY}} \
      --body "<what + testable acceptance criteria>

      ## Blocked by
      <same-repo #N prerequisites, or 'None'>

      Part of #<the PRD number you found in step 1>"
  Referencing an IN-FLIGHT issue under `## Blocked by` is allowed — the new work simply waits for it.
- **prd** → if the PRD is closed, reopen it (gh issue reopen <prd> -R {{SLUG}}) and clear review:
    gh issue edit <prd> -R {{SLUG}} --remove-label {{LABEL_REVIEWED}}
  Append the new scope to the PRD body (gh issue edit <prd> --body "<old body + new scope>",
  preserving the existing text and `## Acceptance criteria`). Then create ONLY the DELTA child
  issues — additive; never duplicate a child that already exists (match by title/intent against the
  children you listed in step 1).
- **plan** → edit PLAN.md (commit + push to the default branch) and/or .harness/targets.tsv
  (add a row `id<TAB>repo<TAB>deps<TAB>desc`, or change a dependency edge). For a NEW multi target,
  run `bash .harness/seed.sh <unit-id>` (creates the repo + labels + CI) so the pool can claim it.
  Cascade the structural change down: update the PRD and create the delta issues it implies.

## 4. Ordering rules (HARD — these protect the running fleet)
- Only set/adjust `## Blocked by` on IDLE issues. NEVER edit an issue labelled {{LABEL_WORKING}}.
- Use same-repo `#N` refs only in `## Blocked by`.
- Introduce NO dependency cycle: before adding edge A→B, confirm B does not (transitively) depend on A.

## 5. Re-engage the unit (so dispatch re-includes it next poll)
- prd / planned mode: the PRD must end OPEN and NOT labelled {{LABEL_REVIEWED}} (you reopened/cleared it).
- issue-only mode: a new OPEN {{LABEL_READY}} issue is sufficient.
Do NOT restart the fleet — the running pool claims the new work within one poll. If NO pool is
running (all units retired), say so and recommend: .harness/bin/harness start --recover

## 6. Safety invariants — re-confirm ALL before finishing
- You modified no {{LABEL_WORKING}} (in-flight) issue.
- You introduced no dependency cycle.
- Every change was ADDITIVE — you removed or cancelled nothing already dispatched (do not duplicate
  existing issues).
- A live REVIEW was already guarded by the launcher; you did not bypass it.

## 7. Summarize
Post a comment on the PRD (or the lead issue) listing: the issues you created (with links), the
ordering graph (what blocks what), and what you deliberately left untouched (in-flight issues, by
number). Append one run-log line summarizing the injection.

When the work is injected, ordered, and the unit is re-engaged, output exactly:
<promise>{{PROMISE}}</promise>
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/test_prompt_labels.sh`
Expected: PASS — the summary line shows all assertions passed.

- [ ] **Step 5: Commit**

```bash
git add prompts/inject.md test/test_prompt_labels.sh
git commit -m "feat(inject): prompts/inject.md reconciliation algorithm + safety invariants"
```

---

## Task 4: `inject.sh` — thin headless launcher

**Files:**
- Create: `inject.sh`
- Test: `test/test_inject.sh` (extend)

- [ ] **Step 1: Add the failing launcher assertions**

In `test/test_inject.sh`, insert this block immediately **before** the final `finish` line:

```bash
# ── §2 inject.sh launcher: resolve unit, REVIEW-guard, render, launch ─────────
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_OWNER="acme"
HARNESS_SPEC="docs/spec.md"; PROMPTS_DIR="$HERE/../prompts"
TMPCO="$(mktemp -d)"; unit_checkout(){ echo "$TMPCO"; }   # don't clobber the real repo
LAUNCH="$RUN_DIR/launch.log"; : > "$LAUNCH"
launch_claude(){ echo "$1 :: $2" >> "$LAUNCH"; }           # record "<sess> :: <wd>"

# happy path: nothing live → launches hz-inject-main and renders the task file
( session_live(){ return 1; }
  source "$HERE/../inject.sh" issue "add a rate limiter" )
assert_eq "$?" "0" "inject.sh issue exits 0 when nothing is live"
assert_ok "launched hz-inject-main session" bash -c "grep -q 'hz-inject-main :: $TMPCO' '$LAUNCH'"
assert_ok "rendered the injector task file" bash -c "grep -q 'INJECT DONE' '$TMPCO/.harness-task.md'"
assert_ok "task file carries the brief"     bash -c "grep -q 'add a rate limiter' '$TMPCO/.harness-task.md'"

# REVIEW guard: a live hz-main orch session whose goal is REVIEW must abort (exit 1)
echo REVIEW > "$RUN_DIR/hz-main.goal"
( session_live(){ [[ "$1" == hz-main ]]; }
  source "$HERE/../inject.sh" issue "add a rate limiter" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh aborts while a REVIEW session is live for the unit"

# bad altitude is rejected
( source "$HERE/../inject.sh" bogus "x" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh rejects an unknown altitude"

# empty brief is rejected
( session_live(){ return 1; }
  source "$HERE/../inject.sh" issue "" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh rejects an empty brief"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_inject.sh`
Expected: FAIL — `inject.sh` does not exist; the happy-path source fails.

- [ ] **Step 3: Create `inject.sh`**

```bash
#!/usr/bin/env bash
# inject.sh <plan|prd|issue> [--unit <id>] "<brief>"
#   Thin launcher for live work injection. Resolves the unit, refuses to run while a REVIEW
#   session is live, renders prompts/inject.md, and launches a headless Ralph session named
#   hz-inject-<unit> (never collides with team_sessions, so it consumes no CAP/orch slot).
#   The live pool picks up the injected work on its next poll — no fleet restart.
set -uo pipefail

# Source lib.sh only when executed directly (not when sourced by the test).
if [[ -z "${_HARNESS_LIB_SOURCED:-}" ]]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

ALTITUDE="${1:?usage: inject.sh <plan|prd|issue> [--unit <id>] \"<brief>\"}"; shift
case "$ALTITUDE" in plan|prd|issue) ;; *) die "bad altitude: $ALTITUDE (want plan|prd|issue)";; esac

UNIT="main"
if [[ "${1:-}" == "--unit" ]]; then UNIT="${2:?--unit needs an id}"; shift 2; fi
BRIEF="$*"
[[ -n "$BRIEF" ]] || die "a brief is required: inject.sh $ALTITUDE \"<brief>\""

SLUG="$(unit_slug "$UNIT")"; [[ -n "$SLUG" ]] || die "could not resolve repo for unit: $UNIT"
PROJECT="$UNIT"; DESC="$(unit_desc "$UNIT")"; CHECKOUT="$(unit_checkout "$UNIT")"

# Safety: never inject while a REVIEW orchestration session is live for this unit — a REVIEW
# could close the PRD out from under us. All orch actions share sess_orch's name; the .goal
# file records which action it is.
orch="$(sess_orch "$UNIT")"
if session_live "$orch" && [[ "$(cat "$RUN_DIR/$orch.goal" 2>/dev/null)" == REVIEW ]]; then
  die "a REVIEW session ($orch) is live for $UNIT — wait for it to finish, or abort it, then retry"
fi

sess="$(sess_inject "$UNIT")"
session_live "$sess" && die "an injector is already running for $UNIT ($sess)"

PROMISE="INJECT DONE"; MAXITER="$HARNESS_INJECT_MAXITER"; GOAL="INJECT"
render "$PROMPTS_DIR/inject.md" \
  ALTITUDE="$ALTITUDE" BRIEF="$BRIEF" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" \
  OWNER="$HARNESS_OWNER" SPEC="$HARNESS_SPEC" PROMISE="$PROMISE" \
  LABEL_READY="$HARNESS_LABEL_READY" LABEL_PRD="$HARNESS_LABEL_PRD" \
  LABEL_WORKING="$HARNESS_LABEL_WORKING" LABEL_BLOCKED="$HARNESS_LABEL_BLOCKED" \
  LABEL_REVIEWED="$HARNESS_LABEL_REVIEWED" > "$CHECKOUT/.harness-task.md"

launch_claude "$sess" "$CHECKOUT"
log "injector launched: $sess (altitude=$ALTITUDE unit=$UNIT) — pool picks it up next poll, no restart"
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x inject.sh`

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/test_inject.sh`
Expected: PASS — all `§1` and `§2` assertions pass, ending with `── N/N passed`.

- [ ] **Step 6: Commit**

```bash
git add inject.sh test/test_inject.sh
git commit -m "feat(inject): inject.sh launcher — REVIEW-guard, render, launch hz-inject-<unit>"
```

---

## Task 5: The three thin skills (`/harness-plan`, `/harness-prd`, `/harness-issue`)

**Files:**
- Create: `skill/harness-issue/SKILL.md`, `skill/harness-prd/SKILL.md`, `skill/harness-plan/SKILL.md`
- Test: `test/test_subskills.sh`

- [ ] **Step 1: Add the failing assertions**

In `test/test_subskills.sh`, extend the `CMD` map:

```bash
declare -A CMD=(
  [harness-init]=init [harness-start]=start [harness-stop]=stop
  [harness-pause]=pause [harness-resume]=resume [harness-status]=status
  [harness-plan]=plan [harness-prd]=prd [harness-issue]=issue
)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_subskills.sh`
Expected: FAIL at `harness-plan SKILL.md exists` (files not created yet).

- [ ] **Step 3: Create `skill/harness-issue/SKILL.md`**

```markdown
---
name: harness-issue
description: Inject one or more discrete implementation issues into a LIVE Harness fleet — grills you first, then reconciles against GitHub and creates ready-for-agent issues with correct ordering (no restart). Trigger on /harness-issue or "add an issue to the fleet".
---

# /harness-issue — inject implementation issue(s) into a live fleet

Adds discrete units of work to a RUNNING fleet; the pool picks them up on its next poll — no restart.
Don't hand-create the issue yourself — this routes through the injector so reconciliation + ordering are correct.

**This mutates GitHub (creates issues, sets `## Blocked by`). Grill first, confirm, then run.**

1. **Grill the user** (use the `grill-me` skill / its pattern). Mutate NOTHING yet. Resolve:
   - the concrete outcome wanted (one shippable unit of work);
   - testable acceptance criteria;
   - ordering — what it depends on (must finish first), and which existing idle work must wait for it;
   - what it must NOT break.
2. **Replay a crystallized brief** in one short paragraph and get explicit confirmation. This is the human safety gate.
3. Run: `.harness/bin/harness issue "<crystallized brief>"`
   (multi-topology: target a unit with `.harness/bin/harness issue --unit <id> "<brief>"`.)
4. Report the launched injector session (`hz-inject-<unit>`); watch with `/harness-status`. The live pool dispatches the new issue within one poll.

Needs a running fleet. If the pool has retired (all units COMPLETE), the injector says so — relaunch with `/harness-start` (`--recover`).
```

- [ ] **Step 4: Create `skill/harness-prd/SKILL.md`**

```markdown
---
name: harness-prd
description: Extend a Harness PRD's scope on a LIVE fleet — grills you first, then reopens the PRD, clears `reviewed`, appends the new scope, and creates ONLY the delta issues (no duplicates, no restart). Trigger on /harness-prd or "expand the PRD scope".
---

# /harness-prd — extend the PRD scope on a live fleet

Grows a milestone/scope on a RUNNING fleet. Reopens a completed PRD, appends scope, and creates the
**delta** issues only. Don't edit the PRD by hand — route it through the injector so it reconciles
against existing children and never duplicates them.

**This mutates GitHub (reopens the PRD, edits its body, creates issues). Grill first, confirm, then run.**

1. **Grill the user** (use the `grill-me` skill / its pattern). Mutate NOTHING yet. Resolve:
   - the new scope/milestone and why it's in scope now;
   - testable acceptance criteria for the additions;
   - ordering against existing work (what the new scope depends on; what should wait for it);
   - what it must NOT break or duplicate.
2. **Replay a crystallized brief** in one short paragraph and get explicit confirmation. This is the human safety gate.
3. Run: `.harness/bin/harness prd "<crystallized brief>"`
   (multi-topology: target a unit with `.harness/bin/harness prd --unit <id> "<brief>"`.)
4. Report the launched injector session (`hz-inject-<unit>`); watch with `/harness-status`. Reopening
   the PRD + clearing `reviewed` re-engages the unit so the pool resumes within one poll.

Needs a running fleet. If the pool has retired (all units COMPLETE), the injector says so — relaunch with `/harness-start` (`--recover`).
```

- [ ] **Step 5: Create `skill/harness-plan/SKILL.md`**

```markdown
---
name: harness-plan
description: Inject a plan / topology change into a LIVE Harness fleet — grills you first, then edits PLAN.md and/or targets.tsv (incl. seeding a new target repo) and cascades the delta down to PRD + issues (no restart). Trigger on /harness-plan or "change the plan/topology".
---

# /harness-plan — inject a plan / topology change into a live fleet

The highest-altitude injection: structural or topology change on a RUNNING fleet. Edits `PLAN.md`
and/or `.harness/targets.tsv` (add a target repo, change a dependency edge), then cascades the
change down to the PRD and delta issues. Don't rewrite the plan by hand — route it through the
injector so the change reconciles against live state and seeds any new repo.

**This mutates the repo and GitHub (commits PLAN.md, rewrites targets.tsv, may seed a new repo, creates issues). Grill first, confirm, then run.**

1. **Grill the user** (use the `grill-me` skill / its pattern). Mutate NOTHING yet. Resolve:
   - the structural change wanted (plan edit, new target repo, changed dependency edge);
   - testable acceptance criteria for the change landing;
   - ordering / dependency edges (what unblocks what across units);
   - what it must NOT break (no cycles; never disturb in-flight work).
2. **Replay a crystallized brief** in one short paragraph and get explicit confirmation. This is the human safety gate.
3. Run: `.harness/bin/harness plan "<crystallized brief>"`
   (multi-topology: target a unit with `.harness/bin/harness plan --unit <id> "<brief>"`.)
4. Report the launched injector session (`hz-inject-<unit>`); watch with `/harness-status`. A new
   target is seeded so the multi-pool can claim it once its deps are complete — no restart.

Needs a running fleet. If the pool has retired (all units COMPLETE), the injector says so — relaunch with `/harness-start` (`--recover`).
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash test/test_subskills.sh`
Expected: PASS — ends with `── subskills ok` (per-skill checks + deploy-simulation for all nine skills).

- [ ] **Step 7: Commit**

```bash
git add skill/harness-issue/SKILL.md skill/harness-prd/SKILL.md skill/harness-plan/SKILL.md test/test_subskills.sh
git commit -m "feat(inject): /harness-plan, /harness-prd, /harness-issue thin grill-first skills"
```

---

## Task 6: `prompts/decompose.md` — defensive idempotency

**Files:**
- Modify: `prompts/decompose.md`
- Test: `test/test_prompt_labels.sh`

- [ ] **Step 1: Add the failing assertions**

In `test/test_prompt_labels.sh`, in the `# ── decompose.md assertions ──` group (after the existing `decompose.md` checks), add:

```bash
assert "decompose.md: idempotent — lists existing with --state all" \
  "grep -q 'state all' <<<\"\$out_dec\""
assert "decompose.md: only-missing / no-duplicate rule present" \
  "grep -qi 'only' <<<\"\$out_dec\" && grep -qi 'duplicate' <<<\"\$out_dec\""
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_prompt_labels.sh`
Expected: FAIL — `decompose.md` has no `--state all` / no-duplicate idempotency text yet.

- [ ] **Step 3: Edit `prompts/decompose.md`**

Insert an idempotency step between the slicing step (`2.`) and the per-task creation step (`3.`).
Replace:

```
   implementation tasks (each ~1 PR of work, with its own acceptance criteria).
3. For each task, create an issue in this repo:
```

with:

```
   implementation tasks (each ~1 PR of work, with its own acceptance criteria).
2a. Idempotency — before creating anything, list the issues that already exist:
      gh issue list -R {{SLUG}} --label {{LABEL_READY}} --state all
    Create an issue ONLY for a task with no matching issue yet (match by title/intent); never
    duplicate a task that already has an issue (an injector may have already added some).
3. For each task, create an issue in this repo:
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/test_prompt_labels.sh`
Expected: PASS — all assertions pass.

- [ ] **Step 5: Commit**

```bash
git add prompts/decompose.md test/test_prompt_labels.sh
git commit -m "fix(decompose): idempotent issue creation — list existing, only create missing"
```

---

## Task 7: Document the injection shortcuts (umbrella skill + README)

**Files:**
- Modify: `skill/SKILL.md`, `README.md`
- Test: `test/test_skill.sh`

- [ ] **Step 1: Add the failing assertions**

In `test/test_skill.sh`, after the `assert "documents setup" …` line:

```bash
assert "documents setup"  "grep -qi 'setup' '$S'"
assert "documents issue injection" "grep -q 'harness issue' '$S'"
assert "documents prd injection"   "grep -q 'harness prd' '$S'"
assert "documents plan injection"  "grep -q 'harness plan' '$S'"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_skill.sh`
Expected: FAIL at `documents issue injection` (umbrella skill has no injection section yet).

- [ ] **Step 3: Edit `skill/SKILL.md`**

Insert a new section immediately before the existing `## Per-command shortcuts` heading:

```markdown
## Injecting live work (no restart)
Add work to a RUNNING fleet without stopping it. Each skill grills you, confirms a brief, then runs a
headless injector (`hz-inject-<unit>`) that reconciles against live GitHub state; the pool picks it up next poll:
- `/harness-issue` → `harness issue "<brief>"` — one or more implementation issues.
- `/harness-prd`   → `harness prd "<brief>"` — reopen the PRD, append scope, create the delta issues.
- `/harness-plan`  → `harness plan "<brief>"` — edit `PLAN.md`/`targets.tsv` (incl. a new target repo).

The injector never touches an in-flight (`agent-working`) issue and refuses to run while a REVIEW session is live for the unit.

## Per-command shortcuts
```

- [ ] **Step 4: Edit `README.md` — CLI command table**

In `README.md`, in the CLI command table, after the `attach` row:

```markdown
| `attach <unit> [issue]` | tmux-attach to a running session |
| `plan "<brief>"` | Inject a plan/topology change into a live fleet (grill via `/harness-plan`) |
| `prd "<brief>"` | Extend the PRD scope + create delta issues (grill via `/harness-prd`) |
| `issue "<brief>"` | Inject implementation issue(s) into a live fleet (grill via `/harness-issue`) |
```

- [ ] **Step 5: Edit `README.md` — per-command shortcut table**

In `README.md`, in the `### Per-command shortcuts` table, after the `/harness-status` row:

```markdown
| `/harness-status` | `harness status` | read-only, runs immediately |
| `/harness-issue`  | `harness issue`  | grills first; creates `ready-for-agent` issue(s) with ordering |
| `/harness-prd`    | `harness prd`    | grills first; reopens PRD, appends scope, creates delta issues |
| `/harness-plan`   | `harness plan`   | grills first; edits `PLAN.md`/`targets.tsv`, cascades delta issues |
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash test/test_skill.sh`
Expected: PASS — ends with `── skill ok`.

- [ ] **Step 7: Commit**

```bash
git add skill/SKILL.md README.md test/test_skill.sh
git commit -m "docs(inject): document plan/prd/issue injection in /harness skill + README"
```

---

## Task 8: Full-suite verification

**Files:** none (verification only)

- [ ] **Step 1: Run the entire test suite**

Run: `bash test/run.sh`
Expected: every `test_*.sh` / `test_*.py` block runs; final exit code 0. Confirm in particular:
`== test_inject.sh ==`, `== test_cli.sh ==`, `== test_subskills.sh ==`, `== test_skill.sh ==`,
`== test_prompt_labels.sh ==` all show their pass lines and nothing reports `FAIL`.

- [ ] **Step 2: Sanity-check the CLI help end-to-end**

Run: `bin/harness help`
Expected: usage lists `plan`, `prd`, and `issue` with their `"<brief>"` descriptions.

- [ ] **Step 3: Confirm the deploy glob would ship the new skills**

Run: `ls skill/harness-plan/SKILL.md skill/harness-prd/SKILL.md skill/harness-issue/SKILL.md`
Expected: all three paths exist (install.sh / update.sh copy every `skill/*/SKILL.md`, so no installer edit is needed).

- [ ] **Step 4: Final commit (if anything is uncommitted)**

```bash
git status            # expect clean if Tasks 1–7 each committed
```

---

## Self-review (spec coverage)

Checked against `docs/superpowers/specs/2026-05-23-harness-live-work-injection-design.md`:

| Spec acceptance criterion | Covered by |
|---|---|
| `harness plan\|prd\|issue "<brief>"` exist + appear in `harness help` | Task 2 (routing + usage), Task 8 step 2 |
| Three skills install (via `install.sh` glob) + are recognized; each grills before mutating | Task 5 (skills with explicit grill→confirm→run), Task 8 step 3 |
| `/harness-issue` creates a `ready-for-agent` issue with correct `## Blocked by`; pool dispatches within one poll, no restart | Task 3 (`inject.md` §3 issue + §5 re-engage), Task 4 (launcher); pickup reuses existing `issuelib.dispatch` (no code change) |
| `/harness-prd` reopens PRD, clears `reviewed`, appends scope, creates only delta issues | Task 3 (`inject.md` §3 prd), Task 5 (`harness-prd` skill) |
| `/harness-plan` adds a `targets.tsv` row, seeds the repo, multi-pool claims it when deps complete | Task 3 (`inject.md` §3 plan — `targets.tsv` + `seed.sh`), Task 5 (`harness-plan` skill) |
| Injector never edits an `agent-working` issue; aborts/waits if a REVIEW session is live | Task 4 (REVIEW-guard, tested), Task 3 (`inject.md` §1/§4/§6 rules, tested for presence) |
| Injector session name does not collide with `team_sessions` (verified by test) | Task 1 (`sess_inject` + non-collision test) |
| No dependency cycle can be introduced (verified by test) | Task 3 (`inject.md` §4 cycle guard, asserted present) |
| `test_inject.sh` passes; `test_cli.sh`, `test_skill.sh`, `test_subskills.sh` updated + passing | Tasks 1/4 (new), 2/7/5 (updated), Task 8 (full suite) |
| `prompts/decompose.md` defensive idempotency | Task 6 |

**Note on prompt-driven behaviors.** The reconciliation itself (additive-delta, cycle avoidance, PRD reopen) runs inside the headless Claude injector at runtime — it is not shell logic. The honest unit-testable surface is therefore: (a) the launcher's deterministic guards/naming/render (Tasks 1 & 4, executed in tests), and (b) that `inject.md` actually instructs each rule (Task 3, asserted via `render` + `grep`, the same pattern `test_prompt_labels.sh` already uses for the other orchestration prompts). End-to-end "dispatched within one poll on a live fleet" is an operational property of the unchanged pool loop and is validated by operating a real fleet, not by a unit test.

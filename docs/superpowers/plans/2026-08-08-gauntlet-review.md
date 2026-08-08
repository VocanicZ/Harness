# Gauntlet Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the REVIEW stage so a PRD that names a real-world quality bar is judged by a blind A/B against it, looping through the existing REVIEW → IMPL → REVIEW edge until it wins or a round cap concedes.

**Architecture:** Prompt-layer change plus one bash helper. `prompts/prd.md` learns to emit an optional `## Quality bar` section; `scripts/lib.sh` gains `gauntlet_round` (counts `<!-- harness-gauntlet round=N -->` markers in the PRD's comments) and a `HARNESS_GAUNTLET_ROUNDS` default; `scripts/drive.sh` computes the round at spawn time and templates three new vars into the review prompt; `prompts/review.md` becomes two-phase (criteria gate, then gauntlet). No change to `scripts/issuelib.py` and no new pipeline state — a lost round files one `ready-for-agent` issue, which is the existing failure path.

**Tech Stack:** bash 4+, `gh` CLI (JSON + `-q` jq filters), python3 (only via the existing `render()`), plain-bash test rig in `test/`.

**Spec:** `docs/superpowers/specs/2026-08-08-gauntlet-review-design.md`

## Global Constraints

- **No new runtime dependency.** `git`, `tmux`, `python3`, `gh`, `claude` only.
- **State lives in GitHub, never on disk.** Round state is PRD comments. `$GAUNTLET_DIR` holds only the current round's evidence and must be safe to delete.
- **Nothing is written inside the review `CHECKOUT`.** A review session runs in a real clone; gauntlet artifacts go under `STATE_DIR`.
- **Autonomous agents never park.** No prompt branch may apply `agent-blocked`; every failure path must still reach a completed review pass.
- **Off by default.** A PRD with no `## Quality bar` must produce byte-identical review behaviour to today.
- **Shell style:** scripts run under `set -uo pipefail` (not `-e`). Never rely on `cmd && x=y` for assignment — use an `if`.
- **Prompt templating:** `{{VAR}}` placeholders substituted by `render()` (`scripts/lib.sh:710`). An unrendered `{{...}}` reaching an agent is a bug.
- **Tests:** plain bash, `test/helpers.sh` rig (`assert_eq` / `assert_ok` / `assert_no` / `finish`), function stubs — no framework, no network. `test/run.sh` auto-discovers `test_*.sh`.
- **Merging:** this repo forbids `gh pr merge --auto`; squash-merge directly when green.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/lib.sh` | **Modify.** `HARNESS_GAUNTLET_ROUNDS` default + export; `gauntlet_round <prd>` helper. |
| `scripts/drive.sh` | **Modify** (`spawn_orch`, ~line 131-149). Compute the round for `REVIEW`, pass three render vars. |
| `prompts/prd.md` | **Modify.** Emit an optional, validated `## Quality bar` section. |
| `prompts/review.md` | **Modify** (rewrite). Two-phase reviewer: criteria gate, then gauntlet round. |
| `README.md` | **Modify.** One config row + a `### Gauntlet review` section. |
| `test/test_gauntlet.sh` | **Create.** Round counting + `spawn_orch` render vars. |
| `test/test_prompt_labels.sh` | **Modify.** Render the new keys; assert no `{{GAUNTLET_` survives. |
| `test/test_readme_docs.sh` | **Modify.** Assert the config row and section exist. |

Tasks are ordered so each one's tests can run standalone: the helper exists before the caller, the caller exists before the prompts that consume its vars.

---

### Task 1: `gauntlet_round` helper + config default

**Files:**
- Modify: `scripts/lib.sh` (defaults block ~line 56, export list ~line 67, new function after `render()` ~line 716)
- Test: `test/test_gauntlet.sh` (create)

**Interfaces:**
- Consumes: `$SLUG` (set per-unit by `drive.sh`), `gh`.
- Produces: `gauntlet_round <prd>` → prints a 1-based integer round number on stdout, always succeeds. `$HARNESS_GAUNTLET_ROUNDS` (default `3`), exported.

- [ ] **Step 1: Write the failing test**

Create `test/test_gauntlet.sh`:

```bash
#!/usr/bin/env bash
# test_gauntlet.sh — gauntlet review: round counting (lib.sh) + spawn_orch render vars (drive.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/helpers.sh"
make_env

SLUG=acme/widget

echo "=== gauntlet_round ==="
# gauntlet_round reads a COUNT from `gh ... -q '... | length'`, so the stub returns the count.
gh(){ echo 0; }
assert_eq "$(gauntlet_round 7)" "1" "no markers -> round 1"

gh(){ echo 2; }
assert_eq "$(gauntlet_round 7)" "3" "two markers -> round 3"

gh(){ return 1; }
assert_eq "$(gauntlet_round 7)" "1" "gh failure -> round 1 (a transient error never fakes a concede)"

gh(){ echo "warning: template ignored"; }
assert_eq "$(gauntlet_round 7)" "1" "non-numeric gh output -> round 1"

finish
```

Make it executable: `chmod +x test/test_gauntlet.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test_gauntlet.sh`
Expected: FAIL — `gauntlet_round: command not found`, all four assertions report `want [1] got []`.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib.sh`, add to the defaults block (directly after the `HARNESS_WORKTREE_HOOK` line):

```sh
: "${HARNESS_GAUNTLET_ROUNDS:=3}"        # gauntlet review: rounds allowed before the reviewer concedes
```

Add `HARNESS_GAUNTLET_ROUNDS` to the `export HARNESS_...` list (append to the line that already carries `HARNESS_AUTHOR_ALLOWLIST HARNESS_USE_POLLER HARNESS_PREFIX_COLLISION HARNESS_WORKTREE_HOOK`).

Add the function immediately after `render()`:

```sh
# gauntlet_round <prd> — echo the gauntlet round this review pass will run (1-based).
# Round state is the PRD's own comment stream: every LOST round leaves a
# `<!-- harness-gauntlet round=N -->` marker (see prompts/review.md). Nothing on disk, so a
# resume on another host picks up at the right round. ANY failure — offline, rate limit, junk
# on stdout — counts as zero markers and returns round 1: a transient gh error must never be
# able to push the reviewer past the cap and fake a concede.
gauntlet_round(){ local prd="$1" n
  n="$(gh issue view "$prd" -R "$SLUG" --json comments \
       -q '[.comments[].body | select(test("<!-- harness-gauntlet round="))] | length' 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo $(( n + 1 )); }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test_gauntlet.sh`
Expected: PASS — `── 4/4 passed`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh test/test_gauntlet.sh
git commit -m "feat(gauntlet): gauntlet_round helper + HARNESS_GAUNTLET_ROUNDS default"
```

---

### Task 2: `spawn_orch` computes the round and passes the render vars

**Files:**
- Modify: `scripts/drive.sh` (`spawn_orch`, the `local tmpl; case ...` block and the `render` call)
- Test: `test/test_gauntlet.sh` (extend)

**Interfaces:**
- Consumes: `gauntlet_round` (Task 1), `$STATE_DIR`, `$UNIT`, `$HARNESS_GAUNTLET_ROUNDS`.
- Produces: three render keys available to every orchestration prompt — `GAUNTLET_DIR` (absolute, `$STATE_DIR/gauntlet/$UNIT`), `GAUNTLET_ROUNDS` (integer), `GAUNTLET_ROUND` (integer for `REVIEW`, empty string for `PLAN`/`PRD`/`DECOMPOSE`).

- [ ] **Step 1: Write the failing test**

Append to `test/test_gauntlet.sh`, **above** the final `finish` line:

```bash
echo "=== spawn_orch render vars ==="
UNIT=main; PROJECT=main; DESC=widget
STATE_DIR="$(mktemp -d)"
CHECKOUT="$(mktemp -d)"
CALLS="$RUN_DIR/calls"
HARNESS_TOPOLOGY=single
HARNESS_GAUNTLET_ROUNDS=3

# Stub every side effect; `render` records its argv so we can inspect the keys.
render(){ echo "render $*" >> "$CALLS"; return 0; }
launch_claude(){ :; }
default_branch(){ echo main; }
ensure_safe(){ :; }
git(){ :; }
gh(){ echo 1; }        # one marker on the PRD -> this pass is round 2

: > "$CALLS"
spawn_orch REVIEW 7 "REVIEW DONE" >/dev/null 2>&1
assert_ok "REVIEW: GAUNTLET_DIR lives under STATE_DIR" \
  grep -q "GAUNTLET_DIR=$STATE_DIR/gauntlet/main" "$CALLS"
assert_no "REVIEW: GAUNTLET_DIR never under CHECKOUT" \
  grep -q "GAUNTLET_DIR=$CHECKOUT" "$CALLS"
assert_ok "REVIEW: GAUNTLET_ROUND computed from markers (1 marker -> 2)" \
  grep -q "GAUNTLET_ROUND=2" "$CALLS"
assert_ok "REVIEW: GAUNTLET_ROUNDS passed through" \
  grep -q "GAUNTLET_ROUNDS=3" "$CALLS"

: > "$CALLS"
spawn_orch DECOMPOSE 7 "DECOMPOSE DONE" >/dev/null 2>&1
assert_ok "DECOMPOSE: GAUNTLET_ROUND rendered empty (no PRD payload to count)" \
  grep -qE "GAUNTLET_ROUND=( |\$)" "$CALLS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test_gauntlet.sh`
Expected: FAIL — the four new `assert_ok` lines fail (no `GAUNTLET_` key in the recorded argv); `assert_no` passes vacuously.

- [ ] **Step 3: Write minimal implementation**

In `scripts/drive.sh`, inside `spawn_orch`, directly after the `case "$action" in ... esac` that picks `tmpl`, add:

```sh
  # Round is computed HERE, not in the prompt: a Claude session cannot call a lib.sh function,
  # and letting it count its own comments makes the cap something it can miscount past.
  local ground=""
  if [[ "$action" == REVIEW ]]; then ground="$(gauntlet_round "$payload")"; fi
```

Then extend the `render` call to:

```sh
  render "$PROMPTS_DIR/$tmpl" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" OWNER="$HARNESS_OWNER" \
    SPEC="$HARNESS_SPEC" PRD="$payload" ISSUE="" BRANCH="" PROMISE="$PROMISE" \
    LABEL_READY="$HARNESS_LABEL_READY" LABEL_PRD="$HARNESS_LABEL_PRD" LABEL_REVIEWED="$HARNESS_LABEL_REVIEWED" \
    GAUNTLET_DIR="$STATE_DIR/gauntlet/$UNIT" GAUNTLET_ROUNDS="$HARNESS_GAUNTLET_ROUNDS" \
    GAUNTLET_ROUND="$ground" > "$CHECKOUT/.harness-task.md"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test_gauntlet.sh`
Expected: PASS — `── 9/9 passed`

Then confirm nothing else regressed: `bash test/test_spawn.sh && bash test/test_drive.sh`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/drive.sh test/test_gauntlet.sh
git commit -m "feat(gauntlet): spawn_orch computes the round and renders the gauntlet vars"
```

---

### Task 3: PRD prompt emits an optional `## Quality bar`

**Files:**
- Modify: `prompts/prd.md`
- Test: `test/test_prompt_labels.sh` (extend the `out_prd` block)

**Interfaces:**
- Consumes: nothing new (no render keys — the section is authored content).
- Produces: the `## Quality bar` contract that `prompts/review.md` (Task 4) parses:
  `Beat: <named artifact + URL>` and a `Judged on:` bullet list of 2–4 dimensions.

- [ ] **Step 1: Write the failing test**

In `test/test_prompt_labels.sh`, add after the existing decompose assertions:

```bash
# ── prd.md quality-bar assertions ────────────────────────────────────────────
assert "prd.md: teaches the '## Quality bar' section" \
  "grep -q '## Quality bar' <<<\"\$out_prd\""

assert "prd.md: bar contract is Beat + Judged on" \
  "grep -q 'Beat:' <<<\"\$out_prd\" && grep -q 'Judged on' <<<\"\$out_prd\""

assert "prd.md: enforces named + fetchable + comparable" \
  "grep -qi 'named' <<<\"\$out_prd\" && grep -qi 'fetchable' <<<\"\$out_prd\" && grep -qi 'comparable' <<<\"\$out_prd\""

assert "prd.md: omission is explicitly allowed (never invent a bar)" \
  "grep -qi 'omit' <<<\"\$out_prd\" && grep -qi 'never invent' <<<\"\$out_prd\""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test_prompt_labels.sh`
Expected: FAIL on all four new assertions (`prd.md` has no quality-bar text yet).

- [ ] **Step 3: Write minimal implementation**

In `prompts/prd.md`, insert this as **step 3** (between the existing `to-prd` step and the `gh issue create` step), then renumber the existing steps 3 and 4 to 4 and 5:

```markdown
3. QUALITY BAR — optional, and honestly optional. If (and only if) there is a real, specific
   artifact this project should beat, add ONE more section to the PRD body:
     ## Quality bar
     Beat: <one named artifact + URL>
     Judged on:
     - <dimension — decidable by RUNNING something>
     - <dimension>
   The bar must be NAMED (a specific thing, not a category — "ripgrep" plus its URL, not "fast
   grep tools"), FETCHABLE (the reviewer can clone, install, run, or open it), and COMPARABLE
   (ours and it can sit side by side and a judge can pick one). Each `Judged on` dimension must be
   decidable by running a task, not by opinion. 2-4 dimensions.
   If no reference passes all three tests, OMIT the section entirely — that is the normal case for
   internal tooling, and omitting it simply leaves review on acceptance criteria alone. NEVER
   invent a bar to fill the section: a fake reference costs the fleet a real implementation round
   every time it loses to it.
```

Also extend the `gh issue create` step's body note so it reads `--body "<the PRD markdown, incl. an '## Acceptance criteria' section, and '## Quality bar' if step 3 produced one>"`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test_prompt_labels.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add prompts/prd.md test/test_prompt_labels.sh
git commit -m "feat(gauntlet): PRD prompt emits an optional, validated quality bar"
```

---

### Task 4: Two-phase `prompts/review.md`

**Files:**
- Modify: `prompts/review.md` (rewrite)
- Test: `test/test_prompt_labels.sh` (update the `out_review` render call + new assertions)

**Interfaces:**
- Consumes: `{{GAUNTLET_DIR}}`, `{{GAUNTLET_ROUND}}`, `{{GAUNTLET_ROUNDS}}` (Task 2); the `## Quality bar` contract (Task 3).
- Produces: the `<!-- harness-gauntlet round=N -->` PRD comment marker that `gauntlet_round` (Task 1) counts. Written on a LOST round only.

- [ ] **Step 1: Write the failing test**

In `test/test_prompt_labels.sh`, update the `out_review` render call to pass the new keys:

```bash
out_review="$(render "$HERE/../prompts/review.md" \
  PRD=7 SLUG=acme/widget PROJECT=w DESC=d SPEC= \
  LABEL_READY=go LABEL_PRD=spec LABEL_REVIEWED=verified \
  GAUNTLET_DIR=/tmp/gaunt GAUNTLET_ROUND=2 GAUNTLET_ROUNDS=3)"
```

and add these assertions after the existing review block:

```bash
assert "review.md: no unrendered {{GAUNTLET_ token" \
  "! grep -q '{{GAUNTLET_' <<<\"\$out_review\""

assert "review.md: criteria gate runs before the gauntlet" \
  "[[ \$(grep -n 'PHASE 1' <<<\"\$out_review\" | head -1 | cut -d: -f1) -lt \$(grep -n 'PHASE 2' <<<\"\$out_review\" | head -1 | cut -d: -f1) ]]"

assert "review.md: no quality bar -> sign off unchanged" \
  "grep -qi 'no .*Quality bar' <<<\"\$out_review\""

assert "review.md: round/cap values are rendered" \
  "grep -q 'round 2 of 3' <<<\"\$out_review\""

assert "review.md: writes the round marker with the rendered round" \
  "grep -q 'harness-gauntlet round=2' <<<\"\$out_review\""

assert "review.md: evidence dirs live under the rendered GAUNTLET_DIR" \
  "grep -q '/tmp/gaunt/r2' <<<\"\$out_review\""

assert "review.md: .mapping is a sibling of A/ and B/" \
  "grep -q '.mapping' <<<\"\$out_review\" && grep -qi 'sibling' <<<\"\$out_review\""

assert "review.md: critic verdict is binary (no scores)" \
  "grep -q 'winner: A|B' <<<\"\$out_review\" && grep -qi 'no.*scores\|not.*scores' <<<\"\$out_review\""

assert "review.md: concede path signs off at the cap" \
  "grep -qi 'concede' <<<\"\$out_review\""

assert "review.md: never parks on a quality gate" \
  "! grep -q 'add-label agent-blocked' <<<\"\$out_review\" && grep -qi 'never apply an agent-blocked' <<<\"\$out_review\""

assert "review.md: a lost round files exactly ONE issue" \
  "grep -qi 'exactly ONE' <<<\"\$out_review\""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test_prompt_labels.sh`
Expected: FAIL on the new review assertions (current `review.md` has no phases and no gauntlet text).

- [ ] **Step 3: Write minimal implementation**

Replace `prompts/review.md` entirely with:

```markdown
You are the reviewer for {{PROJECT}} ({{DESC}}).
Running autonomously in a Ralph loop. Output the completion promise ONLY when genuinely true.

Repo (this working dir): {{SLUG}}
PRD under review: #{{PRD}}  (all its implementation issues are closed)
Gauntlet: round {{GAUNTLET_ROUND}} of {{GAUNTLET_ROUNDS}}   Evidence dir: {{GAUNTLET_DIR}}

GOAL: verify the implementation satisfies PRD #{{PRD}}, then either sign off or file fixes.

PHASE 1 — CRITERIA GATE (always).
1. Read PRD #{{PRD}} and its `## Acceptance criteria`.  gh issue view {{PRD}} -R {{SLUG}}
2. Review the implemented code against EVERY acceptance criterion. Run the test suite. Spawn a
   review sub-agent for a thorough pass (correctness, edge cases, the criteria the spec
   set for {{PROJECT}} — e.g. go/no-go gate numbers if this is a spike).
3. If ANY criterion is unmet: for each gap, create a `{{LABEL_READY}}` implementation issue in
   this repo (with `## Blocked by` if needed) and comment the findings on PRD #{{PRD}}. Do NOT add
   `{{LABEL_REVIEWED}}`. Do NOT run phase 2 — a half-built artifact loses every comparison for
   reasons the acceptance criteria already told you, wasting a full round. That is a completed
   review pass; go to OUTPUT.
4. All criteria met. If PRD #{{PRD}} has no `## Quality bar` section, the gauntlet is OFF for this
   PRD: SIGN OFF now (step 6). Otherwise continue to PHASE 2.

PHASE 2 — GAUNTLET (only when phase 1 passed AND the PRD carries a `## Quality bar`).
The bar names one real artifact to beat and the dimensions to judge on:
    ## Quality bar
    Beat: <named artifact + URL>
    Judged on: <2-4 dimensions>

5a. CAP. If round {{GAUNTLET_ROUND}} is greater than {{GAUNTLET_ROUNDS}}, CONCEDE: comment on PRD
    #{{PRD}} with the standing gap from the previous round and the fact that the cap was reached,
    then SIGN OFF (step 6). A bar can be honestly unbeatable and this fleet has no human to call
    it off; conceding is how the unit still reaches COMPLETE instead of looping on one PRD until
    the budget dies — and, in multi topology, holding every dependent target hostage behind it.
5b. PROVISION. Fetch / clone / install / launch the reference under {{GAUNTLET_DIR}}/ref/. If it
    cannot be provisioned — paywall, no public build, a credential this fleet does not hold —
    comment on PRD #{{PRD}} saying exactly what failed, then SIGN OFF on the acceptance criteria
    alone (step 6). NEVER apply an agent-blocked label: this fleet is autonomous and must not park
    on a quality gate.
5c. RUN. Write a FIXED task list derived from the `Judged on` dimensions — the same tasks, in the
    same order, against both artifacts — and run it against ours and against the reference.
    Capture both, coin-flipping which side is which THIS round:
      mkdir -p {{GAUNTLET_DIR}}/r{{GAUNTLET_ROUND}}/A {{GAUNTLET_DIR}}/r{{GAUNTLET_ROUND}}/B
      # in each: transcript.txt, timings.txt, and screenshot.png wherever a UI is involved
      echo "A=ours" > {{GAUNTLET_DIR}}/r{{GAUNTLET_ROUND}}/.mapping    # or "A=ref"
    `.mapping` is a SIBLING of A/ and B/ — never write it inside either, and never name the sides
    in any file under them.
5d. JUDGE. Spawn ONE critic sub-agent with FRESH context. Give it exactly two things: the two
    absolute directory paths, and the `Judged on` dimensions. Instruct it to read nothing outside
    those two directories — not .mapping, not this repo, not git history — and to answer in
    exactly two lines:
      winner: A|B
      gap: <one sentence — the single largest meaningful difference>
    Binary only. Do NOT ask for scores or a per-dimension table: numeric scores drift upward every
    round and the loop stops meaning anything.
5e. RESOLVE. Only now read {{GAUNTLET_DIR}}/r{{GAUNTLET_ROUND}}/.mapping and map the winner to a
    side.
    WON (ours is the winner):
      gh issue comment {{PRD}} -R {{SLUG}} --body "Gauntlet round {{GAUNTLET_ROUND}}: won vs <bar>. Gap called out: <gap>."
      then SIGN OFF (step 6). Write NO round marker — the gauntlet is over.
    LOST:
      Create exactly ONE `{{LABEL_READY}}` issue in this repo, for the critic's single largest gap
      — not a checklist of everything you noticed. One gap per round is what makes this a loop
      instead of a shotgun. Then:
      gh issue comment {{PRD}} -R {{SLUG}} --body "<!-- harness-gauntlet round={{GAUNTLET_ROUND}} -->
      Gauntlet round {{GAUNTLET_ROUND}}: lost vs <bar>. Gap: <gap>. Filed #<issue>."
      Do NOT add `{{LABEL_REVIEWED}}`. The pool implements the gap issue, and review runs again at
      the next round. That is a completed review pass; go to OUTPUT.

6. SIGN OFF:
     gh issue edit {{PRD}} -R {{SLUG}} --add-label {{LABEL_REVIEWED}}
     gh issue close {{PRD}} -R {{SLUG}} --comment "Reviewed: all acceptance criteria met."
   The `{{LABEL_REVIEWED}}` label is the authoritative SIGN-OFF — applying it is the one thing you
   MUST do here. The close is bookkeeping: if it fails (e.g. a rate limit) the harness closes the
   PRD itself once it sees the reviewed label, so a signed-off PRD always reaches COMPLETE.

OUTPUT — every branch above is a completed review pass: signed off, criteria gaps filed, or a
gauntlet gap filed. When one of them is done, output exactly:
<promise>{{PROMISE}}</promise>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test_prompt_labels.sh`
Expected: PASS.

Then the whole suite: `bash test/run.sh`
Expected: PASS (non-zero exit means a sibling test regressed — most likely `test_skill.sh` or `test_readme_docs.sh`; fix before committing).

- [ ] **Step 5: Commit**

```bash
git add prompts/review.md test/test_prompt_labels.sh
git commit -m "feat(gauntlet): two-phase review — criteria gate, then blind A/B vs the bar"
```

---

### Task 5: Document it

**Files:**
- Modify: `README.md` (config table + a new `### Gauntlet review` section)
- Test: `test/test_readme_docs.sh` (extend)

**Interfaces:**
- Consumes: `HARNESS_GAUNTLET_ROUNDS` (Task 1), the review flow (Task 4).
- Produces: nothing code-facing.

- [ ] **Step 1: Write the failing test**

Append to `test/test_readme_docs.sh`, before the final `echo`:

```bash
# 4. Gauntlet review — config row, its own section, and the honest blindness caveat.
assert "config table lists HARNESS_GAUNTLET_ROUNDS" \
  "grep -qE '^\| \`HARNESS_GAUNTLET_ROUNDS\`' '$README'"
assert "README has a Gauntlet review section" \
  "grep -qE '^### Gauntlet review' '$README'"
assert "README documents the ## Quality bar opt-in" \
  "grep -q '## Quality bar' '$README'"
assert "README is honest that blindness is not a sandbox" \
  "grep -qi 'not a sandbox' '$README'"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/test_readme_docs.sh`
Expected: FAIL on the first new assertion (`exit 1` — this test aborts on first failure by design).

- [ ] **Step 3: Write minimal implementation**

Add to the README config table, directly after the `HARNESS_WORKTREE_HOOK` row:

```markdown
| `HARNESS_GAUNTLET_ROUNDS` | `3` | Gauntlet review: rounds allowed before the reviewer concedes and signs off. Only applies to a PRD carrying a `## Quality bar` — see [Gauntlet review](#gauntlet-review) |
```

Add this section directly after `### Parallel-lane merge safety` (outer fence is quadruple —
the section itself contains a fenced example):

````markdown
### Gauntlet review

Review normally grades the build against the PRD's own `## Acceptance criteria`. That bar is
self-referential — the same fleet wrote the PRD, decomposed it, and implemented it — so a pass
means "it meets the spec we wrote", never "it is any good".

A PRD may opt in to a harder gate by carrying one extra section:

```markdown
## Quality bar
Beat: ripgrep — https://github.com/BurntSushi/ripgrep
Judged on:
- time to first result on a 1M-line tree
- output legibility for a multi-file match
```

When it is present and every acceptance criterion already passes, the reviewer runs a **gauntlet
round**: it provisions the named reference, runs one fixed task list against both artifacts,
writes the two results into unlabelled `A/` and `B/` directories under
`.harness/gauntlet/<unit>/r<round>/`, and hands only those two paths to a **fresh-context critic
sub-agent**, which returns a binary winner plus the single largest gap. No scores — numeric
scoring drifts upward every round.

If ours wins, the PRD is signed off. If it loses, the reviewer files **one** `ready-for-agent`
issue for that one gap and leaves a `<!-- harness-gauntlet round=N -->` comment on the PRD; the
pool implements it and review runs again at round N+1. The loop is the ordinary
REVIEW → IMPL → REVIEW path — no new pipeline stage.

The bar must be **named** (a specific artifact, not a category), **fetchable** (the reviewer can
clone, install, run, or open it), and **comparable** (both can sit side by side and a judge can
pick one). A PRD with no `## Quality bar` reviews exactly as it always has, so this is off unless
a PRD asks for it.

**Rounds are capped** by `HARNESS_GAUNTLET_ROUNDS` (default `3`). At the cap the reviewer concedes:
it comments the standing gap and signs off. A bar can be honestly unbeatable, and an autonomous
fleet has nobody to call the loop off — without a cap one PRD would burn the budget forever and,
in `multi` topology, block every dependent target behind it. A reference that cannot be
provisioned (paywalled, no public build) is treated the same way: comment why, sign off on the
criteria alone. The reviewer never parks a quality gate behind `agent-blocked`.

**Blindness here is prompt discipline, not a sandbox.** The reviewer wrote the side mapping, so it
knows it; only the critic sub-agent is blind, via fresh context plus an explicit instruction not to
read outside the two directories. A determined agent could peek — the same trust model as the rest
of the engine.

Credit: the pattern is Matt Shumer's [Gauntlet Loop](https://github.com/robonuggets/gauntlet-loop).
````

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/test_readme_docs.sh`
Expected: PASS — `── readme docs ok`

Then: `bash test/run.sh`
Expected: whole suite PASS.

- [ ] **Step 5: Commit**

```bash
git add README.md test/test_readme_docs.sh
git commit -m "docs: gauntlet review — config key, opt-in bar, cap and blindness caveat"
```

---

## Ship

- [ ] Open the PR: `gh pr create -R VocanicZ/Harness --fill --head feat/gauntlet-review --base main`
- [ ] Squash-merge when green (`gh pr merge --squash --delete-branch` — this repo forbids `--auto`).
- [ ] `harness update` on each host to ff-pull the shared `~/.harness/engine`. Live fleets keep the old prompts until relaunch; no migration, since existing PRDs carry no `## Quality bar`.

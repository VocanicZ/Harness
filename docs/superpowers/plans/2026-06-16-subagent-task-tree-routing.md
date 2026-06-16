# subagent-task-tree Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the `subagent-task-tree` skill to `VocanicZ/vocanicz-ai-tools` and route Harness implementation workers through it (gated to sizeable issues), installed by both Harness's `install.sh` and the vat Node installer.

**Architecture:** Two repos. (1) `vocanicz-ai-tools` gains a `skills/subagent-task-tree/` dir plus installer logic that copies it into `~/.claude/skills/`. (2) `Harness` gains an `ensure_skills` branch that clones the vat repo and copies the skill, plus a gated prompt line in `impl.md`. Each install path is best-effort and idempotent (skip when the skill already exists).

**Tech Stack:** Bash (Harness `install.sh`, bats-style `test/*.sh` rig), Node.js ESM (`vocanicz-ai-tools` `src/modules/harness.js`, vitest).

---

## File Structure

**vocanicz-ai-tools repo** (cloned separately under a worktree/tmp):
- Create: `skills/subagent-task-tree/SKILL.md`, `.../MANAGER-BRIEF-TEMPLATE.md`, `.../AUDIT-PROMPTS.md` — the published skill (copied verbatim from `~/.claude/skills/subagent-task-tree/`).
- Modify: `src/modules/harness.js` — `setupClaudeIntegration` copies the skill dir recursively into `~/.claude/skills/`, guarded against overwrite; add a small recursive-copy helper.
- Modify: `test/harness.test.js` — assert the copy happens and does not clobber an existing skill.

**Harness repo** (working dir `/home/claude/Harness`):
- Modify: `install.sh` — add `VOCANICZ_TOOLS_URL` var + `ensure_skills` branch that clones vat and copies the skill.
- Modify: `prompts/impl.md` — gated subagent-task-tree wording on the sub-agent line.
- Create: `test/test_vocanicz_skill.sh` — exercises the new `ensure_skills` branch against a local fake vat repo.

The two repos are independent deliverables; the Harness side does not import vat code, it clones it at install time. Order: do the vat publish first (so the skill exists to clone), then Harness.

---

## Task 1: Publish the skill to vocanicz-ai-tools (Component A)

**Files (in a fresh clone of `VocanicZ/vocanicz-ai-tools`):**
- Create: `skills/subagent-task-tree/SKILL.md`
- Create: `skills/subagent-task-tree/MANAGER-BRIEF-TEMPLATE.md`
- Create: `skills/subagent-task-tree/AUDIT-PROMPTS.md`

- [ ] **Step 1: Clone the repo and branch**

```bash
cd /tmp && rm -rf vat-work
gh repo clone VocanicZ/vocanicz-ai-tools vat-work
cd /tmp/vat-work
git checkout -b feat/subagent-task-tree-skill
```

- [ ] **Step 2: Copy the 3 skill files verbatim**

```bash
mkdir -p /tmp/vat-work/skills/subagent-task-tree
cp ~/.claude/skills/subagent-task-tree/SKILL.md \
   ~/.claude/skills/subagent-task-tree/MANAGER-BRIEF-TEMPLATE.md \
   ~/.claude/skills/subagent-task-tree/AUDIT-PROMPTS.md \
   /tmp/vat-work/skills/subagent-task-tree/
```

- [ ] **Step 3: Verify the files are intact**

Run: `diff -rq ~/.claude/skills/subagent-task-tree /tmp/vat-work/skills/subagent-task-tree`
Expected: no output (identical).

- [ ] **Step 4: Commit (do NOT push/PR yet — push after Tasks 2–3 so the PR carries the installer change too)**

```bash
cd /tmp/vat-work
git add skills/subagent-task-tree
git commit -m "feat: add subagent-task-tree skill (audited chained subagent tree)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: vat installer copies the skill (Component B)

**Files (in `/tmp/vat-work`):**
- Modify: `src/modules/harness.js` — `setupClaudeIntegration` (ends ~line 102) + new helper
- Test: `test/harness.test.js`

- [ ] **Step 1: Write the failing test**

Open `test/harness.test.js` and add (adjust the import line to match how the file already imports from `../src/modules/harness.js`):

```js
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { copySkillDirIfAbsent } from '../src/modules/harness.js';

describe('copySkillDirIfAbsent', () => {
  let tmp;
  beforeEach(() => { tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'vat-skill-')); });
  afterEach(() => { fs.rmSync(tmp, { recursive: true, force: true }); });

  it('copies a skill dir recursively into the dest', () => {
    const src = path.join(tmp, 'src-skill');
    fs.mkdirSync(src, { recursive: true });
    fs.writeFileSync(path.join(src, 'SKILL.md'), 'hello');
    const dest = path.join(tmp, 'skills', 'mine');
    copySkillDirIfAbsent(src, dest);
    expect(fs.readFileSync(path.join(dest, 'SKILL.md'), 'utf-8')).toBe('hello');
  });

  it('does NOT overwrite an existing dest skill', () => {
    const src = path.join(tmp, 'src-skill');
    fs.mkdirSync(src, { recursive: true });
    fs.writeFileSync(path.join(src, 'SKILL.md'), 'new');
    const dest = path.join(tmp, 'skills', 'mine');
    fs.mkdirSync(dest, { recursive: true });
    fs.writeFileSync(path.join(dest, 'SKILL.md'), 'original');
    copySkillDirIfAbsent(src, dest);
    expect(fs.readFileSync(path.join(dest, 'SKILL.md'), 'utf-8')).toBe('original');
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /tmp/vat-work && npx vitest run test/harness.test.js`
Expected: FAIL — `copySkillDirIfAbsent` is not exported / not a function.

- [ ] **Step 3: Add the exported helper to `src/modules/harness.js`**

Add near the other helpers (the file already imports `fs`, `path`, `existsSync`, `os` — reuse them; add any missing import):

```js
/**
 * Recursively copy a skill directory into dest, but only if dest does not
 * already exist (never clobber a user's same-named skill). Best-effort.
 */
export function copySkillDirIfAbsent(src, dest) {
  if (!existsSync(src) || existsSync(dest)) return;
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.cpSync(src, dest, { recursive: true });
}
```

- [ ] **Step 4: Wire it into `setupClaudeIntegration`**

At the end of `setupClaudeIntegration` (after the internal-Harness-skills copy block), add — `__dirname` resolves to `src/modules`, so the package's own `skills/` is three levels up:

```js
  // Install the bundled subagent-task-tree skill (does not clobber an existing one)
  try {
    const bundledSkill = path.join(__dirname, '..', '..', 'skills', 'subagent-task-tree');
    copySkillDirIfAbsent(bundledSkill, path.join(skillsDir, 'subagent-task-tree'));
  } catch (err) { /* best effort */ }
```

If `__dirname` is not already defined in this ESM module, add at the top after imports:

```js
import { fileURLToPath } from 'node:url';
const __dirname = path.dirname(fileURLToPath(import.meta.url));
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /tmp/vat-work && npx vitest run test/harness.test.js`
Expected: PASS (both new cases).

- [ ] **Step 6: Run the full vat suite (no regressions)**

Run: `cd /tmp/vat-work && npx vitest run`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
cd /tmp/vat-work
git add src/modules/harness.js test/harness.test.js
git commit -m "feat: vat installer copies subagent-task-tree into ~/.claude/skills

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Push branch and open the PR

- [ ] **Step 1: Push and open the PR**

```bash
cd /tmp/vat-work
git push -u origin feat/subagent-task-tree-skill
gh pr create -R VocanicZ/vocanicz-ai-tools --fill --base master --head feat/subagent-task-tree-skill \
  --title "feat: publish subagent-task-tree skill + installer wiring" \
  --body "Adds skills/subagent-task-tree/ and copies it into ~/.claude/skills during setupClaudeIntegration. Consumed by Harness install.sh (separate PR).

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 2: Record the PR URL** in the final summary. Do not merge unless the user asks.

---

## Task 4: Harness `ensure_skills` clones + copies the skill (Component C)

**Files (in `/home/claude/Harness`):**
- Modify: `install.sh` — add `VOCANICZ_TOOLS_URL` near `MATTPOCOCK_SKILLS_URL` (~line 12); add a copy block inside `ensure_skills` before its `return 0`.
- Test: `test/test_vocanicz_skill.sh`

- [ ] **Step 1: Write the failing test**

Create `test/test_vocanicz_skill.sh` — it builds a fake local "vat repo" git remote containing `skills/subagent-task-tree/SKILL.md`, points `VOCANICZ_TOOLS_URL` at it, runs `ensure_skills`, and asserts the skill landed and an existing same-named skill is preserved:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HARNESS_INSTALL_NOMAIN=1
source "$HERE/../install.sh"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }

# Fake vat remote: a real git repo carrying the skill dir.
SRC="$(mktemp -d)/vat-src"; mkdir -p "$SRC/skills/subagent-task-tree"
printf 'name: subagent-task-tree\n' > "$SRC/skills/subagent-task-tree/SKILL.md"
git -C "$SRC" init -q
git -C "$SRC" -c user.email=t@t -c user.name=t add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm init >/dev/null

# Fresh HOME so ensure_skills writes into an empty ~/.claude/skills.
H="$(mktemp -d)"
# Neutralise the OTHER network installs so this test stays offline & focused:
#   - claude CLI absent -> plugin step is skipped
#   - pre-create to-prd/to-issues -> matt-pocock clone is skipped
mkdir -p "$H/.claude/skills/to-prd" "$H/.claude/skills/to-issues"
HOME="$H" PATH="/usr/bin:/bin" VOCANICZ_TOOLS_URL="$SRC" ensure_skills >/dev/null 2>&1
assert "ensure_skills installs subagent-task-tree" "[[ -f '$H/.claude/skills/subagent-task-tree/SKILL.md' ]]"

# Idempotent / non-clobbering: an existing skill is left untouched.
H2="$(mktemp -d)"
mkdir -p "$H2/.claude/skills/to-prd" "$H2/.claude/skills/to-issues" "$H2/.claude/skills/subagent-task-tree"
printf 'KEEP-ME\n' > "$H2/.claude/skills/subagent-task-tree/SKILL.md"
HOME="$H2" PATH="/usr/bin:/bin" VOCANICZ_TOOLS_URL="$SRC" ensure_skills >/dev/null 2>&1
assert "ensure_skills does not clobber an existing skill" "grep -q KEEP-ME '$H2/.claude/skills/subagent-task-tree/SKILL.md'"

rm -rf "$SRC" "$H" "$H2"
echo "── vocanicz skill ok"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_vocanicz_skill.sh`
Expected: FAIL on the first assert — the skill is not installed (no copy block yet).

- [ ] **Step 3: Add the `VOCANICZ_TOOLS_URL` var**

In `install.sh`, next to the existing `MATTPOCOCK_SKILLS_URL` line (~line 12), add:

```bash
VOCANICZ_TOOLS_URL="${VOCANICZ_TOOLS_URL:-https://github.com/VocanicZ/vocanicz-ai-tools.git}"
```

- [ ] **Step 4: Add the copy block to `ensure_skills`**

In `install.sh`, inside `ensure_skills`, immediately before its final `return 0` (after the matt-pocock block), add — mirrors the matt-pocock find/cp pattern:

```bash
  # vocanicz-ai-tools: the subagent-task-tree skill (best-effort, never clobbers a user skill).
  if [[ -d "$sk/subagent-task-tree" ]]; then
    echo "  ✓ subagent-task-tree skill already present"
  else
    local vtmp; vtmp="$(mktemp -d)"
    if git clone --depth 1 "$VOCANICZ_TOOLS_URL" "$vtmp" >/dev/null 2>&1; then
      local vsrc
      vsrc="$(find "$vtmp" -type f -name SKILL.md -path "*/subagent-task-tree/SKILL.md" 2>/dev/null | head -n1)"
      if [[ -n "$vsrc" ]]; then
        mkdir -p "$sk"; cp -r "$(dirname "$vsrc")" "$sk/" 2>/dev/null \
          && echo "  ✓ installed subagent-task-tree skill into $sk" \
          || echo "  ! could not copy subagent-task-tree skill — install it manually"
      else
        echo "  ! cloned $VOCANICZ_TOOLS_URL but found no subagent-task-tree skill — install manually"
      fi
    else
      echo "  ! could not clone $VOCANICZ_TOOLS_URL — install subagent-task-tree skill manually"
    fi
    rm -rf "$vtmp"
  fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/test_vocanicz_skill.sh`
Expected: `── vocanicz skill ok` and both asserts `ok:`.

- [ ] **Step 6: Run the full Harness suite (no regressions)**

Run: `bash test/run.sh`
Expected: all tests pass (notably `test_install.sh`, `test_subskills.sh`).

- [ ] **Step 7: Commit**

```bash
cd /home/claude/Harness
git add install.sh test/test_vocanicz_skill.sh
git commit -m "feat(install): fetch subagent-task-tree skill from vocanicz-ai-tools

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Gate the impl prompt onto subagent-task-tree (Component D)

**Files (in `/home/claude/Harness`):**
- Modify: `prompts/impl.md:18`
- Test: `test/test_prompt_labels.sh` (add an assert) — confirm framework grep style first.

- [ ] **Step 1: Add a guard assert to a prompt test**

Inspect `test/test_prompt_labels.sh` (or `test/test_bug_flow.sh`) for how it greps rendered/raw prompts, then add an assertion that `prompts/impl.md` references `subagent-task-tree`. If `test_prompt_labels.sh` reads raw `prompts/impl.md`, add:

```bash
assert "impl prompt routes sizeable work through subagent-task-tree" \
  "grep -q 'subagent-task-tree' '$HERE/../prompts/impl.md'"
```

If no existing prompt test reads `impl.md` raw, create `test/test_impl_subagent_skill.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
P="$HERE/../prompts/impl.md"
assert "impl prompt references subagent-task-tree" "grep -q 'subagent-task-tree' '$P'"
assert "impl prompt still gates on issue size"     "grep -qi 'sizeable' '$P'"
echo "── impl subagent skill ok"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test_impl_subagent_skill.sh` (or `bash test/test_prompt_labels.sh`)
Expected: FAIL — `impl.md` does not yet mention `subagent-task-tree`.

- [ ] **Step 3: Edit `prompts/impl.md` line 18**

Replace the current line:

```
   For sizeable work, dispatch parallel sub-agents (`subagent-driven-development`). Stay in THIS repo.
```

with (apply-the-discipline wording, gated):

```
   For sizeable / multi-subtask work, apply the audited `subagent-task-tree` discipline
   (planner → plan-auditor → per-subtask implementer + spec/quality/domain audits → drift-auditor),
   treating this issue's subtasks as the tree's tasks. For small issues, a single implementer +
   review (or `subagent-driven-development`) is fine — just do it. Stay in THIS repo.
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash test/test_impl_subagent_skill.sh`
Expected: `── impl subagent skill ok`.

- [ ] **Step 5: Run the full Harness suite (no regressions)**

Run: `bash test/run.sh`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
cd /home/claude/Harness
git add prompts/impl.md test/test_impl_subagent_skill.sh
git commit -m "feat(prompts): route sizeable impl work through subagent-task-tree (gated)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Open the Harness PR

- [ ] **Step 1: Push a branch and open the PR**

```bash
cd /home/claude/Harness
git checkout -b feat/subagent-task-tree-routing
git push -u origin feat/subagent-task-tree-routing
gh pr create -R VocanicZ/Harness --fill --base main --head feat/subagent-task-tree-routing \
  --title "feat: route impl workers through subagent-task-tree" \
  --body "Installs the subagent-task-tree skill (from vocanicz-ai-tools) and gates sizeable impl work onto it. Design: docs/superpowers/specs/2026-06-16-subagent-task-tree-routing-design.md. Pairs with vocanicz-ai-tools PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Note: this repo forbids `gh pr merge --auto` (memory: repo-automerge-disabled). Do not merge unless the user asks; if they do, use `gh pr merge --squash` once CLEAN.

- [ ] **Step 2: Record both PR URLs in the final summary.**

---

## Self-Review notes
- **Spec coverage:** A→Task 1, B→Task 2, C→Task 4, D→Task 5, E→Tasks 2/4/5; publish-as-PR→Tasks 3/6. All covered.
- **`VOCANICZ_TOOLS_URL`** is used identically in `ensure_skills` (Task 4 Step 3/4) and the test (Task 4 Step 1) — names match.
- **`copySkillDirIfAbsent`** signature `(src, dest)` is consistent between definition (Task 2 Step 3) and call sites (Task 2 Step 1 test, Step 4 wiring).
- **Ordering:** vat publish (Tasks 1–3) precedes Harness clone-consumer (Tasks 4–6) so the skill exists to clone — though Harness tests use a local fake remote and don't depend on the real PR being merged.

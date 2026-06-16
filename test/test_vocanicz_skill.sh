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

# Best-effort: a clone failure must still return 0 (never fail the install).
H3="$(mktemp -d)"
mkdir -p "$H3/.claude/skills/to-prd" "$H3/.claude/skills/to-issues"
HOME="$H3" PATH="/usr/bin:/bin" VOCANICZ_TOOLS_URL="/nonexistent/not-a-repo.git" ensure_skills >/dev/null 2>&1
rc=$?
assert "ensure_skills returns 0 even when clone fails (best-effort)" "[[ $rc -eq 0 ]]"

rm -rf "$SRC" "$H" "$H2" "$H3"
echo "── vocanicz skill ok"

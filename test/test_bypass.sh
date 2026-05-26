#!/usr/bin/env bash
# test_bypass.sh — ensure_bypass defaults the session + its sub-agents to bypassPermissions via
# <wd>/.claude/settings.local.json, merging (not clobbering) any existing rules, keeping it out of
# commits, and staying a no-op for supervised (non-autonomous) launches.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"

TESTS_RUN=0; TESTS_FAIL=0
assert(){
  local name="$1" cmd="$2"
  TESTS_RUN=$((TESTS_RUN+1))
  if eval "$cmd"; then echo "  ok: $name"; else echo "  FAIL: $name"; TESTS_FAIL=$((TESTS_FAIL+1)); fi
}
mode_of(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('permissions',{}).get('defaultMode','(none)'))" "$1" 2>/dev/null; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── A1: fresh worktree → settings.local.json gets defaultMode=bypassPermissions ───────────────
wd="$TMP/fresh"; mkdir -p "$wd"; git -C "$wd" init -q
HARNESS_AUTONOMOUS=true ensure_bypass "$wd"
sl="$wd/.claude/settings.local.json"
assert "A1: settings.local.json created"            "[[ -f '$sl' ]]"
assert "A1: defaultMode == bypassPermissions"       "[[ \"\$(mode_of '$sl')\" == bypassPermissions ]]"
assert "A1: valid JSON"                              "python3 -c 'import json;json.load(open(\"$sl\"))'"
assert "A1: pattern added to worktree info/exclude"  "grep -qxF '.claude/settings.local.json' \"\$(git -C '$wd' rev-parse --git-path info/exclude)\""

# ── A2: existing allow rules are PRESERVED (merge, not clobber) ───────────────────────────────
wd2="$TMP/existing"; mkdir -p "$wd2/.claude"; git -C "$wd2" init -q
cat > "$wd2/.claude/settings.local.json" <<'JSON'
{ "permissions": { "allow": ["Bash(mkdir -p tests_iter)", "Bash(rm -f tests_iter/*)"] }, "statusLine": {"x":1} }
JSON
HARNESS_AUTONOMOUS=true ensure_bypass "$wd2"
sl2="$wd2/.claude/settings.local.json"
assert "A2: defaultMode added"                       "[[ \"\$(mode_of '$sl2')\" == bypassPermissions ]]"
assert "A2: existing allow rule preserved"           "grep -q 'tests_iter' '$sl2'"
assert "A2: unrelated top-level key preserved"       "python3 -c 'import json;assert json.load(open(\"$sl2\")).get(\"statusLine\")=={\"x\":1}'"

# ── A3: idempotent — second run keeps one exclude line, mode still set ─────────────────────────
HARNESS_AUTONOMOUS=true ensure_bypass "$wd"
excl="$(git -C "$wd" rev-parse --git-path info/exclude)"
assert "A3: exclude line not duplicated"             "[[ \$(grep -cxF '.claude/settings.local.json' \"\$excl\") -eq 1 ]]"
assert "A3: mode still bypassPermissions"            "[[ \"\$(mode_of '$sl')\" == bypassPermissions ]]"

# ── A4: supervised (HARNESS_AUTONOMOUS=false) is a no-op ───────────────────────────────────────
wd3="$TMP/supervised"; mkdir -p "$wd3"; git -C "$wd3" init -q
HARNESS_AUTONOMOUS=false ensure_bypass "$wd3"
assert "A4: no settings.local.json written when supervised" "[[ ! -f '$wd3/.claude/settings.local.json' ]]"

echo "── $((TESTS_RUN-TESTS_FAIL))/$TESTS_RUN passed"
[[ $TESTS_FAIL -eq 0 ]]

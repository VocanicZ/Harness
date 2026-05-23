#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../skill/SKILL.md"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert "skill file exists"        "[[ -f '$S' ]]"
assert "has name frontmatter"     "head -5 '$S' | grep -q '^name:'"
assert "has description"          "head -8 '$S' | grep -q '^description:'"
assert "documents start"          "grep -q 'harness start' '$S'"
assert "documents stop"           "grep -q 'harness stop' '$S'"
assert "documents status"         "grep -q 'harness status' '$S'"
echo "── skill ok"

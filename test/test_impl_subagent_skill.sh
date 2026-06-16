#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
P="$HERE/../prompts/impl.md"
assert "impl prompt references subagent-task-tree" "grep -q 'subagent-task-tree' '$P'"
assert "impl prompt still gates on issue size"     "grep -qi 'sizeable' '$P'"
echo "── impl subagent skill ok"

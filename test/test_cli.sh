#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/harness"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert "no args prints usage"        "\"$CLI\" 2>&1 | grep -qi usage"
assert "unknown cmd errors"          "! \"$CLI\" bogus >/dev/null 2>&1"
assert "help lists start/stop/status" "\"$CLI\" help 2>&1 | grep -q start && \"$CLI\" help 2>&1 | grep -q status"
assert "help lists pause"  "\"$CLI\" help 2>&1 | grep -q pause"
assert "help lists resume" "\"$CLI\" help 2>&1 | grep -q resume"
assert "help lists update" "\"$CLI\" help 2>&1 | grep -q update"
assert "help lists setup"  "\"$CLI\" help 2>&1 | grep -q setup"
assert "help lists plan"   "\"$CLI\" help 2>&1 | grep -q plan"
assert "help lists prd"    "\"$CLI\" help 2>&1 | grep -q prd"
assert "help lists issue"  "\"$CLI\" help 2>&1 | grep -q issue"
assert "help lists migrate" "\"$CLI\" help 2>&1 | grep -q migrate"
assert "help lists uninstall" "\"$CLI\" help 2>&1 | grep -q uninstall"
echo "── cli ok"

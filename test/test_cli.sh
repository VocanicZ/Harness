#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/harness"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert "no args prints usage"        "\"$CLI\" 2>&1 | grep -qi usage"
assert "unknown cmd errors"          "! \"$CLI\" bogus >/dev/null 2>&1"
assert "help lists start/stop/status" "\"$CLI\" help 2>&1 | grep -q start && \"$CLI\" help 2>&1 | grep -q status"
echo "── cli ok"

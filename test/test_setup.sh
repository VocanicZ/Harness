#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLS="$(mktemp)"; : > "$CALLS"; export CALLS
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

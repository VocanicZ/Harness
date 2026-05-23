#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HARNESS_INSTALL_NOMAIN=1
source "$HERE/../install.sh"
# PATH stubs to simulate tool presence; check_prereqs uses real `command -v` + `gh auth status`
PATHBIN="$(mktemp -d)"; export PATH="$PATHBIN:$PATH"
for t in git tmux python3 gh claude; do printf '#!/bin/sh\nexit 0\n' > "$PATHBIN/$t"; chmod +x "$PATHBIN/$t"; done
printf '#!/bin/sh\ncase "$1" in auth) exit 0;; version) exit 0;; esac\nexit 0\n' > "$PATHBIN/gh"; chmod +x "$PATHBIN/gh"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert "prereqs pass when all present" "check_prereqs"
# remove claude -> fail
rm -f "$PATHBIN/claude"
assert "prereqs fail without claude"   "! check_prereqs 2>/dev/null"
printf '#!/bin/sh\nexit 0\n' > "$PATHBIN/claude"; chmod +x "$PATHBIN/claude"
# unauthenticated gh -> fail
printf '#!/bin/sh\ncase "$1" in auth) exit 1;; esac\nexit 0\n' > "$PATHBIN/gh"; chmod +x "$PATHBIN/gh"
assert "prereqs fail when gh not authed" "! check_prereqs 2>/dev/null"
echo "── install ok"

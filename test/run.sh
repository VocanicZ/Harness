#!/usr/bin/env bash
# run.sh — run every test_*.sh in this dir; non-zero exit if any fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# Blanket hermeticity guard. lib.sh takes STATE_DIR from the environment, and a pool worker exports
# its project's STATE_DIR to every child — so running this suite from inside a live agent session
# used to point every test's CONFIG / WORKTREES_DIR / CHECKOUTS_DIR at a REAL project's .harness/.
# Hand each test its own throwaway one BEFORE it can source lib.sh. Individual tests re-pin too
# (helpers.sh make_env) so a direct `bash test_foo.sh` is safe as well; test_hermetic.sh guards both.
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
rc=0
for t in test_*.sh test_*.py; do
  [[ -e "$t" ]] || continue
  echo "== $t =="
  export STATE_DIR="$TMPROOT/$t/.harness"
  mkdir -p "$STATE_DIR/worktrees" "$STATE_DIR/checkouts" "$STATE_DIR/run/claims"
  case "$t" in *.py) python3 "$t" || rc=1;; *) bash "$t" || rc=1;; esac
done
exit $rc

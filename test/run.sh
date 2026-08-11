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
# Same blanket guard, second seam: config lines are `: "${VAR:=…}"`, so an inherited HARNESS_* from
# the live fleet running this suite BEATS the fixture's own value. Pinning paths was not enough —
# drop the config vars too, before any test can read them. (helpers.sh only defines functions at
# top level, so sourcing it here has no other effect. Tests re-drop them via make_env.)
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
unset_inherited_config
rc=0
for t in test_*.sh test_*.py; do
  [[ -e "$t" ]] || continue
  echo "== $t =="
  export STATE_DIR="$TMPROOT/$t/.harness"
  mkdir -p "$STATE_DIR/worktrees" "$STATE_DIR/checkouts" "$STATE_DIR/run/claims"
  # Host root too (lib.sh:86): it is NOT derived from STATE_DIR, and its poller registry is SHARED by
  # every co-resident fleet — a fixture entry left there aborts a real `harness start` on a bogus
  # prefix collision. Give each test its own host root as well.
  # All three: lib.sh:87-88 prefer an INHERITED HARNESS_POLLER_DIR / HARNESS_SNAPSHOTS_DIR over the
  # HARNESS_HOME a test sets for itself, and :89 exports them from every fleet process — so pinning
  # HARNESS_HOME alone leaves a test's own isolation defeated.
  export HARNESS_HOME="$TMPROOT/$t/host"
  export HARNESS_POLLER_DIR="$HARNESS_HOME/poller" HARNESS_SNAPSHOTS_DIR="$HARNESS_HOME/snapshots"
  mkdir -p "$HARNESS_POLLER_DIR/registry" "$HARNESS_SNAPSHOTS_DIR"
  case "$t" in *.py) python3 "$t" || rc=1;; *) bash "$t" || rc=1;; esac
done
exit $rc

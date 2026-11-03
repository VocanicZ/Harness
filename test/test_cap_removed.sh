#!/usr/bin/env bash
# test_cap_removed.sh — #469 (PRD #464 §2): CAP is gone; HARNESS_POOL is the only parallelism knob.
#   - no HARNESS_CAP / lane-CAP reference is left in scripts/ except the migration code,
#   - prompts/review.md's gauntlet/security round CAP is untouched,
#   - POOL defaults to 3 and a stray HARNESS_CAP changes nothing,
#   - `harness init` no longer asks for or writes a CAP, and `status` no longer prints one.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
export RUN_DIR="$(mktemp -d)"; tmp_track "$RUN_DIR"

echo "-- no lane-CAP reference left in scripts/ outside the migration code"
left="$(cd "$ROOT/scripts" && grep -rnE 'HARNESS_CAP|\$CAP\b|\$\{CAP\b|\bCAP=|cap=\$|\bcap \$' . \
        | grep -vE '^\./(fleet-migrate\.sh|fleet_migrate\.py):' )"
assert_eq "$left" "" "scripts/ outside fleet-migrate.sh / fleet_migrate.py mentions neither HARNESS_CAP nor \$CAP"
assert_ok "the migration code still names HARNESS_CAP (it drops the line)" grep -q 'HARNESS_CAP' "$ROOT/scripts/fleet_migrate.py"
assert_ok "prompts/review.md keeps the security-audit round cap" grep -q '^S1\. CAP\.' "$ROOT/prompts/review.md"
assert_ok "prompts/review.md keeps the gauntlet round cap"      grep -q '^5a\. CAP\.' "$ROOT/prompts/review.md"

echo "-- POOL defaults to 3; CAP does not leak in"
( unset HARNESS_POOL; source "$ROOT/scripts/lib.sh"
  assert_eq "$HARNESS_POOL" "3" "HARNESS_POOL defaults to 3"
  assert_eq "$POOL"         "3" "POOL mirrors it"
  assert_eq "${CAP-unset}"  "unset" "lib.sh defines no CAP"
  assert_eq "${HARNESS_CAP-unset}" "unset" "...and no HARNESS_CAP default"
  finish ) || exit 1
( HARNESS_CAP=5 HARNESS_POOL=2; source "$ROOT/scripts/lib.sh"
  assert_eq "$POOL" "2" "HARNESS_CAP=5 in the environment does not change POOL"
  assert_eq "${CAP-unset}" "unset" "...and defines no CAP"
  finish ) || exit 1

echo "-- init: no CAP prompt, none written"
W="$(mktemp -d)"; tmp_track "$W"
( cd "$W" && git init -q . 2>/dev/null; STATE_DIR="$W/.harness" HARNESS_INIT_SEED=0 HARNESS_REPO=acme/w HARNESS_MODE=issue-only \
    bash "$ROOT/scripts/init.sh" >/dev/null 2>&1 < /dev/null )
if [[ -f "$W/.harness/config" ]]; then
  assert_no "init writes no HARNESS_CAP line" grep -q HARNESS_CAP "$W/.harness/config"
  assert_ok "init writes the POOL line"        grep -q 'HARNESS_POOL' "$W/.harness/config"
else
  assert_no "init source asks for no CAP" grep -q 'HARNESS_CAP' "$ROOT/scripts/init.sh"
fi

finish

#!/usr/bin/env bash
# test_pool_bugs.sh — #214: a pool worker takes the oldest open bug of its unit's repo while the priority
# lane is busy. The two lanes share one claim file per bug, so a bug either lane holds is never offered
# to the other. (The pool-taken bug's session tending is test_pool_lanes.sh's: bug_lane_tend / reap_ownerless_pool_bugs.)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
make_env
HARNESS_REPO="acme/widget"; SLUG="acme/widget"; UNIT=main
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
claim_of(){ cat "$CLAIMS_DIR/bug-acme_widget-$1.claim" 2>/dev/null; }

echo "-- claims: either lane's hold keeps the bug from the other"
printf 'P1 %s acme/widget#30\n' "$$" > "$CLAIMS_DIR/bug-acme_widget-30.claim"   # the lane holds #30
assert_no "pool cannot claim a bug the lane holds" claim_bug pool-main "acme/widget#30"
assert_eq "$(awk '{print $1}' <<<"$(claim_of 30)")" "P1" "the lane's claim is untouched"
assert_ok "pool claims a free bug" claim_bug pool-main "acme/widget#31"
assert_eq "$(claim_of 31)" "pool-main $$ acme/widget#31" "pool claim names its unit, pid and ref"
_bug_numbers(){ printf 'acme/widget#30\nacme/widget#31\nacme/widget#32\n'; }
assert_eq "$(claimable_bugs | tr '\n' ' ')" "acme/widget#32 " "the lane is never offered a bug the pool holds"
assert_no "a second pool claim on the same bug is refused" claim_bug pool-other "acme/widget#31"
assert_eq "$(lane_bug)" "acme/widget#30" "lane_bug reports the lane's bug, not the pool's"
assert_eq "$(pool_bug_claims main | cut -f2)" "acme/widget#31" "pool_bug_claims lists the unit's pool claims"
assert_eq "$(pool_bug_claims other)" "" "...and only that unit's"
rm -f "$CLAIMS_DIR"/bug-*.claim

echo "-- priority_free_slots"
assert_eq "$(priority_free_slots)" "0" "no lane running → no free priority slot (the pool takes the bugs)"
echo "$$" > "$RUN_DIR/priority.pid"
assert_eq "$(priority_free_slots)" "1" "lane up and idle → one free slot"
printf 'pool-main %s acme/widget#31\n' "$$" > "$CLAIMS_DIR/bug-acme_widget-31.claim"
assert_eq "$(priority_free_slots)" "1" "a pool-held bug does not occupy the lane"
printf 'P1 %s acme/widget#30\n' "$$" > "$CLAIMS_DIR/bug-acme_widget-30.claim"
assert_eq "$(priority_free_slots)" "0" "lane holding a bug → busy"
rm -f "$CLAIMS_DIR"/bug-*.claim "$RUN_DIR/priority.pid"

echo "-- dispatch_actions passes --priority-free only when HARNESS_POOL_TAKES_BUGS=1"
STUB="$RUN_DIR/issuelib-stub.py"; printf 'import sys; print(" ".join(sys.argv[1:]))\n' > "$STUB"
REAL_ISSUELIB="$ISSUELIB"; ISSUELIB="$STUB"
HARNESS_POOL_TAKES_BUGS=1
assert_eq "$(dispatch_actions acme/widget 2 1 '')" \
  "dispatch acme/widget 2 --allow-orchestration 1 --busy-prds  --priority-free 0" "knob on → lane's free slots passed"
HARNESS_POOL_TAKES_BUGS=0
assert_eq "$(dispatch_actions acme/widget 2 1 '')" \
  "dispatch acme/widget 2 --allow-orchestration 1 --busy-prds " "knob off → bugs stay on the lane"
HARNESS_POOL_TAKES_BUGS=1; ISSUELIB="$REAL_ISSUELIB"

finish

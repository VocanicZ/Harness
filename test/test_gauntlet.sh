#!/usr/bin/env bash
# test_gauntlet.sh — gauntlet review: round counting (lib.sh) + spawn_orch render vars (drive.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/helpers.sh"
make_env

SLUG=acme/widget

echo "=== gauntlet_round ==="
# gauntlet_round reads a COUNT from `gh ... -q '... | length'`, so the stub returns the count.
gh(){ echo 0; }
assert_eq "$(gauntlet_round 7)" "1" "no markers -> round 1"

gh(){ echo 2; }
assert_eq "$(gauntlet_round 7)" "3" "two markers -> round 3"

gh(){ return 1; }
assert_eq "$(gauntlet_round 7)" "1" "gh failure -> round 1 (a transient error never fakes a concede)"

gh(){ echo "warning: template ignored"; }
assert_eq "$(gauntlet_round 7)" "1" "non-numeric gh output -> round 1"

finish

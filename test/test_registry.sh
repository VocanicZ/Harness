#!/usr/bin/env bash
# test_registry.sh — the fleet's unit registry is one repo (PRD #464, #473): one unit, named HARNESS_UNIT
# (default `main`), on HARNESS_REPO. There is no targets.tsv and no HARNESS_TOPOLOGY any more.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env

HARNESS_REPO="acme/widget"; HARNESS_UNIT=""
assert_eq "$(all_units | tr '\n' ' ')" "main " "one unit 'main' by default"
assert_eq "$(unit_repo main)" "acme/widget" "unit_repo = HARNESS_REPO"
assert_eq "$(unit_slug main)" "acme/widget" "slug = repo (already owner/repo)"
assert_eq "$(unit_checkout main)" "$PROJECT_ROOT" "checkout defaults to PROJECT_ROOT"
HARNESS_UNIT=core
assert_eq "$(all_units | tr '\n' ' ')" "core " "HARNESS_UNIT names the one unit"

# a bare repo name gets the owner prefix
HARNESS_REPO="widget"; HARNESS_OWNER=acme
assert_eq "$(unit_slug main)" "acme/widget" "bare repo name -> owner/repo"

# the multi-repo machinery is gone: a leftover targets.tsv / topology key is not read
assert_no "unit_deps is gone"      declare -F unit_deps
assert_no "deps_complete is gone"  declare -F deps_complete
assert_no "_tgt_field is gone"     declare -F _tgt_field
assert_no "ensure_checkout is gone" declare -F ensure_checkout
finish

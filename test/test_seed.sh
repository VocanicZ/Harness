#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"; make_env
HARNESS_LABEL_READY=go HARNESS_LABEL_PRD=spec HARNESS_LABEL_PAUSED=zzz   # custom names
HARNESS_LABEL_BUG=buglbl HARNESS_LABEL_BUG_TRIAGED=trgd                  # bug-lane labels
CALLS="$RUN_DIR/gh.calls"; : > "$CALLS"
gh(){ echo "$*" >> "$CALLS"
  case "$1 $2" in "repo view") return 0;; "label create") return 0;; "api") return 0;; esac; return 0; }
export -f gh
SLUG="acme/widget"
source "$HERE/../scripts/seed.sh" --labels-only "$SLUG"   # a label-only entrypoint for the test
assert_ok "created custom ready label" bash -c "grep -q 'label create go' '$CALLS'"
assert_ok "created custom prd label"   bash -c "grep -q 'label create spec' '$CALLS'"
assert_ok "created custom paused label" bash -c "grep -q 'label create zzz' '$CALLS'"
assert_ok "created bug label"          bash -c "grep -q 'label create buglbl' '$CALLS'"
assert_ok "created bug-triaged label"  bash -c "grep -q 'label create trgd' '$CALLS'"

echo "=== full bootstrap: the CI workflow is OPT-IN (HARNESS_SEED_CI, default 0) ==="
# Absent ci.yml (the contents GET fails) so the only thing deciding whether it is written is the flag.
gh(){ echo "$*" >> "$CALLS"
  case "$*" in *"contents/.github/workflows/ci.yml"*"--method PUT"*|*"--method PUT"*"contents/.github/workflows/ci.yml"*) return 0;;
               *"contents/.github/workflows/ci.yml"*) return 1;; esac; return 0; }
HARNESS_TOPOLOGY=single; HARNESS_REPO=acme/widget
: > "$CALLS"; ( unset HARNESS_SEED_CI; source "$HERE/../scripts/seed.sh" main ) >/dev/null 2>&1
assert_no "default: no ci.yml committed to the target repo" grep -q -- "--method PUT repos/acme/widget/contents/.github/workflows/ci.yml" "$CALLS"
assert_no "default: no branch protection requiring a CI check that will never report" grep -q "branches/main/protection" "$CALLS"
assert_ok "default: auto-merge still enabled" grep -q "allow_auto_merge=true" "$CALLS"
: > "$CALLS"; ( HARNESS_SEED_CI=1; source "$HERE/../scripts/seed.sh" main ) >/dev/null 2>&1
assert_ok "HARNESS_SEED_CI=1: ci.yml committed" grep -q -- "--method PUT repos/acme/widget/contents/.github/workflows/ci.yml" "$CALLS"
assert_ok "HARNESS_SEED_CI=1: branch protection requires the test check" grep -q "branches/main/protection" "$CALLS"
assert_eq "$(env -u HARNESS_SEED_CI bash -c "source '$HERE/../scripts/lib.sh'; echo \$HARNESS_SEED_CI")" "0" "HARNESS_SEED_CI defaults to 0"

echo "=== #245: seeding disables the repo's existing test-CI workflows (HARNESS_DISABLE_CI, default 1) ==="
# The stub stands in for `gh api .../actions/workflows --jq …@tsv` (rows already jq-shaped) and logs
# every `gh workflow disable`. Fixture: two test-CI workflows, a release one, a deploy one, one already
# disabled, and a GitHub-managed dynamic one that `gh workflow disable` cannot touch.
gh(){ echo "$*" >> "$CALLS"
  case "$*" in
    *"actions/workflows"*) printf '%s\t%s\t%s\t%s\n' \
        11 active .github/workflows/ci.yml ci \
        12 active .github/workflows/submodule-pin-guard.yml "submodule pin guard" \
        13 active .github/workflows/release.yml "Release" \
        14 active .github/workflows/pages.yml "Deploy docs" \
        15 disabled_manually .github/workflows/old.yml old \
        16 active dynamic/dependabot/dependabot-updates "Dependabot Updates";;
  esac; return 0; }
LOGS="$RUN_DIR/seed.log"
disabled(){ grep -q "^workflow disable $1 -R acme/widget" "$CALLS"; }
: > "$CALLS"; ( unset HARNESS_DISABLE_CI HARNESS_SEED_CI; source "$HERE/../scripts/seed.sh" main ) >"$LOGS" 2>&1
assert_ok "default: test-CI ci.yml disabled"                disabled 11
assert_ok "default: any non-release check disabled too"     disabled 12
assert_no "default: release workflow left alone"            disabled 13
assert_no "default: deploy workflow left alone"             disabled 14
assert_no "default: an already-disabled workflow is not re-disabled" disabled 15
assert_no "default: GitHub-managed dynamic workflow skipped" disabled 16
assert_ok "default: logs which workflow it disabled"        grep -q "disabled GitHub CI workflow on acme/widget: ci.yml" "$LOGS"
assert_ok "default: logs the release/deploy it kept"        grep -q "left release/deploy workflows on acme/widget running: release.yml pages.yml" "$LOGS"
: > "$CALLS"; ( HARNESS_DISABLE_CI=all; unset HARNESS_SEED_CI; source "$HERE/../scripts/seed.sh" main ) >/dev/null 2>&1
assert_ok "HARNESS_DISABLE_CI=all: release disabled too"    disabled 13
assert_ok "HARNESS_DISABLE_CI=all: deploy disabled too"     disabled 14
: > "$CALLS"; ( HARNESS_DISABLE_CI=0; unset HARNESS_SEED_CI; source "$HERE/../scripts/seed.sh" main ) >/dev/null 2>&1
assert_no "HARNESS_DISABLE_CI=0: opt-out touches no workflow" grep -q "workflow disable" "$CALLS"
: > "$CALLS"; ( unset HARNESS_DISABLE_CI; HARNESS_SEED_CI=1; source "$HERE/../scripts/seed.sh" main ) >/dev/null 2>&1
assert_no "HARNESS_SEED_CI=1 (explicit CI opt-in) disables nothing" grep -q "workflow disable" "$CALLS"
# harness init / setup on a single-topology repo reach it through the --disable-ci fast path.
: > "$CALLS"; ( unset HARNESS_DISABLE_CI HARNESS_SEED_CI; source "$HERE/../scripts/seed.sh" --disable-ci acme/widget ) >/dev/null 2>&1
assert_ok "--disable-ci <slug>: disables test CI"           disabled 11
assert_no "--disable-ci <slug>: creates no labels"          grep -q "label create" "$CALLS"
gh(){ echo "$*" >> "$CALLS"; case "$*" in *"actions/workflows"*) return 1;; esac; return 0; }
: > "$CALLS"; ( unset HARNESS_DISABLE_CI HARNESS_SEED_CI; source "$HERE/../scripts/seed.sh" --disable-ci acme/widget ) >"$LOGS" 2>&1
assert_ok "listing fails: warns and disables nothing" grep -q "could not list acme/widget's workflows" "$LOGS"
assert_eq "$(env -u HARNESS_DISABLE_CI bash -c "source '$HERE/../scripts/lib.sh'; echo \$HARNESS_DISABLE_CI")" "1" "HARNESS_DISABLE_CI defaults to 1"
# harness init and setup both seed through seed_if_needed; on a single-topology repo that must reach
# the workflow-disable step too, not just the labels.
gh(){ echo "$*" >> "$CALLS"
  case "$*" in *"actions/workflows"*) printf '11\tactive\t.github/workflows/ci.yml\tci\n';; esac; return 0; }
export -f gh; export CALLS   # seed_if_needed runs seed.sh as a child process
: > "$CALLS"; ( unset HARNESS_DISABLE_CI HARNESS_SEED_CI; seed_if_needed main ) >/dev/null 2>&1
assert_ok "seed_if_needed (harness init/setup, single topology) disables test CI" disabled 11
assert_ok "seed_if_needed (single topology) still seeds labels" grep -q "label create go" "$CALLS"
finish

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
finish

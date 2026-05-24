#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/helpers.sh"; make_env
HARNESS_LABEL_READY=go HARNESS_LABEL_PRD=spec HARNESS_LABEL_PAUSED=zzz   # custom names
HARNESS_LABEL_BUG=buglbl HARNESS_LABEL_BUG_TRIAGED=trgd                  # bug-lane labels
CALLS="$RUN_DIR/gh.calls"; : > "$CALLS"
gh(){ echo "$*" >> "$CALLS"
  case "$1 $2" in "repo view") return 0;; "label create") return 0;; "api") return 0;; esac; return 0; }
export -f gh
SLUG="acme/widget"
source "$HERE/../seed.sh" --labels-only "$SLUG"   # a label-only entrypoint for the test
assert_ok "created custom ready label" bash -c "grep -q 'label create go' '$CALLS'"
assert_ok "created custom prd label"   bash -c "grep -q 'label create spec' '$CALLS'"
assert_ok "created custom paused label" bash -c "grep -q 'label create zzz' '$CALLS'"
assert_ok "created bug label"          bash -c "grep -q 'label create buglbl' '$CALLS'"
assert_ok "created bug-triaged label"  bash -c "grep -q 'label create trgd' '$CALLS'"
finish

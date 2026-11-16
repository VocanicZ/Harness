#!/usr/bin/env bash
# test_status_orphaned.sh — #1233: harness status lists an open PR with no linked open issue and no live lane as `orphaned`.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUN_DIR="$(mktemp -d)"; trap 'rm -rf "$RUN_DIR"' EXIT
source "$HERE/../scripts/status.sh"
# --- #1233: an open PR with no linked open issue and no live lane is listed `orphaned` ---
# #1103 (a review's suite-log PR) sat open 4 days because nothing owned it. pr_orphan_lines is pure (canned JSON in).
PRS='[{"number":1103,"title":"docs: review round 1 logs","headRefName":"review/prd-475-r1","closingIssuesReferences":[]},
      {"number":50,"title":"feat: x","headRefName":"issue/7","closingIssuesReferences":[]},
      {"number":51,"title":"feat: y","headRefName":"issue/8","closingIssuesReferences":[{"number":9}]},
      {"number":52,"title":"feat: z","headRefName":"issue/10","closingIssuesReferences":[]},
      {"number":53,"title":"feat: w","headRefName":"bug/other","closingIssuesReferences":[{"number":4}]}]'
OPEN='[{"number":7},{"number":9},{"number":11}]'
po="$(pr_orphan_lines acme/widget "$PRS" "$OPEN" "hz-acme_widget-i10")"
echo "$po" | grep '#1103' | grep -q 'orphaned' && echo "  ok: PR with no issue and no lane -> orphaned" || { echo "  FAIL: #1103 not orphaned — got [$po]"; exit 1; }
echo "$po" | grep '#50 ' | grep -q 'orphaned' && { echo "  FAIL: branch issue/7 names an open issue — got [$po]"; exit 1; } || echo "  ok: branch names an open issue -> not orphaned"
echo "$po" | grep '#51 ' | grep -q 'orphaned' && { echo "  FAIL: closes open #9 — got [$po]"; exit 1; } || echo "  ok: closes an open issue -> not orphaned"
echo "$po" | grep '#52 ' | grep -q 'orphaned' && { echo "  FAIL: live lane on i10 — got [$po]"; exit 1; } || echo "  ok: closed issue but live lane -> not orphaned"
echo "$po" | grep '#53 ' | grep -q 'orphaned' && echo "  ok: closes only a closed issue, no lane -> orphaned" || { echo "  FAIL: #53 should be orphaned — got [$po]"; exit 1; }
pu="$(pr_orphan_lines acme/widget "$PRS" "" "")"
echo "$pu" | grep -q 'orphaned' && { echo "  FAIL: unknown issue list must mark nothing — got [$pu]"; exit 1; } || echo "  ok: gh could not list issues -> nothing marked orphaned"
echo "── status orphaned PRs ok"

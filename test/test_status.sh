#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUN_DIR="$(mktemp -d)"
out="$(HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget bash "$HERE/../status.sh" 2>&1 || true)"
echo "$out" | grep -qiE "worker" && echo "  ok: status mentions workers" || { echo "  FAIL"; exit 1; }
echo "── status smoke ok"

# paused state renders "PAUSED": create the flag in the SAME RUN_DIR the status run uses
mkdir -p "$RUN_DIR"; touch "$RUN_DIR/PAUSED"
out3="$(HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget RUN_DIR="$RUN_DIR" bash "$HERE/../status.sh" 2>&1 || true)"
echo "$out3" | grep -qi paused && echo "  ok: status shows PAUSED when flag set" || { echo "  FAIL: no PAUSED"; exit 1; }

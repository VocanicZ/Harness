#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUN_DIR="$(mktemp -d)"
out="$(HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget bash "$HERE/../status.sh" 2>&1 || true)"
echo "$out" | grep -qiE "worker" && echo "  ok: status mentions workers" || { echo "  FAIL"; exit 1; }
echo "── status smoke ok"

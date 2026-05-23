#!/usr/bin/env bash
# run.sh — run every test_*.sh in this dir; non-zero exit if any fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
rc=0
for t in test_*.sh; do
  echo "== $t =="
  bash "$t" || rc=1
done
exit $rc

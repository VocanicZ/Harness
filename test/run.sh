#!/usr/bin/env bash
# run.sh — run every test_*.sh in this dir; non-zero exit if any fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
rc=0
for t in test_*.sh test_*.py; do
  [[ -e "$t" ]] || continue
  echo "== $t =="
  case "$t" in *.py) python3 "$t" || rc=1;; *) bash "$t" || rc=1;; esac
done
exit $rc

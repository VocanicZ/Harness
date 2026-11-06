#!/usr/bin/env bash
# windows-relevant.sh [path...] — #494 (PRD #475, Solution 8): does a diff touch code whose behaviour differs on Windows?
# Paths come from the arguments, else one per line from stdin (`git diff --name-only origin/main...HEAD | windows-relevant.sh`).
# Exit 0 = at least one path is Windows-relevant (the lane runs its rtdd rounds on HARNESS_WINDOWS_HOST too); 1 = none.
# Prints the matching paths. The list is the one in docs/reference.md "Windows host checks".
set -uo pipefail
windows_relevant_path(){ case "${1#./}" in
  scripts/portable.*|install.sh|update.sh|scripts/uninstall.sh|scripts/doctor.sh|scripts/session/headless.sh) return 0;;
  scripts/cli/*|scripts/supervise.sh|scripts/web.sh|scripts/attach.sh|test/smoke/winsma/*) return 0;;
  *) return 1;; esac; }
main(){ local p hit=1 paths=()
  if (( $# )); then paths=("$@"); else while IFS= read -r p || [[ -n "$p" ]]; do paths+=("$p"); done; fi
  for p in ${paths[@]+"${paths[@]}"}; do [[ -n "$p" ]] && windows_relevant_path "$p" && { printf '%s\n' "$p"; hit=0; }; done
  return $hit; }
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"

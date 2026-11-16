#!/usr/bin/env bash
# rtdd: always
# test_static_skip_lints.sh — #1229: the repo-wide STATIC scan of the suite's skips, alone. It lived in test_windows_skip.sh, a file a
# lane's rtdd rounds never select for a change that only ADDS a call to a test file: #1223 (#1110) called the helper #1149 (#1117) had
# removed, and the release gate at 2b0ed48 was the first run to see the red. The only input is the repo tree (one grep per file set),
# so the file is in the always-run guard set (test/guards.sh). What stays in test_windows_skip.sh is the behaviour: windows_skip,
# posix_branch_off_windows, the fixture matrices.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config

# no test prints the old nameless SKIP, and the old helper name is gone (#1117). test_windows_skip.sh names both in its own comments
# and cells; this file names them in the scan below.
leaks="$(grep -lE 'POSIX branch, no counterpart|skip_posix_branch' "$HERE"/test_*.sh "$HERE"/test_*.py "$HERE/helpers.sh" 2>/dev/null |
  grep -vE '/test_windows_skip\.sh$|/test_static_skip_lints\.sh$')"
assert_eq "$leaks" "" "no test prints a SKIP that names no n/a matrix row for a POSIX branch, or calls the removed skip_posix_branch (#1117, #1229)"
assert_no "test_portable.py prints no SKIP for a POSIX branch" grep -qE 'print\(" +SKIP' "$HERE/test_portable.py"
finish

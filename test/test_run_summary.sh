#!/usr/bin/env bash
# test_run_summary.sh — #492 / PRD #475 Solution 6: test/run.sh ends with a per-failure summary and honours
# HARNESS_TEST_TIMEOUT, so a long run on a Windows host reads in one place and a hung test cannot stall it.
# Runs a copy of run.sh over a directory of three fake tests: one passes, one fails, one hangs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
command -v timeout >/dev/null 2>&1 || { echo "  skip: no timeout(1) on this host"; finish; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/suite"; cp "$HERE/run.sh" "$HERE/helpers.sh" "$T/suite/"; cp -r "$HERE/guard" "$T/suite/guard"
printf '#!/usr/bin/env bash\necho in-a\nexit 0\n' >"$T/suite/test_a_pass.sh"
printf '#!/usr/bin/env bash\necho in-b\nexit 1\n'  >"$T/suite/test_b_fail.sh"
printf '#!/usr/bin/env bash\necho in-c\nsleep 60\n' >"$T/suite/test_c_hang.sh"
printf 'import sys\nprint("in-d")\nsys.exit(0)\n'   >"$T/suite/test_d_pass.py"

# with a cap: the hang is ended, every test still runs, the summary names exactly the two red ones
out="$(HARNESS_TEST_TIMEOUT=2 bash "$T/suite/run.sh" 2>&1)"; rc=$?
assert_ok "run.sh exits non-zero when a test fails or times out" test "$rc" -ne 0
for n in a_pass b_fail c_hang; do assert_ok "ran test_$n.sh" grep -qF "== test_$n.sh ==" <<<"$out"; done
assert_ok "ran the .py test too" grep -qF "== test_d_pass.py ==" <<<"$out"
assert_ok "the hang is reported as a TIMEOUT" grep -qF "TIMEOUT: test_c_hang.sh ran past HARNESS_TEST_TIMEOUT=2s" <<<"$out"
assert_ok "the summary counts passes" grep -qxF "== run.sh: 2/4 test files passed ==" <<<"$out"
assert_ok "the summary names the failing test" grep -qxF "FAILED: test_b_fail.sh" <<<"$out"
assert_ok "… and the timed-out one" grep -qxF "FAILED: test_c_hang.sh" <<<"$out"
assert_no "… and no passing one" grep -qE "^FAILED: test_(a_pass|d_pass)" <<<"$out"

# without a cap (the default): a suite of passing tests is green and says so
rm -f "$T/suite/test_b_fail.sh" "$T/suite/test_c_hang.sh"
out="$(bash "$T/suite/run.sh" 2>&1)"; rc=$?
assert_eq "$rc" "0" "an all-green suite exits 0"
assert_ok "… and the summary says 2/2" grep -qxF "== run.sh: 2/2 test files passed ==" <<<"$out"
assert_no "… with no FAILED line" grep -q "^FAILED:" <<<"$out"
assert_no "… and no cap by default (no TIMEOUT)" grep -q "TIMEOUT" <<<"$out"
out="$(HARNESS_TEST_TIMEOUT=abc bash "$T/suite/run.sh" 2>&1)"; rc=$?
assert_eq "$rc" "0" "a non-numeric HARNESS_TEST_TIMEOUT is ignored, not an error"

# Named files (#493: the winsma run of the headless twins): `run.sh <test>…` runs just those, under the same summary; a name
# that is no file is a failure of its own, never a silent skip.
printf '#!/usr/bin/env bash\necho in-b\nexit 1\n' >"$T/suite/test_b_fail.sh"
out="$(bash "$T/suite/run.sh" test_a_pass.sh test_d_pass.py 2>&1)"; rc=$?
assert_eq "$rc" "0" "run.sh with two named passing tests exits 0"
assert_ok "… and runs exactly those: 2/2" grep -qxF "== run.sh: 2/2 test files passed ==" <<<"$out"
assert_no "… without the other tests" grep -qF "== test_b_fail.sh ==" <<<"$out"
out="$(bash "$T/suite/run.sh" test_a_pass.sh test_b_fail.sh test_missing.sh 2>&1)"; rc=$?
assert_ok "a named failing test and a named missing one both fail the run" test "$rc" -ne 0
assert_ok "… the missing one is named" grep -qxF "FAILED: test_missing.sh" <<<"$out"
assert_ok "… with the reason" grep -qF "FAIL: test_missing.sh: no such test file" <<<"$out"
assert_ok "… and the count is 1/3" grep -qxF "== run.sh: 1/3 test files passed ==" <<<"$out"

# A file may lengthen its own cap on a Windows host (`# harness-test-timeout-windows: N`, #607): a fork-heavy test that is slow
# under Git Bash is not a hang. Forced here; on a posix host the marker is ignored, and without a cap there is no cap at all.
mkdir -p "$T/cap-suite"; cp "$HERE/run.sh" "$HERE/helpers.sh" "$T/cap-suite/"; cp -r "$HERE/guard" "$T/cap-suite/guard"
printf '#!/usr/bin/env bash\n# harness-test-timeout-windows: 30\nsleep 4\n' >"$T/cap-suite/test_slow.sh"
out="$(HARNESS_PLATFORM=windows HARNESS_TEST_TIMEOUT=2 bash "$T/cap-suite/run.sh" 2>&1)"; rc=$?
assert_eq "$rc" "0" "a Windows host gives a file its own longer cap (a 4s test under a 2s cap passes)"
out="$(HARNESS_PLATFORM=posix HARNESS_TEST_TIMEOUT=2 bash "$T/cap-suite/run.sh" 2>&1)"; rc=$?
assert_ok "a posix host ignores the marker: the same test times out" grep -qF "TIMEOUT: test_slow.sh ran past HARNESS_TEST_TIMEOUT=2s" <<<"$out"
sed -i 's/windows: 30/windows: 2/' "$T/cap-suite/test_slow.sh"
out="$(HARNESS_PLATFORM=windows HARNESS_TEST_TIMEOUT=3 bash "$T/cap-suite/run.sh" 2>&1)"
assert_ok "the marker only lengthens: a shorter one keeps the run's cap" grep -qxF "== run.sh: 0/1 test files passed ==" <<<"$out"
assert_ok "… and the TIMEOUT line names the cap that applied" grep -qF "ran past HARNESS_TEST_TIMEOUT=3s" <<<"$out"

# Windows side-effect stubs: on a Windows host (forced here) run.sh points schtasks and winget at recording stubs, so no
# test reaches the real Task Scheduler or winget; on Linux it leaves both unset.
mkdir -p "$T/stubs-suite"; cp "$HERE/run.sh" "$HERE/helpers.sh" "$T/stubs-suite/"; cp -r "$HERE/guard" "$T/stubs-suite/guard"
cat >"$T/stubs-suite/test_env.sh" <<'S'
echo "SCHTASKS=${HARNESS_SCHTASKS:-unset}"; echo "WINGET=${HARNESS_WINGET:-unset}"
[[ -x ${HARNESS_SCHTASKS:-/nonexistent} ]] && { "$HARNESS_SCHTASKS" //Create //TN x; echo "create_rc=$?"; "$HARNESS_SCHTASKS" //Query //TN x; echo "query_rc=$?"; }
S
out="$(HARNESS_PLATFORM=windows bash "$T/stubs-suite/run.sh" 2>&1)"
assert_ok "on Windows run.sh stubs schtasks (an executable under the run's temp root)" grep -qE '^SCHTASKS=/.*/stubs/schtasks$' <<<"$out"
assert_ok "… and winget" grep -qE '^WINGET=/.*/stubs/winget$' <<<"$out"
assert_ok "… the stub accepts a create" grep -qx "create_rc=0" <<<"$out"
assert_ok "… and reports a task absent on query (rc 1)" grep -qx "query_rc=1" <<<"$out"
out="$(env -u HARNESS_SCHTASKS -u HARNESS_WINGET HARNESS_PLATFORM=posix bash "$T/stubs-suite/run.sh" 2>&1)"
assert_ok "off Windows run.sh leaves HARNESS_SCHTASKS unset" grep -qx "SCHTASKS=unset" <<<"$out"
assert_ok "… and HARNESS_WINGET" grep -qx "WINGET=unset" <<<"$out"
finish

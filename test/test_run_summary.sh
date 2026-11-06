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
mkdir -p "$T/suite"; cp "$HERE/run.sh" "$HERE/helpers.sh" "$T/suite/"
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

# Windows side-effect stubs: on a Windows host (forced here) run.sh points schtasks and winget at recording stubs, so no
# test reaches the real Task Scheduler or winget; on Linux it leaves both unset.
mkdir -p "$T/stubs-suite"; cp "$HERE/run.sh" "$HERE/helpers.sh" "$T/stubs-suite/"
cat >"$T/stubs-suite/test_env.sh" <<'S'
echo "SCHTASKS=${HARNESS_SCHTASKS:-unset}"; echo "WINGET=${HARNESS_WINGET:-unset}"
[[ -x ${HARNESS_SCHTASKS:-/nonexistent} ]] && { "$HARNESS_SCHTASKS" //Create //TN x; echo "create_rc=$?"; "$HARNESS_SCHTASKS" //Query //TN x; echo "query_rc=$?"; }
S
out="$(HARNESS_PLATFORM=windows bash "$T/stubs-suite/run.sh" 2>&1)"
assert_ok "on Windows run.sh stubs schtasks (an executable under the run's temp root)" grep -qE '^SCHTASKS=/.*/stubs/schtasks$' <<<"$out"
assert_ok "… and winget" grep -qE '^WINGET=/.*/stubs/winget$' <<<"$out"
assert_ok "… the stub accepts a create" grep -qx "create_rc=0" <<<"$out"
assert_ok "… and reports a task absent on query (rc 1)" grep -qx "query_rc=1" <<<"$out"
out="$(HARNESS_PLATFORM=posix bash "$T/stubs-suite/run.sh" 2>&1)"
assert_ok "off Windows run.sh leaves HARNESS_SCHTASKS unset" grep -qx "SCHTASKS=unset" <<<"$out"
assert_ok "… and HARNESS_WINGET" grep -qx "WINGET=unset" <<<"$out"
finish

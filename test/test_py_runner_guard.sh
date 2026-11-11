#!/usr/bin/env bash
# rtdd: always
# test_py_runner_guard.sh — #892: run.sh runs a Python test file as `python3 <file>`, so a file with test_ functions and no
# `if __name__ == "__main__":` runner defined its tests, ran none and exited 0 — test_ralph_stop_hook.py (19 tests) and
# test_bench_refeeds.py (4) passed that way. Every such file must run its tests, a failing test must fail the run, and a
# main-less file must be caught by name rather than pass silently. #917: and so must a test defined BELOW the runner, which
# walks globals() as it executes and so never sees it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
PRIVATE_TMP="$(mktemp -d)"; tmp_track "$PRIVATE_TMP"; export TMPDIR="$PRIVATE_TMP"

# 1. The tree: every test_*.py that defines test_ functions carries a runner.
bare=""
for f in "$HERE"/test_*.py; do
  grep -qE '^[[:space:]]*def test_' "$f" && ! grep -q '__main__' "$f" && bare+=" $(basename "$f")"
done
assert_eq "$bare" "" "every Python test file with test_ functions has a __main__ runner"

# 1b. #917: and no test_ function sits below the runner, where it would be defined too late to run.
late=""
for f in "$HERE"/test_*.py; do
  awk '/^if __name__ == "__main__":/ {m=1; next} m && /^(async )?def test_/ {f=1} END {exit !f}' "$f" && late+=" $(basename "$f")"
done
assert_eq "$late" "" "no Python test file defines a test_ function after its __main__ runner"

# 2. The two files named in #892 run all their tests, through run.sh.
out="$(cd "$HERE" && bash run.sh test_ralph_stop_hook.py test_bench_refeeds.py 2>&1)"; rc=$?
assert_eq "$rc" "0" "run.sh test_ralph_stop_hook.py test_bench_refeeds.py exits 0"
assert_eq "$(grep -c '^  ok: test_' <<<"$out")" "23" "...and runs all 23 tests (19 + 4)"

# 3. run.sh itself, on a copy with fixture test files.
RT="$(mktemp -d)"; tmp_track "$RT"; mkdir -p "$RT/test"
cp "$HERE/run.sh" "$HERE/helpers.sh" "$RT/test/"; cp -r "$HERE/guard" "$RT/test/guard"
cat > "$RT/test/test_fx_mainless.py" <<'PY'
def test_never_runs():
    assert False
PY
cat > "$RT/test/test_fx_failing.py" <<'PY'
import sys
def test_canary():
    assert False, "deliberate"
if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except Exception: print(f"  FAIL: {name}"); fails += 1
    sys.exit(1 if fails else 0)
PY
cat > "$RT/test/test_fx_passing.py" <<'PY'
import sys
def test_fine():
    assert True
if __name__ == "__main__":
    test_fine(); sys.exit(0)
PY
cat > "$RT/test/test_fx_nofuncs.py" <<'PY'
print("a script-style test: runs at top level, no test_ functions")
PY
cat > "$RT/test/test_fx_late.py" <<'PY'
import sys
def test_early():
    assert True
if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except Exception: print(f"  FAIL: {name}"); fails += 1
    sys.exit(1 if fails else 0)

def test_defined_too_late():
    assert False
PY
run_fx(){ (cd "$RT/test" && bash run.sh "$@" 2>&1); }

out="$(run_fx test_fx_mainless.py)"; rc=$?
assert_ok "a main-less file with test_ functions fails run.sh" test "$rc" -ne 0
assert_ok "...naming the file and the missing runner" grep -q 'test_fx_mainless.py defines test_ functions but has no' <<<"$out"
assert_ok "...and listing it as FAILED" grep -q '^FAILED: test_fx_mainless.py' <<<"$out"

out="$(run_fx test_fx_late.py)"; rc=$?
assert_ok "a test_ function defined after the runner fails run.sh" test "$rc" -ne 0
assert_ok "...naming the file and the late test" grep -q 'test_fx_late.py defines test_defined_too_late after its if __name__' <<<"$out"
assert_ok "...and listing it as FAILED" grep -q '^FAILED: test_fx_late.py' <<<"$out"
assert_ok "...without running the file's other tests" test "$(grep -c '^  ok: test_' <<<"$out")" -eq 0

out="$(run_fx test_fx_failing.py)"; rc=$?
assert_ok "a failing test in a file with a runner fails run.sh" test "$rc" -ne 0

out="$(run_fx test_fx_passing.py test_fx_nofuncs.py)"; rc=$?
assert_eq "$rc" "0" "a passing runner file and a script-style file (no test_ functions) still pass"

finish

#!/usr/bin/env bash
# test_bench_fixture.sh — #380 (PRD #345): the benchmark's fixture. One end-user brief, hidden tests
# the agents never see, bench/grade.py to score a checkout against them, and a reference solution
# proving the hidden tests are passable. Covered here: the reference scores 100% (pip build, and the
# PYTHONPATH fallback when it cannot be built), an empty repo scores 0 without crashing the grader,
# a broken solution lands strictly between (the hidden tests can fail), the grader never touches the
# checkout it grades, and nothing a run can see — the brief, any run script — names or copies the
# hidden tests or the reference.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"
FIX="$ROOT/bench/fixture"
GRADE="$ROOT/bench/grade.py"
W="$(mktemp -d)"; tmp_track "$W"
# the grader also fuzzes the build against the reference (#589): a few cases here, test_bench_fuzz.py runs the real count
export BENCH_FUZZ_CASES=48

# frag <field> <json> — one field of the grader's JSON fragment
frag(){ python3 -c 'import json,sys; print(json.loads(sys.argv[2])[sys.argv[1]])' "$1" "$2"; }
detail(){ python3 -c 'import json,sys; print(json.loads(sys.argv[2])["details"][sys.argv[1]])' "$1" "$2"; }
score(){ echo "$(frag passed "$1")/$(frag total "$1") failed=$(frag failed "$1")"; }

echo "=== the fixture ships its four parts ==="
assert_ok "brief.md"                   test -s "$FIX/brief.md"
assert_ok "hidden tests"               test -s "$FIX/hidden/test_hidden.py"
assert_ok "bench/grade.py"             test -x "$GRADE"
assert_ok "reference solution"         test -s "$FIX/reference/pennywise/__init__.py"

echo "=== the reference solution scores 100% ==="
REF="$(python3 "$GRADE" "$FIX/reference")"; rc=$?
assert_eq "$rc" "0" "grader exits 0"
assert_eq "$(python3 -c 'import json,sys; print(sorted(json.loads(sys.argv[1])))' "$REF")" \
          "['details', 'failed', 'fuzz', 'passed', 'total']" "fragment is {passed, failed, total, details, fuzz}"
assert_eq "$(python3 -c 'import json,sys; f=json.loads(sys.argv[1])["fuzz"]; print(f["fuzz_cases"], f["fuzz_divergences"], f["fuzz_examples"], f["fuzz_seed"])' "$REF")" \
          "48 0 [] 589" "reference: the fuzz ran its cases and found 0 divergences against itself"
assert_ok "hidden tests exist (total > 0)"   test "$(frag total "$REF")" -gt 0
assert_eq "$(frag failed "$REF")" "0" "reference: nothing failed"
assert_eq "$(frag passed "$REF")" "$(frag total "$REF")" "reference: passed == total"
assert_eq "$(detail install "$REF")" "pip" "reference is built and installed with pip"
assert_eq "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1])["details"]["tests"]; print(len(d), all(t["status"]=="passed" for t in d))' "$REF")" \
          "$(frag total "$REF") True" "details lists every test, all passed"

echo "=== the reference also passes when it cannot be pip-installed (PYTHONPATH fallback) ==="
cp -r "$FIX/reference" "$W/nopip"; rm "$W/nopip/pyproject.toml"
NOPIP="$(python3 "$GRADE" "$W/nopip")"
assert_eq "$(detail install "$NOPIP")" "pythonpath" "no pyproject.toml → falls back to PYTHONPATH"
assert_eq "$(score "$NOPIP")" "$(frag total "$REF")/$(frag total "$REF") failed=0" "fallback scores 100%"

echo "=== an empty repo scores 0 and does not crash the grader ==="
mkdir "$W/empty"
EMPTY="$(python3 "$GRADE" "$W/empty")"; rc=$?
assert_eq "$rc" "0" "grader exits 0 on an empty repo"
assert_eq "$(frag passed "$EMPTY")" "0" "empty repo: 0 passed"
assert_eq "$(frag total "$EMPTY")" "$(frag total "$REF")" "empty repo: same total as the reference"
assert_eq "$(frag failed "$EMPTY")" "$(frag total "$REF")" "empty repo: everything failed"
git -C "$W/empty" init -q 2>/dev/null; : > "$W/empty/README.md"
assert_eq "$(frag passed "$(python3 "$GRADE" "$W/empty")")" "0" "a repo with only a README scores 0 too"

echo "=== a broken solution lands strictly between (a hidden test can fail) ==="
cp -r "$FIX/reference" "$W/broken"
sed -i 's|return sum((e.amount for e in entries), Decimal("0.00"))|return Decimal("0.00")|' "$W/broken/pennywise/ledger.py"
BROKEN="$(python3 "$GRADE" "$W/broken")"
assert_ok "broken balance: some hidden test fails"  test "$(frag failed "$BROKEN")" -gt 0
assert_ok "broken balance: the rest still pass"     test "$(frag passed "$BROKEN")" -gt 0
assert_eq "$(( $(frag passed "$BROKEN") + $(frag failed "$BROKEN") ))" "$(frag total "$BROKEN")" "passed + failed == total"

echo "=== a broken solution diverges from the reference under the fuzz ==="
BROKEN_FUZZ="$(BENCH_FUZZ_CASES=120 python3 "$GRADE" "$W/broken" | python3 -c 'import json,sys; f=json.load(sys.stdin)["fuzz"]; print(f["fuzz_cases"], f["fuzz_divergences"] > 0, len(f["fuzz_examples"]) > 0)')"
assert_eq "$BROKEN_FUZZ" "120 True True" "broken balance: divergences counted, examples recorded"

echo "=== --fuzz-only backfills an arm's results JSON and its grade.json ==="
mkdir -p "$W/res/x.logs"; echo '{"arm": "x", "logs": "x.logs", "fuzz_cases": 1}' > "$W/res/x.json"; echo '{"passed": 1}' > "$W/res/x.logs/grade.json"
OUT="$(python3 "$GRADE" "$FIX/reference" --fuzz-only --arm-json "$W/res/x.json")"; rc=$?
assert_eq "$rc" "0" "--fuzz-only exits 0"
assert_eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["fuzz_cases"], d["fuzz_divergences"], d["fuzz_seed"], len(d["fuzz_hash"]), d["arm"])' "$W/res/x.json")" \
          "48 0 589 64 x" "results JSON: fuzz_* replaced, the rest kept"
assert_eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["passed"], d["fuzz"]["fuzz_cases"])' "$W/res/x.logs/grade.json")" \
          "1 48" "logs/grade.json carries the fuzz fragment too"
python3 "$GRADE" "$FIX/reference" --arm-json "$W/res/x.json" >/dev/null 2>&1; assert_eq "$?" "2" "--arm-json without --fuzz-only → exit 2"
python3 "$GRADE" "$FIX/reference" --fuzz-only --arm-json >/dev/null 2>&1;      assert_eq "$?" "2" "--arm-json without a file → exit 2"

echo "=== the grader copies: the graded checkout is left untouched ==="
cp -r "$FIX/reference" "$W/pristine"
before="$(cd "$W/pristine" && find . -print | LC_ALL=C sort | xargs -d '\n' ls -ld --time-style=+%s 2>/dev/null | md5sum)"
python3 "$GRADE" "$W/pristine" > /dev/null
after="$(cd "$W/pristine" && find . -print | LC_ALL=C sort | xargs -d '\n' ls -ld --time-style=+%s 2>/dev/null | md5sum)"
assert_eq "$after" "$before" "no file added, removed or changed in the graded repo"

echo "=== grader argument checks ==="
python3 "$GRADE" "$W/does-not-exist" >/dev/null 2>&1; assert_eq "$?" "2" "missing repo dir → exit 2"
python3 "$GRADE" >/dev/null 2>&1;                       assert_eq "$?" "2" "no argument → exit 2"

echo "=== the brief gives no file layout, test or grading hints ==="
assert_no "brief does not mention hidden tests, the reference or grading" \
  grep -qiE 'hidden|reference solution|grad(e|er|ing)|bench|unit test|test suite|acceptance' "$FIX/brief.md"
assert_no "brief names no source/file layout" \
  grep -qE 'pyproject|setup\.py|src/|__init__|__main__|\.py\b|tests?/' "$FIX/brief.md"
assert_no "brief names no hidden test" grep -qE 'test_[a-z]|Tests\b' "$FIX/brief.md"

echo "=== nothing hidden or reference is reachable from the brief or any run script ==="
# a run script may use bench/fixture/brief.md and nothing else of the fixture dir.
# bench/results/ is recorded output (raw agent transcripts), not a run script: it is scanned below for
# the hidden/reference paths specifically, not for the word "fixture" the agents use for their own test fixtures.
BAD="$(cd "$ROOT" && grep -rnoE 'fixture[^[:space:]"'"'"')]*' bench --include='*' --exclude-dir=fixture --exclude-dir=results --exclude=grade.py --exclude=fuzz.py 2>/dev/null | grep -vE 'fixture/brief\.md$' || true)"
assert_eq "$BAD" "" "bench/ scripts (bar the graders grade.py and fuzz.py) reference only fixture/brief.md"
BAD="$(cd "$ROOT" && grep -rlE 'fixture/(hidden|reference)|run_hidden|bench/fixture|test_hidden' bench/results 2>/dev/null || true)"
assert_eq "$BAD" "" "recorded bench results (raw transcripts, logs) never touched the hidden tests or the reference"
BAD="$(cd "$ROOT" && grep -rnE 'bench/fixture|fixture/(hidden|reference)|run_hidden' bin scripts skill prompts plugins docs install.sh update.sh 2>/dev/null | grep -vE 'bench/fixture/brief\.md' || true)"
assert_eq "$BAD" "" "engine, skills, prompts, docs: no reference to the hidden tests or reference"
assert_no "reference solution does not embed the hidden tests" grep -rqE 'test_hidden|run_hidden|unittest' "$FIX/reference"
assert_ok "hidden tests do not sit in the reference tree" test ! -e "$FIX/reference/hidden"

finish

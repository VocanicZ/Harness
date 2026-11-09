#!/usr/bin/env bash
# harness-test-timeout-windows: 6000
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
# the fragment goes in on stdin: an empty repo's carries every test's stderr, past Windows' 32 KB command line (#686)
frag(){ python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1" <<<"$2"; }
detail(){ python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["details"][sys.argv[1]])' "$1" <<<"$2"; }
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
          "48 0 [] 620" "reference: the fuzz ran its cases and found 0 divergences against itself"
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
          "48 0 620 64 x" "results JSON: fuzz_* replaced, the rest kept"
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
# What an arm can reach is whatever a run script puts in front of it: bench/run.py seeds the run repo with the fixture's
# brief (bench/fixtures.py names it) and hands the arm the written change request; nothing else of a fixture dir. So the
# scripts that start or run an arm never name a fixture's hidden tests, reference, fuzz or hint file. The graders
# (grade.py, fuzz.py, progress.py's milestone grading) and the registry (fixtures.py) are the only code that does, and
# they run on the host, outside the arm's checkout. bench/results/ is recorded output (raw agent transcripts), scanned below.
BAD="$(cd "$ROOT" && grep -rnE 'fixture(-large)?/(hidden|reference|shape|notes)|run_hidden|test_hidden|shape\.json' bench/run.py bench/armlib.py bench/arms bench/aggregate.py bench/quality.py bench/testcov.py 2>/dev/null || true)"
assert_eq "$BAD" "" "run.py, armlib.py and the arms never name a fixture's hidden tests, reference or shape file"
BAD="$(cd "$ROOT" && grep -rlE 'fixture(-large)?/(hidden|reference)|run_hidden|bench/fixture|test_hidden' bench/results 2>/dev/null || true)"
assert_eq "$BAD" "" "recorded bench results (raw transcripts, logs) never touched the hidden tests or the reference"
BAD="$(cd "$ROOT" && grep -rnE 'bench/fixture|fixture(-large)?/(hidden|reference)|run_hidden' bin scripts skill prompts plugins docs install.sh update.sh 2>/dev/null | grep -vE 'bench/fixture/brief\.md' || true)"
assert_eq "$BAD" "" "engine, skills, prompts, docs: no reference to the hidden tests or reference"
assert_no "reference solution does not embed the hidden tests" grep -rqE 'test_hidden|run_hidden|unittest' "$FIX/reference"
assert_ok "hidden tests do not sit in the reference tree" test ! -e "$FIX/reference/hidden"

echo "=== the large fixture ships its parts (#592) ==="
LG="$ROOT/bench/fixture-large"
for f in brief.md change.md shape.json fixture.json fuzz.py hidden/run_hidden.py hidden/support.py reference/pyproject.toml reference/tallybook/__init__.py; do
  assert_ok "large: $f" test -s "$LG/$f"
done
assert_ok "large: hidden tests of all 16 modules" test "$(ls "$LG"/hidden/test_[0-9][0-9]_*.py | wc -l)" -eq 16
assert_no "large brief does not mention hidden tests, the reference or grading" \
  grep -qiE 'hidden test|reference solution|grad(e|er|ing)|bench(mark)?\b|unit test|test suite|acceptance test' "$LG/brief.md"
assert_no "large change request does not either" grep -qiE 'hidden test|reference solution|grad(e|er|ing)|bench(mark)?\b|unit test|test suite' "$LG/change.md"
assert_no "large brief names no source/file layout" grep -qE 'pyproject|setup\.py|src/|__init__\.py|tests?/' "$LG/brief.md"
assert_no "the brief describes the original behaviour only: no lock date, no half-to-even" grep -qiE 'lock date|LockedPeriod|half to even|half-to-even|banker' "$LG/brief.md"
assert_ok "the change request carries all three changes" bash -c "grep -q 'half to even' '$LG/change.md' && grep -q 'lock date' '$LG/change.md' && grep -q '\"code\"' '$LG/change.md'"
assert_no "the reference does not embed the hidden tests" grep -rqE 'run_hidden|hidden/' "$LG/reference"

echo "=== the large reference scores 100% in both phases, a broken one does not, an empty repo scores 0 ==="
LARGE_FUZZ=40
( BENCH_FUZZ_CASES=$LARGE_FUZZ python3 "$GRADE" "$LG/reference" --fixture large > "$W/lg-post.json" ) &
( TALLYBOOK_PHASE=pre python3 "$GRADE" "$LG/reference" --fixture large --phase pre --tests-only > "$W/lg-pre.json" ) &
( python3 "$GRADE" "$LG/reference" --fixture large --phase pre --tests-only > "$W/lg-pre-on-post.json" ) &
mkdir "$W/lg-empty"
( python3 "$GRADE" "$W/lg-empty" --fixture large --tests-only > "$W/lg-empty.json" ) &
cp -r "$LG/reference" "$W/lg-broken"
sed -i 's|^def round_div(n, d):|def round_div(n, d):\n    return n // d|' "$W/lg-broken/tallybook/money.py"
( BENCH_FUZZ_CASES=120 python3 "$GRADE" "$W/lg-broken" --fixture large > "$W/lg-broken.json" ) &
wait
# 981 results are too big for an argument list: read the graders' JSON from files
fragf(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[2]))[sys.argv[1]])' "$1" "$2"; }
# The reference is a program for a POSIX host: four of its hidden tests read the exit status of a process whose pipe was closed or
# that was sent SIGINT/SIGTERM, which Windows does not have (a native Python cannot even send signal 2). On a real Windows host
# exactly those four fail, nothing else (#686); anywhere else none does.
LG_WIN_ONLY="M15CommandLine.test_a_closed_reader_ends_quietly M15Serve.test_serve_announces_and_stops_cleanly M16Server.test_a_failing_request_prints_nothing M16Server.test_stops_cleanly_on_sigterm_and_sigint"
LG_WANT_FAIL=""; LG_WANT_MODS="True"
real_windows_host && { LG_WANT_FAIL="$LG_WIN_ONLY"; LG_WANT_MODS="True"; }
failed_ids(){ python3 -c 'import json,sys; print(" ".join(sorted(t["id"] for t in json.load(open(sys.argv[1]))["details"]["tests"] if t["status"] != "passed")))' "$1"; }
# modules_ok <json> <failing ids> — every module is scored, and every one without a listed failure passed in full
modules_ok(){ python3 -c '
import json,sys,re
m=json.load(open(sys.argv[1]))["modules"]; ids=sys.argv[2].split()
bad={re.match(r"M(\d\d)",i).group(1) for i in ids}
print(sorted(m)==["%02d"%i for i in range(1,17)] and all((v["passed"]==v["total"]>0) == (k not in bad) for k,v in m.items()))' "$1" "$2"; }
LGP="$W/lg-post.json"
assert_eq "$(failed_ids "$LGP")" "$LG_WANT_FAIL" "large reference, post-change: nothing failed (on Windows: only the POSIX-signal tests)"
assert_ok "large reference: about a thousand hidden tests" test "$(fragf total "$LGP")" -ge 900
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["details"]["install"])' "$LGP")" "pip" "large reference is built and installed with pip"
assert_eq "$(modules_ok "$LGP" "$LG_WANT_FAIL")" "True" "every one of the 16 modules is scored, all passed (bar the modules of the Windows-only failures)"
assert_eq "$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))["fuzz"]; print(f["fuzz_cases"], f["fuzz_divergences"], f["fuzz_seed"])' "$LGP")" "$LARGE_FUZZ 0 592" "large reference: the fuzz ran its cases and found 0 divergences against itself"
assert_eq "$(failed_ids "$W/lg-pre.json")" "$(real_windows_host && echo "$LG_WIN_ONLY")" "large reference with TALLYBOOK_PHASE=pre: every pre-change test passes (on Windows: bar the POSIX-signal ones)"
assert_ok "the post-change test set is not the pre-change one" test "$(fragf total "$W/lg-pre.json")" -ne "$(fragf total "$LGP")"
assert_ok "the post-change reference fails some pre-change tests: the change request changes behaviour" test "$(fragf failed "$W/lg-pre-on-post.json")" -gt 0
assert_eq "$(fragf passed "$W/lg-empty.json")" "0" "large: an empty repo scores 0"
assert_eq "$(fragf total "$W/lg-empty.json")" "$(fragf total "$LGP")" "large: an empty repo has the reference's total"
assert_ok "large broken rounding: some hidden test fails" test "$(fragf failed "$W/lg-broken.json")" -gt 0
assert_ok "large broken rounding: the rest pass" test "$(fragf passed "$W/lg-broken.json")" -gt 0
assert_eq "$(python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))["fuzz"]; print(f["fuzz_divergences"] > 0)' "$W/lg-broken.json")" "True" "large broken rounding: the fuzz sees it too"

finish

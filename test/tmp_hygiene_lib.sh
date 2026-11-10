# tmp_hygiene_lib.sh — what the test_tmp_hygiene_<subject>.sh files share (#608). Sourced after helpers.sh; not a test, run.sh never runs it.
# hygiene_direct <test file> — run it directly (no run.sh) under a fresh private TMPDIR and assert it leaves that empty.
# Its own pass/fail is that test's business (run.sh runs it too); only what it leaves is ours.
hygiene_direct(){ local t="$1" d; echo "-- $t run directly leaves its TMPDIR empty"
  d="$T/${t%.sh}"; mkdir -p "$d"
  TMPDIR="$d" bash "$HERE/$t" >"$T/${t%.sh}.log" 2>&1
  assert_eq "$(ls -A "$d" | head -5)" "" "$t leaves nothing in its TMPDIR"
}

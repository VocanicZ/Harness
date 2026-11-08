#!/usr/bin/env bash
# test_tmp_hygiene.sh — #294: the suite must not leak temp dirs/files into $TMPDIR. make_env used to
# leave a RUN_DIR (~3000 inodes with its stubs and sockets) plus two loose mktemp files per call, and
# nothing removed them; on a shared host that exhausted /tmp's inodes and took every session's Bash
# tool down. Each case runs under its OWN fresh TMPDIR and asserts it is empty afterwards — never a
# global /tmp/tmp.* count, which other lanes on the host change concurrently.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# leftovers DIR — what is left in DIR, one entry per line (empty when clean).
leftovers(){ ls -A "$1"; }

echo "-- make_env keeps everything inside RUN_DIR, and removes every RUN_DIR it made"
d="$T/unit"; mkdir -p "$d"
out="$(TMPDIR="$d" bash -c '
  source "$1/../scripts/lib.sh"; source "$1/helpers.sh"
  make_env; echo "$TARGETS_TSV"; echo "$COMPLETE_SET"; echo "$RUN_DIR"
  make_env; make_env; echo "$RUN_DIR"' _ "$HERE")"
{ read -r tsv; read -r cset; read -r first; read -r last; } <<<"$out"
assert_eq "${tsv%/*}" "$first" "TARGETS_TSV lives inside RUN_DIR"
assert_eq "${cset%/*}" "$first" "COMPLETE_SET lives inside RUN_DIR"
assert_ok "three make_env calls made distinct RUN_DIRs" test "$first" != "$last"
assert_eq "$(leftovers "$d")" "" "three make_env calls: all three RUN_DIRs removed on exit"

echo "-- a test's own EXIT trap set before make_env is kept, and still cleans up"
d="$T/pre-trap"; mkdir -p "$d"
TMPDIR="$d" bash -c '
  source "$1/../scripts/lib.sh"; source "$1/helpers.sh"
  trap "touch \"$TMPDIR/../pre-trap-ran\"" EXIT
  make_env' _ "$HERE"
assert_ok "the earlier EXIT trap still ran" test -e "$T/pre-trap-ran"
assert_eq "$(leftovers "$d")" "" "…and RUN_DIR was removed as well"

echo "-- make_env in a subshell cleans its own RUN_DIR and leaves the parent's alone"
d="$T/subshell"; mkdir -p "$d"
out="$(TMPDIR="$d" bash -c '
  source "$1/../scripts/lib.sh"; source "$1/helpers.sh"
  make_env; outer="$RUN_DIR"
  ( make_env; echo "$RUN_DIR" )
  [[ -d "$outer" ]] && echo outer-kept' _ "$HERE")"
assert_ok "the parent RUN_DIR survives a subshell make_env" grep -qx outer-kept <<<"$out"
assert_ok "the subshell RUN_DIR is gone when the subshell exits" test ! -e "$(head -1 <<<"$out")"
assert_eq "$(leftovers "$d")" "" "subshell + parent: nothing left on exit"

# A real test file, run directly (no run.sh) under a fresh private TMPDIR, must leave it empty: test_tmp_hygiene_<subject>.sh, one per
# subject (#608: the loop over them took 583 s in this one file, past the per-file cap on Windows). They share tmp_hygiene_lib.sh.
# Each subject must have its file, or the check below is silently never run.
for t in test_claim.sh test_drive.sh test_watchdog.sh test_supervise.sh test_cli_matrix.sh; do
  assert_ok "$t has its direct-run hygiene file" grep -q "hygiene_direct $t" "$HERE/test_tmp_hygiene_${t#test_}"
done

echo "-- run.sh gives each test its own TMPDIR and removes it once the test finishes"
R="$T/runner"; d="$T/runner-tmp"; mkdir -p "$R" "$d"
cp "$HERE/run.sh" "$HERE/helpers.sh" "$R/"; cp -r "$HERE/guard" "$R/guard"
# Fixture tests that leak the way the real ones did: a bare mktemp with no trap, in bash and Python.
cat >"$R/test_leak.sh" <<'EOF'
#!/usr/bin/env bash
mktemp -d >/dev/null; mktemp >/dev/null
[[ "${TMPDIR:-}" == "$RUNNER_TMP"/* ]] && echo "bash TMPDIR under TMPROOT"
EOF
cat >"$R/test_leak.py" <<'EOF'
import os, tempfile
tempfile.mkdtemp(); tempfile.mkstemp()
if tempfile.gettempdir().startswith(os.environ["RUNNER_TMP"] + "/"): print("python TMPDIR under TMPROOT")
EOF
out="$(TMPDIR="$d" RUNNER_TMP="$d" bash "$R/run.sh" 2>&1)"; rc=$?
assert_eq "$rc" 0 "the fixture suite passes"
assert_ok "bash tests get a TMPDIR under the runner's root" grep -qx "bash TMPDIR under TMPROOT" <<<"$out"
assert_ok "python tests get a TMPDIR under the runner's root" grep -qx "python TMPDIR under TMPROOT" <<<"$out"
assert_eq "$(leftovers "$d")" "" "run.sh leaves nothing in the TMPDIR it was started with"
echo "-- #419 tmp_cleanup kills this user's processes rooted in a tracked dir, and only those"
# A test that dies before its own kill-trap left the workers / lanes it started polling a deleted home
# for days. tmp_cleanup stops every process whose cwd, or STATE_DIR / HARNESS_HOME / HARNESS_LANE_DIR,
# is inside a tracked dir — by path, never by command-line pattern (a shared host) — then removes it.
# pids419 <proc-root> — run a child shell that tracks a dir, starts three sleeps (cwd inside, env
# inside, unrelated) and exits; print "<cwd-pid> <env-pid> <other-pid> <tracked-dir>".
pids419(){ TMPDIR="$T/leak" HARNESS_PROC_ROOT="$1" bash -c '
  source "$1/helpers.sh"; D="$(mktemp -d)"; tmp_track "$D"
  ( cd "$D" && exec sleep 300 ) >/dev/null 2>&1 & a=$!
  ( cd "$2" && exec env HARNESS_HOME="$D/host" sleep 300 ) >/dev/null 2>&1 & b=$!
  ( cd "$2" && exec sleep 300 ) >/dev/null 2>&1 & c=$!
  sleep 0.5; echo "$a $b $c $D"' _ "$HERE" "$T/outside"; }
dead419(){ ! kill -0 "$1" 2>/dev/null || grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
mkdir -p "$T/leak" "$T/outside"
if [[ -d /proc/self ]]; then
  read -r a b c D <<<"$(pids419 /proc)"; sleep 0.3
  assert_ok "a process whose cwd is inside a tracked dir is dead after tmp_cleanup" dead419 "$a"
  assert_ok "a process with HARNESS_HOME inside a tracked dir is dead after tmp_cleanup" dead419 "$b"
  assert_ok "an unrelated process outside every tracked dir survives" kill -0 "$c"
  assert_ok "…and the tracked dir is removed" test ! -e "$D"
  kill "$a" "$b" "$c" 2>/dev/null
fi
read -r a b c D <<<"$(pids419 "$T/no-proc")"; sleep 0.3
assert_ok "no /proc: tmp_cleanup still removes the tracked dir" test ! -e "$D"
assert_ok "no /proc: …and kills nothing" kill -0 "$a"
kill "$a" "$b" "$c" 2>/dev/null

finish

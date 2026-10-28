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

# A real test file, run directly (no run.sh) under a fresh private TMPDIR, must leave it empty.
# test_claim: one make_env. test_drive: many. test_watchdog / test_supervise: their own EXIT trap
# after make_env. test_cli_matrix: a tmux socket under RUN_DIR, reaped by its own kill-server trap.
for t in test_claim.sh test_drive.sh test_watchdog.sh test_supervise.sh test_cli_matrix.sh; do
  echo "-- $t run directly leaves its TMPDIR empty"
  d="$T/${t%.sh}"; mkdir -p "$d"
  # Its own pass/fail is that test's business (run.sh runs it too); only what it leaves is ours.
  TMPDIR="$d" bash "$HERE/$t" >"$T/${t%.sh}.log" 2>&1
  assert_eq "$(leftovers "$d" | head -5)" "" "$t leaves nothing in its TMPDIR"
done

echo "-- run.sh gives each test its own TMPDIR and removes it once the test finishes"
R="$T/runner"; d="$T/runner-tmp"; mkdir -p "$R" "$d"
cp "$HERE/run.sh" "$HERE/helpers.sh" "$R/"
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
finish

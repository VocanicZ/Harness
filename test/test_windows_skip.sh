#!/usr/bin/env bash
# test_windows_skip.sh — #492 / PRD #475 Solution 6: the OS-aware skip helper (helpers.sh windows_skip).
#
# A test may skip itself on Windows only through windows_skip <matrix row>, and only when that row is `n/a` on
# Windows in the parity matrix. A `✓` row (or a `✓ target` one) and a row the matrix does not have are FAILURES,
# on every OS — so a wrong skip is caught on Linux, not first on a Windows host. Every case runs on a fixture
# matrix, and on the real docs/reference.md for the one row that is n/a there.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
REAL="$HERE/../docs/reference.md"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat >"$T/matrix.md" <<'M'
### Windows parity matrix

| feature | Linux | Windows |
|---|---|---|
| `harness stop` | ✓ | ✓ |
| `harness release` | ✓ | ✓ target (#475 task 8) |
| `swarm submission` | ✓ | n/a: a Linux-only service ([source](https://example.com/swarm)) |
| `cli ghost` | ✓ | n/a: no Windows build ([source](https://example.com/ghost)) |

#### Non-interactive mode per agent CLI

| cli | non-interactive command |
|---|---|
| `harness stop` | not a matrix row: the research table shares names |
| `research only` | x |
M

# run <platform> <row> [why] — windows_skip in a fresh bash on <platform>: prints its output, then
# "rc=<status> fail=<TESTS_FAIL>" (the status windows_skip returned, the failures it counted).
run(){ local plat="$1"; shift
  HARNESS_PLATFORM="$plat" HARNESS_PARITY_DOC="${DOC:-$T/matrix.md}" bash -c '
    source "$1"; shift; windows_skip "$@"; echo "rc=$? fail=$TESTS_FAIL"' _ "$HERE/helpers.sh" "$@"; }
tail1(){ tail -n1 <<<"$1"; }

# --- n/a row: skips on Windows, runs everywhere else ----------------------------------------------
out="$(run windows "swarm submission" "needs condor")"
assert_eq "$(tail1 "$out")" "rc=0 fail=0" "n/a row on Windows: skip (status 0, no failure)"
assert_ok "… and the skip names the row" grep -qF "SKIP (Windows n/a: row 'swarm submission'): needs condor" <<<"$out"
out="$(run posix "swarm submission" "needs condor")"
assert_eq "$(tail1 "$out")" "rc=1 fail=0" "n/a row off Windows: no skip (status 1, no failure) — the test runs"
assert_no "… and prints no SKIP" grep -q SKIP <<<"$out"
out="$(run windows "cli ghost" "no build")"
assert_eq "$(tail1 "$out")" "rc=0 fail=0" "an n/a agent-CLI row skips too"

# --- ✓ and ✓ target rows: a failure, on every OS ---------------------------------------------------
for plat in windows posix; do
  out="$(run $plat "harness stop" "tmux")"
  assert_eq "$(tail1 "$out")" "rc=1 fail=1" "✓ row on $plat: failure, no skip"
  assert_ok "… the failure names the row and says it is not n/a" grep -qF "row 'harness stop' is ✓ on Windows, not n/a" <<<"$out"
  assert_no "… no SKIP printed" grep -q SKIP <<<"$out"
  out="$(run $plat "harness release" "tmux")"
  assert_eq "$(tail1 "$out")" "rc=1 fail=1" "✓ target row on $plat: failure, no skip"
  assert_ok "… the failure says ✓" grep -qF "row 'harness release' is ✓ on Windows" <<<"$out"
done

# --- an unknown row: a failure, on every OS --------------------------------------------------------
for plat in windows posix; do
  out="$(run $plat "harnes stop" "typo")"
  assert_eq "$(tail1 "$out")" "rc=1 fail=1" "unknown row on $plat: failure, no skip"
  assert_ok "… the failure names the row the matrix lacks" grep -qF "the parity matrix has no row 'harnes stop'" <<<"$out"
done
out="$(run windows "research only" "x")"
assert_eq "$(tail1 "$out")" "rc=1 fail=1" "a name that is only in the per-CLI research table is no matrix row"
out="$(DOC="$T/missing.md" run windows "swarm submission" "x")"
assert_eq "$(tail1 "$out")" "rc=1 fail=1" "an unreadable matrix is a failure, never a skip"

# --- windows_skip_file: skip = finish + exit 0; no skip = keeps going -------------------------------
cat >"$T/skipfile.sh" <<'S'
source "$1"
windows_skip_file "swarm submission" "needs condor"
echo "RAN BODY"
finish
S
out="$(HARNESS_PLATFORM=windows HARNESS_PARITY_DOC="$T/matrix.md" bash "$T/skipfile.sh" "$HERE/helpers.sh")"; rc=$?
assert_eq "$rc" "0" "windows_skip_file on an n/a row on Windows: exits 0"
assert_no "… without running the body" grep -q "RAN BODY" <<<"$out"
assert_ok "… after printing its result line" grep -qF "── 0/0 passed" <<<"$out"
out="$(HARNESS_PLATFORM=posix HARNESS_PARITY_DOC="$T/matrix.md" bash "$T/skipfile.sh" "$HERE/helpers.sh")"; rc=$?
assert_eq "$rc" "0" "windows_skip_file off Windows: the file runs and ends green"
assert_ok "… the body ran" grep -q "RAN BODY" <<<"$out"
cat >"$T/badfile.sh" <<'S'
source "$1"
windows_skip_file "harness stop" "tmux"
echo "RAN BODY"
finish
S
out="$(HARNESS_PLATFORM=windows HARNESS_PARITY_DOC="$T/matrix.md" bash "$T/badfile.sh" "$HERE/helpers.sh")"; rc=$?
assert_ok "windows_skip_file on a ✓ row: the file still runs its body…" grep -q "RAN BODY" <<<"$out"
assert_ok "… and ends red" test "$rc" -ne 0

# --- the real matrix ------------------------------------------------------------------------------
DOC="$REAL"
out="$(run windows "swarm submission" "needs condor")"
assert_eq "$(tail1 "$out")" "rc=0 fail=0" "real docs/reference.md: swarm submission is n/a on Windows, so it skips there"
out="$(run windows "harness stop" "x")"
assert_eq "$(tail1 "$out")" "rc=1 fail=1" "real docs/reference.md: harness stop is ✓, so it may not skip"
unset DOC

# --- host_is_windows: HARNESS_PLATFORM wins, else uname --------------------------------------------
assert_ok "host_is_windows: HARNESS_PLATFORM=windows" env HARNESS_PLATFORM=windows bash -c "source '$HERE/helpers.sh'; host_is_windows"
assert_no "host_is_windows: HARNESS_PLATFORM=posix" env HARNESS_PLATFORM=posix bash -c "source '$HERE/helpers.sh'; host_is_windows"
printf '#!/bin/sh\necho MINGW64_NT-10.0-19045\n' >"$T/uname"; chmod +x "$T/uname"
assert_ok "host_is_windows: an unforced MINGW uname" env -u HARNESS_PLATFORM PATH="$T:$PATH" bash -c "source '$HERE/helpers.sh'; host_is_windows"
printf '#!/bin/sh\necho Linux\n' >"$T/uname"
assert_no "host_is_windows: an unforced Linux uname" env -u HARNESS_PLATFORM PATH="$T:$PATH" bash -c "source '$HERE/helpers.sh'; host_is_windows"
# --- posix_branch_off_windows (#1117): a POSIX-only cell is asserted off-Windows, never a SKIP -----------------------------------
# PRD #475: every Windows skip names an n/a matrix row. A POSIX-only branch (flock, fcntl, procps) has no such row: on a real Windows
# host it is a PASS (the engine takes its Windows branch), counted in TESTS_RUN, and prints no SKIP. A fake MINGW uname is a real Windows host.
printf '#!/bin/sh\necho MINGW64_NT-10.0-19045\n' >"$T/uname"
pb(){ local u="$1"; shift; env -u HARNESS_PLATFORM ${u:+PATH="$u:$PATH"} HARNESS_PLATFORM="$1" bash -c '
  source "$1"; posix_branch_off_windows "a flock cell"; echo "rc=$? run=$TESTS_RUN fail=$TESTS_FAIL"' _ "$HERE/helpers.sh"; }
out="$(pb "$T" windows)"
assert_eq "$(tail1 "$out")" "rc=0 run=1 fail=0" "posix_branch_off_windows on a real Windows host: handled (status 0), one assertion, no failure"
assert_no "… prints no SKIP" grep -q SKIP <<<"$out"
assert_ok "… and says the POSIX branch is not used, as an ok" grep -qF "ok: the POSIX branch is not used on a Windows host (a flock cell)" <<<"$out"
out="$(pb "$T" posix)"   # the cell forces HARNESS_PLATFORM=posix, as the tests do; the assertion must not read it
assert_eq "$(tail1 "$out")" "rc=0 run=1 fail=0" "… with HARNESS_PLATFORM=posix forced by the test, still passes (the check unsets it)"
printf '#!/bin/sh\necho Linux\n' >"$T/uname"
out="$(pb "$T" posix)"
assert_eq "$(tail1 "$out")" "rc=1 run=0 fail=0" "posix_branch_off_windows on Linux: not handled (status 1), nothing asserted — the POSIX cells run"
assert_eq "$(sed '$d' <<<"$out")" "" "… and prints nothing"
# no test prints the old nameless SKIP, and the old helper name is gone
leaks="$(grep -lE 'POSIX branch, no counterpart|skip_posix_branch' "$HERE"/test_*.sh "$HERE"/test_*.py "$HERE/helpers.sh" 2>/dev/null | grep -v '/test_windows_skip.sh$')"
assert_eq "$leaks" "" "no test prints a SKIP that names no n/a matrix row for a POSIX branch (#1117)"
assert_no "test_portable.py prints no SKIP for a POSIX branch" grep -qE 'print\(" +SKIP' "$HERE/test_portable.py"
finish

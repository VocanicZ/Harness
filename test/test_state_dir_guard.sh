#!/usr/bin/env bash
# test_state_dir_guard.sh — an INHERITED STATE_DIR that disagrees with the project discovered from
# cwd must be REFUSED, not silently obeyed (#168).
#
# The 2026-08-12 incident: a session launched inside fleet A inherited A's exported STATE_DIR, then
# `cd`-ed to project B and ran `harness stop` — which stopped A's fleet and reported success. The
# distinction that matters is DELIBERATE (--state-dir / HARNESS_STATE_DIR_OK=1) vs INHERITED, and an
# env var alone cannot express it.
#
# Hermetic by construction: the CLI under test is a copy of bin/harness inside a throwaway ENGINE_DIR
# whose scripts/ are stubs that just announce themselves — so an "allowed" command is observable
# without launching tmux, and a "refused" one is provably not executed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
unset STATE_DIR HARNESS_STATE_DIR_OK

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- throwaway engine: real entrypoint, stub subcommand scripts -------------------------------
ENGINE="$TMP/engine"; mkdir -p "$ENGINE/bin" "$ENGINE/scripts"
cp "$HERE/../bin/harness" "$ENGINE/bin/harness"
CLI="$ENGINE/bin/harness"
for s in start stop status doctor pause resume attach setup migrate inject init uninstall; do
  cat > "$ENGINE/scripts/$s.sh" <<EOF
#!/usr/bin/env bash
echo "RAN $s STATE_DIR=\${STATE_DIR:-} ARGS=\$*"
EOF
done

# --- two projects, A (the fleet we came from) and B (the one we are standing in) ---------------
A="$TMP/projA"; B="$TMP/projB"
mkdir -p "$A/.harness" "$B/.harness" "$B/src/deep" "$TMP/nowhere"
: > "$A/.harness/config"; : > "$B/.harness/config"

run(){ # run <cwd> -- <cmd...>   (env is set by the caller via `env`)
  local cwd="$1"; shift; ( cd "$cwd" && "$@" ) 2>&1
}

# ============================================================================================
echo "── 1. the 2026-08-12 incident: inherited A + standing in B → refuse"
out="$(run "$B" env STATE_DIR="$A/.harness" bash "$CLI" stop)"; rc=$?
TESTS_RUN=$((TESTS_RUN+1))
if [[ $rc -ne 0 ]]; then echo "  ok: incident: harness stop exits non-zero"; else echo "  FAIL: incident: harness stop exits non-zero"; TESTS_FAIL=$((TESTS_FAIL+1)); fi
assert_ok "incident: refusal names the inherited path"  grep -qF "$A/.harness" <<<"$out"
assert_ok "incident: refusal names this directory's path" grep -qF "$B/.harness" <<<"$out"
assert_ok "incident: says it is refusing"               grep -qi "refus" <<<"$out"
assert_ok "incident: says STATE_DIR came from the environment" grep -qi "inherit" <<<"$out"
assert_no "incident: A's stop.sh never ran"             grep -q "RAN stop" <<<"$out"

echo "── 1b. every project command refuses, not just stop"
for cmd in start stop status doctor pause resume; do
  out="$(run "$B" env STATE_DIR="$A/.harness" bash "$CLI" "$cmd")"; rc=$?
  TESTS_RUN=$((TESTS_RUN+1))
  if [[ $rc -ne 0 ]] && ! grep -q "RAN $cmd" <<<"$out"; then
    echo "  ok: $cmd refuses a disagreeing inherited STATE_DIR"
  else
    echo "  FAIL: $cmd refuses a disagreeing inherited STATE_DIR — rc=$rc out=[$out]"; TESTS_FAIL=$((TESTS_FAIL+1))
  fi
done

# ============================================================================================
echo "── 2. a MATCHING inherited STATE_DIR still works, silently"
out="$(run "$B" env STATE_DIR="$B/.harness" bash "$CLI" status)"
assert_ok "matching: status runs"            grep -q "RAN status" <<<"$out"
assert_ok "matching: STATE_DIR is B's"       grep -qF "STATE_DIR=$B/.harness" <<<"$out"
assert_no "matching: no refusal noise"       grep -qi "refus" <<<"$out"
assert_eq "$(wc -l <<<"$out")" "1" "matching: exactly one line of output (no new noise)"

echo "── 2b. matching from a SUBDIRECTORY of the project (discovery walks up)"
out="$(run "$B/src/deep" env STATE_DIR="$B/.harness" bash "$CLI" status)"
assert_ok "subdir: status runs" grep -q "RAN status" <<<"$out"

echo "── 2c. a trailing slash / non-canonical inherited path is still a match"
out="$(run "$B" env STATE_DIR="$B/.harness/" bash "$CLI" status)"
assert_ok "trailing slash: status runs" grep -q "RAN status" <<<"$out"
out="$(run "$B" env STATE_DIR="$B/./.harness" bash "$CLI" status)"
assert_ok "dot path: status runs" grep -q "RAN status" <<<"$out"

echo "── 2d. cwd INSIDE the fleet's own state tree (a worktree with its own config) is a match"
mkdir -p "$B/.harness/worktrees/main-i1/.harness"; : > "$B/.harness/worktrees/main-i1/.harness/config"
out="$(run "$B/.harness/worktrees/main-i1" env STATE_DIR="$B/.harness" bash "$CLI" status)"
assert_ok "worktree: status runs (workers export STATE_DIR legitimately)" grep -q "RAN status" <<<"$out"

# ============================================================================================
echo "── 3. inherited STATE_DIR with NO discoverable project still works (#53 vendored case)"
out="$(run "$TMP/nowhere" env STATE_DIR="$A/.harness" bash "$CLI" status)"
assert_ok "vendored: status runs"       grep -q "RAN status" <<<"$out"
assert_ok "vendored: STATE_DIR is A's"  grep -qF "STATE_DIR=$A/.harness" <<<"$out"

echo "── 3b. no STATE_DIR and no project at all → the pre-existing clear error (unchanged)"
out="$(run "$TMP/nowhere" bash "$CLI" status)"; rc=$?
TESTS_RUN=$((TESTS_RUN+1))
if [[ $rc -ne 0 ]] && grep -qi "not inside a Harness project" <<<"$out"; then
  echo "  ok: outside any project the original error still fires"
else
  echo "  FAIL: outside any project the original error still fires — rc=$rc out=[$out]"; TESTS_FAIL=$((TESTS_FAIL+1))
fi

# ============================================================================================
echo "── 4. escape hatches: DELIBERATE beats inherited"
out="$(run "$B" bash "$CLI" stop --state-dir "$A/.harness")"
assert_ok "--state-dir after the command: runs"     grep -q "RAN stop" <<<"$out"
assert_ok "--state-dir after the command: targets A" grep -qF "STATE_DIR=$A/.harness" <<<"$out"

out="$(run "$B" bash "$CLI" --state-dir "$A/.harness" stop)"
assert_ok "--state-dir before the command: runs"     grep -q "RAN stop" <<<"$out"
assert_ok "--state-dir before the command: targets A" grep -qF "STATE_DIR=$A/.harness" <<<"$out"

out="$(run "$B" bash "$CLI" stop "--state-dir=$A/.harness")"
assert_ok "--state-dir=PATH form: targets A" grep -qF "STATE_DIR=$A/.harness" <<<"$out"

# the flag must be CONSUMED, not passed through to the subcommand script
assert_no "--state-dir is not forwarded to the subcommand" grep -q -- "--state-dir" <<<"$out"

out="$(run "$B" env STATE_DIR="$A/.harness" HARNESS_STATE_DIR_OK=1 bash "$CLI" stop)"
assert_ok "HARNESS_STATE_DIR_OK=1: runs"     grep -q "RAN stop" <<<"$out"
assert_ok "HARNESS_STATE_DIR_OK=1: targets A" grep -qF "STATE_DIR=$A/.harness" <<<"$out"

echo "── 4b. --state-dir with a missing path fails cleanly"
out="$(run "$B" bash "$CLI" stop --state-dir)"; rc=$?
TESTS_RUN=$((TESTS_RUN+1))
if [[ $rc -ne 0 ]] && ! grep -q "RAN stop" <<<"$out"; then
  echo "  ok: --state-dir with no argument errors"
else
  echo "  FAIL: --state-dir with no argument errors — rc=$rc out=[$out]"; TESTS_FAIL=$((TESTS_FAIL+1))
fi

echo "── 4c. subcommand arguments survive the flag scan"
out="$(run "$B" env STATE_DIR="$B/.harness" bash "$CLI" stop --clean)"
assert_ok "unrelated flags still reach the subcommand" grep -qF "ARGS=--clean" <<<"$out"

# ============================================================================================
echo "── 5. the escape hatch is documented in --help"
help="$(bash "$CLI" --help 2>&1)"
assert_ok "help documents --state-dir"          grep -q -- "--state-dir" <<<"$help"
assert_ok "help documents HARNESS_STATE_DIR_OK" grep -q "HARNESS_STATE_DIR_OK" <<<"$help"
assert_ok "README documents the refusal"     grep -q -- "--state-dir" "$HERE/../README.md"
assert_ok "README documents HARNESS_STATE_DIR_OK" grep -q "HARNESS_STATE_DIR_OK" "$HERE/../README.md"

echo "── 6. uninstall is guarded too (it DELETES a project's .harness/)"
out="$(run "$B" env STATE_DIR="$A/.harness" bash "$CLI" uninstall)"; rc=$?
TESTS_RUN=$((TESTS_RUN+1))
if [[ $rc -ne 0 ]] && grep -qi "refus" <<<"$out"; then
  echo "  ok: uninstall refuses a disagreeing inherited STATE_DIR"
else
  echo "  FAIL: uninstall refuses a disagreeing inherited STATE_DIR — rc=$rc out=[$out]"; TESTS_FAIL=$((TESTS_FAIL+1))
fi

finish

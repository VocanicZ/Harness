#!/usr/bin/env bash
# test_guard_set.sh — #1059: lanes run an always-run guard set (test/guards.sh) with Round 1, whatever rtdd selects. Half the real
# release-gate reds were repo-wide guards a lane's rtdd rounds never select (they read the whole tree; coverage picks only tests
# that execute the changed code). A test joins the set with a `# rtdd: always` header; the set is fast; the lane prompts say to run it;
# and a new HARNESS_* read with no docs row fails the set — the lane's pre-PR check — not the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
ROOT="$HERE/.."

# The set: the guards named in the issue, and none of the minutes-long ones.
set_list="$(bash "$HERE/guards.sh" list)"
for g in test_config_table.sh test_portable_guard.py test_session_backend.sh test_tmux_twins.sh test_py_runner_guard.sh test_prompt_label_lint.sh; do
  assert_ok "guard set holds $g" grep -qxF "$g" <<<"$set_list"
done
for slow in test_cli_readme.sh test_cli_matrix.sh test_cli_matrix_guard.sh test_guard_set.sh; do
  assert_ok "guard set leaves out $slow (waits on matrix cells, or is this test)" bash -c '! grep -qxF "$1" <<<"$2"' _ "$slow" "$set_list"
done
bad=""; while IFS= read -r f; do [[ -f $HERE/$f ]] || bad+=" $f"; done <<<"$set_list"
assert_eq "$bad" "" "every file in the set exists"

# Convention: the header, in the first 15 lines, as a whole comment line; a mention elsewhere is not a mark.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/test"; cp "$HERE/guards.sh" "$T/test/"
printf '#!/usr/bin/env bash\n# rtdd: always\ntrue\n' > "$T/test/test_marked.sh"
printf '#!/usr/bin/env python3\n# rtdd: always\n' > "$T/test/test_marked_py.py"
printf '#!/usr/bin/env bash\n# the header is `# rtdd: always`\ntrue\n' > "$T/test/test_mentions.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$T/test/test_plain.sh"
{ printf '#!/usr/bin/env bash\n'; for _ in $(seq 20); do echo '#'; done; echo '# rtdd: always'; } > "$T/test/test_late.sh"
assert_eq "$(bash "$T/test/guards.sh" list | tr '\n' ' ')" "test_marked.sh test_marked_py.py " "only a header line in the first 15 lines marks a test"
rm -f "$T/test/test_marked.sh" "$T/test/test_marked_py.py"
assert_eq "$(bash "$T/test/guards.sh" list)" "" "an empty set lists nothing"
assert_ok "an empty set is an error, not a green" bash -c '! bash "$1" run >/dev/null 2>&1' _ "$T/test/guards.sh"
assert_eq "$(bash "$HERE/guards.sh" bogus 2>&1 >/dev/null | head -1)" "usage: guards.sh [run|list]" "an unknown mode prints usage"

# The prompts a lane runs from say to run it (impl, bug-fix and resume all include _rtdd.md).
for p in impl bug-fix resume; do
  assert_ok "prompts/$p.md includes the rtdd partial" grep -q '{{> _rtdd.md}}' "$ROOT/prompts/$p.md"
done
assert_ok "_rtdd.md tells a lane to run bash test/guards.sh with Round 1" grep -qE 'bash test/guards\.sh.*Round 1|Round 1.*bash test/guards\.sh' "$ROOT/prompts/_rtdd.md"
assert_ok "_rtdd.md says the guard set is not the full suite" grep -qE 'NOT the full suite' "$ROOT/prompts/_rtdd.md"

# Acceptance: in a tree with the real runner and guard, a new HARNESS_* read with no docs row fails the set (the lane's pre-PR
# check), and the row turns it green again.
F="$T/tree"; mkdir -p "$F/test" "$F/scripts/cli" "$F/docs"
cp "$HERE/guards.sh" "$HERE/run.sh" "$HERE/helpers.sh" "$HERE/test_config_table.sh" "$F/test/"; cp -r "$HERE/guard" "$F/test/"
printf '%s\n' '## Configuration' '| `HARNESS_OLD` | x | an old setting |' '### Next' > "$F/docs/reference.md"
INTERNAL="$(printf 'echo "$%s"\n' $CONFIG_TABLE_INTERNAL)"   # the adapter still reads the engine-internal ones
printf '%s\n' 'echo "$HARNESS_OLD"' "$INTERNAL" > "$F/scripts/cli/a.sh"
out="$(bash "$F/test/guards.sh" 2>&1)"; rc=$?
assert_eq "$rc" "0" "fixture tree: every setting has a row -> the set is green"
printf '%s\n' 'echo "$HARNESS_OLD $HARNESS_FLEETS_DIR_LIKE_NEW"' "$INTERNAL" > "$F/scripts/cli/a.sh"
out="$(bash "$F/test/guards.sh" 2>&1)"; rc=$?
assert_ok "fixture tree: a new HARNESS_* read with no docs row fails the guard set" test "$rc" -ne 0
assert_ok "…and the report names test_config_table.sh and the setting" bash -c 'grep -q "FAILED: test_config_table.sh" <<<"$1" && grep -q HARNESS_FLEETS_DIR_LIKE_NEW <<<"$1"' _ "$out"
printf '%s\n' '## Configuration' '| `HARNESS_OLD` | x | y |' '| `HARNESS_FLEETS_DIR_LIKE_NEW` | x | y |' '### Next' > "$F/docs/reference.md"
bash "$F/test/guards.sh" >/dev/null 2>&1
assert_eq "$?" "0" "fixture tree: the docs row turns the set green again"

# Speed: the real set under the 60s the issue asks for (HARNESS_GUARD_SET_CAP raises it on a slow or loaded host).
cap="${HARNESS_GUARD_SET_CAP:-60}"
s=$SECONDS; out="$(bash "$HERE/guards.sh" 2>&1)"; rc=$?; took=$((SECONDS-s))
assert_eq "$rc" "0" "the real guard set is green on this tree"
assert_ok "the real guard set ran in ${took}s (cap ${cap}s)" test "$took" -lt "$cap"
finish

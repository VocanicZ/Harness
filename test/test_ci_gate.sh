#!/usr/bin/env bash
# test_ci_gate.sh — the default-branch CI gate and the prompts' merge gate (#50).
#
# The bug: the fleet's merge decision read mergeable-state only and never the check RESULT, so on a
# repo with no REQUIRED status check (private + free plan ⇒ branch protection and rulesets both 403)
# four PRs landed on a red default branch and nothing noticed for eleven hours. Two halves are
# guarded here, matching the two halves of the fix:
#   1. ci_gate_ok  — the pool holds NEW dispatch while the default branch is red (blast-radius cap).
#   2. the prompts — an impl/bug-fix session reads `gh pr checks` and refuses to merge red.
# Group 1 drives lib.sh directly through the ci_status_default_branch seam; no gh, no Actions run.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env

# Silence the gate's banner; capture it instead so the dedup behaviour is assertable.
LOG_LINES=""
log(){ LOG_LINES+="$*"$'\n'; }
# The seam every test below overrides — stands in for `issuelib ci-status <slug>`. The verdict is
# baked in at definition time (${1@Q}); closing over a local would leave it unset when the gate
# actually calls the stub.
set_ci(){ eval "ci_status_default_branch(){ printf '%s\n' ${1@Q}; }"; }

echo "-- group 1: ci_gate_ok"
HARNESS_CI_GATE=1

set_ci $'pass\t\t'
assert_ok "green default branch dispatches" ci_gate_ok acme/widget

set_ci $'fail\tci\thttps://gh/run/1'
assert_no "red default branch holds dispatch" ci_gate_ok acme/widget

# FAIL-OPEN is the whole safety story: a fleet that halts on uncertainty is worse than the bug it
# guards. Every not-positively-red verdict must dispatch.
set_ci $'unknown\t\t'
assert_ok "unknown verdict dispatches"        ci_gate_ok acme/widget
set_ci ""
assert_ok "empty output (issuelib HOLD/exit 3) dispatches" ci_gate_ok acme/widget
ci_status_default_branch(){ return 3; }
assert_ok "seam exits non-zero -> dispatches" ci_gate_ok acme/widget

# The escape hatch, for a project that would rather take its chances than ever stall.
HARNESS_CI_GATE=0
set_ci $'fail\tci\thttps://gh/run/1'
assert_ok "HARNESS_CI_GATE=0 disables the gate entirely" ci_gate_ok acme/widget
HARNESS_CI_GATE=1

echo "-- group 2: the banner is actionable and deduped"
_CI_GATE_LOGGED=""; LOG_LINES=""
set_ci $'fail\tneuro\thttps://gh/run/42'
ci_gate_ok acme/widget
assert_ok "banner names the workflow" grep -q "neuro" <<<"$LOG_LINES"
assert_ok "banner names the run url"  grep -q "https://gh/run/42" <<<"$LOG_LINES"
assert_ok "banner names the remedy"   grep -qi "bug lane is not gated" <<<"$LOG_LINES"
# A red branch is re-checked every poll; logging it every poll would bury the fleet log.
before="$(wc -l <<<"$LOG_LINES")"
ci_gate_ok acme/widget; ci_gate_ok acme/widget
assert_eq "$(wc -l <<<"$LOG_LINES")" "$before" "same failure logs once, not once per poll"
# ...but a DIFFERENT red run is news again.
set_ci $'fail\tneuro\thttps://gh/run/43'
ci_gate_ok acme/widget
assert_ok "a new failing run re-announces" test "$(wc -l <<<"$LOG_LINES")" -gt "$before"

echo "-- group 3: drive_unit consults the gate before dispatching"
# The gate must sit in the dispatch path, not merely exist. Drive one poll of drive_unit with a red
# branch and assert nothing was spawned; then green, and assert IMPL was.
source "$HERE/../scripts/drive.sh"
write_targets <<'EOF'
widget	acme/widget	-	root
EOF
SPAWNED=""
spawn_impl(){ SPAWNED+="IMPL:$1 "; }
spawn_orch(){ SPAWNED+="ORCH:$1 "; }
close_prd(){ :; }
reap_done_sessions(){ :; }; reap_team(){ :; }; watchdog_team(){ :; }; reap_finished_inject(){ :; }
count_team_sessions(){ echo 0; }
dispatch_actions(){ printf 'IMPL\t7\tISSUE 7 DONE\n'; }
POLL=0
# unit_complete is helpers.sh's file-backed stub; flip it after one pass so the loop terminates.
_PASSES=0
unit_complete(){ _PASSES=$((_PASSES+1)); (( _PASSES > 2 )); }

set_ci $'fail\tci\thttps://gh/run/9'
SPAWNED=""; _PASSES=0; _CI_GATE_LOGGED=""
drive_unit widget >/dev/null 2>&1
assert_eq "$SPAWNED" "" "red branch: drive_unit spawns nothing"

set_ci $'pass\t\t'
SPAWNED=""; _PASSES=0
drive_unit widget >/dev/null 2>&1
assert_ok "green branch: drive_unit spawns IMPL" grep -q "IMPL:7" <<<"$SPAWNED"

echo "-- group 4: the prompts refuse to merge a red PR"
# The engine cannot enforce this one — it lives in the agent's instructions — so pin the
# instruction text. Both merge-capable prompts must gate, and must gate BEFORE they merge.
for p in impl bug-fix; do
  f="$HERE/../prompts/$p.md"
  assert_ok "$p.md reads the check result"       grep -q 'gh pr checks' "$f"
  assert_ok "$p.md refuses to merge red"         grep -qi 'DO NOT MERGE' "$f"
  assert_ok "$p.md forbids weakening the check"  grep -qi 'never disable or weaken' "$f"
  assert_ok "$p.md withholds the promise on red" grep -qi 'is NOT a promise' "$f"
  # Ordering matters: a gate quoted after the merge step is decoration.
  gate="$(grep -n 'gh pr checks' "$f" | head -1 | cut -d: -f1)"
  merge="$(grep -n 'gh pr merge' "$f" | head -1 | cut -d: -f1)"
  assert_ok "$p.md gates BEFORE merging (gate@$gate < merge@$merge)" test "$gate" -lt "$merge"
done
# impl.md's autonomy clause must not be readable as "merge anyway".
assert_ok "impl.md says the gate overrides 'never park'" \
  grep -qi 'OVERRIDES the autonomy note' "$HERE/../prompts/impl.md"

finish

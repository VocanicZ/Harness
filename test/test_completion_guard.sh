#!/usr/bin/env bash
# test_completion_guard.sh — a unit held incomplete by an open ready child says so.
#
# is_complete now also requires open_children == 0, so a state that used to be unreachable is
# reachable: not complete, nothing in flight, nothing dispatchable. drive_unit polls there
# indefinitely — correct (the work really is outstanding) but it must not be silent, and in multi
# topology it holds every dependent unit behind deps_complete. dispatch_stalled_banner is the
# mitigation, and this pins it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
source "$HERE/../scripts/drive.sh"

LOG_LINES=""
log(){ LOG_LINES+="$*"$'\n'; }
write_targets <<'EOF'
widget	acme/widget	-	root
EOF
SPAWNED=""
spawn_impl(){ SPAWNED+="IMPL:$1 "; }
spawn_orch(){ SPAWNED+="ORCH:$1 "; }
close_prd(){ SPAWNED+="CLOSE:$1 "; }
reap_done_sessions(){ :; }; reap_team(){ :; }; watchdog_team(){ :; }; reap_finished_inject(){ :; }
count_team_sessions(){ echo 0; }
ci_status_default_branch(){ printf 'pass\t\t\n'; }
POLL=0
# The status read behind the banner — the seam, stubbed so no gh is needed.
STATUS_LINE="acme/widget: mode=prd PRD#61(closed) plan=N children=9 open=1 unblocked=0 paused=0 reviewed=Y complete=N"
run_one_poll(){  # drive_unit for exactly one pass
  _PASSES=0
  unit_complete(){ _PASSES=$((_PASSES+1)); (( _PASSES > 1 )); }
  drive_unit widget >/dev/null 2>&1
}

echo "-- group 1: a stalled unit announces itself"
python3(){ [[ "${2:-}" == status ]] && { printf '%s\n' "$STATUS_LINE"; return 0; }; return 0; }
dispatch_actions(){ printf ''; }          # nothing dispatchable
_STALL_LOGGED=""; LOG_LINES=""; SPAWNED=""
run_one_poll
assert_ok "a stalled unit logs a banner"        grep -q "nothing dispatchable" <<<"$LOG_LINES"
assert_ok "the banner carries the status line"  grep -q "open=1 unblocked=0" <<<"$LOG_LINES"
assert_ok "the banner names the remedy"         grep -qi "close or unblock it" <<<"$LOG_LINES"
assert_eq "$SPAWNED" "" "a stalled unit spawns nothing"

echo "-- group 2: deduped on the state, so a stuck unit is not a log firehose"
# Count BANNERS, not log lines — every poll logs its own unrelated "drive …" line either way.
banners(){ grep -c "nothing dispatchable" <<<"$LOG_LINES"; }
assert_eq "$(banners)" "1" "the first stall announces once"
run_one_poll; run_one_poll
assert_eq "$(banners)" "1" "the same stalled state logs once, not once per poll"
STATUS_LINE="acme/widget: mode=prd PRD#61(closed) plan=N children=9 open=2 unblocked=0 paused=0 reviewed=Y complete=N"
run_one_poll
assert_eq "$(banners)" "2" "a CHANGED state re-announces"

echo "-- group 3: it fires only when genuinely idle"
# Work available -> dispatch, no banner. This is the common path and must stay quiet.
dispatch_actions(){ printf 'IMPL\t80\tISSUE 80 DONE\n'; }
_STALL_LOGGED=""; LOG_LINES=""; SPAWNED=""
run_one_poll
assert_ok "dispatchable work spawns"          grep -q "IMPL:80" <<<"$SPAWNED"
assert_no "dispatchable work logs no banner"  grep -q "nothing dispatchable" <<<"$LOG_LINES"

# Sessions in flight -> not idle, so no banner even with an empty dispatch (the cap is simply full).
dispatch_actions(){ printf ''; }
count_team_sessions(){ echo 2; }
_STALL_LOGGED=""; LOG_LINES=""; SPAWNED=""
run_one_poll
assert_no "in-flight sessions log no banner" grep -q "nothing dispatchable" <<<"$LOG_LINES"
count_team_sessions(){ echo 0; }

# A transient gh HOLD makes dispatch print nothing AND the status read fail. Empty status must be
# swallowed rather than logged as a stall — a rate limit is not a stuck unit.
python3(){ return 3; }
_STALL_LOGGED=""; LOG_LINES=""
run_one_poll
assert_no "a gh HOLD is not reported as a stall" grep -q "nothing dispatchable" <<<"$LOG_LINES"

unset -f python3
finish

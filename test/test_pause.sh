#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/helpers.sh"; make_env
assert_no "not paused initially" is_paused
touch "$PAUSE_FLAG"
assert_ok "paused after flag created" is_paused
rm -f "$PAUSE_FLAG"
assert_no "not paused after flag removed" is_paused
# config default present
assert_eq "$HARNESS_LABEL_PAUSED" "agent-paused" "default paused label"

# --- worker_tick idles (rc 3) when paused, without claiming -------------------
source "$HERE/../drive.sh" 2>/dev/null || true
source "$HERE/../pool-worker.sh" 2>/dev/null || true
HARNESS_TOPOLOGY=multi
write_targets <<'EOF'
a	acme/a	-	root
EOF
set_complete
claimed=""
claim_next(){ claimed=yes; echo a; }   # if called, we'd see claimed=yes
touch "$PAUSE_FLAG"
worker_tick W1; rc=$?
assert_eq "$rc" "3" "worker_tick returns 3 when paused"
assert_eq "$claimed" "" "worker_tick did NOT claim while paused"
rm -f "$PAUSE_FLAG"

# --- drive_unit drains (breaks) when paused, without dispatching --------------
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; CAP=2; POLL=0
dispatched=""
reap_done_sessions(){ :; }; reap_team(){ :; }; count_team_sessions(){ echo 0; }
dispatch_actions(){ dispatched=yes; printf 'IMPL\t5\tISSUE 5 DONE\n'; }
spawn_impl(){ dispatched=spawned; }
unit_complete(){ return 1; }   # never complete on its own
touch "$PAUSE_FLAG"
drive_unit main
assert_eq "$dispatched" "" "drive_unit did NOT dispatch while paused (drained immediately)"
rm -f "$PAUSE_FLAG"

# --- pause.sh (soft) creates the flag -----------------------------------------
RUN_DIR2="$(mktemp -d)"
RUN_DIR="$RUN_DIR2" bash "$HERE/../pause.sh" >/dev/null 2>&1
assert_ok "soft pause.sh created PAUSED flag" bash -c "[[ -f '$RUN_DIR2/PAUSED' ]]"
rm -rf "$RUN_DIR2"

# --- pause --force: injects checkpoint, confirms via label, never kills -------
RUN_DIR3="$(mktemp -d)"; CALLS="$RUN_DIR3/calls"; : > "$CALLS"
export CALLS
export HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme HARNESS_PAUSE_GRACE=2
# one live impl session for unit "main", issue 5
tmux(){ echo "tmux $*" >> "$CALLS"
  case "$1" in
    ls) echo "hz-main-i5";;
    send-keys) : ;;
    kill-session) : ;;   # if ever called, recorded above
  esac; }
# gh: issue already carries the paused label -> confirms immediately
gh(){ echo "gh $*" >> "$CALLS"
  case "$1 $2" in
    "issue view") echo '{"labels":[{"name":"agent-paused"}]}';;
  esac; return 0; }
export -f tmux gh
RUN_DIR="$RUN_DIR3" bash "$HERE/../pause.sh" --force >/dev/null 2>&1
assert_ok "force: PAUSED flag set"            bash -c "[[ -f '$RUN_DIR3/PAUSED' ]]"
assert_ok "force: checkpoint sent to session" bash -c "grep -q 'send-keys' '$CALLS'"
assert_no "force: never killed the session"   bash -c "grep -q 'kill-session' '$CALLS'"
rm -rf "$RUN_DIR3"

finish

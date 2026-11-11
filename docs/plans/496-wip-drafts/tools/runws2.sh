#!/usr/bin/env bash
# runws2.sh <name> <mode> <stages>: ws_run plus a one-off repair step after the lock is taken (the first e2e run's damage to the owner's skills)
SC=$(dirname "$(readlink -f "$0")")
export WINSMA_SSH=$SC/wsssh.sh HARNESS_WINDOWS_HOST=winsma WS_LANE_SESSION=hzhn-harness-i496 WS_LANE_PID=${LANE_PID:-$$}
export WS_LOG=$SC/$1.log; mode=$2; stages=$3
WSH_DIR=$SC/x; set -uo pipefail
for f in common lock park isolate guard credentials cleanup; do source "$WSH_DIR/$f.sh"; done
issue=496; rc=0; step=""
cmd="export HX_STAGES='$stages' HX_BRANCH=issue/496; $(cat $SC/x/e2e.sh)"
ws_log "run: #$issue on $(ws_host), mode $mode, stages $stages (repair first: $([[ -f $SC/repair-body.sh && -z ${NO_REPAIR:-} ]] && echo yes || echo no))"
trap 'ws_cleanup "$issue" >/dev/null 2>&1' INT TERM
WS_LOCK_RUN=1 ws_lock "$issue" || exit 1
if [[ -z ${NO_REPAIR:-} && -f $SC/repair-body.sh ]]; then
  ws_log "repair: relinking the skills the first run's supervisor moved"
  ws_call_script() { :; }
  bash -c "$WINSMA_SSH" < $SC/repair-body.sh 2>&1 | tee -a "$WS_LOG"
fi
ws_isolate "$issue" || step=isolate
[[ -z "$step" ]] && { ws_guard "$issue" before || step="guard before"; }
[[ -z "$step" && -n "$(ws_token)" ]] && { ws_scan "$issue" before || step="scan before"; }
if [[ -z "$step" ]]; then out="$(mktemp)"; ws_log "exec: e2e stages $stages"; WS_CAP_CHECK=0 WS_SENTINEL=1 ws_exec "$issue" "$mode" "$cmd" 2>&1 | tee "$out" | tee -a "$WS_LOG"
  [[ "${PIPESTATUS[0]}" == 0 ]] || step="command"
  grep -q '^WS-EXIT ' "$out" || { ws_log "exec: remote shell ended without WS-EXIT"; step=command; }; rm -f "$out"; fi
[[ "$step" == isolate || "$step" == "guard before" || "$step" == "scan before" ]] || {
  ws_guard "$issue" after || step="${step:+$step, }guard after"
  [[ -n "$(ws_token)" ]] && { ws_scan "$issue" after || step="${step:+$step, }scan after"; }; }
ws_cleanup "$issue" || step="${step:+$step, }cleanup"
[[ -z "$step" ]] && { ws_log "run: OK"; exit 0; }
ws_log "run: FAILED at $step"; exit 1

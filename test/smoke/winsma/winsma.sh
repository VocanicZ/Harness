#!/usr/bin/env bash
# winsma.sh — drive the owner's Windows check host from the claude host (#479, PRD #475). See docs/windows-smoke.md.
#
#   winsma.sh host                         print HARNESS_WINDOWS_HOST (exit 1 if unset)
#   winsma.sh lock <issue> [session] [pid] take C:\hx-lock (FIFO queue; wait your turn), start the heartbeat loop
#   winsma.sh unlock <issue>               release it
#   winsma.sh park <issue> [owner/repo]    queued and not next: keep the ticket, swap agent-working for waiting-winsma, free the pool slot (#1034)
#                                          `park <prd> <owner/repo> --review`: the PRD review lane (#1038)
#   winsma.sh turn <issue>                 (engine) refresh a parked issue's ticket; exit 0 = it is next, 1 = waiting, 2 = host unreachable
#   winsma.sh status                       who holds the lock, for how long, and the queue in order
#   winsma.sh isolate <issue> [--venv]     create C:\hx-<issue>\ (and a python venv in it)
#   winsma.sh env <issue> [base|install|suite]   the export lines for that mode
#   winsma.sh exec <issue> <mode> <command>      run one command inside the isolation (token on stdin)
#   winsma.sh guard <issue> before|after   record / compare the machine files, Harness\* tasks, ~/.claude.json
#   winsma.sh scan <issue> before|after    GH_TOKEN leak scan
#   winsma.sh task-add <issue> <name> <command>  | pid-add <issue> <pid>   record a task / process of the run
#   winsma.sh cleanup <issue>              kill, delete, release, check winsma is clean
#   winsma.sh run <issue> [mode] <command> the whole sequence: lock → isolate → guard → command → guard → scan → cleanup
set -uo pipefail
WSH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in common lock park isolate guard credentials cleanup; do source "$WSH_DIR/$f.sh"; done

# ws_run <issue> <mode> <command> — cleanup always runs; the exit status is 0 only if every step held.
ws_run(){ local issue="$1" mode="$2" cmd="$3" rc=0 step=""
  ws_log "run: #$issue on $(ws_host), mode $mode: $cmd"
  trap 'ws_cleanup "$issue" >/dev/null 2>&1' INT TERM
  WS_LOCK_RUN=1 ws_lock "$issue" || { return 1; }
  ws_isolate "$issue" || step=isolate
  [[ -z "$step" ]] && { ws_guard "$issue" before || step="guard before"; }
  [[ -z "$step" && -n "$(ws_token)" ]] && { ws_scan "$issue" before || step="scan before"; }
  if [[ -z "$step" ]]; then local out; out="$(mktemp)"; ws_log "exec: $cmd"; WS_CAP_CHECK=0 WS_SENTINEL=1 ws_exec "$issue" "$mode" "$cmd" 2>&1 | tee "$out" | tee -a "${WS_LOG:-/dev/null}"
    local erc="${PIPESTATUS[0]}"
    [[ "$erc" == 0 ]] || step="command"
    # The remote shell reports its command's status as its last line: without it the command killed its own shell (#496).
    grep -q '^WS-EXIT ' "$out" || { ws_log "exec: the remote shell ended without reporting an exit status (the command killed it)"; step="command"; }
    rm -f "$out"; fi
  [[ "$step" == isolate || "$step" == "guard before" || "$step" == "scan before" ]] || {
    ws_guard "$issue" after || step="${step:+$step, }guard after"
    [[ -n "$(ws_token)" ]] && { ws_scan "$issue" after || step="${step:+$step, }scan after"; }; }
  ws_cleanup "$issue" || step="${step:+$step, }cleanup"
  trap - INT TERM
  [[ -z "$step" ]] && { ws_log "run: OK"; return 0; }
  ws_log "run: FAILED at $step"; return 1; }

main(){ local cmd="${1:-}"; shift || true
  case "$cmd" in
    host)     ws_need_host && echo;;
    lock)     ws_lock "$@";;
    unlock)   ws_unlock "$@";;
    status)   ws_status;;
    park)     ws_park "$@";;
    turn)     ws_turn "$@";;
    isolate)  ws_isolate "$@";;
    env)      ws_env "$@";;
    exec)     ws_exec "$@";;
    guard)    ws_guard "$@";;
    scan)     ws_scan "$@";;
    task-add) ws_task_add "$@";;
    pid-add)  ws_pid_add "$@";;
    cleanup)  ws_cleanup "$@";;
    run)      if [[ $# -ge 3 ]]; then ws_run "$1" "$2" "$3"; else ws_run "$1" base "$2"; fi;;
    *) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p;' | head -25 >&2; return 2;;
  esac; }
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"

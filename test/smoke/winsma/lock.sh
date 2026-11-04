#!/usr/bin/env bash
# lock.sh — the C:\hx-lock lock (#479, PRD #475 "The winsma lock"). Sourced by winsma.sh; needs common.sh.
#   WS_POLL         seconds between polls while someone else holds it (default 300, the rule)
#   WS_STALE_SEC    heartbeat age past which a lock MAY be broken (default 1800)
#   WS_LOCK_TIMEOUT seconds to wait at most (default 0 = as long as it takes)
#   WS_OWNER_LIVE_CMD  test seam: `<session> <host_pid>` exits 0 while the owner lane is live on this host
# A lane that finds the lock held WAITS. It never labels itself agent-paused (that trips the #417 self-park
# nudge and checkpoint churn): the winsma-heavy tasks are chained with `Blocked by` to keep waits rare.
ws_owner_live(){ local session="$1" pid="$2"
  if [[ -n "${WS_OWNER_LIVE_CMD:-}" ]]; then $WS_OWNER_LIVE_CMD "$session" "$pid"; return; fi
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && return 0
  [[ -n "$session" && "$session" != - ]] && command -v tmux >/dev/null 2>&1 && tmux has-session -t "$session" 2>/dev/null && return 0
  return 1; }
# ws_lock <issue> [session] [host_pid] — take the lock (waiting or breaking a stale one), then start the heartbeat loop.
ws_lock(){ local issue="$1" session="${2:-${WS_LANE_SESSION:-lane-$1}}" pid="${3:-${WS_LANE_PID:-$PPID}}"
  ws_need_host >/dev/null || return 1
  local stale="${WS_STALE_SEC:-1800}" poll="${WS_POLL:-300}" started rc state o oi os op age; started=$SECONDS
  while :; do
    ws_call r_lock_take "$issue" "$session" "$pid"; rc=$?
    if (( rc == 0 )); then
      ws_call r_hb_start "$issue" >/dev/null || { ws_die "taken, but the heartbeat loop did not start"; return 1; }
      ws_log "lock: hx-lock taken by #$issue ($session)"; return 0
    fi
    (( rc == 1 )) || { ws_die "could not reach the lock (exit $rc)"; return 1; }
    state="$(ws_call r_lock_state)" || { ws_die "could not read the lock"; return 1; }
    read -r o oi os op age <<<"$state"
    if [[ "$o" == free ]]; then continue; fi
    if (( age > stale )); then
      if [[ "$oi" == - ]]; then
        ws_call r_lock_drop_orphan "$stale" && { ws_log "lock: dropped an ownerless stale hx-lock"; continue; }
      elif ! ws_owner_live "$os" "$op"; then
        ws_log "lock: #$oi ($os) heartbeat is ${age}s old and its lane is gone; breaking it"
        ws_call r_lock_break "$oi" "$stale" && continue
      fi
    fi
    if (( ${WS_LOCK_TIMEOUT:-0} > 0 && SECONDS - started >= WS_LOCK_TIMEOUT )); then
      { ws_die "hx-lock still held by #$oi after ${WS_LOCK_TIMEOUT}s"; return 1; }
    fi
    ws_log "lock: held by #$oi ($os), heartbeat ${age}s old; waiting ${poll}s"
    sleep "$poll"
  done; }
ws_unlock(){ ws_call r_lock_release "$1"; }

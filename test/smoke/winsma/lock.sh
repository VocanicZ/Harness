#!/usr/bin/env bash
# lock.sh — the C:\hx-lock lock (#479, PRD #475 "The winsma lock"). Sourced by winsma.sh; needs common.sh.
#   WS_POLL         seconds between polls while someone else holds it (default 300, the rule)
#   WS_STALE_SEC    heartbeat age past which a lock MAY be broken (default 1800)
#   WS_LOCK_TIMEOUT seconds to wait at most (default 0 = as long as it takes)
#   WS_HOLD_MAX     seconds one acquisition may run commands while another lane is queued (default 5400): past it
#                   `exec` refuses to START a command, so the holder releases and re-queues (#1033)
#   WS_HOLD_HARD    seconds past which the queue's first lane may break even a LIVE holder (default 3x WS_HOLD_MAX, 0 = never)
#   WS_OWNER_LIVE_CMD  test seam: `<session> <host_pid>` exits 0 while the owner lane is live on this host
# A lane that finds the lock held WAITS. It never labels itself agent-paused (that trips the #417 self-park
# nudge and checkpoint churn): the winsma-heavy tasks are chained with `Blocked by` to keep waits rare.
ws_owner_live(){ local session="$1" pid="$2"
  if [[ -n "${WS_OWNER_LIVE_CMD:-}" ]]; then $WS_OWNER_LIVE_CMD "$session" "$pid"; return; fi
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && return 0
  [[ -n "$session" && "$session" != - ]] && command -v tmux >/dev/null 2>&1 && tmux has-session -t "$session" 2>/dev/null && return 0
  return 1; }
# ws_clock_ms — milliseconds on a monotonic-enough wall clock (test seam: a test redefines it). EPOCHREALTIME is bash 5+;
# without it only whole seconds are known, so ws_lock_expired demands a whole extra second rather than risk giving up early.
ws_clock_ms(){ if [[ -n "${EPOCHREALTIME:-}" ]]; then local t="${EPOCHREALTIME/[.,]/}"; echo $(( 10#$t / 1000 ))
  else echo $(( SECONDS * 1000 )); fi; }
# ws_lock_expired <started_ms> — has WS_LOCK_TIMEOUT real seconds passed since <started_ms>? Never true early (#682): a whole-second
# clock reads 1s after as little as a few ms, so on one the elapsed time must EXCEED the timeout, which makes it at least that long.
ws_lock_expired(){ local to="${WS_LOCK_TIMEOUT:-0}" slack=0 now; (( to > 0 )) || return 1
  [[ -n "${EPOCHREALTIME:-}" ]] || slack=1000; now="$(ws_clock_ms)"; (( now - $1 >= to * 1000 + slack )); }
# ws_lock <issue> [session] [host_pid] — take the lock in FIFO order (#1033): a lane that finds it held, or finds a lane queued
# ahead of it, takes a ticket in C:\hx-queue and waits its turn; a stale break or a hard-ceiling break clears the way.
# Then start the heartbeat loop. Releasing and asking again sends the lane to the back of the queue.
ws_lock(){ local issue="$1" session="${2:-${WS_LANE_SESSION:-lane-$1}}" pid="${3:-${WS_LANE_PID:-$PPID}}"
  ws_need_host >/dev/null || return 1
  local stale="${WS_STALE_SEC:-1800}" poll="${WS_POLL:-300}" hmax="${WS_HOLD_MAX:-5400}" hard started rc info line o oi os op age hold
  local q qn qi qs qp qw qa pos total dead; hard="${WS_HOLD_HARD:-$(( hmax * 3 ))}"; started="$(ws_clock_ms)"
  while :; do
    info="$(ws_call r_lock_info)" || { ws_die "could not read the lock"; return 1; }
    dead=0
    while read -r q qn qi qs qp qw qa; do   # a dead waiter must not block the line: refresh stale AND its lane gone
      [[ "$q" == q ]] || continue
      (( qa > stale )) && [[ "$qi" != "$issue" ]] && ! ws_owner_live "$qs" "$qp" \
        && { ws_log "lock: queue ticket of #$qi ($qs) is ${qa}s stale and its lane is gone; dropping it"; ws_call r_queue_drop "$qn" "$stale" && dead=1; }
    done <<<"$info"
    (( dead )) && { info="$(ws_call r_lock_info)" || { ws_die "could not read the lock"; return 1; }; }
    ws_call r_lock_take "$issue" "$session" "$pid"; rc=$?
    if (( rc == 0 )); then
      ws_call r_hb_start "$issue" >/dev/null || { ws_die "taken, but the heartbeat loop did not start"; return 1; }
      ws_log "lock: hx-lock taken by #$issue ($session)"; return 0
    fi
    (( rc == 1 )) || { ws_die "could not reach the lock (exit $rc)"; return 1; }
    ws_call r_queue_join "$issue" "$session" "$pid" >/dev/null || { ws_die "could not take a place in the queue"; return 1; }
    info="$(ws_call r_lock_info)" || { ws_die "could not read the lock"; return 1; }
    pos=0; total=0
    while read -r q qn qi _; do [[ "$q" == q ]] || continue; total=$((total+1)); [[ "$qi" == "$issue" ]] && pos=$total; done <<<"$info"
    line="$(head -1 <<<"$info")"; read -r o oi os op age hold <<<"$line"
    if [[ "$o" == free ]]; then   # free, but a lane queued earlier is ahead: wait for its poll, no spinning
      ws_log "lock: free, but #$(awk '$1=="q"{print $3; exit}' <<<"$info") is first in the queue; queue position $pos of $total; waiting ${poll}s"
    else
      if (( age > stale )); then
        if [[ "$oi" == - ]]; then
          ws_call r_lock_drop_orphan "$stale" && { ws_log "lock: dropped an ownerless stale hx-lock"; continue; }
        elif ! ws_owner_live "$os" "$op"; then
          ws_log "lock: #$oi ($os) heartbeat is ${age}s old and its lane is gone; breaking it"
          ws_call r_lock_break "$oi" "$stale" && continue
        fi
      fi
      # The hard ceiling: a runaway command can hold a live lane's lock for ever. Only the first in line may break it.
      if (( hard > 0 && hold > hard && pos == 1 )) && [[ "$oi" != - && "$oi" != "$issue" ]]; then
        ws_log "lock: #$oi ($os) has held hx-lock ${hold}s, past WS_HOLD_HARD ${hard}s, and #$issue is first in the queue; breaking it"
        ws_call r_lock_break_hold "$oi" "$hard" && continue
      fi
      # Say who holds it BEFORE the timeout check (#682): every waiter that finds a held lock tells the operator at least once.
      ws_log "lock: held by #$oi ($os), heartbeat ${age}s old, held ${hold}s; queue position $pos of $total; waiting ${poll}s"
    fi
    if ws_lock_expired "$started"; then
      ws_call r_queue_leave "$issue" >/dev/null
      { ws_die "hx-lock still held by #${oi:--} after ${WS_LOCK_TIMEOUT}s"; return 1; }
    fi
    sleep "$poll"
  done; }
ws_unlock(){ ws_call r_lock_release "$1"; }
# ws_hold_gate <issue> — refuse to START a command once the issue has held the lock past WS_HOLD_MAX while another lane is queued
# (#1033). Exits 3 with the reason; a host that cannot be asked does not stop the command (the command would fail itself).
ws_hold_gate(){ local msg rc
  msg="$(ws_call r_hold_gate "$1" "${WS_HOLD_MAX:-5400}" "${WS_STALE_SEC:-1800}" 2>&1)"; rc=$?
  (( rc == 3 )) || return 0
  ws_die "$msg"; return 3; }
# ws_status — the lock and its queue, for `harness status` and operators (#1033).
ws_status(){ local info line o oi os op age hold q qn qi qs qp qw qa n=0
  info="$(ws_call r_lock_info 2>/dev/null)" || { echo "winsma: unreachable"; return 1; }
  line="$(head -1 <<<"$info")"; [[ -n "$line" ]] || { echo "winsma: unreachable"; return 1; }
  read -r o oi os op age hold <<<"$line"
  if [[ "$o" == free ]]; then echo "  winsma lock: free"
  else echo "  winsma lock: held by #$oi ($os) for $(ws_dur "$hold"), heartbeat ${age}s old"; fi
  while read -r q qn qi qs qp qw qa; do [[ "$q" == q ]] || continue; n=$((n+1))
    printf '    queue %d: #%s (%s) waiting %s\n' "$n" "$qi" "$qs" "$(ws_dur "$qw")"; done <<<"$info"
  (( n )) || echo "    queue: empty"; return 0; }
ws_dur(){ local s="${1:-0}"; if (( s >= 3600 )); then printf '%dh%02dm' $((s/3600)) $((s%3600/60)); elif (( s >= 60 )); then printf '%dm%02ds' $((s/60)) $((s%60)); else printf '%ds' "$s"; fi; }

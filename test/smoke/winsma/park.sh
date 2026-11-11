#!/usr/bin/env bash
# park.sh — a lane waiting for the winsma lock gives up its pool slot (#1034, follows the FIFO queue of #1033). Sourced by
# winsma.sh; needs common.sh and lock.sh.
#   winsma.sh park <issue> [owner/repo]   the LANE, queued and not next: keep the ticket, post a handoff, swap agent-working
#                                         for the waiting label (HARNESS_LABEL_WAITING_WINSMA, default waiting-winsma). The
#                                         engine then ends the session and does not dispatch the issue until its ticket is next.
#                                         `park <prd> [owner/repo] --review` is the PRD review lane (#1038): no push check (its worktree is never
#                                         pushed), the PRD gets the waiting label only, and the review is re-dispatched as REVIEW:<prd>.
#   winsma.sh turn <issue>                the ENGINE, each tick, for a parked issue: refresh its ticket (the lane is gone, so a
#                                         refresh is what keeps the place) and say whether it is next. exit 0 = next, 1 = still
#                                         waiting, 2 = the host could not be asked (the issue stays parked).
# The waiting label is NOT agent-paused: no HARNESS CHECKPOINT was sent, and the #417 self-park nudge keys on agent-paused.
#   WS_PARK_CHECK_PUSHED  1 (default) = refuse to park from a dirty worktree or an unpushed HEAD: the session is ended on the swap
ws_turn(){ local issue="$1" stale="${WS_STALE_SEC:-1800}" info line o oi os op age hold q qn qi first="" pos=0 total=0
  [[ "$issue" =~ ^[0-9]+$ ]] || { ws_die "issue must be a number, got '$issue'"; return 2; }
  ws_need_host >/dev/null || return 2
  ws_call r_queue_join "$issue" "parked-$issue" - >/dev/null || { ws_die "could not refresh the ticket of #$issue"; return 2; }
  info="$(ws_call r_lock_info)" || { ws_die "could not read the lock"; return 2; }
  while read -r q qn qi _; do [[ "$q" == q ]] || continue; total=$((total+1)); [[ -n "$first" ]] || first="$qi"
    [[ "$qi" == "$issue" ]] && pos=$total; done <<<"$info"
  line="$(head -1 <<<"$info")"; read -r o oi os op age hold <<<"$line"
  [[ -n "$o" ]] || { ws_die "could not read the lock"; return 2; }
  if [[ "$first" != "$issue" ]]; then echo "waiting: queue position $pos of $total"; return 1; fi
  if [[ "$o" == free ]]; then echo "ready: hx-lock is free and #$issue is first in the queue"; return 0; fi
  # A holder whose lane is gone (heartbeat past WS_STALE_SEC) is broken by the lane that asks next: wake it, a parked queue has no one else to.
  if [[ "$oi" != "$issue" ]] && (( age > stale )) && ! ws_owner_live "$os" "$op"; then
    echo "ready: #$oi ($os) holds hx-lock but its heartbeat is ${age}s old and its lane is gone"; return 0; fi
  echo "waiting: held by #$oi ($os); first in the queue"; return 1; }
# ws_park_pushed — 0 when the worktree is clean and HEAD is on origin under the same branch name (the session ends on the swap).
ws_park_pushed(){ local br head remote
  git rev-parse --git-dir >/dev/null 2>&1 || { ws_die "park: not in a git worktree"; return 1; }
  [[ -z "$(git status --porcelain 2>/dev/null)" ]] || { ws_die "park: uncommitted changes — commit and push first (the session is ended when you park)"; return 1; }
  br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; head="$(git rev-parse HEAD 2>/dev/null)"
  remote="$(git ls-remote origin "refs/heads/$br" 2>/dev/null | awk '{print $1}' | head -1)"
  [[ -n "$remote" && "$remote" == "$head" ]] || { ws_die "park: $br is not pushed (HEAD $head, origin ${remote:-has no such branch}) — push first"; return 1; }
  return 0; }
ws_park(){ local issue="$1" slug="" work waiting br rc review=0 a; shift
  for a in "$@"; do case "$a" in --review) review=1;; *) [[ -n "$slug" ]] || slug="$a";; esac; done
  slug="${slug:-${HARNESS_REPO:-}}"
  [[ "$issue" =~ ^[0-9]+$ ]] || { ws_die "issue must be a number, got '$issue'"; return 1; }
  [[ -n "$slug" ]] || { ws_die "park: no repo — pass owner/repo"; return 1; }
  ws_need_host >/dev/null || return 1
  work="${HARNESS_LABEL_WORKING:-agent-working}"; waiting="${HARNESS_LABEL_WAITING_WINSMA:-waiting-winsma}"
  # --review (#1038): the PRD review lane. Its work is a throwaway worktree that is never pushed and its issue is the PRD, which never
  # carries agent-working: nothing to push or to hand over but a comment, and one label to add.
  if (( review == 0 )) && [[ "${WS_PARK_CHECK_PUSHED:-1}" != 0 ]]; then ws_park_pushed || return 1; fi
  br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "issue/$issue")"
  # The ticket first: the place is what the park keeps. A lane that never queued takes one at the back now.
  ws_call r_queue_join "$issue" "parked-$issue" - >/dev/null || { ws_die "park: could not keep a place in the queue"; return 1; }
  ws_turn "$issue" >/dev/null; rc=$?
  (( rc == 0 )) && { ws_die "park: #$issue is next and hx-lock is free — take the lock instead of parking"; return 4; }
  (( rc == 2 )) && return 1
  if (( review )); then
    gh issue comment "$issue" -R "$slug" --body "<!-- harness-winsma-review-park prd=$issue -->
Parked in the winsma lock queue (#1038): the review of PRD #$issue was waiting for hx-lock and gave up its pool slot. Its ticket in the queue is kept for #$issue, so the place is not lost. Harness re-dispatches the review once the ticket is next and the lock is free. On the re-dispatch: the Linux full-suite result and the other review findings are in the comments above; take the lock with winsma.sh (it succeeds at once, without queueing behind a lane that queued after you), run the Windows suite and finish the review." >/dev/null \
      || { ws_die "park: could not post the handoff comment"; return 1; }
    gh issue edit "$issue" -R "$slug" --add-label "$waiting" >/dev/null || { ws_die "park: could not add $waiting"; return 1; }
    ws_log "park: the review of PRD #$issue parked in the winsma queue ($waiting); its session ends and the review is re-dispatched when its ticket is next"
    return 0
  fi
  gh issue comment "$issue" -R "$slug" --body "<!-- harness-handoff issue=$issue branch=$br -->
Parked in the winsma lock queue (#1034): this lane was waiting for hx-lock and gave up its pool slot. The branch \`$br\` is pushed; its ticket in the queue is kept for #$issue, so the place is not lost. Harness re-dispatches the issue as a resume once the ticket is next and the lock is free. On resume: take the lock again with winsma.sh (it succeeds at once, without queueing behind a lane that queued after you) and run the Windows step you were waiting for." >/dev/null \
    || { ws_die "park: could not post the handoff comment"; return 1; }
  # ONE edit: add the waiting label and drop agent-working together, so the issue is never seen with neither.
  gh issue edit "$issue" -R "$slug" --add-label "$waiting" --remove-label "$work" >/dev/null \
    || { ws_die "park: could not swap $work for $waiting"; return 1; }
  ws_log "park: #$issue parked in the winsma queue ($waiting); its session ends and the issue is re-dispatched when its ticket is next"
  return 0; }

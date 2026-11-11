#!/usr/bin/env bash
# status.sh [--watch [secs]] — Harness fleet dashboard.
#   (no args)        print once and exit
#   --watch          live refresh every 8s (Ctrl-C to quit — does NOT stop the fleet)
#   --watch 10       live refresh every 10s
# Top section is a plain RUNNING/STOPPED verdict for at-a-glance status.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

iter_of(){ [[ -f "$1/.claude/ralph-loop.local.md" ]] && grep -m1 '^iteration:' "$1/.claude/ralph-loop.local.md" | tr -dc '0-9' || echo '?'; }
pid_up(){ [[ -f "$1" ]] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }

# fleet_verdict <up> <total> <sess_total> <done_n> <all_n> <paused:0|1> [lane_up:0|1] — the
# one-line at-a-glance state. Precedence: PAUSED (forced-drain) > DEGRADED (no pid alive but a
# fleet tmux session outlived an unclean death — see below) > STOPPED (NOTHING live: no pool
# worker AND no priority lane #35) > LANE-ONLY (pool down but the lane is alive #35) >
# IDLE/WATCHING (resident #24: workers up but all work complete, just polling) > RUNNING.
fleet_verdict(){
  local up="$1" total="$2" sess="$3" done_n="$4" all_n="$5" paused="$6" lane_up="${7:-0}"
  if [[ "$paused" == 1 ]]; then
    echo "PAUSED   (drained — workers idle; resume: harness/resume.sh)"
  elif (( up == 0 && lane_up == 0 && sess > 0 )); then
    # No pool worker and no lane pid is alive, yet detached claude tmux session(s) are still
    # live: the pool/lane died UNCLEANLY (kill -9 / host crash) and the tmux server outlived
    # it. Reporting STOPPED would lure the operator into a plain `start`, relaunching workers
    # that re-claim units whose claude sessions are already live -> double-dispatch. Flag it as
    # DEGRADED and point at the crash-safe path instead.
    echo "DEGRADED ($sess fleet session(s) live but no worker/lane pid — unclean death; do NOT plain-start, run: harness/start.sh --recover)"
  elif (( up == 0 && lane_up == 0 )); then
    echo "STOPPED  (pool not running — start with: harness/start.sh)"
  elif (( up == 0 )); then
    echo "RUNNING  (pool down; priority bug lane live)"
  elif (( all_n > 0 && done_n >= all_n )); then
    echo "IDLE/WATCHING  ($up/$total workers resident; all work complete — polling for new work)"
  else
    echo "RUNNING  ($up/$total workers up, $sess $(cli_name) session(s) live)"
  fi
}

# session_row <sess> <wd> — one live session's line under its worker: its goal loop's iteration and, for
# a backend that keeps one, the session's own state (a headless lane's idle | busy | limit | transient,
# #352 — a pane's state is only on its screen).
session_row(){ local st; st="$(sess_state "$1" 2>/dev/null)"
  printf '        ⟳ %-18s ralph-iter=%s%s\n' "$1" "$(iter_of "$2")" "${st:+  $(sess_backend): $st}"; }

# model_mismatch_report — #376: every session of THIS fleet (last 7d) whose dominant-by-output model is
# another family than the model it was launched with (stats.py's model_mismatch events). Silent when
# there are none, and never fails the dashboard.
model_mismatch_report(){ local l
  while IFS= read -r l; do [[ -n "$l" ]] && printf '  ⚠ %s\n' "$l"; done \
    < <(timeout 10 python3 "$STATS_PY" mismatches --fleet "$HARNESS_SESS_PREFIX" 2>/dev/null)
  return 0; }

# churn_report — #545: every issue of THIS fleet the crash-loop guard parked (churn.py: a `churn` event not
# yet followed by a relaunch of the issue). Silent when there are none, and never fails the dashboard.
churn_report(){ local l
  while IFS= read -r l; do [[ -n "$l" ]] && printf '  ⚠ %s\n' "$l"; done \
    < <(timeout 10 python3 "$ENGINE_DIR/scripts/churn.py" status --fleet "$HARNESS_SESS_PREFIX" 2>/dev/null)
  return 0; }

# duplicate_workers_report — #647: a live top-level worker process of THIS fleet that no pid file names, or a slot with more than one.
# The pid files alone said UP for a fleet that was running 27 workers instead of 3. A worker's own `$(…)` forks are not workers
# (fleet_worker_procs), so a healthy fleet — even mid-fork — prints nothing. Silent without a /proc; never fails the dashboard.
duplicate_workers_report(){ local pid slot n untracked list="" dup=0
  declare -A _per=()
  untracked=" $(fleet_untracked_workers "$STATE_DIR" | awk '{printf "%s ", $1}')"
  while read -r pid slot; do
    [[ -n $pid ]] || continue
    _per[$slot]=$(( ${_per[$slot]:-0} + 1 )); list+="${list:+, }pid $pid ($slot)"
    [[ $untracked == *" $pid "* ]] && dup=1
  done < <(fleet_worker_procs "$STATE_DIR")
  (( ${#_per[@]} )) && for slot in "${!_per[@]}"; do n="${_per[$slot]}"; (( n > 1 )) && dup=1; done
  (( dup )) || return 0
  printf '  ⚠ duplicate workers: %s\n' "$list"
  echo "      a pid file names fewer workers than are running, or a slot has more than one — fix: harness start (adopts or stops them)"
  return 0; }

# winsma_report — #1033: who holds the Windows host's lock (C:\hx-lock), for how long, and the queue in order. Prints nothing without
# HARNESS_WINDOWS_HOST; a host that fails or does not answer within WS_STATUS_TIMEOUT (default 5s) is one `winsma: unreachable`
# line. The answer goes through a file so a hung ssh's leftover child cannot hold the dashboard open; never fails the dashboard.
winsma_report(){ [[ -n "${HARNESS_WINDOWS_HOST:-}" ]] || return 0
  local f; f="$(mktemp 2>/dev/null)" || return 0
  if timeout "${WS_STATUS_TIMEOUT:-5}" bash "$ENGINE_DIR/test/smoke/winsma/winsma.sh" status >"$f" 2>/dev/null </dev/null; then cat "$f"
  else echo "  winsma: unreachable"; fi
  rm -f "$f"; return 0; }

render_once(){
  local up=0 total="$POOL" sess_total
  for ((i=1;i<=POOL;i++)); do pid_up "$RUN_DIR/worker-$i.pid" && up=$((up+1)); done
  # #73: count only the fleet's own full-grammar sessions, not every bare `<prefix>-…` string.
  sess_total="$(sess_list | grep -cE "$(fleet_session_re)" || true)"

  local done_n=0 u
  for u in $(all_units); do unit_complete "$u" 2>/dev/null && done_n=$((done_n+1)) || true; done
  local all_n; all_n="$(all_units | wc -l | tr -d ' ')"

  local paused=0; is_paused && paused=1
  local lane_up=0; pid_up "$RUN_DIR/priority.pid" && lane_up=1
  local verdict; verdict="$(fleet_verdict "$up" "$total" "$sess_total" "$done_n" "$all_n" "$paused" "$lane_up")"

  # Print the fleet header FIRST — the test greps for "worker" in this block.
  echo "═══════════════════════  Harness fleet  ═══════════════════════════"
  echo "  FLEET: $verdict"
  echo "  pool=$POOL  poll=${POLL}s   $(date '+%H:%M:%S')"
  usage_report   # #194: each account's usage windows, and any checkpoint hold
  one_auto_report   # #392: the HARNESS_ONE_AUTO lane per account, its issue, forecast, or why it stopped
  gh_rate_report   # #183: each GitHub token's remaining budget, reset time, and any rate-limit hold
  model_mismatch_report   # #376: a session that ran another model than the one it was launched with
  churn_report            # #545: an issue parked because every session on it died young
  duplicate_workers_report   # #647: a live worker no pid file names, or two on one slot
  winsma_report              # #1033: the Windows host's lock holder, hold time and queue
  echo "───────────────────────────────────────────────────────────────────"

  # Which tmux namespace this fleet owns, and who else is on the host. A shared prefix is what makes
  # `harness stop` here kill another project's agents, so it belongs in the at-a-glance view — under
  # the banner, like every other block, not above it.
  echo "prefix: $HARNESS_SESS_PREFIX"
  local p prj rd slugs sibs=0
  # $FLEET_ROW_SEP, not tab: a POLLER row's run_dir is an empty INTERIOR field and bash collapses
  # runs of tab, so the slug list would land in $rd and the `(slugs)` suffix would vanish from the
  # row. Same treatment as the other fleet_registry_entries consumers (lib.sh, doctor.sh).
  while IFS="$FLEET_ROW_SEP" read -r p prj rd slugs; do
    [[ -n "$p" ]] || continue
    sibs=$((sibs+1)); printf '  sibling fleet: %-12s %s%s\n' "$p" "$(dirname "$prj")" "${slugs:+ ($slugs)}"
  done < <(fleet_registry_entries "$STATE_DIR" | tr '\t' "$FLEET_ROW_SEP")
  (( sibs == 0 )) && echo "  (no other fleets registered on this host)"

  # #472: one row per worker — `worker-N → #<issue> <session> <state>`, or `idle`. A worker holds one
  # lane claim (#468): its token names the issue (IMPL:7, DECOMPOSE:41, <repo>#6); a PLAN/PRD action has
  # none and shows the action. A claim with no session yet (a bug lane's `-`) shows `-` / starting.
  for ((i=1;i<=POOL;i++)); do
    local mark cf ctok csess cissue cstate cwd
    if pid_up "$RUN_DIR/worker-$i.pid"; then mark="● UP  "; else mark="○ DOWN"; fi
    cf="$(worker_claims_of "$i" | head -n1)"
    if [[ -z "$cf" ]]; then printf '%s worker-%-2s idle\n' "$mark" "$i"; continue; fi
    ctok="$(awk '{print $3; exit}' "$cf" 2>/dev/null)"; csess="$(awk '{print $4; exit}' "$cf" 2>/dev/null)"
    cissue="${ctok##*[:#]}"; [[ "$cissue" =~ ^[0-9]+$ ]] && cissue="#$cissue" || cissue="${ctok%%:*}"
    cstate="starting"
    if [[ -n "$csess" && "$csess" != - ]]; then
      cstate="$(sess_state "$csess" 2>/dev/null)"; cstate="${cstate:-running}"
    else csess=-; fi
    printf '%s worker-%-2s → %s %s %s\n' "$mark" "$i" "$cissue" "$csess" "$cstate"
    if [[ "$csess" != - ]]; then
      if [[ "$csess" == *-i* ]]; then cwd="$WORKTREES_DIR/${csess#${HARNESS_SESS_PREFIX}-}"; else cwd="$(fleet_checkout)"; fi
      session_row "$csess" "$cwd"
    fi
  done

  # Priority bug lane (#35): its own row — the pool counts above never include it, so without
  # this the lane is operationally invisible. Shows UP/DOWN from priority.pid, plus its held
  # bug + phase: the repo-qualified ref from the bug-*.claim (its stored token) and the phase from
  # the live hz-bug-<repo-sanitised>-<n>-<phase> session (#44) — or "watching" when idle.
  echo "──────────────────────  priority bug lane  ────────────────────────"
  local lmark lpid
  if pid_up "$RUN_DIR/priority.pid"; then
    lmark="● UP  "; lpid="pid $(cat "$RUN_DIR/priority.pid")"
  else
    lmark="○ DOWN"; lpid="(not running)"
  fi
  printf '%s priority lane %s\n' "$lmark" "$lpid"
  local lbug; lbug="$(lane_bug 2>/dev/null || true)"
  if [[ -n "$lbug" ]]; then
    local lphase; lphase="$(lane_phase "$lbug" 2>/dev/null || true)"
    # A repo-qualified ref (<owner>/<repo>#N, #44) already carries its own '#'; a bare number
    # (legacy bare claim) gets the '#' prefix. Avoids the ugly 'bug #acme/a#6'.
    case "$lbug" in
      *#*) printf '        ▶ bug %s (%s)\n'  "$lbug" "${lphase:-?}";;
      *)   printf '        ▶ bug #%s (%s)\n' "$lbug" "${lphase:-?}";;
    esac
  elif pid_up "$RUN_DIR/priority.pid"; then
    echo "        · watching (no bug claimed)"
  fi

  # Per-unit open PRs — non-fatal when gh is not available/authed.
  echo "──────────────────────────  open PRs  ─────────────────────────────"
  for u in $(all_units); do
    local slug; slug="$(unit_slug "$u")"
    local prs
    prs="$(gh pr list -R "$slug" --state open --json number,title,headRefName \
           -q '.[] | "  #\(.number) \(.headRefName) — \(.title)"' 2>/dev/null || true)"
    if [[ -n "$prs" ]]; then
      echo "  $slug:"
      echo "$prs"
    fi
  done
  echo "═══════════════════════════════════════════════════════════════════"
}

# Guard the entrypoint so test/other scripts can source this file for fleet_verdict
# without triggering a full render.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == "--watch" ]]; then
    secs="${2:-8}"
    tput civis 2>/dev/null   # hide cursor for stable, flicker-free redraw
    trap 'tput cnorm 2>/dev/null; tput ed 2>/dev/null; echo "(stopped watching — fleet keeps running in background)"; exit 0' INT TERM
    clear
    while true; do
      # Render the whole frame first, then paint in place — avoids slow gh/issuelib calls
      # dribbling line-by-line down the screen.
      frame="$(render_once compact)"$'\n'"  ↻ live every ${secs}s · Ctrl-C stops watching (NOT the fleet)"
      tput cup 0 0 2>/dev/null
      printf '%s' "$frame"
      tput ed 2>/dev/null      # wipe leftover lines from a taller previous frame
      sleep "$secs"
    done
  else
    render_once
  fi
fi

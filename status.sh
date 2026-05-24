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
# one-line at-a-glance state. Precedence: PAUSED (forced-drain) > STOPPED (NOTHING live: no pool
# worker AND no priority lane #35) > LANE-ONLY (pool down but the lane is alive #35) >
# IDLE/WATCHING (resident #24: workers up but every unit complete, just polling) > RUNNING.
fleet_verdict(){
  local up="$1" total="$2" sess="$3" done_n="$4" all_n="$5" paused="$6" lane_up="${7:-0}"
  if [[ "$paused" == 1 ]]; then
    echo "PAUSED   (drained — workers idle; resume: harness/resume.sh)"
  elif (( up == 0 && lane_up == 0 )); then
    echo "STOPPED  (pool not running — start with: harness/start.sh)"
  elif (( up == 0 )); then
    echo "RUNNING  (pool down; priority bug lane live)"
  elif (( all_n > 0 && done_n >= all_n )); then
    echo "IDLE/WATCHING  ($up/$total workers resident; all $all_n units complete — polling for new work)"
  else
    echo "RUNNING  ($up/$total workers up, $sess claude session(s) live)"
  fi
}

render_once(){
  local up=0 total="$POOL" sess_total
  for ((i=1;i<=POOL;i++)); do pid_up "$RUN_DIR/worker-$i.pid" && up=$((up+1)); done
  sess_total="$(tmux ls -F '#S' 2>/dev/null | grep -cE "^${HARNESS_SESS_PREFIX}-" || true)"

  local done_n=0 u
  for u in $(all_units); do unit_complete "$u" 2>/dev/null && done_n=$((done_n+1)) || true; done
  local all_n; all_n="$(all_units | wc -l | tr -d ' ')"

  local paused=0; is_paused && paused=1
  local lane_up=0; pid_up "$RUN_DIR/priority.pid" && lane_up=1
  local verdict; verdict="$(fleet_verdict "$up" "$total" "$sess_total" "$done_n" "$all_n" "$paused" "$lane_up")"

  # Print the fleet header FIRST — the test greps for "worker" in this block.
  echo "═══════════════════════  Harness fleet  ═══════════════════════════"
  echo "  FLEET: $verdict"
  echo "  pool=$POOL  cap=$CAP/worker  poll=${POLL}s   units: $done_n/$all_n complete   $(date '+%H:%M:%S')"
  echo "───────────────────────────────────────────────────────────────────"

  for ((i=1;i<=POOL;i++)); do
    local mark wpid unit_id
    if pid_up "$RUN_DIR/worker-$i.pid"; then
      mark="● UP  "; wpid="pid $(cat "$RUN_DIR/worker-$i.pid")"
    else
      mark="○ DOWN"; wpid="(not running)"
    fi
    unit_id="$(worker_unit "$i" 2>/dev/null || true)"
    printf '%s worker-%-2s %s\n' "$mark" "$i" "$wpid"
    if [[ -n "$unit_id" ]]; then
      local slug; slug="$(unit_slug "$unit_id")"
      printf '        ▶ driving unit %s (%s)\n' "$unit_id" "$slug"
      # Non-fatal: issuelib may not be configured (no gh auth, no labels) in test/offline envs.
      python3 "$HARNESS_DIR/issuelib.py" status "$(unit_repo "$unit_id")" 2>/dev/null | sed 's/^/        /' || true
      local checkout; checkout="$(unit_checkout "$unit_id")"
      mapfile -t ss < <(team_sessions "$unit_id")
      for s in "${ss[@]:-}"; do
        [[ -z "$s" ]] && continue
        if [[ "$s" == *-i* ]]; then
          wd="$WORKTREES_DIR/${s#${HARNESS_SESS_PREFIX}-}"
        else
          wd="$checkout"
        fi
        printf '        ⟳ %-18s ralph-iter=%s\n' "$s" "$(iter_of "$wd")"
      done
    else
      echo "        · idle (no unit claimed)"
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
    # (legacy single-topology claim) gets the '#' prefix. Avoids the ugly 'bug #acme/a#6'.
    case "$lbug" in
      *#*) printf '        ▶ bug %s (%s)\n'  "$lbug" "${lphase:-?}";;
      *)   printf '        ▶ bug #%s (%s)\n' "$lbug" "${lphase:-?}";;
    esac
  elif pid_up "$RUN_DIR/priority.pid"; then
    echo "        · watching (no bug claimed)"
  fi

  echo "────────────────────────  unit frontier  ──────────────────────────"
  # Non-fatal: claimable_units calls unit_complete which may invoke gh/issuelib.
  local claimable
  claimable="$(claimable_units 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)"
  printf '  ready/claimable now: %s\n' "${claimable:-(none or unavailable)}"
  if [[ "${1:-}" != compact ]]; then
    for u in $(all_units); do
      unit_complete "$u" 2>/dev/null && continue || true
      deps_complete "$u" 2>/dev/null && continue || true
      local deps unmet=""; deps="$(unit_deps "$u")"
      IFS=',' read -ra ds <<< "$deps"
      for d in "${ds[@]}"; do unit_complete "$d" 2>/dev/null || unmet+="$d " || true; done
      printf '  ⏳ %-10s waiting on: %s\n' "$u" "$unmet"
    done
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

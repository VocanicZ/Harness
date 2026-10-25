#!/usr/bin/env bash
# test_stale_lock.sh — #179: an agent-working lock must never outlive its session.
#   1. reap while gh is down, then gh recovers → the label is cleared on the NEXT poll (the queue).
#   2. the per-poll sweep frees a lock no live session owns once it is HARNESS_ORPHAN_LOCK_MIN old,
#      and never one with a live impl / orch / bug-lane session, a fresh one, or one with a worktree.
# The lock is keyed off tmux session names, which are the same for every CLI, so each scenario runs
# under every claimed CLI (claude + agy) — the owner's feature x CLI rule.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"

ago(){ date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }   # ISO stamp <secs> ago

setup(){
  make_env
  HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_SESS_PREFIX=hz; CAP=2; POLL=0
  HARNESS_ORPHAN_LOCK_MIN=20
  WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
  GHLOG="$RUN_DIR/gh.log"; : > "$GHLOG"; GHDOWN="$RUN_DIR/gh.down"; rm -f "$GHDOWN"
  LIVE="$RUN_DIR/live"; : > "$LIVE"
  # gh: fails outright while $GHDOWN exists (the outage); otherwise records the call and succeeds.
  # $EDITDOWN fails only the label edit — the issue reads fine but the write does not land.
  EDITDOWN="$RUN_DIR/edit.down"; rm -f "$EDITDOWN"
  gh(){ [[ -f "$GHDOWN" ]] && return 1; [[ "$1 $2" == "issue edit" && -f "$EDITDOWN" ]] && return 1
        echo "gh $*" >> "$GHLOG"
        [[ "$1 $2" == "issue view" ]] && echo '{"state":"OPEN","labels":[{"name":"agent-working"}]}'; return 0; }
  # tmux: a session is live iff its name is listed in $LIVE.
  tmux(){ [[ "$1" == has-session ]] && { grep -qxF "$3" "$LIVE"; return; }; return 0; }
  remove_worktree(){ rm -rf "$2"; }
  stats_sweep_ended(){ :; }; harness_event(){ :; }
}
unlocks(){ grep -c "issue edit $1 -R acme/widget --remove-label agent-working" "$GHLOG"; }
comments(){ grep -c "issue comment $1 -R acme/widget" "$GHLOG"; }

for cli in claude agy; do
  export HARNESS_CLI="$cli"
  echo "=== [$cli] reap with gh failing, then gh recovering → cleared on the next poll ==="
  setup
  mkdir -p "$WORKTREES_DIR/main-i7"   # the watchdog just killed hz-main-i7; its worktree is left
  # drive_unit, two polls. Poll 1 runs with gh DOWN: the reap removes the worktree but cannot reach
  # GitHub. gh recovers during poll 1's dispatch; poll 2 must clear the label with no worktree left.
  touch "$GHDOWN"
  TICK="$RUN_DIR/tick"; echo 0 > "$TICK"
  dispatch_actions(){ local n; n="$(cat "$TICK")"; echo $((n+1)) > "$TICK"; rm -f "$GHDOWN"; }
  unit_complete(){ [[ "$(cat "$TICK")" -ge 2 ]]; }
  reap_done_sessions(){ :; }; reap_orch(){ :; }; watchdog_team(){ :; }; reap_finished_inject(){ :; }
  ci_gate_ok(){ return 0; }; usage_watch(){ :; }; usage_held(){ return 1; }; gh_budget_low(){ return 1; }
  gh_rate_wait(){ return 0; }; count_team_sessions(){ echo 0; }; team_sessions(){ :; }
  finalize_unit(){ :; }; dispatch_stalled_banner(){ :; }; _working_locks(){ :; }
  drive_unit main >/dev/null
  assert_no "[$cli] worktree reaped on poll 1" test -d "$WORKTREES_DIR/main-i7"
  assert_eq "$(unlocks 7)" "1" "[$cli] agent-working cleared on #7 once gh recovered"
  assert_eq "$(cat "$RUN_DIR/pending-unlock")" "" "[$cli] queue drained after the successful retry"

  echo "=== [$cli] reap of an OPEN issue whose label edit fails → queued, cleared on retry ==="
  setup
  mkdir -p "$WORKTREES_DIR/main-i8"
  UNIT=main; SLUG=acme/widget; CHECKOUT="$RUN_DIR"
  touch "$EDITDOWN"; reap_team >/dev/null
  assert_eq "$(cat "$RUN_DIR/pending-unlock")" "acme/widget	8" "[$cli] the refused unlock is queued, not dropped"
  rm -f "$EDITDOWN"; retry_pending_unlocks >/dev/null
  assert_eq "$(unlocks 8)" "1" "[$cli] and cleared once the edit goes through"

  echo "=== [$cli] a failed unlock is queued once and kept until GitHub takes it ==="
  setup
  touch "$GHDOWN"
  assert_no "[$cli] unlock_issue reports the gh failure" unlock_issue acme/widget 9
  unlock_issue acme/widget 9 >/dev/null
  assert_eq "$(cat "$RUN_DIR/pending-unlock")" "acme/widget	9" "[$cli] queued exactly once"
  retry_pending_unlocks
  assert_eq "$(cat "$RUN_DIR/pending-unlock")" "acme/widget	9" "[$cli] still queued while gh is down"
  rm -f "$GHDOWN"
  retry_pending_unlocks
  assert_eq "$(unlocks 9)" "1" "[$cli] retry clears it once gh is back"
  assert_eq "$(cat "$RUN_DIR/pending-unlock")" "" "[$cli] and drops it from the queue"
  # re-claimed while queued: a live session owns the lock again — drop the entry, keep the label.
  touch "$GHDOWN"; unlock_issue acme/widget 10 >/dev/null; rm -f "$GHDOWN"
  echo "hz-main-i10" >> "$LIVE"
  retry_pending_unlocks
  assert_eq "$(unlocks 10)" "0" "[$cli] a re-claimed issue's lock is left alone"
  assert_eq "$(cat "$RUN_DIR/pending-unlock")" "" "[$cli] and its entry is dropped"

  echo "=== [$cli] sweep: orphaned locks freed, live / fresh / worktree-owned ones never ==="
  setup
  old="$(ago 7200)"; fresh="$(ago 300)"
  _working_locks(){ printf '%s\t%s\n' 11 "$old" 12 "$old" 13 "$old" 14 "$old" 15 "$fresh" 16 "$old" 17 "$old" 18 garbage; }
  printf '%s\n' hz-main-i12 hz-main-p13 hz-bug-acme_widget-14-fix > "$LIVE"   # impl, orch, bug-lane fix
  mkdir -p "$WORKTREES_DIR/main-i16"                                           # still owned by reap_team
  mkdir -p "$(triage_worktree acme/widget 17)"                                 # a triage still launching
  sweep_orphan_locks main >/dev/null
  assert_eq "$(unlocks 11)" "1" "[$cli] #11: no session, 2h old → unlocked"
  assert_eq "$(comments 11)" "1" "[$cli] #11: and told why in a comment"
  assert_eq "$(unlocks 12)" "0" "[$cli] #12: live impl session → never unlocked"
  assert_eq "$(unlocks 13)" "0" "[$cli] #13: live orch session → never unlocked"
  assert_eq "$(unlocks 14)" "0" "[$cli] #14: live bug-lane session (<prefix>-bug-<slug>-<n>-*) → never unlocked"
  assert_eq "$(unlocks 15)" "0" "[$cli] #15: locked 5m ago (< HARNESS_ORPHAN_LOCK_MIN) → left alone"
  assert_eq "$(unlocks 16)" "0" "[$cli] #16: impl worktree present → its reaper owns the lock"
  assert_eq "$(unlocks 17)" "0" "[$cli] #17: bug-lane worktree present → its reaper owns the lock"
  assert_eq "$(unlocks 18)" "0" "[$cli] #18: unparseable age → left alone"
  # bug-lane triage phase is a live session too
  : > "$GHLOG"; echo hz-bug-acme_widget-11-triage > "$LIVE"; rm -rf "$RUN_DIR/unlocked"
  sweep_orphan_locks main >/dev/null
  assert_eq "$(unlocks 11)" "0" "[$cli] live bug-lane triage session → never unlocked"
  # the snapshot still shows #11 locked on the next poll — no second unlock, no second comment
  : > "$LIVE"; : > "$GHLOG"
  sweep_orphan_locks main >/dev/null; sweep_orphan_locks main >/dev/null
  assert_eq "$(comments 11)" "1" "[$cli] freed once per window, not once per poll"
  # gh down at sweep time → the unlock is queued, not lost
  setup
  _working_locks(){ printf '%s\t%s\n' 21 "$(ago 7200)"; }
  touch "$GHDOWN"; sweep_orphan_locks main >/dev/null
  assert_eq "$(cat "$RUN_DIR/pending-unlock")" "acme/widget	21" "[$cli] sweep unlock during an outage is queued"
done

echo "=== the bug lane queues a failed unlock too ==="
source "$HERE/../scripts/priority-worker.sh"
setup
_bug_repos(){ echo acme/widget; }; _repo_working_bugs(){ echo 31; }
touch "$GHDOWN"; reap_lane >/dev/null
assert_eq "$(cat "$RUN_DIR/pending-unlock")" "acme/widget	31" "reap_lane queues the unlock gh refused"

finish

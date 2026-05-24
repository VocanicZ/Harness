#!/usr/bin/env bash
# test_recover.sh — start --recover's orphaned-agent-working sweep (recover_orphan_working).
# #43: the recover sweep must NOT strip agent-working from a bug whose sess_bug {triage,fix}
# session is LIVE — else the lane re-claims the bug and spawn_bug rips out the worktree the
# still-live agent is editing (double-dispatch / worktree corruption). It gates on
# bug_session_live — the SAME liveness predicate the lane's per-poll reap uses (#42, reap_lane)
# — so the two reconciliation paths can never disagree. Dead-session orphans (impl OR bug) are
# still freed, so crash recovery keeps working.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"; make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme

# session_live driven by a $LIVE listing — same rig as test_priority's reap_lane test.
LIVE="$RUN_DIR/live_sessions"; : > "$LIVE"
session_live(){ grep -qxF "$1" "$LIVE"; }

# gh seam: the repo is seeded; `issue list` yields the OPEN agent-working candidates (already
# past the agent-blocked filter the real query applies); `issue edit --remove-label` is recorded,
# never run for real. recover_orphan_working must NEVER touch a worktree (sweep_orphan_bug_worktrees' job).
GHLOG="$RUN_DIR/gh"; WORKING=""
gh(){ case "$1 $2" in
    "repo view")  return 0 ;;
    "issue list") printf '%s\n' $WORKING ;;
    "issue edit") echo "$*" >> "$GHLOG" ;;
  esac; return 0; }
WTLOG="$RUN_DIR/wt"; remove_worktree(){ echo "$*" >> "$WTLOG"; }

# ── dead-session bug: --recover frees its stale agent-working (crash recovery still works) ──
: > "$GHLOG"; : > "$WTLOG"; : > "$LIVE"; WORKING="9"
recover_orphan_working >/dev/null 2>&1
assert_ok "dead-session bug freed by recover" \
  grep -q "issue edit 9 -R acme/widget --remove-label agent-working" "$GHLOG"
assert_eq "$(cat "$WTLOG")" "" "recover sweep never touches a worktree"

# ── LIVE bug session: --recover retains agent-working (no double-dispatch / corruption) ──
# The live session is the REAL one production creates — the 3-arg repo-qualified sess_bug
# "<slug>" <n> <phase> (#44), built with the SAME slug recover_orphan_working derives — so this
# verifies the recover skip against the production session name, not a 2-arg stand-in (#48).
SLUG="$(unit_slug "$(all_units)")"                       # exactly the slug recover_orphan_working derives
: > "$GHLOG"; printf '%s\n' "$(sess_bug "$SLUG" 9 fix)" > "$LIVE"; WORKING="9"
recover_orphan_working >/dev/null 2>&1
assert_eq "$(cat "$GHLOG")" "" "live bug-FIX session: agent-working retained by recover"
: > "$GHLOG"; printf '%s\n' "$(sess_bug "$SLUG" 9 triage)" > "$LIVE"; WORKING="9"
recover_orphan_working >/dev/null 2>&1
assert_eq "$(cat "$GHLOG")" "" "live bug-TRIAGE session: agent-working retained by recover"

# ── no regression: a live IMPL session is still skipped; a fully-dead impl issue still freed ──
: > "$GHLOG"; printf '%s\n' "$(sess_impl main 5)" > "$LIVE"; WORKING="5"
recover_orphan_working >/dev/null 2>&1
assert_eq "$(cat "$GHLOG")" "" "live impl session: agent-working retained by recover"
: > "$GHLOG"; : > "$LIVE"; WORKING="5"
recover_orphan_working >/dev/null 2>&1
assert_ok "dead impl issue freed by recover" \
  grep -q "issue edit 5 -R acme/widget --remove-label agent-working" "$GHLOG"

finish

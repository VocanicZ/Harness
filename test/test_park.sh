#!/usr/bin/env bash
# test_park.sh — #271: a lane that labels its issue agent-blocked parks it, on an autonomous fleet too.
#   1. reap_done_sessions ends the parked session in the same poll (`check ISSUE:<n>` is DONE), and
#      reap_team frees its slot and records the park.
#   2. the next dispatch hands the slot to the unit's other ready issue, not back to the parked one,
#      for poll after poll — the engine's own unlock (which bumps updatedAt) is not a change.
#   3. a change to the issue (comment / label edit → a later updatedAt) re-enables it.
# Real issuelib.py, reading a snapshot (no gh); gh/tmux are stubbed. Session names are the same for
# every CLI, so each scenario runs under every claimed CLI (claude + agy) — the owner's feature x CLI rule.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"

# snapshot <#5 labels csv> <#5 updatedAt> — the poller's view: #5 (the parked one) and #6 (ready).
snapshot(){ python3 - "$SNAP" "$1" "$2" <<'EOF'
import json, sys, time
path, labels5, upd5 = sys.argv[1:]
iss = lambda n, labels, upd: {"number": n, "title": f"t{n}", "state": "OPEN", "body": "",
                              "labels": [{"name": l} for l in labels.split(",") if l],
                              "author": {"login": "bot"}, "updatedAt": upd}
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget",
           "issues": [iss(5, labels5, upd5), iss(6, "ready-for-agent", "2026-10-28T00:00:00Z")],
           "has_plan": False, "plan_marker": None, "self_login": "bot", "ext_deps": {},
           "issue_branches": []}, open(path, "w"))
EOF
}

setup(){
  make_env
  HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_SESS_PREFIX=hz; CAP=1; POLL=0
  UNIT=main; REPO="acme/widget"; SLUG="acme/widget"; CHECKOUT="$RUN_DIR/co"
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0
  unset HARNESS_BLOCKED_BACKOFF_MIN HARNESS_PARKED_FILE
  WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
  LIVE="$RUN_DIR/live"; KILLED="$RUN_DIR/killed"; : > "$KILLED"
  # GitHub's updatedAt for #5: the engine's own unlock bumps it, as the real API does.
  UPD="$RUN_DIR/upd"; echo "2026-10-28T00:31:00Z" > "$UPD"
  gh(){ case "$1 $2" in
          "issue edit") echo "2026-10-28T02:13:00Z" > "$UPD";;
          "issue view") if [[ "$*" == *updatedAt* ]]; then cat "$UPD"
                        else echo '{"labels":[{"id":"x","name":"agent-blocked"},{"id":"y","name":"agent-working"}],"state":"OPEN"}'; fi;;
        esac; return 0; }
  tmux(){ case "$1" in
            has-session) grep -qxF "$3" "$LIVE";;
            kill-session) echo "$3" >> "$KILLED"; grep -vxF "$3" "$LIVE" > "$LIVE.n"; mv "$LIVE.n" "$LIVE";;
            ls|list-sessions) cat "$LIVE";;
          esac; }
  remove_worktree(){ rm -rf "$2"; }
  stats_sweep_ended(){ :; }; harness_event(){ :; }; stats_sess_event(){ :; }
}

for cli in claude agy; do
  export HARNESS_CLI="$cli"
  echo "=== [$cli] a lane parks #5 agent-blocked: reaped in one poll, slot goes to #6 ==="
  setup
  s="$(sess_impl main 5)"; echo "$s" > "$LIVE"; echo "ISSUE:5" > "$RUN_DIR/$s.goal"
  mkdir -p "$WORKTREES_DIR/main-i5"
  snapshot "ready-for-agent,agent-working,agent-blocked" "2026-10-28T00:31:00Z"
  assert_eq "$(python3 "$ISSUELIB" check "$REPO" ISSUE:5 2>/dev/null)" "DONE" "[$cli] check ISSUE:5 is DONE once #5 is agent-blocked"
  reap_done_sessions 2>/dev/null
  assert_eq "$(cat "$KILLED")" "$s" "[$cli] reap_done_sessions killed the parked session in one poll"
  assert_eq "$(count_team_sessions main)" "0" "[$cli] its slot is free"
  reap_team 2>/dev/null
  assert_no "[$cli] reap_team removed its worktree" test -d "$WORKTREES_DIR/main-i5"
  assert_eq "$(cut -f1,2,4 "$(parked_file)")" "acme/widget	5	2026-10-28T02:13:00Z" \
    "[$cli] the park records the updatedAt read AFTER the engine's own unlock"
  # the poller now sees the unlock: agent-working gone, updatedAt bumped by it — that is no change.
  snapshot "ready-for-agent,agent-blocked" "2026-10-28T02:13:00Z"
  for poll in 1 2 3; do
    assert_eq "$(dispatch_actions "$REPO" 1 1 "" 2>/dev/null)" "IMPL	6	ISSUE 6 DONE" \
      "[$cli] poll $poll: the free slot takes #6, not the parked #5"
  done
  assert_ok "[$cli] status names the hold" grep -q "PARKED.*#5" <(python3 "$ISSUELIB" status "$REPO" 2>/dev/null)

  echo "=== [$cli] a change to #5 re-enables it ==="
  snapshot "ready-for-agent,agent-blocked" "2026-10-28T03:00:00Z"
  assert_eq "$(dispatch_actions "$REPO" 1 1 "" 2>/dev/null)" "IMPL	5	ISSUE 5 DONE" "[$cli] a comment after the park → #5 dispatches again"

  echo "=== [$cli] a queued unlock that lands later re-parks at the new updatedAt ==="
  setup
  snapshot "ready-for-agent,agent-blocked" "2026-10-28T00:31:00Z"
  printf 'acme/widget\t5\n' > "$RUN_DIR/pending-unlock"
  mkdir -p "$(dirname "$(parked_file)")"
  printf 'acme/widget\t5\t%s\t2026-10-28T00:31:00Z\n' "$(date +%s)" > "$(parked_file)"
  retry_pending_unlocks 2>/dev/null
  assert_eq "$(cut -f4 "$(parked_file)")" "2026-10-28T02:13:00Z" "[$cli] the late unlock's bump is folded into the park"
  assert_eq "$(grep -c . "$(parked_file)")" "1" "[$cli] one record per issue"
done

finish

#!/usr/bin/env bash
# test_checkpoint_end.sh — #1159: a lane that CHECKPOINTED (a usage hold, `pause --force`) is ended once the
# pause / hold is gone. A tmux lane has no turn counter, so usage_park_lanes never sees it; it sat idle at its
# prompt with an agent-paused issue for good, holding its pool slot.
#   1. <sess>.checkpoint + issue PAUSED + idle prompt, no pause flag, no hold -> killed (reap -> resume).
#   2. the same with the pause flag set, or a usage hold standing -> left alone.
#   3. a lane still running its checkpoint turn, or sitting in a dialog -> left alone.
#   4. dirty / unpushed worktree -> mechanically checkpointed first; a failing push -> not killed.
#   5. no checkpoint marker -> #417's nudge-then-kill is unchanged (test_selfpark.sh).
#   6. a priority bug lane (hz-bug-…-fix|triage) is ended the same way.
#   7. a pool worker holding >= 2 claims writes no `write error: Broken pipe` (SIGPIPE ignored).
# Real issuelib.py over a snapshot; gh and tmux are stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../scripts/pool-worker.sh"; source "$HERE/helpers.sh"

snapshot(){ python3 - "$SNAP" "$1" <<'EOF'
import json, sys, time
path, labels5 = sys.argv[1:]
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget",
           "issues": [{"number": 5, "title": "t5", "state": "OPEN", "body": "",
                       "labels": [{"name": l} for l in labels5.split(",") if l],
                       "author": {"login": "bot"}, "updatedAt": "2026-11-02T02:50:00Z"}],
           "has_plan": False, "plan_marker": None, "self_login": "bot", "ext_deps": {},
           "issue_branches": []}, open(path, "w"))
EOF
}

S=hz-main-i5
setup(){  # a checkpointed lane: marker present, issue agent-paused, pane idle at its prompt, WIP on origin
  make_env
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; POOL=1; POLL=0
  UNIT=main; REPO="acme/widget"; SLUG="acme/widget"; PROJECT=main; DESC=widget; CHECKOUT="$RUN_DIR/co"
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude
  WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; LIVE="$RUN_DIR/live"; echo "$S" > "$LIVE"
  export CALLS LIVE; unset PANE_FILE
  ORIGIN="$RUN_DIR/origin.git"; git init -q --bare "$ORIGIN"
  WD="$WORKTREES_DIR/main-i5"; git init -q "$WD"
  git -C "$WD" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$WD" checkout -q -b issue/5; git -C "$WD" remote add origin "$ORIGIN"
  git -C "$WD" config user.email t@t; git -C "$WD" config user.name t
  echo done > "$WD/feature.txt"; git -C "$WD" add feature.txt; git -C "$WD" commit -q -m work
  git -C "$WD" push -q origin issue/5   # the checkpoint turn pushed: HEAD == origin/issue/5
  echo "$WD" > "$RUN_DIR/$S.wd"; echo "ISSUE:5" > "$RUN_DIR/$S.goal"
  echo "5	acme/widget	" > "$RUN_DIR/$S.checkpoint"
  gh(){ echo "gh $*" >> "$CALLS"
        case "$1 $2" in "issue view") echo '{"labels":[{"name":"agent-paused"}],"state":"OPEN"}';; esac; return 0; }
  tmux(){ echo "tmux $*" >> "$CALLS"
          case "$1" in
            has-session) grep -qxF "$3" "$LIVE";;
            kill-session) grep -vxF "$3" "$LIVE" > "$LIVE.n"; mv "$LIVE.n" "$LIVE";;
            ls|list-sessions) cat "$LIVE";;
            capture-pane) if [[ -n "${PANE_FILE:-}" ]]; then cat "$PANE_FILE"
                          else printf '%s\n' 'Checkpoint pushed and handed off.' '❯ '; fi;;
          esac; }
  export -f gh tmux
  remove_worktree(){ rm -rf "$2"; }
  stats_sweep_ended(){ :; }; harness_event(){ :; }
  snapshot "ready-for-agent,agent-paused"
}
killed(){ grep -c "kill-session -t ${1:-$S}" "$CALLS"; }
hold(){ mkdir -p "$(_usage_hold_dir)"; : > "$(_usage_hold_dir)/acctA.hold"; }

echo "=== checkpointed + PAUSED + idle prompt, no pause, no hold: ended (#1159) ==="
setup
reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "1" "the checkpointed idle lane is killed"
assert_eq "$(grep -c 'may not wait on a human' "$CALLS")" "0" "no self-park nudge for a requested checkpoint"
assert_eq "$(grep -c 'issue comment' "$CALLS")" "0" "work already on origin: no second handoff comment"
touch -d "2 minutes ago" "$WD"
reap_team 2>/dev/null
assert_no "reap_team then removes its worktree" test -d "$WD"
assert_no "the checkpoint marker went with the session" test -f "$RUN_DIR/$S.checkpoint"

echo "=== the pause flag stands: left alone ==="
setup
touch "$PAUSE_FLAG"
reap_done_sessions 2>/dev/null; reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "0" "paused fleet: not killed"
assert_eq "$(grep -c 'send-keys' "$CALLS")" "0" "paused fleet: nothing typed into the pane"
rm -f "$PAUSE_FLAG"
reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "1" "pause cleared (harness resume): killed on the next poll"

echo "=== a usage hold stands: left alone, ended once it is released ==="
setup
hold
reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "0" "usage hold: not killed"
rm -f "$(_usage_hold_dir)"/*.hold
reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "1" "hold released: killed on the next poll"

echo "=== a lane still in its checkpoint turn, or in a dialog, is left alone ==="
setup
export PANE_FILE="$HERE/fixtures/cli/claude/busy.txt"
reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "0" "busy pane: not killed"
export PANE_FILE="$HERE/fixtures/cli/claude/bypass-dialog.txt"
reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "0" "dialog: not killed"
assert_eq "$(grep -c 'send-keys' "$CALLS")" "0" "dialog: no key sent"
unset PANE_FILE

echo "=== unpushed work is pushed first; a failing push never kills ==="
setup
echo wip > "$WD/dirty.txt"
reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "1" "dirty worktree: killed after the mechanical checkpoint"
assert_ok "the dirty file was pushed to origin/issue/5" bash -c "git -C '$ORIGIN' show issue/5:dirty.txt | grep -q wip"
assert_ok "a harness-handoff comment was posted" grep -q 'harness-handoff issue=5' "$CALLS"
setup
echo wip > "$WD/dirty.txt"; git -C "$WD" remote set-url origin "$RUN_DIR/no-such-origin.git"
reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "0" "push fails: not killed"
reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "0" "push fails: still not killed on the retry"
git -C "$WD" remote set-url origin "$ORIGIN"
reap_done_sessions 2>/dev/null
assert_eq "$(killed)" "1" "push works again: killed"
setup
echo more > "$WD/more.txt"; git -C "$WD" add more.txt; git -C "$WD" commit -q -m local-only   # committed, never pushed
reap_done_sessions 2>/dev/null
assert_ok "an unpushed commit reaches origin before the kill" bash -c "git -C '$ORIGIN' show issue/5:more.txt | grep -q more"
assert_eq "$(killed)" "1" "unpushed commit: killed after the push"

echo "=== no checkpoint marker: #417 self-park is unchanged ==="
setup
rm -f "$RUN_DIR/$S.checkpoint"
reap_done_sessions 2>/dev/null
assert_eq "$(grep -c 'may not wait on a human' "$CALLS")" "1" "no marker: nudged"
assert_eq "$(killed)" "0" "no marker: not killed"

echo "=== a checkpointed priority bug lane is ended once the pause / hold is gone ==="
for phase in fix triage; do
  setup
  B=hz-bug-acme_widget-7-$phase; echo "$B" > "$LIVE"
  echo "$WD" > "$RUN_DIR/$B.wd"; echo "7	acme/widget	" > "$RUN_DIR/$B.checkpoint"
  bug_repo(){ echo acme/widget; }
  hold
  bug_lane_tend acme/widget 7 2>/dev/null
  assert_eq "$(killed "$B")" "0" "$phase: hold stands: not killed"
  rm -f "$(_usage_hold_dir)"/*.hold
  bug_lane_tend acme/widget 7 2>/dev/null
  assert_eq "$(killed "$B")" "1" "$phase: hold gone: killed (bug_lane_tend)"
done

echo "=== after pause --force + resume, an unclaimed checkpointed bug session is ended by the priority lane ==="
source "$HERE/../scripts/priority-worker.sh"
for phase in fix triage; do
  setup
  B=hz-bug-acme_widget-7-$phase; echo "$B" > "$LIVE"
  echo "$WD" > "$RUN_DIR/$B.wd"; echo "7	acme/widget	" > "$RUN_DIR/$B.checkpoint"
  bug_repo(){ echo acme/widget; }; bug_checkout(){ echo "$CHECKOUT"; }
  touch "$PAUSE_FLAG"
  reap_checkpointed_bugs 2>/dev/null
  assert_eq "$(killed "$B")" "0" "$phase: paused: not killed"
  rm -f "$PAUSE_FLAG"
  reap_checkpointed_bugs 2>/dev/null
  assert_eq "$(killed "$B")" "1" "$phase: pause gone: killed (reap_checkpointed_bugs)"
done

echo "=== a pool worker holding two claims writes no Broken pipe error ==="
setup
CLAIMS_DIR="$RUN_DIR/claims"; mkdir -p "$CLAIMS_DIR"
printf 'W1 %s tok1 hz-main-i5 1\n' "$$" > "$CLAIMS_DIR/impl-5.claim"
printf 'W1 %s tok2 hz-main-i6 1\n' "$$" > "$CLAIMS_DIR/impl-6.claim"
printf 'W1 %s tok3 hz-main-i7 1\n' "$$" > "$CLAIMS_DIR/impl-7.claim"
err="$RUN_DIR/pipe.err"
( trap '' PIPE; for _ in 1 2 3 4 5; do worker_owns_lane W1; done; worker_has_claim W1 ) 2> "$err"
assert_ok "worker_owns_lane finds its claim" worker_owns_lane W1
assert_ok "worker_has_claim finds its claim" worker_has_claim W1
assert_no "a worker with no claim owns no lane" worker_owns_lane W9
assert_eq "$(wc -c < "$err" | tr -d ' ')" "0" "stderr is empty (no write error: Broken pipe)"
# worker_tick's one-lane-per-worker guard and worker_owns_lane
assert_no "pool-worker.sh no longer pipes worker_claims into head" grep -q 'worker_claims "\$wid" | head\|worker_claims "\$1" | head' "$HERE/../scripts/pool-worker.sh"

finish

#!/usr/bin/env bash
# test_selfpark.sh — #417: an impl lane that parks ITSELF agent-paused (no HARNESS CHECKPOINT was
# sent to it) on an autonomous fleet is not left holding its slot forever.
#   1. first poll: ONE targeted nudge, no kill; a second poll inside HARNESS_SELFPARK_GRACE_MIN: nothing.
#   2. still parked past the grace: mechanical checkpoint (branch pushed, harness-handoff comment) and
#      kill; reap_team frees it and the next dispatch of the issue renders resume.md.
#   3. the issue back on agent-working: no kill, the state is cleared — a later park nudges afresh.
#   4. a checkpoint the engine DID send (pause --force, the #194 usage checkpoint) is no self-park.
#   5. a non-autonomous fleet is unchanged.
# Real issuelib.py over a snapshot (no gh for the check); gh and tmux are stubbed. The scenarios run
# under every claimed CLI (claude + agy): session names and the send/kill seam are the same for each.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"

# snapshot <#5 labels csv> — the poller's view of #5.
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
setup(){
  make_env
  HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; CAP=1; POLL=0
  UNIT=main; REPO="acme/widget"; SLUG="acme/widget"; PROJECT=main; DESC=widget; CHECKOUT="$RUN_DIR/co"
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0
  WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; LIVE="$RUN_DIR/live"; echo "$S" > "$LIVE"
  export CALLS LIVE
  # The lane's worktree: a real git repo with WIP and an origin to push it to.
  ORIGIN="$RUN_DIR/origin.git"; git init -q --bare "$ORIGIN"
  WD="$WORKTREES_DIR/main-i5"; git init -q "$WD"
  git -C "$WD" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$WD" checkout -q -b issue/5; git -C "$WD" remote add origin "$ORIGIN"
  git -C "$WD" config user.email t@t; git -C "$WD" config user.name t
  echo wip > "$WD/feature.txt"
  echo "$WD" > "$RUN_DIR/$S.wd"; echo "ISSUE:5" > "$RUN_DIR/$S.goal"
  gh(){ echo "gh $*" >> "$CALLS"
        case "$1 $2" in
          "issue view") echo '{"labels":[{"name":"agent-paused"}],"state":"OPEN"}';;
        esac; return 0; }
  tmux(){ echo "tmux $*" >> "$CALLS"
          case "$1" in
            has-session) grep -qxF "$3" "$LIVE";;
            kill-session) grep -vxF "$3" "$LIVE" > "$LIVE.n"; mv "$LIVE.n" "$LIVE";;
            ls|list-sessions) cat "$LIVE";;
            capture-pane) printf '%s\n' 'Still waiting on a decision from the PRD owner.' '❯ ';;
          esac; }
  export -f gh tmux
  remove_worktree(){ rm -rf "$2"; }
  stats_sweep_ended(){ :; }; harness_event(){ :; }
}
nudges(){ grep -c "send-keys -t $S .*may not wait on a human" "$CALLS"; }
killed(){ grep -c "kill-session -t $S" "$CALLS"; }

for cli in claude agy; do
  export HARNESS_CLI="$cli"
  echo "=== [$cli] a lane self-parks #5 agent-paused: one targeted nudge, then quiet inside the grace ==="
  setup
  snapshot "ready-for-agent,agent-paused"
  reap_done_sessions 2>/dev/null
  assert_eq "$(nudges)" "1" "[$cli] poll 1: exactly one autonomy nudge"
  assert_ok "[$cli] the nudge tells it to remove agent-paused" grep -q "send-keys -t $S .*remove \`agent-paused\`" "$CALLS"
  assert_eq "$(killed)" "0" "[$cli] poll 1: not killed"
  reap_done_sessions 2>/dev/null
  assert_eq "$(nudges)" "1" "[$cli] poll 2 inside the grace: no further message"
  assert_eq "$(killed)" "0" "[$cli] poll 2 inside the grace: not killed"

  echo "=== [$cli] still parked past HARNESS_SELFPARK_GRACE_MIN: checkpoint and kill, resume on re-dispatch ==="
  echo $(( $(date +%s) - 31 * 60 )) > "$RUN_DIR/$S.selfpark"
  reap_done_sessions 2>/dev/null
  assert_ok "[$cli] a harness-handoff comment is posted" \
    grep -q 'gh issue comment 5 -R acme/widget --body <!-- harness-handoff issue=5 branch=issue/5 -->' "$CALLS"
  assert_ok "[$cli] the handoff names the self-park" grep -qi 'self-park' "$CALLS"
  assert_ok "[$cli] the WIP is pushed to origin/issue/5" bash -c "git -C '$ORIGIN' show issue/5:feature.txt | grep -q wip"
  assert_eq "$(killed)" "1" "[$cli] the session is killed"
  assert_eq "$(nudges)" "1" "[$cli] no second nudge before the kill"
  reap_team 2>/dev/null
  assert_no "[$cli] reap_team removed its worktree" test -d "$WD"
  assert_no "[$cli] the self-park state went with the session" test -f "$RUN_DIR/$S.selfpark"
  ( render(){ echo "render $*" >> "$CALLS"; }
    ensure_checkout(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }; default_branch(){ echo main; }
    resume_handoff(){ :; }
    git(){ case "$*" in *"worktree add"*) mkdir -p "$WD";; esac; return 0; }
    prepare_impl 5 "ISSUE 5 DONE" >/dev/null 2>&1 )
  assert_ok "[$cli] the next dispatch of #5 renders resume.md" grep -q 'render .*prompts/resume.md' "$CALLS"

  echo "=== [$cli] the agent recovers after the nudge: no kill, state cleared, a later park nudges afresh ==="
  setup
  snapshot "ready-for-agent,agent-paused"
  reap_done_sessions 2>/dev/null
  assert_eq "$(nudges)" "1" "[$cli] parked: nudged"
  snapshot "ready-for-agent,agent-working"
  reap_done_sessions 2>/dev/null
  assert_no "[$cli] recovered: the self-park state is cleared" test -f "$RUN_DIR/$S.selfpark"
  assert_eq "$(killed)" "0" "[$cli] recovered: not killed"
  snapshot "ready-for-agent,agent-paused"
  reap_done_sessions 2>/dev/null
  assert_eq "$(nudges)" "2" "[$cli] a later self-park starts over with a fresh nudge"
  assert_eq "$(killed)" "0" "[$cli] ... and no kill"

  echo "=== [$cli] a resumed lane (agent-working + agent-paused, before it re-claims) is no self-park ==="
  setup
  snapshot "ready-for-agent,agent-working,agent-paused"
  reap_done_sessions 2>/dev/null
  assert_eq "$(nudges)" "0" "[$cli] both labels: no nudge"

  echo "=== [$cli] a checkpoint sent by the usage checkpoint is no self-park ==="
  setup
  snapshot "ready-for-agent,agent-paused"
  usage_checkpoint_account acctA "usage limit near" 2>/dev/null
  assert_ok "[$cli] the usage checkpoint reached the session" grep -q "send-keys -t $S .*HARNESS CHECKPOINT" "$CALLS"
  assert_ok "[$cli] the usage checkpoint left a marker" test -s "$RUN_DIR/$S.checkpoint"
  reap_done_sessions 2>/dev/null; reap_done_sessions 2>/dev/null
  assert_eq "$(nudges)" "0" "[$cli] usage checkpoint: no nudge"
  echo $(( $(date +%s) - 31 * 60 )) > "$RUN_DIR/$S.selfpark"; reap_done_sessions 2>/dev/null
  assert_eq "$(killed)" "0" "[$cli] usage checkpoint: no kill"

  echo "=== [$cli] a checkpoint sent by pause --force is no self-park ==="
  setup
  snapshot "ready-for-agent,agent-paused"
  HARNESS_PAUSE_GRACE=2 RUN_DIR="$RUN_DIR" bash "$HERE/../scripts/pause.sh" --force >/dev/null 2>&1
  rm -f "$PAUSE_FLAG"   # the drive loop skips a paused fleet anyway; this pins the marker on its own
  assert_ok "[$cli] pause --force reached the session" grep -q "send-keys -t $S .*HARNESS CHECKPOINT" "$CALLS"
  assert_ok "[$cli] pause --force left a marker" test -s "$RUN_DIR/$S.checkpoint"
  reap_done_sessions 2>/dev/null
  assert_eq "$(nudges)" "0" "[$cli] pause --force: no nudge"
  assert_eq "$(killed)" "0" "[$cli] pause --force: no kill"

  echo "=== [$cli] a relaunch of the session forgets the old marker ==="
  ( sess_start(){ return 0; }; sleep(){ :; }; ensure_trusted(){ :; }; ensure_bypass(){ :; }
    ensure_usage_statusline(){ :; }; cli_launch(){ :; }; sess_send_line(){ :; }; _launch_first_input(){ :; }
    session_live(){ return 1; }; write_state(){ :; }; sess_resume_id(){ :; }
    launch_agent "$S" "$WD" >/dev/null 2>&1 )
  assert_no "[$cli] launch_agent cleared the checkpoint marker" test -f "$RUN_DIR/$S.checkpoint"

  echo "=== [$cli] a non-autonomous fleet is unchanged ==="
  setup
  export HARNESS_AUTONOMOUS=false
  snapshot "ready-for-agent,agent-paused"
  reap_done_sessions 2>/dev/null; reap_done_sessions 2>/dev/null
  assert_eq "$(nudges)" "0" "[$cli] non-autonomous: no nudge"
  assert_eq "$(killed)" "0" "[$cli] non-autonomous: no kill"
  assert_no "[$cli] non-autonomous: no self-park state" test -f "$RUN_DIR/$S.selfpark"
done

echo "=== the knob has a documented default ==="
assert_eq "$HARNESS_SELFPARK_GRACE_MIN" "30" "HARNESS_SELFPARK_GRACE_MIN defaults to 30"

finish

#!/usr/bin/env bash
# harness-test-timeout-windows: 1800
# test_winsma_park.sh — #1034: a lane waiting on the winsma lock parks, frees its pool slot, and is re-dispatched once, as a
# resume, when its ticket is next. The engine half (the winsma.sh half is test_winsma.sh's "# park" section): the waiting label
# keeps an issue out of dispatch, `check` reads a parked session as done (so the slot is freed) and never as PAUSED (so the #417
# self-park nudge never sees it), winsma_wake_tick removes the label when `winsma.sh turn` says the ticket is next, and an
# unreachable host leaves the issue parked. A fake winsma (a fake ssh running the host script locally, a fake C: drive), a
# stub gh, issuelib over a snapshot.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
ROOT="$HERE/.."; W="$ROOT/test/smoke/winsma"
rc=0

snap(){ python3 - "$SNAP" "$@" <<'PY'
import json, sys, time
path, specs = sys.argv[1], sys.argv[2:]
issues = []
for s in specs:
    n, _, labels = s.partition(":")
    issues.append({"number": int(n), "title": f"t{n}", "state": "OPEN", "body": "## What to build\nx\n",
                   "labels": [{"name": l} for l in labels.split(",") if l], "author": {"login": "bot"}, "updatedAt": "2026-11-11T02:50:00Z"})
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget", "issues": issues, "has_plan": False,
           "plan_marker": None, "self_login": "bot", "ext_deps": {}, "issue_branches": []}, open(path, "w"))
PY
}
# snap_prd <prd-labels> — a PRD (#900) whose one child (#901) is closed: its review is due. HARNESS_MODE=prd.
snap_prd(){ python3 - "$SNAP" "$1" <<'PY'
import json, sys, time
path, labels = sys.argv[1], sys.argv[2]
def iss(n, state, labs, body):
    return {"number": n, "title": f"t{n}", "state": state, "body": body, "labels": [{"name": l} for l in labs.split(",") if l],
            "author": {"login": "bot"}, "updatedAt": "2026-11-11T02:50:00Z"}
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget", "has_plan": False, "plan_marker": None,
           "self_login": "bot", "ext_deps": {}, "issue_branches": [],
           "issues": [iss(900, "OPEN", labels, "## Acceptance criteria\n- x\n"), iss(901, "CLOSED", "ready-for-agent", "## What to build\nx\n\n## Blocked by\nNone\n\n## Parent\n#900\n")]},
          open(path, "w"))
PY
}
revs(){ HARNESS_MODE=prd python3 "$ISSUELIB" dispatch acme/widget 3 2>/dev/null | cut -f1,2 | tr '\t' ':' | tr '\n' ' ' | sed 's/ $//'; }
setup(){ make_env
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude
  SLUG=acme/widget; REPO=acme/widget; UNIT=main
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"; unset HARNESS_SNAPSHOT_DIR
  T="$RUN_DIR/winsma"; mkdir -p "$T/c" "$T/bin"; printf '#!/usr/bin/env bash\nexec bash -s\n' >"$T/bin/fakessh"; printf '#!/usr/bin/env bash\nnohup bash "$1" >/dev/null 2>&1 </dev/null &\necho $!\n' >"$T/bin/spawn"; chmod +x "$T/bin/fakessh" "$T/bin/spawn"
  export WS_C="$T/c" WINSMA_SSH="$T/bin/fakessh" HARNESS_WINDOWS_HOST=winsma-fake WS_POLL=0.2 WS_STALE_SEC=1800 WS_WAKE_TIMEOUT=30 GH_TOKEN=x
  export WS_OWNER_LIVE_CMD=true HARNESS_WINSMA_WAKE_S=0 WS_SPAWN="$T/bin/spawn" WS_HB_INTERVAL=1 WS_KILL=kill WS_PYTHON=python3
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; LOGF="$RUN_DIR/log"; : > "$LOGF"; LIVELABELS="$RUN_DIR/livelabels"
  gh(){ echo "gh $*" >> "$CALLS"
        case "$*" in
          "issue view "*"--json labels"*) cat "$LIVELABELS" 2>/dev/null;;
        esac; return 0; }
  log(){ echo "$*" >> "$LOGF"; }
  harness_event(){ echo "event $*" >> "$CALLS"; }
  ws(){ ( source "$W/winsma.sh"; "$@" ); }          # run a ws_* function against the fake host
  impls(){ python3 "$ISSUELIB" dispatch acme/widget 3 2>/dev/null | cut -f1,2 | tr '\t' ':' | tr '\n' ' ' | sed 's/ $//'; }
  edits(){ grep -c "^gh issue edit .*--remove-label waiting-winsma" "$CALLS"; }
}

echo "=== 1. the waiting label keeps an issue out of dispatch; the slot goes to the next one ==="
setup; snap "222:ready-for-agent,waiting-winsma" "333:ready-for-agent"
assert_eq "$(impls)" "IMPL:333" "a parked issue is never dispatched; the free slot goes to the next claimable issue"
snap "222:ready-for-agent,waiting-winsma"
assert_eq "$(python3 "$ISSUELIB" dispatch acme/widget 3 2>/dev/null | wc -l | tr -d ' ')" "0" "...and with nothing else claimable nothing is dispatched (the issue is not stuck: no STUCK diagnosis)"
assert_no "a parked issue is not reported STUCK by status" bash -c "python3 '$ISSUELIB' status acme/widget 2>&1 | grep -q STUCK"
snap "222:bug,waiting-winsma" "333:bug"
assert_eq "$(python3 -c "import sys; sys.path.insert(0, '$ROOT/scripts'); import issuelib as i; print(i.bug_lane_issues('acme/widget'))")" "[333]" "the bug lane leaves a parked bug alone too"
snap "222:ready-for-agent"
assert_eq "$(impls)" "IMPL:222" "the label gone: dispatched, once"

echo "=== 2. a parked session is DONE (slot freed), never PAUSED (no #417 nudge) ==="
setup
snap "222:ready-for-agent,waiting-winsma"
assert_eq "$(python3 "$ISSUELIB" check acme/widget ISSUE:222 2>/dev/null)" "DONE" "waiting label, no agent-working: the session's goal is satisfied"
snap "222:ready-for-agent,waiting-winsma,agent-working"
assert_eq "$(python3 "$ISSUELIB" check acme/widget ISSUE:222 2>/dev/null)" "PENDING" "still agent-working (mid-swap): the lane is left alone"
snap "222:ready-for-agent,agent-paused"
assert_eq "$(python3 "$ISSUELIB" check acme/widget ISSUE:222 2>/dev/null)" "PAUSED" "(control) agent-paused without agent-working is still PAUSED"
snap "222:ready-for-agent,waiting-winsma"
SESS=hz-main-i222; echo "ISSUE:222" > "$RUN_DIR/$SESS.goal"; echo "/wt/222" > "$RUN_DIR/$SESS.wd"
cli_kill(){ echo "kill $1" >> "$CALLS"; }; selfpark_tend(){ echo "selfpark $1" >> "$CALLS"; }; stats_sess_event(){ :; }
check_session_goal "$SESS"
assert_eq "$(grep -c '^kill hz-main-i222' "$CALLS")" "1" "check_session_goal ends B's session: B holds no lane (its slot is free)"
assert_eq "$(grep -c '^selfpark' "$CALLS")" "0" "the #417 self-park nudge never touches a parked issue"
assert_no "the session's goal file is gone with it" test -f "$RUN_DIR/$SESS.goal"

echo "=== 3. the wake tick: queue behind A, park, A releases, B is re-dispatched exactly once as a resume ==="
setup
ws ws_lock 111 lane-a $$ >/dev/null                                  # A holds the lock
ws ws_call r_queue_join 222 lane-b $$ >/dev/null; sleep 0.05; ws ws_call r_queue_join 333 lane-c $$ >/dev/null   # B queued, then C
snap "222:ready-for-agent,waiting-winsma" "333:ready-for-agent,waiting-winsma"                                # both parked
printf 'waiting-winsma\nready-for-agent\n' > "$LIVELABELS"
winsma_wake_tick
assert_eq "$(edits)" "0" "A holds the lock: nobody is woken"
ws ws_unlock 111
winsma_wake_tick
assert_eq "$(edits)" "1" "A released: exactly one label removed"
assert_ok "...the one of B, whose ticket is next" grep -q '^gh issue edit 222 .*--remove-label waiting-winsma' "$CALLS"
assert_no "...C stays parked behind it" grep -q '^gh issue edit 333' "$CALLS"
assert_eq "$(grep -c '^event winsma_wake' "$CALLS")" "1" "one winsma_wake event"
printf 'ready-for-agent\n' > "$LIVELABELS"                         # gh now shows the label gone; the snapshot still lags
winsma_wake_tick; winsma_wake_tick
assert_eq "$(edits)" "1" "a laggy snapshot does not make the tick wake B again (the live labels are read first)"
snap "222:ready-for-agent" "333:ready-for-agent,waiting-winsma"
assert_eq "$(impls)" "IMPL:222" "B is dispatched once; C is still held"
# the dispatch is a resume: the branch B parked is on origin
( spawn_state(){ :; }
  launch_claude(){ :; }; ensure_checkout(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }; remove_worktree(){ :; }
  default_branch(){ echo main; }; session_live(){ return 1; }; issue_parent_prd(){ :; }; resume_handoff(){ :; }; win_repo_config(){ :; }
  git(){ case "$*" in *"worktree add"*) local a; for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && mkdir -p "$a" && : > "$a/.git"; done;;
                      *"ls-remote --heads origin issue/222"*) echo "abc123	refs/heads/issue/222";; esac; return 0; }
  CHECKOUT="$RUN_DIR/co"; mkdir -p "$CHECKOUT"; PROJECT=w; DESC=d; PROMISE=P
  prepare_impl 222 "ISSUE 222 DONE" >/dev/null 2>&1
  echo "$IMPL_TMPL" > "$RUN_DIR/tmpl" )
assert_eq "$(cat "$RUN_DIR/tmpl" 2>/dev/null)" "resume.md" "...through the resume path, from the pushed branch"
ws ws_lock 222 lane-b2 $$ >/dev/null 2>&1; assert_eq "$?" "0" "B's next lock attempt succeeds at once"
assert_eq "$(sed -n 's/^issue=//p' "$WS_C/hx-lock/owner")" "222" "...ahead of C, which queued after it"

echo "=== 4. the host cannot be reached: the issue stays parked, nothing crashes ==="
setup
ws ws_call r_queue_join 222 lane-b $$ >/dev/null
snap "222:ready-for-agent,waiting-winsma"; printf 'waiting-winsma\n' > "$LIVELABELS"
WINSMA_SSH=false winsma_wake_tick; r1=$?; WINSMA_SSH=false winsma_wake_tick
assert_eq "$r1" "0" "the tick returns cleanly"
assert_eq "$(edits)" "0" "the label stays: the issue is not dispatched"
assert_eq "$(grep -c 'stays parked' "$LOGF")" "1" "one log line per outage, not one per tick"
winsma_wake_tick
assert_eq "$(edits)" "1" "the host back: the ticket is next and the lock free, the label goes"
WS_WAKE_TIMEOUT=1; export WS_WAKE_TIMEOUT
printf '#!/usr/bin/env bash\nsleep 30\n' > "$RUN_DIR/slowssh"; chmod +x "$RUN_DIR/slowssh"
printf 'waiting-winsma\n' > "$LIVELABELS"; : > "$CALLS"
s0=$SECONDS; WINSMA_SSH="$RUN_DIR/slowssh" winsma_wake_tick; el=$((SECONDS - s0))
assert_eq "$(( el < 20 ))" "1" "a host that hangs is cut off by WS_WAKE_TIMEOUT"
assert_eq "$(edits)" "0" "...and the issue stays parked"

echo "=== 5. no parked issue: no call at all; no Windows host configured: nothing to wait for ==="
setup; snap "222:ready-for-agent"
WINSMA_SSH="$RUN_DIR/does-not-exist" winsma_wake_tick; assert_eq "$?" "0" "no parked issue: the host is never asked"
assert_eq "$(edits)" "0" "...and nothing is edited"
snap "222:ready-for-agent,waiting-winsma"; printf 'waiting-winsma\n' > "$LIVELABELS"
HARNESS_WINDOWS_HOST="" winsma_wake_tick
assert_eq "$(edits)" "1" "no HARNESS_WINDOWS_HOST: nothing to wait for, the label is removed"
setup; snap "222:ready-for-agent,waiting-winsma"; ws ws_call r_queue_join 222 lane-b $$ >/dev/null; printf 'waiting-winsma\n' > "$LIVELABELS"
HARNESS_WINSMA_WAKE_S=3600 winsma_wake_tick; HARNESS_WINSMA_WAKE_S=3600 winsma_wake_tick
assert_eq "$(edits)" "1" "the tick is throttled to one pass per HARNESS_WINSMA_WAKE_S"

echo "=== 7. the PRD review lane parks too (#1038) ==="
setup
snap_prd "prd"
assert_eq "$(revs)" "REVIEW:900" "(control) a PRD whose children are closed is dispatched a review"
snap_prd "prd,waiting-winsma"
assert_eq "$(revs)" "" "a PRD carrying the waiting label is never dispatched a review (no slot taken)"
assert_no "...and is not reported STUCK" bash -c "HARNESS_MODE=prd python3 '$ISSUELIB' status acme/widget 2>&1 | grep -q STUCK"
assert_eq "$(HARNESS_MODE=prd python3 "$ISSUELIB" check acme/widget REVIEW:900 2>/dev/null)" "DONE" "check reads the parked review session as done (its slot is freed)"
snap_prd "prd"
assert_eq "$(HARNESS_MODE=prd python3 "$ISSUELIB" check acme/widget REVIEW:900 2>/dev/null)" "PENDING" "(control) an unparked, unreviewed PRD: the review is still running"
snap_prd "prd,waiting-winsma"
SESS=hz-main-orch-900; echo "REVIEW:900" > "$RUN_DIR/$SESS.goal"; echo "/wt/orch900" > "$RUN_DIR/$SESS.wd"; : > "$CALLS"
cli_kill(){ echo "kill $1" >> "$CALLS"; }; selfpark_tend(){ echo "selfpark $1" >> "$CALLS"; }; stats_sess_event(){ :; }
HARNESS_MODE=prd check_session_goal "$SESS"
assert_eq "$(grep -c '^kill hz-main-orch-900' "$CALLS")" "1" "check_session_goal ends the review's session: it holds no slot"
assert_eq "$(grep -c '^selfpark' "$CALLS")" "0" "the #417 self-park nudge never touches a parked review"
assert_no "the session's goal file is gone with it" test -f "$RUN_DIR/$SESS.goal"

echo "=== 8. a review lane queues behind A, parks, is woken when its ticket is next and re-dispatched exactly once ==="
setup
export GHLOG="$RUN_DIR/ghpark"; : > "$GHLOG"
ws ws_lock 111 lane-a $$ >/dev/null                                  # A holds the lock
ws ws_call r_queue_join 900 review-900 $$ >/dev/null                  # the review lane queues (its issue number is the PRD's)
( gh(){ echo "gh $*" >> "$GHLOG"; return 0; }; export WS_PARK_CHECK_PUSHED=1   # a throwaway worktree: no pushed branch, and still no refusal
  cd "$RUN_DIR" || exit 1; ws ws_park 900 acme/widget --review >/dev/null 2>"$RUN_DIR/park.err" ); assert_eq "$?" "0" "the review lane parks with --review from an unpushed throwaway worktree"
assert_eq "$(grep -c 'issue edit 900 .*--add-label waiting-winsma' "$GHLOG")" "1" "the PRD gets the waiting label, in one edit"
assert_no "...which neither removes agent-working nor touches agent-paused" grep -Eq 'remove-label|agent-paused' "$GHLOG"
assert_ok "...and a park comment with the review marker is posted on the PRD" grep -q 'issue comment 900 .*harness-winsma-review-park prd=900' "$GHLOG"
assert_no "an implementation park (no --review) from the same worktree is still refused for being unpushed" bash -c "cd '$RUN_DIR' && source '$W/winsma.sh' && gh(){ return 0; } && ws_park 900 acme/widget"
assert_eq "$(ws ws_call r_queue_state | awk '{print $2}' | tr '\n' ' ')" "900 " "its ticket survives the park"
snap_prd "prd,waiting-winsma"; printf 'prd\nwaiting-winsma\n' > "$LIVELABELS"; : > "$CALLS"
assert_eq "$(revs)" "" "parked: no REVIEW is dispatched"
winsma_wake_tick
assert_eq "$(edits)" "0" "A holds the lock: the review is not woken"
ws ws_unlock 111
winsma_wake_tick
assert_ok "A released: the wake tick removes the label from the PRD" grep -q '^gh issue edit 900 .*--remove-label waiting-winsma' "$CALLS"
printf 'prd\n' > "$LIVELABELS"; winsma_wake_tick; winsma_wake_tick
assert_eq "$(edits)" "1" "...exactly once (a laggy snapshot does not wake it again)"
snap_prd "prd"
assert_eq "$(revs)" "REVIEW:900" "the PRD is re-dispatched as REVIEW:900, exactly once"
ws ws_lock 900 review-900b $$ >/dev/null 2>&1; assert_eq "$?" "0" "the re-dispatched review takes the lock on its first attempt"
assert_ok "the Windows suite prompt tells a queued review how to park" bash -c "grep -q 'winsma.sh park {{PRD}} {{SLUG}} --review' '$ROOT/prompts/_windows_suite.md' && grep -q 'waiting-winsma' '$ROOT/prompts/_windows_suite.md'"
assert_ok "prepare_orch renders the suite block with the slug" grep -q 'windows_block _windows_suite.md PRD="\$payload" SLUG="\$SLUG"' "$ROOT/scripts/drive.sh"

echo "=== 9. the park is an engine-owned wait spec (#1066): written next to the label, woken by its deadline, spent on the wake ==="
setup
ws ws_lock 111 lane-a $$ >/dev/null                                  # A holds the lock, so B parks instead of taking it
ws ws_call r_queue_join 222 lane-b $$ >/dev/null
export GHLOG="$RUN_DIR/ghpark9"; : > "$GHLOG"; WF="$RUN_DIR/hz-main-i222.wait"
( gh(){ echo "gh $*" >> "$GHLOG"; return 0; }; export HARNESS_WAIT_FILE="$WF" WS_PARK_CHECK_PUSHED=0
  cd "$RUN_DIR" || exit 1; ws ws_park 222 acme/widget >/dev/null 2>&1 ); assert_eq "$?" "0" "B parks"
assert_eq "$(python3 "$ROOT/scripts/waitlib.py" fields --file "$WF" cond resume issue slug label)" $'winsma\tredispatch\t222\tacme/widget\twaiting-winsma' "park wrote the lane's wait spec: cond winsma, resume redispatch, the issue, the label"
dl=$(python3 "$ROOT/scripts/waitlib.py" fields --file "$WF" deadline | cut -f1); dl=${dl%%.*}
assert_ok "...with a deadline (12h by default)" test "$dl" -gt "$(( $(date +%s) + 40000 ))"
snap "222:ready-for-agent,waiting-winsma"; printf 'waiting-winsma\n' > "$LIVELABELS"; : > "$CALLS"
WINSMA_SSH=false winsma_wake_tick
assert_eq "$(edits)" "0" "the host cannot be asked and the deadline is far: B stays parked"
python3 - "$WF" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["deadline"] = 1; json.dump(d, open(p, "w"))
PY
WINSMA_SSH=false winsma_wake_tick
assert_eq "$(edits)" "1" "its deadline passed: the label is removed without asking the host"
assert_ok "...the log says why" grep -q 'winsma-wake: #222 — its wait deadline passed' "$LOGF"
assert_no "...and the spent park is forgotten" test -e "$WF"
assert_eq "$(grep -c '^event wait_done .*cond=winsma' "$CALLS")" "1" "one wait_done event"
unset HARNESS_WAIT_FILE
setup; snap "222:ready-for-agent,waiting-winsma"; printf 'waiting-winsma\n' > "$LIVELABELS"; ws ws_call r_queue_join 222 lane-b $$ >/dev/null
winsma_wake_tick
assert_eq "$(edits)" "1" "(control) a label with no spec, from before #1066, is still woken by the ticket alone"

echo "=== 6. wired into the pool's chores, the label is seeded and configurable ==="
assert_ok "worker_chores runs winsma_wake_tick" grep -q 'winsma_wake_tick' "$ROOT/scripts/pool-worker.sh"
assert_eq "$HARNESS_LABEL_WAITING_WINSMA" "waiting-winsma" "the label defaults to waiting-winsma"
assert_ok "seed.sh seeds it" grep -q 'HARNESS_LABEL_WAITING_WINSMA' "$ROOT/scripts/seed.sh"
assert_ok "init.sh writes it" grep -q 'HARNESS_LABEL_WAITING_WINSMA' "$ROOT/scripts/init.sh"

finish || rc=1
exit $rc

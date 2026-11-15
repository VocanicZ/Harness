#!/usr/bin/env bash
# test_quota_park.sh — #1154: a lane whose wait is hours away (a usage window that resets later) parks: it gives its pool slot up
# (the waiting-quota label, no agent-working) instead of holding it for days, another ready issue takes the slot, and at the reset the
# engine re-dispatches the parked issue ONCE, as a resume. The engine half (waitlib.py set / quota-park.sh are test_waitlib.py's):
# the label keeps an issue out of dispatch and out of STUCK, `check` reads a parked session as done (so the slot is freed) and never
# as PAUSED, quota_wake_tick removes the label once the reset time has passed and no usage hold stands, staggered, once.
# A stub gh, issuelib over a snapshot, real wait specs under RUN_DIR.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
ROOT="$HERE/.."; WL="$ROOT/scripts/waitlib.py"

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
setup(){ make_env
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude HARNESS_QUOTA_WAKE_S=0 HARNESS_WAIT_STAGGER_S=0
  SLUG=acme/widget; REPO=acme/widget; UNIT=main
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"; unset HARNESS_SNAPSHOT_DIR
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; LOGF="$RUN_DIR/log"; : > "$LOGF"; LIVELABELS="$RUN_DIR/livelabels"
  gh(){ echo "gh $*" >> "$CALLS"
        case "$*" in "issue view "*"--json labels"*) cat "$LIVELABELS" 2>/dev/null;; esac; return 0; }
  log(){ echo "$*" >> "$LOGF"; }
  harness_event(){ echo "event $*" >> "$CALLS"; }
  impls(){ python3 "$ISSUELIB" dispatch acme/widget 3 2>/dev/null | cut -f1,2 | tr '\t' ':' | tr '\n' ' ' | sed 's/ $//'; }
  edits(){ grep -c "^gh issue edit .*--remove-label waiting-quota" "$CALLS"; }
  # park <issue> <until-epoch> [account] — the spec a parked lane leaves (waitlib.py set, in a lane, as quota-park.sh ran)
  park(){ local f="$RUN_DIR/$HARNESS_SESS_PREFIX-main-i$1.wait"
    python3 "$WL" set --file "$f" --limit --until "$2" --account "${3:-}" --resume redispatch --what "usage limit (resets later)" >/dev/null
    python3 - "$f" "$1" <<'PY'
import json, sys
p, n = sys.argv[1:]; d = json.load(open(p)); d.update({"issue": int(n), "slug": "acme/widget", "label": "waiting-quota"}); json.dump(d, open(p, "w"))
PY
  }
}
export HARNESS_SESS_PREFIX=qpk

echo "=== 1. the label keeps an issue out of dispatch; the freed slot goes to the next ready issue ==="
setup; snap "222:ready-for-agent,waiting-quota" "333:ready-for-agent"
assert_eq "$(impls)" "IMPL:333" "a quota-parked issue is never dispatched; the slot goes to the next claimable issue"
snap "222:ready-for-agent,waiting-quota"
assert_eq "$(python3 "$ISSUELIB" dispatch acme/widget 3 2>/dev/null | wc -l | tr -d ' ')" "0" "...with nothing else claimable nothing is dispatched"
assert_no "a parked issue is not reported STUCK by status" bash -c "python3 '$ISSUELIB' status acme/widget 2>&1 | grep -q STUCK"
snap "222:bug,waiting-quota" "333:bug"
assert_eq "$(python3 -c "import sys; sys.path.insert(0, '$ROOT/scripts'); import issuelib as i; print(i.bug_lane_issues('acme/widget'))")" "[333]" "the bug lane leaves a quota-parked bug alone too"
assert_eq "$(snap "222:ready-for-agent,waiting-quota"; python3 "$ISSUELIB" waiting-quota acme/widget)" "222" "issuelib waiting-quota lists the parked issue"
assert_eq "$(python3 "$ISSUELIB" waiting-winsma acme/widget)" "" "...and the winsma list does not"
snap "222:ready-for-agent"
assert_eq "$(impls)" "IMPL:222" "the label gone: dispatched, once"

echo "=== 2. ACCEPTANCE: a parked session is DONE, its slot is freed (count_team_sessions drops), never PAUSED ==="
setup
snap "222:ready-for-agent,waiting-quota,agent-working"
assert_eq "$(python3 "$ISSUELIB" check acme/widget ISSUE:222 2>/dev/null)" "PENDING" "mid-swap (still agent-working): the lane is left alone"
snap "222:ready-for-agent,waiting-quota"
assert_eq "$(python3 "$ISSUELIB" check acme/widget ISSUE:222 2>/dev/null)" "DONE" "waiting-quota, no agent-working: the session's goal is satisfied"
SESS=qpk-main-i222; echo "ISSUE:222" > "$RUN_DIR/$SESS.goal"; echo "/wt/222" > "$RUN_DIR/$SESS.wd"; : > "$RUN_DIR/$SESS.live"
sess_list(){ [[ -f "$RUN_DIR/$SESS.live" ]] && echo "$SESS"; echo "qpk-main-i500"; }   # #500 is another lane, still running
cli_kill(){ echo "kill $1" >> "$CALLS"; rm -f "$RUN_DIR/$1.live"; }; selfpark_tend(){ echo "selfpark $1" >> "$CALLS"; }; stats_sess_event(){ :; }
assert_eq "$(count_team_sessions main)" "2" "before the park: two sessions hold two slots"
check_session_goal "$SESS"
assert_eq "$(grep -c '^kill qpk-main-i222' "$CALLS")" "1" "check_session_goal ends the parked lane's session"
assert_eq "$(count_team_sessions main)" "1" "count_team_sessions drops: the slot is free"
assert_eq "$(grep -c '^selfpark' "$CALLS")" "0" "the #417 self-park nudge never touches a parked issue"
unset -f sess_list cli_kill selfpark_tend stats_sess_event

echo "=== 3. ACCEPTANCE: at the reset the parked issue is re-dispatched exactly once, as a resume; not before ==="
setup
NOW="$(date +%s)"; park 222 "$((NOW + 7200))"
snap "222:ready-for-agent,waiting-quota" "333:ready-for-agent"; printf 'waiting-quota\nready-for-agent\n' > "$LIVELABELS"
assert_eq "$(python3 "$WL" parked --dir "$RUN_DIR" | cut -f2,5)" $'222\tlimit' "the park spec is in the run dir"
quota_wake_tick
assert_eq "$(edits)" "0" "two hours before the reset: not woken"
python3 - "$RUN_DIR/qpk-main-i222.wait" <<'PY'
import json, sys, time
p = sys.argv[1]; d = json.load(open(p)); d["not_before"] = time.time() - 5; json.dump(d, open(p, "w"))
PY
quota_wake_tick
assert_eq "$(edits)" "1" "the reset passed: exactly one label removed"
assert_ok "...the one of #222" grep -q '^gh issue edit 222 .*--remove-label waiting-quota' "$CALLS"
assert_eq "$(grep -c '^event wait_done .*cond=limit resume=redispatch' "$CALLS")" "1" "one wait_done event"
assert_ok "...the log says why" grep -q 'quota-wake: #222 — its usage window reset' "$LOGF"
assert_eq "$(python3 "$WL" parked --dir "$RUN_DIR")" "" "...and the spent park spec is forgotten"
printf 'ready-for-agent\n' > "$LIVELABELS"                      # gh now shows the label gone; the snapshot still lags
quota_wake_tick; quota_wake_tick
assert_eq "$(edits)" "1" "a laggy snapshot does not wake it again"
snap "222:ready-for-agent" "333:ready-for-agent"
assert_eq "$(impls)" "IMPL:222 IMPL:333" "#222 is dispatched with the rest, once"
# the dispatch is a resume: the branch the lane parked is on origin
( spawn_state(){ :; }
  launch_claude(){ :; }; ensure_checkout(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }; remove_worktree(){ :; }
  default_branch(){ echo main; }; session_live(){ return 1; }; issue_parent_prd(){ :; }; resume_handoff(){ :; }; win_repo_config(){ :; }
  git(){ case "$*" in *"worktree add"*) local a; for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && mkdir -p "$a" && : > "$a/.git"; done;;
                      *"ls-remote --heads origin issue/222"*) echo "abc123	refs/heads/issue/222";; esac; return 0; }
  CHECKOUT="$RUN_DIR/co"; mkdir -p "$CHECKOUT"; PROJECT=w; DESC=d; PROMISE=P
  prepare_impl 222 "ISSUE 222 DONE" >/dev/null 2>&1
  echo "$IMPL_TMPL" > "$RUN_DIR/tmpl" )
assert_eq "$(cat "$RUN_DIR/tmpl" 2>/dev/null)" "resume.md" "...through the resume path, from the pushed branch"

echo "=== 4. a usage hold, a stagger and a late snapshot: the wake waits for each ==="
setup
NOW="$(date +%s)"; park 222 "$((NOW - 5))" acctA; park 333 "$((NOW - 5))" acctB
snap "222:ready-for-agent,waiting-quota" "333:ready-for-agent,waiting-quota"; printf 'waiting-quota\n' > "$LIVELABELS"
mkdir -p "$RUN_DIR/usage-holds"; : > "$RUN_DIR/usage-holds/acctA.hold"
quota_wake_tick
assert_eq "$(edits)" "1" "acctA is on a usage hold: #222 stays parked; #333 (acctB, no hold) is woken"
assert_ok "...#333 is the one woken" grep -q '^gh issue edit 333 .*--remove-label waiting-quota' "$CALLS"
rm -f "$RUN_DIR/usage-holds/acctA.hold"
quota_wake_tick
assert_ok "the hold cleared: #222 is woken at the next tick" grep -q '^gh issue edit 222 .*--remove-label waiting-quota' "$CALLS"
setup
NOW="$(date +%s)"; park 222 "$((NOW - 5))"; park 333 "$((NOW - 5))"
snap "222:ready-for-agent,waiting-quota" "333:ready-for-agent,waiting-quota"; printf 'waiting-quota\n' > "$LIVELABELS"
export HARNESS_WAIT_STAGGER_S=3600
quota_wake_tick
assert_eq "$(edits)" "1" "two parks due in the same tick: staggered, one wake (the other waits for the next window)"
export HARNESS_WAIT_STAGGER_S=0
quota_wake_tick
assert_ok "...and the next tick wakes the other" grep -q '^gh issue edit 333 .*--remove-label waiting-quota' "$CALLS"
setup; snap "222:ready-for-agent,waiting-quota"; printf 'waiting-quota\n' > "$LIVELABELS"
quota_wake_tick
assert_eq "$(edits)" "1" "a label with no spec on this host (a lost run dir) is woken, not parked for ever"
setup; snap "222:ready-for-agent"; quota_wake_tick
assert_eq "$(grep -c '^gh ' "$CALLS")" "0" "no parked issue: no gh call at all"

echo "=== 5. a file park wakes when its file appears, or its deadline passes ==="
setup
F="$RUN_DIR/qpk-main-i222.wait"; GATE="$RUN_DIR/gate-open"
python3 "$WL" set --file "$F" --path "$GATE" --deadline-s 72000 --resume redispatch >/dev/null
python3 - "$F" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d.update({"issue": 222, "slug": "acme/widget", "label": "waiting-quota"}); json.dump(d, open(p, "w"))
PY
snap "222:ready-for-agent,waiting-quota"; printf 'waiting-quota\n' > "$LIVELABELS"
quota_wake_tick; assert_eq "$(edits)" "0" "the file is not there: still parked"
: > "$GATE"; quota_wake_tick; assert_eq "$(edits)" "1" "the file appeared: woken"

echo "=== 5b. scripts/quota-park.sh itself: the handoff, one label edit, and the refusals ==="
setup
QB="$RUN_DIR/qbin"; QLOG="$RUN_DIR/qgh.log"; mkdir -p "$QB"; : > "$QLOG"
printf '#!/usr/bin/env bash\nprintf "gh %%s\\n" "$(printf %%s "$*" | tr "\\n" " ")" >> "%s"\n' "$QLOG" > "$QB/gh"; chmod +x "$QB/gh"
git init -q --bare "$RUN_DIR/origin.git"; git clone -q "$RUN_DIR/origin.git" "$RUN_DIR/qwt" 2>/dev/null
( cd "$RUN_DIR/qwt" && git checkout -q -b issue/77 && echo a > f && git add f \
  && git -c user.name=t -c user.email=t@t commit -q -m wip && git push -q -u origin issue/77 )
qpark(){ ( cd "$RUN_DIR/qwt" && PATH="$QB:$PATH" bash "$ROOT/scripts/quota-park.sh" "$@" ); }
out="$(qpark 77 acme/widget 4102444800 "usage limit (resets Sun)" 2>&1)"; rc=$?
assert_eq "$rc" "0" "a clean, pushed branch parks"
assert_ok "...the handoff comment leads with the harness-handoff marker for the issue and branch" grep -q '^gh issue comment 77 -R acme/widget --body <!-- harness-handoff issue=77 branch=issue/77 -->' "$QLOG"
assert_ok "...and says when the issue is re-dispatched" grep -q 'not before 2100-01-01' "$QLOG"
assert_eq "$(grep -c '^gh issue edit' "$QLOG")" "1" "...ONE label edit"
assert_ok "...that swaps agent-working for waiting-quota" grep -q '^gh issue edit 77 -R acme/widget --add-label waiting-quota --remove-label agent-working$' "$QLOG"
: > "$QLOG"; echo dirty > "$RUN_DIR/qwt/g"
qpark 77 acme/widget 0 >/dev/null 2>"$RUN_DIR/qerr"; assert_eq "$?" "1" "a dirty worktree is refused"
assert_ok "...saying why" grep -q 'uncommitted changes' "$RUN_DIR/qerr"
assert_eq "$(wc -l < "$QLOG" | tr -d ' ')" "0" "...with no gh call: the lane keeps agent-working"
rm -f "$RUN_DIR/qwt/g"; ( cd "$RUN_DIR/qwt" && echo b >> f && git -c user.name=t -c user.email=t@t commit -q -am more )
qpark 77 acme/widget 0 >/dev/null 2>"$RUN_DIR/qerr"; assert_eq "$?" "1" "an unpushed HEAD is refused"
assert_ok "...saying so" grep -q 'is not pushed' "$RUN_DIR/qerr"
HARNESS_PARK_CHECK_PUSHED=0 qpark 77 acme/widget 0 >/dev/null 2>&1; assert_eq "$?" "0" "HARNESS_PARK_CHECK_PUSHED=0 skips the push check"
qpark x acme/widget >/dev/null 2>&1; assert_eq "$?" "1" "a non-numeric issue is refused"

echo "=== 6. wired into the pool's chores, the label is seeded, configurable and documented ==="
assert_ok "worker_chores runs quota_wake_tick" grep -q 'quota_wake_tick' "$ROOT/scripts/pool-worker.sh"
assert_eq "$HARNESS_LABEL_WAITING_QUOTA" "waiting-quota" "the label defaults to waiting-quota"
assert_ok "seed.sh seeds it" grep -q 'HARNESS_LABEL_WAITING_QUOTA' "$ROOT/scripts/seed.sh"
assert_ok "init.sh writes it" grep -q 'HARNESS_LABEL_WAITING_QUOTA' "$ROOT/scripts/init.sh"
assert_ok "docs/reference.md documents the label" grep -q 'HARNESS_LABEL_WAITING_QUOTA' "$ROOT/docs/reference.md"
assert_ok "the LONG WAITS prompt tells a lane to park a wait that is hours away" grep -q 'PARKS you (#1154)' "$ROOT/prompts/_long_waits.md"
finish || rc=1
exit ${rc:-0}

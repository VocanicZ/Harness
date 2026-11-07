#!/usr/bin/env bash
# test_launch_failed.sh — #596 (PRD #587 §2): a tmux launch counts only if the session really exists.
#   1. tmux_sess_start confirms the session with has-session: a tmux that exits 0 without creating one
#      (`error creating …`) is a failed start
#   2. the caller's (stale) TMUX is not passed to the lane's tmux: the launch lands on the default server
#   3. launch_agent whose start failed logs launch_failed, not launch, and leaves no .launched mark
#   4. a lane gone within 30s of its launch logs launch_failed; claim_lane then holds that issue back for the
#      backoff (no tight spin), takes another issue meanwhile, and re-claims once the backoff ran out
#   5. a lane that ran past 30s is a normal reap: no launch_failed, and its backoff is cleared
# Real tmux on a private TMUX_TMPDIR for 1-2 (kills only its own server); gh, git and the launch are stubbed after.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/scripts/lib.sh"; source "$ROOT/scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$ROOT/scripts/pool-worker.sh"; source "$HERE/helpers.sh"
command -v tmux >/dev/null || { echo "  skip: tmux not installed"; exit 0; }
T="$(mktemp -d /tmp/t596.XXXXXX)"
trap 'TMUX_TMPDIR="$T/srv" tmux kill-server 2>/dev/null; rm -rf "$T"' EXIT

not(){ ! "$@"; }
echo "== 1. a start that left no session is a failed start =="
mkdir -p "$T/fakebin"
cat > "$T/fakebin/tmux" <<'FAKE'
#!/bin/sh
case "$1" in
  new-session) echo "error creating /nonexistent/tmux-1000/default (No such file or directory)" >&2; exit 0;;
  has-session) exit 1;;
esac
exit 0
FAKE
chmod +x "$T/fakebin/tmux"
err="$( PATH="$T/fakebin:$PATH"; unset -f tmux; source "$ROOT/scripts/session/tmux.sh"; tmux_sess_start s596 /tmp 2>&1 )"; rc=$?
assert_eq "$rc" "1" "new-session printed an error and exited 0, no session: tmux_sess_start fails"
assert_ok "…and the tmux error stays visible to the caller" grep -q "error creating" <<<"$err"

echo "== 2. a stale TMUX does not reach the lane's tmux =="
export TMUX_TMPDIR="$T/srv"; mkdir -p "$TMUX_TMPDIR"
( export TMUX="$T/gone-dir/default,4242,0" TMUX_PANE=%0; unset -f tmux
  source "$ROOT/scripts/session/tmux.sh"; tmux_sess_start s596 /tmp -e HARNESS_SESSION=u596 )
assert_eq "$?" "0" "stale TMUX (socket directory missing): the launch succeeds on the default server"
assert_ok "…and the session exists there" env -u TMUX tmux has-session -t =s596
out="$( export TMUX="$T/gone-dir/default,4242,0" TMUX_PANE=%0; source "$ROOT/scripts/session/tmux.sh"; tmux_env_sanitize; echo "${TMUX-unset}/${TMUX_PANE-unset}" )"
assert_eq "$out" "unset/unset" "tmux_env_sanitize drops a TMUX whose socket is gone"
env -u TMUX tmux kill-server 2>/dev/null

echo "== 3. launch_agent whose backend could not start the session =="
restore(){ source "$ROOT/scripts/lib.sh"; source "$ROOT/scripts/drive.sh"; source "$ROOT/scripts/pool-worker.sh"; }
setup(){
  restore; make_env
  HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme; HARNESS_SESS_PREFIX=hz; HARNESS_UNIT=""
  POOL=2; POLL=0; HARNESS_USE_POLLER=0; HARNESS_CHECKOUT="$RUN_DIR/co"; mkdir -p "$HARNESS_CHECKOUT"
  export HARNESS_AUTONOMOUS=true HARNESS_MODE=issue-only HARNESS_POOL_TAKES_BUGS=0 HARNESS_CLI=claude HARNESS_CI_GATE=0
  WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
  SNAP="$RUN_DIR/snap.json"; export HARNESS_SNAPSHOT_FILE="$SNAP"
  HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"; export HARNESS_EVENTS_FILE; : > "$HARNESS_EVENTS_FILE"
  NOW=5000; date(){ if [[ "${1:-}" == +%s ]]; then echo "$NOW"; else command date "$@"; fi; }
  log(){ :; }; fleet_ctx; mkdir -p "$CLAIMS_DIR"
  gh(){ case "$*" in *"issue view"*) echo '{"state":"OPEN","labels":[]}';; esac; return 0; }; export -f gh
  remove_worktree(){ :; }; unlock_issue(){ :; }; one_lease_live(){ return 1; }
  ensure_checkout(){ :; }; busy_prds_for(){ :; }; busy_issues_for(){ :; }; is_claimed(){ [[ -f "$CLAIMS_DIR/$1.claim" ]]; }
}
evs(){ python3 -c 'import json,sys
for l in open(sys.argv[1]): print(json.loads(l).get("event"), end=" ")' "$HARNESS_EVENTS_FILE"; }
snap(){ python3 - "$SNAP" "$@" <<'PY'
import json, sys, time
path, nums = sys.argv[1], sys.argv[2:]
issues = [{"number": int(n), "title": f"t{n}", "state": "OPEN", "body": "## What to build\nx\n",
           "labels": [{"name": "ready-for-agent"}], "author": {"login": "bot"}, "updatedAt": "2026-11-02T02:50:00Z"} for n in nums]
json.dump({"schema_version": 1, "generated_at": time.time(), "slug": "acme/widget", "issues": issues, "has_plan": False,
           "plan_marker": None, "self_login": "bot", "ext_deps": {}, "issue_branches": []}, open(path, "w"))
PY
}

setup
WD="$RUN_DIR/wd"; mkdir -p "$WD"; SESS="$(sess_impl "$UNIT" 7)"; GOAL="ISSUE:7"; PROMISE="X"; MAXITER=1
session_live(){ return 1; }; sess_start(){ return 1; }; sess_backend(){ echo tmux; }
ensure_trusted(){ :; }; write_state(){ :; }; lane_guard_env(){ :; }; lane_tmp_env(){ :; }; sess_resume_id(){ :; }
launch_agent "$SESS" "$WD"; rc=$?
assert_eq "$rc" "1" "launch_agent returns failure when the session could not be started"
assert_eq "$(evs)" "launch_failed " "…logs launch_failed and no launch event"
assert_ok "…leaves no .launched mark" test ! -f "$RUN_DIR/$SESS.launched"
assert_ok "…and arms the lane's backoff" launch_backoff_active impl-7

echo "== 4. a lane gone within 30s of its launch =="
setup; snap 7 8
SESS7="$(sess_impl "$UNIT" 7)"
echo "$((NOW - 2)) uuid-7" > "$RUN_DIR/$SESS7.launched"     # launched 2s ago
session_live(){ return 1; }
reap_impl_lane 7
assert_eq "$(evs | grep -o launch_failed)" "launch_failed" "a lane gone 2s after launch logs launch_failed"
assert_eq "$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    e=json.loads(l)
    if e["event"]=="launch_failed": print(e.get("session"), e.get("kind"), e.get("issue"), e.get("reason"))' "$HARNESS_EVENTS_FILE")" \
  "uuid-7 impl 7 session_gone" "…naming its session, kind, issue and reason"
assert_ok "…and its claim key is in backoff" launch_backoff_active impl-7
session_live(){ return 1; }
got="$(claim_lane W1 | cut -f1,2)"
assert_eq "$got" "IMPL	8" "claim_lane skips #7 during its backoff and takes #8 (no tight spin on the failed one)"
rm -f "$CLAIMS_DIR/impl-8.claim"
snap 7
assert_eq "$(claim_lane W1 | cut -f1,2)" "" "with only #7 ready and its backoff running, nothing is claimed"
NOW=$((NOW + 61))
assert_eq "$(claim_lane W1 | cut -f1,2)" "IMPL	7" "after the backoff ran out #7 is claimed again"
rm -f "$CLAIMS_DIR/impl-7.claim"
launch_backoff_mark impl-7; launch_backoff_mark impl-7   # the third consecutive failure: 60 << 2 = 240s
NOW=$((NOW + 100))
assert_ok "the backoff doubles per consecutive failure: still held 100s after the third" launch_backoff_active impl-7
NOW=$((NOW + 150))
assert_ok "…and over after 250s (60s << 2 = 240s)" not launch_backoff_active impl-7

echo "== 5. a lane that ran past 30s is a plain reap =="
setup
SESS9="$(sess_impl "$UNIT" 9)"; echo "$((NOW - 400)) uuid-9" > "$RUN_DIR/$SESS9.launched"
launch_backoff_mark impl-9
session_live(){ return 1; }
reap_impl_lane 9
assert_eq "$(evs | grep -c launch_failed)" "0" "a lane that ran 400s is not a launch_failed"
assert_ok "…and its stale backoff is cleared" test ! -f "$RUN_DIR/launchfail.impl-9"

finish

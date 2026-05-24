#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/helpers.sh"; make_env
assert_no "not paused initially" is_paused
touch "$PAUSE_FLAG"
assert_ok "paused after flag created" is_paused
rm -f "$PAUSE_FLAG"
assert_no "not paused after flag removed" is_paused
# config default present
assert_eq "$HARNESS_LABEL_PAUSED" "agent-paused" "default paused label"

# --- worker_tick idles (rc 3) when paused, without claiming -------------------
source "$HERE/../drive.sh" 2>/dev/null || true
source "$HERE/../pool-worker.sh" 2>/dev/null || true
HARNESS_TOPOLOGY=multi
write_targets <<'EOF'
a	acme/a	-	root
EOF
set_complete
claimed=""
claim_next(){ claimed=yes; echo a; }   # if called, we'd see claimed=yes
touch "$PAUSE_FLAG"
worker_tick W1; rc=$?
assert_eq "$rc" "3" "worker_tick returns 3 when paused"
assert_eq "$claimed" "" "worker_tick did NOT claim while paused"
rm -f "$PAUSE_FLAG"

# --- drive_unit drains (breaks) when paused, without dispatching --------------
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; CAP=2; POLL=0
dispatched=""
reap_done_sessions(){ :; }; reap_team(){ :; }; count_team_sessions(){ echo 0; }
dispatch_actions(){ dispatched=yes; printf 'IMPL\t5\tISSUE 5 DONE\n'; }
spawn_impl(){ dispatched=spawned; }
unit_complete(){ return 1; }   # never complete on its own
touch "$PAUSE_FLAG"
drive_unit main
assert_eq "$dispatched" "" "drive_unit did NOT dispatch while paused (drained immediately)"
rm -f "$PAUSE_FLAG"

# --- pause.sh (soft) creates the flag -----------------------------------------
RUN_DIR2="$(mktemp -d)"
RUN_DIR="$RUN_DIR2" bash "$HERE/../pause.sh" >/dev/null 2>&1
assert_ok "soft pause.sh created PAUSED flag" bash -c "[[ -f '$RUN_DIR2/PAUSED' ]]"
rm -rf "$RUN_DIR2"

# --- pause --force: injects checkpoint, confirms via label, never kills -------
RUN_DIR3="$(mktemp -d)"; CALLS="$RUN_DIR3/calls"; : > "$CALLS"
export CALLS
export HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme HARNESS_PAUSE_GRACE=2
# one live impl session for unit "main", issue 5
tmux(){ echo "tmux $*" >> "$CALLS"
  case "$1" in
    ls) echo "hz-main-i5";;
    send-keys) : ;;
    kill-session) : ;;   # if ever called, recorded above
  esac; }
# gh: issue already carries the paused label -> confirms immediately
gh(){ echo "gh $*" >> "$CALLS"
  case "$1 $2" in
    "issue view") echo '{"labels":[{"name":"agent-paused"}]}';;
  esac; return 0; }
export -f tmux gh
RUN_DIR="$RUN_DIR3" bash "$HERE/../pause.sh" --force >/dev/null 2>&1
assert_ok "force: PAUSED flag set"            bash -c "[[ -f '$RUN_DIR3/PAUSED' ]]"
assert_ok "force: checkpoint sent to session" bash -c "grep -q 'send-keys' '$CALLS'"
assert_no "force: never killed the session"   bash -c "grep -q 'kill-session' '$CALLS'"
rm -rf "$RUN_DIR3"

# --- pause --force ALSO checkpoints priority-lane sessions (#36) --------------
# Legacy BARE lane sessions (hz-bug-<n>-(triage|fix)) — they end in -triage/-fix, not -i<digits>,
# so the old impl-only selector missed them and silently dropped an in-flight bug fix's WIP. A
# forced pause must reach BOTH lane phases: send the checkpoint, poll the bug's issue for
# agent-paused, never kill. The fix branch is issue/<n>; triage has no code branch but must still
# flip the label. (The bare form is the pre-#44 shape, still handled via the bug_bare_re fallback;
# the repo-qualified shape is covered by the #44 multi case below.)
RUN_DIR5="$(mktemp -d)"; CALLS5="$RUN_DIR5/calls"; : > "$CALLS5"
export CALLS="$CALLS5"
export HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme HARNESS_PAUSE_GRACE=2
# two live lane sessions: a fix and a triage, for bugs #9 and #11
tmux(){ echo "tmux $*" >> "$CALLS"
  case "$1" in
    ls) printf 'hz-bug-9-fix\nhz-bug-11-triage\n';;
    send-keys) : ;;
    kill-session) : ;;
  esac; }
gh(){ echo "gh $*" >> "$CALLS"
  case "$1 $2" in
    "issue view") echo '{"labels":[{"name":"agent-paused"}]}';;
  esac; return 0; }
export -f tmux gh
RUN_DIR="$RUN_DIR5" bash "$HERE/../pause.sh" --force >/dev/null 2>&1
assert_ok "lane fix: checkpoint sent to hz-bug-9-fix" \
  bash -c "grep -q 'send-keys -t hz-bug-9-fix' '$CALLS5'"
assert_ok "lane triage: checkpoint sent to hz-bug-11-triage" \
  bash -c "grep -q 'send-keys -t hz-bug-11-triage' '$CALLS5'"
assert_ok "lane: confirms via the bug's issue (polls gh issue view for #9)" \
  bash -c "grep -qE 'gh issue view 9 ' '$CALLS5'"
assert_no "lane: never killed a lane session" \
  bash -c "grep -q 'kill-session' '$CALLS5'"
assert_ok "lane: PAUSED flag set" bash -c "[[ -f '$RUN_DIR5/PAUSED' ]]"
unset CALLS
rm -rf "$RUN_DIR5"

# --- #44 multi-topology: pause --force routes to the CORRECT repo on collision --
# Two repos each hold a bug #6; the lane currently fixes acme/b's #6 (session
# hz-bug-acme_b-6-fix, claim bug-acme_b-6 carrying token acme/b#6). The old _checkpoint_target
# parsed the BARE number out of the session and re-resolved the repo via bug_repo — the
# "first repo that lists #6" rescan — which in `multi` picks the WRONG repo. The checkpoint
# message and the confirmation poll must reference acme/b (the repo CARRIED in the claim), never
# acme/a.
RUN_DIR6="$(mktemp -d)"; CALLS6="$RUN_DIR6/calls"; : > "$CALLS6"
mkdir -p "$RUN_DIR6/claims"
printf 'P1 12345 acme/b#6\n' > "$RUN_DIR6/claims/bug-acme_b-6.claim"
export CALLS="$CALLS6"
export HARNESS_TOPOLOGY=multi HARNESS_OWNER=acme HARNESS_PAUSE_GRACE=2
tmux(){ echo "tmux $*" >> "$CALLS"
  case "$1" in
    ls) printf 'hz-bug-acme_b-6-fix\n';;
    send-keys) : ;;
    kill-session) : ;;
  esac; }
gh(){ echo "gh $*" >> "$CALLS"
  case "$1 $2" in
    "issue view") echo '{"labels":[{"name":"agent-paused"}]}';;
  esac; return 0; }
export -f tmux gh
RUN_DIR="$RUN_DIR6" bash "$HERE/../pause.sh" --force >/dev/null 2>&1
assert_ok "multi: checkpoint sent to hz-bug-acme_b-6-fix" \
  bash -c "grep -q 'send-keys -t hz-bug-acme_b-6-fix' '$CALLS6'"
assert_ok "multi: confirms via the CARRIED repo (polls gh issue view 6 -R acme/b)" \
  bash -c "grep -qE 'gh issue view 6 -R acme/b( |\$)' '$CALLS6'"
assert_no "multi: never mis-routes to the colliding repo acme/a" \
  bash -c "grep -qE 'gh issue view 6 -R acme/a( |\$)' '$CALLS6'"
assert_no "multi: never killed a lane session" \
  bash -c "grep -q 'kill-session' '$CALLS6'"
unset CALLS
rm -rf "$RUN_DIR6"

# --- #49 bare-repo config: the lane's real claim AGREES with _checkpoint_target's session lookup --
# #44 owner-qualified the session/worktree but left _bug_numbers' token (and so the claim key) on the
# RAW _bug_repos string. On a BARE repo (widget + HARNESS_OWNER=acme) the lane wrote bug-widget-9.claim
# while naming the session hz-bug-acme_widget-9-fix; _checkpoint_target parsed san=acme_widget, looked
# up bug-acme_widget-9.claim (MISSING), and fell back to the lossy bug_repo rescan — routing the
# checkpoint to the wrong repo (here, an empty rescan → acme/ ). With the token owner-qualified at
# construction, the claim the lane writes and the lookup the checkpoint performs share ONE slug, so
# --force confirms via the CARRIED repo acme/widget — no rescan.
RUN_DIR7="$(mktemp -d)"; CALLS7="$RUN_DIR7/calls"; : > "$CALLS7"
# Write the claim via the REAL _bug_numbers/claim_next_bug for a bare repo (the path that regressed).
( export CLAIMS_DIR="$RUN_DIR7/claims" POOL_LOCK="$RUN_DIR7/pool.lock"
  export HARNESS_TOPOLOGY=multi HARNESS_OWNER=acme
  source "$HERE/../lib.sh"
  _bug_repos(){ echo widget; }; _repo_bugs(){ printf '9\tfix\n'; }
  claim_next_bug P1 >/dev/null )
assert_eq "$(basename "$(ls "$RUN_DIR7/claims"/bug-*.claim)")" "bug-acme_widget-9.claim" \
  "lane wrote the owner-qualified claim file for a bare repo (token owner-qualified at construction)"
export CALLS="$CALLS7"
export HARNESS_TOPOLOGY=multi HARNESS_OWNER=acme HARNESS_PAUSE_GRACE=2
# the live session the lane named for that bare-repo bug (hz-bug-<owner-qualified-slug>-9-fix)
tmux(){ echo "tmux $*" >> "$CALLS"
  case "$1" in
    ls) printf 'hz-bug-acme_widget-9-fix\n';;
    send-keys) : ;;
    kill-session) : ;;
  esac; }
gh(){ echo "gh $*" >> "$CALLS"
  case "$1 $2" in
    "issue view") echo '{"labels":[{"name":"agent-paused"}]}';;
  esac; return 0; }
export -f tmux gh
RUN_DIR="$RUN_DIR7" bash "$HERE/../pause.sh" --force >/dev/null 2>&1
assert_ok "bare-repo: confirms via the CARRIED repo (gh issue view 9 -R acme/widget — claim lookup HIT)" \
  bash -c "grep -qE 'gh issue view 9 -R acme/widget( |\$)' '$CALLS7'"
assert_no "bare-repo: did NOT fall back to the lossy bug_repo rescan (no gh issue view 9 -R acme/ )" \
  bash -c "grep -qE 'gh issue view 9 -R acme/( |\$)' '$CALLS7'"
unset CALLS
rm -rf "$RUN_DIR7"

# --- resume.sh clears the flag (alive-worker branch: does NOT exec start) -----
RUN_DIR4="$(mktemp -d)"; touch "$RUN_DIR4/PAUSED"
# a live worker pidfile (use this shell's pid so kill -0 succeeds)
printf '%s\n' "$$" > "$RUN_DIR4/worker-1.pid"
RUN_DIR="$RUN_DIR4" bash "$HERE/../resume.sh" >/dev/null 2>&1; resume_rc=$?
assert_ok "resume removed PAUSED flag" bash -c "[[ ! -f '$RUN_DIR4/PAUSED' ]]"
assert_eq "$resume_rc" "0" "resume exited 0 (alive branch — did not exec start)"
rm -rf "$RUN_DIR4"

finish

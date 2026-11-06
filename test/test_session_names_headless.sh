#!/usr/bin/env bash
# test_session_names_headless.sh — #493 / PRD #475 task 6: the headless twin of test_unit_tmux_safe.sh (#554) and
# test_bug_session_tmux_safe.sh (#557). Those two draw tmux panes to prove the session names a fleet derives from its
# unit (<prefix>-<unit>-i<N>) and its repo slug (<prefix>-bug-<slug>-<n>-<phase>) are safe and that every reader agrees
# on them; this runs the SAME assertions on HARNESS_SESSION_BACKEND=headless, where a lane is a detached runner process
# (scripts/cli/claude_headless.py, the fake claude of test/fixtures/cli/claude/stream-json/) and its identity is a lane
# DIRECTORY named after the session — so it runs on Windows, where there is no tmux. Same behaviour, no tmux:
#   - fleet_unit / unit_safe / slug_safe / sess_impl / sess_bug / _bug_claim_key map every character outside
#     [A-Za-z0-9_-] to `_`, and a unit / slug that is already safe keeps its names byte for byte;
#   - a real headless lane launched under the sanitised name is live, found by the name every reader computes
#     (sess_live, session_live, team_sessions, session_lane_key, bug_session_live, fleet_bug_numbers), gone after sess_kill;
#   - the lane directory name is the session name and is filesystem-safe (no `:`, `.`, `/` or other character Windows
#     refuses in a path), and a tmux-style target (=name, name:0.0) reaches the same directory.
# Needs python3 and bash only; never tmux. Kills only the runners it started.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
make_env
source "$ROOT/scripts/lib.sh" >/dev/null 2>&1
export RUN_DIR HARNESS_SESS_PREFIX=hz HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
FAKE="$HERE/fixtures/cli/claude/stream-json/fake-claude"
export HARNESS_CLAUDE_BIN="python3 $FAKE" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions"
LOG="$RUN_DIR/harness.log"; log(){ printf '%s\n' "$*" >> "$LOG"; }

# Only the processes this test started: each lane's runner (its pid file) and each fake claude (calls.jsonl / pids).
# Never a pattern kill: the host runs other lanes.
our_pids(){ local d; shopt -s nullglob
  for d in "$HARNESS_HOME"/lanes/*/; do cat "$d/pid" 2>/dev/null; echo; done
  for d in "$RUN_DIR"/fake-*/; do
    python3 -c 'import json,sys; [print(json.loads(l)["pid"]) for l in open(sys.argv[1])]' "$d/calls.jsonl" 2>/dev/null
    [[ -f "$d/pids" ]] && tr ' ' '\n' < "$d/pids"
  done; shopt -u nullglob; }
cleanup(){ local p; for p in $(our_pids); do [[ $p =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; done; tmp_cleanup; }
trap cleanup EXIT
# wait_until <seconds> <command…> — true once <command> is.
wait_until(){ local t="$1" i; shift; for (( i = 0; i < t * 10; i++ )); do "$@" && return 0; sleep 0.1; done; return 1; }
# lane <name> — a worktree and a fake-claude dir whose one turn ends normally.
lane(){ local name="$1"
  WD="$RUN_DIR/wd-$name"; mkdir -p "$WD"; echo "the task" > "$WD/.harness-task.md"
  export FAKE_CLAUDE_DIR="$RUN_DIR/fake-$name"; mkdir -p "$FAKE_CLAUDE_DIR"
  printf '%s\n' normal > "$FAKE_CLAUDE_DIR/plan"; }
# fs_safe <name> — nothing in <name> a Windows (or any) path refuses, nor a separator: only [A-Za-z0-9_-].
fs_safe(){ [[ -n $1 && "$1" != *[!A-Za-z0-9_-]* ]]; }
# lane_dir_ok <session> — the lane directory exists and its last path component IS the session name.
lane_dir_ok(){ local d; d="$(headless_lane_dir "$1")"; [[ -d $d && "${d##*/}" == "$1" ]]; }
no_dir(){ [[ ! -e "$(headless_lane_dir "$1")" ]]; }

# ---- #554: fleet_unit — pure, no backend ----
echo "== fleet_unit: an unsafe HARNESS_UNIT is normalised, a safe one is untouched =="
assert_eq "$(sess_backend)" headless "the backend is headless"
unit_of(){ ( HARNESS_UNIT="$1"; fleet_unit ); }
assert_eq "$(unit_of next.js)"          "next_js"          "next.js -> next_js"
assert_eq "$(unit_of owner.github.io)"  "owner_github_io"  "owner.github.io -> owner_github_io"
assert_eq "$(unit_of 'a:b')"            "a_b"              "a colon -> _"
assert_eq "$(unit_of 'a b')"            "a_b"              "a space -> _"
assert_eq "$(unit_of harness)"          "harness"          "harness unchanged"
assert_eq "$(unit_of main)"             "main"             "main unchanged"
assert_eq "$(unit_of my-repo_2)"        "my-repo_2"        "dash, underscore and digit unchanged"
assert_eq "$(unit_of Mixed-Case)"       "Mixed-Case"       "an already-safe unit with capitals unchanged"
assert_eq "$(unit_of '')"               "main"             "empty -> main"
assert_eq "$(unit_of '..')"             "__"               "dots only -> underscores"
assert_eq "$( ( unset HARNESS_UNIT; fleet_unit ) )" "main" "unset -> main"
assert_eq "$(unit_safe 'x.y')"          "x_y"              "unit_safe is the one rule"
HARNESS_UNIT=next.js HARNESS_SESS_PREFIX=hz
assert_eq "$(sess_impl "$(fleet_unit)" 5)" "hz-next_js-i5" "sess_impl on the dotted unit has no dot"

# ---- #557: slug_safe / sess_bug / _bug_claim_key — pure, no backend ----
echo "== slug_safe: unsafe characters -> _, a safe slug untouched =="
assert_eq "$(slug_safe vercel/next.js)"  "vercel_next_js"  "owner/next.js -> vercel_next_js"
assert_eq "$(slug_safe 'a:b c')"         "a_b_c"           "colon and space -> _"
assert_eq "$(slug_safe acme/widget)"     "acme_widget"     "acme/widget -> acme_widget"
assert_eq "$(slug_safe My-Org/repo_2)"   "My-Org_repo_2"   "capitals, dash, underscore, digit unchanged"

echo "== sess_bug / claim key for a dotted repo carry no . or : =="
SB="$(sess_bug vercel/next.js 7 fix)"
assert_eq "$SB" "hz-bug-vercel_next_js-7-fix" "sess_bug vercel/next.js"
assert_no "no dot or colon in sess_bug" bash -c '[[ "$1" == *[.:]* ]]' _ "$SB"
assert_eq "$(sess_bug vercel_next_js 7 fix)" "$SB" "sess_bug is idempotent on an already-sanitised slug"
assert_eq "$(_bug_claim_key 'vercel/next.js#7')" "bug-vercel_next_js-7" "claim key vercel/next.js#7"
assert_eq "$(_bug_claim_key 'a:b/c.d#12')" "bug-a_b_c_d-12" "claim key with : and . in the repo"

echo "== names for repos without dots are unchanged =="
assert_eq "$(sess_bug acme/widget 7 triage)"   "hz-bug-acme_widget-7-triage" "sess_bug acme/widget"
assert_eq "$(sess_bug My-Org/repo_2 3 fix)"    "hz-bug-My-Org_repo_2-3-fix"  "sess_bug with - and _"
assert_eq "$(_bug_claim_key 'acme/widget#7')"  "bug-acme_widget-7"           "claim key acme/widget#7"
assert_eq "$(_bug_claim_key 'My-Org/repo_2#3')" "bug-My-Org_repo_2-3"        "claim key with - and _"
assert_eq "$(_bug_claim_key 7)"                "bug-7"                       "bare number claim key"

# ---- #554 on a real headless lane: the unit's session ----
echo "== a lane session for a dotted repo is found live (headless) =="
HARNESS_REPO=vercel/next.js HARNESS_UNIT=next.js HARNESS_SESS_PREFIX=hz
S="$(sess_impl "$(fleet_unit)" 5)"
assert_eq "$S" "hz-next_js-i5" "the session name every reader computes"
assert_no "no dot or colon in the session name" bash -c '[[ "$1" == *[.:]* ]]' _ "$S"
assert_ok "the session name is filesystem-safe" fs_safe "$S"
assert_no "(before) the lane is not live" session_live "$S"
lane i5
GOAL=ISSUE:5 launch_agent "$S" "$WD" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "launch_agent starts the headless lane under the sanitised name"
assert_ok "session_live reports the lane live" session_live "$S"
assert_ok "sess_live reports it live" sess_live "$S"
assert_ok "team_sessions lists it" bash -c 'source "$1/scripts/lib.sh" >/dev/null 2>&1; HARNESS_UNIT=next.js HARNESS_SESS_PREFIX=hz HARNESS_SESSION_BACKEND=headless HARNESS_HOME="$2"; team_sessions "$(fleet_unit)" | grep -qx hz-next_js-i5' _ "$ROOT" "$HARNESS_HOME"
assert_eq "$(sess_list)" "$S" "sess_list lists exactly that name"
assert_eq "$(session_lane_key "$S")" "impl-5" "session_lane_key reads the lane number back"
assert_ok "the lane directory is named by the session" lane_dir_ok "$S"
assert_ok "…and its name is filesystem-safe (no : . / or other illegal character)" fs_safe "${S##*/}"
assert_eq "$(headless_lane_dir "$S")" "$HARNESS_HOME/lanes/$S" "the lane directory is <home>/lanes/<session>"
assert_eq "$(headless_lane_dir "=$S")" "$(headless_lane_dir "$S")" "a tmux-style =name target reaches the same lane"
assert_eq "$(headless_lane_dir "$S:0.0")" "$(headless_lane_dir "$S")" "…and so does name:window.pane"
assert_eq "$(sess_panes)" "$S:0.0 headless" "sess_panes names the lane"
# the bug this guards: the RAW unit never finds the lane the sanitised one created
assert_no "(control) the raw dotted name is not found" session_live "hz-next.js-i5"
assert_ok "(control) …and has no lane directory" no_dir "hz-next.js-i5"
assert_ok "sess_kill ends the lane" sess_kill "$S"
assert_no "…it is no longer live" session_live "$S"
assert_eq "$(sess_list)" "" "…and is no longer listed"
assert_no "sess_kill on the gone lane is false" sess_kill "$S"

# ---- an already-safe unit: names byte for byte ----
echo "== a safe unit keeps its names byte for byte =="
HARNESS_REPO=acme/widget HARNESS_UNIT=my-repo_2 HARNESS_SESS_PREFIX=hz
S2="$(sess_impl "$(fleet_unit)" 3)"
assert_eq "$S2" "hz-my-repo_2-i3" "a safe unit's session name is unchanged"
lane i3
GOAL=ISSUE:3 launch_agent "$S2" "$WD" >/dev/null 2>&1
assert_ok "its lane is live under that very name" session_live "$S2"
assert_eq "$(headless_lane_dir "$S2")" "$HARNESS_HOME/lanes/hz-my-repo_2-i3" "…and its lane directory carries it byte for byte"
assert_eq "$(session_lane_key "$S2")" "impl-3" "…and session_lane_key reads it"
sess_kill "$S2"; assert_no "killed" session_live "$S2"

# ---- #557 on real headless lanes: bug sessions for a dotted repo ----
echo "== a bug-lane session for a dotted repo is found live (headless) =="
HARNESS_REPO=vercel/next.js HARNESS_UNIT=next.js HARNESS_SESS_PREFIX=hz
assert_no "(before) bug_session_live is false" bug_session_live vercel/next.js 7
BF="$(sess_bug vercel/next.js 7 fix)"; BT="$(sess_bug vercel/next.js 8 triage)"
assert_ok "the fix session name is filesystem-safe" fs_safe "$BF"
assert_ok "…and so is the triage one" fs_safe "$BT"
lane b7
GOAL=BUG:7 launch_agent "$BF" "$WD" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "launch_agent starts the dotted-repo fix lane"
assert_ok "bug_session_live reports the dotted-repo fix lane live" bug_session_live vercel/next.js 7
assert_ok "the fix lane directory is named by the sanitised session" lane_dir_ok "$BF"
assert_eq "$(headless_lane_dir "$BF")" "$HARNESS_HOME/lanes/hz-bug-vercel_next_js-7-fix" "…hz-bug-vercel_next_js-7-fix"
lane b8
GOAL=BUG:8 launch_agent "$BT" "$WD" >/dev/null 2>&1
assert_ok "bug_session_live reports the triage lane live" bug_session_live vercel/next.js 8
assert_ok "the triage lane directory is named by the sanitised session" lane_dir_ok "$BT"
assert_no "a bug with no lane is not live" bug_session_live vercel/next.js 9
assert_no "…nor is the same number in another repo" bug_session_live acme/widget 7
assert_eq "$(fleet_bug_numbers | tr '\n' ' ')" "7 8 " "fleet_bug_numbers sees the dotted repo's bug lanes"
assert_ok "sess_kill ends the fix lane" sess_kill "$BF"
assert_no "bug_session_live reports it gone" bug_session_live vercel/next.js 7
assert_eq "$(fleet_bug_numbers | tr '\n' ' ')" "8 " "fleet_bug_numbers drops the killed lane"
sess_kill "$BT"
assert_no "the triage lane is gone too" bug_session_live vercel/next.js 8
assert_eq "$(fleet_bug_numbers | tr '\n' ' ')" "" "fleet_bug_numbers is empty with no bug lane live"

echo "== a safe slug keeps its bug lane name byte for byte =="
HARNESS_REPO=acme/widget HARNESS_UNIT=widget
BS="$(sess_bug acme/widget 7 triage)"
assert_eq "$BS" "hz-bug-acme_widget-7-triage" "the safe slug's session name is unchanged"
lane b7s
GOAL=BUG:7 launch_agent "$BS" "$WD" >/dev/null 2>&1
assert_ok "bug_session_live finds the safe-slug lane" bug_session_live acme/widget 7
assert_eq "$(headless_lane_dir "$BS")" "$HARNESS_HOME/lanes/hz-bug-acme_widget-7-triage" "…under a lane directory carrying it byte for byte"
sess_kill "$BS"; assert_no "killed" bug_session_live acme/widget 7

finish

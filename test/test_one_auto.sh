#!/usr/bin/env bash
# test_one_auto.sh — #392: HARNESS_ONE_AUTO=1 starts ONE harness-one lane per account by itself while the
# #194 usage hold is on. On a real git fixture, a stubbed gh and a fake usage reading (no live GitHub, no
# agent CLI — the lane's launch is stubbed): default off; the trigger; the host-wide one-lane lock (a
# second fleet's hold starts no second lane); the gate on both sides of HARNESS_ONE_STOP_PCT; a lane that
# checkpoints mid-issue; chaining to the next issue once one closes; the hold clearing mid-chain; the
# per-phase re-check for a lane with no lease; turns between fleets; the pool worker's wiring; status + web.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/helpers.sh"
make_env
export RUN_DIR HARNESS_STATE_DIR_OK=1 HARNESS_REPO=acme/widget HARNESS_OWNER=acme
export GIT_CONFIG_GLOBAL="$RUN_DIR/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$STATE_DIR"; : > "$STATE_DIR/config"

# ── fixture: the project checkout (PROJECT_ROOT = RUN_DIR) with a bare origin ───────────────────
git init -q --bare -b main "$RUN_DIR/origin.git"
git -C "$RUN_DIR" init -q -b main
printf 'state/\nhost/\n*.stub\ngh/\nbin/\n' > "$RUN_DIR/.gitignore"; echo hi > "$RUN_DIR/README"
git -C "$RUN_DIR" add README .gitignore; git -C "$RUN_DIR" commit -qm init
git -C "$RUN_DIR" remote add origin "$RUN_DIR/origin.git"; git -C "$RUN_DIR" push -q origin main

# ── gh stub: per-issue state + labels in files ($GH/<n>.state, $GH/<n>.labels); edits logged ─────
GH="$RUN_DIR/gh"; mkdir -p "$GH" "$RUN_DIR/bin"
cat > "$RUN_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
GH="$(dirname "$0")/../gh"; q=""; prev=""
for a in "$@"; do [[ "$prev" == -q ]] && q="$a"; prev="$a"; done
n="$3"; st="$(cat "$GH/$n.state" 2>/dev/null || echo OPEN)"; lb="$(cat "$GH/$n.labels" 2>/dev/null)"
case "$1 $2" in
  "issue view")
    if [[ "$q" == *join* && "$q" == *state* ]]; then echo "$st $lb"
    elif [[ "$q" == *join* ]]; then echo "$lb"
    elif [[ "$q" == *labels* ]]; then python3 -c 'import json,sys; print(json.dumps([l for l in sys.argv[1].split(",") if l]))' "$lb"
    elif [[ "$q" == .state ]]; then echo "$st"
    elif [[ "$q" == *body* ]]; then echo ""
    else python3 -c 'import json,sys; print(json.dumps({"state": sys.argv[1], "labels": [{"name": l} for l in sys.argv[2].split(",") if l]}, separators=(",", ":")))' "$st" "$lb"; fi;;
  "issue edit")
    echo "edit $*" >> "$GH/log"; prev=""
    for a in "$@"; do
      [[ "$prev" == --add-label ]] && { tr , '\n' < "$GH/$n.labels" | grep -qx "$a" || { sed -i "s/\$/,$a/; s/^,//" "$GH/$n.labels"; }; }
      [[ "$prev" == --remove-label ]] && { tr , '\n' < "$GH/$n.labels" | grep -vx "$a" | paste -sd, - > "$GH/l.tmp"; mv "$GH/l.tmp" "$GH/$n.labels"; }
      prev="$a"
    done;;
  "issue list") cat "$GH/bodies.json";;
  "repo view") echo main;;
  *) exit 1;;
esac
EOF
chmod +x "$RUN_DIR/bin/gh"; export PATH="$RUN_DIR/bin:$PATH"
issue(){ echo "${3:-OPEN}" > "$GH/$1.state"; echo "${2:-ready-for-agent}" > "$GH/$1.labels"; }
has_label(){ tr , '\n' < "$GH/$1.labels" | grep -qx "$2"; }
issue 7; issue 8
printf '[{"number": 1, "body": "%s"}, {"number": 7, "body": "%s"}, {"number": 8, "body": "%s"}]\n' \
  "$(printf 'x%.0s' {1..80})" "$(printf 'y%.0s' {1..80})" "$(printf 'z%.0s' {1..80})" > "$GH/bodies.json"

# ── issuelib stub: `next` is the first of $RUN_DIR/next's numbers not in --exclude (dispatch order
# is issuelib's own test) ─
cat > "$RUN_DIR/issuelib.stub" <<'EOF'
import os, sys
if sys.argv[1] == "next":
    p = os.path.join(os.environ["RUN_DIR"], "next")
    ns = open(p).read().split() if os.path.exists(p) else []
    skip = set(sys.argv[sys.argv.index("--exclude")+1].split(",")) if "--exclude" in sys.argv else set()
    ns = [n for n in ns if n not in skip]
    if ns: print(ns[0])
EOF
ISSUELIB="$RUN_DIR/issuelib.stub"
next_is(){ echo "$1" > "$RUN_DIR/next"; }

# ── usage + forecast fixture (as test_one_run.sh): one past lane, p80 = 2 % of the window ───────
STUB="$RUN_DIR/usage.stub"; future=$(( $(date +%s) + 3600 ))
export HARNESS_USAGE_CMD="cat '$STUB'" HARNESS_ONE_USD_PER_PCT=5 HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"
stub_usage(){ printf 'main\tseven_day\t%s\t%s\n' "$1" "$future" > "$STUB"; mkdir -p "$(_usage_dir)"; touch "$(_usage_dir)/main.json"; }
EV="$HARNESS_EVENTS_FILE"
cat > "$EV" <<'EOF'
{"event": "launch", "ts": "2026-10-01T00:00:00Z", "prefix": "hz", "repo": "acme/widget", "unit": "main", "kind": "impl", "issue": 1, "session": "s1"}
{"event": "session_end", "ts": "2026-10-01T01:00:00Z", "prefix": "hz", "repo": "acme/widget", "unit": "main", "kind": "impl", "issue": 1, "session": "s1", "usage": {"claude-opus-5-5": {"output": 400000}}}
EOF
hold(){ mkdir -p "$(_usage_hold_dir)"; printf 'main\tseven_day\t%s\t%s\n' "$1" "$future" > "$(_usage_hold_dir)/main.hold"; }
unhold(){ rm -f "$(_usage_hold_dir)"/*.hold; }

# ── the lane's launch is stubbed: a "live session" is a file; cli_kill ends it ──────────────────
LIVE="$RUN_DIR/live"; mkdir -p "$LIVE"; LAUNCHED="$RUN_DIR/launched"; : > "$LAUNCHED"
launch_claude(){ touch "$LIVE/$1"; echo "$2" > "$RUN_DIR/$1.wd"; echo "$1" >> "$LAUNCHED"; }
session_live(){ [[ -f "$LIVE/$1" ]]; }
cli_kill(){ rm -f "$LIVE/$1"; }
launches(){ grep -c . "$LAUNCHED"; }
UNIT=main REPO=acme/widget SLUG=acme/widget PROJECT=main DESC=widget CHECKOUT="$RUN_DIR"
OA="$HARNESS_HOME/one-auto"; LANE="$OA/main.lane"; STOPPED="$OA/main.stopped"
# what reap_team does once a lane is gone: its worktree and local branch removed
reap_wts(){ local wd; for wd in "$WORKTREES_DIR"/main-i*; do [[ -d "$wd" ]] && remove_worktree "$RUN_DIR" "$wd" "issue/${wd##*-i}" >/dev/null 2>&1; done; return 0; }
reset_auto(){ rm -rf "$OA"; reap_wts; : > "$LAUNCHED"; rm -f "$LIVE"/*; _OA_SAID=""; }

echo "-- default off: a hold leaves the fleet idle"
hold 91; stub_usage 91; next_is 7
HARNESS_ONE_AUTO=0 one_auto_tick
assert_eq "$(launches)" "0" "HARNESS_ONE_AUTO=0: the hold starts no lane"
assert_no "and claims nothing" has_label 7 agent-working
assert_no "and leaves no auto-lane record on the host" test -e "$OA"
assert_eq "$HARNESS_ONE_AUTO" "0" "the setting defaults to 0"

echo "-- trigger: =1 and a hold starts exactly one lane, gated APPROVE"
export HARNESS_ONE_AUTO=1
one_auto_tick >/dev/null 2>&1
assert_eq "$(launches)" "1" "the hold starts one lane"
assert_eq "$(cat "$LAUNCHED")" "hz-main-i7" "an ordinary impl session on the next claimable issue"
assert_ok "the issue is claimed agent-working" has_label 7 agent-working
assert_ok "set up the way dispatch does it (impl.md)" grep -q '^You are an implementation engineer on main' "$WORKTREES_DIR/main-i7/.harness-task.md"
assert_ok "its task ends with the per-phase re-check" grep -q 'one phase 7 <phase> --unit main' "$WORKTREES_DIR/main-i7/.harness-task.md"
assert_ok "the lane record is on the host, per account" test -f "$LANE"
assert_ok "it carries the forecast arithmetic" grep -q 'main seven_day: now 91% + p80 2% + reserve 2% = 95% vs stop 98%' "$LANE"
assert_ok "the start is a stats event" grep -q '"event": *"one_auto_start"' "$EV"
one_auto_tick >/dev/null 2>&1
assert_eq "$(launches)" "1" "the next poll starts no second lane while the first runs"

echo "-- one lane per account, host-wide: a second fleet's hold starts no second lane"
issue 8; next_is 8
( STATE_DIR="$RUN_DIR/fleet-b"; UNIT=other; one_auto_tick ) >/dev/null 2>&1
assert_eq "$(launches)" "1" "a second fleet held on the same account starts nothing"
assert_no "and claims nothing" has_label 8 agent-working
rm -f "$OA/main.want/$(_usage_key "$RUN_DIR/fleet-b:other")"   # fleet B's hold lifts: it wants the lane no more

echo "-- status + web show the lane"
out="$(one_auto_report)"
assert_ok "harness status names the lane, its issue and forecast" grep -q 'one-auto: main lane on acme/widget#7 (hz-main-i7.*p80' <<<"$out"
web="$(python3 -c 'import sys,json; sys.path.insert(0, sys.argv[1]); import web_data, time; print(json.dumps(web_data.one_auto(time.time())))' "$HERE/../scripts")"
assert_ok "the web data carries the running lane" grep -q '"state": "running".*"issue": 7' <<<"$web"
html="$(python3 -c 'import sys,json,time; sys.path.insert(0, sys.argv[1]); import web_render; print(web_render.one_auto_callout(json.loads(sys.argv[2])[0], time.time()))' "$HERE/../scripts" "$web")"
assert_ok "the dashboard renders it" grep -q 'data-one-auto="running".*acme/widget#7' <<<"$html"

echo "-- chaining: the issue closes → the lane is freed → the next poll starts the next issue"
issue 7 "" CLOSED; rm -f "$LIVE/hz-main-i7"   # reap_done_sessions ended the lane on its goal
one_auto_tend >/dev/null 2>&1
assert_no "the lane record is freed" test -f "$LANE"
assert_no "a closed issue does not stop the chain" test -f "$STOPPED"
assert_ok "the finish is a stats event" grep -q '"event": *"one_auto_done"' "$EV"
one_auto_tick >/dev/null 2>&1
assert_eq "$(tail -1 "$LAUNCHED")" "hz-main-i8" "the next claimable issue gets its own lane"

echo "-- reaching the stop % mid-issue: the lane checkpoints, the engine ends it, the chain stops"
# The lane follows `harness one phase`'s CHECKPOINT: the branch pushed, the handoff, agent-paused.
issue 8 "ready-for-agent,agent-paused"
one_auto_tend >/dev/null 2>&1
assert_no "a lane whose issue went agent-paused is ended" session_live hz-main-i8
assert_no "its record is freed" test -f "$LANE"
assert_ok "an issue still open after its run stops the chain" grep -q 'open_after_run' "$STOPPED"
assert_ok "it stays agent-paused for the pool to resume after the reset" has_label 8 agent-paused
next_is 8; n="$(launches)"
one_auto_tick >/dev/null 2>&1
assert_eq "$(launches)" "$n" "a stopped chain starts nothing until the window resets"
out="$(one_auto_report)"
assert_ok "harness status says why it stopped" grep -q 'one-auto: main lane STOPPED (open_after_run)' <<<"$out"

echo "-- the gate: a forecast over the stop % starts no issue and logs the forecast"
reset_auto; issue 7; next_is 7; hold 95.6; stub_usage 95.6
out="$(one_auto_tick 2>&1)"
assert_eq "$(launches)" "0" "95.6% + p80 2% + reserve 2% = 99.6% > 98%: no lane"
assert_no "nothing claimed" has_label 7 agent-working
assert_ok "the stop names the forecast" grep -q 'deny.*99.6% vs stop 98%' "$STOPPED"
assert_ok "and is logged" grep -q 'one-auto: main lane stops — deny: acme/widget#7 does not fit.*99.6%' <<<"$out"
assert_ok "and is a stats event with the forecast" grep -q '"event": *"one_auto_stop".*"reason": *"deny".*99.6%' "$EV"
stub_usage 94
one_auto_tick >/dev/null 2>&1
assert_eq "$(launches)" "0" "a DENY stops the chain until the held window resets, though usage reads lower"
reset_auto; hold 94; stub_usage 94
one_auto_tick >/dev/null 2>&1
assert_eq "$(launches)" "1" "94% + 2% + 2% = 98%: exactly at the stop starts the lane"

echo "-- the hold clears mid-chain: no new issue starts; the running lane finishes"
issue 7 "" CLOSED; rm -f "$LIVE/hz-main-i7"; one_auto_tend >/dev/null 2>&1
unhold; next_is 8; issue 8
one_auto_tick >/dev/null 2>&1
assert_eq "$(launches)" "1" "with no hold, nothing starts the next issue"
assert_no "and nothing is claimed" has_label 8 agent-working
reset_auto; hold 91; stub_usage 91; next_is 8
one_auto_tick >/dev/null 2>&1; unhold
assert_ok "a lane started under the hold…" session_live hz-main-i8
one_auto_tend >/dev/null 2>&1
assert_ok "…runs on once the hold clears (a normal session of the fleet)" session_live hz-main-i8
assert_ok "its record is kept fresh by the fleet that owns it" test -f "$LANE"
assert_ok "and its issue stays agent-working, so the pool never races it" has_label 8 agent-working

echo "-- the per-phase re-check works for a lane, which has no lease"
hold 91; stub_usage 95.6
out="$( source "$HERE/../scripts/one.sh"; session_live(){ [[ "$1" == hz-main-i8 ]]; }
        one_phase 8 explore --unit main --events "$EV" --bodies "$GH/bodies.json" 2>&1 )"; rc=$?
assert_eq "$rc" "1" "phase on a live auto lane's issue CHECKPOINTs when the work left does not fit"
assert_ok "with the pause --force checkpoint message" grep -q '^HARNESS CHECKPOINT' <<<"$out"
assert_ok "then exit — no release: the engine ends the lane" grep -q '^Once checkpointed, exit: this is a HARNESS_ONE_AUTO lane' <<<"$out"
assert_no "and never tells the lane to drop its own worktree" grep -q 'release 8' <<<"$out"
out="$( source "$HERE/../scripts/one.sh"; session_live(){ false; }; one_phase 8 explore --unit main 2>&1 )"; rc=$?
assert_eq "$rc" "2" "no lease and no lane: still a usage error"

echo "-- #446: an issue a live lane still owns is skipped — the next claimable one starts"
# A checkpointed lane keeps its worktree (agent-paused, agent-working dropped): busy_issues_for owns #7,
# so the tick starts #8 instead of failing on #7's worktree every poll.
reset_auto; hold 91; stub_usage 91; issue 7 "ready-for-agent,agent-paused"; issue 8; next_is "7 8"
mkdir -p "$WORKTREES_DIR/main-i7"
out="$(one_auto_tick 2>&1)"
assert_eq "$(cat "$LAUNCHED")" "hz-main-i8" "the tick skips #7 (its worktree is present) and starts #8"
assert_no "it never tries the owned #7" grep -q 'could not start' <<<"$out"
assert_no "nor claims it" has_label 7 agent-working
reset_auto; rm -rf "$WORKTREES_DIR/main-i7"; next_is "7"; mkdir -p "$WORKTREES_DIR/main-i7"
out="$(one_auto_tick 2>&1)"
assert_eq "$(launches)" "0" "the only claimable issue is owned: no lane starts"
assert_ok "and it says none is claimable" grep -q 'no claimable issue on acme/widget' <<<"$out"
rm -rf "$WORKTREES_DIR/main-i7"

echo "-- #561: another worker's chores (reap_team) between the worktree add and the launch must not reap the lane"
# prepare_impl has made the worktree and the session is not up yet: the window the lane's spawn is exposed in.
reset_auto; hold 91; stub_usage 91; issue 9; next_is 9; rm -f "$CLAIMS_DIR"/impl-*.claim
SPAWN_LOG="$RUN_DIR/spawn.log"; : > "$SPAWN_LOG"
_real_launch="$(declare -f launch_claude)"
stats_sweep_ended(){ :; }
launch_claude(){
  echo "claim=$(is_claimed impl-9 && echo held || echo none)" >> "$SPAWN_LOG"
  echo "lane=$(pool_lane_keys | tr '\n' ' ')" >> "$SPAWN_LOG"
  reap_team 2>/dev/null
  echo "worktree=$([[ -d "$WORKTREES_DIR/main-i9" ]] && echo alive || echo reaped)" >> "$SPAWN_LOG"
  touch "$LIVE/$1"; echo "$2" > "$RUN_DIR/$1.wd"; echo "$1" >> "$LAUNCHED"; }
one_auto_tick >/dev/null 2>&1
assert_ok "the lane holds an impl-9 claim while it spawns" grep -q '^claim=held' "$SPAWN_LOG"
assert_ok "the pool cap counts the spawning lane" grep -q '^lane=.*impl-9' "$SPAWN_LOG"
assert_ok "reap_team in that window leaves the worktree alone" grep -q '^worktree=alive' "$SPAWN_LOG"
assert_eq "$(launches)" "1" "and the lane still launches"
assert_ok "the issue stays claimed agent-working" has_label 9 agent-working
assert_no "the claim is released once the session is up (adoption takes over)" test -e "$CLAIMS_DIR/impl-9.claim"
echo "-- #561: a claim a pool worker already holds means the issue is not the auto lane's to start"
reset_auto; issue 9; next_is 9; : > "$SPAWN_LOG"
lane_claim_write impl-9 W1 IMPL:9 hz-main-i9
one_auto_tick >/dev/null 2>&1
assert_eq "$(launches)" "0" "no lane starts on a claimed issue"
assert_no "and no auto-lane record is left" test -e "$LANE"
assert_ok "the pool worker's claim is untouched" is_claimed impl-9
rm -f "$CLAIMS_DIR/impl-9.claim"
echo "-- #561: a spawn that fails drops the claim, so the reapers clean up"
reset_auto; issue 9; next_is 9
launch_claude(){ return 1; }
one_auto_tick >/dev/null 2>&1
assert_no "a failed launch leaves no claim behind" test -e "$CLAIMS_DIR/impl-9.claim"
assert_no "and no auto-lane record" test -e "$LANE"
eval "$_real_launch"
rm -rf "$WORKTREES_DIR/main-i9"

echo "-- turns: fleets on one account take turns at a free lane"
reset_auto; mkdir -p "$OA/main.want"
me="$(_oa_me)"; other="$(_usage_key "$RUN_DIR/fleet-b:other")"
touch "$OA/main.want/$me" "$OA/main.want/$other"
echo "$me" > "$OA/main.last"
assert_no "the fleet served last waits while another fleet wants the lane" _oa_my_turn main
echo "$other" > "$OA/main.last"
assert_ok "and takes it once the other was served" _oa_my_turn main
touch -d '-2 hours' "$OA/main.want/$other"; echo "$me" > "$OA/main.last"
assert_ok "a want nobody refreshed does not hold the turn" _oa_my_turn main
touch -d '-2 hours' "$OA/main.want/$me"; printf 'x\tmain\tacme/widget\t9\ts\tmain\t0\t\n' > "$LANE"; touch -d '-2 hours' "$LANE"
assert_no "a lane record nobody refreshed (a dead fleet's) is free" one_auto_lane_live main

echo "-- the pool worker's chores: the auto lane is ticked only while the hold is on"
reset_auto
TICKS=0
one_auto_tick(){ TICKS=$((TICKS+1)); }
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1; source "$HERE/../scripts/drive.sh"; source "$HERE/../scripts/pool-worker.sh"
reap_done_sessions(){ :; }; reap_team(){ :; }; reap_orch(){ :; }; watchdog_team(){ :; }; reap_finished_inject(){ :; }
one_auto_tend(){ :; }; reap_ownerless_pool_bugs(){ :; }; release_tick(){ :; }; retry_pending_unlocks(){ :; }; sweep_orphan_locks(){ :; }
sweep_stale_lane_claims(){ :; }; adopt_lanes(){ :; }; chores_slotless(){ :; }
write_targets <<'EOF'
main	acme/widget	-	root
EOF
POLL=0
hold 91; worker_chores W1 >/dev/null 2>&1; worker_chores W1 >/dev/null 2>&1
assert_eq "$TICKS" "2" "held: every chores pass ticks the auto lane"
unhold; TICKS=0; worker_chores W1 >/dev/null 2>&1
assert_eq "$TICKS" "0" "not held: the auto lane is never ticked"

finish

#!/usr/bin/env bash
# test_inject.sh — live-work-injection: session naming/non-collision + inject.sh launcher.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"; make_env
HARNESS_SESS_PREFIX=hz

# ── §1 sess_inject naming + non-collision with team_sessions ──────────────────
assert_eq "$(sess_inject main)" "hz-inject-main" "sess_inject names hz-inject-<unit>"

# team_sessions greps tmux output; stub tmux to emit both an injector and an impl session.
tmux(){ printf '%s\n' "hz-inject-main" "hz-main-i7"; }
assert_eq "$(team_sessions main)" "hz-main-i7" "team_sessions excludes hz-inject-main (no CAP collision)"
assert_no "injector session never matches team_sessions" \
  bash -c "printf '%s\n' hz-inject-main | grep -qE '^hz-main(\$|-i)'"
unset -f tmux

# ── §2 inject.sh launcher: resolve unit, REVIEW-guard, render, launch ─────────
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_OWNER="acme"
HARNESS_SPEC="docs/spec.md"; PROMPTS_DIR="$HERE/../prompts"
TMPCO="$(mktemp -d)"; unit_checkout(){ echo "$TMPCO"; }   # don't clobber the real repo
LAUNCH="$RUN_DIR/launch.log"; : > "$LAUNCH"
launch_claude(){ echo "$1 :: $2" >> "$LAUNCH"; }           # record "<sess> :: <wd>"

# happy path: nothing live → launches hz-inject-main and renders the task file
( session_live(){ return 1; }
  source "$HERE/../scripts/inject.sh" issue "add a rate limiter" )
assert_eq "$?" "0" "inject.sh issue exits 0 when nothing is live"
assert_ok "launched hz-inject-main session" bash -c "grep -q 'hz-inject-main :: $TMPCO' '$LAUNCH'"
assert_ok "rendered the injector task file" bash -c "grep -q 'INJECT DONE' '$TMPCO/.harness-task.md'"
assert_ok "task file carries the brief"     bash -c "grep -q 'add a rate limiter' '$TMPCO/.harness-task.md'"

# REVIEW guard: a live orch session whose goal is REVIEW must abort (exit 1). The orch session name
# is PRD-qualified now (multi-PRD) — inject.sh and the fixture both derive it from sess_orch, so the
# unit-level name is hz-main-p0. The guard scans every live orch session, so tmux is stubbed to list
# it (team_sessions is what enumerates them).
echo REVIEW > "$RUN_DIR/$(sess_orch main).goal"
( tmux(){ printf '%s\n' "$(sess_orch main)"; }
  session_live(){ [[ "$1" == "$(sess_orch main)" ]]; }
  source "$HERE/../scripts/inject.sh" issue "add a rate limiter" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh aborts while a REVIEW session is live for the unit"

# … and on a PRD-qualified orch session that is NOT p0: after the multi-PRD rename only PLAN/PRD use
# p0, so a guard that read the single well-known p0 name would silently stop firing while a REVIEW
# of PRD #41 (session hz-main-p41, goal `REVIEW:41`) closes that PRD out from under the injection.
rm -f "$RUN_DIR/$(sess_orch main).goal"
echo "REVIEW:41" > "$RUN_DIR/hz-main-p41.goal"
( tmux(){ printf '%s\n' hz-main-p41; }
  session_live(){ [[ "$1" == hz-main-p41 ]]; }
  source "$HERE/../scripts/inject.sh" issue "add a rate limiter" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh aborts while a REVIEW is live on a non-p0 orch session"
rm -f "$RUN_DIR/hz-main-p41.goal"

# bad altitude is rejected
( source "$HERE/../scripts/inject.sh" bogus "x" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh rejects an unknown altitude"

# empty brief is rejected
( session_live(){ return 1; }
  source "$HERE/../scripts/inject.sh" issue "" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh rejects an empty brief"

# ── §3 explicit `harness plan` bypasses the plan-complete marker gate ─────────
# A finished plan leaves a committed marker; the auto-PLAN dispatch gate (issuelib) suppresses
# replanning while its spec hash matches. Explicit `harness plan` routes through inject.sh, NOT that
# gate, so it must still launch even with the marker present in the checkout.
rm -f "$RUN_DIR/$(sess_orch main).goal"             # clear the REVIEW goal left by the guard test
mkdir -p "$TMPCO/docs/harness"
printf '{"spec":"docs/spec.md","spec_hash":"deadbeef"}\n' > "$TMPCO/docs/harness/plan-complete.json"
: > "$LAUNCH"
( session_live(){ return 1; }
  source "$HERE/../scripts/inject.sh" plan "rework the topology" )
assert_eq "$?" "0" "inject.sh plan exits 0 despite a plan-complete marker (bypasses the gate)"
assert_ok "harness plan launched the injector regardless of the marker" \
  bash -c "grep -q 'hz-inject-main :: $TMPCO' '$LAUNCH'"

# ── §4 pool_live: resident iff a worker pid OR the priority lane is alive (#22) ──
# A cleanly-retired pool (workers exit 0 on all_complete) leaves only dead-pid files; with no
# live lane either, nothing claims injected work until `harness start --recover`.
rm -f "$RUN_DIR"/worker-*.pid "$RUN_DIR"/priority.pid
assert_no "pool_live false when no worker/lane pids exist (truly stopped)" pool_live
printf '%s\n' "$$" > "$RUN_DIR/worker-1.pid"          # this shell -> live worker
assert_ok "pool_live true when a worker pid is alive" pool_live
printf '%s\n' "999999" > "$RUN_DIR/worker-1.pid"     # dead pid -> retired worker
assert_no "pool_live false when the only worker pid is dead" pool_live
printf '%s\n' "$$" > "$RUN_DIR/priority.pid"          # but the lane is alive -> resident
assert_ok "pool_live true when only the priority lane is alive" pool_live
rm -f "$RUN_DIR"/worker-*.pid "$RUN_DIR"/priority.pid

# ── §5 inject success message is honest about a retired pool (resolves #22) ──────
# Reuses the §2/§3 stubs (unit_checkout, launch_claude, render). The final log line goes to
# stdout, so capture the sourced run's stdout to a file and grep it.
MSG="$RUN_DIR/inject.msg"
printf '%s\n' "$$" > "$RUN_DIR/worker-1.pid"          # resident pool
( session_live(){ return 1; }; source "$HERE/../scripts/inject.sh" issue "x" ) > "$MSG" 2>&1
assert_ok "resident pool -> 'no restart' message"        bash -c "grep -q 'no restart' '$MSG'"
assert_no "resident pool -> no restart guidance"         bash -c "grep -q 'harness start' '$MSG'"

rm -f "$RUN_DIR"/worker-*.pid "$RUN_DIR"/priority.pid  # truly stopped
( session_live(){ return 1; }; source "$HERE/../scripts/inject.sh" issue "x" ) > "$MSG" 2>&1
assert_ok "retired pool -> 'harness start' restart guidance" bash -c "grep -q 'harness start' '$MSG'"
assert_no "retired pool -> NOT the misleading 'no restart'"  bash -c "grep -q 'no restart' '$MSG'"
rm -f "$RUN_DIR"/worker-*.pid "$RUN_DIR"/priority.pid

# ── §6 gc_orphan_goals: GC leaked .goal files (Ralph self-exit / inject has no reaper) ───────
# A goal file is written for EVERY launched session (launch_claude) but is only removed when a
# reaper KILLS a still-live session (reap_done_sessions / finalize_unit / drive_bug). Ralph sessions
# self-exit on their completion promise BEFORE any reaper kills them, and inject sessions have no
# reaper at all — so their goal files leak (a confirmed real orphan: an old hz-inject-main.goal with
# no session). gc_orphan_goals removes a goal file iff its session is no longer live, and leaves a
# live session's goal (an in-flight claim a reaper still owns) untouched.
make_env
HARNESS_SESS_PREFIX=hz
echo IMPL    > "$RUN_DIR/hz-main-i7.goal"        # dead session -> leaked goal, must be GC'd
echo INJECT  > "$RUN_DIR/hz-inject-main.goal"    # dead inject session (no reaper) -> must be GC'd
echo ISSUE:9 > "$RUN_DIR/hz-main-i9.goal"        # live session -> in-flight, must be kept
session_live(){ [[ "$1" == "hz-main-i9" ]]; }
gc_orphan_goals
assert_no "gc removed the dead impl session's leaked goal"    test -f "$RUN_DIR/hz-main-i7.goal"
assert_no "gc removed the dead inject session's leaked goal"  test -f "$RUN_DIR/hz-inject-main.goal"
assert_ok "gc kept the live session's goal (in-flight claim)" test -f "$RUN_DIR/hz-main-i9.goal"
unset -f session_live

# ── §7 inject.sh refuses to launch while the fleet is paused (#90) ────────────
# Every other worker path (drive.sh, pool-worker.sh, priority-worker.sh) gates on is_paused;
# inject.sh did not, so `harness plan|prd|issue` would mutate GitHub/git (create issues, reopen the
# PRD, clear the reviewed label, commit PLAN.md) while the fleet is supposed to be frozen. inject.sh
# must REFUSE and exit non-zero when PAUSE_FLAG exists, unless --force is passed.
make_env
HARNESS_SESS_PREFIX=hz
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_OWNER="acme"
HARNESS_SPEC="docs/spec.md"; PROMPTS_DIR="$HERE/../prompts"
TMPCO="$(mktemp -d)"; unit_checkout(){ echo "$TMPCO"; }
LAUNCH="$RUN_DIR/launch.log"; : > "$LAUNCH"
launch_claude(){ echo "$1 :: $2" >> "$LAUNCH"; }

# paused → refuse: no launch, exit non-zero
touch "$PAUSE_FLAG"
: > "$LAUNCH"
( session_live(){ return 1; }
  source "$HERE/../scripts/inject.sh" issue "add a rate limiter" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh refuses (exit 1) while the fleet is paused"
assert_no "inject.sh did NOT launch the injector while paused" \
  bash -c "grep -q 'hz-inject-main' '$LAUNCH'"

# paused + --force → proceeds anyway (override)
: > "$LAUNCH"
( session_live(){ return 1; }
  source "$HERE/../scripts/inject.sh" issue --force "add a rate limiter" )
assert_eq "$?" "0" "inject.sh --force overrides the pause and launches"
assert_ok "inject.sh --force launched the injector despite the pause" \
  bash -c "grep -q 'hz-inject-main :: $TMPCO' '$LAUNCH'"
assert_no "--force is stripped from the rendered brief" \
  bash -c "grep -q -- '--force' '$TMPCO/.harness-task.md'"

# not paused → unchanged (launches normally)
rm -f "$PAUSE_FLAG"
: > "$LAUNCH"
( session_live(){ return 1; }
  source "$HERE/../scripts/inject.sh" issue "add a rate limiter" )
assert_eq "$?" "0" "inject.sh proceeds normally when not paused"
assert_ok "inject.sh launched the injector when not paused" \
  bash -c "grep -q 'hz-inject-main :: $TMPCO' '$LAUNCH'"

# ── §8 review_session_live: scan EVERY live orch session, not just p0 (#149) ──────────
# Goals are PRD-qualified now (`REVIEW:41`) and several orch sessions can be live at once (one per
# PRD), so the predicate enumerates them via team_sessions instead of reading one well-known name.
make_env
HARNESS_SESS_PREFIX=hz
echo "REVIEW:41" > "$RUN_DIR/hz-main-p41.goal"
tmux(){ printf '%s\n' hz-main-p41; }
session_live(){ [[ "$1" == hz-main-p41 ]]; }
assert_ok "review_session_live detects a live REVIEW on a non-p0 session" review_session_live main

echo "DECOMPOSE:41" > "$RUN_DIR/hz-main-p41.goal"
assert_no "review_session_live ignores a live DECOMPOSE" review_session_live main

# an unqualified legacy goal (`REVIEW`, pre-multi-PRD) still counts
echo "REVIEW" > "$RUN_DIR/hz-main-p41.goal"
assert_ok "review_session_live matches an unqualified legacy REVIEW goal" review_session_live main

# one REVIEW among several live orch sessions is enough to fire
tmux(){ printf '%s\n' hz-main-p0 hz-main-p41 hz-main-i7; }
echo "DECOMPOSE:41" > "$RUN_DIR/hz-main-p41.goal"
echo "PRD"          > "$RUN_DIR/hz-main-p0.goal"
assert_no "review_session_live false when no live session is a REVIEW" review_session_live main
echo "REVIEW:41" > "$RUN_DIR/hz-main-p41.goal"
assert_ok "review_session_live true when ANY live orch session is a REVIEW" review_session_live main

# a REVIEW goal left behind by a session that is NOT live must not fire
tmux(){ printf '%s\n' hz-main-p0; }
assert_no "review_session_live ignores a stale goal whose session is gone" review_session_live main
unset -f tmux session_live

# ── §9 attach.sh selects among several live orch sessions (#149) ──────────────────────
# attach.sh runs as its own process, so stub tmux as a fake binary on PATH.
make_env
FAKEBIN="$RUN_DIR/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ls)          printf '%s\n' $FAKE_SESSIONS ;;
  has-session) [[ " $FAKE_SESSIONS " == *" $3 "* ]] ;;
  attach)      echo "ATTACH:$3" >> "$FAKE_ATTACH_LOG" ;;
esac
EOF
chmod +x "$FAKEBIN/tmux"
export FAKE_ATTACH_LOG="$RUN_DIR/attach.log"; : > "$FAKE_ATTACH_LOG"
export HARNESS_SESS_PREFIX=hz

# exactly one live orch session → attach straight to it, even though it is not p0
export FAKE_SESSIONS="hz-main-p41 hz-main-i7"
out="$(PATH="$FAKEBIN:$PATH" bash "$HERE/../scripts/attach.sh" main 2>&1)"; rc=$?
assert_eq "$rc" "0" "attach.sh exits 0 with exactly one live orch session"
assert_ok "attach.sh attached to the single live orch session (hz-main-p41)" \
  bash -c "grep -q 'ATTACH:hz-main-p41' '$FAKE_ATTACH_LOG'"

# several live orch sessions → refuse, and list them so the operator can name one
: > "$FAKE_ATTACH_LOG"
export FAKE_SESSIONS="hz-main-p0 hz-main-p41 hz-main-i7"
out="$(PATH="$FAKEBIN:$PATH" bash "$HERE/../scripts/attach.sh" main 2>&1)"; rc=$?
assert_eq "$rc" "1" "attach.sh refuses when several orch sessions are live"
assert_ok "attach.sh lists hz-main-p0"  bash -c "printf '%s' \"\$1\" | grep -q 'hz-main-p0'"  _ "$out"
assert_ok "attach.sh lists hz-main-p41" bash -c "printf '%s' \"\$1\" | grep -q 'hz-main-p41'" _ "$out"
assert_no "attach.sh did not attach to any of them" \
  bash -c "grep -q ATTACH '$FAKE_ATTACH_LOG'"

# … and naming one of them outright attaches to it (the escape hatch the error points at)
: > "$FAKE_ATTACH_LOG"
out="$(PATH="$FAKEBIN:$PATH" bash "$HERE/../scripts/attach.sh" hz-main-p41 2>&1)"; rc=$?
assert_eq "$rc" "0" "attach.sh accepts a live session name outright"
assert_ok "attach.sh attached to the named session hz-main-p41" \
  bash -c "grep -q 'ATTACH:hz-main-p41' '$FAKE_ATTACH_LOG'"

# an explicit issue argument is unchanged — attach straight to the impl session
: > "$FAKE_ATTACH_LOG"
out="$(PATH="$FAKEBIN:$PATH" bash "$HERE/../scripts/attach.sh" main 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "attach.sh <unit> <issue> still attaches to the impl session"
assert_ok "attach.sh attached to hz-main-i7" \
  bash -c "grep -q 'ATTACH:hz-main-i7' '$FAKE_ATTACH_LOG'"

# no live orch session at all → the old error path (no session '<sess_orch>')
: > "$FAKE_ATTACH_LOG"
export FAKE_SESSIONS="hz-main-i7"
out="$(PATH="$FAKEBIN:$PATH" bash "$HERE/../scripts/attach.sh" main 2>&1)"; rc=$?
assert_eq "$rc" "1" "attach.sh exits 1 when no orch session is live"
assert_no "attach.sh did not attach with no orch session live" \
  bash -c "grep -q ATTACH '$FAKE_ATTACH_LOG'"
unset FAKE_SESSIONS FAKE_ATTACH_LOG

finish

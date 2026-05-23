#!/usr/bin/env bash
# test_inject.sh — live-work-injection: session naming/non-collision + inject.sh launcher.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/helpers.sh"; make_env
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
  source "$HERE/../inject.sh" issue "add a rate limiter" )
assert_eq "$?" "0" "inject.sh issue exits 0 when nothing is live"
assert_ok "launched hz-inject-main session" bash -c "grep -q 'hz-inject-main :: $TMPCO' '$LAUNCH'"
assert_ok "rendered the injector task file" bash -c "grep -q 'INJECT DONE' '$TMPCO/.harness-task.md'"
assert_ok "task file carries the brief"     bash -c "grep -q 'add a rate limiter' '$TMPCO/.harness-task.md'"

# REVIEW guard: a live hz-main orch session whose goal is REVIEW must abort (exit 1)
echo REVIEW > "$RUN_DIR/hz-main.goal"
( session_live(){ [[ "$1" == hz-main ]]; }
  source "$HERE/../inject.sh" issue "add a rate limiter" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh aborts while a REVIEW session is live for the unit"

# bad altitude is rejected
( source "$HERE/../inject.sh" bogus "x" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh rejects an unknown altitude"

# empty brief is rejected
( session_live(){ return 1; }
  source "$HERE/../inject.sh" issue "" ) 2>/dev/null
assert_eq "$?" "1" "inject.sh rejects an empty brief"

finish

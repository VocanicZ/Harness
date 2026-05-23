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

finish

#!/usr/bin/env bash
# test_bug_session_tmux_safe.sh — #557: sess_bug embeds the repo slug (<prefix>-bug-<slug>-<n>-<phase>) and only mapped
# `/` to `_`, so vercel/next.js gave hz-bug-vercel_next.js-7-fix. tmux reads `.` and `:` in a target as window/pane
# separators: new-session made hz-bug-vercel_next_js-7-fix but has-session -t <dotted> failed, so bug_session_live was
# always false. slug_safe (lib.sh) maps every character outside [A-Za-z0-9_-] to `_` and is the one rule behind
# sess_bug, _bug_claim_key and fleet_bug_numbers; a slug that is already safe keeps its names byte for byte.
# Real tmux on a private TMUX_TMPDIR; kills only its own server.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
make_env
source "$ROOT/scripts/lib.sh" >/dev/null 2>&1
HARNESS_SESS_PREFIX=hz

echo "== slug_safe: unsafe characters -> _, a safe slug untouched =="
assert_eq "$(slug_safe vercel/next.js)"  "vercel_next_js"  "owner/next.js -> vercel_next_js"
assert_eq "$(slug_safe 'a:b c')"         "a_b_c"           "colon and space -> _"
assert_eq "$(slug_safe acme/widget)"     "acme_widget"     "acme/widget -> acme_widget"
assert_eq "$(slug_safe My-Org/repo_2)"   "My-Org_repo_2"   "capitals, dash, underscore, digit unchanged"

echo "== sess_bug / claim key for a dotted repo carry no . or : =="
S="$(sess_bug vercel/next.js 7 fix)"
assert_eq "$S" "hz-bug-vercel_next_js-7-fix" "sess_bug vercel/next.js"
assert_no "no dot or colon in sess_bug" bash -c '[[ "$1" == *[.:]* ]]' _ "$S"
assert_eq "$(sess_bug vercel_next_js 7 fix)" "$S" "sess_bug is idempotent on an already-sanitised slug"
assert_eq "$(_bug_claim_key 'vercel/next.js#7')" "bug-vercel_next_js-7" "claim key vercel/next.js#7"
assert_eq "$(_bug_claim_key 'a:b/c.d#12')" "bug-a_b_c_d-12" "claim key with : and . in the repo"

echo "== names for repos without dots are unchanged =="
assert_eq "$(sess_bug acme/widget 7 triage)"   "hz-bug-acme_widget-7-triage" "sess_bug acme/widget"
assert_eq "$(sess_bug My-Org/repo_2 3 fix)"    "hz-bug-My-Org_repo_2-3-fix"  "sess_bug with - and _"
assert_eq "$(_bug_claim_key 'acme/widget#7')"  "bug-acme_widget-7"           "claim key acme/widget#7"
assert_eq "$(_bug_claim_key 'My-Org/repo_2#3')" "bug-My-Org_repo_2-3"        "claim key with - and _"
assert_eq "$(_bug_claim_key 7)"                "bug-7"                       "bare number claim key"

command -v tmux >/dev/null || { echo "  skip: tmux not installed"; finish; exit 0; }
echo "== a bug-lane session for a dotted repo is found live =="
T="$(mktemp -d /tmp/t557.XXXXXX)"   # the socket path has to be short
export TMUX_TMPDIR="$T"; unset TMUX TMUX_PANE   # never the host's server
trap 'tmux kill-server 2>/dev/null; rm -rf "$T"' EXIT
export HARNESS_SESSION_BACKEND=tmux
assert_no "(before) bug_session_live is false" bug_session_live vercel/next.js 7
sess_start "$(sess_bug vercel/next.js 7 fix)" /tmp >/dev/null 2>&1
assert_ok "bug_session_live reports the dotted-repo fix lane live" bug_session_live vercel/next.js 7
sess_start "$(sess_bug vercel/next.js 8 triage)" /tmp >/dev/null 2>&1
assert_ok "bug_session_live reports the triage lane live" bug_session_live vercel/next.js 8
HARNESS_REPO=vercel/next.js HARNESS_UNIT=next.js
assert_eq "$(fleet_bug_numbers | tr '\n' ' ')" "7 8 " "fleet_bug_numbers sees the dotted repo's bug lanes"

finish

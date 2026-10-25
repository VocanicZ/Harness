#!/usr/bin/env bash
# test_ghrate.sh — #183: a rate-limit-aware dispatcher. A stubbed `gh` returns a rate-limit error
# and `gh api rate_limit` names a reset T seconds out: the dispatcher records a hold and makes NO
# further gh call until T. Below HARNESS_GH_BUDGET_PCT of the budget, nothing new is claimed, the
# poll interval doubles, and in-flight sessions are untouched. `harness status` shows each token's
# budget, reset and hold. The token is what is limited, so every cell runs for claude AND agy.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/../scripts/pool-worker.sh"
source "$HERE/../scripts/priority-worker.sh"
source "$HERE/helpers.sh"
make_env
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl" HARNESS_GH_RATE_GUARD=1
export HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme
unset GH_TOKEN GITHUB_TOKEN
POLL=1; PRIORITY_POLL=1

# The stub gh: logs `<epoch> <args>` per call; `api rate_limit` prints $RATE (exit 1 if it is
# absent); any other call fails with $ERR's text while $ERR exists, else succeeds with `[]`.
BIN="$RUN_DIR/bin"; mkdir -p "$BIN"
export GH_CALLS="$RUN_DIR/gh.calls" GH_RATE="$RUN_DIR/gh.rate" GH_ERR="$RUN_DIR/gh.err"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
echo "$(date +%s) $*" >> "$GH_CALLS"
if [[ "$1 ${2:-}" == "api rate_limit" ]]; then [[ -f "$GH_RATE" ]] || exit 1; cat "$GH_RATE"; exit 0; fi
if [[ -f "$GH_ERR" ]]; then cat "$GH_ERR" >&2; exit 1; fi
echo '[]'
SH
chmod +x "$BIN/gh"; export PATH="$BIN:$PATH"
rate(){ printf '{"resources":{"core":{"limit":5000,"remaining":%s,"reset":%s},"graphql":{"limit":5000,"remaining":%s,"reset":%s}}}' \
  "$1" "$3" "$2" "$3" > "$GH_RATE"; }
RATE_DIR="$HARNESS_HOME/ghrate"
calls(){ grep -c . "$GH_CALLS" 2>/dev/null || echo 0; }
fresh(){ rm -rf "$RATE_DIR" "$GH_ERR"; : > "$GH_CALLS"; _GH_RATE_LOGGED=""; _GH_LOW_LOGGED=""; }

for cli in claude agy; do
  export HARNESS_CLI="$cli"
  # ── A: a rate limit → hold until the reset, no gh call before it ──────────────
  fresh; T=$(( $(date +%s) + 30 ))   # far enough out that a loaded host cannot reach it mid-check
  rate 0 4000 "$T"; echo 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' > "$GH_ERR"
  dispatch_actions acme/widget 1 1 "" 2>/dev/null; rc=$?
  assert_eq "$rc" "3" "$cli: a rate-limited dispatch read HOLDs"
  assert_eq "$(gh_rate_held)" "$T" "$cli: the hold carries the reset read from gh api rate_limit"
  n="$(calls)"
  python3 "$ISSUELIB" complete acme/widget >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "3" "$cli: every issuelib read refuses while held"
  assert_eq "$(calls)" "$n" "$cli: a held read never calls gh"
  rm -f "$GH_ERR"
  # re-pin the reset 3s from NOW, so the waits below are timed from here, not from the slow reads above
  T=$(( $(date +%s) + 3 )); printf '{"reset": %s, "resource": "core"}' "$T" > "$RATE_DIR/gh-auth.hold"
  TICKS="$RUN_DIR/ticks"; : > "$TICKS"; tick(){ echo x >> "$TICKS"; }
  out="$(gh_rate_wait tick)"
  assert_ok "$cli: gh_rate_wait slept until the reset" test "$(date +%s)" -ge "$T"
  assert_eq "$(calls)" "$n" "$cli: no gh call at all until the reset"
  assert_eq "$(grep -c 'github rate limit' <<< "$out")" "1" "$cli: one log line per hold, not one per poll"
  assert_ok "$cli: gh-free work (the watchdog) keeps running while held" test "$(grep -c . "$TICKS")" -ge 2
  assert_ok "$cli: the hold is a stats hold event" grep -q '"cause": "gh_rate_limit"' "$HARNESS_EVENTS_FILE"
  dispatch_actions acme/widget 1 1 "" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "$cli: after the reset, dispatch reads gh again"
  assert_ok "$cli: the first call after the hold is at or after T" \
    awk -v n="$n" -v t="$T" 'NR==n+1 { exit !($1 >= t) }' "$GH_CALLS"

  # drive_unit and the pool worker both sleep through a hold before their next gh read
  fresh; T=$(( $(date +%s) + 30 )); rate 0 4000 "$T"
  echo 'gh: API rate limit exceeded (HTTP 403)' > "$GH_ERR"; dispatch_actions acme/widget 1 1 "" 2>/dev/null
  rm -f "$GH_ERR"; T=$(( $(date +%s) + 2 )); printf '{"reset": %s}' "$T" > "$RATE_DIR/gh-auth.hold"
  SEEN="$RUN_DIR/seen"; : > "$SEEN"
  unit_complete(){ date +%s >> "$SEEN"; return 0; }; finalize_unit(){ :; }; watchdog_team(){ :; }
  drive_unit main >/dev/null
  assert_ok "$cli: drive_unit's next completion read waits for the reset" test "$(head -1 "$SEEN")" -ge "$T"
  fresh; T=$(( $(date +%s) + 30 )); rate 0 4000 "$T"
  echo 'gh: API rate limit exceeded (HTTP 403)' > "$GH_ERR"; dispatch_actions acme/widget 1 1 "" 2>/dev/null
  rm -f "$GH_ERR"; : > "$SEEN"; T=$(( $(date +%s) + 2 )); printf '{"reset": %s}' "$T" > "$RATE_DIR/gh-auth.hold"
  rate 4000 4000 "$T"   # the budget refills at the reset
  python3 - "$RATE_DIR/gh-auth.rate" "$T" <<'PY2'
import json, sys   # the probe cached at the limit, re-stamped to this reset: stale once it passes
f, t = sys.argv[1], int(sys.argv[2]); d = json.load(open(f))
for v in d["resources"].values(): v["reset"] = t
json.dump(d, open(f, "w"))
PY2
  claim_next(){ date +%s >> "$SEEN"; echo ""; }; all_complete(){ return 1; }; snapshot_gate(){ return 0; }
  worker_step W1 >/dev/null
  assert_ok "$cli: the pool worker's next claim waits for the reset" test "$(head -1 "$SEEN")" -ge "$T"
  source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; POLL=1; PRIORITY_POLL=1

  # ── C: below the budget threshold → no new claims, double poll, live sessions untouched ──
  fresh; reset=$(( $(date +%s) + 3600 )); rate 900 4000 "$reset"   # core 18% < 20%
  assert_ok "$cli: core under 20% is a low budget" gh_budget_low
  CLAIMED="$RUN_DIR/claimed"; : > "$CLAIMED"
  claim_next(){ echo pool >> "$CLAIMED"; echo main; }
  claim_next_bug(){ echo bug >> "$CLAIMED"; echo "acme/widget#9"; }
  worker_tick W1 >/dev/null; rc=$?
  assert_eq "$rc" "5" "$cli: worker_tick idles on a low budget"
  bug_tick P1 >/dev/null; rc=$?
  assert_eq "$rc" "5" "$cli: bug_tick idles on a low budget"
  assert_eq "$(cat "$CLAIMED")" "" "$cli: nothing is claimed below the threshold"
  SLEPT="$RUN_DIR/slept"; : > "$SLEPT"; sleep(){ echo "$1" >> "$SLEPT"; }
  snapshot_gate(){ return 0; }; POLL=7; PRIORITY_POLL=7
  worker_step W1 >/dev/null; bug_step P1 >/dev/null
  assert_eq "$(tr '\n' ' ' < "$SLEPT")" "14 14 " "$cli: the poll interval doubles on a low budget"
  : > "$SLEPT"; TMUXLOG="$RUN_DIR/tmux"; : > "$TMUXLOG"
  tmux(){ echo "tmux $*" >> "$TMUXLOG"; [[ "$1" == ls ]] && echo hz-main-i5; return 0; }
  DISPATCHED="$RUN_DIR/dispatched"; : > "$DISPATCHED"; polls=0
  reap_done_sessions(){ :; }; reap_team(){ :; }; reap_orch(){ :; }; watchdog_team(){ :; }
  reap_finished_inject(){ :; }; ci_gate_ok(){ return 0; }; count_team_sessions(){ echo 1; }; finalize_unit(){ :; }
  dispatch_actions(){ echo yes >> "$DISPATCHED"; }
  unit_complete(){ polls=$((polls+1)); (( polls > 2 )); }
  drive_unit main >/dev/null
  assert_eq "$(cat "$DISPATCHED")" "" "$cli: drive_unit dispatches nothing new on a low budget"
  assert_eq "$(tr '\n' ' ' < "$SLEPT")" "14 14 " "$cli: drive_unit polls at half rate on a low budget"
  assert_no "$cli: in-flight sessions are untouched" grep -qE 'kill-session|send-keys' "$TMUXLOG"
  unset -f sleep tmux
  source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"
  source "$HERE/../scripts/pool-worker.sh"; source "$HERE/../scripts/priority-worker.sh"; POLL=1; PRIORITY_POLL=1
done
export HARNESS_CLI=claude

# the guard's edges: graphql counts too, a fresh probe is reused, fail-open, and the off switch
fresh; rate 4000 400 "$(( $(date +%s) + 3600 ))"
assert_ok "graphql under the threshold is a low budget too" gh_budget_low
fresh; rate 2000 2000 "$(( $(date +%s) + 3600 ))"
assert_no "40% left is not low" gh_budget_low
n="$(calls)"; gh_budget_low
assert_eq "$(calls)" "$n" "a probe younger than HARNESS_GH_RATE_TTL is reused, not re-fetched"
fresh; rm -f "$GH_RATE"
assert_no "a failed probe reads as not low (fail-open)" gh_budget_low
fresh; rate 0 0 "$(( $(date +%s) + 3600 ))"
HARNESS_GH_RATE_GUARD=0 gh_budget_low; rc=$?
assert_eq "$rc" "1" "HARNESS_GH_RATE_GUARD=0 turns the budget guard off"
HARNESS_GH_RATE_GUARD=0 bash -c "echo 'API rate limit exceeded' > '$GH_ERR'; python3 '$ISSUELIB' complete acme/widget" >/dev/null 2>&1
assert_no "HARNESS_GH_RATE_GUARD=0: a rate limit records no hold" test -e "$RATE_DIR/gh-auth.hold"

# a secondary limit (budget left) holds a minute; a plain permission 403 holds nothing
fresh; rate 4000 4000 "$(( $(date +%s) + 3600 ))"
echo 'gh: You have exceeded a secondary rate limit (HTTP 403)' > "$GH_ERR"
python3 "$ISSUELIB" complete acme/widget >/dev/null 2>&1
held="$(gh_rate_held)"; now="$(date +%s)"
assert_ok "a secondary limit holds about a minute" test "$held" -ge $(( now + 55 )) -a "$held" -le $(( now + 61 ))
fresh; rate 4000 4000 "$(( $(date +%s) + 3600 ))"
echo 'HTTP 403: Resource not accessible by integration' > "$GH_ERR"
python3 "$ISSUELIB" complete acme/widget >/dev/null 2>&1
assert_no "a permission 403 with budget left is not a rate limit" gh_rate_held
fresh; rm -f "$GH_RATE"; echo 'HTTP 403: forbidden' > "$GH_ERR"
python3 "$ISSUELIB" complete acme/widget >/dev/null 2>&1
assert_no "an unnamed 403 with no readable budget holds nothing" gh_rate_held
mkdir -p "$RATE_DIR"; echo '{garbled' > "$RATE_DIR/gh-auth.hold"
assert_no "a garbled hold file is no hold" gh_rate_held

# ── D: harness status — each token's budget, reset, and hold ──────────────────
fresh; reset=$(( $(date +%s) + 3600 )); rate 900 4500 "$reset"
GH_TOKEN=s3cret gh_rate_report >/dev/null   # a second token, seen earlier on this host
rate 1200 4800 "$reset"; echo 'API rate limit exceeded' > "$GH_ERR"
python3 "$ISSUELIB" complete acme/widget >/dev/null 2>&1   # budget left: a secondary hold
out="$(gh_rate_report)"
hm="$(date -d "@$reset" +%H:%M)"
assert_ok "status shows this token's remaining budget and reset" \
  grep -q "github: gh-auth: core 1200/5000 resets $hm, graphql 4800/5000 resets $hm  HOLD until" <<< "$out"
assert_ok "status shows every token seen on the host" grep -q "github: token-[0-9a-f]\{8\}: core 900/5000" <<< "$out"
assert_no "a token is never printed" grep -q s3cret <<< "$out"
assert_eq "$(HARNESS_GH_RATE_GUARD=0; rm -rf "$RATE_DIR"; gh_rate_report)" "" "guard off: no budget lines"
mkdir -p "$RATE_DIR"; echo '{}' > "$RATE_DIR/gh-auth.rate"
rm -f "$GH_RATE"
assert_eq "$(gh_rate_report)" "  github: gh-auth: no data" "a token with no readable budget says so"

finish

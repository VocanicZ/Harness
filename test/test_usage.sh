#!/usr/bin/env bash
# test_usage.sh — #194: watch usage, checkpoint every live session to GitHub BEFORE the limit hits.
# A stubbed usage source (HARNESS_USAGE_CMD) crosses HARNESS_USAGE_CHECKPOINT_PCT: every live
# impl/lane session gets the HARNESS CHECKPOINT instruction, no new claim happens, and claims resume
# once the stub reports the reset. A session already frozen at a limit gets a MECHANICAL checkpoint
# (branch pushed, handoff posted) and is never killed. Both through the CLI seam, for claude and agy.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/../scripts/pool-worker.sh"
source "$HERE/../scripts/priority-worker.sh"
source "$HERE/helpers.sh"
make_env
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"

STUB="$RUN_DIR/usage.stub"
future=$(( $(date +%s) + 3600 )); past=$(( $(date +%s) - 60 ))
stub_usage(){ printf 'acctA\tfive_hour\t%s\t%s\n' "$1" "${2:-$future}" > "$STUB"; }
export HARNESS_USAGE_CMD="cat '$STUB'"

# ── A: the CLI seam ──────────────────────────────────────────────────────────
stub_usage 42
for cli in claude agy; do
  assert_eq "$(HARNESS_CLI=$cli cli_limit_usage)" "$(printf 'acctA\tfive_hour\t42\t%s' "$future")" \
    "$cli: HARNESS_USAGE_CMD is read through cli_limit_usage"
done
( unset HARNESS_USAGE_CMD; HARNESS_AGY_BIN="$RUN_DIR/no-such-agy" HARNESS_CLI=agy cli_limit_usage >/dev/null ); rc=$?
assert_eq "$rc" "1" "agy with no usage source (no agy binary): usage unavailable"
# #188: agy reports its windows itself (`agy -p /usage`); the adapter turns remaining into used %.
rm -rf "$(_usage_dir)"   # the failed read above is cached too (HARNESS_AGY_USAGE_TTL)
AGYSTUB="$RUN_DIR/agy-stub"
printf '#!/bin/sh
echo "$*" >> %q.calls
exec cat %q
' "$AGYSTUB" "$HERE/fixtures/cli/agy/usage-windows.json" > "$AGYSTUB"; chmod +x "$AGYSTUB"
got="$(unset HARNESS_USAGE_CMD; HARNESS_AGY_BIN="$AGYSTUB" HARNESS_CLI=agy cli_limit_usage | cut -f1-3)"
assert_eq "$got" "$(cat "$HERE/fixtures/cli/agy/usage-windows.expected")" "agy: usage windows from agy -p /usage, as used %"
( unset HARNESS_USAGE_CMD; HARNESS_AGY_BIN="$AGYSTUB" HARNESS_CLI=agy cli_limit_usage >/dev/null )
assert_eq "$(wc -l < "$AGYSTUB.calls")" "1" "agy: a second read inside HARNESS_AGY_USAGE_TTL reuses the first (one agy call)"
rm -rf "$(_usage_dir)"
( unset HARNESS_USAGE_CMD; HARNESS_CLI=claude cli_limit_usage >/dev/null ); rc=$?
assert_eq "$rc" "1" "claude before any status-line drop: usage unavailable"
( unset HARNESS_USAGE_CMD; HARNESS_CLI=other cli_limit_usage >/dev/null ); rc=$?
assert_eq "$rc" "1" "an unknown CLI: usage unavailable"

# ── B: the claude adapter — status line → drop file → usage lines ─────────────
WT="$RUN_DIR/wt-statusline"; mkdir -p "$WT"
out="$(printf '{"workspace":{"current_dir":"%s"},"rate_limits":{"five_hour":{"used_percentage":91.5,"resets_at":%s},"seven_day":{"used_percentage":30,"resets_at":%s}}}' \
  "$WT" "$future" "$past" | CLAUDE_CONFIG_DIR=/x/accounts/work bash "$HERE/../scripts/usage-statusline.sh" "$(_usage_dir)")"
assert_eq "$out" "harness · 5h 92% · 7d 30%" "statusline prints the windows"
assert_ok "statusline dropped the account's windows" test -f "$(_usage_dir)/work.json"
got="$(unset HARNESS_USAGE_CMD; HARNESS_CLI=claude cli_limit_usage)"
assert_eq "$got" "$(printf 'work\tfive_hour\t91.5\t%s' "$future")" "claude adapter reports the open window, skips the reset one"
echo "$WT" > "$RUN_DIR/hz-main-i3.wd"
assert_eq "$(session_account hz-main-i3)" "work" "a session maps to the account its status line reported"
assert_eq "$(session_account hz-main-i4)" "" "a session with no drop has no known account"
out="$(echo 'not json' | bash "$HERE/../scripts/usage-statusline.sh" "$(_usage_dir)")"
assert_eq "$out" "" "statusline ignores unparseable input"
out="$(printf '{"cwd":"%s"}' "$WT" | bash "$HERE/../scripts/usage-statusline.sh" "$(_usage_dir)")"
assert_eq "$out" "harness · usage n/a" "statusline with no rate_limits says usage n/a"
rm -rf "$(_usage_dir)"

# ensure_usage_statusline wires Harness-owned claude trees only, and never overwrites
WT2="$RUN_DIR/wt2"; mkdir -p "$WT2"
ensure_usage_statusline "$WT2"
assert_ok "worktree status line points at usage-statusline.sh" grep -q 'usage-statusline.sh' "$WT2/.claude/settings.local.json"
printf '{"statusLine":{"type":"command","command":"mine"}}' > "$WT2/.claude/settings.local.json"
ensure_usage_statusline "$WT2"
assert_ok "an existing statusLine is left alone" grep -q '"mine"' "$WT2/.claude/settings.local.json"
ensure_usage_statusline "$PROJECT_ROOT"
assert_no "the owner's own project root is never touched" test -f "$PROJECT_ROOT/.claude/settings.local.json"
WT3="$RUN_DIR/wt3"; mkdir -p "$WT3"
HARNESS_CLI=agy ensure_usage_statusline "$WT3"
HARNESS_USAGE_STATUSLINE=0 ensure_usage_statusline "$WT3"
assert_no "agy / HARNESS_USAGE_STATUSLINE=0: no status line wired" test -f "$WT3/.claude/settings.local.json"
printf 'not json' > "$WT3/s.json"; mkdir -p "$WT3/.claude"; mv "$WT3/s.json" "$WT3/.claude/settings.local.json"
ensure_usage_statusline "$WT3"
assert_ok "a corrupt settings file is replaced, not crashed on" grep -q 'usage-statusline.sh' "$WT3/.claude/settings.local.json"

# ── B2 (#364): each new reading lands in the event log, once per account/window ──
n_readings(){ grep -c '"event": "usage_reading"' "$HARNESS_EVENTS_FILE" 2>/dev/null || true; }
printf 'acctR\tfive_hour\t12.5\t%s\nacctR\tseven_day\t40\t%s\nacctR\tfive_hour\t12.5\t%s\nacctR\tbad\tn/a\t0\n' \
  "$future" "$future" "$future" > "$STUB"
before="$(n_readings)"; usage_watch
assert_eq "$(( $(n_readings) - before ))" "2" "one usage_reading per account/window per poll (a repeated line and a malformed one are not logged)"
assert_ok "usage_reading carries account, window, pct and resets_at" \
  grep -q "\"event\": \"usage_reading\".*\"account\": \"acctR\", \"window\": \"five_hour\", \"pct\": \"12.5\", \"resets_at\": $future" "$HARNESS_EVENTS_FILE"
usage_watch
assert_eq "$(( $(n_readings) - before ))" "2" "the next poll's unchanged readings are not logged again"
printf 'acctR\tfive_hour\t13\t%s\nacctR\tseven_day\t40\t%s\n' "$future" "$future" > "$STUB"; usage_watch
assert_eq "$(( $(n_readings) - before ))" "3" "a changed reading is logged"
printf 'acctR\tfive_hour\t14\t%s\n' "$future" > "$STUB"
( HARNESS_EVENTS_FILE=/nonexistent/dir/events.jsonl; usage_watch ); rc=$?
assert_eq "$rc" "0" "a failing event log never fails the poll"
rm -rf "$RUN_DIR/usage-readings"

# ── C: crossing the threshold checkpoints every live session and holds claims ──
export HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme HARNESS_USAGE_CHECKPOINT_PCT=90
CALLS="$RUN_DIR/calls"; : > "$CALLS"
PANE="$RUN_DIR/pane"; printf '%s\n' 'Working… (esc to interrupt)' > "$PANE"
tmux(){ echo "tmux $*" >> "$CALLS"
  case "$1" in
    ls) printf 'hz-main-i5\nhz-bug-acme_widget-9-fix\nhz-main-p0\n' ;;
    capture-pane) cat "$PANE" ;;
  esac; return 0; }
gh(){ echo "gh $*" >> "$CALLS"; return 0; }

printf 'acctA\tfive_hour\tn/a\t0\nacctA\tfive_hour\n' > "$STUB"; usage_watch
assert_no "malformed usage lines: no hold, no crash" usage_held
stub_usage 50; usage_watch
assert_no "below the threshold: no hold" usage_held
assert_no "below the threshold: nothing sent" grep -q 'send-keys' "$CALLS"

stub_usage 91; usage_watch
assert_ok "at 91% of a window: claims held" usage_held
assert_ok "impl session got the checkpoint instruction" \
  grep -q 'send-keys -t hz-main-i5 -l HARNESS CHECKPOINT — usage limit near (five_hour window at 91%)' "$CALLS"
assert_ok "lane session got the checkpoint instruction" grep -q 'send-keys -t hz-bug-acme_widget-9-fix -l HARNESS CHECKPOINT' "$CALLS"
assert_no "orch session is not a checkpoint target" grep -q 'send-keys -t hz-main-p0' "$CALLS"
assert_ok "instruction names the paused label swap" grep -q 'hz-main-i5 -l .*--remove-label agent-working --add-label agent-paused' "$CALLS"
assert_no "the usage checkpoint never kills a session" grep -q 'kill-session' "$CALLS"
assert_ok "usage_checkpoint event logged" grep -q '"event": "usage_checkpoint".*"account": "acctA"' "$HARNESS_EVENTS_FILE"
sent="$(grep -c 'HARNESS CHECKPOINT' "$CALLS")"
usage_watch
assert_eq "$(grep -c 'HARNESS CHECKPOINT' "$CALLS")" "$sent" "a held account is not re-checkpointed every poll"

# no new claims while held — pool worker, lane, and an in-flight drive_unit
CLAIMED="$RUN_DIR/claimed"; : > "$CLAIMED"   # claim_next runs in $(…): record to a file, not a var
claim_next(){ echo pool >> "$CLAIMED"; echo main; }
worker_tick W1; rc=$?
assert_eq "$rc" "3" "worker_tick idles while usage is held"
assert_eq "$(cat "$CLAIMED")" "" "worker_tick claims nothing while usage is held"
claim_next_bug(){ echo bug >> "$CLAIMED"; echo "acme/widget#9"; }
bug_tick P1; rc=$?
assert_eq "$rc" "3" "bug_tick idles while usage is held"
assert_eq "$(cat "$CLAIMED")" "" "the bug lane claims nothing while usage is held"
DISPATCHED="$RUN_DIR/dispatched"; : > "$DISPATCHED"; polls=0
reap_done_sessions(){ :; }; reap_team(){ :; }; reap_orch(){ :; }; watchdog_team(){ :; }
reap_finished_inject(){ :; }; ci_gate_ok(){ return 0; }; count_team_sessions(){ echo 0; }; finalize_unit(){ :; }
dispatch_actions(){ echo yes >> "$DISPATCHED"; }
unit_complete(){ polls=$((polls+1)); (( polls > 3 )); }
drive_unit main >/dev/null
assert_eq "$(cat "$DISPATCHED")" "" "drive_unit holds new dispatch while usage is held"
usage_report > "$RUN_DIR/report"
assert_ok "status shows the window and the hold" grep -q 'usage: acctA five_hour 91% (checkpoint at 90%.*HOLD' "$RUN_DIR/report"

# the stub reports the reset → hold released, claims resume
stub_usage 3; usage_watch
assert_no "after the reset: hold released" usage_held
assert_ok "usage_resume event logged" grep -q '"event": "usage_resume".*"account": "acctA"' "$HARNESS_EVENTS_FILE"
drive_unit(){ :; }; seed_if_needed(){ :; }; release_claim(){ :; }
worker_tick W1 >/dev/null
assert_eq "$(cat "$CLAIMED")" "pool" "claims resume once the window resets"
source "$HERE/../scripts/drive.sh"   # restore the real drive_unit, keep its sweeps stubbed
reap_done_sessions(){ :; }; reap_team(){ :; }; reap_orch(){ :; }; finalize_unit(){ :; }
polls=0; drive_unit main >/dev/null
assert_ok "drive_unit dispatches again after the reset" grep -q yes "$DISPATCHED"

# a hold whose window has passed is released even when usage turns unavailable
stub_usage 95; usage_watch; assert_ok "re-held at 95%" usage_held
printf 'acctA\tfive_hour\t95\t%s\n' "$past" > "$(_usage_hold_dir)/acctA.hold"
export HARNESS_USAGE_CMD="exit 1"
usage_watch
assert_no "usage unavailable + reset time passed: hold released" usage_held
assert_ok "unavailable usage is logged once" test -f "$RUN_DIR/usage.unavailable"
usage_report > "$RUN_DIR/report"
assert_ok "status says usage unavailable" grep -q 'usage: unavailable' "$RUN_DIR/report"
export HARNESS_USAGE_CMD="true"
usage_report > "$RUN_DIR/report"
assert_ok "status with no open windows says so" grep -q 'no open windows' "$RUN_DIR/report"
export HARNESS_USAGE_CMD="cat '$STUB'"

# sessions known to be on ANOTHER account are left alone
: > "$CALLS"; rm -f "$(_usage_hold_dir)"/*.hold
mkdir -p "$(_usage_dir)/cwd"; echo "$RUN_DIR/wt-i5" > "$RUN_DIR/hz-main-i5.wd"
echo acctB > "$(_usage_dir)/cwd/$(_usage_key "$RUN_DIR/wt-i5")"
stub_usage 99; usage_watch
assert_no "a session on another account is not checkpointed" grep -q 'send-keys -t hz-main-i5 ' "$CALLS"
assert_ok "the unknown-account lane session is checkpointed" grep -q 'send-keys -t hz-bug-acme_widget-9-fix ' "$CALLS"
rm -rf "$(_usage_dir)" "$(_usage_hold_dir)" "$RUN_DIR/hz-main-i5.wd"

# ── D: a session already frozen at the limit gets a MECHANICAL checkpoint, not killed ──
ORIGIN="$RUN_DIR/origin.git"; git init -q --bare "$ORIGIN"
WD="$RUN_DIR/wt-i7"; git init -q "$WD"
git -C "$WD" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$WD" checkout -q -b issue/7; git -C "$WD" remote add origin "$ORIGIN"
git -C "$WD" config user.email t@t; git -C "$WD" config user.name t
echo wip > "$WD/feature.txt"; echo brief > "$WD/.harness-task.md"
echo "$WD" > "$RUN_DIR/hz-main-i7.wd"
printf '%s\n' "  ⎿  You've hit your session limit · resets 3am (UTC)" '❯' > "$PANE"
: > "$CALLS"
tmux(){ echo "tmux $*" >> "$CALLS"
  case "$1" in ls) echo hz-main-i7 ;; capture-pane) cat "$PANE" ;; esac; return 0; }
gh(){ printf 'gh %s\n' "$*" >> "$CALLS"; return 0; }
stub_usage 100; usage_watch
assert_ok "frozen session: WIP branch pushed to origin" bash -c "git -C '$ORIGIN' rev-parse -q --verify refs/heads/issue/7 >/dev/null"
assert_ok "frozen session: the WIP file is in the pushed commit" bash -c "git -C '$ORIGIN' show issue/7:feature.txt | grep -q wip"
assert_no "frozen session: the brief is not committed" bash -c "git -C '$ORIGIN' show issue/7:.harness-task.md >/dev/null 2>&1"
assert_ok "frozen session: handoff comment posted" grep -q 'gh issue comment 7 -R acme/widget --body <!-- harness-handoff issue=7 branch=issue/7 -->' "$CALLS"
assert_ok "frozen session: handoff carries the last screen" grep -q "hit your session limit" "$CALLS"
assert_no "frozen session: no /handoff instruction typed into a frozen pane" grep -q 'HARNESS CHECKPOINT' "$CALLS"
assert_no "frozen session: never killed" grep -q 'kill-session' "$CALLS"
rm -rf "$(_usage_hold_dir)"

# the watchdog checkpoints on the limit message itself (no usage source needed) — once per episode
export HARNESS_USAGE_CMD="exit 1"
: > "$CALLS"; rm -f "$RUN_DIR/hz-main-i7.limitcp"
echo more >> "$WD/feature.txt"
session_live(){ return 0; }
_watchdog_limit_pick(){ :; }; _watchdog_limit_nudge(){ :; }
watchdog_session hz-main-i7; watchdog_session hz-main-i7
assert_eq "$(grep -c '^gh issue comment 7 ' "$CALLS")" "1" "limit message: one mechanical checkpoint per episode"
assert_ok "limit message: event logged" grep -q '"reason": "limit_message"' "$HARNESS_EVENTS_FILE"
printf '%s\n' 'Resumed… (esc to interrupt)' > "$PANE"; watchdog_session hz-main-i7
assert_no "back off the limit: episode marker cleared" test -f "$RUN_DIR/hz-main-i7.limitcp"
printf '%s\n' '   ❯ 1. Stop and wait for limit to reset' > "$PANE"; : > "$CALLS"
watchdog_session hz-main-i7
assert_ok "limit menu: mechanical checkpoint too" grep -q '^gh issue comment 7 ' "$CALLS"

# a failed handoff post is logged, never fatal
gh(){ printf 'gh %s\n' "$*" >> "$CALLS"; return 1; }
out="$(mechanical_checkpoint hz-main-i7 "$(cat "$PANE")")"; rc=$?
assert_eq "$rc" "0" "a failed handoff post does not fail the checkpoint (the push already landed)"
assert_ok "a failed handoff post is logged" grep -q 'handoff comment for acme/widget#7 failed' <<< "$out"
gh(){ printf 'gh %s\n' "$*" >> "$CALLS"; return 0; }

# diverged origin → pushed to a side branch; unpushable → no comment, rc 1
git -C "$WD" reset -q --hard HEAD~1; echo other > "$WD/other.txt"
rm -f "$RUN_DIR/hz-main-i7.limitcp"; : > "$CALLS"
mechanical_checkpoint hz-main-i7 "$(cat "$PANE")"
assert_ok "diverged origin: pushed to a checkpoint side branch" bash -c "git -C '$ORIGIN' for-each-ref --format='%(refname)' | grep -q 'issue/7-checkpoint-'"
assert_ok "diverged origin: comment names the side branch" grep -q 'had diverged' "$CALLS"
git -C "$WD" remote set-url origin "$RUN_DIR/nowhere.git"; : > "$CALLS"
mechanical_checkpoint hz-main-i7 "$(cat "$PANE")"; rc=$?
assert_eq "$rc" "1" "unpushable work: mechanical checkpoint reports failure"
assert_no "unpushable work: no handoff claiming a push" grep -q 'gh issue comment' "$CALLS"

# a session that is no impl/lane session is never a checkpoint target
_checkpoint_target hz-main-p0; rc=$?
assert_eq "$rc" "1" "an orch session does not resolve to a checkpoint target"

# an unresolvable repo never reaches gh (gh -R "" would hit the cwd's repo)
HARNESS_TOPOLOGY=multi; : > "$TARGETS_TSV"; : > "$CALLS"
mechanical_checkpoint hz-ghost-i120 "$(cat "$PANE")"; rc=$?
assert_eq "$rc" "1" "unresolved repo: no checkpoint"
assert_no "unresolved repo: gh never called" grep -q '^gh ' "$CALLS"

finish

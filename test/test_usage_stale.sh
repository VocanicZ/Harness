#!/usr/bin/env bash
# test_usage_stale.sh — #658: a usage reading is only as good as its age.
# The claude adapter's status-line drops freeze when a fleet's panes stop drawing the status line; the
# hold must not run on an old low number as if it were live. A stale reading below the threshold opens
# nothing (and is said so, once); a stale reading AT/ABOVE it still holds (usage only grows inside a
# window); staleness never releases a hold early. And the drops of every fleet on the host (the registry
# at $HARNESS_FLEETS_DIR) feed one account's reading: the newest `at` wins.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/../scripts/pool-worker.sh"
source "$HERE/../scripts/priority-worker.sh"
source "$HERE/helpers.sh"
make_env
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"
export HARNESS_REPO=acme/widget HARNESS_OWNER=acme HARNESS_USAGE_CHECKPOINT_PCT=90
export HARNESS_CLI=claude; unset HARNESS_USAGE_CMD CLAUDE_CONFIG_DIR
CALLS="$RUN_DIR/calls"; : > "$CALLS"
tmux(){ echo "tmux $*" >> "$CALLS"; case "$1" in ls) printf 'hz-main-i5\n' ;; capture-pane) echo 'Working…' ;; esac; return 0; }
gh(){ echo "gh $*" >> "$CALLS"; return 0; }

now=$(date +%s); future=$(( now + 86400 ))
# drop <dir> <account> <pct> <age-seconds> [reset] [window] — a status-line drop <age> seconds old
drop(){ mkdir -p "$1"; printf '{"account":"%s","at":%s,"rate_limits":{"%s":{"used_percentage":%s,"resets_at":%s}}}' \
  "$2" "$(( now - $4 ))" "${6:-seven_day}" "$3" "${5:-$future}" > "$1/$2.json"; }
reset_state(){ rm -rf "$(_usage_dir)" "$(_usage_hold_dir)" "$RUN_DIR/usage-stale" "$RUN_DIR/usage-readings" "$FLEETS_SIB"; : > "$CALLS"; : > "$HARNESS_EVENTS_FILE"; }
FLEETS_SIB="$RUN_DIR/sibling"

# ── 1: the minimal repro — a 31-minute-old 70% reading is stale, not current ──────────────────────
reset_state
drop "$(_usage_dir)" main 70 $(( 31 * 60 ))
out1="$(usage_watch)"; out2="$(usage_watch)"
assert_no "stale 70% (threshold 90): no hold" usage_held
assert_eq "$(grep -c 'reading is stale' <<<"$out1"$'\n'"$out2")" "1" "the stale line is logged once over two polls"
assert_ok "the stale line names account, window, age and pct" grep -q 'usage: main seven_day reading is stale (31m old, 70%)' <<<"$out1"
assert_ok "the stale line says what still checkpoints" grep -q 'checkpointing on the limit message only' <<<"$out1"
assert_ok "a usage_stale event is recorded" grep -q '"event": "usage_stale".*"account": "main"' "$HARNESS_EVENTS_FILE"
assert_eq "$(grep -c '"event": "usage_stale"' "$HARNESS_EVENTS_FILE")" "1" "one usage_stale event per episode"
usage_report > "$RUN_DIR/report"
assert_ok "usage_report marks it STALE with its age" grep -q 'usage: main seven_day 70% (checkpoint at 90%, resets .*) STALE 31m old' "$RUN_DIR/report"
# the episode ends when a fresh reading arrives; the next stale spell is a new episode
drop "$(_usage_dir)" main 71 10; usage_watch >/dev/null
drop "$(_usage_dir)" main 71 $(( 40 * 60 )); out="$(usage_watch)"
assert_ok "a new stale episode is logged again" grep -q 'reading is stale' <<<"$out"
usage_report > "$RUN_DIR/report"; drop "$(_usage_dir)" main 71 10; usage_report > "$RUN_DIR/report2"
assert_no "a fresh reading is not marked STALE" grep -q STALE "$RUN_DIR/report2"

# ── 2: a stale reading AT/ABOVE the threshold still holds (usage only grows until the reset) ──────
reset_state
drop "$(_usage_dir)" main 95 $(( 30 * 3600 ))
usage_watch >/dev/null
assert_ok "stale 95% with a future reset: the hold opens" usage_held
assert_ok "…and the live sessions are checkpointed" grep -q 'HARNESS CHECKPOINT' "$CALLS"

# ── 3: staleness never releases a hold early ──────────────────────────────────────────────────────
reset_state
drop "$(_usage_dir)" main 95 10; usage_watch >/dev/null
assert_ok "held at 95%" usage_held
drop "$(_usage_dir)" main 70 $(( 31 * 60 )); usage_watch >/dev/null
assert_ok "the drop goes stale at a lower number: the hold is kept" usage_held
touch -d "@$(( now - 3 * 3600 ))" "$(_usage_hold_dir)/main.hold"   # opened 3h ago: a 31m-old reading is NEWER than the hold, yet stale
usage_watch >/dev/null
assert_ok "a reading taken after the hold opened but itself stale does not release it" usage_held
rm -f "$(_usage_dir)/main.json"; usage_watch >/dev/null
assert_ok "the drop disappears (future reset): the hold is kept" usage_held
touch -d "@$(( now - 120 ))" "$(_usage_hold_dir)/main.hold"   # the hold opened two minutes ago (#659: only a reading taken after it releases)
drop "$(_usage_dir)" main 40 10; usage_watch >/dev/null
assert_no "a FRESH reading below the threshold releases it" usage_held
# a hold whose recorded reset has passed is released even with nothing to read
drop "$(_usage_dir)" main 95 10; usage_watch >/dev/null; assert_ok "re-held" usage_held
rm -f "$(_usage_dir)/main.json"
printf 'main\tseven_day\t95\t%s\n' "$(( now - 60 ))" > "$(_usage_hold_dir)/main.hold"; usage_watch >/dev/null
assert_no "the recorded reset passed: released" usage_held

# ── 4: readings are shared across the fleets on the host ──────────────────────────────────────────
# a sibling fleet (in the registry) has a fresh 91% on the same account; ours is old and low
reset_state
mkdir -p "$HARNESS_FLEETS_DIR"
printf '{"prefix":"sib","project":"/p/sib","run_dir":"%s","slugs":[],"started_at":1}' "$FLEETS_SIB" > "$HARNESS_FLEETS_DIR/sib.json"
printf 'not json' > "$HARNESS_FLEETS_DIR/junk.json"
printf '{"prefix":"gone","project":"/p/gone","run_dir":"%s/no-such-run"}' "$RUN_DIR" > "$HARNESS_FLEETS_DIR/gone.json"
printf '{"prefix":"nodir"}' > "$HARNESS_FLEETS_DIR/nodir.json"
drop "$(_usage_dir)" main 70 $(( 30 * 3600 ))
drop "$FLEETS_SIB/usage" main 91 60
got="$(claude_limit_usage)"; rc=$?
assert_eq "$rc" "0" "junk / missing / dir-less registry entries are skipped, never fatal"
assert_eq "$(cut -f1-3 <<<"$got")" "$(printf 'main\tseven_day\t91')" "the sibling's fresh 91% beats our old 70%"
usage_watch >/dev/null
assert_ok "the hold opens on the sibling's reading" usage_held
# …and the newest `at` wins the other way round too
reset_state
printf '{"prefix":"sib","project":"/p/sib","run_dir":"%s"}' "$FLEETS_SIB" > "$HARNESS_FLEETS_DIR/sib.json"
drop "$(_usage_dir)" main 50 60
drop "$FLEETS_SIB/usage" main 60 3600
got="$(claude_limit_usage)"
assert_eq "$(cut -f1-3 <<<"$got")" "$(printf 'main\tseven_day\t50')" "our fresh 50% beats a sibling's older 60%"
# a sibling alone is a reading (our fleet has no drop at all)
reset_state
printf '{"prefix":"sib","project":"/p/sib","run_dir":"%s"}' "$FLEETS_SIB" > "$HARNESS_FLEETS_DIR/sib.json"
drop "$FLEETS_SIB/usage" main 33 60
assert_eq "$(claude_limit_usage | cut -f1-3)" "$(printf 'main\tseven_day\t33')" "a sibling's drop is a reading when we have none"
# another account's sibling reading is not ours
drop "$FLEETS_SIB/usage" other 99 60
assert_eq "$(claude_limit_usage | cut -f1 | sort | tr '\n' ' ')" "main other " "accounts stay apart"
rm -f "$HARNESS_FLEETS_DIR"/*.json
assert_eq "$(claude_limit_usage | cut -f1 | tr '\n' ' ')" "" "no registry: only our own drops (none here)";

# ── 5: the 5th column is the winning reading's own time ────────────────────────────────────────────
reset_state
drop "$(_usage_dir)" main 70 $(( 31 * 60 ))
assert_eq "$(claude_limit_usage | awk -F'\t' '{print $5}')" "$(( now - 31 * 60 ))" "the adapter reports the reading's own at"

# ── 6: harness one reports the age of the reading that won ────────────────────────────────────────
source "$HERE/../scripts/one.sh"
reset_state
printf '{"prefix":"sib","project":"/p/sib","run_dir":"%s"}' "$FLEETS_SIB" > "$HARNESS_FLEETS_DIR/sib.json"
drop "$(_usage_dir)" main 70 $(( 30 * 3600 ))
drop "$FLEETS_SIB/usage" main 91 120
touch -d "@$(( now - 30 * 3600 ))" "$(_usage_dir)/main.json"
age="$(one_readings | head -1 | cut -f5)"
assert_ok "one_readings age is the sibling's (≈120s), not our drop's mtime (30h): got '$age'" \
  bash -c '[[ "'"$age"'" =~ ^[0-9]+$ ]] && (( '"$age"' >= 100 && '"$age"' <= 200 ))'
assert_eq "$(one_readings | head -1 | cut -f1-4 | cut -f1-3)" "$(printf 'main\tseven_day\t91')" "one_readings still reports the winning reading"
assert_eq "$(one_readings | head -1 | awk -F'\t' '{print NF}')" "6" "one_readings keeps its 6 columns"

finish

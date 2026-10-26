#!/usr/bin/env bash
# test_launch_argv.sh — #213: launch_agent must never put the task prompt in the agent's argv.
# The prompt used to be typed as `exec claude … "$(cat .harness-task.md)"`, so every lane's argv
# carried its full task text — and one lane's `pkill -f "rtdd run --base"` (a string every impl /
# bug-fix / resume prompt contains) killed every lane on the host in the same second. The launch
# line must carry only a fixed bootstrap prompt that points the agent at .harness-task.md by name.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
BOOT="${HARNESS_BOOTSTRAP_PROMPT:-<unset>}"

SENT_KEYS="$RUN_DIR/tmux_sent_keys"
tmux(){ [[ "$1" == has-session ]] && return 1
        if [[ "$1" == send-keys ]]; then shift; echo "$*" >> "$SENT_KEYS"; fi; return 0; }
sleep(){ :; }
log(){ :; }
ensure_trusted(){ :; }
ensure_bypass(){ :; }
ensure_usage_statusline(){ :; }

WD="$RUN_DIR/worktree"; mkdir -p "$WD"
printf 'You are a fixer.\nGOAL: fix UNIQUE_MARKER_123 then run rtdd run --base origin/main\n' > "$WD/.harness-task.md"
PROMISE="X DONE"; MAXITER=3; GOAL="BUG 213"

echo "=== claude launch ==="
: > "$SENT_KEYS"
( export HARNESS_CLI=claude CLAUDE_BIN=mock-claude CLAUDE_FLAGS="--fa --fb"
  launch_agent "sess-claude" "$WD" )
line="$(cat "$SENT_KEYS")"
assert_no "claude launch line carries no task text" grep -F -q UNIQUE_MARKER_123 <<<"$line"
assert_no "claude launch line does not interpolate the task file" grep -F -q 'cat .harness-task.md' <<<"$line"
assert_ok "claude launch line names .harness-task.md via the bootstrap prompt" \
  grep -F -q "\"$BOOT\"" <<<"$line"
assert_ok "bootstrap prompt references .harness-task.md" grep -F -q .harness-task.md <<<"$BOOT"
assert_ok "claude launch keeps --session-id <uuid> and CLAUDE_FLAGS" \
  grep -E -q 'exec mock-claude --session-id [0-9a-f-]{36} --fa --fb "' <<<"$line"
assert_ok "ralph state still holds the full task text" grep -F -q UNIQUE_MARKER_123 "$WD/.claude/ralph-loop.local.md"

echo "=== agy launch ==="
: > "$SENT_KEYS"
( export HARNESS_CLI=agy HARNESS_AGY_BIN=mock-agy HARNESS_AGY_FLAGS="--flag1 --flag2"
  launch_agent "sess-agy" "$WD" )
line="$(cat "$SENT_KEYS")"
assert_no "agy launch line carries no task text" grep -F -q UNIQUE_MARKER_123 <<<"$line"
assert_no "agy launch line does not interpolate the task file" grep -F -q 'cat .harness-task.md' <<<"$line"
assert_ok "agy launch keeps its flags and -i with the bootstrap prompt" \
  grep -F -q "exec mock-agy --flag1 --flag2 -i \"$BOOT\"" <<<"$line"

echo "=== real process: argv has no task text ==="
# Exec a stub agent the way the pane would (the recorded line, run by a shell in $WD) and look for
# the marker in its live argv. With the task interpolated, pgrep -f would find it.
# The stub waits on a fifo with the read builtin: no child process to orphan when it is killed.
STUB="$RUN_DIR/stub-agent"; mkfifo "$STUB.fifo"
printf '#!/usr/bin/env bash\nread -r -t 30 <> "%s"\n' "$STUB.fifo" > "$STUB"; chmod +x "$STUB"
: > "$SENT_KEYS"
( export HARNESS_CLI=claude CLAUDE_BIN="$STUB" CLAUDE_FLAGS=""
  launch_agent "sess-real" "$WD" )
line="$(cat "$SENT_KEYS")"; line="${line% Enter}"; line="${line#-t sess-real }"
( cd "$WD" && eval "$line" ) & pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -r /proc/$pid/cmdline ]] && grep -q -a stub-agent /proc/$pid/cmdline && break; command sleep 0.1; done
assert_ok "stub agent is running" grep -q -a stub-agent /proc/$pid/cmdline
marker_procs(){ pgrep -f UNIQUE_MARKER_123 >/dev/null; }   # pgrep never matches itself
assert_no "pgrep -f finds no process carrying the task marker" marker_procs
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

echo "=== prompts carry the PID-only kill rule ==="
for p in impl bug-fix resume bug-triage review inject; do
  assert_ok "prompts/$p.md forbids pattern kills" grep -F -q 'never `pkill -f`' "$HERE/../prompts/$p.md"
done

finish

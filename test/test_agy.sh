#!/usr/bin/env bash
# test_agy.sh — tests for Google Antigravity (agy) CLI support in Harness
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env

echo "=== Group 1: Config defaults ==="
assert_eq "$HARNESS_CLI" "claude" "default HARNESS_CLI is claude"
assert_eq "$HARNESS_AGY_BIN" "agy" "default HARNESS_AGY_BIN is agy"
assert_eq "$HARNESS_AGY_FLAGS" "--dangerously-skip-permissions --effort high" "default HARNESS_AGY_FLAGS"

echo "=== Group 2: Workspace trust ==="
# The agy adapter's trust (#188: agy reads "trustedWorkspaces" in its settings.json)
export HARNESS_AGY_TRUST_FILE="$RUN_DIR/agy-settings.json"
rm -f "$HARNESS_AGY_TRUST_FILE"
cli_with agy cli_trust "/path/to/repo1"
assert_ok "trust file created" test -f "$HARNESS_AGY_TRUST_FILE"
assert_ok "repo1 trusted" grep -q '"/path/to/repo1"' "$HARNESS_AGY_TRUST_FILE"
assert_ok "trust is a trustedWorkspaces entry" cli_with agy cli_trusted "/path/to/repo1"

# Add second path, ensure both exist
cli_with agy cli_trust "/path/to/repo2"
assert_ok "repo1 still trusted" grep -q '"/path/to/repo1"' "$HARNESS_AGY_TRUST_FILE"
assert_ok "repo2 trusted" grep -q '"/path/to/repo2"' "$HARNESS_AGY_TRUST_FILE"

# ensure_trusted routes to agy when HARNESS_CLI=agy
rm -f "$HARNESS_AGY_TRUST_FILE"
(
  export HARNESS_CLI=agy
  ensure_trusted "/path/to/repo3"
)
assert_ok "ensure_trusted with HARNESS_CLI=agy writes to agy trust file" \
  grep -q '"/path/to/repo3"' "$HARNESS_AGY_TRUST_FILE"

# ensure_trusted does NOT write to agy trust file when HARNESS_CLI=claude
rm -f "$HARNESS_AGY_TRUST_FILE"
(
  export HARNESS_CLI=claude
  export HARNESS_CLAUDE_CONFIG="$RUN_DIR/claude.json"
  ensure_trusted "/path/to/repo4"
)
assert_no "ensure_trusted with HARNESS_CLI=claude does not write to agy trust file" \
  test -f "$HARNESS_AGY_TRUST_FILE"
assert_ok "ensure_trusted with HARNESS_CLI=claude writes to claude config" \
  grep -q '"/path/to/repo4"' "$RUN_DIR/claude.json"

echo "=== Group 3: Agent launch ==="
# Stub tmux send-keys
SENT_KEYS="$RUN_DIR/tmux_sent_keys"
tmux(){
  if [[ "$1" == "has-session" ]]; then
    return 1
  fi
  if [[ "$1" == "send-keys" ]]; then
    shift
    echo "$*" >> "$SENT_KEYS"
  fi
  return 0
}

TASK_DIR="$RUN_DIR/worktree"
mkdir -p "$TASK_DIR"
echo "Test Task Content" > "$TASK_DIR/.harness-task.md"

# Stub sleep so test runs fast
sleep(){ :; }

# Test launch with claude
: > "$SENT_KEYS"
(
  export HARNESS_CLI=claude
  export CLAUDE_BIN="mock-claude"
  export CLAUDE_FLAGS=""
  launch_agent "sess-claude" "$TASK_DIR"
)
assert_ok "launch_agent for claude invokes CLAUDE_BIN with --session-id" \
  grep -F -q 'mock-claude --session-id' "$SENT_KEYS"

# Test launch_claude backward-compatibility alias
: > "$SENT_KEYS"
(
  export HARNESS_CLI=claude
  export CLAUDE_BIN="mock-claude"
  export CLAUDE_FLAGS=""
  launch_claude "sess-claude-alias" "$TASK_DIR"
)
assert_ok "launch_claude alias invokes CLAUDE_BIN" \
  grep -F -q 'mock-claude --session-id' "$SENT_KEYS"

# Test launch with agy
: > "$SENT_KEYS"
(
  export HARNESS_CLI=agy
  export HARNESS_AGY_BIN="mock-agy"
  export HARNESS_AGY_FLAGS="--flag1 --flag2"
  launch_agent "sess-agy" "$TASK_DIR"
)
assert_ok "launch_agent for agy invokes AGY_BIN with AGY_FLAGS and -i" \
  grep -F -q "mock-agy --flag1 --flag2 -i \"$HARNESS_BOOTSTRAP_PROMPT\"" "$SENT_KEYS"

echo "=== Group 4: Watchdog patterns ==="
# Test HARNESS_ACTIVE_TURN_RE via session_active_turn
assert_ok "matches Claude cancel" session_active_turn "esc to interrupt"
assert_ok "matches Claude background" session_active_turn "to run in background"
assert_ok "matches agy Generating..." cli_with agy session_active_turn "⣟  Generating..."

# Test idle prompt detection in session_limit_idle
assert_ok "session_limit_idle detects Claude ❯ prompt" session_limit_idle $'usage limit reached\n❯ '
assert_ok "session_limit_idle detects agy > prompt" cli_with agy session_limit_idle $'You have exhausted your quota on this model.\n> '

# Test stall detection in session_stalled
assert_ok "session_stalled detects Claude ❯ prompt on API Error" session_stalled $'API Error\n❯ '
assert_ok "session_stalled detects agy > prompt on its retry give-up" cli_with agy session_stalled $'Agent execution terminated due to error.\n> '

echo "=== Group 5: Setup & Start checks ==="
FAKE_BIN_DIR="$RUN_DIR/fake_bin"
mkdir -p "$FAKE_BIN_DIR"

# Test setup.sh with HARNESS_CLI=agy when agy is missing
(
  export PATH="$FAKE_BIN_DIR:/usr/bin:/bin"
  rm -f "$FAKE_BIN_DIR/agy"
  export HARNESS_CLI=agy
  out="$(bash "$HERE/../scripts/setup.sh" 2>&1 || true)"
  grep -q "missing agy" <<< "$out"
)
assert_ok "setup.sh warns on missing agy when HARNESS_CLI=agy" true

# Test setup.sh with HARNESS_CLI=agy when agy is present
touch "$FAKE_BIN_DIR/agy"
chmod +x "$FAKE_BIN_DIR/agy"
(
  export PATH="$FAKE_BIN_DIR:/usr/bin:/bin"
  export HARNESS_CLI=agy
  out="$(bash "$HERE/../scripts/setup.sh" 2>&1 || true)"
  ! grep -q "missing agy" <<< "$out"
)
assert_ok "setup.sh succeeds when agy is present" true

# Test start.sh with HARNESS_CLI=agy when agy is missing
(
  export PATH="$FAKE_BIN_DIR:/usr/bin:/bin"
  rm -f "$FAKE_BIN_DIR/agy"
  export HARNESS_CLI=agy
  out="$(bash "$HERE/../scripts/start.sh" 2>&1 || true)"
  grep -q "agy: command not found" <<< "$out"
)
assert_ok "start.sh errors when agy is missing" true

echo "=== Group 6: Status display ==="
tmux(){
  if [[ "$1" == "list-sessions" ]]; then
    echo "test-1: 1 windows"
  fi
  return 0
}
(
  export HARNESS_SESS_PREFIX="test"
  export HARNESS_CLI=agy
  out="$(bash "$HERE/../scripts/status.sh" 2>&1 || true)"
  grep -q "agy session(s) live" <<< "$out"
)
assert_ok "status.sh prints 'agy session(s) live' when HARNESS_CLI=agy" true

(
  export HARNESS_SESS_PREFIX="test"
  export HARNESS_CLI=claude
  out="$(bash "$HERE/../scripts/status.sh" 2>&1 || true)"
  grep -q "claude session(s) live" <<< "$out"
)
assert_ok "status.sh prints 'claude session(s) live' when HARNESS_CLI=claude" true

echo "=== Group 7: Stop hook execution ==="
HOOK="$HERE/../plugins/ralph-loop/hooks/stop-hook.sh"
assert_ok "stop-hook.sh is executable" test -x "$HOOK"

WORK_DIR="$RUN_DIR/hook_workspace"
mkdir -p "$WORK_DIR/.claude"
TRANSCRIPT="$RUN_DIR/transcript.txt"

# Case A: No loop file -> allow
res="$(printf '{"workspacePaths": ["%s"], "transcriptPath": "%s", "executionNum": 1}' "$WORK_DIR" "$TRANSCRIPT" | "$HOOK")"
assert_ok "hook allows when no loop file" grep -q '"decision": "allow"' <<< "$res"

# Case B: Loop file present, no promise -> continue
cat <<'EOF' > "$WORK_DIR/.claude/ralph-loop.local.md"
---
active: true
iteration: 1
maxIterations: 5
completionPromise: "TASK COMPLETED"
prompt: "Do the task"
---
EOF
echo "Working on task..." > "$TRANSCRIPT"
res="$(printf '{"workspacePaths": ["%s"], "transcriptPath": "%s", "executionNum": 1}' "$WORK_DIR" "$TRANSCRIPT" | "$HOOK")"
assert_ok "hook continues when promise not fulfilled" grep -q '"decision": "continue"' <<< "$res"
assert_ok "loop file still exists" test -f "$WORK_DIR/.claude/ralph-loop.local.md"

# Case C: Promise in transcript -> allow and unlink loop file
echo "Here is the result: <promise>TASK COMPLETED</promise>" > "$TRANSCRIPT"
res="$(printf '{"workspacePaths": ["%s"], "transcriptPath": "%s", "executionNum": 2}' "$WORK_DIR" "$TRANSCRIPT" | "$HOOK")"
assert_ok "hook allows when promise fulfilled" grep -q '"decision": "allow"' <<< "$res"
assert_no "loop file unlinked after completion" test -f "$WORK_DIR/.claude/ralph-loop.local.md"

# Case D: Max iterations reached -> allow and unlink loop file
cat <<'EOF' > "$WORK_DIR/.claude/ralph-loop.local.md"
---
active: true
iteration: 5
maxIterations: 5
completionPromise: "TASK COMPLETED"
prompt: "Do the task"
---
EOF
echo "Still working..." > "$TRANSCRIPT"
res="$(printf '{"workspacePaths": ["%s"], "transcriptPath": "%s", "executionNum": 5}' "$WORK_DIR" "$TRANSCRIPT" | "$HOOK")"
assert_ok "hook allows on max iterations" grep -q '"decision": "allow"' <<< "$res"
assert_no "loop file unlinked after max iterations" test -f "$WORK_DIR/.claude/ralph-loop.local.md"

# Case E (#188): a real agy 1.4 transcript. The agent read its task file, whose text names the
# promise; agy logs that read's output as source=MODEL type=GENERIC. Only the model's own replies
# (PLANNER_RESPONSE) may end the loop, and none of them output the promise.
loop_file(){ printf -- '---\nactive: true\niteration: 1\nmax_iterations: 4\ncompletion_promise: "ZEBRA DONE"\n---\n\nOnly on your THIRD reply output <promise>ZEBRA DONE</promise>.\n' > "$WORK_DIR/.claude/ralph-loop.local.md"; }
loop_file
AGY_TR="$HERE/fixtures/cli/agy/hook-transcript.jsonl"
res="$(printf '{"workspacePaths": ["%s"], "transcriptPath": "%s"}' "$WORK_DIR" "$AGY_TR" | "$HOOK")"
assert_ok "agy: the promise inside tool output does not end the loop" grep -q '"decision": "continue"' <<< "$res"
assert_ok "agy: loop file kept while the model has not output the promise" test -f "$WORK_DIR/.claude/ralph-loop.local.md"
# …and the same transcript with one more reply that DOES output it ends the loop.
loop_file
{ cat "$AGY_TR"; echo '{"step_index": 9, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "content": "<promise>ZEBRA DONE</promise>"}'; } > "$RUN_DIR/agy-done.jsonl"
res="$(printf '{"workspacePaths": ["%s"], "transcriptPath": "%s"}' "$WORK_DIR" "$RUN_DIR/agy-done.jsonl" | "$HOOK")"
assert_ok "agy: the model's own promise ends the loop" grep -q '"decision": "allow"' <<< "$res"
assert_no "agy: loop file removed on the model's promise" test -f "$WORK_DIR/.claude/ralph-loop.local.md"

echo "=== Group 8 (#256): usage cache, transient regex, session id ==="
AGY_FIX="$HERE/fixtures/cli/agy"
agy_usage_stub(){ printf '#!/bin/sh\nexec cat %q\n' "$2" > "$1"; chmod +x "$1"; }
# A worker that opened the cache before a refresh never reads it half written: the refresh lands as
# a new file renamed over it, so the open one still holds the whole old answer.
agy_usage_stub "$RUN_DIR/agy-usage-ok" "$AGY_FIX/usage-windows.json"
CACHE="$(_usage_dir)/agy.tsv"; mkdir -p "${CACHE%/*}"
printf 'old\tcache\t1\t0\n' > "$CACHE"; touch -d '1 hour ago' "$CACHE"
exec {rfd}<"$CACHE"
( unset HARNESS_USAGE_CMD; HARNESS_AGY_BIN="$RUN_DIR/agy-usage-ok" HARNESS_CLI=agy cli_limit_usage >/dev/null )
assert_eq "$(cat <&$rfd)" "$(printf 'old\tcache\t1\t0')" "agy usage cache: a reader holding the old cache is not rewritten under it"
exec {rfd}<&-
assert_eq "$(cut -f1-3 "$CACHE")" "$(cat "$AGY_FIX/usage-windows.expected")" "agy usage cache: the refresh replaces the cache"
assert_eq "$(compgen -G "$CACHE.*" | wc -l)" "0" "agy usage cache: no temp file left beside it"
# One bucket with a non-string reset_time drops that row, not every window.
rm -rf "$(_usage_dir)"
python3 - "$AGY_FIX/usage-windows.json" "$RUN_DIR/usage-bad-row.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["command"]["data"]["groups"][0]["buckets"][0]["reset_time"] = 12345
json.dump(d, open(sys.argv[2], "w"))
PY
agy_usage_stub "$RUN_DIR/agy-usage-bad" "$RUN_DIR/usage-bad-row.json"
got="$(unset HARNESS_USAGE_CMD; HARNESS_AGY_BIN="$RUN_DIR/agy-usage-bad" HARNESS_CLI=agy cli_limit_usage | cut -f1-3)"
assert_eq "$got" "$(sed 1d "$AGY_FIX/usage-windows.expected")" "agy usage: a bad reset_time skips its row and keeps the rest"

# agy's retry-in-progress status shows over the `>` input box: busy, never a transient give-up.
RETRYING="$(cat "$AGY_FIX/transient-retrying.txt")"
assert_no "agy transient regex: the retrying status does not match" grep -qE "$(cli_with agy cli_transient_re)" <<<"$RETRYING"
assert_ok "agy transient regex: the give-up line matches" grep -qE "$(cli_with agy cli_transient_re)" "$AGY_FIX/transient.txt"
assert_no "agy: a pane still retrying is not stalled" cli_with agy session_stalled "$RETRYING"
assert_ok "agy: a pane still retrying reads as busy" cli_with agy cli_pane_busy "$RETRYING"
# Without the bypass flag agy asks before a tool runs; its selected option sits at column 0 like the
# input box, and supervise must never type a nudge into it.
assert_no "agy: a tool-permission prompt is not the input prompt" cli_with agy cli_pane_prompt "$(cat "$AGY_FIX/permission.txt")"
# Trust as agy_trust writes it, seen on the host: the exact path opens with no dialog, while a
# directory under a trusted one still asks — so every worktree is trusted by its own path.
assert_no "agy: a worktree agy_trust pre-accepted opens with no trust dialog" grep -qE "$(cli_with agy cli_dialog_re)" "$AGY_FIX/bypass-subagent.txt"
assert_ok "agy: a directory under a trusted one still shows the trust dialog" grep -qE "$(cli_with agy cli_dialog_re)" "$AGY_FIX/trust-child-of-trusted.txt"

# The session id: the workspace's last conversation counts only when it started at or after this
# session's launch (write_state's started_at), so a relaunch never reports the previous one.
SID_WD="$RUN_DIR/sid-wd"; mkdir -p "$SID_WD"; echo task > "$SID_WD/.harness-task.md"
sid_conv(){ local t="$HARNESS_AGY_HOME/brain/$1/.system_generated/logs"; mkdir -p "$t" "$HARNESS_AGY_HOME/cache"
  printf '{"step_index":0,"created_at":"%s"}\n' "$2" > "$t/transcript.jsonl"
  printf '{"%s": "%s"}' "$SID_WD" "$1" > "$HARNESS_AGY_HOME/cache/last_conversations.json"; }
sid_conv prev-conv 2026-01-01T00:00:00Z
assert_eq "$(cli_with agy cli_session_id "$SID_WD" u1)" "prev-conv" "agy session id: no launch recorded, the mapped id stands"
write_state "$SID_WD" "" "" u1
assert_eq "$(cli_with agy cli_session_id "$SID_WD" u1)" "" "agy session id: right after a relaunch, the previous session's id is not reported"
sid_conv new-conv "$(date -u -d '+5 seconds' +%Y-%m-%dT%H:%M:%SZ)"
assert_eq "$(cli_with agy cli_session_id "$SID_WD" u1)" "new-conv" "agy session id: the conversation started since the launch is reported"

finish

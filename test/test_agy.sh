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
# Test _trust_agy_config
export HARNESS_AGY_TRUST_FILE="$RUN_DIR/trustedFolders.json"
rm -f "$HARNESS_AGY_TRUST_FILE"
_trust_agy_config "/path/to/repo1"
assert_ok "trust file created" test -f "$HARNESS_AGY_TRUST_FILE"
assert_ok "repo1 trusted" grep -q '"/path/to/repo1"' "$HARNESS_AGY_TRUST_FILE"

# Add second path, ensure both exist
_trust_agy_config "/path/to/repo2"
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
  grep -F -q 'mock-agy --flag1 --flag2 -i "$(cat .harness-task.md)"' "$SENT_KEYS"

echo "=== Group 4: Watchdog patterns ==="
# Test HARNESS_ACTIVE_TURN_RE via session_active_turn
assert_ok "matches Claude cancel" session_active_turn "esc to interrupt"
assert_ok "matches Claude background" session_active_turn "to run in background"
assert_ok "matches agy Generating..." session_active_turn "⣟  Generating..."

# Test idle prompt detection in session_limit_idle
assert_ok "session_limit_idle detects Claude ❯ prompt" session_limit_idle $'usage limit reached\n❯ '
assert_ok "session_limit_idle detects agy > prompt" session_limit_idle $'usage limit reached\n> '

# Test stall detection in session_stalled
assert_ok "session_stalled detects Claude ❯ prompt on API Error" session_stalled $'API Error\n❯ '
assert_ok "session_stalled detects agy > prompt on API Error" session_stalled $'API Error\n> '

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

finish

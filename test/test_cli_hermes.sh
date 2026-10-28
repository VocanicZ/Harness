#!/usr/bin/env bash
# test_cli_hermes.sh — PRD #189 / #263: the `hermes` adapter's own seams, beyond the shared matrix
# rows. Every fact asserted here is a row of docs/cli-capabilities.md § `hermes`, read off the
# fixtures in test/fixtures/cli/hermes/ (README.md there says how each was captured).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
cli_load hermes || exit 1
F="$HERE/fixtures/cli/hermes"; WD="$RUN_DIR/wd"; mkdir -p "$WD"; git -C "$WD" init -q; printf 'GOAL: x\n' > "$WD/.harness-task.md"
UUID=11111111-2222-3333-4444-555555555555
has(){ grep -qF -- "$1" <<<"$2"; }
lacks(){ ! grep -qF -- "$1" <<<"$2"; }
pane(){ cat "$F/$1.txt"; }
mkdir -p "$RUN_DIR/bin"; cat > "$RUN_DIR/bin/hermes" <<'STUB'
#!/usr/bin/env bash
echo "$HERMES_HOME $*" >> "$HERMES_CALLS"
STUB
chmod +x "$RUN_DIR/bin/hermes"; export PATH="$RUN_DIR/bin:$PATH" HERMES_CALLS="$RUN_DIR/hermes.calls"
# The operator's home: the runtime Hermes installed, its login, its config with a key a lane must keep.
OP="$HARNESS_HERMES_HOME"; mkdir -p "$OP/installs" "$OP/tools" "$OP/skills"
echo '{"version": 1}' > "$OP/auth.json"
printf 'model:\n  default: "gpt-4.1"\n  provider: "copilot"\n\nagent:\n  # keep this comment\n  disabled_toolsets:\n    - browser\n  max_turns: 90\n' > "$OP/config.yaml"
export HARNESS_USER_SKILLS="$RUN_DIR/user-skills"; mkdir -p "$HARNESS_USER_SKILLS"
H="$WD/.harness-hermes"; CFG="$H/config.yaml"
block(){ sed -n "/^$1:/,/^[^[:space:]#]/p" "$CFG" | grep -v "^[^[:space:]]" ; }

# --- the launch line and the lane's own home ------------------------------------------------------
line="$(cli_launch "$WD" "$UUID" anthropic/claude-sonnet-5.5 high)"
assert_ok "a lane has its own HERMES_HOME" has "exec env HERMES_HOME=$H hermes chat " "$line"
assert_ok "addressed by title, created if missing" has "-c $UUID --create-if-missing" "$line"
assert_ok "yolo and hooks accepted at launch" has '--yolo --accept-hooks' "$line"
assert_ok "first turn submitted with -q" has "-q \"$HARNESS_BOOTSTRAP_PROMPT\"" "$line"
assert_ok "no -m on the line (refused beside -c <title> --create-if-missing)" lacks ' -m ' "$line"
assert_ok "no --reasoning on the line (refused the same way)" lacks '--reasoning' "$line"
assert_ok "the lane's model is in its config" grep -qx '  default: "anthropic/claude-sonnet-5.5"' <(block model)
assert_ok "…the operator's provider kept" grep -qx '  provider: "copilot"' <(block model)
assert_ok "the lane's effort is in its config" grep -qx '  reasoning_effort: "high"' <(block agent)
assert_ok "approvals off for the whole lane profile" grep -qx '  mode: off' <(block approvals)
assert_ok "the clarify toolset is off" grep -qxF '  disabled_toolsets: ["clarify"]' <(block agent)
assert_no "…replacing the operator's list, every line of it" grep -qx '    - browser' <(block agent)
assert_ok "…the operator's other agent keys kept" grep -qx '  max_turns: 90' <(block agent)
assert_ok "…and its comments" grep -qx '  # keep this comment' <(block agent)
assert_ok "no update checks in a lane" grep -qx '  check: false' <(block updates)
assert_ok "Harness's user skills are an external skills dir" grep -qxF "  external_dirs: [\"$HARNESS_USER_SKILLS\"]" <(block skills)
assert_eq "$(cli_lane_settings "$WD")" $'model.default=anthropic/claude-sonnet-5.5\nagent.reasoning_effort=high' "the lane settings the launch event records"
assert_eq "$(readlink "$H/installs"):$(readlink "$H/tools"):$(readlink "$H/skills")" "$OP/installs:$OP/tools:$OP/skills" "the runtime and skills are linked from the operator's home"
assert_ok "the operator's stored login is copied" cmp -s "$OP/auth.json" "$H/auth.json"
assert_eq "$(git -C "$WD" status --porcelain -- .harness-hermes)" "" "the lane's home is never committed"
assert_eq "$(cat "$H/.gitignore")" "*" "…ignored by its own .gitignore, whatever the worktree's exclude says"
assert_ok "…kept out by info/exclude as well" grep -qxF '.harness-hermes/' "$(git -C "$WD" rev-parse --absolute-git-dir)/info/exclude"
cli_launch "$WD" "$UUID" "" "" >/dev/null
assert_ok "a relaunch with no model takes the operator's again" grep -qx '  default: "gpt-4.1"' <(block model)
assert_eq "$(cli_lane_settings "$WD")" "" "…and records no lane settings"

# --- trust: the lane config's skills.trusted_project_dirs, kept across relaunches -----------------
cli_trust "$WD"; cli_trust "$WD"
assert_ok "the worktree's skills are trusted" cli_trusted "$WD"
assert_eq "$(grep -c '^  trusted_project_dirs: ' "$CFG")" 1 "…once"
cli_launch "$WD" "$UUID" "" "" >/dev/null
assert_ok "…and still after a relaunch" cli_trusted "$WD"
assert_no "another worktree is not" cli_trusted "$RUN_DIR/other"

# --- send, kill ------------------------------------------------------------------------------------
TMUXLOG="$RUN_DIR/tmux.log"; : > "$TMUXLOG"
tmux(){ echo "tmux $*" >> "$TMUXLOG"; }; sleep(){ echo "sleep $*" >> "$TMUXLOG"; }
cli_send sess-x "$WD" "Please continue — x"
assert_eq "$(cat "$TMUXLOG")" $'tmux send-keys -t sess-x -l Please continue — x\nsleep 0.5\ntmux send-keys -t sess-x Enter' \
  "the Enter waits for the text to land (a same-burst Enter is a newline in the composer)"
: > "$TMUXLOG"
cli_kill sess-x "$WD"
assert_ok "kill stops the lane's gateway, which outlives the pane" grep -qxF "$H gateway stop -y" "$HERMES_CALLS"
assert_eq "$(cat "$TMUXLOG")" "tmux kill-session -t sess-x" "…once the pane is gone (a live TUI starts a new gateway)"
: > "$HERMES_CALLS"; cli_kill sess-y "$RUN_DIR/no-such-wd"
assert_eq "$(cat "$HERMES_CALLS")" "" "a session with no lane home stops no gateway"
unset -f tmux sleep

# --- panes ----------------------------------------------------------------------------------------
assert_eq "$(cli_loop)" driven "no Stop hook Harness can block: Harness drives"
assert_eq "$(cli_skill handoff)" handoff "a skill is named, not slashed (Hermes's own /handoff shadows it)"
assert_eq "$(cli_turn_secs "$(pane busy)")" 18 "turn time off the busy top rule"
assert_eq "$(cli_turn_secs "$(pane busy-retrying)")" 47 "…or the status bar's ⏱ when the rule is truncated"
assert_eq "$(cli_turn_secs "$(pane idle)")" 0 "no turn at the idle prompt"
assert_eq "$(cli_turn_secs '── ⠸ 💻 make test · 1h 5m · ↓ 3 tok ──')" 3900 "hours and minutes"
assert_eq "$(cli_turn_secs '── ⠸ thinking · 2m ──── title ─')" 120 "minutes"
not_prompt_line(){ [[ "$(cli_pane_prompt_line "$(pane busy)")" == 0 ]]; }
assert_ok "an echoed prompt in the scrollback is no prompt" not_prompt_line
assert_eq "$(turn_queued "$(pane busy-typed)")" "" "text typed under a running turn is not queued (Enter redirects the turn: steer.txt)"
assert_ok "the busy composer is busy" cli_pane_busy "$(pane busy-typed)"
assert_ok "a limit that names its reset parks" session_limit_idle "$(pane limit)"
assert_ok "a 503 after every retry stalls" session_stalled "$(pane transient)"
assert_ok "the interrupted turn's pane is idle" cli_pane_prompt "$(pane interrupted)"
assert_no "…and not busy" cli_pane_busy "$(pane interrupted)"

# --- the driven loop's reply (state.db) -----------------------------------------------------------
DB="$H/state.db"; cp "$F/transcript.db" "$DB"; SID="$(cli_session_id "$WD" "$(cat "$F/session")")"
assert_ok "the session is found by its title" has local- "$SID"
replies(){ cli_last_reply "$@" >/dev/null; }
sql(){ python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2], sys.argv[3:]); c.commit()' "$DB" "$@"; }
reply="$(cli_last_reply "$WD" "$SID")"
assert_eq "$(tail -n +2 <<<"$reply")" "<promise>CAP DONE</promise>" "the reply that ended the last prompt's turn"
assert_eq "$(head -1 <<<"$reply")" "$(python3 -c 'import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT max(id) FROM messages WHERE session_id = ? AND role = ?", (sys.argv[2], "user")).fetchone()[0])' "$DB" "$SID")" \
  "…after the id of that prompt (here the message a finished delegation injected)"
sql "INSERT INTO session_turn_leases VALUES (?, 'pid=1', ?, ?)" "$SID" "$(date +%s)" "$(( $(date +%s) + 300 ))"
assert_no "no reply while the gateway holds the turn's lease" replies "$WD" "$SID"
sql "UPDATE session_turn_leases SET expires_at = 1"
assert_ok "…a lapsed lease holds nothing" replies "$WD" "$SID"
sql "UPDATE async_delegations SET completed_at = NULL, owner_pid = ?" "$$"
assert_no "no reply while a background delegation it dispatched still runs" replies "$WD" "$SID"
sql "UPDATE async_delegations SET owner_pid = 999999999"
assert_ok "…one whose owner died holds nothing" replies "$WD" "$SID"
sql "INSERT INTO messages (session_id, role, content, timestamp, active) VALUES (?, 'user', 'go on', 1, 1)" "$SID"
assert_no "a prompt not yet answered has no reply" replies "$WD" "$SID"
sql "INSERT INTO messages (session_id, role, content, timestamp, finish_reason, display_kind, active) VALUES (?, 'assistant', 'Your request was not processed.', 2, NULL, 'failed_turn', 1)" "$SID"
assert_no "a failed turn is the watchdog's" replies "$WD" "$SID"
sql "INSERT INTO messages (session_id, role, content, timestamp, active) VALUES (?, 'user', 'again', 3, 1)" "$SID"
sql "INSERT INTO messages (session_id, role, content, timestamp, finish_reason, display_kind, active) VALUES (?, 'assistant', '', 4, NULL, 'hidden', 1)" "$SID"
assert_no "…so is an interrupted one" replies "$WD" "$SID"

# --- transcripts + usage: the session's own, then its delegate_task child's ------------------------
cp "$F/bypass-subagent.db" "$DB"
mapfile -t ts < <(cli_transcripts "$WD" "$SID")
assert_eq "${#ts[@]}" 2 "the session and its sub-agent"
assert_eq "$(cli_usage "${ts[@]}")" $'gpt-4.1\t19650\t357\t68608\t0' "usage sums every transcript's session_model_usage"

col="$(bash "$HERE/test_cli_matrix.sh" --tsv | awk -F'\t' '$1=="hermes" && $3!="ok" && $3 !~ /^n\/a:/')"
assert_eq "$col" "" "every hermes matrix cell is ok or n/a"
finish

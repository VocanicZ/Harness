#!/usr/bin/env bash
# test_cli_openclaw.sh — PRD #189 / #264: the `openclaw` adapter's own seams, beyond the shared
# matrix rows. Every fact asserted here is a row of docs/cli-capabilities.md § `openclaw`, read off
# the fixtures in test/fixtures/cli/openclaw/ (README.md there says how each was captured).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
cli_load openclaw || exit 1
F="$HERE/fixtures/cli/openclaw"; WD="$RUN_DIR/wd"; mkdir -p "$WD"; git -C "$WD" init -q; printf 'GOAL: UNIQUE_TASK_MARKER\n' > "$WD/.harness-task.md"
LOOP="$HERE/../scripts/cli/openclaw-loop.sh"
UUID=11111111-2222-3333-4444-555555555555
has(){ grep -qF -- "$1" <<<"$2"; }
lacks(){ ! grep -qF -- "$1" <<<"$2"; }
pane(){ cat "$F/$1.txt"; }
# screen <loop output> — what the pane shows of it: the loop clears the screen at each turn's start and end.
screen(){ printf '%s\n' "${1##*$'\e[3J'}"; }
# The stub `openclaw`: each call's argv and message file, then the envelope $OC_ENVELOPE (a file;
# empty = none), exiting $OC_RC.
mkdir -p "$RUN_DIR/bin"; cat > "$RUN_DIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$OC_CALLS"
while (( $# )); do [[ $1 == --message-file ]] && cat "$2" >> "$OC_MSGS"; shift; done
[[ -s ${OC_ENVELOPE:-} ]] && cat "$OC_ENVELOPE"
exit "${OC_RC:-0}"
STUB
chmod +x "$RUN_DIR/bin/openclaw"; export PATH="$RUN_DIR/bin:$PATH" OC_CALLS="$RUN_DIR/oc.calls" OC_MSGS="$RUN_DIR/oc.msgs"
ENV1="$RUN_DIR/envelope.json"; head -1 "$F/transcript.jsonl" > "$ENV1"; export OC_ENVELOPE="$ENV1"
# The operator's config and the user skills Harness installs: a skills dir with a SKILL.md of its own,
# as ~/.claude/skills has.
OP="$RUN_DIR/op/openclaw.json"; mkdir -p "${OP%/*}"; export HARNESS_OPENCLAW_CONFIG="$OP"
printf '{"agents": {"defaults": {"model": {"primary": "claude-cli/claude-haiku-5-5"}}}, "skills": {"load": {"extraDirs": ["/opt/team-skills"]}}}\n' > "$OP"
export HARNESS_USER_SKILLS="$RUN_DIR/user-skills" HARNESS_OPENCLAW_AGENTS_SKILLS="$RUN_DIR/no-agents-skills"; mkdir -p "$HARNESS_USER_SKILLS/handoff" "$HARNESS_USER_SKILLS/rtdd"
touch "$HARNESS_USER_SKILLS/SKILL.md" "$HARNESS_USER_SKILLS/handoff/SKILL.md" "$HARNESS_USER_SKILLS/rtdd/SKILL.md"
CFG="$WD/.harness-openclaw/openclaw.json"
cfg(){ python3 -c 'import json, sys; d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[k]
print(json.dumps(d))' "$CFG" "$1" 2>/dev/null; }

# --- the launch line and the lane config ------------------------------------------------------------
line="$(cli_launch "$WD" "$UUID" claude-cli/claude-sonnet-5-5 high)"
assert_ok "the pane runs Harness's loop, not the TUI" has "bash $(printf '%q' "$(cd "$HERE/../scripts/cli" && pwd)/openclaw-loop.sh") " "$line"
assert_ok "…in the worktree" has "--cwd $(printf '%q' "$WD") " "$line"
assert_ok "…its session the launch's own id" has "--run $UUID " "$line"
assert_ok "the lane's model" has '--model claude-cli/claude-sonnet-5-5 ' "$line"
assert_ok "the lane's effort as --thinking" has '--thinking high ' "$line"
assert_ok "…spelled as the matrix's effort-flag fixture says" has "$(cat "$F/effort-flag")high " "$line"
assert_ok "a turn may run for hours (agent exec's own default is 600s)" has "--timeout $HARNESS_OPENCLAW_TIMEOUT " "$line"
assert_ok "the bootstrap is the first message" has "\"$HARNESS_BOOTSTRAP_PROMPT\"" "$line"
assert_ok "…never the task" lacks UNIQUE_TASK_MARKER "$line"
assert_ok "the lane config may include the operator's from outside its dir" has "OPENCLAW_INCLUDE_ROOTS=$(printf '%q' "${OP%/*}") " "$line"
assert_ok "the turn runs on the lane config" has "--config $(printf '%q' "$CFG")" "$line"
assert_eq "$(cfg '$include')" "\"$OP\"" "the lane config includes the operator's (model, auth, plugins)"
assert_eq "$(cfg tools.exec)" '{"mode": "full"}' "…with host exec running unasked over it"
assert_eq "$(cfg skills.load.extraDirs)" "[\"/opt/team-skills\", \"$HARNESS_USER_SKILLS/handoff\", \"$HARNESS_USER_SKILLS/rtdd\"]" \
  "the operator's extra skill dirs, then each user skill Harness installs (a dir with its own SKILL.md reads as one skill)"
assert_ok "the lane is bypassed" cli_bypassed "$WD"
nolane="$(cli_launch "$WD" "$UUID" "" "")"
assert_ok "no lane model: the operator config's default" lacks '--model' "$nolane"
assert_ok "no lane effort: no --thinking" lacks '--thinking' "$nolane"
assert_eq "$(git -C "$WD" status --porcelain | grep -v harness-task)" "" "the lane's run state is kept out of its commits"
printf '{\n  // JSON5\n  agents: {}\n}\n' > "$OP"; cli_launch "$WD" "$UUID" "" "" >/dev/null
assert_eq "$(cfg skills.load.extraDirs)" "[\"$HARNESS_USER_SKILLS/handoff\", \"$HARNESS_USER_SKILLS/rtdd\"]" "an operator config that is JSON5 is still included, its own extra dirs unread"
rm -f "$OP"; cli_launch "$WD" "$UUID" "" "" >/dev/null
assert_eq "$(cfg '$include')" "" "no operator config: nothing to include"
assert_ok "…and the lane still bypassed" cli_bypassed "$WD"
echo '{"tools": {"exec": {"mode": "ask"}}}' > "$CFG"
assert_no "a lane config that asks is not bypassed" cli_bypassed "$WD"
cli_bypass "$WD"
assert_ok "…until cli_bypass rewrites it" cli_bypassed "$WD"

# --- the loop: one `agent exec` per message ----------------------------------------------------------
: > "$OC_CALLS"; : > "$OC_MSGS"
out="$(printf 'Please continue — nudge\n\n🔄 Ralph iteration 2 | next\n' | bash "$LOOP" --bin openclaw --cwd "$WD" --run "$UUID" --config "$CFG" \
  --model m/x --thinking low --timeout 99 "$HARNESS_BOOTSTRAP_PROMPT" 2>&1)"
assert_eq "$(grep -c 'agent exec' "$OC_CALLS")" 3 "one agent exec per message: the bootstrap, then each line typed (a blank one is none)"
assert_ok "each is scoped to the worktree" grep -qF -- "--cwd $WD " "$OC_CALLS"
assert_ok "…keeps its state in the worktree's run dir" grep -qF -- "--state-dir $WD/.harness-openclaw " "$OC_CALLS"
assert_ok "…runs on the lane config, model, effort and timeout" grep -qF -- "agent exec --config $CFG --cwd $WD --state-dir $WD/.harness-openclaw --model m/x --thinking low --timeout 99 --message-file " "$OC_CALLS"
assert_ok "…and prints its JSON envelope" grep -qE -- '--json$' "$OC_CALLS"
assert_ok "a message goes in a file, never in argv" lacks "$HARNESS_BOOTSTRAP_PROMPT" "$(cat "$OC_CALLS")"
assert_eq "$(cat "$OC_MSGS")" "$HARNESS_BOOTSTRAP_PROMPT"$'\nPlease continue — nudge\n🔄 Ralph iteration 2 | next' "…the bootstrap, then each line as typed"
RUNS="$WD/.harness-openclaw/runs/$UUID.jsonl"
assert_eq "$(grep -c . "$RUNS")" 3 "each turn's envelope is a line of the session's transcript"
assert_eq "$(cli_transcripts "$WD" "$UUID")" "$RUNS" "…which cli_transcripts finds by the launch's id"
assert_eq "$(grep -o 'harness-openclaw ❯ ' <<<"$out" | wc -l)" 4 "the prompt after each turn, and once more before the input ends"
assert_ok "the reply is shown above it" has "STILL WORKING" "$(screen "$out")"
assert_no "…on a screen the busy line is gone from" cli_pane_busy "$(screen "$out")"
assert_no "no turn left running" test -e "$WD/.harness-openclaw/running"
# A failed turn: its error line is what the pane regexes read; no envelope at all is still a turn.
rm -f "$RUNS"
python3 -c 'import json; print(json.dumps({"ok": False, "status": "error", "final": "", "error": {"message": "\u26a0\ufe0f The AI service needs a short break. Please try again in a few minutes.", "kind": "exception"}}))' > "$RUN_DIR/limit.json"
out="$(OC_ENVELOPE="$RUN_DIR/limit.json" OC_RC=1 bash "$LOOP" --bin openclaw --cwd "$WD" --run "$UUID" go </dev/null 2>&1)"
assert_ok "a limit-failed turn prints OpenClaw's own copy where cli_limit_re reads it" session_limit_idle "$(screen "$out")"
out="$(OC_ENVELOPE= OC_RC=7 bash "$LOOP" --bin openclaw --cwd "$WD" --run "$UUID" go </dev/null 2>&1)"
assert_ok "a turn with no envelope prints why" has 'harness-openclaw: error: openclaw agent exec exited 7 with no JSON envelope' "$out"
assert_eq "$(grep -c . "$RUNS")" 2 "…and is recorded all the same"
out="$(bash "$LOOP" --bin "env OC_RC=0 openclaw" --cwd "$WD" --run r2 go </dev/null 2>&1)"
assert_ok "--bin is a command line (HARNESS_OPENCLAW_BIN, #272)" test -s "$WD/.harness-openclaw/runs/r2.jsonl"

# The pane's hangup reaches the loop, which stops the running turn's whole tree.
cat > "$RUN_DIR/bin/openclaw-slow" <<'STUB'
#!/usr/bin/env bash
sleep 41 & echo $! > "$OC_KID"; sleep 42
STUB
chmod +x "$RUN_DIR/bin/openclaw-slow"; export OC_KID="$RUN_DIR/oc.kid"
bash "$LOOP" --bin openclaw-slow --cwd "$WD" --run r3 go </dev/null >/dev/null 2>&1 & LP=$!
for i in $(seq 50); do [[ -s $OC_KID ]] && break; sleep 0.1; done
kill -HUP "$LP"; wait "$LP" 2>/dev/null; sleep 0.3
assert_no "a hangup of the pane's loop stops the turn's whole tree" kill -0 "$(cat "$OC_KID")"

# --- the driven loop's reply (runs/<id>.jsonl) -------------------------------------------------------
rm -f "$RUNS"
replies(){ cli_last_reply "$@" >/dev/null; }
assert_no "no reply before the first turn ends" replies "$WD" "$UUID"
"$F/turn-end" "$WD" "$UUID" "STILL WORKING"
reply="$(cli_last_reply "$WD" "$UUID")"
assert_eq "$(tail -n +2 <<<"$reply")" "STILL WORKING" "the reply that ended the last turn"
assert_ok "…after an id unique to that turn" grep -qxE '1:[0-9a-f-]{36}' <<<"$(head -1 <<<"$reply")"
sleep 30 & SL=$!; echo "$SL" > "$WD/.harness-openclaw/running"
assert_no "no reply while a turn runs" replies "$WD" "$UUID"
kill "$SL" 2>/dev/null; wait "$SL" 2>/dev/null
assert_ok "…a dead turn's pid holds nothing" replies "$WD" "$UUID"
rm -f "$WD/.harness-openclaw/running"
tail -1 "$F/limit-runs.jsonl" >> "$RUNS"
assert_no "a limit-failed turn is the watchdog's" replies "$WD" "$UUID"
tail -1 "$F/transient-runs.jsonl" >> "$RUNS"
assert_no "…so is a transient one" replies "$WD" "$UUID"
python3 -c 'import json; print(json.dumps({"ok": False, "status": "error", "final": "", "sessionId": "s9", "error": {"message": "No route-compatible authentication source is configured for openai.", "kind": "exception"}}))' >> "$RUNS"
assert_eq "$(cli_last_reply "$WD" "$UUID")" $'4:s9\nNo route-compatible authentication source is configured for openai.' \
  "any other failure is the turn's reply: the loop counts it and goes on (max-iter ends it)"

# --- send, kill ------------------------------------------------------------------------------------
TMUXLOG="$RUN_DIR/tmux.log"; : > "$TMUXLOG"
tmux(){ echo "tmux $*" >> "$TMUXLOG"; }
cli_send sess-x "$WD" "HARNESS CHECKPOINT — test"
assert_eq "$(cat "$TMUXLOG")" $'tmux send-keys -t sess-x -l HARNESS CHECKPOINT — test\ntmux send-keys -t sess-x Enter' \
  "a checkpoint is typed at the loop's prompt: the next turn's message"
: > "$TMUXLOG"; ( sleep 31 & sleep 30; wait ) & SL=$!; echo "$SL" > "$WD/.harness-openclaw/running"; sleep 0.3
kids="$(ps -o pid= --ppid "$SL" | xargs)"
cli_kill sess-x "$WD"
assert_eq "$(cat "$TMUXLOG")" "tmux kill-session -t sess-x" "kill ends the pane"
wait "$SL" 2>/dev/null; rc=$?
assert_eq "$rc" 143 "…and the turn it was running"
gone(){ local p; for p in $kids; do kill -0 "$p" 2>/dev/null && return 1; done; return 0; }
sleep 0.3
assert_ok "…with every process under it (the CLI backend, the turn's commands)" gone
unset -f tmux; rm -f "$WD/.harness-openclaw/running"

# --- panes ----------------------------------------------------------------------------------------
assert_eq "$(cli_loop)" driven "Harness drives every turn"
assert_eq "$(cli_skill handoff)" handoff "a skill is named (skill.txt)"
assert_eq "$(cli_skill handoff)" "$(cat "$F/handoff-skill")" "…as the matrix's handoff-skill fixture says"
assert_eq "$(cli_turn_secs "$(pane busy)")" "" "the loop draws no turn timer"
assert_ok "text typed under a running turn: still busy (busy-typed.txt)" cli_pane_busy "$(pane busy-typed)"
assert_eq "$(turn_queued "$(pane busy-typed)")" "" "…nothing queued in an input box (the terminal holds it for the next turn)"
assert_ok "a 429 that names a usage limit parks (limit.txt)" session_limit_idle "$(pane limit)"
assert_ok "a 429 with OpenClaw's own copy parks too (limit-short-break.txt)" session_limit_idle "$(pane limit-short-break)"
assert_no "…and never stalls" session_stalled "$(pane limit-short-break)"
assert_ok "a 503 after OpenClaw's retries stalls (transient.txt)" session_stalled "$(pane transient)"
not_limit(){ ! session_limit_idle "$1"; }
assert_ok "a reply quoting an error is no error" not_limit "$(printf 'The AI service needs a short break, it said.\nharness-openclaw ❯ ')"
assert_ok "…not even OpenClaw's own copy at column 0" not_limit "$(printf '⚠️ The AI service needs a short break.\nharness-openclaw ❯ ')"

# --- usage: per <provider>/<model>, every turn's envelope -------------------------------------------
assert_eq "$(cli_usage "$F/transcript.jsonl")" "$(cat "$F/usage.expected")" "usage folds the transcript's envelopes"
assert_eq "$(cli_usage "$F/transcript.jsonl" "$F/limit-runs.jsonl")" "$(cat "$F/usage.expected")" "…a failed turn has none"
assert_eq "$(cut -f1 "$F/usage.expected")" "$(cat "$F/model")" "…under the model the matrix launches with, as --model names it"
# The captured transcript is the lane's runs/<session>.jsonl: the launch's id finds it, and the CLI's
# session id is that same id.
SID="$(cat "$F/session")"; cp "$F/transcript.jsonl" "$WD/.harness-openclaw/runs/$SID.jsonl"
assert_eq "$(cli_session_id "$WD" "$SID")" "$SID" "the session id is the launch's own (the matrix's session fixture)"
assert_eq "$(cli_usage $(cli_transcripts "$WD" "$SID"))" "$(cat "$F/usage.expected")" "…whose transcript cli_transcripts finds and cli_usage folds"

col="$(bash "$HERE/test_cli_matrix.sh" --tsv | awk -F'\t' '$1=="openclaw" && $3!="ok" && $3 !~ /^n\/a:/')"
assert_eq "$col" "" "every openclaw matrix cell is ok or n/a"
finish

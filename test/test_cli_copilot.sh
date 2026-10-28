#!/usr/bin/env bash
# test_cli_copilot.sh — PRD #189 / #259: the `copilot` adapter's own seams, beyond the shared matrix rows.
# Every fact asserted here is a row of docs/cli-capabilities.md § `copilot`, read off the fixtures in
# test/fixtures/cli/copilot/ (README.md there says how each was captured).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
cli_load copilot || exit 1
F="$HERE/fixtures/cli/copilot"; WD="$RUN_DIR/wd"; mkdir -p "$WD"; printf 'GOAL: x\n' > "$WD/.harness-task.md"
UUID=11111111-2222-3333-4444-555555555555
has(){ grep -qF -- "$1" <<<"$2"; }
pane(){ cat "$F/$1.txt"; }
# fake_tmux — tmux as the watchdog drives it, each call one line of $TMUXLOG: the pane shows $FAKE_PANE.
fake_tmux(){ export TMUXLOG="$RUN_DIR/tmux.$BASHPID"; : > "$TMUXLOG"; FAKE_PANE="$F/idle.txt"
  tmux(){ local IFS=$'\t'; printf '%s\n' "$*" >> "$TMUXLOG"; [[ $1 == capture-pane ]] && cat "$FAKE_PANE"; return 0; }; }
sent_text(){ awk -F'\t' -v s="$1" '$1 == "send-keys" && $3 == s && $4 == "-l" { print $5 }' "$TMUXLOG"; }
export COPILOT_HOME="$RUN_DIR/copilot-home"; mkdir -p "$COPILOT_HOME"

# --- the launch line -----------------------------------------------------------------------------
line="$(cli_launch "$WD" "$UUID" claude-sonnet-5.5 high)"
assert_ok "caller-set session id" has "--session-id=$UUID" "$line"
assert_ok "effort flag" has '--effort=high' "$line"
assert_ok "model flag" has '--model=claude-sonnet-5.5' "$line"
assert_ok "everything allowed" has '--yolo' "$line"
assert_ok "the agent may not stop on a question" has '--no-ask-user' "$line"
assert_ok "no update mid-fleet" has '--no-auto-update' "$line"
assert_ok "the bootstrap is the -i prompt" has "-i \"$HARNESS_BOOTSTRAP_PROMPT\"" "$line"
assert_ok "an operator's COPILOT_HOME reaches the pane" has "COPILOT_HOME=$COPILOT_HOME exec copilot " "$line"
assert_eq "$(env -u COPILOT_HOME bash -c 'source "$1"; cli_load copilot; cli_launch /wd u "" ""' _ "$HERE/../scripts/lib.sh")" \
  "exec copilot --session-id=u --yolo --no-ask-user --no-auto-update -i \"$HARNESS_BOOTSTRAP_PROMPT\"" \
  "no COPILOT_HOME, no lane model/effort: the configured flags as they are"
line="$(HARNESS_COPILOT_FLAGS='--yolo --model=auto --reasoning-effort=low' cli_launch "$WD" "$UUID" gpt-5.5 max)"
assert_eq "$(grep -oE -- '--(model|effort|reasoning-effort)=' <<<"$line" | sort | uniq -c | xargs)" "1 --effort= 1 --model=" \
  "the lane's model and effort replace the configured ones (--reasoning-effort is effort's alias)"

# --- workspace trust in config.json (JSON behind // comment lines) ------------------------------
cat > "$COPILOT_HOME/config.json" <<'EOF'
// User settings belong in settings.json.
// This file is managed automatically.
{
  "firstLaunchAt": "2026-10-28T02:27:01.208Z",
  "trustedFolders": [
    "/elsewhere"
  ]
}
EOF
cli_trust "$WD"
assert_ok "trust is a trustedFolders entry" \
  python3 -c 'import json,sys; body="".join(l for l in open(sys.argv[1]) if not l.startswith("//")); assert sys.argv[2] in json.loads(body)["trustedFolders"]' "$COPILOT_HOME/config.json" "$WD"
assert_ok "cli_trusted reads it back" cli_trusted "$WD"
assert_no "another dir is not trusted by it" cli_trusted "$RUN_DIR/other"
assert_ok "the comment header is kept" grep -qx '// This file is managed automatically.' "$COPILOT_HOME/config.json"
assert_ok "every other key is kept" grep -qF '"firstLaunchAt": "2026-10-28T02:27:01.208Z"' "$COPILOT_HOME/config.json"
assert_ok "…and every other folder" cli_trusted /elsewhere
cli_trust "$WD"
assert_eq "$(grep -cF "\"$WD\"" "$COPILOT_HOME/config.json")" 1 "trusting twice writes one entry"
rm -f "$COPILOT_HOME/config.json"; cli_trust "$WD"
assert_ok "a fresh home gets a config.json with the entry" cli_trusted "$WD"
assert_ok "trust takes the lock file the CLI keeps beside config.json" test -f "$COPILOT_HOME/config.json.trusted-folders.lock"
not_prompt(){ ! cli_pane_prompt "$1"; }
assert_ok "the trust dialog is not the prompt" not_prompt "$(pane trust)"

# --- panes ---------------------------------------------------------------------------------------
assert_ok "busy fixture is busy" grep -qE "$(cli_busy_re)" "$F/busy.txt"
assert_ok "a turn before its first tool call is busy" cli_pane_busy "$(pane busy-start)"
assert_ok "the first Escape's hint is still busy" cli_pane_busy "$(sed 's/esc esc interrupt/esc again to interrupt/' "$F/busy.txt")"
assert_ok "an interrupted turn prints its line" grep -qE "$(cli_interrupted_re)" "$F/interrupted.txt"
assert_ok "…and is back at the prompt" cli_pane_prompt "$(pane interrupted)"
assert_eq "$(cli_pane_prompt_line "$(pane steer)")" "$(grep -n '^❯' "$F/steer.txt" | cut -d: -f1)" "the prompt line is the box's, not the echo above it"
assert_eq "$(turn_queued "$(pane steer)")" "" "text typed mid-turn is steered into it, never queued in the box"
assert_ok "the rate-limit menu is a limit menu" session_limit_menu "Rate limit hit. Switch to the auto model?"
assert_ok "…and a dialog, never a prompt" not_prompt "$(pane idle)"$'\n Rate limit hit. Switch to the auto model?'
assert_eq "$(cli_turn_secs "$(pane busy)")" "" "copilot draws no turn timer"
assert_eq "$(cli_skill handoff)" "/handoff" "a skill is a slash command (skill.txt)"
assert_eq "$(cat "$F/handoff-skill")" "$(cli_skill handoff)" "…as the matrix's handoff-skill fixture says"
assert_ok "…as the capture ran one" grep -qF 'skill(echo-proof)' "$F/skill.txt"

# --- transcripts, usage, the driven loop ---------------------------------------------------------
assert_eq "$(cli_loop)" driven "agentStop caps at 8 blocks, below HARNESS_IMPL_MAXITER: Harness drives"
assert_eq "$(cli_session_id "$WD" "$UUID")" "$UUID" "the session id is the one the launch set"
assert_ok "the captured session id is the loop run's session.start" grep -qF "\"sessionId\": \"$(cat "$F/session")\"" "$F/transcript.jsonl"
assert_eq "$(cli_transcripts "$WD" "$UUID")" "" "no transcript before the session wrote one"
mkdir -p "$COPILOT_HOME/session-state/$UUID"; sed "s#@CWD@#$WD#" "$F/transcript.jsonl" > "$COPILOT_HOME/session-state/$UUID/events.jsonl"
assert_eq "$(cli_transcripts "$WD" "$UUID")" "$COPILOT_HOME/session-state/$UUID/events.jsonl" "transcript path from the id"
assert_eq "$(cli_usage "$COPILOT_HOME/session-state/$UUID/events.jsonl")" "$(cat "$F/usage.expected")" \
  "usage: input without the cache reads/writes, per model"
reply="$(cli_last_reply "$WD" "$UUID")"
assert_eq "$(tail -n +2 <<<"$reply")" "<promise>CAP DONE</promise>" "the reply to the last prompt (the loop run's second turn)"
assert_ok "…keyed by that prompt's event id" grep -qF "\"id\": \"$(head -1 <<<"$reply")\"" "$F/transcript.jsonl"
mkdir -p "$COPILOT_HOME/session-state/sub"; cp "$F/bypass-subagent.jsonl" "$COPILOT_HOME/session-state/sub/events.jsonl"
assert_eq "$(cli_last_reply "$WD" sub | tail -n +2)" "SUBAGENT DONE" "a sub-agent's own prompt and replies are not the session's"
assert_ok "the sub-agent ran its shell with no prompt" python3 -c 'import json,sys
ev = [json.loads(l) for l in open(sys.argv[1])]
ok = any(e.get("agentId") and e["type"] == "tool.execution_complete" and e["data"].get("success") for e in ev)
sys.exit(0 if ok else 1)' "$F/bypass-subagent.jsonl"
printf '%s\n' '{"type": "user.message", "data": {"content": "next"}, "id": "p3"}' '{"type": "assistant.turn_start", "data": {"turnId": "0"}, "id": "t3"}' \
  >> "$COPILOT_HOME/session-state/$UUID/events.jsonl"
assert_no "no reply while the last prompt's turn runs" cli_last_reply "$WD" "$UUID"
printf '%s\n' '{"type": "assistant.turn_end", "data": {"turnId": "0"}, "id": "e3"}' '{"type": "abort", "data": {"reason": "user_abort"}, "id": "a3"}' \
  >> "$COPILOT_HOME/session-state/$UUID/events.jsonl"
assert_eq "$(cli_last_reply "$WD" "$UUID")" "p3" "an aborted turn has ended, with an empty reply"
printf '%s\n' '{"type": "user.message", "data": {"content": "go"}, "id": "p4"}' '{"type": "assistant.turn_start", "data": {"turnId": "0"}, "id": "t4"}' \
  '{"type": "assistant.turn_end", "data": {"turnId": "0"}, "id": "e4"}' '{"type": "assistant.turn_start", "data": {"turnId": "1"}, "id": "t5"}' \
  >> "$COPILOT_HOME/session-state/$UUID/events.jsonl"
assert_no "a prompt's first model call ended but its next one runs: no reply yet" cli_last_reply "$WD" "$UUID"

# A loop that reaches max_iterations ends without the promise, and no further prompt is typed.
( fake_tmux; session_live(){ return 0; }; sess=hz-max-i8; w="$RUN_DIR/max"; mkdir -p "$w"; printf 'GOAL: x\n' > "$w/.harness-task.md"
  write_state "$w" "NEVER" 2 "$UUID"; echo "$w" > "$RUN_DIR/$sess.wd"
  for r in one two three; do "$F/turn-end" "$w" "$UUID" "$r"; watchdog_session "$sess"; done
  cli_done "$w" && [[ $(sent_text "$sess" | wc -l) == 1 ]] )
assert_eq "$?" 0 "max_iterations ends the driven loop after one re-prompt"
# A pane that is busy, or parked at a limit, is never re-prompted by the loop.
( fake_tmux; session_live(){ return 0; }; sess=hz-busy-i9; w="$RUN_DIR/busy"; mkdir -p "$w"; printf 'GOAL: x\n' > "$w/.harness-task.md"
  write_state "$w" "NEVER" 5 "$UUID"; echo "$w" > "$RUN_DIR/$sess.wd"; "$F/turn-end" "$w" "$UUID" "working"
  FAKE_PANE="$F/busy.txt"; watchdog_session "$sess"
  FAKE_PANE="$F/limit.txt"
  limit_checkpoint_once(){ :; }; watchdog_session "$sess"; watchdog_session "$sess"
  [[ -s $TMUXLOG ]] && ! grep -qF 'Ralph iteration' "$TMUXLOG" )
assert_eq "$?" 0 "a busy or limit-parked pane is not re-prompted"

# --- usage windows -------------------------------------------------------------------------------
python3 - "$F/transcript.jsonl" "$COPILOT_HOME/session-state/$UUID/events.jsonl" <<'PY'
import json, sys
with open(sys.argv[2], "w") as out:
    for line in open(sys.argv[1]):
        d = json.loads(line)
        for q in ((d.get("data") or {}).get("quotaSnapshots") or {}).values():
            q["resetDate"] = "2099-01-01T00:00:00Z"
        print(json.dumps(d), file=out)
PY
assert_eq "$(unset HARNESS_USAGE_CMD; cli_limit_usage)" "$(printf 'copilot\tchat\t0.8\t4070908800')" \
  "the chat quota is the window; completions (editors only) and a no-entitlement quota are not"
sed -i 's/2099-01-01T00:00:00Z/2001-01-01T00:00:00Z/g' "$COPILOT_HOME/session-state/$UUID/events.jsonl"
assert_no "a passed reset is no window" eval 'unset HARNESS_USAGE_CMD; cli_limit_usage'

# --- prerequisites -------------------------------------------------------------------------------
assert_ok "the binary is the only prerequisite" eval '{ PATH="$RUN_DIR/nobin:/usr/bin:/bin" cli_prereqs || :; } | grep -qxF "MISSING copilot binary (copilot): npm install -g @github/copilot"'
assert_ok "init offers copilot" grep -qx copilot <<<"$(cli_list)"

col="$(bash "$HERE/test_cli_matrix.sh" --tsv | awk -F'\t' '$1=="copilot" && $3!="ok"')"
assert_eq "$col" "" "every copilot matrix cell is ok"
finish

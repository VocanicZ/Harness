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
# A real directory, not a bare /elsewhere: MSYS rewrites that env value to C:/Program Files/Git/elsewhere for a native python (#605).
ELSEWHERE="$RUN_DIR/elsewhere"; mkdir -p "$ELSEWHERE"
cat > "$COPILOT_HOME/config.json" <<EOF
// User settings belong in settings.json.
// This file is managed automatically.
{
  "firstLaunchAt": "2026-10-28T02:27:01.208Z",
  "trustedFolders": [
    "$ELSEWHERE"
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
assert_ok "…and every other folder" cli_trusted "$ELSEWHERE"
cli_trust "$WD"
assert_eq "$(grep -cF -e "\"$WD\"" -e "\"$(native_path "$WD")\"" "$COPILOT_HOME/config.json")" 1 "trusting twice writes one entry"
rm -f "$COPILOT_HOME/config.json"; cli_trust "$WD"
assert_ok "a fresh home gets a config.json with the entry" cli_trusted "$WD"
# POSIX: a flock on a file the CLI keeps beside config.json. Windows: lock_acquire's mkdir mutex, `<file>.d`, gone once trust returns.
if host_is_windows; then assert_no "trust takes the lock beside config.json and leaves none held" test -d "$COPILOT_HOME/config.json.trusted-folders.lock.d"
else assert_ok "trust takes the lock file the CLI keeps beside config.json" test -f "$COPILOT_HOME/config.json.trusted-folders.lock"; fi
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
# …nor an injector's, which no watchdog tends (reap_finished_inject runs the tick itself).
( fake_tmux; session_live(){ return 0; }; sess="$(sess_inject main)"; w="$RUN_DIR/inj"; mkdir -p "$w"; printf 'GOAL: x\n' > "$w/.harness-task.md"
  write_state "$w" "NEVER" 5 "$UUID"; echo "$w" > "$RUN_DIR/$sess.wd"; FAKE_PANE="$F/limit.txt"
  for r in one two three; do "$F/turn-end" "$w" "$UUID" "$r"; reap_finished_inject main; done
  [[ -s $TMUXLOG ]] && ! grep -qF 'Ralph iteration' "$TMUXLOG" && grep -qx 'iteration: 1' "$w/.claude/ralph-loop.local.md" )
assert_eq "$?" 0 "an injector parked at a limit is not re-prompted"
( fake_tmux; session_live(){ return 0; }; sess="$(sess_inject main)"; w="$RUN_DIR/inj2"; mkdir -p "$w"; printf 'GOAL: x\n' > "$w/.harness-task.md"
  write_state "$w" "INJ DONE" 5 "$UUID"; echo "$w" > "$RUN_DIR/$sess.wd"
  "$F/turn-end" "$w" "$UUID" "<promise>INJ DONE</promise>"; reap_finished_inject main
  cli_done "$w" && grep -qF "kill-session" "$TMUXLOG" )
assert_eq "$?" 0 "an injector's promise ends its loop and the injector is reaped"
# Only the turn's last message answers it: a promise announced mid-run is no answer.
( fake_tmux; session_live(){ return 0; }; sess=hz-mid-i10; w="$RUN_DIR/mid"; mkdir -p "$w"; printf 'GOAL: x\n' > "$w/.harness-task.md"
  write_state "$w" "MID DONE" 5 "$UUID"; echo "$w" > "$RUN_DIR/$sess.wd"
  "$F/turn-end" "$w" "$UUID" "I will output <promise>MID DONE</promise> once the tests pass"
  f="$COPILOT_HOME/session-state/$UUID/events.jsonl"
  python3 -c 'import json,sys; l=open(sys.argv[1]).read().splitlines(); end=l.pop(); m=json.loads(l[-1]); m["id"]="m2"; m["data"]["content"]="tests still failing"; l.append(json.dumps(m)); l.append(end); open(sys.argv[1],"w").write("\n".join(l)+"\n")' "$f"
  watchdog_session "$sess"; ! cli_done "$w" && [[ $(sent_text "$sess" | wc -l) == 1 ]] )
assert_eq "$?" 0 "a promise announced before the turn's last message does not end the loop"
# A turn that answers the transient-error nudge leaves the error line on screen: its promise is still read.
( fake_tmux; session_live(){ return 0; }; sess=hz-err-i11; w="$RUN_DIR/err"; mkdir -p "$w"; printf 'GOAL: x\n' > "$w/.harness-task.md"
  write_state "$w" "ERR DONE" 5 "$UUID"; echo "$w" > "$RUN_DIR/$sess.wd"; FAKE_PANE="$F/transient.txt"
  watchdog_session "$sess"; "$F/turn-end" "$w" "$UUID" "<promise>ERR DONE</promise>"; watchdog_session "$sess"
  cli_done "$w" && [[ $(cat "$RUN_DIR/$sess.stall" 2>/dev/null || echo 0) == 0 ]] )
assert_eq "$?" 0 "a promise given with the transient-error line still on screen ends the loop"
# (a paused pool worker keeps tending a driven goal loop: test_pool_lanes.sh section 7)
# A paused bug lane keeps polling the watchdog of a driven goal loop it holds in drive_bug.
( source "$HERE/../scripts/priority-worker.sh"; HARNESS_REPO=acme/widget; PRIORITY_POLL=0
  polls="$RUN_DIR/lane-polls"; : > "$polls"
  _bug_ref_repo(){ echo acme/widget; }; _bug_ref_num(){ echo 5; }; bug_phase(){ echo fix; }; bug_checkout(){ echo "$RUN_DIR/co"; }
  spawn_bug(){ return 0; }; remove_worktree(){ :; }; bug_worktree(){ echo x; }; triage_worktree(){ echo y; }; stats_sweep_ended(){ :; }
  is_paused(){ return 0; }; usage_watch(){ :; }; bug_goal_done(){ return 1; }
  session_live(){ (( $(wc -l < "$polls") < 3 )); }; watchdog_session(){ echo poll >> "$polls"; }
  drive_bug "acme/widget#5" >/dev/null 2>&1; [[ $(wc -l < "$polls") == 3 ]] )
assert_eq "$?" 0 "a paused bug lane drains a driven goal loop by polling its watchdog until the session ends"

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
# grep reads the whole report (no -q): the handoff skill's line follows, and an early exit would kill
# the writer with SIGPIPE under pipefail.
assert_ok "the binary is the only prerequisite" eval '{ PATH="$RUN_DIR/nobin:/usr/bin:/bin" cli_prereqs || :; } | grep -xF "MISSING copilot binary (copilot): npm install -g @github/copilot" >/dev/null'
assert_ok "…beside the handoff skill, where copilot loads skills (#303)" \
  has "MISSING copilot skill handoff ($COPILOT_HOME/skills/handoff)" "$(cli_prereqs 2>&1)"
assert_ok "init offers copilot" grep -qx copilot <<<"$(cli_list)"

# #483: copilot has a headless lane runner (scripts/cli/copilot_headless.py), so its headless-* rows run on
# the fixture replay (fake-copilot) like claude's: every copilot matrix cell is ok, those rows included.
# only this CLI's cells are read, so only this CLI's are computed: the whole matrix is ~10x slower on a Windows host than the 600 s cap (#605)
cells="$(HARNESS_MATRIX_CLIS=copilot bash "$HERE/test_cli_matrix.sh" --tsv | awk -F'\t' '$1=="copilot"')"
assert_eq "$(awk -F'\t' '$3!="ok"' <<<"$cells")" "" "every copilot matrix cell is ok, its headless-* rows included"
assert_eq "$(awk -F'\t' '$2 ~ /^headless-/' <<<"$cells" | wc -l)" 14 "…and it has all 14 of them"
# …and on the Windows code paths (HARNESS_PLATFORM=windows forced on this host, an flock-backed msvcrt for
# portable.py): the rows that start a lane, send to it, park it at a limit, read its windows and its usage.
# (headless-checkpoint and -resume, which drive spawn_impl's long prompt through the same path, are red
# under that emulation for claude too: they are the winsma run's, #475 task 8.)
win="$(HARNESS_MATRIX_HEADLESS_PLATFORM=windows HARNESS_MATRIX_CLIS=copilot \
  HARNESS_MATRIX_ROWS='^headless-(launch|send|busy-idle|limit-parks|transient-stalls|usage-windows|stats-session-end-usage|stop)$' \
  bash "$HERE/test_cli_matrix.sh" --tsv)"
assert_eq "$(awk -F'\t' '$3=="ok"' <<<"$win" | wc -l)" 8 "copilot's lane rows pass under HARNESS_PLATFORM=windows (8 of them)"
assert_eq "$(awk -F'\t' '$3!="ok"' <<<"$win")" "" "…and none is red"
# A headless lane's screen has a turn timer (headless_core.py pane); a pane's copilot draws none (#483: it is what
# lets the stuck-turn interrupt reach a lane whose checkpoint waits behind a long turn).
hl_pane=$'✻ Working… (1m 5s · esc to interrupt)\n────────────\n❯ \n────────────'
assert_eq "$(HARNESS_SESSION_BACKEND=headless cli_turn_secs "$hl_pane")" 65 "copilot on the headless backend: the lane's turn timer is read"
assert_eq "$(HARNESS_SESSION_BACKEND=tmux cli_turn_secs "$hl_pane")" "" "…on tmux copilot has no turn timer (unavailable)"
assert_eq "$(HARNESS_SESSION_BACKEND=headless cli_turn_secs $'────\n❯ \n────')" 0 "…and an idle lane has no turn running"
assert_ok "copilot is a headless CLI" grep -qx copilot <<<"$(cli_headless_list)"
assert_eq "$(HARNESS_SESSION_BACKEND=headless cli_backend_check 2>&1; echo $?)" 0 "…and the headless backend does not refuse it as tmux-only"
# #605: a trusted folder is found by the directory, not its spelling (C:/x from the environment, /c/x from `pwd`).
SPC="$RUN_DIR/spell"; mkdir -p "$SPC"; printf '// managed\n{"trustedFolders": ["C:/w/proj"]}\n' > "$SPC/config.json"
( export COPILOT_HOME="$SPC" HARNESS_PLATFORM=windows
  assert_ok "windows: /c/w/proj is the folder kept as C:/w/proj" cli_trusted /c/w/proj
  cli_trust /c/w/proj
  assert_eq "$(grep -c 'w/proj' "$SPC/config.json")" 1 "windows: trusting it again adds no second spelling"
  assert_no "windows: another folder is not trusted" cli_trusted /c/w/other
  finish ) || TESTS_FAIL=$((TESTS_FAIL+1))
finish

#!/usr/bin/env bash
# test_cli_codex.sh — PRD #189 / #257: the `codex` adapter's own seams, beyond the shared matrix rows.
# Every fact asserted here is a row of docs/cli-capabilities.md § `codex`, read off the fixtures in
# test/fixtures/cli/codex/ (README.md there says how each was captured).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
cli_load codex || exit 1
F="$HERE/fixtures/cli/codex"; WD="$RUN_DIR/wd"; mkdir -p "$WD"; printf 'GOAL: x\n' > "$WD/.harness-task.md"
UUID=11111111-2222-3333-4444-555555555555
SID="$(cat "$F/session")"
has(){ grep -qF -- "$1" <<<"$2"; }
pane(){ cat "$F/$1.txt"; }
not_prompt_trust(){ ! cli_pane_prompt "$(pane trust)"; }
export CODEX_HOME="$RUN_DIR/codex-home"; mkdir -p "$CODEX_HOME"

# --- the launch line -----------------------------------------------------------------------------
line="$(cli_launch "$WD" "$UUID" gpt-5.6-luna xhigh)"
assert_ok "effort is a config override, not a flag" has '-c model_reasoning_effort=xhigh' "$line"
assert_eq "$(grep -o 'model_reasoning_effort' <<<"$line" | wc -l)" 1 "the lane's effort replaces the default one"
assert_ok "model is -m" has '-m gpt-5.6-luna' "$line"
assert_ok "scrollback kept for capture-pane" has '--no-alt-screen' "$line"
assert_ok "approvals and sandbox bypassed" has '--dangerously-bypass-approvals-and-sandbox' "$line"
assert_ok "Harness's own Stop hook may run untrusted" has '--dangerously-bypass-hook-trust' "$line"
assert_no "codex cannot take a caller-set id" has '--session-id' "$line"
assert_no "no caller-set id anywhere on the line" has "$UUID" "$line"
assert_ok "the prompt is the positional bootstrap" has "\"$HARNESS_BOOTSTRAP_PROMPT\"" "$line"
assert_eq "$(cli_launch "$WD" "$UUID" "" "")" \
  "exec codex --no-alt-screen --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -c model_reasoning_effort=high \"$HARNESS_BOOTSTRAP_PROMPT\"" \
  "no lane model/effort: the configured flags as they are"

# --- workspace trust in config.toml --------------------------------------------------------------
cat > "$CODEX_HOME/config.toml" <<'EOF'
model = "gpt-5.6-luna"

[marketplaces.harness]
source_type = "local"
source = "/opt/harness/plugins/codex"

[projects."/elsewhere"]
trust_level = "trusted"
EOF
cli_trust "$WD"
assert_ok "trust is a [projects] entry in config.toml" grep -qF "[projects.\"$WD\"]" "$CODEX_HOME/config.toml"
assert_ok "cli_trusted reads it back" cli_trusted "$WD"
assert_no "another dir is not trusted by it" cli_trusted "$RUN_DIR/other"
assert_ok "the update modal is turned off" grep -qx 'check_for_update_on_startup = false' "$CODEX_HOME/config.toml"
cfg_ok(){ python3 -c 'import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
ok = (d.get("check_for_update_on_startup") is False and d["model"] == "gpt-5.6-luna"
      and d["marketplaces"]["harness"]["source"] == "/opt/harness/plugins/codex"
      and d["projects"]["/elsewhere"]["trust_level"] == "trusted" and d["projects"][sys.argv[2]]["trust_level"] == "trusted")
sys.exit(0 if ok else 1)' "$CODEX_HOME/config.toml" "$WD"; }
assert_ok "update check is top-level, every other key kept" cfg_ok
cli_trust "$WD"
assert_eq "$(grep -cF "[projects.\"$WD\"]" "$CODEX_HOME/config.toml")" 1 "trusting twice writes one entry"
assert_eq "$(grep -c 'check_for_update_on_startup' "$CODEX_HOME/config.toml")" 1 "…and one update-check key"
printf '\n[projects."%s/untrusted"]\ntrust_level = "untrusted"\n' "$RUN_DIR" >> "$CODEX_HOME/config.toml"
cli_trust "$RUN_DIR/untrusted"
assert_ok "an untrusted entry is flipped to trusted" cli_trusted "$RUN_DIR/untrusted"
assert_eq "$(grep -cF "[projects.\"$RUN_DIR/untrusted\"]" "$CODEX_HOME/config.toml")" 1 "…in place, not duplicated"
rm -f "$CODEX_HOME/config.toml"; cli_trust "$WD"
assert_ok "trust with no config.toml yet" cli_trusted "$WD"

# --- the session id: discovered from the worktree's rollout --------------------------------------
d="$CODEX_HOME/sessions/2026/10/27"; mkdir -p "$d"
sed "s#@CWD@#$WD#" "$F/transcript.jsonl" > "$d/rollout-2026-10-27T22-47-16-$SID.jsonl"
assert_eq "$(cli_session_id "$WD" "$UUID")" "$SID" "session id read from the worktree's rollout"
assert_eq "$(cli_session_id "$RUN_DIR/elsewhere" "$UUID")" "" "a rollout of another cwd is not this worktree's"
# A relaunch: the state file says the lane started after that rollout, so its id is not this one's.
write_state "$WD" "X DONE" 5 "$UUID"
assert_eq "$(cli_session_id "$WD" "$UUID")" "" "a rollout from before this launch is the previous session's"
rm -f "$WD/.claude/ralph-loop.local.md"
# A sub-agent writes its own rollout in the same cwd under the parent's session_id
# (bypass-subagent.jsonl); it is never the lane's session, but its usage is the lane's.
python3 - "$F/bypass-subagent.jsonl" "$WD" "$d/rollout-2026-10-27T22-52-38-sub.jsonl" "$SID" <<'PY'
import json, sys
src, wd, dst, sid = sys.argv[1:]
with open(dst, "w") as out:
    for line in open(src):
        r = json.loads(line.replace("@CWD@", wd))
        if r.pop("conversation") != "subagent":
            continue
        if r["type"] == "session_meta":
            r["payload"].update(session_id=sid, parent_thread_id=sid, timestamp="2026-10-27T23:59:59.000Z")
        print(json.dumps(r), file=out)
PY
assert_eq "$(cli_session_id "$WD" "$UUID")" "$SID" "a newer sub-agent rollout in the worktree is not the session"
assert_eq "$(cli_transcripts "$WD" "$SID" | xargs -n1 basename | paste -sd' ')" \
  "rollout-2026-10-27T22-47-16-$SID.jsonl rollout-2026-10-27T22-52-38-sub.jsonl" \
  "transcripts: the session's rollout first, then its sub-agents'"
assert_eq "$(cli_transcripts "$WD" "")" "" "no session id, no transcripts"
assert_eq "$(cli_usage "$(cli_transcripts "$WD" "$SID" | head -1)")" "$(cat "$F/usage.expected")" \
  "usage folds token_count per turn_context model, cached input as cache reads"

# --- usage windows from the newest rollout's rate_limits -----------------------------------------
windows(){ python3 - "$F/transcript.jsonl" "$d/rollout-2026-10-27T22-47-16-$SID.jsonl" "$1" <<'PY'
import json, sys, time
with open(sys.argv[2], "w") as out:
    for line in open(sys.argv[1]):
        r = json.loads(line)
        for w in ((r.get("payload") or {}).get("rate_limits") or {}).values():
            if isinstance(w, dict) and "resets_at" in w:
                w["resets_at"] = int(time.time()) + int(sys.argv[3])
        print(json.dumps(r), file=out)
PY
  touch "$d/rollout-2026-10-27T22-47-16-$SID.jsonl"; (unset HARNESS_USAGE_CMD; cli_limit_usage); }
assert_eq "$(windows 3600 | cut -f1-3)" "$(cat "$F/usage-windows.expected")" "the 30-day primary window, its used percent"
assert_no "a window whose reset has passed is not reported" windows -60

# --- panes ---------------------------------------------------------------------------------------
assert_ok "idle: the composer is the prompt" cli_pane_prompt "$(pane idle)"
assert_eq "$(cli_pane_prompt_line "$(pane busy)")" "$(grep -n '^› Ask Codex' "$F/busy.txt" | tail -1 | cut -d: -f1)" \
  "the live composer, not a submitted prompt echoed above it"
assert_ok "the trust dialog's › option is not a prompt" not_prompt_trust
assert_eq "$(cli_turn_secs "$(pane busy)")" 13 "the status row's timer is the turn's seconds"
assert_eq "$(cli_turn_secs "$(pane idle)")" 0 "no status row, no turn"
assert_eq "$(cli_turn_secs $'• Working (1m 05s • esc to interrupt)\n› x')" 65 "minutes and seconds"
assert_ok "Escape prints the interrupt line" grep -qE "$(cli_interrupted_re)" "$F/interrupted.txt"
assert_no "an interrupted turn is not busy" cli_pane_busy "$(pane interrupted)"
assert_ok "an interrupted turn leaves the prompt" cli_pane_prompt "$(pane interrupted)"
assert_no "the free-plan reset banner is no usage limit" session_limit_idle "$(pane idle)"
assert_no "a 400 error cell is no transient stall" session_stalled "$(pane error400)"
assert_no "…and no usage limit" session_limit_idle "$(pane error400)"

# --- the goal loop: the harness-ralph Stop hook --------------------------------------------------
assert_eq "$(cli_loop)" hook "Codex's Stop hook drives the loop"
assert_eq "$(cli_skill handoff)" '$handoff' "a skill is invoked as \$<name>"
LW="$RUN_DIR/loop"; mkdir -p "$LW"; printf 'GOAL: UNIQUE_TASK_MARKER\n' > "$LW/.harness-task.md"
write_state "$LW" "LOOP DONE" 2 "$UUID"
out="$("$F/stop-hook" "$LW" "$SID" "still going")"
assert_ok "no promise: the hook blocks with the task as the next prompt" python3 -c 'import json, sys
d = json.loads(sys.argv[1]); sys.exit(0 if d["decision"] == "block" and "UNIQUE_TASK_MARKER" in d["reason"] else 1)' "$out"
assert_ok "…and counts the iteration" grep -qx 'iteration: 2' "$LW/.claude/ralph-loop.local.md"
out="$("$F/stop-hook" "$LW" "$SID" "nope")"
assert_eq "$out" "" "max_iterations reached: the hook lets the turn end"
assert_ok "…and ends the loop" cli_done "$LW"
write_state "$LW" "LOOP DONE" 9 "$UUID"
"$F/stop-hook" "$LW" "$SID" "I read the task: output <promise>OTHER</promise> when done" >/dev/null
assert_no "a different promise does not end the loop" cli_done "$LW"
"$F/stop-hook" "$LW" "$SID" "all done <promise>LOOP  DONE</promise>" >/dev/null
assert_ok "the promise in the reply ends the loop" cli_done "$LW"
out="$("$F/stop-hook" "$LW" "$SID" "anything")"
assert_eq "$out" "" "no state file: another session's turn is left alone"

# --- prerequisites -------------------------------------------------------------------------------
# The fake's `plugin list`, once the plugin is added, prints it and then a long remote catalog, as the
# real one does: a reader that stops at the first match must not fail the check (pipefail + SIGPIPE).
pre(){ ( local d="$RUN_DIR/pre"; mkdir -p "$d"
  printf '#!/bin/sh\necho "$*" >> %q\n[ "$1 $2" = "plugin list" ] && [ -f %q ] && { echo "harness-ralph@harness  installed, enabled  1.0.0  /x"; exec seq 1 200000; }\nexit 0\n' \
    "$d/calls" "$d/added" > "$d/codex"; chmod +x "$d/codex"; PATH="$d:$PATH"; "$@" ) }
out="$(pre cli_prereqs 2>&1)"
assert_ok "the marketplace is named with its add command" has "MISSING codex marketplace harness: codex plugin marketplace add $(cd "$HERE/.." && pwd)/scripts/cli/../../plugins/codex" "$out"
assert_ok "the plugin is named with its add command" has "MISSING codex plugin harness-ralph: codex plugin add harness-ralph@harness" "$out"
assert_ok "the handoff skill is named where codex loads skills (#303)" has "MISSING codex skill handoff ($HARNESS_CODEX_USER_SKILLS/handoff)" "$out"
# Every skill the prompts name (#315) placed too: this checks the plugin, not the skills.
touch "$RUN_DIR/pre/added"
for n in $(cli_prompt_skills); do [[ $n == rtdd ]] || cli_skill_place "$HERE/../skill/$n" "$HARNESS_CODEX_USER_SKILLS/$n"; done
assert_ok "an installed plugin passes" pre eval 'cli_prereqs >/dev/null'
assert_ok "the marketplace it names holds the plugin" python3 -c 'import json, os, sys
m = json.load(open(sys.argv[1] + "/.agents/plugins/marketplace.json"))
p = [x for x in m["plugins"] if x["name"] == "harness-ralph"][0]
r = os.path.join(sys.argv[1], p["source"]["path"])
sys.exit(0 if m["name"] == "harness" and json.load(open(r + "/.codex-plugin/plugin.json"))["name"] == "harness-ralph"
         and "Stop" in json.load(open(r + "/hooks/hooks.json"))["hooks"] else 1)' "$HERE/../plugins/codex"

# #353: codex has no headless lane runner, so its headless-* rows read n/a, tmux-only — and only those.
col="$(bash "$HERE/test_cli_matrix.sh" --tsv | awk -F'\t' '$1=="codex" && $3!="ok" && !($2 ~ /^headless-/ && $3 == "n/a:tmux-only")')"
assert_eq "$col" "" "every codex matrix cell is ok, but its headless-* rows: n/a, tmux-only"
finish

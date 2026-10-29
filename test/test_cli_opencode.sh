#!/usr/bin/env bash
# test_cli_opencode.sh — PRD #189 / #261: the `opencode` adapter's own seams, beyond the shared matrix
# rows. Every fact asserted here is a row of docs/cli-capabilities.md § `opencode`, read off the
# fixtures in test/fixtures/cli/opencode/ (README.md there says how each was captured).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
cli_load opencode || exit 1
F="$HERE/fixtures/cli/opencode"; WD="$RUN_DIR/wd"; mkdir -p "$WD"; git -C "$WD" init -q; printf 'GOAL: x\n' > "$WD/.harness-task.md"
UUID=11111111-2222-3333-4444-555555555555
has(){ grep -qF -- "$1" <<<"$2"; }
pane(){ cat "$F/$1.txt"; }
mkdir -p "$RUN_DIR/bin"; cat > "$RUN_DIR/bin/opencode" <<'STUB'
#!/usr/bin/env bash
case "$1" in --version) echo "${FAKE_OC_VERSION:-1.19.5}" ;; esac
STUB
chmod +x "$RUN_DIR/bin/opencode"; export PATH="$RUN_DIR/bin:$PATH"
DB="$XDG_DATA_HOME/opencode/opencode.db"

# --- prerequisites: OpenCode 1 only ---------------------------------------------------------------
assert_eq "$(FAKE_OC_VERSION=2.1.4 cli_prereqs 2>&1 | grep -c 'OpenCode 2 is not supported')" 1 "OpenCode 2 is refused"
v2_prereqs(){ FAKE_OC_VERSION=2.1.4 cli_prereqs >/dev/null 2>&1; }
assert_no "…and fails" v2_prereqs
v1_prereqs(){ cli_prereqs >/dev/null 2>&1; }
assert_ok "the handoff skill is named where opencode loads skills (#303)" \
  has "MISSING opencode skill handoff ($HARNESS_USER_SKILLS/handoff)" "$(cli_prereqs 2>&1)"
mkdir -p "$HARNESS_USER_SKILLS/handoff"; cp "$HERE/../skill/handoff/SKILL.md" "$HARNESS_USER_SKILLS/handoff/"
assert_ok "OpenCode 1 passes on the binary alone" v1_prereqs
assert_ok "…naming its version" has "ok      opencode binary (opencode, 1.19.5)" "$(cli_prereqs)"

# --- the launch line and the lane's inline config -------------------------------------------------
# cfg <line> — the OPENCODE_CONFIG_CONTENT the pane's shell hands opencode for <line>.
cfg(){ LINE="$1" python3 -c 'import os, shlex
print(next(w.split("=", 1)[1] for w in shlex.split(os.environ["LINE"]) if w.startswith("OPENCODE_CONFIG_CONTENT=")))'; }
echo '{"$schema": "https://opencode.ai/config.json", "model": "keep/me"}' > "$WD/opencode.json"; cp "$WD/opencode.json" "$RUN_DIR/oc.orig"
line="$(cli_launch "$WD" "$UUID" anthropic/claude-sonnet-5.5 high)"
assert_ok "auto-approve" has '--auto' "$line"
assert_ok "prompt via --prompt" has "--prompt \"$HARNESS_BOOTSTRAP_PROMPT\"" "$line"
assert_ok "provider/model" has '-m anthropic/claude-sonnet-5.5' "$line"
assert_ok "no update mid-fleet" has 'OPENCODE_DISABLE_AUTOUPDATE=1 exec opencode ' "$line"
assert_ok "questions denied, effort as the build agent's variant" \
  python3 -c 'import json,sys; c=json.loads(sys.argv[1]); assert c["permission"]["question"]=="deny" and c["agent"]["build"]["variant"]=="high"' "$(cfg "$line")"
assert_ok "the goal-loop plugin is loaded from the engine by path" \
  python3 -c 'import json,sys; assert json.loads(sys.argv[1])["plugin"]==["file://"+sys.argv[2]]' "$(cfg "$line")" "$(cd "$HERE/../scripts/cli" && pwd -P)/opencode-ralph.js"
assert_ok "…and handed the goal-loop script" has "OPENCODE_HARNESS_LOOP='$GOAL_LOOP_PY' " "$line"
assert_ok "nothing is written into the worktree: the project's opencode.json is as it was" cmp -s "$WD/opencode.json" "$RUN_DIR/oc.orig"
assert_no "…and no plugin is copied into it" test -e "$WD/.opencode"
assert_eq "$(cli_lane_settings "$WD")" "" "no lane settings live outside the launch line"
assert_no "a lane with no effort names no variant (the model's default)" has variant "$(cfg "$(cli_launch "$WD" "$UUID" "" "")")"
line="$(HARNESS_OPENCODE_FLAGS='--auto -m other/model' cli_launch "$WD" "$UUID" lane/model "")"
assert_eq "$(grep -oE -- '(^| )(-m|--model) [^ ]+' <<<"$line" | xargs)" "-m lane/model" "the lane's model replaces the configured one"
line="$(CLI_DIR="$RUN_DIR/it's here" GOAL_LOOP_PY="$RUN_DIR/o'loop.py" cli_launch "$WD" "$UUID" "" "")"
assert_ok "a quote in the engine's path survives the pane's shell" \
  python3 -c 'import json,sys; assert json.loads(sys.argv[1])["plugin"][0].endswith("/it%27s%20here/opencode-ralph.js")' "$(cfg "$line")"
assert_eq "$(LINE="$line" python3 -c 'import os, shlex; print(next(w for w in shlex.split(os.environ["LINE"]) if w.startswith("OPENCODE_HARNESS_LOOP=")))')" \
  "OPENCODE_HARNESS_LOOP=$RUN_DIR/o'loop.py" "…and in the loop script's"
assert_ok "bypassed: --auto on the line, questions denied in its config" cli_bypassed "$WD"
no_deny(){ ( _opencode_config(){ echo '{"plugin": []}'; }; cli_bypassed "$WD" ); }
assert_no "…not without the deny" no_deny
no_auto(){ HARNESS_OPENCODE_FLAGS= cli_bypassed "$WD"; }
assert_no "…nor without --auto" no_auto

# --- the session id: discovered from the database --------------------------------------------------
mkdir -p "${DB%/*}"; cp "$F/transcript.db" "$DB"
SID="$(cat "$F/session")"
python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("UPDATE session SET directory = ?", (sys.argv[2],)); c.commit()' "$DB" "$WD"
assert_eq "$(cli_session_id "$WD" "$UUID")" "$SID" "the session id is the newest top-level session in the worktree"
assert_eq "$(cli_session_id "$RUN_DIR/other" "$UUID")" "" "…never one of another worktree"
write_state "$WD" "X DONE" 5 "$UUID"
assert_eq "$(cli_session_id "$WD" "$UUID")" "" "…nor one started before this launch (a relaunch in the same worktree)"
rm -f "$WD/.claude/ralph-loop.local.md"
assert_eq "$(XDG_DATA_HOME="$RUN_DIR/no-data" cli_session_id "$WD" "$UUID")" "" "no database yet: no id"

# --- transcripts: the session's, then its sub-agents' ----------------------------------------------
cp "$F/bypass-subagent.db" "$DB"
got="$(cli_transcripts "$WD" "$SID")"
assert_eq "$(sed -n 1p <<<"$got")" "$DB#$SID" "the session's own transcript first"
assert_eq "$(sed -n 2p <<<"$got")" "$DB#ses_e7eac6cd0ffewAa5ZtAo9g6MCn" "…then its sub-agent's (a child session)"
assert_eq "$(cli_transcripts "$WD" ses_nope)" "" "an unknown session has none"
assert_eq "$(cli_usage "$DB#ses_e7eac6cd0ffewAa5ZtAo9g6MCn")" "$(printf 'opencode/big-pickle\t16389\t105\t16502\t0')" \
  "a sub-agent's usage is read from its own messages (reasoning counted as output)"

# --- panes ----------------------------------------------------------------------------------------
assert_ok "a permission panel reads as busy, not idle" grep -qE "$(cli_busy_re)" "$F/busy-permission.txt"
assert_ok "…and as a dialog nothing is typed into" cli_pane_dialog "$(pane busy-permission)"
assert_no "…so never as the prompt" cli_pane_prompt "$(pane busy-permission)"
quoted="$(sed '1a\  ┃  $ grep -n "esc interrupt|△ Permission required|Free usage exceeded" opencode.sh' "$F/idle.txt")"
assert_no "the busy hint quoted in a tool call above the prompt is no running turn" cli_pane_busy "$quoted"
assert_no "…nor a dialog" cli_pane_dialog "$quoted"
assert_no "…nor a limit park" session_limit_idle "$quoted"
assert_ok "OpenCode's own retries are a running turn" cli_pane_busy "$(pane busy-retrying)"
assert_no "…never a stall" session_stalled "$(pane busy-retrying)"
assert_no "a limit OpenCode is still retrying is not parked yet" session_limit_idle "$(pane busy-limit-retrying)"
assert_eq "$(cli_prompt_text "$(sed -n "$(cli_pane_prompt_line "$(pane idle)")p" "$F/idle.txt")")" "" "the agent line holds no typed text"
assert_ok "a queued nudge is its own message, the box is empty" has QUEUED "$(pane steer)"
assert_eq "$(source "$HERE/../scripts/turn.sh"; turn_queued "$(pane steer)")" "" "…so nothing reads as queued in the box"
assert_eq "$(grep -cE "$(cli_interrupted_re)" "$F/interrupted.txt")" 1 "an interrupted turn says so"
assert_eq "$(grep -cE "$(cli_interrupted_re)" "$F/idle.txt")" 0 "…a finished one does not"
assert_eq "$(cli_turn_secs "$(pane busy)")" "" "no turn timer"
assert_eq "$(cli_skill handoff)" handoff "a skill is invoked by name (its skill tool), not as a slash command"
assert_ok "…as skill.txt shows" has '→ Skill "echo-proof"' "$(pane skill)"
assert_eq "$(cli_loop)" hook "the session.idle plugin drives the loop"

# --- the plugin itself, under node (it runs on OpenCode's Bun; node is not a suite dependency) ----
if command -v node >/dev/null; then
  P="$RUN_DIR/plugin"; mkdir -p "$P/wd"; git -C "$P/wd" init -q; printf 'GOAL: PLUGIN_TASK_MARKER\n' > "$P/wd/.harness-task.md"
  cp "$HERE/../scripts/cli/opencode-ralph.js" "$P/harness-ralph.mjs"
  cat > "$P/drive.mjs" <<'JS'
// drive.mjs <plugin> <dir> <reply> <events…> — load the plugin with a fake SDK client and hand it
// each event (`idle`, `error`, `busy`, `idle-child`); print each prompt it sends, with the agent and
// model it names.
const [plugin, dir, reply, ...evs] = process.argv.slice(2)
const { HarnessRalph } = await import(plugin)
const client = {
  session: {
    get: async ({ path }) => ({ data: { id: path.id, parentID: path.id === "child" ? "lane" : undefined } }),
    messages: async () => ({ data: [
      { info: { role: "user", agent: "build", model: { providerID: "acme", modelID: "m-9" } }, parts: [{ type: "text", text: "go" }] },
      { info: { role: "assistant" }, parts: [{ type: "text", text: reply }] }] }),
    promptAsync: async ({ path, body }) =>
      console.log(`PROMPT ${path.id} ${body.agent}/${body.model?.providerID}/${body.model?.modelID} ${body.parts[0].text.split("\n")[0]}`),
  },
  app: { log: async ({ body }) => console.error(body.message) },
}
const hooks = await HarnessRalph({ client, directory: dir })
const ev = { idle: "session.idle", "idle-child": "session.idle", error: "session.error", busy: "session.status" }
for (const e of evs) {
  const properties = { sessionID: e === "idle-child" ? "child" : "lane", status: e === "busy" ? { type: "busy" } : { type: "idle" } }
  await hooks.event({ event: { type: ev[e], properties } })
}
JS
  drive(){ OPENCODE_HARNESS_LOOP="$GOAL_LOOP_PY" node "$P/drive.mjs" "$P/harness-ralph.mjs" "$P/wd" "$@" 2>&1; }
  write_state "$P/wd" "PLUGIN DONE" 5 x
  out="$(drive "STILL WORKING" idle)"
  assert_ok "plugin: an idle lane without the promise is re-prompted with the next iteration" \
    has 'PROMPT lane build/acme/m-9 🔄 Ralph iteration 2 | To stop: output <promise>PLUGIN DONE</promise>' "$out"
  assert_ok "…as the agent and model its last prompt ran with, and the state file counts it" grep -qx 'iteration: 2' "$P/wd/.claude/ralph-loop.local.md"
  out="$(drive "STILL WORKING" error idle idle-child)"
  assert_eq "$out" "" "plugin: a turn that ended in an error is not re-prompted, nor is a sub-agent's session"
  assert_ok "…and neither counts an iteration" grep -qx 'iteration: 2' "$P/wd/.claude/ralph-loop.local.md"
  out="$(drive "STILL WORKING" error busy idle)"
  assert_ok "plugin: an error is forgotten once the session runs a turn again" has 'PROMPT lane build/acme/m-9 🔄 Ralph iteration 3' "$out"
  out="$(OPENCODE_HARNESS_LOOP= node "$P/drive.mjs" "$P/harness-ralph.mjs" "$P/wd" "STILL WORKING" idle 2>&1)"
  assert_eq "$out" "" "plugin: a session Harness did not launch (no loop script named) is left alone"
  out="$(drive "done <promise>PLUGIN DONE</promise>" idle)"
  assert_eq "$out" "" "plugin: the promise ends the loop with no prompt"
  assert_ok "…and removes the state file (cli_done)" cli_done "$P/wd"
  out="$(drive "STILL WORKING" idle)"
  assert_eq "$out" "" "plugin: a worktree with no goal loop is left alone"
else
  echo "  skip: node not installed — the plugin was not driven (the matrix's loop-mode drives its step)"
fi

col="$(bash "$HERE/test_cli_matrix.sh" --tsv | awk -F'\t' '$1=="opencode" && $3!="ok" { print $2, substr($3, 1, 4) }')"
assert_eq "$col" "$(printf 'trust-dialog-is-not-prompt n/a:\ntrust-pre-accepted n/a:\nusage-windows n/a:\nsupervisor-skips-trust-dialog n/a:')" \
  "every opencode matrix cell is ok, but the rows that cannot exist for it (n/a with a reason)"
finish

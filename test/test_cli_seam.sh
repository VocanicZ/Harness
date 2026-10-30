#!/usr/bin/env bash
# test_cli_seam.sh — #253 (PRD #189): every CLI-specific path goes through the adapter seam
# (scripts/cli/). Nothing outside scripts/cli/ may know a CLI's TUI strings, binary or config path;
# the stuck-turn helpers and the supervisor read an agy pane through agy's adapter; `harness setup`
# installs what is missing; `harness init` refuses a CLI with no adapter; and a lane's own model and
# effort (a worktree hook's `.harness-lane`) reach the launch line production builds, on every CLI.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
FIX="$HERE/fixtures/cli"
NUDGE='Please continue — the transient API error has cleared; resume the in-flight task.'

echo "=== 1: no CLI-specific string outside scripts/cli/ ==="
# Code lines only: whole-line comments and trailing ` # …` comments are prose about a CLI, not a
# path through it.
code(){ sed -E '/^[[:space:]]*#/d; s/[[:space:]]#[^"'"'"']*$//' "$1"; }
cli_leaks(){ local f re='❯|esc to interrupt|esc to cancel|(command -v|need|which|type) +"?(claude|agy)\b|\b(claude|agy) +(plugin|--version|-p )|for [a-z_]+ in [^;]*\b(claude|agy)\b|HARNESS_(CLAUDE|AGY)_(BIN|FLAGS)|\.gemini/|\.claude\.json'
  for f in "$ROOT"/scripts/*.sh; do code "$f" | grep -nE -- "$re" | sed "s#^#${f#"$ROOT"/}:#"; done; }
assert_eq "$(cli_leaks)" "" "no TUI string, binary check or config path of a CLI in scripts/*.sh"
# The grep is real: the same lines planted in a scratch script are caught.
LEAK="$ROOT/scripts/zz-leak-probe.sh"
printf '%s\n' 'awk "/^❯/"' 'command -v claude' 'for b in claude agy gh; do :; done' > "$LEAK"
leaks="$(cli_leaks)"; rm -f "$LEAK"
assert_eq "$(grep -c zz-leak-probe <<<"$leaks")" "3" "the grep catches a planted prompt glyph and binary checks"

echo "=== 2: turn.sh reads an agy pane through the agy adapter ==="
# agy_pane <fixture> [queued text] — a fixture pane; with text, typed into its live input box (the
# LAST `>` line: agy echoes each submitted prompt at column 0, so earlier ones are scrollback).
agy_pane(){ local f="$FIX/agy/$1.txt" n
  [[ $# -gt 1 ]] || { cat "$f"; return; }
  n=$(grep -nE '^>( |$)' "$f" | tail -1 | cut -d: -f1)
  awk -v n="$n" -v q="$2" 'NR == n { print "> " q; next } { print }' "$f"; }
BUSY="$(agy_pane busy-generating)"; BUSYQ="$(agy_pane busy-generating "$NUDGE")"; IDLEQ="$(agy_pane idle "$NUDGE")"
assert_ok "fixture: the agy busy pane holds an earlier prompt at column 0" grep -qE '^> Write another' <<<"$BUSY"
assert_eq "$(cli_with agy turn_secs "$BUSY")" "" "agy draws no turn timer: turn_secs is unavailable (empty)"
assert_eq "$(cli_with agy turn_queued "$BUSY")" "" "agy: the echoed earlier prompt is not queued input"
assert_eq "$(cli_with agy turn_queued "$BUSYQ")" "$NUDGE" "agy: turn_queued reads the live input box"
TQ="$RUN_DIR/agy.turnq"; rm -f "$TQ"
assert_no "agy: a nudge queued for the first time gets one poll to land" cli_with agy turn_should_interrupt "$BUSYQ" "$TQ"
assert_ok "agy: the same nudge still queued a poll later must be interrupted" cli_with agy turn_should_interrupt "$BUSYQ" "$TQ"
rm -f "$TQ"; cli_with agy turn_should_interrupt "$IDLEQ" "$TQ"
assert_no "agy: text in an idle pane's box is not a stuck turn" cli_with agy turn_should_interrupt "$IDLEQ" "$TQ"
assert_eq "$(cli_with claude turn_queued "$BUSYQ")" "" "claude's adapter does not read agy's input box"
# turn_interrupt: agy prints no `Interrupted`; the turn has ended once the pane is no longer busy.
KEYS="$RUN_DIR/keys"; PANE="$RUN_DIR/pane"; GOES_IDLE=1
tmux(){ case "$1" in
  capture-pane) cat "$PANE" ;;
  send-keys) echo "${*: -1}" >> "$KEYS"; [[ "${*: -1}" == Escape ]] && (( GOES_IDLE )) && agy_pane idle > "$PANE" ;;
esac; return 0; }
sleep(){ :; }
: > "$KEYS"; printf '%s\n' "$BUSYQ" > "$PANE"
assert_ok "agy: turn_interrupt succeeds once the busy line goes away" cli_with agy turn_interrupt hz-x-i1
assert_eq "$(tr '\n' ' ' < "$KEYS")" "Escape Enter " "agy: Escape, then Enter"
: > "$KEYS"; GOES_IDLE=0; HARNESS_INTERRUPT_WAIT=0; printf '%s\n' "$BUSYQ" > "$PANE"
assert_no "agy: a turn still busy after Escape is not reported ended" cli_with agy turn_interrupt hz-x-i1
assert_eq "$(tr '\n' ' ' < "$KEYS")" "Escape " "agy: still busy → Enter withheld"
unset -f tmux sleep

echo "=== 3: the supervisor's frozen/busy checks on agy panes ==="
export HARNESS_SUPERVISE_CONF="$RUN_DIR/none.conf" HARNESS_SUPERVISE_STATE="$RUN_DIR/sup" HARNESS_SUPERVISE_LOG="$RUN_DIR/sup.log"
source "$ROOT/scripts/supervise.sh"
SUP_DRY=1 CPU_ACTIVE_S=0
tmux(){ case "$1" in capture-pane) cat "$PANE" ;; display) echo 999999999 ;; esac; return 0; }
spass(){ sup_watch_pane "$1" "$SUP_STATE/panes/$1" 0 0 "nudge-$1" agy; }
nudged(){ grep -q "nudge-$1" "$SUP_LOG"; }
: > "$SUP_LOG"; rm -rf "$SUP_STATE"
# Streaming below the echoed prompt and above the live box is activity (the screen is everything
# above the LAST prompt line, not the first).
printf '%s\n' "$BUSY" > "$PANE"; spass agy-stream
awk '/Generating\.\.\./ { print "  and one more streamed line." } { print }' <<<"$BUSY" > "$PANE"; spass agy-stream
assert_no "agy: text streaming above the live box is activity, never a nudge" nudged agy-stream
# The footer's token count moving (10.1k → 10.2k) is activity too.
agy_pane idle > "$PANE"; spass agy-footer
sed 's/^10\.1k /10.2k /' "$FIX/agy/idle.txt" > "$PANE"; spass agy-footer
assert_no "agy: a moving footer token count is activity" nudged agy-footer
# A quiet idle prompt is frozen and nudged; a dialog and a limit park are never typed into.
agy_pane idle > "$PANE"; spass agy-idle; spass agy-idle
assert_ok "agy: a quiet idle prompt is nudged" nudged agy-idle
agy_pane trust > "$PANE"; spass agy-trust; spass agy-trust
assert_no "agy: the trust dialog is never typed into" grep -q agy-trust "$SUP_LOG"
agy_pane limit > "$PANE"; spass agy-limit; spass agy-limit
assert_no "agy: a pane parked on agy's quota message is left alone" nudged agy-limit
# One of our nudges still queued in agy's box a pass later: Escape, then Enter.
printf '%s\n' "$BUSYQ" > "$PANE"; spass agy-stuck; spass agy-stuck
assert_ok "agy: a nudge stuck behind a running turn gets Escape…" grep -q "DRY tmux send-keys -t agy-stuck Escape" "$SUP_LOG"
assert_ok "…then Enter" grep -q "DRY tmux send-keys -t agy-stuck Enter" "$SUP_LOG"
unset -f tmux
# #339: sup_cli decides adapter membership with no pipe into an early-exiting grep -q. A cli_list
# still writing after the match must not SIGPIPE it (pipefail) into the fleet's CLI's adapter.
cli_list_real="$(declare -f cli_list)"
cli_list(){ echo agy; sleep 0.2; echo claude; echo codex; }
assert_eq "$(HARNESS_CLI=claude sup_cli agy)" agy "sup_cli: agy resolves to agy while cli_list is still writing"
assert_ok "sup_cli: agy's quota regex is in sup_limit_re while cli_list is still writing" \
  grep -qF "exhausted your quota" <<<"$(HARNESS_CLI=claude sup_limit_re agy)"
eval "$cli_list_real"
for c in $(cli_list); do sup_cli_all_ok=1; [[ $(HARNESS_CLI=bogus sup_cli "$c") == "$c" ]] || { sup_cli_all_ok=0; break; }; done
assert_eq "$sup_cli_all_ok" 1 "sup_cli: every adapter in cli_list resolves to itself"
assert_eq "$(HARNESS_CLI=codex sup_cli bash)" codex "sup_cli: a name with no adapter falls back to the fleet's CLI"
assert_eq "$(HARNESS_CLI=codex sup_cli dispatch)" codex "sup_cli: dispatch.sh is no adapter"
# _cli_re_hits: a hit on line 1 of a >64 KiB pane is still reported under pipefail.
big="agy-hit-line"$'\n'"$(head -c 200000 /dev/zero | tr '\0' x | fold -w 100)"
assert_ok "_cli_re_hits: a hit on line 1 of a >64 KiB input is reported" _cli_re_hits 'agy-hit-line' "$big"

echo "=== 4: harness setup installs missing prerequisites ==="
S="$RUN_DIR/setup"; mkdir -p "$S/bin" "$S/state"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/tmux"; printf '#!/bin/sh\nexit 0\n' > "$S/bin/gh"
# agy stub: `plugin list` names harness-ralph only once `plugin install` has run.
cat > "$S/bin/agy" <<EOF
#!/bin/sh
echo "\$*" >> "$S/agy.log"
case "\$1 \$2" in
  "plugin list") [ -f "$S/installed" ] && echo '{"name": "harness-ralph"}'; exit 0 ;;
  "plugin install") [ -f "$S/broken" ] && exit 1; touch "$S/installed"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$S/bin/"*
run_setup(){ ( export PATH="$S/bin:$PATH" STATE_DIR="$S/state" HARNESS_CLI=agy HARNESS_AGY_BIN="$S/bin/agy" \
    HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_AGY_USER_SKILLS="$S/skills"
  gh(){ return 0; }; export -f gh
  bash "$ROOT/scripts/setup.sh" ) >"$S/out" 2>&1; }
: > "$S/agy.log"; rm -f "$S/installed"
run_setup; rc=$?
assert_eq "$rc" "0" "setup succeeds once it has installed the missing plugin"
assert_ok "setup ran the adapter's install for the missing plugin" grep -qx "plugin install .*/plugins/ralph-loop" "$S/agy.log"
assert_ok "setup reports it installed" grep -q "harness-ralph (installed)" "$S/out"
: > "$S/agy.log"; rm -f "$S/installed"; touch "$S/broken"
run_setup; rc=$?
assert_no "setup fails when a prerequisite still cannot be installed" test "$rc" = 0
assert_ok "…and names what is missing" grep -q "MISSING agy plugin harness-ralph" "$S/out"

echo "=== 5: harness init rejects a CLI with no adapter ==="
I="$RUN_DIR/init"; mkdir -p "$I/proj"
run_init(){ ( cd "$I/proj" && env STATE_DIR="$I/proj/.harness" HARNESS_INIT_NONINTERACTIVE=1 HARNESS_CLI="$1" \
    HARNESS_OWNER=acme HARNESS_REPO=acme/widget HARNESS_SESS_PREFIX=hzseam \
    bash "$ROOT/scripts/init.sh" ) >"$I/out" 2>&1; }
run_init bogus-cli; rc=$?
assert_no "init with an unknown CLI exits non-zero" test "$rc" = 0
assert_no "…and writes no config" test -f "$I/proj/.harness/config"
assert_ok "…and lists the CLIs it has" grep -q "unknown agent CLI: bogus-cli (have: agy claude codex copilot hermes openclaw opencode)" "$I/out"
run_init agy; rc=$?
assert_eq "$rc" "0" "init accepts a CLI that has an adapter"
assert_ok "…and writes it" grep -qx ': "${HARNESS_CLI:=agy}"' "$I/proj/.harness/config"

echo "=== 6: a lane's own model and effort reach the launch line, on every CLI ==="
SENT="$RUN_DIR/sent"
tmux(){ case "$1" in has-session) return 1 ;; send-keys) shift; echo "$*" >> "$SENT" ;; esac; return 0; }
sleep(){ :; }
for cli in $(cli_list); do
  WD="$RUN_DIR/lane-$cli"; mkdir -p "$WD"; git -C "$WD" init -q
  echo "task" > "$WD/.harness-task.md"
  printf 'model=lane-model-x\neffort=low\n' > "$WD/.harness-lane"   # what a worktree hook writes
  : > "$SENT"
  ( cli_load "$cli"; HARNESS_AUTONOMOUS=false launch_agent "hz-lane-$cli" "$WD" )
  line="$(grep -m1 -F 'exec ' "$SENT")"
  # Each CLI spells the effort its own way (fixtures/cli/<cli>/effort-flag: `--effort `, or codex's
  # `-c model_reasoning_effort=`, copilot's `--effort=`; opencode's is no flag but the `variant=` its
  # lane settings name) and the model as --model or -m, copilot's with `=` (hermes's is no flag but the
  # `model.default=` its lane settings name: Hermes refuses -m beside `-c <title>`).
  ef="$(cat "$HERE/fixtures/cli/$cli/effort-flag")"
  effort="$line"$'\n'"$( cli_load "$cli"; cli_lane_settings "$WD" )"
  assert_ok "$cli: the launch carries the lane's model" grep -qE -- "(--model|-m)[= ]lane-model-x|^model\.default=lane-model-x$" <<<"$effort"
  assert_eq "$(grep -oE -- '(^| )(--model|-m)[= ]|^model\.default=' <<<"$effort" | wc -l)" "1" "$cli: the model is given once"
  assert_ok "$cli: the launch carries the lane's effort" grep -qF -- "${ef}low" <<<"$effort"
  assert_eq "$(grep -oF -- "$ef" <<<"$effort" | wc -l)" "1" "$cli: the configured effort is replaced, not repeated"
  assert_ok "$cli: .harness-lane is kept out of the lane's commits" \
    grep -qxF .harness-lane "$(git -C "$WD" rev-parse --absolute-git-dir)/info/exclude"
  rm -f "$WD/.harness-lane"; : > "$SENT"
  ( cli_load "$cli"; HARNESS_AUTONOMOUS=false launch_agent "hz-lane2-$cli" "$WD" )
  assert_no "$cli: no .harness-lane, no lane model on the launch line" grep -qF -- "lane-model-x" "$SENT"
done
unset -f tmux sleep

echo "=== 7: a launch's model and effort come from the adapter (#307) ==="
WD="$RUN_DIR/me-claude"; mkdir -p "$WD/.claude"
assert_eq "$(cli_with claude cli_model_effort 'exec claude --model=opus --effort high "go"' "$WD")" $'opus\thigh' \
  "claude: --model=/--effort on the line"
printf '{"model": "haiku"}' > "$WD/.claude/settings.json"
assert_eq "$(cli_with claude cli_model_effort 'exec claude --effort=max "go"' "$WD")" $'haiku\tmax' \
  "claude: no --model → the worktree's settings.json"
printf '{"model": "sonnet"}' > "$WD/.claude/settings.local.json"
assert_eq "$(cli_with claude cli_model_effort 'exec claude --effort=max "go"' "$WD")" $'sonnet\tmax' \
  "claude: …settings.local.json (a worktree hook's pin) over settings.json"
assert_eq "$(cli_with claude cli_model_effort 'exec claude --model opus "go"' "$WD")" $'opus\t' "claude: the line's --model wins"
assert_eq "$(cli_with codex cli_model_effort 'exec codex -m gpt-5.6-luna -c model_reasoning_effort="low" "go"' "$WD")" \
  $'gpt-5.6-luna\tlow' "codex: -m and the -c model_reasoning_effort= override, quotes dropped"
assert_eq "$(cli_with copilot cli_model_effort 'exec copilot --model=gpt-4.1 --reasoning-effort=xhigh -i "go"' "$WD")" \
  $'gpt-4.1\txhigh' "copilot: --reasoning-effort= is its effort too"
assert_eq "$(cli_with agy cli_model_effort 'exec agy -i "go"' "$WD")" $'\t' "a line that names neither: both empty (the CLI's default)"

echo "=== 8: the goal-loop script lives at a CLI-neutral path (#307) ==="
assert_eq "$(cd "$ROOT" && grep -n 'plugins/codex' scripts/*.sh scripts/*.py)" "" "no top-level script reaches into plugins/codex"
assert_eq "$GOAL_LOOP_PY" "$ENGINE_DIR/scripts/goal_loop.py" "the driven loop runs scripts/goal_loop.py"
assert_ok "Codex's Stop hook is a byte-for-byte copy of it (Codex copies a plugin into its cache)" \
  cmp -s "$ROOT/scripts/goal_loop.py" "$ROOT/plugins/codex/harness-ralph/hooks/stop-hook.py"

finish

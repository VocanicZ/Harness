#!/usr/bin/env bash
# test_headless_adapters.sh — #480 / PRD #475: cli_headless_list and the tmux-only refusal derive from the
# headless adapters present (scripts/cli/<cli>_headless.py), so a new adapter enables its CLI on the
# headless backend with no edit to dispatch.sh. Runs against a COPY of scripts/ with a made-up CLI added.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -r "$ROOT/scripts" "$TMP/scripts"
CLID="$TMP/scripts/cli"
list(){ ( source "$CLID/dispatch.sh"; cli_headless_list | xargs ); }
check(){ ( export HARNESS_SESSION_BACKEND=headless HARNESS_CLI="$1"; source "$CLID/dispatch.sh"; cli_backend_check 2>&1 ); }

echo "== the adapters present are the headless CLIs =="
assert_eq "$(list)" "claude codex copilot hermes openclaw opencode" "claude, codex, copilot (#483), hermes, openclaw and opencode are the CLIs with an adapter"
assert_eq "$(ls "$CLID"/*_headless.py | xargs -n1 basename | xargs)" "claude_headless.py codex_headless.py copilot_headless.py hermes_headless.py openclaw_headless.py opencode_headless.py" "…and <cli>_headless.py is each one's adapter"
assert_ok "headless_core.py is no CLI's adapter" test -f "$CLID/headless_core.py"
assert_no "…and not listed as a CLI" bash -c "source '$CLID/dispatch.sh'; cli_list | grep -q headless"

echo "== a new adapter enables its CLI, with no edit to dispatch.sh =="
printf '# fakecli — a made-up CLI for this test\nfakecli_bin(){ echo fakecli; }\n' > "$CLID/fakecli.sh"
assert_eq "$(list)" "claude codex copilot hermes openclaw opencode" "a CLI with no adapter is still tmux-only"
msg="$(check fakecli)"; rc=$?
assert_ok "…refused on headless, naming it" grep -qF "agent CLI 'fakecli' is tmux-only" <<<"$msg"
assert_ok "…and pointing at the headless CLIs" grep -qF "runs claude, codex, copilot, hermes, openclaw, opencode lanes only" <<<"$msg"
: > "$CLID/fakecli_headless.py"
assert_eq "$(list)" "claude codex copilot fakecli hermes openclaw opencode" "drop in fakecli_headless.py and it is listed"
out="$(check fakecli)"; rc=$?
assert_eq "$rc" 0 "…and cli_backend_check accepts it on headless"
assert_eq "$out" "" "…silently"
assert_ok "…and the refusal for another CLI names both headless CLIs" grep -qF "runs claude, codex, copilot, fakecli, hermes, openclaw, opencode lanes only" <<<"$(check agy)"

echo "== copilot's runner: its own command, the adapter's bin and the session as --session-id (#483) =="
argv="$( export HARNESS_CLI=copilot HARNESS_BOOTSTRAP_PROMPT=go HARNESS_COPILOT_BIN=cop HARNESS_COPILOT_FLAGS="--yolo --no-ask-user --no-auto-update"; source "$CLID/dispatch.sh"; cli_headless /wd uuid-1 gpt-6-luna high resume | xargs -d '\n' printf '%s|' )"
assert_eq "$argv" "python3|$CLID/copilot_headless.py|run|--cwd|/wd|--bin|cop|--session-id|uuid-1|--resume|--flags=--yolo --no-ask-user --no-auto-update --model=gpt-6-luna --effort=high|--message|go|" "cli_headless for copilot: the lane's model and effort replace the configured flags'"
argv="$( export HARNESS_CLI=copilot HARNESS_BOOTSTRAP_PROMPT=go HARNESS_COPILOT_BIN=cop HARNESS_COPILOT_FLAGS="--yolo --model=old"; source "$CLID/dispatch.sh"; cli_headless /wd uuid-1 "" high | xargs -d '\n' printf '%s|' )"
assert_ok "…an operator's --model stays when the lane names none (and takes the effort, its model being named)" grep -qF -- "--flags=--yolo --model=old --effort=high|" <<<"$argv"
assert_no "…and Auto (no model named) takes no --effort, which -p refuses" grep -qF -- "--effort" <<<"$(export HARNESS_CLI=copilot HARNESS_BOOTSTRAP_PROMPT=go HARNESS_COPILOT_FLAGS=--yolo; source "$CLID/dispatch.sh"; cli_headless /wd u "" high | xargs -d '\n' printf '%s|')"

echo "== codex has a runner command of its own: exec flags, no TUI flag =="
argv="$( export HARNESS_CLI=codex HARNESS_BOOTSTRAP_PROMPT=go HARNESS_CODEX_FLAGS='--no-alt-screen --dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort=high'; source "$CLID/dispatch.sh"; cli_headless /wd uuid-1 mdl low | xargs -d '\n' printf '%s|' )"
assert_eq "$argv" "python3|$CLID/codex_headless.py|run|--cwd|/wd|--bin|codex|--session-id|uuid-1|--flags=--dangerously-bypass-approvals-and-sandbox -m mdl -c model_reasoning_effort=low|--message|go|" "cli_headless for codex: no --no-alt-screen, the lane's model and effort replacing the configured ones"
assert_ok "…and a resume names the thread to carry on" grep -qxF -- "--resume" <<<"$( export HARNESS_CLI=codex HARNESS_BOOTSTRAP_PROMPT=go; source "$CLID/dispatch.sh"; cli_headless /wd tid m e resume )"

echo "== the default runner command starts the adapter's runner =="
argv="$( export HARNESS_CLI=fakecli HARNESS_BOOTSTRAP_PROMPT=go; source "$CLID/dispatch.sh"; cli_headless /wd uuid-1 mdl hi resume | xargs -d '\n' printf '%s|' )"
assert_eq "$argv" "python3|$CLID/fakecli_headless.py|run|--cwd|/wd|--session-id|uuid-1|--resume|--model|mdl|--effort|hi|--message|go|" "cli_headless for an adapter-only CLI"
out="$( export HARNESS_CLI=agy; source "$CLID/dispatch.sh"; cli_headless /wd uuid-1 m e 2>&1 )"; rc=$?
assert_eq "$rc" 1 "a CLI with no adapter has no headless command"
assert_ok "…it is tmux-only" grep -qF "agent CLI 'agy' is tmux-only" <<<"$out"
finish

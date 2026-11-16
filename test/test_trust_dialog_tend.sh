#!/usr/bin/env bash
# test_trust_dialog_tend.sh — #1237: a Claude lane that sits on the "Yes, I trust this folder" dialog for ITS OWN worktree is
# answered by the worker's tend tick (trust_dialog_tend, drive.sh): Down, a re-read that shows `❯ Yes, I trust this folder`
# selected, then Enter (the cursor starts on `❯ No, exit`: a bare Enter ends the session). Nothing else is ever typed into a dialog:
#   - another path (or one that merely starts with the lane's worktree) → no keys
#   - Bypass Permissions / CLAUDE.md imports / the limit menu → no keys
#   - a non-Claude CLI's trust dialog → no keys (the adapter hook defaults to a no-op)
#   - a dialog still showing after 3 answers → no fourth; the lane is reported stuck, trust_dialog_unanswered
set -uo pipefail
unset ENGINE_DIR
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
FIX="$HERE/fixtures/cli"
S=hz-main-i5

# The pane the stub tmux serves. `send-keys … Down` moves the cursor to the Yes row (PANE_DOWN_WORKS=0: it does not), and `Enter`
# is only logged. Every key sent lands in $CALLS.
setup(){
  make_env
  HARNESS_SESS_PREFIX=hz; HARNESS_CLI=claude; export HARNESS_CLI
  CALLS="$RUN_DIR/calls"; : > "$CALLS"; EVENTS="$RUN_DIR/events"; : > "$EVENTS"; LOGF="$RUN_DIR/log"; : > "$LOGF"
  PANE="$RUN_DIR/pane"; PANE_DOWN_WORKS=1; export CALLS PANE PANE_DOWN_WORKS
  tmux(){ case "$1" in
      has-session) return 0;;
      capture-pane) cat "$PANE";;
      send-keys) echo "tmux $*" >> "$CALLS"
        if [[ "$*" == *" Down"* && "${PANE_DOWN_WORKS:-1}" == 1 ]]; then
          sed -e 's/^ ❯ No, exit/   No, exit/' -e 's/^   Yes, I trust this folder/ ❯ Yes, I trust this folder/' "$PANE" > "$PANE.n"; mv "$PANE.n" "$PANE"
        fi;;
    esac; }
  export -f tmux
  harness_event(){ echo "$*" >> "$EVENTS"; }
  log(){ echo "$*" >> "$LOGF"; }
  export HARNESS_TRUST_KEY_DELAY_S=0
}
# the lane's worktree is whatever .wd says
lane_wd(){ echo "$1" > "$RUN_DIR/$S.wd"; }
keys(){ grep -c "send-keys" "$CALLS"; }
PLAIN_WD="/tmp/claude-1000/-home-claude-harness-dev--harness-worktrees-harness-i188/df46c444-3d54-448f-b5e0-4ac14b620474/scratchpad/cap/claude/repo"
WRAPPED_WD="/tmp/hzt-2474852314/bench-run-796y_uen/clone/.harness/worktrees/bench-run-20261116-small-harness-harness-r02-i2"

echo "=== the dialog for the lane's own worktree (single-line path): Down, confirm Yes selected, Enter ==="
setup; cp "$FIX/claude/trust.txt" "$PANE"; lane_wd "$PLAIN_WD"
trust_dialog_tend "$S"
assert_eq "$(sed -n 1p "$CALLS")" "tmux send-keys -t $S Down" "first key: Down"
assert_eq "$(sed -n 2p "$CALLS")" "tmux send-keys -t $S Enter" "second key: Enter (Yes is now selected)"
assert_eq "$(keys)" "2" "exactly two keys"
assert_ok "trust_dialog_answered stats event" grep -q "trust_dialog_answered" "$EVENTS"
assert_ok "and a log line" grep -qi "trust" "$LOGF"
assert_eq "$(cat "$RUN_DIR/$S.trustanswers")" "1" "one answer counted"

echo "=== the same, the path wrapped at 80 columns ==="
setup; cp "$FIX/claude/trust-wrapped.txt" "$PANE"; lane_wd "$WRAPPED_WD"
trust_dialog_tend "$S"
assert_eq "$(sed -n 1p "$CALLS")" "tmux send-keys -t $S Down" "wrapped: Down"
assert_eq "$(sed -n 2p "$CALLS")" "tmux send-keys -t $S Enter" "wrapped: Enter"
assert_ok "wrapped: trust_dialog_answered" grep -q "trust_dialog_answered" "$EVENTS"

echo "=== Enter is NEVER sent unless Yes is the selected row ==="
setup; cp "$FIX/claude/trust.txt" "$PANE"; lane_wd "$PLAIN_WD"; PANE_DOWN_WORKS=0
trust_dialog_tend "$S"
assert_eq "$(keys)" "1" "Down was sent, the pane still reads No: no Enter"
assert_no "no Enter" grep -q "Enter" "$CALLS"
assert_no "no answered event" grep -q "trust_dialog_answered" "$EVENTS"

echo "=== another path: no keys ==="
setup; cp "$FIX/claude/trust.txt" "$PANE"; lane_wd "/some/other/worktree"
trust_dialog_tend "$S"
assert_eq "$(keys)" "0" "a different worktree's dialog is not answered"
echo "=== a path that merely STARTS with the lane's worktree: no keys ==="
setup; cp "$FIX/claude/trust.txt" "$PANE"; lane_wd "${PLAIN_WD%/repo}"
trust_dialog_tend "$S"
assert_eq "$(keys)" "0" "a longer path under the worktree is not the worktree"
setup; cp "$FIX/claude/trust-wrapped.txt" "$PANE"; lane_wd "${WRAPPED_WD}-and-more"
trust_dialog_tend "$S"; assert_eq "$(keys)" "0" "wrapped: the lane's path is longer than the dialog's"
setup; cp "$FIX/claude/trust-wrapped.txt" "$PANE"; lane_wd "/tmp/hzt-2474852314/bench-run-796y_uen/clone/.harness/worktrees/bench-run-2026"
trust_dialog_tend "$S"; assert_eq "$(keys)" "0" "wrapped: the first line alone (a prefix) is not the path"
echo "=== no .wd: no keys ==="
setup; cp "$FIX/claude/trust.txt" "$PANE"
trust_dialog_tend "$S"; assert_eq "$(keys)" "0" "a lane with no worktree on record"

echo "=== Windows: the lane's wd is /c/x, the dialog names C:/x ==="
setup
mkdir -p "$RUN_DIR/cyg"
cat > "$RUN_DIR/cyg/cygpath" <<'CYG'
#!/bin/sh
case "$2" in /[a-z]/*) printf '%s:%s\n' "$(printf %s "$2" | cut -c2 | tr a-z A-Z)" "$(printf %s "$2" | cut -c3-)";; *) printf '%s\n' "$2";; esac
CYG
chmod +x "$RUN_DIR/cyg/cygpath"
sed 's#/tmp/claude-1000/[^ ]*/repo#C:/hx-win/lane#' "$FIX/claude/trust.txt" > "$PANE"; lane_wd "/c/hx-win/lane"
PATH="$RUN_DIR/cyg:$PATH" HARNESS_PLATFORM=windows trust_dialog_tend "$S"
assert_eq "$(keys)" "2" "the native spelling of the lane's wd matches"

echo "=== other dialogs are never typed into ==="
for f in bypass-dialog imports-dialog limit; do
  setup; cp "$FIX/claude/$f.txt" "$PANE"; lane_wd "$PLAIN_WD"
  trust_dialog_tend "$S"; assert_eq "$(keys)" "0" "claude $f: no keys"
done
setup; printf '%s\n' 'working…' '❯ ' > "$PANE"; lane_wd "$PLAIN_WD"
trust_dialog_tend "$S"; assert_eq "$(keys)" "0" "an idle prompt: no keys"

echo "=== a non-Claude CLI's trust dialog is not answered ==="
for cli in codex agy copilot; do
  setup; export HARNESS_CLI="$cli"; cp "$FIX/$cli/trust.txt" "$PANE"
  lane_wd "$(grep -A2 'Accessing workspace' "$PANE" | tail -1 | sed 's/^ *//')"
  trust_dialog_tend "$S"; assert_eq "$(keys)" "0" "$cli: no keys"
  assert_eq "$(cli_trust_dialog_path "$(cat "$PANE")")" "" "$cli: the adapter hook is a no-op"
done
export HARNESS_CLI=claude

echo "=== the bound: 3 answers, then the lane is reported stuck and never typed into again ==="
setup; lane_wd "$PLAIN_WD"
for i in 1 2 3; do cp "$FIX/claude/trust.txt" "$PANE"; trust_dialog_tend "$S"; done
assert_eq "$(keys)" "6" "three answers = three Down + Enter pairs"
assert_eq "$(cat "$RUN_DIR/$S.trustanswers")" "3" "three counted"
assert_no "not stuck yet" grep -q "trust_dialog_unanswered" "$EVENTS"
cp "$FIX/claude/trust.txt" "$PANE"; trust_dialog_tend "$S"
assert_eq "$(keys)" "6" "no fourth answer"
assert_ok "stuck: reason trust_dialog_unanswered (stats event)" grep -q "trust_dialog_unanswered" "$EVENTS"
assert_ok "and logged" grep -q "trust_dialog_unanswered" "$LOGF"
n="$(grep -c trust_dialog_unanswered "$EVENTS")"
cp "$FIX/claude/trust.txt" "$PANE"; trust_dialog_tend "$S"
assert_eq "$(keys)" "6" "still no key"
assert_eq "$(grep -c trust_dialog_unanswered "$EVENTS")" "$n" "the stuck report is made once"

echo "=== wiring: every tend step reaches trust_dialog_tend ==="
for fn in tend_lane_done bug_lane_tend; do
  :
done
assert_ok "bug_lane_tend calls it" bash -c "sed -n '/^bug_lane_tend()/,/^bug_lane_reap_worktrees/p' '$HERE/../scripts/drive.sh' | grep -q trust_dialog_tend"
assert_ok "tend_lane_done calls it for impl + orch lanes" bash -c "[[ \$(sed -n '/^tend_lane_done()/,/^# --- #594/p' '$HERE/../scripts/pool-worker.sh' | grep -c trust_dialog_tend) -ge 2 ]]"
assert_ok "the priority worker's bug loop calls it" grep -q 'trust_dialog_tend' "$HERE/../scripts/priority-worker.sh"
finish

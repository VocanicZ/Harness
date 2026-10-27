#!/usr/bin/env bash
# test_cli_matrix.sh — #188 / PRD #189: every feature row for every CLI that has an adapter, run
# against fixtures captured from the real CLI (test/fixtures/cli/<cli>/, see each README.md). One
# cell per row; the README's support table is checked against these cells (test_cli_readme.sh).
# --tsv prints `<cli>\t<row>\tok|FAIL` per cell instead of asserting.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"
FIX="$HERE/fixtures/cli"
TSV=0; [[ "${1:-}" == --tsv ]] && TSV=1
cell(){ local cli="$1" row="$2"; shift 2
  if (( TSV )); then
    if "$@" >/dev/null 2>&1; then printf '%s\t%s\tok\n' "$cli" "$row"; else printf '%s\t%s\tFAIL\n' "$cli" "$row"; fi
  else assert_ok "$cli: $row" "$@"; fi; }
pane(){ cat "$FIX/$1/$2.txt"; }
has(){ grep -qF -- "$1" <<<"$2"; }
lacks(){ ! grep -qF -- "$1" <<<"$2"; }
not(){ ! "$@"; }
every_busy_is_busy(){ local f; for f in "$FIX/$1"/busy*.txt; do cli_pane_busy "$(cat "$f")" || return 1; done; }
# A running turn whose own output shows the CLI's transient-error line (a 500 in a log tail, the
# agent quoting it) is still a running turn: the watchdog must never nudge or kill it.
no_busy_stalls(){ local f err; err="$(grep -vxF -f "$FIX/$1/idle.txt" "$FIX/$1/transient.txt" | grep -v '^$')"
  [[ -n "$err" ]] || return 1
  for f in "$FIX/$1"/busy*.txt; do session_stalled "$err"$'\n'"$(cat "$f")" && return 1; done; return 0; }
same(){ [[ "$1" == "$2" ]]; }

# plant_cli_home <cli> <wd> — put the fixture's own transcript and session map where the adapter
# looks for them (the stats.py / agy-home seams make_env pinned into RUN_DIR).
plant_cli_home(){ local cli="$1" wd="$2" sid; sid="$(cat "$FIX/$cli/session")"
  mkdir -p "$HARNESS_CLAUDE_CONFIG_DIRS/projects/fixture" "$HARNESS_AGY_HOME/cache" "$HARNESS_AGY_HOME/conversations"
  case "$cli" in
    claude) cp "$FIX/claude/transcript.jsonl" "$HARNESS_CLAUDE_CONFIG_DIRS/projects/fixture/$sid.jsonl" ;;
    agy)    sed "s#@WD@#$wd#" "$FIX/agy/last_conversations.json" > "$HARNESS_AGY_HOME/cache/last_conversations.json"
            cp "$FIX/agy/transcript.db" "$HARNESS_AGY_HOME/conversations/$sid.db" ;;
  esac; }
# usage_windows_ok <cli> — the CLI's usage windows, read through the adapter from the fixture's real
# source, report the expected <account> <window> <pct used>.
usage_windows_ok(){ local cli="$1" got bin
  rm -rf "$(_usage_dir)"; mkdir -p "$(_usage_dir)"
  case "$cli" in
    claude) python3 - "$FIX/claude/usage-drop.json" "$(_usage_dir)/main.json" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
for w in d["rate_limits"].values():
    w["resets_at"] = int(time.time()) + 3600      # a passed reset is (correctly) skipped
json.dump(d, open(sys.argv[2], "w"))
PY
      ;;
    agy) bin="$RUN_DIR/bin/agy"; mkdir -p "${bin%/*}"
      printf '#!/bin/sh\n[ "$1 $2 $3 $4" = "-p /usage --output-format json" ] && exec cat %q\nexit 2\n' "$FIX/agy/usage-windows.json" > "$bin"
      chmod +x "$bin"; export HARNESS_AGY_BIN="$bin" ;;
  esac
  got="$(unset HARNESS_USAGE_CMD; cli_limit_usage | cut -f1-3 | sort)"
  [[ -n "$got" && "$got" == "$(sort "$FIX/$cli/usage-windows.expected")" ]]; }
# send_and_kill_ok — cli_send delivers the text then Enter to the session; cli_kill ends it.
send_and_kill_ok(){ local log="$RUN_DIR/tmux.calls"; : > "$log"
  ( tmux(){ echo "$*" >> "$log"; }
    cli_send hz-x-i1 "$RUN_DIR" "Please continue — hello"; cli_kill hz-x-i1 "$RUN_DIR" )
  grep -qxF 'send-keys -t hz-x-i1 -l Please continue — hello' "$log" && grep -qxF 'send-keys -t hz-x-i1 Enter' "$log" \
    && grep -qxF 'kill-session -t hz-x-i1' "$log"; }
# session_end_usage_ok <wd> <session> — #185 through the seam: a session_end event for a session of
# this CLI carries the per-model usage its own transcripts hold.
session_end_usage_ok(){ local ctx="$RUN_DIR/ctx.json"
  printf '{"worktree": "%s", "session": "%s", "kind": "impl"}' "$1" "$2" > "$ctx"
  rm -f "$HARNESS_EVENTS_FILE"
  harness_event session_end --ctx "$ctx" usage_tsv="$(_stats_cli_usage "$ctx")"
  python3 - "$HARNESS_EVENTS_FILE" "$FIX/$(cli_name)/usage.expected" <<'PY'
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1])][-1]
want = {}
for line in open(sys.argv[2]):
    m, i, o, cr, cw = line.rstrip("\n").split("\t")
    want[m] = {"input": int(i), "output": int(o), "cache_read": int(cr), "cache_create": int(cw)}
sys.exit(0 if ev.get("usage") == want else 1)
PY
}
# done_signal_ok <wd> — the goal loop is running while its state file exists, ended once it is gone.
done_signal_ok(){ local wd="$1"
  write_state "$wd" "ISSUE 1 DONE" 5 x
  cli_done "$wd" && return 1
  rm -f "$wd/.claude/ralph-loop.local.md"
  cli_done "$wd"; }

rc=0
for cli in $(cli_list); do
  ( cli_load "$cli" || exit 1
    F="$FIX/$cli"; WD="$RUN_DIR/$cli-wd"; mkdir -p "$WD"; git -C "$WD" init -q
    printf 'GOAL: UNIQUE_TASK_MARKER\n' > "$WD/.harness-task.md"
    SID="$(cat "$F/session")"; MODEL="$(cat "$F/model")"
    plant_cli_home "$cli" "$WD"
    cell "$cli" fixtures-recorded          test -s "$F/VERSION"
    line="$(cli_launch "$WD" "$SID" "$MODEL" high)"
    cell "$cli" launch-bootstrap-prompt    has "$HARNESS_BOOTSTRAP_PROMPT" "$line$(cli_first_input high)"
    cell "$cli" launch-no-task-text        lacks UNIQUE_TASK_MARKER "$line"
    cell "$cli" launch-model               has "$MODEL" "$line$(cli_lane_settings "$WD")"
    cell "$cli" launch-effort-once         same "$(grep -o -- '--effort' <<<"$line" | wc -l)" 1
    cell "$cli" session-id                 same "$(cli_session_id "$WD" "$SID")" "$SID"
    cell "$cli" idle-is-prompt             cli_pane_prompt "$(pane "$cli" idle)"
    cell "$cli" idle-is-not-busy           not cli_pane_busy "$(pane "$cli" idle)"
    cell "$cli" busy-is-busy               every_busy_is_busy "$cli"
    [[ -f "$F/trust.txt" ]] && cell "$cli" trust-dialog-is-not-prompt not cli_pane_prompt "$(pane "$cli" trust)"
    cell "$cli" transient-stalls           session_stalled "$(pane "$cli" transient)"
    cell "$cli" idle-never-stalls          not session_stalled "$(pane "$cli" idle)"
    cell "$cli" busy-never-stalls          no_busy_stalls "$cli"
    cell "$cli" limit-parks                session_limit_idle "$(pane "$cli" limit)"
    cell "$cli" transient-is-not-limit     not session_limit_idle "$(pane "$cli" transient)"
    cli_trust "$WD";  cell "$cli" trust-pre-accepted       cli_trusted "$WD"
    cli_bypass "$WD"; cell "$cli" bypass-covers-subagents  cli_bypassed "$WD"
    cell "$cli" done-signal                done_signal_ok "$WD"
    cell "$cli" loop-mode                  grep -qxE 'hook|driven' <<<"$(cli_loop)"
    cell "$cli" transcripts-found          test -n "$(cli_transcripts "$WD" "$(cli_session_id "$WD" "$SID")")"
    cell "$cli" usage-from-transcript      same "$(cli_usage "$(cli_transcripts "$WD" "$(cli_session_id "$WD" "$SID")" | head -1)" | sort)" "$(sort "$F/usage.expected")"
    cell "$cli" stats-session-end-usage    session_end_usage_ok "$WD" "$SID"
    cell "$cli" usage-windows              usage_windows_ok "$cli"
    cell "$cli" checkpoint-skill           test -n "$(cli_skill handoff)"
    cell "$cli" send-and-kill              send_and_kill_ok
    cell "$cli" prereqs-named              grep -qF "$cli" <<<"$(cli_prereqs 2>&1)"
    (( TSV )) || finish ) || rc=1
done
exit "$rc"

#!/usr/bin/env bash
# test_cli_matrix.sh — #188 / PRD #189: every feature row for every CLI that has an adapter, run
# against fixtures captured from the real CLI (test/fixtures/cli/<cli>/, see each README.md). One
# cell per row, each driving Harness's own code path for the feature (launch_agent, inject.sh, the
# drive.sh lanes, pause.sh, supervise.sh, stats.py, init.sh) through the adapter (#254). The README's
# support table is checked against these cells (test_cli_readme.sh).
# --tsv prints `<cli>\t<row>\tok|FAIL|n/a:<reason>` per cell instead of asserting.
# test_cli_matrix_guard.sh reruns it on a cut-down fixture tree (HARNESS_MATRIX_FIX), for some CLIs
# (HARNESS_MATRIX_CLIS), with adapter functions stubbed to `:` (HARNESS_MATRIX_STUB="trust trusted").
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"
FIX="${HARNESS_MATRIX_FIX:-$HERE/fixtures/cli}"
# Every pane below runs the CLI's fake (fixtures/cli/<cli>/fake-cli) from PATH, under its plain name.
unset CLAUDE_BIN AGY_BIN; export HARNESS_CLAUDE_BIN=claude HARNESS_AGY_BIN=agy HARNESS_CODEX_BIN=codex HARNESS_COPILOT_BIN=copilot HARNESS_OPENCODE_BIN=opencode HARNESS_HERMES_BIN=hermes HARNESS_OPENCLAW_BIN=openclaw FIX
TSV=0; [[ "${1:-}" == --tsv ]] && TSV=1
cell(){ local cli="$1" row="$2"; shift 2
  if (( TSV )); then
    if "$@" >/dev/null 2>&1; then printf '%s\t%s\tok\n' "$cli" "$row"; else printf '%s\t%s\tFAIL\n' "$cli" "$row"; fi
  else assert_ok "$cli: $row" "$@"; fi; }
# na <cli> <row> <reason> — a row that cannot exist for this CLI; the README cell shows the reason.
na(){ if (( TSV )); then printf '%s\t%s\tn/a:%s\n' "$1" "$2" "$3"; else echo "  n/a: $1: $2 — $3"; fi; }
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
    codex)  mkdir -p "$CODEX_HOME/sessions/2026/10/27"
            sed "s#@CWD@#$wd#" "$FIX/codex/transcript.jsonl" > "$CODEX_HOME/sessions/2026/10/27/rollout-2026-10-27T22-47-16-$sid.jsonl" ;;
    copilot) mkdir -p "$COPILOT_HOME/session-state/$sid"
            sed "s#@CWD@#$wd#" "$FIX/copilot/transcript.jsonl" > "$COPILOT_HOME/session-state/$sid/events.jsonl" ;;
    opencode) mkdir -p "$XDG_DATA_HOME/opencode"; cp "$FIX/opencode/transcript.db" "$XDG_DATA_HOME/opencode/opencode.db"
            python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("UPDATE session SET directory = ?", (sys.argv[2],)); c.commit()' "$XDG_DATA_HOME/opencode/opencode.db" "$wd" ;;
    hermes) mkdir -p "$(_hermes_home "$wd")"; cp "$FIX/hermes/transcript.db" "$(_hermes_db "$wd")" ;;
    openclaw) mkdir -p "$wd/.harness-openclaw/runs"; cp "$FIX/openclaw/transcript.jsonl" "$(_openclaw_runs "$wd" "$sid")" ;;
  esac; }
# usage_windows_ok <cli> — the CLI's usage windows, read through the adapter from the fixture's real
# source, report the expected <account> <window> <pct used>.
usage_windows_ok(){ ( local cli="$1" got bin
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
    codex) export CODEX_HOME="$RUN_DIR/codex-usage"; mkdir -p "$CODEX_HOME/sessions/2026/10/27"
      python3 - "$FIX/codex/transcript.jsonl" "$CODEX_HOME/sessions/2026/10/27/rollout-2026-10-27T22-47-16-$(cat "$FIX/codex/session").jsonl" <<'PY'
import json, sys, time
with open(sys.argv[2], "w") as out:
    for line in open(sys.argv[1]):
        d = json.loads(line)
        for w in ((d.get("payload") or {}).get("rate_limits") or {}).values():
            if isinstance(w, dict) and "resets_at" in w:
                w["resets_at"] = int(time.time()) + 3600      # a passed reset is (correctly) skipped
        print(json.dumps(d), file=out)
PY
      ;;
    copilot) export COPILOT_HOME="$RUN_DIR/copilot-usage"; mkdir -p "$COPILOT_HOME/session-state/$(cat "$FIX/copilot/session")"
      python3 - "$FIX/copilot/transcript.jsonl" "$COPILOT_HOME/session-state/$(cat "$FIX/copilot/session")/events.jsonl" <<'PY'
import json, sys, time
reset = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600))   # a passed reset is (correctly) skipped
with open(sys.argv[2], "w") as out:
    for line in open(sys.argv[1]):
        d = json.loads(line)
        for q in ((d.get("data") or {}).get("quotaSnapshots") or {}).values():
            q["resetDate"] = reset
        print(json.dumps(d), file=out)
PY
      ;;
    hermes|openclaw) bin="$RUN_DIR/bin/$cli"; mkdir -p "${bin%/*}"
      python3 - "$FIX/$cli/usage-windows.json" "$RUN_DIR/$cli-usage.json" <<'PY'
import json, sys, time
from datetime import datetime, timezone
d = json.load(open(sys.argv[1]))
reset = time.time() + 3600                     # a passed reset is (correctly) skipped
for w in d.get("windows") or []:               # hermes usage --json
    w["resets_at"] = datetime.fromtimestamp(reset, timezone.utc).isoformat()
for p in (d.get("usage") or {}).get("providers") or []:   # openclaw status --usage --json
    for w in p["windows"]:
        w["resetAt"] = int(reset * 1000)
json.dump(d, open(sys.argv[2], "w"))
PY
      if [[ $cli == hermes ]]; then printf '#!/bin/sh\n[ "$1 $2" = "usage --json" ] && exec cat %q\nexit 2\n' "$RUN_DIR/$cli-usage.json" > "$bin"
      else printf '#!/bin/sh\n[ "$1 $2 $3" = "status --usage --json" ] && exec cat %q\nexit 2\n' "$RUN_DIR/$cli-usage.json" > "$bin"; fi
      chmod +x "$bin"; export "HARNESS_${cli^^}_BIN=$bin" ;;
  esac
  got="$(unset HARNESS_USAGE_CMD; cli_limit_usage | cut -f1-3 | sort)"
  [[ -n "$got" && "$got" == "$(sort "$FIX/$cli/usage-windows.expected")" ]] ); }
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
# launch_event_ok <model> <effort> — #307: the `launch` event launch_agent logs for a lane pinned to
# <model>/<effort> (.harness-lane, as launch-model pins it) carries both, read through the adapter
# (cli_model_effort) off the CLI's own launch line and lane config.
launch_event_ok(){ ( fake_tmux; local wd="$RUN_DIR/launch-ev-$HARNESS_CLI"; new_wd "$wd"; GOAL=ISSUE:6
  export HARNESS_EVENTS_FILE="$RUN_DIR/launch-ev-$HARNESS_CLI.jsonl"; rm -f "$HARNESS_EVENTS_FILE"
  printf 'model=%s\neffort=%s\n' "$1" "$2" > "$wd/$HARNESS_LANE_FILE"
  launch_agent hz-ev-i6 "$wd" >/dev/null 2>&1
  python3 - "$HARNESS_EVENTS_FILE" "$1" "$2" <<'PY'
import json, sys
ev = [e for e in map(json.loads, open(sys.argv[1])) if e.get("event") == "launch"]
sys.exit(0 if ev and ev[-1].get("model") == sys.argv[2] and ev[-1].get("effort") == sys.argv[3] else 1)
PY
) }
# done_signal_ok <wd> — the goal loop is running while its state file exists, ended once it is gone.
done_signal_ok(){ local wd="$1"
  write_state "$wd" "ISSUE 1 DONE" 5 x
  cli_done "$wd" && return 1
  rm -f "$wd/.claude/ralph-loop.local.md"
  cli_done "$wd"; }

# --- the real code paths, with tmux and GitHub faked ----------------------------------------------
# fake_tmux — tmux as Harness drives it, each call one line of $TMUXLOG (its args tab-separated): no
# session is live yet, a pane shows the CLI's idle prompt, `ls` lists $FAKE_LIVE. Exported, so a
# script Harness runs as a child (pause.sh) drives it too. launch_agent's sleeps are skipped.
fake_tmux(){ export TMUXLOG="$RUN_DIR/tmux.$BASHPID"; : > "$TMUXLOG"
  tmux(){ local IFS=$'\t'; printf '%s\n' "$*" >> "$TMUXLOG"
    case "$1" in has-session) return 1;; capture-pane) cat "$FIX/$HARNESS_CLI/idle.txt";; ls) printf '%s\n' ${FAKE_LIVE:-};; esac
    return 0; }
  sleep(){ :; }; export -f tmux; }
# typed_line <sess> — the line Harness typed into <sess> to start the agent.
typed_line(){ awk -F'\t' -v s="$1" '$1 == "send-keys" && $3 == s && $4 != "-l" && $5 == "Enter" && NF == 5 { print $4; exit }' "$TMUXLOG"; }
# sent_text <sess> — each line delivered to <sess> through cli_send.
sent_text(){ awk -F'\t' -v s="$1" '$1 == "send-keys" && $3 == s && $4 == "-l" { print $5 }' "$TMUXLOG"; }
# session_env_of <sess> — the -e K=V pairs <sess> was created with.
session_env_of(){ awk -F'\t' -v s="$1" '$1 == "new-session" { n = ""; for (i = 1; i < NF; i++) if ($i == "-s") n = $(i + 1)
  if (n == s) for (i = 1; i < NF; i++) if ($i == "-e") print $(i + 1) }' "$TMUXLOG"; }
state_uuid(){ sed -n 's/^session_id: //p' "$1/.claude/ralph-loop.local.md" 2>/dev/null; }
# run_pane <sess> <wd> — run the typed line as the pane's shell would (in <wd>, with the session's
# env) against the CLI's fake, which leaves on disk what the real CLI leaves (fake-cli). The fake runs
# $FAKE_CLI_TURN as the turn's tool call; rtdd there is fake_rtdd.
run_pane(){ local line bin d="$RUN_DIR/bin-$HARNESS_CLI" envs=()
  line="$(typed_line "$1")"; [[ -n $line ]] || return 1
  mapfile -t envs < <(session_env_of "$1")
  bin="$(cli_bin)"; mkdir -p "$d"
  printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$FIX/$HARNESS_CLI/fake-cli" > "$d/${bin##*/}"
  # rtdd's v1 event line (VocanicZ/rtdd#503): one per call, its ctx every HARNESS_* var it ran with.
  cat > "$d/rtdd" <<'RTDD'
#!/usr/bin/env bash
[[ -n ${RTDD_EVENT_LOG:-} ]] || exit 0
python3 -c 'import json, os, sys
ctx = {k: v for k, v in os.environ.items() if k.startswith("HARNESS_")}
print(json.dumps({"v": 1, "ts": "2026-10-27T00:00:00Z", "cmd": sys.argv[1], "argv": sys.argv[1:], "exit": 0,
                  "duration_ms": 5, "changed_nodes": 2, "round1": 1, "round2": 0, "ctx": ctx}))' "$@" >> "$RTDD_EVENT_LOG"
RTDD
  chmod +x "$d/${bin##*/}" "$d/rtdd"
  ( cd "$2" && env -u RTDD_EVENT_LOG -u HARNESS_SESSION -u HARNESS_ISSUE -u HARNESS_PRD -u HARNESS_KIND -u HARNESS_PREFIX \
      -u HARNESS_REPO PATH="$d:$PATH" "${envs[@]}" bash -c "$line" ) </dev/null >/dev/null 2>&1; }
# new_wd <wd> — a fresh worktree with a task file.
new_wd(){ mkdir -p "$1" && git -C "$1" init -q && printf 'GOAL: UNIQUE_TASK_MARKER\n' > "$1/.harness-task.md"; }

# lane_ok <sess> <wd> <promise> — a lane Harness set up was launched through this CLI's adapter: the
# line typed is the CLI's own launch line for that worktree and lane, carrying the bootstrap and not
# the task; the worktree is trusted and bypassed and its goal loop armed on the lane's promise; and
# once the line runs, the session id Harness resolves finds the transcript the CLI wrote.
lane_ok(){ local line uuid sid model effort
  line="$(typed_line "$1")"; uuid="$(state_uuid "$2")"; [[ -n $line && -n $uuid ]] || return 1
  model="$(lane_setting "$2" model)"; effort="$(lane_setting "$2" effort)"
  same "$line" "$(cli_launch "$2" "$uuid" "$model" "$effort")" || return 1
  has "$HARNESS_BOOTSTRAP_PROMPT" "$line$(cli_first_input "$effort")" && lacks "$3" "$line" || return 1
  grep -qF -- "$3" "$2/.harness-task.md" && grep -qF -- "$3" "$2/.claude/ralph-loop.local.md" || return 1
  cli_trusted "$2" && cli_bypassed "$2" && not cli_done "$2" || return 1
  run_pane "$1" "$2" || return 1
  sid="$(cli_session_id "$2" "$uuid")"; [[ -n $sid ]] && test -n "$(cli_transcripts "$2" "$sid")"; }
# lane_env — one unit (acme/widget, single topology) with fake_tmux, GitHub answering from FAKE_LABELS
# / FAKE_HANDOFF, a pushed branch iff FAKE_REMOTE_BRANCH, and `worktree add` making a fresh repo.
# Call it AFTER sourcing drive.sh, whose own default_branch it replaces.
lane_env(){ fake_tmux
  UNIT=main PROJECT=main DESC=widget SLUG=acme/widget
  export HARNESS_OWNER=acme HARNESS_REPO=acme/widget HARNESS_TOPOLOGY=single HARNESS_SESS_PREFIX=hz HARNESS_PAUSE_GRACE=2
  CHECKOUT="$RUN_DIR/checkout-$HARNESS_CLI"; mkdir -p "$CHECKOUT" "$WORKTREES_DIR"; git -C "$CHECKOUT" init -q
  ensure_checkout(){ :; }; unit_checkout(){ echo "$CHECKOUT"; }; default_branch(){ echo main; }; pool_live(){ return 0; }
  ensure_safe(){ :; }; run_worktree_hook(){ :; }; remove_worktree(){ :; }; log(){ :; }
  gh(){ case "$1 $2" in
      "api user") echo fleetbot;;
      "issue view") case "$*" in
          *"--json labels"*) echo "${FAKE_LABELS:-[]}";;
          *length*) echo 0;;
          *"--json comments"*) printf '%s\n' "${FAKE_HANDOFF:-}";;
        esac;;
    esac; return 0; }
  git(){ local a wt=
    case " $* " in
      *" worktree add "*) for a; do [[ $a == "$WORKTREES_DIR"/* ]] && wt="$a"; done
        mkdir -p "$wt" && command git -C "$wt" init -q; return;;
      *" ls-remote "*) [[ -z ${FAKE_REMOTE_BRANCH:-} ]] || printf 'abc\trefs/heads/%s\n' "$FAKE_REMOTE_BRANCH"; return 0;;
      *" fetch "*|*" checkout "*|*" reset "*) return 0;;
    esac; command git "$@"; }
  export -f gh; }

# lane_launch <wd> <model> <effort> — launch_agent a lane whose worktree hook pinned <model> and
# <effort> (.harness-lane); prints the line typed, the CLI's lane settings and its first input.
lane_launch(){ ( fake_tmux; new_wd "$1"; GOAL=ISSUE:4
  printf 'model=%s\neffort=%s\n' "$2" "$3" > "$1/$HARNESS_LANE_FILE"
  launch_agent hz-lane-i4 "$1" >/dev/null 2>&1; typed_line hz-lane-i4; cli_lane_settings "$1"; cli_first_input "$3" ) }
# effort_once_ok <launch> <effort> — the lane's effort, and no other, reaches the launch exactly once,
# in the CLI's own spelling (fixtures/cli/<cli>/effort-flag: `--effort `, or codex's config override).
effort_once_ok(){ local f; f="$(cat "$FIX/$HARNESS_CLI/effort-flag")"
  same "$(grep -oF -- "$f" <<<"$1" | wc -l)" 1 && has "$f$2" "$1"; }
# session_id_ok — the id Harness resolves for a launch is the one the CLI wrote its session under: the
# typed line runs against the CLI's fake in a fresh worktree (no planted fixture answers for it).
session_id_ok(){ ( fake_tmux; local wd="$RUN_DIR/sid-$HARNESS_CLI" uuid sid; new_wd "$wd"; GOAL=ISSUE:3
  launch_agent hz-sid-i3 "$wd" >/dev/null 2>&1 && run_pane hz-sid-i3 "$wd" || exit 1
  uuid="$(state_uuid "$wd")"; sid="$(cli_session_id "$wd" "$uuid")"
  [[ -n $sid ]] && test -n "$(cli_transcripts "$wd" "$sid")" ); }
# trust_ok — a fresh worktree is not trusted until cli_trust trusts it. trust_noop — it already is:
# the CLI has no gate to pre-accept, so the row is n/a (#305), never a ✓ no test could fail.
trust_ok(){ local wd="$RUN_DIR/trust-$HARNESS_CLI"; new_wd "$wd"; not cli_trusted "$wd" && cli_trust "$wd" && cli_trusted "$wd"; }
trust_noop(){ local wd="$RUN_DIR/untrusted-$HARNESS_CLI"; new_wd "$wd"; cli_trusted "$wd"; }
# bypass_ok — after launch_agent, the worktree reads as bypassed, the line cli_bypassed judges is the
# line typed, and the CLI's own capture of a sub-agent run under that bypass shows it ran (subagent_ok).
bypass_ok(){ ( fake_tmux; local wd="$RUN_DIR/bypass-$HARNESS_CLI"; new_wd "$wd"; GOAL=ISSUE:5
  launch_agent hz-byp-i5 "$wd" >/dev/null 2>&1
  cli_bypassed "$wd" && same "$(typed_line hz-byp-i5)" "$(cli_launch "$wd" "$(state_uuid "$wd")" "" "")" ) &&
    subagent_ok "$HARNESS_CLI"; }
# subagent_ok <cli> — #305: the real CLI, launched with the lane's bypass, had a sub-agent run a shell
# command, and its own record (fixtures/cli/<cli>/bypass-subagent.*, see each README.md) shows that
# sub-agent's call ran to success; where a control capture without the bypass exists, it shows the
# approval prompt the bypass capture lacks. claude has no capture: its README row says what is checked.
subagent_ok(){ [[ $1 == claude ]] && return 0
  python3 - "$1" "$FIX/$1" <<'PY'
import json, sqlite3, sys
cli, d = sys.argv[1], sys.argv[2]
rows = lambda f: [json.loads(l) for l in open(f"{d}/{f}") if l.strip()]
text = lambda f: open(f"{d}/{f}").read()
def prompt_only_in(control, marker):  # the control shows the prompt; the bypass capture does not
    return marker in text(control) and marker not in text("bypass-subagent.txt")
ok = False
if cli == "agy":
    r = rows("bypass-subagent.jsonl")
    ok = (any("Created the following subagent" in x["content"] for x in r if x["conversation"] == "parent")
          and any("Command exited with code 0." in x["content"] for x in r if x["conversation"] == "subagent")
          and prompt_only_in("permission.txt", "Requesting permission for:"))
elif cli == "codex":
    r = rows("bypass-subagent.jsonl")
    meta = {x["conversation"]: x["payload"] for x in r if x["type"] == "session_meta"}
    sub = [x["payload"] for x in r if x["conversation"] == "subagent"]
    calls = {p["call_id"] for p in sub if p.get("type") == "custom_tool_call" and p.get("status") == "completed"
             and "touch subagent-proof.txt" in p.get("input", "")}
    outs = {p["call_id"] for p in sub if p.get("type") == "custom_tool_call_output"}
    ok = bool(calls & outs) and meta["subagent"].get("parent_thread_id") == meta["parent"]["id"]
elif cli == "copilot":
    r = [x for x in rows("bypass-subagent.jsonl") if x.get("agentId")]
    started = {x["data"]["toolCallId"] for x in r if x["type"] == "tool.execution_start"
               and x["data"]["toolName"] == "bash" and x["data"]["arguments"].get("command") == "touch subagent-proof.txt"}
    done = {x["data"]["toolCallId"] for x in r if x["type"] == "tool.execution_complete"
            and x["data"].get("success") and (x["data"].get("shellExecution") or {}).get("exitCode") == 0}
    ok = bool(started & done)
elif cli == "opencode":
    c = sqlite3.connect(f"file:{d}/bypass-subagent.db?mode=ro", uri=True)
    lane = open(f"{d}/session").read().strip()
    kids = [k for (k,) in c.execute("SELECT id FROM session WHERE parent_id = ?", (lane,))]
    msgs = [json.loads(m) for k in kids for (m,) in c.execute("SELECT data FROM message WHERE session_id = ?", (k,))]
    ok = (any(m.get("role") == "assistant" and m.get("time", {}).get("completed") and not m.get("error") for m in msgs)
          and "✓ General Task" in text("bypass-subagent.txt")
          and prompt_only_in("busy-permission.txt", "Permission required"))
elif cli == "hermes":
    c = sqlite3.connect(f"file:{d}/bypass-subagent.db?mode=ro", uri=True)
    kid = c.execute("SELECT id FROM sessions WHERE parent_session_id IS NOT NULL").fetchone() or ("",)
    asked = [m for (m,) in c.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'user'", kid)]
    ran = [json.loads(m) for (m,) in c.execute(
        "SELECT content FROM messages WHERE session_id = ? AND role = 'tool' AND tool_name = 'terminal'", kid)]
    ok = any("rm -r junk-dir" in m for m in asked) and any(r.get("exit_code") == 0 and "approval" not in r for r in ran)
sys.exit(0 if ok else 1)
PY
}
# loop_ok — the goal loop as this CLI runs it (cli_loop). `hook`: the Stop hook of the plugin Harness
# installs for it (fixtures/cli/<cli>/stop-hook) re-feeds the task after a turn without the promise,
# and ends the loop — which cli_done sees — after a turn that outputs it. `driven`: driven_loop_ok.
loop_ok(){ ( local wd="$RUN_DIR/loop-$HARNESS_CLI" sid=loop-session out
  [[ "$(cli_loop)" == driven ]] && { driven_loop_ok; exit; }
  [[ "$(cli_loop)" == hook ]] || exit 1
  new_wd "$wd"; write_state "$wd" "LOOP DONE" 5 "$sid"
  out="$("$FIX/$HARNESS_CLI/stop-hook" "$wd" "$sid" 2>/dev/null)"
  has UNIQUE_TASK_MARKER "$out" && not cli_done "$wd" || exit 1
  "$FIX/$HARNESS_CLI/stop-hook" "$wd" "$sid" "all done <promise>LOOP DONE</promise>" >/dev/null 2>&1; cli_done "$wd" ); }

# driven_loop_ok — #259: the Harness-driven goal loop, through the watchdog every lane's poll runs
# (watchdog_session). The CLI records a turn that ends without the promise (fixtures/cli/<cli>/turn-end)
# and its pane sits idle: the watchdog types the next iteration — the promise to output and the
# bootstrap, never the task — once, however many polls see that same idle pane. A turn that outputs
# the promise ends the loop, which cli_done sees.
driven_loop_ok(){ ( fake_tmux; session_live(){ return 0; }
  local wd="$RUN_DIR/driven-$HARNESS_CLI" sess=hz-loop-i6 uuid=66666666-7777-8888-9999-000000000000 sid msg
  new_wd "$wd"; write_state "$wd" "LOOP DONE" 5 "$uuid"; echo "$wd" > "$RUN_DIR/$sess.wd"
  sid="$(cli_session_id "$wd" "$uuid")"
  watchdog_session "$sess"; [[ -z "$(sent_text "$sess")" ]] || exit 1          # no turn has ended yet
  "$FIX/$HARNESS_CLI/turn-end" "$wd" "$sid" "STILL WORKING" || exit 1
  watchdog_session "$sess"; watchdog_session "$sess"
  msg="$(sent_text "$sess")"
  same "$(wc -l <<<"$msg")" 1 && has "<promise>LOOP DONE</promise>" "$msg" && has "$HARNESS_BOOTSTRAP_PROMPT" "$msg" &&
    lacks UNIQUE_TASK_MARKER "$msg" && grep -qx 'iteration: 2' "$wd/.claude/ralph-loop.local.md" && not cli_done "$wd" || exit 1
  "$FIX/$HARNESS_CLI/turn-end" "$wd" "$sid" "all done <promise>LOOP DONE</promise>" || exit 1
  watchdog_session "$sess"; cli_done "$wd" && same "$(sent_text "$sess" | wc -l)" 1 ); }
# inject_ok — `/harness-issue|prd|plan` (inject.sh): each altitude's injector is launched on the
# unit's checkout through the adapter.
inject_ok(){ ( lane_env; local alt
  for alt in issue prd plan; do
    ( source "$HERE/../scripts/inject.sh" "$alt" "add a rate limiter" ) >/dev/null 2>&1 || exit 1
    lane_ok "$(sess_inject main)" "$CHECKOUT" "INJECT DONE" || exit 1
    : > "$TMUXLOG"
  done ); }
# bug_lane_ok — the bug lane (drive.sh spawn_bug): triage, then fix, each its own session through the adapter.
bug_lane_ok(){ ( source "$HERE/../scripts/drive.sh"; lane_env
  spawn_bug 9 triage >/dev/null 2>&1 && lane_ok "$(sess_bug acme/widget 9 triage)" "$(triage_worktree acme/widget 9)" "BUG 9 triage DONE" || exit 1
  names_handoff_skill "$(triage_worktree acme/widget 9)/.harness-task.md" || exit 1
  spawn_bug 9 fix >/dev/null 2>&1 && lane_ok "$(sess_bug acme/widget 9 fix)" "$(bug_worktree acme/widget 9)" "BUG 9 fix DONE" &&
    names_handoff_skill "$(bug_worktree acme/widget 9)/.harness-task.md" ); }
# review_ok — the PRD review (drive.sh spawn_orch REVIEW) with its gauntlet round, through the adapter.
review_ok(){ ( source "$HERE/../scripts/drive.sh"; lane_env; local wd
  spawn_orch REVIEW 7 "REVIEW DONE" >/dev/null 2>&1 || exit 1
  wd="$(orch_worktree acme/widget 7)"
  lane_ok "$(sess_orch main 7)" "$wd" "REVIEW DONE" &&
    grep -qF "Gauntlet: round 1 of $HARNESS_GAUNTLET_ROUNDS   Evidence dir: $STATE_DIR/gauntlet/main/p7" "$wd/.harness-task.md" ); }
# checkpoint_ok — host A: an impl lane (spawn_impl) runs issue 7 through this CLI, its prompt's
# CHECKPOINT PROTOCOL naming the handoff skill as the CLI invokes a skill (handoff-skill, #303);
# `pause --force` types the checkpoint into it through the adapter — naming that skill the same way,
# and the handoff marker — and marks the fleet paused, killing nothing.
checkpoint_ok(){ local sess msg
  spawn_impl 7 "ISSUE 7 DONE" >/dev/null 2>&1 || return 1
  sess="$(sess_impl main 7)"; lane_ok "$sess" "$WORKTREES_DIR/main-i7" "ISSUE 7 DONE" || return 1
  names_handoff_skill "$WORKTREES_DIR/main-i7/.harness-task.md" || return 1
  FAKE_LIVE="$sess" FAKE_LABELS='["agent-paused"]' RUN_DIR="$RUN_DIR" bash "$HERE/../scripts/pause.sh" --force >/dev/null 2>&1 || return 1
  msg="$(sent_text "$sess")"
  has "HARNESS CHECKPOINT" "$msg" && has "run the $(cat "$FIX/$HARNESS_CLI/handoff-skill") skill" "$msg" &&
    has '<!-- harness-handoff issue=7 branch=issue/7 -->' "$msg" && test -f "$RUN_DIR/PAUSED" && not grep -q '^kill-session' "$TMUXLOG"; }
# names_handoff_skill <task file> — the rendered prompt names the CLI's handoff skill (handoff-skill)
# and no other CLI's spelling of it: `/handoff` is a built-in that fails on hermes (handoff.txt).
names_handoff_skill(){ local want; want="$(cat "$FIX/$HARNESS_CLI/handoff-skill")"
  grep -qF "run the $want skill and post the handoff" "$1" && lacks "{{HANDOFF_SKILL}}" "$(cat "$1")" &&
    { [[ $want == /handoff ]] || lacks "/handoff" "$(cat "$1")"; }; }
host_a(){ RUN_DIR="$RUN_DIR/host-a-$HARNESS_CLI"; PAUSE_FLAG="$RUN_DIR/PAUSED"; mkdir -p "$RUN_DIR"
  source "$HERE/../scripts/drive.sh"; lane_env; }
checkpoint_skill_ok(){ ( host_a; checkpoint_ok ); }
# pause_resume_ok — host A checkpoints (checkpoint_ok); host B, with none of A's local state (its own
# state dir, run dir, worktrees), resumes issue 7 from GitHub alone — the agent-paused label, the
# pushed branch, the handoff comment — rendering resume.md with the handoff, through the adapter.
pause_resume_ok(){ ( host_a; checkpoint_ok || exit 1
  local b="${RUN_DIR%/*}/host-b-$HARNESS_CLI"; mkdir -p "$b"
  RUN_DIR="$b/run" STATE_DIR="$b/state" WORKTREES_DIR="$b/worktrees"; PAUSE_FLAG="$RUN_DIR/PAUSED"; mkdir -p "$RUN_DIR"
  lane_env
  FAKE_LABELS='["agent-paused"]' FAKE_REMOTE_BRANCH=issue/7
  FAKE_HANDOFF=$'<!-- harness-handoff issue=7 branch=issue/7 -->\nHOST A LEFT OFF HERE'
  spawn_impl 7 "ISSUE 7 DONE" >/dev/null 2>&1 || exit 1
  lane_ok "$(sess_impl main 7)" "$WORKTREES_DIR/main-i7" "ISSUE 7 DONE" &&
    grep -qF "HOST A LEFT OFF HERE" "$WORKTREES_DIR/main-i7/.harness-task.md" &&
    grep -qF "BEGIN HANDOFF" "$WORKTREES_DIR/main-i7/.harness-task.md" ); }
# frozen_ok <kind> — #180: the CLI's idle pane and its <kind> pane (trust dialog, limit), drawn in
# real tmux panes (a private server) and gone quiet. supervise.sh nudges the idle prompt and never
# types into the other. A missing fixture fails the cell: no half of it is skipped (#305).
frozen_ok(){ ( command -v tmux >/dev/null || exit 1
  local cli="$HARNESS_CLI" other="$1" k i
  export TMUX_TMPDIR="$RUN_DIR/tmux-$cli"; mkdir -p "$TMUX_TMPDIR"; unset TMUX
  export HARNESS_SUPERVISE_CONF=/dev/null HARNESS_SUPERVISE_STATE="$RUN_DIR/sup-$cli" HARNESS_SUPERVISE_LOG="$RUN_DIR/sup-$cli.log"
  source "$HERE/../scripts/supervise.sh"; SUP_DRY=1 CPU_ACTIVE_S=0
  trap 'tmux kill-server 2>/dev/null' EXIT
  for k in idle "$other"; do [[ -f $FIX/$cli/$k.txt ]] || exit 1
    tmux new-session -d -s "$cli-$k" -x 160 -y 45 "cat '$FIX/$cli/$k.txt'; exec sleep 600"; done
  for (( i = 0; i < 50; i++ )); do tmux capture-pane -p -t "$cli-idle" 2>/dev/null | grep -qE "$(cli_idle_re)" && break; command sleep 0.1; done
  command sleep 0.3
  for i in 1 2; do for k in idle "$other"; do
    sup_watch_pane "$cli-$k" "$SUP_STATE/panes/$cli-$k" 0 0 "nudge-$k" "$cli"; done; done
  grep -qF "send-keys -t $cli-idle -l nudge-idle" "$SUP_LOG" && not grep -qF "$cli-$other" "$SUP_LOG" ); }
# rtdd_event_ok — #186: a lane launched through this CLI calls `rtdd which` from its turn; rtdd sees
# the session's env through the CLI and logs it, and `harness stats` joins the call to the lane's
# session and issue. A CLI whose turns do not run in the pane's env has its fake drop what it would
# not pass on (hermes: every lane variable its seeded config leaves out of client_env_passthrough).
rtdd_event_ok(){ ( lane_env; local wd="$RUN_DIR/rtdd-$HARNESS_CLI" sess uuid
  export HARNESS_EVENTS_FILE="$RUN_DIR/rtdd-$HARNESS_CLI.events" HARNESS_RTDD_EVENTS_FILE="$RUN_DIR/rtdd-$HARNESS_CLI.jsonl"
  rm -f "$HARNESS_EVENTS_FILE" "$HARNESS_RTDD_EVENTS_FILE"; new_wd "$wd"
  GOAL=ISSUE:11 PROMISE="ISSUE 11 DONE" MAXITER=5 STAT_PRD=5; sess="$(sess_impl main 11)"
  launch_agent "$sess" "$wd" >/dev/null 2>&1
  FAKE_CLI_TURN='rtdd which --base origin/main' run_pane "$sess" "$wd" || exit 1
  uuid="$(state_uuid "$wd")"
  python3 "$HERE/../scripts/stats.py" report --issue 11 -R acme/widget --json 2>/dev/null | python3 -c 'import json, sys
d = json.load(sys.stdin); by = {s["session"]: s["rtdd"] for s in d["sessions"]}
sys.exit(0 if d["rtdd"].get("which") == 1 and by.get(sys.argv[1], {}).get("which") == 1 else 1)' "$uuid" ); }
# init_choice_ok — `harness init` answered with this CLI (its non-interactive answer: the config key
# in the environment) writes it to the config, and a fleet that loads that config (lib.sh) drives it.
init_choice_ok(){ local cli="$HARNESS_CLI" d="$RUN_DIR/init-$HARNESS_CLI" out
  mkdir -p "$d"
  ( cd "$d" && env -u HARNESS_CLI STATE_DIR="$d/.harness" HARNESS_INIT_NONINTERACTIVE=1 "$CLI_CONFIG_VAR=$cli" \
      HARNESS_TOPOLOGY=multi HARNESS_SESS_PREFIX=hzinit bash "$HERE/../scripts/init.sh" ) </dev/null >/dev/null 2>&1 || return 1
  out="$(cd "$d" && env -u HARNESS_CLI STATE_DIR="$d/.harness" bash -c 'source "$1"; cli_name; cli_launch /wd uuid "" ""' _ \
    "$HERE/../scripts/lib.sh" 2>/dev/null)"
  grep -qxF ": \"\${$CLI_CONFIG_VAR:=$cli}\"" "$d/.harness/config" &&
    same "$(sed -n 1p <<<"$out")" "$cli" && same "$(sed -n 2p <<<"$out")" "$(cli_launch /wd uuid "" "")"; }
# prereqs_ok — `harness setup` through the adapter: with no binary it names the binary and fails; with
# the binary but none of its plugins it names each missing one and fails; --install installs each
# through the binary, by the command it named, and then passes. A CLI Harness installs nothing into
# (copilot: its goal loop is Harness's own; opencode: its loop plugin loads from the engine,
# fixtures/cli/<cli>/installs-nothing) passes on the binary alone, naming nothing missing. The binary
# answers --version with the fixtures' (opencode refuses any but a 1.x).
prereqs_ok(){ ( local d="$RUN_DIR/prereqs-$HARNESS_CLI" bin out missing p
  export HOME="$d/home"; mkdir -p "$HOME" "$d/bin" "$d/none"
  unset CLAUDE_CONFIG_DIR COPILOT_HOME HARNESS_USER_SKILLS HARNESS_AGY_USER_SKILLS HARNESS_CODEX_USER_SKILLS \
    HARNESS_COPILOT_USER_SKILLS   # every skill dir under this HOME: one CLI's --install never feeds the next
  bin="$(cli_bin)"
  out="$(PATH="$d/none" cli_prereqs 2>&1)" && exit 1
  grep -qF "MISSING $HARNESS_CLI binary ($bin)" <<<"$out" || exit 1
  printf '#!/bin/sh\necho "$*" >> %q\n[ "$1" = --version ] && head -1 %q\nexit 0\n' "$d/calls" "$FIX/$HARNESS_CLI/VERSION" > "$d/bin/$bin"
  chmod +x "$d/bin/$bin"; export PATH="$d/bin:$PATH"
  # The handoff skill is missing on this empty HOME too (#303): handoff_skill_ok is its cell.
  out="$(cli_prereqs 2>&1)" && exit 1
  missing="$(sed -n "s/^MISSING [^:]*: $bin //p" <<<"$out")"
  if [[ -z $missing ]]; then [[ $(cli_loop) == driven || -s "$FIX/$HARNESS_CLI/installs-nothing" ]] || exit 1; fi
  cli_prereqs --install >/dev/null 2>&1 || exit 1
  [[ -z $missing ]] || while read -r p; do grep -qF -- "$p" "$d/calls" || exit 1; done <<<"$missing" ); }
# handoff_skill_ok — #303: the handoff skill every checkpoint names (checkpoint_ok). On a host without
# it `harness setup` (cli_prereqs) names it missing for this CLI; then each install path — `harness
# setup`'s --install and install.sh (install_harness_skills) — puts Harness's own skill/handoff where
# the CLI loads user skills from: fixtures/cli/<cli>/skills-dir, under HOME (docs/cli-capabilities.md).
# hermes and openclaw read that dir only as one their lane's config names (_hermes_seed,
# _openclaw_config), so their lane config must name it too. An operator's own handoff skill there is
# kept, never overwritten.
handoff_skill_ok(){ ( local d="$RUN_DIR/handoff-$HARNESS_CLI" bin out want src="$HERE/../skill/handoff/SKILL.md" wd
  export HOME="$d/home"; mkdir -p "$HOME" "$d/bin"
  unset CLAUDE_CONFIG_DIR COPILOT_HOME HARNESS_USER_SKILLS HARNESS_AGY_USER_SKILLS HARNESS_CODEX_USER_SKILLS \
    HARNESS_COPILOT_USER_SKILLS HARNESS_OPENCLAW_AGENTS_SKILLS
  bin="$(cli_bin)"; want="$HOME/$(cat "$FIX/$HARNESS_CLI/skills-dir")/handoff"
  printf '#!/bin/sh\n[ "$1" = --version ] && head -1 %q\nexit 0\n' "$FIX/$HARNESS_CLI/VERSION" > "$d/bin/$bin"
  chmod +x "$d/bin/$bin"; export PATH="$d/bin:$PATH"
  out="$(cli_prereqs 2>&1)" && exit 1
  grep -qF "MISSING $HARNESS_CLI skill handoff ($want)" <<<"$out" || exit 1
  cli_prereqs --install >/dev/null 2>&1
  cmp -s "$src" "$want/SKILL.md" || exit 1
  grep -qF "ok      $HARNESS_CLI skill handoff ($want)" <<<"$(cli_prereqs 2>&1)" || exit 1
  rm -rf "$HOME"; mkdir -p "$HOME"
  ( HARNESS_INSTALL_NOMAIN=1 source "$HERE/../install.sh"; HARNESS_SKILL_SRC="$HERE/../skill" install_harness_skills ) >/dev/null 2>&1
  cmp -s "$src" "$want/SKILL.md" || exit 1
  wd="$d/wd"; mkdir -p "$wd"; git -C "$wd" init -q
  case "$HARNESS_CLI" in
    hermes) _hermes_seed "$wd" >/dev/null 2>&1; grep -qF "${want%/handoff}" "$(_hermes_home "$wd")/config.yaml" || exit 1 ;;
    openclaw) _openclaw_config "$wd" >/dev/null 2>&1; WANT="${want%/handoff}" python3 -c 'import json, os, sys
sys.exit(0 if os.environ["WANT"] in json.load(open(sys.argv[1]))["skills"]["load"]["extraDirs"] else 1)' "$(_openclaw_cfg "$wd")" || exit 1 ;;
  esac
  printf 'operator own\n' > "$want/SKILL.md"
  cli_prereqs --install >/dev/null 2>&1
  ( HARNESS_INSTALL_NOMAIN=1 source "$HERE/../install.sh"; HARNESS_SKILL_SRC="$HERE/../skill" install_harness_skills ) >/dev/null 2>&1
  [[ $(cat "$want/SKILL.md") == "operator own" ]] ); }

rc=0
for cli in ${HARNESS_MATRIX_CLIS:-$(cli_list)}; do
  ( cli_load "$cli" || exit 1
    for f in ${HARNESS_MATRIX_STUB:-}; do eval "${cli}_$f(){ :; }"; done
    F="$FIX/$cli"; WD="$RUN_DIR/$cli-wd"; mkdir -p "$WD"; git -C "$WD" init -q
    printf 'GOAL: UNIQUE_TASK_MARKER\n' > "$WD/.harness-task.md"
    SID="$(cat "$F/session")"; MODEL="$(cat "$F/model")"
    plant_cli_home "$cli" "$WD"
    cell "$cli" fixtures-recorded          test -s "$F/VERSION"
    line="$(cli_launch "$WD" "$SID" "$MODEL" high)"
    cell "$cli" launch-bootstrap-prompt    has "$HARNESS_BOOTSTRAP_PROMPT" "$line$(cli_first_input high)"
    cell "$cli" launch-no-task-text        lacks UNIQUE_TASK_MARKER "$line"
    lane="$(lane_launch "$RUN_DIR/$cli-lane" "$MODEL" low)"
    cell "$cli" launch-model               has "$MODEL" "$lane"
    cell "$cli" launch-effort-once         effort_once_ok "$lane" low
    cell "$cli" session-id                 session_id_ok
    cell "$cli" idle-is-prompt             cli_pane_prompt "$(pane "$cli" idle)"
    cell "$cli" idle-is-not-busy           not cli_pane_busy "$(pane "$cli" idle)"
    cell "$cli" busy-is-busy               every_busy_is_busy "$cli"
    if [[ -f "$F/trust.txt" ]]; then cell "$cli" trust-dialog-is-not-prompt not cli_pane_prompt "$(pane "$cli" trust)"
    elif [[ -s "$F/trust.na" ]]; then na "$cli" trust-dialog-is-not-prompt "$(cat "$F/trust.na")"
    else cell "$cli" trust-dialog-is-not-prompt false; fi
    cell "$cli" transient-stalls           session_stalled "$(pane "$cli" transient)"
    cell "$cli" idle-never-stalls          not session_stalled "$(pane "$cli" idle)"
    cell "$cli" busy-never-stalls          no_busy_stalls "$cli"
    cell "$cli" limit-parks                session_limit_idle "$(pane "$cli" limit)"
    cell "$cli" transient-is-not-limit     not session_limit_idle "$(pane "$cli" transient)"
    if [[ -s "$F/trust.na" ]] && trust_noop; then na "$cli" trust-pre-accepted "$(cat "$F/trust.na")"
    else cell "$cli" trust-pre-accepted       trust_ok; fi
    cli_trust "$WD"
    if [[ -s "$F/bypass-subagent.na" ]]; then na "$cli" bypass-covers-subagents "$(cat "$F/bypass-subagent.na")"
    else cell "$cli" bypass-covers-subagents    bypass_ok; fi
    cell "$cli" done-signal                done_signal_ok "$WD"
    cell "$cli" loop-mode                  loop_ok
    cell "$cli" transcripts-found          test -n "$(cli_transcripts "$WD" "$(cli_session_id "$WD" "$SID")")"
    cell "$cli" usage-from-transcript      same "$(cli_usage "$(cli_transcripts "$WD" "$(cli_session_id "$WD" "$SID")" | head -1)" | sort)" "$(sort "$F/usage.expected")"
    cell "$cli" stats-launch-model-effort  launch_event_ok "$MODEL" low
    cell "$cli" stats-session-end-usage    session_end_usage_ok "$WD" "$SID"
    if [[ -s "$F/usage-windows.na" ]]; then na "$cli" usage-windows "$(cat "$F/usage-windows.na")"
    else cell "$cli" usage-windows              usage_windows_ok "$cli"; fi
    cell "$cli" checkpoint-skill           checkpoint_skill_ok
    cell "$cli" handoff-skill-installed    handoff_skill_ok
    cell "$cli" pause-force-resume-other-host pause_resume_ok
    cell "$cli" send-and-kill              send_and_kill_ok
    cell "$cli" inject-sessions            inject_ok
    cell "$cli" bug-lane-triage-fix        bug_lane_ok
    cell "$cli" review-gauntlet            review_ok
    cell "$cli" supervisor-frozen-session  frozen_ok limit
    if [[ -f "$F/trust.txt" ]]; then cell "$cli" supervisor-skips-trust-dialog frozen_ok trust
    elif [[ -s "$F/trust.na" ]]; then na "$cli" supervisor-skips-trust-dialog "$(cat "$F/trust.na")"
    else cell "$cli" supervisor-skips-trust-dialog false; fi
    cell "$cli" rtdd-event-context         rtdd_event_ok
    cell "$cli" prereqs-named              prereqs_ok
    cell "$cli" init-wizard-choice         init_choice_ok
    (( TSV )) || finish ) || rc=1
done
exit "$rc"

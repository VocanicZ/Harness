#!/usr/bin/env bash
# test_supervise.sh — #180: `harness supervise`, the host-level supervisor. One case per rule, on
# scratch tmux panes (a private tmux server), stubbed gh / harness / systemctl, and fixture pid files.
# Ported from the claude-host prototype's test_harness_manager.sh (5/5) and test_harness_checkpoint.sh
# (8/8), plus the fleet kill cases, the dead-worker / orphan-lock / paused / stopped rules, the
# systemd unit, and the scratch reap. Every pane rule runs for each claimed CLI (claude, agy).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
command -v tmux >/dev/null || { echo "  skip: tmux not installed"; exit 0; }
T="$(mktemp -d)"
export TMUX_TMPDIR="$T/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX   # a private server: no live session is touched
trap 'tmux kill-server 2>/dev/null; rm -rf "$T"' EXIT
export HARNESS_SUPERVISE_CONF="$T/none.conf" HARNESS_SUPERVISE_STATE="$T/sup" HARNESS_SUPERVISE_LOG="$T/sup.log"
source "$HERE/../scripts/supervise.sh"
SUP_DRY=1 CPU_ACTIVE_S=0
LOG=$SUP_LOG
quiet(){ "$@" 2>/dev/null; }
mk(){ tmux kill-session -t "=$1" 2>/dev/null; tmux new-session -d -s "$1" -x 120 -y 20 "$2"; }
pass(){ local t; for t; do sup_watch_pane "$t" "$SUP_STATE/panes/$t" 0 0 "nudge-$t" "$CLI"; done; }

# Per CLI: the pane prompt each one draws.
for CLI in claude agy; do
  if [[ $CLI == agy ]]; then P='│ > '; else P='❯ '; fi
  echo "=== $CLI: frozen-pane activity rules ==="
  rm -rf "$SUP_STATE"; : >"$LOG"
  mk "$CLI-idle"  "printf 'done\n$P\n── status\n'; sleep 600"
  mk "$CLI-busy"  "printf 'waiting\n$P\n'; sh -c 'while :; do :; done' & sleep 600"
  mk "$CLI-dlg"   "printf 'Do you trust this folder?\n 1. Yes\n 2. No\n'; sleep 600"
  mk "$CLI-timer" "printf 'idle\n$P\n'; i=0; while :; do i=\$((i+1)); printf '\r  ◯ general-purpose  task 1m %ds' \$i; sleep 1; done"
  mk "$CLI-limit" "printf 'You have hit your session limit · resets 5pm\n$P\n'; sleep 600"
  sleep 1
  pass "$CLI-idle" "$CLI-busy" "$CLI-dlg" "$CLI-timer" "$CLI-limit"     # baseline
  sleep 3
  pass "$CLI-idle" "$CLI-busy" "$CLI-dlg" "$CLI-timer" "$CLI-limit"     # quiet?
  assert_ok "$CLI: an idle prompt is nudged"                grep -q "nudge-$CLI-idle" "$LOG"
  assert_ok "$CLI: the nudge clears the input line first"   grep -q "send-keys -t $CLI-idle C-u" "$LOG"
  assert_no "$CLI: a CPU-busy child is not nudged"          grep -q "nudge-$CLI-busy" "$LOG"
  assert_no "$CLI: a dialog is never typed into"            grep -q "$CLI-dlg" "$LOG"
  assert_no "$CLI: a ticking background timer is not nudged" grep -q "nudge-$CLI-timer" "$LOG"
  assert_no "$CLI: a usage-limit pane is left alone"        grep -q "$CLI-limit" "$LOG"
  sup_watch_pane "$CLI-idle" "$SUP_STATE/panes/$CLI-idle" 0 0 "nudge-again" "$CLI"
  assert_no "$CLI: no second nudge inside RENUDGE_S"        grep -q "nudge-again" "$LOG"
  tmux kill-server 2>/dev/null
done
assert_no "a claude pane is not mistaken for an agy prompt" bash -c "grep -qE \"\$(source '$HERE/../scripts/supervise.sh'; sup_prompt_re agy)\" <<<'❯ '"

echo "=== net gate ==="
ONLINE_URL=file:///nonexistent
assert_no "offline holds every action"   sup_net_gate
assert_ok "offline is recorded"          test -f "$SUP_STATE/offline"
ONLINE_URL=file:///etc/hostname
assert_ok "reconnect passes the gate"    sup_net_gate
assert_no "reconnect clears offline"     test -f "$SUP_STATE/offline"
CLI=claude; : >"$LOG"; mk claude-idle "printf 'done\n❯ \n'; sleep 600"; sleep 1
pass claude-idle; echo "x x 0 0 1 $(date +%s)" >"$SUP_STATE/panes/claude-idle"   # just nudged…
ONLINE_URL=file:///nonexistent; sup_net_gate; ONLINE_URL=file:///etc/hostname; sup_net_gate
read -r _ _ _ _ nud lastn <"$SUP_STATE/panes/claude-idle"
assert_eq "$nud $lastn" "0 0" "reconnect re-arms every pane for an immediate nudge"

echo "=== fleet kill: only after an IGNORED nudge, quiet until KILL_MIN ==="
KILLS="$T/kills"; : >"$KILLS"
rec_kill(){ echo "$1" >>"$KILLS"; }
mk tp-u-i1 "printf 'stuck\n❯ \n'; sleep 600"                                   # ignores the nudge
mk tp-u-i2 "printf 'stuck\n❯ \n'; read -r x; clear; printf 'on it\n❯ \n'; sleep 600"  # reacts to it
sleep 1
SUP_DRY=0
kpass(){ local t; for t; do sup_watch_pane "$t" "$SUP_STATE/panes/$t" 0 1 "nudge" claude rec_kill; done; }
kpass tp-u-i1 tp-u-i2                                     # baseline
kpass tp-u-i1 tp-u-i2                                     # quiet → nudged (kill needs a nudge first)
assert_eq "$(cat "$KILLS")" "" "nothing killed before a nudge was sent"
sleep 1
for t in tp-u-i1 tp-u-i2; do read -r a b c t0 rest <"$SUP_STATE/panes/$t"; echo "$a $b $c $((t0-120)) $rest" >"$SUP_STATE/panes/$t"; done
kpass tp-u-i1 tp-u-i2                                     # KILL_MIN reached
assert_ok "ignored nudge + quiet until KILL_MIN → killed"  grep -qx tp-u-i1 "$KILLS"
assert_no "reacted to the nudge → not killed"              grep -qx tp-u-i2 "$KILLS"
assert_no "a killed pane's state is forgotten"             test -f "$SUP_STATE/panes/tp-u-i1"
tmux kill-server 2>/dev/null

echo "=== #207: one endless turn with input queued → Escape, then Enter ==="
# The spinner's timer ticks every second, so the activity test alone calls such a pane busy forever.
# turnpane.sh draws a mid-turn Claude Code pane; like the real TUI it prints `Interrupted` on Escape,
# and `submitted` once Enter delivers the queued text.
TP="$T/turnpane.sh"
cat >"$TP" <<'PANE'
timer=$1; shift
printf '%s\n' '⏺ Bash(timeout 590 bash -c "until grep -q done replay.log; do sleep 30; done")' \
  "✻ Polling the bench replay… ($timer · ↓ 12.3k tokens · esc to interrupt)" '' '────────────────'
printf '❯ %s\n' "$*"; printf '%s\n' '────────────────'
IFS= read -rsn1 k; [ "$k" = "$(printf '\033')" ] && echo '  ⎿  Interrupted · What should Claude do instead?'
IFS= read -rs l; echo submitted; sleep 600
PANE
mk claude-longturn "bash $TP '5h 0m 3s' 'harness supervise: no activity for a while.'"
mk claude-longtool "bash $TP '5h 0m 3s'"
mk claude-shortturn "bash $TP '30m 12s' 'also check the flaky test'"
sleep 1
SUP_DRY=1; : >"$LOG"
pass claude-longturn claude-longtool claude-shortturn
assert_ok "dry run: a 5 h turn with queued input gets Escape…" grep -q "DRY tmux send-keys -t claude-longturn Escape" "$LOG"
assert_ok "…then Enter"                                        grep -q "DRY tmux send-keys -t claude-longturn Enter" "$LOG"
assert_no "a 5 h turn with an empty input box is left alone"   grep -q "claude-longtool" "$LOG"
assert_no "a 30 min turn with queued input is left alone"      grep -q "claude-shortturn" "$LOG"
SUP_DRY=0; HARNESS_INTERRUPT_WAIT=5; : >"$LOG"; SEV="$T/turn.events"; : >"$SEV"
stats_sess_event(){ echo "$1 $2 ${*:3}" >>"$SEV"; }
pass claude-longturn
assert_ok "the turn is interrupted and the queued text submitted" bash -c "tmux capture-pane -p -t claude-longturn | grep -q submitted"
assert_eq "$(cat "$SEV")" "claude-longturn turn_interrupted turn_s=18003 queued_nudges=1" \
  "a fleet session's interrupt is logged as turn_interrupted"
unset -f stats_sess_event; source "$HERE/../scripts/lib.sh"   # restore the real one
mk claude-deaf "bash -c \"printf '%s\n' '✻ Polling… (5h 0m 3s · ↓ 1k tokens · esc to interrupt)' '────' '❯ harness supervise: no activity' '────'; sleep 600\""
sleep 1; HARNESS_INTERRUPT_WAIT=0; : >"$LOG"
pass claude-deaf
assert_ok "a turn that never reports Interrupted is logged for a retry" grep -q "claude-deaf did not report Interrupted" "$LOG"
assert_no "…and gets no Enter"                                         grep -q "send-keys -t claude-deaf Enter" "$LOG"
tmux kill-server 2>/dev/null

echo "=== checkpoint before kill ==="
gstub="$T/gstub"; mkdir -p "$gstub"
printf '#!/bin/sh\necho "$@" >> %s/gh.calls\n' "$T" >"$gstub/gh"; chmod +x "$gstub/gh"
OPATH=$PATH; export PATH="$gstub:$PATH"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
git init -q --bare "$T/remote.git"
git clone -q "$T/remote.git" "$T/wt" 2>/dev/null
gc "$T/wt" config user.email t@t; gc "$T/wt" config user.name t
echo base >"$T/wt/a.txt"; echo task0 >"$T/wt/.harness-task.md"; gc "$T/wt" add -A; gc "$T/wt" commit -qm base; gc "$T/wt" push -q origin HEAD:main
gc "$T/wt" checkout -qb issue/7
echo "work in progress" >"$T/wt/b.txt"; mkdir -p "$T/wt/.claude"; echo x >"$T/wt/.claude/ralph-loop.local.md"
echo task >"$T/wt/.harness-task.md"; gc "$T/wt" add .harness-task.md        # staged by the agent, still never committed
HARNESS_SESS_PREFIX=tp HARNESS_TOPOLOGY=multi
TARGETS_TSV="$T/targets.tsv"; printf 'u\towner/repo\t-\tdesc\n' >"$TARGETS_TSV"
echo "$T/wt" >"$RUN_DIR/tp-u-i7.wd"
mk tp-u-i7 "sleep 300"
sup_checkpoint_and_kill tp-u-i7 130 "❯ frozen screen"
assert_ok "WIP pushed to origin/issue/7"        bash -c "git -C '$T/remote.git' show issue/7:b.txt | grep -q 'work in progress'"
assert_eq "$(git -C "$T/remote.git" show issue/7:.harness-task.md)" "task0" ".harness-task.md never committed (even when staged)"
assert_no ".claude never committed"             quiet git -C "$T/remote.git" cat-file -e issue/7:.claude/ralph-loop.local.md
assert_ok "handoff comment with marker"         grep -q "issue comment 7 -R owner/repo --body <!-- harness-handoff issue=7 branch=issue/7 -->" "$T/gh.calls"
assert_ok "the comment carries the last screen" grep -q "frozen screen" "$T/gh.calls"
assert_no "session killed after checkpoint"     quiet tmux has-session -t =tp-u-i7
# diverged remote: never force — push to <branch>-checkpoint-<ts>
gc "$T/wt" reset -q --hard HEAD~1; echo other >"$T/wt/c.txt"
mk tp-u-i7 "sleep 300"
sup_checkpoint_and_kill tp-u-i7 130 "❯ frozen"
assert_ok "diverged remote → pushed to a checkpoint branch" bash -c "git -C '$T/remote.git' branch --list 'issue/7-checkpoint-*' | grep -q ."
assert_ok "…and origin/issue/7 was not force-pushed"         bash -c "git -C '$T/remote.git' show issue/7:b.txt | grep -q 'work in progress'"
# uncommittable (a hook-free failure: no identity) → must NOT kill, or the push would drop the WIP
echo wip2 >"$T/wt/e.txt"; mk tp-u-i7 "sleep 300"
( export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME= GIT_COMMITTER_NAME=; gc "$T/wt" config --unset user.name; gc "$T/wt" config user.useConfigOnly true
  sup_checkpoint_and_kill tp-u-i7 130 "❯ frozen" ); rc=$?
gc "$T/wt" config user.name t; gc "$T/wt" config --unset user.useConfigOnly
assert_no "returns failure when the WIP cannot be committed" test "$rc" = 0
assert_ok "session NOT killed when the WIP cannot be committed" tmux has-session -t =tp-u-i7
assert_ok "commit ERROR logged for a human"           grep -q "ERROR tp-u-i7: could not commit" "$LOG"
# unpushable: origin gone → must NOT kill
echo more >"$T/wt/d.txt"; gc "$T/wt" remote set-url origin "$T/nope.git"; mk tp-u-i7 "sleep 300"
sup_checkpoint_and_kill tp-u-i7 130 "❯ frozen"; rc=$?
assert_no "returns failure when no push is possible"  test "$rc" = 0
assert_ok "session NOT killed when no push is possible" tmux has-session -t =tp-u-i7
assert_ok "ERROR logged for a human"                  grep -q "ERROR tp-u-i7: could not push" "$LOG"
# not on a feature branch (detached HEAD): nowhere safe to push → must NOT kill
gc "$T/wt" checkout -q --detach; mk tp-u-i7 "sleep 300"
sup_checkpoint_and_kill tp-u-i7 130 "❯ frozen"; rc=$?
gc "$T/wt" checkout -q issue/7
assert_no "detached HEAD: returns failure"            test "$rc" = 0
assert_ok "detached HEAD: session NOT killed"         tmux has-session -t =tp-u-i7
assert_ok "detached HEAD: ERROR logged for a human"   grep -q "ERROR tp-u-i7: .* is not on a feature branch (detached)" "$LOG"
# an orch (decompose/review) session has no branch: handoff comment, then kill
: >"$T/gh.calls"; mk tp-u-p9 "sleep 300"
sup_checkpoint_and_kill tp-u-p9 130 "❯ frozen"
assert_ok "orch session: handoff comment without a branch" grep -q "issue comment 9 -R owner/repo --body <!-- harness-handoff issue=9 -->" "$T/gh.calls"
assert_no "orch session: killed"                           quiet tmux has-session -t =tp-u-p9
tmux kill-server 2>/dev/null

echo "=== per-fleet rules: dead workers, orphan locks, paused, stopped ==="
# A fixture fleet with its own .harness/config, discovered through the glob.
F="$T/fleets/proj"; mkdir -p "$F/.harness/run"
printf ': "${HARNESS_SESS_PREFIX:=fx}"\n: "${HARNESS_POOL:=2}"\n: "${HARNESS_REPO:=owner/fx}"\n' >"$F/.harness/config"
SUP_FLEET_GLOB="$T/fleets/*/.harness"; export HARNESS_FLEETS_DIR="$T/registry"
mkdir -p "$HARNESS_FLEETS_DIR"; printf '{"prefix":"fx","project":"%s"}\n' "$F/.harness" >"$HARNESS_FLEETS_DIR/fx.json"
assert_eq "$(sup_fleets)" "$(realpath "$F/.harness")" "registry + glob find the fleet once"
printf '#!/bin/sh\necho "$@" >> %s/harness.calls\n' "$T" >"$T/harness-stub"; chmod +x "$T/harness-stub"
SUP_HARNESS="$T/harness-stub"
sleep 600 & LIVE=$!
dead_pid(){ sh -c 'echo $$' ; }
fleet_reset(){ rm -f "$T/harness.calls" "$T/gh.calls" "$F/.harness/run/"*.pid "$F/.harness/run/PAUSED"; : >"$LOG"; }
# gh stub: issue 5 (no session, labelled long ago), 6 (live session), 8 (labelled just now)
cat >"$gstub/gh" <<EOF
#!/bin/sh
echo "\$@" >> $T/gh.calls
case "\$1 \$2" in
  "issue list") printf '5\n6\n8\n' ;;
  "api repos/owner/fx/issues/5/timeline") echo 2020-01-01T00:00:00Z ;;
  "api repos/owner/fx/issues/6/timeline") echo 2020-01-01T00:00:00Z ;;
  "api repos/owner/fx/issues/8/timeline") date -u +%Y-%m-%dT%H:%M:%SZ ;;
esac
EOF
fleet_reset; echo "$LIVE" >"$F/.harness/run/worker-1.pid"; echo "$LIVE" >"$F/.harness/run/worker-2.pid"
mk fx-main-i6 "printf 'busy\n'; sleep 600"
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_no "live workers → no restart"                       test -f "$T/harness.calls"
assert_ok "orphan lock (no session, old label) → label removed" grep -q "issue edit 5 -R owner/fx --remove-label agent-working" "$T/gh.calls"
assert_ok "orphan lock → explained in a comment"            grep -q "issue comment 5 -R owner/fx" "$T/gh.calls"
assert_no "a lock with a live session is kept"              grep -q "issue edit 6" "$T/gh.calls"
assert_no "a lock younger than LOCK_GRACE is kept"          grep -q "issue edit 8" "$T/gh.calls"
fleet_reset; echo "$LIVE" >"$F/.harness/run/worker-1.pid"; dead_pid >"$F/.harness/run/worker-2.pid"
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_ok "a dead pool worker → harness start for that fleet" grep -q -- "--state-dir $F/.harness start" "$T/harness.calls"
fleet_reset; echo "$LIVE" >"$F/.harness/run/worker-1.pid"; dead_pid >"$F/.harness/run/priority.pid"
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_ok "a dead priority lane → harness start"            test -s "$T/harness.calls"
fleet_reset; dead_pid >"$F/.harness/run/worker-1.pid"; touch "$F/.harness/run/PAUSED"
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_no "a PAUSED fleet is skipped (no restart)"          test -f "$T/harness.calls"
assert_no "a PAUSED fleet is skipped (no gh)"               test -f "$T/gh.calls"
fleet_reset
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_no "a fleet stopped on purpose (no pid files) is skipped" test -f "$T/gh.calls"
fleet_reset; dead_pid >"$F/.harness/run/worker-1.pid"
SUP_DRY=1 SUP_ONCE=1 ONLINE_URL=file:///etc/hostname sup_pass >/dev/null
assert_ok "--dry-run logs the restart"                      grep -q "DRY env -C .* start" "$LOG"
assert_no "--dry-run does nothing"                          test -f "$T/harness.calls"
assert_ok "--dry-run touches no label"                      bash -c "! grep -q 'issue edit' '$T/gh.calls'"
fleet_reset; echo "$LIVE" >"$F/.harness/run/worker-1.pid"
HARNESS_SESS_PREFIX=leaked SUP_DRY=0 sup_check_fleet "$F/.harness"     # an inherited fleet config…
assert_ok "…never overrides the fleet's own config"         grep -q "issue edit 5 -R owner/fx" "$T/gh.calls"
# gh unreachable: logged, the pass goes on (no edit)
mv "$gstub/gh" "$gstub/gh.ok"; printf '#!/bin/sh\necho "$@" >> %s/gh.calls; echo "connection refused" >&2; exit 1\n' "$T" >"$gstub/gh"; chmod +x "$gstub/gh"
fleet_reset; echo "$LIVE" >"$F/.harness/run/worker-1.pid"
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_ok "gh unreachable → WARN logged"                    grep -q "WARN owner/fx: gh unreachable (connection refused)" "$LOG"
assert_no "gh unreachable → no label touched"               grep -q "issue edit" "$T/gh.calls"
mv "$gstub/gh.ok" "$gstub/gh"
# the CLI entry: one --once --dry-run pass over the fixture fleet; an unknown option is refused
fleet_reset; dead_pid >"$F/.harness/run/worker-1.pid"
out="$(HARNESS_SUPERVISE_GLOB="$SUP_FLEET_GLOB" HARNESS_SUPERVISE_HARNESS="$T/harness-stub" ONLINE_URL=file:///etc/hostname \
  bash "$HERE/../scripts/supervise.sh" --once --dry-run 2>&1)"
assert_ok "supervise --once --dry-run previews the restart"  grep -q "DRY env -C .* start" <<<"$out"
assert_no "supervise --once --dry-run acts on nothing"       test -f "$T/harness.calls"
bash "$HERE/../scripts/supervise.sh" --bogus >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "an unknown option exits 2"
kill "$LIVE" 2>/dev/null
tmux kill-server 2>/dev/null

echo "=== arc rules (#181): supervise_rules.py judges, supervise acts ==="
# A stub judge: records what it was handed, prints the canned verdict in $T/rules.out.
cat >"$T/rules-stub" <<EOF
import sys
open("$T/rules.args", "w").write(" ".join(sys.argv[1:]) + "\\n")
open("$T/rules.stdin", "w").write(sys.stdin.read())
import os; open("$T/rules.env", "w").write(os.environ.get("HARNESS_SNAPSHOT_FILE", "") + "\\n")
sys.stdout.write(open("$T/rules.out").read())
EOF
SUP_RULES="$T/rules-stub"
sleep 600 & LIVE=$!
arc_reset(){ fleet_reset; echo "$LIVE" >"$F/.harness/run/worker-1.pid"; : >"$T/rules.out"; rm -f "$T/rules.args" "$T/rules.stdin"; }
arc_out(){ printf '%s\n' "$@" >"$T/rules.out"; }
zw="$T/zw"; git init -q --bare "$T/zremote.git"; git clone -q "$T/zremote.git" "$zw" 2>/dev/null
gc "$zw" commit -q --allow-empty -m base; gc "$zw" push -q origin HEAD:main; gc "$zw" checkout -qb issue/6; gc "$zw" push -q origin issue/6
mk fx-main-i6 "printf 'busy\n'; sleep 600"; mk fx-main-p3 "sleep 600"; mk fx-zz "sleep 600"
arc_reset; arc_out "ALARM frontier:owner/fx NO FRONTIER owner/fx 3 open children" "RESOLVED unfiled"
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_ok "the judge is handed every live session, parsed"  grep -qx "$(printf 'fx-main-i6\towner/fx\t6\timpl')" "$T/rules.stdin"
assert_ok "…an orch session as orch"                        grep -qx "$(printf 'fx-main-p3\towner/fx\t3\torch')" "$T/rules.stdin"
assert_ok "…anything else as other"                         grep -qx "$(printf 'fx-zz\t\t\tother')" "$T/rules.stdin"
assert_ok "…its fleet's on-disk counters and slugs"         grep -q -- "--counters $SUP_STATE/rules/fx.json --repo-dir .* owner/fx" "$T/rules.args"
assert_ok "an ALARM is logged, tagged with its fleet"       grep -q "ALARM frontier:owner/fx NO FRONTIER .*\[fleet fx\]" "$LOG"
assert_ok "a RESOLVED is logged"                            grep -q "RESOLVED unfiled \[fleet fx\]" "$LOG"
assert_eq "$(cat "$T/rules.env")" "" "no fresh poller snapshot → the judge reads gh directly"
printf '{"schema_version":1,"slug":"owner/fx","generated_at":%s,"issues":[]}' "$(date +%s)" >"$HARNESS_SNAPSHOTS_DIR/owner__fx.json"
arc_reset; SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_eq "$(cat "$T/rules.env")" "$HARNESS_SNAPSHOTS_DIR/owner__fx.json" "a fresh poller snapshot → the judge reads it, not gh"
rm -f "$HARNESS_SNAPSHOTS_DIR/owner__fx.json"
arc_reset; arc_out "FIX unlocked owner/fx 6"
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_ok "unlocked work → agent-working re-added"          grep -q "issue edit 6 -R owner/fx --add-label agent-working" "$T/gh.calls"
arc_reset; arc_out "FIX unlocked owner/fx 6"
SUP_DRY=1 sup_check_fleet "$F/.harness"
assert_no "--dry-run re-labels nothing"                     grep -q "add-label" "$T/gh.calls"
assert_ok "--dry-run judges on a throwaway copy of the counters" grep -q -- "--counters $SUP_STATE/rules/fx.json.dry" "$T/rules.args"
assert_no "…which is removed afterwards"                    test -e "$SUP_STATE/rules/fx.json.dry"
echo "$zw" >"$F/.harness/run/fx-main-i6.wd"
arc_reset; arc_out "FIX zombie fx-main-i6"
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_no "a clean zombie is killed"                        quiet tmux has-session -t =fx-main-i6
assert_no "…without a checkpoint comment"                   grep -q "issue comment 6" "$T/gh.calls"
mk fx-main-i6 "sleep 600"; echo wip >"$zw/z.txt"
arc_reset; arc_out "FIX zombie fx-main-i6"
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_ok "a zombie holding WIP is checkpointed first"      bash -c "git -C '$T/zremote.git' show issue/6:z.txt | grep -q wip"
assert_ok "…with a comment saying why"                      grep -q "still alive after its issue closed" "$T/gh.calls"
assert_no "…then killed"                                    quiet tmux has-session -t =fx-main-i6
mk fx-main-i6 "printf 'STOP_HOOK_BLOCK_CAP\n'; sleep 600"; echo wip2 >"$zw/w.txt"; sleep 1
arc_reset; arc_out "FIX wedged fx-main-i6"
SUP_DRY=0 sup_check_fleet "$F/.harness"
assert_ok "a wedged session's WIP is pushed"                bash -c "git -C '$T/zremote.git' show issue/6:w.txt | grep -q wip2"
assert_ok "…the handoff says it hit the block cap"          grep -q "hit the stop-hook block cap" "$T/gh.calls"
assert_ok "…and carries its last screen"                    grep -q "STOP_HOOK_BLOCK_CAP" "$T/gh.calls"
assert_no "…then it is killed"                              quiet tmux has-session -t =fx-main-i6
# --alarms reads the real judge's on-disk counters
mkdir -p "$SUP_STATE/rules"; printf '{"firing":["wf-leak:owner/fx"],"messages":{"wf-leak:owner/fx":"WAYFINDER LEAK owner/fx [11]"}}' >"$SUP_STATE/rules/fx.json"
out="$(HARNESS_SUPERVISE_STATE="$SUP_STATE" bash "$HERE/../scripts/supervise.sh" --alarms)"
assert_eq "$out" "$(printf 'fx\twf-leak:owner/fx\tWAYFINDER LEAK owner/fx [11]')" "supervise --alarms lists what is firing"
kill "$LIVE" 2>/dev/null
tmux kill-server 2>/dev/null
SUP_RULES="$HERE/../scripts/supervise_rules.py"

echo "=== non-Harness agent panes (EXTRA_RE): nudge only ==="
: >"$LOG"; rm -rf "$SUP_STATE/panes"; EXTRA_MIN=0
# pane_current_command must read `claude`: run the pane through a binary of that name.
mkdir -p "$T/xbin"; ln -sf "$(command -v sleep)" "$T/xbin/claude"
mk hg2 "printf 'waiting\n❯ \n'; exec $T/xbin/claude 600"
mk other "printf 'waiting\n❯ \n'; exec $T/xbin/claude 600"
sleep 1; EXTRA_RE='^hg2$'
SUP_DRY=1 sup_check_extra; sleep 1; SUP_DRY=1 sup_check_extra
assert_ok "a quiet EXTRA_RE agent pane is nudged"           grep -qE "send-keys -t hg2:[0-9]+\.[0-9]+ -l" "$LOG"
assert_no "a session outside EXTRA_RE is not watched"       grep -q "other" "$LOG"
assert_no "EXTRA_RE panes are never killed"                 grep -q "kill-session" "$LOG"
tmux kill-server 2>/dev/null
export PATH=$OPATH

echo "=== systemd user unit ==="
U="$T/unit"; mkdir -p "$T/tools"
for b in claude gh rtdd; do printf '#!/bin/sh\n' >"$T/tools/$b"; chmod +x "$T/tools/$b"; done
printf '#!/bin/sh\necho "$@" >> %s/systemctl.calls\n' "$T" >"$T/systemctl"; chmod +x "$T/systemctl"
printf '#!/bin/sh\necho "$@" >> %s/loginctl.calls\n' "$T" >"$T/loginctl"; chmod +x "$T/loginctl"
SUP_UNIT_DIR=$U SUP_SYSTEMCTL=$T/systemctl SUP_LOGINCTL=$T/loginctl SUP_HARNESS=/eng/bin/harness
out="$(PATH="$T/tools:$PATH" sup_install 2>&1)"
assert_ok "--install writes the unit"                       test -f "$U/harness-supervise.service"
assert_ok "unit restarts always"                            grep -qx "Restart=always" "$U/harness-supervise.service"
assert_ok "a unit restart never kills the fleets it started" grep -qx "KillMode=process" "$U/harness-supervise.service"
assert_ok "unit runs this engine's supervise"               grep -qx "ExecStart=/eng/bin/harness supervise" "$U/harness-supervise.service"
assert_ok "unit PATH holds the claude/gh/rtdd dir"          grep -q "^Environment=PATH=$T/tools:" "$U/harness-supervise.service"
assert_ok "systemd reloaded + enabled + (re)started"        bash -c "grep -q daemon-reload '$T/systemctl.calls' && grep -q 'enable harness-supervise' '$T/systemctl.calls' && grep -q 'restart harness-supervise' '$T/systemctl.calls'"
assert_ok "linger enabled"                                  grep -q enable-linger "$T/loginctl.calls"
assert_ok "installed from this engine"                      sup_installed
other_engine(){ local SUP_HARNESS=/other/bin/harness; sup_installed; }
assert_no "another engine's checkout does not own the unit" other_engine
rm "$T/tools/rtdd"
out="$(PATH="$T/tools:/usr/bin:/bin" sup_install 2>&1)"
assert_ok "a missing rtdd is warned about"                  grep -q "'rtdd' is not on PATH.*full test suites" <<<"$out"
printf '#!/bin/sh\nexit 1\n' >"$T/loginctl"
out="$(PATH="$T/tools:$PATH" sup_install 2>&1)"
assert_ok "a linger failure is warned about"                grep -q "enable-linger failed" <<<"$out"
sup_uninstall >/dev/null
assert_no "--uninstall removes the unit"                    test -f "$U/harness-supervise.service"
assert_ok "--uninstall disables it"                         grep -q "disable --now harness-supervise" "$T/systemctl.calls"
assert_ok "harness help lists supervise"                    bash -c "bash '$HERE/../bin/harness' help | grep -q '^  supervise'"
assert_ok "harness supervise dispatches"                    bash -c "bash '$HERE/../bin/harness' supervise --help | grep -qi 'host-level supervisor'"

echo "=== harness update redeploys the unit; uninstall removes it ==="
R="$HERE/.."
REMOTE="$T/eng-remote.git"; git init -q --bare -b main "$REMOTE"
EW="$T/eng-work"; mkdir -p "$EW/scripts" "$EW/bin"
cp "$R/update.sh" "$R/install.sh" "$EW/"; cp "$R/scripts/supervise.sh" "$EW/scripts/"; cp "$R/bin/harness" "$EW/bin/"
gc "$EW" init -q -b main; gc "$EW" add -A; gc "$EW" commit -qm init; gc "$EW" remote add origin "$REMOTE"; gc "$EW" push -q -u origin main
ENG="$T/engine"; git clone -q "$REMOTE" "$ENG"
U2="$T/unit2"; mkdir -p "$U2"; : >"$T/systemctl.calls"
printf '[Service]\nExecStart=%s/bin/harness supervise\nEnvironment=PATH=stale\n' "$ENG" >"$U2/harness-supervise.service"
upd(){ HARNESS_SKIP_RTDD=1 HARNESS_SUPERVISE_UNIT_DIR="$U2" HARNESS_SUPERVISE_SYSTEMCTL="$T/systemctl" \
  HARNESS_SUPERVISE_LOGINCTL="$T/loginctl" ENGINE_DIR="$ENG" bash "$R/update.sh" >/dev/null 2>&1; }   # this checkout's update.sh, driving the $ENG install
upd
assert_no "update rewrites an installed unit (stale PATH gone)" grep -q "PATH=stale" "$U2/harness-supervise.service"
assert_ok "update restarts the supervisor on the new engine"    grep -q "restart harness-supervise" "$T/systemctl.calls"
printf '[Service]\nExecStart=/other/bin/harness supervise\nEnvironment=PATH=stale\n' >"$U2/harness-supervise.service"
: >"$T/systemctl.calls"; upd
assert_ok "update leaves another engine's unit alone"           grep -q "PATH=stale" "$U2/harness-supervise.service"
assert_no "…and restarts nothing"                               grep -q restart "$T/systemctl.calls"
rm -f "$U2/harness-supervise.service"; : >"$T/systemctl.calls"; upd
assert_no "update never installs a unit that was not installed" test -f "$U2/harness-supervise.service"
UR="$T/un"; mkdir -p "$UR/.harness/engine" "$UR/bin" "$UR/proj/.harness"
printf '[Service]\nExecStart=%s/bin/harness supervise\n' "$(cd "$R" && pwd)" >"$U2/harness-supervise.service"
( HARNESS_UNINSTALL_NOMAIN=1 HARNESS_HOME="$UR/.harness" HARNESS_BIN_DIR="$UR/bin" HARNESS_USER_SKILLS="$UR/skills" \
  STATE_DIR="$UR/proj/.harness" HARNESS_SUPERVISE_UNIT_DIR="$U2" HARNESS_SUPERVISE_SYSTEMCTL="$T/systemctl" \
  bash -c 'source "$1"; other_fleets_depend_on_engine(){ return 1; }; main --force' _ "$R/scripts/uninstall.sh" ) >/dev/null 2>&1 </dev/null
assert_no "uninstall removes this engine's supervisor unit"     test -f "$U2/harness-supervise.service"

echo "=== reaping a session also reaps its scratch ==="
co="$T/co"; git init -q "$co"; gc "$co" commit -q --allow-empty -m base
wd="$T/worktrees/u-i42"; gc "$co" worktree add -q "$wd" 2>/dev/null
export HARNESS_TMP_ROOT="$T/tmproot"; san="$(printf '%s' "$wd" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$HARNESS_TMP_ROOT/claude-$(id -u)/$san/cache"
gc "$co" worktree add -q --detach "$HARNESS_TMP_ROOT/hz-baseline-42" 2>/dev/null
gc "$co" worktree add -q --detach "$HARNESS_TMP_ROOT/hz-baseline-43" 2>/dev/null
remove_worktree "$co" "$wd"
assert_no "the session's Claude Code scratch dir is removed" test -d "$HARNESS_TMP_ROOT/claude-$(id -u)/$san"
assert_no "its /tmp/hz-*-<n> worktree is removed"            test -d "$HARNESS_TMP_ROOT/hz-baseline-42"
assert_ok "another issue's /tmp/hz-* worktree is kept"       test -d "$HARNESS_TMP_ROOT/hz-baseline-43"
finish

#!/usr/bin/env bash
# test_one_run.sh — #366: `harness one start | phase | release`, the /harness-one execution, on a real
# git fixture and a stubbed gh (no live GitHub). start re-checks the precondition, claims agent-working
# and sets the issue up the way dispatch does (impl.md; resume.md for an agent-paused issue), with a
# lease the reapers honour; phase FITS or CHECKPOINTs on the forecast left, and a CHECKPOINT is the
# very instruction `pause --force` sends a lane (same message, same labels); release leaves nothing
# behind, so the pool's own spawn_impl resumes the issue. The per-phase math itself is test_one.py's.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/helpers.sh"
make_env
export RUN_DIR HARNESS_STATE_DIR_OK=1 HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme
HARNESS_TOPOLOGY=single
export GIT_CONFIG_GLOBAL="$RUN_DIR/gitconfig"; : > "$GIT_CONFIG_GLOBAL"   # ensure_safe writes here, not ~
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$STATE_DIR"; : > "$STATE_DIR/config"
ONE=(bash "$HERE/../scripts/one.sh")

# ── fixture: the project checkout (PROJECT_ROOT = RUN_DIR) with a bare origin ───────────────────
git init -q --bare -b main "$RUN_DIR/origin.git"
git -C "$RUN_DIR" init -q -b main
printf 'state/\nhost/\n*.stub\n' > "$RUN_DIR/.gitignore"; echo hi > "$RUN_DIR/README"
git -C "$RUN_DIR" add README .gitignore; git -C "$RUN_DIR" commit -qm init
git -C "$RUN_DIR" remote add origin "$RUN_DIR/origin.git"; git -C "$RUN_DIR" push -q origin main

# ── gh stub: issue #7's state + labels in files; every edit logged ──────────────────────────────
GH="$RUN_DIR/gh"; mkdir -p "$GH" "$RUN_DIR/bin"; echo OPEN > "$GH/state"; echo ready-for-agent > "$GH/labels"
cat > "$RUN_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
GH="$(dirname "$0")/../gh"; q=""; prev=""
for a in "$@"; do [[ "$prev" == -q ]] && q="$a"; prev="$a"; done
case "$1 $2" in
  "issue view")
    if [[ "$q" == *join* ]]; then echo "$(cat "$GH/state") $(cat "$GH/labels")"
    elif [[ "$q" == *labels* ]]; then python3 -c 'import json,sys; print(json.dumps([l for l in sys.argv[1].split(",") if l]))' "$(cat "$GH/labels")"
    elif [[ "$q" == *body* ]]; then echo ""
    else python3 -c 'import json,sys; print(json.dumps({"state": sys.argv[1], "labels": [{"name": l} for l in sys.argv[2].split(",") if l]}, separators=(",", ":")))' "$(cat "$GH/state")" "$(cat "$GH/labels")"; fi;;
  "issue edit")
    echo "edit $*" >> "$GH/log"; prev=""
    for a in "$@"; do
      [[ "$prev" == --add-label ]] && { grep -qx "$a" <(tr , '\n' < "$GH/labels") || sed -i "s/\$/,$a/; s/^,//" "$GH/labels"; }
      [[ "$prev" == --remove-label ]] && { tr , '\n' < "$GH/labels" | grep -vx "$a" | paste -sd, - > "$GH/l.tmp"; mv "$GH/l.tmp" "$GH/labels"; }
      prev="$a"
    done;;
  "repo view") echo main;;
  *) exit 1;;
esac
EOF
chmod +x "$RUN_DIR/bin/gh"; export PATH="$RUN_DIR/bin:$PATH"
has_label(){ tr , '\n' < "$GH/labels" | grep -qx "$1"; }

# ── usage + forecast fixture (as test_one.sh): one past lane, p80 = 2 % of the window at
# HARNESS_ONE_USD_PER_PCT=5, spread evenly over the five phases (0.4 % each) — no transcript ─────
STUB="$RUN_DIR/usage.stub"; future=$(( $(date +%s) + 3600 ))
export HARNESS_USAGE_CMD="cat '$STUB'" HARNESS_ONE_USD_PER_PCT=5
stub_usage(){ printf 'main\tseven_day\t%s\t%s\n' "$1" "$future" > "$STUB"; mkdir -p "$(_usage_dir)"; touch "$(_usage_dir)/main.json"; }
EV="$RUN_DIR/events.jsonl"
cat > "$EV" <<'EOF'
{"event": "launch", "ts": "2026-10-01T00:00:00Z", "prefix": "hz", "repo": "acme/widget", "unit": "main", "kind": "impl", "issue": 1, "session": "s1"}
{"event": "session_end", "ts": "2026-10-01T01:00:00Z", "prefix": "hz", "repo": "acme/widget", "unit": "main", "kind": "impl", "issue": 1, "session": "s1", "usage": {"claude-opus-5-5": {"output": 400000}}}
EOF
BODIES="$RUN_DIR/bodies.json"
printf '[{"number": 1, "body": "%s"}, {"number": 7, "body": "%s"}]\n' "$(printf 'x%.0s' {1..80})" "$(printf 'y%.0s' {1..80})" > "$BODIES"
phase(){ "${ONE[@]}" phase 7 "$1" --events "$EV" --bodies "$BODIES" "${@:2}"; }
WD="$WORKTREES_DIR/main-i7"; LEASE="$(one_lease_file main 7)"; stub_usage 10

# ── start: the precondition is re-checked immediately before the claim ──────────────────────────
"${ONE[@]}" start 7 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "3" "start on a RUNNING, un-held fleet is refused"
assert_no "and nothing was claimed" has_label agent-working
assert_no "and no worktree set up" test -d "$WD"

touch "$RUN_DIR/PAUSED"
phase explore >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "phase on an issue harness one start did not claim is a usage error"

out="$("${ONE[@]}" start 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "start on a PAUSED fleet claims"
assert_ok "the issue is claimed agent-working" has_label agent-working
assert_ok "on its own worktree, the way dispatch sets it up" test -d "$WD"
assert_eq "$(git -C "$WD" rev-parse --abbrev-ref HEAD)" "issue/7" "on branch issue/7"
assert_ok "impl.md is rendered for a fresh issue" grep -q '^You are an implementation engineer on main' "$WD/.harness-task.md"
assert_ok "rendered for #7 with its promise" grep -q 'ISSUE 7 DONE' "$WD/.harness-task.md"
assert_ok "the task ends with the per-phase re-check" grep -q 'one phase 7 <phase> --unit main' "$WD/.harness-task.md"
assert_ok "and the release" grep -q 'one release 7 --unit main' "$WD/.harness-task.md"
assert_ok "and the hand-back to done (#367)" grep -q 'one done 7 --unit main. confirms it DONE' "$WD/.harness-task.md"
assert_ok "the lease is taken" test -f "$LEASE"
assert_ok "start says what it rendered" grep -q 'rendered impl.md' <<<"$out"

"${ONE[@]}" start 7 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "4" "an issue already agent-working is not claimed twice"

# ── the lease keeps the pool's reapers off the issue ────────────────────────────────────────────
UNIT=main REPO=acme/widget SLUG=acme/widget PROJECT=main DESC=widget CHECKOUT="$RUN_DIR"
stats_sweep_ended(){ :; }
reap_team
assert_ok "reap_team keeps off a leased worktree (no tmux session works it)" test -d "$WD"
assert_ok "the lock sweeps count the lease as a live session" issue_session_live acme/widget 7

# ── phase: FITS, or the checkpoint pause --force sends ──────────────────────────────────────────
touch -d '-1 hour' "$LEASE"
stub_usage 95.6
out="$(phase ship 2>&1)"; rc=$?
assert_eq "$rc" "0" "before ship: 95.6% + 0.4% left + 2% reserve = 98%: FITS"
assert_ok "and says so" grep -q 'FITS — go on with ship' <<<"$out"
assert_ok "each phase refreshes the lease" test "$(( $(date +%s) - $(stat -c %Y "$LEASE") ))" -lt 60
out="$(phase explore 2>&1)"; rc=$?
assert_eq "$rc" "1" "before explore: 95.6% + 2% (the whole issue) + 2% = 99.6%: CHECKPOINT"
assert_ok "the arithmetic names the window" grep -q 'CHECKPOINT — main seven_day: 99.6% > 98%' <<<"$out"
reason="harness one: the forecast left from explore no longer fits under HARNESS_ONE_STOP_PCT=98%"
want="$(_checkpoint_msg 7 acme/widget issue/7 agent-working agent-paused "$reason")"
assert_ok "the checkpoint is _checkpoint_msg, the instruction pause --force sends" grep -qxF "$want" <<<"$out"
# pause --force, for the lane hz-main-i7 that would work #7: the same instruction, its reason aside
_checkpoint_target hz-main-i7
lane="$(_checkpoint_msg "$_CP_ISSUE" "$_CP_SLUG" "$_CP_BRANCH" "$HARNESS_LABEL_WORKING" "$HARNESS_LABEL_PAUSED")"
assert_eq "${want#*"$reason"}" "${lane#*pause requested}" "word for word what pause --force sends lane hz-main-i7"
assert_ok "it pushes the branch" grep -q 'push your branch to origin' <<<"$out"
assert_ok "posts the handoff marker" grep -qF '`<!-- harness-handoff issue=7 branch=issue/7 -->`' <<<"$out"
assert_ok "and swaps agent-working for agent-paused" grep -qF -- '--remove-label agent-working --add-label agent-paused' <<<"$out"
assert_ok "then release, instead of exiting" grep -q 'one release 7 --unit main' <<<"$out"
phase explore --json > "$RUN_DIR/p.json" 2>/dev/null; rc=$?
assert_eq "$rc:$(python3 -c 'import json,sys; g=json.load(open(sys.argv[1])); print(g["verdict"], g["phase"])' "$RUN_DIR/p.json")" \
  "1:CHECKPOINT explore" "--json carries the verdict"

# ── release: refuses to drop unpushed work; after the checkpoint leaves nothing behind ──────────
echo wip > "$WD/wip.txt"; git -C "$WD" add wip.txt; git -C "$WD" commit -qm wip
"${ONE[@]}" release 7 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "4" "release refuses while the branch has unpushed commits"
assert_ok "and keeps the worktree" test -d "$WD"
# the session follows the checkpoint: push + label swap (the handoff comment is gh's to post)
git -C "$WD" push -q origin issue/7
gh issue edit 7 -R acme/widget --remove-label agent-working --add-label agent-paused
out="$("${ONE[@]}" release 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "release after the checkpoint"
assert_no "the worktree is gone" test -d "$WD"
assert_no "the local branch is gone" git -C "$RUN_DIR" rev-parse -q --verify refs/heads/issue/7
assert_no "the lease is gone" test -f "$LEASE"
assert_ok "the issue stays agent-paused" has_label agent-paused
assert_no "and is not agent-working" has_label agent-working
assert_ok "release says the pool resumes it" grep -q 'the pool resumes it' <<<"$out"

# ── the pool resumes it, through its own spawn_impl path, from the pushed branch ─────────────────
RENDERED="$RUN_DIR/rendered"
( render(){ echo "$1" > "$RENDERED"; }; launch_claude(){ echo "$1" >> "$RENDERED"; }; issue_parent_prd(){ :; }
  spawn_impl 7 "ISSUE 7 DONE" ) >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "the pool's spawn_impl sets #7 up again — nothing of this session's in its way"
assert_ok "from resume.md" grep -q 'resume.md$' "$RENDERED"
assert_ok "and launches its lane" grep -qx 'hz-main-i7' "$RENDERED"
remove_worktree "$RUN_DIR" "$WD" issue/7
gh issue edit 7 -R acme/widget --remove-label agent-working   # that lane is gone again; #7 is agent-paused

# ── an agent-paused issue started by harness one renders resume.md ───────────────────────────────
out="$("${ONE[@]}" start 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "start an agent-paused issue"
assert_ok "renders resume.md" grep -q 'rendered resume.md' <<<"$out"
assert_ok "the task resumes #7" grep -q '^You are RESUMING a previously force-paused implementation of issue #7' "$WD/.harness-task.md"
assert_ok "claimed agent-working" has_label agent-working

# ── a release that never checkpointed frees the lock, as a reap would ────────────────────────────
gh issue edit 7 -R acme/widget --remove-label agent-paused
out="$("${ONE[@]}" release 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "release with nothing unpushed"
assert_no "agent-working is cleared" has_label agent-working
assert_ok "and says so" grep -q 'not checkpointed' <<<"$out"

# ── a lease nothing refreshes is a dead session: the pool reaps it like any lane ────────────────
"${ONE[@]}" start 7 >/dev/null 2>&1
touch -d "-$(( HARNESS_ONE_LEASE_MIN + 1 )) minutes" "$LEASE"
assert_no "a stale lease is not a live session" issue_session_live acme/widget 7
reap_team
assert_no "reap_team reaps a worktree whose lease went stale" test -d "$WD"
assert_no "and drops the lease" test -f "$LEASE"
assert_no "and the lock" has_label agent-working
# ── #445: the interactive session's own spend, through the claude adapter's real sources ────────
# No HARNESS_USAGE_CMD stub: claude_limit_usage reads the status-line drop a lane left before the fleet
# paused — frozen from here on, nothing edits it — and the session's spend lands where Claude Code
# writes it, its account's config dir (<account>/projects/<slug>/<session>.jsonl). Each phase must see
# that spend on top of the frozen reading, at HARNESS_ONE_USD_PER_PCT=5 ($5 per 1%).
unset HARNESS_USAGE_CMD
ACCT="$RUN_DIR/accounts/main"; CCD_WAS="$HARNESS_CLAUDE_CONFIG_DIRS"; export HARNESS_CLAUDE_CONFIG_DIRS="$ACCT"
TR="$ACCT/projects/-work-widget/s445.jsonl"; mkdir -p "$(dirname "$TR")"; : > "$TR"
DROP="$(_usage_dir)/main.json"
drop(){ # <pct> <resets_at> <taken at> — what usage-statusline.sh writes for account main
  python3 -c 'import json,sys; json.dump({"account": "main", "at": int(sys.argv[3]), "rate_limits": {"seven_day": {"used_percentage": float(sys.argv[1]), "resets_at": int(sys.argv[2])}}}, open(sys.argv[4], "w"))' \
    "$1" "$2" "$3" "$DROP"; touch -d "@$3" "$DROP"; }
MSG=0
spend(){ # <usd> — the session's next message, as Claude Code logs it: opus output at $25/Mtok
  MSG=$(( MSG + 1 ))
  python3 -c 'import json,sys,time; print(json.dumps({"type": "assistant", "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "message": {"id": "msg" + sys.argv[2], "model": "claude-opus-5-5", "usage": {"output_tokens": int(float(sys.argv[1]) * 40000)}}}))' \
    "$1" "$MSG" >> "$TR"; }
drop 90 "$future" "$(( $(date +%s) - 120 ))"; frozen="$(sha1sum < "$DROP")$(stat -c %Y "$DROP")"
out="$("${ONE[@]}" start 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "#445: start #7 with the fleet paused and only a frozen status-line reading"
assert_ok "start keeps the readings it saw" grep -qP '^main\tseven_day\t90(\.0)?\t' "$(one_start_file main 7)"
out="$(phase explore 2>&1)"; rc=$?
assert_eq "$rc" "0" "before explore: 90% + nothing spent + 2% + 2% = 94%: FITS"
spend 10   # 2%
out="$(phase test 2>&1)"; rc=$?
assert_eq "$rc" "0" "before test: 90% + 2% spent + 1.6% + 2% = 95.6%: FITS"
assert_ok "the check names the spend since the reading" grep -q 'now 92% (read 90% + 2% spent since: \$10 in transcripts)' <<<"$out"
spend 15   # 3% more
out="$(phase impl 2>&1)"; rc=$?
assert_eq "$rc" "1" "before impl: 90% + 5% spent + 1.2% + 2% = 98.2%: CHECKPOINT on the session's own spend"
assert_ok "naming the window" grep -q 'CHECKPOINT — main seven_day: 98.2% > 98%' <<<"$out"
assert_ok "with the checkpoint instruction" grep -q '^HARNESS CHECKPOINT' <<<"$out"
assert_eq "$(sha1sum < "$DROP")$(stat -c %Y "$DROP")" "$frozen" "the reading stayed frozen throughout — nothing edited it"
# the spend cannot be counted (no config dir is account main's): the frozen reading never FITS
out="$(HARNESS_CLAUDE_CONFIG_DIRS="$RUN_DIR/elsewhere" phase ship 2>&1)"; rc=$?
assert_eq "$rc" "1" "a reading from before the start whose spend is uncountable: CHECKPOINT"
assert_ok "saying the usage is stale" grep -q 'main seven_day: usage stale — the reading is taken before this session started' <<<"$out"
"${ONE[@]}" release 7 --force >/dev/null 2>&1
assert_no "release drops the start snapshot" test -f "$(one_start_file main 7)"

# a window read at start and reset since: claude_limit_usage drops it, the check puts it back at 0%
# (#454) No fixed timing: start must read the window before its reset — under load start can take
# longer than any fixed lead, and an empty snapshot leaves phase nothing to check — so the lead
# doubles until start's snapshot holds the window; then wait until the reset has passed, so the
# spend is logged after it and phase sees it reset, however long either step took.
for lead in 2 4 8 16 32 64 128; do
  reset=$(( $(date +%s) + lead ))
  drop 90 "$reset" "$(( $(date +%s) - 60 ))"
  "${ONE[@]}" start 7 >/dev/null 2>&1
  grep -qP "^main\tseven_day\t90(\.0)?\t$reset\t" "$(one_start_file main 7)" 2>/dev/null && break
  "${ONE[@]}" release 7 --force >/dev/null 2>&1
done
assert_ok "start read the window before its reset" grep -qP "^main\tseven_day\t90(\.0)?\t$reset\t" "$(one_start_file main 7)"
until (( $(date +%s) > reset )); do sleep 0.2; done
spend 4   # 0.8% since the reset
out="$(phase ship 2>&1)"; rc=$?
assert_eq "$rc" "0" "after the reset: 0% + 0.8% spent + 0.4% + 2% = 3.2%: FITS"
assert_ok "the reset window is checked, not dropped" grep -q 'main seven_day: now 0.8% (read 0% at reset + 0.8% spent since' <<<"$out"
out="$(HARNESS_CLAUDE_CONFIG_DIRS="$RUN_DIR/elsewhere" phase ship 2>&1)"; rc=$?
assert_eq "$rc" "1" "a reset window whose spend since is uncountable: CHECKPOINT, never a silent 0%"
assert_ok "saying why" grep -q 'usage stale — the reading is gone since its window reset' <<<"$out"
"${ONE[@]}" release 7 --force >/dev/null 2>&1
# ── #452: a window of the session's own account (CLAUDE_CONFIG_DIR's basename) that no reading holds ─
# (a) Multi-account host: the only drop is account sub's, while this session runs on main and spends
# $480 (96%) — sub spent nothing. Each of main's windows is checked from 0% at the start + that spend.
after_start(){ local t0; t0="$(head -1 "$(one_start_file main 7)")"; until (( $(date +%s) > t0 )); do sleep 0.2; done; }
SUBD="$RUN_DIR/accounts/sub"; mkdir -p "$SUBD/projects"; export HARNESS_CLAUDE_CONFIG_DIRS="$ACCT:$SUBD"
rm -f "$DROP"
python3 -c 'import json,sys,time; json.dump({"account": "sub", "at": int(time.time()), "rate_limits": {"seven_day": {"used_percentage": 10.0, "resets_at": int(sys.argv[1])}}}, open(sys.argv[2], "w"))' \
  "$future" "$(_usage_dir)/sub.json"
out="$(CLAUDE_CONFIG_DIR="$ACCT" "${ONE[@]}" start 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "#452: start #7 with only account sub read"
out="$(CLAUDE_CONFIG_DIR="$ACCT" phase explore 2>&1)"; rc=$?
assert_eq "$rc" "0" "#452: nothing spent yet: main's unread windows at 0% + 2% + 2%: FITS"
assert_ok "main's windows are checked though no reading holds them" grep -q 'main seven_day: now 0% (read 0% at start (no reading of it) + 0% spent since' <<<"$out"
after_start   # a message logged in start's own second is not "since" it
spend 480   # 96% of main
out="$(CLAUDE_CONFIG_DIR="$ACCT" phase test 2>&1)"; rc=$?
assert_eq "$rc" "1" "#452: the session's account spent 96% + 1.6% + 2% = 99.6%: CHECKPOINT though sub is at 10%"
assert_ok "naming the session's account" grep -q 'CHECKPOINT — main five_hour: 99.6% > 98%; main seven_day: 99.6% > 98%' <<<"$out"
# no config dir is the session account's: no lower bound — listed as unchecked, with a warning
out="$(CLAUDE_CONFIG_DIR="$RUN_DIR/accounts/ghost" phase test 2>&1)"; rc=$?
assert_ok "an uncountable session account is listed unchecked, never left out" grep -q 'unchecked: ghost five_hour: WARNING' <<<"$out"
"${ONE[@]}" release 7 --force >/dev/null 2>&1
# (b) The fleet paused past a 5h reset: the drop's five_hour has reset, so claude_limit_usage drops it
# and start's snapshot never holds it — only seven_day is read. The session's spend since the start
# must still reach five_hour.
rm -f "$(_usage_dir)/sub.json"; export HARNESS_CLAUDE_CONFIG_DIRS="$ACCT"
python3 -c 'import json,sys,time; json.dump({"account": "main", "at": int(time.time()), "rate_limits": {"five_hour": {"used_percentage": 90.0, "resets_at": int(time.time()) - 60}, "seven_day": {"used_percentage": 1.0, "resets_at": int(sys.argv[1])}}}, open(sys.argv[2], "w"))' \
  "$future" "$DROP"
out="$(CLAUDE_CONFIG_DIR="$ACCT" "${ONE[@]}" start 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "#452: start #7 after the 5h window reset"
assert_no "start's snapshot does not hold the reset window" grep -qP '^main\tfive_hour\t' "$(one_start_file main 7)"
after_start
spend 480   # 96%
out="$(CLAUDE_CONFIG_DIR="$ACCT" phase gate 2>&1)"; rc=$?
assert_eq "$rc" "1" "#452: the reset 5h window: 0% + 96% spent since start + 0.8% + 2% = 98.8%: CHECKPOINT"
assert_ok "the 5h window is checked from the start" grep -q 'main five_hour: now 96% (read 0% at start (no reading of it) + 96% spent since: \$480 in transcripts)' <<<"$out"
assert_ok "and CHECKPOINTs on its own arithmetic" grep -qE '^CHECKPOINT — .*main five_hour: 98.8% > 98%' <<<"$out"
"${ONE[@]}" release 7 --force >/dev/null 2>&1
export HARNESS_USAGE_CMD="cat '$STUB'" HARNESS_CLAUDE_CONFIG_DIRS="$CCD_WAS"
# ── #451: usage from a live query — HARNESS_USAGE_CMD, the codex adapter — and no claude drop ─────
# Nothing dates these readings (no <usage-dir>/<account>.json, no usage cache), and no Claude config
# dir is account codex's, so its spend since cannot be counted: the reading is as current as the
# query, padded as before #445 — FITS under the stop %, CHECKPOINT over it, never "usage stale".
rm -f "$DROP"; printf 'codex\t5h\t10\t%s\n' "$future" > "$STUB"
out="$("${ONE[@]}" start 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "#451: start #7 with usage from HARNESS_USAGE_CMD and no claude status-line drop"
out="$(phase explore 2>&1)"; rc=$?
assert_eq "$rc" "0" "#451: before explore: codex 10% + 3 stale pad + 2% + 2% = 17%: FITS"
assert_ok "the live reading is padded" grep -q 'codex 5h: now 10% + 3 stale pad (age unknown' <<<"$out"
assert_no "not stopped as stale" grep -q 'usage stale' <<<"$out"
printf 'codex\t5h\t92\t%s\n' "$future" > "$STUB"
out="$(phase explore 2>&1)"; rc=$?
assert_eq "$rc" "1" "#451: before explore: codex 92% + 3 + 2% + 2% = 99%: CHECKPOINT"
assert_ok "on the arithmetic" grep -q 'CHECKPOINT — codex 5h: 99% > 98%' <<<"$out"
# the codex adapter itself: the newest rollout's rate_limits, read live from its session files
CX="$RUN_DIR/codex-home/sessions/2026/11/03"; mkdir -p "$CX"
cx(){ printf '{"type": "event_msg", "payload": {"type": "token_count", "rate_limits": {"limit_id": "codex", "primary": {"used_percent": %s, "window_minutes": 300, "resets_at": %s}}}}\n' "$1" "$future" > "$CX/rollout-2026-11-03T00-00-00-s451.jsonl"; }
cx_phase(){ HARNESS_USAGE_CMD="" HARNESS_CLI=codex CODEX_HOME="$RUN_DIR/codex-home" phase "$@"; }
cx 10; out="$(cx_phase test 2>&1)"; rc=$?
assert_eq "$rc" "0" "#451: the codex adapter's reading, 10% + 3 + 1.6% + 2%: FITS"
assert_ok "read through codex_limit_usage" grep -q 'codex 5h: now 10% + 3 stale pad' <<<"$out"
cx 93; out="$(cx_phase test 2>&1)"; rc=$?
assert_eq "$rc" "1" "#451: the codex adapter's reading, 93% + 3 + 1.6% + 2% = 99.6%: CHECKPOINT"
assert_ok "on the arithmetic, not as stale" grep -q 'CHECKPOINT — codex 5h: 99.6% > 98%' <<<"$out"
"${ONE[@]}" release 7 --force >/dev/null 2>&1
# ── done (#367): the goal check reap_done_sessions runs, then the next claimable issue's fresh gate ─
# The board comes from a snapshot (issuelib's read seam), so `check` and `next` never reach gh.
SNAP="$RUN_DIR/board.json"
board(){ python3 - "$SNAP" "$@" <<'PYEOF'
import json, sys
path, spec = sys.argv[1], sys.argv[2:]
issues = []
for s in spec:   # <n>:<STATE>:<label,label>[:<blocked-by n>]
    n, state, labels, *dep = s.split(":")
    body = (f"## Blocked by\n#{dep[0]}\n" if dep else "")
    issues.append({"number": int(n), "title": f"t{n}", "state": state, "body": body, "updatedAt": "",
                   "author": {"login": "me"}, "labels": [{"name": l} for l in labels.split(",") if l]})
json.dump({"slug": "acme/widget", "self_login": "me", "issues": issues}, open(path, "w"))
PYEOF
}
done_(){ HARNESS_SNAPSHOT_FILE="$SNAP" HARNESS_MODE=issue-only HARNESS_AUTONOMOUS=false \
  "${ONE[@]}" done "$1" --events "$EV" --bodies "$BODIES" "${@:2}"; }
edits(){ wc -l < "$GH/log"; }
board 7:OPEN:ready-for-agent,agent-working 8:OPEN:ready-for-agent 9:OPEN:ready-for-agent:10 \
      10:OPEN:ready-for-agent,agent-working 11:OPEN:ready-for-agent,agent-paused 12:OPEN:ready-for-agent,agent-blocked
before="$(edits)"
out="$(done_ 7 2>&1)"; rc=$?
assert_eq "$rc" "4" "done while the goal check is PENDING"
assert_ok "says it is not done" grep -q 'not DONE' <<<"$out"
assert_no "and offers nothing" grep -qE 'RECOMMEND|next claimable' <<<"$out"
board 7:CLOSED:ready-for-agent 8:OPEN:ready-for-agent 9:OPEN:ready-for-agent:10 \
      10:OPEN:ready-for-agent,agent-working 11:OPEN:ready-for-agent,agent-paused 12:OPEN:ready-for-agent,agent-blocked
stub_usage 10
out="$(done_ 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "done once #7 closed: the next issue fits — APPROVE"
assert_ok "reports #7 DONE via the goal check" grep -q 'acme/widget#7 DONE (goal check)' <<<"$out"
assert_ok "offers the agent-paused #11 first, as dispatch resumes it" grep -q 'next claimable: acme/widget#11' <<<"$out"
assert_ok "with a fresh gate for #11" grep -q '^gate #11:' <<<"$out"
assert_ok "and its recommendation" grep -q '^RECOMMEND: APPROVE' <<<"$out"
assert_ok "handing the decision back" grep -q 'approve / pick another issue / stop' <<<"$out"
assert_eq "$(edits)" "$before" "nothing is claimed or labelled without the human approving"
done_ 7 --json > "$RUN_DIR/d.json" 2>/dev/null; rc=$?
assert_eq "$rc:$(python3 -c 'import json,sys; g=json.load(open(sys.argv[1])); print(g["issue"], g["verdict"])' "$RUN_DIR/d.json")" \
  "0:11 APPROVE" "--json: stdout is the next issue's gate JSON alone"
stub_usage 97
done_ 7 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "the next issue's gate DENIES: done exits 1"
# #446: a lane that checkpointed keeps its worktree (agent-paused, not agent-working) — busy_issues_for
# owns #11, so done offers the next claimable issue dispatch would take, never the one start would fail on.
stub_usage 10; mkdir -p "$WORKTREES_DIR/main-i11"
out="$(done_ 7 2>&1)"; rc=$?
assert_eq "$rc" "0" "done with #11's worktree still present: the next issue fits — APPROVE"
assert_ok "offers #8, skipping #11 that a live lane owns (busy_issues_for)" grep -q 'next claimable: acme/widget#8' <<<"$out"
assert_no "never the owned #11" grep -q 'acme/widget#11' <<<"$out"
mkdir -p "$WORKTREES_DIR/main-i8"
out="$(done_ 7 2>&1)"; rc=$?
assert_eq "$rc" "5" "every claimable issue owned by a live lane: none offered"
assert_ok "says so" grep -q 'no claimable issue' <<<"$out"
rmdir "$WORKTREES_DIR/main-i11" "$WORKTREES_DIR/main-i8"; stub_usage 97
board 7:CLOSED:ready-for-agent 9:OPEN:ready-for-agent:10 10:OPEN:ready-for-agent,agent-working \
      12:OPEN:ready-for-agent,agent-blocked
out="$(done_ 7 2>&1)"; rc=$?
assert_eq "$rc" "5" "none claimable — blocked, working and agent-blocked are never offered"
assert_ok "says so" grep -q 'no claimable issue' <<<"$out"
assert_no "and gates nothing" grep -q 'RECOMMEND' <<<"$out"
rm -f "$RUN_DIR/PAUSED"; board 7:CLOSED:ready-for-agent 8:OPEN:ready-for-agent
done_ 7 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "3" "the next issue's gate still refuses on a RUNNING, un-held fleet"
finish

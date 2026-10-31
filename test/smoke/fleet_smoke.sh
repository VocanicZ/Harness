#!/usr/bin/env bash
# fleet_smoke.sh <cli> — one REAL fleet session completing a trivial issue end to end (#306, PRD #189 AC5),
# on the tmux session backend or (SMOKE_BACKEND=headless, #354) the headless one.
#
# Not part of test/run.sh (it lives outside test/'s test_* glob): it talks to GitHub, spends the CLI's
# quota and takes minutes. Run it by hand on the fleet host, once per CLI the README lists:
#
#   bash test/smoke/fleet_smoke.sh codex
#   SMOKE_BACKEND=headless bash test/smoke/fleet_smoke.sh claude    # headless lanes + checkpoint/resume
#
# What it does, every step through the fleet's own path — nothing here drives the agent:
#   1. sandbox repo  SMOKE_REPO (default <gh login>/harness-smoke-<cli>), created private if absent and
#                    seeded once with a README, a passing test/run.sh and a .gitignore for .harness/;
#   2. issue         one PRD issue plus one trivial `ready-for-agent` issue whose `## Parent` names it;
#   3. fleet         a fresh clone + `harness init` (HARNESS_CLI=<cli>, pool 1, cap 1, issue-only) +
#                    `harness setup` + `harness start`, from THIS checkout's engine;
#   4. wait          until the issue closes (claim → session → PR → merge/close) or SMOKE_TIMEOUT,
#                    then until the fleet has ended that session itself (SMOKE_REAP_WAIT). With
#                    SMOKE_CHECKPOINT=1 (the headless default) the run pauses mid-session first:
#                    SMOKE_CHECKPOINT_AFTER seconds after the lane is up (the task's first step a
#                    `sleep`, so it is still mid-task), `harness pause --force`
#                    checkpoints it to GitHub (agent-paused, lane ended), then `harness resume` puts the
#                    issue back in the pool, and the wait goes on until the resumed lane closes it;
#   5. teardown      `harness stop --clean`, anything the run left open closed, its branches deleted,
#                    the clone removed. The repo itself is kept for the next run (deleting it needs
#                    the delete_repo scope); SMOKE_DELETE_REPO=1 deletes it instead.
# Every step is logged to SMOKE_LOG (default $TMPDIR/harness-smoke/<cli>[-<backend>]-<utc stamp>.log,
# the backend named unless tmux), headed with the CLI's version and the date. Recorded runs are
# committed under test/smoke/logs/.
#
# Exit: 0 the issue closed through a merged PR (after its checkpoint and resume, when asked for one) ·
#       1 it did not (timeout, closed unmerged, or a checkpoint that never ran or never confirmed) · 2 usage.
#
# Env:
#   SMOKE_BACKEND       the fleet's session backend: tmux (default) | headless (HARNESS_SESSION_BACKEND)
#   SMOKE_CHECKPOINT    1 = checkpoint + resume mid-session (default 1 on headless, 0 on tmux)
#   SMOKE_CHECKPOINT_AFTER  seconds the lane runs before the checkpoint (default 30)
#   SMOKE_TASK_WAIT     with a checkpoint, the task's first step is `sleep <this>` (default 240): a
#                       trivial task is done in about a minute, so the checkpoint needs a window mid-task
#   SMOKE_TURN_MAX      the sandbox's HARNESS_TURN_MAX when checkpointing (default 120): a lane's goal
#                       loop can keep one turn open until the issue is done, so the checkpoint, queued
#                       behind that turn, is let in by the fleet's own stuck-turn interrupt (#207)
#   SMOKE_REPO          owner/repo of the sandbox (one per CLI, so runs can go in parallel)
#   SMOKE_TIMEOUT       seconds to wait for the issue to close (default 3600)
#   SMOKE_POLL          seconds between progress checks (default 30)
#   SMOKE_REAP_WAIT     seconds, once the issue closes, for the fleet to end its own session (default
#                       600) — so the log carries the session's end, not a teardown kill mid-loop
#   SMOKE_EXTRA_CONFIG  file whose lines are appended to the sandbox's .harness/config — a host's
#                       HARNESS_<CLI>_BIN / _FLAGS pin (e.g. the account wrapper claude lanes use)
#   SMOKE_DELETE_REPO   1 = delete the sandbox repo at teardown (needs `gh auth refresh -s delete_repo`)
#   SMOKE_HARNESS       the harness entrypoint (default: this checkout's bin/harness)
#   SMOKE_REMOTE        the URL the sandbox is cloned from (default https://github.com/<SMOKE_REPO>.git)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage(){ echo "usage: $(basename "$0") <cli>    (one of: $(ls "$HERE/../../scripts/cli" | sed -n 's/\.sh$//p' | grep -vE '^dispatch$|-loop$' | xargs))" >&2; exit 2; }
CLI="${1:-}"; [[ -n "$CLI" && "$CLI" != -* ]] || usage
[[ -f "$HERE/../../scripts/cli/$CLI.sh" ]] || { echo "fleet_smoke: no adapter for '$CLI'" >&2; usage; }

# A live fleet exports its whole config to every session it launches, and the config is written
# `: "${VAR:=…}"` — so run from inside a lane, the sandbox would silently take THAT fleet's repo, prefix
# and CLI. Drop every inherited HARNESS_* (the host path pins too: lib.sh re-derives them from $HOME),
# the state dir, and the parent agent's own session markers.
for v in $(compgen -v HARNESS_); do unset "$v"; done
unset STATE_DIR ENGINE_DIR RUN_DIR HARNESS_DIR CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID \
      CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN

HARNESS="${SMOKE_HARNESS:-$HERE/../../bin/harness}"
BACKEND="${SMOKE_BACKEND:-tmux}"
[[ -f "$HERE/../../scripts/session/$BACKEND.sh" && "$BACKEND" != dispatch ]] || { echo "fleet_smoke: no session backend '$BACKEND'" >&2; usage; }
CHECKPOINT="${SMOKE_CHECKPOINT:-$([[ "$BACKEND" == headless ]] && echo 1 || echo 0)}"
CP_AFTER="${SMOKE_CHECKPOINT_AFTER:-30}"
TASK_WAIT="${SMOKE_TASK_WAIT:-240}"
TIMEOUT="${SMOKE_TIMEOUT:-3600}"; POLL="${SMOKE_POLL:-30}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOGIN="$(gh api user --jq .login 2>/dev/null)" || { echo "fleet_smoke: gh is not authenticated" >&2; exit 2; }
REPO="${SMOKE_REPO:-$LOGIN/harness-smoke-$CLI}"
OWNER="${REPO%%/*}"
LOG_BASE="$CLI"; [[ "$BACKEND" == tmux ]] || LOG_BASE="$CLI-$BACKEND"   # tmux runs keep their old name
LOG="${SMOKE_LOG:-${TMPDIR:-/tmp}/harness-smoke/$LOG_BASE-$STAMP.log}"
mkdir -p "$(dirname "$LOG")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/harness-smoke-$CLI.XXXXXX")"
PROJ="$WORK/$(basename "$REPO")"
# A prefix of its own per CLI, no dash: never a dash-prefix of (or equal to) a real fleet's.
PREFIX="smoke$(tr -cd 'a-z0-9' <<<"$CLI")"
ISSUE="" PRD="" STARTED=0

exec > >(tee -a "$LOG") 2>&1
say(){ printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
H(){ "$HARNESS" --state-dir "$PROJ/.harness" "$@"; }
# lanes — this run's live agent sessions; screen <session> — its last screen. On tmux the panes; on
# headless the host's lane runners, read through the engine's own session seam (scripts/session/).
SEAM="$HERE/../../scripts/session/dispatch.sh"
lanes(){ if [[ "$BACKEND" == tmux ]]; then tmux ls -F '#S' 2>/dev/null
  else HARNESS_SESSION_BACKEND="$BACKEND" bash -c 'source "$1" && sess_list' _ "$SEAM" 2>/dev/null; fi | grep "^$PREFIX-"; }
screen(){ if [[ "$BACKEND" == tmux ]]; then tmux capture-pane -p -t "$1" -S -60 2>/dev/null
  else HARNESS_SESSION_BACKEND="$BACKEND" bash -c 'source "$1" && sess_capture "$2"' _ "$SEAM" "$1" 2>/dev/null | tail -60; fi; }

cli_version(){ ( [[ -n "${SMOKE_EXTRA_CONFIG:-}" ]] && source "$SMOKE_EXTRA_CONFIG"
  source "$HERE/../../scripts/cli/dispatch.sh"; cli_load "$CLI" && timeout 30 $(cli_bin) --version 2>&1 | head -1 ); }

teardown(){
  local rc=$? n b
  trap - EXIT INT TERM
  say "== teardown"
  if (( STARTED )); then
    for s in $(lanes || true); do
      say "-- final pane of $s"; screen "$s" | sed 's/^/   | /'
    done
    H stop --clean 2>&1 | sed 's/^/   /'
  fi
  # Leave the sandbox as the run found it: nothing open, no branch but the default one.
  for n in $(gh pr list -R "$REPO" --state open --json number --jq '.[].number' 2>/dev/null); do
    gh pr close "$n" -R "$REPO" --delete-branch -c "fleet_smoke teardown ($STAMP)" >/dev/null 2>&1 && say "closed leftover PR #$n"
  done
  for n in $ISSUE $PRD; do
    [[ "$(gh issue view "$n" -R "$REPO" --json state --jq .state 2>/dev/null)" == OPEN ]] || continue
    gh issue close "$n" -R "$REPO" -c "fleet_smoke teardown ($STAMP)" >/dev/null 2>&1 && say "closed leftover issue #$n"
  done
  local def; def="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)"
  for b in $(gh api "repos/$REPO/branches" --paginate --jq '.[].name' 2>/dev/null); do
    [[ -n "$def" && "$b" != "$def" ]] || continue
    gh api -X DELETE "repos/$REPO/git/refs/heads/$b" >/dev/null 2>&1 && say "deleted branch $b"
  done
  if [[ "${SMOKE_DELETE_REPO:-0}" == 1 ]]; then
    gh repo delete "$REPO" --yes >/dev/null 2>&1 && say "deleted repo $REPO" || say "could not delete $REPO (delete_repo scope?)"
  fi
  rm -rf "$WORK"
  say "== result: $( ((rc == 0)) && echo PASS || echo "FAIL (rc $rc)") | log: $LOG"
  exit "$rc"
}
trap teardown EXIT
trap 'exit 130' INT TERM

say "== fleet smoke | cli=$CLI | $(cli_version) | $(date -u +%Y-%m-%dT%H:%M:%SZ)"
[[ "$BACKEND" == tmux ]] || say "== session backend $BACKEND | checkpoint+resume $( ((CHECKPOINT)) && echo "on, ${CP_AFTER}s into the lane" || echo off)"
say "== engine $(H --version 2>/dev/null | head -1) | repo $REPO | prefix $PREFIX"

# 1. sandbox repo: create once, seed once. The task file names its own path, so a reused repo never
#    already holds this run's answer.
if ! gh repo view "$REPO" >/dev/null 2>&1; then
  say "creating private sandbox $REPO"
  gh repo create "$REPO" --private --add-readme -d "Harness fleet smoke sandbox ($CLI) — test/smoke/fleet_smoke.sh" >/dev/null || exit 1
fi
git clone -q "${SMOKE_REMOTE:-https://github.com/$REPO.git}" "$PROJ" || exit 1
if [[ ! -f "$PROJ/test/run.sh" ]]; then
  say "seeding $REPO"
  mkdir -p "$PROJ/test"
  printf '.harness/\n' > "$PROJ/.gitignore"
  printf '#!/usr/bin/env bash\n# The whole suite: every file named under smoke/ is non-empty.\nset -eu\ncd "$(dirname "$0")/.."\nfor f in smoke/*; do [ -e "$f" ] || continue; [ -s "$f" ] || { echo "FAIL: $f is empty"; exit 1; }; done\necho ok\n' > "$PROJ/test/run.sh"
  chmod +x "$PROJ/test/run.sh"
  printf '# harness-smoke-%s\n\nSandbox for Harness fleet smoke runs (`test/smoke/fleet_smoke.sh` in VocanicZ/Harness).\n\nTest command: `bash test/run.sh` — it is the full suite and the gate.\n' "$CLI" > "$PROJ/README.md"
  git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "chore: seed smoke sandbox" && git -C "$PROJ" push -q origin HEAD || exit 1
fi

# 2. the fleet's config, written by its own wizard.
say "== harness init"
( cd "$PROJ" && HARNESS_INIT_NONINTERACTIVE=1 HARNESS_SESSION_BACKEND="$BACKEND" HARNESS_CLI="$CLI" HARNESS_MODE=issue-only HARNESS_TOPOLOGY=single \
    HARNESS_OWNER="$OWNER" HARNESS_REPO="$REPO" HARNESS_SESS_PREFIX="$PREFIX" HARNESS_POOL=1 HARNESS_CAP=1 \
    HARNESS_POLL=30 HARNESS_PRIORITY_POLL=60 HARNESS_USE_POLLER=0 HARNESS_AUTONOMOUS=true \
    "$HARNESS" init </dev/null ) 2>&1 | sed 's/^/   /'
[[ -f "$PROJ/.harness/config" ]] || { say "harness init wrote no config"; exit 1; }
# A sandbox with a one-line suite: verify locally, never on swarm.
printf ': "${HARNESS_SWARM:=off}"\n' >> "$PROJ/.harness/config"
# A checkpoint must reach a lane mid-task: let the stuck-turn interrupt deliver it, give it time to land.
(( CHECKPOINT )) && printf ': "${HARNESS_TURN_MAX:=%s}"\n: "${HARNESS_PAUSE_GRACE:=900}"\n' "${SMOKE_TURN_MAX:-120}" >> "$PROJ/.harness/config"
[[ -n "${SMOKE_EXTRA_CONFIG:-}" ]] && cat "$SMOKE_EXTRA_CONFIG" >> "$PROJ/.harness/config"
grep -v '^#' "$PROJ/.harness/config" | sed 's/^/   /'
say "== harness setup"
H setup 2>&1 | sed 's/^/   /'; (( PIPESTATUS[0] == 0 )) || { say "harness setup failed"; exit 1; }

# 3. the work.
WAIT_STEP=""; (( CHECKPOINT )) && WAIT_STEP="First run \`sleep $TASK_WAIT\` as a command of its own: this smoke run needs the lane to be mid-task for a while. Then:"$'\n'
PRD="$(gh issue create -R "$REPO" -l prd -t "Smoke PRD ($CLI, $STAMP)" \
        -b "Tracking issue for one fleet smoke run. Closed by teardown." | grep -oE '[0-9]+$')" || exit 1
ISSUE="$(gh issue create -R "$REPO" -l ready-for-agent -t "Add smoke/$STAMP.txt" -b "$(cat <<EOF
Trivial smoke task for the Harness fleet ($CLI).

## What to do
${WAIT_STEP}Create the file \`smoke/$STAMP.txt\` containing exactly one line: \`hello from $CLI\`.

## Acceptance
- [ ] \`smoke/$STAMP.txt\` exists with that one line.
- [ ] \`bash test/run.sh\` exits 0.

## Parent
#$PRD
EOF
)" | grep -oE '[0-9]+$')" || exit 1
say "filed PRD #$PRD and issue #$ISSUE"

say "== harness start"
STARTED=1
H start 2>&1 | sed 's/^/   /'

# 4. wait for the fleet to close it. Log each change of state, not every poll.
# With CHECKPOINT, the first time the lane has been up CP_AFTER seconds the fleet is paused with
# --force (the lane checkpoints to GitHub and is ended), then resumed; the wait then goes on.
deadline=$(( $(date +%s) + TIMEOUT )); last="" state="" lane_up="" cp_done=0
while (( $(date +%s) < deadline )); do
  row="$(gh issue view "$ISSUE" -R "$REPO" --json state,labels --jq '[.state, ([.labels[].name]|sort|join(","))]|@tsv' 2>/dev/null)"
  state="${row%%$'\t'*}"
  sess="$(lanes | paste -sd, -)"
  prs="$(gh pr list -R "$REPO" --state all --json number,state --jq 'map("#\(.number) \(.state)")|join(",")' 2>/dev/null)"
  now="issue=${row//$'\t'/ labels=} sessions=${sess:-none} prs=${prs:-none}"
  [[ "$now" != "$last" ]] && say "$now"; last="$now"
  [[ "$state" == CLOSED ]] && break
  if (( CHECKPOINT && ! cp_done )) && [[ -n "$sess" ]]; then
    : "${lane_up:=$(date +%s)}"
    if (( $(date +%s) - lane_up >= CP_AFTER )); then
      cp_done=1
      say "== checkpoint: harness pause --force (lane $sess up $(( $(date +%s) - lane_up ))s)"
      H pause --force 2>&1 | sed 's/^/   /'
      labels="$(gh issue view "$ISSUE" -R "$REPO" --json labels --jq '[.labels[].name]|sort|join(",")' 2>/dev/null)"
      sess="$(lanes | paste -sd, -)"
      say "after checkpoint: labels=$labels sessions=${sess:-none}"
      [[ ",$labels," == *,agent-paused,* ]] || { say "checkpoint not confirmed: issue #$ISSUE is not agent-paused"; exit 1; }
      [[ -n "$(gh issue view "$ISSUE" -R "$REPO" --json comments --jq '.comments[].body|select(startswith("<!-- harness-handoff issue='"$ISSUE"' "))' 2>/dev/null)" ]] \
        && say "handoff comment posted on #$ISSUE" || say "no handoff comment on #$ISSUE"
      say "== resume: harness resume"
      H resume 2>&1 | sed 's/^/   /'
      last=""
    fi
  fi
  sleep "$POLL"
done
[[ "$state" == CLOSED ]] || { say "timed out after ${TIMEOUT}s — issue #$ISSUE still ${state:-unknown}"; H status 2>&1 | sed 's/^/   /'; exit 1; }
(( CHECKPOINT && ! cp_done )) && { say "issue #$ISSUE closed before its lane had run ${CP_AFTER}s — no checkpoint was exercised"; exit 1; }

# The lane ends its loop after the merge (promise → done) and the fleet reaps the session, writing its
# session_end. Teardown would kill it mid-loop; give the fleet its own exit first.
reap_deadline=$(( $(date +%s) + ${SMOKE_REAP_WAIT:-600} ))
while lanes | grep -q . && (( $(date +%s) < reap_deadline )); do sleep "$POLL"; done
sess="$(lanes | paste -sd, -)"
say "fleet sessions after close: ${sess:+$sess still live after ${SMOKE_REAP_WAIT:-600}s}${sess:-none (ended by the fleet)}"

# 5. how it closed: the merged PR, its file, the session's own record.
# The sandbox keeps earlier runs' merged PRs: take the one that names this issue (body, title or branch).
merged="$(N="$ISSUE" gh pr list -R "$REPO" --state merged --json number,title,url,mergedAt,body,headRefName --jq '.[]
  | select(((.body + " " + .title) | test("#" + env.N + "\\b")) or (.headRefName | test("\\D" + env.N + "$")))
  | "#\(.number) \(.title) \(.url) merged \(.mergedAt)"' 2>/dev/null)"
say "issue #$ISSUE CLOSED"
say "merged PR: ${merged:-none}"
git -C "$PROJ" pull -q origin HEAD 2>/dev/null
say "smoke/$STAMP.txt on the default branch: $(cat "$PROJ/smoke/$STAMP.txt" 2>/dev/null || echo '<missing>')"
H stats --issue "$ISSUE" -R "$REPO" 2>&1 | sed 's/^/   /'
# The fleet's own record of the resumed lane carrying on its checkpointed session (launch_agent).
(( CHECKPOINT )) && grep -rhs 'carries on agent session' "$PROJ/.harness" | sed 's/^/   /'
[[ -n "$merged" ]] || { say "closed without a merged PR"; exit 1; }
exit 0

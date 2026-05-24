#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/../drive.sh"; source "$HERE/helpers.sh"
make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; CAP=2; POLL=0
DISPATCHED="$RUN_DIR/dispatched"; : > "$DISPATCHED"
# Isolate WORKTREES_DIR to an empty temp dir: drive_unit now runs finalize_unit on completion,
# whose glob/`rm -rf` would otherwise hit the LIVE $HARNESS_DIR/worktrees. With it empty, the
# sweep matches nothing — hermetic by construction, not by accident of the git stub's exit code.
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"

# stubs: no real tmux/gh. spawn_impl just records; sessions are never "live".
# team_sessions/tmux/git are also stubbed so finalize_unit's session-kill + prune never reach the
# real fleet (the live config's prefix is in this process); WORKTREES_DIR above is the real guard.
spawn_impl(){ echo "IMPL $1" >> "$DISPATCHED"; }
spawn_orch(){ echo "ORCH $1" >> "$DISPATCHED"; }
reap_done_sessions(){ :; }
reap_team(){ :; }
count_team_sessions(){ echo 0; }
team_sessions(){ :; }
tmux(){ :; }
git(){ :; }
# dispatch returns two IMPL the first tick, then nothing; unit completes on tick 2.
TICK="$RUN_DIR/tick"; echo 0 > "$TICK"
dispatch_actions(){ local n; n="$(cat "$TICK")"; n=$((n+1)); echo "$n" > "$TICK"
  if [[ "$n" == 1 ]]; then printf 'IMPL\t5\tISSUE 5 DONE\nIMPL\t6\tISSUE 6 DONE\n'; fi; }
COMPLETE_AFTER=2
unit_complete(){ [[ "$(cat "$TICK")" -ge "$COMPLETE_AFTER" ]]; }

drive_unit main
assert_eq "$(grep -c '^IMPL' "$DISPATCHED")" "2" "drove two IMPL actions on first tick"
assert_ok "loop exited when unit_complete flipped" true

# --- finalize_unit: the on-completion sweep that fixes the leftover session/worktree ---
# Run in fully isolated temp dirs with recording stubs, so nothing touches the real fleet.
make_env
HARNESS_TOPOLOGY=single
UNIT=main; CHECKOUT="$RUN_DIR/co"; mkdir -p "$CHECKOUT"
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR/main-i7"   # a leftover impl worktree
echo REVIEW > "$RUN_DIR/$(sess_orch main).goal"                 # a leftover session's goal file
team_sessions(){ printf '%s\n' "$(sess_orch main)"; }           # one session still up for the unit
KILLED="$RUN_DIR/killed"; : > "$KILLED"
tmux(){ [[ "$1" == kill-session ]] && echo "$3" >> "$KILLED"; return 0; }
BR="$RUN_DIR/branches"; : > "$BR"
git(){ [[ "$*" == *"branch -D"* ]] && echo "$*" >> "$BR"; return 1; }  # nonzero ⇒ worktree-remove falls back to rm -rf

finalize_unit
assert_eq "$(cat "$KILLED")" "$(sess_orch main)" "finalize killed the leftover team session"
assert_no "finalize removed the session goal file"   test -f "$RUN_DIR/$(sess_orch main).goal"
assert_no "finalize removed the impl worktree"       test -d "$WORKTREES_DIR/main-i7"
assert_ok "finalize deleted the local feature branch" grep -q "branch -D issue/7" "$BR"

# --- archive_plan: on completion, archive PLAN.md + write a spec-keyed marker (idempotent) ---
# CHECKOUT is a plain dir (no git repo) so `git mv`/commit/push fall back / no-op; archival itself
# must still happen via the plain-mv fallback. HARNESS_SPEC points at a real temp spec to hash.
make_env
HARNESS_TOPOLOGY=single; UNIT=main; CHECKOUT="$RUN_DIR/repo"; mkdir -p "$CHECKOUT"
SPECFILE="$RUN_DIR/spec.md"; printf 'spec v1\n' > "$SPECFILE"; HARNESS_SPEC="$SPECFILE"
printf '# the plan\n' > "$CHECKOUT/PLAN.md"
git(){ return 1; }                 # not a git repo: git mv fails → plain-mv fallback; commit/push no-op

archive_plan
assert_no "archive_plan removed PLAN.md from repo root" test -f "$CHECKOUT/PLAN.md"
ARCHIVED="$(ls "$CHECKOUT"/docs/harness/archive/PLAN-*.md 2>/dev/null | head -n1)"
assert_ok "PLAN.md archived under docs/harness/archive/PLAN-<ts>.md" test -f "$ARCHIVED"
assert_ok "archived copy keeps the plan body" grep -q 'the plan' "$ARCHIVED"
assert_ok "wrote the plan-complete marker" test -f "$CHECKOUT/docs/harness/plan-complete.json"
WANT_HASH="$(HARNESS_SPEC="$SPECFILE" python3 "$HARNESS_DIR/issuelib.py" spec-hash)"
assert_ok "marker records the spec content hash" grep -q "$WANT_HASH" "$CHECKOUT/docs/harness/plan-complete.json"
assert_ok "marker records the HARNESS_SPEC path"  grep -qF "$SPECFILE" "$CHECKOUT/docs/harness/plan-complete.json"

# idempotent: a second run with no live PLAN.md is a safe no-op (no error, no duplicate archive)
NARCH_BEFORE="$(ls "$CHECKOUT"/docs/harness/archive/ | wc -l)"
assert_ok "archive_plan re-run is a no-op (exit 0)" archive_plan
assert_eq "$(ls "$CHECKOUT"/docs/harness/archive/ | wc -l)" "$NARCH_BEFORE" "no duplicate archive on re-run"

# --- multi-topology: completed unit's row(s) cleared from targets.tsv ---
make_env
HARNESS_TOPOLOGY=multi; UNIT=b; CHECKOUT="$RUN_DIR/repo-b"; mkdir -p "$CHECKOUT"
HARNESS_SPEC="$RUN_DIR/spec.md"; printf 'spec\n' > "$HARNESS_SPEC"
printf '# id\trepo\tdeps\tdesc\na\tacme/a\t-\troot\nb\tacme/b\ta\tmid\nc\tacme/c\tb\tleaf\n' > "$TARGETS_TSV"
git(){ return 1; }
archive_plan
assert_eq "$(_tgt_row b)" "" "targets.tsv row for completed unit b removed"
assert_ok "targets.tsv keeps other units (a)" test -n "$(_tgt_row a)"
assert_ok "targets.tsv keeps other units (c)" test -n "$(_tgt_row c)"
finish

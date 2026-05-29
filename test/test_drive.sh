#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
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

# --- CLOSE_PRD: the engine closes a reviewed-but-open PRD directly (no Ralph session) ---
# The dispatch loop must route a CLOSE_PRD action to close_prd() (a single `gh issue close`), NOT to
# spawn_orch (which would launch a whole review session). This is the deterministic PRD-close fix.
make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; SLUG="acme/widget"; CAP=2; POLL=0
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
ROUTED="$RUN_DIR/routed"; : > "$ROUTED"
spawn_impl(){ echo "IMPL $1" >> "$ROUTED"; }
spawn_orch(){ echo "ORCH $1 $2" >> "$ROUTED"; }
close_prd(){ echo "CLOSE_PRD $1" >> "$ROUTED"; }
reap_done_sessions(){ :; }; reap_team(){ :; }; count_team_sessions(){ echo 0; }
team_sessions(){ :; }; tmux(){ :; }; git(){ :; }
TICK="$RUN_DIR/tick2"; echo 0 > "$TICK"
dispatch_actions(){ local n; n="$(cat "$TICK")"; n=$((n+1)); echo "$n" > "$TICK"
  if [[ "$n" == 1 ]]; then printf 'CLOSE_PRD\t7\tPRD CLOSED\n'; fi; }
unit_complete(){ [[ "$(cat "$TICK")" -ge 2 ]]; }
drive_unit main
assert_ok "CLOSE_PRD routed to close_prd() (engine closes the PRD)" grep -q '^CLOSE_PRD 7' "$ROUTED"
assert_no "CLOSE_PRD did NOT spawn an orch/review session" grep -q '^ORCH' "$ROUTED"

# close_prd() runs a single idempotent `gh issue close` against the unit's repo
source "$HERE/../scripts/drive.sh"   # restore the real close_prd (the routing section stubbed it)
make_env
HARNESS_TOPOLOGY=single; SLUG="acme/widget"
GHC="$RUN_DIR/ghclose"; : > "$GHC"
gh(){ echo "gh $*" >> "$GHC"; return 0; }
close_prd 7
assert_ok "close_prd issues gh issue close for the PRD" grep -q 'gh issue close 7 -R acme/widget' "$GHC"

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
WANT_HASH="$(HARNESS_SPEC="$SPECFILE" python3 "$HARNESS_DIR/scripts/issuelib.py" spec-hash)"
assert_ok "marker records the spec content hash" grep -q "$WANT_HASH" "$CHECKOUT/docs/harness/plan-complete.json"
assert_ok "marker records the HARNESS_SPEC path"  grep -qF "$SPECFILE" "$CHECKOUT/docs/harness/plan-complete.json"

# idempotent: a second run with no live PLAN.md is a safe no-op (no error, no duplicate archive)
NARCH_BEFORE="$(ls "$CHECKOUT"/docs/harness/archive/ | wc -l)"
assert_ok "archive_plan re-run is a no-op (exit 0)" archive_plan
assert_eq "$(ls "$CHECKOUT"/docs/harness/archive/ | wc -l)" "$NARCH_BEFORE" "no duplicate archive on re-run"

# --- multi-topology: completing a unit must NOT drop its targets.tsv row ---
# Regression for the F1 row-drop bug: targets.tsv is the dependency registry. Here c depends on b;
# if finalizing b deleted b's row, c's dep would become unresolvable and the DAG would freeze.
# Completion is recomputed live each poll, so a finished unit is skipped without removing its row.
make_env
HARNESS_TOPOLOGY=multi; UNIT=b; CHECKOUT="$RUN_DIR/repo-b"; mkdir -p "$CHECKOUT"
HARNESS_SPEC="$RUN_DIR/spec.md"; printf 'spec\n' > "$HARNESS_SPEC"
printf '# id\trepo\tdeps\tdesc\na\tacme/a\t-\troot\nb\tacme/b\ta\tmid\nc\tacme/c\tb\tleaf\n' > "$TARGETS_TSV"
git(){ return 1; }
archive_plan
assert_ok "completed unit b's row PERSISTS (dependents resolve it)" test -n "$(_tgt_row b)"
assert_eq "$(unit_repo b)" "acme/b" "b's row still resolves its repo for dependents"
assert_ok "targets.tsv keeps other units (a)" test -n "$(_tgt_row a)"
assert_ok "targets.tsv keeps other units (c)" test -n "$(_tgt_row c)"

# ── #34: the lane must reap bug-fix worktrees — a crashed fix must not wedge spawn_bug ──
# REAL git here (not stubbed): the wedge is a genuine `git worktree add` rc-128 collision
# ('issue/N' already used by worktree), so only real git reproduces it. Everything else
# (gh/render/launch/tmux) is stubbed → hermetic, no network, no tmux.
make_env
unset -f git   # earlier sections stub git() as a function; restore the real binary for the worktree ops
HARNESS_TOPOLOGY=single; HARNESS_REPO=acme/widget
UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget; HARNESS_SPEC=""
CHECKOUT="$RUN_DIR/co"; git init -q "$CHECKOUT"
git -C "$CHECKOUT" config user.email t@t; git -C "$CHECKOUT" config user.name t
git -C "$CHECKOUT" commit -q --allow-empty -m init
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
GH="$RUN_DIR/ghcalls"; : > "$GH"
gh(){ echo "gh $*" >> "$GH"; return 0; }
render(){ :; }; launch_claude(){ :; }; tmux(){ :; }
ensure_checkout(){ :; }; ensure_safe(){ :; }; default_branch(){ echo main; }

WD="$(bug_worktree "$SLUG" 5)"
spawn_bug 5 fix >/dev/null 2>&1; assert_eq "$?" "0" "spawn_bug fix succeeds on a clean checkout"
assert_ok "fix worktree created"                  test -d "$WD"
assert_eq "$(git -C "$WD" branch --show-current)" "issue/5" "fix worktree is on branch issue/5"
# crashed fix: the worktree is LEFT behind (drive_bug never reaped it). The re-drive must NOT
# fail on the rc-128 collision — spawn_bug defensively removes the leftover before re-adding.
spawn_bug 5 fix >/dev/null 2>&1; assert_eq "$?" "0" "spawn_bug fix succeeds AGAIN over a leftover worktree (no rc-128 wedge)"
assert_ok "fix worktree still present after crash-replay spawn" test -d "$WD"
# reapable: remove_worktree tears down the worktree + local branch cleanly (no accumulation)
remove_worktree "$CHECKOUT" "$WD" "issue/5" >/dev/null 2>&1
assert_no "remove_worktree removed the fix worktree" test -d "$WD"
assert_no "remove_worktree deleted the local issue/5 branch" \
  bash -c "git -C '$CHECKOUT' rev-parse --verify -q issue/5 >/dev/null 2>&1"
assert_eq "$(git -C "$CHECKOUT" worktree list | grep -c "bug-acme_widget-i5")" "0" \
  "fix worktree no longer registered after reap"

# ── #34: a FAILED spawn_bug fix must NOT leave the issue stamped agent-working ──
# Else the open bug keeps agent-working with no live session → bug_lane_issues excludes it and the
# lane never re-claims it. Force `worktree add` to fail; the stamp must come AFTER worktree setup.
make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO=acme/widget
UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget; HARNESS_SPEC=""
CHECKOUT="$RUN_DIR/co2"; mkdir -p "$CHECKOUT"
WORKTREES_DIR="$RUN_DIR/wt2"; mkdir -p "$WORKTREES_DIR"
GH2="$RUN_DIR/ghcalls2"; : > "$GH2"
gh(){ echo "gh $*" >> "$GH2"; return 0; }
render(){ :; }; launch_claude(){ :; }; tmux(){ :; }
ensure_checkout(){ :; }; ensure_safe(){ :; }; default_branch(){ echo main; }
git(){ case "$*" in *"worktree add"*) return 1;; *) return 0;; esac; }
spawn_bug 5 fix; assert_eq "$?" "1" "spawn_bug fix returns nonzero when worktree add fails"
assert_eq "$(grep -c 'add-label' "$GH2" 2>/dev/null; true)" "0" \
  "spawn_bug does NOT stamp agent-working when worktree add fails (#34 no wedge)"
unset -f git

# ── #34: sweep_orphan_bug_worktrees removes a dead-session fix worktree, keeps a live one ──
# start.sh recover() calls this on crash/new-machine boot: the lane never reaped its own worktree
# (the host died), so a leftover blocks the next spawn unless recovery sweeps it.
make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO=acme/widget
SLUG=acme/widget
CHECKOUT="$RUN_DIR/cosweep"; git init -q "$CHECKOUT"
git -C "$CHECKOUT" config user.email t@t; git -C "$CHECKOUT" config user.name t
git -C "$CHECKOUT" commit -q --allow-empty -m init
WORKTREES_DIR="$RUN_DIR/wtsweep"; mkdir -p "$WORKTREES_DIR"
ensure_safe(){ :; }
DEAD="$(bug_worktree "$SLUG" 5)"; LIVE="$(bug_worktree "$SLUG" 6)"
git -C "$CHECKOUT" worktree add -q -B issue/5 "$DEAD"
git -C "$CHECKOUT" worktree add -q -B issue/6 "$LIVE"
session_live(){ [[ "$1" == "$(sess_bug "$SLUG" 6 fix)" ]]; }   # only #6's repo-qualified fix session is live (#44)
sweep_orphan_bug_worktrees >/dev/null 2>&1
assert_no "sweep removed the dead-session bug worktree (#5)" test -d "$DEAD"
assert_ok "sweep kept the live-session bug worktree (#6)"    test -d "$LIVE"
assert_no "sweep deleted the dead bug's local branch (issue/5)" \
  bash -c "git -C '$CHECKOUT' rev-parse --verify -q issue/5 >/dev/null 2>&1"
finish

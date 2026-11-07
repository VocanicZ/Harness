#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
make_env
HARNESS_REPO="acme/widget"; POOL=2; POLL=0
# --- close_prd: the engine closes a reviewed-but-open PRD directly (no Ralph session). The pool worker
# routes the CLOSE_PRD action here (chores_slotless; test_pool_lanes). ---
# close_prd() runs a single idempotent `gh issue close` against the unit's repo
make_env
SLUG="acme/widget"
GHC="$RUN_DIR/ghclose"; : > "$GHC"
gh(){ echo "gh $*" >> "$GHC"; return 0; }
close_prd 7
assert_ok "close_prd issues gh issue close for the PRD" grep -q 'gh issue close 7 -R acme/widget' "$GHC"

# --- label_ready (#287): the engine labels a stray child ready — no session, no slot ---
make_env
SLUG="acme/widget"; HARNESS_LABEL_READY=go
GHL="$RUN_DIR/ghlabel"; : > "$GHL"
gh(){ echo "gh $*" >> "$GHL"; return 0; }
label_ready 18
assert_ok "label_ready adds the ready label to the stray" grep -q 'gh issue edit 18 -R acme/widget --add-label go' "$GHL"

# --- file_child (#614): the engine files the one child of a small PRD / POOL=1 — one gh create, no session ---
make_env
SLUG="acme/widget"; HARNESS_LABEL_READY=go
GHF="$RUN_DIR/ghfile"; : > "$GHF"; GH_EXISTING=0
gh(){ echo "gh $*" >> "$GHF"
  case "$1 $2" in
    "issue list") echo "$GH_EXISTING";;
    "issue create") return "${GH_CREATE_RC:-0}";;
  esac; return 0; }
REAL_ISSUELIB="$ISSUELIB"; ISSUELIB="$RUN_DIR/fake-issuelib.py"
printf 'import sys\nprint("## Acceptance criteria\\n\\n- [ ] ship it\\n\\nPart of #%%s" %% sys.argv[3])\n' > "$ISSUELIB"
file_child 7
assert_ok "file_child creates the child titled for the PRD" grep -q 'gh issue create -R acme/widget --title \[AFK\] Implement PRD #7 --body' "$GHF"
assert_ok "file_child labels the child ready" grep -q -- '--label go' "$GHF"
assert_ok "file_child passes the PRD's criteria and Part of line in the body" grep -q 'ship it' "$GHF"
assert_eq "$(grep -c 'issue create' "$GHF")" "1" "one create"
# idempotent: a second poll (snapshot still lagging) files nothing more
file_child 7
assert_eq "$(grep -c 'issue create' "$GHF")" "1" "second call files nothing (marker)"
# a child already carrying the title (any state) stops it even without our marker
make_env; SLUG="acme/widget"; : > "$GHF"; GH_EXISTING=1
file_child 8
assert_no "file_child skips when the titled child already exists" grep -q 'issue create' "$GHF"
# a failed create leaves no marker, so the next poll retries
make_env; SLUG="acme/widget"; : > "$GHF"; GH_EXISTING=0; GH_CREATE_RC=1
file_child 9
GH_CREATE_RC=0; file_child 9
assert_eq "$(grep -c 'issue create' "$GHF")" "2" "a failed create is retried on the next call"
ISSUELIB="$REAL_ISSUELIB"; unset -f gh; GH_CREATE_RC=0

# --- archive_plan: on completion, archive PLAN.md + write a spec-keyed marker (idempotent) ---
# CHECKOUT is a plain dir (no git repo) so `git mv`/commit/push fall back / no-op; archival itself
# must still happen via the plain-mv fallback. HARNESS_SPEC points at a real temp spec to hash.
make_env
UNIT=main; CHECKOUT="$RUN_DIR/repo"; mkdir -p "$CHECKOUT"
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

# ── #34: the lane must reap bug-fix worktrees — a crashed fix must not wedge spawn_bug ──
# REAL git here (not stubbed): the wedge is a genuine `git worktree add` rc-128 collision
# ('issue/N' already used by worktree), so only real git reproduces it. Everything else
# (gh/render/launch/tmux) is stubbed → hermetic, no network, no tmux.
make_env
unset -f git   # earlier sections stub git() as a function; restore the real binary for the worktree ops
HARNESS_REPO=acme/widget
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

# ── worktrees the SESSION made die with its worktree ──
# Claude Code's agent isolation nests worktrees under <wd>/.claude/worktrees/ and agents check out
# base refs under their scratchpad (/tmp/claude-<uid>/<wd sanitized>/…). Each is a full checkout
# nobody else removes — 72 of them (12.9 GB) piled up on the fleet host. An unrelated worktree of
# the same checkout must survive.
spawn_bug 5 fix >/dev/null 2>&1
SAN="$(printf '%s' "$WD" | sed 's/[^A-Za-z0-9]/-/g')"
NESTED="$WD/.claude/worktrees/agent-x"; SCRATCH="$RUN_DIR/claude-1000/$SAN/sess/scratchpad/basewt"
OTHER="$RUN_DIR/other-wt"
git -C "$CHECKOUT" worktree add -q -b worktree-agent-x "$NESTED" 2>/dev/null
git -C "$CHECKOUT" worktree add -q --detach "$SCRATCH" 2>/dev/null
git -C "$CHECKOUT" worktree add -q --detach "$OTHER" 2>/dev/null
remove_worktree "$CHECKOUT" "$WD" "issue/5" >/dev/null 2>&1
assert_no "nested agent worktree removed"     test -d "$NESTED"
assert_no "scratchpad worktree removed"       test -d "$SCRATCH"
assert_no "nested worktree-agent-x branch deleted" \
  bash -c "git -C '$CHECKOUT' rev-parse --verify -q worktree-agent-x >/dev/null 2>&1"
assert_ok "unrelated worktree kept"           test -d "$OTHER"
assert_eq "$(git -C "$CHECKOUT" worktree list | wc -l)" "2" "only the checkout + unrelated worktree stay registered"

# ── #34: a FAILED spawn_bug fix must NOT leave the issue stamped agent-working ──
# Else the open bug keeps agent-working with no live session → bug_lane_issues excludes it and the
# lane never re-claims it. Force `worktree add` to fail; the stamp must come AFTER worktree setup.
make_env
HARNESS_REPO=acme/widget
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

# ── #416: prepare_impl must NOT stamp agent-working when `worktree add` fails ──
# A failure there can mean a live lane still owns the issue's worktree; the stamp used to go on
# FIRST and stay, so the label flapped every pool pass. Mirror spawn_bug (#34): stamp after the add.
make_env
HARNESS_REPO=acme/widget
UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget; HARNESS_SPEC=""
CHECKOUT="$RUN_DIR/co416"; mkdir -p "$CHECKOUT"
WORKTREES_DIR="$RUN_DIR/wt416"; mkdir -p "$WORKTREES_DIR"
GH416="$RUN_DIR/ghcalls416"; : > "$GH416"
gh(){ case "$*" in *add-label*) echo "gh $* wt=$([[ -d "$WORKTREES_DIR/main-i5" ]] && echo yes || echo no)" >> "$GH416";;
                   *) echo "gh $*" >> "$GH416";; esac; return 0; }
render(){ :; }; launch_claude(){ :; }; tmux(){ :; }; run_worktree_hook(){ :; }; resume_handoff(){ :; }
ensure_checkout(){ :; }; ensure_safe(){ :; }; default_branch(){ echo main; }
git(){ case "$*" in *"worktree add"*) return 128;; *) return 0;; esac; }
prepare_impl 5 "ISSUE 5 DONE" 2>/dev/null; assert_eq "$?" "1" "prepare_impl returns nonzero when worktree add fails"
assert_eq "$(grep -c 'add-label' "$GH416" 2>/dev/null; true)" "0" \
  "prepare_impl does NOT stamp agent-working when worktree add fails (#416)"
git(){ case "$*" in *"worktree add"*) mkdir -p "$WORKTREES_DIR/main-i5";; esac; return 0; }
: > "$GH416"
prepare_impl 5 "ISSUE 5 DONE" 2>/dev/null; assert_eq "$?" "0" "prepare_impl succeeds when worktree add does"
assert_eq "$(grep -c 'add-label agent-working' "$GH416")" "1" "agent-working stamped exactly once on success"
assert_ok "... and only after the worktree exists" grep -q 'add-label agent-working wt=yes' "$GH416"
unset -f git gh

# ── #34: sweep_orphan_bug_worktrees removes a dead-session fix worktree, keeps a live one ──
# start.sh recover() calls this on crash/new-machine boot: the lane never reaped its own worktree
# (the host died), so a leftover blocks the next spawn unless recovery sweeps it.
make_env
HARNESS_REPO=acme/widget
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

# ── #5/#109: a FAILED spawn_bug TRIAGE must NOT leave the issue stamped agent-working (#34 invariant) ──
# Triage now creates a worktree too, so the stamp must come AFTER that worktree step — a failed
# `worktree add` must return BEFORE stamping, exactly like the fix phase, or the open bug keeps
# agent-working with no live session and the lane never re-claims it.
make_env
HARNESS_REPO=acme/widget
UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget; HARNESS_SPEC=""
CHECKOUT="$RUN_DIR/co3"; mkdir -p "$CHECKOUT"
WORKTREES_DIR="$RUN_DIR/wt3"; mkdir -p "$WORKTREES_DIR"
GH3="$RUN_DIR/ghcalls3"; : > "$GH3"
gh(){ echo "gh $*" >> "$GH3"; return 0; }
render(){ :; }; launch_claude(){ :; }; tmux(){ :; }
ensure_checkout(){ :; }; ensure_safe(){ :; }; default_branch(){ echo main; }
git(){ case "$*" in *"worktree add"*) return 1;; *) return 0;; esac; }
spawn_bug 5 triage; assert_eq "$?" "1" "spawn_bug triage returns nonzero when worktree add fails (#109)"
assert_eq "$(grep -c 'add-label' "$GH3" 2>/dev/null; true)" "0" \
  "spawn_bug does NOT stamp agent-working when triage worktree add fails (#34/#109 no wedge)"
unset -f git

# ── #5/#109: sweep_orphan_bug_worktrees also reaps orphan TRIAGE worktrees (dead session), keeps live ──
make_env
HARNESS_REPO=acme/widget; SLUG=acme/widget
CHECKOUT="$RUN_DIR/cosweep2"; git init -q "$CHECKOUT"
git -C "$CHECKOUT" config user.email t@t; git -C "$CHECKOUT" config user.name t
git -C "$CHECKOUT" commit -q --allow-empty -m init
WORKTREES_DIR="$RUN_DIR/wtsweep2"; mkdir -p "$WORKTREES_DIR"
ensure_safe(){ :; }
TDEAD="$(triage_worktree "$SLUG" 7)"; TLIVE="$(triage_worktree "$SLUG" 8)"
git -C "$CHECKOUT" worktree add -q -B agent/bug-triage-7 "$TDEAD"
git -C "$CHECKOUT" worktree add -q -B agent/bug-triage-8 "$TLIVE"
session_live(){ [[ "$1" == "$(sess_bug "$SLUG" 8 triage)" ]]; }   # only #8's triage session live
sweep_orphan_bug_worktrees >/dev/null 2>&1
assert_no "sweep removed the dead-session triage worktree (#7/#109)" test -d "$TDEAD"
assert_ok "sweep kept the live-session triage worktree (#8/#109)"    test -d "$TLIVE"
assert_no "sweep deleted the dead triage's local branch (agent/bug-triage-7)" \
  bash -c "git -C '$CHECKOUT' rev-parse --verify -q agent/bug-triage-7 >/dev/null 2>&1"

# ── per-PRD orch session names + worktree paths (multi-PRD) ──────────────────────────
assert_eq "$(HARNESS_SESS_PREFIX=hz sess_orch main 41)" "hz-main-p41" "sess_orch embeds the PRD"
assert_eq "$(HARNESS_SESS_PREFIX=hz sess_orch main)"    "hz-main-p0"  "sess_orch defaults to p0"
assert_eq "$(WORKTREES_DIR=/w orch_worktree acme/widget 41)" "/w/orch-acme_widget-p41" \
  "orch_worktree is repo-qualified and PRD-suffixed"

# team_sessions must count BOTH the new -p form and any -i impl session, plus the bare legacy
# form so an orch session launched by the pre-upgrade engine is still reaped rather than orphaned.
# Earlier blocks stub team_sessions out (line 21/46/71) and make_env does not re-source lib.sh —
# restore the REAL one so this exercises the shipped regex, not a stub.
source "$HERE/../scripts/lib.sh"
tmux(){ printf '%s\n' hz-main hz-main-p41 hz-main-i7 hz-other-p1 hz-mainline-p2; }
assert_eq "$(HARNESS_SESS_PREFIX=hz team_sessions main | tr '\n' ' ')" \
  "hz-main hz-main-p41 hz-main-i7 " "team_sessions matches legacy, -p and -i, and nothing else"
unset -f tmux

# ── the busy-PRD set reaches dispatch_actions ────────────────────────────────────────
BUSY_SEEN=""
dispatch_actions(){ BUSY_SEEN="$4"; return 0; }
tmux(){ printf '%s\n' hz-main-p41 hz-main-i7; }
HARNESS_SESS_PREFIX=hz busy_prds_for main >/dev/null
assert_eq "$(HARNESS_SESS_PREFIX=hz busy_prds_for main)" "41" \
  "busy_prds_for extracts PRD numbers from live -p sessions, ignoring p0 and -i"
unset -f tmux dispatch_actions

finish

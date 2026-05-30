#!/usr/bin/env bash
# test_bug_flow.sh — the two-phase bug flow (#27): phase-aware template selection, the
# label-transition + close contracts baked into the rendered prompts, and the guarantee
# that triage and fix run as TWO DISTINCT sessions (fresh context each).
# Prompts are rendered to files and grepped from files: their bodies contain backticks, which
# would execute if interpolated into a `bash -c` herestring.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/../scripts/priority-worker.sh"   # defines drive_bug/bug_goal_done; main() guarded out
source "$HERE/helpers.sh"
make_env

# ── phase detection: `bug` → triage, `bug-triaged` → fix ─────────────────────
# _bug_labels is the overridable GitHub seam (comma-joined label names). Everything
# downstream (template + session choice) keys off the phase it yields.
SLUG=acme/widget
_bug_labels(){ echo "bug"; }
assert_eq "$(bug_phase 7)" "triage" "untriaged bug -> triage phase"
_bug_labels(){ echo "bug-triaged"; }
assert_eq "$(bug_phase 7)" "fix" "bug-triaged -> fix phase"
_bug_labels(){ echo "bug,bug-triaged,agent-working"; }
assert_eq "$(bug_phase 7)" "fix" "bug-triaged wins when both labels present (already past triage)"

# ── bug-triage.md contract: refine + flip label IN PLACE, no code, no fan-out ─
TRI="$RUN_DIR/triage.txt"
render "$HERE/../prompts/bug-triage.md" \
  ISSUE=42 SLUG=acme/widget PROJECT=w DESC=d OWNER=acme SPEC= BRANCH=issue/42 \
  PROMISE='BUG 42 triage DONE' \
  LABEL_READY=ready-for-agent LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused \
  LABEL_BUG=bug LABEL_BUG_TRIAGED=bug-triaged > "$TRI"

assert_ok "triage: flips bug -> bug-triaged (remove bug, add bug-triaged)" \
  grep -qE -- '--remove-label bug .*--add-label bug-triaged' "$TRI"
# C1 strand fix: the engine's bug_goal_done fires the moment `bug-triaged` is present (bug_phase==fix)
# and the hold loop then KILLS the triage session — possibly between the flip and the agent-working
# drop. If agent-working drops AFTER the flip, that kill can strand the bug `bug-triaged`+agent-working,
# which bug_lane_candidates excludes — invisible to the fix phase until reap_lane sweeps it (a ~60s
# flap). So the prompt MUST drop agent-working BEFORE the bug->bug-triaged flip: when the engine sees
# bug-triaged and kills, agent-working is already gone, so the bug is immediately fix-claimable.
assert_ok "triage: drops agent-working BEFORE the bug->bug-triaged flip (C1: no fix-phase strand)" \
  bash -c "awk '/--remove-label agent-working/ && !w{w=NR} /--remove-label bug .*--add-label bug-triaged/ && !f{f=NR} END{exit !(w && f && w < f)}' '$TRI'"
assert_ok "triage: refines body + acceptance criteria" \
  grep -qi 'acceptance' "$TRI"
assert_ok "triage: explicitly no sub-agent fan-out" \
  grep -qiE 'no sub-agent|without sub-agent|never dispatch sub-agent' "$TRI"
assert_no "triage: writes NO code (does not open a PR)" \
  grep -qE 'gh pr (create|merge)' "$TRI"
assert_ok "triage: may close as invalid/duplicate/wontfix" \
  grep -qiE 'invalid|duplicate|wontfix' "$TRI"
# #107: the close/disposition path must DROP the working label via its OWN gh issue edit command,
# and BEFORE gh issue close. bug_goal_done returns done the instant the issue reads CLOSED, so the
# hold loop can KILL the session between a post-close remove-label and its completion — stranding the
# now-closed bug carrying agent-working (mirrors the C1 flip-path strand fixed in #101). Anchor on
# `gh issue comment` (close-path only) so the flip path's own remove-label can't satisfy this.
assert_ok "triage: close path drops agent-working BEFORE gh issue close (#107: no CLOSED-kill strand)" \
  bash -c "awk '/gh issue comment/{c=NR} /gh issue edit .*--remove-label agent-working/{if(c)r=NR} /gh issue close/{k=NR} END{exit !(c && r && k && c < r && r < k)}' '$TRI'"
# the drop is a standalone command, never a flag bolted onto gh issue close (invalid gh usage)
assert_no "triage: --remove-label is NOT a flag on gh issue close (#107)" \
  grep -qE 'gh issue close .*--remove-label' "$TRI"
assert_ok "triage: completion promise present" \
  grep -q '<promise>BUG 42 triage DONE</promise>' "$TRI"
assert_no "triage: no unrendered {{ token" \
  grep -q '{{' "$TRI"

# parameterised label flip — custom labels must reach the gh command, defaults must not leak
TRIC="$RUN_DIR/triage_custom.txt"
render "$HERE/../prompts/bug-triage.md" \
  ISSUE=42 SLUG=acme/widget PROJECT=w DESC=d OWNER=acme SPEC= BRANCH=issue/42 \
  PROMISE=P LABEL_READY=go LABEL_WORKING=busy LABEL_PAUSED=zzz \
  LABEL_BUG=defect LABEL_BUG_TRIAGED=triaged > "$TRIC"
assert_ok "triage: custom labels reach the flip command" \
  grep -qE -- '--remove-label defect .*--add-label triaged' "$TRIC"
assert_no "triage: default 'bug-triaged' label absent when parameterised" \
  grep -qE -- '--add-label bug-triaged' "$TRIC"
# #107: the close-path working-label drop is parameterised too — a custom-label fleet must drop its
# OWN working label before close, never leak the literal default agent-working.
assert_ok "triage: custom close path drops the custom working label before gh issue close (#107)" \
  bash -c "awk '/gh issue comment/{c=NR} /gh issue edit .*--remove-label busy/{if(c)r=NR} /gh issue close/{k=NR} END{exit !(c && r && k && c < r && r < k)}' '$TRIC'"

# ── bug-fix.md contract: TDD -> PR -> auto-merge -> close the refined issue ──
FIX="$RUN_DIR/fix.txt"
render "$HERE/../prompts/bug-fix.md" \
  ISSUE=42 SLUG=acme/widget PROJECT=w DESC=d OWNER=acme SPEC= BRANCH=issue/42 \
  PROMISE='BUG 42 fix DONE' \
  LABEL_READY=ready-for-agent LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused \
  LABEL_BUG=bug LABEL_BUG_TRIAGED=bug-triaged > "$FIX"

assert_ok "fix: implements the refined bug-triaged issue" \
  grep -qi 'bug-triaged' "$FIX"
assert_ok "fix: uses TDD" \
  grep -qiE 'test-driven|TDD' "$FIX"
assert_ok "fix: opens a PR" \
  grep -q 'gh pr create' "$FIX"
assert_ok "fix: tries to enable auto-merge first" \
  grep -q 'gh pr merge --auto --squash --delete-branch' "$FIX"
assert_ok "fix: falls back to a direct squash merge when auto-merge is disabled" \
  grep -q 'gh pr merge --squash --delete-branch' "$FIX"
assert_ok "fix: drives the PR to MERGED, not merely opened" \
  grep -qiE 'ends MERGED|Do not stop at' "$FIX"
assert_ok "fix: closes the issue on merge" \
  grep -qE 'closes #42' "$FIX"
assert_ok "fix: completion promise present" \
  grep -q '<promise>BUG 42 fix DONE</promise>' "$FIX"
assert_no "fix: no unrendered {{ token" \
  grep -q '{{' "$FIX"

# ── drive_bug: phase selects template + DISTINCT session; marks agent-working ─
# Hermetic: stub the GitHub/launch layer; session_live false so drive_bug returns right
# after spawning (no real tmux session to wait on). Each stub records to $CALLS. git creates
# the fix worktree dir so spawn_bug's render redirect has somewhere to write.
CALLS="$RUN_DIR/calls"
stub_bug(){ : > "$CALLS"
  render(){ echo "render $1" >> "$CALLS"; return 0; }                  # $1 = template path
  launch_claude(){ echo "launch_claude $1" >> "$CALLS"; return 0; }    # $1 = session name
  tmux(){ echo "tmux $*" >> "$CALLS"; return 0; }
  gh(){ echo "gh $*" >> "$CALLS"; return 0; }
  git(){ echo "git $*" >> "$CALLS"
    if [[ "$1" == -C && "$3" == worktree && "$4" == add ]]; then
      local a; for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && mkdir -p "$a"; done
    fi; return 0; }
  default_branch(){ echo main; }; ensure_safe(){ :; }; ensure_checkout(){ :; }
  session_live(){ return 1; }   # stubbed launch -> no live session -> no blocking wait
}
HARNESS_TOPOLOGY=single; HARNESS_REPO=acme/widget

# triage phase
stub_bug; _bug_labels(){ echo "bug"; }
drive_bug 42 >/dev/null 2>&1
sess_triage="$(grep '^launch_claude ' "$CALLS" | awk '{print $2}')"
assert_ok "drive_bug(bug): renders bug-triage.md" \
  grep -q 'render .*prompts/bug-triage.md' "$CALLS"
assert_ok "drive_bug(bug): launches a triage session" \
  grep -qE '^launch_claude .*-triage$' "$CALLS"
assert_ok "drive_bug(bug): marks the issue agent-working (no double-dispatch)" \
  grep -q 'add-label agent-working' "$CALLS"

# fix phase
stub_bug; _bug_labels(){ echo "bug-triaged"; }
drive_bug 42 >/dev/null 2>&1
sess_fix="$(grep '^launch_claude ' "$CALLS" | awk '{print $2}')"
assert_ok "drive_bug(bug-triaged): renders bug-fix.md" \
  grep -q 'render .*prompts/bug-fix.md' "$CALLS"
assert_ok "drive_bug(bug-triaged): launches a fix session" \
  grep -qE '^launch_claude .*-fix$' "$CALLS"
assert_ok "drive_bug(bug-triaged): marks the issue agent-working" \
  grep -q 'add-label agent-working' "$CALLS"
# #37: the fix worktree path is repo-qualified so two repos' same-numbered bugs never collide
# on a shared worktree dir (which would block the second fix).
assert_ok "drive_bug(bug-triaged): fix worktree path is repo-qualified (#37)" \
  grep -qE 'worktree add .* .*/bug-acme_widget-i42( |$)' "$CALLS"
assert_no "drive_bug(bug-triaged): does NOT use the bare unqualified bug-i42 path" \
  grep -qE 'worktree add .* .*/bug-i42( |$)' "$CALLS"

assert_ok "triage and fix are TWO DISTINCT sessions" \
  bash -c "[[ -n '$sess_triage' && -n '$sess_fix' && '$sess_triage' != '$sess_fix' ]]"

# ── spawn_bug fix RESUMES a checkpointed bug (resume.md), else starts fresh (#36) ──
# A force-paused fix flips agent-working → agent-paused and pushes its issue/<n> branch. The next
# claim must CONTINUE that WIP, not restart cold. Mirrors spawn_impl: agent-paused label OR an
# existing remote branch → resume.md. Default stub_bug reports neither → fresh bug-fix.md.
stub_bug; _bug_labels(){ echo "bug-triaged"; }   # fix phase, not paused, no remote branch
drive_bug 42 >/dev/null 2>&1
assert_ok "fix (fresh): renders bug-fix.md when not paused / no remote branch" \
  grep -q 'render .*prompts/bug-fix.md' "$CALLS"
assert_no "fix (fresh): does NOT render resume.md" \
  grep -q 'render .*prompts/resume.md' "$CALLS"

# paused issue: gh issue view reports agent-paused -> resume.md instead of bug-fix.md
stub_bug; _bug_labels(){ echo "bug-triaged"; }
gh(){ echo "gh $*" >> "$CALLS"
  case "$1 $2" in "issue view") echo '["agent-paused","bug-triaged"]';; esac; return 0; }
drive_bug 42 >/dev/null 2>&1
assert_ok "fix (resume): renders resume.md when issue carries agent-paused" \
  grep -q 'render .*prompts/resume.md' "$CALLS"
assert_no "fix (resume): does NOT render bug-fix.md when resuming" \
  grep -q 'render .*prompts/bug-fix.md' "$CALLS"

# pushed WIP branch (no paused label): ls-remote finds origin/issue/<n> -> resume.md
stub_bug; _bug_labels(){ echo "bug-triaged"; }
git(){ echo "git $*" >> "$CALLS"
  if [[ "$1" == -C && "$3" == worktree && "$4" == add ]]; then
    local a; for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && mkdir -p "$a"; done
  fi
  [[ "$3" == ls-remote ]] && echo "abc123	refs/heads/issue/42"
  return 0; }
drive_bug 42 >/dev/null 2>&1
assert_ok "fix (resume): renders resume.md when a remote issue/<n> branch exists" \
  grep -q 'render .*prompts/resume.md' "$CALLS"

# ── bug_goal_done: each phase's completion signal (drives the hold/reap loop) ─
# Seams: _bug_state (issue OPEN/CLOSED), _bug_labels (drives bug_phase).
_bug_state(){ echo OPEN; }; _bug_labels(){ echo "bug"; }
assert_no "triage NOT done while still untriaged + open" bug_goal_done 42 triage
_bug_labels(){ echo "bug-triaged"; }
assert_ok "triage done once label flipped to bug-triaged" bug_goal_done 42 triage
_bug_state(){ echo CLOSED; }; _bug_labels(){ echo "bug"; }
assert_ok "triage done when issue closed (invalid/duplicate/wontfix)" bug_goal_done 42 triage
_bug_state(){ echo OPEN; }; _bug_labels(){ echo "bug-triaged"; }
assert_no "fix NOT done while issue still open" bug_goal_done 42 fix
_bug_state(){ echo CLOSED; }
assert_ok "fix done when issue closed (PR merged)" bug_goal_done 42 fix

# ── drive_bug holds the claim for a live session, reaps it once the goal is met ─
stub_bug; PRIORITY_POLL=0
_bug_labels(){ echo "bug-triaged"; }   # fix phase
session_live(){ return 0; }            # session reports live...
_bug_state(){ echo CLOSED; }           # ...and the fix already merged → reap it
drive_bug 42 >/dev/null 2>&1
assert_ok "drive_bug reaps the session once the phase goal is met" \
  grep -q 'tmux kill-session' "$CALLS"
# #34: a completed fix must also tear down its worktree + local branch (no accumulation, and no
# leftover to wedge the next fix). The branch -D is the reap's unique fingerprint — spawn_bug's
# defensive pre-add removal removes only the worktree, never the branch.
assert_ok "drive_bug reaps the fix worktree + local branch once the goal is met" \
  grep -q 'branch -D issue/42' "$CALLS"

# ── drive_bug leaves a live session running when paused (drains, no reap) ─────
stub_bug; PRIORITY_POLL=0
_bug_labels(){ echo "bug-triaged"; }
session_live(){ return 0; }
_bug_state(){ echo OPEN; }             # goal NOT met
touch "$PAUSE_FLAG"
drive_bug 42 >/dev/null 2>&1
rm -f "$PAUSE_FLAG"
assert_no "drive_bug does NOT reap a live session when paused (drains)" \
  grep -q 'tmux kill-session' "$CALLS"
# #34: a paused fix session still owns its worktree — drive_bug must NOT reap it (branch -D absent).
assert_no "drive_bug does NOT reap the worktree branch when paused (drains)" \
  grep -q 'branch -D issue/42' "$CALLS"

# ── #5/#109: bug-TRIAGE runs in its OWN per-session worktree, never the shared $CHECKOUT ──
# PINNED defect: triage ran in $CHECKOUT (PROJECT_ROOT in single topology). A concurrent spawn_orch
# `render > $CHECKOUT/.harness-task.md` (brief clobber) + `git reset -q --hard origin/<base>`
# (working-tree yank) therefore corrupted the in-flight triage. Fix = give triage its own worktree,
# exactly like spawn_impl / the bug FIX phase. This is the real-git regression proving isolation.
make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO=acme/widget
UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget; HARNESS_SPEC=""
unset -f git 2>/dev/null || true   # earlier tests stubbed git — the isolation proof needs REAL git
ORIGIN="$RUN_DIR/origin.git"; git init -q --bare "$ORIGIN"
SEED="$RUN_DIR/seed"; git init -q "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
echo "src-v1" > "$SEED/code.txt"; git -C "$SEED" add -A; git -C "$SEED" commit -qm init
git -C "$SEED" branch -M main; git -C "$SEED" remote add origin "$ORIGIN"; git -C "$SEED" push -q origin main
CHECKOUT="$RUN_DIR/checkout"; git clone -q "$ORIGIN" "$CHECKOUT"
WORKTREES_DIR="$RUN_DIR/wt"; mkdir -p "$WORKTREES_DIR"
# stub only the launch layer; render writes a KNOWN triage brief into $wd/.harness-task.md
render(){ echo "TRIAGE-BRIEF-ISOLATED"; }
launch_claude(){ :; }; tmux(){ :; }; gh(){ :; }
default_branch(){ echo main; }; ensure_safe(){ :; }; ensure_checkout(){ :; }
spawn_bug 109 triage
TRI_WT="$(triage_worktree "$SLUG" 109)"
assert_ok "triage: dedicated worktree created off origin/main (#109)" test -d "$TRI_WT"
assert_eq "$(cat "$TRI_WT/.harness-task.md" 2>/dev/null)" "TRIAGE-BRIEF-ISOLATED" \
  "triage: brief written INTO the triage worktree (#109)"
assert_no "triage: did NOT write .harness-task.md into the shared \$CHECKOUT (#109 clobber source)" \
  test -f "$CHECKOUT/.harness-task.md"
# Now simulate a CONCURRENT spawn_orch against the SAME $CHECKOUT: brief clobber + hard reset (the yank).
echo "ORCH-BRIEF-CLOBBER" > "$CHECKOUT/.harness-task.md"
echo "src-v2-orch" > "$CHECKOUT/code.txt"
git -C "$CHECKOUT" reset -q --hard origin/main
assert_eq "$(cat "$TRI_WT/.harness-task.md" 2>/dev/null)" "TRIAGE-BRIEF-ISOLATED" \
  "triage: brief survives a concurrent orch render on \$CHECKOUT (#109 no clobber)"
assert_eq "$(cat "$TRI_WT/code.txt" 2>/dev/null)" "src-v1" \
  "triage: working tree survives a concurrent git reset --hard on \$CHECKOUT (#109 no yank)"

# ── #5/#109: drive_bug reaps the TRIAGE worktree once its session ends (parity with the fix reap) ──
# Triage now owns a worktree, so the cap-1 lane must tear it down on completion just like the fix
# phase — else a triage worktree leaks on every triaged bug and a crashed one wedges the next attempt.
stub_bug; PRIORITY_POLL=0
_bug_labels(){ echo "bug"; }     # triage phase...
session_live(){ return 0; }      # session reports live...
_bug_state(){ echo CLOSED; }     # ...and triage closed it (invalid/dup/wontfix) → goal met → reap
drive_bug 42 >/dev/null 2>&1
assert_ok "drive_bug reaps the triage worktree + branch once triage completes (#109)" \
  grep -q 'branch -D agent/bug-triage-42' "$CALLS"

# paused triage session still owns its worktree — drive_bug must NOT reap it (drains)
stub_bug; PRIORITY_POLL=0
_bug_labels(){ echo "bug"; }; session_live(){ return 0; }; _bug_state(){ echo OPEN; }
touch "$PAUSE_FLAG"; drive_bug 42 >/dev/null 2>&1; rm -f "$PAUSE_FLAG"
assert_no "drive_bug does NOT reap the triage worktree branch when paused (#109 drains)" \
  grep -q 'branch -D agent/bug-triage-42' "$CALLS"

finish

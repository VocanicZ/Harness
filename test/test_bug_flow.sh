#!/usr/bin/env bash
# test_bug_flow.sh — the two-phase bug flow (#27): phase-aware template selection, the
# label-transition + close contracts baked into the rendered prompts, and the guarantee
# that triage and fix run as TWO DISTINCT sessions (fresh context each).
# Prompts are rendered to files and grepped from files: their bodies contain backticks, which
# would execute if interpolated into a `bash -c` herestring.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../drive.sh"
source "$HERE/../priority-worker.sh"   # defines drive_bug/bug_goal_done; main() guarded out
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
assert_ok "triage: refines body + acceptance criteria" \
  grep -qi 'acceptance' "$TRI"
assert_ok "triage: explicitly no sub-agent fan-out" \
  grep -qiE 'no sub-agent|without sub-agent|never dispatch sub-agent' "$TRI"
assert_no "triage: writes NO code (does not open a PR)" \
  grep -qE 'gh pr (create|merge)' "$TRI"
assert_ok "triage: may close as invalid/duplicate/wontfix" \
  grep -qiE 'invalid|duplicate|wontfix' "$TRI"
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
assert_ok "fix: enables auto-merge" \
  grep -q 'gh pr merge --auto' "$FIX"
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

finish

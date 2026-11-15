#!/usr/bin/env bash
# quota-park.sh — #1154: a lane whose wait is hours away (a usage window that resets later, a bench batch waiting for a quota gate)
# gives its pool slot up instead of holding it. The twin of `winsma.sh park` (#1034): post a handoff, swap agent-working for the
# waiting label (HARNESS_LABEL_WAITING_QUOTA, default waiting-quota) in ONE edit, and let the engine end the session (the pool reads
# "waiting label, no agent-working" as done, so the slot is free). quota_wake_tick (scripts/lib.sh) removes the label once the wait is
# over and the pool relaunches the issue as a resume from its pushed branch.
#
#   quota-park.sh <issue> <owner/repo> [<wake epoch> [<what>]]
#
# `waitlib.py set` calls this for a long wait in a lane (it writes the resume=redispatch spec first); it is not a command a lane types.
# Refuses (exit 1, label untouched) while the worktree is dirty or HEAD is not on origin: the session ends on the swap, so nothing may
# be left in it. HARNESS_PARK_CHECK_PUSHED=0 skips that check (a lane with no branch of its own).
set -uo pipefail
issue="${1:-}"; slug="${2:-}"; wake="${3:-0}"; what="${4:-a long wait}"
die(){ echo "quota-park: $*" >&2; exit 1; }
[[ "$issue" =~ ^[0-9]+$ ]] || die "issue must be a number, got '$issue'"
[[ -n "$slug" ]] || die "no repo — pass owner/repo"
work="${HARNESS_LABEL_WORKING:-agent-working}"; waiting="${HARNESS_LABEL_WAITING_QUOTA:-waiting-quota}"
git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git worktree"
br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "issue/$issue")"
if [[ "${HARNESS_PARK_CHECK_PUSHED:-1}" != 0 ]]; then
  [[ -z "$(git status --porcelain 2>/dev/null)" ]] || die "uncommitted changes — commit and push first (the session is ended when you park)"
  head="$(git rev-parse HEAD 2>/dev/null)"
  remote="$(git ls-remote origin "refs/heads/$br" 2>/dev/null | awk '{print $1}' | head -1)"
  [[ -n "$remote" && "$remote" == "$head" ]] || die "$br is not pushed (HEAD $head, origin ${remote:-has no such branch}) — push first"
fi
when="when its wait ends"
if [[ "$wake" =~ ^[0-9]+$ ]] && (( wake > 0 )); then when="not before $(date -u -d "@$wake" '+%Y-%m-%d %H:%MZ' 2>/dev/null || echo "epoch $wake")"; fi
gh issue comment "$issue" -R "$slug" --body "<!-- harness-handoff issue=$issue branch=$br -->
Parked until a long wait ends (#1154): this lane was waiting on ${what} and gave up its pool slot instead of holding it. The branch \`$br\` is pushed. Harness re-dispatches the issue as a resume ${when}, once the usage hold is clear. On resume: carry on from the branch and the notes above; re-check the condition you were waiting for first." >/dev/null \
  || die "could not post the handoff comment"
# ONE edit: add the waiting label and drop agent-working together, so the issue is never seen with neither.
gh issue edit "$issue" -R "$slug" --add-label "$waiting" --remove-label "$work" >/dev/null \
  || die "could not swap $work for $waiting"
echo "quota-park: #$issue parked ($waiting) — ${what}; its session ends and the issue is re-dispatched ${when}"
exit 0

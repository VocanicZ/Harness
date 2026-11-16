#!/usr/bin/env bash
# test_prompt_review_owns_prs.sh — #1233: a PR the review opens (suite logs, review notes) is merged in the same review
# session, or handed to a `ready-for-agent` issue that owns it; the review is not done while it sits open with no owner
# (#1103 waited 4 days). Prompts are grepped as rendered text (newlines folded).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
flat(){ tr '\n' ' ' | tr -s ' '; }

R="$(render "$P/review.md" PROJECT=w DESC=d SLUG=acme/widget PRD=7 PROMISE="REVIEW DONE" LABEL_READY=ready-for-agent \
  LABEL_REVIEWED=prd-reviewed | flat)"

echo "-- a review-opened PR is merged by the review"
assert_ok "rule present" grep -qF 'REVIEW-OPENED PRs OWN THEMSELVES' <<<"$R"
assert_ok "merged in the same review session" grep -qF 'merges that PR in THIS session, after the gate' <<<"$R"
assert_ok "squash merge command names the repo" grep -qF 'gh pr merge --squash --delete-branch -R acme/widget <pr-number>' <<<"$R"
assert_ok "applies to every branch, before OUTPUT" grep -qF 'applies to EVERY branch below, before OUTPUT' <<<"$R"

echo "-- unmergeable -> a ready-for-agent issue owns the PR"
assert_ok "files a ready issue that owns the PR" grep -qF 'file ONE `ready-for-agent` issue that OWNS the PR' <<<"$R"
assert_ok "owner issue carries Blocked by None + Parent trailer" grep -qF "ENDING with the \`## Blocked by\` / \`None\` and \`## Parent\` / \`#7\`" <<<"$R"
assert_ok "the owner issue is the exception to one issue per round" grep -qF 'is the one exception to ONE ISSUE PER REVIEW ROUND' <<<"$R"
assert_ok "not done while a PR it opened has no owner" grep -qF 'The review is NOT done while a PR it opened is open with no owner' <<<"$R"
finish

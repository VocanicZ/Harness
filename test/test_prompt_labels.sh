#!/usr/bin/env bash
# test_prompt_labels.sh — verify LABEL_* render keys reach executable gh commands.
# Run after sourcing lib.sh (which provides render()).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"

TESTS_RUN=0; TESTS_FAIL=0
assert(){
  local name="$1" cmd="$2"
  TESTS_RUN=$((TESTS_RUN+1))
  if eval "$cmd"; then
    echo "  ok: $name"
  else
    echo "  FAIL: $name"
    TESTS_FAIL=$((TESTS_FAIL+1))
  fi
}

# ── render each template with custom label values ────────────────────────────
out_review="$(render "$HERE/../prompts/review.md" \
  PRD=7 SLUG=acme/widget PROJECT=w DESC=d SPEC= \
  LABEL_READY=go LABEL_PRD=spec LABEL_REVIEWED=verified \
  GAUNTLET_DIR=/tmp/gaunt GAUNTLET_ROUND=2 GAUNTLET_ROUNDS=3)"

out_dec="$(render "$HERE/../prompts/decompose.md" \
  PRD=7 SLUG=acme/widget PROJECT=w DESC=d SPEC= OWNER=acme \
  LABEL_READY=go LABEL_PRD=spec LABEL_REVIEWED=verified)"

out_prd="$(render "$HERE/../prompts/prd.md" \
  PRD=7 SLUG=acme/widget PROJECT=w DESC=d SPEC= \
  LABEL_READY=go LABEL_PRD=spec LABEL_REVIEWED=verified)"

# ── review.md assertions ─────────────────────────────────────────────────────
assert "review.md: add-label verified appears" \
  "grep -q 'add-label verified' <<<\"\$out_review\""

assert "review.md: no default 'add-label reviewed' in gh lines" \
  "! grep -E '^[[:space:]]*(gh |[a-z].*&&.*gh )' <<<\"\$out_review\" | grep -qE 'add-label reviewed( |\$)'"

# Simpler: no executable gh line contains the literal default 'reviewed' label
assert "review.md: default label 'reviewed' absent from gh add-label lines" \
  "! grep -qE 'add-label reviewed( |\$)' <<<\"\$out_review\""

assert "review.md: custom ready label 'go' used in ready-for-agent context" \
  "grep -q 'ready-for-agent\|go' <<<\"\$out_review\""

assert "review.md: no unrendered {{LABEL_ token" \
  "! grep -q '{{LABEL_' <<<\"\$out_review\""

# ── review.md gauntlet assertions ────────────────────────────────────────────
assert "review.md: no unrendered {{GAUNTLET_ token" \
  "! grep -q '{{GAUNTLET_' <<<\"\$out_review\""

assert "review.md: criteria gate runs before the gauntlet" \
  "[[ \$(grep -n 'PHASE 1' <<<\"\$out_review\" | head -1 | cut -d: -f1) -lt \$(grep -n 'PHASE 2' <<<\"\$out_review\" | head -1 | cut -d: -f1) ]]"

assert "review.md: no quality bar -> sign off unchanged" \
  "grep -qi 'no .*Quality bar' <<<\"\$out_review\""

assert "review.md: round/cap values are rendered" \
  "grep -q 'round 2 of 3' <<<\"\$out_review\""

assert "review.md: writes the round marker with the rendered round" \
  "grep -q 'harness-gauntlet round=2' <<<\"\$out_review\""

assert "review.md: evidence dirs live under the rendered GAUNTLET_DIR" \
  "grep -q '/tmp/gaunt/r2' <<<\"\$out_review\""

assert "review.md: .mapping is a sibling of A/ and B/" \
  "grep -q '.mapping' <<<\"\$out_review\" && grep -qi 'sibling' <<<\"\$out_review\""

assert "review.md: critic verdict is binary (no scores)" \
  "grep -q 'winner: A|B' <<<\"\$out_review\" && grep -qi 'no.*scores\|not.*scores' <<<\"\$out_review\""

assert "review.md: concede path signs off at the cap" \
  "grep -qi 'concede' <<<\"\$out_review\""

assert "review.md: never parks on a quality gate" \
  "! grep -q 'add-label agent-blocked' <<<\"\$out_review\" && grep -qi 'never apply an agent-blocked' <<<\"\$out_review\""

assert "review.md: a lost round files exactly ONE issue" \
  "grep -qi 'exactly ONE' <<<\"\$out_review\""

# The reviewer must NOT close the PRD itself. The engine's CLOSE_PRD is gated on
# children_all_closed; an agent-side `gh issue close` is not, so a review that signs off AND files
# a follow-up in the same pass used to strand that follow-up forever — a closed PRD makes the unit
# COMPLETE, and claimable_units drops a complete unit before drive_unit ever asks dispatch what is
# outstanding. Observed on hardcore-gacha-2: #80 filed 03:00:35, PRD closed 03:01:04, pool idle
# from 03:06 with an open ready-for-agent issue and the unit reporting complete=Y.
assert "review.md: does NOT close the PRD itself" \
  "! grep -qE 'gh issue close +(7|\{\{PRD\}\})' <<<\"\$out_review\""

assert "review.md: sign-off still applies the reviewed label" \
  "grep -q 'add-label verified' <<<\"\$out_review\""

assert "review.md: hands the close to the engine, gated on the ready issues" \
  "grep -qi 'ENGINE closes the PRD' <<<\"\$out_review\" && grep -qi 'only once every' <<<\"\$out_review\""

assert "review.md: names the strand-a-follow-up trap explicitly" \
  "grep -qi 'strands it permanently\|orphans it permanently' <<<\"\$out_review\""

assert "review.md: still permits filing a follow-up alongside a sign-off" \
  "grep -qi 'filing a follow-up and signing off in the same pass is fine' <<<\"\$out_review\""

# ── decompose.md assertions ──────────────────────────────────────────────────
assert "decompose.md: --label go (custom ready) appears in gh issue create" \
  "grep -q '\-\-label go' <<<\"\$out_dec\""

assert "decompose.md: --label ready-for-agent default absent from gh issue create" \
  "! grep -qE '\-\-label ready-for-agent' <<<\"\$out_dec\""

assert "decompose.md: gh issue list uses custom ready label" \
  "grep -qE 'gh issue list.*--label go' <<<\"\$out_dec\""

assert "decompose.md: no unrendered {{LABEL_ token" \
  "! grep -q '{{LABEL_' <<<\"\$out_dec\""

assert "decompose.md: idempotent — lists existing with --state all" \
  "grep -q 'state all' <<<\"\$out_dec\""

assert "decompose.md: only-missing / no-duplicate rule present" \
  "grep -qi 'only' <<<\"\$out_dec\" && grep -qi 'duplicate' <<<\"\$out_dec\""

# ── decompose.md cross-unit coordination (direct cross-repo deps) ─────────────
assert "decompose.md: cross-unit fix issue filed directly in target unit's repo via targets.tsv" \
  "grep -qi 'targets.tsv' <<<\"\$out_dec\" && grep -qiE \"target unit'?s? repo\" <<<\"\$out_dec\""

assert "decompose.md: cross-repo fix issue gets a requester backlink" \
  "grep -qi 'backlink' <<<\"\$out_dec\""

assert "decompose.md: cross-repo owner/repo#N added to requester's Blocked by" \
  "grep -q 'owner/repo#' <<<\"\$out_dec\" && grep -qi 'Blocked by' <<<\"\$out_dec\""

assert "decompose.md: documents no automated cross-repo cycle detection" \
  "grep -qi 'no automated cross-repo cycle detection' <<<\"\$out_dec\""

assert "decompose.md: coordination repo/label demoted to optional tracking" \
  "grep -qi 'optional' <<<\"\$out_dec\" && grep -qi 'tracking' <<<\"\$out_dec\""

# ── decompose.md multi-PRD attribution ───────────────────────────────────────
# A child must name its PRD in a `## Parent` section — issuelib.parse_parent reads that section
# to bucket children per PRD. Without it a second PRD's children are unattributed.
assert "decompose.md: emits a ## Parent section in the issue body" \
  "grep -q '## Parent' <<<\"\$out_dec\""

# The idempotency listing must be scoped to THIS PRD's children; a repo-wide listing lets a
# sibling PRD's issues make this decompose skip real work as 'already existing'.
assert "decompose.md: idempotency listing is scoped to this PRD's children" \
  "grep -q 'contains(\"Part of #7\")' <<<\"\$out_dec\""

assert "decompose.md: says a sibling PRD's issues are not yours" \
  "grep -qi 'sibling PRD' <<<\"\$out_dec\""

# ── prd.md assertions ────────────────────────────────────────────────────────
assert "prd.md: --label spec (custom prd label) appears in gh issue create" \
  "grep -q '\-\-label spec' <<<\"\$out_prd\""

assert "prd.md: default '--label prd' absent from gh issue create" \
  "! grep -qE '\-\-label prd( |\$|\"|\047)' <<<\"\$out_prd\""

assert "prd.md: gh issue list uses custom prd label" \
  "grep -qE 'gh issue list.*--label spec' <<<\"\$out_prd\""

assert "prd.md: gh label create uses custom prd label" \
  "grep -qE 'gh label create spec' <<<\"\$out_prd\""

assert "prd.md: default 'gh label create prd' absent" \
  "! grep -qE 'gh label create prd ' <<<\"\$out_prd\""

assert "prd.md: no unrendered {{LABEL_ token" \
  "! grep -q '{{LABEL_' <<<\"\$out_prd\""

# ── prd.md quality-bar assertions ────────────────────────────────────────────
assert "prd.md: teaches the '## Quality bar' section" \
  "grep -q '## Quality bar' <<<\"\$out_prd\""

assert "prd.md: bar contract is Beat + Judged on" \
  "grep -q 'Beat:' <<<\"\$out_prd\" && grep -q 'Judged on' <<<\"\$out_prd\""

assert "prd.md: enforces named + fetchable + comparable" \
  "grep -qi 'named' <<<\"\$out_prd\" && grep -qi 'fetchable' <<<\"\$out_prd\" && grep -qi 'comparable' <<<\"\$out_prd\""

assert "prd.md: omission is explicitly allowed (never invent a bar)" \
  "grep -qi 'omit' <<<\"\$out_prd\" && grep -qi 'never invent' <<<\"\$out_prd\""

# ── prd.md multi-PRD assertions ──────────────────────────────────────────────
assert "prd.md: authors one PRD issue per independent workstream" \
  "grep -qi 'one PRD issue per independent workstream' <<<\"\$out_prd\""

assert "prd.md: each PRD carries a ## Blocked by section" \
  "grep -q '## Blocked by' <<<\"\$out_prd\""

assert "prd.md: prefers parallel PRDs, sequences only on a real dependency" \
  "grep -qi 'PARALLEL' <<<\"\$out_prd\" && grep -qi 'real dependency' <<<\"\$out_prd\""

# ── inject.md render ─────────────────────────────────────────────────────────
out_inject="$(render "$HERE/../prompts/inject.md" \
  ALTITUDE=issue BRIEF='wire up a healthcheck endpoint' SLUG=acme/widget \
  PROJECT=w DESC=d SPEC= OWNER=acme PROMISE=INJECT_DONE \
  LABEL_READY=go LABEL_PRD=spec LABEL_WORKING=busy LABEL_BLOCKED=stuck LABEL_REVIEWED=verified)"

# ── inject.md assertions ─────────────────────────────────────────────────────
assert "inject.md: no unrendered {{ token" \
  "! grep -q '{{' <<<\"\$out_inject\""

assert "inject.md: brief substituted" \
  "grep -q 'wire up a healthcheck endpoint' <<<\"\$out_inject\""

assert "inject.md: altitude substituted" \
  "grep -qiE 'altitude:?[[:space:]]+issue' <<<\"\$out_inject\""

assert "inject.md: custom ready label 'go' used in gh issue create" \
  "grep -qE -- '--label go' <<<\"\$out_inject\""

assert "inject.md: default 'agent-working' label absent (working label parameterized)" \
  "! grep -q 'agent-working' <<<\"\$out_inject\""

assert "inject.md: custom working label 'busy' appears" \
  "grep -q 'busy' <<<\"\$out_inject\""

assert "inject.md: custom reviewed label 'verified' appears" \
  "grep -q 'verified' <<<\"\$out_inject\""

assert "inject.md: in-flight working-label issues are read-only" \
  "grep -qi 'in-flight' <<<\"\$out_inject\" && grep -qi 'read-only' <<<\"\$out_inject\""

assert "inject.md: cycle guard present" \
  "grep -qiE 'cycle' <<<\"\$out_inject\""

assert "inject.md: additive / no-duplicate rule present" \
  "grep -qi 'additive' <<<\"\$out_inject\" && grep -qiE 'duplicat' <<<\"\$out_inject\""

assert "inject.md: targets.tsv + seed.sh topology path present" \
  "grep -q 'targets.tsv' <<<\"\$out_inject\" && grep -q 'seed.sh' <<<\"\$out_inject\""

assert "inject.md: same-repo Blocked by ordering present" \
  "grep -q '## Blocked by' <<<\"\$out_inject\" && grep -qi 'same-repo' <<<\"\$out_inject\""

assert "inject.md: completion promise present" \
  "grep -q 'INJECT_DONE' <<<\"\$out_inject\" && grep -q '<promise>' <<<\"\$out_inject\""

# ── summary ──────────────────────────────────────────────────────────────────
echo "── $((TESTS_RUN-TESTS_FAIL))/$TESTS_RUN passed"
[[ $TESTS_FAIL -eq 0 ]]

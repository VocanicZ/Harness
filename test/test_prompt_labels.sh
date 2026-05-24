#!/usr/bin/env bash
# test_prompt_labels.sh — verify LABEL_* render keys reach executable gh commands.
# Run after sourcing lib.sh (which provides render()).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

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
  LABEL_READY=go LABEL_PRD=spec LABEL_REVIEWED=verified)"

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

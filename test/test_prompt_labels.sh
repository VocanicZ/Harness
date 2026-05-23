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

# ── summary ──────────────────────────────────────────────────────────────────
echo "── $((TESTS_RUN-TESTS_FAIL))/$TESTS_RUN passed"
[[ $TESTS_FAIL -eq 0 ]]

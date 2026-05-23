#!/usr/bin/env bash
# seed.sh — create (if absent) and seed a GitHub repo for a harness unit:
#   labels (harness vocabulary), a language-agnostic CI workflow, auto-merge enabled.
# Idempotent.
#
# Usage:
#   seed.sh --labels-only <owner/repo>   # only create/update labels on an existing repo
#   seed.sh <unit-id>                    # full bootstrap for a unit
#
# Generalisation notes (vs. original seed-repo.sh):
#   - Label names come from $HARNESS_LABEL_* (no hardcoded names).
#   - Repo description uses unit_desc() rather than a Bonsai-specific string.
#   - Repo create only runs in multi topology (single topology assumes the project
#     repo already exists in situ — the working tree IS the repo).
#   - Owner comes from $HARNESS_OWNER (was $OWNER from a bonsai-specific sp_repo fn).
#   - The CI workflow content is unchanged (it was already language-agnostic).
#   - Auto-merge and branch-protection calls are unchanged.
#   - No submodule logic (Bonsai-specific); no sp_repo/sp_desc (bonsai registry).

set -uo pipefail

# Source lib.sh only when executed directly (not when sourced by the test).
if [[ -z "${_HARNESS_LIB_SOURCED:-}" ]]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

# ---------------------------------------------------------------------------
# add_label <name> <color> <description>
# Idempotent: tries create, ignores failure (label already exists).
# Uses explicit -R <SLUG> flag; SLUG must be set before calling.
# ---------------------------------------------------------------------------
_seed_add_label(){
  local name="$1" color="$2" desc="$3"
  gh label create "$name" --color "$color" --description "$desc" -R "$_SEED_SLUG" \
    >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# _seed_labels — create all harness labels on $_SEED_SLUG
# ---------------------------------------------------------------------------
_seed_labels(){
  _seed_add_label "$HARNESS_LABEL_READY"    0e8a16 "Implementation issue an agent may pick up"
  _seed_add_label "$HARNESS_LABEL_PRD"      5319e7 "PRD tracking issue"
  _seed_add_label "$HARNESS_LABEL_WORKING"  fbca04 "An agent session currently owns this issue"
  _seed_add_label "$HARNESS_LABEL_BLOCKED"  b60205 "Blocked — needs another unit or a human"
  _seed_add_label "$HARNESS_LABEL_REVIEWED" 0052cc "PRD verified against acceptance criteria"
  _seed_add_label "$HARNESS_LABEL_COORD"    d4c5f9 "Cross-unit coordination"
}

# ---------------------------------------------------------------------------
# --labels-only <slug> fast path
# Source-safe: `return 0` succeeds when sourced; falls back to `exit 0` when run.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--labels-only" ]]; then
  _SEED_SLUG="${2:?--labels-only requires <owner/repo>}"
  _seed_labels
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Full bootstrap path — requires a unit id
# ---------------------------------------------------------------------------
UNIT_ID="${1:?usage: seed.sh --labels-only <slug> | seed.sh <unit-id>}"
_SEED_SLUG="$(unit_slug "$UNIT_ID")"
[[ -n "$_SEED_SLUG" ]] || die "could not resolve slug for unit: $UNIT_ID"
DESC="$(unit_desc "$UNIT_ID")"

# Create repo only in multi topology (single = project repo already exists).
if [[ "$HARNESS_TOPOLOGY" != single ]]; then
  if gh repo view "$_SEED_SLUG" >/dev/null 2>&1; then
    log "repo exists: $_SEED_SLUG"
  else
    log "creating repo: $_SEED_SLUG"
    gh repo create "$_SEED_SLUG" --private \
      --description "Harness unit ${UNIT_ID} — ${DESC}" \
      --add-readme \
      || die "gh repo create failed for $_SEED_SLUG"
    sleep 2
  fi
fi

# Labels.
_seed_labels

# Language-agnostic CI workflow (unchanged from original).
if ! gh api "repos/$_SEED_SLUG/contents/.github/workflows/ci.yml" >/dev/null 2>&1; then
  log "adding CI workflow to $_SEED_SLUG"
  CI_B64="$(cat <<'YML' | base64 -w0
name: ci
on:
  pull_request:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: run tests (autodetect stack)
        run: |
          set -e
          if   [ -f Cargo.toml ];   then cargo test --all;
          elif [ -f go.mod ];       then go test ./...;
          elif [ -f package.json ]; then npm ci && npm test --if-present;
          elif [ -f gradlew ];      then ./gradlew test;
          elif [ -f pom.xml ];      then mvn -B test;
          elif [ -f pyproject.toml ] || ls tests/*.py >/dev/null 2>&1; then pip install -e . 2>/dev/null || true; pytest -q || [ $? -eq 5 ];
          else echo "no test stack yet — passing"; fi
YML
)"
  gh api --method PUT "repos/$_SEED_SLUG/contents/.github/workflows/ci.yml" \
    -f message="ci: language-autodetect test workflow" -f "content=$CI_B64" >/dev/null 2>&1 \
    || log "warn: could not add CI workflow (continuing)"
fi

# Enable auto-merge + delete merged branches; best-effort branch protection requiring CI.
gh api --method PATCH "repos/$_SEED_SLUG" \
  -F allow_auto_merge=true -F delete_branch_on_merge=true >/dev/null 2>&1 || true
gh api --method PUT "repos/$_SEED_SLUG/branches/main/protection" \
  -F "required_status_checks[strict]=true" \
  -f "required_status_checks[contexts][]=test" \
  -F "enforce_admins=false" \
  -F "required_pull_request_reviews=null" \
  -F "restrictions=null" >/dev/null 2>&1 \
  || log "note: branch protection not set (private/free tier?) — auto-merge will land on mergeable instead of waiting for CI"

log "seeded $_SEED_SLUG"

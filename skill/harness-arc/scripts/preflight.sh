#!/usr/bin/env bash
# Pre-flight before filing an arc's PRDs.  usage: preflight.sh <owner/repo> [repo-dir]
set -uo pipefail
# NOTE: issuelib takes the FULL owner/repo SLUG. Not the bare repo name (gh rejects the
#       format), and not the targets.tsv unit id (gh expands it to <owner>/<unit> and 404s).
REPO_NAME="${1:?usage: preflight.sh <owner/repo> [repo-dir]}"; REPO="${2:-$PWD}"
ENGINE="${HARNESS_ENGINE:-$HOME/.harness/engine/scripts}"
cd "$REPO" || exit 1
set -a; [ -f .harness/config ] && . .harness/config; set +a
export HARNESS_SNAPSHOT_FILE=

echo "── unit state ─────────────────────────────────────────────"
python3 "$ENGINE/issuelib.py" status "$REPO_NAME" || echo "  (issuelib read failed — retry)"
echo "  want: open=0. Any OPEN ready-for-agent child is prior work still in flight."

echo "── dispatcher ─────────────────────────────────────────────"
python3 "$ENGINE/issuelib.py" dispatch "$REPO_NAME" 3 --allow-orchestration 1 || true
echo "  A brand-new PRD must resolve to DECOMPOSE, never REVIEW."
echo "  REVIEW on a fresh PRD = a stale ready-for-agent label on one of ITS closed children,"
echo "  which makes children_exist true, skips DECOMPOSE, and closes the PRD UNWORKED."

echo "── design pushed? ─────────────────────────────────────────"
git fetch -q origin main 2>/dev/null
if [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main 2>/dev/null)" ]; then
  echo "  OK: HEAD == origin/main"
else
  echo "  !! HEAD != origin/main. DECOMPOSE reads origin/main — push the spec and plan FIRST,"
  echo "     or a worker will be tasked with rewriting your audited design."
fi

echo "── stale ready-for-agent on closed issues ─────────────────"
gh issue list -R "${HARNESS_REPO:-$(git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')}" \
  --state closed --label "${HARNESS_LABEL_READY:-ready-for-agent}" --limit 5 \
  --json number,state -q '.[]|"  closed #\(.number) still labelled ready-for-agent"' 2>/dev/null
echo "  (harmless across PRDs — attribution is per-PRD via '## Parent' — but strip any that belong"
echo "   to the PRD you are about to file.)"

echo "── worker pool ────────────────────────────────────────────"
echo "  pool-worker processes: $(pgrep -f pool-worker.sh | wc -l)  (configured pool=${HARNESS_POOL:-?})"
echo "  Count SLOTS not processes — one slot can show several children."

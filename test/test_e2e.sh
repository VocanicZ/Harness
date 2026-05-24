#!/usr/bin/env bash
# test_e2e.sh — offline end-to-end smoke test for the issue-only single-repo decision path.
# gh is fully stubbed; no network required.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export HARNESS_MODE=issue-only HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme

# ── Phase 1: two open ready issues, no PLAN.md ────────────────────────────────
STUB="$(mktemp -d)"; export PATH="$STUB:$PATH"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue list" ]]; then
  echo '[{"number":5,"title":"a","state":"OPEN","labels":[{"name":"ready-for-agent"}],"body":"","author":{"login":"bot"}},
        {"number":6,"title":"b","state":"OPEN","labels":[{"name":"ready-for-agent"}],"body":"","author":{"login":"bot"}}]'
elif [[ "$1 $2" == "api user" ]]; then echo "bot"   # authenticated self
elif [[ "$1" == "api" ]]; then exit 1   # no PLAN.md
else echo '{}'; fi
EOF
chmod +x "$STUB/gh"

out="$(python3 "$HERE/../scripts/issuelib.py" dispatch acme/widget 3 --allow-orchestration 1)"

# TAB-correct greps using ANSI-C $'...' quoting so \t is a real tab character
echo "$out" | grep -q $'^IMPL\t5' && echo "  ok: dispatch IMPL #5" || { echo "FAIL: did not find IMPL<TAB>5 in output: $out"; exit 1; }
echo "$out" | grep -q $'^IMPL\t6' && echo "  ok: dispatch IMPL #6" || { echo "FAIL: did not find IMPL<TAB>6 in output: $out"; exit 1; }
echo "$out" | grep -qE '^(PLAN|PRD|DECOMPOSE)' && { echo "FAIL: issue-only emitted orchestration: $out"; exit 1; } || echo "  ok: no orchestration in issue-only"

# ── Phase 2: both issues closed → complete ────────────────────────────────────
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue list" ]]; then
  echo '[{"number":5,"title":"a","state":"CLOSED","labels":[{"name":"ready-for-agent"}],"body":"","author":{"login":"bot"}},
        {"number":6,"title":"b","state":"CLOSED","labels":[{"name":"ready-for-agent"}],"body":"","author":{"login":"bot"}}]'
elif [[ "$1 $2" == "api user" ]]; then echo "bot"
elif [[ "$1" == "api" ]]; then exit 1; else echo '{}'; fi
EOF
chmod +x "$STUB/gh"

result="$(python3 "$HERE/../scripts/issuelib.py" complete acme/widget)"
[[ "$result" == "DONE" ]] && echo "  ok: complete when all closed" || { echo "FAIL: expected DONE, got: $result"; exit 1; }

echo "── e2e ok"

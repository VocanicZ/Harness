#!/usr/bin/env bash
# test_security_audit.sh — opt-in security audit at PRD review (HARNESS_SECURITY_AUDIT, default off).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/drive.sh"
source "$HERE/helpers.sh"
make_env
SLUG=acme/widget

echo "=== config defaults ==="
assert_eq "$(env -u HARNESS_SECURITY_AUDIT bash -c "source '$ROOT/scripts/lib.sh'; echo \$HARNESS_SECURITY_AUDIT")" "0" \
  "HARNESS_SECURITY_AUDIT defaults to 0 (off)"
assert_eq "$(env -u HARNESS_SECURITY_AUDIT_ROUNDS bash -c "source '$ROOT/scripts/lib.sh'; echo \$HARNESS_SECURITY_AUDIT_ROUNDS")" "2" \
  "HARNESS_SECURITY_AUDIT_ROUNDS defaults to 2"

echo "=== security_audit_round counts only the fleet's own markers ==="
FIXTURE="$RUN_DIR/prd-comments.json"
gh(){
  case "$1 $2" in
    "api user") echo "fleet-bot";;
    "issue view") local q=""; while (($#)); do [[ "$1" == -q ]] && { q="$2"; break; }; shift; done
                  jq -r "$q" "$FIXTURE";;
  esac; }
cat > "$FIXTURE" <<'EOF'
{"comments":[
 {"author":{"login":"fleet-bot"},"body":"<!-- harness-security-audit round=1 -->\nSecurity audit round 1: 2 findings filed."},
 {"author":{"login":"mallory"},"body":"<!-- harness-security-audit round=2 -->"},
 {"author":{"login":"mallory"},"body":"<!-- harness-security-audit round=3 -->"},
 {"author":{"login":"fleet-bot"},"body":"<!-- harness-gauntlet round=1 -->"}
]}
EOF
assert_eq "$(security_audit_round 7)" "2" "one fleet audit marker -> round 2; outsider + gauntlet markers ignored"

echo "=== spawn_orch REVIEW render vars ==="
UNIT=main; PROJECT=main; DESC=widget; CHECKOUT="$(mktemp -d)"; HARNESS_TOPOLOGY=single
CALLS="$RUN_DIR/calls"
render(){ echo "render $*" >> "$CALLS"; }
launch_claude(){ :; }; default_branch(){ echo main; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }; remove_worktree(){ :; }
git(){ local a; case "$*" in *"worktree add"*) for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && mkdir -p "$a"; done;; esac; return 0; }

: > "$CALLS"; HARNESS_SECURITY_AUDIT=1 HARNESS_SECURITY_AUDIT_ROUNDS=2 spawn_orch REVIEW 7 "REVIEW DONE" >/dev/null 2>&1
assert_ok "SECURITY_AUDIT=1 passed through" grep -q "SECURITY_AUDIT=1 " "$CALLS"
assert_ok "SECURITY_AUDIT_ROUNDS passed through" grep -q "SECURITY_AUDIT_ROUNDS=2" "$CALLS"
assert_ok "SECURITY_AUDIT_ROUND computed from fleet markers" grep -q "SECURITY_AUDIT_ROUND=2" "$CALLS"
assert_ok "SECURITY_AUDIT_DIR is PRD-scoped under STATE_DIR" grep -q "SECURITY_AUDIT_DIR=$STATE_DIR/security-audit/main/p7" "$CALLS"
assert_ok "SECURITY_AUDIT_SKILL points at the vendored skill in the engine" \
  grep -q "SECURITY_AUDIT_SKILL=$ENGINE_DIR/vendor/security-audit/SKILL.md" "$CALLS"

: > "$CALLS"; HARNESS_SECURITY_AUDIT=0 spawn_orch REVIEW 7 "REVIEW DONE" >/dev/null 2>&1
assert_ok "disabled fleet renders SECURITY_AUDIT=0" grep -q "SECURITY_AUDIT=0 " "$CALLS"

echo "=== review.md ==="
unset -f render; source "$ROOT/scripts/lib.sh" >/dev/null 2>&1   # the real render
r(){ render "$ROOT/prompts/review.md" PRD=7 SLUG=acme/widget PROMISE="REVIEW DONE" LABEL_READY=ready-for-agent \
  LABEL_REVIEWED=reviewed GAUNTLET_DIR=/g GAUNTLET_ROUND=1 GAUNTLET_ROUNDS=3 \
  SECURITY_AUDIT="$1" SECURITY_AUDIT_ROUND=2 SECURITY_AUDIT_ROUNDS=2 SECURITY_AUDIT_DIR=/s/p7 \
  SECURITY_AUDIT_SKILL=/engine/vendor/security-audit/SKILL.md; }
out="$(r 1)"
assert_no "no unrendered {{SECURITY_AUDIT token" grep -q "{{SECURITY_AUDIT" <<<"$out"
line(){ grep -n "$1" <<<"$out" | head -1 | cut -d: -f1; }
assert_ok "phase order: criteria < security audit < gauntlet" \
  test "$(line 'PHASE 1')" -lt "$(line 'PHASE 2 — SECURITY AUDIT')" -a "$(line 'PHASE 2 — SECURITY AUDIT')" -lt "$(line 'PHASE 3 — GAUNTLET')"
assert_ok "names the vendored skill path" grep -q "/engine/vendor/security-audit/SKILL.md" <<<"$out"
assert_ok "audit output dir rendered" grep -q "/s/p7" <<<"$out"
assert_ok "round/cap rendered" grep -q "round 2 of 2" <<<"$out"
assert_ok "lost round writes the audit marker at the start of the comment" \
  grep -q -- '--body "<!-- harness-security-audit round=2 -->' <<<"$out"
assert_ok "enabled flag is visible to the reviewer" grep -q "Security audit: 1" <<<"$out"
assert_ok "prompt says the phase is skipped when the flag is 0" grep -qi "is 0.*skip" <<<"$out"

echo "=== vendored skill ==="
for f in SKILL.md HUNTING.md RECONNAISSANCE.md VALIDATION-AND-REPORTING.md ATTACK-CLASSES.md report-schema.json \
         validate-findings.cjs validate-coverage-ledger.cjs; do
  assert_ok "vendor/security-audit/$f present" test -f "$ROOT/vendor/security-audit/$f"
done

finish

#!/usr/bin/env bash
# test_claude_launch_dialogs.sh — #660: a lean Claude lane (--setting-sources project,local) must not stop at
# the two launch dialogs nothing answers.
#   1. Bypass Permissions mode: the "accepted" bit (skipDangerousModePermissionPrompt) lives in the user
#      settings, which a lean lane no longer reads, so claude_bypass writes it into <wd>/.claude/settings.local.json.
#   2. "Allow external CLAUDE.md file imports?": the workspace pre-accept also marks the warning as shown (never
#      as approved), under the lane dir AND, for a linked worktree, the main checkout Claude Code keys it by.
#   3. Both dialogs' panes are dialogs, not prompts (fixtures captured from the issue).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
make_env
export HARNESS_CLI=claude HARNESS_AUTONOMOUS=true
FIX="$HERE/fixtures/cli/claude"

jget(){ python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d.get(k, "<absent>") if isinstance(d, dict) else "<absent>"
print(d)' "$@" 2>/dev/null; }
mkrepo(){ git init -q "$1"; git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base; }

echo "=== bypass: the dialog's accepted bit goes into settings.local.json ==="
WD="$RUN_DIR/bp"; mkrepo "$WD"
ensure_bypass "$WD"
SL="$WD/.claude/settings.local.json"
assert_eq "$(jget "$SL" skipDangerousModePermissionPrompt)" "True" "claude_bypass writes skipDangerousModePermissionPrompt: true"
assert_eq "$(jget "$SL" permissions defaultMode)" "bypassPermissions" "…beside permissions.defaultMode"
assert_ok "claude_bypassed holds with both" cli_bypassed "$WD"
python3 - "$SL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); del d["skipDangerousModePermissionPrompt"]; json.dump(d, open(sys.argv[1], "w"))
PY
assert_no "claude_bypassed fails when the skip key is missing" cli_bypassed "$WD"
ensure_bypass "$WD"
assert_ok "ensure_bypass puts it back" cli_bypassed "$WD"

echo "=== bypass: an existing settings.local.json keeps its other keys ==="
WD2="$RUN_DIR/bp2"; mkrepo "$WD2"; mkdir -p "$WD2/.claude"
echo '{"statusLine":{"x":1},"permissions":{"allow":["Bash(ls)"]}}' > "$WD2/.claude/settings.local.json"
ensure_bypass "$WD2"
assert_eq "$(jget "$WD2/.claude/settings.local.json" statusLine x)" "1" "unrelated key survives"
assert_eq "$(jget "$WD2/.claude/settings.local.json" skipDangerousModePermissionPrompt)" "True" "skip key added"

echo "=== workspace pre-accept: trust + imports-warning-shown, under the lane dir and its main checkout ==="
CFG="$RUN_DIR/cfg.json"; export HARNESS_CLAUDE_CONFIG="$CFG"
MAIN="$RUN_DIR/main"; mkrepo "$MAIN"; LANE="$RUN_DIR/lane"; git -C "$MAIN" worktree add -q -b lane "$LANE"
python3 - "$CFG" "$MAIN" <<'PY'
import json, sys
json.dump({"userID": "keep", "projects": {"/other": {"hasTrustDialogAccepted": True, "lastCost": 2}, sys.argv[2]: {"allowedTools": ["Bash"]}}}, open(sys.argv[1], "w"))
PY
ensure_trusted "$LANE"
entry(){ python3 -c 'import json,sys
p = json.load(open(sys.argv[1]))["projects"].get(sys.argv[2], {}); print(p.get(sys.argv[3], "<absent>"))' "$CFG" "$1" "$2"; }
MAINREAL="$(git -C "$LANE" rev-parse --path-format=absolute --git-common-dir)"; MAINREAL="${MAINREAL%/.git}"
for d in "$LANE" "$MAINREAL"; do
  assert_eq "$(entry "$d" hasTrustDialogAccepted)" "True" "trusted: $d"
  assert_eq "$(entry "$d" hasClaudeMdExternalIncludesWarningShown)" "True" "imports warning shown: $d"
  assert_eq "$(entry "$d" hasClaudeMdExternalIncludesApproved)" "<absent>" "imports never approved: $d"
done
assert_eq "$(entry "$MAINREAL" allowedTools)" "['Bash']" "the main checkout's existing fields survive"
assert_eq "$(entry /other lastCost)" "2" "another project's entry survives"
assert_eq "$(jget "$CFG" userID)" "keep" "top-level keys survive"
assert_ok "claude_trusted holds for the lane" cli_trusted "$LANE"
python3 - "$CFG" "$LANE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); del d["projects"][sys.argv[2]]["hasClaudeMdExternalIncludesWarningShown"]; json.dump(d, open(sys.argv[1], "w"))
PY
assert_no "claude_trusted fails without the imports-warning flag" cli_trusted "$LANE"

echo "=== an existing imports answer is kept ==="
python3 - "$CFG" "$MAINREAL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["projects"][sys.argv[2]]["hasClaudeMdExternalIncludesApproved"] = True; json.dump(d, open(sys.argv[1], "w"))
PY
ensure_trusted "$LANE"
assert_eq "$(entry "$MAINREAL" hasClaudeMdExternalIncludesApproved)" "True" "Approved: true stays"
python3 - "$CFG" "$MAINREAL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["projects"][sys.argv[2]]["hasClaudeMdExternalIncludesApproved"] = False; json.dump(d, open(sys.argv[1], "w"))
PY
ensure_trusted "$LANE"
assert_eq "$(entry "$MAINREAL" hasClaudeMdExternalIncludesApproved)" "False" "Approved: false stays"

echo "=== a plain (non-worktree) dir gets only its own entry ==="
PLAIN="$RUN_DIR/plain"; mkrepo "$PLAIN"; ensure_trusted "$PLAIN"
assert_eq "$(entry "$PLAIN" hasClaudeMdExternalIncludesWarningShown)" "True" "plain repo: warning shown"

echo "=== fixtures: both launch dialogs are dialogs, never a prompt ==="
for f in bypass-dialog imports-dialog; do
  assert_ok "$f: cli_pane_dialog" cli_pane_dialog "$(cat "$FIX/$f.txt")"
  assert_no "$f: not cli_pane_prompt" cli_pane_prompt "$(cat "$FIX/$f.txt")"
done
finish

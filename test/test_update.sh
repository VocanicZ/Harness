#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fake .harness checkout with user config + a git stub that no-ops the pull
TMP="$(mktemp -d)"; HD="$TMP/.harness"; mkdir -p "$HD/skill" "$TMP/.claude"
cp "$HERE/../update.sh" "$HD/update.sh"
cp "$HERE/../lib.sh" "$HD/lib.sh"
printf 'name: harness\ndescription: x\n' > "$HD/skill/SKILL.md"
# user config with a CUSTOM value that MUST survive
printf ': "${HARNESS_MODE:=prd}"\n: "${HARNESS_REPO:=acme/widget}"\n' > "$HD/config"
printf 'a\tacme/a\t-\troot\n' > "$HD/targets.tsv"
cp "$HD/config" "$TMP/cfg_before"; cp "$HD/targets.tsv" "$TMP/tsv_before"
# git stub: pull --ff-only succeeds (no-op); anything else no-ops
git(){ case "$*" in *"pull --ff-only"*) return 0;; *) return 0;; esac; }
export -f git
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
( cd "$TMP" && HARNESS_DIR="$HD" bash "$HD/update.sh" >/dev/null 2>&1 )
assert "config byte-identical after update"   "cmp -s '$TMP/cfg_before' '$HD/config'"
assert "targets.tsv byte-identical after update" "cmp -s '$TMP/tsv_before' '$HD/targets.tsv'"
assert "skill redeployed"                      "[[ -f '$TMP/.claude/skills/harness/SKILL.md' ]]"
assert "update.sh has no git clean"            "! grep -qE 'git +clean' '$HD/update.sh'"
assert "update.sh has no git reset --hard"     "! grep -qE 'reset +--hard' '$HD/update.sh'"
assert "update.sh has no git checkout -f"      "! grep -qE 'checkout +-f' '$HD/update.sh'"
rm -rf "$TMP"
echo "── update ok"

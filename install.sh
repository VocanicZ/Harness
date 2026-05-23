#!/usr/bin/env bash
set -uo pipefail
HARNESS_REPO_URL="${HARNESS_REPO_URL:-https://github.com/VocanicZ/Harness.git}"
HARNESS_MARKETPLACE="${HARNESS_MARKETPLACE:-anthropics/claude-plugins-official}"
HARNESS_MARKETPLACE_NAME="${HARNESS_MARKETPLACE_NAME:-claude-plugins-official}"
MATTPOCOCK_SKILLS_URL="${MATTPOCOCK_SKILLS_URL:-https://github.com/mattpocock/skills.git}"

need(){ command -v "$1" >/dev/null 2>&1; }
check_prereqs(){
  local ok=1
  for b in git tmux python3; do need "$b" || { echo "MISSING: $b" >&2; ok=0; }; done
  if ! need gh; then echo "MISSING: gh (install: https://cli.github.com)" >&2; ok=0
  elif ! gh auth status >/dev/null 2>&1; then echo "gh not authenticated — run: gh auth login" >&2; ok=0; fi
  if ! need claude; then echo "MISSING: claude (Claude Code CLI)" >&2; ok=0
  elif ! claude --version >/dev/null 2>&1; then echo "claude present but not runnable (model configured?)" >&2; ok=0; fi
  [[ "$ok" == 1 ]]
}

_plugin_installed(){  # $1 = name@marketplace
  local f="$HOME/.claude/plugins/installed_plugins.json"
  [[ -f "$f" ]] && python3 -c "import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if sys.argv[2] in d.get('plugins',{}) else 1)" "$f" "$1" 2>/dev/null
}
_ensure_plugin(){  # $1 = plugin name
  local ref="$1@$HARNESS_MARKETPLACE_NAME"
  if _plugin_installed "$ref"; then echo "  ✓ plugin $ref already installed"; return 0; fi
  echo "  installing plugin $ref ..."
  claude plugin install "$ref" --scope user >/dev/null 2>&1 \
    && echo "  ✓ installed $ref" \
    || echo "  ! could not install $ref — install manually: claude plugin install $ref"
}
ensure_skills(){
  echo "ensuring required Claude plugins + skills (best-effort) ..."
  if need claude; then
    claude plugin marketplace add "$HARNESS_MARKETPLACE" >/dev/null 2>&1 || true
    _ensure_plugin superpowers
    _ensure_plugin ralph-loop
    find "$HOME/.claude/plugins/cache" -path '*/ralph-loop/*/hooks/*.sh' -exec chmod +x {} \; 2>/dev/null || true
  else
    echo "  ! 'claude' CLI not found — install superpowers + ralph-loop plugins manually"
  fi
  local sk="$HOME/.claude/skills"
  if [[ -d "$sk/to-prd" && -d "$sk/to-issues" ]]; then
    echo "  ✓ matt-pocock skills (to-prd/to-issues) already present"
  else
    local tmp; tmp="$(mktemp -d)"
    if git clone --depth 1 "$MATTPOCOCK_SKILLS_URL" "$tmp" >/dev/null 2>&1; then
      mkdir -p "$sk"; local f d
      # portable (no GNU find -printf): copy the parent dir of every SKILL.md
      while IFS= read -r f; do d="$(dirname "$f")"; cp -r "$d" "$sk/" 2>/dev/null || true; done \
        < <(find "$tmp" -type f -name SKILL.md 2>/dev/null)
      if [[ -d "$sk/to-prd" || -d "$sk/to-issues" ]]; then
        echo "  ✓ installed matt-pocock skills into $sk"
      else
        echo "  ! cloned $MATTPOCOCK_SKILLS_URL but found no skills to copy — install to-prd/to-issues manually"
      fi
    else
      echo "  ! could not clone $MATTPOCOCK_SKILLS_URL — install to-prd/to-issues manually"
    fi
    rm -rf "$tmp"
  fi
  return 0
}
main(){
  check_prereqs || { echo "Prerequisites unmet — fix the above and re-run." >&2; exit 1; }
  ensure_skills
  if [[ -d .harness/.git ]]; then git -C .harness pull --ff-only; else git clone "$HARNESS_REPO_URL" .harness; fi
  mkdir -p .claude/skills/harness && cp .harness/skill/SKILL.md .claude/skills/harness/SKILL.md
  # per-command thin skills (/harness-init, /harness-start, …) live in skill/<name>/SKILL.md
  for d in .harness/skill/*/; do
    [[ -f "$d/SKILL.md" ]] || continue
    n="$(basename "$d")"; mkdir -p ".claude/skills/$n" && cp "$d/SKILL.md" ".claude/skills/$n/SKILL.md"
  done
  grep -qxF '.harness/' .gitignore 2>/dev/null || echo '.harness/' >> .gitignore
  bash .harness/init.sh
  echo "Done. Start with: .harness/bin/harness start   (or ask Claude: /harness)"
}
[[ "${HARNESS_INSTALL_NOMAIN:-0}" == 1 ]] || main "$@"

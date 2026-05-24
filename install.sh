#!/usr/bin/env bash
# install.sh — install the engine ONCE per host (#54, PRD #52). The engine (all code/assets) lives
# at a single host location, $HARNESS_HOME/engine, and `harness` is symlinked onto PATH. Projects
# never get their own engine copy; per-project config + state live in <project>/.harness/ (created
# by `harness init`). `harness update` ff-pulls only this one shared install.
set -uo pipefail
HARNESS_REPO_URL="${HARNESS_REPO_URL:-https://github.com/VocanicZ/Harness.git}"
HARNESS_HOME="${HARNESS_HOME:-$HOME/.harness}"           # host root for the shared engine (+ PRD-B subdirs)
HARNESS_BIN_DIR="${HARNESS_BIN_DIR:-$HOME/.local/bin}"   # where the `harness` PATH symlink is placed
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
# place_engine — clone/place the engine at the SINGLE host location $HARNESS_HOME/engine (never into
# a project's ./.harness/). Idempotent: an existing install is fast-forwarded, not re-cloned.
place_engine(){
  local home="${HARNESS_HOME:-$HOME/.harness}" dest
  dest="$home/engine"
  mkdir -p "$home"
  if [[ -d "$dest/.git" ]]; then
    echo "  engine already present at $dest — fast-forwarding"
    git -C "$dest" pull --ff-only || echo "  ! could not ff-pull $dest (diverged?) — leaving as-is" >&2
  else
    echo "  installing engine to $dest ..."
    git clone "$HARNESS_REPO_URL" "$dest"
  fi
}

# print_path_instructions — portability fallback when the PATH symlink can't be written: tell the
# user exactly how to put the engine's bin/ on PATH themselves.
print_path_instructions(){
  local target="$1" dir; dir="$(dirname "$target")"
  cat >&2 <<EOF
  ! could not create the 'harness' symlink (${HARNESS_BIN_DIR:-$HOME/.local/bin} not writable).
    Put the engine on your PATH manually instead:
        export PATH="$dir:\$PATH"
    (add that line to ~/.bashrc or ~/.zshrc, then re-open your shell)
EOF
}

# link_path — symlink `harness` onto PATH ($HARNESS_BIN_DIR/harness → engine/bin/harness). ENGINE_DIR
# resolves via realpath of the entrypoint's OWN path (bin/harness), so the symlink runs the real
# engine. If the link can't be written, fall back to printing explicit PATH instructions.
link_path(){
  local home="${HARNESS_HOME:-$HOME/.harness}" bindir="${HARNESS_BIN_DIR:-$HOME/.local/bin}"
  local target="$home/engine/bin/harness" link="$bindir/harness"
  mkdir -p "$bindir" 2>/dev/null
  if ln -sfn "$target" "$link" 2>/dev/null; then
    echo "  linked $link -> $target"
    case ":$PATH:" in
      *":$bindir:"*) ;;
      *) echo "  NOTE: $bindir is not on your PATH yet. Add it:"
         echo "        export PATH=\"$bindir:\$PATH\"  # add to ~/.bashrc or ~/.zshrc" ;;
    esac
  else
    print_path_instructions "$target"
  fi
}

main(){
  check_prereqs || { echo "Prerequisites unmet — fix the above and re-run." >&2; exit 1; }
  ensure_skills
  place_engine
  link_path
  cat <<EOF
Done. The engine is installed once at $HARNESS_HOME/engine and linked as 'harness'.
Next: cd into a project and run  harness init   (creates that project's .harness/ config + state).
EOF
}
[[ "${HARNESS_INSTALL_NOMAIN:-0}" == 1 ]] || main "$@"

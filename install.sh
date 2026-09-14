#!/usr/bin/env bash
# install.sh — install the engine ONCE per host (#54, PRD #52). The engine (all code/assets) lives
# at a single host location, $HARNESS_HOME/engine, and `harness` is symlinked onto PATH. Projects
# never get their own engine copy; per-project config + state live in <project>/.harness/ (created
# by `harness init`). `harness update` ff-pulls only this one shared install.
set -uo pipefail
HARNESS_REPO_URL="${HARNESS_REPO_URL:-https://github.com/VocanicZ/Harness.git}"
HARNESS_HOME="${HARNESS_HOME:-${HOME:-}/.harness}"           # host root for the shared engine (+ PRD-B subdirs)
HARNESS_BIN_DIR="${HARNESS_BIN_DIR:-${HOME:-}/.local/bin}"   # where the `harness` PATH symlink is placed
HARNESS_MARKETPLACE="${HARNESS_MARKETPLACE:-anthropics/claude-plugins-official}"
HARNESS_MARKETPLACE_NAME="${HARNESS_MARKETPLACE_NAME:-claude-plugins-official}"
MATTPOCOCK_SKILLS_URL="${MATTPOCOCK_SKILLS_URL:-https://github.com/mattpocock/skills.git}"
VOCANICZ_TOOLS_URL="${VOCANICZ_TOOLS_URL:-https://github.com/VocanicZ/vocanicz-ai-tools.git}"
RTDD_INSTALL_SPEC="${RTDD_INSTALL_SPEC:-github:VocanicZ/rtdd}"   # upstream's own installer, run via npx

need(){ command -v "$1" >/dev/null 2>&1; }
check_prereqs(){
  local ok=1
  for b in git tmux python3; do need "$b" || { echo "MISSING: $b" >&2; ok=0; }; done
  if ! need gh; then echo "MISSING: gh (install: https://cli.github.com)" >&2; ok=0
  elif ! gh auth status >/dev/null 2>&1; then echo "gh not authenticated — run: gh auth login" >&2; ok=0; fi
  if ! need claude && ! need agy; then echo "MISSING: claude or agy (install Claude Code CLI or Antigravity CLI)" >&2; ok=0
  elif need claude && ! claude --version >/dev/null 2>&1; then echo "claude present but not runnable (model configured?)" >&2; ok=0
  elif need agy && ! agy --version >/dev/null 2>&1; then echo "agy present but not runnable" >&2; ok=0; fi
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
_agy_plugin_installed(){
  agy plugin list 2>/dev/null | grep -q "\"$1\""
}
_ensure_agy_plugin(){
  local name="$1" dir="$2"
  if _agy_plugin_installed "$name"; then echo "  ✓ agy plugin $name already installed"; return 0; fi
  if [[ -d "$dir" ]]; then
    echo "  installing agy plugin $name ..."
    agy plugin install "$dir" >/dev/null 2>&1 \
      && echo "  ✓ installed agy plugin $name" \
      || echo "  ! could not install agy plugin $name — install manually: agy plugin install $dir"
  fi
}
# ensure_rtdd — install the coverage-derived test selector the IMPL/bug-fix/resume prompts use AS
# their test loop, in place of two full-suite runs per lane. Its own function because BOTH entry
# points need it: an engine ff-pulled by `harness update` brings prompts that call `rtdd`, and a host
# that only ever ran install.sh before would otherwise have the prompts without the binary. Install
# is best-effort (a host without curl still gets a working engine); a lane without rtdd falls all the
# way back to the old full-suite bar, which is the cost this replaces.
ensure_rtdd(){
  [[ "${HARNESS_SKIP_RTDD:-0}" == 1 ]] && return 0   # tests set this: ensure_rtdd must never network
  if need rtdd; then
    echo "  ✓ rtdd already installed ($(command -v rtdd))"
    return 0
  fi
  # Upstream's documented install is `npx github:VocanicZ/rtdd` — a Node installer that resolves the
  # right release asset for this platform and verifies it against the release checksums, then also
  # installs rtdd's agent skill for the agent CLIs present on this host (~/.claude/skills/rtdd and
  # friends). That machine-wide skill write is why the prompts can say "the `rtdd` skill"; it is also
  # the broadest thing this line does, so it is named here rather than left as a surprise.
  # Deliberately NOT `curl <url> | sh`: a piped stream executes whatever arrived, so a connection
  # dropped mid-transfer runs a TRUNCATED script, and the URL would be an overridable input to a
  # shell. This runs third-party code either way — the same trust this installer already asks for.
  if ! need npx; then
    echo "  ! npx not found — skipping rtdd install; lanes fall back to full-suite runs."
    echo "    Install it later with:  npx $RTDD_INSTALL_SPEC"
    return 0
  fi
  echo "  installing rtdd (npx $RTDD_INSTALL_SPEC) ..."
  # timeout + GIT_TERMINAL_PROMPT=0: npm's fetch timeout is 300s with retries, and a `github:` spec
  # git-clones — a credential prompt goes to /dev/tty and would hang `harness update` FOREVER,
  # redirections notwithstanding. stderr is kept on the failure path: a CHECKSUM MISMATCH is the one
  # signal from that installer worth reading, and discarding it was hiding it behind a generic line.
  local rtdd_log; rtdd_log="$(mktemp)"
  if timeout "${RTDD_INSTALL_TIMEOUT:-300}" env GIT_TERMINAL_PROMPT=0 npx -y "$RTDD_INSTALL_SPEC" \
       >"$rtdd_log" 2>&1 && need rtdd; then
    echo "  ✓ installed rtdd"
  elif [[ -x "${HOME:-}/.local/bin/rtdd" || -x /usr/local/bin/rtdd ]]; then
    # It installed; it just is not on THIS shell's PATH (nvm/volta prefixes, a non-login shell).
    # Saying "did not complete" here would also re-run the whole install on every future update.
    echo "  ✓ installed rtdd, but it is not on your PATH — add its directory to PATH"
  else
    echo "  ! rtdd install did not complete — lanes fall back to full-suite runs; retry: npx $RTDD_INSTALL_SPEC"
    sed -n '$p' "$rtdd_log" 2>/dev/null | sed 's/^/    /'
  fi
  rm -f "$rtdd_log"
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
  if need agy; then
    echo "ensuring required Antigravity plugins + skills (best-effort) ..."
    local agy_plugin_dir="${HARNESS_HOME:-$HOME/.harness}/engine/plugins/ralph-loop"
    [[ -d "$agy_plugin_dir" ]] || agy_plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plugins/ralph-loop"
    _ensure_agy_plugin harness-ralph "$agy_plugin_dir"
  fi
  local sk="$HOME/.claude/skills"
  if [[ -d "$sk/to-prd" && -d "$sk/to-issues" ]]; then
    echo "  ✓ matt-pocock skills (to-prd/to-issues) already present"
  else
    local tmp; tmp="$(mktemp -d)"
    if git clone --depth 1 "$MATTPOCOCK_SKILLS_URL" "$tmp" >/dev/null 2>&1; then
      mkdir -p "$sk"; local want src
      # Copy ONLY the intended skills (the ones the guard above checks) — NOT every SKILL.md parent
      # dir in the clone. Copying everything would clobber a user's pre-existing same-named skill and
      # pull in skills never requested. Locate each wanted skill's dir by its SKILL.md (any depth).
      for want in to-prd to-issues; do
        [[ -d "$sk/$want" ]] && continue   # don't overwrite an existing same-named user skill
        src="$(find "$tmp" -type f -name SKILL.md -path "*/$want/SKILL.md" 2>/dev/null | head -n1)"
        [[ -n "$src" ]] && cp -r "$(dirname "$src")" "$sk/" 2>/dev/null || true
      done
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
  # vocanicz-ai-tools: the subagent-task-tree skill (best-effort, never clobbers a user skill).
  if [[ -d "$sk/subagent-task-tree" ]]; then
    echo "  ✓ subagent-task-tree skill already present"
  else
    local vtmp; vtmp="$(mktemp -d)"
    if git clone --depth 1 "$VOCANICZ_TOOLS_URL" "$vtmp" >/dev/null 2>&1; then
      local vsrc
      vsrc="$(find "$vtmp" -type f -name SKILL.md -path "*/subagent-task-tree/SKILL.md" 2>/dev/null | head -n1)"
      if [[ -n "$vsrc" ]]; then
        mkdir -p "$sk"; cp -r "$(dirname "$vsrc")" "$sk/" 2>/dev/null \
          && echo "  ✓ installed subagent-task-tree skill into $sk" \
          || echo "  ! could not copy subagent-task-tree skill — install it manually"
      else
        echo "  ! cloned $VOCANICZ_TOOLS_URL but found no subagent-task-tree skill — install manually"
      fi
    else
      echo "  ! could not clone $VOCANICZ_TOOLS_URL — install subagent-task-tree skill manually"
    fi
    rm -rf "$vtmp"
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
    # Surface a failed ff-pull as a NON-zero return (consistent with update.sh, which exit 1s on the
    # same failure) instead of swallowing it — otherwise a diverged/dirty shared engine silently
    # stays stale for ALL fleets while install still reports success.
    if ! git -C "$dest" pull --ff-only; then
      echo "  ! could not ff-pull $dest (diverged or local engine edits) — resolve there manually." >&2
      return 1
    fi
  else
    echo "  installing engine to $dest ..."
    git clone "$HARNESS_REPO_URL" "$dest"
  fi
}

# create_host_root — establish the ~/.harness host ROOT with the poller/ and snapshots/ subdirs
# (#57, PRD #52). PRD-B (#69) populates them: the host poller writes its registry + pidfile under
# poller/ and per-repo snapshot JSON under snapshots/ (opt-in per fleet via HARNESS_USE_POLLER).
# Install just creates the dirs so the host layout is stable. Idempotent (mkdir -p is a no-op).
create_host_root(){
  local home="${HARNESS_HOME:-$HOME/.harness}"
  mkdir -p "$home/poller" "$home/snapshots"
}

# install_harness_skills — deploy the engine's OWN /harness operator skills to USER scope
# (~/.claude/skills) ONCE per host, not vendored per project (#57, PRD #52). Source is the shared
# engine's skill/ dir (place_engine runs first in main); the umbrella skill/SKILL.md → harness/, and
# each per-command skill/<name>/SKILL.md → <name>/. Best-effort: a missing source warns, never fails.
install_harness_skills(){
  local src="${HARNESS_SKILL_SRC:-${HARNESS_HOME:-$HOME/.harness}/engine/skill}"
  local dst="${HARNESS_USER_SKILLS:-$HOME/.claude/skills}"
  if [[ ! -d "$src" ]]; then
    echo "  ! engine skill/ not found at $src — install /harness skills manually" >&2; return 0
  fi
  mkdir -p "$dst"
  local n=0 d
  if [[ -f "$src/SKILL.md" ]]; then
    mkdir -p "$dst/harness"; cp "$src/SKILL.md" "$dst/harness/SKILL.md" && n=$((n+1))
  fi
  for d in "$src"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue
    mkdir -p "$dst/$(basename "$d")"; cp "$d/SKILL.md" "$dst/$(basename "$d")/SKILL.md" && n=$((n+1))
  done
  echo "  ✓ installed $n /harness skill(s) into $dst (user scope)"
  if [[ -z "${HARNESS_USER_SKILLS:-}" || -n "${HARNESS_AGY_USER_SKILLS:-}" ]]; then
    local agy_dst="${HARNESS_AGY_USER_SKILLS:-$HOME/.gemini/config/skills}"
    if need agy || [[ -d "$HOME/.gemini" ]]; then
      mkdir -p "$agy_dst"
      if [[ -f "$src/SKILL.md" ]]; then
        mkdir -p "$agy_dst/harness"; cp "$src/SKILL.md" "$agy_dst/harness/SKILL.md"
      fi
      for d in "$src"/*/; do
        [[ -f "$d/SKILL.md" ]] || continue
        mkdir -p "$agy_dst/$(basename "$d")"; cp "$d/SKILL.md" "$agy_dst/$(basename "$d")/SKILL.md"
      done
      echo "  ✓ installed $n /harness skill(s) into $agy_dst (agy user scope)"
    fi
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
  ensure_rtdd
  place_engine || { echo "Engine install/update failed — see above; not finalizing." >&2; exit 1; }
  create_host_root          # ~/.harness/{poller,snapshots}/ — host-poller dirs (PRD-B, #69)
  install_harness_skills    # /harness operator skills → ~/.claude/skills (user scope, once)
  link_path
  cat <<EOF
Done. The engine is installed once at $HARNESS_HOME/engine and linked as 'harness'.
Next: cd into a project and run  harness init   (creates that project's .harness/ config + state).
EOF
}
[[ "${HARNESS_INSTALL_NOMAIN:-0}" == 1 ]] || main "$@"

#!/usr/bin/env bash
# install.sh — install the engine ONCE per host (#54, PRD #52). The engine (all code/assets) lives
# at a single host location, $HARNESS_HOME/engine, and `harness` is symlinked onto PATH. Projects
# never get their own engine copy; per-project config + state live in <project>/.harness/ (created
# by `harness init`). `harness update` ff-pulls only this one shared install.
set -uo pipefail
HARNESS_REPO_URL="${HARNESS_REPO_URL:-https://github.com/VocanicZ/Harness.git}"
HARNESS_HOME="${HARNESS_HOME:-${HOME:-}/.harness}"           # host root for the shared engine (+ PRD-B subdirs)
HARNESS_BIN_DIR="${HARNESS_BIN_DIR:-${HOME:-}/.local/bin}"   # where the `harness` PATH symlink is placed
MATTPOCOCK_SKILLS_URL="${MATTPOCOCK_SKILLS_URL:-https://github.com/mattpocock/skills.git}"
VOCANICZ_TOOLS_URL="${VOCANICZ_TOOLS_URL:-https://github.com/VocanicZ/vocanicz-ai-tools.git}"
RTDD_INSTALL_SPEC="${RTDD_INSTALL_SPEC:-github:VocanicZ/rtdd}"   # upstream's own installer, run via npx

need(){ command -v "$1" >/dev/null 2>&1; }
# _load_cli_seam — source the agent CLI adapters (scripts/cli/dispatch.sh, #188): every CLI fact —
# binary, plugins, skills dir — is the adapter's, never this file's. This checkout's copy when
# install.sh runs from one, else the placed engine's (a piped install has no checkout to read).
_load_cli_seam(){ local d
  declare -F cli_list >/dev/null && return 0
  for d in "$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)" "${HARNESS_HOME:-$HOME/.harness}/engine"; do
    [[ -f "$d/scripts/cli/dispatch.sh" ]] && { source "$d/scripts/cli/dispatch.sh"; return 0; }
  done
  return 1; }
_load_cli_seam
# _host_clis — every CLI with an adapter whose binary is on this host. Binaries are resolved at CALL
# time through the adapter (HARNESS_<CLI>_BIN), so a caller that sets one after sourcing this file
# (test_install.sh, update.sh's environment) is honoured (#240); a name that does not resolve reads
# as that CLI being absent.
_host_clis(){ local c; declare -F cli_list >/dev/null || return 0
  for c in $(cli_list); do need "$(_cli_exe_of "$c")" && echo "$c"; done; return 0; }
# _cli_exe_of <cli> — the CLI's executable (#272: HARNESS_<CLI>_BIN may be `env VAR=… claude`). An
# older placed engine's seam has no cli_exe; its cli_bin is then the best there is.
_cli_exe_of(){ if declare -F cli_exe >/dev/null; then cli_with "$1" cli_exe; else cli_with "$1" cli_bin; fi; }
check_prereqs(){
  local ok=1 c any=
  for b in git tmux python3; do need "$b" || { echo "MISSING: $b" >&2; ok=0; }; done
  if ! need gh; then echo "MISSING: gh (install: https://cli.github.com)" >&2; ok=0
  elif ! gh auth status >/dev/null 2>&1; then echo "gh not authenticated — run: gh auth login" >&2; ok=0; fi
  if declare -F cli_list >/dev/null; then       # no adapters yet (a piped install): main re-checks after place_engine
    for c in $(_host_clis); do
      any=1
      cli_with "$c" cli_runnable || { echo "$c present but not runnable ($(cli_with "$c" cli_bin))" >&2; ok=0; }
    done
    [[ -n "$any" ]] || { echo "MISSING: an agent CLI — install one of: $(cli_list | xargs)" >&2; ok=0; }
  fi
  [[ "$ok" == 1 ]]
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
  # Each agent CLI on this host gets the plugins its lanes need, installed by its own adapter
  # (cli_prereqs --install). Harness's own plugins come from the placed engine's plugins/ when there
  # is one (HARNESS_ENGINE_PLUGINS): that copy outlives the checkout this script may be running from.
  local c any= plugins="${HARNESS_HOME:-$HOME/.harness}/engine/plugins"
  [[ -d "$plugins" ]] || plugins="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plugins"
  for c in $(_host_clis); do
    any=1; echo "ensuring the $c CLI's plugins (best-effort) ..."
    HARNESS_ENGINE_PLUGINS="$plugins" cli_with "$c" cli_prereqs --install 2>&1 | sed 's/^/  /'
  done
  [[ -n "$any" ]] || echo "  ! no agent CLI found — install one, then re-run to provision its plugins"
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
# each skill/<name>/ → <name>/, whole (harness-arc ships REFERENCE.md + scripts/ beside its SKILL.md).
# Best-effort: a missing source warns, never fails.
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
    mkdir -p "$dst/$(basename "$d")"; cp -R "$d." "$dst/$(basename "$d")/" && n=$((n+1))
  done
  echo "  ✓ installed $n /harness skill(s) into $dst (user scope)"
  # A CLI that reads user skills somewhere else (cli_user_skills_dir) gets its own copy, when it is
  # installed or its config dir exists. A pinned HARNESS_USER_SKILLS is a sandbox: it never reaches
  # into the real HOME's other CLI dirs.
  local c cdst
  for c in $(cli_list 2>/dev/null); do
    cdst="$(cli_with "$c" cli_user_skills_dir)"; [[ -n "$cdst" ]] || continue
    [[ -n "${HARNESS_USER_SKILLS:-}" && "$cdst" == "$HOME"/* ]] && continue
    need "$(_cli_exe_of "$c")" || [[ -d "$(dirname "$cdst")" ]] || continue
    mkdir -p "$cdst"
    if [[ -f "$src/SKILL.md" ]]; then
      mkdir -p "$cdst/harness"; cp "$src/SKILL.md" "$cdst/harness/SKILL.md"
    fi
    for d in "$src"/*/; do
      [[ -f "$d/SKILL.md" ]] || continue
      mkdir -p "$cdst/$(basename "$d")"; cp -R "$d." "$cdst/$(basename "$d")/"
    done
    echo "  ✓ installed $n /harness skill(s) into $cdst ($c user scope)"
  done
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
  place_engine || { echo "Engine install/update failed — see above; not finalizing." >&2; exit 1; }
  if ! declare -F cli_list >/dev/null; then     # a piped install: the adapters arrived with the engine
    _load_cli_seam && check_prereqs || { echo "Prerequisites unmet — fix the above and re-run." >&2; exit 1; }
  fi
  ensure_skills
  ensure_rtdd
  create_host_root          # ~/.harness/{poller,snapshots}/ — host-poller dirs (PRD-B, #69)
  install_harness_skills    # /harness operator skills → ~/.claude/skills (user scope, once)
  link_path
  cat <<EOF
Done. The engine is installed once at $HARNESS_HOME/engine and linked as 'harness'.
Next: cd into a project and run  harness init   (creates that project's .harness/ config + state).
EOF
}
[[ "${HARNESS_INSTALL_NOMAIN:-0}" == 1 ]] || main "$@"

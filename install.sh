#!/usr/bin/env bash
# install.sh — install the engine ONCE per host (#54, PRD #52). The engine (all code/assets) lives
# at a single host location, $HARNESS_HOME/engine, and `harness` is symlinked onto PATH. Projects
# never get their own engine copy; per-project config + state live in <project>/.harness/ (created
# by `harness init`). The engine is a published release (#282): releases/latest, or HARNESS_REF=<tag>,
# verified against SHA256SUMS and extracted to $HARNESS_HOME/releases/<tag>/ behind the engine symlink.
set -uo pipefail
HARNESS_HOME="${HARNESS_HOME:-${HOME:-}/.harness}"           # host root for the shared engine (+ PRD-B subdirs)
HARNESS_BIN_DIR="${HARNESS_BIN_DIR:-${HOME:-}/.local/bin}"   # where the `harness` PATH symlink is placed
MATTPOCOCK_SKILLS_URL="${MATTPOCOCK_SKILLS_URL:-https://github.com/mattpocock/skills.git}"
VOCANICZ_TOOLS_URL="${VOCANICZ_TOOLS_URL:-https://github.com/VocanicZ/vocanicz-ai-tools.git}"
RTDD_INSTALL_SPEC="${RTDD_INSTALL_SPEC:-github:VocanicZ/rtdd}"   # upstream's own installer, run via npx

need(){ command -v "$1" >/dev/null 2>&1; }
# ── native Windows (Git Bash, #356, docs/adr/0001-native-windows-runtime.md) ─────────────────────
# install.sh runs before any engine exists (`curl | bash`), so it carries its own platform test:
# portable.sh's is_windows, with the same HARNESS_PLATFORM=windows|posix override the suite forces.
inst_windows(){ case "${HARNESS_PLATFORM:-$(uname -s 2>/dev/null)}" in windows|MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }
# By default Git Bash's `ln -s` silently makes a COPY; the engine link must be a real symlink, so
# every link install and update make is native (Developer Mode or an administrator; `harness doctor`
# checks that one can be made). Exported, and set for update.sh too, which sources this file.
if inst_windows && [[ " ${MSYS:-} " != *" winsymlinks:nativestrict "* ]]; then export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict"; fi
# py_runs <cmd…> — <cmd…> is a Python 3 that actually runs (the Microsoft Store `python3` stub does not).
py_runs(){ local o; o="$("$@" -c 'import sys; print(sys.version_info[0])' 2>/dev/null)"; [[ $o == 3* ]]; }
# python_probe — the interpreter the python3 shim runs: HARNESS_PYTHON, else the first of python3 /
# python / `py -3` that runs, a single name resolved to its full path (so the shim never finds itself).
# Looked up with the shim's own directory off PATH.
python_probe(){ local c w path=":$PATH:" sd="${HARNESS_HOME:-$HOME/.harness}/bin"
  path="${path//:$sd:/:}"; path="${path#:}"; path="${path%:}"
  if [[ -n ${HARNESS_PYTHON:-} ]]; then printf '%s\n' "$HARNESS_PYTHON"; return 0; fi
  for c in python3 python "py -3"; do
    read -r -a w <<<"$c"
    w[0]="$(PATH="$path" command -v "${w[0]}" 2>/dev/null)" || continue
    PATH="$path" py_runs "${w[@]}" || continue
    if (( ${#w[@]} == 1 )); then printf '%s\n' "${w[0]}"; else printf '%s\n' "$c"; fi
    return 0
  done
  return 1; }
# inst_py <args…> — run Python as install.sh itself needs it (#403): python3 off Windows; on Windows
# python_probe's interpreter, since the `python3` on PATH may be the Store stub and the shim may not
# exist yet (a first install resolves releases/latest before it can write one).
inst_py(){ local p w
  inst_windows || { python3 "$@"; return; }
  p="$(python_probe)" || { echo "MISSING: a Python 3 that runs (python3/python/py -3; the Microsoft Store stub is not one)" >&2; return 127; }
  if [[ -f $p ]]; then "$p" "$@"; else read -r -a w <<<"$p"; "${w[@]}" "$@"; fi; }
# install_python_shim — Windows only: $HARNESS_HOME/bin/python3, which bin/harness puts first on PATH,
# runs HARNESS_PYTHON (default: python_probe's answer, baked in), so the engine's `python3` calls
# reach a real interpreter. Re-run by `harness update`.
install_python_shim(){ local d="${HARNESS_HOME:-$HOME/.harness}/bin" py
  inst_windows || return 0
  py="$(python_probe)" || { echo "MISSING: a Python 3 that runs (python3/python/py -3; the Microsoft Store stub is not one) — install it, or set HARNESS_PYTHON" >&2; return 1; }
  mkdir -p "$d" || return 1
  { cat <<'EOF'
#!/usr/bin/env bash
# python3 — Harness's shim (#356): on Windows the `python3` on PATH is the Microsoft Store stub, so
# this runs HARNESS_PYTHON instead (default: the interpreter install.sh found). Written by install.sh
# and `harness update`; bin/harness puts this directory first on PATH.
# UTF-8 mode (#406): stdio and open() default to UTF-8, not the ANSI code page (cp1252), so every
# engine Python reads and prints the lane files' and the TUI shapes' non-ASCII (✻ ❯ — …) intact.
export PYTHONUTF8=1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EOF
    printf 'p="${HARNESS_PYTHON:-%s}"\n' "$(printf '%q' "$py")"
    cat <<'EOF'
[[ -f $p ]] && exec "$p" "$@"
read -r -a argv <<<"$p"
s=":$PATH:"; s="${s//:$here:/:}"
x="$(PATH="$s" command -v "${argv[0]}")" || { echo "python3 shim: '$p' not found — set HARNESS_PYTHON" >&2; exit 127; }
exec "$x" "${argv[@]:1}" "$@"
EOF
  } >"$d/python3" || return 1
  chmod +x "$d/python3"
  echo "  python3 shim: $d/python3 -> $py"; }
# inst_bash_exe — Git's bash.exe for the harness.cmd shim (WSL's bash.exe is first on the cmd PATH).
inst_bash_exe(){ local r
  [[ -n ${HARNESS_BASH_EXE:-} ]] && { printf '%s\n' "$HARNESS_BASH_EXE"; return 0; }
  r="$(cygpath -w / 2>/dev/null)" || r='C:\Program Files\Git\'
  printf '%s\\bin\\bash.exe\n' "${r%\\}"; }
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
# ── ~/.local/bin, off PATH (#431) ─────────────────────────────────────────────────────────────────
# Claude Code's native installer (and this one's `harness` link) write to ~/.local/bin, which a fresh
# Linux session's PATH often lacks (~/.profile adds it only at login, only if it existed then).
# inst_local_bin puts it on PATH for the rest of this install when it exists; _CLI_PATH_ADDED (shared
# with scripts/cli/dispatch.sh) remembers that the user's own shell does not have it.
inst_local_bin(){ local d="${HOME:-}/.local/bin"
  [[ -n ${HOME:-} && -d $d ]] || return 0
  case ":$PATH:" in *":$d:"*) return 0 ;; esac
  export PATH="$d:$PATH"; hash -r
  case ":${_CLI_PATH_ADDED:-}:" in *":$d:"*) ;; *) _CLI_PATH_ADDED="${_CLI_PATH_ADDED:+$_CLI_PATH_ADDED:}$d" ;; esac; }
# inst_off_path <dir> — rc 0 when the user's own PATH lacks <dir>: this install added it, or nobody did.
inst_off_path(){ case ":${_CLI_PATH_ADDED:-}:" in *":$1:"*) return 0 ;; esac
  case ":$PATH:" in *":$1:"*) return 1 ;; esac; return 0; }
# inst_path_note <what> <dir> — tell the user, once per <what> and <dir>, the PATH line their shell needs.
inst_path_note(){ case ":${_CLI_PATH_NOTED:-}:" in *":$1@$2:"*) return 0 ;; esac
  _CLI_PATH_NOTED="${_CLI_PATH_NOTED:+$_CLI_PATH_NOTED:}$1@$2"
  echo "  NOTE: $1 is in $2, which is not on your PATH yet. Add it, then re-open your shell:"
  echo "        export PATH=\"$2:\$PATH\"  # add to ~/.bashrc or ~/.zshrc"; }
check_prereqs(){
  local ok=1 c any= exe
  for b in $PREREQ_TOOLS; do [[ $b == gh ]] || need "$b" || { echo "MISSING: $b" >&2; ok=0; }; done
  # Windows (#356): no tmux (lanes are headless), and `python3` may be the Store stub — a Python 3
  # that RUNS is the prerequisite; the shim install_python_shim writes makes it `python3`.
  if inst_windows && ! python_probe >/dev/null; then
    echo "MISSING: a Python 3 that runs (python3/python/py -3; the Microsoft Store stub is not one)" >&2; ok=0
  fi
  if ! need gh; then echo "MISSING: gh (install: https://cli.github.com)" >&2; ok=0
  elif ! gh auth status >/dev/null 2>&1; then echo "gh not authenticated — run: gh auth login" >&2; ok=0; fi
  if declare -F cli_list >/dev/null; then       # no adapters yet (a piped install): main re-checks after place_engine
    inst_local_bin
    for c in $(_host_clis); do
      any=1
      cli_with "$c" cli_runnable || { echo "$c present but not runnable ($(cli_with "$c" cli_bin))" >&2; ok=0; }
      exe="$(command -v "$(_cli_exe_of "$c")")"
      [[ $exe == */* ]] && inst_off_path "${exe%/*}" && inst_path_note "$c" "${exe%/*}"
    done
    [[ -n "$any" ]] || { echo "MISSING: an agent CLI — install one of: $(cli_list | xargs)" >&2; ok=0; }
  fi
  [[ "$ok" == 1 ]]
}

# ── offering missing prerequisites (#342) ───────────────────────────────────────────────────────
# offer_prereqs asks to install what check_prereqs would find missing, instead of only failing.
# Questions read from $HARNESS_TTY (/dev/tty: works under `curl | bash`, whose stdin is the script).
# HARNESS_INSTALL_PREREQS=1 answers yes, 0 no; no terminal and no setting prints the command only.
PREREQ_TOOLS="git tmux python3 curl sha256sum tar gh"
# Windows (#356): Git for Windows brings git, curl, sha256sum and tar; Python is probed (python_probe).
inst_windows && PREREQ_TOOLS="git curl sha256sum tar gh"
# pkg_manager — the host package manager offer_prereqs installs with; nothing when none is known.
pkg_manager(){ local m
  for m in apt-get dnf pacman zypper apk brew; do need "$m" && { echo "$m"; return 0; }; done; return 1; }
# pkg_name <manager> <tool> — the package that provides <tool> under <manager>.
pkg_name(){
  case "$1:$2" in
    *:sha256sum)                echo coreutils ;;
    pacman:gh|apk:gh)           echo github-cli ;;
    pacman:python3|brew:python3) echo python ;;
    *)                          echo "$2" ;;
  esac; }
# pkg_install_cmd <manager> <tool>… — the exact command that installs <tool>… (deduplicated packages),
# through sudo when not root and sudo exists — never for brew, which refuses to run as root.
pkg_install_cmd(){ local m="$1" p pkgs=" " su=""; shift
  for p in "$@"; do p="$(pkg_name "$m" "$p")"; [[ "$pkgs" == *" $p "* ]] || pkgs+="$p "; done
  pkgs="${pkgs# }"; pkgs="${pkgs% }"
  [[ "$m" != brew && "$(id -u 2>/dev/null)" != 0 ]] && need sudo && su="sudo "
  case "$m" in
    apt-get) echo "${su}apt-get update && ${su}apt-get install -y $pkgs" ;;
    dnf)     echo "${su}dnf install -y $pkgs" ;;
    pacman)  echo "${su}pacman -S --needed --noconfirm $pkgs" ;;
    zypper)  echo "${su}zypper --non-interactive install $pkgs" ;;
    apk)     echo "${su}apk add $pkgs" ;;
    brew)    echo "brew install $pkgs" ;;
  esac; }
_tty(){ echo "${HARNESS_TTY:-/dev/tty}"; }
_has_tty(){ ( : <"$(_tty)" ) 2>/dev/null; }
# ask_yes <question> — rc 0 yes, 1 no, 2 nobody to ask (no terminal, no HARNESS_INSTALL_PREREQS).
ask_yes(){ local a
  case "${HARNESS_INSTALL_PREREQS:-}" in 1) return 0 ;; 0) return 1 ;; esac
  _has_tty || return 2
  printf '%s [Y/n] ' "$1" >&2
  IFS= read -r a <"$(_tty)" || a=n
  [[ -z "$a" || "$a" == [Yy]* ]]; }
# offer <question> <shown command> [<run>…] — ask; yes runs <run>… (default: <shown command> in bash,
# stdin from the terminal so sudo / gh auth login can prompt). No or nobody to ask prints the command.
offer(){ local q="$1" show="$2" rc; shift 2
  ask_yes "$q"; rc=$?
  if (( rc == 0 )); then
    echo "  running: $show"
    local in=/dev/null; _has_tty && in="$(_tty)"
    if (( $# )); then "$@" <"$in"; else "${BASH:-bash}" -c "$show" <"$in"; fi
    hash -r; return 0
  fi
  (( rc == 1 )) && echo "  skipped — install it yourself with:  $show" >&2 \
                || echo "  no terminal to ask (set HARNESS_INSTALL_PREREQS=1 to accept) — run:  $show" >&2
  return 1; }
# ── native Windows: prerequisites through winget (#488, PRD #475) ────────────────────────────────
# On Git Bash the package manager is winget, the way apt or brew is on Linux. HARNESS_WINGET names the
# binary (the suite points it at a logging stub: no test ever runs a real `winget install`). Each missing
# prerequisite is its own offer with its own winget id, so a "no" to one does not skip the rest.
WINGET_GIT=Git.Git                 # git, bash, curl, sha256sum, tar
WINGET_PYTHON=Python.Python.3.13   # a real Python 3, not the Microsoft Store stub
WINGET_GH=GitHub.cli
WINGET_CLAUDE=Anthropic.ClaudeCode
WINGET_NODE=OpenJS.NodeJS.LTS      # npx, for rtdd's installer
inst_winget(){ printf '%s\n' "${HARNESS_WINGET:-winget}"; }
# winget_cmd <id> — the exact command that installs <id> (non-interactive: both agreements accepted).
winget_cmd(){ printf '%q install --id %s -e --source winget --accept-package-agreements --accept-source-agreements' "$(inst_winget)" "$1"; }
# winget_offer <question> <id> — offer one winget package; without winget, say what to run instead.
winget_offer(){ local q="$1" id="$2"
  if need "$(inst_winget)"; then offer "$q" "$(winget_cmd "$id")" && _WINGET_RAN=1
  else echo "  ! $q — winget is not on PATH (install 'App Installer' from the Microsoft Store, or set HARNESS_WINGET); then run:  $(winget_cmd "$id")" >&2; fi; }
# offer_prereqs_windows — Git for Windows, Python 3, gh, an agent CLI (Claude Code) and Node (for rtdd),
# each only when missing. Then gh sign-in, as on Linux.
offer_prereqs_windows(){ local b git_missing=0 _WINGET_RAN=0
  for b in $PREREQ_TOOLS; do [[ $b == gh ]] || need "$b" || git_missing=1; done
  (( git_missing )) && winget_offer "Git for Windows (git, curl, sha256sum, tar) is missing — install it with winget?" "$WINGET_GIT"
  python_probe >/dev/null || winget_offer "No Python 3 that runs (the Microsoft Store python3 stub does not count) — install Python with winget?" "$WINGET_PYTHON"
  need gh || winget_offer "gh (GitHub CLI) is missing — install it with winget?" "$WINGET_GH"
  declare -F cli_list >/dev/null && inst_local_bin
  if declare -F cli_list >/dev/null && [[ -z "$(_host_clis)" ]] && cli_list | grep -qx claude; then
    winget_offer "No agent CLI found — install Claude Code with winget?" "$WINGET_CLAUDE"
  fi
  if [[ "${HARNESS_SKIP_RTDD:-0}" != 1 && -z "${_NODE_OFFERED:-}" ]] && ! need rtdd && ! need npx; then
    _NODE_OFFERED=1
    winget_offer "Node.js (npx) is missing — rtdd's installer needs it; install Node with winget?" "$WINGET_NODE"
  fi
  (( _WINGET_RAN )) && echo "  NOTE: winget updates PATH for NEW terminals only. If a prerequisite below still reads MISSING, open a new Git Bash and re-run install.sh." >&2
  if need gh && ! gh auth status >/dev/null 2>&1; then
    offer "gh is not signed in — run gh auth login now?" "gh auth login"
  fi
  return 0; }
# check_windows_host — Developer Mode and the git identity, each with the exact fix. Developer Mode
# matters because the engine link must be a real symlink: off in the registry is only a problem when
# this shell cannot make one anyway (an administrator can). rc 1 only for that; a missing git identity
# is a warning (GIT_AUTHOR_* in the environment is a fine alternative). Windows only.
WIN_DEVMODE_FIX='turn on Developer Mode (Settings → System → For developers → Developer Mode), or run this shell as an administrator; in an administrator PowerShell: reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1'
WIN_IDENTITY_FIX='git config --global user.name "Your Name"  &&  git config --global user.email "you@users.noreply.github.com"'
inst_devmode(){ local reg="${HARNESS_REG:-reg}" o
  need "$reg" || { echo unknown; return 0; }
  o="$("$reg" query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' //v AllowDevelopmentWithoutDevLicense 2>/dev/null)" || { echo off; return 0; }
  if grep -q '0x1' <<<"$o"; then echo on; else echo off; fi; }
inst_symlink_ok(){ local d rc=1; d="$(mktemp -d)" || return 1
  ( cd "$d" && mkdir t && MSYS=winsymlinks:nativestrict ln -s t l 2>/dev/null && [[ -L l ]] ) && rc=0
  rm -rf "$d"; return "$rc"; }
check_windows_host(){ local ok=1 m
  inst_windows || return 0
  if [[ "$(inst_devmode)" == off ]]; then
    if inst_symlink_ok; then echo "  Developer Mode is off, but this shell can make symlinks (an administrator) — fine here; other shells need it." >&2
    else echo "MISSING: Developer Mode — this shell cannot make a real symlink, and the engine link must be one. Fix: $WIN_DEVMODE_FIX" >&2; ok=0; fi
  fi
  m=()
  [[ -n "$(git config --get user.name 2>/dev/null)" || -n "${GIT_AUTHOR_NAME:-}" ]] || m+=(user.name)
  [[ -n "$(git config --get user.email 2>/dev/null)" || -n "${GIT_AUTHOR_EMAIL:-}" ]] || m+=(user.email)
  (( ${#m[@]} )) && echo "  ! git has no ${m[*]} — a lane's first commit would fail. Fix: $WIN_IDENTITY_FIX" >&2
  [[ "$ok" == 1 ]]; }
# offer_prereqs — the tools (one package-manager command), then gh sign-in, then an agent CLI (Claude
# Code, through the claude adapter's own cli_prereqs --install) when adapters are loaded and no agent
# CLI is on the host. Always rc 0: check_prereqs, which runs next, is the verdict.
offer_prereqs(){ local b miss=() m cmd
  if inst_windows; then offer_prereqs_windows; return 0; fi
  for b in $PREREQ_TOOLS; do need "$b" || miss+=("$b"); done
  if (( ${#miss[@]} )); then
    if m="$(pkg_manager)"; then
      cmd="$(pkg_install_cmd "$m" "${miss[@]}")"
      offer "Missing ${miss[*]} — install with $m?" "$cmd"
    else
      echo "  ! missing ${miss[*]}, and no known package manager (apt-get dnf pacman zypper apk brew) to offer" >&2
    fi
  fi
  if need gh && ! gh auth status >/dev/null 2>&1; then
    offer "gh is not signed in — run gh auth login now?" "gh auth login"
  fi
  declare -F cli_list >/dev/null && inst_local_bin   # a Claude Code already in ~/.local/bin is not re-offered
  if declare -F cli_list >/dev/null && [[ -z "$(_host_clis)" ]] && cli_list | grep -qx claude; then
    cmd="$(cli_with claude cli_prereqs 2>/dev/null | sed -n 's/^MISSING claude binary ([^)]*): //p' | head -1)"
    offer "No agent CLI found — install Claude Code?" "${cmd:-cli_prereqs --install}" \
      cli_with claude cli_prereqs --install
  fi
  return 0; }
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

# ── releases (PRD #274, #279) ──────────────────────────────────────────────────────────────────────
# A host runs a published release: $HARNESS_HOME/releases/vX.Y.Z/ is one release, extracted once and
# never modified, and $HARNESS_HOME/engine is a relative symlink to one of them, flipped by a single
# rename(2). These mirror rtdd's internal/selfupdate/: the same messages (rtdd → Harness,
# checksums.txt → SHA256SUMS) and the same exit discipline — rc 2 a configuration problem the
# operator can fix, rc 3 an environment that failed underneath (network, checksum, disk).
HARNESS_RELEASE_REPO="${HARNESS_RELEASE_REPO:-VocanicZ/Harness}"
HARNESS_API_URL="${HARNESS_API_URL:-https://api.github.com/repos/$HARNESS_RELEASE_REPO/releases/latest}"
HARNESS_BASE_URL="${HARNESS_BASE_URL:-https://github.com/$HARNESS_RELEASE_REPO/releases/download}"
REL_CMD="harness update"   # who the messages below speak as; place_engine scopes it to `harness install`

# semver_cmp <a> <b> — prints -1, 0 or 1 as <a> is older than, the same as, or newer than <b>. rc 2
# (and nothing printed) when either is not [v]MAJOR.MINOR.PATCH[-pre]. A pre-release sorts below its
# release; two pre-releases of one version compare as strings (rtdd's parseVersion/compare).
semver_cmp(){
  local re='^v?([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z.-]+))?$' a b i x y
  [[ "$1" =~ $re ]] || return 2; a=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}")
  [[ "$2" =~ $re ]] || return 2; b=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}")
  for i in 0 1 2; do
    x=$((10#${a[i]})); y=$((10#${b[i]}))
    (( x < y )) && { echo -1; return 0; }; (( x > y )) && { echo 1; return 0; }
  done
  x="${a[3]}"; y="${b[3]}"
  if [[ "$x" == "$y" ]]; then echo 0
  elif [[ -z "$x" ]]; then echo 1
  elif [[ -z "$y" || "$x" < "$y" ]]; then echo -1
  else echo 1; fi
}
# rel_latest_tag — the tag_name $HARNESS_API_URL (releases/latest) names. rc 2: it named no release
# (none published, or only a draft — GitHub answers 404 {"message":"Not Found"}, hence no curl -f);
# rc 3: unreachable or unreadable. Errors go to stderr in rtdd's words.
rel_latest_tag(){
  local body tag
  if ! body="$(curl -sSL "$HARNESS_API_URL" 2>&1)"; then
    echo "$REL_CMD: could not resolve the latest release from $HARNESS_API_URL: ${body:-curl failed}" >&2; return 3
  fi
  if ! tag="$(inst_py -c 'import json,sys; d=json.loads(sys.stdin.read()); print((d.get("tag_name") or "") if isinstance(d,dict) else "")' <<<"$body" 2>/dev/null)"; then
    echo "$REL_CMD: could not resolve the latest release from $HARNESS_API_URL: the response is not JSON" >&2; return 3
  fi
  [[ -n "$tag" ]] || return 2
  printf '%s\n' "$tag"
}
# rel_fetch <tag> <dir> — download harness-<tag>.tar.gz and SHA256SUMS from $HARNESS_BASE_URL/<tag>/
# into <dir> and verify the archive against the SHA256SUMS line whose LAST field is its name. A
# missing entry is a failure, never a skip. rc 3 on a failed fetch, a missing entry, or a mismatch.
rel_fetch(){
  local tag="$1" dir="$2" arc="harness-$1.tar.gz" want got
  local url="$HARNESS_BASE_URL/$tag"
  curl -fsSL -o "$dir/$arc" "$url/$arc" || { echo "$REL_CMD: could not download $url/$arc" >&2; return 3; }
  curl -fsSL -o "$dir/SHA256SUMS" "$url/SHA256SUMS" || { echo "$REL_CMD: could not download $url/SHA256SUMS" >&2; return 3; }
  want="$(awk -v n="$arc" '{ f=$NF; sub(/^\*/, "", f) } f == n { print $1; exit }' "$dir/SHA256SUMS")"
  [[ -n "$want" ]] || { echo "$REL_CMD: SHA256SUMS carries no entry for $arc" >&2; return 3; }
  got="$(sha256sum "$dir/$arc" | awk '{print $1}')"
  [[ "$want" == "$got" ]] || { echo "$REL_CMD: checksum mismatch for $arc: expected $want, got $got" >&2; return 3; }
}
# rel_install <tag> — fetch + verify <tag>, extract it into releases/.staging-<tag>.XXXX (same
# filesystem), require VERSION line 1 == <tag>, then rename it to releases/<tag>. An existing
# releases/<tag> carrying that VERSION is a no-op. Any failure removes the staging and temp dirs, so
# releases/<tag> never exists half-written. rc 3 on any failure.
rel_install(){
  local tag="$1" rel="$HARNESS_HOME/releases" tmp stage
  if [[ -d "$rel/$tag" ]]; then
    [[ "$(sed -n 1p "$rel/$tag/VERSION" 2>/dev/null)" == "$tag" ]] && return 0
    echo "$REL_CMD: $rel/$tag exists but is not release $tag; move it aside and retry" >&2; return 3
  fi
  mkdir -p "$rel" || return 3
  tmp="$(mktemp -d)" || return 3
  if ! stage="$(mktemp -d "$rel/.staging-$tag.XXXX")"; then rm -rf "$tmp"; return 3; fi
  _rel_install_into "$tag" "$tmp" "$stage"; local rc=$?
  rm -rf "$tmp"; (( rc == 0 )) || rm -rf "$stage"
  return $rc
}
_rel_install_into(){
  local tag="$1" tmp="$2" stage="$3"
  rel_fetch "$tag" "$tmp" || return 3
  # The archive goes in on stdin: GNU tar reads `C:/hx/tmp/…` (a mixed-form TMPDIR on Windows) as host:path.
  tar -xzf - -C "$stage" --strip-components=1 <"$tmp/harness-$tag.tar.gz" \
    || { echo "$REL_CMD: could not extract harness-$tag.tar.gz" >&2; return 3; }
  [[ "$(sed -n 1p "$stage/VERSION" 2>/dev/null)" == "$tag" ]] \
    || { echo "$REL_CMD: harness-$tag.tar.gz does not carry VERSION $tag" >&2; return 3; }
  chmod 755 "$stage"
  mv -T "$stage" "$HARNESS_HOME/releases/$tag" || { echo "$REL_CMD: could not place $HARNESS_HOME/releases/$tag" >&2; return 3; }
}
# engine_flip <name> — point $HARNESS_HOME/engine at releases/<name> with ONE rename(2): a new
# relative link beside it, then mv -T over it, so a path through engine never sees it missing or
# half-written. Appends <name> to releases/.installed (newest last).
engine_flip(){
  local h="$HARNESS_HOME" tmp="$HARNESS_HOME/engine.flip.$$"
  rm -f "$tmp"
  ln -s "releases/$1" "$tmp" && mv -T "$tmp" "$h/engine" \
    || { rm -f "$tmp"; echo "$REL_CMD: could not point $h/engine at releases/$1" >&2; return 3; }
  echo "$1" >> "$h/releases/.installed"
}
# engine_current — the release name engine points at; empty when engine is not a symlink.
engine_current(){ [[ -L "$HARNESS_HOME/engine" ]] && basename "$(readlink "$HARNESS_HOME/engine")"; return 0; }
# engine_version — line 1 of engine/VERSION; v0.0.0 when there is none, so a migrated git-<sha>
# tree orders below every release.
engine_version(){ local v; v="$(sed -n 1p "$HARNESS_HOME/engine/VERSION" 2>/dev/null)"; echo "${v:-v0.0.0}"; }
# rel_previous — the release `update --rollback` flips to: the newest releases/.installed entry that
# is not the current target and whose releases/<name> still exists. Empty when there is none.
rel_previous(){
  local rel="$HARNESS_HOME/releases" cur name
  cur="$(engine_current)"
  while IFS= read -r name; do
    [[ -n "$name" && "$name" != "$cur" && "$name" != .* && "$name" != */* && -d "$rel/$name" ]] || continue
    echo "$name"; return 0
  done < <(tac "$rel/.installed" 2>/dev/null)
  return 0
}
# engine_migrate_git <tag> — move a git-checkout engine onto releases (#281). A no-op unless
# $HARNESS_HOME/engine is a real directory with .git. Installs <tag> FIRST, so a failed download
# leaves the git engine exactly where it was; then moves the checkout, uncommitted edits and all, to
# releases/git-<12-char sha> (-2, -3 … if taken) and points engine at releases/<tag>, back to back.
# No git command runs on the tree but rev-parse. Both names go to .installed (the old tree first),
# so it counts as a release for retention and --rollback. Sets ENGINE_MIGRATED to the old tree's
# name. rc 3 on any failure.
engine_migrate_git(){
  local tag="$1" h="$HARNESS_HOME" sha name i=1 tmp="$HARNESS_HOME/engine.flip.$$"
  ENGINE_MIGRATED=""
  [[ -d "$h/engine" && ! -L "$h/engine" && -e "$h/engine/.git" ]] || return 0
  rel_install "$tag" || return 3
  sha="$(git -C "$h/engine" rev-parse --short=12 HEAD 2>/dev/null)" || sha="unknown"
  name="git-$sha"
  while [[ -e "$h/releases/$name" ]]; do i=$((i+1)); name="git-$sha-$i"; done
  rm -f "$tmp"
  ln -s "releases/$tag" "$tmp" || { echo "$REL_CMD: could not create $tmp" >&2; return 3; }
  if ! mv -T "$h/engine" "$h/releases/$name"; then
    rm -f "$tmp"; echo "$REL_CMD: could not move $h/engine to $h/releases/$name" >&2; return 3
  fi
  if ! mv -T "$tmp" "$h/engine"; then
    mv -T "$h/releases/$name" "$h/engine" 2>/dev/null; rm -f "$tmp"
    echo "$REL_CMD: could not point $h/engine at releases/$tag" >&2; return 3
  fi
  printf '%s\n%s\n' "$name" "$tag" >> "$h/releases/.installed"
  ENGINE_MIGRATED="$name"
}
# proc_engine_dir <pid> — a process's ENGINE_DIR from its exec-time environ (the twin of lib.sh's
# proc_state_dir; copied here because a piped install has no lib.sh).
proc_engine_dir(){ tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n 's/^ENGINE_DIR=//p' | head -1; }
# rel_in_use <dir> — rc 0 iff some live process's ENGINE_DIR, realpath'd, is <dir> or under it. Reads
# each environ in-shell (no fork per process): a fleet host runs hundreds of them.
rel_in_use(){
  local want e kv
  want="$(realpath -m "$1" 2>/dev/null)" || want="$1"
  for e in /proc/[0-9]*/environ; do
    while IFS= read -r -d '' kv; do
      [[ "$kv" == ENGINE_DIR=* ]] || continue
      kv="$(realpath -m "${kv#ENGINE_DIR=}" 2>/dev/null)" || break
      [[ "$kv" == "$want" || "$kv" == "$want"/* ]] && return 0
      break
    done 2>/dev/null < "$e"
  done
  return 1
}
# rel_prune — keep the current release and the previous 2 (the last 3 distinct names in
# releases/.installed); remove every other releases/<name> unless it is the engine's target or a
# live process runs from it. Dotfiles are never touched, except a .staging-* dir over an hour old
# (an interrupted install's leftover). Only ever rm -rf's releases/<name> directories.
rel_prune(){
  local rel="$HARNESS_HOME/releases" cur keep=" " n d name
  [[ -d "$rel" ]] || return 0
  cur="$(engine_current)"
  n=0
  while IFS= read -r name; do
    [[ -n "$name" && "$keep" != *" $name "* ]] || continue
    keep+="$name "; n=$((n+1)); (( n >= 3 )) && break
  done < <(tac "$rel/.installed" 2>/dev/null)
  for d in "$rel"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    [[ "$keep" == *" $name "* || "$name" == "$cur" ]] && continue
    rel_in_use "$rel/$name" && continue
    rm -rf "${rel:?}/$name"
  done
  find "$rel" -mindepth 1 -maxdepth 1 -type d -name '.staging-*' -mmin +60 -exec rm -rf {} + 2>/dev/null
  return 0
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
# place_engine — install a published release at the SINGLE host location $HARNESS_HOME/engine (never
# into a project's ./.harness/), through the same rel_install + engine_flip as `harness update` (#282).
# The tag is HARNESS_REF when set (never compared, even an older one), else releases/latest. A
# git-checkout engine is migrated aside the way update does it (engine_migrate_git). An installed
# same tag is a no-op flip. Any failure returns 1 with engine untouched and no releases/<tag> left
# behind. Sets INSTALLED_TAG for main's closing line.
place_engine(){
  local REL_CMD="harness install" tag rc
  INSTALLED_TAG=""
  mkdir -p "$HARNESS_HOME" || return 1
  if [[ -n "${HARNESS_REF:-}" ]]; then
    tag="$HARNESS_REF"
    if [[ ! -d "$HARNESS_HOME/releases/$tag" ]] && ! curl -fsSL -o /dev/null "$HARNESS_BASE_URL/$tag/SHA256SUMS" 2>/dev/null; then
      echo "harness install: no Harness release $tag at $HARNESS_BASE_URL/$tag" >&2; return 1
    fi
  else
    tag="$(rel_latest_tag)"; rc=$?
    if (( rc == 2 )); then
      echo "harness install: $HARNESS_API_URL named no release; if a release exists it may still be an unpublished draft. Nothing installed." >&2
      return 1
    fi
    (( rc == 0 )) || return 1
  fi
  echo "  installing Harness $tag to $HARNESS_HOME/releases/$tag ..."
  if [[ -d "$HARNESS_HOME/engine" && ! -L "$HARNESS_HOME/engine" && -e "$HARNESS_HOME/engine/.git" ]]; then
    engine_migrate_git "$tag" || { rmdir "$HARNESS_HOME/releases" 2>/dev/null; return 1; }
    echo "  migrated the git-checkout engine to $HARNESS_HOME/releases/$ENGINE_MIGRATED (local edits kept)"
  elif [[ "$(engine_current)" != "$tag" ]]; then
    rel_install "$tag" || { rmdir "$HARNESS_HOME/releases" 2>/dev/null; return 1; }
    engine_flip "$tag" || return 1
  fi
  INSTALLED_TAG="$tag"
  echo "  installed Harness $tag at $HARNESS_HOME/releases/$tag"
}

# create_host_root — establish the ~/.harness host ROOT with the poller/ and snapshots/ subdirs
# (#57, PRD #52). PRD-B (#69) populates them: the host poller writes its registry + pidfile under
# poller/ and per-repo snapshot JSON under snapshots/ (opt-in per fleet via HARNESS_USE_POLLER).
# Install just creates the dirs so the host layout is stable. Idempotent (mkdir -p is a no-op).
create_host_root(){
  local home="${HARNESS_HOME:-$HOME/.harness}"
  mkdir -p "$home/poller" "$home/snapshots"
}

# install_harness_skills — put the engine's OWN skills in USER scope, once per host, never vendored per
# project (#57, PRD #52): the umbrella skill/SKILL.md as harness/, and each skill/<name>/ (harness-arc
# ships REFERENCE.md + scripts/ beside its SKILL.md), including every skill the lane prompts name
# (#303, #315: handoff, and to-prd, to-issues, writing-plans, caveman, subagent-task-tree vendored from
# upstream). #439: into ~/.claude/skills (HARNESS_USER_SKILLS) AND the user-skills dir of every
# supported CLI installed on the host — its binary on PATH or its config dir present — each the dir
# that CLI reads (cli_user_skills_dir; hermes: ~/.hermes/skills), as SYMLINKS to the one canonical
# copy, the engine's skill/<name> through the stable engine link (cli_skill_link), so an update
# refreshes every CLI at once. A missing, dangling or old-release link, or an old Harness copy, is
# (re)linked; an operator's same-named skill (cli_skill_ours) is kept and named. Re-run by every
# `harness update`, `setup` and `start` (skills_heal), so a CLI support was added for later gets its
# links without a reinstall. A pinned HARNESS_USER_SKILLS is a sandbox: it never reaches into the real
# HOME's other CLI dirs. HARNESS_SKILLS_QUIET=1 prints only what changed. Best-effort: never fails.
install_harness_skills(){
  local src="${HARNESS_SKILL_SRC:-${HARNESS_HOME:-$HOME/.harness}/engine/skill}"
  local dst="${HARNESS_USER_SKILLS:-$HOME/.claude/skills}" quiet="${HARNESS_SKILLS_QUIET:-0}"
  if [[ ! -d "$src" ]]; then
    echo "  ! engine skill/ not found at $src — install /harness skills manually" >&2; return 0
  fi
  src="${src%/}"
  # An older placed engine's adapter seam has no cli_skill_link: copy, as that release did.
  declare -F cli_skill_link >/dev/null || { _install_skills_copy "$src" "$dst"; return 0; }
  local -a dirs=("$dst") who=("user scope") ; local c cdst i
  for c in $(cli_list 2>/dev/null); do
    cdst="$(cli_with "$c" cli_user_skills_dir)"; [[ -n "$cdst" ]] || continue
    [[ -n "${HARNESS_USER_SKILLS:-}" && "$cdst" != "$dst" && "$cdst" == "$HOME"/* ]] && continue
    need "$(_cli_exe_of "$c")" || [[ -d "$(dirname "$cdst")" ]] || continue
    for i in "${!dirs[@]}"; do [[ ${dirs[$i]} == "$cdst" ]] && { who[$i]+=", $c"; continue 2; }; done
    dirs+=("$cdst"); who+=("$c")
  done
  local d n r out new old kept total
  for i in "${!dirs[@]}"; do
    d="${dirs[$i]}"; new=0; old=0; kept=""; total=0
    mkdir -p "$d" 2>/dev/null || { echo "  ! cannot create $d — /harness skills not linked for ${who[$i]}" >&2; continue; }
    for n in "$src/SKILL.md" "$src"/*/; do
      n="${n%/}"
      if [[ $n == "$src/SKILL.md" ]]; then [[ -f $n ]] || continue; r="$d/harness"
      else [[ -f "$n/SKILL.md" ]] || continue; r="$d/${n##*/}"; fi
      total=$((total+1))
      out="$(cli_skill_link "$n" "$r")" || { echo "  ! could not link $r -> $n" >&2; continue; }
      case "$out" in
        linked) new=$((new+1)) ;; relinked) old=$((old+1)) ;; kept) kept+=" ${r##*/}" ;;
      esac
    done
    if (( new + old )); then echo "  ✓ linked /harness skills into $d (${who[$i]}): $new new, $old relinked, $total in all"
    elif (( ! quiet )); then echo "  ✓ /harness skills linked in $d (${who[$i]}): $total, all current"; fi
    [[ -z $kept ]] || (( quiet )) || echo "  ! kept your own skill(s) in $d:$kept — not Harness's; remove one to get Harness's link"
  done
  return 0
}

# _install_skills_copy <src> <dst> — the pre-#439 deploy, for an engine whose seam cannot link: copy
# each skill into <dst> (_place_skill).
_install_skills_copy(){ local src="$1" dst="$2" n=0 d
  mkdir -p "$dst"
  if [[ -f "$src/SKILL.md" ]]; then mkdir -p "$dst/harness"; cp "$src/SKILL.md" "$dst/harness/SKILL.md" && n=$((n+1)); fi
  for d in "$src"/*/; do [[ -f "$d/SKILL.md" ]] && _place_skill "$d" "$dst/$(basename "$d")" && n=$((n+1)); done
  echo "  ✓ installed $n /harness skill(s) into $dst (user scope)"; }

# _place_skill <src dir> <dst dir> — copy one engine skill dir whole. A skill the prompts name rather
# than a /harness one (skill/handoff and the vendored ones, #303, #315) carries a `<!-- harness-skill:`
# line; a same-named skill already there WITHOUT that line is the operator's own and is left alone.
_place_skill(){ local m='<!-- harness-skill:'
  if grep -qF "$m" "$1/SKILL.md" && [[ -f "$2/SKILL.md" ]] && ! grep -qF "$m" "$2/SKILL.md"; then return 0; fi
  mkdir -p "$2" && cp -R "$1." "$2/"; }

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
    # Windows: cmd/PowerShell cannot run a bash script, and their `bash` is WSL's — harness.cmd runs
    # the link through Git's bash.exe by path.
    if inst_windows; then
      printf '@echo off\r\n"%s" "%%~dp0harness" %%*\r\n' "$(inst_bash_exe)" >"$bindir/harness.cmd" \
        && echo "  wrote $bindir/harness.cmd (runs harness through Git's bash)"
    fi
    inst_off_path "$bindir" && inst_path_note "'harness'" "$bindir"
  else
    print_path_instructions "$target"
  fi
}

main(){
  offer_prereqs
  check_prereqs || { echo "Prerequisites unmet — fix the above and re-run." >&2; exit 1; }
  check_windows_host || { echo "Prerequisites unmet — fix the above and re-run." >&2; exit 1; }
  # Windows (#356, #403): the shim first, and its directory first on PATH, so every later `python3` —
  # here and in what main runs — reaches a real interpreter, never the Microsoft Store stub.
  install_python_shim || { echo "Prerequisites unmet — fix the above and re-run." >&2; exit 1; }
  inst_windows && export PATH="$HARNESS_HOME/bin:$PATH"
  place_engine || { echo "Engine install/update failed — see above; not finalizing." >&2; exit 1; }
  if ! declare -F cli_list >/dev/null; then     # a piped install: the adapters arrived with the engine
    _load_cli_seam && offer_prereqs && check_prereqs || { echo "Prerequisites unmet — fix the above and re-run." >&2; exit 1; }
  fi
  ensure_skills
  ensure_rtdd
  create_host_root          # ~/.harness/{poller,snapshots}/ — host-poller dirs (PRD-B, #69)
  install_harness_skills    # /harness skills → every installed CLI's user-skills dir, as links (#439)
  link_path
  cat <<EOF
Done. Harness $INSTALLED_TAG is installed once at $HARNESS_HOME/engine and linked as 'harness'.
Next: cd into a project and run  harness init   (creates that project's .harness/ config + state).
EOF
}
[[ "${HARNESS_INSTALL_NOMAIN:-0}" == 1 ]] || main "$@"

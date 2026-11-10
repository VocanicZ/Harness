#!/usr/bin/env bash
# test_windows_installer.sh — #488 (PRD #475, Solution 4): install.sh on Windows offers each missing
# prerequisite through winget, checks Developer Mode and the git identity, and Harness repos get
# per-repo longpaths + line-ending config; `harness doctor` reports the same. Forced on Linux with
# HARNESS_PLATFORM=windows. winget, reg, ln and gh are stubs: no test runs a real `winget install`.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"
export HARNESS_INSTALL_NOMAIN=1 HARNESS_SKIP_RTDD=0
unset HARNESS_INSTALL_PREREQS HARNESS_WINGET HARNESS_REG GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL MSYS HARNESS_PYTHON
for v in $(compgen -e | grep -E '^HARNESS_[A-Z]+_BIN$'); do unset "$v"; done
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pin_host_home "$T/home/.harness"   # + the fleet/poller/snapshot pins, unit dirs and user bus (#541)
export HOME="$T/home" HARNESS_HOME="$T/home/.harness"; mkdir -p "$HOME"
# git must not read the real user's or system config (the checks below read identity, the tests write repo config).
export GIT_CONFIG_GLOBAL="$T/gitconfig-global" GIT_CONFIG_SYSTEM="$T/gitconfig-system"
printf '[user]\n\tname = Test User\n\temail = test@example.com\n' >"$GIT_CONFIG_GLOBAL"; : >"$GIT_CONFIG_SYSTEM"

SYS="$T/sys"; mkdir -p "$SYS"
for t in sed grep head cat bash sh mktemp rm env xargs ls tr dirname basename mkdir chmod ln git awk cut sort uname id rmdir; do
  link_tool "$t" "$SYS"; done
LOG="$T/log"
stub(){ mkdir -p "$1"; printf '#!/bin/sh\necho "%s $*" >> %q\n%s\n' "$2" "$LOG" "${3:-exit 0}" > "$1/$2"; chmod +x "$1/$2"; }
STORE='echo "Python was not found; run without arguments to install from the Microsoft Store" >&2; exit 9009'
REALPY='[ "$1" = -c ] && case "$2" in *version_info*) echo 3; exit 0;; esac; echo realpy'
# win <dir> <fn…> — install.sh's function on Windows, PATH=<dir>:$SYS, a fresh hash table.
win(){ local d="$1"; shift; ( hash -r; export HARNESS_PLATFORM=windows PATH="$d:$SYS"; source "$R/install.sh" 2>/dev/null; "$@" ); }
# A host where everything but winget is missing; the Store stub is the only python3.
N="$T/none"; stub "$N" winget; stub "$N" python3 "$STORE"
WG="$N/winget"
ids(){ grep -o -- '--id [^ ]*' "$LOG" | awk '{print $2}' | tr '\n' ' '; }

echo "=== winget offers: each missing prerequisite, with the right id ==="
: > "$LOG"; out="$(HARNESS_WINGET="$WG" HARNESS_INSTALL_PREREQS=1 HARNESS_TTY="$T/no-tty" win "$N" offer_prereqs 2>&1)"
assert_ok "Git for Windows is offered as Git.Git"         grep -q 'winget install --id Git.Git ' "$LOG"
assert_ok "Python is offered as Python.Python.3.13 (the Store stub is not a Python)" grep -q -- '--id Python.Python.3.13 ' "$LOG"
assert_ok "gh is offered as GitHub.cli"                   grep -q -- '--id GitHub.cli ' "$LOG"
assert_ok "Claude Code is offered as Anthropic.ClaudeCode" grep -q -- '--id Anthropic.ClaudeCode ' "$LOG"
assert_ok "Node (for rtdd) is offered as OpenJS.NodeJS.LTS" grep -q -- '--id OpenJS.NodeJS.LTS ' "$LOG"
assert_eq "$(grep -c '^winget ' "$LOG")" 5                "exactly five installs, one per prerequisite"
assert_ok "every install accepts the agreements, so it never prompts" test "$(grep -c -- '--accept-package-agreements --accept-source-agreements' "$LOG")" = 5
assert_ok "=1 installs without prompting (no terminal here)" grep -q 'running: ' <<<"$out"
assert_no "… and never reports 'no terminal to ask'"      grep -q 'no terminal to ask' <<<"$out"
assert_ok "after installing, it says winget changes PATH for NEW terminals only" grep -q 'NEW terminals' <<<"$out"

: > "$LOG"; out="$(HARNESS_WINGET="$WG" HARNESS_INSTALL_PREREQS=0 win "$N" offer_prereqs 2>&1)"
assert_eq "$(grep -c '^winget ' "$LOG")" 0               "=0 offers nothing: winget is never run"
for id in Git.Git Python.Python.3.13 GitHub.cli Anthropic.ClaudeCode OpenJS.NodeJS.LTS; do
  assert_ok "=0 still prints the command for $id"         grep -qF -- "--id $id " <<<"$out"
done

: > "$LOG"; out="$(HARNESS_WINGET="$WG" HARNESS_TTY="$T/no-tty" win "$N" offer_prereqs 2>&1)"
assert_eq "$(grep -c '^winget ' "$LOG")" 0               "no terminal and no setting: nothing installed"
assert_ok "… and it says how to accept"                   grep -q 'HARNESS_INSTALL_PREREQS=1' <<<"$out"

# A "y" on the terminal installs; the question names the package.
Y="$T/yes"; printf 'y\ny\ny\ny\ny\n' >"$Y"
: > "$LOG"; out="$(HARNESS_WINGET="$WG" HARNESS_TTY="$Y" win "$N" offer_prereqs 2>&1)"
assert_ok "answering y installs"                          grep -q -- '--id Git.Git ' "$LOG"
assert_ok "… after a [Y/n] question that names the package" grep -q 'Git for Windows.*\[Y/n\]' <<<"$out"

echo "=== only what is missing is offered ==="
H="$T/have"; stub "$H" winget; stub "$H" git; stub "$H" curl; stub "$H" sha256sum; stub "$H" tar
stub "$H" gh; stub "$H" python3 "$REALPY"; stub "$H" npx
: > "$LOG"; HARNESS_WINGET="$H/winget" HARNESS_INSTALL_PREREQS=1 win "$H" offer_prereqs >/dev/null 2>&1
assert_ok "git, python, gh and node present: only Claude Code is offered" test "$(ids)" = "Anthropic.ClaudeCode "
: > "$LOG"; HARNESS_SKIP_RTDD=1 HARNESS_WINGET="$N/winget" HARNESS_INSTALL_PREREQS=1 win "$N" offer_prereqs >/dev/null 2>&1
assert_no "HARNESS_SKIP_RTDD=1 does not offer Node"       grep -q 'NodeJS' "$LOG"
G="$T/gitonly"; stub "$G" winget; for t in git curl sha256sum tar gh; do stub "$G" "$t"; done; stub "$G" python3 "$STORE"; stub "$G" python "$REALPY"
: > "$LOG"; HARNESS_WINGET="$G/winget" HARNESS_INSTALL_PREREQS=1 win "$G" offer_prereqs >/dev/null 2>&1
assert_no "a python that runs (python, not the python3 stub) is not re-offered" grep -q 'Python.Python' "$LOG"
assert_no "gh/git present: not offered"                   grep -qE 'Git.Git|GitHub.cli' "$LOG"

echo "=== no winget on the host ==="
NW="$T/nowinget"; stub "$NW" python3 "$STORE"
: > "$LOG"; out="$(HARNESS_INSTALL_PREREQS=1 win "$NW" offer_prereqs 2>&1)"; rc=$?
assert_eq "$rc" 0                                         "offer_prereqs still returns 0 (check_prereqs is the verdict)"
assert_ok "it names the missing winget and the command"   grep -q 'winget is not on PATH.*Git.Git' <<<"$out"

echo "=== Linux is unchanged ==="
L="$T/linux"; stub "$L" apt-get; stub "$L" id 'echo 0'; stub "$L" winget
: > "$LOG"; out="$( hash -r; export HARNESS_PLATFORM=posix PATH="$L:$SYS" HARNESS_INSTALL_PREREQS=0; source "$R/install.sh" 2>/dev/null; offer_prereqs 2>&1 )"
assert_ok "posix still offers through apt-get"            grep -q 'apt-get install' <<<"$out"
assert_no "… and never mentions winget"                   grep -q 'winget' <<<"$out"

echo "=== Developer Mode and the git identity ==="
M="$T/dm"; stub "$M" reg 'echo "    AllowDevelopmentWithoutDevLicense    REG_DWORD    0x0"'
out="$(HARNESS_REG="$M/reg" win "$M" check_windows_host 2>&1)"; rc=$?
assert_ok "Developer Mode off but symlinks work (administrator): not blocking" test "$rc" = 0
assert_ok "… and it says so"                              grep -q 'Developer Mode is off, but this shell can make symlinks' <<<"$out"
printf '#!/bin/sh\nexit 1\n' >"$M/ln"; chmod +x "$M/ln"
out="$(HARNESS_REG="$M/reg" win "$M" check_windows_host 2>&1)"; rc=$?
assert_eq "$rc" 1                                         "Developer Mode off and no symlink: blocking"
assert_ok "… names the Settings path"                     grep -qF 'Settings → System → For developers → Developer Mode' <<<"$out"
assert_ok "… and the exact administrator command"         grep -qF 'reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1' <<<"$out"
M1="$T/dm1"; stub "$M1" reg 'echo "    AllowDevelopmentWithoutDevLicense    REG_DWORD    0x1"'
printf '#!/bin/sh\nexit 1\n' >"$M1/ln"; chmod +x "$M1/ln"
out="$(HARNESS_REG="$M1/reg" win "$M1" check_windows_host 2>&1)"; rc=$?
assert_eq "$rc" 0                                         "Developer Mode on: fine"
assert_no "… nothing printed about it"                    grep -q 'Developer Mode' <<<"$out"
M2="$T/dm2"; stub "$M2" reg 'exit 1'; printf '#!/bin/sh\nexit 1\n' >"$M2/ln"; chmod +x "$M2/ln"
out="$(HARNESS_REG="$M2/reg" win "$M2" check_windows_host 2>&1)"; rc=$?
assert_eq "$rc" 1                                         "the registry value absent counts as off"
assert_ok "Linux: check_windows_host is a no-op"          test -z "$( hash -r; export HARNESS_PLATFORM=posix PATH="$M:$SYS" HARNESS_REG="$M/reg"; source "$R/install.sh" 2>/dev/null; check_windows_host 2>&1 )"

printf '' >"$GIT_CONFIG_GLOBAL"
out="$(HARNESS_REG="$M1/reg" win "$M1" check_windows_host 2>&1)"; rc=$?
assert_eq "$rc" 0                                         "a missing git identity is a warning, not a stop"
assert_ok "… names both missing settings"                 grep -q 'git has no user.name user.email' <<<"$out"
assert_ok "… and the exact fix"                           grep -qF 'git config --global user.name "Your Name"  &&  git config --global user.email "you@users.noreply.github.com"' <<<"$out"
printf '[user]\n\tname = Only Name\n' >"$GIT_CONFIG_GLOBAL"
out="$(HARNESS_REG="$M1/reg" win "$M1" check_windows_host 2>&1)"
assert_ok "only user.email missing: names just that"      grep -q 'git has no user.email' <<<"$out"
out="$(GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=b@c HARNESS_REG="$M1/reg" win "$M1" check_windows_host 2>&1)"
assert_no "GIT_AUTHOR_* in the environment counts"        grep -q 'git has no' <<<"$out"
printf '[user]\n\tname = Test User\n\temail = test@example.com\n' >"$GIT_CONFIG_GLOBAL"
out="$(HARNESS_REG="$M1/reg" win "$M1" check_windows_host 2>&1)"
assert_no "an identity set: nothing printed"              grep -q 'git has no' <<<"$out"

echo "=== a release extracts when TMPDIR is in Windows mixed form (C:/…) ==="
source "$HERE/release_fixture.sh"
SRV="$T/srv"; rel_server "$SRV"; rel_publish "$SRV" v9.9.9; rel_latest "$SRV" v9.9.9
# Linux: a directory literally named C: under cwd stands in for the drive. A Windows host has a real mixed-form spelling of a real directory.
mkdir -p "$T/cwd/C:/tmp"; MIXED_TMP="C:/tmp"
if real_windows_host; then mkdir -p "$T/mixed-tmp"; MIXED_TMP="$(cygpath -m "$T/mixed-tmp")"; fi
out="$( cd "$T/cwd" && export TMPDIR="$MIXED_TMP" HARNESS_HOME="$T/hh" HARNESS_PLATFORM=windows PATH="$SYS:$PATH"; hash -r; source "$R/install.sh" 2>/dev/null; REL_CMD="harness install"; rel_install v9.9.9 2>&1 )"; rc=$?
assert_eq "$rc" 0                                         "rel_install with TMPDIR=C:/tmp succeeds (tar is not told C: is a host)"
assert_ok "… and the release is in place"                 test -f "$T/hh/releases/v9.9.9/VERSION"

echo "=== install.sh and portable.sh print the same fixes ==="
assert_eq "$(bash -c "source '$R/install.sh' 2>/dev/null; printf %s \"\$WIN_DEVMODE_FIX\"")" "$(bash -c "source '$R/scripts/portable.sh'; printf %s \"\$WIN_DEVMODE_FIX\"")" "Developer Mode fix text"
assert_eq "$(bash -c "source '$R/install.sh' 2>/dev/null; printf %s \"\$WIN_IDENTITY_FIX\"")" "$(bash -c "source '$R/scripts/portable.sh'; printf %s \"\$WIN_IDENTITY_FIX\"")" "git identity fix text"

echo "=== per-repo longpaths and line endings; global and system config untouched ==="
REPO="$T/repo"; git init -q "$REPO"; git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b wt "$T/wt"
printf '[core]\n\tautocrlf = true\n' >>"$GIT_CONFIG_GLOBAL"; printf '[core]\n\teditor = vi\n' >"$GIT_CONFIG_SYSTEM"
gsum="$(sha256sum "$GIT_CONFIG_GLOBAL" "$GIT_CONFIG_SYSTEM")"
( export HARNESS_PLATFORM=windows; source "$R/scripts/portable.sh"; win_repo_config "$T/wt" )
assert_eq "$(git -C "$T/wt" config --local --get core.longpaths)" true  "core.longpaths=true in the repo the worktree belongs to"
assert_eq "$(git -C "$T/wt" config --local --get core.autocrlf)"  false "core.autocrlf=false"
assert_eq "$(git -C "$T/wt" config --local --get core.eol)"       lf    "core.eol=lf"
assert_eq "$(sha256sum "$GIT_CONFIG_GLOBAL" "$GIT_CONFIG_SYSTEM")" "$gsum" "the global and system git config are byte-for-byte untouched"
assert_eq "$(git config --global --get core.longpaths || echo unset)" unset "… core.longpaths is not in the global config"
REPO2="$T/repo2"; git init -q "$REPO2"
( export HARNESS_PLATFORM=posix; source "$R/scripts/portable.sh"; win_repo_config "$REPO2" )
assert_eq "$(git -C "$REPO2" config --local --get core.longpaths || echo unset)" unset "Linux: no settings written"
( export HARNESS_PLATFORM=windows; source "$R/scripts/portable.sh"; win_repo_config "$T/not-a-repo" ); assert_eq "$?" 0 "not a repo: quiet no-op"

echo "=== the spawn paths configure each fresh worktree ==="
spawn_configures(){   # <label> <spawn invocation…>
  local label="$1"; shift
  local out; out="$(bash -c '
    set -uo pipefail
    export RUN_DIR="$(mktemp -d)"
    source "'"$R"'/scripts/lib.sh"; source "'"$R"'/scripts/drive.sh"
    TMP="$(mktemp -d)"; WORKTREES_DIR="$TMP/worktrees"; mkdir -p "$WORKTREES_DIR"
    UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget; CHECKOUT="$TMP/co"
    mkdir -p "$WORKTREES_DIR/main-i7" "$(bug_worktree acme/widget 7)" "$(triage_worktree acme/widget 7)"
    git(){ :; }; gh(){ :; }; tmux(){ :; }; render(){ :; }; launch_claude(){ :; }
    default_branch(){ echo main; }; ensure_safe(){ :; }; ensure_checkout(){ :; }; remove_worktree(){ :; }
    win_repo_config(){ echo "$1" >> "$TMP/configured"; }
    '"$*"' >/dev/null 2>&1
    cat "$TMP/configured" 2>/dev/null
  ')"
  assert_ok "$label" test -n "$out"
}
spawn_configures "spawn_impl runs win_repo_config on its worktree"       'spawn_impl 7 "PROMISE"'
spawn_configures "spawn_bug fix runs win_repo_config on its worktree"    'spawn_bug 7 fix'
spawn_configures "spawn_bug triage runs win_repo_config on its worktree" 'spawn_bug 7 triage'

echo "=== harness doctor reports the same things and names the fix ==="
source "$R/scripts/lib.sh"; _DOCTOR_SOURCED=1 source "$R/scripts/doctor.sh"
DR="$T/dr"; mkdir -p "$DR"; git init -q "$DR/co"
for t in gh node npx rtdd; do stub "$DR" "$t"; done
stub "$DR" reg 'echo "    AllowDevelopmentWithoutDevLicense    REG_DWORD    0x1"'
dp(){ ( export HARNESS_PLATFORM=windows HARNESS_REG="$DR/reg" HARNESS_WINGET=winget HARNESS_CHECKOUT="$DR/co"; "$@"; doctor_windows_prereqs ); }
out="$(dp true 2>&1)"
assert_ok "Developer Mode on is reported"                 grep -q 'developer mode: on ✓' <<<"$out"
assert_ok "an identity is reported"                       grep -q 'git identity: ✓' <<<"$out"
assert_ok "unset per-repo git settings are a problem naming the fix" grep -q 'core.longpaths core.autocrlf core.eol not set — harness doctor --fix' <<<"$out"
( export HARNESS_PLATFORM=windows HARNESS_CHECKOUT="$DR/co" DOCTOR_FIX=1; doctor_windows_prereqs >/dev/null 2>&1 )
assert_eq "$(git -C "$DR/co" config --local --get core.longpaths)" true "--fix sets core.longpaths on the checkout"
out="$(dp true 2>&1)"; assert_ok "… and then it reads ✓" grep -q 'longpaths + LF ✓' <<<"$out"
printf '' >"$GIT_CONFIG_GLOBAL"
out="$(dp true 2>&1)"
assert_ok "a missing identity names the exact fix"        grep -qF 'git identity: no user.name user.email — git config --global user.name "Your Name"' <<<"$out"
printf '#!/bin/sh\nexit 1\n' >"$DR/ln"; chmod +x "$DR/ln"; stub "$DR" reg 'echo "    AllowDevelopmentWithoutDevLicense    REG_DWORD    0x0"'
out="$(PATH="$DR:$PATH" dp true 2>&1)"
assert_ok "Developer Mode off and no symlink names the fix" grep -qF 'developer mode: off — turn on Developer Mode' <<<"$out"
out="$(PATH="$SYS" dp true 2>&1)"
assert_ok "gh missing: the winget command"                grep -q 'gh: MISSING — winget install --id GitHub.cli -e' <<<"$out"
printf '[user]\n\tname = Test User\n\temail = test@example.com\n' >"$GIT_CONFIG_GLOBAL"
assert_eq "$( ( export HARNESS_PLATFORM=posix; doctor_windows_prereqs; echo rc=$? ) )" "rc=0" "Linux: doctor_windows_prereqs is a no-op"

finish

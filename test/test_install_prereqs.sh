#!/usr/bin/env bash
# test_install_prereqs.sh — #342: install.sh OFFERS to install what check_prereqs would find missing
# (host package manager, gh auth login, Claude Code via its adapter) instead of only failing.
# Every package manager, sudo, id and gh here is a logging stub on a PATH that holds nothing else
# but a few coreutils; no test runs a real package manager or a real install.sh main.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
export HARNESS_INSTALL_NOMAIN=1 HARNESS_INSTALL_CLI_BIN=0 HARNESS_SKIP_RTDD=1
unset HARNESS_INSTALL_PREREQS CLAUDE_BIN
for v in $(compgen -e | grep -E '^HARNESS_[A-Z]+_BIN$'); do unset "$v"; done
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pin_host_home "$T/home/.harness"   # + the fleet/poller/snapshot pins, unit dirs and user bus (#541)
export HOME="$T/home" HARNESS_HOME="$T/home/.harness"; mkdir -p "$HOME"
source "$HERE/../install.sh"

# SYS: the few real tools the functions under test use; nothing a prerequisite check looks for.
SYS="$T/sys"; mkdir -p "$SYS"
for t in sed grep head cat bash sh mktemp rm env xargs ls tr dirname basename mkdir chmod ln; do
  p="$(command -v "$t")" && ln -s "$p" "$SYS/$t"; done
LOG="$T/log"
# stub <dir> <name> [<body>] — a logging stub: appends "<name> <args>" to $LOG, then runs <body>.
stub(){ mkdir -p "$1"; printf '#!/bin/sh\necho "%s $*" >> %q\n%s\n' "$2" "$LOG" "${3:-exit 0}" > "$1/$2"; chmod +x "$1/$2"; }
# on <dir> — run the rest of the line on PATH=<dir>:$SYS with a fresh hash table.
on(){ local d="$1"; shift; ( hash -r; PATH="$d:$SYS"; "$@" ); }

# ── package names ─────────────────────────────────────────────────────────────────────────────────
for m in apt-get dnf pacman zypper apk brew; do
  assert_ok "$m: sha256sum comes from coreutils" test "$(pkg_name "$m" sha256sum)" = coreutils
done
assert_ok "pacman: gh is github-cli"     test "$(pkg_name pacman gh)" = github-cli
assert_ok "apk: gh is github-cli"        test "$(pkg_name apk gh)" = github-cli
assert_ok "apt-get: gh is gh"            test "$(pkg_name apt-get gh)" = gh
assert_ok "dnf / zypper / brew: gh is gh" test "$(pkg_name dnf gh)$(pkg_name zypper gh)$(pkg_name brew gh)" = ghghgh
assert_ok "pacman: python3 is python"    test "$(pkg_name pacman python3)" = python
assert_ok "brew: python3 is python"      test "$(pkg_name brew python3)" = python
assert_ok "apt-get: python3 is python3"  test "$(pkg_name apt-get python3)" = python3
for t in git tmux curl tar; do
  assert_ok "pacman: $t is $t" test "$(pkg_name pacman "$t")" = "$t"
done

# ── which package manager ─────────────────────────────────────────────────────────────────────────
D="$T/pm1"; stub "$D" pacman
assert_ok "pkg_manager finds pacman" test "$(on "$D" pkg_manager)" = pacman
D="$T/pm2"; stub "$D" brew; stub "$D" apt-get
assert_ok "pkg_manager prefers the system manager over brew" test "$(on "$D" pkg_manager)" = apt-get
assert_no "pkg_manager fails with none" on "$T/empty" pkg_manager

# ── the exact command ────────────────────────────────────────────────────────────────────────────
U="$T/user"; stub "$U" id 'echo 1000'; stub "$U" sudo 'exec "$@"'
R="$T/root"; stub "$R" id 'echo 0';    stub "$R" sudo 'exec "$@"'
N="$T/nosudo"; stub "$N" id 'echo 1000'
assert_ok "apt-get, not root: sudo on both steps, deduplicated packages" test \
  "$(on "$U" pkg_install_cmd apt-get git sha256sum tar sha256sum)" = \
  "sudo apt-get update && sudo apt-get install -y git coreutils tar"
assert_ok "apt-get as root: no sudo" test \
  "$(on "$R" pkg_install_cmd apt-get git)" = "apt-get update && apt-get install -y git"
assert_ok "not root and no sudo: no sudo" test "$(on "$N" pkg_install_cmd dnf git)" = "dnf install -y git"
assert_ok "pacman maps gh / python3 / sha256sum" test \
  "$(on "$U" pkg_install_cmd pacman gh python3 sha256sum)" = \
  "sudo pacman -S --needed --noconfirm github-cli python coreutils"
assert_ok "zypper" test "$(on "$U" pkg_install_cmd zypper tmux)" = "sudo zypper --non-interactive install tmux"
assert_ok "apk"    test "$(on "$U" pkg_install_cmd apk gh)" = "sudo apk add github-cli"
assert_ok "brew never sudo, even when not root" test "$(on "$U" pkg_install_cmd brew python3 gh)" = "brew install python gh"

# ── offer_prereqs: every tool missing, apt-get on a non-root host ────────────────────────────────
A="$T/apt"; stub "$A" id 'echo 1000'; stub "$A" sudo 'exec "$@"'; stub "$A" apt-get
WANT="sudo apt-get update && sudo apt-get install -y git tmux python3 curl coreutils tar gh"
YES="$T/yes"; printf 'y\n' > "$YES"; NO="$T/no"; printf 'n\n' > "$NO"; ENTER="$T/enter"; printf '\n' > "$ENTER"

: > "$LOG"; out="$(HARNESS_INSTALL_PREREQS=0 on "$A" offer_prereqs 2>&1)"
assert_ok "HARNESS_INSTALL_PREREQS=0 prints the exact install command" grep -qF -- "$WANT" <<<"$out"
assert_no "...and installs nothing" grep -q apt-get "$LOG"

: > "$LOG"; out="$(HARNESS_TTY="$NO" on "$A" offer_prereqs 2>&1)"
assert_ok "answering n prints the exact install command" grep -qF -- "$WANT" <<<"$out"
assert_ok "...after asking" grep -qF '[Y/n]' <<<"$out"
assert_no "...and installs nothing" grep -q apt-get "$LOG"

: > "$LOG"; out="$(HARNESS_TTY="$T/no-such-tty" on "$A" offer_prereqs 2>&1)"
assert_ok "no terminal, no setting: prints the exact install command" grep -qF -- "$WANT" <<<"$out"
assert_no "...asks nothing" grep -qF '[Y/n]' <<<"$out"
assert_no "...and installs nothing" grep -q apt-get "$LOG"
assert_no "...and check_prereqs still fails as today" on "$A" check_prereqs 2>/dev/null

: > "$LOG"; HARNESS_INSTALL_PREREQS=1 on "$A" offer_prereqs >/dev/null 2>&1
assert_ok "HARNESS_INSTALL_PREREQS=1 runs apt-get update through sudo" grep -qx 'sudo apt-get update' "$LOG"
assert_ok "...then installs every missing package" \
  grep -qx 'apt-get install -y git tmux python3 curl coreutils tar gh' "$LOG"
: > "$LOG"; HARNESS_TTY="$YES" on "$A" offer_prereqs >/dev/null 2>&1
assert_ok "answering y installs" grep -qx 'apt-get install -y git tmux python3 curl coreutils tar gh' "$LOG"
: > "$LOG"; HARNESS_TTY="$ENTER" on "$A" offer_prereqs >/dev/null 2>&1
assert_ok "Enter (the default) installs" grep -qx 'apt-get install -y git tmux python3 curl coreutils tar gh' "$LOG"

# ── nothing missing: nothing asked ───────────────────────────────────────────────────────────────
F="$T/full"; for t in git tmux python3 curl sha256sum tar apt-get; do stub "$F" "$t"; done
stub "$F" gh 'exit 0'
C="$T/withclaude"; stub "$C" claude
: > "$LOG"; out="$(HARNESS_TTY="$YES" on "$F:$C" offer_prereqs 2>&1)"
assert_no "all tools, gh signed in and an agent CLI present: nothing offered" grep -qF '[Y/n]' <<<"$out"
assert_no "...nothing run" grep -qE '^(apt-get|gh auth login)' "$LOG"

# ── gh present but signed out ────────────────────────────────────────────────────────────────────
G="$T/gh"; for t in git tmux python3 curl sha256sum tar; do stub "$G" "$t"; done
stub "$G" gh 'case "$1 $2" in "auth status") exit 1;; esac; exit 0'
: > "$LOG"; out="$(HARNESS_TTY="$NO" on "$G" offer_prereqs 2>&1)"
assert_ok "signed-out gh, declined: prints gh auth login" grep -qF 'gh auth login' <<<"$out"
assert_no "...and does not run it" grep -qx 'gh auth login' "$LOG"
: > "$LOG"; HARNESS_TTY="$YES" on "$G" offer_prereqs >/dev/null 2>&1
assert_ok "signed-out gh, accepted: runs gh auth login" grep -qx 'gh auth login' "$LOG"

# ── no agent CLI: Claude Code through the claude adapter's own cli_prereqs --install ─────────────
eval "real_cli_with() $(declare -f cli_with | tail -n +2)"
cli_with(){ if [[ "$*" == "claude cli_prereqs --install" ]]; then echo "ADAPTER $*" >> "$LOG"; else real_cli_with "$@"; fi; }
assert_ok "no agent CLI on the stub PATH" test -z "$(on "$F" _host_clis)"
: > "$LOG"; out="$(HARNESS_TTY="$NO" on "$F" offer_prereqs 2>&1)"
assert_ok "no agent CLI, declined: prints the adapter's install command" \
  grep -qF 'curl -fsSL https://claude.ai/install.sh | bash' <<<"$out"
assert_no "...and installs nothing" grep -q ADAPTER "$LOG"
: > "$LOG"; HARNESS_INSTALL_PREREQS=1 on "$F" offer_prereqs >/dev/null 2>&1
assert_ok "no agent CLI, accepted: runs the claude adapter's cli_prereqs --install" \
  grep -qx 'ADAPTER claude cli_prereqs --install' "$LOG"
: > "$LOG"; out="$(HARNESS_INSTALL_PREREQS=1 on "$F:$C" offer_prereqs 2>&1)"
assert_no "an agent CLI present: Claude Code not offered" grep -q ADAPTER "$LOG"

# ── #431: the vendor installer puts claude in ~/.local/bin, which this shell's PATH lacks ─────────
# The real adapter path (cli_with → claude_prereqs → _cli_bin_ensure) with a stub `curl` that serves
# a stub installer script: it writes $HOME/.local/bin/claude and nothing else. No real installer runs.
eval "cli_with() $(declare -f real_cli_with | tail -n +2)"
V="$T/vendor"; for t in git tmux python3 sha256sum tar; do stub "$V" "$t"; done; stub "$V" gh 'exit 0'
printf '%s\n' 'mkdir -p "$HOME/.local/bin"' \
  'printf "#!/bin/sh\nexit 0\n" > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"' > "$T/claude-install.sh"
stub "$V" curl "cat '$T/claude-install.sh'"
flow(){ offer_prereqs; check_prereqs; }
H="$T/h431"; mkdir -p "$H"
: > "$LOG"; out="$(HOME="$H" HARNESS_INSTALL_CLI_BIN=1 HARNESS_INSTALL_PREREQS=1 on "$V" flow 2>&1)"; rc=$?
assert_ok "stub installer ran (curl fetched it)" grep -q '^curl -fsSL https://claude.ai/install.sh' "$LOG"
assert_ok "...and wrote ~/.local/bin/claude" test -x "$H/.local/bin/claude"
assert_no "claude in ~/.local/bin off PATH, accepted: no MISSING: an agent CLI" grep -qF 'MISSING: an agent CLI' <<<"$out"
assert_ok "...and the prerequisite check passes" test "$rc" = 0
assert_ok "...printing the PATH line to add" grep -qF "export PATH=\"$H/.local/bin:\$PATH\"" <<<"$out"
assert_ok "...and to re-open the shell" grep -qi 're-open your shell' <<<"$out"
assert_ok "...once (the adapter's NOTE and check_prereqs do not both print it)" \
  test "$(grep -cF "export PATH=\"$H/.local/bin:" <<<"$out")" = 1

# a second run: claude is already in ~/.local/bin (still off PATH) — nothing re-offered, check passes
: > "$LOG"; out="$(HOME="$H" HARNESS_INSTALL_CLI_BIN=1 HARNESS_TTY="$YES" on "$V" flow 2>&1)"; rc=$?
assert_no "re-run: Claude Code not offered again" grep -qF '[Y/n]' <<<"$out"
assert_no "...the installer not fetched again" grep -q '^curl' "$LOG"
assert_ok "...the prerequisite check passes" test "$rc" = 0
assert_ok "...and the PATH line is printed" grep -qF "export PATH=\"$H/.local/bin:\$PATH\"" <<<"$out"

# ~/.local/bin already on the user's own PATH: no PATH line
out="$(HOME="$H" on "$V:$H/.local/bin" check_prereqs 2>&1)"
assert_no "~/.local/bin on PATH: no PATH line" grep -qF 'export PATH=' <<<"$out"

# link_path: `harness` lands in ~/.local/bin, which this install put on PATH itself — still told
lp(){ inst_local_bin; link_path; }
out="$(HOME="$H" HARNESS_HOME="$H/.harness" HARNESS_BIN_DIR="$H/.local/bin" on "$V" lp 2>&1)"
assert_ok "link_path into an install-added ~/.local/bin prints the PATH line" \
  grep -qF "export PATH=\"$H/.local/bin:\$PATH\"" <<<"$out"
lp2(){ flow >/dev/null 2>&1; link_path; }
out="$(HOME="$H" HARNESS_HOME="$H/.harness" HARNESS_BIN_DIR="$H/.local/bin" on "$V" lp2 2>&1)"
assert_ok "...even after claude's own PATH line for the same directory" \
  grep -qF "export PATH=\"$H/.local/bin:\$PATH\"" <<<"$out"
out="$(HOME="$H" HARNESS_HOME="$H/.harness" HARNESS_BIN_DIR="$H/.local/bin" on "$V:$H/.local/bin" lp 2>&1)"
assert_no "link_path into a ~/.local/bin already on PATH: no PATH line" grep -qF 'export PATH=' <<<"$out"

# ── main offers before it checks, and again once a piped install's adapters arrive ───────────────
body="$(declare -f main)"
assert_ok "main offers before its first check_prereqs" \
  test "$(grep -nE 'offer_prereqs|check_prereqs' <<<"$body" | head -2 | grep -c offer_prereqs)" -ge 1
assert_ok "main offers again after loading a piped install's adapters" \
  grep -qE '_load_cli_seam && offer_prereqs && check_prereqs' <<<"$body"
finish

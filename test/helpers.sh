#!/usr/bin/env bash
# helpers.sh — minimal bash test rig + temp-env setup for the harness pool logic.
# Sourced by test_*.sh AFTER sourcing ../scripts/lib.sh (and ../scripts/drive.sh where needed).
# Overrides unit_complete so tests control "which units are COMPLETE" without GitHub.
TESTS_RUN=0; TESTS_FAIL=0
assert_eq(){ TESTS_RUN=$((TESTS_RUN+1)); if [[ "$1" == "$2" ]]; then echo "  ok: $3"; else echo "  FAIL: $3 — want [$2] got [$1]"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }
assert_ok(){ local msg="$1"; shift; TESTS_RUN=$((TESTS_RUN+1)); if "$@"; then echo "  ok: $msg"; else echo "  FAIL: $msg — expected success from: $*"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }
assert_no(){ local msg="$1"; shift; TESTS_RUN=$((TESTS_RUN+1)); if "$@"; then echo "  FAIL: $msg — expected failure from: $*"; TESTS_FAIL=$((TESTS_FAIL+1)); else echo "  ok: $msg"; fi; }
finish(){ echo "── $((TESTS_RUN-TESTS_FAIL))/$TESTS_RUN passed"; [[ $TESTS_FAIL -eq 0 ]]; }

# windows_row_value <row> [doc] — the Windows cell of <row> in the parity matrix of docs/reference.md (#492, PRD #475),
# printed trimmed; rc 1 and nothing printed when the matrix has no such row. HARNESS_PARITY_DOC names another doc
# (the helper's own tests point it at a fixture). Only the `| feature | Linux | Windows |` table is read: the per-CLI
# research table below it shares row names. Pure awk, so it runs in Git Bash as it does on Linux.
windows_row_value(){ local row="$1" doc="${2:-${HARNESS_PARITY_DOC:-$(dirname "${BASH_SOURCE[0]}")/../docs/reference.md}}"
  [[ -r $doc ]] || { echo "windows_row_value: cannot read $doc" >&2; return 1; }
  awk -F'|' -v row="$row" '
    function trim(x){ gsub(/^[ \t\r]+|[ \t\r]+$/, "", x); return x }
    trim($2)=="feature" && trim($3)=="Linux" && trim($4)=="Windows" { on=1; next }
    on && substr($0,1,1)!="|" { on=0 }
    on { f=trim($2); gsub(/^`|`$/, "", f); if (f==row) { print trim($4); found=1; exit } }
    END { exit found ? 0 : 1 }' "$doc"; }

# harness_label_defaults [lib.sh] — every `: "${HARNESS_LABEL_*:=<label>}"` default of scripts/lib.sh, one per line. A
# trailing `# …` comment on the line is allowed (#1053: an end-anchored regex dropped agent-paused, bug, bug-triaged, hitl).
harness_label_defaults(){ sed -nE 's/^: "\$\{HARNESS_LABEL_[A-Z_]+:=([^}]+)\}".*$/\1/p' "${1:-$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh}"; }
# prompt_kebab_leaks <lib.sh> <prompt.md…> — the backticked kebab-case words of those prompts that are none of lib.sh's labels
# (a skill named by hand: `subagent-driven-development`, #321), one per line, backticks kept.
prompt_kebab_leaks(){ local lib="$1"; shift
  grep -ohE '`[a-z][a-z0-9]*(-[a-z0-9]+)+`' "$@" | grep -vxF -f <(harness_label_defaults "$lib" | sed 's/.*/`&`/'); }

# host_is_windows — Git Bash / MSYS / Cygwin, or HARNESS_PLATFORM=windows (the suite's way to force the Windows paths on
# Linux; HARNESS_PLATFORM=posix forces the other way). scripts/portable.sh has the engine's is_windows; this is the
# test rig's, so helpers.sh needs no engine file sourced first.
host_is_windows(){ case "${HARNESS_PLATFORM:-}" in windows) return 0;; posix) return 1;; esac
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0;; *) return 1;; esac; }

# native_path <path> — <path> in the form a NATIVE Windows program reads (`C:/x/y`, cygpath -m) when this host is Windows,
# unchanged elsewhere (#493). Git Bash converts an MSYS path (`/c/x/y`) handed to a native exe, but not one inside a
# command line a native Python lane runner builds itself: `HARNESS_CLAUDE_BIN="python3 /c/x/fake-claude"` made the runner
# open `C:\c\x\fake-claude`, so no headless lane with a fake agent ever ran a turn on winsma (#606). Put the fake's path
# through this: HARNESS_CLAUDE_BIN="python3 $(native_path "$FAKE")".
native_path(){ if host_is_windows && command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# native_wpath <path> — <path> as MSYS hands it to a NATIVE program through the environment or argv (`C:\x\y`, cygpath -w) when this
# host is Windows, unchanged elsewhere (#1108). `HARNESS_TIER_TOML=$T/x.toml python3 …` reaches a native Python as `C:\…\x.toml`, so a
# message that echoes it names that spelling, not the `/c/…` one the test built the fixture with: a test greps its output for this.
native_wpath(){ if host_is_windows && command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# real_windows_host — this machine IS Windows (Git Bash / MSYS / Cygwin), whatever HARNESS_PLATFORM forces. Not host_is_windows:
# a test that forces HARNESS_PLATFORM=posix on Linux still has flock and fcntl; one that does it on winsma does not (#607).
real_windows_host(){ case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0;; *) return 1;; esac; }

# skip_posix_branch <what> — for a cell that exercises the POSIX implementation of a primitive (flock, fcntl, a fd inherited
# by a child, procps `ps -o`) forced with HARNESS_PLATFORM=posix. On a real Windows host that implementation cannot run
# (Git Bash has no flock, Python no fcntl), and the Windows branch of the same primitive is asserted by the file's own
# [windows] cells, which run on every OS (#607). Prints SKIP and returns 0 there, returns 1 anywhere else: write
#   skip_posix_branch "flock fd inheritance" || { …the POSIX cells… }
# It is not a way out of a Windows cell: the Windows branch is never skipped (windows_skip, on an n/a matrix row, is the
# only skip of a feature).
skip_posix_branch(){ real_windows_host || return 1; echo "  SKIP (POSIX branch, no counterpart to run on a Windows host): ${1:-}"; return 0; }
# any_spelling <path> — an ERE group matching <path> in both spellings a Windows host prints it in (/c/x and C:/x); on Linux the path itself.
# The engine echoes HARNESS_HOME / unit lines in the native spelling while a test builds its fixtures in the MSYS one (#608).
any_spelling(){ local n; n="$(native_path "$1")"; if [[ $n == "$1" ]]; then printf '%s' "$1"; else printf '(%s|%s)' "$1" "$n"; fi; }
# On a real Windows host `ln -s` copies unless MSYS says winsymlinks:nativestrict, so every fixture that builds a link (a PATH link,
# the engine symlink, a skill link) and then asserts `-L` read false (#608). install.sh sets it for itself; a test that builds its
# fixtures with a bare `ln -s` needs it too, so it is set once here for every test (test_windows_update.sh/test_install_prereqs.sh do the same).
real_windows_host && [[ " ${MSYS:-} " != *" winsymlinks:nativestrict "* ]] && export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict"
# fake_rtdd_name — the file name a test gives its fake rtdd (#921). On Windows rtdd_exe asks for `rtdd.exe` first, so a fake named bare `rtdd`
# loses to the host's REAL rtdd.exe further down PATH (winsma has one) and the test runs the real binary. A shebang script named rtdd.exe
# runs under Git's bash, and the bare name `rtdd` resolves to it too.
fake_rtdd_name(){ if real_windows_host; then echo rtdd.exe; else echo rtdd; fi; }
# link_tool <name> <dir> — put the PATH's <name> into <dir>, for a fixture PATH of "just these tools" (#921). On Linux a symlink. On a Windows
# host a symlink does not work: `command -v` names an MSYS tool without its .exe, and even a nativestrict link to the .exe cannot be run from a
# PATH that lacks Git's /usr/bin (the link's target is a POSIX path Windows cannot follow, so bash reports 127; install.sh's `dirname` came back
# empty and no CLI adapter loaded). An MSYS exe also needs msys-2.0.dll (and its siblings) beside it, so there the tool is HARD-linked (a copy
# if the volumes differ) as <name>.exe next to hard links of Git's msys-*.dll, once per dir. Tools outside /usr/bin (git) get their own dir's dlls.
link_tool(){ local t="$1" d="$2" p f src; p="$(command -v "$t")" || return 1
  if ! real_windows_host; then ln -sf "$p" "$d/$t"; return; fi
  p="$(readlink -f "$p")"; src="${p%/*}"
  if [[ ! -e $d/.dlls-${src//\//_} ]]; then
    for f in "$src"/*.dll; do [[ -e $f ]] && { ln -f "$f" "$d/" 2>/dev/null || cp "$f" "$d/"; }; done
    [[ $src == /usr/bin ]] || for f in /usr/bin/msys-*.dll; do [[ -e $d/${f##*/} ]] || ln -f "$f" "$d/" 2>/dev/null || cp "$f" "$d/"; done
    : > "$d/.dlls-${src//\//_}"
  fi
  ln -f "$p" "$d/${p##*/}" 2>/dev/null || cp "$p" "$d/${p##*/}"; }
# file_url <path> — a file:// URL native curl can read (#608). Git for Windows' curl is a native exe: `file:///c/x` (the MSYS
# spelling of C:/x) reads C:\c\x, so every fixture that served a fake release from $T/srv got "could not resolve" on winsma and
# install.sh / update.sh / harness update exited 1 or 3. Windows: file:///C:/x/y; elsewhere file:///x/y, as before.
file_url(){ local p; p="$(native_path "$1")"; case "$p" in /*) printf 'file://%s' "$p";; *) printf 'file:///%s' "$p";; esac; }
# sys_path — the PATH a test hands a process it keeps "system tools only" (#608): /usr/bin:/bin on Linux. On Git for Windows curl and
# git are not in /usr/bin: they live in the MSYSTEM's own tree (/ucrt64/bin on winsma, /mingw64/bin elsewhere), so a PATH of
# /usr/bin:/bin alone read "curl: command not found" and install.sh could not resolve the latest release. There the directories of
# the curl, git and python3 on the CALLER's PATH are appended (call it where PATH is still whole: PATH="$STUB:$(sys_path)"). Always real dirs.
sys_path(){ local p=/usr/bin:/bin t d
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*) for t in curl git python3; do d="$(command -v "$t" 2>/dev/null)"; d="${d%/*}"
    [[ -n $d && $d != "$t" && :$p: != *":$d:"* ]] && p="$p:$d"; done;; esac
  printf '%s' "$p"; }
# posix_path <path> — <path> in MSYS form (`/c/x/y`, cygpath -u) when this host is Windows, unchanged elsewhere (#605).
# One directory has two spellings in a Windows run: lib.sh's export_native_paths turns ENGINE_DIR, STATE_DIR, HARNESS_HOME
# ... into `C:/x`, while `pwd`, `realpath` and `mktemp -d` answer `/c/x`. A test that compares two paths, or looks for one in
# a file the engine wrote, must not care which spelling it got: assert_path_eq compares through this, and
# grep_path <path> <file> looks for the path in EITHER spelling.
posix_path(){ if host_is_windows && command -v cygpath >/dev/null 2>&1; then cygpath -u "$1" 2>/dev/null || printf '%s' "$1"; else printf '%s' "$1"; fi; }
# assert_path_eq <got> <want> <msg> — assert_eq on two paths, in any spelling of one place (C:/x, C:\x, /c/x).
assert_path_eq(){ assert_eq "$(posix_path "$1")" "$(posix_path "$2")" "$3"; }
# grep_path <path> <file> — true when <file> holds <path> in its MSYS or its mixed-case Windows spelling (-F, so no regex).
grep_path(){ grep -qF -e "$(posix_path "$1")" -e "$(native_path "$1")" "$2"; }

# alive_any <pid> — the process is alive and not a zombie, by its MSYS pid OR (Windows) by its native one (#606): a fake agent
# written in native Python records os.getpid(), a Windows pid, in calls.jsonl / pids, and MSYS `kill -0` does not know it.
# all_gone <pid…> — none of them is alive (a pid that is empty or not a number counts as gone).
alive_any(){ [[ ${1:-} =~ ^[0-9]+$ ]] || return 1
  if kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; then return 0; fi
  host_is_windows || return 1
  tasklist //FI "PID eq $1" //NH 2>/dev/null | tr -d '\r' | grep -qE "[[:space:]]$1[[:space:]]"; }
all_gone(){ local p; for p in "$@"; do ! alive_any "$p" || return 1; done; }

# windows_skip <matrix row> <why> — the ONE way a test skips itself on Windows. A skip is allowed only when the row it
# names is `n/a` on Windows in the parity matrix (docs/reference.md): Windows physically cannot do that feature.
#   row n/a on Windows : on Windows prints "SKIP (Windows n/a: row '<row>'): <why>" and returns 0; elsewhere returns 1.
#   row ✓ (or ✓ target): FAIL, loudly, on every OS — a feature Windows can do is never skipped there; returns 1.
#   row missing        : FAIL, loudly, on every OS — a typo'd or unlisted row is never a free pass; returns 1.
# A FAIL counts in TESTS_FAIL, so the file ends red even if the caller ignores the status. Use:
#   windows_skip "swarm submission" "needs the Linux HTCondor service" && { finish; exit 0; }
# or windows_skip_file, which does exactly that.
windows_skip(){ local row="$1" why="${2:-}" val
  if ! val="$(windows_row_value "$row")"; then
    TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1))
    echo "  FAIL: windows_skip: the parity matrix has no row '$row' — a Windows skip names a matrix row that is n/a on Windows"; return 1; fi
  case "$val" in
    n/a*) host_is_windows || return 1
          echo "  SKIP (Windows n/a: row '$row'): $why"; return 0;;
    *)    TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1))
          echo "  FAIL: windows_skip: row '$row' is ${val%% *} on Windows, not n/a — Windows runs this test, it may not skip it"; return 1;;
  esac; }
# windows_skip_file <matrix row> <why> — windows_skip for a whole file: when it skips, finish and exit 0 (a file that
# skipped on its n/a row is green); when it does not, a call that FAILed leaves the file to run on and end red.
windows_skip_file(){ if windows_skip "$@"; then finish; exit 0; fi; return 0; }

# config_table_gaps [root] — #1059: the HARNESS_* settings the adapters (scripts/cli/*.sh) read that docs/reference.md's
# Configuration table has no row for, one per line (empty = covered). Harness's own variables — set by the engine, never by an
# operator — are the few in `internal`. test_cli_readme.sh asserts it with the matrix cells (minutes); test_config_table.sh asserts
# the same alone (a second), and is in the always-run guard set (test/guards.sh), so a new setting with no row fails the lane, not the gate.
CONFIG_TABLE_INTERNAL="HARNESS_BOOTSTRAP_PROMPT HARNESS_SESSION HARNESS_ENGINE_PLUGINS HARNESS_CLAUDE_CONFIG HARNESS_AGY_TRUST_FILE"
# HARNESS_BOOTSTRAP_PROMPT: lib.sh's fixed launch prompt. HARNESS_SESSION: a lane variable, set per
# session. HARNESS_ENGINE_PLUGINS: install.sh points it at the placed engine. HARNESS_CLAUDE_CONFIG,
# HARNESS_AGY_TRUST_FILE: test seams (helpers.sh).
config_table_read_vars(){ local root="${1:-$(dirname "${BASH_SOURCE[0]}")/..}"
  ( cd "$root" && grep -ohE '\bHARNESS_[A-Z0-9_]*[A-Z0-9]\b' scripts/cli/*.sh | sort -u ); }
config_table_vars(){ local root="${1:-$(dirname "${BASH_SOURCE[0]}")/..}"
  sed -n '/^## Configuration/,/^### /p' "$root/docs/reference.md" | grep '^| `HARNESS_' | cut -d'|' -f2 | grep -oE 'HARNESS_[A-Z0-9_]+' | sort -u; }
config_table_gaps(){ local root="${1:-$(dirname "${BASH_SOURCE[0]}")/..}"
  comm -23 <(config_table_read_vars "$root") <(config_table_vars "$root") | grep -vxF -f <(tr ' ' '\n' <<<"$CONFIG_TABLE_INTERNAL"); return 0; }

# tmux_needing_tests [dir] — #493 / PRD #475 task 6: the shell tests in <dir> (default: this directory) that need a
# real tmux, one file name per line. A test needs tmux when, outside comments, a line RUNS tmux to start a pane
# (`tmux [-L sock] new-session`, behind an optional `env -u VAR` or `command`) or gates on the binary
# (`command -v tmux` in command position: `if command -v tmux`, `command -v tmux >/dev/null || …`). A string that only
# names such a command (an assertion message, a printf of a fixture) is not in command position and is not counted.
# test/tmux_twins.tsv names the headless twin of every one; test/test_tmux_twins.sh is the grep check that none is left.
tmux_needing_tests(){ local dir="${1:-$(dirname "${BASH_SOURCE[0]}")}" f
  local cp='(^|[;&|({]|[[:space:]](then|do|if)|![[:space:]])[[:space:]]*((if|then|do|while|until)[[:space:]]+)?(![[:space:]]+)?'
  local re="${cp}(command -v tmux[[:space:]]*(>|\|\||&&|\)|;|\$)|(env( -u [A-Za-z_]+)* )?(command )?tmux( -[LS] [^[:space:]]+)* (new-session|new)([[:space:]]|\$))"
  local code   # held in a variable, not piped: `grep -q` quits at its first hit and the upstream grep would die of SIGPIPE under pipefail
  for f in "$dir"/test_*.sh; do [[ -f $f ]] || continue
    code="$(grep -vE '^[[:space:]]*#' "$f")"
    grep -qE "$re" <<<"$code" && basename "$f"; done; return 0; }

# default_signals_prefix — set DEFSIG, a command prefix that starts what follows with SIGINT, SIGHUP and
# SIGQUIT back at their default disposition (#553), and SIGPIPE and SIGXFSZ too (#574: an ignored SIGPIPE turns a
# closed pipe into an EPIPE "write error" on stderr). A non-interactive bash cannot trap, or reset, a
# signal that was ignored when it STARTED, and the disposition is inherited: the suite run from a
# background or nohup context (the auto-release gate) hands every test, and every child a test starts,
# SIGINT as SIG_IGN, so a `trap … INT` in the code under test silently does nothing. `env --default-signal`
# (coreutils >= 9.0) restores them; else a python3 trampoline does, resetting SIGPIPE and SIGXFSZ too —
# python ignores both itself and the exec'd child would inherit that. Use as: "${DEFSIG[@]}" cmd args…
default_signals_prefix(){
  if env --default-signal=INT true >/dev/null 2>&1; then DEFSIG=(env --default-signal=INT,HUP,QUIT,PIPE,XFSZ)
  else
    DEFSIG=(python3 -c 'import os,signal,sys
for n in ("SIGINT","SIGHUP","SIGQUIT","SIGPIPE","SIGXFSZ"):
    if hasattr(signal,n): signal.signal(getattr(signal,n),signal.SIG_DFL)
os.execvp(sys.argv[1],sys.argv[1:])')
  fi
}
# sigint_restorable — can a child started through DEFSIG take a SIGINT even when this shell ignores it?
# Probes it for real (a Git Bash or an old coreutils might not manage it): the child traps INT and exits 0.
sigint_restorable(){
  [[ ${#DEFSIG[@]} -gt 0 ]] || default_signals_prefix
  ( trap '' INT; exec "${DEFSIG[@]}" bash -c 'trap "exit 0" INT; kill -INT $$; sleep 2; exit 1' ) >/dev/null 2>&1
}

# The per-project CONFIG vars lib.sh exports (scripts/lib.sh) — every one of which a pool worker
# hands down to the agent session that may be running this suite. Deliberately EXCLUDES the four
# host PATH pins (HARNESS_HOME / _POLLER_DIR / _SNAPSHOTS_DIR / _FLEETS_DIR): run.sh and make_env set
# those to throwaways on purpose, so unsetting them here would undo the isolation. Every other
# HARNESS_* the engine exports belongs here — snapshot_gate's HARNESS_SNAPSHOT_FILE/_DIR and each
# adapter's _BIN too (#333); test_hermetic.sh fails on any export this list misses.
HARNESS_CONFIG_VARS="HARNESS_MODE HARNESS_OWNER HARNESS_REPO HARNESS_UNIT HARNESS_CHECKOUT HARNESS_SPEC
  HARNESS_AUTONOMOUS HARNESS_POOL HARNESS_CAP HARNESS_POLL HARNESS_PRIORITY_POLL HARNESS_SESS_PREFIX
  HARNESS_LABEL_READY HARNESS_LABEL_PRD HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED
  HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD HARNESS_LABEL_PAUSED HARNESS_LABEL_BUG
  HARNESS_LABEL_BUG_TRIAGED HARNESS_LABEL_HITL HARNESS_LABEL_WAITING_WINSMA HARNESS_AUTHOR_ALLOWLIST HARNESS_USE_POLLER
  HARNESS_PREFIX_COLLISION HARNESS_WORKTREE_HOOK HARNESS_GAUNTLET_ROUNDS HARNESS_CI_GATE HARNESS_SEED_CI HARNESS_DISABLE_CI
  HARNESS_SECURITY_AUDIT HARNESS_SECURITY_AUDIT_ROUNDS HARNESS_USAGE_CHECKPOINT_PCT HARNESS_USAGE_STALE_MIN HARNESS_USAGE_CMD HARNESS_USAGE_STATUSLINE
  HARNESS_GH_RATE_GUARD HARNESS_GH_BUDGET_PCT HARNESS_GH_RATE_TTL HARNESS_BLOCKED_BACKOFF_MIN HARNESS_SELFPARK_GRACE_MIN
  HARNESS_COAUTHOR HARNESS_ENGINE_CHILD_MAX HARNESS_CHURN_COUNT HARNESS_CHURN_MAX_WALL_S HARNESS_CHURN_WINDOW_MIN
  HARNESS_SWARM HARNESS_WINDOWS_HOST HARNESS_SESSION_BACKEND HARNESS_CLI HARNESS_AGY_BIN HARNESS_AGY_FLAGS HARNESS_CODEX_BIN HARNESS_CODEX_FLAGS
  HARNESS_COPILOT_BIN HARNESS_COPILOT_FLAGS HARNESS_OPENCODE_BIN HARNESS_OPENCODE_FLAGS
  HARNESS_AUTORELEASE_DIR HARNESS_RELEASE_REASON HARNESS_RELEASE_REPO HARNESS_RELEASE_CMD
  HARNESS_CLAUDE_BIN HARNESS_CLAUDE_FLAGS HARNESS_HERMES_BIN HARNESS_OPENCLAW_BIN HARNESS_OPENCLAW_TIMEOUT
  HARNESS_TURN_MAX HARNESS_INTERRUPT_WAIT HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR
  HARNESS_MODEL_MANAGER HARNESS_EFFORT_MANAGER HARNESS_MODEL_IMPLEMENTER HARNESS_EFFORT_IMPLEMENTER"

# unset_inherited_config — drop a LIVE fleet's config out of the environment.
#
# The path pins alone were not enough. Config lines are written `: "${VAR:=value}"`, so a pre-set
# env var beats the file BY DESIGN — which means a suite running inside a live agent session read
# that fleet's HARNESS_REPO / HARNESS_AUTONOMOUS instead of the fixture's, and `harness init`'s
# round-trip assertion failed on a developer's machine while passing on a bare one. The product
# behaviour is correct; the test environment was the leak.
#
# CALL IT BEFORE lib.sh IS SOURCED, never after — which is why it is NOT part of make_env. lib.sh
# fills each var with its default at source time, but the runtime readers (sess_orch's
# $HARNESS_SESS_PREFIX, the label lookups) re-read the ENV on every call, so unsetting afterwards
# empties them mid-test rather than restoring defaults. run.sh drops them once before the loop, so
# every test gets a clean process; test_init.sh re-drops for a direct `bash test_init.sh`.
unset_inherited_config(){ unset $HARNESS_CONFIG_VARS; }

# The lane's own identity (#541). A lane exports HARNESS_SESSION (a uuid), HARNESS_ISSUE/PRD/KIND/PREFIX and
# the tmux client's TMUX/TMUX_PANE to everything it runs. sess_sweep kills EVERY process whose environ carries
# HARNESS_SESSION=<uuid>, and lane/stop paths act on the inherited prefix and tmux server — so a test that
# reaches one with the lane's identity kills the lane that is running it (exit 137, ~20 sessions on #541).
# ENGINE_DIR (handled below, not in this list) is the lane's engine: scripts default their engine to it, so a test
# that builds its own engine would act on the lane's instead (test_web_install's uninstall left the unit behind).
# HARNESS_WAIT_FILE (#1084) is the lane's own wait spec (wait_env, #1066). ws_park_spec writes a park spec to it whenever it is set, so a
# test that parked inside a lane overwrote the lane's real job spec with fixture data (#900 acme/widget) and the engine never resumed
# the lane. A test that needs a wait file pins its own per-test path, as test_winsma_park.sh section 9 does.
# Dropped when this file is sourced, so every test is a stranger to the fleet that launched it; a test that
# wants a session sets its own after sourcing.
# HARNESS_ENGINE_STAMP (#682) is the same kind of thing: pool.sh / priority.sh export the worker's engine stamp (#602) and every child
# inherits it, the release gate included. A test's stand-in "unstamped" worker then carries the host's stamp, roll.sh calls it stale
# and kills it (test_engine_roll.sh red at the e902e61 gate). A test that wants a stamped process sets it inline on that process.
HARNESS_LANE_IDENTITY_VARS="HARNESS_SESSION HARNESS_ISSUE HARNESS_PRD HARNESS_KIND HARNESS_PREFIX HARNESS_ENGINE_STAMP HARNESS_WAIT_FILE RTDD_EVENT_LOG TMUX TMUX_PANE"
unset $HARNESS_LANE_IDENTITY_VARS
# …and the user skill dirs a sandboxed host pins (#921). A winsma suite run exports HARNESS_USER_SKILLS (and a lane may export the agy/codex
# ones) so nothing reaches the real home; a test that points HOME at its own fixture then installs skills into the host's pinned dir and reads
# its own empty ~/.claude/skills (setup, rtdd, update, ensure_skills). make_env and each test that wants one re-export its own after this.
unset HARNESS_USER_SKILLS HARNESS_AGY_USER_SKILLS HARNESS_CODEX_USER_SKILLS
# ENGINE_DIR is re-pointed, not just dropped: most tests source lib.sh BEFORE this file, and lib.sh has already
# exported ENGINE_DIR (the lane's, if it was inherited). Unsetting it left them with none ("ENGINE_DIR: unbound
# variable" in cli/claude.sh). The repo under test is its own engine; a test that sources no lib.sh has none.
if [[ -n "${HARNESS_DIR:-}" ]]; then export ENGINE_DIR="$HARNESS_DIR"; else unset ENGINE_DIR; fi

# ── the host seam: ONE list, ONE helper (#541) ─────────────────────────────────────────────────────
# Every fleet process exports HARNESS_FLEETS_DIR / HARNESS_POLLER_DIR / HARNESS_SNAPSHOTS_DIR (lib.sh)
# and a lane inherits them, and every reader PREFERS the inherited value over the HARNESS_HOME a test
# sets for itself. A test that sets HARNESS_HOME alone therefore still reads — and, through
# `harness supervise` / `harness update`, ROLLS — every real fleet on the host (#541: workers of every
# fleet killed and relaunched from a test sandbox's engine). pin_host_home is the one place that
# re-pins every host path under a throwaway home; run.sh, make_env and each test that picks its own
# HARNESS_HOME go through it, and test_hermetic.sh fails on a test that does not.
#
# <VAR>:<subdir> — re-pinned to <home>/<subdir>.
HARNESS_HOST_PIN_VARS="HARNESS_FLEETS_DIR:fleets HARNESS_POLLER_DIR:poller HARNESS_SNAPSHOTS_DIR:snapshots
  TMUX_TMPDIR:tmux XDG_CONFIG_HOME:config"
# Inherited path pins with a default derived from HARNESS_HOME: dropped, so the default lands in the sandbox.
# (The unit dirs are dropped, not pinned: web.sh / supervise.sh default them to $XDG_CONFIG_HOME/systemd/user —
# pinned above — on Linux and to $HARNESS_HOME/tasks on Windows; a pin to one dir would break the Windows default.)
HARNESS_HOST_DROP_VARS="HARNESS_WEB_UNIT_DIR HARNESS_SUPERVISE_UNIT_DIR HARNESS_HEADLESS_DIR HARNESS_LANE_DIR HARNESS_PARKED_FILE HARNESS_GH_RATE_DIR
  HARNESS_EVENTS_FILE HARNESS_RTDD_EVENTS_FILE HARNESS_SUPERVISE_CONF HARNESS_SUPERVISE_STATE HARNESS_SUPERVISE_LOG"
# The user service manager is host state too: web.sh / supervise.sh `systemctl --user` / `loginctl` against
# the live bus and write units into ~/.config/systemd/user (the live harness-web.service was stopped and
# its unit file deleted by a test that did, #541). A tool that fails is what a host with no bus does.
HARNESS_HOST_FAIL_TOOLS="HARNESS_WEB_SYSTEMCTL HARNESS_WEB_LOGINCTL HARNESS_SUPERVISE_SYSTEMCTL HARNESS_SUPERVISE_LOGINCTL"
HARNESS_HOST_DROP_BUS="XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS"
# HARNESS_NATIVE_PATH_VARS (scripts/portable.sh) members that need no pin here, and why. A name in that
# list that is in neither list above nor here fails test_hermetic.sh: a new host path must be decided.
#   ENGINE_DIR RUN_DIR — per-test engine / run dir, set by each test or make_env, never inherited from a host path
#   STATE_DIR — project state; re-pinned by run.sh and make_env (not a host path)
#   HARNESS_HOME — the root this helper is given
#   HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR — per-project config, dropped by unset_inherited_config
#   CLAUDE_CONFIG_DIR — Claude Code's config dir, dropped by make_env
HARNESS_HOST_PATH_EXEMPT="ENGINE_DIR RUN_DIR STATE_DIR HARNESS_HOME HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR CLAUDE_CONFIG_DIR"
# tmux_guard_install — put test/guard/tmux first on PATH, once (#649). tmux does not fail when TMUX_TMPDIR names a MISSING
# directory: it silently uses /tmp/tmux-$UID/, the host's DEFAULT server. A test that wipes the private home it pinned and then
# calls tmux (test_supervise_autoupdate.sh's fresh_host did) therefore killed every lane on the host, three times on 2026-11-07.
# The guard refuses (exit 97, loud) any tmux call made while TMUX_TMPDIR is unset, empty, missing or /tmp, and otherwise execs
# the next tmux on PATH. run.sh installs it for the whole suite; pin_host_home for a direct `bash test_foo.sh`.
TMUX_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guard"
# The guard exists to stop a test reaching the host's tmux server, so it is on PATH only while a real tmux is (#655). With none
# behind it `command -v tmux` would still succeed and every gate on it would take its tmux branch and die with 127 instead of
# skipping or running its headless twin (native Windows, tmux-less slots, test_tmux_twins.sh): then it is taken OUT of PATH,
# also when run.sh inherited it. Stubs are shell functions or sit on PATH before this call; a tmux that appears on PATH later
# is the test's own.
tmux_guard_real_tmux(){ local e self; self="$(cd "$TMUX_GUARD_DIR" && pwd -P)"
  while IFS= read -r e; do
    [[ -n $e && -x $e/tmux && -f $e/tmux && "$(cd "$e" 2>/dev/null && pwd -P)" != "$self" ]] && return 0
  done < <(tr ':' '\n' <<<"$PATH"); return 1; }
tmux_guard_install(){ [[ -x $TMUX_GUARD_DIR/tmux ]] || { echo "tmux_guard_install: $TMUX_GUARD_DIR/tmux is missing — not running unguarded" >&2; return 1; }
  if ! tmux_guard_real_tmux; then
    PATH="$(tr ':' '\n' <<<"$PATH" | grep -vxF "$TMUX_GUARD_DIR" | paste -sd: -)"; export PATH; return 0; fi
  case ":$PATH:" in ":$TMUX_GUARD_DIR:"*) ;; *) PATH="$TMUX_GUARD_DIR:$(tr ':' '\n' <<<"$PATH" | grep -vxF "$TMUX_GUARD_DIR" | paste -sd: -)"; export PATH;; esac; }
# tmux_short_dir (#1077) — a private TMUX_TMPDIR whose socket path stays short, whatever $TMPDIR is. A tmux socket is
# $TMUX_TMPDIR/tmux-$UID/<name>, and an AF_UNIX path is at most 107 bytes. A dir made by `mktemp -d` or under $RUN_DIR inherits the whole
# depth of $TMPDIR (the release gate's /tmp/tmp.X/gate-tmp/tmp.Y, then run.sh's <test>/tmp, then the test's own mktemp, #1060) and came to
# 110-126 bytes: "error connecting to … (File name too long)". So the dir is made directly under /tmp, tracked (tmp_track, #294: the test's
# EXIT trap must run tmp_cleanup) and private: it exists and is never /tmp itself, which test/guard/tmux (#649) refuses. Sets and exports
# TMUX_TMPDIR (and TMUX_SHORT_DIR), drops the lane's TMUX / TMUX_PANE. It must run in the shell that owns the test's EXIT trap, not in
# a $(…): a command substitution would track the dir in its own subshell and remove it on return.
tmux_short_dir(){ local d
  d="$(mktemp -d "${HARNESS_TMUX_SHORT_ROOT:-/tmp}/hxsock.XXXXXX" 2>/dev/null)" || d="$(mktemp -d)" || return 1
  tmp_track "$d"; TMUX_SHORT_DIR="$d"; export TMUX_TMPDIR="$d"; unset TMUX TMUX_PANE; }
# pin_host_home <dir> — export HARNESS_HOME=<dir> and everything that would otherwise point at the host.
# Creates nothing: a test may assert on a host root that does not exist yet.
pin_host_home(){ local home="$1" e v
  [[ -n "$home" ]] || { echo "pin_host_home: no home given" >&2; return 1; }
  export HARNESS_HOME="$home"
  for e in $HARNESS_HOST_PIN_VARS; do export "${e%%:*}=$home/${e#*:}"; done
  mkdir -p "$TMUX_TMPDIR"; unset $HARNESS_LANE_IDENTITY_VARS   # ops 2026-11-05: a private tmux server; unset TMUX alone still reached /tmp/tmux-$UID/default (live lanes)
  tmux_guard_install || return 1
  unset $HARNESS_HOST_DROP_VARS $HARNESS_HOST_DROP_BUS
  for v in $HARNESS_HOST_FAIL_TOOLS; do export "$v=false"; done
  POLLER_REGISTRY_DIR="$HARNESS_POLLER_DIR/registry"; POLLER_PID="$HARNESS_POLLER_DIR/poller.pid"; POLLER_LOCK="$HARNESS_POLLER_DIR/poller.lock"
}

# Temp hygiene (#294). make_env's RUN_DIR holds stubs, claims, state and tmux sockets — thousands of
# inodes — and a script calls make_env many times, so an unremoved one per call exhausted a shared
# host's /tmp. tmp_track records a path; tmp_cleanup removes every recorded one. The first
# tmp_track in a shell installs `tmp_cleanup` as its EXIT trap, AFTER any trap already set there. A
# test that sets its OWN EXIT trap later replaces this one, so it must call tmp_cleanup last itself:
#   trap 'tmux kill-server 2>/dev/null; tmp_cleanup' EXIT
# A subshell inherits the list but not the trap: its first tmp_track starts a list of its own, so
# its exit removes only what it made and never the parent's RUN_DIR.
TMP_TRACKED=(); TMP_OWNER=""
# A no-op in a subshell that tracked nothing itself: the list it inherited is the parent's to remove.
tmp_cleanup(){ [[ "$TMP_OWNER" == "$BASHPID" ]] || return 0
  (( ${#TMP_TRACKED[@]} )) && { tmp_kill_rooted "${TMP_TRACKED[@]}"; rm -rf "${TMP_TRACKED[@]}"; }
  TMP_TRACKED=(); return 0; }
# tmp_kill_rooted <dir>… (#419) — stop this user's processes rooted in any <dir>: cwd inside one, or a
# STATE_DIR / HARNESS_HOME / HARNESS_LANE_DIR in their environment inside one. A test that dies before
# its own kill-trap (SIGKILL, a timeout, a branch starting what it should refuse) otherwise leaves the
# workers and lanes it started polling a deleted home for days. By PATH only — never a command-line
# pattern, this is a shared host — and never this shell or an ancestor of it. TERM, then KILL what is
# still up after 2s. No /proc (macOS, Git Bash): nothing to read, so nothing is killed.
tmp_kill_rooted(){ local proc="${HARNESS_PROC_ROOT:-/proc}"
  [[ -d "$proc/self" ]] && command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$proc" "$BASHPID" "$@" <<'PY' 2>/dev/null || true
import os, signal, sys, time
proc, me, dirs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
# A root is a test's own throwaway dir. One that is shallow (/, /home, /tmp, $HOME…) or that CONTAINS $HOME or the host's real
# ~/.harness would match every live worker and lane of the user running the suite (#649: pool workers died during host test runs),
# so it is ignored — never "everything under it".
home = os.path.realpath(os.environ.get("HOME", "/nonexistent"))
def broad(d):
    rd = os.path.realpath(d)
    if len([c for c in rd.split("/") if c]) < 3:
        return True
    return any(h == rd or h.startswith(rd + "/") for h in (home, home + "/.harness"))
roots = {r for d in dirs if d.strip("/") and not broad(d) for r in (d.rstrip("/"), os.path.realpath(d))}
inside = lambda p: any(p == r or p.startswith(r + "/") for r in roots)
def status(pid, key):
    try:
        for line in open(f"{proc}/{pid}/status"):
            if line.startswith(key + ":"):
                return line.split()[1]
    except (OSError, IndexError):
        pass
    return ""
keep, chain, p = {os.getpid(), os.getppid()}, set(), me   # this script, its shell, and every ancestor
while p > 1 and p not in chain:
    chain.add(p); ppid = status(p, "PPid"); p = int(ppid) if ppid.isdigit() else 0
keep |= chain
uid, hits = os.getuid(), []
for e in os.listdir(proc):
    if not e.isdigit() or int(e) in keep:
        continue
    try:
        if os.stat(f"{proc}/{e}").st_uid != uid:
            continue
        cwd = os.readlink(f"{proc}/{e}/cwd")
    except OSError:
        continue
    hit = inside(cwd[:-len(" (deleted)")] if cwd.endswith(" (deleted)") else cwd)
    if not hit:
        try:
            env = open(f"{proc}/{e}/environ", "rb").read().split(b"\0")
        except OSError:
            env = []
        hit = any(k in (b"STATE_DIR", b"HARNESS_HOME", b"HARNESS_LANE_DIR") and v and inside(os.fsdecode(v))
                  for k, _, v in (kv.partition(b"=") for kv in env))
    if hit:
        hits.append(int(e))
def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return status(pid, "State") != "Z"
for sig in (signal.SIGTERM, signal.SIGKILL):
    for pid in hits:
        try:
            os.kill(pid, sig)
        except OSError:
            pass
    deadline = time.time() + 2
    while sig == signal.SIGTERM and time.time() < deadline and any(alive(p) for p in hits):
        time.sleep(0.05)
    hits = [p for p in hits if alive(p)]
PY
}
tmp_track(){
  if [[ "$TMP_OWNER" != "$BASHPID" ]]; then
    local prev=""
    # Only the top-level shell keeps an earlier trap: in a subshell `trap -p` reports the PARENT's.
    if [[ "$BASHPID" == "$$" ]]; then prev="$(trap -p EXIT)"; else TMP_TRACKED=(); fi
    TMP_TRACKED+=("$@"); TMP_OWNER="$BASHPID"
    # `trap -p` prints `trap -- 'CMD' EXIT`; re-split it (this clobbers $@, already recorded) for CMD.
    if [[ -n "$prev" ]]; then eval "set -- $prev"; trap -- "$3; tmp_cleanup" EXIT; else trap tmp_cleanup EXIT; fi
    return 0
  fi
  TMP_TRACKED+=("$@")
}
make_env(){
  RUN_DIR="$(mktemp -d)"; tmp_track "$RUN_DIR"; CLAIMS_DIR="$RUN_DIR/claims"; POOL_LOCK="$RUN_DIR/pool.lock"; PAUSE_FLAG="$RUN_DIR/PAUSED"; mkdir -p "$CLAIMS_DIR"
  # #610: a lane launch makes its own TMPDIR under the tmp root (lane_tmpdir); in a test that is RUN_DIR, never the host's /tmp.
  export HARNESS_TMP_ROOT="$RUN_DIR/tmproot"; mkdir -p "$HARNESS_TMP_ROOT"
  # Hermetic state. lib.sh honours an inherited STATE_DIR (scripts/lib.sh:15) and every pool worker
  # exports its project's own to every child, so a test run inside a live agent session resolved
  # CONFIG / WORKTREES_DIR / CHECKOUTS_DIR at that fleet's REAL .harness/ and wrote to it. Re-pin
  # STATE_DIR and everything lib.sh derived from it; export it so child processes (init.sh, spawned
  # scripts) inherit the throwaway one too. Isolating WORKTREES_DIR per test was the old opt-in fix —
  # this makes it the default. See test_hermetic.sh.
  export STATE_DIR="$RUN_DIR/state"
  CONFIG="$STATE_DIR/config"; WORKTREES_DIR="$STATE_DIR/worktrees"; CHECKOUTS_DIR="$STATE_DIR/checkouts"
  # PROJECT_ROOT too: lib.sh:17 derives it from STATE_DIR at source time, and unit_checkout /
  # bug_checkout return it as THE checkout in single topology — leaving it behind would point a
  # test's git operations at the live repo, and would break lib.sh's own
  # "PROJECT_ROOT is the parent of STATE_DIR" invariant (test_path_split.sh).
  PROJECT_ROOT="$RUN_DIR"
  # Host-level state too (lib.sh:86-92). HARNESS_HOME defaults to ~/.harness and is NOT derived from
  # STATE_DIR, so pinning STATE_DIR alone still let tests write the real host poller registry — which
  # is shared by every co-resident fleet, so fixture entries there make `harness start` abort a real
  # fleet on a bogus prefix collision. Same seam, different root.
  pin_host_home "$RUN_DIR/host"   # HARNESS_HOME and every host path under it (one list, above)
  # #183: the rate-limit guard probes `gh api rate_limit` from issuelib — a real network call from a
  # test with no stubbed gh binary. Off by default; test_ghrate.sh turns it on against its stub.
  export HARNESS_GH_RATE_GUARD=0
  # The host FLEET registry is the same seam one notch worse (lib.sh:99-100): it too prefers an
  # inherited value over the HARNESS_HOME just set and is exported by every fleet process, but its
  # entries are DELETED by `doctor --fix` (test_doctor.sh calls doctor_main --fix before its own
  # fleet block pins anything) — so an unpinned suite strips a live sibling fleet's prefix
  # reservation off the real host, not just litters it. Pin it beside HARNESS_HOME, before any test
  # can reach it. See test_hermetic.sh's fleet-decoy block.
  # Claude Code's config too. ensure_trusted seeds EVERY config the launched pane could read —
  # ~/.claude.json, $CLAUDE_CONFIG_DIR/.claude.json, and each ~/.claude-switch/accounts/*/.claude.json
  # — so a test run inside a live agent session (which exports CLAUDE_CONFIG_DIR via .bashrc) wrote
  # fixture /tmp paths straight into the developer's real per-account config. Pin the seam to a
  # throwaway by default and drop the inherited config dir; tests that exercise the fan-out override
  # both explicitly (test_spawn.sh group 3b). Same seam, different root.
  export HARNESS_CLAUDE_CONFIG="$RUN_DIR/claude.json"
  export HARNESS_AGY_TRUST_FILE="$RUN_DIR/agy-settings.json"
  # …and agy's own state dir (#188: conversation ids, transcripts, the usage-window cache).
  export HARNESS_AGY_HOME="$RUN_DIR/agy-home"
  # …and Codex's home (#257: config.toml trust entries, rollouts, the harness-ralph plugin).
  export CODEX_HOME="$RUN_DIR/codex-home"
  # …and Copilot's (#259: config.json trust entries, session-state transcripts).
  export COPILOT_HOME="$RUN_DIR/copilot-home"
  # …and OpenCode's data dir (#261: the opencode.db its sessions and usage live in).
  export XDG_DATA_HOME="$RUN_DIR/xdg-data"
  # …and the operator's Hermes home each lane's own is seeded from (#263: its config.yaml, login, runtime).
  export HARNESS_HERMES_HOME="$RUN_DIR/hermes-home"
  # …and the user skill dirs `harness setup --install` and rtdd_skill_install write into (#303: the
  # handoff skill). Copilot's lives under COPILOT_HOME, pinned above.
  export HARNESS_USER_SKILLS="$RUN_DIR/user-skills" HARNESS_AGY_USER_SKILLS="$RUN_DIR/agy-skills"
  export HARNESS_CODEX_USER_SKILLS="$RUN_DIR/codex-skills"
  # …and `--install`'s fetch of a missing CLI binary (#316): a real npm/curl install off the host's
  # PATH. The matrix's prereqs-named cell turns it back on against its stub npm and curl.
  export HARNESS_INSTALL_CLI_BIN=0
  # …and the label seeding a non-interactive `harness init` does when gh is signed in (#432): a real
  # `gh label create` on the fixture's acme/widget. test_init.sh turns it on against its stub gh.
  export HARNESS_INIT_SEED=0
  # …and the CLIs whose usage windows are read by RUNNING them (#404): agy_limit_usage,
  # hermes_limit_usage and openclaw_limit_usage run `agy` / `hermes` / `openclaw` off PATH, so every
  # usage_watch ran the host's real binary on the operator's real account — a host near its agy weekly
  # limit opened a usage hold in the fixture (test_ghrate.sh). A failing stub of each goes first on
  # PATH; the launch lines still name the bare binary, and a suite that drives its own stub through
  # HARNESS_<CLI>_BIN (or a PATH of its own) still reaches that one. See test_hermetic.sh.
  local cli_stubs="$RUN_DIR/cli-stubs" c; mkdir -p "$cli_stubs"
  for c in agy hermes openclaw; do printf '#!/usr/bin/env bash\nexit 1\n' > "$cli_stubs/$c"; chmod +x "$cli_stubs/$c"; done
  export PATH="$cli_stubs:$PATH"
  unset CLAUDE_CONFIG_DIR
  # …and the transcript search stats.py does for session_end usage (#185): read-only, but a test must
  # not pick up a real session's usage either.
  export HARNESS_CLAUDE_CONFIG_DIRS="$RUN_DIR/claude-config"
  POLLER_REGISTRY_DIR="$HARNESS_POLLER_DIR/registry"
  POLLER_PID="$HARNESS_POLLER_DIR/poller.pid"; POLLER_LOCK="$HARNESS_POLLER_DIR/poller.lock"
  mkdir -p "$WORKTREES_DIR" "$CHECKOUTS_DIR" "$POLLER_REGISTRY_DIR" "$HARNESS_SNAPSHOTS_DIR"
  TARGETS_TSV="$RUN_DIR/targets.tsv"; COMPLETE_SET="$RUN_DIR/complete.set"; : > "$TARGETS_TSV"; : > "$COMPLETE_SET"; POLL=0
  # TEST-ONLY unit registry (the engine has none since #473: one fleet = one repo = one unit). Engine tests
  # whose subject is unit-agnostic (claims, the stall banner, supervise, usage…) still want several named
  # units to tell their claims/sessions apart, so write_targets feeds them rows of
  # `id <TAB> repo <TAB> deps <TAB> desc` and these overrides read them — a fixture seam like unit_complete
  # below, never engine behavior. With no rows written the real one-repo functions answer.
  _fx_row(){ awk -F'\t' -v s="$1" '!/^#/ && $1==s {print; exit}' "$TARGETS_TSV"; }
  _fx_rows(){ [[ -s "$TARGETS_TSV" ]] && grep -qv '^#' "$TARGETS_TSV"; }
  all_units(){ if _fx_rows; then awk -F'\t' '!/^#/ && NF>=2 {print $1}' "$TARGETS_TSV"; else fleet_unit; fi; }
  unit_repo(){ if _fx_rows; then _fx_row "$1" | awk -F'\t' '{print $2}'; else echo "$HARNESS_REPO"; fi; }
  unit_desc(){ if _fx_rows; then _fx_row "$1" | awk -F'\t' '{print $4}'; else echo "${HARNESS_REPO##*/}"; fi; }
  unit_checkout(){ if _fx_rows; then echo "$CHECKOUTS_DIR/$(unit_repo "$1" | sed 's#.*/##')"; else fleet_checkout; fi; }
  unit_complete(){ grep -qxF "$1" "$COMPLETE_SET" 2>/dev/null; }
}
# gitattr_eol <tree> <path>… — the eol attribute <tree>'s own .gitattributes gives each path, one per
# line (#404). Asked of a throwaway repository holding only a copy of that file, so it answers for a
# tree that is no git repository: release.sh gates on a `git archive` extract, where `git -C <tree>
# check-attr` dies "not a git repository" and an assertion on it fails on the gate, not the file.
# The host's own attribute files are left out, so only the tree's decides. No .gitattributes: rc 1.
gitattr_eol(){ local tree="$1" t out rc=1; shift
  [[ -f "$tree/.gitattributes" ]] || { echo "gitattr_eol: no $tree/.gitattributes" >&2; return 1; }
  t="$(mktemp -d)" || return 1
  if git init -q "$t" && cp "$tree/.gitattributes" "$t/"; then
    out="$(GIT_ATTR_NOSYSTEM=1 git -C "$t" -c core.attributesFile=/dev/null check-attr eol -- "$@")" && rc=0
  fi
  rm -rf "$t"; (( rc == 0 )) && sed 's/.*: //' <<<"$out"; return $rc; }
write_targets(){ cat > "$TARGETS_TSV"; }
set_complete(){ printf '%s\n' "$@" > "$COMPLETE_SET"; [[ $# -eq 0 ]] && : > "$COMPLETE_SET"; }
unit_complete(){ grep -qxF "$1" "$COMPLETE_SET" 2>/dev/null; }

# tmux_only_tree <dest> — a copy of scripts/ and test/smoke/*.sh under <dest> with a made-up CLI, `fakecli`, that has no
# headless adapter. Every real CLI has one (#486 was the last), so the tests of the tmux-only refusal ride on this one:
# point HARNESS_CLI=fakecli at <dest>/scripts/... (a script, or `source <dest>/scripts/cli/dispatch.sh`).
tmux_only_tree(){ local src; src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mkdir -p "$1/test/smoke" && cp -r "$src/scripts" "$1/scripts" && cp "$src"/test/smoke/*.sh "$1/test/smoke/" &&
    printf '# fakecli — a made-up CLI with no headless adapter (the tests of the tmux-only refusal)\nfakecli_bin(){ echo fakecli; }\n' > "$1/scripts/cli/fakecli.sh"; }

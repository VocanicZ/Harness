#!/usr/bin/env bash
# portable.sh — the engine's process and locking primitives, one function each, so the engine runs
# under Git Bash on native Windows as well as on Linux (#355, docs/adr/0001-native-windows-runtime.md).
#
# Every `flock`, `/proc` read, `pgrep`, `setsid`, `uuidgen` and procps `ps -o` use in the engine goes
# through here; test/test_portable_guard.py fails on a raw one anywhere else (with a reasoned
# allowlist). Each helper's POSIX branch is the implementation the engine ran before #355, moved
# behind a function, so Linux behaviour is unchanged. The Windows branch is taken when `uname -s`
# says MINGW*/MSYS*/CYGWIN* — or when HARNESS_PLATFORM=windows forces it, which is how the suite
# runs the Windows paths on Linux (HARNESS_PLATFORM=posix forces the other way).
#
# HARNESS_PROC_ROOT (default /proc) is where the /proc readers look: a test points it at a fake tree.
#
# Sourced by lib.sh, cli/dispatch.sh, session/dispatch.sh and uninstall.sh; safe to source twice.
[[ -n "${_HARNESS_PORTABLE_SOURCED:-}" ]] && return 0
_HARNESS_PORTABLE_SOURCED=1

case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _HARNESS_OS=windows;; *) _HARNESS_OS=posix;; esac
# is_windows — true on Git Bash / MSYS (or under HARNESS_PLATFORM=windows).
is_windows(){ [[ "${HARNESS_PLATFORM:-$_HARNESS_OS}" == windows ]]; }

# ---------------------------------------------------------------------------------------- locks ---
# lock_acquire <file> <var> [fd]  — block until <file>'s lock is held; <var> receives the handle that
# lock_release takes. lock_try is the same, non-blocking: rc 1 (nothing held) when someone holds it.
#   POSIX:   `exec {fd}>file; flock fd` — the handle is the fd (a fixed [fd] when given, e.g. start.sh's
#            9, which its spawns close with `9>&-`). Held until released or the fd's last copy closes.
#   Windows: there is no flock. An atomic `mkdir <file>.d` takes it, with an `owner` file
#            (`pid<TAB>winpid<TAB>cmdline`, written by rename so it is never read half-written); the
#            handle is that directory. A lock whose owner pid is dead — or that has had no owner for
#            HARNESS_LOCK_STALE_S seconds (its taker died between mkdir and writing it) — is stale,
#            and the next taker steals it, the way a dead holder's fd closing frees a flock.
lock_acquire(){ _lock_take "$1" "$2" block "${3:-}"; }
lock_try(){ _lock_take "$1" "$2" try "${3:-}"; }
_lock_take(){ local __lk_f="$1" __lk_v="$2" __lk_mode="$3" __lk_fd="$4"
  if ! is_windows; then
    if [[ -n $__lk_fd ]]; then eval "exec $__lk_fd>\"\$__lk_f\"" || return 1
    else exec {__lk_fd}>"$__lk_f" || return 1; fi
    if [[ $__lk_mode == block ]]; then flock "$__lk_fd"; else flock -n "$__lk_fd"; fi \
      || { eval "exec $__lk_fd>&-"; return 1; }
    printf -v "$__lk_v" '%s' "$__lk_fd"; return 0
  fi
  while :; do
    _mlock_try "$__lk_f" && { printf -v "$__lk_v" '%s' "$__lk_f.d"; return 0; }
    [[ $__lk_mode == block ]] || return 1
    sleep "${HARNESS_LOCK_POLL:-0.1}"
  done; }
# lock_release <handle> — release what lock_acquire / lock_try took (an empty handle is a no-op).
lock_release(){ local __lk_h="${1:-}"
  [[ -n $__lk_h ]] || return 0
  if [[ $__lk_h =~ ^[0-9]+$ ]]; then flock -u "$__lk_h" 2>/dev/null; eval "exec $__lk_h>&-"; return 0; fi
  rm -f "$__lk_h/owner"; rmdir "$__lk_h" 2>/dev/null; return 0; }
# lock_free <file> — true iff <file>'s lock could be taken right now. Never itself leaves a holder.
lock_free(){
  if ! is_windows; then ( flock -n 9 ) 9>"$1" 2>/dev/null; return; fi
  [[ ! -d "$1.d" ]] || _mlock_stale "$1.d"; }
# lock_holders <file> — one `PID<TAB>cmdline` line per process holding <file>'s lock.
#   POSIX: every process with the file open (any fd), found by a /proc/*/fd scan (fuser/lsof are not
#          guaranteed on a host) — the answer behind the fd-leak wedge, where an orphaned child keeps
#          an inherited flock fd open. Deduped by pid.
#   Windows: the lock's owner, when it is alive.
lock_holders(){ local lf="$1" rl fd tgt pid seen=" " p="${HARNESS_PROC_ROOT:-/proc}"
  if is_windows; then
    local o; o="$(_mlock_owner "$lf.d")" || return 0
    pid="${o%%$'\t'*}"; proc_alive "$pid" || return 0
    printf '%s\t%s\n' "$pid" "${o##*$'\t'}"; return 0
  fi
  rl="$(readlink -f "$lf" 2>/dev/null)" || return 0
  [[ -n "$rl" ]] || return 0
  for fd in "$p"/[0-9]*/fd/*; do
    tgt="$(readlink "$fd" 2>/dev/null)" || continue
    [[ "$tgt" == "$rl" ]] || continue
    pid="${fd#"$p"/}"; pid="${pid%%/*}"
    [[ "$seen" == *" $pid "* ]] && continue
    seen+="$pid "
    printf '%s\t%s\n' "$pid" "$(proc_cmdline "$pid")"
  done; }
: "${HARNESS_LOCK_STALE_S:=30}"
_mlock_owner(){ local o; [[ -s "$1/owner" ]] && IFS= read -r o < "$1/owner" && printf '%s\n' "$o"; }
_mlock_stale(){ local d="$1" o m now
  if o="$(_mlock_owner "$d")"; then ! proc_alive "${o%%$'\t'*}"; return; fi
  [[ -d $d ]] || return 0
  m="$(stat -c %Y "$d" 2>/dev/null)" || return 1; now="$(date +%s)"
  (( now - m >= HARNESS_LOCK_STALE_S )); }
_mlock_try(){ local f="$1" d="$1.d" me="$BASHPID" seen aside
  if mkdir "$d" 2>/dev/null; then
    printf '%s\t%s\t%s\n' "$me" "$(proc_winpid "$me")" "$(proc_cmdline "$me")" > "$d/.owner.$me" \
      && mv -f "$d/.owner.$me" "$d/owner"
    return 0
  fi
  _mlock_stale "$d" || return 1
  # Steal: rename the stale lock aside (atomic: of two waiters that both saw it stale, one moves it),
  # then check it IS the one judged stale — if a third taker re-made it in between, put it back.
  seen="$(_mlock_owner "$d")"; aside="$d.stale.$me"
  mv -T "$d" "$aside" 2>/dev/null || return 1
  if [[ "$(_mlock_owner "$aside")" != "$seen" ]]; then mv -T "$aside" "$d" 2>/dev/null || rm -rf "$aside"; return 1; fi
  rm -rf "$aside"
  mkdir "$d" 2>/dev/null || return 1
  printf '%s\t%s\t%s\n' "$me" "$(proc_winpid "$me")" "$(proc_cmdline "$me")" > "$d/.owner.$me" \
    && mv -f "$d/.owner.$me" "$d/owner"
  return 0; }

# ------------------------------------------------------------------------------------ processes ---
# MSYS emulates /proc for its own processes (the engine's bash workers): cmdline, environ, ppid and
# winpid all exist there, so these readers serve both platforms.
# proc_cmdline <pid> — the process's argv joined by spaces (empty when it is gone).
proc_cmdline(){ tr '\0' ' ' 2>/dev/null < "${HARNESS_PROC_ROOT:-/proc}/$1/cmdline"; }
# proc_env <pid> <VAR> — one variable from the process's exec-time environment (empty when unreadable).
proc_env(){ local kv
  while IFS= read -r -d '' kv; do [[ $kv == "$2="* ]] && { printf '%s\n' "${kv#"$2="}"; return 0; }; done \
    2>/dev/null < "${HARNESS_PROC_ROOT:-/proc}/$1/environ"
  return 0; }
# proc_winpid <pid> — the Windows pid behind an MSYS pid (empty on POSIX, or when it is gone).
proc_winpid(){ is_windows || return 0; cat "${HARNESS_PROC_ROOT:-/proc}/$1/winpid" 2>/dev/null; return 0; }
# proc_find <regex> — the pids whose command line (argv joined by spaces) matches <regex>, one per
# line, excluding the subshell running the scan. A bash scan of /proc/[0-9]*/cmdline: `pgrep` is
# missing from Git Bash, and the scan is the same on Linux and MSYS.
proc_find(){ local rx="$1" f pid cmd p="${HARNESS_PROC_ROOT:-/proc}"
  for f in "$p"/[0-9]*/cmdline; do
    pid="${f#"$p"/}"; pid="${pid%%/*}"
    # Not the subshell this runs in (a `$(proc_find …)` fork carries its parent's command line).
    [[ $BASHPID != "$$" && $pid == "$BASHPID" ]] && continue
    cmd="$(tr '\0' ' ' 2>/dev/null < "$f")" || continue
    cmd="${cmd% }"
    [[ -n $cmd && $cmd =~ $rx ]] && printf '%s\n' "$pid"
  done; return 0; }
# proc_alive <pid> — the process exists and is not a zombie (procps `ps -o stat=` on POSIX; MSYS has
# no procps `-o`, and `kill -0` already fails there for a reaped process).
proc_alive(){ [[ ${1:-} =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null || return 1
  is_windows && return 0
  [[ "$(ps -o stat= -p "$1" 2>/dev/null)" != Z* ]]; }
# proc_ident <pid> — what tells this process from a later one given the same number: start time and
# command line. POSIX: `ps -o lstart=` + `ps -o args=`; Windows: the winpid + the /proc cmdline.
proc_ident(){
  if is_windows; then printf '%s|%s' "$(proc_winpid "$1")" "$(proc_cmdline "$1")"; return 0; fi
  printf '%s|%s' "$(ps -o lstart= -p "$1" 2>/dev/null)" "$(ps -o args= -p "$1" 2>/dev/null)"; }
# proc_args <pid> — the command line (procps `ps -o args=` on POSIX, /proc cmdline on Windows).
proc_args(){ if is_windows; then local c; c="$(proc_cmdline "$1")"; printf '%s\n' "${c% }"; return 0; fi
  ps -o args= -p "$1" 2>/dev/null; }
# proc_kill_tree <pid> — SIGKILL <pid> and everything it started.
#   POSIX: its process group (a lane runner is its own group leader) and then the pid itself.
#   Windows: MSYS signals do not reach native children, so `taskkill /T /F` on the winpid ends the
#            whole Windows tree; the MSYS kill follows for an MSYS process taskkill could not name.
proc_kill_tree(){ local w
  if is_windows; then
    w="$(proc_winpid "$1")"
    [[ -n $w ]] && "${HARNESS_TASKKILL:-taskkill}" //T //F //PID "$w" >/dev/null 2>&1
    kill -KILL "$1" 2>/dev/null; return 0
  fi
  kill -KILL -- "-$1" 2>/dev/null; kill -KILL "$1" 2>/dev/null; return 0; }
# detach_prefix — the command that runs a program in its own session (`setsid`) where the host has it,
# so the worker that started it can exit: prefix a command with it (empty when there is none). Git
# Bash has no setsid (a native child is not in the MSYS session anyway; #356 owns detaching from the
# logon session).
detach_prefix(){ if ! is_windows && command -v setsid >/dev/null 2>&1; then echo setsid; fi; return 0; }

# ----------------------------------------------------------------------------------------- misc ---
# new_uuid — a random UUID: uuidgen, else the kernel's, else python3 (Git Bash has neither of the two).
new_uuid(){ local u
  u="$(uuidgen 2>/dev/null)" || u=""
  [[ -n $u ]] || u="$(cat "${HARNESS_PROC_ROOT:-/proc}/sys/kernel/random/uuid" 2>/dev/null)" || u=""
  [[ -n $u ]] || u="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)" || u=""
  [[ -n $u ]] && printf '%s\n' "$u"; }
# native_path <path> — the form a native Windows program reads (`cygpath -m`: C:/…); unchanged on POSIX.
native_path(){ if is_windows && command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
# export_native_paths [VAR…] — on Windows, rewrite each EXPORTED path variable (default: the list
# below) in mixed form. MSYS converts argv for native programs (python.exe, gh.exe, claude.exe) but not
# arbitrary environment variables, so a path they read from the environment must already be in their
# form. A variable that is not exported never reaches a native program's environment and is left as
# bash has it, so nothing new is exported and bash's own path comparisons are unchanged.
HARNESS_NATIVE_PATH_VARS="ENGINE_DIR STATE_DIR RUN_DIR HARNESS_HOME TARGETS_TSV HARNESS_EVENTS_FILE
  HARNESS_RTDD_EVENTS_FILE HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR HARNESS_SNAPSHOTS_DIR
  HARNESS_FLEETS_DIR HARNESS_HEADLESS_DIR HARNESS_LANE_DIR HARNESS_PARKED_FILE HARNESS_GH_RATE_DIR
  HARNESS_SUPERVISE_CONF HARNESS_SUPERVISE_STATE HARNESS_SUPERVISE_LOG CLAUDE_CONFIG_DIR"
export_native_paths(){ is_windows || return 0
  local v f; (( $# )) || set -- $HARNESS_NATIVE_PATH_VARS
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || continue
    f="$(declare -p "$v" 2>/dev/null)"; f="${f#declare -}"; [[ ${f%% *} == *x* ]] || continue
    printf -v "$v" '%s' "$(native_path "${!v}")"
  done; }

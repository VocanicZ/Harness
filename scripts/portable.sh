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
_mlock_owner(){ local o; [[ -s "$1/owner" ]] && { IFS= read -r o < "$1/owner"; } 2>/dev/null && printf '%s\n' "$o"; }
# _mlock_stale <dir> — can <dir>'s lock be taken from its holder? A holder that is dead, or no holder at all for
# HARNESS_LOCK_STALE_S seconds. A lock dir that is GONE is not stale (#828): it is free, and a caller that saw it a moment
# ago has nothing to take from — saying "stale" there sent the stealer after whatever lock the next taker had just made.
_mlock_stale(){ local d="$1" o m now
  if o="$(_mlock_owner "$d")"; then ! proc_alive "${o%%$'\t'*}"; return; fi
  [[ -d $d ]] || return 1
  m="$(stat -c %Y "$d" 2>/dev/null)" || return 1; now="$(date +%s)"
  (( now - m >= HARNESS_LOCK_STALE_S )); }
# _mlock_own <dir> — write the owner file into a lock dir this process just made. rc 1 when the dir is gone, i.e. a
# taker that judged the lock stale moved it away before the owner landed: the lock is not ours, so the caller must not
# believe it holds it (#684: that was two takers inside the critical section at once).
_mlock_own(){ local d="$1" me="$BASHPID"
  printf '%s\t%s\t%s\n' "$me" "$(proc_winpid "$me")" "$(proc_cmdline "$me")" 2>/dev/null > "$d/.owner.$me" \
    && mv -f "$d/.owner.$me" "$d/owner" 2>/dev/null; }
_mlock_try(){ local f="$1" d="$1.d" me="$BASHPID" seen aside got
  if mkdir "$d" 2>/dev/null; then _mlock_own "$d"; return; fi
  # #684: the holder may have released between the mkdir above and here. A lock that is GONE is free, not stale.
  if [[ ! -d $d ]]; then mkdir "$d" 2>/dev/null || return 1; _mlock_own "$d"; return; fi
  seen="$(_mlock_owner "$d")"
  if [[ -z $seen ]]; then
    # No owner file: a taker between its mkdir and its owner write, or one that died there. Only an old dir is the second;
    # an empty one is removed by rmdir, which refuses a dir that has anything in it, and the dir's age is read last.
    _mlock_stale "$d" || return 1
    rm -f "$d"/.owner.* 2>/dev/null; rmdir "$d" 2>/dev/null || return 1
    mkdir "$d" 2>/dev/null || return 1
    _mlock_own "$d"; return; fi
  # A named holder that is dead. #828: what is judged dead is the owner FILE read above, and what is taken is that same
  # file: renaming it away is atomic, so of two waiters that both saw it dead one wins, and a lock the holder released and
  # the next taker re-made in between has a different owner file — which the check after the rename notices and puts back.
  # The lock DIR is never renamed: it stays in place the whole time, so no third taker's mkdir can succeed while the lock
  # is being judged, and a mistaken steal costs the live holder nothing but a brief look of having no owner file.
  proc_alive "${seen%%$'\t'*}" && return 1
  aside="$d.dead.$me"
  mv -T "$d/owner" "$aside" 2>/dev/null || return 1
  got=""; { IFS= read -r got < "$aside"; } 2>/dev/null
  if [[ $got != "$seen" ]]; then
    [[ -d $d && ! -e $d/owner ]] && mv -n "$aside" "$d/owner" 2>/dev/null; rm -f "$aside"; return 1; fi
  rm -f "$aside"
  _mlock_own "$d"; }

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
# engine_stamp <engine dir> — a checksum of the worker-side code (scripts/**/*.sh, *.py) of an engine: what a worker loads at
# start and never re-reads. pool.sh / priority.sh export it as HARNESS_ENGINE_STAMP to the worker they launch (#602), and
# fleet_roll compares it with the engine's current one — so a worker on a git-checkout engine, whose ENGINE_DIR does not change
# when `update` fast-forwards it, is still rolled onto the new loop. Empty when the dir has no scripts.
engine_stamp(){ local d="$1" f
  [[ -d $d/scripts ]] || return 0
  while IFS= read -r f; do printf '%s\n' "${f#"$d"/}"; cat "$f"; done < <(find "$d/scripts" -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null | LC_ALL=C sort) | cksum | awk '{print $1 "-" $2}'
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
# proc_kill_tree <pid> — SIGKILL <pid> and everything it started. Returns 1, signalling nothing, for a <pid>
#   that is not a number greater than 1.
#   POSIX: its process group (a lane runner is its own group leader) and then the pid itself.
#   Windows: MSYS signals do not reach native children, so `taskkill /T /F` on the winpid ends the
#            whole Windows tree; the MSYS kill follows for an MSYS process taskkill could not name.
proc_kill_tree(){ local w
  # Refuse what would signal more than one process tree (#543): empty and non-numeric values, 0 (the
  # caller's own process group) and 1 (`kill -- -1` is every process the user owns).
  [[ ${1:-} =~ ^[0-9]+$ ]] && (( 10#$1 > 1 )) || return 1
  if is_windows; then
    w="$(proc_winpid "$1")"
    [[ -n $w ]] && "${HARNESS_TASKKILL:-taskkill}" //T //F //PID "$w" >/dev/null 2>&1
    kill -KILL "$1" 2>/dev/null; return 0
  fi
  kill -KILL -- "-$1" 2>/dev/null; kill -KILL "$1" 2>/dev/null; return 0; }
# winpid_alive / winpid_cmdline / winpid_kill_tree <winpid> — a process by its WINDOWS pid (#606): what a native program (a Python
# runner, the agent CLI) reports for itself, e.g. state.json's claude_pid. MSYS `kill -0`, /proc and `proc_kill_tree` know only
# MSYS pids, so a native turn a dead runner left behind was neither seen nor ended.
winpid_alive(){ [[ ${1:-} =~ ^[0-9]+$ ]] || return 1
  "${HARNESS_TASKLIST:-tasklist}" //FI "PID eq $1" //NH 2>/dev/null | tr -d '\r' | grep -qE "[[:space:]]$1[[:space:]]"; }
winpid_cmdline(){ [[ ${1:-} =~ ^[0-9]+$ ]] || return 0
  powershell -NoProfile -Command "(Get-CimInstance Win32_Process -Filter 'ProcessId=$1').CommandLine" 2>/dev/null | tr -d '\r'; return 0; }
winpid_kill_tree(){ [[ ${1:-} =~ ^[0-9]+$ ]] && (( 10#$1 > 1 )) || return 1
  "${HARNESS_TASKKILL:-taskkill}" //T //F //PID "$1" >/dev/null 2>&1; return 0; }
# proc_ppid <pid> — the parent's pid (empty when it is gone).
proc_ppid(){ local k v
  while read -r k v; do [[ $k == PPid: ]] && { printf '%s\n' "$v"; return 0; }; done \
    2>/dev/null < "${HARNESS_PROC_ROOT:-/proc}/$1/status"
  is_windows || ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; return 0; }
# fleet_worker_procs <state dir> — `<pid> <slot>` for every live TOP-LEVEL pool / priority worker process of THIS fleet (#647),
# whether or not a pid file names it. The process table is the truth a pid file can lose: a pid file overwritten, cleared, or
# read from another pid namespace stops naming a worker that keeps running. Slot = `worker-N` (pool-worker.sh N) or `priority`
# (priority-worker.sh <id>), the pid-file stem its launcher uses. Counted: STATE_DIR (compared by realpath) equal to <state dir>;
# argv names the worker script as an argument of its own (a `grep pool-worker.sh` does not match); and the parent is not itself a
# worker of this fleet — a worker's `$(…)` and background subshells carry its command line and environment, and are not workers.
# Another fleet's workers never match. Nothing without a /proc (macOS), so callers behave as they did before.
fleet_worker_procs(){ local want pid sd cmd kind arg ppid
  declare -A _fw_slot=()
  want="$(realpath -m "$1" 2>/dev/null)" || return 0
  for pid in $(proc_find '(^|[ /])(pool|priority)-worker\.sh( |$)'); do
    sd="$(proc_env "$pid" STATE_DIR)"; [[ -n $sd && "$(realpath -m "$sd" 2>/dev/null)" == "$want" ]] || continue
    cmd="$(proc_cmdline "$pid")"
    # a worker is a shell running the script; `pgrep -f pool-worker.sh` / `bash -c '… grep pool-worker.sh'` only mention it
    [[ $cmd =~ ^([^\ ]*/)?(ba|da|z)?sh(\.exe)?\  && $cmd != *" -c "* ]] || continue
    if [[ $cmd =~ (pool|priority)-worker\.sh\ +([^\ ]+) ]]; then kind="${BASH_REMATCH[1]}"; arg="${BASH_REMATCH[2]}"
    else kind="${cmd##*/}"; kind="${kind%%-*}"; arg=""; fi
    if [[ $kind == priority ]]; then _fw_slot[$pid]=priority; else _fw_slot[$pid]="worker-${arg:-?}"; fi
  done
  for pid in "${!_fw_slot[@]}"; do
    ppid="$(proc_ppid "$pid")"
    [[ -n $ppid && -n ${_fw_slot[$ppid]:-} ]] && continue
    printf '%s %s\n' "$pid" "${_fw_slot[$pid]}"
  done | sort -n; return 0; }
# fleet_untracked_workers <state dir> — fleet_worker_procs minus the pids a run/*.pid file names: the workers nothing launched or
# will stop by pid file — invisible to start, roll and status until #647.
fleet_untracked_workers(){ local pf p line
  declare -A _fu_named=()
  for pf in "$1"/run/*.pid; do [[ -f $pf ]] || continue; p="$(cat "$pf" 2>/dev/null)"; [[ $p =~ ^[0-9]+$ ]] && _fu_named[$p]=1; done
  while IFS= read -r line; do [[ -n $line && -z ${_fu_named[${line%% *}]:-} ]] && printf '%s\n' "$line"; done < <(fleet_worker_procs "$1")
  return 0; }
# proc_descendants <pid>… — every descendant of each <pid> (children, theirs, …), one per line, the
# <pid>s themselves not included. procps `ps -e -o pid=,ppid=` (POSIX only: a tmux pane's tree, #418).
proc_descendants(){ (( $# )) && ! is_windows || return 0
  ps -e -o pid=,ppid= 2>/dev/null | awk -v roots="$*" '
    BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) want[r[i]] = 1 }
    { kid[NR] = $1; par[NR] = $2 }
    END { do { more = 0; for (i = 1; i <= NR; i++) if ((par[i] in want) && !(kid[i] in want)) { want[kid[i]] = 1; out[kid[i]] = 1; more = 1 } } while (more)
          for (p in out) print p }'; return 0; }
# proc_tree_has_comm <root-pid> <comm> — is a process named <comm> (its `comm`, no path) <root-pid> itself or one of
# its descendants? 0 yes, 1 no (also for a <root-pid> that is not a number). POSIX: procps
# `ps -e -o pid=,ppid=,comm=`. Windows (MSYS `ps` has no -o, #355): the table cannot be read, so it answers 0 —
# "assume it is there": a caller that waits for <comm> to go (lane_has_gh, #594) then keeps waiting rather than
# ending a lane while it is mid-filing.
proc_tree_has_comm(){ [[ "${1:-}" =~ ^[0-9]+$ && -n "${2:-}" ]] || return 1
  is_windows && return 0
  ps -e -o pid=,ppid=,comm= 2>/dev/null | awk -v root="$1" -v want="$2" '
    { ppid[$1]=$2; comm[$1]=$3 }
    END { for (p in comm) { if (comm[p] != want) continue; q=p
            while (q != "" && q != 0 && q != 1) { if (q == root) exit 0; q=ppid[q] } }
          exit 1 }'; }
# proc_session_pids <uuid> — the pids whose exec-time environment has HARNESS_SESSION EXACTLY <uuid>
# (one whole NUL-separated entry, fixed string: never a prefix, a suffix, or a pattern; never argv).
# Nothing for an empty <uuid>, or without a /proc to read.
proc_session_pids(){ local p="${HARNESS_PROC_ROOT:-/proc}" f
  [[ -n ${1:-} && -d $p ]] || return 0
  grep -lsxzF -- "HARNESS_SESSION=$1" "$p"/[0-9]*/environ 2>/dev/null | while IFS= read -r f; do
    f="${f#"$p"/}"; printf '%s\n' "${f%%/*}"; done; return 0; }
# proc_sweep_session <uuid> [pid…] — end what a session left running (#418): every process whose
# environment carries HARNESS_SESSION=<uuid> exactly (proc_session_pids — a setsid'd background job
# inherits it too) plus each <pid> (a pane's tree, collected before the session went). Never the caller
# or any ancestor of it, pid 1, a pid in SWEEP_KEEP (space-separated), or one of this fleet's tracked
# workers (tracked_worker_pid, when lib.sh is loaded). SIGTERM, then SIGKILL whatever is still up after
# HARNESS_SWEEP_GRACE seconds (default 3) — on Windows also `taskkill /F` on each one's winpid (MSYS
# signals do not reach a native process; #427). By pid only — never a name or command-line pattern.
# Always true: a missing uuid, an empty environment or nothing left is not an error.
proc_sweep_session(){ local u="${1:-}" p keep=" 1 " hit=() left i grace="${HARNESS_SWEEP_GRACE:-3}"
  (( $# )) && shift
  p="$BASHPID"
  while [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )) && [[ $keep != *" $p "* ]]; do keep+="$p "; p="$(proc_ppid "$p")"; done
  keep+="${SWEEP_KEEP:-} "
  for p in $( { proc_session_pids "$u"; printf '%s\n' "$@"; } | sort -un); do
    [[ $p =~ ^[0-9]+$ && $keep != *" $p "* ]] || continue
    declare -F tracked_worker_pid >/dev/null && tracked_worker_pid "$p" && continue
    proc_alive "$p" && hit+=("$p")
  done
  (( ${#hit[@]} )) || return 0
  kill -TERM "${hit[@]}" 2>/dev/null
  [[ $grace =~ ^[0-9]+$ ]] || grace=3
  for (( i = 0; i <= grace * 10; i++ )); do
    left=(); for p in "${hit[@]}"; do proc_alive "$p" && left+=("$p"); done
    (( ${#left[@]} )) || return 0
    (( i < grace * 10 )) && sleep 0.1
  done
  if is_windows; then local w
    for p in "${left[@]}"; do w="$(proc_winpid "$p")"
      [[ $w =~ ^[0-9]+$ ]] && "${HARNESS_TASKKILL:-taskkill}" //F //PID "$w" >/dev/null 2>&1; done
  fi
  kill -KILL "${left[@]}" 2>/dev/null; return 0; }
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
# posix_path <path> — the MSYS form (`cygpath -u`: /c/…, no backslashes); unchanged on POSIX. The twin of
# native_path, for the other direction: on Windows ONE directory has two spellings in one run (#605) —
# `C:/x` in what a Windows environment variable or export_native_paths hands over, `/c/x` in what `pwd`,
# `realpath` and `mktemp` answer — and a string compare, or a path handed to a tool that wants the other
# one, silently misses. Anything that compares two paths, or writes one into a file bash reads, goes
# through this; never grow a private `cygpath -u` beside it.
posix_path(){ local p="$1"
  if is_windows && command -v cygpath >/dev/null 2>&1; then cygpath -u "$p" 2>/dev/null || printf '%s\n' "$p"
  else printf '%s\n' "$p"; fi; }
# same_path <a> <b> — true when both name the same path in any spelling (C:/x, C:\x, /c/x); a plain string
# compare elsewhere. Textual: it does not follow symlinks (realpath first for that).
same_path(){ [[ "$(posix_path "$1")" == "$(posix_path "$2")" ]]; }
# export_native_paths [VAR…] — on Windows, rewrite each EXPORTED path variable (default: the list
# below) in mixed form. MSYS converts argv for native programs (python.exe, gh.exe, claude.exe) but not
# arbitrary environment variables, so a path they read from the environment must already be in their
# form. A variable that is not exported never reaches a native program's environment and is left as
# bash has it, so nothing new is exported and bash's own path comparisons are unchanged.
# The default list lives in a name no HARNESS_* scrub touches: supervise's sup_clean_env unsets every HARNESS_* variable, and
# under `set -u` the unbound HARNESS_NATIVE_PATH_VARS then ended the lib.sh a fleet check sources, silently, on Windows (#606).
_NATIVE_PATH_VARS_DEFAULT="ENGINE_DIR STATE_DIR RUN_DIR HARNESS_HOME HARNESS_EVENTS_FILE
  HARNESS_RTDD_EVENTS_FILE HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR HARNESS_SNAPSHOTS_DIR
  HARNESS_FLEETS_DIR HARNESS_HEADLESS_DIR HARNESS_LANE_DIR HARNESS_PARKED_FILE HARNESS_GH_RATE_DIR
  HARNESS_SUPERVISE_CONF HARNESS_SUPERVISE_STATE HARNESS_SUPERVISE_LOG CLAUDE_CONFIG_DIR"
HARNESS_NATIVE_PATH_VARS="$_NATIVE_PATH_VARS_DEFAULT"
export_native_paths(){ is_windows || return 0
  local v f; (( $# )) || set -- ${HARNESS_NATIVE_PATH_VARS:-$_NATIVE_PATH_VARS_DEFAULT}
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || continue
    f="$(declare -p "$v" 2>/dev/null)"; f="${f#declare -}"; [[ ${f%% *} == *x* ]] || continue
    printf -v "$v" '%s' "$(native_path "${!v}")"
  done; }

# ------------------------------------------------------------------------------------ lifecycle ---
# Native Windows has no systemd and no detaching `nohup` (#356, ADR 0001 §5): a process `nohup`'d from
# an OpenSSH session dies with that session. These helpers are the Windows stand-ins; each POSIX
# branch is the code the engine ran before.
#
# win_bash_exe — Git's bash.exe, in the form a Windows program reads (C:/Program Files/Git/bin/bash.exe).
# Entrypoints that Windows starts (a scheduled task, a detached launch) name it by path: the `bash`
# on the cmd PATH is C:\Windows\System32\bash.exe, which is WSL's. HARNESS_BASH_EXE overrides.
win_bash_exe(){ local r c
  [[ -n ${HARNESS_BASH_EXE:-} ]] && { printf '%s\n' "$HARNESS_BASH_EXE"; return 0; }
  r="$(cygpath -m / 2>/dev/null)" || r=""
  for c in "${r%/}/bin/bash.exe" "${r%/}/usr/bin/bash.exe"; do [[ -n $r && -f $c ]] && { printf '%s\n' "$c"; return 0; }; done
  native_path "${BASH:-/usr/bin/bash}"; }
# python3_version — the version of the Python 3 that `python3` runs (e.g. 3.13.5); rc 1, printing
# nothing, when it runs none: on a stock Windows host the `python3` on PATH is the Microsoft Store
# stub, which prints "Python was not found…" and exits 9009.
python3_version(){ local v
  v="$(python3 -c 'import sys; print(sys.version.split()[0]) if sys.version_info[0] == 3 else sys.exit(1)' 2>/dev/null)" \
    && [[ -n $v ]] && { printf '%s\n' "$v"; return 0; }
  return 1; }
# PYTHON3_FIX — what to do when python3 does not run a Python 3 (doctor's and start's shared text).
PYTHON3_FIX="install Python 3, then re-run install.sh/harness update for the shim, or set HARNESS_PYTHON"
# win_python3_check — true off Windows, or when python3 runs a Python 3 there; otherwise says so,
# naming the fix, and is false. start.sh refuses to launch a fleet without one (#405): every lane
# claim goes through python3, so a Store-stub host would launch workers that never claim.
win_python3_check(){
  is_windows || return 0
  python3_version >/dev/null && return 0
  echo "python3 does not run a Python 3 (the Microsoft Store stub?) — $PYTHON3_FIX" >&2; return 1; }
# rtdd_exe — the rtdd this host runs, as a path; rc 1 when there is none (#495). On Windows rtdd is `rtdd.exe`, and the
# `.exe` name is looked up first: Git Bash finds `rtdd` for it, a forced-Windows test host (Linux) does not.
rtdd_exe(){ local p
  if is_windows; then p="$(command -v rtdd.exe 2>/dev/null)" && [[ -n $p ]] && { printf '%s\n' "$p"; return 0; }; fi
  p="$(command -v rtdd 2>/dev/null)" && [[ -n $p ]] && printf '%s\n' "$p"; }
# ── Windows host checks (#488, PRD #475): the facts `harness doctor` and install.sh both report ─────
# install.sh runs before any engine exists, so it carries its own copy of the fix texts and the registry
# probe; test/test_windows_installer.sh fails when the two drift.
# WIN_DEVMODE_FIX — what to do when real symlinks cannot be made.
WIN_DEVMODE_FIX='turn on Developer Mode (Settings → System → For developers → Developer Mode), or run this shell as an administrator; in an administrator PowerShell: reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1'
# win_devmode — on | off | unknown: Developer Mode, from the registry (HARNESS_REG names `reg`; a test points it at a stub).
win_devmode(){ local reg="${HARNESS_REG:-reg}" o
  command -v "$reg" >/dev/null 2>&1 || { echo unknown; return 0; }
  o="$("$reg" query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' //v AllowDevelopmentWithoutDevLicense 2>/dev/null)" || { echo off; return 0; }
  if grep -q '0x1' <<<"$o"; then echo on; else echo off; fi; }
# win_symlink_ok — a native symlink can be made here (Developer Mode, or an administrator).
win_symlink_ok(){ local d rc=1; d="$(mktemp -d)" || return 1
  ( cd "$d" && mkdir t && MSYS=winsymlinks:nativestrict ln -s t l 2>/dev/null && [[ -L l ]] ) && rc=0
  rm -rf "$d"; return "$rc"; }
# win_git_identity_missing — prints which of user.name / user.email git has no value for (env identity counts).
win_git_identity_missing(){ local m=()
  [[ -n "$(git config --get user.name 2>/dev/null)" || -n "${GIT_AUTHOR_NAME:-}" ]] || m+=(user.name)
  [[ -n "$(git config --get user.email 2>/dev/null)" || -n "${GIT_AUTHOR_EMAIL:-}" ]] || m+=(user.email)
  (( ${#m[@]} )) || return 1
  echo "${m[*]}"; }
# WIN_IDENTITY_FIX — the commands that give git an identity (the lane's commits need one).
WIN_IDENTITY_FIX='git config --global user.name "Your Name"  &&  git config --global user.email "you@users.noreply.github.com"'
# win_repo_config <dir> — Windows only: the settings a Harness repo needs there, written to THAT repo's
# config (`git -C <dir> config`, never --global / --system): core.longpaths=true (a deep node_modules or
# worktree path passes 260 characters), core.autocrlf=false and core.eol=lf (a lane's checkout stays LF,
# which bash and the repo's scripts need). Quiet; rc 0 when <dir> is not a repo.
win_repo_config(){ is_windows || return 0
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$1" config --local core.longpaths true 2>/dev/null
  git -C "$1" config --local core.autocrlf false 2>/dev/null
  git -C "$1" config --local core.eol lf 2>/dev/null; return 0; }
# _ps_quote <s> — <s> as a PowerShell single-quoted string body (a ' is doubled).
_ps_quote(){ printf '%s' "${1//\'/\'\'}"; }
# _env_script — this shell's exported variables as `export NAME=value` lines a later bash can source.
# Bash's own read-only and per-shell variables are left out; so is any name bash cannot assign.
_env_script(){ local v
  for v in $(compgen -e); do
    [[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case $v in BASHOPTS|SHELLOPTS|BASH_*|BASHPID|PPID|UID|EUID|SHLVL|PWD|OLDPWD|_) continue ;; esac
    printf 'export %s=%q\n' "$v" "${!v}"
  done; }

# _abs_path <path> — <path> made absolute against $PWD (a C:/… or C:\… path already is).
_abs_path(){ if [[ $1 == /* || $1 =~ ^[A-Za-z]:[/\\] ]]; then printf '%s\n' "$1"; else printf '%s\n' "$PWD/$1"; fi; }
# detach_launch [-a] <pidfile> <logfile> <cmd…> — start <cmd…> in the background so it outlives this
# shell and the login session, with stdout+stderr to <logfile> (-a appends), and write its pid to
# <pidfile>. rc 0 once the pid is recorded.
#   POSIX:   `nohup <cmd…> >log 2>&1 9>&- &` and `$!` — exactly what pool.sh, priority.sh and
#            ensure_poller did before #356. fd 9 is closed for the child: start.sh holds its
#            double-start lock there, and a long-lived child must never inherit it.
#   Windows: WMI starts the process (Win32_Process.Create through powershell's Invoke-CimMethod), so
#            it is a child of the WMI service, not of this shell, and leaves the OpenSSH session's job
#            object behind. It gets the user's default environment, not ours, so a launcher script
#            beside <pidfile> (<pidfile>.launch.sh, mode 600 env beside it) restores this shell's
#            exported variables and directory, records `$$` — the MSYS pid, which `exec` keeps and
#            `kill -0`/`kill` understand — and execs <cmd…>. This waits up to HARNESS_DETACH_WAIT
#            seconds (default 30) for the pid. HARNESS_POWERSHELL names powershell (a test fakes it).
#            <pidfile> and <logfile> are made absolute first: WMI starts the launcher in
#            C:\Windows\system32, so a relative path there names nothing of ours.
detach_launch(){ local append=0
  [[ ${1:-} == -a ]] && { append=1; shift; }
  local pidf log; pidf="$(_abs_path "$1")"; log="$(_abs_path "$2")"; shift 2
  if ! is_windows; then
    if (( append )); then nohup "$@" >>"$log" 2>&1 9>&- &
    else nohup "$@" >"$log" 2>&1 9>&- & fi
    echo "$!" > "$pidf"; return 0
  fi
  local launch="$pidf.launch.sh" envf="$pidf.env" redir='>' cl i
  (( append )) && redir='>>'
  ( umask 077; _env_script > "$envf" ) || return 1
  {
    printf '#!/usr/bin/env bash\n# written by harness (detach_launch, #356): restores the launching shell, then runs the command.\n'
    printf 'source %q && rm -f %q\n' "$envf" "$envf"   # #488/#510: the saved environment (GH_TOKEN among it) lives only until restored
    printf 'cd %q 2>/dev/null || cd\n' "$PWD"
    printf 'echo "$$" > %q && mv -f %q %q\n' "$pidf.new" "$pidf.new" "$pidf"
    printf 'exec %s </dev/null %s%q 2>&1\n' "$(printf '%q ' "$@")" "$redir" "$log"
  } > "$launch" || return 1
  rm -f "$pidf" "$pidf.new"
  cl="\"$(win_bash_exe)\" \"$(native_path "$launch")\""
  MSYS2_ARG_CONV_EXCL='*' "${HARNESS_POWERSHELL:-powershell}" -NoProfile -NonInteractive -Command \
    "\$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine='$(_ps_quote "$cl")'}; exit \$r.ReturnValue" \
    </dev/null >/dev/null 2>&1 || { rm -f "$envf"; echo "detach_launch: Win32_Process.Create failed for: $*" >&2; return 1; }
  for (( i = 0; i < ${HARNESS_DETACH_WAIT:-30} * 10; i++ )); do
    [[ -s $pidf ]] && return 0
    sleep 0.1
  done
  rm -f "$envf"; echo "detach_launch: $* started but recorded no pid in $pidf" >&2; return 1; }

# ---- services: Task Scheduler in place of a systemd user unit (#356) -------------------------------
# A service is a launcher script <dir>/<name>.sh — the unit file's stand-in, with the same
# `# ExecStart=<command>` line the engine checks to tell whose install it is — registered as a
# scheduled task. The task starts at logon only, never at boot (#489: a reboot must not start a test
# install's task), in the user's interactive session, with no run-time limit (the default kills a task
# after 72h) and one instance at a time. The launcher's own loop is Restart=always.
# The task name is unique per HARNESS_HOME (#489): the default ~/.harness keeps Harness\<name>, any
# other home appends a short hash of its path (Harness\<name>-<hash>), so two homes on one machine —
# a test install beside a real one — never share, and never delete, each other's tasks.
# HARNESS_SCHTASKS names schtasks (a test fakes it).
_schtasks(){ MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${HARNESS_SCHTASKS:-schtasks}" "$@"; }
# win_home_tag — "" for the default home, else the first 8 hex digits of a hash of the home's path.
win_home_tag(){ local home="${HARNESS_HOME:-$HOME/.harness}" def="$HOME/.harness"
  home="${home%/}"; def="${def%/}"
  [[ $home == "$def" ]] && return 0
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$home" | sha256sum | cut -c1-8
  else printf '%08x\n' "$(printf '%s' "$home" | cksum | cut -d' ' -f1)"; fi; }
win_task_name(){ local tag; tag="$(win_home_tag)"; printf 'Harness\\%s%s\n' "$1" "${tag:+-$tag}"; }
win_task_file(){ printf '%s/%s.sh\n' "$1" "$2"; }
# win_task_xml <launcher> — the task definition: the interactive-token, logon-only task plain
# `schtasks /SC ONLOGON` makes. There is no boot trigger, so it needs no administrator.
win_task_xml(){ local launch="$1" user="${USERNAME:-$(id -un)}" trig logon=InteractiveToken
  trig="<LogonTrigger><Enabled>true</Enabled><UserId>$user</UserId></LogonTrigger>"
  cat <<XML
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Harness: $(basename "$launch" .sh) (written by harness; see $(native_path "$launch"))</Description></RegistrationInfo>
  <Triggers>$trig</Triggers>
  <Principals><Principal id="Author"><UserId>$user</UserId><LogonType>$logon</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author"><Exec><Command>$(win_bash_exe)</Command><Arguments>"$(native_path "$launch")"</Arguments></Exec></Actions>
</Task>
XML
}
# win_task_install <dir> <name> <restart-s> [VAR=value…] -- <cmd…> — write <dir>/<name>.sh (its
# environment, then <cmd…> rerun <restart-s> seconds after each exit, logging to <dir>/<name>.log),
# register it as Harness\<name> and (re)start it. Re-running rewrites both: idempotent.
win_task_install(){ local dir="$1" name="$2" restart="$3"; shift 3
  local kv envs=() launch xml tn
  while (( $# )) && [[ $1 != -- ]]; do envs+=("$1"); shift; done
  [[ ${1:-} == -- ]] && shift
  mkdir -p "$dir" || { echo "ERROR: cannot create $dir" >&2; return 1; }
  launch="$(win_task_file "$dir" "$name")"; xml="$dir/$name.xml"; tn="$(win_task_name "$name")"
  {
    printf '#!/usr/bin/env bash\n# %s: run by the scheduled task %s (#356). Written by harness; re-running the install rewrites it.\n' "$name" "$tn"
    printf '# ExecStart=%s\n' "$*"
    for kv in ${envs[@]+"${envs[@]}"}; do printf 'export %s=%q\n' "${kv%%=*}" "${kv#*=}"; done
    printf 'while :; do\n  %s</dev/null >>%q 2>&1\n  sleep %s\ndone\n' "$(printf '%q ' "$@")" "$dir/$name.log" "$restart"
  } > "$launch" || return 1
  _win_task_register "$launch" "$xml" "$tn" || { echo "WARNING: could not register the scheduled task $tn" >&2; return 1; }
  echo "  wrote $launch (scheduled task $tn)"
  _schtasks /End /TN "$tn" >/dev/null 2>&1
  _schtasks /Run /TN "$tn" >/dev/null || echo "WARNING: could not (re)start $tn" >&2
  return 0; }
# schtasks reads a task definition only as UTF-16 (little-endian, with its byte-order mark).
_win_task_register(){ local launch="$1" xml="$2" tn="$3"
  { printf '\xff\xfe'; win_task_xml "$launch" | iconv -f UTF-8 -t UTF-16LE; } > "$xml" || return 1
  _schtasks /Create /F /TN "$tn" /XML "$(native_path "$xml")" >/dev/null; }
# win_task_uninstall <dir> <name> — stop and delete Harness\<name> and its files.
win_task_uninstall(){ local dir="$1" name="$2" tn; tn="$(win_task_name "$2")"
  _schtasks /End /TN "$tn" >/dev/null 2>&1
  _schtasks /Delete /F /TN "$tn" >/dev/null 2>&1
  rm -f "$(win_task_file "$dir" "$name")" "$dir/$name.xml"; return 0; }
# win_task_pinned <dir> <name> <subcommand> — rc 0 iff <name>'s launcher runs THIS home's engine by one release's path
# (<home>/releases/<tag>/bin/harness <subcommand>) instead of through the engine link. An engine that installed it while
# HARNESS_HOME was spelled C:/x and ENGINE_DIR /c/x did that (#491), and `harness update` must still recognise it as its own
# so it can rewrite it to follow the link. Another home's launcher, or any other command, is not.
win_task_pinned(){ local f line p r
  f="$(win_task_file "$1" "$2")"; line="$(grep -m1 '^# ExecStart=' "$f" 2>/dev/null)" || return 1
  p="${line#\# ExecStart=}"; p="${p% "$3"}"
  [[ $p == */releases/*/bin/harness ]] || return 1
  r="${p%/releases/*/bin/harness}"
  [[ "$(_win_pn "$r")" == "$(_win_pn "${HARNESS_HOME:-$HOME/.harness}")" ]]; }
_win_pn(){ local p; p="$(realpath -m "$1" 2>/dev/null)" || p="$1"; cygpath -u "$p" 2>/dev/null || printf '%s' "$p"; }
# win_task_env <dir> <name> <VAR> — the value <name>'s launcher exports for <VAR> (empty when none).
win_task_env(){ local f; f="$(win_task_file "$1" "$2")"; [[ -f $f ]] || return 0
  ( unset "$3"; eval "$(grep -E "^export $3=" "$f" | tail -1)"; printf '%s' "${!3:-}" ); }

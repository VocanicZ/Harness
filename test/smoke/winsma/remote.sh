#!/usr/bin/env bash
# remote.sh — the part of the winsma helpers that RUNS ON the Windows check host, in Git for Windows'
# bash (#479, PRD #475 "Verification on winsma"). winsma.sh streams this file, then one call such as
# `r_lock_take 479 hz-main-i479 1234`, to `ssh <host> bash -l -s`; nothing is installed there.
#
# Every path hangs off WS_C (the C: drive as bash sees it: /c on Git Bash). The unit tests point WS_C
# at a temp dir and every external tool at a fake, so this file runs unchanged on Linux:
#   WS_C           the C: drive root (default /c)
#   WS_HB_INTERVAL seconds between lock heartbeats (default 300)
#   WS_SPAWN       command: <script> → prints the pid of that script started detached (default: PowerShell Start-Process)
#   WS_KILL        command: <pid> → stop that process tree (default `taskkill //F //T //PID`)
#   WS_PROCS_CMD   command: <issue> → pids of processes whose command line is under C:\hx-<issue>\
#   WS_VENV_ARGS   extra `python -m venv` arguments (the Linux tests pass --without-pip)
#   WS_SCHTASKS    the Task Scheduler CLI (default schtasks); WS_PYTHON the python for JSON work (default python)
#   HX_REAL_HOME   the user home the guard watches (default $HOME — the full-suite mode swaps $HOME, the guard never does)
# Functions return non-zero on failure and print what a human needs to read; none touches a path outside
# $WS_C/hx-<issue>/ and $WS_C/hx-lock apart from the per-run Task Scheduler tasks, and the guard only READS.
: "${WS_C:=/c}"
: "${WS_HB_INTERVAL:=300}"
: "${WS_SCHTASKS:=schtasks}"
: "${WS_PYTHON:=python}"
: "${WS_KILL:=taskkill //F //T //PID}"

_ws_issue_ok(){ [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "winsma: issue must be a number, got '${1:-}'" >&2; return 1; }; }  # never hx-smoke, hx-lock…
_ws_hx(){ echo "$WS_C/hx-$1"; }
_ws_lock(){ echo "$WS_C/hx-lock"; }
_ws_queue(){ echo "$WS_C/hx-queue"; }   # the FIFO of lanes waiting for the lock (#1033): one ticket file per waiting issue
_ws_native(){ if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }   # C:/hx-479/… for native tools
_ws_winpath(){ if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }  # C:\hx-479\…
_ws_real_home(){ echo "${HX_REAL_HOME:-$HOME}"; }
_ws_now(){ date +%s; }

# --- the lock protocol: C:\hx-proto (#1041) ------------------------------------------------------------------
# Every lane streams the helpers from ITS OWN worktree, so a lane on an old branch runs old lock code beside new lanes and, with no
# ticket, never sees the lock free. The host records the newest protocol any client has used; a client below it must rebase.
#   1 = take-when-free, 300s poll (before #1033)   2 = FIFO queue in C:\hx-queue, hold cap (#1033)
r_proto_check(){ local P cur; P="$WS_C/hx-proto"; cur="$(sed -n 's/^proto=//p' "$P" 2>/dev/null | head -1 | tr -dc 0-9)"
  [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "winsma: lock protocol must be a number, got '${1:-}'" >&2; return 2; }
  if (( $1 < ${cur:-0} )); then
    echo "winsma: this lane's lock code speaks protocol $1, but the Windows host's lock is at protocol $cur: its branch predates the FIFO lock (#1033). Rebase onto origin/main and run again; waiting would starve you." >&2
    return 4
  fi
  (( $1 > ${cur:-0} )) && { mkdir -p "$WS_C"; printf 'proto=%s\n' "$1" >"$P"; }; return 0; }

# --- the lock: C:\hx-lock ------------------------------------------------------------------------
# r_lock_take <issue> <session> <host_pid> — atomic `mkdir`; 0 = taken, 1 = held by someone OR someone queued earlier
# is ahead (#1033: FIFO — the lock goes to the oldest ticket, or to anyone when the queue is empty). Taking it drops the
# caller's own ticket and records when (`taken`, epoch seconds: the hold cap counts from it).
r_lock_take(){ _ws_issue_ok "$1" || return 2
  local L first; L="$(_ws_lock)"
  first="$(r_queue_state | head -1 | awk '{print $2}')"
  [[ -z "$first" || "$first" == "$1" ]] || return 1
  mkdir "$L" 2>/dev/null || return 1
  printf 'issue=%s\nsession=%s\nhost_pid=%s\n' "$1" "${2:-}" "${3:-}" >"$L/owner"
  _ws_now >"$L/taken"; _ws_now >"$L/heartbeat"; r_queue_leave "$1"; return 0; }
# r_lock_state — `free`, or `held <issue> <session> <host_pid> <heartbeat_age_seconds> <hold_seconds>`. A lock whose owner or
# heartbeat file is not there yet (the holder is between its mkdir and its writes) ages from the directory.
r_lock_state(){ local L issue session pid hb age taken hold; L="$(_ws_lock)"
  [[ -d "$L" ]] || { echo free; return 0; }
  issue="$(sed -n 's/^issue=//p' "$L/owner" 2>/dev/null | head -1)"
  session="$(sed -n 's/^session=//p' "$L/owner" 2>/dev/null | head -1)"
  pid="$(sed -n 's/^host_pid=//p' "$L/owner" 2>/dev/null | head -1)"
  hb="$(head -1 "$L/heartbeat" 2>/dev/null | tr -dc 0-9)"
  [[ -n "$hb" ]] || hb="$(stat -c %Y "$L" 2>/dev/null || _ws_now)"
  age=$(( $(_ws_now) - hb )); (( age < 0 )) && age=0
  taken="$(head -1 "$L/taken" 2>/dev/null | tr -dc 0-9)"; [[ -n "$taken" ]] || taken="$hb"
  hold=$(( $(_ws_now) - taken )); (( hold < 0 )) && hold=0
  echo "held ${issue:--} ${session:--} ${pid:--} $age $hold"; }
# --- the queue: C:\hx-queue\<ns stamp>-<issue> (#1033) ----------------------------------------------------------
# A ticket is a file `issue= session= host_pid= queued=`; its mtime is the last refresh. Sorted by name = arrival order.
# r_queue_join <issue> <session> <host_pid> — take a place at the back, or refresh the place the issue already has.
r_queue_join(){ _ws_issue_ok "$1" || return 2
  local Q t; Q="$(_ws_queue)"; mkdir -p "$Q"
  for t in "$Q"/[0-9]*-"$1"; do [[ -f "$t" ]] && { touch "$t"; return 0; }; done
  t="$Q/$(date +%s%N)-$1"
  ( set -C; printf 'issue=%s\nsession=%s\nhost_pid=%s\nqueued=%s\n' "$1" "${2:-}" "${3:-}" "$(_ws_now)" >"$t" ) 2>/dev/null || return 1; }
# r_queue_state — one line per ticket, oldest first: `<name> <issue> <session> <host_pid> <waited_s> <refresh_age_s>`.
r_queue_state(){ local Q t n issue session pid queued now; Q="$(_ws_queue)"; now="$(_ws_now)"
  local seen=" "
  for t in "$Q"/[0-9]*-[0-9]*; do [[ -f "$t" ]] || continue; n="${t##*/}"
    issue="$(sed -n 's/^issue=//p' "$t" | head -1)"; [[ "$issue" =~ ^[0-9]+$ && "$seen" != *" $issue "* ]] || continue
    seen+="$issue "
    session="$(sed -n 's/^session=//p' "$t" | head -1)"; pid="$(sed -n 's/^host_pid=//p' "$t" | head -1)"
    queued="$(sed -n 's/^queued=//p' "$t" | head -1 | tr -dc 0-9)"; [[ -n "$queued" ]] || queued="$now"
    echo "$n $issue ${session:--} ${pid:--} $(( now - queued )) $(( now - $(stat -c %Y "$t" 2>/dev/null || echo "$now") ))"
  done; return 0; }
# r_queue_leave <issue> — drop the issue's ticket(s).
r_queue_leave(){ _ws_issue_ok "$1" || return 2; rm -f "$(_ws_queue)"/[0-9]*-"$1" 2>/dev/null; return 0; }
# r_queue_drop <ticket name> <stale_seconds> — drop a ticket only if its refresh is still older than that (the host checked its lane is gone).
r_queue_drop(){ local t; [[ "${1:-}" =~ ^[0-9]+-[0-9]+$ ]] || return 2; t="$(_ws_queue)/$1"
  [[ -f "$t" ]] || return 0
  (( $(_ws_now) - $(stat -c %Y "$t" 2>/dev/null || _ws_now) > ${2:-1800} )) || { echo "winsma: ticket $1 was refreshed; not dropping it" >&2; return 1; }
  rm -f "$t"; }
# r_lock_info — the lock line (r_lock_state), then one `q <ticket line>` per queued ticket: everything `harness status` and a waiter need, in one call.
r_lock_info(){ r_lock_state; r_queue_state | sed 's/^/q /'; }
# r_hold_gate <issue> <hold_max> <stale> — 0 = the next command may start; 3 = this issue has held the lock longer than
# <hold_max> seconds AND a live ticket of another issue is queued: print why. Only ever stops a NEW command.
r_hold_gate(){ _ws_issue_ok "$1" || return 2
  local st n; st="$(r_lock_state)"; set -- "$1" "$2" "$3" $st
  [[ "$4" == held && "$5" == "$1" ]] || return 0
  (( ${9:-0} > $2 )) || return 0
  n="$(r_queue_state | awk -v me="$1" -v st="$3" '$2 != me && $6 <= st' | wc -l | tr -d ' ')"
  (( n > 0 )) || return 0
  echo "hold cap reached, $n lane(s) queued: release and re-queue (#$1 has held hx-lock ${9}s, WS_HOLD_MAX is ${2}s)"; return 3; }
# r_lock_heartbeat <issue> — refresh now (the loop below does this every WS_HB_INTERVAL).
r_lock_heartbeat(){ local L; L="$(_ws_lock)"; [[ -d "$L" ]] && _ws_now >"$L/heartbeat"; }
# r_hb_start <issue> [hold_cap_s|off] [stale_s] — a background loop that refreshes the heartbeat, its pid recorded in pids. It ends by
# itself when the lock is gone or belongs to someone else, so a missed cleanup cannot keep a dead lock fresh. It also ENFORCES the
# hold cap (#1040): once the hold passes <hold_cap_s> and a live ticket of another issue is queued, it releases the lock and ends,
# whatever the holder is doing (a background driver that never runs `exec` is stopped here, not at the gate). `off` = no cap.
r_hb_start(){ _ws_issue_ok "$1" || return 2
  local hx L Q pid cap stale; hx="$(_ws_hx "$1")"; L="$(_ws_lock)"; Q="$(_ws_queue)"; cap="${2:-off}"; stale="${3:-1800}"; mkdir -p "$hx"
  [[ "$cap" == off || "$cap" =~ ^-?[0-9]+$ ]] || cap=off; [[ "$stale" =~ ^[0-9]+$ ]] || stale=1800
  cat >"$hx/hb.sh" <<EOF
#!/usr/bin/env bash
while [ -f "$L/owner" ] && grep -qx 'issue=$1' "$L/owner"; do
  if [ "$cap" != off ]; then
    t=\$(head -1 "$L/taken" 2>/dev/null | tr -dc 0-9); now=\$(date +%s)
    if [ -n "\$t" ] && [ \$((now - t)) -gt $cap ]; then
      n=0
      for f in "$Q"/[0-9]*-[0-9]*; do
        [ -f "\$f" ] || continue
        case "\$f" in *-$1) continue;; esac
        m=\$(stat -c %Y "\$f" 2>/dev/null || echo \$now)
        [ \$((now - m)) -le $stale ] && n=\$((n + 1))
      done
      if [ \$n -gt 0 ]; then rm -rf "$L"; exit 0; fi
    fi
  fi
  date +%s >"$L/heartbeat"; sleep $WS_HB_INTERVAL
done
EOF
  pid="$(${WS_SPAWN:-_ws_spawn_win} "$hx/hb.sh" | tr -dc 0-9)"
  [[ -n "$pid" ]] || { echo "winsma: heartbeat loop did not start" >&2; return 1; }
  r_pid_add "$1" "$pid"; echo "$pid"; }
# r_lock_idle <issue> <idle|active> — a waiter's note about the holder's lane (#1040): `idle` records when the holder's session was first seen
# not working (kept if already there) and prints how many seconds ago that was; `active` clears the note. Only for the lock's current owner.
r_lock_idle(){ _ws_issue_ok "$1" || return 2
  local L f t; L="$(_ws_lock)"; f="$L/idle_since"
  [[ -d "$L" ]] && grep -qx "issue=$1" "$L/owner" 2>/dev/null || return 1
  if [[ "${2:-}" == active ]]; then rm -f "$f"; echo 0; return 0; fi
  [[ -s "$f" ]] || _ws_now >"$f"
  t="$(head -1 "$f" | tr -dc 0-9)"; [[ -n "$t" ]] || t="$(_ws_now)"
  echo $(( $(_ws_now) - t )); }
# r_lock_break_idle <owner_issue> <idle_seconds> — the lock still belongs to that issue and its lane has been idle longer than that:
# clean its run (its heartbeat loop dies with its pids) and drop the lock.
r_lock_break_idle(){ _ws_issue_ok "$1" || return 2
  local L t; L="$(_ws_lock)"
  [[ -d "$L" ]] && grep -qx "issue=$1" "$L/owner" 2>/dev/null || { echo "winsma: lock changed hands; not breaking it" >&2; return 1; }
  t="$(head -1 "$L/idle_since" 2>/dev/null | tr -dc 0-9)"
  [[ -n "$t" ]] && (( $(_ws_now) - t > $2 )) || { echo "winsma: holder was not idle that long; not breaking it" >&2; return 1; }
  r_cleanup "$1" || return 1; rm -rf "$L"; }
# _ws_spawn_win <script> — start a bash script fully detached from this ssh session (a plain `&` job dies with it).
_ws_spawn_win(){ local b s; b="$(_ws_winpath "$(command -v bash)")"; s="$(_ws_winpath "$1")"
  powershell -NoProfile -Command "(Start-Process -FilePath '$b' -ArgumentList '-l','$s' -WindowStyle Hidden -PassThru).Id" | tr -d '\r'; }
# r_lock_release <issue> — remove the lock only if this issue owns it.
r_lock_release(){ _ws_issue_ok "$1" || return 2
  local L; L="$(_ws_lock)"
  [[ -d "$L" ]] || return 0
  grep -qx "issue=$1" "$L/owner" 2>/dev/null || { echo "winsma: hx-lock is not held by #$1; left alone" >&2; return 1; }
  rm -rf "$L"; }
# r_lock_break_hold <owner_issue> <hold_hard_seconds> — the hard ceiling (#1033): the lock still belongs to that issue and has been
# held longer than <hold_hard_seconds>, a runaway even though its lane lives; clean its run and drop the lock.
r_lock_break_hold(){ _ws_issue_ok "$1" || return 2
  local st; st="$(r_lock_state)"; set -- "$1" "$2" $st
  [[ "$3" == held && "$4" == "$1" ]] || { echo "winsma: lock changed hands; not breaking it" >&2; return 1; }
  (( ${8:-0} > $2 )) || { echo "winsma: lock was not held that long; not breaking it" >&2; return 1; }
  r_cleanup "$1" || return 1; rm -rf "$(_ws_lock)"; }
# r_lock_break <owner_issue> <stale_seconds> — the breaker: only if the lock still belongs to that issue AND
# its heartbeat is still older than <stale_seconds> (the host already checked the owner lane is gone); then
# clean that run (kill its pids and anything under its folder, delete its tasks and folder) and drop the lock.
r_lock_break(){ _ws_issue_ok "$1" || return 2
  local st; st="$(r_lock_state)"; set -- "$1" "$2" $st
  [[ "$3" == held && "$4" == "$1" ]] || { echo "winsma: lock changed hands; not breaking it" >&2; return 1; }
  (( ${7:-0} > $2 )) || { echo "winsma: lock heartbeat is fresh again; not breaking it" >&2; return 1; }
  r_cleanup "$1" || return 1; rm -rf "$(_ws_lock)"; }

# r_lock_drop_orphan <stale_seconds> — a lock directory with no owner file whose directory is older than that: its holder
# died between its mkdir and its writes, so there is no run to clean, only the directory.
r_lock_drop_orphan(){ local L; L="$(_ws_lock)"
  [[ -d "$L" && ! -f "$L/owner" ]] || return 1
  (( $(_ws_now) - $(stat -c %Y "$L" 2>/dev/null || _ws_now) > $1 )) || return 1
  rm -rf "$L"; }

# --- per-run bookkeeping -------------------------------------------------------------------------
# r_pid_add <issue> <pid> — record a process the run started. r_task_add <issue> <name> <command> — register a
# Task Scheduler task LOGON-ONLY (never a boot trigger: a reboot mid-run must not start it) and record it.
r_pid_add(){ _ws_issue_ok "$1" || return 2; mkdir -p "$(_ws_hx "$1")"; echo "$2" >>"$(_ws_hx "$1")/pids"; }
r_task_add(){ _ws_issue_ok "$1" || return 2
  local tn="hx-$1\\$2"
  $WS_SCHTASKS //Create //TN "$tn" //TR "$3" //SC ONLOGON //F >/dev/null || return 1
  mkdir -p "$(_ws_hx "$1")"; echo "$tn" >>"$(_ws_hx "$1")/tasks"; }

# --- isolation: C:\hx-<issue>\ -------------------------------------------------------------------
# r_iso_prepare <issue> [--venv] — create the folder tree (and a python venv: never `pip install` into the shared python).
r_iso_prepare(){ _ws_issue_ok "$1" || return 2
  local hx; hx="$(_ws_hx "$1")"
  mkdir -p "$hx"/{harness-home,bin,skills,tmp,npm-cache,clone,home,claude-config,guard,cred} && touch "$hx/pids" "$hx/tasks" || return 1
  if [[ "${2:-}" == --venv && ! -e "$hx/venv" ]]; then "$WS_PYTHON" -m venv ${WS_VENV_ARGS:-} "$(_ws_native "$hx/venv")" || return 1; fi; }
# r_iso_env <issue> <base|install|suite> — print the `export` lines that confine a run to its folder.
#   base     HARNESS_HOME HARNESS_BIN_DIR HARNESS_USER_SKILLS TMPDIR npm_config_cache GIT_CONFIG_GLOBAL + HX_DIR HX_CLONE
#            (GIT_CONFIG_GLOBAL: the fleet's ensure_safe writes safe.directory to the global git config; #488)
#   install  base + CLAUDE_CONFIG_DIR (install/update/uninstall runs need no Claude sign-in)
#   suite    base + HOME and USERPROFILE = the folder's home\ (the full suite's install/uninstall tests cannot reach the real home)
r_iso_env(){ _ws_issue_ok "$1" || return 2
  local hx n mode="${2:-base}"; hx="$(_ws_hx "$1")"; n="$(_ws_native "$hx")"
  case "$mode" in base|install|suite) :;; *) echo "winsma: isolation mode must be base, install or suite" >&2; return 2;; esac
  printf 'export %s=%q\n' HX_ISSUE "$1" HX_DIR "$n" HX_CLONE "$n/clone" HARNESS_HOME "$n/harness-home" HARNESS_BIN_DIR "$n/bin" \
    HARNESS_USER_SKILLS "$n/skills" TMPDIR "$n/tmp" npm_config_cache "$n/npm-cache" GIT_CONFIG_GLOBAL "$n/gitconfig"
  if [[ -d "$hx/venv" ]]; then
    local vb="Scripts"; [[ -d "$hx/venv/Scripts" ]] || vb="bin"
    printf 'export VIRTUAL_ENV=%q\nexport PATH=%q:"$PATH"\n' "$n/venv" "$n/venv/$vb"
  fi
  [[ "$mode" == install ]] && printf 'export CLAUDE_CONFIG_DIR=%q\n' "$n/claude-config"
  [[ "$mode" == suite ]] && printf 'export HOME=%q\nexport USERPROFILE=%q\n' "$n/home" "$(_ws_winpath "$hx/home")"
  return 0; }

# --- processes, tasks, the run's ~/.claude.json entries --------------------------------------------
# _ws_procs_under <issue> — pids whose command line mentions C:\hx-<issue>\ (the trailing backslash keeps hx-47 off hx-479).
_ws_procs_under(){
  if [[ -n "${WS_PROCS_CMD:-}" ]]; then $WS_PROCS_CMD "$1"; return; fi
  powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$_.ProcessId -ne \$PID -and \$_.CommandLine -like '*C:\\hx-$1\\*' } | ForEach-Object { \$_.ProcessId }" 2>/dev/null | tr -d '\r'; }
_ws_kill(){ $WS_KILL "$1" >/dev/null 2>&1; }
# _ws_claude_json_drop <issue> — delete the run's `projects` entries (any key under C:\hx-<issue>) from ~/.claude.json.
_ws_claude_json_drop(){ local cj; cj="$(_ws_real_home)/.claude.json"; [[ -f "$cj" ]] || return 0
  CJ="$cj" PREFIX="hx-$1" "$WS_PYTHON" -I - <<'PY'
import json, os, re, tempfile
cj, tag = os.environ["CJ"], os.environ["PREFIX"]
with open(cj, encoding="utf-8") as f: data = json.load(f)
pat = re.compile(r"^[a-z]:[\\/]+" + re.escape(tag) + r"([\\/]|$)", re.I)
proj = data.get("projects")
if isinstance(proj, dict):
    for k in [k for k in proj if pat.match(k)]: del proj[k]
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cj) or ".", prefix=".claude.json.hx.")
    with os.fdopen(fd, "w", encoding="utf-8") as f: json.dump(data, f, indent=2)
    os.replace(tmp, cj)
PY
}
# r_cleanup <issue> — kill recorded pids and anything under the folder, delete recorded tasks, drop the run's
# ~/.claude.json project entries, delete the folder, release the lock if this issue holds it. Only ever the
# numbered folder of THIS run: C:\hx-smoke\ and C:\hx-lock are not numbers, so they cannot be named.
r_cleanup(){ _ws_issue_ok "$1" || return 2
  local hx pid tn p i rc=0; hx="$(_ws_hx "$1")"
  if [[ -f "$hx/pids" ]]; then while read -r pid; do [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != "$$" ]] && _ws_kill "$pid"; done <"$hx/pids"; fi
  for p in $(_ws_procs_under "$1"); do [[ "$p" =~ ^[1-9][0-9]*$ && "$p" != "$$" ]] && _ws_kill "$p"; done
  if [[ -f "$hx/tasks" ]]; then while IFS= read -r tn; do [[ -n "$tn" ]] && $WS_SCHTASKS //Delete //TN "$tn" //F >/dev/null 2>&1; done <"$hx/tasks"; fi
  _ws_claude_json_drop "$1" || { echo "winsma: could not clean ~/.claude.json" >&2; rc=1; }
  for i in 1 2 3 4 5; do rm -rf "$hx" 2>/dev/null; [[ -e "$hx" ]] || break; sleep 1; done
  [[ -e "$hx" ]] && { echo "winsma: $hx is still there after cleanup" >&2; rc=1; }
  r_lock_release "$1" 2>/dev/null; r_queue_leave "$1"
  return $rc; }
# r_clean_check <issue> — winsma is clean: no folder, no lock of ours, no recorded process left, no run task.
r_clean_check(){ _ws_issue_ok "$1" || return 2
  local bad=0 p
  [[ -e "$(_ws_hx "$1")" ]] && { echo "left behind: $(_ws_hx "$1")"; bad=1; }
  r_lock_state | grep -q "^held $1 " && { echo "left behind: hx-lock held by #$1"; bad=1; }
  for p in $(_ws_procs_under "$1"); do echo "left behind: process $p under hx-$1"; bad=1; done
  $WS_SCHTASKS //Query //FO CSV //NH 2>/dev/null | grep -qi "\\\\hx-$1\\\\" && { echo "left behind: a hx-$1 task"; bad=1; }
  return $bad; }

# --- the before/after guard ----------------------------------------------------------------------
# What it watches (PRD #475): the checksums of the machine files a run must not change; the Harness\* task list;
# and ~/.claude.json reduced to its `projects` outside C:\hx-<issue> plus the top-level keys Harness writes
# (WS_CLAUDE_TOP_KEYS, space-separated; Harness itself writes none beyond `projects`). The whole file is never
# checksummed: Claude Code rewrites its counters and per-project cost fields on every run.
_ws_gh_dirs(){ local d
  [[ -n "${GH_CONFIG_DIR:-}" ]] && { echo "$GH_CONFIG_DIR"; return; }
  if [[ -n "${APPDATA:-}" ]] && command -v cygpath >/dev/null 2>&1; then echo "$(cygpath -u "$APPDATA")/GitHub CLI"; fi
  echo "$(_ws_real_home)/.config/gh"; }
_ws_guard_targets(){ local h; h="$(_ws_real_home)"
  printf '%s\n' "$h/.local/bin" "$h/.claude/settings.json" "$h/.claude/skills" "$h/.claude/plugins/installed_plugins.json" \
    "$h/.claude/plugins/known_marketplaces.json" "$h/.gitconfig" "$h/.harness"; _ws_gh_dirs; }
_ws_sums(){ local t
  while IFS= read -r t; do
    if [[ -d "$t" ]]; then echo "DIR $t"; find "$t" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    elif [[ -f "$t" ]]; then sha256sum "$t"
    else echo "ABSENT $t"; fi
  done < <(_ws_guard_targets); }
_ws_tasks(){ # Harness\* tasks, minus any this run recorded in its own tasks file (those are cleaned up by name)
  local hx="$1" own=""; [[ -f "$hx/tasks" ]] && own="$(cat "$hx/tasks")"
  $WS_SCHTASKS //Query //FO CSV //NH 2>/dev/null | tr -d '\r' | sed -n 's/^"\\\{0,1\}\([^"]*\)".*/\1/p' | grep -i '^Harness\\' | LC_ALL=C sort -u |
    while IFS= read -r tn; do grep -qxF "$tn" <<<"$own" || echo "$tn"; done; }
_ws_claude_view(){ local cj; cj="$(_ws_real_home)/.claude.json"
  [[ -f "$cj" ]] || return 0
  CJ="$cj" PREFIX="hx-$1" KEYS="${WS_CLAUDE_TOP_KEYS:-}" "$WS_PYTHON" -I - <<'PY'
import json, os, re
cj, tag, keys = os.environ["CJ"], os.environ["PREFIX"], os.environ["KEYS"].split()
with open(cj, encoding="utf-8") as f: data = json.load(f)
pat = re.compile(r"^[a-z]:[\\/]+" + re.escape(tag) + r"([\\/]|$)", re.I)
proj = data.get("projects") if isinstance(data.get("projects"), dict) else {}
for k in sorted(proj):
    if not pat.match(k): print("project\t%s\t%s" % (k, json.dumps(proj[k], sort_keys=True)))
for k in keys:
    if k in data: print("top\t%s\t%s" % (k, json.dumps(data[k], sort_keys=True)))
PY
}
# r_guard_snap <issue> <before|after> — record the guard's view of the machine under hx-<issue>\guard\<label>\.
r_guard_snap(){ _ws_issue_ok "$1" || return 2
  local hx d; hx="$(_ws_hx "$1")"; d="$hx/guard/$2"
  case "$2" in before|after) :;; *) echo "winsma: guard label must be before or after" >&2; return 2;; esac
  mkdir -p "$d" || return 1
  _ws_sums >"$d/files.txt"; _ws_tasks "$hx" >"$d/tasks.txt"; _ws_claude_view "$1" >"$d/claude.json.txt" || return 1; }
# r_guard_check <issue> — diff after against before; 0 = nothing changed, 1 = prints what did.
r_guard_check(){ _ws_issue_ok "$1" || return 2
  local hx b a bad=0 part; hx="$(_ws_hx "$1")"; b="$hx/guard/before"; a="$hx/guard/after"
  [[ -d "$b" && -d "$a" ]] || { echo "winsma: guard needs both a before and an after snapshot" >&2; return 2; }
  for part in files tasks claude.json; do
    if ! diff -u "$b/$part.txt" "$a/$part.txt" >"$hx/guard/$part.diff"; then
      echo "GUARD FAILED: $part changed"; sed -n '3,$p' "$hx/guard/$part.diff" | grep '^[-+]' | head -40; bad=1
    fi
  done
  (( bad )) || echo "guard: no change to the machine files, the Harness\\* tasks or ~/.claude.json outside C:\\hx-$1"
  return $bad; }

# --- credentials ---------------------------------------------------------------------------------
# GH_TOKEN reaches this process on the ssh session's STDIN (winsma.sh sends it), into the environment of this
# process tree only. Nothing below writes it, puts it on a command line, or prints it.
# r_cred_env — git auth through GIT_CONFIG_* env vars (an http extraheader, as `gh auth setup-git` would do, but in the
# environment only) and the commit identity through GIT_AUTHOR_* / GIT_COMMITTER_* (WS_GIT_NAME / WS_GIT_EMAIL).
# Printed as export lines that name the variables, not the token: eval them in the same session.
r_cred_env(){ [[ -n "${GH_TOKEN:-}" ]] || { echo "winsma: no GH_TOKEN on stdin" >&2; return 1; }
  echo 'export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader'
  echo 'export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf "x-access-token:%s" "$GH_TOKEN" | base64 -w0)"'
  printf 'export GIT_AUTHOR_NAME=%q GIT_COMMITTER_NAME=%q GIT_AUTHOR_EMAIL=%q GIT_COMMITTER_EMAIL=%q\n' \
    "${WS_GIT_NAME:-harness-winsma}" "${WS_GIT_NAME:-harness-winsma}" "${WS_GIT_EMAIL:-harness@users.noreply.github.com}" "${WS_GIT_EMAIL:-harness@users.noreply.github.com}"; }
_ws_scan_roots(){ local h t; h="$(_ws_real_home)"
  printf '%s\n' "$(_ws_hx "$1")" "$h/.claude/projects" "$h/.harness" "$h/.gitconfig" "$h/.bash_history"
  for t in "${TEMP:-}" "${TMP:-}"; do [[ -n "$t" ]] && { command -v cygpath >/dev/null 2>&1 && cygpath -u "$t" || echo "$t"; }; done | sort -u
  _ws_gh_dirs; }
# r_cred_scan <issue> <before|after> — list the files under the scan roots that contain the token (or its base64 auth
# header form), into hx-<issue>\cred\<label>.txt, as paths only. The pattern file is a process substitution, never a file.
r_cred_scan(){ _ws_issue_ok "$1" || return 2
  [[ -n "${GH_TOKEN:-}" ]] || { echo "winsma: no GH_TOKEN to scan for" >&2; return 1; }
  local hx out root; hx="$(_ws_hx "$1")"; out="$hx/cred/$2.txt"; mkdir -p "$hx/cred"
  : >"$out"
  while IFS= read -r root; do
    [[ -e "$root" ]] || continue
    grep -rlaF -f <(printf '%s\n' "$GH_TOKEN"; printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0; echo) -- "$root" 2>/dev/null >>"$out"
  done < <(_ws_scan_roots "$1")
  LC_ALL=C sort -u -o "$out" "$out"; }
# r_cred_check <issue> — fail if the after scan lists a file the before scan did not (a file that already held the token
# before the run, say the real gh login's hosts.yml, is not the run's doing).
r_cred_check(){ _ws_issue_ok "$1" || return 2
  local hx new; hx="$(_ws_hx "$1")"
  [[ -f "$hx/cred/before.txt" && -f "$hx/cred/after.txt" ]] || { echo "winsma: credential scan needs a before and an after" >&2; return 2; }
  new="$(LC_ALL=C comm -13 "$hx/cred/before.txt" "$hx/cred/after.txt")"
  if [[ -n "$new" ]]; then echo "CREDENTIAL LEAK: GH_TOKEN found in:"; echo "$new"; return 1; fi
  echo "credentials: GH_TOKEN written nowhere new"; }

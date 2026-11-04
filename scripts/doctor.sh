#!/usr/bin/env bash
# doctor.sh [--fix] — fleet health check focused on the lock wedges + stale local state that strand a
# pool. Report-only by default: it prints findings and the exact remediation, and exits non-zero if
# anything is wrong (so it scripts cleanly). `--fix` then clears stale pidfiles and reaps ORPHANED
# lock-holders — strictly scoped to THIS project (a holder of this project's own lockfile, that is
# not a tracked live worker), so a co-resident sibling fleet is never touched.
#
# Why this exists: start.sh's double-start flock is fd-based. A worker killed mid-poll can orphan a
# `sleep` child that inherited the fd and keeps start.lock held — so `start --recover` skips with
# "(another start in progress)" and launches ZERO workers until the sleep elapses. fuser/lsof aren't
# guaranteed on the host (this box has neither), so the reliable answer comes from a /proc fd scan
# (lib: lock_holders). Sourced by test/test_doctor.sh; runs main only when executed directly.
set -uo pipefail
[[ -n "${_DOCTOR_SOURCED:-}" ]] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DOCTOR_FIX=0

# doctor_locks — for each fleet lock, list holders, classify each as a tracked live worker (normal,
# esp. pool.lock held transiently during a claim) or an ORPHAN (the wedge). Echoes findings; with
# --fix, kills orphan holders. Prints nothing reassuring is suppressed. Returns the problem count.
doctor_locks(){
  local problems=0 lf name pid rest sd kind
  for name in start.lock pool.lock; do
    lf="$RUN_DIR/$name"
    [[ -e "$lf" ]] || { echo "  $name: absent (never created — fine)"; continue; }
    if lock_free "$lf"; then echo "  $name: free ✓"; continue; fi
    echo "  $name: HELD"
    while IFS=$'\t' read -r pid rest; do
      [[ -n "$pid" ]] || continue
      sd="$(proc_state_dir "$pid")"
      if tracked_worker_pid "$pid" && kill -0 "$pid" 2>/dev/null; then
        kind="tracked worker (normal — transient claim)"
      elif [[ "$name" == pool.lock ]]; then
        # pool.lock is held ONLY for the duration of a claim — by a tracked worker OR its short-lived
        # children (a forked pool-worker subprocess / an issuelib.py query). Those are NOT orphans;
        # flagging them is a false positive and (worse) --fix-killing one would corrupt a live claim.
        # So a pool.lock holder is never a problem and never a --fix target — report it informationally.
        kind="transient claim holder (normal)"
      else
        # Only a start.lock holder that is not a live tracked worker is a real wedge: the #88 fd-leak,
        # where a killed worker's orphaned poll-sleep keeps the inherited start.lock fd open and blocks
        # the next `start --recover` from launching any workers.
        kind="ORPHAN"; problems=$((problems+1))
      fi
      echo "      pid $pid [$kind]${sd:+  state_dir=$sd}  ${rest}"
      if (( DOCTOR_FIX )) && [[ "$kind" == ORPHAN ]]; then
        # Conservative: never kill a concurrent start.sh / harness process that legitimately holds
        # the lock for its run; the realistic culprit is an orphaned poll `sleep`.
        if [[ "$rest" == *start.sh* || "$rest" == *"harness "* ]]; then
          echo "        ↳ left running (looks like an in-flight start — refusing to kill)"
        else
          if kill "$pid" 2>/dev/null; then
            echo "        ↳ killed orphan $pid"; harness_event unlock lock="$name" pid="$pid"
          else echo "        ↳ kill failed (already gone?)"; fi
        fi
      fi
    done < <(lock_holders "$lf")
  done
  return "$problems"
}

# doctor_pidfiles — RUN_DIR/*.pid whose process is dead are stale (a clean stop removes them; a crash
# leaves them, and they make status/recover misreport). Report them; with --fix, remove them.
doctor_pidfiles(){
  local problems=0 p pid
  shopt -s nullglob
  for p in "$RUN_DIR"/*.pid; do
    pid="$(cat "$p" 2>/dev/null)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "  $(basename "$p"): live (pid $pid) ✓"
    else
      problems=$((problems+1))
      echo "  $(basename "$p"): STALE (pid ${pid:-?} dead)"
      (( DOCTOR_FIX )) && { rm -f "$p" && echo "        ↳ removed stale pidfile"; }
    fi
  done
  shopt -u nullglob
  return "$problems"
}

# doctor_fleets — stale entries in the host-wide fleet registry. A fleet killed with -9 or lost to a
# host crash never reaches stop.sh's fleet_deregister, so its prefix reservation lingers. The start
# guard prunes such entries on its own, but an operator who wants the host clean now needs a lever —
# this is it. Report-only by default; --fix prunes. A LIVE fleet is never touched. Returns the
# problem count, matching doctor_locks.
#
# A row with NO run_dir is skipped outright. fleet_registry_entries also serves poller records, and
# poller_register writes {slug,cadence,prefix,project} — no run_dir — so fleet_stale has no pidfiles
# to check and calls a live poller fleet stale. fleet_deregister can only delete from
# $HARNESS_FLEETS_DIR, so --fix would print `→ pruned`, leave the record untouched, and report the
# identical problem on every subsequent run. Same rule as the start guard: an absent run_dir is not
# evidence of death.
doctor_fleets(){
  local problems=0 pfx prj rd slugs
  [[ -d "$HARNESS_FLEETS_DIR" ]] || { echo "  absent (never created — fine)"; return 0; }
  # $FLEET_ROW_SEP, not tab: a poller row has an empty INTERIOR run_dir field, and bash collapses
  # runs of tab, which would slide the slug list into $rd and defeat the -n test below.
  while IFS="$FLEET_ROW_SEP" read -r pfx prj rd slugs; do
    [[ -n "$pfx" && -n "$rd" ]] || continue
    if fleet_stale "$pfx" "$rd"; then
      problems=$((problems+1))
      echo "  STALE entry — prefix '$pfx' reserved by $(dirname "$prj") (no live sessions, no live pids)"
      if (( DOCTOR_FIX )); then
        fleet_deregister "$prj"; echo "    → pruned"
      else
        echo "    → prune with: harness doctor --fix"
      fi
    fi
  done < <(fleet_registry_entries "" | tr '\t' "$FLEET_ROW_SEP")
  return "$problems"
}

# doctor_windows — native Windows prerequisites (#356, ADR 0001): the headless session backend, Git's
# bash (not WSL's) for the entrypoints Windows starts, a Python 3 that runs (the `python3` on a stock
# host's PATH is the Microsoft Store stub; the install's shim runs HARNESS_PYTHON), symlink creation
# (the engine link; Developer Mode or an administrator), LF line endings in the engine, and the
# Windows tools the lifecycle calls (schtasks for the supervise/web tasks, powershell for detached
# launches, taskkill for lane trees). Only on Windows. Each failure names its fix; returns the count.
doctor_windows(){ local problems=0 u bx py t d
  is_windows || return 0
  if sess_platform_check 2>/dev/null; then echo "  session backend: $(sess_backend) ✓"
  else echo "  session backend: $(sess_backend) — NOT SUPPORTED on Windows (no tmux): set $SESS_CONFIG_VAR=headless in $CONFIG"; problems=$((problems+1)); fi
  u="$("${HARNESS_UNAME:-uname}" -s 2>/dev/null)"
  case "$u" in MINGW*|MSYS*) echo "  shell: Git Bash ($u) ✓" ;;
    *) echo "  shell: '$u' — run harness from Git for Windows' bash (C:\\Program Files\\Git\\bin\\bash.exe), not WSL's bash.exe"; problems=$((problems+1)) ;; esac
  bx="$(win_bash_exe)"
  u="$("$bx" -c 'uname -s' 2>/dev/null)"
  case "$u" in MINGW*|MSYS*) echo "  task bash: $bx ✓" ;;
    *) echo "  task bash: $bx reports '${u:-nothing}' — not Git's bash; set HARNESS_BASH_EXE to Git's bin/bash.exe"; problems=$((problems+1)) ;; esac
  if py="$(python3_version)"; then
    echo "  python3: $py ($(command -v python3)) ✓"
  else
    echo "  python3: does not run (the Microsoft Store stub?) — $PYTHON3_FIX (${HARNESS_WINGET:-winget} install --id Python.Python.3.13 -e)"; problems=$((problems+1))
  fi
  d="$(mktemp -d)"
  if ( cd "$d" && mkdir t && MSYS=winsymlinks:nativestrict ln -s t l 2>/dev/null && [[ -L l ]] ); then echo "  symlinks: can create ✓"
  else echo "  symlinks: cannot create one — enable Developer Mode (Settings → For developers) or run as an administrator"; problems=$((problems+1)); fi
  rm -rf "$d"
  if grep -q $'\r' "$ENGINE_DIR/bin/harness" "$ENGINE_DIR/scripts/lib.sh" 2>/dev/null; then
    echo "  line endings: CRLF in the engine ($ENGINE_DIR) — bash cannot run it; reinstall it from a release, or clone with core.autocrlf=false"; problems=$((problems+1))
  else echo "  line endings: LF ✓"; fi
  for t in "${HARNESS_SCHTASKS:-schtasks}" "${HARNESS_POWERSHELL:-powershell}" "${HARNESS_TASKKILL:-taskkill}"; do
    if command -v "$t" >/dev/null 2>&1; then echo "  $(basename "$t"): ✓"
    else echo "  $(basename "$t"): MISSING — the Windows lifecycle needs it"; problems=$((problems+1)); fi
  done
  return "$problems"
}

# doctor_windows_prereqs — what install.sh offers through winget, and what it checks, as doctor findings
# (#488): gh, an agent CLI, Node/rtdd, Developer Mode, the git identity and the per-repo git settings of
# the fleet's checkout. Each failure names its fix (the winget command, or the setting). `--fix` writes
# the per-repo settings (win_repo_config); the rest is the operator's. Only on Windows; returns the count.
doctor_windows_prereqs(){ local problems=0 w="${HARNESS_WINGET:-winget}" c co m dm any= k v
  is_windows || return 0
  if command -v gh >/dev/null 2>&1; then echo "  gh: ✓"
  else echo "  gh: MISSING — $w install --id GitHub.cli -e"; problems=$((problems+1)); fi
  if declare -F cli_list >/dev/null; then
    for c in $(cli_list); do command -v "$(cli_with "$c" cli_bin 2>/dev/null)" >/dev/null 2>&1 && any="$any $c"; done
    if [[ -n $any ]]; then echo "  agent CLI:$any ✓"
    else echo "  agent CLI: MISSING — $w install --id Anthropic.ClaudeCode -e"; problems=$((problems+1)); fi
  fi
  if rtdd_exe >/dev/null 2>&1; then echo "  rtdd: ✓ ($(rtdd_exe))"
  elif command -v npx >/dev/null 2>&1; then echo "  rtdd: not installed (npx is here: re-run install.sh)"
  else echo "  rtdd: not installed, and no Node — optional (lanes fall back to the closest tests); $w install --id OpenJS.NodeJS.LTS -e, then re-run install.sh"; fi
  dm="$(win_devmode)"
  case "$dm" in
    on) echo "  developer mode: on ✓" ;;
    *)  if win_symlink_ok; then echo "  developer mode: $dm, but symlinks can be made here (administrator) ✓"
        else echo "  developer mode: $dm — $WIN_DEVMODE_FIX"; problems=$((problems+1)); fi ;;
  esac
  if m="$(win_git_identity_missing)"; then echo "  git identity: no $m — $WIN_IDENTITY_FIX"; problems=$((problems+1))
  else echo "  git identity: ✓"; fi
  co="$(fleet_checkout 2>/dev/null)"
  if [[ -n $co ]] && git -C "$co" rev-parse --git-dir >/dev/null 2>&1; then
    m=
    for k in core.longpaths=true core.autocrlf=false core.eol=lf; do
      v="$(git -C "$co" config --local --get "${k%%=*}" 2>/dev/null)"; [[ "$v" == "${k#*=}" ]] || m="$m ${k%%=*}"
    done
    if [[ -z $m ]]; then echo "  git settings ($co): longpaths + LF ✓"
    elif (( DOCTOR_FIX )); then win_repo_config "$co"; echo "  git settings ($co):$m were not set → set (git -C ... config, this repo only)"
    else echo "  git settings ($co):$m not set — harness doctor --fix, or: git -C \"$co\" config core.longpaths true && git -C \"$co\" config core.autocrlf false && git -C \"$co\" config core.eol lf"
      problems=$((problems+1)); fi
  fi
  return "$problems"
}

# doctor_engine_windows — the INSTALLED and ROLLED-BACK states on Windows (#491): the engine is a real link into
# releases/, it points somewhere, no half-finished flip or staging dir is lying around, the `harness` on PATH is a
# link to it, and the supervise/web tasks' launchers run the engine through that link (so a flip, a rollback and an
# update all move them) rather than one release's path. A rolled-back engine (a newer release is kept beside it) is
# reported with the command that goes forward again. Each problem names its fix. Only on Windows; returns the count.
doctor_engine_windows(){ local home="${HARNESS_HOME:-$HOME/.harness}" bin="${HARNESS_BIN_DIR:-$HOME/.local/bin}" problems=0 e cur newest f n tgt
  is_windows || return 0
  e="$home/engine"
  [[ -e $e || -L $e ]] || return 0   # no engine: doctor_leftovers' business
  if [[ -L $e ]]; then
    tgt="$(readlink "$e" 2>/dev/null)"
    if [[ -d $e ]]; then
      cur="$(basename "$tgt")"
      echo "  engine: ${tgt:-?} ($(sed -n 1p "$e/VERSION" 2>/dev/null || echo 'no VERSION')) ✓"
      # rolled back = a release the engine was moved to AFTER it first reached the current one is still installed
      newest="$(awk -v c="$cur" '$0 == c { seen = 1; next } seen && NF { last = $0 } END { print last }' "$home/releases/.installed" 2>/dev/null)"
      if [[ -n $newest && -d $home/releases/$newest ]]; then
        echo "  rolled back: engine is on $cur, $newest is kept beside it — \`harness update --rollback\` goes forward again, \`harness update\` installs the latest"
      fi
    else
      echo "  engine: link ${tgt:-?} is DANGLING (the release it names is gone) — re-run the install line, or: HARNESS_REF=<tag> bash <a Harness checkout>/install.sh"
      problems=$((problems+1))
    fi
  elif [[ -d $e/.git ]]; then
    echo "  engine: a git checkout (not on releases yet) — \`harness update\` moves it onto the latest release once one exists"
  else
    echo "  engine: $e is a plain folder, not a link — Git Bash copied instead of linking (symlinks off); enable Developer Mode or run as an administrator, then re-run the install line"
    problems=$((problems+1))
  fi
  for f in "$home"/engine.flip.* ; do [[ -e $f || -L $f ]] || continue
    echo "  engine: $f is left over from an interrupted update — remove it: rm -rf \"$f\""; problems=$((problems+1)); done
  for f in "$home"/releases/.staging-*; do [[ -d $f ]] || continue
    echo "  releases: $f is an interrupted download — remove it: rm -rf \"$f\""; problems=$((problems+1)); done
  if [[ -e $bin/harness || -L $bin/harness ]]; then
    if [[ -L $bin/harness ]]; then echo "  harness on PATH: link to $(readlink "$bin/harness") ✓"
    else echo "  harness on PATH: $bin/harness is a copy, not a link — it will not follow updates; re-run the install line"; problems=$((problems+1)); fi
  fi
  for n in harness-supervise harness-web; do f="$home/tasks/$n.sh"; [[ -f $f ]] || continue
    if grep -q "^# ExecStart=.*/releases/" "$f"; then
      echo "  task $(win_task_name "$n"): its launcher runs one release's path, so it does not follow the engine — re-register it: harness ${n#harness-} --install"; problems=$((problems+1))
    else echo "  task $(win_task_name "$n"): follows the engine link ✓"; fi
  done
  return "$problems"
}

# doctor_leftovers — the UNINSTALLED state on Windows (#490): no engine under $HARNESS_HOME, yet
# something Harness put on the host is still there — a Task Scheduler task of this home, a task
# launcher, the python3 shim, harness.cmd, a poller, the fleet registry. Each is named; the fix is one
# command, run from a Harness checkout (the engine that would run `harness uninstall` is the thing
# that is gone). An installed engine, or a host with no Harness on it, is silent. Returns the count.
doctor_leftovers(){ local home="${HARNESS_HOME:-$HOME/.harness}" bin="${HARNESS_BIN_DIR:-$HOME/.local/bin}" problems=0 f n found=()
  is_windows || return 0
  [[ -e "$home/engine" || -L "$home/engine" || -d "$home/releases" ]] && return 0
  if [[ -d "$home/tasks" ]]; then
    for f in "$home"/tasks/*.sh; do [[ -f $f ]] || continue
      n="$(basename "$f" .sh)"; found+=("task $(win_task_name "$n") (launcher $f)"); done
  fi
  [[ -f "$home/bin/python3" ]] && grep -qF "python3 — Harness's shim" "$home/bin/python3" 2>/dev/null && found+=("python3 shim $home/bin/python3")
  [[ -f "$bin/harness.cmd" ]] && grep -qF '%~dp0harness' "$bin/harness.cmd" 2>/dev/null && found+=("harness.cmd $bin/harness.cmd")
  [[ -L "$bin/harness" ]] && ! [[ -e "$bin/harness" ]] && found+=("dangling harness link $bin/harness")
  [[ -d "$home/poller" ]] && found+=("poller state $home/poller")
  [[ -d "$home/fleets" ]] && found+=("fleet registry $home/fleets")
  (( ${#found[@]} )) || return 0
  echo "  no engine under $home, but Harness left:"
  for f in "${found[@]}"; do echo "    - $f"; problems=$((problems+1)); done
  echo "    → remove them: bash <a Harness checkout>/scripts/uninstall.sh --force --force-engine   (HARNESS_HOME=$home)"
  return "$problems"
}

doctor_main(){
  local a; for a in "$@"; do case "$a" in --fix) DOCTOR_FIX=1;; -h|--help) echo "usage: harness doctor [--fix]"; return 0;; esac; done
  local tag=""; (( DOCTOR_FIX )) && tag="(--fix) "
  echo "── harness doctor ${tag}── ${STATE_DIR:-?}"
  echo "RUN_DIR: $RUN_DIR"
  local sp=0
  if sess_backend_check 2>/dev/null; then echo "session backend: $(sess_backend)"
  else echo "session backend: $(sess_backend) — UNKNOWN (valid: $(sess_backend_list | xargs); set $SESS_CONFIG_VAR in $CONFIG)"; sp=1; fi
  # #349: the backend must be one the fleet's CLI can run on (headless: claude only).
  local why; why="$(cli_backend_check 2>&1)" || { echo "session backend: $why"; sp=1; }
  local wp=0
  if is_windows; then echo "windows:"; doctor_windows || wp=$?; doctor_windows_prereqs || wp=$((wp+$?)); doctor_engine_windows || wp=$((wp+$?)); doctor_leftovers || wp=$((wp+$?)); fi
  echo "locks:"
  local lp=0 pp=0 fp=0
  doctor_locks   || lp=$?
  echo "pidfiles:"
  doctor_pidfiles || pp=$?
  echo "fleet registry:"
  doctor_fleets   || fp=$?
  local total=$((lp+pp+fp+sp+wp))
  echo "────────────────────────────────────────────"
  if (( total == 0 )); then
    echo "healthy ✓ — no lock wedges, stale pidfiles, or stale fleet-registry entries."
    return 0
  fi
  if (( DOCTOR_FIX )); then
    # Re-check the locks after fixing so we report the resulting state honestly.
    echo "after --fix:"; doctor_locks >/dev/null; local now=0; lock_free "$RUN_DIR/start.lock" || now=1
    if (( now == 0 )); then echo "  start.lock now free ✓ — \`harness start --recover\` will launch workers."
    else echo "  start.lock still held — inspect above; a non-orphan (in-flight start) may hold it."; fi
    return 0
  fi
  echo "$total problem(s) found. To clear: harness doctor --fix   (kills only this project's orphans; prunes stale fleet-registry entries — never a live fleet)"
  return 1
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && doctor_main "$@"

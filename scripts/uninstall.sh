#!/usr/bin/env bash
# uninstall.sh [--force] [--force-engine] — tear down a Harness install/project (#61, PRD #52).
# --force-engine removes the SHARED engine + PATH link even when other co-resident fleets/projects
# still depend on them (the multi-fleet guard otherwise preserves them).
set -uo pipefail
ENGINE_DIR="${ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-${HARNESS_DIR:-}}"   # this project's .harness/ (bin/harness discovers it); may be empty
HARNESS_HOME="${HARNESS_HOME:-$HOME/.harness}"
HARNESS_BIN_DIR="${HARNESS_BIN_DIR:-$HOME/.local/bin}"
_SKILLS_PINNED="${HARNESS_USER_SKILLS:+1}"   # an explicit skills dir is a sandbox (remove_skills)
HARNESS_USER_SKILLS="${HARNESS_USER_SKILLS:-$HOME/.claude/skills}"
SHARED_ENGINE="$HARNESS_HOME/engine"
PATH_LINK="$HARNESS_BIN_DIR/harness"
# Source lib.sh for the multi-fleet guard helpers (proc_state_dir / poller_registry_prefixes).
# Best-effort: a missing/odd lib leaves the guard's helpers undefined, but tests stub the whole
# other_fleets_depend_on_engine function so they never depend on lib at all.
# shellcheck source=/dev/null
[[ -f "$ENGINE_DIR/scripts/lib.sh" ]] && source "$ENGINE_DIR/scripts/lib.sh" 2>/dev/null || true
# #355: proc_find / proc_env even when lib.sh could not be sourced (portable.sh is idempotent).
[[ -f "$ENGINE_DIR/scripts/portable.sh" ]] && source "$ENGINE_DIR/scripts/portable.sh" 2>/dev/null || true

# other_fleets_depend_on_engine — true (0) when a co-resident fleet/project STILL needs the shared
# engine, so uninstalling THIS project must NOT remove $SHARED_ENGINE or the `harness` PATH link out
# from under it. Two independent signals:
#   (a) a live pool-worker.sh/priority-worker.sh process whose STATE_DIR (proc_state_dir) is NOT this
#       project's STATE_DIR — a foreign fleet is actively running against the shared engine; or
#   (b) poller_registry_prefixes "$STATE_DIR" is non-empty — another project is registered active.
# Overridable: tests redefine this (and worker_pids / poller_registry_prefixes need never run)
# before calling main, so the test never touches real /proc or the real registry.
# _worker_pids — pids of live pool/priority workers, one per line. Factored out + overridable so a
# CLI-level test (which can't source+stub the guard) can insulate signal (a) from real host /proc:
# if HARNESS_UNINSTALL_WORKER_PIDS is SET (even to ""), it is used verbatim instead of scanning /proc
# (portable.sh proc_find: pgrep is missing from Git Bash).
_worker_pids(){
  if [[ -n "${HARNESS_UNINSTALL_WORKER_PIDS+x}" ]]; then printf '%s\n' ${HARNESS_UNINSTALL_WORKER_PIDS}; return 0; fi
  declare -F proc_find >/dev/null || return 0
  proc_find 'pool-worker\.sh|priority-worker\.sh'
}
other_fleets_depend_on_engine(){
  local pid sd
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    sd="$(proc_state_dir "$pid")"
    [[ -n "$sd" ]] && ! same_path "$sd" "$STATE_DIR" && return 0   # a worker's STATE_DIR may be C:/x, ours /c/x (#605)
  done < <(_worker_pids)
  [[ -n "$(poller_registry_prefixes "$STATE_DIR" 2>/dev/null)" ]] && return 0
  return 1
}

# release_in_use <dir> — rc 0 iff a live worker (_worker_pids) runs from <dir>: its exec-time
# ENGINE_DIR, realpath'd, is <dir> or under it. Workers only — this uninstall's own process carries
# the ENGINE_DIR of the release it runs from, and must not count as a user of it.
declare -F proc_engine_dir >/dev/null || \
  proc_engine_dir(){ declare -F proc_env >/dev/null && proc_env "$1" ENGINE_DIR; }
release_in_use(){
  local want pid e
  want="$(realpath -m "$1" 2>/dev/null)" || want="$1"
  # Windows (#921): HARNESS_HOME may be spelled C:/x and a worker's environ /c/x; realpath keeps the spelling it is given, so compare in one.
  declare -F posix_path >/dev/null && want="$(posix_path "$want")"
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    e="$(proc_engine_dir "$pid")"; [[ -n "$e" ]] || continue
    e="$(realpath -m "$e" 2>/dev/null)" || continue
    declare -F posix_path >/dev/null && e="$(posix_path "$e")"
    [[ "$e" == "$want" || "$e" == "$want"/* ]] && return 0
  done < <(_worker_pids)
  return 1
}
# remove the ONE shared host engine install. Idempotent. A release-based host (#281): the engine
# symlink, then every releases/<name> no live worker runs from; one still in use is kept and named,
# and releases/ stays with it.
remove_engine(){
  if [[ -L "$SHARED_ENGINE" ]]; then
    rm -f "$SHARED_ENGINE" && echo "  removed shared engine link $SHARED_ENGINE"
  elif [[ -e "$SHARED_ENGINE" ]]; then
    rm -rf "$SHARED_ENGINE" && echo "  removed shared engine $SHARED_ENGINE"
  fi
  local rel="$HARNESS_HOME/releases" d kept=()
  [[ -d "$rel" ]] || return 0
  for d in "$rel"/*/; do
    d="${d%/}"; [[ -d "$d" ]] || continue
    if release_in_use "$d"; then kept+=("$(basename "$d")"); else rm -rf "$d"; fi
  done
  if (( ${#kept[@]} )); then
    echo "  kept releases a live worker still runs from: ${kept[*]} (in $rel)"
  else
    rm -rf "$rel" && echo "  removed releases $rel"
  fi
  return 0
}
# remove the `harness` PATH entrypoint. -L catches a dangling symlink (engine already gone);
# -e catches a plain file. Idempotent. rm -f never errors on an absent path.
remove_path_link(){
  [[ -L "$PATH_LINK" || -e "$PATH_LINK" ]] && rm -f "$PATH_LINK" && echo "  removed PATH entrypoint $PATH_LINK"
  return 0
}
# remove_windows_tasks — every Task Scheduler task THIS home registered (#490): one per launcher in
# $HARNESS_HOME/tasks (the supervise and web tasks, and any a former engine left whose launcher the
# current one no longer recognises), named per home (#489) so another home's tasks are never touched.
# Windows only; the launcher and its task definition go with the task.
remove_windows_tasks(){
  declare -F is_windows >/dev/null && is_windows || return 0
  declare -F win_task_uninstall >/dev/null || return 0
  local dir="$HARNESS_HOME/tasks" f n
  [[ -d "$dir" ]] || return 0
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    n="$(basename "$f" .sh)"
    win_task_uninstall "$dir" "$n" && echo "  removed scheduled task $(win_task_name "$n")"
  done
  shopt -u nullglob
  return 0
}
# stop_poller — the host poller (poller.sh, #71), by the pid its pidfile names and only if that pid is
# still a poller.sh (a recycled pid is someone else's). Never by pattern.
stop_poller(){
  local pf="$HARNESS_HOME/poller/poller.pid" pid
  pid="$(cat "$pf" 2>/dev/null)"; [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  declare -F proc_args >/dev/null && [[ "$(proc_args "$pid")" == *poller.sh* ]] || return 0
  if declare -F proc_kill_tree >/dev/null; then proc_kill_tree "$pid"; else kill "$pid" 2>/dev/null; fi
  echo "  stopped the poller (pid $pid)"
  return 0
}
# remove_entrypoints — what install.sh wrote for Windows beside the `harness` link (#356): harness.cmd in
# the bin dir and the python3 shim in $HARNESS_HOME/bin. Each only if it carries Harness's own text, so a
# user's harness.cmd / python3 of the same name stays.
remove_entrypoints(){
  local cmd="$HARNESS_BIN_DIR/harness.cmd" shim="$HARNESS_HOME/bin/python3"
  if [[ -f "$cmd" ]] && grep -qF '%~dp0harness' "$cmd" 2>/dev/null; then
    rm -f "$cmd" && echo "  removed $cmd"
  fi
  if [[ -f "$shim" ]] && grep -qF "python3 — Harness's shim" "$shim" 2>/dev/null; then
    rm -f "$shim" && echo "  removed the python3 shim $shim"
    # #609: the LF-stdio sitecustomize the shim puts on PYTHONPATH (install.sh python_lf_dir); only its own file.
    # Python compiles it on its first run: the __pycache__ beside it is ours too, and would keep the home alive.
    rm -rf "$HARNESS_HOME/bin/pylf/__pycache__"
    rm -f "$HARNESS_HOME/bin/pylf/sitecustomize.py"; rmdir "$HARNESS_HOME/bin/pylf" 2>/dev/null
    rmdir "$HARNESS_HOME/bin" 2>/dev/null
  fi
  return 0
}
# remove_host_state — the rest of what Harness keeps under $HARNESS_HOME once nothing runs from it
# (#490): the poller and its registry, the fleet registry, snapshots, task launchers, event logs, the
# supervisor's state and log, one-auto and ghrate state, headless lanes, an interrupted engine flip. Only
# these names — a file the operator put there (supervise.conf, notes) stays, and $HARNESS_HOME goes only
# when that leaves it empty.
remove_host_state(){
  local n p
  stop_poller
  shopt -s nullglob
  for n in poller fleets snapshots one-auto ghrate lanes supervise events.jsonl rtdd-events.jsonl \
           supervise.log supervise.log.* tasks tasks.* engine.flip.*; do
    for p in "$HARNESS_HOME"/$n; do
      [[ -e "$p" || -L "$p" ]] || continue
      if [[ "$n" == tasks && -d "$p" ]]; then   # launchers and definitions only, never a stranger's file
        rm -f "$p"/*.sh "$p"/*.xml; rmdir "$p" 2>/dev/null && echo "  removed $p"
      else
        rm -rf "$p" && echo "  removed $p"
      fi
    done
  done
  shopt -u nullglob
  rmdir "$HARNESS_HOME" 2>/dev/null && echo "  removed $HARNESS_HOME"
  return 0
}
# strip the project's '.harness/' .gitignore entry (added by setup), preserving every other line.
# No-op when the file or the entry is absent. Idempotent.
remove_gitignore_entry(){
  local gi="$1"
  [[ -f "$gi" ]] && grep -qxF '.harness/' "$gi" 2>/dev/null || return 0
  # grep -v exits non-zero when it selects ZERO lines (file was ONLY '.harness/'). Don't gate the mv
  # on grep's rc — that would skip the strip AND leave a stray $gi.tmp. Always move the filtered tmp
  # into place (writing it even when empty), so the entry is removed in every case and no litter.
  grep -vxF '.harness/' "$gi" > "$gi.tmp"
  mv "$gi.tmp" "$gi" && echo "  stripped '.harness/' from $gi"
  return 0
}
# remove THIS project's state-only .harness/ (config + run/claims/worktrees) and its .gitignore
# entry. No-op outside a project (STATE_DIR empty). Idempotent — a missing dir is fine.
remove_project_state(){
  [[ -n "$STATE_DIR" ]] || return 0
  # Path-shape + marker guard (#105): rm -rf is strictly destructive, and STATE_DIR is honoured from
  # the env verbatim (line 7) — a pre-set bogus path would otherwise be recursively deleted. A
  # legitimately-resolved STATE_DIR is ALWAYS '.../.harness' WITH a config marker (bin/harness
  # discover_state_dir, harness init, and migrate.sh:25 all agree). Require BOTH before deleting; on
  # mismatch refuse — touch nothing (incl. the parent .gitignore) — and return success so uninstall
  # still proceeds to remove the engine/skills. The normal discovered-.harness case is unchanged.
  if [[ "$(basename "$STATE_DIR")" != ".harness" || ! -f "$STATE_DIR/config" ]]; then
    echo "  refusing to remove project state $STATE_DIR — not a Harness project state dir (need basename '.harness' + a config marker)"
    return 0
  fi
  local parent; parent="$(cd "$STATE_DIR/.." 2>/dev/null && pwd)" || parent=""
  [[ -e "$STATE_DIR" ]] && rm -rf "$STATE_DIR" && echo "  removed project state $STATE_DIR"
  [[ -n "$parent" ]] && remove_gitignore_entry "$parent/.gitignore"
  return 0
}
# _marked_skills <dir> — the skill dirs in <dir> Harness shipped under another name (the handoff skill,
# #303, and the vendored prompt skills, #315): their SKILL.md carries `<!-- harness-skill:`. A
# same-named skill without it is the operator's.
_marked_skills(){ grep -lF '<!-- harness-skill:' "$1"/*/SKILL.md 2>/dev/null | xargs -r -n1 dirname; }
# remove the deployed /harness operator skills (umbrella `harness` + every `harness-*`, and the marked
# prompt skills) from user scope and every CLI's own user-skills dir (cli_user_skills_dir), leaving
# unrelated skills untouched. #439: what goes is what Harness made — its links into an engine's
# skill/ (dangling ones too, once the engine is gone) and its copies (cli_skill_ours); an operator's
# same-named skill stays. Then whatever Harness installed into each CLI itself (cli_uninstall: agy's
# harness-ralph plugin, #236). lib.sh is sourced best-effort above, so the adapter seam is sourced on
# its own; a pinned HARNESS_USER_SKILLS (a sandbox) never reaches into the real HOME's other CLI dirs.
# Idempotent; best-effort: a missing or failing binary never fails this.
# _skill_dirs — HARNESS_USER_SKILLS, then each CLI's user-skills dir, one per line. Read ONCE, as this
# file is sourced: main runs remove_engine before remove_skills, and the adapters that name the dirs
# live in the engine.
_skill_dirs(){ local c us
  declare -F cli_skill_ours >/dev/null || source "$ENGINE_DIR/scripts/cli/dispatch.sh" 2>/dev/null
  echo "$HARNESS_USER_SKILLS"
  declare -F cli_skill_ours >/dev/null || return 0
  for c in $(cli_list); do
    us="$(cli_with "$c" cli_user_skills_dir)"
    [[ -n "$us" ]] && ! [[ -n "$_SKILLS_PINNED" && "$us" == "$HOME"/* ]] && echo "$us"
  done | awk '!seen[$0]++'; }
_SKILL_DIRS="$(_skill_dirs)"
remove_skills(){
  local d n=0 c dir
  if ! declare -F cli_skill_ours >/dev/null; then     # no seam at all: the /harness names alone
    shopt -s nullglob
    for d in "$HARNESS_USER_SKILLS"/harness "$HARNESS_USER_SKILLS"/harness-* $(_marked_skills "$HARNESS_USER_SKILLS"); do
      rm -rf "$d" && n=$((n+1)); done
    shopt -u nullglob
    echo "  removed $n /harness skill dir(s) from $HARNESS_USER_SKILLS"; return 0
  fi
  while IFS= read -r dir; do
    [[ -n $dir ]] || continue
    shopt -s nullglob
    for d in "$dir"/*; do
      [[ -L $d || ${d##*/} == harness || ${d##*/} == harness-* ]] || grep -qF '<!-- harness-skill:' "$d/SKILL.md" 2>/dev/null || continue
      cli_skill_ours "$d" || continue
      rm -rf "$d" && [[ $dir == "$HARNESS_USER_SKILLS" ]] && n=$((n+1))
    done
    shopt -u nullglob
  done <<<"$_SKILL_DIRS"
  echo "  removed $n /harness skill dir(s) from $HARNESS_USER_SKILLS"
  for c in $(cli_list); do cli_with "$c" cli_uninstall >/dev/null 2>&1 || true; done
  return 0
}

# stop_fleet — default-path guard: STOP this project's fleet first (stop --clean) so no orphaned
# tmux sessions / worktrees outlive the engine removal. Best-effort: only when a project config is
# present; never blocks the uninstall (stop failure is tolerated). --force skips this entirely.
stop_fleet(){
  [[ -n "$STATE_DIR" && -f "$STATE_DIR/config" ]] || { echo "  (no project fleet to stop)"; return 0; }
  echo "Stopping the fleet first (stop --clean):"
  STATE_DIR="$STATE_DIR" bash "$ENGINE_DIR/scripts/stop.sh" --clean || true
}
# confirm — the default-path human gate. HARNESS_UNINSTALL_YES=1 auto-confirms (scripting/tests);
# otherwise read a y/N from stdin. Anything but an explicit yes aborts.
confirm(){
  [[ "${HARNESS_UNINSTALL_YES:-0}" == 1 ]] && return 0
  local ans
  read -rp "Remove the shared engine, this project's .harness/, and /harness skills? [y/N]: " ans || ans=""
  [[ "$ans" == y || "$ans" == Y || "$ans" == yes ]]
}

# _real <path> — realpath, one spelling for comparing (Windows C:/x and /c/x, #605); literal on failure.
_real(){ local r; r="$(realpath -m "$1" 2>/dev/null)" || r="$1"
  declare -F posix_path >/dev/null && r="$(posix_path "$r")"; printf '%s\n' "$r"; }
# _is_state_dir — STATE_DIR is something remove_project_state would delete (the #105 shape: basename '.harness' +
# a config marker). Sourcing lib.sh defaults an unset STATE_DIR to the engine root, which is no state dir and
# which `bash <checkout>/scripts/uninstall.sh` run from that checkout (docs/reference.md) must not trip on.
_is_state_dir(){ [[ -n "$STATE_DIR" && "$(basename "$STATE_DIR")" == .harness && -f "$STATE_DIR/config" ]]; }
# refuse_cwd_in_state_dir — #1095: uninstall deletes STATE_DIR, so a caller whose cwd IS it or is under it
# (a lane worktree at <proj>/.harness/worktrees/<lane>, found by the walk up from cwd) is deleting its own
# floor and the live fleet's. A real operator runs this from the project root, the PARENT of .harness/.
# Checked first in main, before any removal, for a STATE_DIR from discovery, the env or --state-dir alike.
refuse_cwd_in_state_dir(){
  _is_state_dir || return 0
  local sd cwd; sd="$(_real "$STATE_DIR")"; cwd="$(_real "$(pwd -P 2>/dev/null || pwd)")"
  [[ "$cwd" == "$sd" || "$cwd" == "$sd"/* ]] || return 0
  {
    echo "harness uninstall: refusing — the current directory is inside the project's state dir, which uninstall deletes."
    echo "  state dir: $sd"
    echo "  cwd:       $cwd"
    echo "  cd out of the project's .harness/ first (to the project root), then run uninstall again. Nothing was removed."
  } >&2
  exit 1
}
# refuse_live_fleet — #1095: a live pool/priority worker whose STATE_DIR is THIS project's means the fleet
# is running; removing its state dir under it kills every lane. --force skips stop_fleet, so check here.
refuse_live_fleet(){
  _is_state_dir || return 0
  local pid sd
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    sd="$(proc_state_dir "$pid" 2>/dev/null)"
    [[ -n "$sd" ]] && same_path "$(_real "$sd")" "$(_real "$STATE_DIR")" || continue
    {
      echo "harness uninstall: refusing — this project's fleet is still running (worker pid $pid, STATE_DIR $sd)."
      echo "  Run 'harness stop' in the project first, then uninstall again. Nothing was removed."
    } >&2
    exit 1
  done < <(_worker_pids)
  return 0
}

uninstall_usage(){
  cat <<'EOF'
usage: harness uninstall [--force] [--force-engine]
  Stop the fleet and remove the engine, this project's .harness/, and the /harness skills.
  --force         skip the confirmation prompt and the fleet stop
  --force-engine  remove the shared engine even if other fleets still depend on it
  -h, --help      print this usage and exit; nothing is removed
EOF
}

main(){
  local force=0 force_engine=0 arg bad=""
  # #1118: parse EVERY argument before anything is touched. --help/-h wins over any other flag;
  # an unknown argument is a usage error (rc 2), never silently ignored.
  for arg in "$@"; do
    case "$arg" in
      -h|--help) uninstall_usage; exit 0 ;;
    esac
  done
  for arg in "$@"; do
    case "$arg" in
      --force)        force=1 ;;
      --force-engine) force_engine=1 ;;
      *) [[ -n "$bad" ]] || bad="$arg" ;;
    esac
  done
  if [[ -n "$bad" ]]; then
    { echo "harness uninstall: unknown option '$bad'"; uninstall_usage; } >&2
    exit 2
  fi
  # #490: on Windows a running worker holds its scripts open, so removing the engine under another
  # fleet fails half way (or yanks it). --force-engine is refused there while one runs; nothing is touched.
  if (( force_engine )) && declare -F is_windows >/dev/null && is_windows && other_fleets_depend_on_engine; then
    echo "harness uninstall: refusing --force-engine — another fleet still uses the shared engine ($SHARED_ENGINE)." >&2
    echo "  Stop it (harness stop, in its project), or run harness uninstall without --force-engine to keep the engine." >&2
    exit 1
  fi
  refuse_cwd_in_state_dir
  if (( ! force )); then
    confirm || { echo "harness uninstall: aborted — nothing removed."; exit 1; }
    stop_fleet
  fi
  refuse_live_fleet   # after stop_fleet on the default path: go ahead once its workers are gone
  echo "Removing Harness:"
  # Multi-fleet guard: the engine + `harness` PATH link are SHARED across co-resident fleets. If
  # another fleet/project still depends on them and the user did not pass --force-engine, preserve
  # them (removing them mid-run would yank scripts/the entrypoint out from under sibling fleets).
  # This project's state + skills are always removed. Single-fleet hosts hit neither signal → the
  # engine + PATH link are removed exactly as before.
  if (( ! force_engine )) && other_fleets_depend_on_engine; then
    echo "  WARNING: other fleets/projects still depend on the shared engine."
    echo "  Preserving $SHARED_ENGINE and the 'harness' PATH link ($PATH_LINK)."
    echo "  Re-run with --force-engine to remove them anyway."
  else
    # the supervisor unit runs FROM the engine: remove it first, or systemd restarts a missing script forever.
    if [[ -f "$ENGINE_DIR/scripts/supervise.sh" ]] && ( source "$ENGINE_DIR/scripts/supervise.sh"; sup_installed ); then
      bash "$ENGINE_DIR/scripts/supervise.sh" --uninstall
    fi
    if [[ -f "$ENGINE_DIR/scripts/web.sh" ]] && ( source "$ENGINE_DIR/scripts/web.sh"; web_installed ); then
      bash "$ENGINE_DIR/scripts/web.sh" --uninstall
    fi
    remove_windows_tasks
    stop_poller
    remove_engine
    remove_path_link
    remove_entrypoints
    ENGINE_REMOVED=1
  fi
  remove_project_state
  remove_skills
  (( ${ENGINE_REMOVED:-0} )) && remove_host_state
  echo "Uninstalled."
}
[[ "${HARNESS_UNINSTALL_NOMAIN:-0}" == 1 ]] || main "$@"

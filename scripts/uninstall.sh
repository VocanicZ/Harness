#!/usr/bin/env bash
# uninstall.sh [--force] [--force-engine] — tear down a Harness install/project (#61, PRD #52).
# --force-engine removes the SHARED engine + PATH link even when other co-resident fleets/projects
# still depend on them (the multi-fleet guard otherwise preserves them).
set -uo pipefail
ENGINE_DIR="${ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-${HARNESS_DIR:-}}"   # this project's .harness/ (bin/harness discovers it); may be empty
HARNESS_HOME="${HARNESS_HOME:-$HOME/.harness}"
HARNESS_BIN_DIR="${HARNESS_BIN_DIR:-$HOME/.local/bin}"
HARNESS_USER_SKILLS="${HARNESS_USER_SKILLS:-$HOME/.claude/skills}"
SHARED_ENGINE="$HARNESS_HOME/engine"
PATH_LINK="$HARNESS_BIN_DIR/harness"
# Source lib.sh for the multi-fleet guard helpers (proc_state_dir / poller_registry_prefixes).
# Best-effort: a missing/odd lib leaves the guard's helpers undefined, but tests stub the whole
# other_fleets_depend_on_engine function so they never depend on lib at all.
# shellcheck source=/dev/null
[[ -f "$ENGINE_DIR/scripts/lib.sh" ]] && source "$ENGINE_DIR/scripts/lib.sh" 2>/dev/null || true

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
# if HARNESS_UNINSTALL_WORKER_PIDS is SET (even to ""), it is used verbatim instead of scanning /proc.
_worker_pids(){
  if [[ -n "${HARNESS_UNINSTALL_WORKER_PIDS+x}" ]]; then printf '%s\n' ${HARNESS_UNINSTALL_WORKER_PIDS}; return 0; fi
  pgrep -f 'pool-worker\.sh|priority-worker\.sh' 2>/dev/null
}
other_fleets_depend_on_engine(){
  local pid sd
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    sd="$(proc_state_dir "$pid")"
    [[ -n "$sd" && "$sd" != "$STATE_DIR" ]] && return 0
  done < <(_worker_pids)
  [[ -n "$(poller_registry_prefixes "$STATE_DIR" 2>/dev/null)" ]] && return 0
  return 1
}

# remove the ONE shared host engine install. Idempotent.
remove_engine(){
  [[ -e "$SHARED_ENGINE" ]] && rm -rf "$SHARED_ENGINE" && echo "  removed shared engine $SHARED_ENGINE"
  return 0
}
# remove the `harness` PATH entrypoint. -L catches a dangling symlink (engine already gone);
# -e catches a plain file. Idempotent. rm -f never errors on an absent path.
remove_path_link(){
  [[ -L "$PATH_LINK" || -e "$PATH_LINK" ]] && rm -f "$PATH_LINK" && echo "  removed PATH entrypoint $PATH_LINK"
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
# remove the deployed /harness operator skills (umbrella `harness` + every `harness-*`) from user
# scope, leaving unrelated skills untouched. Idempotent (nullglob → no-op when none present).
remove_skills(){
  shopt -s nullglob; local d n=0
  for d in "$HARNESS_USER_SKILLS"/harness "$HARNESS_USER_SKILLS"/harness-*; do
    [[ -e "$d" ]] || continue
    rm -rf "$d" && n=$((n+1))
  done
  shopt -u nullglob
  echo "  removed $n /harness skill dir(s) from $HARNESS_USER_SKILLS"
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

main(){
  local force=0 force_engine=0 arg
  for arg in "$@"; do
    case "$arg" in
      --force)        force=1 ;;
      --force-engine) force_engine=1 ;;
    esac
  done
  if (( ! force )); then
    confirm || { echo "harness uninstall: aborted — nothing removed."; exit 1; }
    stop_fleet
  fi
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
    remove_engine
    remove_path_link
  fi
  remove_project_state
  remove_skills
  echo "Uninstalled."
}
[[ "${HARNESS_UNINSTALL_NOMAIN:-0}" == 1 ]] || main "$@"

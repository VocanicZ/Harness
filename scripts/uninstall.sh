#!/usr/bin/env bash
# uninstall.sh [--force] — tear down a Harness install/project (#61, PRD #52).
set -uo pipefail
ENGINE_DIR="${ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-${HARNESS_DIR:-}}"   # this project's .harness/ (bin/harness discovers it); may be empty
HARNESS_HOME="${HARNESS_HOME:-$HOME/.harness}"
HARNESS_BIN_DIR="${HARNESS_BIN_DIR:-$HOME/.local/bin}"
HARNESS_USER_SKILLS="${HARNESS_USER_SKILLS:-$HOME/.claude/skills}"
SHARED_ENGINE="$HARNESS_HOME/engine"
PATH_LINK="$HARNESS_BIN_DIR/harness"

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
  grep -vxF '.harness/' "$gi" > "$gi.tmp" && mv "$gi.tmp" "$gi" && echo "  stripped '.harness/' from $gi"
  return 0
}
# remove THIS project's state-only .harness/ (config + run/claims/worktrees) and its .gitignore
# entry. No-op outside a project (STATE_DIR empty). Idempotent — a missing dir is fine.
remove_project_state(){
  [[ -n "$STATE_DIR" ]] || return 0
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
  local force=0; [[ "${1:-}" == "--force" ]] && force=1
  if (( ! force )); then
    confirm || { echo "harness uninstall: aborted — nothing removed."; exit 1; }
    stop_fleet
  fi
  echo "Removing Harness:"
  remove_engine
  remove_path_link
  remove_project_state
  remove_skills
  echo "Uninstalled."
}
[[ "${HARNESS_UNINSTALL_NOMAIN:-0}" == 1 ]] || main "$@"

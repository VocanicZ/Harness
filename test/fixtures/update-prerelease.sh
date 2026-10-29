#!/usr/bin/env bash
# update.sh [--with-skills] — fast-forward the ONE shared engine install (#54, PRD #52). The engine
# lives at $HARNESS_HOME/engine (resolved here via ENGINE_DIR, set by bin/harness from the realpath
# of the entrypoint). One ff-pull updates every project at once — no per-project re-pull, no skew.
#   --with-skills  also refresh the superpowers/ralph-loop plugins + matt-pocock skills (host-level).
# rtdd is ensured on EVERY update, with or without that flag: the prompts this pull brings call it.
# Touches NO project .harness/: config + state live in the project, separate from the engine. Runs
# `git pull --ff-only` ONLY — no destructive git op that could discard untracked/ignored files.
set -uo pipefail
ENGINE_DIR="${ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
WITH_SKILLS=0; [[ "${1:-}" == "--with-skills" ]] && WITH_SKILLS=1

# fast-forward ONLY. No destructive git operations.
if ! git -C "$ENGINE_DIR" pull --ff-only; then
  echo "ERROR: 'git pull --ff-only' failed in $ENGINE_DIR (diverged or local engine edits)." >&2
  echo "       Resolve there manually; no project state is touched." >&2
  exit 1
fi
echo "  engine updated at $ENGINE_DIR — every project picks it up immediately."

# rtdd, ALWAYS — not behind --with-skills. The engine just ff-pulled prompts whose test loop IS
# `rtdd which`; a host that last ran install.sh before rtdd existed would otherwise get the prompts
# without the binary, and every lane would silently fall back to the full-suite bar this replaces.
# No-op when it is already there, and never fatal: a failed install prints and the update stands.
HARNESS_INSTALL_NOMAIN=1 source "$ENGINE_DIR/install.sh"
ensure_rtdd

# harness supervise (#180): an installed unit is rewritten and restarted from THIS engine, so the
# long-running supervisor loop never keeps running the code the pull just replaced.
if [[ -f "$ENGINE_DIR/scripts/supervise.sh" ]] && ( source "$ENGINE_DIR/scripts/supervise.sh"; sup_installed ); then
  bash "$ENGINE_DIR/scripts/supervise.sh" --install || echo "WARNING: redeploying harness supervise failed" >&2
fi
# harness web (#226): the same for the dashboard's unit — rewritten from THIS engine (keeping its
# bind/port) and restarted, so the server never keeps serving the code the pull just replaced.
if [[ -f "$ENGINE_DIR/scripts/web.sh" ]] && ( source "$ENGINE_DIR/scripts/web.sh"; web_installed ); then
  bash "$ENGINE_DIR/scripts/web.sh" --install || echo "WARNING: redeploying harness web failed" >&2
fi

# optional host-level plugin/skill refresh (reuse install.sh's ensure_skills + the /harness skill
# deploy). The engine was just ff-pulled, so redeploy its /harness skills to user scope from THIS
# engine — otherwise an engine update leaves stale ~/.claude/skills copies behind.
if (( WITH_SKILLS )); then
  ensure_skills
  HARNESS_SKILL_SRC="${HARNESS_SKILL_SRC:-$ENGINE_DIR/skill}" install_harness_skills
fi

# if a pool is running (in this project's state dir), new engine logic only applies after a relaunch.
run_dir="${STATE_DIR:-$ENGINE_DIR}/run"
if compgen -G "$run_dir/worker-*.pid" >/dev/null 2>&1; then
  for pf in "$run_dir"/worker-*.pid; do
    kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null && {
      echo "NOTE: a worker pool is running. Live workers keep the OLD engine logic until relaunched."
      echo "      To apply this update safely: harness pause  →  let sessions drain  →  harness stop  →  harness start --recover"
      break
    }
  done
fi
echo "Update complete."

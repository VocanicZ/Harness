#!/usr/bin/env bash
# update.sh [--with-skills] [--rollback] — update the ONE shared engine install (#54, PRD #52). The engine lives
# at $HARNESS_HOME/engine (resolved here via ENGINE_DIR, set by bin/harness from the realpath of the
# entrypoint). One update moves every project at once — no per-project re-pull, no skew.
#   --with-skills  also refresh the superpowers/ralph-loop plugins + matt-pocock skills (host-level).
# rtdd is ensured on EVERY update, with or without that flag: the prompts this update brings call it.
# Touches NO project .harness/: config + state live in the project, separate from the engine.
#
# A release-based engine ($HARNESS_HOME/engine is a symlink into releases/, PRD #274) follows GitHub
# releases the way `rtdd update` does (#279): releases/latest (or HARNESS_REF=<tag>, never compared),
# semver against the installed VERSION, download + SHA256SUMS verify, extract to releases/<tag>/,
# one rename(2) of the engine link, prune to the current release + the previous 2. The redeploy then
# runs from the NEW release (`update.sh --post-flip`, internal), so units and skills come from the
# code they belong to. Exit 0 for every plain fact (current, updated, nothing published), 2 for a
# config problem the operator can fix, 3 for an environment failure (network, checksum, disk).
#   --rollback  flip engine back to the previous installed release (#280; rel_previous) and redeploy
#               from it, exactly like an update. Nothing is downloaded or pruned, and the flip is
#               recorded in releases/.installed, so a second --rollback goes forward again. With no
#               previous release it says so and exits 2, engine unchanged.
# A git-checkout engine ($HARNESS_HOME/engine a real directory with .git) is MIGRATED once a release
# exists (#281): the release is installed, the checkout is moved aside — uncommitted edits and all —
# to releases/git-<sha>/, where it counts as a release for retention and --rollback, and engine
# becomes the symlink. While nothing is published it keeps the `git pull --ff-only` path. Neither
# path runs a destructive git op that could discard untracked/ignored files.
set -uo pipefail
ENGINE_DIR="${ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
WITH_SKILLS=0; POST_FLIP=0; ROLLBACK=0
for a; do case "$a" in --with-skills) WITH_SKILLS=1 ;; --post-flip) POST_FLIP=1 ;; --rollback) ROLLBACK=1 ;; esac; done

# hand_off — after a flip, run the redeploy tail from the release engine now points at: exec its
# `update.sh --post-flip`, or, for a release cut before that flag existed (an older HARNESS_REF pin,
# which would read it as a plain update and re-run all of this), return so the tail runs from here.
hand_off(){
  new="$(realpath "$HARNESS_HOME/engine")"
  if grep -q -- '--post-flip' "$new/update.sh" 2>/dev/null; then
    post=(--post-flip); (( WITH_SKILLS )) && post+=(--with-skills)
    exec env ENGINE_DIR="$new" HARNESS_ENGINE_LINK="$HARNESS_HOME/engine" bash "$new/update.sh" "${post[@]}"
  fi
  ENGINE_DIR="$new"; HARNESS_ENGINE_LINK="$HARNESS_HOME/engine"; POST_FLIP=1
}
_engine="${HARNESS_HOME:-${HOME:-}/.harness}/engine"
migrate_tag=""
if (( ! POST_FLIP && ! ROLLBACK )) && [[ -d "$_engine" && ! -L "$_engine" && -e "$_engine/.git" ]]; then
  HARNESS_INSTALL_NOMAIN=1 source "$ENGINE_DIR/install.sh"
  if [[ -n "${HARNESS_REF:-}" ]]; then
    migrate_tag="$HARNESS_REF"
  else
    migrate_tag="$(rel_latest_tag)"; rc=$?
    if (( rc == 2 )); then
      echo "harness update: $HARNESS_API_URL named no release; if a release exists it may still be an unpublished draft"
      migrate_tag=""
    elif (( rc != 0 )); then
      exit 3
    fi
  fi
fi

if (( POST_FLIP )); then
  HARNESS_INSTALL_NOMAIN=1 source "$ENGINE_DIR/install.sh"
elif [[ -n "$migrate_tag" ]]; then
  # This running update.sh is the git checkout's own: bash keeps reading it through its open fd
  # after the directory is renamed, and nothing more is sourced from it — hand_off execs straight
  # into the new release.
  engine_migrate_git "$migrate_tag" || exit 3
  ENGINE_DIR="$(realpath "$HARNESS_HOME/engine")"
  echo "migrated the git-checkout engine to $HARNESS_HOME/releases/$ENGINE_MIGRATED; updated Harness -> $migrate_tag"
  hand_off
elif [[ -L "$_engine" ]]; then
  HARNESS_INSTALL_NOMAIN=1 source "$ENGINE_DIR/install.sh"
  # already current / nothing to do: rtdd is still ensured (and --with-skills still honoured), and
  # neither the engine link nor releases/ is touched.
  done_current(){ echo "$1"; ensure_rtdd
    if (( WITH_SKILLS )); then ensure_skills; install_harness_skills; fi
    exit 0; }
  cur="$(engine_version)"
  if (( ROLLBACK )); then
    prev="$(rel_previous)"
    if [[ -z "$prev" ]]; then
      echo "harness update: no previous release to roll back to; engine unchanged at $cur" >&2
      exit 2
    fi
    engine_flip "$prev" || exit 3
    echo "rolled back Harness $cur -> $(engine_version)"
  elif [[ -n "${HARNESS_REF:-}" ]]; then
    tag="$HARNESS_REF"
    [[ "$tag" == "$(engine_current)" ]] && done_current "Harness $tag is already installed."
  else
    tag="$(rel_latest_tag)"; rc=$?
    if (( rc == 2 )); then
      done_current "harness update: $HARNESS_API_URL named no release; if a release exists it may still be an unpublished draft"
    fi
    (( rc == 0 )) || exit 3
    if ! order="$(semver_cmp "$tag" "$cur")"; then
      echo "harness update: cannot tell whether $tag is newer than the running version \"$cur\" (not [v]MAJOR.MINOR.PATCH). Name the release to install with HARNESS_REF=<tag>" >&2
      exit 2
    fi
    (( order <= 0 )) && done_current "Harness $cur is the latest release."
  fi
  if (( ! ROLLBACK )); then
    rel_install "$tag" || exit 3
    engine_flip "$tag" || exit 3
    rel_prune
    echo "updated Harness $cur -> $tag at $HARNESS_HOME/releases/$tag"
  fi
  hand_off
else
  if (( ROLLBACK )); then
    echo "harness update: $ENGINE_DIR is a git checkout, not a release; no previous release to roll back to; engine unchanged" >&2
    exit 2
  fi
  # fast-forward ONLY. No destructive git operations.
  if ! git -C "$ENGINE_DIR" pull --ff-only; then
    echo "ERROR: 'git pull --ff-only' failed in $ENGINE_DIR (diverged or local engine edits)." >&2
    echo "       Resolve there manually; no project state is touched." >&2
    exit 1
  fi
  echo "  engine updated at $ENGINE_DIR — every project picks it up immediately."
  # Sourced AFTER the pull, so the functions below are the ones the pull just brought.
  HARNESS_INSTALL_NOMAIN=1 source "$ENGINE_DIR/install.sh"
fi

# rtdd, ALWAYS — not behind --with-skills. The engine just ff-pulled prompts whose test loop IS
# `rtdd which`; a host that last ran install.sh before rtdd existed would otherwise get the prompts
# without the binary, and every lane would silently fall back to the full-suite bar this replaces.
# No-op when it is already there, and never fatal: a failed install prints and the update stands.
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
  HARNESS_SKILL_SRC="${HARNESS_SKILL_SRC:-${HARNESS_ENGINE_LINK:-$ENGINE_DIR}/skill}" install_harness_skills
fi

# if a pool is running (in this project's state dir), new engine logic only applies after a relaunch.
run_dir="${STATE_DIR:-$ENGINE_DIR}/run"
if compgen -G "$run_dir/worker-*.pid" >/dev/null 2>&1; then
  for pf in "$run_dir"/worker-*.pid; do
    kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null && {
      if (( POST_FLIP )); then
        echo "NOTE: a worker pool is running. Live workers keep running their release directory until relaunched."
      else
        echo "NOTE: a worker pool is running. Live workers keep the OLD engine logic until relaunched."
      fi
      echo "      To apply this update safely: harness pause  →  let sessions drain  →  harness stop  →  harness start --recover"
      break
    }
  done
fi
echo "Update complete."

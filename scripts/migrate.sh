#!/usr/bin/env bash
# migrate.sh — convert a VENDORED .harness/ (the pre-#52 layout: engine code + its own .git living
# inside the project's .harness/ next to the project state) into a STATE-ONLY .harness/ that runs off
# the single shared host engine (~/.harness/engine, #54). Preserves every per-project STATE artifact
# (config, targets.tsv, run/ incl. claims/, worktrees/, checkouts/, prompts/*.local.md) and removes
# the vendored engine clone + its .git. Idempotent. Refuses if the shared engine isn't installed.
#
# Worktree safety: single-topology worktrees are git worktrees of PROJECT_ROOT (the parent repo, not
# .harness/); multi-topology worktrees register against checkouts/*/.git (preserved). So deleting the
# vendored .harness/.git never corrupts an in-flight worktree (#56, PRD #52).
set -uo pipefail
ENGINE_DIR="${ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-${HARNESS_DIR:-$PWD/.harness}}"
HARNESS_HOME="${HARNESS_HOME:-$HOME/.harness}"
SHARED_ENGINE="$HARNESS_HOME/engine"

die(){ echo "harness migrate: $*" >&2; exit 1; }

# Refuse unless the shared host engine exists — migrate re-points the project AT it, so it must be
# installed first. Checking before touching anything keeps a refusal from destroying state.
[[ -e "$SHARED_ENGINE/bin/harness" ]] || die "shared engine not found at $SHARED_ENGINE — run 'harness install' first."

# Must be a real project state dir. config is preserved, so its presence also makes migrate
# idempotent: a re-run on an already state-only .harness/ still finds config and is a clean no-op.
[[ -f "$STATE_DIR/config" ]] || die "no config at $STATE_DIR — not a Harness project (run 'harness init')."

# PRESERVE — the per-project STATE that must survive (kept for the idempotent-rerun no-op and as a
# belt-and-braces guard so a known state entry is never matched as engine).
preserve=(config targets.tsv run worktrees checkouts)
in_preserve(){ local x; for x in "${preserve[@]}"; do [[ "$1" == "$x" ]] && return 0; done; return 1; }

# is_engine_entry NAME — true when NAME is a KNOWN vendored-engine artifact that migrate strips.
# We remove ONLY recognised engine entries rather than "everything not preserved", so unknown user
# content an operator dropped into .harness/ (notes/, archive/, scratch files …) is NOT destroyed.
# Covers both the pre-#52 top-level layout (lib.sh, *.sh, issuelib.py, bin/) and the current engine
# tree (scripts/, skill/, docs/, test/, install.sh, update.sh, LICENSE, README) plus the vendored
# VCS metadata (.git, .gitignore). prompts/ is handled separately (templates stripped, *.local.md
# overrides stashed+restored).
is_engine_entry(){
  case "$1" in
    .git|.gitignore|.gitattributes) return 0 ;;
    bin|docs|scripts|skill|test) return 0 ;;
    install.sh|update.sh) return 0 ;;
    LICENSE|README|README.md) return 0 ;;
    issuelib.py) return 0 ;;
    *.sh|*.py) return 0 ;;   # top-level engine scripts (lib.sh, init.sh, start.sh, *.py helpers)
  esac
  return 1
}

# prompts/*.local.md are project-local prompt OVERRIDES (state) living inside the otherwise-engine
# prompts/ dir. Stash them so removing prompts/ (engine templates) doesn't drop them; restore after.
stash=""
if compgen -G "$STATE_DIR/prompts/*.local.md" >/dev/null 2>&1; then
  stash="$(mktemp -d)"; cp "$STATE_DIR"/prompts/*.local.md "$stash/" 2>/dev/null || true
fi

# Remove ONLY recognised vendored-engine entries (incl. dotfiles like .git/.gitignore). Preserved
# state and any UNKNOWN user content are left untouched. prompts/ is special: its engine TEMPLATES
# (*.md that are not *.local.md) are stripped, but the dir + any *.local.md overrides are kept.
shopt -s dotglob nullglob
for path in "$STATE_DIR"/*; do
  name="$(basename "$path")"
  in_preserve "$name" && continue
  if [[ "$name" == prompts && -d "$path" ]]; then
    for f in "$path"/*; do
      fn="$(basename "$f")"
      case "$fn" in *.local.md) continue ;; esac   # state override — keep
      rm -rf "$f"
    done
    continue
  fi
  is_engine_entry "$name" && rm -rf "$path"
done
shopt -u dotglob nullglob

# Restore stashed prompt overrides into a fresh prompts/ (now state-only).
if [[ -n "$stash" ]]; then
  mkdir -p "$STATE_DIR/prompts"
  cp "$stash"/*.local.md "$STATE_DIR/prompts/" 2>/dev/null || true
  rm -rf "$stash"
fi

echo "migrated $STATE_DIR to state-only (engine: $SHARED_ENGINE)"

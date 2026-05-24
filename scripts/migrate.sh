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

# PRESERVE — the per-project STATE that must survive. Everything else in STATE_DIR is vendored engine
# (lib.sh, *.sh, bin/, issuelib.py, prompts/ templates, README, docs/, test/, skill/, .git, .gitignore
# …) and is removed.
preserve=(config targets.tsv run worktrees checkouts)
in_preserve(){ local x; for x in "${preserve[@]}"; do [[ "$1" == "$x" ]] && return 0; done; return 1; }

# prompts/*.local.md are project-local prompt OVERRIDES (state) living inside the otherwise-engine
# prompts/ dir. Stash them so removing prompts/ (engine templates) doesn't drop them; restore after.
stash=""
if compgen -G "$STATE_DIR/prompts/*.local.md" >/dev/null 2>&1; then
  stash="$(mktemp -d)"; cp "$STATE_DIR"/prompts/*.local.md "$stash/" 2>/dev/null || true
fi

# Remove every non-preserved entry, including dotfiles (.git, .gitignore).
shopt -s dotglob nullglob
for path in "$STATE_DIR"/*; do
  name="$(basename "$path")"
  in_preserve "$name" && continue
  rm -rf "$path"
done
shopt -u dotglob nullglob

# Restore stashed prompt overrides into a fresh prompts/ (now state-only).
if [[ -n "$stash" ]]; then
  mkdir -p "$STATE_DIR/prompts"
  cp "$stash"/*.local.md "$STATE_DIR/prompts/" 2>/dev/null || true
  rm -rf "$stash"
fi

echo "migrated $STATE_DIR to state-only (engine: $SHARED_ENGINE)"

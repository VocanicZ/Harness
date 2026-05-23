#!/usr/bin/env bash
# update.sh [--with-skills] — fast-forward the .harness engine + redeploy the /harness skill,
# WITHOUT re-running the wizard or re-cloning. NEVER removes or alters user config.
#   --with-skills  also refresh the superpowers/ralph-loop plugins + matt-pocock skills.
set -uo pipefail
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"
WITH_SKILLS=0; [[ "${1:-}" == "--with-skills" ]] && WITH_SKILLS=1

# 1) snapshot user-owned state BEFORE touching git (hard guarantee: config survives).
SNAP="$(mktemp -d)"
for f in config targets.tsv; do
  [[ -f "$HARNESS_DIR/$f" ]] && cp -p "$HARNESS_DIR/$f" "$SNAP/$f"
done

# 2) fast-forward ONLY. No destructive git operations that discard user files
#    (config/targets.tsv/run/worktrees/checkouts are gitignored and must survive).
if ! git -C "$HARNESS_DIR" pull --ff-only; then
  echo "ERROR: 'git pull --ff-only' failed (diverged or local engine edits)." >&2
  echo "       Resolve in $HARNESS_DIR manually; your config was NOT touched." >&2
  rm -rf "$SNAP"; exit 1
fi

# 3) verify/restore user config (defends against a misbehaving upstream that tracks a config).
for f in config targets.tsv; do
  if [[ -f "$SNAP/$f" ]]; then
    if [[ ! -f "$HARNESS_DIR/$f" ]] || ! cmp -s "$SNAP/$f" "$HARNESS_DIR/$f"; then
      cp -p "$SNAP/$f" "$HARNESS_DIR/$f"
      echo "  restored user $f (upstream tried to change it)"
    fi
  fi
done
echo "  config preserved"
rm -rf "$SNAP"

# 4) redeploy the /harness operator skill + the per-command thin skills.
mkdir -p "$PROJECT_ROOT/.claude/skills/harness"
cp "$HARNESS_DIR/skill/SKILL.md" "$PROJECT_ROOT/.claude/skills/harness/SKILL.md"
echo "  redeployed .claude/skills/harness/SKILL.md"
for d in "$HARNESS_DIR"/skill/*/; do
  [[ -f "$d/SKILL.md" ]] || continue
  n="$(basename "$d")"
  mkdir -p "$PROJECT_ROOT/.claude/skills/$n"
  cp "$d/SKILL.md" "$PROJECT_ROOT/.claude/skills/$n/SKILL.md"
  echo "  redeployed .claude/skills/$n/SKILL.md"
done

# 5) optional plugin/skill refresh (reuse install.sh's ensure_skills).
if (( WITH_SKILLS )); then
  HARNESS_INSTALL_NOMAIN=1 source "$HARNESS_DIR/install.sh"
  ensure_skills
fi

# 6) if a pool is running, new engine logic only applies after a relaunch.
if compgen -G "$HARNESS_DIR/run/worker-*.pid" >/dev/null 2>&1; then
  for pf in "$HARNESS_DIR"/run/worker-*.pid; do
    kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null && {
      echo "NOTE: a worker pool is running. Live workers keep the OLD engine logic until relaunched."
      echo "      To apply this update safely: harness pause  →  let sessions drain  →  harness stop  →  harness start --recover"
      break
    }
  done
fi
echo "Update complete."

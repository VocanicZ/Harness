#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLS="$(mktemp)"; : > "$CALLS"; export CALLS
# stub the tools setup checks + seeds; single topology, one unit "main"
export HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme
gh(){ echo "gh $*" >> "$CALLS"; case "$1 $2" in "auth status") return 0;; "label create") return 0;; esac; return 0; }
export -f gh
# fake claude/tmux on PATH so prereq checks pass
BIN="$(mktemp -d)"; for t in tmux claude; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$t"; chmod +x "$BIN/$t"; done
export PATH="$BIN:$PATH"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
bash "$HERE/../scripts/setup.sh" >/dev/null 2>&1
assert "setup seeded labels (gh label create called)" "grep -q 'label create' '$CALLS'"
# idempotent: second run also succeeds
bash "$HERE/../scripts/setup.sh" >/dev/null 2>&1; assert "setup rerun ok" "true"
rm -rf "$BIN" "$CALLS"

# ── upward .harness/config discovery (#55, PRD #52): a subcommand run from a NESTED subdirectory of
# a project resolves STATE_DIR by walking UP to the project's .harness/config (like git finds .git).
# Copy the engine, swap one subcommand for a sentinel that echoes the resolved STATE_DIR, lay down a
# fake project with a nested subdir, and invoke the entrypoint from deep inside it.
ENG="$(mktemp -d)/engine"; cp -r "$HERE/.." "$ENG"
cat > "$ENG/scripts/status.sh" <<'EOF'
#!/usr/bin/env bash
echo "SENTINEL_STATE=$STATE_DIR"
EOF
PROJ="$(mktemp -d)"; mkdir -p "$PROJ/.harness" "$PROJ/sub/deep"; : > "$PROJ/.harness/config"
EXPECT="$(cd "$PROJ" && pwd -P)/.harness"
out="$(cd "$PROJ/sub/deep" && env -u STATE_DIR -u HARNESS_DIR "$ENG/bin/harness" status 2>&1)"
GOT="${out#SENTINEL_STATE=}"
assert "subcommand from nested subdir discovers the project's .harness via upward walk" "[[ '$GOT' == '$EXPECT' ]]"
rm -rf "$ENG" "$PROJ"

echo "── setup ok"

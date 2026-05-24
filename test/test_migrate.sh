#!/usr/bin/env bash
# test_migrate.sh — `harness migrate` (#56, PRD #52 slice final): convert a VENDORED .harness/ (the
# pre-#52 layout where engine code + .git lived inside the project's .harness/ alongside its state)
# into a STATE-ONLY .harness/ that runs off the shared host engine (~/.harness/engine, #54).
# Preserves per-project STATE (config, targets.tsv, run/ incl. claims/, worktrees/, checkouts/,
# prompts/*.local.md); removes the vendored engine clone + its .git. Idempotent. Refuses if the
# shared engine is absent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }

# mk_vendored <dir> — build a fake vendored .harness/ at <dir>: engine code (lib.sh, *.sh, bin/,
# issuelib.py, README, prompts/ templates) + a .git + .gitignore, PLUS per-project state (config,
# targets.tsv, run/claims, worktrees/, checkouts/, prompts/*.local.md). Returns with $dir populated.
mk_vendored(){ local d="$1"
  mkdir -p "$d/run/claims" "$d/worktrees/wt-1" "$d/checkouts/repo-a" "$d/bin" "$d/prompts" "$d/.git"
  # engine code — must be REMOVED by migrate
  : > "$d/lib.sh"; : > "$d/init.sh"; : > "$d/start.sh"; : > "$d/issuelib.py"
  : > "$d/bin/harness"; : > "$d/README.md"; : > "$d/.gitignore"
  : > "$d/.git/HEAD"; : > "$d/prompts/impl.md"           # engine prompt TEMPLATE — removed
  # per-project state — must be PRESERVED (with contents intact)
  printf 'HARNESS_MODE=issue-only\nHARNESS_OWNER=acme\n' > "$d/config"
  printf 'id\trepo\tdeps\tdesc\n' > "$d/targets.tsv"
  printf 'claimdata\n' > "$d/run/claims/main.claim"
  printf 'wtfile\n'    > "$d/worktrees/wt-1/file"
  : > "$d/checkouts/repo-a/.keep"
  printf 'local override\n' > "$d/prompts/impl.local.md" # project prompt OVERRIDE (state) — preserved
}

# mk_engine <home> — build a fake shared host engine at <home>/engine (the marker migrate looks for).
mk_engine(){ mkdir -p "$1/engine/bin"; : > "$1/engine/bin/harness"; }

# ── happy path: vendored → state-only, state preserved, engine + .git gone ──────────────
VEND="$(mktemp -d)/.harness"; mk_vendored "$VEND"
HH="$(mktemp -d)/.harness"; mk_engine "$HH"
out="$(STATE_DIR="$VEND" HARNESS_HOME="$HH" bash "$HERE/../scripts/migrate.sh" 2>&1)"; rc=$?
assert "migrate exits 0 on a vendored .harness/"        "[[ $rc -eq 0 ]]"
# state preserved (presence + contents)
assert "config preserved"                               "[[ -f '$VEND/config' ]]"
assert "config contents intact"                         "grep -q 'HARNESS_MODE=issue-only' '$VEND/config'"
assert "targets.tsv preserved"                          "[[ -f '$VEND/targets.tsv' ]]"
assert "run/claims preserved"                           "[[ -f '$VEND/run/claims/main.claim' ]]"
assert "claims contents intact"                         "grep -q 'claimdata' '$VEND/run/claims/main.claim'"
assert "worktrees/ preserved"                           "[[ -f '$VEND/worktrees/wt-1/file' ]]"
assert "worktree contents intact"                       "grep -q 'wtfile' '$VEND/worktrees/wt-1/file'"
assert "checkouts/ preserved"                           "[[ -d '$VEND/checkouts/repo-a' ]]"
assert "prompts/*.local.md override preserved"          "[[ -f '$VEND/prompts/impl.local.md' ]]"
# engine code + .git removed
assert "engine lib.sh removed"                          "[[ ! -e '$VEND/lib.sh' ]]"
assert "engine *.sh scripts removed"                    "[[ ! -e '$VEND/init.sh' && ! -e '$VEND/start.sh' ]]"
assert "engine bin/ removed"                            "[[ ! -e '$VEND/bin' ]]"
assert "engine issuelib.py removed"                     "[[ ! -e '$VEND/issuelib.py' ]]"
assert "engine README removed"                          "[[ ! -e '$VEND/README.md' ]]"
assert "vendored .git removed"                          "[[ ! -e '$VEND/.git' ]]"
assert ".gitignore removed"                             "[[ ! -e '$VEND/.gitignore' ]]"
assert "engine prompt TEMPLATE removed"                 "[[ ! -e '$VEND/prompts/impl.md' ]]"

# ── idempotent: a second run on the already-migrated dir is a clean no-op (exit 0, state intact) ──
out2="$(STATE_DIR="$VEND" HARNESS_HOME="$HH" bash "$HERE/../scripts/migrate.sh" 2>&1)"; rc2=$?
assert "migrate is idempotent (exit 0 on already state-only)" "[[ $rc2 -eq 0 ]]"
assert "config still present after 2nd run"             "[[ -f '$VEND/config' ]]"
assert "worktrees still present after 2nd run"          "[[ -f '$VEND/worktrees/wt-1/file' ]]"
assert "prompts override still present after 2nd run"   "[[ -f '$VEND/prompts/impl.local.md' ]]"

# ── refuses when the shared engine is absent (and does NOT destroy state) ────────────────
VEND2="$(mktemp -d)/.harness"; mk_vendored "$VEND2"
NOENGINE="$(mktemp -d)/.harness"   # exists but has no engine/ subdir
out3="$(STATE_DIR="$VEND2" HARNESS_HOME="$NOENGINE" bash "$HERE/../scripts/migrate.sh" 2>&1)"; rc3=$?
assert "migrate refuses (non-zero) with no shared engine" "[[ $rc3 -ne 0 ]]"
assert "refusal mentions the shared engine / install"     "grep -qiE 'engine|install' <<< \"\$out3\""
assert "refusal does NOT destroy state (config intact)"   "[[ -f '$VEND2/config' ]]"
assert "refusal does NOT remove engine code yet"          "[[ -e '$VEND2/lib.sh' ]]"

# ── end-to-end via the CLI: `harness migrate` run from a vendored project root discovers its
# .harness/ (config present in a vendored layout), strips the engine, and preserves state. ──────
PROJ="$(mktemp -d)"; mk_vendored "$PROJ/.harness"
HH2="$(mktemp -d)/.harness"; mk_engine "$HH2"
out4="$(cd "$PROJ"; unset STATE_DIR HARNESS_DIR; HARNESS_HOME="$HH2" "$HERE/../bin/harness" migrate 2>&1)"; rc4=$?
assert "CLI migrate exits 0 (discovers .harness from cwd)" "[[ $rc4 -eq 0 ]]"
assert "CLI migrate preserves config"                      "[[ -f '$PROJ/.harness/config' ]]"
assert "CLI migrate removes engine lib.sh"                 "[[ ! -e '$PROJ/.harness/lib.sh' ]]"
assert "CLI migrate removes vendored .git"                 "[[ ! -e '$PROJ/.harness/.git' ]]"

echo "── migrate ok"

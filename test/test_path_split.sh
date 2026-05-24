#!/usr/bin/env bash
# test_path_split.sh — the ENGINE_DIR / STATE_DIR split (#53, PRD #52 slice 1).
# lib.sh is the single chokepoint: ASSET paths (prompts, issuelib.py, sub-scripts) resolve under
# ENGINE_DIR; STATE paths (run/, claims/, worktrees/, config, targets.tsv, PROJECT_ROOT) under
# STATE_DIR. Behavior-preserving: when neither is set, BOTH default to lib.sh's own dir (the
# vendored .harness/), so the existing fleet keeps working unchanged.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
rc=0

# ── backward-compat default: nothing set → ENGINE_DIR == STATE_DIR == lib.sh's own dir ──
# Isolate the state mkdir into a temp STATE so sourcing doesn't litter the repo, while still
# proving the DEFAULTING logic (both fall back to the same base when unset).
( unset ENGINE_DIR STATE_DIR
  export RUN_DIR="$(mktemp -d)"     # keep lib.sh's mkdir out of the repo
  source "$HERE/../lib.sh"
  LIBDIR="$(cd "$HERE/.." && pwd)"
  assert_eq "${ENGINE_DIR:-UNSET}" "$LIBDIR" "ENGINE_DIR defaults to lib.sh's own dir"
  assert_eq "${STATE_DIR:-UNSET}"  "$LIBDIR" "STATE_DIR defaults to lib.sh's own dir"
  assert_eq "${ENGINE_DIR:-x}" "${STATE_DIR:-y}" "ENGINE_DIR and STATE_DIR coincide when unseparated"
  finish ) || rc=1

# ── separated: ASSET paths resolve under ENGINE_DIR (never STATE_DIR) ──
( ENG="$(mktemp -d)"; ST="$(mktemp -d)"
  export ENGINE_DIR="$ENG" STATE_DIR="$ST"
  source "$HERE/../lib.sh"
  assert_eq "$PROMPTS_DIR" "$ENG/prompts"     "PROMPTS_DIR resolves under ENGINE_DIR"
  assert_eq "$ISSUELIB"    "$ENG/issuelib.py" "ISSUELIB (issuelib.py path) resolves under ENGINE_DIR"
  finish ) || rc=1

# ── separated: STATE paths resolve under STATE_DIR (never ENGINE_DIR) ──
( ENG="$(mktemp -d)"; ST="$(mktemp -d)"
  export ENGINE_DIR="$ENG" STATE_DIR="$ST"
  source "$HERE/../lib.sh"
  assert_eq "$CONFIG"        "$ST/config"        "CONFIG resolves under STATE_DIR"
  assert_eq "$TARGETS_TSV"   "$ST/targets.tsv"   "TARGETS_TSV resolves under STATE_DIR"
  assert_eq "$RUN_DIR"       "$ST/run"           "RUN_DIR resolves under STATE_DIR"
  assert_eq "$WORKTREES_DIR" "$ST/worktrees"     "WORKTREES_DIR resolves under STATE_DIR"
  assert_eq "$CHECKOUTS_DIR" "$ST/checkouts"     "CHECKOUTS_DIR resolves under STATE_DIR"
  assert_eq "$CLAIMS_DIR"    "$ST/run/claims"    "CLAIMS_DIR resolves under STATE_DIR"
  assert_eq "$POOL_LOCK"     "$ST/run/pool.lock" "POOL_LOCK resolves under STATE_DIR"
  assert_eq "$PROJECT_ROOT"  "$(cd "$ST/.." && pwd)" "PROJECT_ROOT is the parent of STATE_DIR"
  finish ) || rc=1

# ── no cross-contamination: sourcing creates state ONLY under STATE_DIR, never ENGINE_DIR ──
# lib.sh mkdir -p's its runtime state on source; with the dirs separated, a pristine ENGINE_DIR
# must stay pristine (no run/worktrees/checkouts/claims written into the engine).
( ENG="$(mktemp -d)"; ST="$(mktemp -d)"
  export ENGINE_DIR="$ENG" STATE_DIR="$ST"
  source "$HERE/../lib.sh"
  assert_no "no run/ written into ENGINE_DIR"        test -e "$ENG/run"
  assert_no "no worktrees/ written into ENGINE_DIR"  test -e "$ENG/worktrees"
  assert_no "no checkouts/ written into ENGINE_DIR"  test -e "$ENG/checkouts"
  assert_ok "run/ created under STATE_DIR"           test -d "$ST/run"
  assert_ok "worktrees/ created under STATE_DIR"     test -d "$ST/worktrees"
  # assets never resolve under STATE_DIR
  assert_no "PROMPTS_DIR is not under STATE_DIR" bash -c '[[ "'"$PROMPTS_DIR"'" == "'"$ST"'"/* ]]'
  assert_no "ISSUELIB is not under STATE_DIR"    bash -c '[[ "'"$ISSUELIB"'" == "'"$ST"'"/* ]]'
  finish ) || rc=1

# ── bin/harness resolves ENGINE_DIR via realpath: a PATH symlink runs the REAL engine ──
# Copy the engine to a temp dir, swap one subcommand for a sentinel, symlink the entrypoint into a
# separate dir (as `harness` on PATH would be), and invoke it from an unrelated cwd. If ENGINE_DIR
# resolved from the symlink's own dir (no realpath), exec would miss the engine; the sentinel only
# prints when ENGINE_DIR == the symlink TARGET's engine root.
( ENG="$(mktemp -d)/engine"; cp -r "$HERE/.." "$ENG"
  cat > "$ENG/status.sh" <<'EOF'
#!/usr/bin/env bash
echo "SENTINEL_ENGINE=$ENGINE_DIR"
EOF
  BIN="$(mktemp -d)"; ln -s "$ENG/bin/harness" "$BIN/harness"
  out="$(cd /tmp && "$BIN/harness" status 2>&1)"
  assert_ok "symlinked entrypoint execs the real engine's subcommand" \
    bash -c '[[ "'"$out"'" == SENTINEL_ENGINE=* ]]'
  assert_eq "${out#SENTINEL_ENGINE=}" "$ENG" "ENGINE_DIR resolves to the symlink target's engine root"
  finish ) || rc=1

exit $rc

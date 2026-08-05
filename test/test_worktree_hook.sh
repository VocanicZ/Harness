#!/usr/bin/env bash
# test_worktree_hook.sh — HARNESS_WORKTREE_HOOK: provision a freshly added worktree.
# `git worktree add` yields a BARE checkout — submodules are empty dirs, and untracked
# toolchain/build/cache state from the main checkout is absent. The hook is the seam a
# project uses to fix that up. Guards: default is a true no-op, failures are non-fatal
# (a hard fail here would strand the issue under agent-working with no session, the #34
# failure mode), and the hook is actually WIRED into the spawn paths.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
export RUN_DIR="$(mktemp -d)"   # keep lib.sh's mkdir out of the repo
rc=0

# ── unit: run_worktree_hook branches ─────────────────────────────────────────
(
  source "$HERE/../scripts/lib.sh"
  TMP="$(mktemp -d)"; WD="$TMP/wt"; mkdir -p "$WD"
  PROJECT_ROOT="$TMP"

  # 1. unset (the default) is a no-op that succeeds — repos that clone-and-go see no change.
  HARNESS_WORKTREE_HOOK=""
  assert_ok "unset hook is a no-op that succeeds" run_worktree_hook "$WD"

  # 2. absolute + executable: runs, cwd is the worktree, path arrives as $1.
  cat > "$TMP/hook.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n%s\n' "$PWD" "$1" > "$1/hook.out"
EOF
  chmod +x "$TMP/hook.sh"
  HARNESS_WORKTREE_HOOK="$TMP/hook.sh"
  assert_ok "absolute hook runs and succeeds" run_worktree_hook "$WD"
  assert_eq "$(sed -n 1p "$WD/hook.out")" "$WD" "hook runs with cwd = the new worktree"
  assert_eq "$(sed -n 2p "$WD/hook.out")" "$WD" "hook receives the worktree path as \$1"

  # 3. a relative hook resolves against PROJECT_ROOT, not against the caller's cwd —
  #    the natural config value is a repo-relative path like .harness/worktree-hook.sh.
  rm -f "$WD/hook.out"
  mkdir -p "$TMP/.harness"; cp "$TMP/hook.sh" "$TMP/.harness/worktree-hook.sh"
  HARNESS_WORKTREE_HOOK=".harness/worktree-hook.sh"
  assert_ok "relative hook resolves against PROJECT_ROOT" run_worktree_hook "$WD"
  assert_ok "relative hook actually ran" test -f "$WD/hook.out"

  # 4. configured but not executable: skipped, still succeeds (never strands a spawn).
  printf 'not executable\n' > "$TMP/noexec.sh"; chmod -x "$TMP/noexec.sh"
  HARNESS_WORKTREE_HOOK="$TMP/noexec.sh"
  assert_ok "non-executable hook is skipped, not fatal" run_worktree_hook "$WD"

  # 5. a hook that FAILS is logged and swallowed — the session still launches.
  printf '#!/usr/bin/env bash\nexit 3\n' > "$TMP/fail.sh"; chmod +x "$TMP/fail.sh"
  HARNESS_WORKTREE_HOOK="$TMP/fail.sh"
  assert_ok "failing hook is non-fatal" run_worktree_hook "$WD"

  # 6. a missing hook path is skipped, not fatal (same guard as non-executable).
  HARNESS_WORKTREE_HOOK="$TMP/does-not-exist.sh"
  assert_ok "missing hook path is skipped, not fatal" run_worktree_hook "$WD"

  finish
) || rc=1

# ── integration: the hook is wired into the spawn paths ──────────────────────
# A helper nothing calls is the real risk here, so drive spawn_impl / spawn_bug with
# every I/O stubbed and assert the hook fired in each fresh worktree.
spawn_fires_hook(){   # <label> <spawn-invocation...>
  local label="$1"; shift
  local out; out="$(bash -c '
    set -uo pipefail
    HERE="'"$HERE"'"
    export RUN_DIR="$(mktemp -d)"
    source "$HERE/../scripts/lib.sh"
    source "$HERE/../scripts/drive.sh"
    TMP="$(mktemp -d)"
    WORKTREES_DIR="$TMP/worktrees"; mkdir -p "$WORKTREES_DIR"
    printf "#!/usr/bin/env bash\ntouch \"\$1/HOOK_RAN\"\n" > "$TMP/hook.sh"; chmod +x "$TMP/hook.sh"
    HARNESS_WORKTREE_HOOK="$TMP/hook.sh"
    HARNESS_TOPOLOGY=single
    UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget; CHECKOUT="$TMP/co"
    # Stub all I/O. `git` is a no-op, so `worktree add` "succeeds" without creating the
    # dir — pre-create every path spawn_* may use so the hook has somewhere to land.
    mkdir -p "$WORKTREES_DIR/main-i7" "$(bug_worktree acme/widget 7)" "$(triage_worktree acme/widget 7)"
    git(){ :; }; gh(){ :; }; tmux(){ :; }; render(){ :; }; launch_claude(){ :; }
    default_branch(){ echo main; }; ensure_safe(){ :; }; ensure_checkout(){ :; }
    remove_worktree(){ :; }
    '"$*"' >/dev/null 2>&1
    find "$WORKTREES_DIR" "$(dirname "$(bug_worktree acme/widget 7)")" -name HOOK_RAN 2>/dev/null | head -1
  ')"
  assert_ok "$label" test -n "$out"
}

(
  source "$HERE/../scripts/lib.sh"
  spawn_fires_hook "spawn_impl runs the worktree hook"      'spawn_impl 7 "PROMISE"'
  spawn_fires_hook "spawn_bug fix runs the worktree hook"   'spawn_bug 7 fix'
  spawn_fires_hook "spawn_bug triage runs the worktree hook" 'spawn_bug 7 triage'
  finish
) || rc=1

exit $rc

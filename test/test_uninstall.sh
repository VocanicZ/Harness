#!/usr/bin/env bash
# test_uninstall.sh — `harness uninstall [--force]` (#61, PRD #52): tear down a Harness
# install/project. Removes the shared host engine (~/.harness/engine) + its PATH symlink, this
# project's state-only .harness/ + the project .gitignore '.harness/' entry, and the deployed
# /harness* operator skills (~/.claude/skills). The default path STOPS a live fleet first
# (stop --clean) and is confirm-gated; --force skips BOTH the stop guard AND the prompt.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALL="$HERE/../scripts/uninstall.sh"
CLI="$HERE/../bin/harness"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }

# mk_layout <root> — build a throwaway install+project under <root>: a shared engine dir, a PATH
# symlink onto it, user-scope /harness* skills (umbrella + per-command) alongside an UNRELATED
# skill that must survive, and a project whose state-only .harness/ + .gitignore carry a removable
# '.harness/' entry (plus unrelated entries that must survive).
mk_layout(){ local root="$1"
  mkdir -p "$root/.harness/engine/bin" "$root/bin" "$root/.claude/skills" \
           "$root/proj/.harness/run/claims" "$root/proj/.harness/worktrees"
  : > "$root/.harness/engine/bin/harness"; chmod +x "$root/.harness/engine/bin/harness"
  ln -sfn "$root/.harness/engine/bin/harness" "$root/bin/harness"
  local s
  for s in harness harness-init harness-stop harness-uninstall; do
    mkdir -p "$root/.claude/skills/$s"; : > "$root/.claude/skills/$s/SKILL.md"
  done
  mkdir -p "$root/.claude/skills/to-prd"; : > "$root/.claude/skills/to-prd/SKILL.md"   # unrelated — survives
  printf ': "${HARNESS_MODE:=issue-only}"\n: "${HARNESS_TOPOLOGY:=single}"\n' > "$root/proj/.harness/config"
  printf 'node_modules/\n.harness/\ndist/\n' > "$root/proj/.gitignore"
}

# Existing default/--force/CLI subprocess tests below assert the SINGLE-FLEET behavior (engine +
# PATH link removed). On a multi-fleet test host the real guard would (correctly) trip on live
# sibling workers / a populated poller registry and preserve the engine — host state leaking into a
# temp-layout test. So these tests pin single-fleet by stubbing the overridable guard FALSE in a
# wrapper that sources uninstall.sh then calls main; the multi-fleet path has dedicated tests (R8/R9).
SINGLE_FLEET='source "$1"; other_fleets_depend_on_engine(){ return 1; }; shift; main "$@"'

# ── tracer: --force removes the shared engine ───────────────────────────────────────────
R="$(mktemp -d)"; mk_layout "$R"
out="$(HARNESS_UNINSTALL_NOMAIN=1 HARNESS_HOME="$R/.harness" HARNESS_BIN_DIR="$R/bin" \
       HARNESS_USER_SKILLS="$R/.claude/skills" STATE_DIR="$R/proj/.harness" \
       bash -c "$SINGLE_FLEET" _ "$UNINSTALL" --force </dev/null 2>&1)"; rc=$?
assert "--force exits 0"                "[[ $rc -eq 0 ]]"
assert "--force removes the shared engine" "[[ ! -e '$R/.harness/engine' ]]"
assert "--force removes the PATH symlink"  "[[ ! -L '$R/bin/harness' && ! -e '$R/bin/harness' ]]"
assert "--force removes the project .harness/" "[[ ! -e '$R/proj/.harness' ]]"
assert "--force strips the .gitignore '.harness/' entry" "! grep -qxF '.harness/' '$R/proj/.gitignore'"
assert "--force keeps unrelated .gitignore entries" \
  "grep -qxF 'node_modules/' '$R/proj/.gitignore' && grep -qxF 'dist/' '$R/proj/.gitignore'"
assert "--force removes umbrella /harness skill"   "[[ ! -e '$R/.claude/skills/harness' ]]"
assert "--force removes /harness-init skill"        "[[ ! -e '$R/.claude/skills/harness-init' ]]"
assert "--force removes /harness-uninstall skill"   "[[ ! -e '$R/.claude/skills/harness-uninstall' ]]"
assert "--force keeps unrelated skill (to-prd)"     "[[ -e '$R/.claude/skills/to-prd' ]]"

# ── confirm guard: declining the default (confirm-gated) path removes NOTHING ───────────
R2="$(mktemp -d)"; mk_layout "$R2"
out2="$(printf 'n\n' | HARNESS_HOME="$R2/.harness" HARNESS_BIN_DIR="$R2/bin" \
        HARNESS_USER_SKILLS="$R2/.claude/skills" STATE_DIR="$R2/proj/.harness" \
        bash "$UNINSTALL" 2>&1)"; rc2=$?
assert "declining exits non-zero"                  "[[ $rc2 -ne 0 ]]"
assert "decline leaves the engine intact"          "[[ -e '$R2/.harness/engine' ]]"
assert "decline leaves the PATH symlink intact"    "[[ -L '$R2/bin/harness' ]]"
assert "decline leaves the project .harness/ intact" "[[ -e '$R2/proj/.harness' ]]"
assert "decline leaves /harness skills intact"     "[[ -e '$R2/.claude/skills/harness' ]]"
assert "decline leaves the .gitignore entry intact" "grep -qxF '.harness/' '$R2/proj/.gitignore'"

# ── default STOPS the fleet first; --force SKIPS the stop guard (precise control flow) ──
# Source with the NOMAIN guard, then stub stop_fleet (records it ran) + the removal funcs (no-op)
# so we observe ONLY which steps main invokes, on real temp paths. Not exported → subprocess
# tests above/below are unaffected.
HARNESS_UNINSTALL_NOMAIN=1
source "$UNINSTALL"
MARK="$(mktemp -u)"
stop_fleet(){ : > "$MARK"; }
remove_engine(){ :; }; remove_path_link(){ :; }; remove_project_state(){ :; }; remove_skills(){ :; }
HARNESS_UNINSTALL_YES=1
rm -f "$MARK"; ( main )         >/dev/null 2>&1; assert "default path runs stop_fleet first" "[[ -e '$MARK' ]]"
rm -f "$MARK"; ( main --force ) >/dev/null 2>&1; assert "--force path SKIPS stop_fleet"      "[[ ! -e '$MARK' ]]"
unset HARNESS_UNINSTALL_NOMAIN HARNESS_UNINSTALL_YES

# ── confirmed default path removes ALL targets (exercises the REAL stop_fleet → stop.sh) ─
# Single-fleet host: insulate the multi-fleet guard from real host state via its env seams —
# HARNESS_UNINSTALL_WORKER_PIDS="" (no foreign workers, signal a off) + HARNESS_POLLER_DIR at an
# empty dir (no registered sibling projects, signal b off) — so the real guard returns FALSE.
R5="$(mktemp -d)"; mk_layout "$R5"
out5="$(HARNESS_UNINSTALL_YES=1 HARNESS_UNINSTALL_WORKER_PIDS="" HARNESS_POLLER_DIR="$R5/empty-poller" \
        HARNESS_HOME="$R5/.harness" HARNESS_BIN_DIR="$R5/bin" \
        HARNESS_USER_SKILLS="$R5/.claude/skills" STATE_DIR="$R5/proj/.harness" \
        bash "$UNINSTALL" 2>&1)"; rc5=$?
assert "confirmed default exits 0"                 "[[ $rc5 -eq 0 ]]"
assert "confirmed default ran stop --clean"        "grep -q 'stop --clean' <<< \"\$out5\""
assert "confirmed default removes the engine"      "[[ ! -e '$R5/.harness/engine' ]]"
assert "confirmed default removes project .harness/" "[[ ! -e '$R5/proj/.harness' ]]"
assert "confirmed default removes /harness skills" "[[ ! -e '$R5/.claude/skills/harness' ]]"

# ── idempotent: a second --force run on an already-removed layout is a clean no-op ──────
out6="$(HARNESS_UNINSTALL_WORKER_PIDS="" HARNESS_POLLER_DIR="$R/empty-poller" \
        HARNESS_HOME="$R/.harness" HARNESS_BIN_DIR="$R/bin" HARNESS_USER_SKILLS="$R/.claude/skills" \
        STATE_DIR="$R/proj/.harness" bash "$UNINSTALL" --force </dev/null 2>&1)"; rc6=$?
assert "second uninstall is idempotent (exit 0)"   "[[ $rc6 -eq 0 ]]"

# ── remove_gitignore_entry: a .gitignore whose ONLY line is '.harness/' (all-lines-removed case) ─
# grep -v exits non-zero when it selects zero lines, so a naive `grep -v … && mv` never strips the
# entry and litters a stray .gitignore.tmp. Assert the entry IS gone AND no .tmp is left behind.
RGI="$(mktemp -d)"; printf '.harness/\n' > "$RGI/.gitignore"
( HARNESS_UNINSTALL_NOMAIN=1; source "$UNINSTALL"; remove_gitignore_entry "$RGI/.gitignore" ) >/dev/null 2>&1
assert "single-line .gitignore: '.harness/' entry is stripped" "! grep -qxF '.harness/' '$RGI/.gitignore'"
assert "single-line .gitignore: no stray .gitignore.tmp left"  "[[ ! -e '$RGI/.gitignore.tmp' ]]"
# and the multi-line case still strips ONLY '.harness/' (regression guard for the fix)
RGI2="$(mktemp -d)"; printf 'node_modules/\n.harness/\ndist/\n' > "$RGI2/.gitignore"
( HARNESS_UNINSTALL_NOMAIN=1; source "$UNINSTALL"; remove_gitignore_entry "$RGI2/.gitignore" ) >/dev/null 2>&1
assert "multi-line .gitignore: '.harness/' stripped"           "! grep -qxF '.harness/' '$RGI2/.gitignore'"
assert "multi-line .gitignore: unrelated entries survive"      "grep -qxF 'node_modules/' '$RGI2/.gitignore' && grep -qxF 'dist/' '$RGI2/.gitignore'"
assert "multi-line .gitignore: no stray .gitignore.tmp left"   "[[ ! -e '$RGI2/.gitignore.tmp' ]]"

# ── multi-fleet guard: other fleets depend on the shared engine → engine + PATH link PRESERVED ─
# Source with NOMAIN, stub other_fleets_depend_on_engine TRUE (no real /proc / registry touched).
# Default (no --force-engine): engine + PATH link survive, but THIS project's state is still removed
# and a warning is emitted. Then --force-engine overrides and removes them.
R8="$(mktemp -d)"; mk_layout "$R8"
out8="$(HARNESS_UNINSTALL_NOMAIN=1 HARNESS_UNINSTALL_YES=1 \
        HARNESS_HOME="$R8/.harness" HARNESS_BIN_DIR="$R8/bin" \
        HARNESS_USER_SKILLS="$R8/.claude/skills" STATE_DIR="$R8/proj/.harness" \
        bash -c 'source "$1"; other_fleets_depend_on_engine(){ return 0; }; main' _ "$UNINSTALL" 2>&1)"; rc8=$?
assert "guard: exits 0"                              "[[ $rc8 -eq 0 ]]"
assert "guard: PRESERVES the shared engine"          "[[ -e '$R8/.harness/engine' ]]"
assert "guard: PRESERVES the PATH symlink"           "[[ -L '$R8/bin/harness' ]]"
assert "guard: still removes THIS project's .harness/" "[[ ! -e '$R8/proj/.harness' ]]"
assert "guard: still removes /harness skills"        "[[ ! -e '$R8/.claude/skills/harness' ]]"
assert "guard: emits a warning about other fleets"   "grep -qi 'other fleets' <<< \"\$out8\""
assert "guard: warning mentions --force-engine"      "grep -q -- '--force-engine' <<< \"\$out8\""

# guard TRUE + --force-engine → engine + PATH link ARE removed (override)
R9="$(mktemp -d)"; mk_layout "$R9"
out9="$(HARNESS_UNINSTALL_NOMAIN=1 HARNESS_UNINSTALL_YES=1 \
        HARNESS_HOME="$R9/.harness" HARNESS_BIN_DIR="$R9/bin" \
        HARNESS_USER_SKILLS="$R9/.claude/skills" STATE_DIR="$R9/proj/.harness" \
        bash -c 'source "$1"; other_fleets_depend_on_engine(){ return 0; }; main --force-engine' _ "$UNINSTALL" 2>&1)"; rc9=$?
assert "guard+--force-engine: exits 0"               "[[ $rc9 -eq 0 ]]"
assert "guard+--force-engine: REMOVES the engine"    "[[ ! -e '$R9/.harness/engine' ]]"
assert "guard+--force-engine: REMOVES the PATH link" "[[ ! -L '$R9/bin/harness' && ! -e '$R9/bin/harness' ]]"

# guard FALSE (single-fleet default) → engine + PATH link removed (unchanged behavior)
R10="$(mktemp -d)"; mk_layout "$R10"
out10="$(HARNESS_UNINSTALL_NOMAIN=1 HARNESS_UNINSTALL_YES=1 \
        HARNESS_HOME="$R10/.harness" HARNESS_BIN_DIR="$R10/bin" \
        HARNESS_USER_SKILLS="$R10/.claude/skills" STATE_DIR="$R10/proj/.harness" \
        bash -c 'source "$1"; other_fleets_depend_on_engine(){ return 1; }; main' _ "$UNINSTALL" 2>&1)"; rc10=$?
assert "guard FALSE: exits 0"                        "[[ $rc10 -eq 0 ]]"
assert "guard FALSE: REMOVES the engine (unchanged)" "[[ ! -e '$R10/.harness/engine' ]]"
assert "guard FALSE: REMOVES the PATH link (unchanged)" "[[ ! -L '$R10/bin/harness' && ! -e '$R10/bin/harness' ]]"

# ── CLI: `harness help` lists uninstall; `harness uninstall` dispatches via bin/harness ─
assert "help lists uninstall" "\"$CLI\" help 2>&1 | grep -q uninstall"
# end-to-end through the CLI from INSIDE a project (STATE_DIR discovered from cwd), --force path
R7="$(mktemp -d)"; mk_layout "$R7"
out7="$(cd "$R7/proj"; unset STATE_DIR HARNESS_DIR
        HARNESS_UNINSTALL_WORKER_PIDS="" HARNESS_POLLER_DIR="$R7/empty-poller" \
        HARNESS_HOME="$R7/.harness" HARNESS_BIN_DIR="$R7/bin" HARNESS_USER_SKILLS="$R7/.claude/skills" \
          "$CLI" uninstall --force </dev/null 2>&1)"; rc7=$?
assert "CLI uninstall --force exits 0"             "[[ $rc7 -eq 0 ]]"
assert "CLI uninstall removes the engine"          "[[ ! -e '$R7/.harness/engine' ]]"
assert "CLI uninstall removes project state (discovered from cwd)" "[[ ! -e '$R7/proj/.harness' ]]"

echo "── uninstall ok"

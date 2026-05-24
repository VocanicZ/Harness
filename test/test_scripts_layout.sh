#!/usr/bin/env bash
# test_scripts_layout.sh — engine sub-scripts live under scripts/ (#60, PRD #52). Only the PATH
# entrypoint (bin/harness) and the two host-level scripts (install.sh, update.sh) stay at the engine
# root; the other 18 sub-scripts moved into scripts/. The `harness <cmd>` interface is UNCHANGED:
# bin/harness still dispatches each subcommand — now to scripts/<name>.sh (install/update stay root).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"

# ── every moved sub-script lives under scripts/ (17 *.sh + issuelib.py) ──
MOVED=(init start stop status attach pause resume setup inject seed pool pool-worker \
       priority priority-worker drive lib migrate)
for s in "${MOVED[@]}"; do
  assert_ok "scripts/$s.sh exists" test -f "$ROOT/scripts/$s.sh"
done
assert_ok "scripts/issuelib.py exists" test -f "$ROOT/scripts/issuelib.py"

# ── the engine root keeps ONLY bin/harness + install.sh + update.sh — no sub-script lingers there ──
assert_ok "bin/harness kept at root" test -f "$ROOT/bin/harness"
assert_ok "install.sh kept at root"  test -f "$ROOT/install.sh"
assert_ok "update.sh kept at root"   test -f "$ROOT/update.sh"
root_sh="$(cd "$ROOT" && ls -1 ./*.sh 2>/dev/null | sed 's#^\./##' | sort | tr '\n' ' ')"
assert_eq "$root_sh" "install.sh update.sh " "only install.sh + update.sh remain as root-level *.sh"
assert_no "no issuelib.py at root"   test -e "$ROOT/issuelib.py"
assert_no "no lib.sh at root"        test -e "$ROOT/lib.sh"

# ── CLI interface unchanged: each project subcommand dispatches to scripts/<name>.sh ──
for pair in init:init start:start stop:stop status:status attach:attach pause:pause \
            resume:resume setup:setup migrate:migrate; do
  cmd="${pair%%:*}"; scr="${pair##*:}"
  assert_ok "harness $cmd → scripts/$scr.sh" grep -q "ENGINE_DIR/scripts/$scr.sh" "$ROOT/bin/harness"
done
assert_ok "harness plan|prd|issue → scripts/inject.sh" grep -q 'ENGINE_DIR/scripts/inject.sh' "$ROOT/bin/harness"
# install + update stay host-level at the engine root (NOT under scripts/)
assert_ok "harness install → root install.sh" grep -q 'ENGINE_DIR/install.sh' "$ROOT/bin/harness"
assert_ok "harness update → root update.sh"   grep -q 'ENGINE_DIR/update.sh'  "$ROOT/bin/harness"
assert_no "install is NOT routed under scripts/" grep -q 'ENGINE_DIR/scripts/install.sh' "$ROOT/bin/harness"

finish

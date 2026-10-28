#!/usr/bin/env bash
# test_cli_bin_cmdline.sh — #272: HARNESS_<CLI>_BIN is a COMMAND LINE, not one executable name.
# Hosts pin the account with HARNESS_CLAUDE_BIN="env CLAUDE_CONFIG_DIR=… claude" (tmux has dropped
# CLAUDE_CONFIG_DIR before). The launch line runs that whole; every check that needs an executable
# (start.sh's PATH check, cli_runnable, install.sh's _host_clis, the supervisor's pane-command and
# unit-PATH lists) goes through cli_exe, the command line's executable.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
mkdir -p "$T/bin" "$T/abs/path"
# The stub claude: records its environment's CLAUDE_CONFIG_DIR and answers --version.
STUB='#!/bin/sh
echo "stub CCD=${CLAUDE_CONFIG_DIR:-} args=$*" >> "'"$T"'/stub.log"
echo "2.0.0 (Claude Code)"'
printf '%s\n' "$STUB" >"$T/bin/claude"; printf '%s\n' "$STUB" >"$T/abs/path/claude"
chmod +x "$T/bin/claude" "$T/abs/path/claude"
export PATH="$T/bin:$PATH" HARNESS_BOOTSTRAP_PROMPT=P
unset CLAUDE_BIN CLAUDE_CONFIG_DIR

echo "=== 1: the seam — cli_exe, cli_runnable, cli_launch ==="
# case <HARNESS_CLAUDE_BIN> <want exe> <want launch prefix> <want CLAUDE_CONFIG_DIR seen by the stub>
check(){ local bin="$1" exe="$2" pre="$3" ccd="$4" line
  export HARNESS_CLAUDE_BIN="$bin"; : >"$T/stub.log"
  assert_eq "$(cli_exe)" "$exe" "[$bin] cli_exe is the executable"
  assert_ok "[$bin] command -v of cli_exe succeeds" bash -c 'command -v "$1" >/dev/null' _ "$(cli_exe)"
  assert_ok "[$bin] cli_runnable" cli_runnable
  line="$(cli_launch /wd UUID "" "")"
  assert_ok "[$bin] the launch line runs the whole command line" grep -qF -- "exec $pre --session-id UUID" <<<"$line"
  : >"$T/stub.log"; bash -c "${line#exec }" >/dev/null 2>&1
  assert_ok "[$bin] the launch line reaches the stub with CLAUDE_CONFIG_DIR=$ccd" grep -qx "stub CCD=$ccd args=--session-id UUID.*" "$T/stub.log"; }
check "env CLAUDE_CONFIG_DIR=/x claude" claude "env CLAUDE_CONFIG_DIR=/x claude" /x
check "claude" claude "claude" ""
check "$T/abs/path/claude" "$T/abs/path/claude" "$T/abs/path/claude" ""
# cli_runnable runs the WHOLE command line, so the env applies to --version too.
export HARNESS_CLAUDE_BIN="env CLAUDE_CONFIG_DIR=/x claude"; : >"$T/stub.log"; cli_runnable
assert_ok "cli_runnable runs --version under the command line's env" grep -qx "stub CCD=/x args=--version" "$T/stub.log"
# env's own options are skipped too; an option that takes an argument consumes it.
assert_eq "$(HARNESS_CLAUDE_BIN="env -i -u FOO A=1 B=2 /abs/claude --flag" cli_exe)" "/abs/claude" "env options and assignments are skipped"
assert_eq "$(HARNESS_CLAUDE_BIN="/usr/bin/env A=1 claude" cli_exe)" "claude" "an absolute env is env too"
assert_eq "$(HARNESS_CLAUDE_BIN="env CLAUDE_CONFIG_DIR=/x missing-claude" cli_exe)" "missing-claude" "a missing exe is still named"
assert_no "a command line whose exe is missing is not runnable" env HARNESS_CLAUDE_BIN="env A=1 no-such-claude-xyz" bash -c "source '$ROOT/scripts/cli/dispatch.sh'; cli_runnable"
# Every adapter answers cli_exe through the seam.
for c in $(cli_list); do assert_ok "$c: cli_exe answers" test -n "$(cli_with "$c" cli_exe)"; done
assert_eq "$(HARNESS_AGY_BIN="env X=1 agy" cli_with agy cli_exe)" "agy" "agy: the seam applies to every adapter"

echo "=== 2: start.sh's prerequisite check ==="
# start.sh cannot run end to end here (test_start_lock.sh header): a behavioural test of the check
# it runs, plus a static guard that it is the check start.sh actually carries.
start_check(){ bash -c "source '$ROOT/scripts/cli/dispatch.sh'; die(){ echo \"ERROR: \$*\"; exit 1; }
$(grep -E '^command -v "\$\(cli_' "$ROOT/scripts/start.sh")"; }
assert_eq "$(grep -cE '^command -v "\$\(cli_exe\)"' "$ROOT/scripts/start.sh")" "1" "start.sh checks cli_exe on PATH"
assert_eq "$(grep -c 'command -v "$(cli_bin)"' "$ROOT/scripts/start.sh")" "0" "start.sh never checks the whole command line on PATH"
assert_ok "the env-prefix form passes the check" env HARNESS_CLAUDE_BIN="env CLAUDE_CONFIG_DIR=/x claude" bash -c "$(declare -f start_check); ROOT='$ROOT' start_check"
out="$(HARNESS_CLAUDE_BIN="env CLAUDE_CONFIG_DIR=/x no-such-claude-xyz" start_check)"
assert_ok "a missing exe fails the check, naming the executable" grep -q "^ERROR: no-such-claude-xyz not found on PATH" <<<"$out"
assert_no "… not the whole command line" grep -qF "CLAUDE_CONFIG_DIR" <<<"$out"

echo "=== 3: install.sh and the supervisor read the executable ==="
export HARNESS_CLAUDE_BIN="env CLAUDE_CONFIG_DIR=/x claude"
hc="$(HARNESS_INSTALL_NOMAIN=1 bash -c "source '$ROOT/install.sh'; _host_clis")"
assert_ok "_host_clis lists claude for the env-prefix value" grep -qx claude <<<"$hc"
sup(){ bash -c "source '$ROOT/scripts/lib.sh'; source '$ROOT/scripts/supervise.sh'; $1"; }
cmds="$(sup sup_agent_cmds)"
assert_ok "sup_agent_cmds holds claude" grep -qE '(^|\|)claude(\||$)' <<<"$cmds"
assert_no "… not the basename of the whole command line" grep -qF 'x claude' <<<"$cmds"
assert_eq "$(sup 'sup_cmd_cli claude')" "claude" "sup_cmd_cli maps a claude pane to the claude CLI"
assert_eq "$(HARNESS_AGY_BIN="env X=1 /opt/antigravity" sup 'sup_cmd_cli antigravity')" "agy" "sup_cmd_cli maps a pane by the command line's executable"
assert_eq "$(sup sup_agent_bins | head -1)" "claude" "sup_agent_bins lists the executable, first"
assert_no "… never env or an assignment" grep -qxE 'env|CLAUDE_CONFIG_DIR=.*' <<<"$(sup sup_agent_bins)"
U="$T/unit"
for b in gh rtdd systemctl loginctl; do printf '#!/bin/sh\n' >"$T/bin/$b"; chmod +x "$T/bin/$b"; done
out="$(sup "SUP_UNIT_DIR='$U' SUP_SYSTEMCTL='$T/bin/systemctl' SUP_LOGINCTL='$T/bin/loginctl' SUP_HARNESS=/eng/bin/harness sup_install" 2>&1)"
assert_no "sup_install warns nothing about the env-prefix value" grep -q "not on PATH" <<<"$out"

echo "=== 4: docs ==="
assert_ok "README documents HARNESS_CLAUDE_BIN as a command line" grep -qE '^\| `HARNESS_CLAUDE_BIN` \| `claude` \|.*env CLAUDE_CONFIG_DIR=' "$ROOT/README.md"

finish

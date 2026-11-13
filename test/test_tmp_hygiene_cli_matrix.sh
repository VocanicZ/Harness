#!/usr/bin/env bash
# harness-test-timeout-windows: 3600
# test_tmp_hygiene_cli_matrix.sh — #294 / #608: test_cli_matrix.sh (a tmux socket under RUN_DIR, reaped by its own kill-server trap) run directly leaves its private TMPDIR empty.
# Split out of test_tmp_hygiene.sh so each file finishes under the per-test cap; the unit cases stay there.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/tmp_hygiene_lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# What the matrix leaves behind does not depend on how many CLIs it runs. On a Windows host (#1106) every CLI's cells cost hours (#963, #1024: a
# process start is ten times a Linux one) and a run of all of them is the 14400 s of test_cli_matrix.sh itself, past any cap this file could have;
# one CLI's cells make the same RUN_DIR, tmux socket and trap, so that is what is run there.
host_is_windows && export HARNESS_MATRIX_CLIS=claude
hygiene_direct test_cli_matrix.sh

finish

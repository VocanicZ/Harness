#!/usr/bin/env bash
# test_tmp_hygiene_supervise.sh — #294 / #608: test_supervise.sh (its own EXIT trap after make_env) run directly leaves its private TMPDIR empty.
# Split out of test_tmp_hygiene.sh so each file finishes under the per-test cap; the unit cases stay there.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/tmp_hygiene_lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

hygiene_direct test_supervise.sh

finish

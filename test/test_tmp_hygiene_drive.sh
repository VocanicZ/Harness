#!/usr/bin/env bash
# test_tmp_hygiene_drive.sh — #294 / #608: test_drive.sh (many make_env calls) run directly leaves its private TMPDIR empty.
# Split out of test_tmp_hygiene.sh so each file finishes under the per-test cap; the unit cases stay there.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/tmp_hygiene_lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

hygiene_direct test_drive.sh

finish

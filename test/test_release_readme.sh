#!/usr/bin/env bash
# test_release_readme.sh — PRD #274 / #284: README's Install/Update sections document releases,
# --version, --rollback and HARNESS_REF, and nothing still says update ff-pulls main.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
README="$HERE/../README.md"
sec="$(sed -n '/^## Install$/,/^## Prerequisites$/p; /^## Pause \/ resume \/ update$/,/^### Usage-limit checkpoints$/p' "$README")"
assert_ok "found the Install and Pause / resume / update sections" grep -q '^harness pause' <<<"$sec"
for term in 'harness release' 'harness --version' 'harness update --rollback' 'HARNESS_REF=' \
            'is the latest release.' 'SHA256SUMS' '~/.harness/releases/' 'releases/git-'; do
  assert_ok "Install/Update documents $term" grep -qF -- "$term" <<<"$sec"
done
# `help` needs no project: it prints usage before any state-dir discovery.
help="$(env -u STATE_DIR -u ENGINE_DIR bash "$HERE/../bin/harness" help)"
assert_no "README no longer says update ff-pulls the engine" grep -qiE 'ff-pull|pull --ff-only' "$README"
assert_no "harness help no longer says update ff-pulls"      grep -qiE 'ff-pull' <<<"$help"
assert_ok "harness help documents --version"  grep -qF -- '--version' <<<"$help"
assert_ok "harness help documents --rollback" grep -qF -- '--rollback' <<<"$help"
assert_ok "harness help documents release"    grep -qE '^  release ' <<<"$help"
finish

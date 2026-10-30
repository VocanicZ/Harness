#!/usr/bin/env bash
# test_cli_locale.sh — #333: pane matching must not depend on the caller's locale. The adapters'
# pane regexes are multibyte (codex's idle `^[›»]( |$)`, hermes's `^─{3,} [^─].* ─$` and busy
# `^── [^ ─]+ `): under LANG=C / LC_ALL=C, grep reads a bracket expression as single BYTES and
# applies `{3,}` to one byte, so none of them ever matched a UTF-8 pane. A fleet started from a C
# environment (systemd, cron, a bare tmux) then never saw a codex or hermes prompt. Each check runs
# in a fresh bash under the C locale that sources the engine itself, the way a fleet process does.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
F="$HERE/fixtures/cli"
# Only hermes's spinner footer (busy-typed.txt's), so `^── [^ ─]+ ` alone has to see the turn.
SPIN="$(mktemp)"; tmp_track "$SPIN"; grep -E '^── ' "$F/hermes/busy-typed.txt" > "$SPIN"
# under_c <locale vars…> -- <cli> <fn> <fixture> — run `cli_with <cli> <fn> "$(cat fixture)"` in a C bash.
under_c(){ local envs=(); while [[ $1 != -- ]]; do envs+=("$1"); shift; done; shift
  env -u LC_ALL -u LC_CTYPE -u LANG "${envs[@]}" bash -c '
    source "$1/../scripts/cli/dispatch.sh"; cli_with "$2" "$3" "$(cat "$4")"' _ "$HERE" "$@"; }
for loc in "LANG=C" "LC_ALL=C" "LANG=POSIX"; do
  assert_ok "codex idle pane is a prompt under $loc" under_c "$loc" -- codex cli_pane_prompt "$F/codex/idle.txt"
  assert_ok "hermes idle pane is a prompt under $loc" under_c "$loc" -- hermes cli_pane_prompt "$F/hermes/idle.txt"
  assert_ok "hermes busy pane is busy under $loc" under_c "$loc" -- hermes cli_pane_busy "$F/hermes/busy-typed.txt"
  assert_ok "hermes spinner footer alone is busy under $loc" under_c "$loc" -- hermes cli_pane_busy "$SPIN"
  assert_no "hermes busy pane is not a prompt under $loc" under_c "$loc" -- hermes cli_pane_prompt "$F/hermes/busy-typed.txt"
  assert_eq "$(under_c "$loc" -- codex cli_pane_prompt_line "$F/codex/idle.txt")" \
    "$(env LC_ALL=C.UTF-8 bash -c 'source "$1/../scripts/cli/dispatch.sh"; cli_with codex cli_pane_prompt_line "$(cat "$2")"' _ "$HERE" "$F/codex/idle.txt")" \
    "codex prompt line under $loc is the same as under C.UTF-8"
done
# The pin changes only character classification: the caller's collation and messages stay theirs.
assert_eq "$(env -u LC_ALL -u LC_CTYPE LANG=C bash -c 'source "$1/../scripts/cli/dispatch.sh"; echo "${LC_COLLATE:-${LC_ALL:-$LANG}}"' _ "$HERE")" C \
  "collation stays the caller's C"
# An already-UTF-8 caller is left exactly as it was.
assert_eq "$(env -u LC_ALL -u LC_CTYPE LANG=C.UTF-8 bash -c 'source "$1/../scripts/cli/dispatch.sh"; echo "${LC_CTYPE-<unset>}"' _ "$HERE")" "<unset>" \
  "a UTF-8 caller's locale is untouched"

finish

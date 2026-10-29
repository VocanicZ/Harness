#!/usr/bin/env bash
# test_cli_matrix_guard.sh — #305 / PRD #189: no matrix cell is trivially true. A cell whose predicate
# still holds with the adapter's functions stubbed to `:`, or with its fixture gone, proves nothing: it
# must read n/a (the row cannot exist for the CLI) or FAIL, never ok.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
make_env
# res <tsv> <cli> <row> — that cell's result: ok, FAIL or n/a:<reason>.
res(){ awk -F'\t' -v c="$2" -v r="$3" '$1 == c && $2 == r { print $3 }' <<<"$1"; }

# cli_trust / cli_trusted stubbed to `:` for every CLI: trust-pre-accepted is never ok — a CLI with a
# real gate FAILs (its fresh worktree reads as trusted already), a gate-less one is n/a.
cells="$(HARNESS_MATRIX_STUB="trust trusted" bash "$HERE/test_cli_matrix.sh" --tsv 2>/dev/null)"
for cli in claude agy codex copilot opencode hermes openclaw; do
  got="$(res "$cells" "$cli" trust-pre-accepted)"
  assert_ok "stubbed trust: $cli trust-pre-accepted is not ok ($got)" test -n "$got" -a "$got" != ok
done
for cli in claude agy codex copilot; do
  assert_eq "$(res "$cells" "$cli" trust-pre-accepted)" FAIL "stubbed trust: $cli, which has a trust gate, FAILs"
done
assert_eq "$(res "$cells" opencode trust-pre-accepted)" "n/a:$(cat "$HERE/fixtures/cli/opencode/trust.na")" \
  "stubbed trust: opencode, which has no gate, is n/a with its reason"

# A fixture tree with the evidence cut: claude's trust dialog, codex's limit pane, agy's sub-agent
# capture swapped for its no-bypass control. Each cell that leaned on it FAILs; none is skipped.
fix="$RUN_DIR/fixtures"; mkdir -p "$fix"; cp -r "$HERE/fixtures/cli/." "$fix/"
rm "$fix/claude/trust.txt" "$fix/codex/limit.txt"
cp "$fix/agy/permission.txt" "$fix/agy/bypass-subagent.txt"
cells="$(HARNESS_MATRIX_FIX="$fix" HARNESS_MATRIX_CLIS="claude codex agy" bash "$HERE/test_cli_matrix.sh" --tsv 2>/dev/null)"
assert_eq "$(res "$cells" claude trust-dialog-is-not-prompt)" FAIL "no trust.txt, no trust.na: claude trust-dialog-is-not-prompt FAILs"
assert_eq "$(res "$cells" claude supervisor-skips-trust-dialog)" FAIL "no trust.txt, no trust.na: claude supervisor-skips-trust-dialog FAILs"
assert_eq "$(res "$cells" claude supervisor-frozen-session)" ok "…while its idle/limit half still runs"
assert_eq "$(res "$cells" codex supervisor-frozen-session)" FAIL "no limit.txt: codex supervisor-frozen-session FAILs"
assert_eq "$(res "$cells" agy bypass-covers-subagents)" FAIL "agy's sub-agent pane shows the approval prompt: bypass-covers-subagents FAILs"
finish

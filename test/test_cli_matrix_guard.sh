#!/usr/bin/env bash
# harness-test-timeout-windows: 43200
# test_cli_matrix_guard.sh — #305 / PRD #189: no matrix cell is trivially true. A cell whose predicate
# still holds with the adapter's functions stubbed to `:`, or with its fixture gone, proves nothing: it
# must read n/a (the row cannot exist for the CLI) or FAIL, never ok.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
make_env
# res <tsv> <cli> <row> — that cell's result: ok, FAIL or n/a:<reason>.
res(){ awk -F'\t' -v c="$2" -v r="$3" '$1 == c && $2 == r { print $3 }' <<<"$1"; }
# Each matrix run below is fork-heavy (Git Bash forks ~10x slower than Linux: one full matrix is ~100 min on winsma, and this test
# made ten of them, #943), so the runs are started together, each on just the rows its assertions read, and read back once all
# have ended: the same cells and the same assertions, in one wave over the host's cores. None takes a cached cell (env -u
# HARNESS_MATRIX_CACHE, #1024): this test is what proves a cell can fail, test_cli_matrix_cache.sh is what proves a cached one still does. The runs share nothing (each
# test_cli_matrix.sh makes its own RUN_DIR), so none sees another's files.
# mrun <name> <VAR=value…> — test_cli_matrix.sh --tsv under those variables, its cells into $RUN_DIR/<name>.tsv; at most $PAR at a
# time (HARNESS_MATRIX_JOBS, else the host's cores, at most 4). Each run takes its CLIs one after the other (HARNESS_MATRIX_JOBS=1):
# the runs are what is parallel here. tsv <name> — what that run printed, after `wait`.
PAR="${HARNESS_MATRIX_JOBS:-}"; [[ $PAR =~ ^[1-9][0-9]*$ ]] || { PAR="$(nproc 2>/dev/null)"; [[ $PAR =~ ^[1-9][0-9]*$ ]] || PAR=1; (( PAR > 4 )) && PAR=4; }
RUNNING=0
mrun(){ local n="$1"; shift
  (( RUNNING < PAR )) || { wait -n; RUNNING=$((RUNNING - 1)); }
  ( env -u HARNESS_MATRIX_CACHE HARNESS_MATRIX_JOBS=1 "$@" bash "$HERE/test_cli_matrix.sh" --tsv > "$RUN_DIR/$n.tsv" 2>/dev/null ) & RUNNING=$((RUNNING + 1)); }
tsv(){ cat "$RUN_DIR/$1.tsv"; }

CLIS="claude agy codex copilot opencode hermes openclaw"
# A fixture tree with the evidence cut: claude's trust dialog, codex's limit pane, agy's sub-agent
# capture swapped for its no-bypass control. Each cell that leaned on it FAILs; none is skipped.
fix="$RUN_DIR/fixtures"; mkdir -p "$fix"; cp -r "$HERE/fixtures/cli/." "$fix/"
rm "$fix/claude/trust.txt" "$fix/codex/limit.txt"
cp "$fix/agy/permission.txt" "$fix/agy/bypass-subagent.txt"

# The longest runs first. The headless-* rows of a CLI are the slow ones (a real runner process per cell).
# (A tmux-only CLI's headless-* rows read n/a, tmux-only — the headless backend refuses it. Every CLI has a runner since #486, so there is
# none to check here; the refusal itself is test_headless_adapters.sh's, against a made-up CLI.)
# #353 (and #483 for copilot, #486 for agy): claude's headless rows, with the adapter functions they lean on stubbed to `:`. With its
# headless lane runner's command gone (claude_headless) no lane starts, and every headless-* row FAILs;
# with the lane's last reply gone (claude_last_reply) the driven goal loop never ends; with its
# usage-window reader gone (claude_limit_usage) no window is read. The pane rows the stubs leave alone
# stay ok. copilot's, codex's (#481) and agy's are the same three: the runner command (<cli>_headless), the lane's last reply and
# its window reader.
mrun claude-runner HARNESS_MATRIX_STUB=headless HARNESS_MATRIX_CLIS=claude HARNESS_MATRIX_ROWS='^(headless-|launch-bootstrap)'
mrun claude-reply HARNESS_MATRIX_STUB="last_reply limit_usage" HARNESS_MATRIX_CLIS=claude HARNESS_MATRIX_ROWS='^headless-(launch|loop-mode|usage-windows)$'
for c in copilot codex agy; do
  mrun "$c-runner" HARNESS_MATRIX_STUB=headless HARNESS_MATRIX_CLIS=$c HARNESS_MATRIX_ROWS='^(headless-|launch-bootstrap)'
  mrun "$c-reply" HARNESS_MATRIX_STUB="last_reply limit_usage" HARNESS_MATRIX_CLIS=$c HARNESS_MATRIX_ROWS='^headless-(launch|loop-mode|usage-windows)$'
done
# The cut fixtures, for the CLIs whose evidence was cut, and the rows that read it.
mrun cut-claude HARNESS_MATRIX_FIX="$fix" HARNESS_MATRIX_CLIS=claude HARNESS_MATRIX_ROWS='^(trust-dialog-is-not-prompt|supervisor-skips-trust-dialog|supervisor-frozen-session)$'
mrun cut-codex HARNESS_MATRIX_FIX="$fix" HARNESS_MATRIX_CLIS=codex HARNESS_MATRIX_ROWS='^supervisor-frozen-session$'
mrun cut-agy HARNESS_MATRIX_FIX="$fix" HARNESS_MATRIX_CLIS=agy HARNESS_MATRIX_ROWS='^bypass-covers-subagents$'
# cli_trust / cli_trusted stubbed to `:` for every CLI, on the one row it decides (and, for claude, the frozen-session row the stub leaves alone).
for c in $CLIS; do
  rows='^trust-pre-accepted$'; [[ $c == claude ]] && rows='^(trust-pre-accepted|supervisor-frozen-session)$'
  mrun "trust-$c" HARNESS_MATRIX_STUB="trust trusted" HARNESS_MATRIX_CLIS=$c HARNESS_MATRIX_ROWS="$rows"
done
# #943: a run over several CLIs is one child per CLI, up to HARNESS_MATRIX_JOBS at once, and reads as the one-after-the-other run.
# Two cheap rows over three CLIs, both ways: the same cells in the same order, and with 3 jobs all three children start before the
# first one ends (a run of one job starts none).
par_rows='^(idle-|trust-pre-accepted$)'
mrun seq HARNESS_MATRIX_CLIS="agy opencode hermes" HARNESS_MATRIX_ROWS="$par_rows"
( env -u HARNESS_MATRIX_CACHE HARNESS_MATRIX_JOBS=3 HARNESS_MATRIX_TRACE="$RUN_DIR/par.trace" HARNESS_MATRIX_CLIS="agy opencode hermes" HARNESS_MATRIX_ROWS="$par_rows" \
    bash "$HERE/test_cli_matrix.sh" --tsv > "$RUN_DIR/par.tsv" 2>/dev/null ) &
wait

assert_ok "a parallel matrix run has cells" test -s "$RUN_DIR/par.tsv"
assert_eq "$(cat "$RUN_DIR/par.tsv")" "$(tsv seq)" "HARNESS_MATRIX_JOBS=3: the same cells, in the same order, as one CLI after the other"
assert_eq "$(cut -d' ' -f1 "$RUN_DIR/par.trace" | head -3 | tr '\n' ' ')" "start start start " "HARNESS_MATRIX_JOBS=3: all three CLIs' runs start before one ends"
assert_eq "$(grep -c '^end ' "$RUN_DIR/par.trace")" 3 "HARNESS_MATRIX_JOBS=3: all three runs end"

# cli_trust / cli_trusted stubbed to `:` for every CLI: trust-pre-accepted is never ok — a CLI with a
# real gate FAILs (its fresh worktree reads as trusted already), a gate-less one is n/a.
cells="$(for c in $CLIS; do tsv "trust-$c"; done)"
frozen_here="$(res "$cells" claude supervisor-frozen-session)"   # the stub leaves it alone
for cli in claude agy codex copilot opencode hermes openclaw; do
  got="$(res "$cells" "$cli" trust-pre-accepted)"
  assert_ok "stubbed trust: $cli trust-pre-accepted is not ok ($got)" test -n "$got" -a "$got" != ok
done
for cli in claude agy codex copilot; do
  assert_eq "$(res "$cells" "$cli" trust-pre-accepted)" FAIL "stubbed trust: $cli, which has a trust gate, FAILs"
done
assert_eq "$(res "$cells" opencode trust-pre-accepted)" "n/a:$(cat "$HERE/fixtures/cli/opencode/trust.na")" \
  "stubbed trust: opencode, which has no gate, is n/a with its reason"

cells="$(tsv cut-claude; tsv cut-codex; tsv cut-agy)"
assert_eq "$(res "$cells" claude trust-dialog-is-not-prompt)" FAIL "no trust.txt, no trust.na: claude trust-dialog-is-not-prompt FAILs"
assert_eq "$(res "$cells" claude supervisor-skips-trust-dialog)" FAIL "no trust.txt, no trust.na: claude supervisor-skips-trust-dialog FAILs"
# frozen_ok draws real tmux panes; where they cannot be drawn (no tmux, a sandboxed host) every frozen
# cell FAILs on the full fixtures too, and only the cut cells prove anything.
if [[ $frozen_here == ok ]]; then
  assert_eq "$(res "$cells" claude supervisor-frozen-session)" ok "…while its idle/limit half still runs"
fi
assert_eq "$(res "$cells" codex supervisor-frozen-session)" FAIL "no limit.txt: codex supervisor-frozen-session FAILs"
assert_eq "$(res "$cells" agy bypass-covers-subagents)" FAIL "agy's sub-agent pane shows the approval prompt: bypass-covers-subagents FAILs"

# headless-sweep-detached-jobs runs nothing (and reads ok, whatever is stubbed) on a host without setsid or /proc/self/environ,
# which Git Bash has not (#969): there that one row says nothing about the stubs, so it is left out of "every headless-* row FAILs".
headless_rows(){ local skip=""; { command -v setsid >/dev/null && [[ -r /proc/self/environ ]]; } || skip=headless-sweep-detached-jobs
  awk -F'\t' -v c="${2:-claude}" -v skip="$skip" '$1 == c && $2 ~ /^headless-/ && $2 != skip { print $2 "\t" $3 }' <<<"$1"; }
cells="$(tsv claude-runner)"
assert_ok "stubbed runner: claude has headless-* rows" test -n "$(headless_rows "$cells")"
assert_eq "$(headless_rows "$cells" | cut -f2 | sort -u)" FAIL "stubbed runner: every claude headless-* row FAILs"
assert_eq "$(res "$cells" claude launch-bootstrap-prompt)" ok "…while its pane rows still pass"
cells="$(tsv claude-reply)"
assert_eq "$(res "$cells" claude headless-loop-mode)" FAIL "stubbed last reply: claude headless-loop-mode FAILs"
assert_eq "$(res "$cells" claude headless-usage-windows)" FAIL "stubbed usage windows: claude headless-usage-windows FAILs"
assert_eq "$(res "$cells" claude headless-launch)" ok "…while headless-launch, which reads neither, still passes"
for c in copilot codex agy; do
  cells="$(tsv "$c-runner")"
  assert_ok "stubbed runner: $c has headless-* rows" test -n "$(headless_rows "$cells" $c)"
  assert_eq "$(headless_rows "$cells" $c | cut -f2 | sort -u)" FAIL "stubbed runner: every $c headless-* row FAILs"
  cells="$(tsv "$c-reply")"
  assert_eq "$(res "$cells" $c headless-loop-mode)" FAIL "stubbed last reply: $c headless-loop-mode FAILs"
  assert_eq "$(res "$cells" $c headless-usage-windows)" FAIL "stubbed usage windows: $c headless-usage-windows FAILs"
  assert_eq "$(res "$cells" $c headless-launch)" ok "…while headless-launch, which reads neither, still passes"
done
finish

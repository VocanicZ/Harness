#!/usr/bin/env bash
# test_cli_matrix_cache.sh — #1024 / PRD #475: the matrix cells one suite run computes are shared. On a Windows host one CLI's cells take
# over 25 minutes, and eight files want them (the five adapter tests, test_cli_matrix.sh, test_cli_readme.sh, the guard's reruns), so
# HARNESS_MATRIX_CACHE keeps a finished CLI's cells for the rest of the run and run.sh computes them once. Sharing must not make a cell
# easier to pass: a red cell is red in the cache, in the TSV a later reader takes, and in an assertion run, which runs it live.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
make_env
M="$HERE/test_cli_matrix.sh"
res(){ awk -F'\t' -v c="$2" -v r="$3" '$1 == c && $2 == r { print $3 }' <<<"$1"; }
# A fixture tree for claude whose trust dialog evidence is cut: trust-dialog-is-not-prompt is a cell that can only FAIL.
mkfix(){ rm -rf "$1"; mkdir -p "$1"; cp -r "$HERE/fixtures/cli/." "$1/"; }
fix="$RUN_DIR/fix"; mkfix "$fix"; mv "$fix/claude/trust.txt" "$RUN_DIR/trust.txt"; rm -f "$fix/claude/trust.na"
rows='^(idle-is-prompt|idle-is-not-busy|trust-dialog-is-not-prompt)$'
# mx [VAR=value…] — the matrix over claude's rows, assertion mode; mxt — the same with --tsv. No cache unless HARNESS_MATRIX_CACHE is given.
mx(){ env -u HARNESS_MATRIX_CACHE HARNESS_MATRIX_JOBS=1 HARNESS_MATRIX_CLIS=claude HARNESS_MATRIX_ROWS="$rows" HARNESS_MATRIX_FIX="$fix" "$@" bash "$M" 2>/dev/null; }
mxt(){ env -u HARNESS_MATRIX_CACHE HARNESS_MATRIX_JOBS=1 HARNESS_MATRIX_CLIS=claude HARNESS_MATRIX_ROWS="$rows" HARNESS_MATRIX_FIX="$fix" "$@" bash "$M" --tsv 2>/dev/null; }

echo "== --tsv: a cell computed once is taken from the cache, red included =="
C1="$RUN_DIR/cache1"
live="$(mxt HARNESS_MATRIX_CACHE="$C1")"
assert_eq "$(res "$live" claude trust-dialog-is-not-prompt)" FAIL "first run: the cut trust evidence is a FAIL cell"
assert_eq "$(res "$live" claude idle-is-prompt)" ok "…and an intact cell is ok"
assert_eq "$(ls "$C1" | wc -l | tr -d ' ')" 1 "the finished CLI left one cache entry"
# The evidence is restored AFTER the first run: only a cache keeps the cell red.
cp "$RUN_DIR/trust.txt" "$fix/claude/trust.txt"
shared="$(mxt HARNESS_MATRIX_CACHE="$C1")"
assert_eq "$shared" "$live" "second run: the same cells, from the cache (the restored evidence is not re-read)"
assert_eq "$(res "$shared" claude trust-dialog-is-not-prompt)" FAIL "a shared red cell is still reported FAIL"
fresh="$(mxt)"
assert_eq "$(res "$fresh" claude trust-dialog-is-not-prompt)" ok "no HARNESS_MATRIX_CACHE: every run is live (the restored evidence makes it ok)"
rm "$fix/claude/trust.txt"

echo "== another question is another entry =="
other="$(mxt HARNESS_MATRIX_CACHE="$C1" HARNESS_MATRIX_ROWS='^idle-is-prompt$')"
assert_eq "$other" "$(printf 'claude\tidle-is-prompt\tok')" "other rows: not answered from the entry of the first rows"
assert_eq "$(ls "$C1" | wc -l | tr -d ' ')" 2 "…it made an entry of its own"

echo "== an assertion run =="
C2="$RUN_DIR/cache2"
red1="$(mx HARNESS_MATRIX_CACHE="$C2")"; rc1=$?
assert_ok "a red cell fails an assertion run" test "$rc1" -ne 0
assert_ok "…naming the cell" grep -qF "FAIL: claude: trust-dialog-is-not-prompt" <<<"$red1"
red2="$(mx HARNESS_MATRIX_CACHE="$C2")"; rc2=$?
assert_ok "a CLI with a red cell is not replayed: the second assertion run still fails" test "$rc2" -ne 0
assert_ok "…naming the same cell, from a live run" grep -qF "FAIL: claude: trust-dialog-is-not-prompt" <<<"$red2"
# The red tsv entry (above, C1) feeds an assertion run no ok either.
cp -r "$C1" "$RUN_DIR/cache3"
red3="$(mx HARNESS_MATRIX_CACHE="$RUN_DIR/cache3")"; rc3=$?
assert_ok "an assertion run over a cache entry with a red cell fails too" test "$rc3" -ne 0

echo "== a green CLI is replayed =="
cp "$RUN_DIR/trust.txt" "$fix/claude/trust.txt"
C4="$RUN_DIR/cache4"
g1="$(mx HARNESS_MATRIX_CACHE="$C4")"; grc1=$?
assert_eq "$grc1" 0 "all cells ok: the assertion run passes"
assert_ok "…with its ok lines" grep -qF "ok: claude: trust-dialog-is-not-prompt" <<<"$g1"
assert_ok "…and its count" grep -q "^── 3/3 passed" <<<"$g1"
: > "$fix/claude/idle.txt"   # an idle pane that is no prompt: a live run FAILs idle-is-prompt
g2="$(mx HARNESS_MATRIX_CACHE="$C4")"; grc2=$?
assert_eq "$grc2" 0 "second run: replayed, so the emptied idle pane is not re-read"
assert_eq "$g2" "$g1" "…the same lines, the same count"
g3="$(mxt)"
assert_eq "$(res "$g3" claude idle-is-prompt)" FAIL "(and a live run does read it: FAIL)"

echo "== CLIs run in parallel children share the entries too =="
cp "$RUN_DIR/trust.txt" "$fix/claude/trust.txt"; mkfix "$fix"
C5="$RUN_DIR/cache5"
p1="$(mxt HARNESS_MATRIX_CACHE="$C5" HARNESS_MATRIX_JOBS=2 HARNESS_MATRIX_CLIS="agy opencode" HARNESS_MATRIX_ROWS='^idle-is-prompt$')"
assert_eq "$(grep -c . <<<"$p1")" 2 "two CLIs, two parallel children: two cells"
assert_eq "$(ls "$C5" | wc -l | tr -d ' ')" 2 "…one entry per CLI"
: > "$fix/agy/idle.txt"; : > "$fix/opencode/idle.txt"
p2="$(mxt HARNESS_MATRIX_CACHE="$C5" HARNESS_MATRIX_JOBS=2 HARNESS_MATRIX_CLIS="agy opencode" HARNESS_MATRIX_ROWS='^idle-is-prompt$')"
assert_eq "$p2" "$p1" "a second parallel run reads the entries (the emptied idle panes are not re-read)"
assert_eq "$(ls "$C5" | wc -l | tr -d ' ')" 2 "…and adds none"

echo "== run.sh computes the cells once =="
RT="$RUN_DIR/rt"; mkdir -p "$RT/test"; cp "$HERE/run.sh" "$HERE/helpers.sh" "$RT/test/"; cp -r "$HERE/guard" "$RT/test/guard"
cat > "$RT/test/test_cli_matrix.sh" <<'STUB'
#!/usr/bin/env bash
echo "prefetch args=$* clis=${HARNESS_MATRIX_CLIS:-all} cache=${HARNESS_MATRIX_CACHE:+set}" >> "$PROBE"
STUB
for c in codex hermes; do
  printf '#!/usr/bin/env bash\necho "%s cache=${HARNESS_MATRIX_CACHE:+set}" >> "$PROBE"\n# col="$(HARNESS_MATRIX_CLIS=%s bash "$HERE/test_cli_matrix.sh" --tsv | awk)"\n' "$c" "$c" > "$RT/test/test_cli_$c.sh"
done
printf '#!/usr/bin/env bash\necho "readme" >> "$PROBE"\n' > "$RT/test/test_cli_readme.sh"
probe_run(){ : > "$RUN_DIR/probe"; (cd "$RT/test" && PROBE="$RUN_DIR/probe" HERE=. env -u HARNESS_MATRIX_CACHE bash run.sh "$@" >/dev/null 2>&1); cat "$RUN_DIR/probe"; }
got="$(probe_run test_cli_codex.sh test_cli_hermes.sh)"
assert_eq "$(grep -c '^prefetch' <<<"$got")" 1 "two CLIs' files: one prefetch…"
assert_ok "…of exactly those two CLIs, before their files, with the cache set" grep -qxF "prefetch args=--tsv clis=codex hermes cache=set" <<<"$got"
assert_eq "$(head -1 <<<"$got" | cut -d' ' -f1)" prefetch "…the prefetch comes first"
assert_ok "each file sees the cache" grep -qxF "hermes cache=set" <<<"$got"
got="$(probe_run test_cli_codex.sh)"
assert_eq "$(grep -c '^prefetch' <<<"$got")" 0 "one CLI's file alone: no prefetch (it computes its own cells)"
assert_ok "…and it still sees the cache" grep -qxF "codex cache=set" <<<"$got"
got="$(probe_run test_cli_readme.sh test_cli_codex.sh)"
assert_ok "the README test reads every CLI: a prefetch of all" grep -qxF "prefetch args=--tsv clis=all cache=set" <<<"$got"
finish

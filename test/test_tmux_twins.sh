#!/usr/bin/env bash
# rtdd: always
# test_tmux_twins.sh — #493 / PRD #475 task 6 (Solution 6): every test that needs a real tmux has a headless twin.
#
# Windows has no tmux, so a test that draws tmux panes either has a twin on the headless session backend that asserts the
# same behaviour and runs there, or skips through windows_skip on a matrix row that is n/a on Windows (none but swarm
# submission is). This is the grep check that lists what is left over:
#   - test/helpers.sh `tmux_needing_tests` finds the shell tests that start a tmux pane or gate on the binary;
#   - test/tmux_twins.tsv names the twin of each;
#   - here: a tmux test with no line, a stale line, and a twin that is missing, needs tmux itself, skips instead of
#     asserting, or is not on the headless backend are all failures. Every case also runs on a fixture, so the check can fail.
# The frozen-pane cells of test_cli_matrix.sh have their twin in the same file: with no tmux on the host they run the
# CLI's headless supervisor cell (checked at the bottom, on a PATH without tmux).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
REG="$HERE/tmux_twins.tsv"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# twin_problems <test dir> <registry> — one line per problem, nothing when every tmux test has a real twin.
twin_problems(){ local dir="$1" reg="$2" need t twin line n=0 tw rowf
  need="$(tmux_needing_tests "$dir")"
  declare -A seen=() ; local -a lines=()
  while IFS= read -r line || [[ -n $line ]]; do [[ -z $line || $line == \#* ]] && continue
    t="${line%%$'\t'*}"; twin="${line#*$'\t'}"
    if [[ $line != *$'\t'* || -z $twin || $twin == *$'\t'* || ( $twin == *" "* && $twin != na:* ) ]]; then echo "line is not '<test><TAB><twin>': ${line:0:60}"; continue; fi
    [[ -n ${seen[$t]:-} ]] && echo "$t: listed twice"; seen[$t]=1
    grep -qxF "$t" <<<"$need" || echo "$t: listed, but it no longer needs tmux (drop its line)"
    case "$twin" in
      self:*) rowf="${twin#self:}"
              grep -qF "headless_rows" "$dir/$t" && grep -qE "cell \"\\\$cli\" $rowf( |\$)" "$dir/$t" \
                || echo "$t: its self twin '$rowf' is not a headless cell of that file";;
      na:*)   rowf="${twin#na:}"
              case "$(windows_row_value "$rowf" 2>/dev/null)" in n/a*) ;; *) echo "$t: row '$rowf' is not n/a on Windows, so it cannot be skipped there";; esac
              grep -qF "windows_skip" "$dir/$t" && grep -qF "$rowf" "$dir/$t" || echo "$t: it does not skip through windows_skip on row '$rowf'";;
      *)      if [[ ! $twin =~ ^test_[A-Za-z0-9_]+\.sh$ || ! -f "$dir/$twin" ]]; then echo "$t: twin $twin is no test file in the test directory"; continue; fi
              grep -qxF "$twin" <<<"$need" && echo "$t: twin $twin needs tmux itself"
              grep -qE 'windows_skip|command -v tmux.*(skip|exit 0)' "$dir/$twin" && echo "$t: twin $twin skips instead of asserting"
              grep -qE 'HARNESS_SESSION_BACKEND=headless|HARNESS_SESSION_BACKEND:=headless|hl_env' "$dir/$twin" \
                || echo "$t: twin $twin does not run on the headless backend";;
    esac
  done < "$reg"
  while IFS= read -r t; do [[ -z $t ]] && continue
    [[ -n ${seen[$t]:-} ]] || echo "$t: needs tmux and has no headless twin (add a line to test/tmux_twins.tsv)"; done <<<"$need"; }

echo "== the repository: no tmux test is left without a headless twin =="
got="$(twin_problems "$HERE" "$REG")"
assert_eq "$got" "" "every test that needs tmux has a headless twin"
[[ -n $got ]] && sed 's/^/    /' <<<"$got"
n="$(tmux_needing_tests "$HERE" | wc -l | tr -d ' ')"
assert_ok "…and the detector finds the tests (a handful, not none: $n)" test "$n" -ge 9

echo "== the detector counts a pane start and a gate on the binary, not a string that names them =="
D="$T/det"; mkdir -p "$D"
printf 'tmux new-session -d -s x "sleep 9"\n'                                   > "$D/test_a_new.sh"
printf 'env -u STATE_DIR tmux -L sock new-session -d -s x\n'                    > "$D/test_b_env.sh"
printf 'command -v tmux >/dev/null || { echo skip; exit 0; }\n'                 > "$D/test_c_gate.sh"
printf 'if command -v tmux >/dev/null 2>&1; then :; fi\n'                       > "$D/test_d_if.sh"
tm=tmux   # spelled apart: this file's own lines must not read as a tmux test to the detector it tests
printf 'mk(){ %s kill-session -t x; %s new-session -d -s "$1" "$2"; }\n' $tm $tm > "$D/test_e_fn.sh"
printf 'assert_ok "tmux new-session sets -e" grep -q x y\n'                     > "$D/test_s1_msg.sh"
printf "printf 'command -v tmux >/dev/null || die\\\\n' > f\\n"                   > "$D/test_s2_printf.sh"
printf '# tmux new-session in a comment\n  # command -v tmux\n'                  > "$D/test_s3_comment.sh"
printf 'tmux(){ case "$1" in new-session) :;; esac; }\ntmux has-session -t x\n' > "$D/test_s4_stub.sh"
assert_eq "$(tmux_needing_tests "$D" | tr '\n' ' ')" "test_a_new.sh test_b_env.sh test_c_gate.sh test_d_if.sh test_e_fn.sh " \
  "five shapes of a tmux test are found; a message, a printf, a comment and a stub are not"

echo "== the check fails on every way a twin can be missing =="
F="$T/fx"; mkdir -p "$F"
printf 'tmux new-session -d -s x "sleep 9"\n'                                    > "$F/test_real.sh"
printf 'tmux new-session -d -s y "sleep 9"\n'                                    > "$F/test_real2.sh"
printf 'export HARNESS_SESSION_BACKEND=headless\necho ok\n'                      > "$F/test_real_headless.sh"
printf 'export HARNESS_SESSION_BACKEND=headless\ncommand -v tmux >/dev/null || exit 0\n' > "$F/test_twin_needs_tmux.sh"
printf 'export HARNESS_SESSION_BACKEND=headless\nwindows_skip "swarm submission" x\n'  > "$F/test_twin_skips.sh"
printf 'echo no backend named\n'                                                 > "$F/test_twin_tmuxbackend.sh"
printf 'echo plain\n'                                                            > "$F/test_plain.sh"
# (test_twin_needs_tmux.sh is a tmux test itself, on purpose: it carries a valid twin line in every registry below)
reg(){ { printf '%b' "$1"; printf 'test_twin_needs_tmux.sh\ttest_real_headless.sh\n'; } > "$T/reg.tsv"; twin_problems "$F" "$T/reg.tsv"; }
assert_eq "$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\ttest_real_headless.sh\n')" "" "a registry with a real twin for each: clean"
out="$(reg 'test_real.sh\ttest_real_headless.sh\n')"
assert_ok "a tmux test with no line is listed" grep -qF "test_real2.sh: needs tmux and has no headless twin" <<<"$out"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\ttest_real_headless.sh\ntest_plain.sh\ttest_real_headless.sh\n')"
assert_ok "a line for a test that no longer needs tmux is stale" grep -qF "test_plain.sh: listed, but it no longer needs tmux" <<<"$out"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\ttest_missing.sh\n')"
assert_ok "a twin that is not a file is refused" grep -qF "test_real2.sh: twin test_missing.sh is no test file" <<<"$out"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\ttest_real.sh\n')"
assert_ok "a twin that needs tmux itself is refused" grep -qF "test_real2.sh: twin test_real.sh needs tmux itself" <<<"$out"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\ttest_twin_needs_tmux.sh\n')"
assert_ok "…also when it only gates on the binary" grep -qF "twin test_twin_needs_tmux.sh needs tmux itself" <<<"$out"
assert_ok "…and then it skips instead of asserting" grep -qF "twin test_twin_needs_tmux.sh skips instead of asserting" <<<"$out"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\ttest_twin_skips.sh\n')"
assert_ok "a twin that skips through windows_skip is a skip, not a twin" grep -qF "twin test_twin_skips.sh skips instead of asserting" <<<"$out"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\ttest_twin_tmuxbackend.sh\n')"
assert_ok "a twin not on the headless backend is refused" grep -qF "twin test_twin_tmuxbackend.sh does not run on the headless backend" <<<"$out"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real.sh\ttest_real_headless.sh\ntest_real2.sh\ttest_real_headless.sh\n')"
assert_ok "a test listed twice is refused" grep -qF "test_real.sh: listed twice" <<<"$out"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2\n')"
assert_ok "a line with no twin column is refused" grep -qF "line is not '<test><TAB><twin>'" <<<"$out"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\tna:swarm submission\n')"
assert_ok "an n/a skip needs a test that calls windows_skip" grep -qF "test_real2.sh: it does not skip through windows_skip on row 'swarm submission'" <<<"$out"
printf 'tmux new-session -d -s y\nwindows_skip_file "swarm submission" "x"\n' > "$F/test_real2.sh"
assert_eq "$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\tna:swarm submission\n')" "" "an n/a skip on the real swarm submission row, through windows_skip, is a valid twin"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\tna:harness stop\n')"
assert_ok "a skip on a row that is ✓ on Windows is refused" grep -qF "row 'harness stop' is not n/a on Windows" <<<"$out"
printf 'cell "$cli" headless-foo foo_ok\nheadless_rows(){ :; }\ntmux new-session -d -s z\n' > "$F/test_real2.sh"
assert_eq "$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\tself:headless-foo\n')" "" "a self twin that is a headless cell of the same file is valid"
out="$(reg 'test_real.sh\ttest_real_headless.sh\ntest_real2.sh\tself:headless-bar\n')"
assert_ok "…and one that is not a cell is refused" grep -qF "its self twin 'headless-bar' is not a headless cell of that file" <<<"$out"

echo "== the matrix: its tmux cells are their headless twin on a host with no tmux =="
assert_ok "frozen_ok falls back to the headless supervisor cell without tmux" \
  bash -c "sed -n '/^frozen_ok()/,/^  local cli=/p' '$HERE/test_cli_matrix.sh' | grep -q '! command -v tmux' && sed -n '/^frozen_ok()/,/^  local cli=/p' '$HERE/test_cli_matrix.sh' | grep -q headless_supervisor_ok"
# Run the cells on a PATH without tmux (where the host has one): the shadow dir holds a link to every other executable.
NT="$T/notmux"; mkdir -p "$NT"
if [[ -n "$(type -P tmux)" ]]; then
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do [[ -d $d ]] || continue; for f in "$d"/*; do b="${f##*/}"; [[ $b == tmux || -e $NT/$b ]] || ln -s "$f" "$NT/$b" 2>/dev/null; done; done
  mpath="$NT"
else mpath="$PATH"; fi
out="$(PATH="$mpath" HARNESS_MATRIX_CLIS=claude HARNESS_MATRIX_ROWS='^supervisor-' bash "$HERE/test_cli_matrix.sh" 2>&1)"
assert_eq "$(PATH="$mpath" type -P tmux)" "" "no tmux on PATH for the run"
assert_ok "claude: supervisor-frozen-session passes on its headless twin" grep -qF "ok: claude: supervisor-frozen-session" <<<"$out"
assert_ok "claude: supervisor-skips-trust-dialog passes on its headless twin" grep -qF "ok: claude: supervisor-skips-trust-dialog" <<<"$out"
assert_no "…and nothing failed" grep -q "FAIL" <<<"$out"

finish

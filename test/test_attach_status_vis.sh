#!/usr/bin/env bash
# test_attach_status_vis.sh — #1124 / PRD #475: `harness attach` and `harness status` print a config value (HARNESS_PREFIX)
# and the session names built from it escaped, as the other message paths do (#952, #1003): a form feed or any C0/C1 control
# character, DEL, U+2028 and U+2029 become \uXXXX (a newline \n, a tab \t) — never raw on the terminal, never a split line.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
export RUN_DIR HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude HARNESS_REPO=acme/widget

LSEP=$'\xe2\x80\xa8'; PSEP=$'\xe2\x80\xa9'   # byte-spelled: $'\u2028' is locale-dependent
NEL=$'\xc2\x85'
echo "== vis: the escape table =="
assert_eq "$(vis $'p\fz')"           'p\u000cz'  "form feed -> \\u000c"
assert_eq "$(vis $'a\nb')"           'a\nb'      "newline -> \\n"
assert_eq "$(vis $'a\tb')"           'a\tb'      "tab -> \\t"
assert_eq "$(vis $'a\x1bb')"         'a\u001bb'  "ESC -> \\u001b"
assert_eq "$(vis $'a\x7fb')"         'a\u007fb'  "DEL -> \\u007f"
assert_eq "$(vis "a${LSEP}b")"       'a\u2028b'  "U+2028 -> \\u2028"
assert_eq "$(vis "a${PSEP}b")"       'a\u2029b'  "U+2029 -> \\u2029"
assert_eq "$(vis "a${NEL}b")"       'a\u0085b'  "C1 NEL -> \\u0085"
assert_eq "$(vis 'héllo — ok')"      'héllo — ok' "ordinary UTF-8 passes through"

has_raw(){ LC_ALL=C grep -qP '[\x00-\x09\x0b-\x1f\x7f]|\xe2\x80[\xa8\xa9]' <<<"$1"; }   # any control byte but the newline between lines

echo "== attach: the 'no live session' error escapes the prefix =="
for pfx in $'p\fz' "p${LSEP}z"; do
  want='p\u000cz'; [[ "$pfx" == *"$LSEP"* ]] && want='p\u2028z'
  err="$(HARNESS_SESS_PREFIX="$pfx" bash "$ROOT/scripts/attach.sh" xx 2>&1 >/dev/null </dev/null)"; rc=$?
  assert_eq "$rc" 1 "attach exits 1 ($want)"
  assert_eq "$err" "no live session '$want-xx-p0'" "…names the session escaped ($want)"
  assert_no "…and prints no raw control character ($want)" has_raw "$err"
done

echo "== status: the prefix line escapes the prefix =="
out="$(HARNESS_SESS_PREFIX=$'p\fz' bash "$ROOT/scripts/status.sh" 2>&1 </dev/null || true)"
assert_ok "status prints the escaped prefix" grep -qxF 'prefix: p\u000cz' <<<"$out"
assert_no "…and no raw control character anywhere" has_raw "$out"
out="$(HARNESS_SESS_PREFIX="p${LSEP}z" bash "$ROOT/scripts/status.sh" 2>&1 </dev/null || true)"
assert_ok "status prints U+2028 escaped" grep -qxF 'prefix: p\u2028z' <<<"$out"
assert_no "…and no raw U+2028 anywhere" has_raw "$out"
finish

#!/usr/bin/env bash
# test_tmux_fallback_guard.sh — #649: a lane's test run killed the host's shared default tmux server (three outages, 2026-11-07).
# tmux 3.5a does not fail when $TMUX_TMPDIR names a MISSING directory: it uses /tmp/tmux-$UID/ — the host's default server.
# A test that wipes the private home pin_host_home gave it (`rm -rf "$H"` where TMUX_TMPDIR=$H/tmux) then ran `tmux kill-server`
# at the host's server and still passed. The suite's answer is a fail-closed `tmux` guard (test/guard/tmux) first on PATH.
#   1. the guard refuses — exit 97, loud stderr, real tmux never exec'd — when TMUX_TMPDIR is deleted, unset, empty, a file or /tmp,
#      or TMUX names a socket outside it; it execs the next tmux on PATH when TMUX_TMPDIR is a live private dir (and for -S)
#   2. pin_host_home puts the guard first on PATH
#   3. the planted test (pin_host_home; rm -rf the home; tmux kill-server) FAILS under run.sh and never reaches tmux
#   4. a tmux shell function stub still works (a function is not looked up on PATH)
# The "real" tmux here is a fake on PATH that records that it ran: this test never touches a real tmux server.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
ROOT="$(mktemp -d)"; tmp_track "$ROOT"
GUARD="$HERE/guard"
FAKE="$ROOT/fakebin"; mkdir -p "$FAKE"
printf '#!/usr/bin/env bash\necho "REAL tmux $*" >> "%s/real.log"\nexit 0\n' "$ROOT" > "$FAKE/tmux"; chmod +x "$FAKE/tmux"
: > "$ROOT/real.log"
G=(env -u TMUX -u TMUX_PANE PATH="$GUARD:$FAKE:$PATH")   # the suite's PATH: guard first, a fake "real" tmux behind it

# guarded <TMUX_TMPDIR | UNSET> args… — run the guard with that TMUX_TMPDIR; prints "rc|stderr"
guarded(){ local d="$1" rc err; shift
  if [[ $d == UNSET ]]; then err="$(env -u TMUX -u TMUX_PANE -u TMUX_TMPDIR PATH="$GUARD:$FAKE:$PATH" tmux "$@" 2>&1 >/dev/null)"; rc=$?
  else err="$("${G[@]}" TMUX_TMPDIR="$d" tmux "$@" 2>&1 >/dev/null)"; rc=$?; fi
  printf '%s|%s' "$rc" "$err"; }
real_calls(){ wc -l < "$ROOT/real.log" | tr -d ' '; }

echo "=== 1. the guard fails closed ==="
LIVE="$ROOT/live"; mkdir -p "$LIVE"
: > "$ROOT/real.log"; out="$(guarded "$LIVE" ls -F '#S')"
assert_eq "${out%%|*}" "0" "a live private TMUX_TMPDIR: the call goes through"
assert_eq "$(cat "$ROOT/real.log")" "REAL tmux ls -F #S" "...to the next tmux on PATH, args intact"
GONE="$ROOT/gone"; mkdir -p "$GONE"; rm -rf "$GONE"
for c in "ls" "kill-server" "new-session -d -s x sleep 60" "has-session -t x"; do
  : > "$ROOT/real.log"; out="$(guarded "$GONE" $c)"
  assert_eq "${out%%|*}" "97" "a DELETED TMUX_TMPDIR refuses 'tmux $c'"
  assert_eq "$(real_calls)" "0" "...and the real tmux was never exec'd"
done
case "$out" in *REFUSED*"$GONE"*) echo "  ok: the refusal is loud and names the missing dir"; TESTS_RUN=$((TESTS_RUN+1));; *) echo "  FAIL: refusal text: $out"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1));; esac
: > "$ROOT/real.log"; out="$(guarded UNSET kill-server)";  assert_eq "${out%%|*}" "97" "an UNSET TMUX_TMPDIR refuses"
out="$(guarded "" kill-server)";                           assert_eq "${out%%|*}" "97" "an EMPTY TMUX_TMPDIR refuses"
out="$(guarded /tmp kill-server)";                         assert_eq "${out%%|*}" "97" "TMUX_TMPDIR=/tmp refuses"
ln -s /tmp "$ROOT/tmplink"
out="$(guarded "$ROOT/tmplink" kill-server)";              assert_eq "${out%%|*}" "97" "a symlink to /tmp refuses"
: > "$ROOT/file"; out="$(guarded "$ROOT/file" kill-server)"; assert_eq "${out%%|*}" "97" "a TMUX_TMPDIR that is a file refuses"
assert_eq "$(real_calls)" "0" "none of those reached the real tmux"
# a TMUX socket outside the private dir (a lane's own) — tmux would use it before TMUX_TMPDIR
out="$(env -u TMUX_PANE PATH="$GUARD:$FAKE:$PATH" TMUX_TMPDIR="$LIVE" TMUX=/tmp/tmux-1000/default,1,0 tmux ls 2>&1 >/dev/null; echo "rc=$?")"
case "$out" in *rc=97*) echo "  ok: a TMUX socket outside TMUX_TMPDIR refuses"; TESTS_RUN=$((TESTS_RUN+1));; *) echo "  FAIL: TMUX outside: $out"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1));; esac
env -u TMUX_PANE PATH="$GUARD:$FAKE:$PATH" TMUX_TMPDIR="$LIVE" TMUX="$LIVE/tmux-1000/default,1,0" tmux ls >/dev/null 2>&1
assert_eq "$?" "0" "a TMUX socket inside TMUX_TMPDIR passes"
: > "$ROOT/real.log"; "${G[@]}" TMUX_TMPDIR="$GONE" tmux -S "$ROOT/own.sock" ls >/dev/null 2>&1
assert_eq "$?" "0" "an explicit -S socket is the caller's own choice and passes"

echo "=== 2. pin_host_home puts the guard first on PATH ==="
: > "$ROOT/real.log"
( PATH="$FAKE:$PATH"; pin_host_home "$ROOT/h1"
  [[ "${PATH%%:*}" == "$GUARD" ]] && echo first || echo "not-first:${PATH%%:*}"
  pin_host_home "$ROOT/h2"; n="$(tr ':' '\n' <<<"$PATH" | grep -cxF "$GUARD")"; echo "count=$n"
  rm -rf "$ROOT/h2"; tmux kill-server >/dev/null 2>&1; echo "rc=$?" ) > "$ROOT/pin.out" 2>&1
assert_eq "$(sed -n 1p "$ROOT/pin.out")" "first" "pin_host_home: the guard dir leads PATH"
assert_eq "$(sed -n 2p "$ROOT/pin.out")" "count=1" "...once, however often it is called"
assert_eq "$(sed -n 3p "$ROOT/pin.out")" "rc=97" "...so a bare tmux after the home is wiped is refused"
assert_eq "$(real_calls)" "0" "...and the real tmux was never exec'd"

echo "=== 3. the planted test fails under run.sh ==="
RT="$ROOT/suite"; mkdir -p "$RT"; cp "$HERE/run.sh" "$HERE/helpers.sh" "$RT/"; cp -r "$GUARD" "$RT/guard"
cat > "$RT/test_planted.sh" <<'PLANT'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
T="$(mktemp -d)"; pin_host_home "$T/host"
rm -rf "$T/host"          # the offender's fresh_host: wipes the home that holds TMUX_TMPDIR…
tmux kill-server          # …then talks to "the host's default server"
PLANT
printf '#!/usr/bin/env bash\nexit 0\n' > "$RT/test_clean.sh"
: > "$ROOT/real.log"
out="$(cd "$RT" && env -u TMUX -u STATE_DIR PATH="$FAKE:$PATH" bash run.sh test_planted.sh 2>&1)"; rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo red || echo green)" "red" "run.sh goes red on the planted test"
case "$out" in *"REFUSED 'tmux kill-server' in test_planted.sh"*) echo "  ok: the refusal names the test"; TESTS_RUN=$((TESTS_RUN+1));; *) echo "  FAIL: no refusal naming the test: $out"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1));; esac
assert_eq "$(real_calls)" "0" "the real tmux was never exec'd by the planted test"
out="$(cd "$RT" && env -u TMUX -u STATE_DIR PATH="$FAKE:$PATH" bash run.sh test_clean.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "run.sh stays green on a test that makes no tmux call"

echo "=== 4. a tmux function stub still works ==="
( tmux(){ echo "stub $*"; }; PATH="$FAKE:$PATH"; pin_host_home "$ROOT/h3"; rm -rf "$ROOT/h3"; tmux kill-server ) > "$ROOT/stub.out" 2>&1
assert_eq "$(cat "$ROOT/stub.out")" "stub kill-server" "a shell-function tmux is not looked up on PATH"

finish

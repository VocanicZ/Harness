#!/usr/bin/env bash
# test_signal_defaults.sh — #553: a suite started with SIGINT/SIGHUP/SIGQUIT ignored (a background or nohup
# job: the auto-release gate) must behave like a foreground run. test_headless_attach.sh hung forever there:
# bash cannot trap a signal inherited ignored, so the attach's `trap … INT` did nothing and the unbounded
# `wait` on it never returned. Guards: the default_signals_prefix helper, run.sh handing each test the
# default dispositions, and the attach test finishing — passing, or failing bounded — under ignored signals.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
T="$(mktemp -d)"; tmp_track "$T"
IGN=(env --ignore-signal=INT,HUP,QUIT)
if ! "${IGN[@]}" true 2>/dev/null; then echo "  SKIP: env --ignore-signal unavailable"; finish; exit; fi

# SigIgn mask of a process, as a hex string (Linux); empty where /proc is not there.
sigign_probe='[[ -r /proc/self/status ]] && awk "/^SigIgn:/{print \$2}" /proc/self/status'

echo "== helper: DEFSIG restores INT, HUP, QUIT in what it starts =="
if [[ -r /proc/self/status ]]; then
  masked="$("${IGN[@]}" bash -c "$sigign_probe")"
  assert_eq "$(( 16#$masked & 7 ))" 7 "(precondition) the probe shell starts with HUP, INT and QUIT ignored"
  got="$("${IGN[@]}" bash -c "source '$HERE/helpers.sh'; default_signals_prefix; \"\${DEFSIG[@]}\" bash -c '$sigign_probe'")"
  assert_eq "$(( 16#$got & 7 ))" 0 "a child through DEFSIG has HUP, INT and QUIT at default"
fi
# #574: SIGPIPE (signal 13 = bit 0x1000) too — ignored, a closed pipe is an EPIPE "write error" on stderr, not a quiet death.
if [[ -r /proc/self/status ]]; then
  IGNP=(env --ignore-signal=PIPE)
  masked="$("${IGNP[@]}" bash -c "$sigign_probe")"
  assert_eq "$(( 16#$masked & 16#1000 ))" 4096 "(precondition) the probe shell starts with SIGPIPE ignored"
  got="$("${IGNP[@]}" bash -c "source '$HERE/helpers.sh'; default_signals_prefix; \"\${DEFSIG[@]}\" bash -c '$sigign_probe'")"
  assert_eq "$(( 16#$got & 16#1000 ))" 0 "a child through DEFSIG has SIGPIPE at default"
fi
assert_ok "SIGINT is restorable for a child of an INT-ignoring shell here" "${IGN[@]}" bash -c "source '$HERE/helpers.sh'; sigint_restorable"

echo "== run.sh: each test starts with the default dispositions =="
mkdir -p "$T/suite"; cp "$HERE/run.sh" "$HERE/helpers.sh" "$T/suite/"; cp -r "$HERE/guard" "$T/suite/guard"
cat > "$T/suite/test_probe.sh" <<PROBE
#!/usr/bin/env bash
[[ -r /proc/self/status ]] && echo "probe SigIgn=\$(awk '/^SigIgn:/{print \$2}' /proc/self/status)"
trap 'echo probe-got-int; exit 0' INT; kill -INT \$\$; sleep 2; echo probe-int-lost
PROBE
out="$(cd "$T/suite" && timeout -k 5 60 "${IGN[@]}" bash run.sh 2>&1)"
assert_ok "a test run by run.sh can still trap SIGINT" grep -qF "probe-got-int" <<<"$out"
assert_no "…and does not lose it" grep -qF "probe-int-lost" <<<"$out"

echo "== test_headless_attach.sh under ignored signals =="
SECONDS=0
out="$(timeout -k 5 90 "${IGN[@]}" bash "$HERE/test_headless_attach.sh" 2>&1)"; rc=$?
assert_eq "$rc" 0 "it passes, rather than hanging until the timeout kills it (rc 124)"
assert_no "…with no FAIL line" grep -qF "FAIL:" <<<"$out"

echo "== …and when the attach really cannot take SIGINT, it fails bounded =="
SECONDS=0
out="$(HAT_ATTACH_IGNORE_INT=1 timeout -k 5 90 bash "$HERE/test_headless_attach.sh" 2>&1)"; rc=$?
took=$SECONDS
assert_eq "$([[ $rc -ne 0 && $rc -ne 124 && $rc -ne 137 ]] && echo failed || echo "rc=$rc")" failed "it reports FAIL (rc $rc) instead of hanging"
assert_ok "…naming the attach that did not exit" grep -qF "FAIL: the attach process exits" <<<"$out"
assert_ok "…and the attach it started is gone" grep -qF "ok: …and no attach is left alive" <<<"$out"
assert_ok "…within 40 s (took ${took}s)" test "$took" -lt 40
finish

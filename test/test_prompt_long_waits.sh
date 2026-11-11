#!/usr/bin/env bash
# test_prompt_long_waits.sh — #1042: lanes slept 9-10 minutes in a foreground Bash loop and polled again. Every wake came
# after the 5-minute prompt-cache TTL and rewrote the lane's whole context (72% of two days' spend). The impl, resume,
# bug-fix and review prompts, as rendered, carry the LONG WAITS rule (prompts/_long_waits.md), and the two Windows
# partials (the winsma `run` is the longest wait there is) point at it. The poll interval stays under 270 seconds.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
flat(){ tr '\n' ' ' | tr -s ' '; }

echo "-- the partial"
w="$(flat <"$P/_long_waits.md")"
assert_ok "names the rule and the issue"                    grep -qF 'LONG WAITS (#1042)' <<<"$w"
assert_ok "a wait over about 4 minutes is not a sleep-poll" grep -qF 'never sleep-poll a wait longer than about 4 minutes' <<<"$w"
assert_ok "says why: the 5-minute cache rewrite"            grep -qF 'Your prompt cache lives 5 minutes' <<<"$w"
assert_ok "bans the seq/sleep loop"                         grep -qF 'for i in $(seq 1 58); do' <<<"$w"
assert_ok "bans the timeout/until loop"                     grep -qF 'timeout 585 bash -c "until' <<<"$w"
assert_ok "bans the SECONDS/while loop"                     grep -qF 'end=$((SECONDS+570)); while' <<<"$w"
assert_ok "long jobs run with run_in_background"            grep -qF 'Bash `run_in_background`' <<<"$w"
assert_ok "its exit wakes the lane"                         grep -qF 'Its exit wakes you, and waiting costs nothing' <<<"$w"
assert_ok "a queue wait parks (#1034)"                      grep -qF 'park the lane where a park exists' <<<"$w"
assert_ok "unavoidable polling stays under 270 seconds"     grep -qF 'under 270 seconds so the cache stays warm' <<<"$w"

echo "-- every lane prompt, as rendered"
for p in impl.md resume.md bug-fix.md review.md; do
  out="$(render "$P/$p" ISSUE=5 PRD=4 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused | flat)"
  assert_ok "$p: carries the LONG WAITS rule"               grep -qF 'LONG WAITS (#1042) — never sleep-poll a wait longer than about 4 minutes' <<<"$out"
  assert_ok "$p: …with the 270-second poll bound"           grep -qF 'under 270 seconds so the cache stays warm' <<<"$out"
  assert_no "$p: the partial directive is expanded"         grep -qF '{{> _long_waits.md}}' <<<"$out"
  assert_ok "$p: the SHARED HOST paragraph is intact"       grep -qF 'every fleet on the host. Never signal PID 0, PID 1 or a negative PID.' <<<"$out"
done

echo "-- the Windows partials"
for p in _windows_suite.md _windows_rtdd.md; do
  out="$(flat <"$P/$p")"
  assert_ok "$p: points at the LONG WAITS rule"             grep -qF 'LONG WAITS rule applies (#1042)' <<<"$out"
  assert_ok "$p: the winsma run goes in the background"     grep -qF '`run_in_background`' <<<"$out"
done
finish

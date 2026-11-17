#!/usr/bin/env bash
# test_hermetic.sh — the suite must never write a LIVE project's state.
#
# lib.sh honours an inherited STATE_DIR (scripts/lib.sh:15) and exports it (:16), and every pool
# worker exports its project's STATE_DIR to every child — including the agent sessions that run
# this suite. So a test run from inside a live fleet used to resolve CONFIG / WORKTREES_DIR /
# CHECKOUTS_DIR to that fleet's real .harness/ and scribble on it: `harness init`'s acme/widget
# config landed on top of a production config, and bug-acme_widget-i42 worktrees appeared in a
# real project's worktrees dir.
#
# This test pins STATE_DIR at a decoy "live project" and runs the three tests that did the damage.
# The decoy must come back untouched.
#
# (#608) It ran ~60 other test files in one process and, on Windows, ran past the per-test cap. Its loops are files of their own now —
# test_hermetic_state / _fleets / _agy for the first four seams, test_hermetic_engine_<k> for the fifth, test_hermetic_roll_<k> for the
# generalised decoy — sharing hermetic_lib.sh. What stays here is every check that runs no other test file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/hermetic_lib.sh"
# #610: every bare mktemp below lands in one private dir that goes with the test, so a run from a plain
# shell (not run.sh, which gives each test its own TMPDIR) leaves /tmp as it found it.
PRIVATE_TMP="$(mktemp -d)"; tmp_track "$PRIVATE_TMP"; export TMPDIR="$PRIVATE_TMP"
unset_inherited_config   # a direct run from inside a live lane (#541): its HARNESS_* config must not reach the probes below

# ── which tests the slices run (#434, #541, #608) ───────────────────────────────────────────────────────────────────────────────────────
hermetic_scan   # update_tests: every test that runs update.sh / `harness update`; fleet_tests: … or supervise / start (never a test_hermetic*.sh)
# The two that leaked (#434), and one that runs it as `harness update`, must be found — or the scan
# below guards nothing.
for t in test_update.sh test_web_install.sh test_update_prerelease.sh; do
  assert_ok "the update.sh scan finds $t" bash -c '[[ " $1 " == *" $2 "* ]]' _ "${update_tests[*]}" "$t"
done
# #441: the scan must not hang on the pipeline's exit status. Under pipefail, `grep -v … | grep -q`
# was false whenever grep -q quit at its match while grep -v still had a write pending (SIGPIPE, 141)
# — a race, so test_web_install.sh / test_supervise.sh dropped out of update_tests at random and lost
# their decoy-home guard without a failure. A fixture whose match sits in the first 4 KiB of >8 KiB of
# non-comment text, scanned repeatedly on one CPU where taskset exists, must be found every time.
# The fixture's match line is built from parts: spelled out here, it would make THIS file match its own
# scan, and the loop below would run test_hermetic.sh inside itself without end.
RACE="$(mktemp -d)"; tmp_track "$RACE"; u=update
{ printf '%s "$HERE/../scripts/%s.sh" --check\n' bash "$u"
  for (( i = 0; i < 400; i++ )); do echo "assert_ok \"filler line $i of non-comment text\" true"; done
} > "$RACE/test_race.sh"
pin=(); command -v taskset >/dev/null 2>&1 && taskset -c 0 true 2>/dev/null && pin=(taskset -c 0)
missed="$("${pin[@]}" bash -c 'set -uo pipefail; eval "$1"; m=0
  for (( i = 0; i < 300; i++ )); do runs_update "$2" || m=$((m+1)); done; echo "$m"' _ \
  "$(declare -f runs_update)" "$RACE/test_race.sh")"
assert_eq "$missed" 0 "the update.sh scan finds a match early in >8 KiB of text 300/300 (no SIGPIPE race)"
assert_no "the update.sh scan has no '| grep -q' under pipefail" \
  grep -qE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' <<<"$(declare -f runs_update)"
assert_no "the update.sh scan does not pick up test_hermetic*.sh itself (it would run itself)" \
  bash -c '[[ " $1 " == *" test_hermetic.sh "* ]]' _ "${update_tests[*]}"
# Each slice file names its own position and the slice count: the files, together, must be every slice of one count — a file added or
# dropped without renumbering the others would leave part of the scan unrun.
for kind in engine roll heavy; do
  n=$(ls "$HERE"/test_hermetic_${kind}_[0-9]*.sh | wc -l); ok=1
  for (( k = 1; k <= n; k++ )); do grep -qE "hermetic_slice $k $n " "$HERE/test_hermetic_${kind}_$k.sh" || ok=0; done
  assert_eq "$ok" 1 "test_hermetic_${kind}_1..$n: every file runs its own slice $k of $n, so together they run every scanned test"
done
# The heavy tests (each alone fills a slice) run in test_hermetic_heavy_*.sh, never in a roll slice: each must be found by the scan and be in no roll slice.
# test_cli_matrix.sh is cut per CLI (#963: whole, it ran for hours on Windows): it is found as one unit for each adapter under scripts/cli/, never as a whole.
for t in $HEAVY_TESTS; do
  if [[ $SHARDED_TESTS == *" $t "* ]]; then
    for c in $(matrix_clis); do
      assert_ok "heavy test $t: the fleet scan finds the $c unit" bash -c '[[ " $1 " == *" $2 "* ]]' _ "${heavy_tests[*]}" "$t@$c"
    done
    assert_no "heavy test $t is cut per CLI: the scan holds no whole-file unit for it" bash -c '[[ " $1 " == *" $2 "* ]]' _ "${heavy_tests[*]}" "$t"
  else
    assert_ok "heavy test $t is found by the fleet scan" bash -c '[[ " $1 " == *" $2 "* ]]' _ "${heavy_tests[*]}" "$t"
  fi
  assert_no "heavy test $t is in no roll slice (it would run twice)" bash -c '[[ " $1 " == *" $2 "* ]]' _ "${fleet_tests[*]}" "$t"
done
assert_eq "$(heavy_env test_cli_matrix.sh@claude)" "HARNESS_MATRIX_CLIS=claude" "a matrix unit runs only its own CLI's cells"
assert_eq "$(heavy_env test_supervise_autoupdate.sh)" "" "a whole-file heavy unit runs with no extra env"
assert_eq "$(heavy_file test_cli_matrix.sh@claude)" "test_cli_matrix.sh" "a matrix unit runs the matrix file"
# Every unit lands in exactly one heavy slice: the slices, put together, are the scan.
nh=$(ls "$HERE"/test_hermetic_heavy_[0-9]*.sh | wc -l); covered=""
for (( k = 1; k <= nh; k++ )); do covered+="$(hermetic_slice $k $nh ${heavy_tests[@]+"${heavy_tests[@]}"} | tr '\n' ' ')"; done
assert_eq "$(tr ' ' '\n' <<<"$covered" | grep . | sort | tr '\n' ' ')" "$(printf '%s\n' ${heavy_tests[@]+"${heavy_tests[@]}"} | sort | tr '\n' ' ')" \
  "the heavy slices together run every heavy unit exactly once"
# No heavy slice holds more than a share of the matrix CLIs: a slice that held them all would be the hours-long file #963 cut up.
for (( k = 1; k <= nh; k++ )); do
  m=$(hermetic_slice $k $nh ${heavy_tests[@]+"${heavy_tests[@]}"} | grep -c '^test_cli_matrix.sh@' || true)
  assert_ok "heavy slice $k of $nh holds at most 2 matrix CLIs ($m)" test "$m" -le 2
done

# A test that calls make_env must also be hermetic when run directly with a live STATE_DIR
# exported — make_env re-pins STATE_DIR and everything lib.sh derived from it.
decoy="$(make_decoy)"
export STATE_DIR="$decoy"
make_env
assert_no "make_env: STATE_DIR no longer points at the live project" \
  bash -c "[[ '$STATE_DIR' == '$decoy' ]]"
assert_no "make_env: CONFIG no longer points at the live config" \
  bash -c "[[ '$CONFIG' == '$decoy/config' ]]"
assert_no "make_env: WORKTREES_DIR no longer points at the live worktrees" \
  bash -c "[[ '$WORKTREES_DIR' == '$decoy/worktrees' ]]"
assert_no "make_env: CHECKOUTS_DIR no longer points at the live checkouts" \
  bash -c "[[ '$CHECKOUTS_DIR' == '$decoy/checkouts' ]]"
# unit_checkout/bug_checkout return PROJECT_ROOT as THE checkout in single topology, so a stale one
# aims a test's git at the live repo. lib.sh:17 also defines it as the parent of STATE_DIR — hold that.
assert_no "make_env: PROJECT_ROOT no longer points at the live project" \
  bash -c "[[ '$PROJECT_ROOT' == "$(dirname "$decoy")" ]]"
assert_eq "$(cd "$PROJECT_ROOT" && pwd)" "$(cd "$STATE_DIR/.." && pwd)" \
  "make_env: PROJECT_ROOT stays the parent of STATE_DIR (lib.sh:17 invariant)"

# Claude Code's config is host state too. ensure_trusted seeds every config the launched pane could
# read — ~/.claude.json, $CLAUDE_CONFIG_DIR/.claude.json, and each ~/.claude-switch/accounts/*/ —
# so a suite run inside a live agent session (whose .bashrc exports CLAUDE_CONFIG_DIR) wrote fixture
# /tmp paths into the developer's real per-account config. make_env pins the seam and drops the
# inherited config dir.
export CLAUDE_CONFIG_DIR="$(mktemp -d)"
CCD_DECOY="$CLAUDE_CONFIG_DIR"
make_env
assert_eq "${CLAUDE_CONFIG_DIR-<unset>}" "<unset>" \
  "make_env: inherited CLAUDE_CONFIG_DIR is dropped"
assert_ok "make_env: HARNESS_CLAUDE_CONFIG pinned inside the throwaway RUN_DIR" \
  bash -c "[[ '$HARNESS_CLAUDE_CONFIG' == '$RUN_DIR'/* ]]"
( source "$HERE/../scripts/lib.sh"; HARNESS_AUTONOMOUS=true ensure_trusted "$(mktemp -d)" )
assert_no "make_env: ensure_trusted writes no config into the live config dir" \
  test -e "$CCD_DECOY/.claude.json"

# The live fleet's CONFIG, not just its paths. Config lines are `: "${VAR:=…}"`, so an inherited
# value BEATS the file by design — a suite running inside a live agent session (which exports the
# whole set) read that fleet's HARNESS_REPO / HARNESS_AUTONOMOUS in place of its own fixture's, and
# test_init.sh's round-trip assertion failed on a real machine while passing on a bare one. Pinning
# STATE_DIR could not help: nothing about this leak goes through a path.
#
# Asserted in a SUBSHELL, and against unset_inherited_config directly rather than via make_env: the
# drop has to happen before lib.sh is sourced (see helpers.sh), and this file has already sourced it.
( export HARNESS_REPO=live/production HARNESS_AUTONOMOUS=false HARNESS_MODE=planned \
         HARNESS_LABEL_READY=live-ready HARNESS_CI_GATE=0
  unset_inherited_config
  for v in HARNESS_REPO HARNESS_AUTONOMOUS HARNESS_MODE HARNESS_LABEL_READY HARNESS_CI_GATE; do
    [[ "${!v-<unset>}" == "<unset>" ]] || exit 1
  done
  # ...and the fixture's own value now wins where the live one used to.
  cfg="$(mktemp)"; printf ': "${HARNESS_REPO:=fixture/widget}"\n' > "$cfg"; source "$cfg"
  [[ "$HARNESS_REPO" == fixture/widget ]] ) \
  && { echo "  ok: inherited config is dropped and a fixture config round-trips"; TESTS_RUN=$((TESTS_RUN+1)); } \
  || { echo "  FAIL: fixture config still loses to the live env"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)); }
# The host PATH pins must SURVIVE the drop — run.sh and make_env set them deliberately.
( unset_inherited_config
  [[ -n "${HARNESS_HOME:-}" && -n "${HARNESS_POLLER_DIR:-}" && -n "${HARNESS_SNAPSHOTS_DIR:-}" \
     && -n "${HARNESS_FLEETS_DIR:-}" ]] ) \
  && { echo "  ok: the host path pins survive the drop"; TESTS_RUN=$((TESTS_RUN+1)); } \
  || { echo "  FAIL: the host path pins were dropped too"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)); }
# run.sh must actually DO the drop — a helper nobody calls guards nothing.
assert_ok "run.sh drops inherited config before the suite loop" \
  grep -q 'unset_inherited_config' "$HERE/run.sh"
assert_ok "test_init.sh re-drops for a direct invocation" \
  grep -q 'unset_inherited_config' "$HERE/test_init.sh"
# The fleet-registry pin must be in BOTH blanket guards, not just make_env: run.sh hands each test
# its own host root, and a test that never calls make_env (test_init.sh) relies on run.sh's copy.
# (#541: both go through pin_host_home, which is where the fleet-registry pin now lives.)
assert_ok "run.sh pins the host root per test through pin_host_home" \
  grep -qE '^[[:space:]]*pin_host_home ' "$HERE/run.sh"
assert_ok "make_env pins the host root through pin_host_home too" \
  grep -qE '^[[:space:]]*pin_host_home ' "$HERE/helpers.sh"
assert_ok "pin_host_home pins HARNESS_FLEETS_DIR" bash -c '[[ " $1 " == *" HARNESS_FLEETS_DIR:fleets "* ]]' _ "$(echo $HARNESS_HOST_PIN_VARS)"

# #333: the guard must RUN, not merely be named in run.sh. release.sh gates a release with
# `cd <tree> && bash test/run.sh`; run.sh then cd'd into test/ and sourced helpers.sh by a path
# relative to its OLD cwd (test/test/helpers.sh), so unset_inherited_config was never defined and
# every fleet variable leaked into every test. Run a copy of run.sh exactly that way, on a tree whose
# only test is a probe that records what it inherited.
RT="$(mktemp -d)"; tmp_track "$RT"; mkdir -p "$RT/test"
cp "$HERE/run.sh" "$HERE/helpers.sh" "$RT/test/"; cp -r "$HERE/guard" "$RT/test/guard"   # run.sh installs the tmux guard (#649): it ships beside helpers.sh
cat > "$RT/test/test_probe.sh" <<'EOF'
#!/usr/bin/env bash
for v in HARNESS_SESS_PREFIX HARNESS_CLAUDE_BIN HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR \
  HARNESS_TURN_MAX TMUX TMUX_PANE; do echo "$v=${!v-<unset>}"; done > "$PROBE_OUT"
printf '›\n' | grep -qE '^[›»]$' && echo "utf8=yes" >> "$PROBE_OUT" || echo "utf8=no" >> "$PROBE_OUT"
EOF
leaky(){ env -u LC_ALL -u LC_CTYPE PROBE_OUT="$RT/probe.out" LANG=C HARNESS_SESS_PREFIX=leak \
  HARNESS_CLAUDE_BIN=/leak/claude HARNESS_SNAPSHOT_FILE=/leak/s.json HARNESS_SNAPSHOT_DIR=/leak \
  HARNESS_TURN_MAX=1 TMUX=/leak,1,0 TMUX_PANE=%9 "$@"; }
probe_clean(){ [[ "$(cat "$RT/probe.out" 2>/dev/null)" == "$(printf '%s=<unset>\n' HARNESS_SESS_PREFIX \
  HARNESS_CLAUDE_BIN HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR HARNESS_TURN_MAX TMUX TMUX_PANE; echo utf8=yes)" ]]; }
for how in root test abs; do
  rm -f "$RT/probe.out"
  case $how in
    root) out="$(cd "$RT" && leaky bash test/run.sh 2>&1)";;
    test) out="$(cd "$RT/test" && leaky bash run.sh 2>&1)";;
    abs)  out="$(cd / && leaky bash "$RT/test/run.sh" 2>&1)";;
  esac
  assert_ok "run.sh ($how-relative) hands its tests none of the fleet's env, and a UTF-8 locale" probe_clean
  assert_no "run.sh ($how-relative) runs its guard without an error" grep -qE 'No such file|command not found' <<<"$out"
  probe_clean || { cat "$RT/probe.out" 2>/dev/null; head -5 <<<"$out"; }
done
# A run.sh that cannot load its guard must stop, not run the suite unguarded.
mv "$RT/test/helpers.sh" "$RT/helpers.sh.away"; rm -f "$RT/probe.out"
(cd "$RT" && leaky bash test/run.sh >/dev/null 2>&1); rc=$?
assert_no "run.sh without helpers.sh exits non-zero" test "$rc" = 0
assert_no "...before any test runs" test -e "$RT/probe.out"
mv "$RT/helpers.sh.away" "$RT/test/helpers.sh"


# #404: agy, hermes and openclaw read their usage windows by RUNNING their CLI (*_limit_usage), off
# PATH by default. make_env pinned each CLI's home but not its binary, so every test that reached
# usage_watch ran the HOST's real one on the operator's real account: a host near its agy weekly
# limit opened a usage hold in the fixture, and test_ghrate.sh's agy cells failed on the quota, not
# the commit. Put a canary for each first on PATH, BEFORE make_env, reporting a window at 99.8%: make_env
# must shadow it, so no usage probe reaches it and no hold opens.
CAN="$(mktemp -d)"; tmp_track "$CAN"
canary(){ { printf '#!/usr/bin/env bash\necho "$0 $*" >> %q\ncat <<'"'"'J'"'"'\n' "$CAN/calls"; printf '%s\nJ\n' "$2"; } > "$CAN/$1"
  chmod +x "$CAN/$1"; }
canary agy '{"command":{"data":{"groups":[{"name":"G","buckets":[{"window":"weekly","remaining_fraction":0.002,"reset_time":"2030-01-01T00:00:00Z"}]}]}}}'
canary hermes '{"provider":"P","windows":[{"label":"weekly","used_percent":99.8,"resets_at":"2030-01-01T00:00:00Z"}]}'
canary openclaw '{"usage":{"providers":[{"provider":"P","windows":[{"label":"weekly","usedPercent":99.8,"resetAt":1893456000000}]}]}}'
# usage_probe <cli> [VAR=value…] — one usage_watch for <cli> after make_env, the canaries first on
# PATH; prints the number of usage holds it opened.
usage_probe(){ ( export PATH="$CAN:$PATH"; source "$HERE/../scripts/lib.sh"; make_env
  export HARNESS_CLI="$1"; shift; (( $# )) && export "$@"
  usage_watch >/dev/null 2>&1; find "$(_usage_hold_dir)" -name '*.hold' 2>/dev/null | wc -l ); }
for c in agy hermes openclaw; do
  : > "$CAN/calls"
  assert_eq "$(usage_probe "$c")" 0 "make_env: a host near its $c limit opens no usage hold in a test"
  assert_eq "$(cat "$CAN/calls")" "" "make_env: $c's usage probe never runs the $c on the host's PATH"
  # The control: the canary does report over the threshold, and a suite that drives a stub binary
  # on purpose (HARNESS_<CLI>_BIN) still reaches it.
  : > "$CAN/calls"; v="HARNESS_$(tr a-z A-Z <<<"$c")_BIN"
  assert_eq "$(usage_probe "$c" "$v=$CAN/$c")" 1 "...while $v pointed at a stub still drives $c's usage"
  assert_ok "...and runs that stub" grep -q "$CAN/$c" "$CAN/calls"
done
# test_ghrate.sh is the suite that failed the release gate on it (#404): green beside an agy at 99.8%.
: > "$CAN/calls"
assert_ok "test_ghrate.sh passes on a host whose agy is over the checkpoint threshold" \
  env PATH="$CAN:$PATH" bash "$HERE/test_ghrate.sh" >/dev/null 2>&1
assert_eq "$(cat "$CAN/calls")" "" "...and never runs that agy"

# ══ #541: a test that picks its own HARNESS_HOME must not reach the REAL fleets ══════════════════════
# Every fleet process exports HARNESS_FLEETS_DIR / HARNESS_POLLER_DIR / HARNESS_SNAPSHOTS_DIR and a lane
# inherits them; every reader prefers the inherited value over the HARNESS_HOME a test sets. A test that
# sets HARNESS_HOME without re-pinning them reads the real fleet registry — and `harness supervise`
# (sup_au_roll → fleet_roll) / `harness update` (fleet-migrate --all) then KILL AND RELAUNCH every
# registered fleet's workers from the test sandbox's engine. This block is that incident, as a guard.

# pin_host_home itself: from a lane's environment, every host path ends up under the new home.
(
  export HARNESS_FLEETS_DIR=/real/fleets HARNESS_POLLER_DIR=/real/poller HARNESS_SNAPSHOTS_DIR=/real/snap \
         HARNESS_WEB_UNIT_DIR=/real/units HARNESS_SUPERVISE_UNIT_DIR=/real/units XDG_CONFIG_HOME=/real/cfg HARNESS_EVENTS_FILE=/real/ev \
         HARNESS_LANE_DIR=/real/lane HARNESS_SUPERVISE_STATE=/real/sup XDG_RUNTIME_DIR=/run/user/1 \
         DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1/bus HARNESS_WEB_SYSTEMCTL=systemctl
  pin_host_home /pinned/home
  [[ "$HARNESS_HOME" == /pinned/home ]] || exit 1
  for e in $HARNESS_HOST_PIN_VARS; do v="${e%%:*}"; [[ "${!v}" == "/pinned/home/${e#*:}" ]] || { echo "pin: $v=${!v}"; exit 1; }; done
  for v in $HARNESS_HOST_DROP_VARS $HARNESS_HOST_DROP_BUS; do [[ -z "${!v+x}" ]] || { echo "drop: $v still set"; exit 1; }; done
  for v in $HARNESS_HOST_FAIL_TOOLS; do [[ "${!v}" == false ]] || { echo "tool: $v=${!v}"; exit 1; }; done
) && { echo "  ok: pin_host_home re-pins every host path under the new home and drops the user bus"; TESTS_RUN=$((TESTS_RUN+1)); } \
  || { echo "  FAIL: pin_host_home left a host path / the user bus reachable"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)); }

# The lane's identity never reaches a test (#541): sourcing helpers.sh drops it, and pin_host_home does again.
assert_eq "$(HARNESS_SESSION=u-1 HARNESS_ISSUE=541 TMUX=/s,1,0 TMUX_PANE=%1 HARNESS_PREFIX=hz bash -c 'source "$1"; echo "${HARNESS_SESSION-}|${HARNESS_ISSUE-}|${TMUX-}|${TMUX_PANE-}|${HARNESS_PREFIX-}"' _ "$HERE/helpers.sh")" "||||" \
  "sourcing helpers.sh drops the lane's HARNESS_SESSION / HARNESS_ISSUE / TMUX / prefix (sess_sweep would kill the lane)"
assert_eq "$(HARNESS_SESSION=u-1 bash -c 'source "$1"; export HARNESS_SESSION=u-2 TMUX=/s,1,0; pin_host_home /pinned/h; echo "${HARNESS_SESSION-}|${TMUX-}"' _ "$HERE/helpers.sh")" "|" \
  "pin_host_home drops a lane identity set after sourcing"

# #682: pool.sh / priority.sh EXPORT HARNESS_ENGINE_STAMP to the worker they launch (#602), and every child of that
# worker inherits it — the release_kick job, the gate, and the suite. A `sleep` a test starts as an "unstamped worker"
# then carries the host's stamp, roll.sh calls it stale and kills it. The seam must drop it, for a gate run and for a
# direct `bash test_X.sh`; pin_host_home drops it again if a test re-exports it.
# The child reports its own environment (`env` has necessarily exec'd): reading /proc/<pid>/environ of a forked-but-not-yet-
# exec'd `sleep &` returns the outer bash's startup block, which still holds the stamp (flaky, ~5%; #1043).
assert_eq "$(HARNESS_ENGINE_STAMP=1234-5678 bash -c 'source "$1"; env | grep -c "^HARNESS_ENGINE_STAMP="' _ "$HERE/helpers.sh")" "0" \
  "a process a test starts does not carry the host's HARNESS_ENGINE_STAMP in its environ"
assert_eq "$(HARNESS_ENGINE_STAMP=1234-5678 bash -c 'source "$1"; export HARNESS_ENGINE_STAMP=9-9; pin_host_home /pinned/h; echo "${HARNESS_ENGINE_STAMP-}"' _ "$HERE/helpers.sh")" "" \
  "pin_host_home drops a HARNESS_ENGINE_STAMP set after sourcing"

assert_eq "$(HARNESS_WAIT_FILE=/x/lane.wait bash -c 'source "$1"; echo "${HARNESS_WAIT_FILE-<unset>}"' _ "$HERE/helpers.sh")" "<unset>" \
  "sourcing helpers.sh drops the lane's HARNESS_WAIT_FILE (a test's park would overwrite the lane's wait spec)"
assert_eq "$(HARNESS_WAIT_FILE=/x/lane.wait bash -c 'source "$1"; export HARNESS_WAIT_FILE=/y; pin_host_home /pinned/h; echo "${HARNESS_WAIT_FILE-<unset>}"' _ "$HERE/helpers.sh")" "<unset>" \
  "pin_host_home drops a HARNESS_WAIT_FILE set after sourcing"

# #1247: a lane's safe.directory entries (ensure_safe, #1115) arrive as GIT_CONFIG_COUNT / GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n>. Left in a test's
# environment they shifted test_stats' entry-0 value and its -e counts, so the suite was red from inside a lane. Sourcing helpers.sh drops every one
# (any n), and run.sh -- which sources it -- hands its tests none; a test that exports its own after sourcing keeps it.
assert_eq "$(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/lane/checkout GIT_CONFIG_KEY_1=safe.directory GIT_CONFIG_VALUE_1=/other GIT_CONFIG_KEY_12=x.y GIT_CONFIG_VALUE_12=z \
  bash -c 'source "$1"; env | grep -c "^GIT_CONFIG_\(COUNT\|KEY_[0-9]*\|VALUE_[0-9]*\)="' _ "$HERE/helpers.sh")" "0" \
  "sourcing helpers.sh drops the lane's GIT_CONFIG_COUNT / GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n> (its safe.directory entries must not reach a test)"
assert_eq "$(GIT_CONFIG_GLOBAL=/g GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=a.b GIT_CONFIG_VALUE_0=c bash -c 'source "$1"; echo "${GIT_CONFIG_GLOBAL-}|${GIT_CONFIG_NOSYSTEM-}"; export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always; git config --get-all protocol.file.allow' _ "$HERE/helpers.sh")" "/g|1
always" \
  "GIT_CONFIG_GLOBAL / _NOSYSTEM survive, and a test's own GIT_CONFIG_* exported after sourcing works"
assert_eq "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/lane/checkout bash -c 'source "$1"; bash -c "env | grep -c ^GIT_CONFIG_KEY_0="' _ "$HERE/helpers.sh")" "0" \
  "a child of a shell that sourced helpers.sh (run.sh's position) carries no GIT_CONFIG_KEY_0"

# …and the lint above checks that a private dir is SET, not that it still EXISTS at every call (#649): tmux silently uses the host's
# /tmp/tmux-$UID/ when TMUX_TMPDIR names a deleted dir. The fail-closed guard (test/guard/tmux) is what covers that; the behaviour is
# test_tmux_fallback_guard.sh's, here only that nothing can run the suite — or pin a host — without installing it.
assert_ok "run.sh installs the tmux guard before any test runs" grep -q '^tmux_guard_install || exit 1' "$HERE/run.sh"
assert_ok "pin_host_home installs the tmux guard (a direct bash test_foo.sh is guarded too)" bash -c "sed -n '/^pin_host_home(){/,/^}/p' '$HERE/helpers.sh' | grep -q tmux_guard_install"

for t in test_supervise_autoupdate.sh test_update_release.sh test_migrate_release.sh test_update_prerelease.sh test_rollback.sh test_update.sh; do
  assert_ok "the fleet-roller scan finds $t" bash -c '[[ " $1 " == *" $2 "* ]]' _ "${fleet_tests[*]} ${heavy_tests[*]}" "$t"
done

finish

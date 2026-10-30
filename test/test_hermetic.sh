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
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

SENTINEL=': "${HARNESS_REPO:=sentinel/live}"'

# make_decoy — a plausible live project state dir, echoed on stdout.
make_decoy(){
  local d; d="$(mktemp -d)/.harness"
  mkdir -p "$d/worktrees" "$d/checkouts" "$d/run/claims"
  printf '%s\n' "$SENTINEL" > "$d/config"
  printf '%s' "$d"
}

# assert_untouched <decoy> <label> — config still the sentinel, no worktrees/checkouts created.
assert_untouched(){
  local d="$1" label="$2"
  assert_eq "$(cat "$d/config")" "$SENTINEL" "$label: live config not overwritten"
  assert_eq "$(find "$d/worktrees" -mindepth 1 | wc -l)" "0" "$label: no worktrees in live state dir"
  assert_eq "$(find "$d/checkouts" -mindepth 1 | wc -l)" "0" "$label: no checkouts in live state dir"
}

# The offenders: init.sh writes $STATE_DIR/config; drive/bug_flow build $STATE_DIR/worktrees paths.
for t in test_init.sh test_bug_flow.sh test_drive.sh; do
  [[ -f "$HERE/$t" ]] || continue
  decoy="$(make_decoy)"
  STATE_DIR="$decoy" bash "$HERE/$t" >/dev/null 2>&1
  assert_untouched "$decoy" "$t"
done

# ── the HOST root (lib.sh:86-92) is a second, independent seam ──────────────────────────────────
# HARNESS_HOME is NOT derived from STATE_DIR, so pinning STATE_DIR alone left the real ~/.harness
# poller registry writable. That registry is SHARED by every co-resident fleet and `harness start`
# aborts on a prefix collision against it, so fixture entries there don't merely litter — they stop
# an unrelated production fleet from starting at all.
# The vector is HARNESS_POLLER_DIR specifically, not HARNESS_HOME: lib.sh:87 prefers an INHERITED
# HARNESS_POLLER_DIR over the HARNESS_HOME a test just set, and :89 exports it from every fleet
# process — so test_prefix_guard.sh's own `export HARNESS_HOME="$(mktemp -d)"` (line 8) is defeated
# exactly the way test_init.sh's `export HARNESS_DIR` was.
make_host_decoy(){ local d; d="$(mktemp -d)/.harness"; mkdir -p "$d/poller/registry" "$d/snapshots"; printf '%s' "$d"; }
for t in test_prefix_guard.sh test_poller.sh test_priority.sh test_worker.sh; do
  [[ -f "$HERE/$t" ]] || continue
  host="$(make_host_decoy)"
  HARNESS_POLLER_DIR="$host/poller" HARNESS_SNAPSHOTS_DIR="$host/snapshots" bash "$HERE/$t" >/dev/null 2>&1
  assert_eq "$(find "$host/poller/registry" -mindepth 1 | wc -l)" "0" "$t: no registry entries in live host root"
  assert_eq "$(find "$host/snapshots" -mindepth 1 | wc -l)" "0" "$t: no snapshots in live host root"
done

# ── the host FLEET registry is a THIRD such seam, and the worst of the three ────────────────────
# lib.sh:99-100 prefers an inherited HARNESS_FLEETS_DIR over the HARNESS_HOME a test sets for itself
# and then exports it, so every fleet worker hands ~/.harness/fleets down to the agent session that
# runs this suite. Unlike the poller registry, entries here are not merely read — `doctor --fix`
# DELETES them (test_doctor.sh calls doctor_main --fix), so the suite could strip a live sibling
# fleet's prefix reservation off the real host. The decoy holds one entry and must come back intact.
make_fleet_decoy(){ local d; d="$(mktemp -d)/.harness"; mkdir -p "$d/fleets"
  printf '%s\n' '{"prefix":"live","project":"/live/proj/.harness","run_dir":"/live/proj/.harness/run","slugs":["live/repo"],"started_at":0}' \
    > "$d/fleets/live.json"; printf '%s' "$d"; }
for t in test_doctor.sh test_prefix_guard.sh test_fleet_registry.sh test_init.sh test_status.sh; do
  [[ -f "$HERE/$t" ]] || continue
  host="$(make_fleet_decoy)"
  HARNESS_FLEETS_DIR="$host/fleets" bash "$HERE/$t" >/dev/null 2>&1
  assert_ok "$t: the live fleet-registry entry survives (not pruned by --fix)" \
    test -f "$host/fleets/live.json"
  assert_eq "$(find "$host/fleets" -mindepth 1 | wc -l)" "1" "$t: no fixture entries in the live fleet registry"
done

# ── the host's agy binary is a FOURTH seam (#236) ──────────────────────────────────────────────
# uninstall.sh's remove_skills ends with `agy plugin uninstall harness-ralph` — agy's goal loop. Run
# by test_uninstall.sh against the host's real agy, the suite stripped that plugin off a live fleet
# host and every agy lane after it lost its loop. Both seams leak: agy found on PATH, and an
# inherited HARNESS_AGY_BIN (lib.sh:85 exports it from every fleet process) naming the real binary.
# Plant a tripwire on BOTH; it must never be called at all.
# The install side leaks the same way (#240): install.sh's check_prereqs / ensure_skills run
# `agy --version`, `agy plugin list` and `agy plugin install`, reached by test_install.sh directly and
# by test_update.sh / test_supervise.sh through update.sh (which sources install.sh). Each suite pins
# its own stub, so the tripwire log must come back EMPTY — not merely free of `plugin uninstall`.
for t in test_install.sh test_update.sh test_supervise.sh test_uninstall.sh; do
  [[ -f "$HERE/$t" ]] || continue
  TRIP="$(mktemp -d)"; : > "$TRIP/agy.log"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\n' "$TRIP/agy.log" > "$TRIP/agy"; chmod +x "$TRIP/agy"
  PATH="$TRIP:$PATH" HARNESS_AGY_BIN="$TRIP/agy" bash "$HERE/$t" >/dev/null 2>&1
  assert_eq "$(cat "$TRIP/agy.log")" "" \
    "$t: the host's agy is never called (PATH or inherited HARNESS_AGY_BIN)"
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
assert_ok "run.sh pins HARNESS_FLEETS_DIR per test" \
  grep -q 'export HARNESS_FLEETS_DIR=' "$HERE/run.sh"
assert_ok "make_env pins HARNESS_FLEETS_DIR too" \
  grep -q 'export HARNESS_FLEETS_DIR=' "$HERE/helpers.sh"

# #333: the guard must RUN, not merely be named in run.sh. release.sh gates a release with
# `cd <tree> && bash test/run.sh`; run.sh then cd'd into test/ and sourced helpers.sh by a path
# relative to its OLD cwd (test/test/helpers.sh), so unset_inherited_config was never defined and
# every fleet variable leaked into every test. Run a copy of run.sh exactly that way, on a tree whose
# only test is a probe that records what it inherited.
RT="$(mktemp -d)"; tmp_track "$RT"; mkdir -p "$RT/test"
cp "$HERE/run.sh" "$HERE/helpers.sh" "$RT/test/"
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

# #333: every HARNESS_* variable the engine EXPORTS reaches the agent session running this suite, so
# every one must be in the drop list — snapshot_gate's HARNESS_SNAPSHOT_FILE/_DIR made issuelib.py
# read the host's real poller snapshot instead of the stubbed gh, and an inherited absolute
# HARNESS_CLAUDE_BIN satisfied check_prereqs with no claude on PATH. The four host path pins are
# exempt: run.sh and make_env re-pin them to throwaways on purpose.
exported_vars(){ local f; for f in "$HERE/../scripts/lib.sh" "$HERE/../scripts/supervise.sh" "$HERE/../scripts/cli/"*.sh; do
    sed -e :a -e '/\\$/N; s/\\\n//; ta' "$f"; done |
  awk '{ for (i = 1; i <= NF; i++) if ($i == "export") for (j = i + 1; j <= NF; j++) {
           if ($j ~ /^HARNESS_[A-Z0-9_]+(=|$)/) { sub(/=.*/, "", $j); print $j } else if ($j !~ /^-/) break } }' | sort -u; }
missing=""
for v in $(exported_vars); do
  case " HARNESS_HOME HARNESS_POLLER_DIR HARNESS_SNAPSHOTS_DIR HARNESS_FLEETS_DIR " in *" $v "*) continue;; esac
  [[ " $(echo $HARNESS_CONFIG_VARS) " == *" $v "* ]] || missing+=" $v"
done
assert_eq "$missing" "" "every HARNESS_* variable the engine exports is in HARNESS_CONFIG_VARS"
assert_ok "the export scan sees the adapters' and snapshot_gate's exports" \
  bash -c '[[ $(tr "\n" " " <<<"$1") == *HARNESS_CLAUDE_BIN*HARNESS_SNAPSHOT_FILE* ]]' _ "$(exported_vars)"

finish

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

# ── the host's ENGINE is a FIFTH seam (#434) ───────────────────────────────────────────────────
# update.sh picks its path off "${HARNESS_HOME:-$HOME/.harness}/engine": a release symlink (every host
# installed since #279) takes the release path — it sources install.sh, asks the real GitHub releases
# API for the latest tag, and with a newer one published would rel_install + engine_flip the LIVE
# engine. A test that runs update.sh (or `harness update`) without its own HARNESS_HOME read the
# host's link, ignored its own ENGINE_DIR fixture, and went red (test_update.sh, test_web_install.sh)
# or worse. Run every such test against a decoy host root whose engine IS a release symlink — handed
# down as both HOME and an inherited HARNESS_HOME, the two ways the real one reaches a test — with a
# curl tripwire first on PATH. Each must pass, leave the decoy byte-for-byte as it was, and never
# reach github.com.
# runs_update <file> — the test runs update.sh, or `harness update`, on a non-comment line.
# The reader drains all input (>/dev/null, not -q): under pipefail an early-exiting `grep -q` SIGPIPEs
# the writer and the pipeline reads false at random (#441).
runs_update(){ grep -v '^[[:space:]]*#' "$1" |
  grep -E '(bash|exec)[^#|]*update\.sh|harness"?[[:space:]]+update([[:space:]]|$|")' >/dev/null; }
update_tests=()
for f in "$HERE"/test_*.sh; do runs_update "$f" && update_tests+=("$(basename "$f")"); done
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
assert_no "the update.sh scan does not pick up test_hermetic.sh itself (it would run itself)" \
  bash -c '[[ " $1 " == *" test_hermetic.sh "* ]]' _ "${update_tests[*]}"
# decoy_host — a home whose .harness/engine is a release symlink, echoed on stdout (tracked by the
# caller: a tmp_track inside the $(…) would delete it as that subshell exits). It carries a git
# identity, as a real home does — test_supervise.sh's WIP checkpoints commit with the user's own.
decoy_host(){ local d; d="$(mktemp -d)"; printf '[user]\n\tname = t\n\temail = t@t\n' > "$d/.gitconfig"
  mkdir -p "$d/.harness/releases/v0.0.1/bin"; printf 'v0.0.1\n' > "$d/.harness/releases/v0.0.1/VERSION"
  printf 'v0.0.1\n' > "$d/.harness/releases/.installed"; ln -s releases/v0.0.1 "$d/.harness/engine"
  printf '%s' "$d"; }
# tree_state <dir> — every path under <dir> with its type, link target, size and mtime.
tree_state(){ find "$1" -printf '%P %y %l %s %T@\n' | sort; }
for t in "${update_tests[@]}"; do
  dh="$(decoy_host)"; tmp_track "$dh"; before="$(tree_state "$dh/.harness")"
  TRIP="$(mktemp -d)"; tmp_track "$TRIP"; : > "$TRIP/curl.log"
  # Logs every call; refuses github.com, passes anything else (file:// fixtures) to the real curl.
  cat > "$TRIP/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> $(printf %q "$TRIP/curl.log")
[[ "\$*" == *github.com* ]] && exit 22
PATH=$(printf %q "$PATH") exec curl "\$@"
EOF
  chmod +x "$TRIP/curl"
  # #541: nor the user service manager — a test that reaches systemctl/loginctl off PATH, or writes a unit
  # under HOME, would stop and unlink a live fleet host's harness-web.service. Tripwire both.
  : > "$TRIP/bus.log"
  for c in systemctl loginctl; do printf '#!/usr/bin/env bash\necho "%s $*" >> %q\nexit 1\n' "$c" "$TRIP/bus.log" > "$TRIP/$c"; chmod +x "$TRIP/$c"; done
  HOME="$dh" HARNESS_HOME="$dh/.harness" PATH="$TRIP:$PATH" bash "$HERE/$t" >"$TRIP/out" 2>&1; rc=$?
  assert_eq "$rc" 0 "$t passes on a host whose ~/.harness/engine is a release symlink"
  (( rc == 0 )) || grep -E 'FAIL|rror' "$TRIP/out" | head -5
  assert_eq "$(tree_state "$dh/.harness")" "$before" "$t: the host's ~/.harness is left exactly as it was"
  assert_no "$t: never queries github.com (the releases API)" grep -q 'github\.com' "$TRIP/curl.log"
  assert_eq "$(cat "$TRIP/bus.log")" "" "$t: never calls systemctl / loginctl off PATH (the user service manager)"
  assert_no "$t: writes no systemd unit under the inherited HOME" test -e "$dh/.config/systemd"
  # #439: every update links the engine's skills into each installed CLI's user-skills dir under HOME;
  # a test's own engine must never be linked into the inherited (real) home's.
  assert_eq "$(cd "$dh" && ls -d .claude .hermes .agents .gemini .copilot 2>/dev/null | xargs)" "" \
    "$t: links no skills into the inherited HOME's CLI dirs"
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
         HARNESS_WEB_UNIT_DIR=/real/units HARNESS_SUPERVISE_UNIT_DIR=/real/units HARNESS_EVENTS_FILE=/real/ev \
         HARNESS_LANE_DIR=/real/lane HARNESS_SUPERVISE_STATE=/real/sup XDG_RUNTIME_DIR=/run/user/1 \
         DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1/bus HARNESS_WEB_SYSTEMCTL=systemctl
  pin_host_home /pinned/home
  [[ "$HARNESS_HOME" == /pinned/home ]] || exit 1
  for e in $HARNESS_HOST_PIN_VARS; do v="${e%%:*}"; [[ "${!v}" == "/pinned/home/${e#*:}" ]] || { echo "pin: $v=${!v}"; exit 1; }; done
  for v in $HARNESS_HOST_DROP_VARS $HARNESS_HOST_DROP_BUS; do [[ -z "${!v+x}" ]] || { echo "drop: $v still set"; exit 1; }; done
  for v in $HARNESS_HOST_FAIL_TOOLS; do [[ "${!v}" == false ]] || { echo "tool: $v=${!v}"; exit 1; }; done
) && { echo "  ok: pin_host_home re-pins every host path under the new home and drops the user bus"; TESTS_RUN=$((TESTS_RUN+1)); } \
  || { echo "  FAIL: pin_host_home left a host path / the user bus reachable"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)); }

# One source of truth (Acceptance 4): every path var the engine rewrites for native Windows programs
# (HARNESS_NATIVE_PATH_VARS) is pinned or dropped by pin_host_home, or exempted in helpers.sh WITH a reason.
source "$HERE/../scripts/portable.sh" 2>/dev/null
undecided=""
for v in $HARNESS_NATIVE_PATH_VARS; do
  [[ " $(echo $HARNESS_HOST_PIN_VARS | tr ' ' '\n' | sed 's/:.*//' | tr '\n' ' ')$(echo $HARNESS_HOST_DROP_VARS) $(echo $HARNESS_HOST_PATH_EXEMPT) " == *" $v "* ]] || undecided+=" $v"
done
assert_eq "$undecided" "" "every HARNESS_NATIVE_PATH_VARS member is pinned, dropped, or exempted with a reason"
assert_ok "the exemptions are explained in helpers.sh (a '#   NAME … — reason' line each)" bash -c '
  for v in $1; do grep -qE "^#   .*\b$v\b.* — " "$2" || { echo "no reason for $v"; exit 1; }; done' _ "$HARNESS_HOST_PATH_EXEMPT" "$HERE/helpers.sh"

# ── static lint (Acceptance 3): no test assigns HARNESS_HOME before pinning the host fleet registry ────
# host_pin_offenders <file…> — print each file that assigns HARNESS_HOME (export, plain, inline env prefix,
# os.environ, a kwarg) on a line before — or without — a line that pins the host: pin_host_home, make_env,
# or its own HARNESS_FLEETS_DIR. A pin on the SAME line as the assignment counts.
host_pin_offenders(){ local f
  for f in "$@"; do
    awk '/^[[:space:]]*#/ { next }
         { asg = ($0 ~ /(^|[^A-Za-z0-9_])HARNESS_HOME[[:space:]]*=/ || $0 ~ /environ\[[^]]*HARNESS_HOME[^]]*\][[:space:]]*=/)
           pin = ($0 ~ /(^|[^A-Za-z0-9_])(pin_host_home|make_env)([^A-Za-z0-9_]|$)/ || $0 ~ /HARNESS_FLEETS_DIR[^A-Za-z0-9_]*[[:space:]]*=/ || $0 ~ /environ\[[^]]*HARNESS_FLEETS_DIR[^]]*\]/ )
           if (pin) pinned = 1
           if (asg && !pinned) bad = 1 }
         END { exit bad ? 1 : 0 }' "$f" || echo "${f##*/}"
  done; }
LINT="$(mktemp -d)"; tmp_track "$LINT"
printf 'source helpers.sh\nexport HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1\nbash update.sh\n' > "$LINT/test_bad_export.sh"
printf 'HARNESS_HOME="$T/host" bash update.sh\n'                                                    > "$LINT/test_bad_inline.sh"
printf 'import os\nos.environ["HARNESS_HOME"] = d\n'                                                > "$LINT/test_bad_environ.py"
printf 'source helpers.sh\nexport HARNESS_HOME=/h\npin_host_home /h\n'                              > "$LINT/test_bad_late.sh"
printf 'source helpers.sh\npin_host_home "$T/host"\nexport HARNESS_HOME="$T/host"\n'               > "$LINT/test_good_helper.sh"
printf 'source helpers.sh\nmake_env\nHARNESS_HOME=/x cmd\n'                                          > "$LINT/test_good_make_env.sh"
printf 'export HARNESS_HOME="$T/h" HARNESS_FLEETS_DIR="$T/h/fleets"\n'                              > "$LINT/test_good_same_line.sh"
printf 'import os\nos.environ["HARNESS_FLEETS_DIR"] = d + "/f"\nos.environ["HARNESS_HOME"] = d\n'   > "$LINT/test_good_environ.py"
printf '# export HARNESS_HOME=/commented\necho hi\n'                                                 > "$LINT/test_good_comment.sh"
assert_eq "$(host_pin_offenders "$LINT"/test_bad_* | tr '\n' ' ')" \
  "test_bad_environ.py test_bad_export.sh test_bad_inline.sh test_bad_late.sh " "the lint catches a planted offender of every shape"
assert_eq "$(host_pin_offenders "$LINT"/test_good_*)" "" "...and passes a helper, make_env, a same-line pin, and a comment"
offenders="$(host_pin_offenders "$HERE"/test_*.sh "$HERE"/test_*.py | tr '\n' ' ')"
assert_eq "$offenders" "" "no test assigns HARNESS_HOME without pinning HARNESS_FLEETS_DIR (pin_host_home) first"

# ── tmux lint (Acceptance 5): a test that kills tmux must have its own private server ─────────────────
# A real `tmux kill-server` (or kill-session / kill-window on the default socket) in a test that has not
# set a private TMUX_TMPDIR AND dropped the lane's TMUX reaches the server every co-resident fleet runs on.
# Stub bodies, greps and printf'd probe text are not invocations. The scan's own pattern is built from
# parts: spelled out, it would match this file.
tm=tmux; kk=kill
TMUX_KILL_RE="(^|[;&|({'\"[:space:]])(command[[:space:]]+)?${tm}[[:space:]]+${kk}-(server|session|window)([^A-Za-z0-9_-]|\$)"
TMUX_REAL_SKIP='[[:space:]]-[LS][[:space:]]|grep|assert_|printf|echo|sess_describe'   # a private socket, a stub body, a probe string
tmux_offenders(){ local f code
  for f in "$@"; do
    code="$(grep -v '^[[:space:]]*#' "$f")"
    grep -E "$TMUX_KILL_RE" <<<"$code" | grep -vE "$TMUX_REAL_SKIP" >/dev/null || continue   # no real, default-socket kill
    { grep -E '(^|[^A-Za-z0-9_])TMUX_TMPDIR=' <<<"$code" >/dev/null &&
      grep -E '(unset[[:space:]]+([A-Z_]+[[:space:]]+)*TMUX([[:space:]]|$)|env[[:space:]]+-u[[:space:]]+TMUX([[:space:]]|$))' <<<"$code" >/dev/null; } \
      || echo "${f##*/}"
  done; }
printf 'trap "%s %s-server" EXIT\n' "$tm" "$kk"                                                      > "$LINT/test_tmux_bad_server.sh"
printf 'mk(){ %s %s-session -t "=$1"; }\n' "$tm" "$kk"                                              > "$LINT/test_tmux_bad_session.sh"
printf 'export TMUX_TMPDIR="$T/tmux"\n%s %s-server\n' "$tm" "$kk"                                   > "$LINT/test_tmux_bad_no_unset.sh"
printf 'export TMUX_TMPDIR="$T/tmux"; unset TMUX TMUX_PANE\ntrap "%s %s-server" EXIT\n' "$tm" "$kk" > "$LINT/test_tmux_good_private.sh"
printf '%s -L sock %s-server\n' "$tm" "$kk"                                                         > "$LINT/test_tmux_good_L.sh"
printf "grep -q '%s %s-session' \"\$CALLS\"\n" "$tm" "$kk"                                          > "$LINT/test_tmux_good_grep.sh"
assert_eq "$(tmux_offenders "$LINT"/test_tmux_bad_* | tr '\n' ' ')" \
  "test_tmux_bad_no_unset.sh test_tmux_bad_server.sh test_tmux_bad_session.sh " "the tmux lint catches a planted offender"
assert_eq "$(tmux_offenders "$LINT"/test_tmux_good_*)" "" "...and passes a private TMUX_TMPDIR + unset TMUX, a -L socket, and a grep"
assert_eq "$(tmux_offenders "$HERE"/test_*.sh | tr '\n' ' ')" "" "every test that kills tmux has a private TMUX_TMPDIR and drops TMUX"

# ── the generalised decoy (Acceptance 2): a LIVE worker in a registered fleet must survive every test ──
# that updates, supervises, or starts a fleet — handed ONLY the fleet/poller/snapshot pins, which is all a
# lane inherits of the real host. The decoy is the incident in miniature: a registered fleet whose worker
# runs a foreign ENGINE_DIR, which fleet_roll kills and relaunches from the sandbox engine.
# runs_fleets <file> — the test runs update.sh / `harness update`, supervise.sh / `harness supervise`, or `harness start`.
runs_fleets(){ grep -v '^[[:space:]]*#' "$1" |
  grep -E '(bash|exec|"\$[A-Za-z_]+/?[a-z./]*)[^#|]*(update|supervise|start)\.sh|harness"?[[:space:]]+(update|supervise|start)([[:space:]]|$|")' >/dev/null; }
fleet_tests=()
for f in "$HERE"/test_*.sh; do [[ "${f##*/}" == test_hermetic.sh ]] && continue; runs_fleets "$f" && fleet_tests+=("$(basename "$f")"); done
for t in test_supervise_autoupdate.sh test_update_release.sh test_migrate_release.sh test_update_prerelease.sh test_rollback.sh test_update.sh; do
  assert_ok "the fleet-roller scan finds $t" bash -c '[[ " $1 " == *" $2 "* ]]' _ "${fleet_tests[*]}" "$t"
done
DECOY_PID=""
make_live_fleet(){   # LIVE_ROOT: a host root holding ONE registered fleet with a live worker (not in $(): a tmp_track there dies with it)
  LIVE_ROOT="$(mktemp -d)"; tmp_track "$LIVE_ROOT"
  local sd="$LIVE_ROOT/decoy/proj/.harness"; mkdir -p "$LIVE_ROOT/fleets" "$LIVE_ROOT/poller/registry" "$LIVE_ROOT/snapshots" "$sd/run"
  printf ': "${HARNESS_MODE:=single}"\n: "${HARNESS_REPO:=o/decoy}"\n: "${HARNESS_SESS_PREFIX:=decoy}"\n: "${HARNESS_POOL:=1}"\n: "${HARNESS_USE_POLLER:=0}"\n' > "$sd/config"
  (cd "$LIVE_ROOT/decoy/proj" && git init -q .)
  ( cd "$LIVE_ROOT/decoy/proj" && exec env ENGINE_DIR=/old/engine sleep 240 </dev/null >/dev/null 2>&1 ) & DECOY_PID=$!
  echo "$DECOY_PID" > "$sd/run/worker-1.pid"
  printf '{"prefix":"decoy","project":"%s","run_dir":"%s/run","slugs":[],"started_at":1}\n' "$sd" "$sd" > "$LIVE_ROOT/fleets/decoy.json"
}
for t in "${fleet_tests[@]}"; do
  make_live_fleet
  env -u TMUX -u TMUX_PANE HARNESS_FLEETS_DIR="$LIVE_ROOT/fleets" HARNESS_POLLER_DIR="$LIVE_ROOT/poller" \
      HARNESS_SNAPSHOTS_DIR="$LIVE_ROOT/snapshots" bash "$HERE/$t" >/dev/null 2>&1
  assert_ok "$t: the registered fleet's live worker is not killed" kill -0 "$DECOY_PID"
  assert_eq "$(ls "$LIVE_ROOT/fleets")" "decoy.json" "$t: the fleet registry holds only its one original entry"
  assert_eq "$(ls "$LIVE_ROOT/decoy/proj/.harness/run")" "worker-1.pid" "$t: no worker / priority pid file was relaunched into the live fleet"
  assert_eq "$(find "$LIVE_ROOT/poller/registry" "$LIVE_ROOT/snapshots" -mindepth 1 | wc -l)" "0" "$t: nothing in the live poller registry or snapshots dir"
  kill "$DECOY_PID" 2>/dev/null; wait "$DECOY_PID" 2>/dev/null
done

finish

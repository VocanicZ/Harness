#!/usr/bin/env bash
# test_hermetic_engine_1.sh — slice 1 of 4 of the fifth seam of test_hermetic.sh (#434; #608: split out of it, so each file finishes under the
# per-test cap on Windows): every test that runs update.sh or `harness update` passes on a host whose ~/.harness/engine is a release symlink,
# leaves that host exactly as it was, and never reaches github.com.
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
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/hermetic_lib.sh"
# #610: every bare mktemp below lands in one private dir that goes with the test, so a run from a plain
# shell (not run.sh, which gives each test its own TMPDIR) leaves /tmp as it found it.
PRIVATE_TMP="$(mktemp -d)"; tmp_track "$PRIVATE_TMP"; export TMPDIR="$PRIVATE_TMP"
unset_inherited_config   # a direct run from inside a live lane (#541): its HARNESS_* config must not reach the probes below

pin_host_home "$PRIVATE_TMP/pinned-host"   # (#541) the decoy host below is handed down as HOME / HARNESS_HOME on purpose; everything else is pinned
hermetic_scan; mine=(); while read -r x; do [[ -n $x ]] && mine+=("$x"); done < <(hermetic_slice 1 4 "${update_tests[@]}")
echo "-- slice 1 of 4: ${mine[*]:-nothing}"
for t in ${mine[@]+"${mine[@]}"}; do
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

finish
